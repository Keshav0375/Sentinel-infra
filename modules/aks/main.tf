# ─────────────────────────────────────────────────────────────────────────────
# AKS — backend hosting (architecture/infra.md §3.7).
#
# Scale-to-zero is the cost model — via `az aks stop`/`start` on the WHOLE
# cluster (backend §8.5), not nodepool scaling: a system pool cannot go below
# 1 node, and a 1-pool cluster's pool is always a system pool. Found live
# 2026-08-23 (SystemPoolSkuTooLow). Terraform provisions the cluster only — the
# sentinel-backend manifests live in the Sentinel repo and are applied by
# ci_backend_deployment.yml, never from here.
#
# This module also owns the backend pod's WORKLOAD IDENTITY: the UAMI the pod
# runs as, federated to the cluster's OIDC issuer. Creating it here (not in a
# separate module) keeps the issuer→credential edge inside one plan.
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

resource "azurerm_kubernetes_cluster" "sentinel" {
  name                = "sentinel-aks"
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = "sentinel"

  # Free control plane (no SLA — acceptable for a demo stack; the grant covers it).
  sku_tier = "Free"

  # Both required for workload identity: the cluster publishes an OIDC issuer,
  # and the webhook that projects federated tokens into pods is enabled.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  default_node_pool {
    name       = "default"
    node_count = 1
    # B2pls_v2 — ARM64, 2 vCPU / 4 GiB. Third SKU attempt, each rejected live:
    #   B2ats_v2 (grant) → SystemPoolSkuTooLow: system pools need >=4 GB, it has 1
    #   B2s              → not in this subscription's allowed AKS list for
    #                      canadacentral; every allowed small SKU is ARM ('p')
    # B2pls_v2 satisfies the system-pool floor, fits Bpsv2 quota (2 of 10), and
    # bills ~$0.03/hr ONLY while the cluster is started (az aks stop between
    # runs). CONSEQUENCE: the node is arm64 — the backend image must be built
    # linux/arm64 (backend phase 7, docker buildx).
    vm_size = "Standard_B2pls_v2"

    upgrade_settings {
      max_surge = "10%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  lifecycle {
    ignore_changes = [default_node_pool[0].node_count]
  }
}

# Kubelet pulls images from ACR with no imagePullSecrets — the grant lives with
# the consumer, which is why it is here and not in the ACR module.
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                            = var.acr_id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.sentinel.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}

# CI runs az aks get-credentials + kubectl (deploy, scale, smoke). User Role is
# enough — listClusterUserCredential — and deliberately not Admin.
resource "azurerm_role_assignment" "gha_aks_user" {
  scope                            = azurerm_kubernetes_cluster.sentinel.id
  role_definition_name             = "Azure Kubernetes Service Cluster User Role"
  principal_id                     = var.gha_principal_id
  skip_service_principal_aad_check = true
}

# ── Backend workload identity ─────────────────────────────────────────────────
# The UAMI the backend pod runs as. It reads LLM keys straight from Key Vault
# (§3.3, enable_backend_reader) and is attached directly as a PostgreSQL Entra
# admin (§3.2, enable_backend_admin, rev-9) — both toggles flipped at the root
# with this identity's principal_id. No secret ever lands in a K8s Secret.
resource "azurerm_user_assigned_identity" "backend" {
  name                = "sentinel-backend-wi"
  resource_group_name = var.resource_group_name
  location            = var.location
}

# Federate the K8s service account to the UAMI. Subject is the ServiceAccount
# the Deployment runs under; audience is the workload-identity exchange
# audience. The consumer side (SA annotation azure.workload.identity/client-id
# + pod label azure.workload.identity/use) lives in Sentinel/azure/k8s/.
resource "azurerm_federated_identity_credential" "backend" {
  # No resource_group_name: unused + deprecated in azurerm v4 — the same W1
  # finding phase 1 fixed in oidc.tf, reintroduced here by copying the original
  # §3.7 snippet. The parent identity carries the group.
  name                      = "sentinel-backend-fic"
  user_assigned_identity_id = azurerm_user_assigned_identity.backend.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.sentinel.oidc_issuer_url
  subject                   = "system:serviceaccount:sentinel:sentinel-backend"
}
