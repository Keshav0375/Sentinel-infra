# Bootstrap — one-time manual setup

Everything in this repo is Terraform **except** the two things Terraform cannot create for
itself. This document covers those, in order, and nothing else.

> **Run hand-typed `az` and `terraform` commands in PowerShell.** MSYS2 rewrites anything
> shaped like a Unix path into a Windows path, so `--scope /subscriptions/...` silently
> becomes `C:/Program Files/Git/subscriptions/...` and fails confusingly. This affects
> `terraform import` too, not just `az`.
>
> **The `.sh` scripts set `MSYS_NO_PATHCONV=1` themselves**, so they are safe either way —
> but invoking them *from* PowerShell needs the full path to Git Bash, because bare `bash`
> in PowerShell resolves to `C:\Windows\system32\bash.exe`, the **WSL** launcher, and
> fails with `execvpe(/bin/bash) failed: No such file or directory` if no distro is
> installed:
>
> ```powershell
> $bash = "C:\Program Files\Git\bin\bash.exe"
> & $bash scripts/bootstrap-state.sh
> ```
>
> Note PowerShell 5.1 has no `&&` operator — chain with `;` or use separate lines.

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

```powershell
& "C:\Program Files\Git\bin\bash.exe" scripts/bootstrap-state.sh
```

Idempotent — re-running it is a no-op, so it doubles as a "is my state storage healthy?"
check. It creates:

| Thing | Value | Why |
|-------|-------|-----|
| Resource group | `sentinel-state-rg` | **Not** `sentinel-rg` — see below |
| Storage account | `sentineltfstate0375` | `Standard_LRS`, blob encryption, TLS 1.2 min |
| Container | `tfstate` | created with `--auth-mode login`, i.e. via Entra |
| Role assignment | `Storage Blob Data Contributor` → you | see below |

> **The env vars are for recovery, not renaming.** `STATE_SA=othername` changes what the
> *script* creates, but `backend.tf` and `oidc.tf` cannot read env vars and still point at
> the old name — you would get state storage Terraform cannot reach. A real rename means
> changing all six places the script lists. Same applies to `RG`/`UAMI`/`LOCATION`/`OWNER`
> in `bootstrap-oidc.sh`.

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

```powershell
& "C:\Program Files\Git\bin\bash.exe" scripts/bootstrap-oidc.sh
```

Idempotent. Creates the `sentinel-gha` user-assigned managed identity, its two role
assignments, and the first two federated credentials, then prints the five
`terraform import` commands. Run those, then `terraform apply` creates the remaining three
credentials.

> The CI identity is a **managed identity**, not an app registration. The subscription lives
> in the `uwindsor.ca` tenant, where `allowedToCreateApps` is `false` at tenant policy — no
> app registration can be created. A UAMI is an ordinary Azure resource governed by RBAC and
> carries federated credentials identically; `azure/login@v2` cannot tell them apart.

### Two traps in the import step

Both of these were hit for real, and both produce errors that point away from the cause.

**Run the imports in PowerShell, or `export MSYS_NO_PATHCONV=1` first.** MSYS rewrites
`/subscriptions/...` into `C:/Program Files/Git/subscriptions/...` for **any** command —
`terraform` included, not just `az`. The failure reads as a malformed resource ID.

**Resource-ID casing is significant.** `az identity show --query id` returns the id with
`resourcegroups` (lowercase g); the azurerm provider's parser is case-sensitive and rejects
it with *"the segment at position 0 didn't match"*. Use **`resourceGroups`**. The script
builds the id by hand for exactly this reason — don't substitute what `az` printed.

**Expected result:** `terraform plan` after the imports shows **no destroy, no replace** —
only the 3 remaining federated credentials to add.

### Why `skip_service_principal_aad_check` is absent

