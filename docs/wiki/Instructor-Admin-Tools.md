---
title: "Instructor Admin Tools"
---

# Instructor Admin Tools

> These tools are for the **instructor only**. Students never run anything in the `scripts/admin/` folder.

The scripts in `scripts/admin/` build every student's environment before the lab, guard it during the lab, and remove it afterwards — in any tenant and subscription, with nothing tenant-specific in the repository. The step-by-step walkthrough, from a fresh tenant to teardown, is **[Instructor Environment Setup](Instructor-Environment-Setup.md)**; this page is the reference.

---

## 🗺️ Overview -- what the scripts do

<table>
<tr>
<td align="center" width="180"><strong>1. New-WorkshopBootstrap</strong><br><sub>Once: the automation identity</sub></td>
<td align="center" width="180"><strong>2. New-WorkshopEnvironment</strong><br><sub>Per-student identity + group</sub></td>
<td align="center" width="180"><strong>3. Set-LabPolicy</strong><br><sub>Optional policy guardrails</sub></td>
<td align="center" width="180"><strong>4. Remove-WorkshopEnvironment</strong><br><sub>Teardown by tag</sub></td>
</tr>
</table>

Run them in that order. Each script is idempotent -- re-running repairs without duplicating -- and each supports `-WhatIf` to preview. Steps 2 and 4 also run from GitHub Actions: the **Workshop environment (instructor)** workflow, from a private copy of the repository.

Every student gets **their own** user-assigned managed identity with **one** federated credential, for the `main` branch of **their own** fork, and **Contributor on their own resource group only**. There is no shared deploy identity and no wildcard or name-pattern trust.

---

## 🗂️ The roster -- `workshop-roster.csv`

The class is one CSV in `scripts/admin/` (copy `workshop-roster.csv.example`). Tenant, subscription, region and event name are **parameters** (or, for the workflow, repository variables), never CSV columns or code.

> [!IMPORTANT]
> The roster holds students' GitHub usernames (and UPNs, if you add them): personal data, in a public repository. `workshop-roster*.csv` and the output `workshop-client-ids*.csv` are gitignored. For the workflow the roster lives only in the `WORKSHOP_ROSTER_CSV` secret, and the scripts print row labels (`student 03`) and counts, never names.

| Column | Required | Example value |
|--------|----------|---------------|
| `GitHubUsername` | yes | `student01` |
| `EntraUpn` | no | `student01@contoso.onmicrosoft.com` -- gets Reader on their group for the portal and Bastion |
| `AzurePrefix` | no | `stu01` -- derived from the username when empty, unique within the roster |
| `Repository` | no | the fork's name, default `Demo-IaC_Demo_with_VSCode` |

---

## 🔧 Prerequisites

> [!IMPORTANT]
> Install once: PowerShell 7.2+, the Azure CLI and the GitHub CLI.
> ```powershell
> az login --tenant <tenant-id>   # Azure CLI (every script)
> gh auth login                   # GitHub CLI (fork lookups, -SetForkVariables)
> ```

### Azure permissions needed

| Role | Where | Needed for |
|------|-------|-----------|
| **Owner** | Subscription | `New-WorkshopBootstrap.ps1` (custom role, role assignments, lock); local create/remove runs |
| **Resource Policy Contributor** or Owner | Each resource group | `Set-LabPolicy.ps1` |
| **Security Admin** or Owner | Subscription | `Enable-DefenderPlans.ps1` |

No Entra administrator role, Microsoft Graph permission or admin consent is needed: the deploy identities are managed identities (Azure resources).

### GitHub permissions needed

None on the students' forks. Each student sets four or five repository variables on their own fork from the row you send them. Only `-SetForkVariables` (local runs, forks you administer) needs **Admin** on those forks.

---

## 1. 🔑 New-WorkshopBootstrap.ps1 -- the automation identity (once)

**What it does**, once per subscription, run locally by a subscription Owner:
- Creates `rg-workshop-automation` and the managed identity `id-workshop-automation` in it
- Adds **one** federated credential: your private admin repository's `workshop-admin` environment
- Creates the custom role *Workshop Environment Operator* (resource groups and managed identities only) and assigns it at subscription scope
- Assigns **Role Based Access Control Administrator** with a condition: only **Contributor**, only for **service principals**, **never itself**
- Puts a ReadOnly lock on `rg-workshop-automation` so the identity cannot change its own trust
- Prints the variables and the roster secret to set on the admin repository

