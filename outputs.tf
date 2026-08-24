# ─────────────────────────────────────────────────────────────────────────────
# Root outputs — the seam every other repo reads from.
#
# Defined once, at the end of the build, against real module addresses rather
# than accumulated piecemeal. Two rules held here:
#
#   1. An output exists because something CONSUMES it. Outputs are a public
#      interface: every one added is a name that has to keep working. "Might be
#      handy" is how a module ends up with thirty of them and no way to tell
#      which are load-bearing. Each block below names its consumer.
#
#   2. Nothing here is a credential the consumer could get through a narrower
#      channel. The ACR admin password is a module output but deliberately NOT a
#      root output — it reaches the backend repo as a GitHub secret pushed by
#      github-repo-config.tf, which is scoped to one repo rather than to anyone
#      who can run `terraform output`.
#
# ── On depends_on: there is none, deliberately ───────────────────────────────
# Task 4.4 asked for "inter-module dependency ordering". The correct amount of
# explicit ordering here turned out to be zero. Terraform builds its graph from
# REFERENCES, and main.tf already carries the real ones: aks reads
# module.acr.acr_id for the AcrPull grant, keyvault and postgresql read
# module.aks.backend_identity_principal_id, event_grid reads
# module.functions.function_app_id. Every genuine edge is already encoded.
#
# Adding `depends_on` on top of that is an anti-pattern, not belt-and-braces: it
# creates ordering the infrastructure does not require, serialises module
# creation that could run in parallel, and — the real cost — makes Terraform
# treat the whole dependent module as unknown at plan time, so a plan that
# should read "no changes" starts printing "(known after apply)" for resources
# nothing is changing. The proof it is unnecessary: `terraform plan` reports no
# changes and no cycle against live state.
# ─────────────────────────────────────────────────────────────────────────────

# ── Container registry ───────────────────────────────────────────────────────

# Consumed by: backend CI (image push target), §6.4 runner `container:` blocks.
output "acr_login_server" {
  description = "ACR login server FQDN, e.g. sentinelacr0375.azurecr.io."
  value       = module.acr.acr_login_server
}

# ── Database ─────────────────────────────────────────────────────────────────

# Consumed by: backend DATABASE_URL (backend task 1.2), and the deployment
# pipeline's Record step, which writes a deployment row using an Entra token.
output "db_host" {
  description = "PostgreSQL flexible-server FQDN. Auth is Entra-only — there is no password to pair with this."
  value       = module.postgresql.db_host
}

output "db_name" {
  description = "Application database name."
  value       = module.postgresql.db_name
}

# ── Kubernetes ───────────────────────────────────────────────────────────────

# Consumed by: backend deploy workflow (`az aks get-credentials`), and the
# scale-to-zero start/stop commands in docs/BOOTSTRAP.md.
output "aks_cluster_name" {
  description = "AKS cluster name."
  value       = module.aks.aks_cluster_name
}

# Consumed by: backend task 7.2 — the value of the
# azure.workload.identity/client-id annotation on the sentinel-backend
# ServiceAccount. This is the consumer half of the federated credential the AKS
# module created; without it the pod gets no token and every Azure call 401s.
output "backend_identity_client_id" {
  description = "Client ID of the sentinel-backend workload-identity UAMI. Annotate the ServiceAccount with this."
  value       = module.aks.backend_identity_client_id
}

# Consumed by: humans, when a federated-credential mismatch needs diagnosing.
# The issuer is what a subject is matched against, and it changes if the cluster
# is ever recreated — which silently invalidates every workload credential.
output "oidc_issuer_url" {
  description = "AKS OIDC issuer URL — the trust anchor for workload identity."
  value       = module.aks.oidc_issuer_url
}

# ── Key Vault ────────────────────────────────────────────────────────────────

# Consumed by: backend secret loading (azure-keyvault-secrets), and the
# `az keyvault secret set` commands that seed B4-B8 by hand.
output "key_vault_uri" {
  description = "Key Vault URI. The vault is empty by design — Terraform never seeds a runtime secret."
  value       = module.keyvault.key_vault_uri
}

# ── Target application ───────────────────────────────────────────────────────

# Consumed by: the deployment repo's Verify step, and the Datadog monitor that
# generates runtime_error signal.
output "app_url" {
  description = "Public URL of the dummy target app on App Service F1."
  value       = module.app_service.app_url
}

# ── Event bridge ─────────────────────────────────────────────────────────────

# Consumed by: Event Grid subscriptions, and by anything diagnosing why the
# bridge did not fire.
output "function_app_id" {
  description = "Resource ID of the Function App hosting the bridge and rotator handlers."
  value       = module.functions.function_app_id
}

# Consumed by deployment task 2.3, which points the Datadog monitor webhooks here.
output "event_grid_topic_endpoint" {
  description = "Event Grid custom-topic endpoint. Datadog monitor webhooks POST here."
  value       = module.event_grid.topic_endpoint
}

# The matching ACCESS KEY is deliberately NOT an output — it broke rule 2 at the
# top of this file, three blocks after that rule was written. A publisher does
# need it, but its one consumer is a human pasting it into Datadog's webhook
# config once, and `az` is already a narrower channel than this repo's public
# interface:
#
#   az eventgrid topic key list -n sentinel-events-0375 -g sentinel-rg #     --query key1 -o tsv
#
# Same reasoning that keeps the ACR admin password out of here.
