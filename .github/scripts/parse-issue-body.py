#!/usr/bin/env python3
"""
parse-issue-body.py - Extrait les champs structures du corps d'une Issue GitHub.

Ce script parse le Markdown structure genere par les GitHub Issue Forms.
Chaque champ du formulaire produit un titre ### suivi de sa valeur.

Usage:
    python parse-issue-body.py --body "$ISSUE_BODY" --output-dir ./parsed

Produit:
    - output/app_name.txt       : Nom de l'application (kebab-case)
    - output/operation_type.txt : Type d'operation
    - output/app.yaml           : Contenu YAML extrait
"""

import argparse
import os
import re
import sys


def parse_issue_body(body: str) -> dict:
    """Parse le corps Markdown structure d'une Issue GitHub (Issue Forms).

    Les Issue Forms produisent un Markdown avec des titres ### pour chaque champ.
    Cette fonction decoupe le corps en sections et retourne un dictionnaire.
    """
    sections = {}
    current_section = None
    current_content = []

    for line in body.split("\n"):
        header_match = re.match(r"^###\s+(.+)$", line.strip())
        if header_match:
            # Sauvegarder la section precedente
            if current_section is not None:
                sections[current_section] = "\n".join(current_content).strip()
            current_section = header_match.group(1).strip()
            current_content = []
        else:
            current_content.append(line)

    # Sauvegarder la derniere section
    if current_section is not None:
        sections[current_section] = "\n".join(current_content).strip()

    return sections


def extract_yaml_content(raw_content: str) -> str:
    """Extrait le contenu YAML d'un bloc de code Markdown.

    Les textareas avec render: yaml produisent un bloc ```yaml ... ```.
    Cette fonction extrait le contenu entre les balises.
    """
    # Pattern: ```yaml\n...\n```
    pattern = r"```(?:yaml|yml)?\s*\n(.*?)```"
    match = re.search(pattern, raw_content, re.DOTALL)

    if match:
        return match.group(1).strip()

    # Fallback: si pas de code fences, retourner le contenu brut
    return raw_content.strip()


def validate_app_name(app_name: str) -> bool:
    """Valide que le nom suit la convention kebab-case."""
    return bool(re.match(r"^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$", app_name))


def main():
    parser = argparse.ArgumentParser(
        description="Parse GitHub Issue body for Entitlement Management"
    )
    parser.add_argument(
        "--body", required=True, help="Issue body content (Markdown)"
    )
    parser.add_argument(
        "--output-dir", required=True, help="Directory to write extracted files"
    )
    args = parser.parse_args()

    # ---- Parse les sections du corps de l'Issue ----
    sections = parse_issue_body(args.body)

    # ---- Extraction des champs ----
    app_name = sections.get("Nom de l'application", "").strip()
    operation_type = sections.get("Type d'op\u00e9ration", "").strip()
    yaml_raw = sections.get("Contenu YAML", "")
    justification = sections.get("Justification", "").strip()

    # ---- Validation du nom d'application ----
    if not app_name:
        print(
            "\u274c Erreur : Le champ 'Nom de l'application' est vide.",
            file=sys.stderr,
        )
        sys.exit(1)

    if not validate_app_name(app_name):
        print(
            f"\u274c Erreur : Le nom '{app_name}' ne respecte pas la convention kebab-case.",
            file=sys.stderr,
        )
        print(
            "   Format attendu : lettres minuscules, chiffres et tirets (3-64 caracteres).",
            file=sys.stderr,
        )
        sys.exit(1)

    # ---- Extraction du contenu YAML ----
    yaml_content = extract_yaml_content(yaml_raw)

    if not yaml_content:
        print("\u274c Erreur : Le contenu YAML est vide.", file=sys.stderr)
        sys.exit(1)

    # ---- Ecriture des fichiers de sortie ----
    os.makedirs(args.output_dir, exist_ok=True)

    with open(
        os.path.join(args.output_dir, "app_name.txt"), "w", encoding="utf-8"
    ) as f:
        f.write(app_name)

    with open(
        os.path.join(args.output_dir, "operation_type.txt"), "w", encoding="utf-8"
    ) as f:
        f.write(operation_type)

    with open(
        os.path.join(args.output_dir, "app.yaml"), "w", encoding="utf-8"
    ) as f:
        f.write(yaml_content + "\n")

    # ---- Resume ----
    print("\u2705 Issue parsee avec succes :")
    print(f"   Application : {app_name}")
    print(f"   Operation   : {operation_type}")
    print(f"   YAML        : {len(yaml_content)} caracteres extraits")

    return 0


if __name__ == "__main__":
    sys.exit(main())
