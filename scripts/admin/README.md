# Pre-Lab Admin Setup

This folder holds the scripts the **instructor** runs to build, guard and tear down every student's environment. Students never run these scripts.

Full walkthrough, from a fresh tenant to teardown: **[Instructor Environment Setup](https://hybridcloudworks.github.io/Demo-IaC_Demo_with_VSCode/Instructor-Environment-Setup.html)**.

---

## What gets built

Per student: a resource group named after their GitHub username, a **user-assigned managed identity** with **one explicit federated credential** for the `main` branch of their own fork, and **Contributor on their own resource group only**. No shared identity, no wildcard or name-pattern trust, no Microsoft Graph permission, nothing tenant-specific in the repo.

---

## Before you start

### You need

- **PowerShell 7.2+** -- run `pwsh --version` to confirm
- **Azure CLI** signed in: `az login --tenant <tenant-id>`
- **GitHub CLI** signed in: `gh auth login` (raises the GitHub API limit the scripts use from 60 to 5,000 reads an hour; `-SetForkVariables` needs it)
- **workshop-roster.csv** in this folder (copy `workshop-roster.csv.example`; columns `GitHubUsername`, optional `EntraUpn`, `AzurePrefix`, `Repository`)

### Azure permissions required

| Who | Permission | Why |
|-----|------------|-----|
| You, once | **Owner** on the subscription | `New-WorkshopBootstrap.ps1` creates a custom role, two role assignments and a lock |
| You, locally (optional) | **Owner** on the subscription | Running create/remove as yourself instead of through the workflow |
| The automation identity | What the bootstrap grants: a resource-group/managed-identity role, and RBAC Administrator limited to Contributor for service principals other than itself | Create and remove the class from the workflow |
| You (policy, Defender) | **Resource Policy Contributor** or Owner; Security Admin or Owner | `Set-LabPolicy.ps1`, `Enable-DefenderPlans.ps1` |

No Entra administrator role and no admin consent are needed.

> **Important:** `workshop-roster.csv` and `workshop-client-ids.csv` hold GitHub usernames (and UPNs, if you add them). They are gitignored; never commit them, paste them into an issue, or put them in a workflow file. This repository and its Actions logs are public.

---

## The scripts

**Always run with `-WhatIf` first to preview every action before it happens.** Every script is idempotent: re-run it to repair a failed step or add a student.

### 1. New-WorkshopBootstrap.ps1 -- once per subscription, locally

Creates the automation identity that the `workshop-environment` workflow signs in as, with one federated credential for your **private** admin repository's `workshop-admin` environment, then prints the repository variables and secret to set.

```powershell
./New-WorkshopBootstrap.ps1 -TenantId <tenant-id> -SubscriptionId <subscription-id> -AdminRepository MyOrg/workshop-admin -WhatIf
./New-WorkshopBootstrap.ps1 -TenantId <tenant-id> -SubscriptionId <subscription-id> -AdminRepository MyOrg/workshop-admin
```

### 2. New-WorkshopEnvironment.ps1 -- plan and create the class

Supersedes `New-LabEnvironment.ps1` and `Setup-OidcAll.ps1`. Per roster row: resource group, managed identity, one federated credential (the subject format the fork actually presents), Contributor on the group, and optional Reader for the student's Entra account. Writes `workshop-client-ids.csv` (gitignored) with the values each student's fork needs.

```powershell
./New-WorkshopEnvironment.ps1 -EventName MyEvent -SubscriptionId <subscription-id> -TenantId <tenant-id> -WhatIf
./New-WorkshopEnvironment.ps1 -EventName MyEvent -SubscriptionId <subscription-id> -TenantId <tenant-id>
```

Or from your private admin copy: **Actions → Workshop environment (instructor)**, `action: plan`, then `create`.

### 3. Set-LabPolicy.ps1 -- optional Azure Policy guardrails

Applies six policy assignments to each student resource group of an event (found by tag, whatever the groups are called): allowed locations, allowed resource types, and inheritance of the `Owner`, `Event`, `Date` and `Instructor` tags. Every input is a parameter; `-ResourceGroupPrefix` targets groups made another way.

```powershell
./Set-LabPolicy.ps1 -SubscriptionId <subscription-id> -EventName MyEvent -WhatIf
./Set-LabPolicy.ps1 -SubscriptionId <subscription-id> -EventName MyEvent
```

### 4. Remove-WorkshopEnvironment.ps1 -- tear the class down

Deletes everything `New-WorkshopEnvironment.ps1` created for the event, selected by tag (`ManagedBy=workshop-environment`, `Event=<event>`) and nothing else. Pass `-RosterPath` to remove only some students.

```powershell
./Remove-WorkshopEnvironment.ps1 -EventName MyEvent -SubscriptionId <subscription-id> -WhatIf
./Remove-WorkshopEnvironment.ps1 -EventName MyEvent -SubscriptionId <subscription-id>
```

---

## What students do

Each student forks the repo, gets **their own row** of `workshop-client-ids.csv` from you privately, and sets `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_PREFIX` and `AZURE_LOCATION` as repository **variables** on their fork. For forks you administer, `New-WorkshopEnvironment.ps1 -SetForkVariables` sets them for you. Then they enable workflows and run L1.1.

---

## Files in this folder

| File | Purpose |
|------|---------|
| `New-WorkshopBootstrap.ps1` | One-time automation identity, roles and lock |
| `New-WorkshopEnvironment.ps1` | Plan / create per-student groups, identities, credentials and roles |
| `Remove-WorkshopEnvironment.ps1` | Tear down an event by tag |
| `WorkshopEnvironment.psm1` | Shared helpers (roster, redaction, OIDC subjects) |
| `workshop-roster.csv.example` | Roster template -- copy to `workshop-roster.csv` |
| `workshop-roster.csv`, `workshop-client-ids.csv` | Your real data -- never committed (in `.gitignore`) |
| `Set-LabPolicy.ps1`, `lab-policy.bicep`, `lab-policy-rg.bicep` | Azure Policy guardrails |
| `Enable-DefenderPlans.ps1`, `defender-plans.bicep` | Defender for Cloud plans (L3) |
