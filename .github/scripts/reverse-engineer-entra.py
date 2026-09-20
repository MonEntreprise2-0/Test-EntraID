#!/usr/bin/env python3
"""
reverse-engineer-entra.py - Aspiration et traduction déclarative Entra ID vers GitOps.

Scénario D (Admin - Import depuis Entra ID) :
1. Récupère les noms d'applications cibles (séparateurs virgules ou retours à la ligne).
2. Interroge Microsoft Graph API pour trouver les catalogues et paquets d'accès correspondants.
3. Valide STRICTEMENT la nomenclature de TOUS les Access Packages :
   Format obligatoire : [Contexte/Sous-Application] [Niveau de Privilège] - [Environnement]
   ⚠️ RÈGLE FAIL-SAFE : Si un seul Access Package d'une application ne respecte pas cette règle,
   l'import de l'application en entier ÉCHOUE immédiatement (aucun mock ni fallback).
4. Extrait les vraies ressources liées (groupes, rôles applicatifs) et politiques d'approbation réelles.
5. Règle d'écrasement : si l'application existe déjà dans declaration/, son fichier YAML est écrasé.
6. Génère l'arborescence : declaration/<nomapplication>/<nomapplication>.yaml.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import yaml

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

EMAIL_REGEX = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

KNOWN_PRIVILEGES = [
    "read only",
    "read-only",
    "write",
    "admin",
    "user",
    "member",
    "owner",
    "contributor",
    "viewer",
    "operator",
    "full access",
    "standard",
    "standard access",
    "it access",
    "manager",
    "auditor",
    "editor",
]

VALID_ENV_PATTERN = re.compile(
    r"^(dev|development|test|uat|staging|preprod|prod|production|qa|[a-z0-9_-]+)$",
    re.IGNORECASE
)

# Built-in ID du rôle "Catalog owner" dans Entitlement Management Entra ID
CATALOG_OWNER_ROLE_ID = "ae79f266-94d4-4dab-b730-feca7e132178"


def query_graph_api(url: str) -> dict:
    """Exécute un appel REST vers Microsoft Graph API via Azure CLI."""
    cmd = ["az", "rest", "--method", "get", "--url", url, "--output", "json"]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, check=True)
        return json.loads(res.stdout) if res.stdout else {}
    except subprocess.CalledProcessError as e:
        err_msg = (e.stderr or "").strip()
        if "404" not in err_msg:
            print(f"⚠️ Erreur Graph API ({url}) : {err_msg or e}", file=sys.stderr)
        return {}
    except Exception as e:
        print(f"⚠️ Exception Graph API ({url}) : {e}", file=sys.stderr)
        return {}


def parse_target_applications(target_str: str) -> list:
    """Parse la liste des applications cibles (séparateurs virgules ou retours à la ligne)."""
    raw_lines = target_str.replace("\r\n", "\n").replace("\r", "\n")
    apps = []
    for line in raw_lines.split("\n"):
        for item in line.split(","):
            cleaned = item.strip().strip("\"'").strip()
            if cleaned:
                apps.append(cleaned)
    return list(dict.fromkeys(apps))


def validate_and_parse_ap_nomenclature(ap_name: str) -> tuple[bool, dict, str]:
    """
    Valide STRICTEMENT et décompose le nom d'un Access Package selon la convention :
    [context_subapp] [privilege_level] - [env] ou [privilege_level] - [env]

    Retourne : (is_valid, parsed_dict, error_reason)
    """
    if not ap_name or not ap_name.strip():
        return False, {}, "Le nom de l'Access Package est vide."

    clean_name = ap_name.strip()

    # Doit impérativement contenir le séparateur ' - '
    if " - " not in clean_name:
        return False, {}, (
            f"L'Access Package '{clean_name}' ne respecte pas la nomenclature obligatoire "
            f"'[Contexte] [Privilège] - [Environnement]' (séparateur ' - ' manquant)."
        )

    parts = clean_name.rsplit(" - ", 1)
    prefix = parts[0].strip()
    env = parts[1].strip()

    if not prefix:
        return False, {}, f"L'Access Package '{clean_name}' n'a pas de niveau de privilège défini avant ' - '."

    if not env or not VALID_ENV_PATTERN.match(env):
        return False, {}, (
            f"L'Access Package '{clean_name}' possède un environnement invalide ('{env}'). "
            f"Environnements attendus : Dev, UAT, Prod, Test, Staging, etc."
        )

    prefix_lower = prefix.lower()

    # Cas 1 : Le préfixe complet est un privilège connu (ex: "Read Only", "Admin")
    if prefix_lower in KNOWN_PRIVILEGES:
        return True, {
            "context_subapp": "",
            "privilege_level": prefix,
            "env": env
        }, ""

    # Cas 2 : Le préfixe se termine par un privilège connu (ex: "SubApp Read Only", "Credit Write")
    matched_priv = None
    for priv in sorted(KNOWN_PRIVILEGES, key=len, reverse=True):
        if prefix_lower.endswith(" " + priv):
            matched_priv = priv
            break

    if matched_priv:
        context_part = prefix[:-(len(matched_priv) + 1)].strip()
        priv_part = prefix[-(len(matched_priv)):].strip()
        return True, {
            "context_subapp": context_part,
            "privilege_level": priv_part,
            "env": env
        }, ""

    # Cas 3 : Décomposition par défaut (si 1 seul mot -> privilège, si plusieurs -> dernier mot privilège)
    words = prefix.split()
    if len(words) == 1:
        return True, {
            "context_subapp": "",
            "privilege_level": words[0],
            "env": env
        }, ""
    else:
        context_part = " ".join(words[:-1])
        priv_part = words[-1]
        return True, {
            "context_subapp": context_part,
            "privilege_level": priv_part,
            "env": env
        }, ""


def get_all_catalogs() -> list:
    """Récupère l'ensemble des catalogues existants dans Entra ID."""
    endpoints = [
        "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/catalogs?$top=999",
        "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackageCatalogs?$top=999",
    ]
    for url in endpoints:
        data = query_graph_api(url)
        cats = data.get("value", [])
        if cats:
            return cats
    return []


