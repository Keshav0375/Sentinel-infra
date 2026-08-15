# Bootstrap — one-time manual setup

Everything in this repo is Terraform **except** the two things Terraform cannot create for
itself. This document covers those, in order, and nothing else.

> **Run these in PowerShell, not Git Bash.** MSYS2 rewrites anything shaped like a Unix path
> into a Windows path, so `--scope /subscriptions/...` silently becomes
> `C:/Program Files/subscriptions/...` and fails with a confusing error. The `.sh` scripts
> here set `MSYS_NO_PATHCONV=1` themselves, so running *those* from Git Bash is fine — it is
> hand-typed `az` commands that break.

## Why any of this is manual

Two circular dependencies, and one deliberate seam to break each:

1. **State.** Terraform keeps state in an Azure Storage container. It cannot create that
   container, because to run at all it needs somewhere to put state.
2. **Identity.** GitHub Actions authenticates to Azure via OIDC to run Terraform. The
   identity and federated credential that make OIDC work cannot be created by that pipeline,
   because it has no identity yet.

Both are resolved the same way: create the minimum by hand, then **import** it so Terraform
manages it from then on. The manual surface is kept as small as possible and is scripted, so
it is reproducible rather than folklore.

---

## Prerequisites

| Tool | Verify |
|------|--------|
| Azure CLI | `az --version` |
| Terraform ≥ 1.9 | `terraform version` |

```powershell
az login --tenant 12f933b3-3d61-4b19-9a4d-689021de8cc9
az account set --subscription 174e25ca-ab82-4671-a913-9c2f66e5924d
```

## Step 1 — Resource group + resource providers

```powershell
az group create --name sentinel-rg --location canadacentral
```

A fresh subscription has almost every resource provider **unregistered**, and the first
`terraform apply` then fails with `subscription is not registered to use namespace ...` —
which reads like a Terraform bug and is not. Register them once:

```powershell
foreach ($ns in @('Microsoft.Compute','Microsoft.ContainerService','Microsoft.ContainerRegistry',
                  'Microsoft.DBforPostgreSQL','Microsoft.KeyVault','Microsoft.EventGrid',
                  'Microsoft.Web','Microsoft.Storage','Microsoft.ManagedIdentity',
                  'Microsoft.OperationalInsights')) {
  az provider register --namespace $ns
}
az provider show --namespace Microsoft.Compute --query registrationState -o tsv   # → Registered
```

Registration is idempotent and takes a minute or two to settle.

## Step 2 — Terraform state storage

```bash
bash scripts/bootstrap-state.sh
```

Idempotent — re-running it is a no-op, so it doubles as a "is my state storage healthy?"
check. It creates:

| Thing | Value | Why |
|-------|-------|-----|
| Resource group | `sentinel-state-rg` | **Not** `sentinel-rg` — see below |
| Storage account | `sentineltfstate0375` | `Standard_LRS`, blob encryption, TLS 1.2 min |
| Container | `tfstate` | created with `--auth-mode login`, i.e. via Entra |
| Role assignment | `Storage Blob Data Contributor` → you | see below |

Override any name with env vars: `STATE_SA=othername bash scripts/bootstrap-state.sh`.

### Why state lives in its own resource group

`ci_destroy_infra` runs `terraform destroy` followed by `az group delete` on `sentinel-rg`.
If state lived there, the teardown would delete the state describing what it is tearing
down, and the next run would have no idea what exists. Blast-radius isolation at the trust
root.

### Control plane ≠ data plane — the one that will confuse you

`backend.tf` sets `use_azuread_auth = true`, so Terraform reaches the state blob with an
**Entra token** rather than a storage access key. **Being Owner on the subscription grants
no blob access at all.** Owner is a *control-plane* role: it lets you create, configure and
delete the storage account, and gives you nothing inside it.

Without an explicit data-plane grant, `terraform init` fails with a 403 that looks like a
broken backend config. Two principals need it:

- **you**, for local runs — the bootstrap script assigns this
- **the `sentinel-gha` UAMI**, for CI — declared in `oidc.tf` as `gha_state_blob`

RBAC is eventually consistent; propagation takes 30–120s. The script retries rather than
failing on the first attempt.

### If the storage account name is taken

Storage account names are globally unique across **all** of Azure, not just your tenant.
The original `sentineltfstate` was already claimed by someone else — hence `0375`. If the
current name ever collides, change it in **all** of these together, in one commit:

- `backend.tf` — `storage_account_name`
- `scripts/bootstrap-state.sh` — `STATE_SA` default
- `oidc.tf` — the `gha_state_blob` role scope
- this file
- `sentinel-brain` → `architecture/infra.md` §8.1

The script distinguishes "taken by another tenant" from "already yours" and tells you which.

### State locking

Azure Storage provides it natively via **blob leases** — no DynamoDB-equivalent resource, no
extra table. Terraform takes a lease on the state blob for the duration of an operation.
A crashed run can leave a stale lease; `terraform force-unlock <id>` clears it.

## Step 3 — Verify state

```powershell
terraform init
```

Expect `Successfully configured the backend "azurerm"!`. That single line proves the storage
account, the container, the Entra auth path and your data-plane role assignment all work
together — it is the real acceptance test for step 2.

## Step 4 — OIDC identity

See `scripts/bootstrap-oidc.sh` — **task 1.3, not yet implemented.** It creates the
`sentinel-gha` user-assigned managed identity, its two role assignments, and the first two
federated credentials, then prints the five `terraform import` commands.

> The CI identity is a **managed identity**, not an app registration. The subscription lives
> in the `uwindsor.ca` tenant, where `allowedToCreateApps` is `false` at tenant policy — no
> app registration can be created. A UAMI is an ordinary Azure resource governed by RBAC and
> carries federated credentials identically; `azure/login@v2` cannot tell them apart.

## Step 5 — GitHub configuration

Set on the `Keshav0375/Sentinel-infra` repo. Note the split — these are **variables**, not
secrets, because under OIDC they are identifiers rather than credentials:

| Kind | Name | Value |
|------|------|-------|
| variable | `AZURE_CLIENT_ID` | the UAMI's `clientId` (not its principal ID) |
| variable | `AZURE_TENANT_ID` | `12f933b3-3d61-4b19-9a4d-689021de8cc9` |
| variable | `AZURE_SUBSCRIPTION_ID` | `174e25ca-ab82-4671-a913-9c2f66e5924d` |
| variable | `AZURE_LOCATION` | `canadacentral` |
| variable | `PG_ADMIN_OBJECT_ID` | `az ad signed-in-user show --query id -o tsv` |
| variable | `PG_ADMIN_PRINCIPAL_NAME` | your UPN |
| **secret** | `GH_PAT` | GitHub PAT, `repo` scope |

> The secret is `GH_PAT`, **not** `GITHUB_PAT`. GitHub reserves the `GITHUB_` prefix and
> rejects any secret or variable using it — the original name was uncreatable.

There is no `AZURE_CLIENT_SECRET` (OIDC removes it), no `DB_PASSWORD` (PostgreSQL is
Entra-only), and no `sentinel-api-token`.
