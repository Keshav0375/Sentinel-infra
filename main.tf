# ─────────────────────────────────────────────────────────────────────────────
# sentinel-infra — root providers and shared data sources.
#
# Resource modules are wired in from phase 2 onward. This file establishes the
# provider contract they all inherit; it creates nothing itself.
# ─────────────────────────────────────────────────────────────────────────────

provider "azurerm" {
  features {}

  # Mandatory under azurerm v4. Taken from a variable rather than ambient
  # ARM_SUBSCRIPTION_ID so that a local run and a CI run resolve identically and
  # a mistake is visible in the plan rather than in the environment.
  subscription_id = var.subscription_id
}

provider "github" {
  token = var.github_pat
  owner = var.github_owner
}

# The identity currently running Terraform: `az login` locally, the sentinel-gha
# user-assigned managed identity via OIDC in CI. Modules read tenant_id from here
# rather than taking it as another input.
data "azurerm_client_config" "current" {}

# READ, never own (conflict C1). sentinel-rg is created out of band by the
# one-time bootstrap (infra.md §10 step 1) and deleted by ci_destroy_infra's
# `az group delete` (§7.3). Were this a managed resource, `terraform destroy`
# would remove it and the follow-up `az group delete` would then fail against a
# group that no longer exists — and the first `apply` would fail too, since the
# bootstrap has already created it.
data "azurerm_resource_group" "sentinel" {
  name = var.resource_group_name
}

# ── Module wiring ─────────────────────────────────────────────────────────────

module "acr" {
  source              = "./modules/acr"
  resource_group_name = data.azurerm_resource_group.sentinel.name
  location            = var.location
}

# module "postgresql"  {}  # phase 2 · task 2.2  (Entra-only auth)
# module "keyvault"    {}  # phase 2 · task 2.3
# module "aks"         {}  # phase 3 · task 3.1  (workload identity)
# module "event_grid"  {}  # phase 3 · task 3.2
# module "functions"   {}  # phase 3 · task 3.3  (Event Grid → GHA bridge)
# module "app_service" {}  # phase 3 · task 3.4  (F1, sentinel-deployment target)
