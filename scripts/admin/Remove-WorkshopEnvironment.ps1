#Requires -Version 7.2
<#
.SYNOPSIS
    Deletes everything New-WorkshopEnvironment.ps1 created for one event, and
    nothing else.

.DESCRIPTION
    Selects by tag only: a resource group is in scope when it carries
    ManagedBy=workshop-environment AND Event=<EventName>. Within that set:

      - student groups (WorkshopRole=student) are deleted with everything the
        labs deployed into them;
      - the event's identity group (WorkshopRole=identities) is deleted with
        every student identity and federated credential in it;
      - the automation group (WorkshopRole=automation) is never touched, and
        neither is any group with a missing or unknown WorkshopRole.

    Before deleting a student group, the role assignments its student identity
    holds there are removed first, so access ends even if the group itself
    refuses to delete (a Recovery Services vault still holding backup items,
    or a lock). The script waits for the deletions, reports any group that
    survived, and is safe to re-run until nothing is left.

    Pass a roster to remove only those students (their groups and their
    identities) and keep the rest of the event.

    Rows are shown as "student group 03"; -ShowNames reveals the GitHub
    usernames on a local run (never under Actions).

.PARAMETER EventName
    The event name used at creation (Event tag).

.PARAMETER SubscriptionId
    Subscription to clean up.

.PARAMETER TenantId
    Optional tenant check.

.PARAMETER RosterPath
    Optional roster CSV: limit the teardown to these students.

.PARAMETER RosterEnvironmentVariable
    Same, reading the CSV text from an environment variable.

.PARAMETER TimeoutMinutes
    How long to wait for the deletions. Default: 60. Azure Firewall and
    Bastion take several minutes each.

.PARAMETER WhatIf
    List what would be deleted without deleting anything. Always run this first.

.EXAMPLE
    ./scripts/admin/Remove-WorkshopEnvironment.ps1 -EventName MyEvent -SubscriptionId <subscription-id> -WhatIf

.EXAMPLE
    ./scripts/admin/Remove-WorkshopEnvironment.ps1 -EventName MyEvent -SubscriptionId <subscription-id>
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [string] $EventName,
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [string] $TenantId,
    [string] $RosterPath,
    [string] $RosterEnvironmentVariable,
    [ValidateRange(1, 240)] [int] $TimeoutMinutes = 60,
    [switch] $ShowNames
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'WorkshopEnvironment.psm1') -Force
Initialize-WorkshopOutput -ShowNames:$ShowNames

