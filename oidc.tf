# ─────────────────────────────────────────────────────────────────────────────
# Identity plane — passwordless GitHub → Azure auth (architecture/infra.md §4.2).
#
# The CI identity is a USER-ASSIGNED MANAGED IDENTITY, not an app registration.
# The subscription lives in the uwindsor.ca tenant, where `allowedToCreateApps`
# is false at tenant policy — no app registration can be created there at all.
# A UAMI is an ordinary Azure resource governed by RBAC, and it carries federated
# identity credentials exactly like an app registration does. `azure/login@v2`
# cannot tell the two apart.
#
# Everything here lives in the SCHOOL tenant. The two backend-API app
# registrations live in a separate personally-owned tenant and are declared in
# identity.tf at phase 3 task 3.5 — do not mix them into this file.
#
# The five credentials below are written out explicitly rather than with
# for_each. They are uniform enough that for_each is tempting, but the two
# Sentinel-infra ones are IMPORTED BY HAND at the bootstrap seam (§4.3.1) — the
# other three Terraform creates itself — and
# `azurerm_federated_identity_credential.gha["sentinel_infra_main"]` needs shell
# quoting that breaks differently in bash and PowerShell. Explicit addresses keep
# the one manual step in this repo hard to get wrong; that is worth more than
# saving twenty lines.
# ─────────────────────────────────────────────────────────────────────────────

locals {
  # Must match backend.tf exactly. A backend block cannot interpolate variables,
  # so the storage account name is unavoidably written in two places — this is
  # the second. Change them together.
  state_storage_account_id = "/subscriptions/${var.subscription_id}/resourceGroups/sentinel-state-rg/providers/Microsoft.Storage/storageAccounts/sentineltfstate0375"

  github_oidc_issuer = "https://token.actions.githubusercontent.com"
  entra_audience     = ["api://AzureADTokenExchange"]
}

# The CI identity itself. Created by scripts/bootstrap-oidc.sh and imported —
# Terraform cannot create the identity its own pipeline authenticates as.
resource "azurerm_user_assigned_identity" "sentinel_gha" {
  name                = "sentinel-gha"
  resource_group_name = data.azurerm_resource_group.sentinel.name
  location            = var.location
}

# Contributor over the whole resource group: CI manages every Sentinel resource.
#
# NOTE: no `skip_service_principal_aad_check` here, deliberately. That flag guards
# the PrincipalNotFound race when Terraform creates a role assignment against a
# service principal that has not finished replicating — but these two assignments
# are ALWAYS created by scripts/bootstrap-oidc.sh and only imported by Terraform,
# including after a ci_destroy_infra rebuild, so the race cannot occur. It is also
# create-only in the provider: setting it on an imported assignment plans as an
# in-place update that then fails with "doesn't support update".
#
# Phase 2/3 role assignments (AcrPull, Key Vault) DO create against fresh
# identities and should set it.
resource "azurerm_role_assignment" "gha_contributor" {
  scope                = data.azurerm_resource_group.sentinel.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.sentinel_gha.principal_id
}

# Terraform state lives in sentinel-state-rg, OUTSIDE the Contributor scope
# above. backend.tf authenticates to the blob with an Entra token
# (use_azuread_auth), and control-plane rights grant no data-plane access — so
# without this assignment every CI `terraform init` fails with a 403 that reads
# like broken backend config rather than a missing role.
resource "azurerm_role_assignment" "gha_state_blob" {
  scope                = local.state_storage_account_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.sentinel_gha.principal_id
}

