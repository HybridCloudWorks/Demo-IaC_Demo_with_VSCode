#Requires -Version 7.2
<#
.SYNOPSIS
    Creates (or repairs) one isolated deploy identity and resource group per student.

.DESCRIPTION
    Supersedes New-LabEnvironment.ps1 and Setup-OidcAll.ps1. For every row of
    the roster it makes sure that:

      1. The student has a resource group. Default name: the student's GitHub
         username, which is the group the curriculum workflows target by
         default, so the fork needs no AZURE_RESOURCE_GROUP setting.
      2. The student has a user-assigned managed identity, kept in the event's
         identity resource group (students hold no role there).
      3. That identity has exactly one federated credential, for the main
         branch of the student's own fork, in the subject format the fork
         presents (see -SubjectFormat). It is an explicit subject: managed
         identities cannot hold wildcard or pattern credentials at all.
      4. That identity holds Contributor on the student's resource group, and
         nowhere else.
      5. Optional: the student's Entra account (EntraUpn column) holds Reader
         on the same group, for the portal and Bastion.

    It then writes one row per student to a local, gitignored CSV holding the
    values that student's fork needs (AZURE_CLIENT_ID and the rest). Share each
    row privately with its student, or pass -SetForkVariables to set them on
    forks your gh account administers.

    Every step checks before it acts, so re-running is safe; it is also how you
    add late students and pick up forks created after the first run. Anything
    that already exists is only reused when it carries this event's tags: an
    untagged resource group with a student's name stops that row instead of
    being adopted.

    Student usernames and UPNs never reach the console. Rows are shown as
    "student 03"; -ShowNames reveals them on a local run (never under Actions).

.PREREQUISITES
    PowerShell 7.2+, Azure CLI signed in (az login, or azure/login in the
    workflow) as an identity holding the roles New-WorkshopBootstrap.ps1
    grants (or Owner). The GitHub CLI (gh) is optional: it raises the GitHub
    API limit from 60 to 5,000 reads an hour, and -SetForkVariables needs it.

.PARAMETER EventName
    Short event name, 3-32 letters, digits and hyphens (e.g. MyEvent). Tags
    everything this run creates; Remove-WorkshopEnvironment.ps1 deletes by it.

.PARAMETER SubscriptionId
    Subscription to build in.

.PARAMETER TenantId
    Optional. When given, the run stops if the subscription is in another tenant.

.PARAMETER Location
    Region for the resource groups and identities. Default: eastus2. (Federated
    credentials on managed identities are not available in Malaysia South.)

.PARAMETER RosterPath
    Roster CSV. Default: workshop-roster.csv next to this script (gitignored).

.PARAMETER RosterEnvironmentVariable
    Read the roster CSV text from this environment variable instead of a file.
    The workflow uses WORKSHOP_ROSTER_CSV, filled from the secret of that name.

.PARAMETER OutputPath
    Where to write the per-student client IDs. Default:
    workshop-client-ids.csv next to this script (gitignored). Not written
    under -WhatIf.

.PARAMETER RepositoryName
    Default fork name when the roster's Repository column is empty.

.PARAMETER Branch
    Branch in the federated credential subject. Default: main.

.PARAMETER SubjectFormat
    Auto (default): ID-enriched subject for forks created after 15 Jul 2026,
    name-only subject for older forks. Immutable or Classic forces one format.
    Immutable and Auto need the fork to exist; until it does, the row is
    "waiting-for-fork" and gets no credential.

.PARAMETER ResourceGroupPrefix
    Optional prefix for the student resource groups (e.g. rg-techdemo- so
    Set-LabPolicy.ps1 finds them). With a prefix the group no longer matches
    the fork owner, so the student must set the AZURE_RESOURCE_GROUP secret;
    the output CSV says so per row.

.PARAMETER IdentityResourceGroup
    Resource group for the student identities. Default:
    rg-workshop-<event>-identities.

.PARAMETER InstructorName
    Optional value for the Instructor tag (Set-LabPolicy.ps1 inherits it).

.PARAMETER SetForkVariables
    Also set AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID,
    AZURE_PREFIX and AZURE_LOCATION as repository variables on each fork (and
    the AZURE_RESOURCE_GROUP secret when -ResourceGroupPrefix is used).
    Needs gh signed in with admin on the forks. Local runs only.

