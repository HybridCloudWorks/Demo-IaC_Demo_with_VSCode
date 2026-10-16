---
title: "L1.1 — Core Deployment 🟢"
---

# L1.1 — Core Deployment 🟢

**📍 [Level 1 · Deploy](Curriculum-Level-1-Deploy.md)** · Chapter 1 of 4 &nbsp;·&nbsp; Previous: [Start-Here Checklist](Start-Here-Checklist.md) &nbsp;·&nbsp; Next: [L2.1 — Monitoring Fundamentals](Curriculum-L2-1-Monitoring-Fundamentals.md) &nbsp;·&nbsp; Go deeper: [L1.2 — Architecture Expansion](Curriculum-L1-2-Architecture-Expansion.md)

---

**Goal:** deploy the network foundation every later lab builds on — a hub VNet, a peered spoke VNet, Azure Bastion for secure access, and one Linux test VM.

| Who this is for | Time | You need first | Cost while it runs |
|---|---|---|---|
| Lab 1 of 4 · everyone | ~15 min, 10 of it Bastion | A browser, your workshop GitHub account, and your pre-created resource group (named after your account) | 🟢 ~$0.24/hr running total |

> [!IMPORTANT]
> **Your resource group must already exist.** Every lab deploys *into* one; none of them create it. In the classroom yours is already there, named exactly like your GitHub account (e.g. `student01`) — there is nothing to create. Self-hosted on your own subscription, create it once:
> ```powershell
> az group create --name "<your-resource-group>" --location eastus2
> ```

## What you're building

```mermaid
flowchart LR
  YOU(["You<br/>in a browser"])
  NET(["Internet"])

  subgraph HUB["vnet-iacdemo-hub · 10.0.0.0/16"]
    BAS["AzureBastionSubnet<br/>10.0.0.0/26<br/>bas-iacdemo-hub (Basic)"]
    AFW["AzureFirewallSubnet<br/>10.0.1.0/26<br/>reserved, empty until L1.2"]
  end

  subgraph SPOKE["vnet-iacdemo-spoke1 · 10.1.0.0/16"]
    VM["vm-iacdemo-test<br/>snet-workload 10.1.0.0/24<br/>Ubuntu 24.04, B2s<br/>no public IP"]
  end

  YOU -->|"HTTPS 443"| BAS
  BAS -->|"SSH, over the peering"| VM
  HUB <-->|"VNet peering<br/>both directions"| SPOKE
  VM -. "NO WAY OUT<br/>no public IP, no NAT gateway, no route" .-> NET

  classDef net fill:#eef4ff,stroke:#4472c4,color:#1a1a1a
  classDef compute fill:#eefaf0,stroke:#3a9d5d,color:#1a1a1a
  classDef blocked fill:#fdecea,stroke:#c0392b,color:#1a1a1a
  class BAS,AFW net
  class VM compute
  class NET blocked
```

<details><summary>Text description of this diagram</summary>

Two virtual networks, peered in both directions. The **hub**
(`vnet-iacdemo-hub`, `10.0.0.0/16`) holds two subnets: `AzureBastionSubnet`
(`10.0.0.0/26`) running the Basic Bastion host, and `AzureFirewallSubnet`
(`10.0.1.0/26`), which L1.1 creates but leaves empty — L1.2 puts the firewall
there. The **spoke** (`vnet-iacdemo-spoke1`, `10.1.0.0/16`) holds
`snet-workload` (`10.1.0.0/24`) with one Ubuntu VM that has no public IP.

You reach the VM by browsing to Bastion over HTTPS; Bastion reaches the VM by
SSH across the peering. Nothing else can reach it.

The dashed red line is the point of this lab: the VM has **no route to the
internet at all**. No public IP, no NAT gateway, and no route table sending
traffic anywhere. In the classroom your prefix is the `AZURE_PREFIX` your instructor gave you
(for example `student01`), so you'll see `vnet-student01-hub` and so
on; `iacdemo` is only the default when running the bare CLI commands without
setting `AZURE_PREFIX`.

</details>

