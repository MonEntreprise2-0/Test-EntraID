# ============================================================================
# CATALOGUES — azuread_access_package_catalog
# ============================================================================
# Mode 1 : Création / Gestion par Terraform (défaut ou existing: false)
# Mode 2 : Consommation d'un catalogue pré-existant dans Entra ID (existing: true)
#          Supporte la recherche par display_name OU par id (object_id).
# ============================================================================

# 1. Catalogues créés et gérés par Terraform
resource "azuread_access_package_catalog" "this" {
  for_each = {
    for app_name, app in local.apps : app_name => app
    if !try(app.catalog.existing, false) && try(app.catalog.create, true)
  }

  display_name       = each.value.catalog.display_name
  description        = try(each.value.catalog.description, "Catalogue ${each.value.catalog.display_name}")
  externally_visible = try(each.value.catalog.published, true)
}

# 2. Catalogues pré-existants dans Entra ID (Mode Consommateur SSoT)
data "azuread_access_package_catalog" "existing" {
  for_each = {
    for app_name, app in local.apps : app_name => app
    if try(app.catalog.existing, false) || !try(app.catalog.create, true)
  }

  object_id    = try(each.value.catalog.id, null)
  display_name = try(each.value.catalog.id, null) == null ? each.value.catalog.display_name : null
}