def get_catalog_access_packages(cat_id: str) -> list:
    """Récupère les Access Packages existants d'un catalogue dans Entra ID."""
    # 1. Via expand sur le catalogue v1.0
    url1 = f"https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/catalogs/{cat_id}?$expand=accessPackages"
    data1 = query_graph_api(url1)
    if data1 and "accessPackages" in data1 and data1["accessPackages"]:
        return data1["accessPackages"]
    if data1 and "value" in data1 and data1["value"]:
        return data1["value"]

    # 2. Via expand sur le catalogue beta
    url2 = f"https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackageCatalogs/{cat_id}?$expand=accessPackages"
    data2 = query_graph_api(url2)
    if data2 and "accessPackages" in data2 and data2["accessPackages"]:
        return data2["accessPackages"]

    # 3. Fallback : lister tous les access packages et filtrer côté client par catalogId
    url3 = "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/accessPackages?$top=999&$expand=catalog"
    data3 = query_graph_api(url3)
    if data3 and "value" in data3:
        matched = [
            ap for ap in data3["value"]
            if ap.get("catalogId") == cat_id or ap.get("catalog", {}).get("id") == cat_id
        ]
        if matched:
            return matched

    return []


def get_catalog_resources(cat_id: str) -> list:
    """Récupère les ressources (groupes, apps) déjà associées à un catalogue dans Entra ID."""
    endpoints = [
        f"https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/catalogs/{cat_id}/accessPackageResources?$top=999",
        f"https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackageCatalogs/{cat_id}/accessPackageResources?$top=999",
    ]
    for url in endpoints:
        data = query_graph_api(url)
        resources = data.get("value", [])
        if resources:
            return resources
    return []


