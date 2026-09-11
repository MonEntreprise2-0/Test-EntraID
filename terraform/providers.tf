# ============================================================================
# PROVIDERS — Configuration du provider AzureAD et version Terraform
# ============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.47"
    }
  }
}

# -----------------------------------------------------------------------------
# Provider AzureAD
# -----------------------------------------------------------------------------
# Authentication :
#   - En local  : Azure CLI (az login)
#   - En CI/CD  : OIDC via GitHub Actions (Federated Credentials)
#
# Les variables d'environnement suivantes sont injectees par le workflow :
#   ARM_CLIENT_ID, ARM_TENANT_ID, ARM_SUBSCRIPTION_ID, ARM_OIDC_TOKEN
# -----------------------------------------------------------------------------
provider "azuread" {
  tenant_id = var.tenant_id
  use_oidc  = var.use_oidc
}
