# ─────────────────────────────────────────────────────────────────────────────
# Identity plane — the ONLY directory objects in the project (§4.4, R4).
#
# Every resource here targets the IDENTITY tenant (personally owned), never the
# school tenant: uwindsor.ca denies app registration at tenant policy
# (allowedToCreateApps: false, proven via Graph), and only an app registration
# can DEFINE an API audience and app role — a managed identity can hold a role,
# never define one. The file boundary IS the tenant boundary: nothing in any
# other .tf file may use this provider.
#
# Auth: locally, az CLI as the guest-invited school account (Application
# Administrator in the identity tenant); in CI, the provider's own GitHub OIDC
# exchange as sentinel-tf-identity. NO stored secret in either mode.
# ─────────────────────────────────────────────────────────────────────────────

provider "azuread" {
  alias     = "identity"
  tenant_id = var.identity_tenant_id
  client_id = var.identity_client_id
  use_oidc  = var.identity_use_oidc
}

# ── 1. The API: the audience callers request, and the role they must hold ─────
resource "azuread_application" "sentinel_backend" {
  provider     = azuread.identity
  display_name = "sentinel-backend-api"

  # Tenant-qualified, NOT the architecture's original bare `api://sentinel-backend`:
  # new Entra tenants enforce InvalidUniqueTenantIdentifierAsPerAppPolicy — every
  # identifier URI must embed a verified domain, the tenant id, or the app id
  # (found live 2026-08-23). Downstream this is absorbed by design: the audience
  # reaches the backend as SENTINEL_API_AUDIENCE config (task 4.1), never as a
  # literal.
  identifier_uris = ["api://${var.identity_tenant_id}/sentinel-backend"]

  app_role {
    allowed_member_types = ["Application"]
    display_name         = "Incident.Write"
    description          = "Call the incident pipeline and write results"
    value                = "Incident.Write"
    id                   = "11111111-1111-1111-1111-111111111111" # stable — backend 5.6 validates the claim VALUE, but a stable id keeps the assignment import-safe
    enabled              = true
  }
}

resource "azuread_service_principal" "sentinel_backend" {
  provider  = azuread.identity
  client_id = azuread_application.sentinel_backend.client_id
}

# ── 2. The caller ─────────────────────────────────────────────────────────────
# NOT the sentinel-gha UAMI: app-role assignment is a within-tenant directory
# operation with no cross-tenant form, and that UAMI lives in the school tenant.
# Referencing it here fails at apply with a misleading "principal not found".
# The caller is its own registration, federated to the SAME GitHub trust source.
resource "azuread_application" "sentinel_gha_client" {
  provider     = azuread.identity
  display_name = "sentinel-gha-client"
}

resource "azuread_service_principal" "sentinel_gha_client" {
  provider  = azuread.identity
  client_id = azuread_application.sentinel_gha_client.client_id
}

resource "azuread_application_federated_identity_credential" "gha_client_main" {
  provider       = azuread.identity
  application_id = azuread_application.sentinel_gha_client.id
  display_name   = "sentinel-main"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:Keshav0375/Sentinel:ref:refs/heads/main"
}

# ── 3. The grant ──────────────────────────────────────────────────────────────
resource "azuread_app_role_assignment" "gha_incident_write" {
  provider            = azuread.identity
  app_role_id         = "11111111-1111-1111-1111-111111111111"
  principal_object_id = azuread_service_principal.sentinel_gha_client.object_id
  resource_object_id  = azuread_service_principal.sentinel_backend.object_id
}
