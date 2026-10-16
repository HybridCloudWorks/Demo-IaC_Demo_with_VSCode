#Requires -Version 7.2
<#
.SYNOPSIS
    Shared helpers for the workshop environment scripts in scripts/admin/.

.DESCRIPTION
    Imported by New-WorkshopBootstrap.ps1, New-WorkshopEnvironment.ps1 and
    Remove-WorkshopEnvironment.ps1. Nothing in this module changes Azure or
    GitHub by itself: it reads the roster, validates names, builds OIDC
    subjects, wraps az/gh calls, and keeps student data out of the console.

    Privacy contract. The roster holds personal data (GitHub usernames and,
    optionally, Entra UPNs), and this repository, its Actions logs and its
    artifacts are public. So:
      - every message goes through Write-Workshop*, which replaces each
        registered value with its row label ("student 03");
      - under GitHub Actions each value is also registered with ::add-mask::,
        so anything az or gh echoes back is masked by the runner as well;
      - -ShowNames (local runs only) turns the redaction off for the
        instructor's own console. It is ignored under GitHub Actions.
#>

Set-StrictMode -Version 3.0

# --------------------------------------------------------------------------- #
#  Constants                                                                   #
# --------------------------------------------------------------------------- #
$Workshop = [pscustomobject]@{
    # Tags that mark everything this tooling creates. Teardown selects on
    # ManagedBy + Event and nothing else, so never reuse these on other RGs.
    ManagedByTag           = 'ManagedBy'
    ManagedByValue         = 'workshop-environment'
    EventTag               = 'Event'
    RoleTag                = 'WorkshopRole'
    OwnerTag               = 'Owner'
    DateTag                = 'Date'
    InstructorTag          = 'Instructor'

    Issuer                 = 'https://token.actions.githubusercontent.com'
    Audience               = 'api://AzureADTokenExchange'

    # Built-in role definition IDs (identical in every tenant).
    ContributorRoleId      = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
    ReaderRoleId           = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
    RbacAdminRoleId        = 'f58310d9-a9f6-439a-9e8d-f62e7b41a168'

    # GitHub: repositories created after this date present the immutable,
    # ID-enriched OIDC subject (repo:owner@id/repo@id:...). Older ones keep the
    # name-only subject unless they opted in.
    # https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/
    ImmutableSubjectCutoff = [datetimeoffset]'2026-07-15T00:00:00Z'

    DefaultRepositoryName  = 'Demo-IaC_Demo_with_VSCode'
}

# --------------------------------------------------------------------------- #
#  Output and redaction                                                        #
# --------------------------------------------------------------------------- #
$script:State = @{
    InActions   = ($env:GITHUB_ACTIONS -eq 'true')
    ShowNames   = $false
    Redactions  = [System.Collections.Generic.List[object]]::new()
    GitHubMode  = $null
}

function Initialize-WorkshopOutput {
    [CmdletBinding()]
    param([switch] $ShowNames)
    $script:State.Redactions.Clear()
    $script:State.ShowNames = $ShowNames.IsPresent -and -not $script:State.InActions
    if ($ShowNames.IsPresent -and $script:State.InActions) {
        Write-WorkshopWarn '-ShowNames is ignored under GitHub Actions: roster values never go to a workflow log.'
    }
}

function Test-WorkshopWorkflowRun { $script:State.InActions }

function Register-WorkshopSensitiveValue {
    <# Redacts $Value to <$Label> in every later message, and masks it in Actions logs. #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string] $Value, [Parameter(Mandatory)][string] $Label)
    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    # A mask covers one line; a value with a line break (only possible in a
    # malformed roster) is masked line by line so no fragment escapes.
    foreach ($part in ($Value -split '\r?\n' | Where-Object { $_.Trim() })) {
        if ($script:State.InActions) { Write-Host "::add-mask::$part" }
        $script:State.Redactions.Add([pscustomobject]@{ Value = $part; Label = $Label })
    }
}

