# Bootstrap — from an empty subscription to a running deployment

Everything Terraform cannot do for itself, in the order it has to happen.

> **Two layers, two workspaces.** The **platform** — one registry, one cluster, one database
> server — is built once. Each **deployment** is built against it, in its own workspace, and can
> be destroyed without touching it. They are separate *state files*, and that is a safety
> property rather than a preference: in one state, destroying a deployment would take the
> cluster with it.

---

## Why any of this is manual

Three things are structurally impossible for Terraform to create:

| | |
|---|---|
| **The state storage** | It needs somewhere to put state before it can run at all. |
| **The identities its pipeline authenticates as** | It cannot create the credential it is already using. |
| **The identity-tenant app credentials** | Cross-tenant, and reached only by an interactive login. |

The first two live in **`rg-sentinel-bootstrap`** — one group holding exactly what Terraform can
never own, destroyed by nothing. Naming it `-tfstate` would be a lie about half its contents.

Everything else is codified.

---

## ⚠️ The `az` context hazard — read this before anything else

`az` keeps **one** context in `~/.azure`, shared by every terminal. Sentinel spans two tenants,
so **any** `az login --tenant <identity>` silently repoints every other session. This happened
four times during the build, and once produced a "token minted successfully" check that was a
false positive.

Both bootstrap scripts assert the subscription and refuse to run in the wrong one. Plain
`terraform apply` does not.

```powershell
az account show --query "{sub:name, tenant:tenantId}" -o tsv
# expect: Azure for Students   12f933b3-3d61-4b19-9a4d-689021de8cc9
az account set --subscription 174e25ca-ab82-4671-a913-9c2f66e5924d
```

---

## Step 1 — State storage

```bash
./scripts/bootstrap-state.sh
```

Creates `rg-sentinel-bootstrap`, the storage account `stsentineltf<uid6>`, the `tfstate`
container, and grants **you** Storage Blob Data Contributor on it. Registers eleven resource
providers. Idempotent — safe to re-run as a health check.

> **Control plane is not data plane.** Being Owner of the subscription does **not** let you read
> a blob. Without that role assignment `terraform init` returns a 403 that reads like broken
> backend configuration. This is the single most confusing failure in the whole bootstrap.

The storage account name derives from the **subscription**, not from a deployment — it exists
before any deployment does. It must match `backend.tf`, which cannot interpolate variables.

## Step 2 — The three CI identities

```bash
./scripts/bootstrap-identities.sh
```

| Identity | Rights | Federated subjects | Reachable from a PR? |
|---|---|---|---|
| `gha-plan` | Reader + blob **Reader** | `pull_request`, `environment:plan` | yes — and it can change nothing |
| `gha-deploy` | Contributor + RBAC Admin + AKS Cluster Admin | `environment:production`, `environment:destroy` | **no** |
| `gha-ops` | custom 10-action start/stop role | `environment:ops` | **no** |

**The protection is the token, not a rule.** A job declaring `environment: X` receives the OIDC
subject `repo:<owner>/<repo>:environment:X` instead of the branch form, and GitHub will not mint
that for a `pull_request` event. `gha-deploy` is therefore unreachable from a PR *by
construction* — there is nothing to misconfigure.

`gha-plan` holds blob **Reader**, so plans run `-lock=false`. Its entire permission set is
`*/read` plus two blob reads: no write action anywhere in the subscription. The cost is that an
unlocked plan racing an apply can produce a stale plan — acceptable, since plans are advisory
and applies are dispatch-only.

The script prints three client IDs. Set them as repository **variables**, not secrets — under
OIDC these are public identifiers, and masking them turns `AADSTS700213: subject ***` into an
unreadable failure.

## Step 3 — GitHub repository configuration

| Kind | Name | Value |
|---|---|---|
| variable | `AZURE_CLIENT_ID_PLAN` | from step 2 |
| variable | `AZURE_CLIENT_ID_DEPLOY` | from step 2 |
| variable | `AZURE_CLIENT_ID_OPS` | from step 2 |
| variable | `AZURE_TENANT_ID` | `12f933b3-3d61-4b19-9a4d-689021de8cc9` |
| variable | `AZURE_SUBSCRIPTION_ID` | `174e25ca-ab82-4671-a913-9c2f66e5924d` |
| variable | `AZURE_LOCATION` | `canadacentral` |
| variable | `PG_ADMIN_OBJECT_ID` | `az ad signed-in-user show --query id -o tsv` |
| variable | `PG_ADMIN_PRINCIPAL_NAME` | your UPN |
| variable | `KV_ADMIN_OBJECT_ID` | same as `PG_ADMIN_OBJECT_ID` today, separate on purpose |
| variable | `AZURE_IDENTITY_TENANT_ID` | `eae0d3c6-af22-4b70-ad3b-12d625a06139` |

