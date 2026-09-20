# ============================================================================
# POLITIQUES D'ASSIGNATION — azuread_access_package_assignment_policy
# ============================================================================
# Chaque politique definit :
#   - Qui peut demander l'acces (requestor_settings)
#   - Le workflow d'approbation (approval_settings)
#   - La duree de l'assignation (duration_in_days / expiration_date)
#   - La revue d'acces periodique (assignment_review_settings)
#
# Cle for_each : composite key
# ============================================================================

resource "azuread_access_package_assignment_policy" "this" {
  for_each = local.assignment_policies

  access_package_id = azuread_access_package.this[each.value.ap_key].id
  display_name      = each.value.display_name
  description       = "Geree par Terraform - ${each.value.display_name}"

  # Duree de l'assignation
  duration_in_days = (
    try(each.value.assignment_type, "expiring") == "expiring"
    ? try(each.value.duration_in_days, 365)
    : 0  # 0 = permanent (pas d'expiration)
  )

  # ---------------------------------------------------------------------------
  # Qui peut demander cet Access Package
  # ---------------------------------------------------------------------------
  requestor_settings {
    scope_type        = lookup(local.scope_type_map, try(each.value.requestor_scope_type, "none"), "NoSubjects")
    requests_accepted = try(each.value.requestor_scope_type, "none") != "none"

    # Groupes eligibles (uniquement si scope_type = "specific")
    dynamic "requestor" {
      for_each = try(each.value.requestor_scope_type, "") == "specific" ? try(each.value.requestor_groups, []) : []
      content {
        object_id    = data.azuread_group.all[requestor.value].object_id
        subject_type = "groupMembers"
      }
    }
  }

  # ---------------------------------------------------------------------------
  # Workflow d'approbation
  # ---------------------------------------------------------------------------
  approval_settings {
    approval_required = (
      length(try(each.value.authorization_owners, [])) > 0
      ||
      (try(each.value.approval_required, false) && length(try(each.value.approval_stages, [])) > 0)
    )

    # Etapes d'approbation Schema v2 (basees sur authorization_owners)
    dynamic "approval_stage" {
      for_each = length(try(each.value.authorization_owners, [])) > 0 ? [1] : []
      content {
        approval_timeout_in_days = 14

        # Approbateurs individuels declares dans authorization_owners
        dynamic "primary_approver" {
          for_each = try(each.value.authorization_owners, [])
          content {
            object_id    = data.azuread_user.owners[primary_approver.value].object_id
            subject_type = "singleUser"
          }
        }
      }
    }

    # Etapes d'approbation Schema v1 (basees sur approval_stages et groupes)
    dynamic "approval_stage" {
      for_each = (
        length(try(each.value.authorization_owners, [])) == 0 &&
        try(each.value.approval_required, false) &&
        length(try(each.value.approval_stages, [])) > 0
        ? each.value.approval_stages
        : []
      )
      content {
        approval_timeout_in_days = approval_stage.value.days_to_decide

        # Approbateurs principaux (groupes)
        dynamic "primary_approver" {
          for_each = try(approval_stage.value.approver_groups, [])
          content {
            object_id    = data.azuread_group.all[primary_approver.value].object_id
            subject_type = "groupMembers"
          }
        }

        # Approbateurs de secours (fallback)
        dynamic "alternative_approver" {
          for_each = try(approval_stage.value.fallback_approver_groups, [])
          content {
            object_id    = data.azuread_group.all[alternative_approver.value].object_id
            subject_type = "groupMembers"
          }
        }
      }
    }
  }

  # ---------------------------------------------------------------------------
  # Revue d'acces periodique (optionnel)
  # ---------------------------------------------------------------------------
  dynamic "assignment_review_settings" {
    for_each = try(each.value.review_enabled, false) ? [1] : []
    content {
      enabled          = true
      review_frequency = lookup(
        local.review_frequency_map,
        try(each.value.review_frequency, 180),
        "quarterly"
      )
      duration_in_days = min(try(each.value.review_frequency, 180), 14)
      review_type      = lookup(
        local.reviewer_type_map,
        try(each.value.reviewer_type, "Self"),
        "Self"
      )
      access_recommendation_enabled   = true
      approver_justification_required = false

      # Reviseurs specifiques (uniquement si reviewer_type = "specific")
      dynamic "reviewer" {
        for_each = try(each.value.reviewer_groups, [])
        content {
          object_id    = data.azuread_group.all[reviewer.value].object_id
          subject_type = "groupMembers"
        }
      }
    }
  }
}