# ============================================================================
# DATA SOURCES — Validation SSoT contre Entra ID (Support Ardian v1 & v2)
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
# Resolution insensible a la casse grace au mapping discovered_groups
# ---------------------------------------------------------------------------
data "azuread_group" "all" {
  for_each         = toset(local.all_group_names)
  display_name     = try(local.discovered_groups[each.value].display_name, each.value)
  security_enabled = true
}

# ---------------------------------------------------------------------------
# SERVICE PRINCIPALS — Applications referencees dans les YAML
# ---------------------------------------------------------------------------
data "azuread_service_principal" "all" {
  for_each     = toset(local.all_application_names)
  display_name = each.value
}

# ---------------------------------------------------------------------------
# UTILISATEURS — Approbateurs (authorization_owners) declares dans les YAML
# ---------------------------------------------------------------------------
data "azuread_user" "owners" {
  for_each            = toset(local.all_owner_emails)
  user_principal_name = try(local.discovered_users[lower(each.value)].user_principal_name, each.value)
}