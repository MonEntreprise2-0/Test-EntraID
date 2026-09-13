# ============================================================================
# LOCALS — Chargement dynamique des fichiers YAML et aplatissement
# ============================================================================
# Ce fichier est le coeur du mecanisme data-driven :
# 1. fileset() decouvre tous les YAML dans declarations/apps/
# 2. yamldecode() parse chaque fichier en structure HCL
# 3. Les structures imbriquees sont aplaties en maps pour for_each
# ============================================================================

locals {

  # =========================================================================
  # 1. CHARGEMENT DES FICHIERS YAML
  # =========================================================================

  # Decouvrir tous les fichiers YAML (exclure les fichiers prefixes par _)
  yaml_files = [
    for f in fileset("${path.module}/${var.declarations_path}", "*.yaml") :
    f if !startswith(f, "_")
  ]

  # Parser chaque YAML en une map indexee par application_name
  apps = {
    for f in local.yaml_files :
    yamldecode(file("${path.module}/${var.declarations_path}/${f}")).application_name =>
    yamldecode(file("${path.module}/${var.declarations_path}/${f}"))
  }

  # =========================================================================
  # 2. EXTRACTION DES GROUPES (pour les blocs data SSoT)
  # =========================================================================

  # Groupes declares comme ressources dans les catalogues
  resource_group_names = distinct(flatten([
    for app_name, app in local.apps : [
      for res in app.resources : res.display_name
      if res.type == "group"
    ]
  ]))

  # Groupes references dans les politiques (demandeurs, approbateurs, reviseurs)
  policy_group_names = distinct(flatten([
    for app_name, app in local.apps : flatten([
      for ap in app.access_packages : flatten([
        for pol in ap.policies : concat(
          try(pol.requestor.groups, []),
          flatten([
            for stage in try(pol.approval.stages, []) : concat(
              stage.approver_groups,
              try(stage.fallback_approver_groups, [])
            )
          ]),
          try(pol.review.reviewer_groups, [])
        )
      ])
    ])
  ]))

  # Union de tous les noms de groupes uniques
  all_group_names = distinct(concat(local.resource_group_names, local.policy_group_names))

  # =========================================================================
  # 3. EXTRACTION DES APPLICATIONS (pour les blocs data SSoT)
  # =========================================================================

  all_application_names = distinct(flatten([
    for app_name, app in local.apps : [
      for res in app.resources : res.display_name
      if res.type == "application"
    ]
  ]))

  # =========================================================================
  # 4. APLATISSEMENT — Associations Catalogue-Ressources
  # =========================================================================

  # Associations groupes -> catalogues
  catalog_group_associations = {
    for item in flatten([
      for app_name, app in local.apps : [
        for res in app.resources : {
          key          = "${app_name}|${res.display_name}"
          app_name     = app_name
          display_name = res.display_name
        } if res.type == "group"
      ]
    ]) : item.key => item
  }

  # Associations applications -> catalogues
  catalog_app_associations = {
    for item in flatten([
      for app_name, app in local.apps : [
        for res in app.resources : {
          key          = "${app_name}|${res.display_name}"
          app_name     = app_name
          display_name = res.display_name
        } if res.type == "application"
      ]
    ]) : item.key => item
  }

  # =========================================================================
  # 5. APLATISSEMENT — Access Packages
  # =========================================================================

  access_packages = {
    for item in flatten([
      for app_name, app in local.apps : [
        for ap in app.access_packages : {
          key          = "${app_name}|${ap.display_name}"
          app_name     = app_name
          display_name = ap.display_name
          description  = ap.description
          hidden       = try(ap.hidden, false)
        }
      ]
    ]) : item.key => item
  }

  # =========================================================================
  # 6. APLATISSEMENT — Associations Ressource-Package (roles)
  # =========================================================================

  resource_package_associations = {
    for item in flatten([
      for app_name, app in local.apps : [
        for ap in app.access_packages : [
          for rr in ap.resource_roles : {
            key               = "${app_name}|${ap.display_name}|${rr.resource_display_name}|${rr.role}"
            app_name          = app_name
            ap_key            = "${app_name}|${ap.display_name}"
            resource_display_name = rr.resource_display_name
            resource_type     = rr.resource_type
            role              = rr.role
            catalog_assoc_key = "${app_name}|${rr.resource_display_name}"
          }
        ]
      ]
    ]) : item.key => item
  }

  # =========================================================================
  # 7. APLATISSEMENT — Politiques d'assignation
  # =========================================================================

  assignment_policies = {
    for item in flatten([
      for app_name, app in local.apps : [
        for ap in app.access_packages : [
          for pol in ap.policies : {
            key             = "${app_name}|${ap.display_name}|${pol.display_name}"
            app_name        = app_name
            ap_key          = "${app_name}|${ap.display_name}"
            display_name    = pol.display_name
            requestor       = pol.requestor
            approval        = pol.approval
            assignment      = pol.assignment
            review          = try(pol.review, { enabled = false })
          }
        ]
      ]
    ]) : item.key => item
  }

  # =========================================================================
  # 8. TABLE DE CONVERSION — Frequence de revue (jours -> enum Entra ID)
  # =========================================================================
  # Entra ID n'accepte pas de valeur arbitraire en jours pour la frequence
  # de revue. Cette table mappe les valeurs du YAML vers les enums supportes.

  review_frequency_map = {
    7   = "weekly"
    14  = "weekly"
    30  = "monthly"
    60  = "quarterly"
    90  = "quarterly"
    180 = "halfyearly"
    365 = "annual"
  }

  # Mapping scope_type YAML -> Entra ID enum
  scope_type_map = {
    "all_members" = "AllExistingDirectoryMemberUsers"
    "specific"    = "SpecificDirectorySubjects"
    "none"        = "NoSubjects"
  }

  # Mapping reviewer_type YAML -> Entra ID enum
  reviewer_type_map = {
    "self"     = "Self"
    "manager"  = "Manager"
    "specific" = "Reviewers"
  }

  # =========================================================================
  # 9. MAP UNIFIEE DES CATALOGUE IDS (crees ou consommes)
  # =========================================================================
  catalog_ids = merge(
    { for k, c in azuread_access_package_catalog.this : k => c.id },
    { for k, c in data.azuread_access_package_catalog.existing : k => c.id }
  )
}