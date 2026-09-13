# ============================================================================
# OUTPUTS — Identifiants des ressources creees ou consommees
# ============================================================================

# -----------------------------------------------------------------------------
# Catalogues
# -----------------------------------------------------------------------------
output "catalogs" {
  description = "Map des catalogues (application_name => {id, display_name, source})"
  value = merge(
    {
      for app_name, catalog in azuread_access_package_catalog.this :
      app_name => {
        id           = catalog.id
        display_name = catalog.display_name
        source       = "managed_by_terraform"
      }
    },
    {
      for app_name, catalog in data.azuread_access_package_catalog.existing :
      app_name => {
        id           = catalog.id
        display_name = catalog.display_name
        source       = "existing_in_entraid"
      }
    }
  )
}

# -----------------------------------------------------------------------------
# Access Packages
# -----------------------------------------------------------------------------
output "access_packages" {
  description = "Map des Access Packages crees (cle composite => {id, display_name})"
  value = {
    for key, ap in azuread_access_package.this :
    key => {
      id           = ap.id
      display_name = ap.display_name
    }
  }
}

# -----------------------------------------------------------------------------
# Assignment Policies
# -----------------------------------------------------------------------------
output "assignment_policies" {
  description = "Map des politiques d'assignation creees (cle composite => {id, display_name})"
  value = {
    for key, pol in azuread_access_package_assignment_policy.this :
    key => {
      id           = pol.id
      display_name = pol.display_name
    }
  }
}

# -----------------------------------------------------------------------------
# Resume
# -----------------------------------------------------------------------------
output "summary" {
  description = "Resume du deploiement"
  value = {
    total_catalogs   = length(local.catalog_ids)
    total_packages   = length(azuread_access_package.this)
    total_policies   = length(azuread_access_package_assignment_policy.this)
    applications     = keys(local.catalog_ids)
  }
}