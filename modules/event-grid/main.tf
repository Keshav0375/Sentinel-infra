# ─────────────────────────────────────────────────────────────────────────────
# Event Grid — the Datadog → bridge conduit (architecture/infra.md §3.4).
#
# ONE topic, ONE subscription. Both Datadog monitors post to the same topic and
# the bridge classifies — routing lives in code, not in subscription filters,
# so adding a third signal type is a code change rather than infra surgery.
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

resource "azurerm_eventgrid_topic" "sentinel" {
  name                = var.topic_name
  location            = var.location
  resource_group_name = var.resource_group_name
}

# Event Grid VALIDATES the endpoint at creation, so the bridge function must
# already exist with its code deployed — which is why the root wires
# function_app_id from module.functions and why 3.3 builds before 3.2.
resource "azurerm_eventgrid_event_subscription" "to_function" {
  name  = "sentinel-to-function"
  scope = azurerm_eventgrid_topic.sentinel.id

  azure_function_endpoint {
    function_id = "${var.function_app_id}/functions/bridge"

    # Azure populates both server-side; omitting them is a PERPETUAL DIFF
    # proposing to null them on every plan — same class as the Postgres
    # authentication.tenant_id (task 2.2). These are the service defaults,
    # declared, not choices.
    max_events_per_batch              = 1
    preferred_batch_size_in_kilobytes = 64
  }
}