```powershell
./scripts/admin/New-WorkshopBootstrap.ps1 -TenantId <tenant-id> -SubscriptionId <subscription-id> -AdminRepository MyOrg/workshop-admin -WhatIf
./scripts/admin/New-WorkshopBootstrap.ps1 -TenantId <tenant-id> -SubscriptionId <subscription-id> -AdminRepository MyOrg/workshop-admin
```

> [!WARNING]
> A role-assignment condition limits the role and the principal type, not the scope. Use a subscription that holds only workshops, and keep the admin repository private with `main`-only deployments to `workshop-admin`. Details: *Residual risk* in step 2 of [Instructor Environment Setup](Instructor-Environment-Setup.md).

---

## 2. ⚙️ New-WorkshopEnvironment.ps1 -- build the class

**What it does** per roster row:
- Creates a resource group named after the student's GitHub username (the group the curriculum workflows target by default)
- Creates the student's managed identity in `rg-workshop-<event>-identities`
- Writes **one** federated credential for the fork's `main` branch, in the exact subject format that fork presents (forks created after 15 Jul 2026 present `repo:<user>@<user-id>/<repo>@<repo-id>:ref:refs/heads/main`)
- Grants the identity **Contributor** on the student's group, and optionally Reader to the student's `EntraUpn`
- Writes `scripts/admin/workshop-client-ids.csv` (gitignored): one row per student with the values their fork needs

**Tags applied to every resource group:**

| Tag | Value |
|-----|-------|
| `ManagedBy` | `workshop-environment` -- what teardown selects on |
| `Event` | `-EventName` (for example `MyEvent`) |
| `WorkshopRole` | `student` or `identities` |
| `Owner` | the student's GitHub username (student groups) |
| `Date` | UTC date of creation |
| `Instructor` | `-InstructorName`, if given |

**Run it:**

```powershell
# Always preview first
./scripts/admin/New-WorkshopEnvironment.ps1 -EventName MyEvent -SubscriptionId <subscription-id> -TenantId <tenant-id> -WhatIf

# Apply for real
./scripts/admin/New-WorkshopEnvironment.ps1 -EventName MyEvent -SubscriptionId <subscription-id> -TenantId <tenant-id>

# Forks you administer: also set their variables
./scripts/admin/New-WorkshopEnvironment.ps1 -EventName MyEvent -SubscriptionId <subscription-id> -SetForkVariables
```

> [!NOTE]
> A row whose fork does not exist yet ends as `waiting-for-fork`: everything but the credential is built. Re-run once the student forks. An existing resource group or identity is reused only if it carries this event's tags; anything else with the same name stops that row instead of being adopted.

---

## 3. 🛡️ Set-LabPolicy.ps1 -- Apply Azure Policy guardrails (optional)

**What it does** -- assigns 6 Azure Policy assignments to every `rg-techdemo-*` resource group:

| # | Policy | Effect |
|---|--------|--------|
| 1 | Allowed locations | Only `eastus2` and `westus2` deployments are permitted (L1.4 builds its failover stack in `westus2`) |
| 2 | Allowed resource types | Only ~38 types used by L1.1-L1.4 labs are allowed |
| 3 | Inherit tag: Owner | Every resource inside the RG inherits the `Owner` tag |
| 4 | Inherit tag: Event | Every resource inherits the `Event` tag |
| 5 | Inherit tag: Date | Every resource inherits the `Date` tag |
| 6 | Inherit tag: Instructor | Every resource inherits the `Instructor` tag |

It finds groups by the `rg-techdemo-` prefix, so build the class with `-ResourceGroupPrefix rg-techdemo-` (workflow: the `WORKSHOP_RESOURCE_GROUP_PREFIX` variable) if you want it; students then also set the `AZURE_RESOURCE_GROUP` secret, which the client-ID file flags per row. It reads the subscription ID from a `lab-user-data.csv` (see `lab-user-data.csv.example`).

**Run it:**

```powershell
# Always preview first
./scripts/admin/Set-LabPolicy.ps1 -WhatIf

# Apply
./scripts/admin/Set-LabPolicy.ps1
```

> [!NOTE]
> Policy assignments take a few minutes to take effect. Resources that violate the policy will be blocked at deploy time with a clear error message -- not silently.

