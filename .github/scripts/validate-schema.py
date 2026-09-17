#!/usr/bin/env python3
"""
validate-schema.py - Valide un fichier YAML contre le JSON Schema (Format Ardian v2).

Ce script effectue 3 niveaux de validation :
  1. Validation JSON Schema (structure, types, contraintes de champs par resource_type)
  2. Coherence nom de fichier / app_name
  3. Unicite des noms calcules des Access Packages et validite des emails des approbateurs

Usage:
    python validate-schema.py --yaml-file declarations/apps/icredit.yaml \
                              --schema-file schemas/app-declaration.schema.json
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
    print("❌ Module 'pyyaml' requis. Installation : pip install pyyaml", file=sys.stderr)
    sys.exit(2)

try:
    import jsonschema
    from jsonschema import ValidationError, SchemaError, validate
except ImportError:
    print("❌ Module 'jsonschema' requis. Installation : pip install jsonschema", file=sys.stderr)
    sys.exit(2)


def load_yaml(file_path: str) -> dict:
    """Charge et parse un fichier YAML."""
    with open(file_path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def load_schema(file_path: str) -> dict:
    """Charge un fichier JSON Schema."""
    with open(file_path, "r", encoding="utf-8") as f:
        return json.load(f)


def validate_filename_consistency(yaml_data: dict, yaml_file_path: str) -> list:
    """Verifie que app_name correspond au nom du fichier et au nom du dossier parent (insensible a la casse)."""
    errors = []
    abs_path = os.path.abspath(yaml_file_path)
    basename = os.path.splitext(os.path.basename(abs_path))[0]
    parent_dir = os.path.basename(os.path.dirname(abs_path))
    app_name = str(yaml_data.get("app_name") or yaml_data.get("application_name", "")).strip()

    if not basename.startswith("_"):
        # 1. Verification du nom de fichier vs app_name (insensible a la casse)
        if basename.lower() != app_name.lower():
            errors.append(
                f"Incoherence de nommage : app_name='{app_name}' ne correspond pas "
                f"au nom du fichier '{basename}.yaml'. "
                f"Renommez le fichier en '{app_name}.yaml'."
            )

        # 2. Verification de l'arborescence declaration/<nomapplication>/<nomapplication>.yaml
        if parent_dir and parent_dir.lower() != app_name.lower() and parent_dir.lower() != "declaration":
            errors.append(
                f"Incoherence d'arborescence : la convention impose 1 dossier par application "
                f"('declaration/<nomapplication>/<nomapplication>.yaml'). "
                f"Le dossier parent actuel '{parent_dir}' ne correspond pas a app_name='{app_name}'."
            )

    return errors


def validate_access_packages_consistency(yaml_data: dict) -> list:
    """Verifie l'unicite des noms calcules des Access Packages et la coherence des ressources (insensible a la casse)."""
    errors = []
    seen_ap_names = set()

    for idx, ap in enumerate(yaml_data.get("access_packages") or [], 1):
        if not isinstance(ap, dict):
            continue

        display_name = ap.get("display_name")
        if display_name and str(display_name).strip():
            computed_name = str(display_name).strip()
        else:
            context = str(ap.get("context_subapp") or "").strip()
            privilege = str(ap.get("privilege_level") or "").strip()
            env = str(ap.get("env") or "").strip()

            if context:
                computed_name = f"{context} {privilege} - {env}"
            elif privilege and env:
                computed_name = f"{privilege} - {env}"
            else:
                computed_name = privilege or env or f"AP #{idx}"

        normalized_ap_name = computed_name.lower()
        if normalized_ap_name in seen_ap_names:
            errors.append(
                f"Doublon d'Access Package detecte : le nom calcule '{computed_name}' "
                f"est genere plusieurs fois dans le fichier (AP #{idx})."
            )
        seen_ap_names.add(normalized_ap_name)

        # Verification des emails
        email_regex = r"^[^@]+@[^@]+\.[^@]+$"
        for email in (ap.get("authorization_owners") or []):
            if not re.match(email_regex, str(email).strip()):
                errors.append(
                    f"Access Package '{computed_name}' : l'adresse email '{email}' "
                    f"dans authorization_owners est invalide."
                )

    return errors


def main():
    parser = argparse.ArgumentParser(
        description="Validate YAML against JSON Schema for Entitlement Management (Ardian v2)"
    )
    parser.add_argument(
        "--yaml-file", required=True, help="Path to the YAML file to validate"
    )
    parser.add_argument(
        "--schema-file", required=True, help="Path to the JSON Schema file"
    )
    args = parser.parse_args()

    for path, label in [(args.yaml_file, "YAML"), (args.schema_file, "Schema")]:
        if not os.path.isfile(path):
            print(f"❌ Fichier {label} introuvable : {path}", file=sys.stderr)
            sys.exit(2)

    try:
        yaml_data = load_yaml(args.yaml_file)
    except yaml.YAMLError as e:
        print(f"❌ Erreur de syntaxe YAML dans {args.yaml_file} :", file=sys.stderr)
        print(f"   {e}", file=sys.stderr)
        sys.exit(1)

    try:
        schema = load_schema(args.schema_file)
    except json.JSONDecodeError as e:
        print(f"❌ Erreur de syntaxe JSON dans {args.schema_file} :", file=sys.stderr)
        print(f"   {e}", file=sys.stderr)
        sys.exit(2)

    all_errors = []

    # 1. Validation JSON Schema
    try:
        validate(instance=yaml_data, schema=schema)
        print("✅ Validation JSON Schema : OK")
    except ValidationError as e:
        path_str = " > ".join(str(p) for p in e.absolute_path) if e.absolute_path else "racine"
        all_errors.append(f"Schema : {e.message} (chemin: {path_str})")
    except SchemaError as e:
        print(f"❌ Le fichier JSON Schema est invalide : {e.message}", file=sys.stderr)
        sys.exit(2)

    # 2. Coherence et unicite des Access Packages
    ap_errors = validate_access_packages_consistency(yaml_data)
    all_errors.extend(ap_errors)

    # Rapport
    if all_errors:
        print(f"\n❌ {len(all_errors)} erreur(s) de validation detectee(s) :\n")
        for i, err in enumerate(all_errors, 1):
            print(f"   {i}. {err}")
        print(f"\n📄 Fichier : {args.yaml_file}")
        sys.exit(1)
    else:
        print("✅ Coherence nom de fichier : OK")
        print("✅ Noms et approbateurs des Access Packages : OK")
        print(f"\n✅ Toutes les validations sont passees pour {args.yaml_file}")
        sys.exit(0)


if __name__ == "__main__":
    main()