# R5 (2026-08-15). Contributor CANNOT create role assignments — its notActions
# include Microsoft.Authorization/*/Write and /Delete. Phases 2-3 declare six
# Terraform-managed assignments (Key Vault Secrets Officer/User, AcrPull, AKS
# Cluster User), so without this the first CI apply that touches any of them dies
# with AuthorizationFailed, and ci_destroy_infra cannot tear them down either.
#
# Phase 1 never caught this because every apply so far ran locally as subscription
# Owner. CI has not exercised this identity once.
#
# "Role Based Access Control Administrator" rather than Owner or User Access
# Administrator: its built-in definition carries an ABAC condition forbidding the
# assignment of Owner, User Access Administrator and RBAC Administrator itself.
# The identity can therefore grant the roles the modules need but cannot escalate
# its own privileges — which matters because these credentials are reachable from
# pull_request-triggered workflows on a public repo.
resource "azurerm_role_assignment" "gha_rbac_admin" {
  scope                = data.azurerm_resource_group.sentinel.id
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = azurerm_user_assigned_identity.sentinel_gha.principal_id
}

# ci_destroy_infra (§7.3) finishes with `az group delete --name sentinel-state-rg`.
# The data-plane grant above covers blobs inside the account and nothing else, so
# the delete would fail — silently, since §7.3 masks it with `|| true` — leaving
# the state account behind on every teardown.
#
# TENSION, accepted knowingly: this hands CI the ability to delete the very state
# that protects it, which is exactly what putting state in its own resource group
# was meant to guard against. The isolation still holds for the case that matters
# — `terraform destroy` cannot delete the state describing the run in progress —
# but the "everything, always" teardown is a deliberate, separate, final step.
resource "azurerm_role_assignment" "gha_state_rg_contributor" {
  scope                = "/subscriptions/${var.subscription_id}/resourceGroups/sentinel-state-rg"
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.sentinel_gha.principal_id
}

# ── Federated credentials ─────────────────────────────────────────────────────
# Children of the UAMI, so plain Azure resources under RBAC rather than directory
# objects. A managed identity accepts up to 20; we use 5.
#
# `subject` is matched by Azure as an exact, CASE-SENSITIVE string and cannot be
# wildcarded. Both facts matter: the owner casing `Keshav0375` is load bearing
# (a wrong case fails at login with no diff to inspect), and the absence of
# wildcards is deliberate — the blast radius of a compromised workflow is one
# branch of one repo.

resource "azurerm_federated_identity_credential" "sentinel_infra_main" {
  name                      = "sentinel-infra-main"
  user_assigned_identity_id = azurerm_user_assigned_identity.sentinel_gha.id
  audience                  = local.entra_audience
  issuer                    = local.github_oidc_issuer
  subject                   = "repo:${var.github_owner}/Sentinel-infra:ref:refs/heads/main"
}

resource "azurerm_federated_identity_credential" "sentinel_infra_pr" {
  name                      = "sentinel-infra-pr"
  user_assigned_identity_id = azurerm_user_assigned_identity.sentinel_gha.id
  audience                  = local.entra_audience
  issuer                    = local.github_oidc_issuer
  subject                   = "repo:${var.github_owner}/Sentinel-infra:pull_request"
}

resource "azurerm_federated_identity_credential" "sentinel_main" {
  name                      = "sentinel-main"
  user_assigned_identity_id = azurerm_user_assigned_identity.sentinel_gha.id
  audience                  = local.entra_audience
  issuer                    = local.github_oidc_issuer
  subject                   = "repo:${var.github_owner}/Sentinel:ref:refs/heads/main"
}

resource "azurerm_federated_identity_credential" "sentinel_pr" {
  name                      = "sentinel-pr"
  user_assigned_identity_id = azurerm_user_assigned_identity.sentinel_gha.id
  audience                  = local.entra_audience
  issuer                    = local.github_oidc_issuer
  subject                   = "repo:${var.github_owner}/Sentinel:pull_request"
}

resource "azurerm_federated_identity_credential" "sentinel_deployment_main" {
  name                      = "sentinel-deployment-main"
  user_assigned_identity_id = azurerm_user_assigned_identity.sentinel_gha.id
  audience                  = local.entra_audience
  issuer                    = local.github_oidc_issuer
  subject                   = "repo:${var.github_owner}/Sentinel-deployment:ref:refs/heads/main"
}
