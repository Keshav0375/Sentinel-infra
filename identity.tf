# ─────────────────────────────────────────────────────────────────────────────
# Per-deployment app registrations, in the IDENTITY tenant (R4).
#
# ── Why per-deployment and not one shared API ────────────────────────────────
# Each deployment gets its own backend API app, so its audience is its own:
#
#   api://<identity-tenant>/sentinel-backend-demo1-dev
#   api://<identity-tenant>/sentinel-backend-demo2-dev
#
# A token minted for one deployment therefore FAILS audience validation at
# another's backend. With a single shared app every deployment would validate the
# same audience, and the API layer would have no isolation at all while the
# namespaces beneath it did — the weakest link deciding the property.
#
# ── Why they are in a separate tenant ────────────────────────────────────────
# The school tenant sets `allowedToCreateApps: false` at policy, so no app
# registration can be created there by anyone. Everything else — every resource,
# every managed identity — stays school-side, because they hold RBAC on school
# resources.
#
# ── OFF by default, deliberately ─────────────────────────────────────────────
# `api_identity` is not in `defaults.components`. Two reasons:
#
#   1. Nothing consumes these yet. The backend that would validate the token is
#      not built, so an app registration per deployment would be directory
#      clutter with no reader.
#   2. Creating them from CI needs federated credentials on `sentinel-tf-identity`
#      for `environment:plan|production|destroy` — an interactive cross-tenant
#      login that has not happened. Locally it works, because the school account
#      is a redeemed guest holding Application Administrator there.
#
# Turn it on per deployment when the backend phase needs it. Until then a
# deployment is complete without it.
# ─────────────────────────────────────────────────────────────────────────────

locals {
  c_api_identity = (local.is_deployment && contains(local.components, "api_identity")) ? 1 : 0
}

# The API the backend exposes. `Incident.Write` is an APPLICATION role, not a
# delegated scope: the caller is a workflow, not a signed-in human.
resource "azuread_application" "backend_api" {
  provider = azuread.identity
  count    = local.c_api_identity

  display_name = module.naming.names.api_app_name
  owners       = [data.azuread_client_config.identity[0].object_id]

  # Tenant-qualified, and not stylistically. New Entra tenants reject the bare
  # `api://<name>` form with InvalidUniqueTenantIdentifierAsPerAppPolicy —
  # found live 2026-08-23.
  identifier_uris = [module.naming.names.api_identifier_uri]

  app_role {
    id                   = "11111111-1111-1111-1111-111111111111"
    allowed_member_types = ["Application"]
    description          = "Permits dispatching an incident to the Sentinel backend."
    display_name         = "Incident.Write"
    value                = "Incident.Write"
    enabled              = true
  }
}

resource "azuread_service_principal" "backend_api" {
  provider  = azuread.identity
  count     = local.c_api_identity
  client_id = azuread_application.backend_api[0].client_id
}

# The caller. It authenticates by FEDERATED CREDENTIAL from the same GitHub OIDC
# issuer the infra identities use — so the second tenant costs an app
# registration and zero stored secrets. §4.5's "second azure/login" is this.
resource "azuread_application" "gha_client" {
  provider = azuread.identity
  count    = local.c_api_identity

  display_name = module.naming.names.gha_client_name
  owners       = [data.azuread_client_config.identity[0].object_id]
}

resource "azuread_service_principal" "gha_client" {
  provider  = azuread.identity
  count     = local.c_api_identity
  client_id = azuread_application.gha_client[0].client_id
}

# PER-DEPLOYMENT subject. A shared subject would let deployment A's workflow mint
# a token for deployment B — the isolation would exist in the audience and be
# undone at the credential.
resource "azuread_application_federated_identity_credential" "gha_client" {
  provider       = azuread.identity
  count          = local.c_api_identity
  application_id = azuread_application.gha_client[0].id
  display_name   = "gha-${module.naming.names.kubernetes_namespace}"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${var.github_owner}/Sentinel:environment:${module.naming.names.kubernetes_namespace}"
}

# Grants the caller the role. An app-role assignment is a within-tenant
# directory operation with no cross-tenant form, which is exactly why the caller
# had to be an app registration here rather than a school-tenant managed identity.
resource "azuread_app_role_assignment" "gha_incident_write" {
  provider            = azuread.identity
  count               = local.c_api_identity
  app_role_id         = "11111111-1111-1111-1111-111111111111"
  principal_object_id = azuread_service_principal.gha_client[0].object_id
  resource_object_id  = azuread_service_principal.backend_api[0].object_id
}

data "azuread_client_config" "identity" {
  provider = azuread.identity
  count    = local.c_api_identity
}
