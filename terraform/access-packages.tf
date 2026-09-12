# ============================================================================
# ACCESS PACKAGES — azuread_access_package
# ============================================================================
# Un Access Package est un "bundle" de roles sur des ressources.
# Les utilisateurs demandent un Access Package via le portail MyAccess.
#
# Cle for_each : "<application_name>|<access_package_display_name>"
# ============================================================================

resource "azuread_access_package" "this" {
  for_each = local.access_packages

  catalog_id   = azuread_access_package_catalog.this[each.value.app_name].id
  display_name = each.value.display_name
  description  = each.value.description
  hidden       = each.value.hidden
}
