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
  name                = var.cluster_name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.dns_prefix

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
    vm_size = var.node_vm_size

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

# The per-deployment backend identity and its federated credential USED to live
# here (phase 3). They moved to the deployment layer in phase 5: the cluster is
# shared and each deployment gets its own namespace, its own UAMI and its own
# federated subject `system:serviceaccount:<namespace>:<sa>`. Binding one
# identity to the cluster module would have made every deployment share it —
# which is precisely the isolation this design exists to provide.
#
# The `gha_aks_user` role assignment also went: gha-deploy now holds
# "Azure Kubernetes Service Cluster Admin Role" at SUBSCRIPTION scope from
# bootstrap-identities.sh, because it must reach a cluster it has not created yet.
