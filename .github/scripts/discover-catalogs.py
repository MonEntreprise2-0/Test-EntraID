#!/usr/bin/env python3
"""
discover-catalogs.py - Decouverte automatique des catalogues et ressources Entra ID (Support Ardian v2).

Ce script :
1. Interroge Microsoft Graph API via Azure CLI (`az rest`) pour lister les catalogues.
2. Pour chaque catalogue existant, interroge les ressources deja associees.
3. Compare avec les declarations YAML (v1 et v2) :
   - Si le catalogue existe -> Mode Consommateur (`exists: true`).
   - Si une ressource (groupe, app) est deja associee au catalogue dans Entra ID ->
     Genere un bloc `import {}` dans `terraform/imports.tf` pour que Terraform
     l'adopte sans echouer avec `already exists`.
4. Resout les noms de groupes de maniere insensible a la casse et genere `terraform/discovered_groups.json`.

Sorties :
  - `terraform/discovered_catalogs.json`
  - `terraform/discovered_groups.json`
  - `terraform/discovered_summary.md`
  - `terraform/imports.tf` (si des ressources pre-associees sont detectees)
"""

import argparse
import json
import os
import subprocess
import sys

try:
    import yaml
except ImportError:
    print("Module pyyaml requis. Installation : pip install pyyaml", file=sys.stderr)
    sys.exit(1)


def get_entraid_catalogs() -> list:
    """Interroge Microsoft Graph API pour lister les catalogues Entra ID."""
    endpoints = [
        "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/catalogs?$top=999",
        "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackageCatalogs?$top=999",
    ]

    for url in endpoints:
        cmd = ["az", "rest", "--method", "get", "--url", url, "--output", "json"]
        try:
            result = subprocess.run(cmd, capture_output=True, text=True)
            if result.returncode == 0 and result.stdout:
                data = json.loads(result.stdout)
                catalogs = data.get("value", [])
                if catalogs:
                    print(f"📡 {len(catalogs)} catalogue(s) recupere(s) depuis {url}")
                    return catalogs
        except Exception:
            continue

    return []


def get_catalog_resources(catalog_id: str) -> list:
    """Recupere les ressources (groupes, apps) deja associees a un catalogue."""
    endpoints = [
        f"https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/catalogs/{catalog_id}/accessPackageResources?$top=999",
        f"https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackageCatalogs/{catalog_id}/accessPackageResources?$top=999",
    ]

    for url in endpoints:
        cmd = ["az", "rest", "--method", "get", "--url", url, "--output", "json"]
        try:
            result = subprocess.run(cmd, capture_output=True, text=True)
            if result.returncode == 0 and result.stdout:
                data = json.loads(result.stdout)
                return data.get("value", [])
        except Exception:
            continue

    return []


def get_entraid_groups() -> list:
    """Recupere la liste des groupes Entra ID pour la resolution insensible a la casse."""
    endpoints = [
        "https://graph.microsoft.com/v1.0/groups?$top=999&$select=id,displayName",
    ]
    for url in endpoints:
        cmd = ["az", "rest", "--method", "get", "--url", url, "--output", "json"]
        try:
            result = subprocess.run(cmd, capture_output=True, text=True)
            if result.returncode == 0 and result.stdout:
                data = json.loads(result.stdout)
                groups = data.get("value", [])
                if groups:
                    return groups
        except Exception:
            continue
    return []


def load_yaml_declarations(declarations_dir: str) -> dict:
    """Charge toutes les declarations d'applications YAML (v1 et v2)."""
    apps = {}
    if not os.path.isdir(declarations_dir):
        return apps

    for fname in os.listdir(declarations_dir):
        if fname.endswith(".yaml") or fname.endswith(".yml"):
            if fname.startswith("_"):
                continue
            fpath = os.path.join(declarations_dir, fname)
            try:
                with open(fpath, "r", encoding="utf-8") as f:
                    content = yaml.safe_load(f)
                    if content and isinstance(content, dict):
                        app_name = content.get("app_name") or content.get("application_name")
                        if app_name:
                            apps[app_name] = content
            except Exception as e:
                print(f"⚠️ Erreur de lecture de {fname} : {e}", file=sys.stderr)

    return apps


