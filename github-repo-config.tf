# ─────────────────────────────────────────────────────────────────────────────
# Cross-repo distribution — infra tells the other two repos who they are.
# architecture/infra.md §5 · task 4.1 · decisions.md 2026-08-24 (decisions 2, 4)
#
# Everything the backend and deployment pipelines need to reach Azure is created
# here, so it is pushed from here. The alternative — a human copying a client id
# into three GitHub settings pages — is how config drifts silently: nothing
# reports that the value in the UI no longer matches the identity in Azure, and
# the failure surfaces months later as an authentication error nobody can trace.
#
# ── SECRETS vs VARIABLES: the split is deliberate ────────────────────────────
# §5.2/§5.3 originally pushed all nine values as `github_actions_secret`, which
# contradicted §5.4, §7 and §9 — those all treated the identity pointers as repo
# variables. Settled 2026-08-24 in favour of variables, because under OIDC there
# is no secret to protect: a client id is a public identifier, and the entire
# trust decision is the federated-credential SUBJECT, which lives in Azure and
# cannot be read or forged from GitHub.
#
# Masking them is not free. A failed `azure/login` reports
#   AADSTS700213: No matching federated identity record found for subject ***
# and the masked string is the one thing that would have told you what was
# wrong. Three of this project's identity bugs were case or spelling mismatches
# in exactly that field.
#
# Real credentials — the ACR admin password and username — stay secrets.
#
# ── Deferred behind a toggle until B9 ────────────────────────────────────────
# The github provider needs a PAT with `repo` scope (B9, still open). Rather than
# leave this file uncommittable or leave `terraform plan` failing on a 401, the
# resources hang off a `count` toggle, the same deferral pattern phases 2-3 used
# for enable_backend_admin / enable_bridge_reader / enable_rotator_officer.
# Flip `enable_repo_config = true` once the PAT is seeded and apply.
#
# `count` on a bool, not `count = var.github_pat == "" ? 0 : 1`: count must
# resolve at PLAN time, and a value that arrives from a secret is unknown then.
# ─────────────────────────────────────────────────────────────────────────────

locals {
  repo_config = var.enable_repo_config ? 1 : 0

  # var.tenant_id and var.subscription_id rather than
  # `data.azurerm_client_config.current`. main.tf removed the root client_config
  # on purpose and variables.tf says why: the tenant is "pinned rather than read
  # from the ambient az context". That matters more here than anywhere else —
  # this file writes identity into two other repos, and deriving it from
  # whichever tenant `az` happened to be pointed at is precisely the bug that
  # has bitten this build four times. An explicit variable cannot drift with a
  # shell context.
  school_tenant_id = var.tenant_id
  subscription_id  = var.subscription_id
}

# ══════════════════════════════════════════════════════════════════════════════
# Sentinel (backend) — secrets
# ══════════════════════════════════════════════════════════════════════════════

# Not strictly a credential, but it is read in the same breath as the credential
# pair by the §6.4 `container:` block, and splitting one three-line block across
# `secrets.` and `vars.` invites exactly one typo.
resource "github_actions_secret" "sentinel_acr_login_server" {
  count           = local.repo_config
  repository      = "Sentinel"
  secret_name     = "ACR_LOGIN_SERVER"
  plaintext_value = module.acr.acr_login_server
}

resource "github_actions_secret" "sentinel_acr_username" {
  count           = local.repo_config
  repository      = "Sentinel"
  secret_name     = "ACR_USERNAME"
  plaintext_value = module.acr.acr_admin_username
}

resource "github_actions_secret" "sentinel_acr_password" {
  count           = local.repo_config
  repository      = "Sentinel"
  secret_name     = "ACR_PASSWORD"
  plaintext_value = module.acr.acr_admin_password
}

# ══════════════════════════════════════════════════════════════════════════════
# Sentinel (backend) — variables
# ══════════════════════════════════════════════════════════════════════════════

