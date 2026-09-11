#!/usr/bin/env python3
"""
validate-schema.py - Valide un fichier YAML contre le JSON Schema.

Ce script effectue 3 niveaux de validation :
  1. Validation JSON Schema (structure, types, contraintes)
  2. Coherence nom de fichier / application_name
  3. Integrite des references (resource_roles -> resources)

Usage:
    python validate-schema.py --yaml-file declarations/apps/salesforce-crm.yaml \
                              --schema-file schemas/app-declaration.schema.json

Exit codes:
    0 : Validation reussie
    1 : Erreur de validation (schema non respecte)
    2 : Erreur technique (fichier introuvable, YAML invalide, etc.)
"""

import argparse
import json
import os
import sys

try:
    import yaml
except ImportError:
    print(
        "\u274c Module 'pyyaml' requis. Installation : pip install pyyaml",
        file=sys.stderr,
    )
    sys.exit(2)

try:
    import jsonschema
    from jsonschema import ValidationError, SchemaError, validate
except ImportError:
    print(
        "\u274c Module 'jsonschema' requis. Installation : pip install jsonschema",
        file=sys.stderr,
    )
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
    """Verifie que application_name correspond au nom du fichier."""
    errors = []
    basename = os.path.splitext(os.path.basename(yaml_file_path))[0]
    app_name = yaml_data.get("application_name", "")

    if basename != app_name and not basename.startswith("_"):
        errors.append(
            f"Incoherence : application_name='{app_name}' ne correspond pas "
            f"au nom du fichier '{basename}.yaml'. "
            f"Renommez le fichier en '{app_name}.yaml'."
        )

    return errors


def validate_resource_references(yaml_data: dict) -> list:
    """Verifie que les resource_roles referencent des ressources declarees."""
    errors = []

    # Collecter les ressources declarees
    declared_resources = set()
    for res in yaml_data.get("resources", []):
        declared_resources.add((res["display_name"], res["type"]))

    # Verifier chaque access_package
    for ap in yaml_data.get("access_packages", []):
        for rr in ap.get("resource_roles", []):
            ref = (rr["resource_display_name"], rr["resource_type"])
            if ref not in declared_resources:
                errors.append(
                    f"Access Package '{ap['display_name']}' : "
                    f"resource_role reference '{rr['resource_display_name']}' "
                    f"(type: {rr['resource_type']}) qui n'est pas declare "
                    f"dans la section 'resources'."
                )

    return errors


def main():
    parser = argparse.ArgumentParser(
        description="Validate YAML against JSON Schema for Entitlement Management"
    )
    parser.add_argument(
        "--yaml-file", required=True, help="Path to the YAML file to validate"
    )
    parser.add_argument(
        "--schema-file", required=True, help="Path to the JSON Schema file"
    )
    args = parser.parse_args()

    # ---- Verifier que les fichiers existent ----
    for path, label in [(args.yaml_file, "YAML"), (args.schema_file, "Schema")]:
        if not os.path.isfile(path):
            print(f"\u274c Fichier {label} introuvable : {path}", file=sys.stderr)
            sys.exit(2)

    # ---- Charger les fichiers ----
    try:
        yaml_data = load_yaml(args.yaml_file)
    except yaml.YAMLError as e:
        print(
            f"\u274c Erreur de syntaxe YAML dans {args.yaml_file} :",
            file=sys.stderr,
        )
        print(f"   {e}", file=sys.stderr)
        sys.exit(1)

    try:
        schema = load_schema(args.schema_file)
    except json.JSONDecodeError as e:
        print(
            f"\u274c Erreur de syntaxe JSON dans {args.schema_file} :",
            file=sys.stderr,
        )
        print(f"   {e}", file=sys.stderr)
        sys.exit(2)

    all_errors = []

    # ---- 1. Validation JSON Schema ----
    try:
        validate(instance=yaml_data, schema=schema)
        print("\u2705 Validation JSON Schema : OK")
    except ValidationError as e:
        path_str = " > ".join(str(p) for p in e.absolute_path) if e.absolute_path else "racine"
        all_errors.append(f"Schema : {e.message} (chemin: {path_str})")
    except SchemaError as e:
        print(
            f"\u274c Le fichier JSON Schema est invalide : {e.message}",
            file=sys.stderr,
        )
        sys.exit(2)

    # ---- 2. Coherence nom de fichier ----
    filename_errors = validate_filename_consistency(yaml_data, args.yaml_file)
    all_errors.extend(filename_errors)

    # ---- 3. Integrite des references ----
    ref_errors = validate_resource_references(yaml_data)
    all_errors.extend(ref_errors)

    # ---- Rapport ----
    if all_errors:
        print(f"\n\u274c {len(all_errors)} erreur(s) de validation detectee(s) :\n")
        for i, err in enumerate(all_errors, 1):
            print(f"   {i}. {err}")
        print(f"\n\ud83d\udcc4 Fichier : {args.yaml_file}")
        print(
            f"\ud83d\udca1 Consultez le fichier d'exemple : declarations/apps/_example.yaml"
        )
        sys.exit(1)
    else:
        print("\u2705 Validation des references : OK")
        print("\u2705 Coherence nom de fichier : OK")
        print(f"\n\u2705 Toutes les validations sont passees pour {args.yaml_file}")
        sys.exit(0)


if __name__ == "__main__":
    main()
