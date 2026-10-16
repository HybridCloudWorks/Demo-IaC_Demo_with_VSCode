# Instructor notes — workshop identifiers (PRIVATE when filled in)

Copy this file to `instructor-notes.md` and fill in the real values.
`instructor-notes.md` is gitignored. None of these values is committed
anywhere in the repo: the workflows read them from repository secrets or
variables and stop with a clear message if one is missing. The setup itself
is described in `docs/wiki/Instructor-Environment-Setup.md`.

Do **not** record the roster or per-student values here. They live in
`scripts/admin/workshop-roster.csv` and `scripts/admin/workshop-client-ids.csv`
(both gitignored) and, for the workflow, in the `WORKSHOP_ROSTER_CSV` secret.

## Workshop tenant and subscription

| Item                     | Value                                   |
| ------------------------ | --------------------------------------- |
| Tenant ID                | `<tenant-id>`                           |
| Tenant domain            | `<contoso.onmicrosoft.com>`             |
| Subscription ID          | `<subscription-id>` (workshops only)    |
| Region                   | `<eastus2>`                             |

## Automation identity (from New-WorkshopBootstrap.ps1)

| Item                          | Value                                          |
| ----------------------------- | ---------------------------------------------- |
| Private admin repository      | `<MyOrg/workshop-admin>`                       |
| Environment                   | `workshop-admin`                               |
| Automation client ID          | `<client-id>` (`id-workshop-automation`)       |
| Custom role name              | `Workshop Environment Operator (<8 chars>)`    |

The automation identity trusts one subject only: the admin repository's
`workshop-admin` environment. It holds no Microsoft Graph permission. At
subscription scope it can create and delete resource groups and managed
identities, and grant **Contributor** to service principals other than
itself — nothing else.

## Events

| Event name (`WORKSHOP_EVENT_NAME`) | Date         | Students | Destroyed on |
| ---------------------------------- | ------------ | -------- | ------------ |
| `<MyEvent>`                        | `<yyyy-mm-dd>` | `<n>`  | `<yyyy-mm-dd>` |

Each student gets their **own** managed identity, `id-<github-username>`,
with one federated credential for the `main` branch of their own fork and
Contributor on their own resource group only. Nothing is shared between
students, and nothing trusts a name pattern.

## Retired: the TechCon shared identity

The TechCon event ran every fork through one shared app
registration with a name-wildcard flexible federated credential. That tenant
is no longer reachable and the design is retired: do not recreate a shared
deploy identity or any wildcard/name-pattern trust. Forks left over from that
event still carry `AZURE_*` secrets or variables pointing at the old tenant;
delete them before reusing a fork.
