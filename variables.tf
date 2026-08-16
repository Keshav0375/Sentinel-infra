# ─────────────────────────────────────────────────────────────────────────────
# Root input variables.
#
# These names are a long-lived contract: every module in phases 2-4 consumes
# them. Renaming one later is a breaking change across the whole repo.
#
# Deliberately absent:
#   db_password                            — Postgres is Entra-only (rev-5)
#   postgres_entra_admin_group_object_id   — the sentinel-db-admins group was
#                                            removed in rev-9; admins attach directly
# ─────────────────────────────────────────────────────────────────────────────

variable "subscription_id" {
  description = "Azure subscription that hosts every Sentinel resource. Required by the azurerm v4 provider."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a 36-character GUID."
  }
}

# NO DEFAULT, on purpose (R3). A silently defaulted region is a mistake that
# propagates into every resource name and cannot be changed without a full
# teardown. Resolved 2026-08-15 to canadacentral, supplied via the AZURE_LOCATION
# GitHub variable in CI and terraform.tfvars locally — never hardcoded here.
variable "location" {
  description = "Azure region for all resources, e.g. canadacentral. No default: see R3."
  type        = string

  validation {
    condition     = length(trimspace(var.location)) > 0
    error_message = "location must be set explicitly; it has no default."
  }
}

variable "resource_group_name" {
  description = "Resource group holding every Sentinel resource. Created by the bootstrap, read as a data source."
  type        = string
  default     = "sentinel-rg"
}

variable "postgres_entra_admin_object_id" {
  description = "Object ID of the human Entra principal that administers PostgreSQL (break-glass). From `az ad signed-in-user show --query id`."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$", var.postgres_entra_admin_object_id))
    error_message = "postgres_entra_admin_object_id must be a 36-character GUID (an object ID, not a UPN)."
  }
}

variable "postgres_entra_admin_principal_name" {
  description = "UPN of that principal, e.g. you@uwindsor.ca. Must match the object ID above."
  type        = string
}

variable "github_owner" {
  description = "GitHub owner for the three Sentinel repos. Case-sensitive — OIDC federated-credential subjects are matched exactly."
  type        = string
  default     = "Keshav0375"

  validation {
    condition     = var.github_owner == "Keshav0375"
    error_message = "github_owner must be exactly 'Keshav0375'. It is interpolated into all five federated-credential subjects, and Azure matches those case-sensitively — so 'keshav0375' or the old placeholder 'keshxvDev' would produce a login that fails with no diff to inspect. This guard is a typo catcher, not a policy: to genuinely change owner, update it here and in docs/BOOTSTRAP.md together."
  }
}

variable "github_pat" {
  description = "GitHub PAT with `repo` scope, used to push variables/secrets to the sibling repos (phase 4) and by the Function bridge. In CI this is the GH_PAT secret — GitHub reserves the GITHUB_ prefix."
  type        = string
  sensitive   = true
}
