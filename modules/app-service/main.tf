# ─────────────────────────────────────────────────────────────────────────────
# App Service — the TARGET app (architecture/infra.md §3.6).
#
# Hosts dummy-api-0375, the deliberately-breakable FastAPI app from the
# Sentinel-deployment repo. Its deploys and failures are what generate the real
# Datadog signal the whole incident pipeline runs on. Terraform provisions the
# plan + empty web app; code arrives via ci_app_deployment.yml (deployment
# phase 2), never from here.
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

resource "azurerm_service_plan" "deployment" {
  name                = "sentinel-deploy-plan"
  location            = var.location
  resource_group_name = var.resource_group_name
  os_type             = "Linux"
  sku_name            = "F1" # always-free tier: 60 CPU-min/day, 1 GB — the real ceiling for the 30-scenario runs
}

resource "azurerm_linux_web_app" "dummy_api" {
  name                = var.app_name
  location            = var.location
  resource_group_name = var.resource_group_name
  service_plan_id     = azurerm_service_plan.deployment.id

  site_config {
    # Hard F1 constraints, not preferences: the tier rejects Always On (and
    # azurerm defaults it to true → apply fails without this) and only offers a
    # 32-bit worker.
    always_on         = false
    use_32_bit_worker = true

    application_stack {
      python_version = "3.12"
    }

    # Deployment §2.5's startup command — gunicorn wrapping uvicorn workers.
    app_command_line = "gunicorn --bind=0.0.0.0 --timeout 600 -k uvicorn.workers.UvicornWorker app.main:app"
  }

  app_settings = {
    "APP_VERSION"                    = "initial"
    "DD_SERVICE"                     = "dummy-api-0375"
    "DD_ENV"                         = "dev"
    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "true" # Oryx builds requirements.txt on zip deploy
  }

  lifecycle {
    # ci_app_deployment.yml rewrites APP_VERSION on every deploy — that is the
    # pipeline's job, and Terraform must not revert it on the next apply.
    ignore_changes = [app_settings["APP_VERSION"]]
  }
}
