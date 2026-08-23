# ─────────────────────────────────────────────────────────────────────────────
# Functions — the Event Grid → GitHub Actions bridge (architecture/infra.md §3.5).
#
# The bridge is the seam between "Azure noticed something" and "GitHub Actions
# acts on it": Event Grid delivers the Datadog event, the function classifies it
# into one of the two signals and fires repository_dispatch. It is deliberately
# a messenger — HITL means GHA executes, never this function.
#
# The rotator (task 3.6) shares this module and this Y1 plan.
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

# Mandatory backing storage for the Consumption plan. Globally unique →
# 0375 convention (the architecture referenced this account but never named it).
resource "azurerm_storage_account" "func" {
  name                     = var.storage_account_name
  location                 = var.location
  resource_group_name      = var.resource_group_name
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
}

resource "azurerm_service_plan" "functions" {
  name                = "sentinel-func-plan"
  location            = var.location
  resource_group_name = var.resource_group_name
  os_type             = "Linux"
  sku_name            = "Y1" # Consumption — 1M executions/mo always free
}

# The function code ships with the infrastructure. There is no CI workflow for
# function code (infra ships three workflows, none of them deploys functions —
# R6 review), and an app with no code would fail Event Grid's endpoint
# validation when task 3.2 creates the subscription. Zip + remote Oryx build
# keeps the module self-contained; the zip hash retriggers deploy on src change.
data "archive_file" "bridge" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/dist/bridge.zip"
  excludes    = ["rotate"] # task 3.6 adds the rotator's own app + zip
}

resource "azurerm_linux_function_app" "bridge" {
  name                = var.bridge_name
  location            = var.location
  resource_group_name = var.resource_group_name
  service_plan_id     = azurerm_service_plan.functions.id

  storage_account_name       = azurerm_storage_account.func.name
  storage_account_access_key = azurerm_storage_account.func.primary_access_key

  # REQUIRED: GITHUB_TOKEN below is a Key Vault *reference*. Without an identity
  # holding Secrets User on the vault it resolves EMPTY — silently — and the
  # bridge 401s at runtime with nothing pointing at the cause. The keyvault
  # module's enable_bridge_reader grant targets this principal.
  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_stack {
      python_version = "3.12"
    }
  }

  app_settings = {
    "GITHUB_TOKEN"      = "@Microsoft.KeyVault(VaultName=${var.key_vault_name};SecretName=github-pat)"
    "GITHUB_REPO"       = "Keshav0375/Sentinel"
    "GITHUB_EVENT_TYPE" = "incident-alert"

    # Remote build: Oryx installs requirements.txt during zip deploy. Do NOT set
    # WEBSITE_RUN_FROM_PACKAGE alongside these — they are mutually exclusive.
    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "true"
    "ENABLE_ORYX_BUILD"              = "true"
  }

  zip_deploy_file = data.archive_file.bridge.output_path
}

# ── Rotator (task 3.6) ────────────────────────────────────────────────────────
data "archive_file" "rotator" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/dist/rotator.zip"
  excludes    = ["bridge"]
}

# Second app on the same Y1 plan. SystemAssigned: this identity is the only
# WRITE principal on the vault besides the human operator (Secrets Officer via
# enable_rotator_officer). TEAMS_WEBHOOK_URL is a Key Vault reference — Officer
# includes read, so it resolves through the same grant.
resource "azurerm_linux_function_app" "rotator" {
  name                = var.rotator_name
  location            = var.location
  resource_group_name = var.resource_group_name
  service_plan_id     = azurerm_service_plan.functions.id

  storage_account_name       = azurerm_storage_account.func.name
  storage_account_access_key = azurerm_storage_account.func.primary_access_key

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_stack {
      python_version = "3.12"
    }
  }

  app_settings = {
    "KEY_VAULT_URI"     = "https://${var.key_vault_name}.vault.azure.net/"
    "KEY_VAULT_NAME"    = var.key_vault_name
    "TEAMS_WEBHOOK_URL" = "@Microsoft.KeyVault(VaultName=${var.key_vault_name};SecretName=teams-webhook-url)"
    # ANTHROPIC_ADMIN_KEY is deliberately NOT configured: no admin key exists
    # among the 9 seeded secrets, so the rotator escalates to Teams (its manual
    # path) rather than pretending it can mint. Set it later to enable
    # auto-rotation without any code change.

    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "true"
    "ENABLE_ORYX_BUILD"              = "true"
  }

  zip_deploy_file = data.archive_file.rotator.output_path
}
