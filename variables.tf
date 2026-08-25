# ─────────────────────────────────────────────────────────────────────────────
# Root inputs.
#
# Ten, down from twenty. Everything that used to be a variable — SKUs, sizes,
# retention, which components to build — moved into
# azure/config/deployment-config.yaml, because `workflow_dispatch` accepts at
# most 10 inputs and the stack has roughly forty knobs.
#
# What survives here is only what the FORM must carry (which deployment, which
# layer) plus identity values, which cannot live in a config file that a pull
# request can edit.
# ─────────────────────────────────────────────────────────────────────────────

variable "layer" {
  description = "Which layer this workspace manages. `platform` builds the shared cluster, registry and database server; `deployment` builds one isolated deployment against them."
  type        = string

  validation {
    condition     = contains(["platform", "deployment"], var.layer)
    error_message = "layer must be `platform` or `deployment`."
  }
}

variable "deployment" {
  description = "Deployment name — the unit of isolation. Constrained by modules/naming: 2-8 lowercase alphanumeric."
  type        = string
  default     = "sentinel"
}

variable "environment" {
  description = "Environment within the deployment. The platform layer uses `plat`."
  type        = string
  default     = "plat"
}

variable "location" {
  description = "Azure region. Must have an abbreviation in modules/naming, or the plan fails rather than emitting a malformed name."
  type        = string
  default     = "canadacentral"
}

variable "subscription_id" {
  description = "Subscription that owns every resource. Mandatory on the azurerm v4 provider, which gives the root one explicit source instead of ambient ARM_* env."
  type        = string
}

# Pinned rather than read from `data.azurerm_client_config`, and that is not a
# style choice. `az` shares one context across terminals; a cross-tenant login
# repoints it silently, and the Postgres `tenant_id` is ForceNew. Reading the
# ambient context would let a stray `az login` propose destroying the database.
variable "tenant_id" {
  description = "Entra tenant that owns the subscription — the SCHOOL tenant."
  type        = string
  default     = "12f933b3-3d61-4b19-9a4d-689021de8cc9"
}

variable "identity_tenant_id" {
  description = "The IDENTITY tenant (R4). Holds the per-deployment app registrations; the school tenant denies app creation at policy."
  type        = string
  default     = "eae0d3c6-af22-4b70-ad3b-12d625a06139"
}

# ── Values a config file must not hold ───────────────────────────────────────
# These name a human. They belong to the run, not to the deployment.

variable "pg_admin_object_id" {
  description = "Object ID of the human Entra administrator on the Postgres server."
  type        = string
}

variable "pg_admin_principal_name" {
  description = "UPN of that administrator. Postgres stores it verbatim as the role name."
  type        = string
}

variable "kv_admin_object_id" {
  description = "Object ID granted Key Vault Secrets Officer on each deployment's vault — the human who seeds secrets by hand. Deliberately separate from pg_admin_object_id: the same person today need not be the same person forever. NEVER data.azurerm_client_config.current.object_id — under CI that resolves to the pipeline identity and silently strips the human's access."
  type        = string
}

variable "state_storage_account" {
  description = "State storage account, used by the deployment layer's remote-state lookup of the platform. Must match backend.tf, which cannot interpolate variables."
  type        = string
  default     = "stsentineltfb7fa37"
}

# NOTE: `identity_client_id`, `identity_use_oidc` and `github_owner` were removed
# on 2026-08-25 along with identity.tf and the azuread provider. Nothing reads
# them, and tflint is right that an unused variable is the same dead weight as an
# unused provider. They return together when the identity tenant is wired.
