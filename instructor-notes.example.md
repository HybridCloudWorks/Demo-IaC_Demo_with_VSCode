# Instructor notes — workshop identifiers (PRIVATE when filled in)

Copy this file to `instructor-notes.md` and fill in the real values.
`instructor-notes.md` is gitignored. The app/tenant/subscription IDs are
**not** committed anywhere in the repo: the workflows read them from each
fork's `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID`
secrets or variables, and stop with a clear message if one is missing.
Record them here, along with the shared storage account name and any roster
or tenant notes.

## Shared deployment identity (Entra app registration)

| Item                     | Value                     |
| ------------------------ | ------------------------- |
| App (client) ID          | `<app-client-id>`         |
| Tenant ID                | `<tenant-id>`             |
| Subscription ID          | `<subscription-id>`       |
| Shared storage account   | `<storage-account-name>`  |

One app registration is shared by the whole class. It holds Contributor on
every student resource group and is the identity that actually deploys —
students themselves hold only Reader. Each student fork authenticates to it
through a federated credential.

**Subject format matters.** GitHub repos created after 15 Jul 2026 — which
includes every workshop fork — always present the immutable, ID-enriched
OIDC subject, so each federated credential's subject must be:

    repo:User<nn>-TechCon@<owner-id>/Demo-IaC_Demo_with_VSCode@<repo-id>:ref:refs/heads/main

The classic name-only subject (`repo:User<nn>-TechCon/Demo-IaC…`) fails with
`AADSTS700213: No matching federated identity record found`. When a login
fails, the fork's Actions log ("Federated token details") prints the exact
subject to copy into the credential. One Entra *flexible* federated
credential with a claims-matching expression can also cover every fork with
a single entry instead of 35 — but match the forks' owner and repository
**IDs**, never a name wildcard such as `User*-TechCon`: anyone can register a
GitHub account that matches a name pattern, fork the repo, and get a token.

Before class, set `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and
`AZURE_SUBSCRIPTION_ID` on every fork, as secrets or variables (for example
`gh variable set AZURE_CLIENT_ID --repo User01-TechCon/Demo-IaC_Demo_with_VSCode --body <app-client-id>`).
`scripts/admin/Setup-OidcAll.ps1` sets them as secrets for you. Without them
every deploy stops at "Check Azure sign-in settings". VM and SQL passwords
need nothing: when no secret is set, each run generates its own. The shared
storage account is namespaced per student by key — record its name here.

## Roster and naming

- Students: `User01-TechCon` … `User30-TechCon`; testing: `User31-TechCon` … `User35-TechCon`.
- Each `User<nn>-TechCon` has, all pre-created before class:
  - an Entra UPN `User<nn>-TechCon@<tenant-domain>` (Reader on the subscription),
  - a GitHub account of the same name holding a fork of this repo,
  - a resource group named exactly `User<nn>-TechCon`.
- The deploy workflows default their target resource group to the **fork
  owner's name** and their resource prefix to its lowercased first segment
  (`User01-TechCon` → RG `User01-TechCon`, prefix `user01`).

**Isolation is naming, not permissions.** Because one Contributor identity is
shared by the whole class, nothing in Azure stops one student's pipeline from
writing over another's resources — the owner-derived resource group default is
the only thing keeping them apart. Do not hand-edit resource group names in
student forks.
