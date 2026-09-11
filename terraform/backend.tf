# ============================================================================
# BACKEND — Stockage distant du state Terraform
# ============================================================================
# Le state est stocke dans un Azure Blob Storage pour :
#   - Permettre le travail collaboratif (locking)
#   - Securiser le state (chiffrement au repos)
#   - Etre accessible depuis GitHub Actions via OIDC
#
# Pre-requis : le Storage Account et le conteneur doivent etre crees
# manuellement avant le premier 'terraform init'.
# ============================================================================

terraform {
  backend "azurerm" {
    # -----------------------------------------------------------------
    # A PERSONNALISER selon votre environnement
    # -----------------------------------------------------------------
    resource_group_name  = "rg-terraform-state"       # Resource Group du Storage Account
    storage_account_name = "stardiantfstate"           # Nom du Storage Account
    container_name       = "entitlement-mgmt"          # Nom du conteneur blob
    key                  = "entitlement-mgmt.tfstate"  # Nom du fichier state
    use_oidc             = true                        # Auth OIDC depuis GitHub Actions
  }
}
