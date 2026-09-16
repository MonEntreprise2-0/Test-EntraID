# ============================================================================
# VARIABLES — Variables globales du module
# ============================================================================

variable "tenant_id" {
  type        = string
  description = "ID du tenant Azure AD / Entra ID cible."

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.tenant_id))
    error_message = "Le tenant_id doit etre un UUID valide (ex: 12345678-abcd-1234-abcd-123456789012)."
  }
}

variable "use_oidc" {
  type        = bool
  default     = false
  description = "Utiliser OIDC pour l'authentification. Mettre a true dans GitHub Actions, false en local."
}

variable "declarations_path" {
  type        = string
  default     = "../declaration"
  description = "Chemin relatif vers le dossier contenant les fichiers YAML declaratifs."
}
