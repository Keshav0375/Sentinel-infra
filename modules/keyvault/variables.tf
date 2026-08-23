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

variable "gha_principal_id" {
  description = "Principal ID of the sentinel-gha UAMI. Read-only access — CI fetches LLM and Datadog keys at incident-response time but never writes."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$", var.gha_principal_id))
    error_message = "gha_principal_id must be a GUID — the UAMI's principalId, NOT its clientId."
  }
}

# Deferred to phase 3, same pattern as the Postgres backend admin (task 2.2).
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