def extract_app_resources(app_data: dict) -> list:
    """Extrait la liste unique des ressources declarees dans l'application (support v1 et v2)."""
    resources = []
    seen = set()

    # Schema v1 (resources globales a la racine)
    if "resources" in app_data and isinstance(app_data["resources"], list):
        for res in app_data["resources"]:
            r_type = "group" if res.get("type") == "group" else "application"
            r_name = res.get("display_name", "").strip()
            if (r_type, r_name) not in seen and r_name:
                seen.add((r_type, r_name))
                resources.append({"type": r_type, "display_name": r_name})

    # Schema v2 (resources declarees sous chaque Access Package)
    for ap in app_data.get("access_packages", []):
        for res in ap.get("resources", []):
            rtype = res.get("resource_type", "")
            if rtype == "EntraID Group":
                r_type = "group"
                r_name = res.get("group_name", "").strip()
            elif rtype == "Application Role":
                r_type = "application"
                r_name = res.get("enterprise_app", "").strip()
            elif rtype == "Sharepoint Group":
                r_type = "sharepoint"
                r_name = res.get("sharepoint_url", "").strip()
            else:
                continue

            if (r_type, r_name) not in seen and r_name:
                seen.add((r_type, r_name))
                resources.append({"type": r_type, "display_name": r_name})

    return resources