That flag guards the `PrincipalNotFound` race when Terraform creates a role assignment
against a service principal that hasn't finished replicating. These two assignments are
always created by the bootstrap script and only *imported*, so the race cannot occur — and
the flag is create-only, so setting it on an imported assignment plans as an in-place update
that fails with `doesn't support update`. Phase 2/3 assignments do create against fresh
identities and should set it.

## Step 4b — Identity-tenant federated credentials (R4)

**The two-tenant split doubles the federated-credential surface, and this is the half that is
easy to forget.** CI authenticates to *two* tenants on every run: the school tenant as the
`sentinel-gha` UAMI (azurerm), and the identity tenant as the `sentinel-tf-identity` app
registration (the aliased `azuread` provider). A federated credential is scoped to one identity
in one tenant — so **every workflow context needs a credential in both places**.

B11 created only `sentinel-tf-main` (`ref:refs/heads/main`). Proven live 2026-08-24: a
pull-request run gets all the way through the azurerm plan, prints every output, and *then*
dies with `AADSTS700213` building the azuread client. The message names the subject, not the
tenant, so it reads like the school-tenant credential is broken when that one worked perfectly.

The identity tenant needs all three subjects the school tenant has:

| Credential | Subject | Used by |
|---|---|---|
| `sentinel-tf-main` | `repo:Keshav0375/Sentinel-infra:ref:refs/heads/main` | ✅ exists (B11) |
| `sentinel-tf-pr` | `repo:Keshav0375/Sentinel-infra:pull_request` | `ci_infra_dry.yml` `run-plan` |
| `sentinel-tf-env-production` | `repo:Keshav0375/Sentinel-infra:environment:production` | `ci_infra.yml` apply |

These are **bootstrap objects**, not Terraform resources — Terraform authenticates *as* this
app, so it cannot manage its own credentials. Same paradox as the UAMI in step 4.

```powershell
# ⚠️ This repoints the SHARED az context (see the Day 2 hazard). Switch back after.
az login --tenant eae0d3c6-af22-4b70-ad3b-12d625a06139 --allow-no-subscriptions

$app = "378ccade-dd35-4f92-a71f-4a781fe5ace3"   # sentinel-tf-identity, app objectId

'{"name":"sentinel-tf-pr","issuer":"https://token.actions.githubusercontent.com","subject":"repo:Keshav0375/Sentinel-infra:pull_request","audiences":["api://AzureADTokenExchange"]}' | Out-File -Encoding utf8 fic-pr.json
az ad app federated-credential create --id $app --parameters "@fic-pr.json"

'{"name":"sentinel-tf-env-production","issuer":"https://token.actions.githubusercontent.com","subject":"repo:Keshav0375/Sentinel-infra:environment:production","audiences":["api://AzureADTokenExchange"]}' | Out-File -Encoding utf8 fic-env.json
az ad app federated-credential create --id $app --parameters "@fic-env.json"

az ad app federated-credential list --id $app --query "[].{name:name,subject:subject}" -o tsv
Remove-Item fic-pr.json, fic-env.json

# Back to the school tenant, or the next terraform apply runs in the wrong context.
az login --tenant 12f933b3-3d61-4b19-9a4d-689021de8cc9
az account set --subscription 174e25ca-ab82-4671-a913-9c2f66e5924d
```

---

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
| variable | `KV_ADMIN_OBJECT_ID` | `az ad signed-in-user show --query id -o tsv` — same value as `PG_ADMIN_OBJECT_ID`, but a separate variable on purpose: the Key Vault admin and the database admin are the same person today and need not stay that way |
| variable | `AZURE_IDENTITY_CLIENT_ID` | `8f7ff635-799b-4bdd-b1fa-2ff9bbe75560` — `sentinel-tf-identity`, the app CI authenticates as in the **identity** tenant (R4) |
| **secret** | `GH_PAT` | GitHub PAT, `repo` scope |

