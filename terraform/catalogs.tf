# ============================================================================
# CATALOGUES — azuread_access_package_catalog
# ============================================================================
# Mode 1 : Création par Terraform (catalogue absent d'Entra ID)
# Mode 2 : Consommation d'un catalogue existant (Smart Discovery ou existing: true)
# ============================================================================

# 1. Catalogues créés et gérés par Terraform
resource "azuread_access_package_catalog" "this" {
  for_each = local.catalogs_to_create

  display_name       = each.value.catalog.display_name
  description        = try(each.value.catalog.description, "Catalogue ${each.value.catalog.display_name}")
  externally_visible = try(each.value.catalog.published, true)
}

# 2. Catalogues pré-existants dans Entra ID (Fallback si pas de Smart Discovery)
data "azuread_access_package_catalog" "existing" {
  for_each = {
    for app_name, app in local.apps : app_name => app
    if try(app.catalog.existing, false) && !try(local.discovered_catalogs[app_name].exists, false)
  }

  object_id    = try(each.value.catalog.id, null)
  display_name = try(each.value.catalog.id, null) == null ? each.value.catalog.display_name : null
}