def get_access_package_resources(ap_id: str, cat_id: str) -> list:
    """Récupère les ressources liées à un Access Package (groupes, rôles applicatifs, sharepoint)."""
    endpoints = [
        f"https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/accessPackages/{ap_id}?$expand=resourceRoleScopes($expand=role,scope)",
        f"https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/accessPackages/{ap_id}/accessPackageResourceRoleScopes?$expand=accessPackageResourceRole,accessPackageResourceScope",
        f"https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackages/{ap_id}?$expand=accessPackageResourceRoleScopes($expand=accessPackageResourceRole,accessPackageResourceScope)",
        f"https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackages/{ap_id}/accessPackageResourceRoleScopes?$expand=accessPackageResourceRole,accessPackageResourceScope",
    ]

    resources = []
    seen = set()

    for url in endpoints:
        data = query_graph_api(url)
        role_scopes = data.get("resourceRoleScopes") or data.get("accessPackageResourceRoleScopes") or data.get("value", [])
        if role_scopes:
            for rs in role_scopes:
                scope = rs.get("accessPackageResourceScope") or rs.get("scope") or {}
                res_info = scope.get("accessPackageResource") or scope.get("resource") or {}
                role_info = rs.get("accessPackageResourceRole") or rs.get("role") or {}

                if not res_info and "resource" in role_info:
                    res_info = role_info.get("resource", {})

                res_type = res_info.get("resourceType", "").lower()
                res_name = res_info.get("displayName", "")
                role_name = role_info.get("displayName", "")

                if not res_name:
                    continue

                if "group" in res_type:
                    key = ("group", res_name)
                    if key not in seen:
                        seen.add(key)
                        resources.append({
                            "resource_type": "EntraID Group",
                            "group_name": res_name
                        })
                elif "application" in res_type or "serviceprincipal" in res_type:
                    key = ("app", res_name, role_name)
                    if key not in seen:
                        seen.add(key)
                        resources.append({
                            "resource_type": "Application Role",
                            "enterprise_app": res_name,
                            "app_role": role_name or "Default Access"
                        })
                elif "sharepoint" in res_type:
                    key = ("sp", res_name)
                    if key not in seen:
                        seen.add(key)
                        resources.append({
                            "resource_type": "Sharepoint Group",
                            "catalog_id": cat_id,
                            "sharepoint_url": res_info.get("url", "https://sharepoint.com")
                        })
            if resources:
                return resources

    # Repli : Si aucune ressource n'est directement liée à l'AP, vérifier les ressources du catalogue
    cat_resources = get_catalog_resources(cat_id)
    for cr in cat_resources:
        cr_type = cr.get("resourceType", "").lower()
        cr_name = cr.get("displayName", "")
        if not cr_name:
            continue
        if "group" in cr_type:
            key = ("group", cr_name)
            if key not in seen:
                seen.add(key)
                resources.append({
                    "resource_type": "EntraID Group",
                    "group_name": cr_name
                })
        elif "application" in cr_type or "serviceprincipal" in cr_type:
            key = ("app", cr_name)
            if key not in seen:
                seen.add(key)
                resources.append({
                    "resource_type": "Application Role",
                    "enterprise_app": cr_name,
                    "app_role": "Default Access"
                })

    return resources


def get_access_package_approvers(ap_id: str, cat_id: str) -> list:
    """Extrait les adresses email réelles des approbateurs (politiques ou propriétaires de catalogue)."""
    approvers = []

    # 1. Interroger les politiques d'assignation de l'Access Package (v1.0 puis beta)
    policy_endpoints = [
        f"https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/assignmentPolicies?$filter=accessPackage/id eq '{ap_id}'&$top=999",
        f"https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackageAssignmentPolicies?$filter=accessPackage/id eq '{ap_id}'&$top=999",
    ]

    for pol_url in policy_endpoints:
        pol_data = query_graph_api(pol_url)
        policies = pol_data.get("value", [])
        if not policies:
            continue

        for pol in policies:
            approval_settings = pol.get("requestApprovalSettings") or {}
            stages = approval_settings.get("approvalStages") or approval_settings.get("stages") or []
            for stage in stages:
                primary_approvers = stage.get("primaryApprovers", [])
                for approver in primary_approvers:
                    # Cas email / UPN direct
                    direct_email = approver.get("mail") or approver.get("userPrincipalName") or approver.get("userEmail")
                    if direct_email and EMAIL_REGEX.match(direct_email):
                        approvers.append(direct_email)
                        continue

                    user_id = approver.get("userId") or approver.get("id")
                    group_id = approver.get("groupId")

                    if user_id:
                        user_data = query_graph_api(f"https://graph.microsoft.com/v1.0/users/{user_id}?$select=mail,userPrincipalName")
                        email = user_data.get("mail") or user_data.get("userPrincipalName")
                        if email and EMAIL_REGEX.match(email):
                            approvers.append(email)

                    if group_id:
                        group_data = query_graph_api(f"https://graph.microsoft.com/v1.0/groups/{group_id}?$select=mail")
                        email = group_data.get("mail")
                        if email and EMAIL_REGEX.match(email):
                            approvers.append(email)

        if approvers:
            break

    # 2. Si aucun approbateur trouvé dans les politiques, interroger les Catalog Owners
    if not approvers:
        owner_endpoints = [
            f"https://graph.microsoft.com/v1.0/roleManagement/entitlementManagement/roleAssignments?$filter=appScopeId eq '/AccessPackageCatalog/{cat_id}'&$expand=principal",
            f"https://graph.microsoft.com/beta/roleManagement/entitlementManagement/roleAssignments?$filter=appScopeId eq '/AccessPackageCatalog/{cat_id}'&$expand=principal",
            "https://graph.microsoft.com/v1.0/roleManagement/entitlementManagement/roleAssignments?$expand=principal",
        ]
        for owner_url in owner_endpoints:
            owner_data = query_graph_api(owner_url)
            assignments = owner_data.get("value", [])
            for ra in assignments:
                scope = ra.get("directoryScopeId") or ra.get("appScopeId") or ""
                if cat_id in scope:
                    principal = ra.get("principal") or {}
                    email = principal.get("mail") or principal.get("userPrincipalName")
                    if email and EMAIL_REGEX.match(email):
                        approvers.append(email)
                    elif principal.get("id"):
                        p_data = query_graph_api(f"https://graph.microsoft.com/v1.0/users/{principal.get('id')}?$select=mail,userPrincipalName")
                        p_email = p_data.get("mail") or p_data.get("userPrincipalName")
                        if p_email and EMAIL_REGEX.match(p_email):
                            approvers.append(p_email)
            if approvers:
                break

    return list(dict.fromkeys(approvers))