⚠️ **An unset variable is not an error.** GitHub renders a missing `vars.X` as the empty
string, so the workflow runs `-var="kv_admin_object_id="` and Terraform fails somewhere
downstream with a message about a Key Vault role assignment. Set all eight before the first
CI run, and if a plan fails oddly, check this table first.

There is no `AZURE_IDENTITY_TENANT_ID` variable here: no workflow passes it, because
`variables.tf` pins the identity tenant as a default. It *is* pushed to the `Sentinel` repo
by task 4.1, where the backend workflows do need it.

> The secret is `GH_PAT`, **not** `GITHUB_PAT`. GitHub reserves the `GITHUB_` prefix and
> rejects any secret or variable using it — the original name was uncreatable.

There is no `AZURE_CLIENT_SECRET` (OIDC removes it), no `DB_PASSWORD` (PostgreSQL is
Entra-only), and no `sentinel-api-token`.

---

## Day 2 — stopping and starting

Two resources idle **stopped** to conserve the free grants, and they behave *differently*
under Terraform. Getting this wrong costs a confusing failed plan, so it is written down
once here rather than rediscovered.

| Resource | Idle state | `terraform plan` while stopped | Auto-restart |
|---|---|---|---|
| `sentinel-pg-0375` (Postgres) | Stopped | ❌ **Errors** — `400 ServerStoppedError` on 4 resources | Azure restarts it after **7 days** |
| `sentinel-aks` (AKS) | Stopped | ✅ Works fine | No |

```powershell
# Before ANY terraform command:
az postgres flexible-server start -n sentinel-pg-0375 -g sentinel-rg

# After you are done (it consumes grant hours while Ready):
az postgres flexible-server stop  -n sentinel-pg-0375 -g sentinel-rg

# AKS is the backend's scale-to-zero mechanism, not a manual chore — the incident
# workflows drive it (backend §8.5). A system pool cannot scale below 1 node, so
# it is the whole CLUSTER that stops, not the node pool.
az aks start -g sentinel-rg -n sentinel-aks
az aks stop  -g sentinel-rg -n sentinel-aks
```

**Why Postgres errors and AKS does not:** the azurerm provider must *refresh* the Postgres
administrators, database and `azure.extensions` configuration, and the control plane refuses
those reads while the server is stopped. AKS exposes its whole configuration regardless of
power state.

## Day 2 — the two-tenant `az` context hazard

`az` keeps **one** context in `~/.azure`, shared by every terminal. Sentinel spans two
tenants (school = resources, personal = the two app registrations), so **any** `az login
--tenant <identity>` silently repoints every other session — this has happened four times
during the build. Both bootstrap scripts assert `EXPECTED_SUB` and refuse to run in the
wrong context; plain `terraform apply` does not.

```powershell
# Always confirm before applying:
az account show --query "{sub:name, tenant:tenantId}" -o tsv
# Expect: Azure for Students   12f933b3-3d61-4b19-9a4d-689021de8cc9
az account set --subscription 174e25ca-ab82-4671-a913-9c2f66e5924d
```

`identity.tf` still resolves correctly from this school context, because the school account
is a redeemed **guest** with Application Administrator in the identity tenant — the aliased
`azuread` provider mints a token for the same signed-in user.

---

## Step 6 — First apply

```powershell
az postgres flexible-server start -n sentinel-pg-0375 -g sentinel-rg   # see Day 2
terraform init
terraform plan      # read it. every resource should be a create or a no-op
terraform apply
```

## Step 7 — Push the CI runner image (once)

`ci_runners.yml` rebuilds this image on every change to `ci-images/**` — but it authenticates
to an ACR that only exists after step 6, and it runs on a runner that wants the image. One
manual push breaks the circularity; after that, never run this by hand.

```bash
./ci-images/build-push.sh
az acr repository show-tags --name sentinelacr0375 --repository ci-runner -o tsv   # expect: latest
```

## Step 8 — Seed the Key Vault secrets (B4–B8)

