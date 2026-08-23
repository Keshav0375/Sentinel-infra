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
  registry_name       = var.registry_name
}

module "postgresql" {
  source              = "./modules/postgresql"
  resource_group_name = data.azurerm_resource_group.sentinel.name
  location            = var.location

  server_name                         = var.postgres_server_name
  tenant_id                           = var.tenant_id
  postgres_entra_admin_object_id      = var.postgres_entra_admin_object_id
  postgres_entra_admin_principal_name = var.postgres_entra_admin_principal_name

  # Flipped by task 3.1: the backend workload identity becomes the second Entra
  # administrator. The bool is literal (plan-time known); the principal id may be
  # unknown on the apply that creates the UAMI — that split is the point.
  enable_backend_admin      = true
  backend_uami_principal_id = module.aks.backend_identity_principal_id
}

module "keyvault" {
  source              = "./modules/keyvault"
  resource_group_name = data.azurerm_resource_group.sentinel.name
  location            = var.location

  vault_name = var.key_vault_name
  tenant_id  = var.tenant_id

  # The human operator who seeds secrets — explicit, so the assignment does not
  # follow whoever happened to run apply.
  kv_admin_object_id = var.kv_admin_object_id

  # The UAMI's principalId, NOT its clientId — a role assignment needs the
  # service principal's object id.
  gha_principal_id = azurerm_user_assigned_identity.sentinel_gha.principal_id

  # Flipped by task 3.1: the backend pod reads LLM keys via workload identity.
  enable_backend_reader     = true
  backend_uami_principal_id = module.aks.backend_identity_principal_id

  # Flipped by task 3.3: the bridge's KV reference cannot resolve without it.
  enable_bridge_reader = true
  bridge_principal_id  = module.functions.bridge_principal_id

  # enable_rotator_officer stays false until task 3.6 creates the rotator.
}
module "aks" {
  source              = "./modules/aks"
  resource_group_name = data.azurerm_resource_group.sentinel.name
  location            = var.location
  acr_id              = module.acr.acr_id
  gha_principal_id    = azurerm_user_assigned_identity.sentinel_gha.principal_id
}
module "event_grid" {
  source              = "./modules/event-grid"
  resource_group_name = data.azurerm_resource_group.sentinel.name
  location            = var.location
  topic_name          = var.event_topic_name
  function_app_id     = module.functions.function_app_id
}
module "functions" {
  source = "./modules/functions"
  # NOT sentinel-rg: Y1 (Dynamic/Linux) cannot share a resource group with the
  # F1 (Dedicated/Linux) plan already there — see oidc.tf.
  resource_group_name  = data.azurerm_resource_group.functions.name
  location             = var.location
  storage_account_name = var.functions_storage_name
  bridge_name          = var.bridge_name
  key_vault_name       = var.key_vault_name
}
module "app_service" {
  source              = "./modules/app-service"
  resource_group_name = data.azurerm_resource_group.sentinel.name
  location            = var.location
  app_name            = var.dummy_api_name
}
