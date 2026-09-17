# ============================================================================
# CATALOGUES — azuread_access_package_catalog
# ============================================================================
# Tous les catalogues declares dans declarations/apps/ sont geres ici.
# Si un catalogue pre-existe dans Entra ID, Smart Discovery genere automatiquement
# un bloc import {} dans imports.tf pour l'adopter dans le State sans conflit.
# ============================================================================

resource "azuread_access_package_catalog" "this" {
  for_each = local.apps

  display_name       = try(each.value.catalog.display_name, each.value.catalog_name, each.value.app_name)
  description        = try(each.value.app_description, each.value.catalog.description, "Catalogue ${try(each.value.catalog.display_name, each.value.app_name)}")
  externally_visible = try(each.value.catalog.published, true)
  published          = true
}