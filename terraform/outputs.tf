# ============================================================================
# OUTPUTS — Identifiants des ressources creees
# ============================================================================
# Ces outputs permettent de tracer les ressources creees dans Entra ID
# et sont affiches dans les logs du pipeline CI/CD.
# ============================================================================

# -----------------------------------------------------------------------------
# Catalogues
# -----------------------------------------------------------------------------
output "catalogs" {
  description = "Map des catalogues crees (application_name => {id, display_name})"
  value = {
    for app_name, catalog in azuread_access_package_catalog.this :
    app_name => {
      id           = catalog.id
      display_name = catalog.display_name
    }
  }
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
    total_catalogs   = length(azuread_access_package_catalog.this)
    total_packages   = length(azuread_access_package.this)
    total_policies   = length(azuread_access_package_assignment_policy.this)
    applications     = keys(azuread_access_package_catalog.this)
  }
}