function Protect-WorkshopText {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string] $Text)
    if ([string]::IsNullOrEmpty($Text) -or $script:State.ShowNames) { return $Text }
    # Longest first, so "rg-octocat" is replaced before "octocat" can split it.
    foreach ($r in ($script:State.Redactions | Sort-Object { $_.Value.Length } -Descending)) {
        $pattern = '(?<![A-Za-z0-9])' + [regex]::Escape($r.Value) + '(?![A-Za-z0-9])'
        $Text = [regex]::Replace($Text, $pattern, "<$($r.Label)>", 'IgnoreCase')
    }
    $Text
}

function Format-WorkshopLabel {
    <# "student 03", or "student 03 (octocat)" on a local -ShowNames run. #>
    param([Parameter(Mandatory)][string] $Label, [string] $Name)
    if ($script:State.ShowNames -and $Name) { return "$Label ($Name)" }
    $Label
}

function ConvertTo-WorkflowCommandValue([string] $Text) {
    # Workflow commands treat %, CR and LF specially.
    $Text -replace '%', '%25' -replace "`r", '%0D' -replace "`n", '%0A'
}

function Write-WorkshopStep([string] $Message) { Write-Host "`n==> $(Protect-WorkshopText $Message)" -ForegroundColor Cyan }
function Write-WorkshopOk([string] $Message)   { Write-Host "    [ok]   $(Protect-WorkshopText $Message)" -ForegroundColor Green }
function Write-WorkshopSkip([string] $Message) { Write-Host "    [skip] $(Protect-WorkshopText $Message)" -ForegroundColor DarkGray }
function Write-WorkshopPlan([string] $Message) { Write-Host "    [plan] $(Protect-WorkshopText $Message)" -ForegroundColor Yellow }

function Write-WorkshopWarn([string] $Message) {
    $m = Protect-WorkshopText $Message
    if ($script:State.InActions) { Write-Host "::warning::$(ConvertTo-WorkflowCommandValue $m)" }
    else { Write-Host "    [warn] $m" -ForegroundColor Yellow }
}

function Write-WorkshopError([string] $Message) {
    $m = Protect-WorkshopText $Message
    if ($script:State.InActions) { Write-Host "::error::$(ConvertTo-WorkflowCommandValue $m)" }
    else { Write-Host "`nERROR: $m" -ForegroundColor Red }
}

function Add-WorkshopSummary {
    <# Appends Markdown to the Actions job summary. Counts only, never roster values. #>
    param([string[]] $Lines)
    if ($script:State.InActions -and $env:GITHUB_STEP_SUMMARY) {
        Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value (Protect-WorkshopText ($Lines -join "`n")) -Encoding utf8
    }
}

# --------------------------------------------------------------------------- #
#  Native commands                                                             #
# --------------------------------------------------------------------------- #
function Invoke-WorkshopNative {
    <#
    Runs a native command and returns ExitCode, StdOut and StdErr. Never throws
    on a non-zero exit: callers decide, and only print StdErr through the
    redacting writers.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [string[]] $ArgumentList = @(),
        [AllowNull()][string] $InputText
    )
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $output = if ($PSBoundParameters.ContainsKey('InputText') -and $null -ne $InputText) {
        $InputText | & $FilePath @ArgumentList 2>&1
    } else {
        & $FilePath @ArgumentList 2>&1
    }
    $code = $LASTEXITCODE
    $out = [System.Collections.Generic.List[string]]::new()
    $err = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @($output)) {
        if ($line -is [System.Management.Automation.ErrorRecord]) { $err.Add($line.ToString()) }
        elseif ($null -ne $line) { $out.Add([string] $line) }
    }
    [pscustomobject]@{ ExitCode = $code; StdOut = ($out -join "`n"); StdErr = ($err -join "`n") }
}

function Invoke-WorkshopAz {
    <# az with --only-show-errors. Pass arguments as one array: Invoke-WorkshopAz @('group','show',...). #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string[]] $Arguments)
    Invoke-WorkshopNative -FilePath 'az' -ArgumentList ($Arguments + '--only-show-errors')
}

function ConvertFrom-WorkshopJson {
    param([AllowNull()][AllowEmptyString()][string] $Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return $null }
    $Json | ConvertFrom-Json -Depth 20
}