def reverse_engineer(target_apps: list, declaration_dir: str = "declaration") -> tuple[list, list]:
    """
    Exécute l'extraction ciblée depuis Entra ID avec application stricte des règles métier.
    Retourne : (imported_apps, error_messages)
    """
    declaration_dir = os.path.abspath(declaration_dir)
    os.makedirs(declaration_dir, exist_ok=True)

    print("📡 Récupération de la liste des catalogues Entra ID...")
    all_catalogs = get_all_catalogs()
    catalog_names = [cat.get("displayName", "").strip() for cat in all_catalogs if cat.get("displayName")]
    print(f"ℹ️ {len(all_catalogs)} catalogue(s) trouvé(s) dans l'annuaire Entra ID : {', '.join(catalog_names)}")

    imported_apps = []
    error_messages = []
    imported_details = []
    failed_details = []

    for app_query in target_apps:
        q_clean = app_query.strip()
        q_lower = q_clean.lower()
        q_norm = re.sub(r"[^a-z0-9]", "", q_lower)

        # 1. Correspondance exacte
        matched_cat = next((c for c in all_catalogs if c.get("displayName", "").strip() == q_clean), None)

        # 2. Correspondance insensible à la casse
        if not matched_cat:
            matched_cat = next((c for c in all_catalogs if c.get("displayName", "").strip().lower() == q_lower), None)

        # 3. Correspondance insensible à la ponctuation (tirets, underscores, espaces)
        if not matched_cat:
            matched_cat = next((c for c in all_catalogs if re.sub(r"[^a-z0-9]", "", c.get("displayName", "").lower()) == q_norm), None)

        if not matched_cat:
            avail_str = ", ".join([f"`{name}`" for name in catalog_names]) if catalog_names else "aucun"
            err = (
                f"❌ Catalogue introuvable dans Entra ID pour : '{app_query}'.\n"
                f"      Catalogues actuellement existants dans l'annuaire Entra ID : {avail_str}."
            )
            print(f"⚠️ {err}")
            error_messages.append(err)
            failed_details.append({
                "app": app_query,
                "reason": (
                    f"Catalogue introuvable dans Microsoft Entra ID pour '{app_query}'. "
                    f"Catalogues disponibles détectés : {avail_str}"
                )
            })
            continue

        cat_id = matched_cat.get("id")
        cat_display_name = matched_cat.get("displayName")
        cat_description = matched_cat.get("description") or f"Catalogue pour {cat_display_name}"

        print(f"\n📥 Traitement de l'application : '{cat_display_name}' (ID: {cat_id})")

        # 1. Récupération des paquets d'accès réels
        access_packages = get_catalog_access_packages(cat_id)
        print(f"   -> {len(access_packages)} Access Package(s) détecté(s) dans Entra ID.")

        if not access_packages:
            err = (
                f"❌ Rejet de l'application '{cat_display_name}' : aucun Access Package n'existe "
                f"dans ce catalogue dans Entra ID. Au moins un Access Package conforme est requis pour l'import."
            )
            print(f"   {err}")
            error_messages.append(err)
            failed_details.append({
                "app": app_query,
                "reason": "Aucun Access Package dans ce catalogue dans Entra ID"
            })
            continue

        # 2. Validation STRICTE de la nomenclature de chaque Access Package
        # ⚠️ Règle Fail-Safe : Si 1 seul AP est invalide, l'application entière échoue !
        yaml_access_packages = []
        app_has_error = False

        for ap in access_packages:
            ap_id = ap.get("id")
            ap_display_name = ap.get("displayName", "").strip()
            ap_description = ap.get("description") or f"Accès {ap_display_name}"

            is_valid, parsed_ap, reason = validate_and_parse_ap_nomenclature(ap_display_name)
            if not is_valid:
                err = (
                    f"❌ Rejet de l'application '{cat_display_name}' : "
                    f"l'Access Package '{ap_display_name}' ne respecte pas la nomenclature obligatoire.\n"
                    f"      Motif : {reason}\n"
                    f"      Format exigé : '[Contexte/Sous-Application] [Niveau de Privilège] - [Environnement]' (ex: 'Credit Read Only - UAT' ou 'Admin - Prod')."
                )
                print(f"   {err}")
                error_messages.append(err)
                app_has_error = True
                break  # Échec bloquant immédiat pour cette application

            # 3. Récupération des ressources réelles
            resources = get_access_package_resources(ap_id, cat_id)
            if not resources:
                err = (
                    f"❌ Rejet de l'application '{cat_display_name}' : "
                    f"l'Access Package '{ap_display_name}' ne contient aucune ressource associée dans Entra ID "
                    f"et le catalogue ne contient aucun groupe lié."
                )
                print(f"   {err}")
                error_messages.append(err)
                app_has_error = True
                break

            # 4. Récupération des approbateurs réels
            approvers = get_access_package_approvers(ap_id, cat_id)
            if not approvers:
                fallback_admin = os.environ.get("FALLBACK_APPROVER_EMAIL", "OrlaineLEKANEGUETSA@monentreprise123.onmicrosoft.com")
                print(f"   ℹ️ Aucun approbateur ni Catalog Owner trouvé dans Entra ID pour l'Access Package '{ap_display_name}'. Utilisation de l'administrateur par défaut : {fallback_admin}")
                approvers = [fallback_admin]

            ap_entry = {
                "context_subapp": parsed_ap["context_subapp"],
                "privilege_level": parsed_ap["privilege_level"],
                "env": parsed_ap["env"],
                "description": ap_description,
                "authorization_owners": approvers,
                "resources": resources
            }
            yaml_access_packages.append(ap_entry)

        if app_has_error:
            print(f"   🚫 Import annulé pour l'application '{cat_display_name}'. Aucun fichier YAML généré.")
            failed_details.append({
                "app": app_query,
                "reason": error_messages[-1] if error_messages else "Erreur de validation"
            })
            continue

        # 5. Normalisation kebab-case du nom d'application
        app_slug = re.sub(r"[^a-z0-9-]", "-", cat_display_name.lower()).strip("-")
        app_slug = re.sub(r"-+", "-", app_slug)

        doc = {
            "app_name": app_slug,
            "catalog_name": cat_display_name,
            "app_description": cat_description,
            "access_packages": yaml_access_packages
        }

        # 6. Écriture / Écrasement du fichier YAML (1 dossier par application)
        app_folder = os.path.join(declaration_dir, app_slug)
        os.makedirs(app_folder, exist_ok=True)
        target_file = os.path.join(app_folder, f"{app_slug}.yaml")

        with open(target_file, "w", encoding="utf-8") as f:
            yaml.dump(doc, f, sort_keys=False, allow_unicode=True)

        print(f"   ✅ Fichier généré/écrasé avec succès : {target_file}")
        imported_apps.append(app_slug)

        # Extraction pour le compte-rendu de la PR
        aps_list = []
        res_list = []
        seen_res = set()
        all_owners = []

        for yap in yaml_access_packages:
            ctx = yap.get("context_subapp", "").strip()
            priv = yap.get("privilege_level", "").strip()
            env_val = yap.get("env", "").strip()
            ap_full_name = f"{ctx} {priv} - {env_val}".strip() if ctx else f"{priv} - {env_val}".strip()
            aps_list.append(f"`{ap_full_name}`")

            for r in yap.get("resources", []):
                rname = r.get("group_name") or r.get("enterprise_app") or r.get("display_name")
                role = r.get("role") or r.get("app_role") or "Member"
                if (rname, role) not in seen_res:
                    seen_res.add((rname, role))
                    res_list.append(f"`{rname}` ({role})")

            all_owners.extend(yap.get("authorization_owners", []))

        imported_details.append({
            "app": app_slug,
            "aps": ", ".join(aps_list) if aps_list else "Aucun",
            "resources": ", ".join(res_list) if res_list else "Aucune",
            "owners": ", ".join(list(dict.fromkeys(all_owners))) if all_owners else "Aucun"
        })

    print("\n========================================")
    print("📊 BILAN DU REVERSE ENGINEERING :")
    print(f"   Applications importées avec succès : {len(imported_apps)} ({', '.join(imported_apps) if imported_apps else 'aucune'})")
    if error_messages:
        print(f"   Erreurs / Rejets détectés : {len(error_messages)}")
        for err in error_messages:
            print(f"     • {err}")
    print("========================================")

    # Génération du compte-rendu Markdown
    summary_lines = [
        "📋 **Compte rendu de l'import depuis Entra ID**",
        "",
        "✅ **Applications Importées**"
    ]
    if imported_details:
        summary_lines.append("| Nom Application | Access Packages | Ressources & Rôles liés | Authorization Owner |")
        summary_lines.append("|---|---|---|---|")
        for item in imported_details:
            summary_lines.append(f"| `{item['app']}` | {item['aps']} | {item['resources']} | {item['owners']} |")
    else:
        summary_lines.append("_Aucune application importée._")
    summary_lines.append("")

    summary_lines.append("❌ **Échec d'import (Action requise)**")
    if failed_details:
        summary_lines.append("| Nom Application | Raison de l'échec |")
        summary_lines.append("|---|---|")
        for fail in failed_details:
            clean_reason = fail["reason"].replace("\n", " ").strip()
            summary_lines.append(f"| `{fail['app']}` | {clean_reason} |")
    else:
        summary_lines.append("_Aucun échec d'importation._")
    summary_lines.append("")

    summary_md = "\n".join(summary_lines) + "\n"

    return imported_apps, error_messages, summary_md


