#Requires -Version 7.2
<#
.SYNOPSIS
    Applies Azure Policy guardrails to the workshop's student resource groups
    by deploying lab-policy.bicep.

.DESCRIPTION
    Picks the target resource groups one of two ways:

      -EventName            (recommended) every student group that
                            New-WorkshopEnvironment.ps1 created for that event,
                            found by its tags (ManagedBy=workshop-environment,
                            Event=<event>, WorkshopRole=student), whatever the
                            groups are called. Identity and automation groups
                            are never included.
      -ResourceGroupPrefix  every group whose name starts with the prefix
                            (default rg-techdemo-), for groups made some other
                            way, such as the manual per-participant steps.

    One subscription-scope deployment of lab-policy.bicep then assigns, to
    each group:

        1. Allowed locations        -- deployments must target -Location
        2. Allowed resource types   -- only the resource types used by L1.1-L1.4
        3. Inherit tag, one per -TagsToInherit (default Owner, Event, Date,
           Instructor: the tags New-WorkshopEnvironment.ps1 writes)

    All assignments are scoped to the individual resource group so they do not
    affect other resource groups in the subscription.

    The assignments -- and the resource-type whitelist -- are declared in
    lab-policy.bicep next to this script, the same tool the students use,
    reviewable in the same pull requests. This wrapper adds the part a
    template cannot do: finding which resource groups to target. ARM PUTs are
    idempotent, so a re-run converges existing assignments instead of skipping
    them -- an edited whitelist actually lands. Run with -WhatIf to preview
    without applying.

    Every input is a parameter: nothing is read from a roster file, and
    nothing tenant-specific is in the script. Group names (which may be GitHub
    usernames) are shown as "resource group 03" unless you pass -ShowNames.

.PREREQUISITES
    PowerShell 7.2+ and Azure CLI, signed in with an account holding
    Resource Policy Contributor or Owner on the target resource groups
    (Microsoft.Authorization/policyAssignments/write). Contributor is not
    enough -- the role's notActions exclude it, which is the same wall the
    L2.4 chapter teaches.

.PARAMETER SubscriptionId
    The workshop subscription.

.PARAMETER TenantId
    Optional. When given, the run stops if the subscription is in another tenant.

.PARAMETER EventName
    Target the student groups New-WorkshopEnvironment.ps1 tagged for this
    event. Cannot be combined with -ResourceGroupPrefix.

.PARAMETER ResourceGroupPrefix
    Target groups whose name starts with this prefix. Default: rg-techdemo-.
    Used when -EventName is not given. Cannot be empty (that would be every
    group in the subscription).

.PARAMETER Location
    The allowed Azure regions. Default: eastus2, westus2.

    BOTH are required. L1.1-L1.3 deploy to the primary region (eastus2), but L1.4
    deploys its failover stack to a secondary region -- westus2, the default of
    the secondaryLocation parameter in curriculum/L1.4-production-platform/main.bicep. Restricting
    this to eastus2 alone makes L1.4 undeployable. If you change the lab regions,
    change them here and in the L1.4 template together.

.PARAMETER TagsToInherit
    Resource-group tags every resource inside inherits.
    Default: Owner, Event, Date, Instructor.

.PARAMETER ShowNames
    List the target group names on the console.

.PARAMETER WhatIf
    Run the deployment's what-if without making any changes.

.EXAMPLE
    # Preview, for the groups of one workshop event
    ./scripts/admin/Set-LabPolicy.ps1 -SubscriptionId <subscription-id> -EventName MyEvent -WhatIf

.EXAMPLE
    # Apply
    ./scripts/admin/Set-LabPolicy.ps1 -SubscriptionId <subscription-id> -EventName MyEvent

.EXAMPLE
    # Groups created by hand with the rg-techdemo- prefix
    ./scripts/admin/Set-LabPolicy.ps1 -SubscriptionId <subscription-id> -ResourceGroupPrefix rg-techdemo-
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'ByPrefix')]
param(
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [string] $TenantId,
    [Parameter(Mandatory, ParameterSetName = 'ByEvent')] [string] $EventName,
    [Parameter(ParameterSetName = 'ByPrefix')] [string] $ResourceGroupPrefix = 'rg-techdemo-',
    [string[]] $Location = @('eastus2', 'westus2'),
    [string[]] $TagsToInherit = @('Owner', 'Event', 'Date', 'Instructor'),
    [switch] $ShowNames
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'WorkshopEnvironment.psm1') -Force
Initialize-WorkshopOutput -ShowNames:$ShowNames
$TemplateFile = Join-Path $PSScriptRoot 'lab-policy.bicep'
$byEvent = $PSCmdlet.ParameterSetName -eq 'ByEvent'

