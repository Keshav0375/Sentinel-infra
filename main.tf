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

# NOTE: there is deliberately no root-level `data "azurerm_client_config"`.
# Data sources do not inherit across module boundaries, so each module that needs
# tenant_id declares its own (see modules/postgresql, modules/keyvault). A root
# copy was carried through phase 1 and never referenced — tflint flagged it as
# dead, correctly, so it was removed rather than kept on the promise of a later
# consumer. If task 4.1 needs it for the AZURE_TENANT_ID distribution, it is one
# block to add back.

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

module "postgresql" {
  source              = "./modules/postgresql"
  resource_group_name = data.azurerm_resource_group.sentinel.name
  location            = var.location

  postgres_entra_admin_object_id      = var.postgres_entra_admin_object_id
  postgres_entra_admin_principal_name = var.postgres_entra_admin_principal_name

  # backend_uami_principal_id is deliberately not passed — it defaults to null
  # and the second Entra administrator stays count-guarded to 0 until phase 3
  # task 3.1 creates the backend UAMI.
}

# module "keyvault"    {}  # phase 2 · task 2.3
# module "aks"         {}  # phase 3 · task 3.1  (workload identity)
# module "event_grid"  {}  # phase 3 · task 3.2
# module "functions"   {}  # phase 3 · task 3.3  (Event Grid → GHA bridge)
# module "app_service" {}  # phase 3 · task 3.4  (F1, sentinel-deployment target)
