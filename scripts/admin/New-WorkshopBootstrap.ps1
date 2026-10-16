#Requires -Version 7.2
<#
.SYNOPSIS
    One-time, local setup of the automation identity that builds and tears
    down workshop environments from GitHub Actions.

.DESCRIPTION
    Run once per subscription, from your own machine, signed in as an Owner of
    the subscription. It creates:

      1. Resource group rg-workshop-automation (tagged WorkshopRole=automation;
         the teardown script never touches it).
      2. User-assigned managed identity id-workshop-automation in that group,
         with ONE federated credential: your private admin repository's
         workshop-admin environment. Explicit subject, no wildcard.
      3. Custom role "Workshop Environment Operator (<subscription>)": create,
         read and delete resource groups and user-assigned managed identities
         (with their federated credentials). Nothing else.
      4. Role assignments at subscription scope for the identity:
           - that custom role;
           - Role Based Access Control Administrator, with a condition: it may
             only add or remove Contributor, only for service principals
             (managed identities are service principals), and never for
             itself. -AllowStudentPortalAccess also allows Reader for users.
      5. A ReadOnly lock on rg-workshop-automation, so the identity cannot add
         a federated credential to itself. Re-running this script lifts and
         restores the lock around its own changes.

    No Microsoft Graph permission and no admin consent are needed: student
    deploy identities are managed identities, which are Azure resources, not
    app registrations. Nothing here needs an Entra administrator role.

    It then prints the variables and secret to set on the admin repository.
    It never sets them itself.

    Idempotent: every step checks first. Preview with -WhatIf.

.PARAMETER TenantId
    Entra tenant ID. The run stops if the subscription is not in it.

.PARAMETER SubscriptionId
    The workshop subscription. A subscription used only for workshops is
    strongly recommended (see "Residual risk" in the setup guide).

.PARAMETER AdminRepository
    Your PRIVATE copy of this repository, as owner/name. Its
    workshop-environment workflow is the only thing the identity trusts.

.PARAMETER EnvironmentName
    GitHub environment in the federated subject. Default: workshop-admin
    (the workflow uses that name).

.PARAMETER Location
    Region for the automation group and identity. Default: eastus2.

.PARAMETER SubjectFormat
    Auto (default), Immutable or Classic. See New-WorkshopEnvironment.ps1.
    A private copy created today presents the immutable subject.