# The UAMI's client id. NOT azuread_application.sentinel_gha — rev-9 deleted that
# object. The school tenant sets allowedToCreateApps: false, so the CI identity
# is a user-assigned managed identity carrying federated credentials; azure/login
# cannot tell the two apart, but Terraform very much can.
resource "github_actions_variable" "sentinel_azure_client_id" {
  count         = local.repo_config
  repository    = "Sentinel"
  variable_name = "AZURE_CLIENT_ID"
  value         = azurerm_user_assigned_identity.sentinel_gha.client_id
}

resource "github_actions_variable" "sentinel_azure_tenant_id" {
  count         = local.repo_config
  repository    = "Sentinel"
  variable_name = "AZURE_TENANT_ID"
  value         = local.school_tenant_id
}

resource "github_actions_variable" "sentinel_azure_subscription_id" {
  count         = local.repo_config
  repository    = "Sentinel"
  variable_name = "AZURE_SUBSCRIPTION_ID"
  value         = local.subscription_id
}

# ── The identity tenant (R4) ─────────────────────────────────────────────────
# §4.5 has the backend workflows perform a SECOND azure/login — as
# sentinel-gha-client, in the identity tenant, with allow-no-subscriptions — to
# mint the bearer token the backend API validates. §5 pushed that identity
# nowhere at all, so the login could not be written. Added 2026-08-24.
#
# Note what is NOT here: no client secret. sentinel-gha-client authenticates by
# federated credential from the same GitHub OIDC issuer as the UAMI, so the
# second tenant costs an app registration and zero stored credentials.

resource "github_actions_variable" "sentinel_identity_tenant_id" {
  count         = local.repo_config
  repository    = "Sentinel"
  variable_name = "AZURE_IDENTITY_TENANT_ID"
  value         = var.identity_tenant_id
}

resource "github_actions_variable" "sentinel_gha_client_id" {
  count         = local.repo_config
  repository    = "Sentinel"
  variable_name = "AZURE_GHA_CLIENT_ID"
  value         = azuread_application.sentinel_gha_client.client_id
}

# Read off the application rather than rebuilt from a template string, so this
# cannot drift from what Entra actually accepts. The value is
# api://<identity-tenant-id>/sentinel-backend — §5.4 prose said the bare
# api://sentinel-backend, which new tenants reject outright with
# InvalidUniqueTenantIdentifierAsPerAppPolicy.
#
# `one()` because identifier_uris is a set: it returns the single element and
# fails loudly if a second URI is ever added, which is better than [0] silently
# picking whichever one the set happened to order first.
resource "github_actions_variable" "sentinel_api_audience" {
  count         = local.repo_config
  repository    = "Sentinel"
  variable_name = "SENTINEL_API_AUDIENCE"
  value         = one(azuread_application.sentinel_backend.identifier_uris)
}

# ══════════════════════════════════════════════════════════════════════════════
# Sentinel-deployment — variables only
# ══════════════════════════════════════════════════════════════════════════════
# No ACR credential: the deployment repo builds no image. It deploys a Python app
# to App Service from source and only needs to authenticate to Azure.
#
# It also gets no identity-tenant values — it never calls the backend API, it
# only generates the Datadog signal that reaches the backend through Event Grid.

resource "github_actions_variable" "deployment_azure_client_id" {
  count         = local.repo_config
  repository    = "Sentinel-deployment"
  variable_name = "AZURE_CLIENT_ID"
  value         = azurerm_user_assigned_identity.sentinel_gha.client_id
}

resource "github_actions_variable" "deployment_azure_tenant_id" {
  count         = local.repo_config
  repository    = "Sentinel-deployment"
  variable_name = "AZURE_TENANT_ID"
  value         = local.school_tenant_id
}

resource "github_actions_variable" "deployment_azure_subscription_id" {
  count         = local.repo_config
  repository    = "Sentinel-deployment"
  variable_name = "AZURE_SUBSCRIPTION_ID"
  value         = local.subscription_id
}

# NOTE: there is deliberately no DB_PASSWORD anywhere in this file, and adding
# one would be a defect. Postgres is Entra-only; the deployment pipeline's Record
# step and the backend both mint a short-lived token with
# `az account get-access-token --resource-type oss-rdbms`. There is no password
# in existence to distribute.
