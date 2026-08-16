# ─────────────────────────────────────────────────────────────────────────────
# Azure Container Registry (architecture/infra.md §3.1).
#
# Holds two images: `sentinel-backend` (sha-pinned, plus a `stable` rollback tag)
# and `ci-runner` for the self-hosted CI image. AcrPull is NOT granted here — it
# belongs to the AKS module (§3.7) so the grant lives with the consumer.
# ─────────────────────────────────────────────────────────────────────────────

resource "azurerm_container_registry" "sentinel" {
  # Alphanumeric only — ACR rejects hyphens — and globally unique across all of
  # Azure. The unsuffixed `sentinelacr` was already taken by another tenant, as
  # were `sentinel-pg` and `sentinel-kv`; the `0375` suffix is the project-wide
  # convention for globally-scoped names (see §3 naming conventions).
  name                = var.registry_name
  resource_group_name = var.resource_group_name
  location            = var.location

  # Basic, not the Standard the architecture originally specified (owner decision
  # 2026-08-15). The "free 100 GB for 12 months" note describes the Azure **free
  # account** offer; this subscription is **Azure for Students**, where that
  # inclusion is unverified. Standard would bill ~$20/mo against a $100 credit for
  # 100 GB and 10 webhooks that two images will never use. Basic is ~$5/mo with
  # 10 GB and 2 webhooks; auth, AcrPull and the login server are identical, and
  # the SKU can be raised in place later without data loss.
  sku = "Basic"

  # Admin user is enabled so GHA can `docker login` with a username/password pair
  # pulled from Key Vault (`acr-password`, §3.3). AKS itself does NOT use this —
  # it pulls via the AcrPull role assignment on its kubelet identity, so no
  # imagePullSecret is needed in the cluster.
  admin_enabled = true
}
