variable "resource_group_name" {
  description = "Resource group to create the server in. Supplied by the root from data.azurerm_resource_group.sentinel.name."
  type        = string
}

variable "location" {
  description = "Azure region. Supplied by the root from var.location — no default anywhere (R3)."
  type        = string
}

variable "server_name" {
  description = "Globally unique server name — it becomes <name>.postgres.database.azure.com. A variable rather than a literal so a collision is a tfvars change; the unsuffixed `sentinel-pg` was already taken by another tenant."
  type        = string
  default     = "sentinel-pg-0375"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.server_name))
    error_message = "server_name must be 3-63 chars, lowercase alphanumeric or hyphen, and cannot start or end with a hyphen."
  }
}

variable "postgres_entra_admin_object_id" {
  description = "Object ID of the human Entra principal that administers the server (break-glass, and the principal that runs pgaadauth_create_principal for the other roles)."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$", var.postgres_entra_admin_object_id))
    error_message = "postgres_entra_admin_object_id must be a GUID (an object ID, not a UPN)."
  }
}

variable "postgres_entra_admin_principal_name" {
  description = "UPN of that principal, e.g. you@uwindsor.ca. Azure requires it to match the object ID."
  type        = string
}

# Deferred to phase 3 task 3.1 — the backend UAMI does not exist until the AKS
# module creates it. `null` keeps the module's contract complete while the second
# administrator resource stays count-guarded to zero; phase 3 supplies the real
# value and the admin appears with no edit to this module.
variable "backend_uami_principal_id" {
  description = "Principal ID of the backend pod's workload-identity UAMI. null until phase 3 task 3.1 creates it."
  type        = string
  default     = null
}
