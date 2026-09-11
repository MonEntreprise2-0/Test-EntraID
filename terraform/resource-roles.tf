# ============================================================================
# ASSOCIATIONS RESSOURCE-CATALOGUE
# ============================================================================
# Avant d'ajouter une ressource a un Access Package, elle doit d'abord
# etre associee au catalogue parent. Ces ressources creent ce lien.
#
# Deux types d'associations :
#   - Groupes  (origin_system = "AadGroup")
#   - Applications (origin_system = "AadApplication")
# ============================================================================

# ---------------------------------------------------------------------------
# Groupes -> Catalogues
# ---------------------------------------------------------------------------
resource "azuread_access_package_resource_catalog_association" "groups" {
  for_each = local.catalog_group_associations

  catalog_id             = azuread_access_package_catalog.this[each.value.app_name].id
  resource_origin_id     = data.azuread_group.all[each.value.display_name].object_id
  resource_origin_system = "AadGroup"
}

# ---------------------------------------------------------------------------
# Applications -> Catalogues
# ---------------------------------------------------------------------------
resource "azuread_access_package_resource_catalog_association" "apps" {
  for_each = local.catalog_app_associations

  catalog_id             = azuread_access_package_catalog.this[each.value.app_name].id
  resource_origin_id     = data.azuread_service_principal.all[each.value.display_name].object_id
  resource_origin_system = "AadApplication"
}

# ============================================================================
# ASSOCIATIONS RESSOURCE-PACKAGE (roles)
# ============================================================================
# Lie une ressource du catalogue a un Access Package specifique.
# C'est ici que le role est defini (ex: "Member" ou "Owner" pour un groupe).
#
# Cle for_each : "<app>|<access_package>|<resource>|<role>"
# ============================================================================

resource "azuread_access_package_resource_package_association" "this" {
  for_each = local.resource_package_associations

  access_package_id               = azuread_access_package.this[each.value.ap_key].id
  catalog_resource_association_id = (
    each.value.resource_type == "group"
    ? azuread_access_package_resource_catalog_association.groups[each.value.catalog_assoc_key].id
    : azuread_access_package_resource_catalog_association.apps[each.value.catalog_assoc_key].id
  )

  # Le role (Member/Owner) est implicitement derive de la resource_origin.
  # Pour un controle plus fin, utilisez l'API Microsoft Graph directement.

  depends_on = [
    azuread_access_package_resource_catalog_association.groups,
    azuread_access_package_resource_catalog_association.apps,
  ]
}
