# ─────────────────────────────────────────────────────────────────────────────
# Providers, config, and the layer switch.
#
# ── One root, two layers ─────────────────────────────────────────────────────
# `var.layer` selects what a workspace manages. Two separate root directories
# were considered and rejected: that means two provider blocks, two lock files
# and two `init` paths to keep in step, for one boolean's worth of separation.
#
# The layers are separated where it matters instead — in STATE. `platform` is its
# own workspace; each deployment is its own workspace. That is a safety property
# rather than a preference: in a single state, destroying a deployment would take
# the shared cluster with it.
# ─────────────────────────────────────────────────────────────────────────────

provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
}

# NOTE: there is deliberately no `azuread` provider here yet.
#
# It returns in phase 6, aliased to the IDENTITY tenant, when the per-deployment
# app registrations land. Declaring it now would be dead weight the lock file
# still pins and tflint still flags — the same reasoning versions.tf used in
# phase 1, when the identity plane had not yet arrived.

locals {
  is_platform   = var.layer == "platform"
  is_deployment = var.layer == "deployment"

  # ── Config: file for size, form for shape ──────────────────────────────────
  # `merge` is shallow on purpose. A deployment overriding `database:` replaces
  # the whole block rather than merging into it — so an override states every key
  # it needs, and you can read one block and know what that deployment gets
  # without mentally diffing it against defaults.
  config_file = yamldecode(file("${path.root}/azure/config/deployment-config.yaml"))

  # A deployment absent from `deployments:` is completely valid and inherits
  # defaults entirely. That is what makes `deployment: demo1` + `apply` a whole
  # instruction with no file edit — the file is for exceptions, not enrolment.
  cfg = merge(
    local.config_file.defaults,
    try(local.config_file.deployments[var.deployment], {}),
  )

  # The form may override the file for location; everything else comes from YAML.
  location = coalesce(var.location, local.cfg.location)
}

module "naming" {
  source = "./modules/naming"

  deployment         = var.deployment
  environment        = var.environment
  location           = local.location
  subscription_id    = var.subscription_id
  identity_tenant_id = var.identity_tenant_id
}

# ── Guards ────────────────────────────────────────────────────────────────────
# Cheap assertions that fail in seconds, rather than letting a provider explain
# the mistake eight minutes into an apply.
resource "terraform_data" "layer_guards" {
  lifecycle {
    # The platform is one thing, not one per environment. Building it under a
    # second environment name would silently create a SECOND cluster — and the
    # subscription's regional quota is 6 vCPU against a 2 vCPU node, so the
    # failure would arrive as a quota error naming neither cause.
    precondition {
      condition     = !local.is_platform || var.environment == "plat"
      error_message = "the platform layer must use environment `plat`; got `${var.environment}`. A second platform environment would build a second cluster against a 6-vCPU quota."
    }

    # `plat` is reserved. A deployment using it would collide with the platform
    # on every name the naming module produces.
    precondition {
      condition     = !local.is_deployment || var.environment != "plat"
      error_message = "`plat` is reserved for the platform layer. Use dev, prod, or another name."
    }
  }
}