function Test-WorkshopNotFound {
    <# True when an az failure means "it does not exist" rather than a real error. #>
    param([Parameter(Mandatory)] $Result)
    $Result.ExitCode -ne 0 -and
        $Result.StdErr -match 'ResourceGroupNotFound|ResourceNotFound|\(NotFound\)|could not be found|was not found|does not exist'
}

function Invoke-WorkshopWithRetry {
    <#
    Retries an az/gh call while its error matches $RetryPattern: identities
    take a few seconds to replicate before a role assignment can name them,
    and a managed identity rejects concurrent credential writes with 409.
    #>
    param(
        [Parameter(Mandatory)][scriptblock] $Action,
        [Parameter(Mandatory)][string] $RetryPattern,
        [int] $Attempts = 8,
        [int] $DelaySeconds = 10
    )
    $result = $null
    for ($i = 1; $i -le $Attempts; $i++) {
        $result = & $Action
        if ($result.ExitCode -eq 0 -or $result.StdErr -notmatch $RetryPattern) { return $result }
        if ($i -lt $Attempts) { Start-Sleep -Seconds $DelaySeconds }
    }
    $result
}

function Get-WorkshopTag {
    <# Reads a tag from an az JSON object without tripping StrictMode on a missing key. #>
    param([AllowNull()] $Tags, [Parameter(Mandatory)][string] $Name)
    if ($null -eq $Tags) { return $null }
    $p = $Tags.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
    if ($p) { return [string] $p.Value }
    $null
}

function Test-WorkshopOwnedResource {
    <# True only when the tags say this tooling created it for this event and role. #>
    param([AllowNull()] $Tags, [Parameter(Mandatory)][string] $EventName, [Parameter(Mandatory)][string] $Role)
    (Get-WorkshopTag $Tags $Workshop.ManagedByTag) -eq $Workshop.ManagedByValue -and
        (Get-WorkshopTag $Tags $Workshop.EventTag) -ieq $EventName -and
        (Get-WorkshopTag $Tags $Workshop.RoleTag) -eq $Role
}

function ConvertTo-WorkshopTagArgument {
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Tags)
    $list = [System.Collections.Generic.List[string]]::new()
    $list.Add('--tags')
    foreach ($k in $Tags.Keys) {
        if (-not [string]::IsNullOrWhiteSpace([string] $Tags[$k])) { $list.Add("$k=$($Tags[$k])") }
    }
    $list.ToArray()
}

# --------------------------------------------------------------------------- #
#  Validation                                                                  #
# --------------------------------------------------------------------------- #
$script:Patterns = @{
    # GitHub: alphanumerics and single inner hyphens, 1-39 characters.
    GitHubLogin = '^[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}$'
    RepoName    = '^[A-Za-z0-9._-]{1,100}$'
    Upn         = '^[^\s@,;"<>]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$'
    # The curriculum templates cap the prefix at 12 characters (@maxLength(12)).
    Prefix      = '^[a-z][a-z0-9]{1,11}$'
    EventName   = '^[A-Za-z0-9][A-Za-z0-9-]{1,30}[A-Za-z0-9]$'
    Guid        = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
    Location    = '^[a-z][a-z0-9]{2,30}$'
    RgPrefix    = '^[A-Za-z0-9._()-]{0,40}$'
    Branch      = '^[A-Za-z0-9._/-]{1,100}$'
}

function Assert-WorkshopValue {
    param([AllowNull()][AllowEmptyString()][string] $Value, [Parameter(Mandatory)][string] $Kind, [Parameter(Mandatory)][string] $What)
    if ($null -eq $Value -or $Value -notmatch $script:Patterns[$Kind]) {
        throw "$What is not valid (expected $Kind format)."
    }
}

# --------------------------------------------------------------------------- #
#  Roster                                                                      #
# --------------------------------------------------------------------------- #
function Get-RowValue($Row, [string] $Column) {
    $p = $Row.PSObject.Properties | Where-Object { $_.Name -ieq $Column } | Select-Object -First 1
    if ($p -and $null -ne $p.Value) { return ([string] $p.Value).Trim() }
    ''
}

