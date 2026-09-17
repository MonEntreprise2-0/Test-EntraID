#!/usr/bin/env python3
"""
format-pr-comment.py - Génère une synthèse ciblée chaque application pour les Pull Requests.

1. Isole l'application ou les applications modifiées dans la PR.
2. Compare les Access Packages déclarés dans le YAML pour l'application avec l'existant Entra ID.
3. Génère une nomenclature claire et unitaire :
   - ✅ Access Packages Créés : liste des packages à créer
   - ❌ Changements adoptés / Ácrasés : Access Packages existants mis à jour
   - ❌ Access Packages Supprimés : présents dans Entra ID pour ce catalogue, mais absents du YAML
4. Compile les statistiques globales du plan Terraform.
"""

import argparse
import json
import os
import re
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

try:
    import yaml
except ImportError:
    print("Module pyyaml requis. Installation : pip install pyyaml", file=sys.stderr)
    sys.exit(1)


def compute_ap_name(ap: dict) -> str:
    display_name = ap.get("display_name")
    if display_name and str(display_name).strip():
        return str(display_name).strip()
    context = str(ap.get("context_subapp") or "").strip()
    privilege = str(ap.get("privilege_level") or "").strip()
    env = str(ap.get("env") or "").strip()
    if context:
        return f"{context} {privilege} - {env}".strip()
    elif privilege and env:
        return f"{privilege} - {env}".strip()
    return privilege or env or "Access Package"


def extract_resource_summary(res_list: list) -> str:
    items = []
    for r in (res_list or []):
        if not isinstance(r, dict):
            continue
        rname = r.get("group_name") or r.get("enterprise_app") or r.get("display_name") or "Ressource"
        role = r.get("role") or r.get("app_role") or "Member"
        items.append(f"`{rname}` ({role})")
    return ", ".join(items) if items else "Aucune"


