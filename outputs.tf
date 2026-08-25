# ─────────────────────────────────────────────────────────────────────────────
# Root outputs.
#
# Split by layer, because the two are consumed by different readers:
#
#   PLATFORM outputs are read by every deployment, through
#   `data.terraform_remote_state.platform`. They are a contract — renaming one
#   breaks every deployment at once.
#
#   DEPLOYMENT outputs are read by humans and by the other repos' pipelines.
#
# Every output is `try`-guarded on the layer, so the inactive half resolves to
# null rather than failing. `count` on a module makes every reference an index,
# and an unindexed reference in the wrong layer is an error, not an empty value.
#
# Rule kept from phase 4: an output exists because something CONSUMES it. Outputs
# are a public interface; "might be handy" is how a module ends up with thirty
# and no way to tell which are load-bearing.
# ─────────────────────────────────────────────────────────────────────────────

# ── Identity of this workspace ────────────────────────────────────────────────

output "layer" {
  description = "Which layer this workspace manages."
  value       = var.layer
}

output "names" {
  description = "Every name this workspace derives. Exposed for diagnostics — when a global name collides, this is what to compare."
  value       = module.naming.names
}

# ── Platform ──────────────────────────────────────────────────────────────────

output "resource_group_name" {
  description = "The platform resource group."
  value       = try(azurerm_resource_group.platform[0].name, null)
}

# Consumed by: backend CI (image push target) and every runner `container:` block.
output "acr_login_server" {
  description = "ACR login server FQDN. Shared by every deployment — one registry, many images."
  value       = try(module.acr[0].acr_login_server, null)
}

output "acr_id" {
  description = "ACR resource ID, for AcrPull grants in the deployment layer."
  value       = try(module.acr[0].acr_id, null)
}

# Consumed by: `az aks get-credentials`, the pause/resume workflow, and the
# kubernetes provider in the deployment layer.
output "aks_cluster_name" {
  description = "The shared AKS cluster. Deployments get a namespace on it, not a cluster of their own."
  value       = try(module.aks[0].aks_cluster_name, null)
}

output "aks_resource_group" {
  description = "Resource group holding the cluster."
  value       = try(module.aks[0].aks_resource_group, null)
}

# Consumed by: every deployment's federated credential. This is the trust anchor
# for workload identity — it changes if the cluster is recreated, which silently
# invalidates every deployment's credential at once.
output "oidc_issuer_url" {
  description = "AKS OIDC issuer URL — the trust anchor for workload identity."
  value       = try(module.aks[0].oidc_issuer_url, null)
}

# Consumed by: deployments in `database.mode: shared`, and by anyone connecting
# with an Entra token. There is no password to pair with this.
output "postgres_fqdn" {
  description = "Shared Postgres server FQDN. Entra-only auth — no password exists."
  value       = try(module.postgresql[0].db_host, null)
}

# Consumed by: deployments in `database.mode: shared`, which create a database
# on this server without holding the server in their own state — so destroying a
# deployment removes its database and cannot reach the server.
output "postgres_server_id" {
  description = "Resource ID of the shared Postgres server."
  value       = try(module.postgresql[0].server_id, null)
}

output "postgres_admin_principal" {
  description = "The human Entra administrator, so a deployment can grant its own role without re-deriving it."
  value       = try(var.pg_admin_principal_name, null)
}

# ── Deployment ────────────────────────────────────────────────────────────────
# Proves the remote-state seam end to end: these values are READ from the
# platform's state, not computed here. Phase 6 adds the deployment's own
# resources beside them.

output "platform_acr_login_server" {
  description = "The platform's registry, as seen from a deployment workspace. Read-only — a deployment cannot change it."
  value       = try(local.platform.acr_login_server, null)
}

output "platform_aks_cluster_name" {
  description = "The shared cluster, as seen from a deployment workspace."
  value       = try(local.platform.aks_cluster_name, null)
}

output "platform_oidc_issuer_url" {
  description = "The cluster's OIDC issuer, as seen from a deployment workspace. The federated subject for this deployment's namespace is built against it."
  value       = try(local.platform.oidc_issuer_url, null)
}