.PARAMETER ShowNames
    Show GitHub usernames in the console. Local runs only.

.PARAMETER WhatIf
    Plan mode: report every change without making any. Always run this first.

.EXAMPLE
    ./scripts/admin/New-WorkshopEnvironment.ps1 -EventName MyEvent `
        -SubscriptionId <subscription-id> -TenantId <tenant-id> -WhatIf

.EXAMPLE
    ./scripts/admin/New-WorkshopEnvironment.ps1 -EventName MyEvent `
        -SubscriptionId <subscription-id> -TenantId <tenant-id>

.EXAMPLE
    # Pre-staged GitHub accounts you administer: also set the fork variables.
    ./scripts/admin/New-WorkshopEnvironment.ps1 -EventName MyEvent `
        -SubscriptionId <subscription-id> -SetForkVariables
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)] [string] $EventName,
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [string] $TenantId,
    [string] $Location = 'eastus2',
    [string] $RosterPath = (Join-Path $PSScriptRoot 'workshop-roster.csv'),
    [string] $RosterEnvironmentVariable,
    [string] $OutputPath = (Join-Path $PSScriptRoot 'workshop-client-ids.csv'),
    [string] $RepositoryName = 'Demo-IaC_Demo_with_VSCode',
    [string] $Branch = 'main',
    [ValidateSet('Auto', 'Immutable', 'Classic')] [string] $SubjectFormat = 'Auto',
    [string] $ResourceGroupPrefix = '',
    [string] $IdentityResourceGroup,
    [string] $InstructorName,
    [switch] $SetForkVariables,
    [switch] $ShowNames
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'WorkshopEnvironment.psm1') -Force
Initialize-WorkshopOutput -ShowNames:$ShowNames
$Cmdlet = $PSCmdlet
$Today = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')

# --------------------------------------------------------------------------- #
#  Steps (each one checks first, then acts only through ShouldProcess)         #
# --------------------------------------------------------------------------- #
function Confirm-ResourceGroup {
    param([string] $Name, [string] $Label, [System.Collections.IDictionary] $Tags, [string] $Role)
    $show = Invoke-WorkshopAz @('group', 'show', '--name', $Name, '-o', 'json')
    if ($show.ExitCode -eq 0) {
        $rg = ConvertFrom-WorkshopJson $show.StdOut
        if (-not (Test-WorkshopOwnedResource -Tags $rg.tags -EventName $EventName -Role $Role)) {
            throw "$Label already exists but is not tagged for event '$EventName'. It is never adopted: delete or rename it, or use -ResourceGroupPrefix."
        }
        Write-WorkshopSkip "$Label exists"
        return 'exists'
    }
    if (-not (Test-WorkshopNotFound $show)) { throw "Could not read ${Label}: $($show.StdErr)" }
    if ($Cmdlet.ShouldProcess($Label, 'Create resource group')) {
        $r = Invoke-WorkshopAz (@('group', 'create', '--name', $Name, '--location', $Location, '-o', 'none') + (ConvertTo-WorkshopTagArgument $Tags))
        if ($r.ExitCode -ne 0) { throw "Could not create ${Label}: $($r.StdErr)" }
        Write-WorkshopOk "created $Label"
        return 'created'
    }
    Write-WorkshopPlan "would create $Label"
    'planned'
}

function Confirm-StudentIdentity {
    param($Student)
    $label = "$($Student.Label) identity"
    $show = Invoke-WorkshopAz @('identity', 'show', '--name', $Student.IdentityName, '--resource-group', $IdentityResourceGroup, '-o', 'json')
    if ($show.ExitCode -eq 0) {
        $id = ConvertFrom-WorkshopJson $show.StdOut
        $owner = Get-WorkshopTag $id.tags $Workshop.OwnerTag
        if (-not (Test-WorkshopOwnedResource -Tags $id.tags -EventName $EventName -Role 'student-identity') -or $owner -ine $Student.GitHubUsername) {
            throw "$label already exists but is not tagged for this student and event. It is never adopted."
        }
        Write-WorkshopSkip "$label exists"
        return $id
    }
    if (-not (Test-WorkshopNotFound $show)) { throw "Could not read ${label}: $($show.StdErr)" }
    $tags = [ordered]@{
        $Workshop.ManagedByTag = $Workshop.ManagedByValue
        $Workshop.EventTag     = $EventName
        $Workshop.RoleTag      = 'student-identity'
        $Workshop.OwnerTag     = $Student.GitHubUsername
    }
    if ($Cmdlet.ShouldProcess($label, 'Create user-assigned managed identity')) {
        $r = Invoke-WorkshopAz (@('identity', 'create', '--name', $Student.IdentityName, '--resource-group', $IdentityResourceGroup,
                '--location', $Location, '-o', 'json') + (ConvertTo-WorkshopTagArgument $tags))
        if ($r.ExitCode -ne 0) { throw "Could not create ${label}: $($r.StdErr)" }
        Write-WorkshopOk "created $label"
        return (ConvertFrom-WorkshopJson $r.StdOut)
    }
    Write-WorkshopPlan "would create $label"
    $null
}

function Confirm-StudentCredential {
    param($Student)
    $label = "$($Student.Label) federated credential"
    $list = Invoke-WorkshopAz @('identity', 'federated-credential', 'list', '--identity-name', $Student.IdentityName,
        '--resource-group', $IdentityResourceGroup, '-o', 'json')
    if ($list.ExitCode -ne 0) { throw "Could not list ${label}s: $($list.StdErr)" }
    $creds = @(ConvertFrom-WorkshopJson $list.StdOut)
    $mine = $creds | Where-Object { $_.name -eq $CredentialName } | Select-Object -First 1
    $others = @($creds | Where-Object { $_.name -ne $CredentialName })
    if ($others.Count -gt 0) {
        Write-WorkshopWarn "$($Student.Label): the identity has $($others.Count) other federated credential(s) that this script did not create. Review them in the portal; only '$CredentialName' is expected."
    }

    if (-not $Student.Subject) {
        Write-WorkshopWarn "$($Student.Label): fork not found on GitHub yet, so no federated credential. Re-run after the student forks the repo."
        return 'waiting-for-fork'
    }
    if ($mine -and $mine.subject -ceq $Student.Subject -and $mine.issuer -eq $Workshop.Issuer -and
        (@($mine.audiences) -join ',') -eq $Workshop.Audience) {
        Write-WorkshopSkip "$label is current ($($Student.SubjectFormat) subject)"
        return 'ready'
    }
    $verb = if ($mine) { 'update' } else { 'create' }
    $why = if ($mine) { ' (the fork changed since the last run)' } else { '' }
    if ($Cmdlet.ShouldProcess($label, "$verb federated credential, $($Student.SubjectFormat) subject")) {
        $r = Invoke-WorkshopWithRetry -RetryPattern 'Conflict|409|Concurrent' -Attempts 5 -DelaySeconds 5 -Action {
            Invoke-WorkshopAz @('identity', 'federated-credential', $verb, '--name', $CredentialName,
                '--identity-name', $Student.IdentityName, '--resource-group', $IdentityResourceGroup,
                '--issuer', $Workshop.Issuer, '--subject', $Student.Subject, '--audiences', $Workshop.Audience, '-o', 'none')
        }
        if ($r.ExitCode -ne 0) { throw "Could not $verb ${label}: $($r.StdErr)" }
        Write-WorkshopOk "$($verb)d $label$why"
        return 'ready'
    }
    Write-WorkshopPlan "would $verb $label$why"
    'planned'
}

function Confirm-RoleAssignment {
    param([string] $PrincipalId, [string] $PrincipalType, [string] $RoleId, [string] $Scope, [string] $Label)
    $list = Invoke-WorkshopAz @('role', 'assignment', 'list', '--scope', $Scope, '--role', $RoleId,
        '--fill-principal-name', 'false', '--fill-role-definition-name', 'false', '-o', 'json')
    if ($list.ExitCode -ne 0) { throw "Could not list role assignments for ${Label}: $($list.StdErr)" }
    $existing = @(ConvertFrom-WorkshopJson $list.StdOut) | Where-Object { $_.principalId -eq $PrincipalId -and $_.scope -ieq $Scope }
    if ($existing) { Write-WorkshopSkip "$Label already assigned"; return 'exists' }
    if ($Cmdlet.ShouldProcess($Label, 'Create role assignment')) {
        # A new identity takes a few seconds to replicate before ARM can name it.
        $r = Invoke-WorkshopWithRetry -RetryPattern 'PrincipalNotFound|does not exist in the directory|ReplicationDelay' -Action {
            Invoke-WorkshopAz @('role', 'assignment', 'create', '--assignee-object-id', $PrincipalId,
                '--assignee-principal-type', $PrincipalType, '--role', $RoleId, '--scope', $Scope,
                '--description', "Workshop environment: $EventName", '-o', 'none')
        }
        if ($r.ExitCode -ne 0) { throw "Could not assign ${Label}: $($r.StdErr)" }
        Write-WorkshopOk "assigned $Label"
        return 'created'
    }
    Write-WorkshopPlan "would assign $Label"
    'planned'
}

function Confirm-PortalReader {
    param($Student, [string] $Scope, [bool] $GroupExists)
    if (-not $Student.EntraUpn) { return 'n/a' }
    if ($script:UserLookupDenied) { return 'skipped' }
    $u = Invoke-WorkshopAz @('ad', 'user', 'show', '--id', $Student.EntraUpn, '--query', 'id', '-o', 'tsv')
    if ($u.ExitCode -ne 0) {
        if ($u.StdErr -match 'Authorization_RequestDenied|Insufficient privileges|Forbidden') {
            # Expected in the workflow: the automation identity has no Graph
            # permission. Counted once and reported in the summary.
            $script:UserLookupDenied = $true
            return 'skipped'
        }
        Write-WorkshopWarn "$($Student.Label): EntraUpn was not found in the tenant; no portal access granted."
        return 'not-found'
    }
    $userId = $u.StdOut.Trim()
    if (-not $GroupExists) { Write-WorkshopPlan "would grant $($Student.Label) Reader on their resource group"; return 'planned' }
    $state = Confirm-RoleAssignment -PrincipalId $userId -PrincipalType 'User' -RoleId $Workshop.ReaderRoleId -Scope $Scope -Label "$($Student.Label) portal Reader"
    if ($state -eq 'planned') { return 'planned' }
    'granted'
}

function Set-ForkVariable {
    param($Result)
    $fork = $Result.Repository
    $label = "$($Result.Label) fork"
    $existingSecrets = @()
    $s = Invoke-WorkshopNative -FilePath 'gh' -ArgumentList @('secret', 'list', '--repo', $fork, '--json', 'name', '--jq', '.[].name')
    if ($s.ExitCode -ne 0) { Write-WorkshopWarn "${label}: cannot read its settings. Your gh account needs admin on the fork."; return $false }
    $existingSecrets = @($s.StdOut -split "`n" | Where-Object { $_ })

    $vars = [ordered]@{
        AZURE_CLIENT_ID       = $Result.AZURE_CLIENT_ID
        AZURE_TENANT_ID       = $Result.AZURE_TENANT_ID
        AZURE_SUBSCRIPTION_ID = $Result.AZURE_SUBSCRIPTION_ID
        AZURE_PREFIX          = $Result.AZURE_PREFIX
        AZURE_LOCATION        = $Result.AZURE_LOCATION
    }
    foreach ($name in $vars.Keys) {
        if ($existingSecrets -contains $name) {
            # The workflows read secrets.X || vars.X: a stale secret (from an
            # earlier Setup-Oidc.ps1 run) would silently win over the variable.
            Write-WorkshopWarn "${label}: a secret named $name exists and overrides the variable. Delete it: gh secret delete $name --repo <fork>"
        }
        if ($Cmdlet.ShouldProcess($label, "Set variable $name")) {
            $r = Invoke-WorkshopNative -FilePath 'gh' -ArgumentList @('variable', 'set', $name, '--repo', $fork, '--body', $vars[$name])
            if ($r.ExitCode -ne 0) { Write-WorkshopWarn "${label}: could not set $name."; return $false }
        }
    }
    if ($Result.ResourceGroupSecretNeeded -eq 'yes' -and $Cmdlet.ShouldProcess($label, 'Set secret AZURE_RESOURCE_GROUP')) {
        # gh reads the value from stdin when --body is absent.
        $r = Invoke-WorkshopNative -FilePath 'gh' -ArgumentList @('secret', 'set', 'AZURE_RESOURCE_GROUP', '--repo', $fork) -InputText $Result.AZURE_RESOURCE_GROUP
        if ($r.ExitCode -ne 0) { Write-WorkshopWarn "${label}: could not set AZURE_RESOURCE_GROUP."; return $false }
    }
    Write-WorkshopOk "$label settings applied"
    $true
}

