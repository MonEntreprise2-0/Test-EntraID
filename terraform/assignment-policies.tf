# ============================================================================
# POLITIQUES D'ASSIGNATION — azuread_access_package_assignment_policy
# ============================================================================
# Chaque politique definit :
#   - Qui peut demander l'acces (requestor_settings)
#   - Le workflow d'approbation (approval_settings)
#   - La duree de l'assignation (duration_in_days / expiration_date)
#   - La revue d'acces periodique (assignment_review_settings)
#
# Cle for_each : "<app>|<access_package>|<policy_display_name>"
# ============================================================================

resource "azuread_access_package_assignment_policy" "this" {
  for_each = local.assignment_policies

  access_package_id = azuread_access_package.this[each.value.ap_key].id
  display_name      = each.value.display_name
  description       = "Geree par Terraform - ${each.value.display_name}"

  # Duree de l'assignation
  duration_in_days = (
    each.value.assignment.type == "expiring"
    ? each.value.assignment.duration_in_days
    : 0  # 0 = permanent (pas d'expiration)
  )

  # ---------------------------------------------------------------------------
  # Qui peut demander cet Access Package
  # ---------------------------------------------------------------------------
  requestor_settings {
    scope_type        = lookup(local.scope_type_map, each.value.requestor.scope_type, "NoSubjects")
    requests_accepted = each.value.requestor.scope_type != "none"

    # Groupes eligibles (uniquement si scope_type = "specific")
    dynamic "requestor" {
      for_each = each.value.requestor.scope_type == "specific" ? each.value.requestor.groups : []
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
    approval_required = each.value.approval.required

    # Etapes d'approbation (1 a 3 etapes sequentielles)
    dynamic "approval_stage" {
      for_each = each.value.approval.required ? each.value.approval.stages : []
      content {
        approval_timeout_in_days = approval_stage.value.days_to_decide

        # Approbateurs principaux
        dynamic "primary_approver" {
          for_each = approval_stage.value.approver_groups
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
    for_each = try(each.value.review.enabled, false) ? [each.value.review] : []
    content {
      enabled          = true
      review_frequency = lookup(
        local.review_frequency_map,
        assignment_review_settings.value.frequency_in_days,
        "quarterly"  # Valeur par defaut si la frequence n'est pas dans la table
      )
      duration_in_days = min(assignment_review_settings.value.frequency_in_days, 14)
      review_type      = lookup(
        local.reviewer_type_map,
        assignment_review_settings.value.reviewer_type,
        "Self"
      )
      access_recommendation_enabled   = true
      approver_justification_required = false

      # Reviseurs specifiques (uniquement si reviewer_type = "specific")
      dynamic "reviewer" {
        for_each = try(assignment_review_settings.value.reviewer_groups, [])
        content {
          object_id    = data.azuread_group.all[reviewer.value].object_id
          subject_type = "groupMembers"
        }
      }
    }
  }
}
