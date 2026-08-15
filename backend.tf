# ─────────────────────────────────────────────────────────────────────────────
# Remote state (architecture/infra.md §8.1).
#
# State lives in its OWN resource group, not sentinel-rg, so that
# ci_destroy_infra's `terraform destroy` + `az group delete` cannot destroy the
# state that describes what it is destroying.
#
# Auth is Entra, not a storage access key:
#   use_azuread_auth  — reach the blob with a token
#   use_oidc          — in CI that token comes from the GitHub OIDC exchange
#
# This is why the sentinel-gha identity needs `Storage Blob Data Contributor` on
# the storage account (oidc.tf, task 1.3): the state account sits outside the
# Contributor assignment scoped to sentinel-rg. Note that Owner on the
# subscription does NOT imply blob data access — control plane and data plane are
# separate in Azure RBAC, so a human running this locally needs the same grant.
#
# subscription_id / tenant_id / client_id are deliberately absent: a backend block
# cannot interpolate variables, so they arrive as ARM_* env vars. The same file
# therefore works locally (`az login`) and in CI (federated token).
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  backend "azurerm" {
    resource_group_name  = "sentinel-state-rg"
    storage_account_name = "sentineltfstate"
    container_name       = "tfstate"
    key                  = "sentinel.terraform.tfstate"

    use_azuread_auth = true
    use_oidc         = true
  }
}
