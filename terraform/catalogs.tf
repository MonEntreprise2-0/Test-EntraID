# ============================================================================
# CATALOGUES — azuread_access_package_catalog
# ============================================================================
# Un catalogue par application (1 YAML = 1 catalogue).
# Le catalogue est le conteneur logique qui regroupe les ressources
# et les Access Packages d'une application dans Entitlement Management.
# ============================================================================

resource "azuread_access_package_catalog" "this" {
  for_each = local.apps

  display_name       = each.value.catalog.display_name
  description        = each.value.catalog.description
  externally_visible = each.value.catalog.published
}
