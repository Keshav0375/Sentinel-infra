# ─────────────────────────────────────────────────────────────────────────────
# Version pins.
#
# The architecture never stated these (conflict C9), so they are fixed here and
# every module inherits them. azurerm is held at v4 deliberately: v4 makes
# `subscription_id` mandatory on the provider, which is what gives the root a
# single, explicit source for the subscription instead of ambient ARM_* env.
#
# There is NO `azuread` provider. rev-9 moved the identity plane onto Azure RBAC
# primitives (user-assigned managed identity + federated credentials) because the
# subscription lives in the uwindsor.ca tenant, where directory writes are denied
# at tenant policy. Nothing in phases 1-2 touches a directory object. If R4 is
# resolved in favour of an app registration, azuread gets added back here.
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }
}