def main():
    parser = argparse.ArgumentParser(description="Smart Discovery des catalogues et groupes Entra ID (Ardian v2)")
    parser.add_argument("--declarations-dir", required=True, help="Dossier declarations/apps")
    parser.add_argument("--output-file", required=True, help="Fichier JSON de sortie pour Terraform")
    args = parser.parse_args()

    print("====================================================")
    print("🔎 SMART DISCOVERY — Inventaire Entra ID (Ardian v2)")
    print("====================================================")

    entraid_catalogs = get_entraid_catalogs()
    print(f"📊 Catalogues recenses dans le tenant Entra ID : {len(entraid_catalogs)}")

    catalog_by_name = {}
    for c in entraid_catalogs:
        dname = c.get("displayName", "").strip()
        if dname:
            catalog_by_name[dname.lower()] = c

    apps = load_yaml_declarations(args.declarations_dir)
    print(f"📄 Applications declarees dans le repo : {len(apps)}")
    print("----------------------------------------------------")

    discovered = {}
    summary_lines = [
        "### 🔎 Statut des catalogues (Smart Discovery)",
        ""
    ]
    import_blocks = []

    for app_name, app_data in apps.items():
        # En v2 le nom du catalogue est app_name, en v1 catalog.display_name
        catalog_cfg = app_data.get("catalog", {})
        target_name = (
            app_data.get("catalog_name")
            or catalog_cfg.get("display_name")
            or app_data.get("app_name")
            or app_name
        ).strip()
        target_id = str(catalog_cfg.get("id", "")).strip()

        matched = None
        if target_id:
            for c in entraid_catalogs:
                if c.get("id", "").lower() == target_id.lower():
                    matched = c
                    break

        if not matched and target_name:
            matched = catalog_by_name.get(target_name.lower())

        app_resources = extract_app_resources(app_data)

        if matched:
            cat_id = matched.get("id")
            actual_name = matched.get("displayName")
            discovered[app_name] = {
                "exists": True,
                "id": cat_id,
                "display_name": actual_name,
                "status": "found_in_entraid"
            }
            print(f"  ✅ [{app_name}] Catalogue '{actual_name}' trouve dans Entra ID (ID: {cat_id})")
            summary_lines.append(f"- 📦 **{actual_name}** : Déjà existant dans Entra ID (Mode Consommateur, ID: `{cat_id}`)")

            # Verifier les ressources deja associees au catalogue dans Entra ID
            existing_resources = get_catalog_resources(cat_id)
            print(f"     -> {len(existing_resources)} ressource(s) deja presente(s) dans le catalogue")

            res_map = {}
            for r in existing_resources:
                r_name = r.get("displayName", "").strip().lower()
                origin_id = r.get("originId")
                if r_name and origin_id:
                    res_map[r_name] = origin_id

            # Pour chaque ressource de l'application, verifier si elle est deja dans le catalogue
            for res in app_resources:
                r_type = res["type"]
                r_display = res["display_name"]

                if r_display.lower() in res_map:
                    origin_id = res_map[r_display.lower()]
                    res_key = f"{app_name}|{r_display}"
                    target_res = "groups" if r_type == "group" else "apps"
                    import_id = f"{cat_id}/{origin_id}"

                    print(f"     🔗 Ressource '{r_display}' ({r_type}) deja liee au catalogue -> auto-import genere ({import_id})")
                    import_blocks.append(f'''import {{
  to = azuread_access_package_resource_catalog_association.{target_res}["{res_key}"]
  id = "{import_id}"
}}''')
        else:
            discovered[app_name] = {
                "exists": False,
                "id": None,
                "display_name": target_name,
                "status": "not_found"
            }
            print(f"  🆕 [{app_name}] Catalogue '{target_name}' non trouve dans Entra ID (sera cree)")
            summary_lines.append(f"- 🆕 **{target_name}** : Absent d'Entra ID (sera créé par Terraform)")

    # Resolution des groupes pour l'insensibilite a la casse
    print("----------------------------------------------------")
    print("🔎 Resolution insensible a la casse des groupes Entra ID...")
    entraid_groups = get_entraid_groups()
    group_by_name = {g.get("displayName", "").strip().lower(): g for g in entraid_groups if g.get("displayName")}

    discovered_groups = {}
    for app_name, app_data in apps.items():
        for res in extract_app_resources(app_data):
            if res["type"] == "group":
                gname = res["display_name"]
                g_match = group_by_name.get(gname.lower())
                if g_match:
                    discovered_groups[gname] = {
                        "id": g_match.get("id"),
                        "display_name": g_match.get("displayName")
                    }
                    print(f"  ✅ Groupe '{gname}' résolu -> '{g_match.get('displayName')}' (ID: {g_match.get('id')})")
                else:
                    discovered_groups[gname] = {
                        "id": None,
                        "display_name": gname
                    }

    # Ecriture des sorties
    out_dir = os.path.dirname(args.output_file)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    with open(args.output_file, "w", encoding="utf-8") as f:
        json.dump(discovered, f, indent=2)

    groups_file = os.path.join(out_dir if out_dir else ".", "discovered_groups.json")
    with open(groups_file, "w", encoding="utf-8") as f:
        json.dump(discovered_groups, f, indent=2)

    summary_file = os.path.join(out_dir if out_dir else ".", "discovered_summary.md")
    with open(summary_file, "w", encoding="utf-8") as f:
        f.write("\n".join(summary_lines) + "\n\n")

    imports_file = os.path.join(out_dir if out_dir else ".", "imports.tf")
    if import_blocks:
        with open(imports_file, "w", encoding="utf-8") as f:
            f.write("# ============================================================================\n")
            f.write("# IMPORTS AUTOMATIQUES — Generes par Smart Discovery (Ardian v2)\n")
            f.write("# ============================================================================\n\n")
            f.write("\n\n".join(import_blocks) + "\n")
        print(f"📥 {len(import_blocks)} bloc(s) d'import generes dans {imports_file}")
    else:
        if os.path.isfile(imports_file):
            os.remove(imports_file)

    print(f"💾 Fichiers JSON generes : {args.output_file}, {groups_file}")
    print("====================================================\n")


if __name__ == "__main__":
    main()