function Import-WorkshopRoster {
    <#
    Reads the roster from a CSV file, or from an environment variable holding
    the CSV text (the WORKSHOP_ROSTER_CSV secret in the workflow). Columns:

        GitHubUsername  required  the student's GitHub login
        EntraUpn        optional  gets Reader on the student's group (portal, Bastion)
        AzurePrefix     optional  resource-name prefix; derived from the login when empty
        Repository      optional  the fork's name; default Demo-IaC_Demo_with_VSCode

    Every value is registered for redaction before anything can print it.
    Validation errors name row numbers, never values.
    #>
    [CmdletBinding()]
    param(
        [string] $Path,
        [string] $EnvironmentVariable,
        [string] $DefaultRepository = $Workshop.DefaultRepositoryName
    )

    if ($EnvironmentVariable) {
        $raw = [Environment]::GetEnvironmentVariable($EnvironmentVariable)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            throw "The $EnvironmentVariable environment variable is empty. Store the roster CSV in the WORKSHOP_ROSTER_CSV secret (see docs/wiki/Instructor-Environment-Setup.md)."
        }
        $lines = @($raw.TrimStart([char] 0xFEFF) -split "\r?\n" | Where-Object { $_.Trim() })
        $rows = @($lines | ConvertFrom-Csv)
    } else {
        if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "Roster not found: $Path`n  Copy scripts/admin/workshop-roster.csv.example to scripts/admin/workshop-roster.csv (gitignored) and fill it in, or pass -RosterPath."
        }
        $rows = @(Import-Csv -LiteralPath $Path)
    }

    if ($rows.Count -eq 0) { throw 'The roster has a header but no student rows.' }
    if (-not ($rows[0].PSObject.Properties.Name -contains 'GitHubUsername')) {
        throw "The roster has no 'GitHubUsername' column. Expected header: GitHubUsername,EntraUpn,AzurePrefix,Repository"
    }

    $students = [System.Collections.Generic.List[object]]::new()
    $problems = [System.Collections.Generic.List[string]]::new()
    $n = 0
    foreach ($row in $rows) {
        $n++
        $label  = 'student {0:d2}' -f $n
        $login  = Get-RowValue $row 'GitHubUsername'
        $upn    = Get-RowValue $row 'EntraUpn'
        $prefix = (Get-RowValue $row 'AzurePrefix').ToLowerInvariant()
        $repo   = Get-RowValue $row 'Repository'
        if (-not $repo) { $repo = $DefaultRepository }

        if (-not $login -and -not $upn -and -not $prefix) { continue }   # blank line
        Register-WorkshopSensitiveValue $login $label
        Register-WorkshopSensitiveValue $upn "$label UPN"

        if ($login -notmatch $script:Patterns.GitHubLogin) { $problems.Add("Row ${n}: GitHubUsername is missing or is not a valid GitHub login.") }
        if ($upn -and $upn -notmatch $script:Patterns.Upn) { $problems.Add("Row ${n}: EntraUpn is not a valid UPN.") }
        if ($prefix -and $prefix -notmatch $script:Patterns.Prefix) { $problems.Add("Row ${n}: AzurePrefix must be 2-12 lowercase letters and digits, starting with a letter.") }
        if ($repo -notmatch $script:Patterns.RepoName) { $problems.Add("Row ${n}: Repository is not a valid repository name.") }

        $students.Add([pscustomobject]@{
            Row            = $n
            Label          = $label
            GitHubUsername = $login
            EntraUpn       = $upn
            Repository     = $repo
            AzurePrefix    = $prefix
        })
    }

    if ($students.Count -eq 0) { throw 'The roster has no student rows.' }

    foreach ($dup in ($students | Group-Object { $_.GitHubUsername.ToLowerInvariant() } | Where-Object Count -gt 1)) {
        $problems.Add("Rows $(($dup.Group.Row) -join ', '): the same GitHubUsername appears more than once.")
    }
    foreach ($dup in ($students | Where-Object AzurePrefix | Group-Object AzurePrefix | Where-Object Count -gt 1)) {
        $problems.Add("Rows $(($dup.Group.Row) -join ', '): the same AzurePrefix appears more than once.")
    }
    if ($problems.Count -gt 0) { throw ("The roster has problems:`n  " + ($problems -join "`n  ")) }

    Resolve-WorkshopPrefix -Students $students
    foreach ($s in $students) { Register-WorkshopSensitiveValue $s.AzurePrefix "$($s.Label) prefix" }
    $students.ToArray()
}

