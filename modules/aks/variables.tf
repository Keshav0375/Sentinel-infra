variable "resource_group_name" {
  description = "Resource group for the cluster and the backend UAMI. Supplied by the root."
  type        = string
}

variable "location" {
  description = "Azure region. Supplied by the root from var.location — no default anywhere (R3)."
  type        = string
}

variable "acr_id" {
  description = "Registry resource id — the scope of the kubelet's AcrPull grant. From module.acr.acr_id."
  type        = string
}

variable "gha_principal_id" {
  description = "Principal ID of the sentinel-gha UAMI (principalId, NOT clientId). Gets Cluster User for az aks get-credentials in CI."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$", var.gha_principal_id))
    error_message = "gha_principal_id must be a GUID — the UAMI's principalId, not its clientId."
  }
}
