output "aks_cluster_name" {
  description = "Cluster name, for az aks get-credentials / nodepool scale in the workflows."
  value       = azurerm_kubernetes_cluster.sentinel.name
}

output "aks_resource_group" {
  description = "Resource group of the cluster — the workflows take both as inputs."
  value       = azurerm_kubernetes_cluster.sentinel.resource_group_name
}

output "oidc_issuer_url" {
  description = "The cluster's OIDC issuer. The federated credential binds to it; exported for diagnostics and for backend task 7.2's docs."
  value       = azurerm_kubernetes_cluster.sentinel.oidc_issuer_url
}

output "backend_identity_client_id" {
  description = "Client ID of sentinel-backend-wi — the value the K8s ServiceAccount annotation azure.workload.identity/client-id must carry (Sentinel/azure/k8s/)."
  value       = azurerm_user_assigned_identity.backend.client_id
}

# Not in §3.7's output list, but without it nothing can flip the phase-2 deferral
# toggles: role assignments and the Postgres Entra admin need the PRINCIPAL id,
# which is distinct from the client id above. Same addition-with-reason as
# acr_id in phase 2.
output "backend_identity_principal_id" {
  description = "Principal ID of sentinel-backend-wi — consumed by enable_backend_admin (postgres) and enable_backend_reader (keyvault) at the root."
  value       = azurerm_user_assigned_identity.backend.principal_id
}