function Resolve-WorkshopPrefix {
    <#
    Fills in AzurePrefix where the roster left it empty: the login, lowercased,
    letters and digits only, at most 12 characters. Collisions get a two-digit
    suffix. Unique prefixes matter: the templates derive globally unique names
    (SQL, Key Vault) from uniqueString(subscription().id, prefix), so two
    students sharing a prefix in one subscription would collide.
    #>
    param([Parameter(Mandatory)][object[]] $Students)
    $taken = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($s in ($Students | Where-Object AzurePrefix)) { [void] $taken.Add($s.AzurePrefix) }
    foreach ($s in ($Students | Where-Object { -not $_.AzurePrefix })) {
        $base = ($s.GitHubUsername.ToLowerInvariant() -replace '[^a-z0-9]', '')
        if ($base -notmatch '^[a-z]') { $base = "s$base" }
        $candidate = $base.Substring(0, [Math]::Min(12, $base.Length))
        $i = 1
        while ($candidate.Length -lt 2 -or -not $taken.Add($candidate)) {
            $candidate = $base.Substring(0, [Math]::Min(10, $base.Length)) + ('{0:d2}' -f $i)
            $i++
        }
        $s.AzurePrefix = $candidate
    }
}

# --------------------------------------------------------------------------- #
#  GitHub                                                                      #
# --------------------------------------------------------------------------- #
function Initialize-WorkshopGitHub {
    if ($script:State.GitHubMode) { return }
    $hasGh = [bool] (Get-Command gh -ErrorAction SilentlyContinue)
    if ($hasGh -and ($env:GH_TOKEN -or $env:GITHUB_TOKEN -or (Invoke-WorkshopNative -FilePath 'gh' -ArgumentList @('auth', 'status')).ExitCode -eq 0)) {
        $script:State.GitHubMode = 'gh'
    } else {
        # Unauthenticated REST: 60 requests an hour, one per student. Fine for a
        # small class; sign in with gh auth login for anything larger.
        $script:State.GitHubMode = 'rest'
    }
}

function Get-WorkshopGitHubRepository {
    <#
    One public API read per repository: GET /repos/{owner}/{repo}. Returns the
    repository object (id, name, created_at, owner.login, owner.id) or $null
    when it does not exist. Throws on rate limiting or any other failure.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Owner, [Parameter(Mandatory)][string] $Name)
    Initialize-WorkshopGitHub
    if ($script:State.GitHubMode -eq 'gh') {
        $r = Invoke-WorkshopNative -FilePath 'gh' -ArgumentList @('api', "repos/$Owner/$Name")
        if ($r.ExitCode -eq 0) { return (ConvertFrom-WorkshopJson $r.StdOut) }
        if ($r.StdErr -match 'HTTP 404|Not Found') { return $null }
        if ($r.StdErr -match 'rate limit|HTTP 403|HTTP 429') {
            throw 'GitHub API rate limit reached. Wait for the limit to reset (gh api rate_limit) and re-run.'
        }
        throw "GitHub API read failed: $($r.StdErr)"
    }
    $headers = @{ 'Accept' = 'application/vnd.github+json'; 'User-Agent' = 'workshop-environment-script'; 'X-GitHub-Api-Version' = '2022-11-28' }
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
    try {
        Invoke-RestMethod -Uri "https://api.github.com/repos/$Owner/$Name" -Headers $headers -ErrorAction Stop
    } catch {
        $status = $null
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) { $status = [int] $_.Exception.Response.StatusCode }
        if ($status -eq 404) { return $null }
        if ($status -in 403, 429) { throw 'GitHub API rate limit reached (unauthenticated: 60 requests an hour). Run gh auth login, or set GITHUB_TOKEN, and re-run.' }
        throw "GitHub API read failed: $($_.Exception.Message)"
    }
}

