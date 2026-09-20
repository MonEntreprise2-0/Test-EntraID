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

  # Mapping des utilisateurs decouverts de maniere insensible a la casse et par mail/UPN
  discovered_users = try(
    jsondecode(file("${path.module}/discovered_users.json")),
    {}
  )

  # =========================================================================
  # 2. EXTRACTION DES GROUPES (pour les blocs data SSoT)
  # =========================================================================

  # Groupes declares (support v1 et v2, insensible a la casse du type)
  resource_group_names = distinct(flatten([
    for app_name, app in local.apps : concat(
      # Schema v1
      [
        for res in try(app.resources, []) : lookup(res, "display_name", "")
        if contains(["group", "entraid group", "entra id group"], lower(trimspace(lookup(res, "type", lookup(res, "resource_type", "")))))
      ],
      # Schema v2
      flatten([
        for ap in try(app.access_packages, []) : [
          for res in try(ap.resources, []) : lookup(res, "group_name", lookup(res, "display_name", ""))
          if contains(["group", "entraid group", "entra id group"], lower(trimspace(lookup(res, "resource_type", lookup(res, "type", "")))))
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

  # Emails des approbateurs (authorization_owners) declares dans les Access Packages (schema v2)
  all_owner_emails = distinct(flatten([
    for app_name, app in local.apps : [
      for ap in try(app.access_packages, []) : [
        for email in try(ap.authorization_owners, []) : trimspace(email)
        if trimspace(email) != ""
      ]
    ]
  ]))

  # =========================================================================
  # 3. EXTRACTION DES APPLICATIONS (pour les blocs data SSoT)
  # =========================================================================

  all_application_names = distinct(flatten([
    for app_name, app in local.apps : concat(
      # Schema v1
      [
        for res in try(app.resources, []) : lookup(res, "display_name", "")
        if contains(["application", "application role", "app"], lower(trimspace(lookup(res, "type", lookup(res, "resource_type", "")))))
      ],
      # Schema v2
      flatten([
        for ap in try(app.access_packages, []) : [
          for res in try(ap.resources, []) : lookup(res, "enterprise_app", lookup(res, "display_name", ""))
          if contains(["application", "application role", "app"], lower(trimspace(lookup(res, "resource_type", lookup(res, "type", "")))))
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
            key          = "${app_name}|${lookup(res, "display_name", "")}"
            app_name     = app_name
            display_name = lookup(res, "display_name", "")
          } if contains(["group", "entraid group", "entra id group"], lower(trimspace(lookup(res, "type", lookup(res, "resource_type", "")))))
        ],
        # Schema v2
        flatten([
          for ap in try(app.access_packages, []) : [
            for res in try(ap.resources, []) : {
              key          = "${app_name}|${lookup(res, "group_name", lookup(res, "display_name", ""))}"
              app_name     = app_name
              display_name = lookup(res, "group_name", lookup(res, "display_name", ""))
            } if contains(["group", "entraid group", "entra id group"], lower(trimspace(lookup(res, "resource_type", lookup(res, "type", "")))))
          ]
        ])
      )
    ])) : item.key => item if item.display_name != ""
  }

  # Associations applications -> catalogues
  catalog_app_associations = {
    for item in distinct(flatten([
      for app_name, app in local.apps : concat(
        # Schema v1
        [
          for res in try(app.resources, []) : {
            key          = "${app_name}|${lookup(res, "display_name", "")}"
            app_name     = app_name
            display_name = lookup(res, "display_name", "")
          } if contains(["application", "application role", "app"], lower(trimspace(lookup(res, "type", lookup(res, "resource_type", "")))))
        ],
        # Schema v2
        flatten([
          for ap in try(app.access_packages, []) : [
            for res in try(ap.resources, []) : {
              key          = "${app_name}|${lookup(res, "enterprise_app", lookup(res, "display_name", ""))}"
              app_name     = app_name
              display_name = lookup(res, "enterprise_app", lookup(res, "display_name", ""))
            } if contains(["application", "application role", "app"], lower(trimspace(lookup(res, "resource_type", lookup(res, "type", "")))))
          ]
        ])
      )
    ])) : item.key => item if item.display_name != ""
  }

  # =========================================================================
  # 5. APLATISSEMENT — Access Packages
  # =========================================================================

  access_packages = {
    for item in flatten([
      for app_name, app in local.apps : [
        for ap in try(app.access_packages, []) : {
          key = "${app_name}|${try(
            coalesce(ap.display_name, trimspace("${try(ap.context_subapp, "") != "" ? "${ap.context_subapp} " : ""}${try(ap.privilege_level, "")} - ${try(ap.env, "")}")),
            trimspace("${try(ap.context_subapp, "") != "" ? "${ap.context_subapp} " : ""}${try(ap.privilege_level, "")} - ${try(ap.env, "")}")
          )}"
          app_name = app_name
          display_name = try(
            coalesce(ap.display_name, trimspace("${try(ap.context_subapp, "") != "" ? "${ap.context_subapp} " : ""}${try(ap.privilege_level, "")} - ${try(ap.env, "")}")),
            trimspace("${try(ap.context_subapp, "") != "" ? "${ap.context_subapp} " : ""}${try(ap.privilege_level, "")} - ${try(ap.env, "")}")
          )
          description = try(ap.description, "Access Package pour ${app_name}")
          hidden      = try(ap.hidden, false)
          authorization_owners = [
            for email in try(ap.authorization_owners, []) : trimspace(email)
            if trimspace(email) != ""
          ]
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
                coalesce(ap.display_name, trimspace("${try(ap.context_subapp, "") != "" ? "${ap.context_subapp} " : ""}${try(ap.privilege_level, "")} - ${try(ap.env, "")}")),
                trimspace("${try(ap.context_subapp, "") != "" ? "${ap.context_subapp} " : ""}${try(ap.privilege_level, "")} - ${try(ap.env, "")}")
              )}|${lookup(res, "group_name", lookup(res, "enterprise_app", lookup(res, "display_name", "")))}|${lookup(res, "role", lookup(res, "app_role", contains(["admin", "owner"], lower(try(ap.privilege_level, ""))) ? "Owner" : "Member"))}"
              app_name = app_name
              ap_key = "${app_name}|${try(
                coalesce(ap.display_name, trimspace("${try(ap.context_subapp, "") != "" ? "${ap.context_subapp} " : ""}${try(ap.privilege_level, "")} - ${try(ap.env, "")}")),
                trimspace("${try(ap.context_subapp, "") != "" ? "${ap.context_subapp} " : ""}${try(ap.privilege_level, "")} - ${try(ap.env, "")}")
              )}"
              resource_display_name = lookup(res, "group_name", lookup(res, "enterprise_app", lookup(res, "display_name", "")))
              resource_type         = contains(["application", "application role", "app"], lower(trimspace(lookup(res, "resource_type", lookup(res, "type", ""))))) ? "application" : "group"
              role                  = lookup(res, "role", lookup(res, "app_role", contains(["admin", "owner"], lower(try(ap.privilege_level, ""))) ? "Owner" : "Member"))
              catalog_assoc_key     = "${app_name}|${lookup(res, "group_name", lookup(res, "enterprise_app", lookup(res, "display_name", "")))}"
            } if !contains(["sharepoint group", "sharepoint"], lower(trimspace(lookup(res, "resource_type", lookup(res, "type", "")))))
          ]
        )
      ]
    ]) : item.key => item
  }

  # =========================================================================
  # 7. APLATISSEMENT — Politiques d'assignation
  # =========================================================================

  assignment_policies = {
    for ap_key, ap in local.access_packages :
    "${ap_key}|Politique" => {
      key                  = "${ap_key}|Politique"
      app_name             = ap.app_name
      ap_key               = ap_key
      display_name         = "Politique - ${ap.display_name}"
      requestor_scope_type = "all_members"
      requestor_groups     = []
      approval_required    = length(ap.authorization_owners) > 0
      approval_stages      = []
      assignment_type      = "expiring"
      duration_in_days     = 365
      review_enabled       = false
      review_frequency     = 180
      reviewer_type        = "Self"
      reviewer_groups      = []
      authorization_owners = ap.authorization_owners
    }
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