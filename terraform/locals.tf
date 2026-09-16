# ============================================================================
# LOCALS — Chargement dynamique des fichiers YAML (Support Ardian v1 & v2)
# ============================================================================
# Ce fichier est le coeur du mecanisme data-driven :
# 1. fileset() decouvre tous les YAML dans declarations/apps/
# 2. yamldecode() parse chaque fichier en structure HCL
# 3. Les structures imbriquees (v1 ou v2) sont aplaties en maps pour for_each
# ============================================================================

locals {

  # =========================================================================
  # 1. CHARGEMENT DES FICHIERS YAML
  # =========================================================================

  # Decouvrir tous les fichiers YAML (exclure les fichiers prefixes par _)
  yaml_files = [
    for f in fileset("${path.module}/${var.declarations_path}", "**/*.yaml") :
    f if !startswith(basename(f), "_")
  ]

  # Parser chaque YAML en une map indexee par nom d'application
  apps = {
    for f in local.yaml_files :
    coalesce(
      try(yamldecode(file("${path.module}/${var.declarations_path}/${f}")).app_name, null),
      try(yamldecode(file("${path.module}/${var.declarations_path}/${f}")).application_name, null),
      trimsuffix(f, ".yaml")
    ) =>
    yamldecode(file("${path.module}/${var.declarations_path}/${f}"))
  }

  # Mapping des groupes decouverts de maniere insensible a la casse
  discovered_groups = try(
    jsondecode(file("${path.module}/discovered_groups.json")),
    {}
  )

  # =========================================================================
  # 2. EXTRACTION DES GROUPES (pour les blocs data SSoT)
  # =========================================================================

  # Groupes declares (support v1 et v2)
  resource_group_names = distinct(flatten([
    for app_name, app in local.apps : concat(
      # Schema v1
      [
        for res in try(app.resources, []) : res.display_name
        if try(res.type, "") == "group"
      ],
      # Schema v2
      flatten([
        for ap in try(app.access_packages, []) : [
          for res in try(ap.resources, []) : res.group_name
          if try(res.resource_type, "") == "EntraID Group"
        ]
      ])
    )
  ]))

  # Groupes references dans les politiques (demandeurs, approbateurs v1)
  policy_group_names = distinct(flatten([
    for app_name, app in local.apps : flatten([
      for ap in try(app.access_packages, []) : flatten([
        for pol in try(ap.policies, []) : concat(
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
    for app_name, app in local.apps : concat(
      # Schema v1
      [
        for res in try(app.resources, []) : res.display_name
        if try(res.type, "") == "application"
      ],
      # Schema v2
      flatten([
        for ap in try(app.access_packages, []) : [
          for res in try(ap.resources, []) : res.enterprise_app
          if try(res.resource_type, "") == "Application Role"
        ]
      ])
    )
  ]))

  # =========================================================================
  # 4. APLATISSEMENT — Associations Catalogue-Ressources
  # =========================================================================

  # Associations groupes -> catalogues
  catalog_group_associations = {
    for item in distinct(flatten([
      for app_name, app in local.apps : concat(
        # Schema v1
        [
          for res in try(app.resources, []) : {
            key          = "${app_name}|${res.display_name}"
            app_name     = app_name
            display_name = res.display_name
          } if try(res.type, "") == "group"
        ],
        # Schema v2
        flatten([
          for ap in try(app.access_packages, []) : [
            for res in try(ap.resources, []) : {
              key          = "${app_name}|${res.group_name}"
              app_name     = app_name
              display_name = res.group_name
            } if try(res.resource_type, "") == "EntraID Group"
          ]
        ])
      )
    ])) : item.key => item
  }

  # Associations applications -> catalogues
  catalog_app_associations = {
    for item in distinct(flatten([
      for app_name, app in local.apps : concat(
        # Schema v1
        [
          for res in try(app.resources, []) : {
            key          = "${app_name}|${res.display_name}"
            app_name     = app_name
            display_name = res.display_name
          } if try(res.type, "") == "application"
        ],
        # Schema v2
        flatten([
          for ap in try(app.access_packages, []) : [
            for res in try(ap.resources, []) : {
              key          = "${app_name}|${res.enterprise_app}"
              app_name     = app_name
              display_name = res.enterprise_app
            } if try(res.resource_type, "") == "Application Role"
          ]
        ])
      )
    ])) : item.key => item
  }

  # =========================================================================
  # 5. APLATISSEMENT — Access Packages
  # =========================================================================

  access_packages = {
    for item in flatten([
      for app_name, app in local.apps : [
        for ap in try(app.access_packages, []) : {
          key = "${app_name}|${try(
            ap.display_name,
            trimspace("${try(ap.context_subapp, "")} ${ap.privilege_level} - ${ap.env}")
          )}"
          app_name = app_name
          display_name = try(
            ap.display_name,
            trimspace("${try(ap.context_subapp, "")} ${ap.privilege_level} - ${ap.env}")
          )
          description = try(ap.description, "Access Package pour ${app_name}")
          hidden      = try(ap.hidden, false)
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
        for ap in try(app.access_packages, []) : concat(
          # Schema v1
          [
            for rr in try(ap.resource_roles, []) : {
              key                   = "${app_name}|${ap.display_name}|${rr.resource_display_name}|${rr.role}"
              app_name              = app_name
              ap_key                = "${app_name}|${ap.display_name}"
              resource_display_name = rr.resource_display_name
              resource_type         = rr.resource_type
              role                  = rr.role
              catalog_assoc_key     = "${app_name}|${rr.resource_display_name}"
            }
          ],
          # Schema v2
          [
            for res in try(ap.resources, []) : {
              key = "${app_name}|${try(
                ap.display_name,
                trimspace("${try(ap.context_subapp, "")} ${ap.privilege_level} - ${ap.env}")
              )}|${try(res.enterprise_app, res.group_name)}|${try(res.app_role, "Member")}"
              app_name = app_name
              ap_key = "${app_name}|${try(
                ap.display_name,
                trimspace("${try(ap.context_subapp, "")} ${ap.privilege_level} - ${ap.env}")
              )}"
              resource_display_name = try(res.enterprise_app, res.group_name)
              resource_type         = res.resource_type == "Application Role" ? "application" : "group"
              role                  = try(res.app_role, "Member")
              catalog_assoc_key     = "${app_name}|${try(res.enterprise_app, res.group_name)}"
            } if try(res.resource_type, "") != "Sharepoint Group"
          ]
        )
      ]
    ]) : item.key => item
  }

  # =========================================================================
  # 7. APLATISSEMENT — Politiques d'assignation
  # =========================================================================

  assignment_policies = {
    for item in flatten([
      for app_name, app in local.apps : [
        for ap in try(app.access_packages, []) : concat(
          # Schema v1
          [
            for pol in try(ap.policies, []) : {
              key          = "${app_name}|${ap.display_name}|${pol.display_name}"
              app_name     = app_name
              ap_key       = "${app_name}|${ap.display_name}"
              display_name = pol.display_name
              requestor    = pol.requestor
              approval     = pol.approval
              assignment   = pol.assignment
              review       = try(pol.review, { enabled = false })
              owner_only   = false
            }
          ],
          # Schema v2
          contains(keys(ap), "privilege_level") ? [
            {
              key = "${app_name}|${try(
                ap.display_name,
                trimspace("${try(ap.context_subapp, "")} ${ap.privilege_level} - ${ap.env}")
              )}|Politique"
              app_name = app_name
              ap_key = "${app_name}|${try(
                ap.display_name,
                trimspace("${try(ap.context_subapp, "")} ${ap.privilege_level} - ${ap.env}")
              )}"
              display_name = "Politique - ${try(
                ap.display_name,
                trimspace("${try(ap.context_subapp, "")} ${ap.privilege_level} - ${ap.env}")
              )}"
              authorization_owners = try(ap.authorization_owners, [])
              assignment           = { type = "expiring", duration_in_days = 365 }
              requestor = {
                scope_type = "all_members"
                groups     = []
              }
              approval = {
                required = true
                stages   = []
              }
              review = { enabled = false }
            }
          ] : []
        )
      ]
    ]) : item.key => item
  }

  # =========================================================================
  # 8. TABLES DE CONVERSION
  # =========================================================================

  review_frequency_map = {
    7   = "weekly"
    14  = "weekly"
    30  = "monthly"
    60  = "quarterly"
    90  = "quarterly"
    180 = "halfyearly"
    365 = "annual"
  }

  scope_type_map = {
    "all_members" = "AllExistingDirectoryMemberUsers"
    "specific"    = "SpecificDirectorySubjects"
    "none"        = "NoSubjects"
  }

  reviewer_type_map = {
    "self"     = "Self"
    "manager"  = "Manager"
    "specific" = "Reviewers"
  }

  # =========================================================================
  # 9. SMART DISCOVERY — Catalogues
  # =========================================================================

  discovered_catalogs = try(
    jsondecode(file("${path.module}/discovered_catalogs.json")),
    {}
  )

  catalog_ids = {
    for k, c in azuread_access_package_catalog.this : k => c.id
  }
}