function Get-WorkshopSubject {
    <#
    Builds the exact OIDC subject a repository presents, for one context
    ('ref:refs/heads/main' or 'environment:workshop-admin').

      Immutable  repo:<owner>@<owner-id>/<repo>@<repo-id>:<context>
      Classic    repo:<owner>/<repo>:<context>
      Auto       Immutable for repositories created after 15 Jul 2026 (every
                 fork made for a new event), Classic for older ones

    Returns $null when the format needs the repository and it does not exist
    yet. Never a wildcard or a pattern.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('Auto', 'Immutable', 'Classic')][string] $Format,
        [Parameter(Mandatory)][string] $Owner,
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $Context,
        [AllowNull()] $GitHubRepository
    )
    $effective = $Format
    if ($Format -eq 'Auto') {
        if (-not $GitHubRepository) { return $null }
        $created = $GitHubRepository.created_at
        $createdAt = if ($created -is [datetime]) { [datetimeoffset] $created.ToUniversalTime() } else { [datetimeoffset]::Parse([string] $created) }
        $effective = if ($createdAt -ge $Workshop.ImmutableSubjectCutoff) { 'Immutable' } else { 'Classic' }
    }
    if ($effective -eq 'Immutable') {
        if (-not $GitHubRepository) { return $null }
        return [pscustomobject]@{
            Format  = 'Immutable'
            Subject = "repo:$($GitHubRepository.owner.login)@$($GitHubRepository.owner.id)/$($GitHubRepository.name)@$($GitHubRepository.id):$Context"
        }
    }
    $o = if ($GitHubRepository) { $GitHubRepository.owner.login } else { $Owner }
    $r = if ($GitHubRepository) { $GitHubRepository.name } else { $Repository }
    [pscustomobject]@{ Format = 'Classic'; Subject = "repo:$o/${r}:$Context" }
}

# --------------------------------------------------------------------------- #
#  Azure                                                                       #
# --------------------------------------------------------------------------- #
function Connect-WorkshopSubscription {
    <#
    Selects the subscription in the current az session and checks its tenant.
    Does not sign in: run az login (locally) or azure/login (in Actions) first.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $SubscriptionId, [string] $TenantId)
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI (az) not found. Install it (winget install Microsoft.AzureCLI) and run az login.'
    }
    if ((Invoke-WorkshopAz @('account', 'show', '-o', 'none')).ExitCode -ne 0) {
        throw 'Not signed in to Azure. Run: az login --tenant <tenant-id>'
    }
    $set = Invoke-WorkshopAz @('account', 'set', '--subscription', $SubscriptionId)
    if ($set.ExitCode -ne 0) {
        throw 'Cannot select the subscription. Check the ID and that the signed-in identity holds a role on it.'
    }
    $acct = ConvertFrom-WorkshopJson (Invoke-WorkshopAz @('account', 'show', '-o', 'json')).StdOut
    if ($TenantId -and $acct.tenantId -ne $TenantId) {
        throw 'The subscription belongs to a different tenant than -TenantId. Check both IDs.'
    }
    if ($script:State.InActions) {
        Register-WorkshopSensitiveValue $acct.id 'subscription'
        Register-WorkshopSensitiveValue $acct.tenantId 'tenant'
    }
    [pscustomobject]@{ SubscriptionId = $acct.id; TenantId = $acct.tenantId; UserType = $acct.user.type }
}

Export-ModuleMember -Variable Workshop -Function @(
    'Initialize-WorkshopOutput', 'Test-WorkshopWorkflowRun', 'Register-WorkshopSensitiveValue',
    'Protect-WorkshopText', 'Format-WorkshopLabel',
    'Write-WorkshopStep', 'Write-WorkshopOk', 'Write-WorkshopSkip', 'Write-WorkshopPlan',
    'Write-WorkshopWarn', 'Write-WorkshopError', 'Add-WorkshopSummary',
    'Invoke-WorkshopNative', 'Invoke-WorkshopAz', 'ConvertFrom-WorkshopJson', 'Test-WorkshopNotFound',
    'Invoke-WorkshopWithRetry', 'Get-WorkshopTag', 'Test-WorkshopOwnedResource', 'ConvertTo-WorkshopTagArgument',
    'Assert-WorkshopValue', 'Import-WorkshopRoster', 'Resolve-WorkshopPrefix',
    'Get-WorkshopGitHubRepository', 'Get-WorkshopSubject', 'Connect-WorkshopSubscription'
)