try {
    # ------------------------------------------------------------------- #
    Write-WorkshopStep 'Checking inputs'
    if (-not (Test-Path -LiteralPath $TemplateFile)) { throw "Template not found: $TemplateFile" }
    Assert-WorkshopValue $SubscriptionId 'Guid' '-SubscriptionId'
    if ($TenantId) { Assert-WorkshopValue $TenantId 'Guid' '-TenantId' }
    if ($byEvent) {
        Assert-WorkshopValue $EventName 'EventName' '-EventName'
    } elseif ([string]::IsNullOrWhiteSpace($ResourceGroupPrefix)) {
        throw '-ResourceGroupPrefix cannot be empty: that would target every resource group in the subscription. Use -EventName instead.'
    } else {
        Assert-WorkshopValue $ResourceGroupPrefix 'RgPrefix' '-ResourceGroupPrefix'
    }
    if (@($Location).Count -eq 0) { throw '-Location needs at least one region.' }
    foreach ($l in $Location) { Assert-WorkshopValue $l 'Location' '-Location' }
    foreach ($t in $TagsToInherit) {
        if ($t -notmatch '^[A-Za-z][A-Za-z0-9_.-]{0,63}$') { throw "-TagsToInherit: '$t' is not a valid tag name." }
    }
    Write-WorkshopOk ("target: " + $(if ($byEvent) { "student groups of event '$EventName'" } else { "groups named '$ResourceGroupPrefix*'" }))
    Write-WorkshopOk "allowed locations: $($Location -join ', ')   inherited tags: $(if ($TagsToInherit) { $TagsToInherit -join ', ' } else { '(none)' })"

    # ------------------------------------------------------------------- #
    Write-WorkshopStep 'Checking Azure sign-in'
    $null = Connect-WorkshopSubscription -SubscriptionId $SubscriptionId -TenantId $TenantId
    Write-WorkshopOk 'subscription selected and tenant confirmed'

    # ------------------------------------------------------------------- #
    # The one job the template cannot do: a deployment declares which groups
    # get the guardrails, it cannot go looking for them.
    Write-WorkshopStep 'Finding the target resource groups'
    if ($byEvent) {
        $list = Invoke-WorkshopAz @('group', 'list', '--query', "[?tags.$($Workshop.ManagedByTag)=='$($Workshop.ManagedByValue)']", '-o', 'json')
        if ($list.ExitCode -ne 0) { throw "Could not list resource groups: $($list.StdErr)" }
        $targets = @(@(ConvertFrom-WorkshopJson $list.StdOut) |
            Where-Object { Test-WorkshopOwnedResource -Tags $_.tags -EventName $EventName -Role 'student' } |
            ForEach-Object name | Sort-Object)
    } else {
        $list = Invoke-WorkshopAz @('group', 'list', '--query', '[].name', '-o', 'json')
        if ($list.ExitCode -ne 0) { throw "Could not list resource groups: $($list.StdErr)" }
        $targets = @(@(ConvertFrom-WorkshopJson $list.StdOut) |
            Where-Object { $_.StartsWith($ResourceGroupPrefix, [StringComparison]::OrdinalIgnoreCase) } | Sort-Object)
    }
    $i = 0
    foreach ($name in $targets) { $i++; Register-WorkshopSensitiveValue $name ('resource group {0:d2}' -f $i) }

    if ($targets.Count -eq 0) {
        $hint = if ($byEvent) { "Create the class first with New-WorkshopEnvironment.ps1 -EventName $EventName." } else { 'Check the prefix, or use -EventName for groups New-WorkshopEnvironment.ps1 created.' }
        Write-WorkshopWarn "No matching resource groups. $hint"
        exit 0
    }
    Write-WorkshopOk "found $($targets.Count) resource group(s)"
    if ($ShowNames) { $targets | ForEach-Object { Write-WorkshopOk "  $_" } }

    # ------------------------------------------------------------------- #
    # Parameters go in a file, not on the command line: JSON in an argument
    # is fragile through az.cmd on Windows, and a large class makes a long one.
    $deploymentName = if ($byEvent) { "lab-policy-$($EventName.ToLowerInvariant())" } else { 'lab-policy' }
    $paramFile = Join-Path ([System.IO.Path]::GetTempPath()) "lab-policy-$([guid]::NewGuid().ToString('N')).parameters.json"
    [ordered]@{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = [ordered]@{
            resourceGroupNames = @{ value = @($targets) }
            allowedLocations   = @{ value = @($Location) }
            tagsToInherit      = @{ value = @($TagsToInherit) }
        }
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $paramFile -Encoding utf8

    try {
        $commonArgs = @('--location', $Location[0], '--name', $deploymentName, '--template-file', $TemplateFile, '--parameters', "@$paramFile")

        if ($WhatIfPreference) {
            Write-WorkshopStep 'What-if -- no changes will be made'
            $r = Invoke-WorkshopAz (@('deployment', 'sub', 'what-if') + $commonArgs)
            if ($r.ExitCode -ne 0) { throw "what-if failed: $($r.StdErr)" }
            Write-Host (Protect-WorkshopText $r.StdOut)
            exit 0
        }

        if (-not $PSCmdlet.ShouldProcess("$($targets.Count) resource group(s)", 'Assign lab policy guardrails')) { exit 0 }

        Write-WorkshopStep 'Deploying policy assignments'
        $r = Invoke-WorkshopAz (@('deployment', 'sub', 'create') + $commonArgs + @('--query', 'properties.outputs', '-o', 'json'))
        if ($r.ExitCode -ne 0) {
            throw "Deployment failed. Do you hold Resource Policy Contributor or Owner? Contributor cannot write policy assignments.`n  $($r.StdErr)"
        }
        $o = ConvertFrom-WorkshopJson $r.StdOut
    } finally {
        Remove-Item -LiteralPath $paramFile -Force -ErrorAction SilentlyContinue
    }

    # ------------------------------------------------------------------- #
    Write-Host "`n$('=' * 72)" -ForegroundColor Green
    Write-Host ' POLICY ASSIGNMENTS COMPLETE' -ForegroundColor Green
    Write-Host "$('=' * 72)" -ForegroundColor Green
    Write-Host "  Resource groups processed : $($o.resourceGroupsProcessed.value)"
    Write-Host "  Assignments per group     : $($o.assignmentsPerGroup.value)  (location + resource types + $(@($TagsToInherit).Count) tags)"
    Write-Host "  Allowed locations         : $($Location -join ', ')"
    Write-Host "  Resource type whitelist   : $($o.resourceTypeCount.value) types (see lab-policy.bicep)"
    Write-Host ''
} catch {
    Write-WorkshopError $_.Exception.Message
    exit 1
}