---

## 4. 🧹 Remove-WorkshopEnvironment.ps1 -- tear the class down

**What it does:** deletes every resource group tagged `ManagedBy=workshop-environment` and `Event=<event>` -- the student groups with everything the labs deployed, and the identity group with every identity and federated credential -- and nothing else. Each identity's role assignment is removed first, so access ends even if a group refuses to delete. `-RosterPath` limits it to some students.

```powershell
./scripts/admin/Remove-WorkshopEnvironment.ps1 -EventName MyEvent -SubscriptionId <subscription-id> -WhatIf
./scripts/admin/Remove-WorkshopEnvironment.ps1 -EventName MyEvent -SubscriptionId <subscription-id>
```

From the workflow: `action: destroy` previews; set `confirm_event` to the event name to delete.

---

## ✅ What students experience

1. Fork the repo and tell you their GitHub username (before you run step 2)
2. Receive **their own** row from you, privately
3. Set `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_PREFIX` and `AZURE_LOCATION` as repository variables on their fork (skip this if you used `-SetForkVariables`)
4. Enable workflows on the fork's **Actions** tab and run **Curriculum L1.1 - Core Deployment**

```powershell
# Student: should list the five variables
gh variable list
```

| What they see | What it means |
|---------------|---------------|
| The five variables | Ready -- run L1.1 |
| Run stops at *Check Azure sign-in settings* | A variable is missing -- set it from their row |
| `AADSTS700213` at *Azure login* | Wrong fork or branch, or the fork was re-created -- re-run step 2 |

---

## 🔄 Re-running and idempotency

Every script checks before acting:

- Existing groups and identities are reused only when their tags say this event created them
- Existing role assignments and current federated credentials are skipped
- A credential whose fork changed (re-created fork, new repository ID) is updated in place
- The bootstrap lifts its own lock only for the change it makes, then restores it
- Teardown retries only what is left

---

## 🛟 Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `Cannot select the subscription` | Wrong subscription ID, or the signed-in identity has no role on it | Check `az account list` |
| `Not signed in to Azure` | `az login` not done | `az login --tenant <tenant-id>` |
| Row `failed`: resource group already exists but is not tagged | A group with the student's name already exists | Remove it, or use `-ResourceGroupPrefix` |
| Row `waiting-for-fork` | The fork does not exist under that username yet | Have the student fork, re-run |
| `GitHub API rate limit reached` | Unauthenticated lookups (60 an hour) | `gh auth login`, re-run |
| Workflow: *Private repository required* | It was started in a public repository | Use your private admin copy, or run locally |
| Portal Reader `skipped` in the workflow | The automation identity cannot look up Entra users (no Graph permission, by design) | Run create locally as yourself to grant it |
| Policy assignment fails with `AuthorizationFailed` | Missing Resource Policy Contributor or Owner on the RG | Check your Azure role at the RG scope |

---

*Full walkthrough: [Instructor Environment Setup](Instructor-Environment-Setup.md) · GitHub org settings and per-participant manual setup: [Instructor Setup Guide](Instructor-Setup.md)*

<br>

---

> <img src="icon-spotlight.svg" width="16" align="top"> **GitHub feature spotlight · Scripting GitHub with `gh`**
>
> **You just used it:** `New-WorkshopEnvironment.ps1` reads each fork's IDs with `gh api repos/<user>/<repo>` to build its exact OIDC subject, and `-SetForkVariables` writes five variables per fork without a browser. That is the `gh` CLI doing in a loop what would otherwise be dozens of rounds of clicking.
> **Find it:** the `gh api` call in [`scripts/admin/WorkshopEnvironment.psm1`](https://github.com/HybridCloudWorks/Demo-IaC_Demo_with_VSCode/blob/main/scripts/admin/WorkshopEnvironment.psm1) and the `gh variable set` calls in [`scripts/admin/New-WorkshopEnvironment.ps1`](https://github.com/HybridCloudWorks/Demo-IaC_Demo_with_VSCode/blob/main/scripts/admin/New-WorkshopEnvironment.ps1). Verify with `gh variable list --repo <owner>/<repo>`.
> **Beyond the lab:** anything you can do in the GitHub UI, `gh` can do in a script — and in an organization every one of those writes lands in the audit log, so bulk changes stay reviewable.
> [Docs →](https://cli.github.com/manual/gh_variable_set)