# --------------------------------------------------------------------------- #
#  Main                                                                        #
# --------------------------------------------------------------------------- #
try {
    Write-WorkshopStep 'Checking inputs'
    Assert-WorkshopValue $EventName 'EventName' '-EventName'
    Assert-WorkshopValue $SubscriptionId 'Guid' '-SubscriptionId'
    if ($TenantId) { Assert-WorkshopValue $TenantId 'Guid' '-TenantId' }
    Assert-WorkshopValue $Location 'Location' '-Location'
    Assert-WorkshopValue $Branch 'Branch' '-Branch'
    Assert-WorkshopValue $RepositoryName 'RepoName' '-RepositoryName'
    Assert-WorkshopValue $ResourceGroupPrefix 'RgPrefix' '-ResourceGroupPrefix'
    if ($SetForkVariables -and (Test-WorkshopWorkflowRun)) {
        throw '-SetForkVariables is for local runs only: the workflow token cannot write to other repositories.'
    }
    if ($SetForkVariables -and -not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw '-SetForkVariables needs the GitHub CLI (gh) signed in with admin on the forks.'
    }
    if (-not $IdentityResourceGroup) { $IdentityResourceGroup = "rg-workshop-$($EventName.ToLowerInvariant())-identities" }
    $CredentialName = 'github-' + ($Branch -replace '[^A-Za-z0-9_-]', '-')
    $Context = "ref:refs/heads/$Branch"

    $roster = Import-WorkshopRoster -Path $RosterPath -EnvironmentVariable $RosterEnvironmentVariable -DefaultRepository $RepositoryName
    foreach ($s in $roster) {
        $s | Add-Member -NotePropertyName ResourceGroup -NotePropertyValue "$ResourceGroupPrefix$($s.GitHubUsername)"
        $s | Add-Member -NotePropertyName IdentityName -NotePropertyValue "id-$($s.GitHubUsername.ToLowerInvariant())"
        if ($s.ResourceGroup.Length -gt 90) { throw "Row $($s.Row): the resource group name would exceed 90 characters. Shorten -ResourceGroupPrefix." }
        Register-WorkshopSensitiveValue $s.ResourceGroup "$($s.Label) resource group"
        Register-WorkshopSensitiveValue $s.IdentityName "$($s.Label) identity"
    }
    Write-WorkshopOk "$($roster.Count) students in the roster"
    Write-WorkshopOk "event: $EventName   location: $Location   subject format: $SubjectFormat"
    if ($WhatIfPreference) { Write-Host "`n  *** PLAN MODE -- no changes will be made ***" -ForegroundColor Yellow }

    Write-WorkshopStep 'Checking Azure sign-in'
    $ctx = Connect-WorkshopSubscription -SubscriptionId $SubscriptionId -TenantId $TenantId
    Write-WorkshopOk 'subscription selected and tenant confirmed'

    Write-WorkshopStep 'Looking up each fork on GitHub (one public API read per student)'
    $found = 0
    foreach ($s in $roster) {
        $repo = Get-WorkshopGitHubRepository -Owner $s.GitHubUsername -Name $s.Repository
        if ($repo) {
            $found++
            # Mask the canonical spelling too: Actions masks are case-sensitive.
            Register-WorkshopSensitiveValue $repo.owner.login $s.Label
            Register-WorkshopSensitiveValue $repo.full_name "$($s.Label) fork"
        }
        $subject = Get-WorkshopSubject -Format $SubjectFormat -Owner $s.GitHubUsername -Repository $s.Repository -Context $Context -GitHubRepository $repo
        $s | Add-Member -NotePropertyName GitHubRepo -NotePropertyValue $repo
        $s | Add-Member -NotePropertyName Subject -NotePropertyValue $(if ($subject) { $subject.Subject } else { $null })
        $s | Add-Member -NotePropertyName SubjectFormat -NotePropertyValue $(if ($subject) { $subject.Format } else { $SubjectFormat })
    }
    Write-WorkshopOk "$found of $($roster.Count) forks found"
    $classic = @($roster | Where-Object { $_.Subject -and $_.SubjectFormat -eq 'Classic' }).Count
    if ($classic -gt 0) {
        Write-WorkshopWarn "$classic fork(s) predate 15 Jul 2026 and get the name-only subject. If a login fails with AADSTS700213, that fork opted into immutable subjects: re-run with -SubjectFormat Immutable."
    }

    Write-WorkshopStep 'Event identity resource group'
    $idRgTags = [ordered]@{
        $Workshop.ManagedByTag = $Workshop.ManagedByValue
        $Workshop.EventTag     = $EventName
        $Workshop.RoleTag      = 'identities'
        $Workshop.DateTag      = $Today
    }
    $idRgState = Confirm-ResourceGroup -Name $IdentityResourceGroup -Label 'identity resource group' -Tags $idRgTags -Role 'identities'

    $script:UserLookupDenied = $false
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($s in $roster) {
        Write-WorkshopStep (Format-WorkshopLabel $s.Label $s.GitHubUsername)
        $status = 'ready'
        $identity = $null
        $portal = 'n/a'
        $scope = "/subscriptions/$($ctx.SubscriptionId)/resourceGroups/$($s.ResourceGroup)"
        try {
            $rgTags = [ordered]@{
                $Workshop.ManagedByTag  = $Workshop.ManagedByValue
                $Workshop.EventTag      = $EventName
                $Workshop.RoleTag       = 'student'
                $Workshop.OwnerTag      = $s.GitHubUsername
                $Workshop.DateTag       = $Today
                $Workshop.InstructorTag = $InstructorName
            }
            $rgState = Confirm-ResourceGroup -Name $s.ResourceGroup -Label "$($s.Label) resource group" -Tags $rgTags -Role 'student'

            if ($idRgState -eq 'planned') {
                Write-WorkshopPlan "would create $($s.Label) identity, its federated credential and its Contributor role"
                $status = 'planned'
            } else {
                $identity = Confirm-StudentIdentity $s
                if ($identity) {
                    $credState = Confirm-StudentCredential $s
                    if ($rgState -eq 'planned') {
                        Write-WorkshopPlan "would assign $($s.Label) identity Contributor on their resource group"
                        $status = 'planned'
                    } else {
                        $roleState = Confirm-RoleAssignment -PrincipalId $identity.principalId -PrincipalType 'ServicePrincipal' `
                            -RoleId $Workshop.ContributorRoleId -Scope $scope -Label "$($s.Label) identity Contributor"
                        if ($roleState -eq 'planned' -or $credState -eq 'planned') { $status = 'planned' }
                    }
                    if ($credState -eq 'waiting-for-fork') { $status = 'waiting-for-fork' }
                } else {
                    Write-WorkshopPlan "would add $($s.Label) federated credential and Contributor role"
                    $status = 'planned'
                }
            }
            $portal = Confirm-PortalReader -Student $s -Scope $scope -GroupExists ($rgState -ne 'planned')
        } catch {
            $status = 'failed'
            Write-WorkshopError "$($s.Label): $($_.Exception.Message)"
        }

        $owner = if ($s.GitHubRepo) { $s.GitHubRepo.owner.login } else { $s.GitHubUsername }
        $forkName = if ($s.GitHubRepo) { $s.GitHubRepo.name } else { $s.Repository }
        $results.Add([pscustomobject][ordered]@{
            Label                     = $s.Label
            GitHubUsername            = $owner
            Repository                = "$owner/$forkName"
            Status                    = $status
            AZURE_CLIENT_ID           = if ($identity) { $identity.clientId } else { '' }
            AZURE_TENANT_ID           = $ctx.TenantId
            AZURE_SUBSCRIPTION_ID     = $ctx.SubscriptionId
            AZURE_PREFIX              = $s.AzurePrefix
            AZURE_LOCATION            = $Location
            AZURE_RESOURCE_GROUP      = $s.ResourceGroup
            ResourceGroupSecretNeeded = if ($ResourceGroupPrefix) { 'yes' } else { 'no' }
            FederatedSubject          = if ($s.Subject) { $s.Subject } else { '' }
            PortalReader              = $portal
            # For the instructor only: grant chapter-specific extra roles to it.
            PrincipalId               = if ($identity) { $identity.principalId } else { '' }
        })
    }

    # ----------------------------------------------------------------------- #
    #  Output                                                                  #
    # ----------------------------------------------------------------------- #
    if ($WhatIfPreference) {
        Write-WorkshopStep 'Plan mode: the client ID file was not written'
    } else {
        Write-WorkshopStep 'Writing the per-student client IDs'
        $dir = Split-Path -Parent $OutputPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        # Label is the "student 03" the console used, so a warning maps to its row.
        $results | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding utf8
        Write-WorkshopOk "wrote $($results.Count) rows to $OutputPath"
        # Best effort: warn if the file would be picked up by git.
        if (Get-Command git -ErrorAction SilentlyContinue) {
            $inRepo = Invoke-WorkshopNative -FilePath 'git' -ArgumentList @('-C', (Split-Path -Parent (Resolve-Path -LiteralPath $OutputPath)), 'rev-parse', '--is-inside-work-tree')
            if ($inRepo.ExitCode -eq 0 -and $inRepo.StdOut.Trim() -eq 'true') {
                $ignored = Invoke-WorkshopNative -FilePath 'git' -ArgumentList @('-C', (Split-Path -Parent (Resolve-Path -LiteralPath $OutputPath)), 'check-ignore', '-q', (Resolve-Path -LiteralPath $OutputPath).Path)
                if ($ignored.ExitCode -ne 0) { Write-WorkshopWarn "$OutputPath is inside a git work tree and is NOT ignored. It holds student data: move it or add it to .gitignore before committing anything." }
            }
        }
        Write-Host '    Share each row privately with its student (never in a public issue, chat or repo).' -ForegroundColor DarkGray
    }

    if ($SetForkVariables) {
        Write-WorkshopStep 'Setting variables on the forks'
        foreach ($r in ($results | Where-Object { $_.AZURE_CLIENT_ID -and $_.Status -eq 'ready' })) {
            [void] (Set-ForkVariable $r)
        }
    }

    # ----------------------------------------------------------------------- #
    #  Summary (counts only)                                                   #
    # ----------------------------------------------------------------------- #
    $byStatus = $results | Group-Object Status | Sort-Object Name
    Write-Host "`n$('=' * 72)" -ForegroundColor Green
    Write-Host ' WORKSHOP ENVIRONMENT SUMMARY' -ForegroundColor Green
    Write-Host "$('=' * 72)" -ForegroundColor Green
    foreach ($g in $byStatus) { Write-Host ('  {0,-18} {1}' -f $g.Name, $g.Count) }
    if ($script:UserLookupDenied) {
        Write-WorkshopWarn 'Portal Reader was skipped: this identity cannot look up Entra users. Grant it from a local run (your own az login), or skip portal access.'
    }
    $summary = @('## Workshop environment', '', "Event: ``$EventName`` - mode: $(if ($WhatIfPreference) { 'plan' } else { 'create' })", '', '| Status | Students |', '|---|---|')
    $summary += $byStatus | ForEach-Object { "| $($_.Name) | $($_.Count) |" }
    Add-WorkshopSummary $summary

    if ($WhatIfPreference) { Write-Host "`n  *** PLAN MODE -- no changes were made ***`n" -ForegroundColor Yellow }
    $waiting = @($results | Where-Object Status -eq 'waiting-for-fork').Count
    if ($waiting -gt 0) { Write-WorkshopWarn "$waiting student(s) have no fork yet. Re-run once they fork; nothing else needs repeating." }
    if (@($results | Where-Object Status -eq 'failed').Count -gt 0) { exit 1 }
} catch {
    Write-WorkshopError $_.Exception.Message
    exit 1
}
