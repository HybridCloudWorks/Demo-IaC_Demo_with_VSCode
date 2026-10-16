# L4.1 — Backup Fundamentals 🟣

**📍 [Level 4 · Protect](https://github.com/saulpatinojr/Demo-IaC_Demo_with_VSCode/wiki/Curriculum-Level-4-Protect)** · Chapter 1 of 4 &nbsp;·&nbsp; Previous: [L3.1 — Security Foundation](https://github.com/saulpatinojr/Demo-IaC_Demo_with_VSCode/wiki/Curriculum-L3-1-Security-Foundation) &nbsp;·&nbsp; Next: [🗺️ Curriculum Map](https://github.com/saulpatinojr/Demo-IaC_Demo_with_VSCode/wiki/Curriculum-Map) — main path complete, pick your next column · Go deeper: [L4.2 — PaaS Protection](https://github.com/saulpatinojr/Demo-IaC_Demo_with_VSCode/wiki/Curriculum-L4-2-PaaS-Protection)

---

**Goal:** protect the Level 1 virtual machines, and understand what a recovery
point actually is. This chapter also contains the one decision the curriculum
will not let you take back.

**The IaC lesson:** irreversible settings belong in the template as reviewed
parameters — and `dependsOn` is how a template forces them to deploy before
the resources that freeze them.

<br>

| Who this is for | Time | You need first | Cost while it runs |
|---|---|---|---|
| Chapter 1 of Level 4 · everyone | ~20 min | **L1.1 only** — the workflow's `include_web_tier` toggle defaults off; tick it while L1.2 stands to protect the web VMs too | 🟣 ~$0.06/hr added · ~$2.07/hr running total |

> [!WARNING]
> **Vault redundancy freezes the moment the first item is protected.** LRS, ZRS
> or GRS is chosen once, for the life of the vault — decide before you run this.
> L4.4 needs cross-region restore and cannot turn it on retrospectively.

<br>

## What you're building

One vault, one policy, four protected VMs. The template's whole shape is an
ordering constraint: vault redundancy lives on a storage config that is only
writable while the vault has **never** protected anything, so that config
deploys first and every protected item depends on it.

```mermaid
flowchart LR
  subgraph VMS["Level 1 VMs"]
    V1["vm-iacdemo-test"]
    V2["vm-iacdemo-web0..2"]
  end
  SC["storage config<br/>redundancy + CRR<br/>DEPLOYS FIRST"]
  POL["bkpol-iacdemo-daily<br/>30 daily · 12 weekly<br/>02:00 UTC"]
  VAULT["rsv-iacdemo-backup<br/>soft delete 14 days<br/>enhanced security"]
  ITEMS["protected items<br/>$10/month each"]

  SC --> VAULT
  POL --> VAULT
  V1 --> ITEMS
  V2 --> ITEMS
  ITEMS --> VAULT
  SC -. "freezes once<br/>ITEMS exist" .-> ITEMS

  classDef vm fill:#eefaf0,stroke:#3a9d5d,color:#1a1a1a
  classDef vault fill:#f5eefc,stroke:#7c4dbe,color:#1a1a1a
  classDef frozen fill:#fdecea,stroke:#c0392b,color:#1a1a1a
  class V1,V2 vm
  class VAULT,POL,ITEMS vault
  class SC frozen
```

<details><summary>Text description of this diagram</summary>

A Recovery Services vault, a policy, and the protected items that bind the two
to the Level 1 VMs.

The red box is the ordering constraint that shapes the whole template. Vault
redundancy and the cross-region restore flag live on the storage config, and
they are only writable while the vault has **never** protected anything. The
template therefore deploys the storage config first and makes the protected
items depend on it — get that order wrong and the setting is frozen at whatever
the default happened to be.

Soft delete is on with enhanced security, holding deleted recovery points for
14 days and requiring multi-factor authorisation to disable. It is what defeats
"the attacker deleted the backups too" — and it is also why deleting this lab
does not immediately stop the storage meter.

</details>

**Source:** [`curriculum/L4.1-backup-fundamentals/main.bicep`](https://github.com/saulpatinojr/Demo-IaC_Demo_with_VSCode/blob/main/curriculum/L4.1-backup-fundamentals/main.bicep) · [`main.bicepparam`](https://github.com/saulpatinojr/Demo-IaC_Demo_with_VSCode/blob/main/curriculum/L4.1-backup-fundamentals/main.bicepparam)

<br>

<details><summary><b>🔍 Going deeper — the semicolon-separated item names</b></summary>

<br>

Those semicolon-separated names are not a typo. Azure Backup addresses an
IaaS VM through a container/item pair whose names encode the resource group
and the VM name — `iaasvmcontainer;iaasvmcontainerv2;<rg>;<vm>`. Getting them
wrong produces an unhelpful error, and it is the single most common reason
this resource fails. Read the `protectedItems` loop in the template once,
slowly.

</details>

<details><summary><b>🔍 Going deeper — the permissions this needs</b></summary>

<table>
<tr>
<td width="72" align="center" valign="top"><img src="icon-azure-rbac.svg" width="44"></td>
<td valign="top">
<b>Azure RBAC — the minimum this chapter needs</b><br><br>
<b>Contributor</b> on the lab resource group. <b>Backup Contributor</b> is the least-privilege equivalent.<br>
<sub>Why: the vault, its policies and the protected items are all ordinary resources, and registering a VM needs write access to the VM as well as to the vault. Note what Contributor does <b>not</b> distinguish: <b>Backup Operator</b> can trigger backups and restores but cannot delete recovery points, and that split is the whole point of L4.3.</sub>
</td>
</tr>
<tr>
<td width="72" align="center" valign="top"><img src="icon-entra-id.svg" width="44"></td>
<td valign="top">
<b>Microsoft Entra ID roles</b><br><br>
<b>None.</b><br>
<sub>Azure Backup reaches the disks through the vault system-assigned identity, granted automatically at registration. No app registration, no consent, no directory role.</sub>
</td>
</tr>
</table>

<sub><a href="https://learn.microsoft.com/azure/backup/backup-rbac-rs-vault">For more info</a> — Azure RBAC roles for Azure Backup</sub>

</details>

<br>

---

> [!NOTE]
> **🏫 Classroom: use the GitHub Actions option.** Your Azure account holds
> Reader, so local `az deployment` commands will be refused — deploys go
> through your fork's workflow, which uses the shared workshop identity
> automatically. Compiling locally (`az bicep build`) works for everyone.

## 🚀 Deploy it — pick any one of three ways

<table>
<tr>
<td align="center" width="240"><img src="bicep.png" width="70"><br><br><b>1 · Bicep CLI</b><br><sub>Copy-paste in the terminal</sub></td>
<td align="center" width="240"><img src="gh-actions.png" width="70"><br><br><b>2 · GitHub Actions</b><br><sub>One button in the browser</sub></td>
<td align="center" width="240"><img src="gh-copilot.png" width="70"><br><br><b>3 · GitHub Copilot</b><br><sub>Ask AI in plain English</sub></td>
</tr>
</table>

<br>

---

## <img src="bicep.png" width="30" align="top">&nbsp; Option 1 · Bicep from the terminal

```powershell
az deployment group what-if --resource-group $env:AZURE_RESOURCE_GROUP --parameters curriculum/L4.1-backup-fundamentals/main.bicepparam
az deployment group create  --resource-group $env:AZURE_RESOURCE_GROUP --parameters curriculum/L4.1-backup-fundamentals/main.bicepparam
```

**You should see:** `redundancy` echoing your choice, `crossRegionRestoreEnabled`,
and a `redundancyIsFrozen` output stating plainly that L4.4 cannot change it.

**Decide redundancy before the first run, not after:**

```powershell
$env:CURRICULUM_VAULT_REDUNDANCY = "LocallyRedundant"   # half the storage price, no cross-region restore, ever
$env:CURRICULUM_CROSS_REGION_RESTORE = "true"           # needs GeoRedundant; L4.4 wants this
```

<br>

---

## <img src="gh-actions.png" width="30" align="top">&nbsp; Option 2 · GitHub Actions (push-button)

**Actions → "Curriculum L4 - Backup & Recovery Readiness" → Run workflow →
L4.1 - Backup Fundamentals**.

Two of the run inputs are the frozen decisions — **Vault redundancy** and **Enable cross-region restore**. They are surfaced as run inputs rather than buried in a parameter file precisely because nobody can fix them later.

<br>

---

## <img src="gh-copilot.png" width="30" align="top">&nbsp; Option 3 · GitHub Copilot (plain English)

Load your values first: `./scripts/Load-LabSettings.ps1`. Then in
**Copilot Chat → Agent mode**:

> Deploy `curriculum/L4.1-backup-fundamentals/main.bicep` to my lab resource group (`$env:AZURE_RESOURCE_GROUP`) with `az deployment group create`.

**Then ask it to do the impossible:**

> Change the redundancy on the existing vault in `curriculum/L4.1-backup-fundamentals/main.bicep` from GeoRedundant to LocallyRedundant and redeploy.

It will edit the parameter happily. The deployment then fails, because Azure
refuses the change once an item is protected. This is a good failure to see
once: the constraint lives in the platform, not in the template.

<br>

---

## ✅ Verify it

<table>
<tr>
<td align="center" width="33%"><b>Mode</b><br><sub>Portal only</sub></td>
<td align="center" width="33%"><b>Time</b><br><sub>~8 minutes</sub></td>
<td align="center" width="33%"><b>Goal</b><br><sub>Understand vault state, protection state, and restore paths</sub></td>
</tr>
</table>

> [!IMPORTANT]
> This chapter has frozen decisions. Verify them now, before the estate grows.

<details open><summary><b>Step 1 · Vault settings deep dive</b></summary>

Open `rsv-<prefix>-backup` and inspect:

- **Properties** -> redundancy model (LRS/ZRS/GRS)
- **Backup Infrastructure** -> cross-region restore setting
- **Security settings** -> soft delete enabled, retention period

**PASS:** redundancy and CRR match what you intended, and soft delete is enabled.

</details>

<details open><summary><b>Step 2 · VM protection state</b></summary>

In the vault, open **Backup items** -> **Azure Virtual Machine**.

**PASS:** `vm-<prefix>-test` appears as protected and is bound to the expected policy (`bkpol-<prefix>-daily`).

If web tier is enabled, confirm web VMs are listed too.

</details>

<details open><summary><b>Step 3 · Recovery Center walkthrough</b></summary>

Open **Recovery Center** (search for it in Azure Portal), then:

- Scope to your subscription/resource group.
- Open **Protected items** and find `vm-<prefix>-test`.
- Open **Backup jobs** and **Backup alerts** for a quick health view.

**PASS:** you can locate the VM, see its protection status, and find job history in one place.

</details>

<details open><summary><b>Step 4 · Restore options overview (no restore run required)</b></summary>

From the protected VM item, open **Restore VM** and review available restore types.

**PASS:** you can explain the difference between a full VM restore and file-level recovery, and when each is appropriate.

</details>

<details><summary><b>Step 5 · Cost and teardown risk check</b></summary>

In the vault and Recovery Center, review protected instance count and stored recovery points.

**PASS:** you can explain why backup costs can continue after VM deletion until recovery points are removed and soft-delete retention expires.

</details>

> [!TIP]
> If status looks stale, wait a few minutes and refresh. Backup jobs and protection health are not always instant in the portal.

<br>

> <img src="icon-spotlight.svg" width="16" align="top"> **GitHub feature spotlight · The template that owns a frozen decision**
>
> **You just used it:** redundancy and cross-region restore are parameters on
> this template, with the freeze written on them — so the decision is in the
> pull request, with a reviewer, rather than in a portal dropdown someone
> clicked past.
> **Find it:** the `vaultRedundancy` and `enableCrossRegionRestore` parameter
> descriptions, and the `dependsOn` that forces the storage config to land
> before any protected item.
> **Beyond the lab:** irreversible settings deserve review more than reversible
> ones, and code review is the only place that reliably happens.
> [Docs →](https://docs.github.com/pull-requests/collaborating-with-pull-requests/reviewing-changes-in-pull-requests)

<br>

---

## ➡️ What carries forward

This chapter completes the main path — deploy, monitor, secure, protect. Going
deeper, L4.2 protects the data that is not on a disk — where "backup" usually
turns out to mean something already switched on that nobody has verified.

<br>

## 🧭 Where next?

| Your situation | Go to |
|---|---|
| **Main path complete!** Pick your next move — go deeper anywhere, or take the extra-credit tracks | **[🗺️ Curriculum Map](https://github.com/saulpatinojr/Demo-IaC_Demo_with_VSCode/wiki/Curriculum-Map)** |
| Go deeper here — protect the data that isn't on a disk | [L4.2 — PaaS Protection](https://github.com/saulpatinojr/Demo-IaC_Demo_with_VSCode/wiki/Curriculum-L4-2-PaaS-Protection) |
| Extra credit — put Microsoft Sentinel on the workspace | [L5.1 — Sentinel Foundation](https://github.com/saulpatinojr/Demo-IaC_Demo_with_VSCode/wiki/Curriculum-L5-1-Sentinel-Foundation) |
| Extra credit — high availability and disaster recovery | [L6.1 — High Availability & Redundancy](https://github.com/saulpatinojr/Demo-IaC_Demo_with_VSCode/wiki/Curriculum-L6-1-High-Availability) |
| Want the big picture of this level first | [Level 4 · Protect overview](https://github.com/saulpatinojr/Demo-IaC_Demo_with_VSCode/wiki/Curriculum-Level-4-Protect) |
| Done for the day — the estate bills while idle | [Cleanup & Reset](https://github.com/saulpatinojr/Demo-IaC_Demo_with_VSCode/wiki/Cleanup-and-Reset) |
| Something didn't work | [Troubleshooting](https://github.com/saulpatinojr/Demo-IaC_Demo_with_VSCode/wiki/Troubleshooting) |