try {
    Write-WorkshopStep 'Checking inputs'
    Assert-WorkshopValue $EventName 'EventName' '-EventName'
    Assert-WorkshopValue $SubscriptionId 'Guid' '-SubscriptionId'
    if ($TenantId) { Assert-WorkshopValue $TenantId 'Guid' '-TenantId' }

    $only = $null
    if ($RosterPath -or $RosterEnvironmentVariable) {
        $roster = Import-WorkshopRoster -Path $RosterPath -EnvironmentVariable $RosterEnvironmentVariable
        $only = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($s in $roster) { [void] $only.Add($s.GitHubUsername) }
        Write-WorkshopOk "limited to the $($only.Count) students in the roster"
    }
    if ($WhatIfPreference) { Write-Host "`n  *** PLAN MODE -- nothing will be deleted ***" -ForegroundColor Yellow }

    Write-WorkshopStep 'Checking Azure sign-in'
    $null = Connect-WorkshopSubscription -SubscriptionId $SubscriptionId -TenantId $TenantId
    Write-WorkshopOk 'subscription selected and tenant confirmed'

    # ------------------------------------------------------------------- #
    Write-WorkshopStep "Finding resources tagged for event '$EventName'"
    $list = Invoke-WorkshopAz @('group', 'list', '--query', "[?tags.$($Workshop.ManagedByTag)=='$($Workshop.ManagedByValue)']", '-o', 'json')
    if ($list.ExitCode -ne 0) { throw "Could not list resource groups: $($list.StdErr)" }
    $tagged = @(ConvertFrom-WorkshopJson $list.StdOut) | Where-Object { (Get-WorkshopTag $_.tags $Workshop.EventTag) -ieq $EventName }

    $studentGroups = [System.Collections.Generic.List[object]]::new()
    $identityGroups = [System.Collections.Generic.List[object]]::new()
    $n = 0
    foreach ($rg in ($tagged | Sort-Object name)) {
        $role = Get-WorkshopTag $rg.tags $Workshop.RoleTag
        $owner = Get-WorkshopTag $rg.tags $Workshop.OwnerTag
        switch ($role) {
            'student' {
                $n++
                $label = 'student group {0:d2}' -f $n
                Register-WorkshopSensitiveValue $rg.name $label
                Register-WorkshopSensitiveValue $owner $label
                if ($only -and -not $only.Contains([string] $owner)) { continue }
                $studentGroups.Add([pscustomobject]@{ Name = $rg.name; Id = $rg.id; Owner = $owner; Label = $label })
            }
            'identities' { $identityGroups.Add($rg) }
            'automation' { }   # never in scope (it carries no Event tag anyway)
            default { Write-WorkshopWarn "a resource group tagged for this event has no known WorkshopRole and was left alone." }
        }
    }

    # Student identities live in the identity group(s); find them by tag.
    $identities = [System.Collections.Generic.List[object]]::new()
    foreach ($g in $identityGroups) {
        $ids = Invoke-WorkshopAz @('identity', 'list', '--resource-group', $g.name, '-o', 'json')
        if ($ids.ExitCode -ne 0) { throw "Could not list identities: $($ids.StdErr)" }
        foreach ($id in @(ConvertFrom-WorkshopJson $ids.StdOut)) {
            if (-not (Test-WorkshopOwnedResource -Tags $id.tags -EventName $EventName -Role 'student-identity')) { continue }
            $owner = Get-WorkshopTag $id.tags $Workshop.OwnerTag
            Register-WorkshopSensitiveValue $id.name 'student identity'
            Register-WorkshopSensitiveValue $owner 'student'
            $identities.Add([pscustomobject]@{ Id = $id.id; PrincipalId = $id.principalId; Owner = $owner; Group = $g.name })
        }
    }
    $eventPrincipals = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($i in $identities) { [void] $eventPrincipals.Add($i.PrincipalId) }
    $identitiesToDelete = @(if ($only) { $identities | Where-Object { $only.Contains([string] $_.Owner) } } else { $identities })
    $deleteIdentityGroups = -not $only

    Write-WorkshopOk "$($studentGroups.Count) student resource group(s)"
    Write-WorkshopOk "$($identitiesToDelete.Count) student identit$(if ($identitiesToDelete.Count -eq 1) { 'y' } else { 'ies' })"
    Write-WorkshopOk "$(if ($deleteIdentityGroups) { $identityGroups.Count } else { 0 }) identity resource group(s)"
    if ($studentGroups.Count -eq 0 -and $identitiesToDelete.Count -eq 0 -and (-not $deleteIdentityGroups -or $identityGroups.Count -eq 0)) {
        Write-WorkshopOk "nothing is tagged for event '$EventName'. Nothing to delete."
        Add-WorkshopSummary @('## Workshop environment', '', "Event: ``$EventName`` - destroy: nothing to delete")
        exit 0
    }

    foreach ($g in $studentGroups) { Write-WorkshopPlan "delete $($g.Label) (and everything the labs deployed in it)" }
    if ($deleteIdentityGroups) { foreach ($g in $identityGroups) { Write-WorkshopPlan 'delete the identity resource group (every student identity and federated credential)' } }
    else { Write-WorkshopPlan "delete $($identitiesToDelete.Count) student identities from the identity group" }

    $what = "event '$EventName': $($studentGroups.Count) student resource group(s) and $($identitiesToDelete.Count) identities"
    if (-not $PSCmdlet.ShouldProcess($what, 'Delete')) {
        if ($WhatIfPreference) { Write-Host "`n  *** PLAN MODE -- nothing was deleted ***`n" -ForegroundColor Yellow }
        Add-WorkshopSummary @('## Workshop environment', '', "Event: ``$EventName`` - destroy preview", '',
            '| Would delete | Count |', '|---|---|', "| Student resource groups | $($studentGroups.Count) |", "| Student identities | $($identitiesToDelete.Count) |")
        exit 0
    }

    # ------------------------------------------------------------------- #
    Write-WorkshopStep 'Revoking student identity access'
    $failures = 0
    foreach ($g in $studentGroups) {
        $ra = Invoke-WorkshopAz @('role', 'assignment', 'list', '--scope', $g.Id, '--fill-principal-name', 'false', '--fill-role-definition-name', 'false', '-o', 'json')
        if ($ra.ExitCode -ne 0) { Write-WorkshopWarn "$($g.Label): could not list role assignments; the group delete removes them anyway."; continue }
        $mine = @(@(ConvertFrom-WorkshopJson $ra.StdOut) | Where-Object { $eventPrincipals.Contains([string] $_.principalId) -and $_.scope -ieq $g.Id })
        if ($mine.Count -eq 0) { Write-WorkshopSkip "$($g.Label): no identity role assignments"; continue }
        $d = Invoke-WorkshopAz (@('role', 'assignment', 'delete', '--ids') + @($mine.id))
        if ($d.ExitCode -ne 0) { $failures++; Write-WorkshopWarn "$($g.Label): could not remove $($mine.Count) role assignment(s): $($d.StdErr)" }
        else { Write-WorkshopOk "$($g.Label): removed $($mine.Count) role assignment(s)" }
    }

    Write-WorkshopStep 'Deleting resource groups'
    $pending = [System.Collections.Generic.List[object]]::new()
    foreach ($g in $studentGroups) {
        $r = Invoke-WorkshopAz @('group', 'delete', '--name', $g.Name, '--yes', '--no-wait')
        if ($r.ExitCode -ne 0) { $failures++; Write-WorkshopWarn "$($g.Label): delete request failed: $($r.StdErr)" }
        else { $pending.Add([pscustomobject]@{ Name = $g.Name; Label = $g.Label }); Write-WorkshopOk "$($g.Label): delete requested" }
    }
    if ($deleteIdentityGroups) {
        foreach ($g in $identityGroups) {
            $r = Invoke-WorkshopAz @('group', 'delete', '--name', $g.name, '--yes', '--no-wait')
            if ($r.ExitCode -ne 0) { $failures++; Write-WorkshopWarn "identity resource group: delete request failed: $($r.StdErr)" }
            else { $pending.Add([pscustomobject]@{ Name = $g.name; Label = 'identity resource group' }); Write-WorkshopOk 'identity resource group: delete requested' }
        }
    } else {
        foreach ($i in $identitiesToDelete) {
            $r = Invoke-WorkshopAz @('identity', 'delete', '--ids', $i.Id)
            if ($r.ExitCode -ne 0) { $failures++; Write-WorkshopWarn "a student identity could not be deleted: $($r.StdErr)" }
        }
        Write-WorkshopOk "deleted $($identitiesToDelete.Count) student identities (federated credentials go with them)"
    }

    Write-WorkshopStep "Waiting for the deletions (up to $TimeoutMinutes minutes)"
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 30
        foreach ($p in @($pending)) {
            $e = Invoke-WorkshopAz @('group', 'exists', '--name', $p.Name)
            if ($e.ExitCode -eq 0 -and $e.StdOut.Trim() -eq 'false') { [void] $pending.Remove($p); Write-WorkshopOk "$($p.Label): gone" }
        }
    }

    Write-Host "`n$('=' * 72)" -ForegroundColor Green
    Write-Host ' WORKSHOP TEARDOWN SUMMARY' -ForegroundColor Green
    Write-Host "$('=' * 72)" -ForegroundColor Green
    Write-Host "  resource groups still present : $($pending.Count)"
    Write-Host "  failed requests               : $failures"
    Add-WorkshopSummary @('## Workshop environment', '', "Event: ``$EventName`` - destroy", '', '| Result | Count |', '|---|---|',
        "| Student resource groups deleted | $($studentGroups.Count - @($pending | Where-Object Label -like 'student*').Count) |",
        "| Resource groups still present | $($pending.Count) |", "| Failed requests | $failures |")

    if ($pending.Count -gt 0 -or $failures -gt 0) {
        foreach ($p in $pending) { Write-WorkshopWarn "$($p.Label) still exists." }
        Write-WorkshopWarn 'A group usually survives because of a Recovery Services vault with backup items (L4: stop protection and delete the backup data, soft delete keeps it 14 days) or a resource lock. Fix that and re-run: only what is left is retried.'
        exit 1
    }
    Write-WorkshopOk "everything tagged for event '$EventName' is gone"
} catch {
    Write-WorkshopError $_.Exception.Message
    exit 1
}
