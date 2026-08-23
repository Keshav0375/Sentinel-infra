variable "resource_group_name" {
  description = "Resource group to create the vault in. Supplied by the root from data.azurerm_resource_group.sentinel.name."
  type        = string
}

variable "location" {
  description = "Azure region. Supplied by the root from var.location — no default anywhere (R3)."
  type        = string
}

variable "vault_name" {
  description = "Globally unique vault name — it becomes <name>.vault.azure.net. A variable rather than a literal so a collision is a tfvars change; the unsuffixed `sentinel-kv` was already taken by another tenant."
  type        = string
  default     = "sentinel-kv-0375"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]$", var.vault_name))
    error_message = "vault_name must be 3-24 chars, alphanumeric or hyphen, start with a letter and not end with a hyphen."
  }
}

variable "kv_admin_object_id" {
  description = "Object ID of the HUMAN operator who seeds secrets (§10 step 7). Explicit rather than data.azurerm_client_config.current.object_id, which would resolve to the CI identity when CI applies and destroy the human's access."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$", var.kv_admin_object_id))
    error_message = "kv_admin_object_id must be a GUID (an object ID, not a UPN)."
  }
}

variable "gha_principal_id" {
  description = "Principal ID of the sentinel-gha UAMI. Read-only access — CI fetches LLM and Datadog keys at incident-response time but never writes."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$", var.gha_principal_id))
    error_message = "gha_principal_id must be a GUID — the UAMI's principalId, NOT its clientId."
  }
}

# Deferred to phase 3, same pattern as the Postgres backend admin (task 2.2).
# Bool toggles rather than null-checks: `count` must resolve at PLAN time, and
# the phase-3 caller passes ids that are only known after apply.
variable "enable_backend_reader" {
  description = "Whether to grant the backend UAMI read access. Set true by the root from phase 3 task 3.1 onward."
  type        = bool
  default     = false
}

variable "enable_rotator_officer" {
  description = "Whether to grant the rotator Function write access. Set true by the root from phase 3 task 3.6 onward."
  type        = bool
  default     = false
}

variable "backend_uami_principal_id" {
  description = "Principal ID of the backend pod's workload-identity UAMI. null until phase 3 task 3.1 creates it."
  type        = string
  default     = null
}

variable "rotator_principal_id" {
  description = "Principal ID of the rotator Function's system-assigned identity. null until phase 3 task 3.6 creates it."
  type        = string
  default     = null
}