Also create four GitHub **environments**: `plan`, `production`, `destroy`, `ops`. Put a required
reviewer on `destroy`; the others need none.

> ⚠️ **An unset variable is not an error.** GitHub renders a missing `vars.X` as the empty
> string, so the workflow runs `-var="kv_admin_object_id="` and Terraform fails somewhere
> downstream about a role assignment. If a run fails oddly, check this table first.

There is no `AZURE_CLIENT_SECRET` (OIDC removes it), no `DB_PASSWORD` (Postgres is Entra-only),
and no `GITHUB_`-prefixed name (GitHub reserves that prefix outright).

## Step 4 — Identity-tenant federated credentials (R4)

**The two-tenant split doubles the federated-credential surface, and this is the half that gets
forgotten.** CI authenticates to *two* tenants on every run: the school tenant as a UAMI, and
the identity tenant as `sentinel-tf-identity`. A credential is scoped to one identity in one
tenant, so every workflow context needs one in **both**.

Proven live in phase 4: a pull-request run got through the *entire* azurerm plan, printed every
output, and then died `AADSTS700213` building the azuread client — with a message naming the
subject but not the tenant, so it read as though the school credential were broken.

```powershell
# ⚠️ repoints the SHARED az context. Switch back afterwards.
az login --tenant eae0d3c6-af22-4b70-ad3b-12d625a06139 --allow-no-subscriptions

$app = "378ccade-dd35-4f92-a71f-4a781fe5ace3"   # sentinel-tf-identity

foreach ($e in @("plan","production","destroy")) {
  "{`"name`":`"sentinel-tf-env-$e`",`"issuer`":`"https://token.actions.githubusercontent.com`",`"subject`":`"repo:Keshav0375/Sentinel-infra:environment:$e`",`"audiences`":[`"api://AzureADTokenExchange`"]}" |
    Out-File -Encoding utf8 fic.json
  az ad app federated-credential create --id $app --parameters "@fic.json"
}
Remove-Item fic.json

