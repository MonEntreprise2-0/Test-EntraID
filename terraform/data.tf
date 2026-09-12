# ============================================================================
# DATA SOURCES — Validation SSoT contre Entra ID
# ============================================================================
# Ces blocs data interrogent Entra ID pour verifier que les ressources
# referencees dans les fichiers YAML existent reellement.
#
# PRINCIPE FONDAMENTAL : Entra ID est la Source Unique de Verite (SSoT).
# Si une ressource n'existe pas dans Entra ID, 'terraform plan' ECHOUE
# immediatement avec un message d'erreur clair.
#
# Le code Terraform ne CREE JAMAIS les ressources sous-jacentes (groupes,
# applications). Il les CONSOMME uniquement.
# ============================================================================

# ---------------------------------------------------------------------------
# Tenant actuel (pour reference)
# ---------------------------------------------------------------------------
data "azuread_client_config" "current" {}

# ---------------------------------------------------------------------------
# GROUPES — Tous les groupes references dans les YAML
# ---------------------------------------------------------------------------
# Inclut :
#   - Les groupes declares dans la section 'resources' (ressources du catalogue)
#   - Les groupes references dans les politiques (demandeurs, approbateurs, reviseurs)
#
# Si un groupe n'existe pas dans Entra ID, Terraform echouera ici avec :
#   Error: GroupNotFound - No group found with display_name "XXX"
# ---------------------------------------------------------------------------
data "azuread_group" "all" {
  for_each         = toset(local.all_group_names)
  display_name     = each.value
  security_enabled = true
}

# ---------------------------------------------------------------------------
# SERVICE PRINCIPALS — Applications referencees dans les YAML
# ---------------------------------------------------------------------------
# Les applications Entra ID sont representees par leur Service Principal.
# Le display_name doit correspondre exactement a celui de l'Enterprise App.
#
# Si une application n'existe pas, Terraform echouera ici avec :
#   Error: ServicePrincipalNotFound - No service principal found with
#          display_name "XXX"
# ---------------------------------------------------------------------------
data "azuread_service_principal" "all" {
  for_each     = toset(local.all_application_names)
  display_name = each.value
}