**Terraform never writes a runtime secret.** The vault is created empty on purpose: a secret
in state is a secret in a storage account, readable by anything with state access, and
diffable in every plan. These are set by hand, once, and rotated at the provider.

```bash
az keyvault secret set --vault-name sentinel-kv-0375 --name anthropic-api-key  --value <...>
az keyvault secret set --vault-name sentinel-kv-0375 --name openai-api-key     --value <...>
az keyvault secret set --vault-name sentinel-kv-0375 --name datadog-api-key    --value <...>
az keyvault secret set --vault-name sentinel-kv-0375 --name datadog-app-key    --value <...>
az keyvault secret set --vault-name sentinel-kv-0375 --name langfuse-public-key --value <...>
az keyvault secret set --vault-name sentinel-kv-0375 --name langfuse-secret-key --value <...>
az keyvault secret set --vault-name sentinel-kv-0375 --name teams-webhook-url  --value <...>
```

Set `--expires` on each. The rotation Function watches `SecretNearExpiry`; a secret with no
expiry never fires it, so the rotation path silently does nothing.

## Step 9 — Turn on cross-repo distribution (B9)

`github-repo-config.tf` ships **disabled**, because the github provider authenticates at
configure time and a missing PAT fails the whole plan with a 401 rather than skipping one
resource.

1. Create a GitHub PAT with `repo` scope and set it as the `GH_PAT` secret (step 5).
2. Change `enable_repo_config`'s default to `true` in `variables.tf` and commit — one line,
   reviewable, and it leaves a date in the history for when distribution turned on.
3. Apply. Then confirm:

```bash
gh secret   list -R Keshav0375/Sentinel              # 3:  ACR_LOGIN_SERVER, ACR_USERNAME, ACR_PASSWORD
gh variable list -R Keshav0375/Sentinel              # 6:  AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID,
                                                     #     AZURE_IDENTITY_TENANT_ID, AZURE_GHA_CLIENT_ID, SENTINEL_API_AUDIENCE
gh variable list -R Keshav0375/Sentinel-deployment   # 3:  AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID
```

---

## Teardown — Owner-run, local, deliberate (§7.3)

**There is no destroy workflow, and adding one would be a mistake.** R6, 2026-08-16:

A full teardown has to *purge* the soft-deleted Key Vault. Deleted vaults live at
**subscription** scope, and the CI identity holds nothing there — its RBAC Administrator is
scoped to `sentinel-rg` by design. From CI the purge returns 403, `|| true` swallows it, and
the next apply fails on a vault name that is reserved for another 7 days by a vault nobody
can see. Granting CI a subscription-scope Key Vault role would fix the purge and hand a
workflow reachable from `pull_request` triggers the ability to manage every vault in the
subscription — a permanent privilege for a once-a-project operation.

So teardown is a thing a human does, as Owner, on purpose:

```bash
# 0. Confirm the context. This deletes everything; the two-tenant hazard above is
#    not a theoretical concern here.
az account show --query "{sub:name, tenant:tenantId}" -o tsv

# 1. Terraform-managed resources.
az postgres flexible-server start -n sentinel-pg-0375 -g sentinel-rg   # or destroy errors
terraform destroy

# 2. The bootstrap-created resource groups Terraform only reads.
az group delete --name sentinel-rg      --yes
az group delete --name sentinel-func-rg --yes

# 3. PURGE the vault. Without this, sentinel-kv-0375 is unusable for 7 days and a
#    rebuild fails on the reserved name. This is the step CI cannot do.
az keyvault purge --name sentinel-kv-0375 --location canadacentral

# 4. State last — it describes everything above, so it goes when nothing needs it.
az group delete --name sentinel-state-rg --yes
```

Rebuilding afterwards means starting again from Step 1: the bootstrap seams
(`bootstrap-state.sh`, `bootstrap-oidc.sh`, the 7-object import) exist precisely because
Terraform cannot create the identity and the storage its own pipeline runs on.
