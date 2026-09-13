# ============================================================================
# CATALOGUES — azuread_access_package_catalog
# ============================================================================
# Mode 1 : Creation par Terraform (catalogue absent d'Entra ID)
# Mode 2 : Consommation d'un catalogue existant (Smart Discovery ou existing: true)
# ============================================================================

# 1. Catalogues crees et geres par Terraform
resource "azuread_access_package_catalog" "this" {
  for_each = local.catalogs_to_create

  display_name       = try(each.value.catalog.display_name, each.value.app_name)
  description        = try(each.value.app_description, each.value.catalog.description, "Catalogue ${try(each.value.catalog.display_name, each.value.app_name)}")
  externally_visible = try(each.value.catalog.published, true)
}

# 2. Catalogues pre-existants dans Entra ID (Fallback si pas de Smart Discovery)
data "azuread_access_package_catalog" "existing" {
  for_each = {
    for app_name, app in local.apps : app_name => app
    if try(app.catalog.existing, false) && !try(local.discovered_catalogs[app_name].exists, false)
  }

  object_id    = try(each.value.catalog.id, null)
  display_name = try(each.value.catalog.id, null) == null ? try(each.value.catalog.display_name, each.value.app_name) : null
}