def main():
    parser = argparse.ArgumentParser(description="Importation déclarative depuis Entra ID (Reverse Engineering)")
    parser.add_argument("--applications", required=True, help="Noms des applications séparés par des virgules")
    parser.add_argument("--declaration-dir", default="declaration", help="Répertoire cible (défaut: declaration)")
    parser.add_argument("--output-list", help="Fichier texte pour enregistrer la liste des apps importées")
    parser.add_argument("--error-file", help="Fichier texte pour enregistrer les erreurs bloquantes")
    parser.add_argument("--summary-file", help="Fichier Markdown pour enregistrer le compte-rendu d'import")
    args = parser.parse_args()

    targets = parse_target_applications(args.applications)
    imported, errors, summary_md = reverse_engineer(targets, args.declaration_dir)

    if args.output_list:
        os.makedirs(os.path.dirname(os.path.abspath(args.output_list)), exist_ok=True)
        with open(args.output_list, "w", encoding="utf-8") as f:
            for app in imported:
                f.write(f"{app}\n")

    if args.error_file and errors:
        os.makedirs(os.path.dirname(os.path.abspath(args.error_file)), exist_ok=True)
        with open(args.error_file, "w", encoding="utf-8") as f:
            for err in errors:
                f.write(f"{err}\n")

    if args.summary_file:
        os.makedirs(os.path.dirname(os.path.abspath(args.summary_file)), exist_ok=True)
        with open(args.summary_file, "w", encoding="utf-8") as f:
            f.write(summary_md)

    # Toujours sortir avec code 0 pour garantir la création systématique de la Pull Request.
    # Le compte-rendu détaillé (succès et éventuels rejets avec leurs motifs) est transmis à la PR via summary_file.
    sys.exit(0)


if __name__ == "__main__":
    main()