.PARAMETER AllowStudentPortalAccess
    Also let the identity grant Reader to users (the roster's EntraUpn column).
    Note: the workflow still cannot look users up without a Graph permission;
    the portal Reader is normally granted from a local run.

.PARAMETER SkipLock
    Do not place the ReadOnly lock on the automation group.

.EXAMPLE
    ./scripts/admin/New-WorkshopBootstrap.ps1 -TenantId <tenant-id> `
        -SubscriptionId <subscription-id> -AdminRepository MyOrg/workshop-admin -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)] [string] $TenantId,
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $AdminRepository,
    [string] $EnvironmentName = 'workshop-admin',
    [string] $Location = 'eastus2',
    [string] $AutomationResourceGroup = 'rg-workshop-automation',
    [string] $AutomationIdentityName = 'id-workshop-automation',
    [string] $OperatorRoleName,
    [ValidateSet('Auto', 'Immutable', 'Classic')] [string] $SubjectFormat = 'Auto',
    [switch] $AllowStudentPortalAccess,
    [switch] $SkipLock
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'WorkshopEnvironment.psm1') -Force
Initialize-WorkshopOutput
$Cmdlet = $PSCmdlet
$LockName = 'workshop-automation-readonly'
$script:LockLifted = $false
$Scope = "/subscriptions/$SubscriptionId"

function Remove-AutomationLock {
    # Called before any write inside the locked group.
    if (-not $script:LockPresent) { return $true }
    if (-not $Cmdlet.ShouldProcess($AutomationResourceGroup, "Lift ReadOnly lock '$LockName' for this run")) { return $false }
    $r = Invoke-WorkshopAz @('lock', 'delete', '--name', $LockName, '--resource-group', $AutomationResourceGroup)
    if ($r.ExitCode -ne 0) { throw "Could not lift the lock: $($r.StdErr)" }
    $script:LockPresent = $false
    $script:LockLifted = $true
    Write-WorkshopOk "lifted lock $LockName (restored at the end)"
    $true
}

try {
    # ------------------------------------------------------------------- #
    Write-WorkshopStep 'Checking inputs'
    Assert-WorkshopValue $TenantId 'Guid' '-TenantId'
    Assert-WorkshopValue $SubscriptionId 'Guid' '-SubscriptionId'
    Assert-WorkshopValue $Location 'Location' '-Location'
    if ($AdminRepository -notmatch '^([A-Za-z0-9-]+)/([A-Za-z0-9._-]+)$') { throw '-AdminRepository must be owner/name.' }
    $adminOwner = $Matches[1]; $adminName = $Matches[2]
    if ($EnvironmentName -notmatch '^[A-Za-z0-9._-]{1,255}$') { throw '-EnvironmentName is not a valid environment name.' }
    if (-not $OperatorRoleName) { $OperatorRoleName = "Workshop Environment Operator ($($SubscriptionId.Substring(0, 8)))" }
    if (Test-WorkshopWorkflowRun) { throw 'Run the bootstrap locally, signed in as a subscription Owner, not from a workflow.' }
    if ($WhatIfPreference) { Write-Host "`n  *** PLAN MODE -- no changes will be made ***" -ForegroundColor Yellow }

    # ------------------------------------------------------------------- #
    Write-WorkshopStep 'Checking Azure sign-in'
    $ctx = Connect-WorkshopSubscription -SubscriptionId $SubscriptionId -TenantId $TenantId
    Write-WorkshopOk "subscription $SubscriptionId in tenant $TenantId"
    if ($ctx.UserType -ne 'user') { Write-WorkshopWarn 'You are signed in as a service principal. The bootstrap is meant for a person who owns the subscription.' }

    # ------------------------------------------------------------------- #
    Write-WorkshopStep "Federated subject for $AdminRepository (environment: $EnvironmentName)"
    $repo = Get-WorkshopGitHubRepository -Owner $adminOwner -Name $adminName
    if (-not $repo -and $SubjectFormat -ne 'Classic') {
        throw "Repository $AdminRepository not found. Create your private copy first, and sign in with gh auth login so the script can read it (it is private)."
    }
    if ($repo -and -not $repo.private) {
        Write-WorkshopWarn "$AdminRepository is PUBLIC. Its Actions logs and artifacts are public: use a private copy for the workshop-environment workflow."
    }
    $subject = Get-WorkshopSubject -Format $SubjectFormat -Owner $adminOwner -Repository $adminName -Context "environment:$EnvironmentName" -GitHubRepository $repo
    Write-WorkshopOk "subject ($($subject.Format)): $($subject.Subject)"

    # ------------------------------------------------------------------- #
    Write-WorkshopStep 'Resource provider Microsoft.ManagedIdentity'
    $state = (Invoke-WorkshopAz @('provider', 'show', '--namespace', 'Microsoft.ManagedIdentity', '--query', 'registrationState', '-o', 'tsv')).StdOut.Trim()
    if ($state -eq 'Registered') { Write-WorkshopSkip 'registered' }
    elseif ($Cmdlet.ShouldProcess('Microsoft.ManagedIdentity', 'Register resource provider')) {
        $r = Invoke-WorkshopAz @('provider', 'register', '--namespace', 'Microsoft.ManagedIdentity', '--wait')
        if ($r.ExitCode -ne 0) { throw "Could not register Microsoft.ManagedIdentity: $($r.StdErr)" }
        Write-WorkshopOk 'registered'
    } else { Write-WorkshopPlan 'would register Microsoft.ManagedIdentity' }

    # ------------------------------------------------------------------- #
    Write-WorkshopStep "Automation resource group $AutomationResourceGroup"
    $rgShow = Invoke-WorkshopAz @('group', 'show', '--name', $AutomationResourceGroup, '-o', 'json')
    $rgExists = $rgShow.ExitCode -eq 0
    if ($rgExists) {
        $rg = ConvertFrom-WorkshopJson $rgShow.StdOut
        if ((Get-WorkshopTag $rg.tags $Workshop.ManagedByTag) -ne $Workshop.ManagedByValue -or (Get-WorkshopTag $rg.tags $Workshop.RoleTag) -ne 'automation') {
            throw "$AutomationResourceGroup exists but was not created by this script. Pass -AutomationResourceGroup with a new name."
        }
        Write-WorkshopSkip 'exists'
    } elseif (-not (Test-WorkshopNotFound $rgShow)) {
        throw "Could not read the resource group: $($rgShow.StdErr)"
    } elseif ($Cmdlet.ShouldProcess($AutomationResourceGroup, 'Create resource group')) {
        $tags = [ordered]@{ $Workshop.ManagedByTag = $Workshop.ManagedByValue; $Workshop.RoleTag = 'automation' }
        $r = Invoke-WorkshopAz (@('group', 'create', '--name', $AutomationResourceGroup, '--location', $Location, '-o', 'none') + (ConvertTo-WorkshopTagArgument $tags))
        if ($r.ExitCode -ne 0) { throw "Could not create the resource group: $($r.StdErr)" }
        $rgExists = $true
        Write-WorkshopOk 'created'
    } else { Write-WorkshopPlan 'would create it' }

    $script:LockPresent = $false
    if ($rgExists) {
        $locks = @(ConvertFrom-WorkshopJson (Invoke-WorkshopAz @('lock', 'list', '--resource-group', $AutomationResourceGroup, '-o', 'json')).StdOut)
        $script:LockPresent = [bool] ($locks | Where-Object { $_.name -eq $LockName })
    }

    # ------------------------------------------------------------------- #
    Write-WorkshopStep "Automation identity $AutomationIdentityName"
    $identity = $null
    if ($rgExists) {
        $idShow = Invoke-WorkshopAz @('identity', 'show', '--name', $AutomationIdentityName, '--resource-group', $AutomationResourceGroup, '-o', 'json')
        if ($idShow.ExitCode -eq 0) { $identity = ConvertFrom-WorkshopJson $idShow.StdOut; Write-WorkshopSkip "exists (client ID $($identity.clientId))" }
        elseif (-not (Test-WorkshopNotFound $idShow)) { throw "Could not read the identity: $($idShow.StdErr)" }
    }
    if (-not $identity) {
        if ($rgExists -and (Remove-AutomationLock) -and $Cmdlet.ShouldProcess($AutomationIdentityName, 'Create user-assigned managed identity')) {
            $tags = [ordered]@{ $Workshop.ManagedByTag = $Workshop.ManagedByValue; $Workshop.RoleTag = 'automation' }
            $r = Invoke-WorkshopAz (@('identity', 'create', '--name', $AutomationIdentityName, '--resource-group', $AutomationResourceGroup,
                    '--location', $Location, '-o', 'json') + (ConvertTo-WorkshopTagArgument $tags))
            if ($r.ExitCode -ne 0) { throw "Could not create the identity: $($r.StdErr)" }
            $identity = ConvertFrom-WorkshopJson $r.StdOut
            Write-WorkshopOk "created (client ID $($identity.clientId))"
        } else { Write-WorkshopPlan 'would create it' }
    }

    # ------------------------------------------------------------------- #
    $credName = 'github-' + ($EnvironmentName -replace '[^A-Za-z0-9_-]', '-')
    Write-WorkshopStep "Federated credential $credName"
    if ($identity) {
        $creds = @(ConvertFrom-WorkshopJson (Invoke-WorkshopAz @('identity', 'federated-credential', 'list', '--identity-name', $AutomationIdentityName,
                    '--resource-group', $AutomationResourceGroup, '-o', 'json')).StdOut)
        $mine = $creds | Where-Object { $_.name -eq $credName } | Select-Object -First 1
        foreach ($other in ($creds | Where-Object { $_.name -ne $credName })) {
            Write-WorkshopWarn "unexpected federated credential '$($other.name)' (subject $($other.subject)). This identity should trust one subject only: delete it unless you added it on purpose."
        }
        if ($mine -and $mine.subject -ceq $subject.Subject -and $mine.issuer -eq $Workshop.Issuer) {
            Write-WorkshopSkip 'current'
        } else {
            $verb = if ($mine) { 'update' } else { 'create' }
            if ((Remove-AutomationLock) -and $Cmdlet.ShouldProcess($credName, "$verb federated credential")) {
                $r = Invoke-WorkshopAz @('identity', 'federated-credential', $verb, '--name', $credName, '--identity-name', $AutomationIdentityName,
                    '--resource-group', $AutomationResourceGroup, '--issuer', $Workshop.Issuer, '--subject', $subject.Subject,
                    '--audiences', $Workshop.Audience, '-o', 'none')
                if ($r.ExitCode -ne 0) { throw "Could not $verb the federated credential: $($r.StdErr)" }
                Write-WorkshopOk "$($verb)d"
            } else { Write-WorkshopPlan "would $verb it" }
        }
    } else { Write-WorkshopPlan 'would create it once the identity exists' }

    # ------------------------------------------------------------------- #
    Write-WorkshopStep "Custom role '$OperatorRoleName'"
    $actions = @(
        'Microsoft.Resources/subscriptions/resourceGroups/read'
        'Microsoft.Resources/subscriptions/resourceGroups/write'
        'Microsoft.Resources/subscriptions/resourceGroups/delete'
        'Microsoft.ManagedIdentity/userAssignedIdentities/read'
        'Microsoft.ManagedIdentity/userAssignedIdentities/write'
        'Microsoft.ManagedIdentity/userAssignedIdentities/delete'
        'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/read'
        'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/write'
        'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/delete'
    )
    $roleList = Invoke-WorkshopAz @('role', 'definition', 'list', '--custom-role-only', 'true', '--name', $OperatorRoleName, '--scope', $Scope, '-o', 'json')
    if ($roleList.ExitCode -ne 0) { throw "Could not list role definitions: $($roleList.StdErr)" }
    $role = @(ConvertFrom-WorkshopJson $roleList.StdOut) | Select-Object -First 1
    $definition = [ordered]@{
        Name             = $OperatorRoleName
        IsCustom         = $true
        Description      = 'Create, read and delete workshop resource groups and the user-assigned managed identities (and their federated credentials) that student forks deploy with. Used by scripts/admin/New-WorkshopEnvironment.ps1 and Remove-WorkshopEnvironment.ps1.'
        Actions          = $actions
        NotActions       = @()
        DataActions      = @()
        NotDataActions   = @()
        AssignableScopes = @($Scope)
    }
    $roleId = $null
    if ($role) {
        $roleId = $role.name
        $current = @($role.permissions | ForEach-Object { $_.actions }) | Sort-Object
        if ((($current -join ',') -eq (($actions | Sort-Object) -join ',')) -and (@($role.assignableScopes) -contains $Scope)) {
            Write-WorkshopSkip 'exists and is current'
        } elseif ($Cmdlet.ShouldProcess($OperatorRoleName, 'Update custom role definition')) {
            # az matches the existing custom role by its Name on update.
            $tmp = New-TemporaryFile
            try {
                $definition | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding utf8
                $r = Invoke-WorkshopAz @('role', 'definition', 'update', '--role-definition', "@$tmp", '-o', 'none')
                if ($r.ExitCode -ne 0) { throw "Could not update the role definition: $($r.StdErr)" }
            } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
            Write-WorkshopOk 'updated'
        } else { Write-WorkshopPlan 'would update it' }
    } elseif ($Cmdlet.ShouldProcess($OperatorRoleName, 'Create custom role definition')) {
        $tmp = New-TemporaryFile
        try {
            $definition | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding utf8
            $r = Invoke-WorkshopAz @('role', 'definition', 'create', '--role-definition', "@$tmp", '-o', 'json')
            if ($r.ExitCode -ne 0) {
                if ($r.StdErr -match 'RoleDefinitionWithSameNameExists') { throw "A custom role named '$OperatorRoleName' already exists for another scope. Pass -OperatorRoleName with a different name." }
                throw "Could not create the role definition: $($r.StdErr)"
            }
            $roleId = (ConvertFrom-WorkshopJson $r.StdOut).name
        } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        Write-WorkshopOk 'created'
    } else { Write-WorkshopPlan 'would create it' }

    # ------------------------------------------------------------------- #
    Write-WorkshopStep 'Role assignments at subscription scope'
    if ($identity) {
        $self = $identity.principalId
        $c = $Workshop.ContributorRoleId; $rd = $Workshop.ReaderRoleId
        $writeOk = "(@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$c} AND @Request[Microsoft.Authorization/roleAssignments:PrincipalType] ForAnyOfAnyValues:StringEqualsIgnoreCase {'ServicePrincipal'} AND @Request[Microsoft.Authorization/roleAssignments:PrincipalId] ForAnyOfAllValues:GuidNotEquals {$self})"
        $deleteOk = "(@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$c} AND @Resource[Microsoft.Authorization/roleAssignments:PrincipalType] ForAnyOfAnyValues:StringEqualsIgnoreCase {'ServicePrincipal'})"
        if ($AllowStudentPortalAccess) {
            $writeOk = "($writeOk OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$rd} AND @Request[Microsoft.Authorization/roleAssignments:PrincipalType] ForAnyOfAnyValues:StringEqualsIgnoreCase {'User'}))"
            $deleteOk = "($deleteOk OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$rd} AND @Resource[Microsoft.Authorization/roleAssignments:PrincipalType] ForAnyOfAnyValues:StringEqualsIgnoreCase {'User'}))"
        }
        $condition = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR $writeOk) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR $deleteOk)"

        $wanted = @(
            @{ Label = $OperatorRoleName; RoleId = $roleId; Condition = $null }
            @{ Label = 'Role Based Access Control Administrator (conditioned)'; RoleId = $Workshop.RbacAdminRoleId; Condition = $condition }
        )
        foreach ($w in $wanted) {
            if (-not $w.RoleId) { Write-WorkshopPlan "would assign $($w.Label) once the role exists"; continue }
            $list = Invoke-WorkshopAz @('role', 'assignment', 'list', '--scope', $Scope, '--role', $w.RoleId,
                '--fill-principal-name', 'false', '--fill-role-definition-name', 'false', '-o', 'json')
            if ($list.ExitCode -ne 0) { throw "Could not list role assignments: $($list.StdErr)" }
            $existing = @(ConvertFrom-WorkshopJson $list.StdOut) | Where-Object { $_.principalId -eq $self -and $_.scope -ieq $Scope } | Select-Object -First 1
            $norm = { param($s) if ($s) { ($s -replace '\s+', ' ').Trim() } else { '' } }
            if ($existing -and (& $norm $existing.condition) -eq (& $norm $w.Condition)) { Write-WorkshopSkip "$($w.Label): current"; continue }
            if ($existing) {
                # A changed condition is replaced, not edited in place.
                if (-not $Cmdlet.ShouldProcess($w.Label, 'Replace role assignment (condition changed)')) { Write-WorkshopPlan "would replace $($w.Label)"; continue }
                $d = Invoke-WorkshopAz @('role', 'assignment', 'delete', '--ids', $existing.id)
                if ($d.ExitCode -ne 0) { throw "Could not remove the old assignment: $($d.StdErr)" }
            } elseif (-not $Cmdlet.ShouldProcess($w.Label, 'Assign at subscription scope')) { Write-WorkshopPlan "would assign $($w.Label)"; continue }
            $assignArgs = @('role', 'assignment', 'create', '--assignee-object-id', $self, '--assignee-principal-type', 'ServicePrincipal',
                '--role', $w.RoleId, '--scope', $Scope, '--description', 'Workshop environment automation', '-o', 'none')
            if ($w.Condition) { $assignArgs += @('--condition', $w.Condition, '--condition-version', '2.0') }
            $r = Invoke-WorkshopWithRetry -RetryPattern 'PrincipalNotFound|does not exist|RoleDefinitionDoesNotExist' -Action { Invoke-WorkshopAz $assignArgs }
            if ($r.ExitCode -ne 0) { throw "Could not assign $($w.Label): $($r.StdErr)" }
            Write-WorkshopOk "assigned $($w.Label)"
        }
    } else { Write-WorkshopPlan 'would assign the custom role and the conditioned RBAC Administrator role' }

    # ------------------------------------------------------------------- #
    Write-WorkshopStep "ReadOnly lock on $AutomationResourceGroup"
    if ($SkipLock) { Write-WorkshopWarn '-SkipLock: the identity can add federated credentials to itself.' }
    elseif ($script:LockPresent) { Write-WorkshopSkip 'present' }
    elseif ($rgExists -and $Cmdlet.ShouldProcess($AutomationResourceGroup, "Create ReadOnly lock '$LockName'")) {
        $r = Invoke-WorkshopAz @('lock', 'create', '--name', $LockName, '--lock-type', 'ReadOnly', '--resource-group', $AutomationResourceGroup,
            '--notes', 'Keeps the workshop automation identity from changing its own federated credentials. Re-run New-WorkshopBootstrap.ps1 to change them.', '-o', 'none')
        if ($r.ExitCode -ne 0) { throw "Could not create the lock: $($r.StdErr)" }
        Write-WorkshopOk 'locked'
    } else { Write-WorkshopPlan 'would lock it' }

    # ------------------------------------------------------------------- #
    $clientId = if ($identity) { $identity.clientId } else { '<client-id-after-create>' }
    $repoArg = "--repo $AdminRepository --env $EnvironmentName"
    Write-Host "`n$('=' * 72)" -ForegroundColor Green
    Write-Host ' NEXT: CONFIGURE THE ADMIN REPOSITORY' -ForegroundColor Green
    Write-Host "$('=' * 72)" -ForegroundColor Green
    Write-Host @"

  1. In $AdminRepository create the environment '$EnvironmentName'
     (Settings > Environments > New environment). Restrict deployment
     branches to main, and add yourself as a required reviewer if your plan
     allows it on a private repository (GitHub Enterprise).

  2. Set these (environment variables shown; repository variables work too):

     gh variable set AZURE_CLIENT_ID       $repoArg --body $clientId
     gh variable set AZURE_TENANT_ID       $repoArg --body $TenantId
     gh variable set AZURE_SUBSCRIPTION_ID $repoArg --body $SubscriptionId
     gh variable set WORKSHOP_EVENT_NAME   $repoArg --body <MyEvent>
     gh variable set WORKSHOP_LOCATION     $repoArg --body $Location

  3. Store the roster as a secret (piped, so it never sits on a command line):

     Get-Content -Raw scripts/admin/workshop-roster.csv | gh secret set WORKSHOP_ROSTER_CSV $repoArg

  4. Run the 'Workshop environment' workflow with action = plan.

  The identity holds no Microsoft Graph permission. At subscription scope it
  holds '$OperatorRoleName' and Role Based Access Control Administrator
  limited to Contributor for service principals other than itself.

"@
    if ($WhatIfPreference) { Write-Host '  *** PLAN MODE -- no changes were made ***' -ForegroundColor Yellow }
} catch {
    Write-WorkshopError $_.Exception.Message
    if ($script:LockLifted -and -not $script:LockPresent) {
        Write-WorkshopWarn "This run lifted the ReadOnly lock on $AutomationResourceGroup and stopped before restoring it. Re-run the script to finish and restore it."
    }
    exit 1
}
