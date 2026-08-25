# ─────────────────────────────────────────────────────────────────────────────
# The DEPLOYMENT layer — one isolated deployment, built against the platform.
#
# Phase 5 establishes the SEAM. The resources themselves (Key Vault, Functions,
# App Service, Event Grid, the namespace and its identity) land in phase 6.
#
# ── Why a read-only remote-state lookup and not variables ────────────────────
# A deployment NEEDS the cluster's OIDC issuer and the registry's login server,
# and must be unable to change either. A data source enforces exactly that.
# Passing them as variables would mean the same values written in two places,
# drifting the first time one is edited.
#
# It also enforces the direction of dependency. Platform does not know its
# deployments exist; deployments cannot write platform state. Destroying a
# deployment therefore CANNOT touch the cluster — not by convention, but because
# its state file contains none of it.
# ─────────────────────────────────────────────────────────────────────────────

locals {
  deployment_count = local.is_deployment ? 1 : 0
}

data "terraform_remote_state" "platform" {
  count = local.deployment_count

  backend = "azurerm"

  # The `workspace` ARGUMENT, not a hand-built key. The azurerm backend stores a
  # workspace's state at `<key>env:<workspace>`, appending rather than nesting —
  # `env:/platform/sentinel.tfstate` is the S3 backend's layout and would read a
  # blob that does not exist. Getting this wrong produces "no state found",
  # which reads like the platform was never applied.
  workspace = "platform"

  config = {
    resource_group_name  = "rg-sentinel-bootstrap"
    storage_account_name = var.state_storage_account
    container_name       = "tfstate"
    key                  = "sentinel.tfstate"
    use_azuread_auth     = true
    use_oidc             = true
  }
}

locals {
  # Empty at the platform layer, so nothing here can be referenced by accident.
  platform = try(data.terraform_remote_state.platform[0].outputs, {})
}

# Fails fast and legibly when a deployment is planned before the platform exists.
# Without it the first error is a missing map key several modules deep, which
# names an attribute rather than the cause.
resource "terraform_data" "platform_available" {
  count = local.deployment_count

  lifecycle {
    precondition {
      condition     = try(local.platform.aks_cluster_name, "") != ""
      error_message = "platform state is empty or unreadable. Apply the platform layer first: terraform workspace select platform && terraform apply -var layer=platform"
    }
  }
}
