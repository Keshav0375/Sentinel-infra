output "function_app_id" {
  description = "Bridge app resource id — task 3.2 appends /functions/bridge to build the Event Grid endpoint."
  value       = azurerm_linux_function_app.bridge.id
}

output "function_app_name" {
  description = "Bridge app name, for az functionapp log tailing and diagnostics."
  value       = azurerm_linux_function_app.bridge.name
}

output "bridge_principal_id" {
  description = "System-assigned identity of the bridge — consumed by the keyvault module's enable_bridge_reader grant so the GITHUB_TOKEN Key Vault reference can resolve."
  value       = azurerm_linux_function_app.bridge.identity[0].principal_id
}