az ad app federated-credential list --id $app --query "[].{n:name,s:subject}" -o table
```

`environment:ops` is **not** needed — pause/resume never runs Terraform, so it never touches the
`azuread` provider.

While you are in that tenant, confirm the service principal actually holds its role. Phase 4
recorded this as granted when it was not:

```powershell
az rest --method GET --url "https://graph.microsoft.com/v1.0/servicePrincipals/a999bb84-7f5f-40ec-84ed-817337c9c1ba/transitiveMemberOf" --query "value[].displayName" -o tsv
# expect: Application Administrator
```

Then switch back:

```powershell
az login --tenant 12f933b3-3d61-4b19-9a4d-689021de8cc9
az account set --subscription 174e25ca-ab82-4671-a913-9c2f66e5924d
```

## Step 5 — The platform layer

One registry, one cluster, one database server. Built once.

```bash
terraform init
terraform workspace new platform     # or: terraform workspace select platform
terraform apply                      # terraform.tfvars sets layer = "platform"
```

**Why one cluster.** The subscription's regional quota is **6 vCPU** and an AKS node is 2 —
cluster-per-deployment stops at three with no headroom. Each deployment gets a namespace
instead, and the isolation is not weaker for being logical: workload identity federates on
`system:serviceaccount:<namespace>:<sa>`, matched by Entra as an exact string with no wildcard,
so a pod in one namespace cannot mint a token for another's Key Vault.

**The cluster is ARM64** (`Standard_B2pls_v2`), which propagates: backend images must build
`linux/arm64`. Not a preference — the grant SKU `B2ats_v2` fails the system pool's 4 GB floor,
`B2s` is not in this subscription's allowed list for canadacentral, and every permitted small
SKU there is ARM.

## Step 6 — Runner image

```bash
./ci-images/build-push.sh
az acr repository show-tags --name <acr> --repository ci-runner -o tsv
```

One manual push breaks the circularity — the workflow that builds this image needs an ACR the
platform apply creates, and runs inside the image it builds. Afterwards `ci_runners.yml` owns
every rebuild, which is what keeps the image corresponding to a commit rather than to someone's
laptop.

## Step 7 — A deployment

**One button press.** Actions → *Sentinel Infra — Deploy* → Run workflow:

| Field | Value |
|---|---|
| `deployment` | `demo1` |
| `action` | `apply` |
| `scope` | `deployment` |
| `environment_name` | `dev` |

Everything else is optional. That is the whole instruction — a deployment absent
from `azure/config/deployment-config.yaml` inherits `defaults:` entirely, so no file edit is
needed. Add a block there only when a deployment must differ.

**To tear it down:** same workflow, `action: destroy`, and retype the confirmation. The retype is
the only friction and it is deliberate — it is the difference between an irreversible action and
a mis-click. What you type depends on the scope:

| `scope` | `confirm` | destroys |
|---|---|---|
| `deployment` | the deployment name | that deployment only |
| `platform` | `platform` | the shared cluster/registry/database — **refused** while any deployment still holds state |
| `all` | `destroy-everything` | every deployment, then the platform, in that order |

`scope: all` is the one that reaches zero. Afterwards the verify job asserts against Azure that
the subscription holds only `rg-sentinel-bootstrap` and `NetworkWatcherRG` — both $0 — and fails
red if anything else survived. A green verify job is the proof; a green destroy is not.

**Apply works the same way in reverse.** `scope: all` builds the platform first, then the named
deployment, then seeds its vault. One press from an empty subscription to a working stack.

**To pause everything without deleting:** Actions → *Sentinel — Pause / Resume*.

Locally, the same thing:

```bash
terraform workspace new demo1-dev
terraform apply -var layer=deployment -var deployment=demo1 -var environment=dev
```

A deployment absent from `azure/config/deployment-config.yaml` inherits `defaults:` entirely, so
this needs no file edit. Add a block there only when a deployment must differ.

## Step 8 — Key Vault secrets, per deployment

⚠️ **Every deployment has its own vault, and every one ships empty.** The bridge reads
`GITHUB_TOKEN` as a Key Vault reference, so until you seed it that reference resolves to the
literal `@Microsoft.KeyVault(...)` string. The handlers detect that and log rather than crashing
— a deployment with an unseeded vault is a *valid* state, it just cannot dispatch.

**This is now automatic.** The deploy workflow's *Seed the vault* step writes these from the
GitHub `production` environment secrets after every apply, so a destroy → recreate cycle comes
back with a working vault and no manual step. Populate the secrets once with
`bash scripts/set-gh-secrets.sh` (which reads `.env`; copy `.env.example` and fill it), and the
rebuild loop stops needing you.

The step is idempotent by design: it writes only when a secret is absent or within 30 days of
expiring. Writing on every apply would keep resetting the expiry clock the rotation Function
watches, so `SecretNearExpiry` would never fire and nothing would ever rotate.

`ANTHROPIC_API_KEY` and `OPENAI_API_KEY` are deliberately **not** in that list. Both vendors
support workload identity federation, so the backend pod will authenticate with its projected
service-account token and there is no key to store — see `architecture/decisions.md` 2026-08-30
in `sentinel-brain`. Built in backend phase 7.

To seed by hand instead, get the vault name from the deployment's outputs
(`terraform output names`), then:

**Terraform never writes a runtime secret.** The vault is created empty on purpose: a secret in
state is a secret in a storage account, readable by anything with state access and visible in
every plan. Set by hand, once, rotated at the provider.

```bash
az keyvault secret set --vault-name <kv> --name anthropic-api-key   --value <...> --expires <+90d>
az keyvault secret set --vault-name <kv> --name openai-api-key      --value <...> --expires <+90d>
az keyvault secret set --vault-name <kv> --name datadog-api-key     --value <...> --expires <+90d>
az keyvault secret set --vault-name <kv> --name datadog-app-key     --value <...> --expires <+90d>
az keyvault secret set --vault-name <kv> --name langfuse-public-key --value <...> --expires <+90d>
az keyvault secret set --vault-name <kv> --name langfuse-secret-key --value <...> --expires <+90d>
az keyvault secret set --vault-name <kv> --name teams-webhook-url   --value <...> --expires <+90d>
```

Set `--expires` on every one. The rotation Function watches `SecretNearExpiry`; a secret with no
expiry never fires it, so the rotation path silently does nothing.

---

## Day 2 — stopping and starting

Two resources idle **stopped**, and they behave *differently* under Terraform.

| Resource | Idle | `plan` while stopped | `apply` while stopped | Auto-restart |
|---|---|---|---|---|
| Postgres | Stopped | ❌ `400 ServerStoppedError` | ❌ | after **7 days** |
| AKS | Stopped | ✅ works | ❌ `OperationNotAllowed` | no |

**The AKS row is not symmetric, and that catches people.** A stopped cluster plans perfectly
well — it exposes its whole configuration regardless of power state — and then the apply fails
with `Operations are not allowed when the managed cluster is not in the Running power state`.
So a change to the cluster can look completely fine right up until it doesn't. Start it before
applying anything that touches AKS, not just before planning.

**Why they differ:** the provider must *refresh* Postgres' administrators, database and
`azure.extensions` configuration, and the control plane refuses those reads while the server is
down. AKS exposes its whole configuration regardless of power state.

```powershell
az postgres flexible-server start -n <psql> -g <rg>   # before ANY terraform command
az postgres flexible-server stop  -n <psql> -g <rg>
az aks start -g <rg> -n <aks>
az aks stop  -g <rg> -n <aks>
```

Both CI terraform jobs check and start the database themselves — this broke a run three times
before it was fixed in the one place that removes it permanently.

**Pause is not zero cost.** Stopping ends the *compute* charge, which dominates. OS disks,
storage, the AKS load balancer and the ACR daily charge continue. Only destroy is zero.

## Day 2 — Windows-specific traps

Both cost real time; both are now handled inside the scripts.

**Git Bash rewrites Unix-looking paths.** An Azure resource ID starts with `/subscriptions/`, so
`--scope /subscriptions/...` arrives as `C:/Program Files/Git/subscriptions/...` and the API
answers `MissingSubscription` — a message that says nothing about path conversion. Set
`MSYS_NO_PATHCONV=1`.

**`az` emits CRLF.** Command substitution strips the trailing newline but *not* the carriage
return, so every captured value silently carries one — which breaks string comparisons and
resource IDs.

---

## Teardown

**The workflow is the supported path, including for the platform.** Actions → *Sentinel Infra —
Deploy* → `action: destroy`, `scope: all`, `confirm: destroy-everything`. It destroys every
deployment first and the platform last — the order matters, because a deployment reads the
platform through `terraform_remote_state` and holds a namespace on its cluster and a database on
its Postgres server. Destroying the platform first does not fail loudly; it leaves orphaned state
describing resources that no longer exist.

Everything below is the same thing by hand, for when you want to watch it happen.

**A deployment:**

```bash
terraform workspace select demo1-dev
terraform destroy -var layer=deployment -var deployment=demo1 -var environment=dev
terraform workspace select platform && terraform workspace delete demo1-dev
```

The Key Vault needs no manual purge: the azurerm provider purges on destroy by default, so the
name is immediately reusable. That is what makes destroy → recreate of the same deployment name
work at all.

**The platform**, only when nothing depends on it — `scripts/lifecycle.sh` enforces this and a
hand-run does not, so check `terraform workspace list` first:

```bash
terraform workspace select platform
terraform destroy -var layer=platform
```

**The bootstrap group is last, and by hand** — it holds the state describing everything above:

```bash
az group delete --name rg-sentinel-bootstrap --yes
az role definition delete --name "Sentinel Ops Start Stop"
```

Rebuilding afterwards starts again from step 1.

**Verify, do not assume.** A `terraform destroy` that exits 0 has proved only that everything in
state is gone. It cannot speak for a resource dropped from state by a failed apply. On 2026-08-30
an entire deployment — a resource group, a Key Vault, and a database on the shared Postgres
server — was found alive five days after it was believed destroyed, with every exit code 0. Run
the referee:

```bash
bash scripts/verify-estate.sh --mode destroyed --scope all
```

---

## Reconciling drift (what `refresh-only` used to do)

The deploy workflow no longer offers `refresh-only`. It was one arrow-key from `destroy` in the
same dropdown, and `apply -refresh-only` will happily **drop resources from state** when the API
reports them gone — making them invisible to every later destroy, which is the exact leak the
teardown work exists to prevent.

Its real use is reconciling after someone edits a resource in the portal. That is a twice-a-year
operation, best run locally with your eyes on the output:

```bash
terraform workspace select <workspace>
terraform plan -refresh-only          # look at what it proposes FIRST
terraform apply -refresh-only         # only if the proposal is what you expect
```
