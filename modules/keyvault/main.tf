# ─────────────────────────────────────────────────────────────────────────────
# Key Vault (architecture/infra.md §3.3).
#
# Terraform creates the VAULT and the ACCESS, never the SECRET VALUES. There is
# deliberately not a single `azurerm_key_vault_secret` resource here: a secret
# declared in HCL ends up in plaintext in the state file, and the state file is a
# blob other principals can read. The 9 runtime secrets are seeded out of band
# with `az keyvault secret set` (§10 step 7) and rotated by the rotator Function.
#
# This module is also the FIRST thing in the project that exercises R5 — the
# `Role Based Access Control Administrator` grant on sentinel-rg. Contributor
# cannot create role assignments, so if these ever fail in CI with
# AuthorizationFailed, R5 is the diagnosis, not the module.
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

# Module-local: data sources do not inherit across module boundaries.
data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "sentinel" {
  name                = var.vault_name
  resource_group_name = var.resource_group_name
  location            = var.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # RBAC, not access policies (decision 2026-07-04). Access policies are a second,
  # parallel permission system that does not show up in `az role assignment list`
  # — so an auditor reading RBAC would see an incomplete picture of who can read
  # these secrets.
  #
  # NOT `enable_rbac_authorization`: that spelling is deprecated in azurerm v4 and
  # removed in v5. Verified against the pinned 4.81.0 binary.
  rbac_authorization_enabled = true

  # Soft-delete is mandatory on Key Vault — the only choice is how long, and
  # whether a delete can ever be made permanent. Azure defaults to 90 days +
  # purge protection, which would strand this vault's GLOBALLY UNIQUE name for 90
  # days after any `ci_destroy_infra` run and make the "everything, always"
  # rebuild impossible under the same name.
  #
  # 7 days + purge allowed, plus an explicit `az keyvault purge` in §7.3, makes
  # the designed teardown loop actually work. Accepted cost: a mistaken destroy
  # can be purged for real — tolerable precisely because Terraform stores no
  # secret values here. Every one of the 9 secrets is re-seedable from its
  # external source, so the vault holds no unrecoverable state.
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
}

# ── Access ────────────────────────────────────────────────────────────────────
# Officer = read/write secrets. User = read only. The split matters: only the
# human operator and the rotator Function ever need to WRITE, and the two
# runtime consumers (CI, backend pod) are read-only by construction rather than
# by convention.

# The HUMAN operator who seeds the 9 secrets (§10 step 7).
#
# Deliberately NOT `data.azurerm_client_config.current.object_id`, which the
# architecture originally specified. That resolves to whoever ran `apply`: the
# human locally, but the sentinel-gha UAMI in CI. The assignment would then
# flip-flop on every context switch — and the first CI apply would destroy the
# human's Officer rights, leaving nobody able to run §10 step 7. It would also
# silently hand CI write access that §3.3's access table says it must not have.
#
# An explicit id is stable regardless of who applies.
# Renamed from `terraform_kv_admin` when the principal changed from
# "whoever ran apply" to an explicit id. A `moved` block makes this a state
# rename rather than a destroy-then-create, so there is never a window in which
# nobody holds Officer on the vault.
moved {
  from = azurerm_role_assignment.terraform_kv_admin
  to   = azurerm_role_assignment.kv_admin
}

resource "azurerm_role_assignment" "kv_admin" {
  scope                = azurerm_key_vault.sentinel.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = var.kv_admin_object_id
}

# GHA reads secrets at incident-response time (ci_incident_response fetches LLM
# and Datadog keys). Read-only: the pipeline has no reason to write.
resource "azurerm_role_assignment" "gha_kv_reader" {
  scope                = azurerm_key_vault.sentinel.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = var.gha_principal_id

  # Set on assignments Terraform CREATES against a service principal. On a
  # post-ci_destroy_infra rebuild the UAMI is brand new and Entra replication
  # lags, which surfaces as an intermittent PrincipalNotFound. Safe here because
  # this resource is created, never imported — the flag is create-only and fails
  # with "doesn't support update" if added to an existing assignment (infra 1.3).
  skip_service_principal_aad_check = true
}

# ── Deferred to phase 3 ───────────────────────────────────────────────────────
# Same bool-toggle + count pattern as the Postgres backend admin (task 2.2).
# One deferral style across the whole phase, so a reader learns it once.
#
# The toggle is a bool the caller sets, NOT `count = var.principal_id == null`.
# `count` must resolve at plan time; the phase-3 caller passes principal ids that
# are only known after the apply that creates them.

# The backend pod reads LLM keys directly from Key Vault via workload identity —
# which is why no K8s Secret carries them. UAMI created in phase 3 task 3.1.
resource "azurerm_role_assignment" "backend_kv_reader" {
  count = var.enable_backend_reader ? 1 : 0

  scope                            = azurerm_key_vault.sentinel.id
  role_definition_name             = "Key Vault Secrets User"
  principal_id                     = var.backend_uami_principal_id
  skip_service_principal_aad_check = true
}

# The rotator Function writes new versions when SecretNearExpiry fires, so it
# needs Officer rather than User. System-assigned MI created in phase 3 task 3.6.
resource "azurerm_role_assignment" "rotator_kv_officer" {
  count = var.enable_rotator_officer ? 1 : 0

  scope                            = azurerm_key_vault.sentinel.id
  role_definition_name             = "Key Vault Secrets Officer"
  principal_id                     = var.rotator_principal_id
  skip_service_principal_aad_check = true
}