def main():
    parser = argparse.ArgumentParser(description="Synthèse unitaire de PR pour Entitlement Management")
    parser.add_argument("--changed-files", default="", help="Liste des fichiers YAML modifiés")
    parser.add_argument("--tfplan-json", default="", help="Chemin vers tfplan.json")
    parser.add_argument("--catalog-packages-json", default="", help="Chemin vers entraid_catalog_packages.json")
    parser.add_argument("--discovered-summary", default="", help="Chemin vers discovered_summary.md")
    parser.add_argument("--plan-output", default="", help="Chemin vers plan_output.txt")
    parser.add_argument("--output-file", required=True, help="Chemin du fichier Markdown généré")
    args = parser.parse_args()

    catalog_packages = {}
    if args.catalog_packages_json and os.path.isfile(args.catalog_packages_json):
        try:
            with open(args.catalog_packages_json, "r", encoding="utf-8") as f:
                catalog_packages = json.load(f)
        except Exception as e:
            print(f"⚠️ Erreur de lecture de {args.catalog_packages_json}: {e}", file=sys.stderr)

    files = [f.strip() for f in args.changed_files.split() if f.strip().endswith(".yaml") or f.strip().endswith(".yml")]
    if not files:
        for root, _, fnames in os.walk("declaration"):
            for fn in fnames:
                if (fn.endswith(".yaml") or fn.endswith(".yml")) and not fn.startswith("_"):
                    files.append(os.path.join(root, fn))

    creates = "0"
    updates = "0"
    destroys = "0"
    replaces = "0"
    no_change = False

    if args.plan_output and os.path.isfile(args.plan_output):
        try:
            with open(args.plan_output, "r", encoding="utf-8", errors="ignore") as pf:
                content = pf.read()
                creates = str(len(re.findall(r"# .* will be created", content)))
                updates = str(len(re.findall(r"# .* will be updated", content)))
                destroys = str(len(re.findall(r"# .* will be destroyed", content)))
                replaces = str(len(re.findall(r"# .* must be replaced", content)))
                if "No changes." in content:
                    no_change = True
        except Exception:
            pass

    output_lines = [
        "## 📋 Synthèse Ciblée du Plan de Déploiement Entra ID",
        ""
    ]

    if args.discovered_summary and os.path.isfile(args.discovered_summary):
        try:
            with open(args.discovered_summary, "r", encoding="utf-8") as sf:
                dt = sf.read().strip()
                if dt:
                    output_lines.append(dt)
                    output_lines.append("")
        except Exception:
            pass

    for fpath in files:
        if not os.path.isfile(fpath):
            continue
        try:
            with open(fpath, "r", encoding="utf-8") as f:
                app_data = yaml.safe_load(f)
        except Exception as e:
            continue

        if not isinstance(app_data, dict):
            continue

        app_name = app_data.get("app_name") or app_data.get("application_name") or os.path.splitext(os.path.basename(fpath))[0]
        catalog_name = app_data.get("catalog_name") or app_data.get("catalog", {}).get("display_name") or app_name

        output_lines.append(f"### 🎯 Application ciblée : `{app_name}` (Catalogue : `{catalog_name}`)")
        output_lines.append("")

        declared_aps = {}
        for ap in (app_data.get("access_packages") or []):
            if not isinstance(ap, dict):
                continue
            name = compute_ap_name(ap)
            declared_aps[name.lower()] = {
                "name": name,
                "env": ap.get("env", "N/A"),
                "privilege": ap.get("privilege_level", "N/A"),
                "resources": ap.get("resources") or ap.get("resource_roles") or []
            }

        existing_for_app = catalog_packages.get(app_name) or []
        existing_aps = {p.get("display_name", "").strip().lower(): p for p in existing_for_app if p.get("display_name")}


        created_list = []
        modified_list = []
        deleted_list = []


        for ap_lower, ap_info in declared_aps.items():
            if ap_lower in existing_aps:
                ext = existing_aps[ap_lower]
                modified_list.append({
                    "name": ap_info["name"],
                    "id": ext.get("id", "N/A"),
                    "action": "Écrasé & adopté (Alignement YAML)",
                    "resources": extract_resource_summary(ap_info["resources"])
                })
            else:
                created_list.append({
                    "name": ap_info["name"],
                    "privilege": ap_info["privilege"],
                    "env": ap_info["env"],
                    "resources": extract_resource_summary(ap_info["resources"])
                })

        for ext_lower, ext_info in existing_aps.items():
            if ext_lower not in declared_aps:
                deleted_list.append({
                    "name": ext_info.get("display_name"),
                    "id": ext_info.get("id", "N/A"),
                    "status": "Absent du YAML (Non conservé)"
                })

        output_lines.append("#### ✅ Access Packages Créés")
        if created_list:
            output_lines.append("| Nom de l'Access Package | Niveau / Env | Ressources & Rôles liés |")
            output_lines.append("|---|---|---|")
            for c in created_list:
                output_lines.append(f"| **{c['name']}** | `{c['privilege']}` / `{c['env']}` | {c['resources']} |")
        else:
            output_lines.append("_Aucun nouveau Access Package à créer._")
        output_lines.append("")

        output_lines.append("#### 🔄 Access Packages Modifiés (Écrasés dans Entra ID)")
        if modified_list:
            output_lines.append("| Nom de l'Access Package | ID Entra ID | Ressources & Rôles cibles | Statut |")
            output_lines.append("|---|---|---|---|")
            for m in modified_list:
                output_lines.append(f"| **{m['name']}** | `{m['id']}` | {m['resources']} | 🔄 {m['action']} |")
        else:
            output_lines.append("_Aucun Access Package existant à écraser/modifier._")
        output_lines.append("")

        output_lines.append("#### ❌ Access Packages Supprimés")
        if deleted_list:
            output_lines.append("| Nom de l'Access Package | ID Entra ID | Remarque |")
            output_lines.append("|---|---|---|")
            for d in deleted_list:
                output_lines.append(f"| **{d['name']}** | `{d['id']}` | ⚠️ {d['status']} |")
        else:
            output_lines.append("_Aucun Access Package supprimé._")
        output_lines.append("")
        output_lines.append("---")

    output_lines.append("### 📊 Statistiques Globales Terraform")
    output_lines.append("")
    output_lines.append("| Action | Nombre d'Assets |")
    output_lines.append("|---|---|")
    output_lines.append(f"| 🆕 Assets à créer | {creates} |")
    output_lines.append(f"| ✏️ Assets à modifier / écraser | {updates} |")
    output_lines.append(f"| 🗑️ Assets à supprimer | {destroys} |")
    output_lines.append(f"| 🔄 Remplacements | {replaces} |")
    output_lines.append("")

    if no_change and creates == "0" and updates == "0" and destroys == "0":
        output_lines.append("✅ **Aucun changement détecté** — l'annuaire Entra ID (SSoT) est déjà parfaitement synchronisé.")
        output_lines.append("")

    out_dir = os.path.dirname(args.output_file)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    with open(args.output_file, "w", encoding="utf-8") as f:
        f.write("\n".join(output_lines) + "\n")

    print(f"✅ Synthèse unitaire générée avec succès dans {args.output_file}")


if __name__ == "__main__":
    main()
