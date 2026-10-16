---
title: "IaC with GitHub Copilot — Workshop Home"
---

# IaC with GitHub Copilot — Workshop Home

Learn to author **Azure Bicep** with **GitHub Copilot**, and deploy it from **GitHub Actions** with no stored cloud credentials — one discipline per level: deploy, monitor, secure, protect.

> [!IMPORTANT]
> **Classroom students: everything is pre-staged.** Your GitHub account already
> holds a fork of this repo, your Azure resource group already exists (it has
> your username's name), and the deploy identity is already wired up. You can
> run the entire main path from the browser without installing anything.
> Running it on your own subscription instead? The self-hosted on-ramp is
> **Windows 11 only** (the helper scripts use `winget`); everything after
> setup is platform-agnostic.

## Start where you are

<table>
<tr>
<td align="center" width="240"><img src="icon-new-here.svg" width="56"><br><br><b>New to all of this</b><br><sub>Start with the "why", then deploy</sub><br><br><a href="Understanding-IaC.html">Understanding IaC →</a></td>
<td align="center" width="240"><img src="icon-know-azure.svg" width="56"><br><br><b>I know Azure, new to GitHub</b><br><sub>Repos, Actions, secrets, OIDC</sub><br><br><a href="GitHub-Essentials.html">GitHub Essentials →</a></td>
<td align="center" width="240"><img src="icon-just-deploy.svg" width="56"><br><br><b>Just let me deploy</b><br><sub>Two checks, then straight to L1.1</sub><br><br><a href="Start-Here-Checklist.html">Start Here Checklist →</a></td>
</tr>
</table>

All three paths converge on the **main path** — one foundation chapter per level, west to east:

**[L1.1 Deploy](Curriculum-L1-1-Core-Deployment.md) → [L2.1 Monitor](Curriculum-L2-1-Monitoring-Fundamentals.md) → [L3.1 Secure](Curriculum-L3-1-Security-Foundation.md) → [L4.1 Protect](Curriculum-L4-1-Backup-Fundamentals.md)**

Every level also goes **deeper** — optional chapters that raise the complexity, cost and prerequisites. The **[🗺️ Curriculum Map](Curriculum-Map.md)** shows all 22 chapters, what each needs, and what each costs.

---

## 🧱 The main path

Four stops, all deploying into **your single assigned resource group**, each teaching a new discipline on the environment the previous stop left behind:

```mermaid
flowchart LR
  M1["L1.1 · Deploy the core<br/>VNets, Bastion, one VM<br/>~$0.24/hr"]
  M2["L2.1 · Monitor it<br/>agent, data collection,<br/>diagnostics → Log Analytics<br/>~$0.06/hr"]
  M3["L3.1 · Check its security<br/>posture workbook<br/>$0"]
  M4["L4.1 · Back it up<br/>Recovery Services vault,<br/>daily VM backup<br/>~$10/mo"]

  M1 --> M2 --> M3 --> M4

  classDef s1 fill:#eefaf0,stroke:#3a9d5d,color:#1a1a1a
  class M1,M2,M3,M4 s1
```

<details><summary>Text description of this diagram</summary>

Four chapters run left to right: L1.1 deploys the network core (hub and spoke
VNets, Azure Bastion, one Linux VM). L2.1 monitors it (Azure Monitor Agent, a
data collection rule, and diagnostic settings flowing into Log Analytics).
L3.1 checks its security (an Azure Resource Graph posture workbook, at no
cost). L4.1 protects it (a Recovery Services vault taking daily backups of
the VM). Each chapter builds directly on the previous one and none requires
anything else.

</details>

| Stop | Guide | Requires | What gets added | Deploy time |
|------|-------|----------|-----------------|-------------|
| **L1.1** | [Core Deployment](Curriculum-L1-1-Core-Deployment.md) | — | VNets, Bastion, test VM | ~15 min |
| **L2.1** | [Monitoring Fundamentals](Curriculum-L2-1-Monitoring-Fundamentals.md) | L1.1 | Monitor agent, data collection rule, Log Analytics | ~5 min |
| **L3.1** | [Security Foundation](Curriculum-L3-1-Security-Foundation.md) | — | Security posture workbook | ~2 min |
| **L4.1** | [Backup Fundamentals](Curriculum-L4-1-Backup-Fundamentals.md) | L1.1 | Recovery Services vault, daily VM backup | ~5 min |

> [!TIP]
> **Want more?** Each level goes deeper — L1.2 adds an Azure Firewall and web
> tier, L1.3 a full multi-service app, L2.2–L2.4 turn monitoring data into
> answers, and Levels 5 (Sentinel) and 6 (Recovery) are extra-credit tracks.
> Depth costs more and depends on more: the
> [Curriculum Map](Curriculum-Map.md)
> shows every chapter's price and prerequisites before you commit. The
> expensive detour to know about: **L1.2's firewall is $1.25/hr on its own,
> and nothing requires it.**

---

## 🚀 Three ways to work (every chapter offers all three)

| | ⚙️ GitHub Actions | 🤖 GitHub Copilot | 🔧 Bicep CLI |
|---|---|---|---|
| **How** | Click **Run workflow** in your fork's Actions tab | Describe changes in plain English, review, push, then deploy via Actions | Copy-paste terminal commands |
| **Best for** | The classroom main path — zero setup | Exploring and modifying the templates | Seeing every step |
| **Deploys run on** | GitHub's runners, as your own workshop identity | GitHub's runners (Copilot edits, Actions deploys) | Your machine, as you |
| **Classroom?** | ✅ Yes — this is your path | ✅ Authoring yes; deploying goes through Actions | ⚠️ No — deploying locally needs Azure write access your classroom account doesn't have |

**Classroom accounts hold Reader in Azure.** You can *look at* everything in
the portal, but only your workshop deploy identity — which your fork's
workflows use automatically — can create resources. That is why the Actions
button is the way, and why local `az deployment` commands from the chapter
pages are for self-hosted use. (Local `az bicep build` — compiling — works for
everyone; compiling needs no Azure at all.)

---

## 🤖 The Copilot workflow

Each chapter provides **agent-mode prompts**. In VS Code:

1. Press **`Ctrl+Alt+I`** → switch the dropdown to **Agent**.
2. Paste the chapter prompt. Copilot reads the repo, edits Bicep files, and runs `az bicep build` to verify.
3. **Review every diff** — you are the reviewer. Never accept blindly.
4. Commit, push to your fork, then run the chapter's GitHub Actions workflow.

> [!IMPORTANT]
> Copilot is your pair programmer, not an autopilot. Its suggestions may need adjustment — catching and fixing those is part of the learning.

---

## ✅ Before your first deploy

**Classroom** — three checks, no installs:

- [ ] Signed in to GitHub as your workshop account (e.g. `student01`)
- [ ] You can see your fork: `github.com/<your-account>/Demo-IaC_Demo_with_VSCode`
- [ ] On the fork's **Actions** tab, workflows are enabled (one green button click the first time)

Then open [L1.1](Curriculum-L1-1-Core-Deployment.md) and run your first deployment. The workflow already knows your resource group (it is named after your account) and everything else it needs.

<details><summary><b>Self-hosted</b> — running this on your own subscription</summary>

- [ ] Tools installed — run `./scripts/Install-LabTools.ps1` *(one command, Windows with admin rights)*
- [ ] Repo **forked**, cloned, opened in VS Code, Copilot signed in
- [ ] `az login` + `gh auth login` done
- [ ] A resource group created, and OIDC wired up via `./scripts/Setup-Oidc.ps1 -ResourceGroup "<your-rg>" -Prefix "<yourname>"`

The full walkthrough is in the [Deployment Guide](Deployment-Guide.md).

</details>

---

## 🛟 When things break

Check [Troubleshooting](Troubleshooting.md). Done for the day? Run the **"Teardown labs"** workflow in your fork's Actions tab — it deletes everything inside your resource group (dry-run first, by default). Self-hosted users can also run `./scripts/Cleanup-Labs.ps1 -ResourceGroup <your-rg>` locally.

> [!WARNING]
> Azure Firewall (~$1.25/hr), Bastion, Front Door, and SQL all bill while running. Do not leave them deployed overnight.

<br>

---

> <img src="icon-spotlight.svg" width="16" align="top"> **GitHub feature spotlight · A docs site built from a folder**
>
> **You just used it:** every page you are reading is a Markdown file in the repository under `docs/wiki/`. This one is `index.md`.
> **Find it:** [`.github/workflows/pages.yml`](https://github.com/HybridCloudWorks/Demo-IaC_Demo_with_VSCode/blob/main/.github/workflows/pages.yml) builds that folder into this GitHub Pages site on every push to `main` that changes it, so a page change is reviewed in a pull request like code.
> **Beyond the lab:** docs that live in git get diffs, history and pull requests. Documentation stops being the thing nobody can review.
> [Docs →](https://docs.github.com/pages/getting-started-with-github-pages/about-github-pages)

---

## On this site

### Start here
1. [Home](index.md)
2. [Start Here — Checklist](Start-Here-Checklist.md)
3. [Checklist — Part 2](Start-Here-Checklist-Part-2.md)
4. [Deployment Guide](Deployment-Guide.md)

### 🧭 Main path — go east
One foundation chapter per level, in order. Same environment, a new discipline each stop.

| | Chapter | Cost |
|---|---|---|
|1️⃣| [L1.1 — Deploy the core](Curriculum-L1-1-Core-Deployment.md) | ~$0.24/hr |
|2️⃣| [L2.1 — Monitor it](Curriculum-L2-1-Monitoring-Fundamentals.md) | ~$0.06/hr |
|3️⃣| [L3.1 — Check its security](Curriculum-L3-1-Security-Foundation.md) | $0 |
|4️⃣| [L4.1 — Back it up](Curriculum-L4-1-Backup-Fundamentals.md) | ~$10/mo |

Extra credit: [L5.1 — Sentinel](Curriculum-L5-1-Sentinel-Foundation.md) · [L6.1 — HA audit](Curriculum-L6-1-High-Availability.md)

**[🗺️ Curriculum Map](Curriculum-Map.md)** — all 22 chapters, with costs and prerequisites

### ⬇️ Go deeper — go south
Optional depth per level. Costs and prerequisites rise as you descend — check the [map](Curriculum-Map.md) first.

**[Level 1 · Deploy](Curriculum-Level-1-Deploy.md)** — running cost with everything above still deployed:

| | Deeper chapter | Running cost |
|---|---|---|
|🟡| [L1.2 — Firewall + web tier](Curriculum-L1-2-Architecture-Expansion.md) | ~$1.65/hr |
|🟠| [L1.3 — Multi-service app](Curriculum-L1-3-Multi-Service-Application.md) | ~$1.73/hr |
|🔴| [L1.4 — Production platform](Curriculum-L1-4-Production-Platform.md) | ~$1.84/hr |

- [Level 2 · Monitor](Curriculum-Level-2-Monitor.md) — [L2.2](Curriculum-L2-2-Operational-Visibility.md) · [L2.3](Curriculum-L2-3-Proactive-Operations.md) · [L2.4](Curriculum-L2-4-Monitoring-Strategy.md)
- [Level 3 · Secure](Curriculum-Level-3-Secure.md) — [L3.2](Curriculum-L3-2-Workload-Protection.md) · [L3.3](Curriculum-L3-3-Security-Operations.md) · [L3.4](Curriculum-L3-4-Security-Architecture.md)
- [Level 4 · Protect](Curriculum-Level-4-Protect.md) — [L4.2](Curriculum-L4-2-PaaS-Protection.md) · [L4.3](Curriculum-L4-3-Backup-Operations.md) · [L4.4](Curriculum-L4-4-Data-Protection-Strategy.md)
- [Level 5 · Detect](Curriculum-Level-5-Detect.md) — [L5.2](Curriculum-L5-2-Detection-Investigation.md) · [L5.3](Curriculum-L5-3-SOC-Operations.md)
- [Level 6 · Recover](Curriculum-Level-6-Recover.md) — [L6.2](Curriculum-L6-2-Disaster-Recovery.md) · [L6.3](Curriculum-L6-3-Continuity-Validation.md)

🔴 = L1.2's Azure Firewall is **$1.25/hr on its own** — nothing requires it; tear it down promptly.

### Background
- [Understanding IaC](Understanding-IaC.md)
- [GitHub Essentials](GitHub-Essentials.md)
- [Getting Comfortable with the Tools](Getting-Comfortable-with-the-Tools.md)

### Reference
- [Cost model](Curriculum-Cost-Model.md)
- [How the curriculum is organized](Curriculum-Redesign.md)
- [Copilot Prompt Library](Copilot-Prompt-Library.md)
- [Troubleshooting](Troubleshooting.md)
- [Tools and References](Tools-and-References.md)
- [Cleanup & Reset](Cleanup-and-Reset.md)

### Instructors
- [Instructor Environment Setup](Instructor-Environment-Setup.md) — stand the class up in any tenant, then tear it down
- [Instructor Setup Guide](Instructor-Setup.md)
- [Instructor Admin Tools](Instructor-Admin-Tools.md)

---
**Done for the day?** [Tear it down](Cleanup-and-Reset.md) — Firewall, Bastion,
SQL and Front Door all bill while idle.

[Repository](https://github.com/HybridCloudWorks/Demo-IaC_Demo_with_VSCode) · [Cost breakdown](https://github.com/HybridCloudWorks/Demo-IaC_Demo_with_VSCode/tree/main/unit%20cost) · [Report a problem with these docs](https://github.com/HybridCloudWorks/Demo-IaC_Demo_with_VSCode/issues/new)

<sub>Built entirely from <a href="https://aka.ms/avm">Azure Verified Modules</a>.
Prices verified against the Azure retail price list on 4 August 2026 (East US 2).
These pages are built from <code>docs/wiki/</code> in the repository — edit them
there, through a pull request.</sub>
