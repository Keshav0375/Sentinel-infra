output "topic_id" {
  description = "Topic resource id."
  value       = azurerm_eventgrid_topic.sentinel.id
}

output "topic_endpoint" {
  description = "Ingest URL — the Datadog webhook integration posts here (deployment task 2.3)."
  value       = azurerm_eventgrid_topic.sentinel.endpoint
}

output "topic_key" {
  description = "Access key for the Datadog webhook's aeg-sas-key header. Sensitive: lands in state and is pushed to the deployment repo as a secret in task 4.1 — never echoed."
  value       = azurerm_eventgrid_topic.sentinel.primary_access_key
  sensitive   = true
}
