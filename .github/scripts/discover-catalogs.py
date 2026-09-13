#!/usr/bin/env python3
"""
discover-catalogs.py - Decouverte automatique des catalogues et ressources Entra ID.

Ce script :
1. Interroge Microsoft Graph API via Azure CLI (`az rest`) pour lister les catalogues.
2. Pour chaque catalogue existant, interroge les ressources deja associees.
3. Compare avec les declarations YAML :
   - Si le catalogue existe -> Mode Consommateur (`exists: true`).
   - Si une ressource (groupe) est deja associee au catalogue dans Entra ID ->
     Genere un bloc `import {}` dans `terraform/imports.tf` pour que Terraform
     l'adopte sans echouer avec `already exists`.

Sorties :
  - `terraform/discovered_catalogs.json`
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
        except Exception as e:
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


def load_yaml_declarations(declarations_dir: str) -> dict:
    """Charge toutes les declarations d'applications YAML."""
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
                        app_name = content.get("application_name")
                        if app_name:
                            apps[app_name] = content
            except Exception as e:
                print(f"⚠️ Erreur de lecture de {fname} : {e}", file=sys.stderr)

    return apps


def main():
    parser = argparse.ArgumentParser(description="Smart Discovery des catalogues Entra ID")
    parser.add_argument("--declarations-dir", required=True, help="Dossier declarations/apps")
    parser.add_argument("--output-file", required=True, help="Fichier JSON de sortie pour Terraform")
    args = parser.parse_args()

    print("====================================================")
    print("🔎 SMART DISCOVERY — Inventaire Entra ID")
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
        catalog_cfg = app_data.get("catalog", {})
        target_name = str(catalog_cfg.get("display_name", "")).strip()
        target_id = str(catalog_cfg.get("id", "")).strip()

        matched = None
        if target_id:
            for c in entraid_catalogs:
                if c.get("id", "").lower() == target_id.lower():
                    matched = c
                    break

        if not matched and target_name:
            matched = catalog_by_name.get(target_name.lower())

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

            # Pour chaque ressource du YAML, verifier si elle est deja dans le catalogue
            for res in app_data.get("resources", []):
                r_type = res.get("type", "group")
                r_display = res.get("display_name", "").strip()

                if r_display.lower() in res_map:
                    origin_id = res_map[r_display.lower()]
                    res_key = f"{app_name}|{r_display}"
                    target_res = "groups" if r_type == "group" else "apps"
                    import_id = f"{cat_id}/{origin_id}"

                    print(f"     🔗 Ressource '{r_display}' deja liee au catalogue -> auto-import genere ({import_id})")
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

    print("----------------------------------------------------")

    # 3. Ecrire le fichier JSON pour Terraform
    out_dir = os.path.dirname(args.output_file)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    with open(args.output_file, "w", encoding="utf-8") as f:
        json.dump(discovered, f, indent=2)

    # 4. Ecrire le fichier Markdown de resume
    summary_file = os.path.join(out_dir if out_dir else ".", "discovered_summary.md")
    with open(summary_file, "w", encoding="utf-8") as f:
        f.write("\n".join(summary_lines) + "\n\n")

    # 5. Ecrire les blocs d'import automatique si necessaire
    imports_file = os.path.join(out_dir if out_dir else ".", "imports.tf")
    if import_blocks:
        with open(imports_file, "w", encoding="utf-8") as f:
            f.write("# ============================================================================\n")
            f.write("# IMPORTS AUTOMATIQUES — Generes par Smart Discovery\n")
            f.write("# ============================================================================\n\n")
            f.write("\n\n".join(import_blocks) + "\n")
        print(f"📥 {len(import_blocks)} bloc(s) d'import generes dans {imports_file}")
    else:
        # Nettoyer l'ancien imports.tf s'il existait
        if os.path.isfile(imports_file):
            os.remove(imports_file)

    print(f"💾 Fichier JSON genere : {args.output_file}")
    print("====================================================\n")


if __name__ == "__main__":
    main()