**Source:** [`curriculum/L1.1-core-deployment/main.bicep`](https://github.com/HybridCloudWorks/Demo-IaC_Demo_with_VSCode/blob/main/curriculum/L1.1-core-deployment/main.bicep) · [`curriculum/L1.1-core-deployment/main.bicepparam`](https://github.com/HybridCloudWorks/Demo-IaC_Demo_with_VSCode/blob/main/curriculum/L1.1-core-deployment/main.bicepparam)

> [!NOTE]
> **Why Bastion and not a VPN Gateway?** A gateway is the real-world hybrid entry point, but takes 30–45 minutes to deploy. Bastion gives you the same "no public IP on the VM" story in about ten. The commented-out gateway module at the bottom of `main.bicep` shows what the real thing looks like.

<br>

## 🚀 Deploy it — pick any one of three ways

All three deploy the **same** template and give the **same** result. Choose the one you're most comfortable with.

<table>
<tr>
<td align="center" width="240"><img src="bicep.png" width="70"><br><br><b>1 · Bicep CLI</b><br><sub>Copy-paste in the terminal</sub></td>
<td align="center" width="240"><img src="gh-actions.png" width="70"><br><br><b>2 · GitHub Actions</b><br><sub>One button in the browser</sub></td>
<td align="center" width="240"><img src="gh-copilot.png" width="70"><br><br><b>3 · GitHub Copilot</b><br><sub>Ask AI in plain English</sub></td>
</tr>
</table>

<br>

---

> [!NOTE]
> **🏫 Classroom: use Option 2 (GitHub Actions).** Your Azure account holds Reader, so the local `az deployment` commands in Options 1 and 3 will be refused — deploys go through your fork's workflow, which uses your workshop deploy identity automatically. Compiling locally (`az bicep build`) works for everyone.

## <img src="bicep.png" width="30" align="top">&nbsp; Option 1 · Bicep from the terminal

**Best if you like the command line** and want to watch each step happen. Self-hosted only — a classroom (Reader) account can't run `az deployment` locally.

### Do this once (self-hosted)

**Classroom students configure nothing beyond the values their instructor gives them** — the workflow in Option 2 derives everything else from your fork: target resource group = your account name (`student01`), `AZURE_PREFIX` = the value from your instructor (without one, your account name's first segment, lowercased), and the VM and SQL admin passwords come from your fork's `VM_ADMIN_PASSWORD` / `SQL_ADMIN_PASSWORD` secrets, or are generated fresh (and masked) for each run when those are not set. Skip straight to Option 2 — setting `VM_ADMIN_PASSWORD` first only if you want to sign in through Bastion (`gh secret set VM_ADMIN_PASSWORD` prompts for it; 12+ characters, 3 of 4 character classes).

Self-hosted with the CLI, fill in one small file instead of typing variables into every command.

<details><summary><b>Self-hosted only · lab-settings.csv</b></summary>

Copy `lab-settings.csv.example` to **`lab-settings.csv`** in the repo root and fill in the row — it opens in Excel or VS Code:

| Column | What goes in it |
|---|---|
| `AZURE_PREFIX` | Your short name. Lowercase, max 12 characters — it prefixes every resource name. |
| `AZURE_LOCATION` | `eastus2` unless told otherwise. |
| `AZURE_RESOURCE_GROUP` | The group from the callout above. |
| `VM_ADMIN_PASSWORD` | You choose it. **This is the password you SSH with below.** |
| `SQL_ADMIN_PASSWORD` | You choose it. Not used until L1.3, but set it now. |
| `ALERT_EMAIL` | Where L1.3 sends its alert. |

Then load it. Leave `-Persist` off and the values last for this terminal only; add it and they survive new terminals:

```powershell
./scripts/Load-LabSettings.ps1            # this terminal only
./scripts/Load-LabSettings.ps1 -Persist   # also save for future terminals
```

`lab-settings.csv` is in `.gitignore`, so your passwords are never committed.

> [!IMPORTANT]
> **`-Persist` writes your passwords to this machine in plain text** (Windows registry, `HKCU\Environment`), and they stay until removed. **Remove them when you finish:**
> ```powershell
> ./scripts/Load-LabSettings.ps1 -Clear          # just the saved values
> ./scripts/Clear-LabCredentials.ps1             # also sign out of az and gh
> ```
> This workshop is **Windows 11 only**. If you try it on macOS or Linux anyway, `-Persist` does nothing at all — only Windows has a user environment store for it to write to. Re-run the plain command in each new terminal; `lab-settings.csv` is the persistence. Full details on [Cleanup & Reset](Cleanup-and-Reset.md).

</details>

### Then deploy

Preview first, then create. Run both from the repo root:

```powershell
az deployment group what-if --resource-group $env:AZURE_RESOURCE_GROUP --parameters curriculum/L1.1-core-deployment/main.bicepparam
az deployment group create  --resource-group $env:AZURE_RESOURCE_GROUP --parameters curriculum/L1.1-core-deployment/main.bicepparam
```

**You should see:** `what-if` lists the resources it would create and changes nothing. `create` takes about ten minutes — Bastion is the slow part — and ends with `"provisioningState": "Succeeded"`.

<br>

---

## <img src="gh-actions.png" width="30" align="top">&nbsp; Option 2 · GitHub Actions (push-button)

**Best if you'd rather click a button** and let the cloud do the work — and the only option a classroom (Reader) account can use.

> [!NOTE]
> **Classroom: already wired up — nothing to run.** Your fork deploys with your own workshop identity, whose three IDs (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`) your instructor set on your fork before class (or sent you to add as repository variables), and the workflow derives the resource group and prefix from your fork's owner. If a run stops at **Check Azure sign-in settings**, those IDs are missing — report it to your instructor. **Self-hosted:** run the one-time `./scripts/Setup-Oidc.ps1` per the [Deployment Guide](Deployment-Guide.md).

### Then deploy

On GitHub: **Actions → "Curriculum L1.1 - Core Deployment" → Run workflow**. Prefer the terminal? `gh workflow run curriculum-l1-1-core-deployment.yml`.

**You should see:** three steps run in order — **Lint → What-if → Deploy** — and a green tick. It signs in with OIDC, so no password is stored anywhere.

<br>

---

## <img src="gh-copilot.png" width="30" align="top">&nbsp; Option 3 · GitHub Copilot (plain English)

**Best if you'd rather describe what you want** and have AI change the template and deploy it for you. The deploy step is self-hosted only (classroom accounts hold Reader) — though Copilot's *editing* and `az bicep build` work for everyone.

Copilot runs the deploy **locally**, so (self-hosted) load your values once first — same file as Option 1: `./scripts/Load-LabSettings.ps1`.

Open **Copilot Chat → Agent mode** and paste:

> Deploy `curriculum/L1.1-core-deployment/main.bicep` to my lab resource group (`$env:AZURE_RESOURCE_GROUP`) with `az deployment group create`.

**Want to change something first?** Just ask — for example:

> Add a `snet-data` subnet `10.1.2.0/24` to the spoke VNet, run `az bicep build` to check it, then deploy.

Copilot edits the Bicep, verifies it compiles, and runs the deploy. If a command errors, paste the message back and it fixes it.

<br>

---

## ✅ Verify it

1. **Reach the VM through Bastion** — in the Portal, open `vm-<your prefix>-test` → **Connect → Bastion**, and sign in as `azureuser` with the `VM_ADMIN_PASSWORD` secret you set on your fork before the first deploy. (Self-hosted: the `VM_ADMIN_PASSWORD` you set.) No secret set? Then the run generated a one-time password that nobody can see — skip to check 2, which needs no sign-in.

  **You should see:** the Ubuntu login banner and system information in the browser, including the VM prompt. That confirms Bastion is working and the VM is reachable even though it has no public IP.

  <img src="bastion-login-example.svg" alt="Example Ubuntu banner and system information shown after Bastion login" width="980">

2. **Confirm peering in the Portal** — no terminal needed:

   - Open `vnet-<your prefix>-spoke1` -> **Peerings**.
   - Open `peer-spoke-to-hub`.

   **You should see:** `Peering status = Connected`.

   Optional double-check: open `vnet-<your prefix>-hub` -> **Peerings** -> `peer-hub-to-spoke` and confirm it is also `Connected`.

> <img src="icon-spotlight.svg" width="16" align="top"> **GitHub feature spotlight · Manual workflows and the run log**
>
> **You just used it:** every deploy workflow here is `workflow_dispatch` only — it runs when a person clicks **Run workflow**, never automatically on a push. Nobody deploys to Azure by accident.
> **Find it:** the **Actions** tab → *Deploy L1.1 - Hub & Spoke* → your run. Expand any step to see the exact `az` command and everything it printed.
> **Beyond the lab:** that run is a permanent, timestamped, linkable record of who deployed what and when — an audit trail you get for free, instead of screenshots and "who ran the deploy?" in chat.
> [Docs →](https://docs.github.com/actions/using-workflows/manually-running-a-workflow)

<br>

---

## ➡️ What carries forward

L1.2 deploys an Azure Firewall into the hub's reserved `AzureFirewallSubnet`, adds a `snet-web` subnet to this spoke, and routes **this** subnet's traffic through the firewall too — which is what finally gives the test VM its internet access.


## 🧭 Where next?

| Your situation | Go to |
|---|---|
| **Continue the main path — monitor what you just built** | **[L2.1 — Monitoring Fundamentals](Curriculum-L2-1-Monitoring-Fundamentals.md)** |
| Go deeper in Level 1 instead — add the firewall + web tier ($1.25/hr!) | [L1.2 — Architecture Expansion](Curriculum-L1-2-Architecture-Expansion.md) |
| Skip ahead to the app tier — L1.3 doesn't need L1.2 | [L1.3 — Multi-Service Application](Curriculum-L1-3-Multi-Service-Application.md) |
| Done for the day — Bastion bills while idle | [Cleanup & Reset](Cleanup-and-Reset.md) |
| Something didn't work | [Troubleshooting](Troubleshooting.md) |
| See every chapter, cost and prerequisite | [🗺️ Curriculum Map](Curriculum-Map.md) |
