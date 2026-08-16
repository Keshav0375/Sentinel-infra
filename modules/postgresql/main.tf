# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL Flexible Server (architecture/infra.md §3.2).
#
# Entra-ONLY authentication. There is no administrator password anywhere in this
# module, in state, or in Key Vault — `password_auth_enabled = false` means one
# cannot exist. Every client presents a short-lived Entra access token (audience
# https://ossrdbms-aad.database.windows.net) as the psql password instead.
#
# B1MS + 32 GB storage + 32 GB backup matches the Azure for Students 12-month
# free grant exactly (750 h/month of Burstable B1MS). Changing the SKU or raising
# storage takes it off the free meter.
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  # Declared per-module rather than inherited. A module that implicitly relies on
  # the root's provider constraints breaks the moment it is consumed from
  # anywhere else, and tflint flags the omission. §2 mandates exactly three files
  # per module, so this lives in main.tf rather than a fourth versions.tf.
  required_version = ">= 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

# Module-local: data sources do NOT inherit across module boundaries, so this
# cannot be read from the root — each module that needs tenant_id declares its own.
data "azurerm_client_config" "current" {}

resource "azurerm_postgresql_flexible_server" "sentinel" {
  name                = var.server_name
  resource_group_name = var.resource_group_name
  location            = var.location

  version    = "16"
  sku_name   = "B_Standard_B1ms"
  storage_mb = 32768
  zone       = "1"

  # No administrator_login / administrator_password. Entra-only (rev-5): a stolen
  # connection string is useless without a live token, and there is no long-lived
  # credential to rotate, leak, or forget to rotate.
  authentication {
    active_directory_auth_enabled = true
    password_auth_enabled         = false

    # Azure populates this server-side the moment an Entra administrator is
    # attached. Omitting it gives a PERPETUAL DIFF: every plan proposes setting
    # tenant_id back to null, which would read as drift forever and train the
    # reader to ignore a non-empty plan.
    tenant_id = data.azurerm_client_config.current.tenant_id
  }
}

# ── Entra administrators ──────────────────────────────────────────────────────
# rev-9: the `sentinel-db-admins` group is gone — creating a group is a directory
# write the uwindsor.ca tenant denies. Admins attach directly instead, one
# resource per principal. Only an Entra admin can create further DB roles via
# pgaadauth_create_principal (§10 step 8), which is how sentinel-gha and the
# backend get their non-admin logins.

# The human owner — break-glass psql access, and the principal that runs
# §10 step 8 to create the other roles.
resource "azurerm_postgresql_flexible_server_active_directory_administrator" "human" {
  server_name         = azurerm_postgresql_flexible_server.sentinel.name
  resource_group_name = var.resource_group_name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  object_id           = var.postgres_entra_admin_object_id
  principal_name      = var.postgres_entra_admin_principal_name
  principal_type      = "User"

  # Entra auth must be ON before any Entra admin can be attached.
  depends_on = [azurerm_postgresql_flexible_server.sentinel]
}

# The backend pod's workload identity. Deferred: the UAMI is created by the AKS
# module in phase 3 task 3.1, so there is nothing to point at yet. The count
# guard lets phase 3 supply the value and have this resource appear as a one-line
# diff, rather than phase 2 shipping a knowingly-incomplete §3.2 or phase 3
# editing this file. Task 2.3 defers its backend/rotator role assignments the
# same way — one pattern for one problem.
resource "azurerm_postgresql_flexible_server_active_directory_administrator" "backend_uami" {
  count = var.backend_uami_principal_id == null ? 0 : 1

  server_name         = azurerm_postgresql_flexible_server.sentinel.name
  resource_group_name = var.resource_group_name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  object_id           = var.backend_uami_principal_id
  principal_name      = "sentinel-backend-wi"
  principal_type      = "ServicePrincipal"

  depends_on = [azurerm_postgresql_flexible_server.sentinel]
}

# ── Database ──────────────────────────────────────────────────────────────────
resource "azurerm_postgresql_flexible_server_database" "sentinel" {
  name      = "sentinel"
  server_id = azurerm_postgresql_flexible_server.sentinel.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# pgvector must be allow-listed at the server before the backend can run
# `CREATE EXTENSION vector` (alembic migration 001). Allow-listing does not
# create the extension — it only permits it.
resource "azurerm_postgresql_flexible_server_configuration" "pgvector" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.sentinel.id
  value     = "VECTOR"
}

# ── Firewall ──────────────────────────────────────────────────────────────────
# Allow-all is deliberate for dev, and safe here for one specific reason
# (§3.2 "Network reach ≠ auth"): password auth is DISABLED on this server, so
# reaching the port gets an attacker nothing without a valid Entra token issued
# to an admin or a pgaadauth-created role. The firewall controls who can *reach*
# the port, not who can *log in*.
#
# Two client classes need reach and neither has a stable IP: GitHub-hosted
# runners (ci_app_deployment records deploys, ci_incident_response fetches
# context) rotate across a wide published range, and the AKS node pool has no
# fixed egress IP without a NAT gateway. Production would use a Private Endpoint
# + VNet integration; that is out of scope for a demo stack and would break the
# GitHub-hosted runners entirely.
#
# tfsec/tflint will flag this rule. Annotate the finding — never silence it.
resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_all_dev" {
  name             = "allow-all-dev"
  server_id        = azurerm_postgresql_flexible_server.sentinel.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "255.255.255.255"
}
