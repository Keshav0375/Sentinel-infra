# ─────────────────────────────────────────────────────────────────────────────
# Version pins.
#
# The architecture never stated these (conflict C9), so they are fixed here and
# every module inherits them. azurerm is held at v4 deliberately: v4 makes
# `subscription_id` mandatory on the provider, which is what gives the root a
# single, explicit source for the subscription instead of ambient ARM_* env.
#
# There is NO `azuread` provider — in phases 1-2. rev-9 moved the identity plane
# onto Azure RBAC primitives (user-assigned managed identity + federated
# credentials) because the subscription lives in the uwindsor.ca tenant, where
# directory writes are denied at tenant policy. Nothing here touches a directory
# object.
#
# It returns at phase 3 task 3.5 as `azuread ~> 3.0`, aliased to a SECOND,
# personally-owned tenant that holds the two backend-API app registrations and
# nothing else (R4, resolved 2026-08-15). It is not added now because an unused
# provider is dead weight the lock file would still pin.
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
    # Added at task 3.5, exactly as promised above: aliased to the personally-
    # owned IDENTITY tenant, used by identity.tf and nothing else.
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
  }
}
