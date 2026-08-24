# Sentinel-infra

Terraform for the Sentinel platform: seven modules, an identity plane spanning two Entra
tenants, and the CI that applies them.

> **The runbook is not here.** Ordered bootstrap steps, teardown, and day-2 operations live in
> [docs/BOOTSTRAP.md](docs/BOOTSTRAP.md). Keeping them in one place is deliberate — a runbook
> duplicated across two files is a runbook where one copy is quietly wrong, and the wrong copy
> is the one someone follows at 2am.

---

## What is here

```
.
├── main.tf                    provider config + all 7 module calls
├── versions.tf                provider pins (azurerm ~>4, azuread ~>3, github ~>6)
├── variables.tf               20 inputs; 6 are required with no default
├── outputs.tf                 the seam other repos read
├── backend.tf                 remote state (azurerm, OIDC + Entra auth)
├── oidc.tf                    CI identity: UAMI + roles + 5 federated credentials
├── identity.tf                the SECOND tenant — 2 app registrations, nothing else
├── github-repo-config.tf      pushes secrets/variables to the other two repos
├── modules/                   acr · postgresql · keyvault · aks · event-grid · functions · app-service
├── ci-images/                 CI runner image + its one-time bootstrap push
├── scripts/                   bootstrap-state.sh · bootstrap-oidc.sh
└── .github/workflows/         3 workflows (see below)
```

## The two things that surprise people

**1. There are two Entra tenants.** Every Azure resource lives in the university tenant, which
denies app registration at tenant policy (`allowedToCreateApps: false`). The two app
registrations the backend API needs therefore live in a separate, personally-owned tenant, and
`identity.tf` talks to it through an aliased `azuread` provider. Everything else — including
all three managed identities — stays in the school tenant, because they hold RBAC on school
resources and would break if moved.

**2. Postgres has no password.** Authentication is Entra-only. There is no `DB_PASSWORD`
secret, variable, or Key Vault entry anywhere in this repo, and adding one would be a defect,
not a convenience. Connect with a token:

```bash
PGPASSWORD="$(az account get-access-token \
  --resource-type oss-rdbms --query accessToken -o tsv)" \
  psql "host=<db_host> user=<your-upn> dbname=sentinel sslmode=require"
```

## Workflows

| File | Trigger | What it does |
|------|---------|--------------|
| `ci_infra_dry.yml` | every push; PRs to `main` | `run-validate` (no Azure) on every push; `run-plan` on PRs and `main`, posting the plan as a PR comment |
| `ci_infra.yml` | push to `main` | `terraform apply -auto-approve`, gated by the `production` environment |
| `ci_runners.yml` | push to `main` under `ci-images/**` | rebuilds and pushes `ci-runner:latest` |

**There is no destroy workflow, and that is deliberate.** Tearing down fully requires purging a
soft-deleted Key Vault, and deleted vaults live at *subscription* scope where the CI identity
holds nothing. From CI the purge returns 403 silently and the next apply then fails on the
reserved name. Granting CI a subscription-scope Key Vault role to fix that would let it manage
every vault in the subscription — a permanent privilege for a once-a-project operation.
Teardown is an Owner-run local procedure in [docs/BOOTSTRAP.md](docs/BOOTSTRAP.md).

**The dry run splits its jobs by credential need.** Federated credentials exist for exactly two
subjects per repo — `refs/heads/main` and `pull_request` — and Azure matches a subject as an
exact string with no wildcard. So `run-validate` is built to need nothing: `-backend=false`
means no state access, and `terraform validate` needs no variable values. It runs on every
push, including branches that have no credential at all.

**⚠️ CI runs Terraform only.** `tflint`, `shellcheck` and `gitleaks` are *not* run by any
workflow — the quality gate lives in the `Sentinel` repo and infra CI does not reach across for
it. Run it locally before every push:

```bash
python ../Sentinel/scripts/quality_gate.py --repo infra --path .
```

## Root outputs

| Output | Consumed by |
|--------|-------------|
| `acr_login_server` | backend CI image push; runner `container:` blocks |
| `db_host`, `db_name` | backend `DATABASE_URL`; the deployment pipeline's Record step |
| `aks_cluster_name` | `az aks get-credentials`; the start/stop commands |
| `backend_identity_client_id` | the `azure.workload.identity/client-id` annotation on the backend ServiceAccount |
| `oidc_issuer_url` | diagnosing federated-credential mismatches |
| `key_vault_uri` | backend secret loading; the manual seeding commands |
| `app_url` | the deployment repo's Verify step |
| `function_app_id` | Event Grid subscriptions |
| `event_grid_topic_endpoint` | Datadog monitor webhooks. The matching access key is deliberately not an output — read it with `az eventgrid topic key list` |

Neither the ACR admin password nor the Event Grid access key is a root output. The password reaches the backend repo as a GitHub secret
pushed by `github-repo-config.tf`, which is a narrower channel than `terraform output`.

## Local use

Six variables are required and have no default: `subscription_id`, `location`,
`postgres_entra_admin_object_id`, `postgres_entra_admin_principal_name`, `kv_admin_object_id`,
`github_pat`. Copy `terraform.tfvars.example` and fill it in.

```bash
terraform init
terraform plan
```

⚠️ **Start the database first.** A stopped `sentinel-pg-0375` makes `terraform plan` fail with
`400 ServerStoppedError` — the provider must refresh the admins, database and configuration,
and none of that is readable while the server is down. A stopped AKS cluster does *not* have
this problem. Details and the start/stop commands are in
[docs/BOOTSTRAP.md](docs/BOOTSTRAP.md#day-2--stopping-and-starting).
