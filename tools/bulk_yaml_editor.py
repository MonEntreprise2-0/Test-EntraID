#!/usr/bin/env python3
"""
Ardian Cloud IAM — Local Mass YAML Editor
Outil d'administration locale pour la modification transverse et le packaging GitOps.

Arborescence supportée : declaration/<nomapplication>/<nomapplication>.yaml
"""

import os
import sys
import glob
import json
import difflib
import argparse
import zipfile
from datetime import datetime
from pathlib import Path
from typing import List, Dict, Any

try:
    from ruamel.yaml import YAML
    import jsonschema
except ImportError:
    print("❌ Erreur : modules manquants. Exécutez : pip install ruamel.yaml jsonschema", file=sys.stderr)
    sys.exit(1)


class MassYamlModifier:
    """Gestionnaire de modifications en masse de déclarations d'habilitations."""

    def __init__(self, declaration_dir: str = "declaration", schema_path: str = "schemas/app-declaration.schema.json"):
        self.declaration_dir = Path(declaration_dir)
        self.schema_path = Path(schema_path)
        self.yaml = YAML()
        self.yaml.preserve_quotes = True
        self.yaml.indent(mapping=2, sequence=4, offset=2)
        self.schema = self._load_schema()
        self.modified_files: List[Path] = []

    def _load_schema(self) -> Dict[str, Any]:
        """Charge le schéma JSON officiel pour la validation en local."""
        if not self.schema_path.exists():
            print(f"⚠️ Avertissement : Schéma non trouvé à l'emplacement {self.schema_path}")
            return {}
        with open(self.schema_path, "r", encoding="utf-8") as f:
            return json.load(f)

    def discover_files(self, app_filter: List[str] = None) -> List[Path]:
        """Isole les fichiers éligibles dans declaration/<app>/<app>.yaml."""
        targets = []
        if not self.declaration_dir.exists():
            return targets

        for app_dir in self.declaration_dir.iterdir():
            if app_dir.is_dir() and not app_dir.name.startswith("_"):
                if app_filter and app_dir.name.lower() not in [a.lower() for a in app_filter]:
                    continue
                yaml_file = app_dir / f"{app_dir.name}.yaml"
                if yaml_file.exists():
                    targets.append(yaml_file)
                else:
                    # Fallback sur tout fichier yaml du dossier
                    for f in app_dir.glob("*.yaml"):
                        if not f.name.startswith("_"):
                            targets.append(f)

        return sorted(targets)

    def replace_owner(self, data: Dict[str, Any], old_owner: str, new_owner: str) -> bool:
        """Remplace un email d'approbateur (insensible à la casse sur l'ancien email)."""
        changed = False
        old_owner_norm = old_owner.lower().strip()
        for pkg in data.get("access_packages", []):
            owners = pkg.get("authorization_owners", [])
            for idx, email in enumerate(owners):
                if str(email).lower().strip() == old_owner_norm:
                    owners[idx] = new_owner.strip()
                    changed = True
        return changed

    def add_owner(self, data: Dict[str, Any], new_owner: str) -> bool:
        """Ajoute un approbateur s'il n'est pas déjà présent."""
        changed = False
        new_owner_norm = new_owner.lower().strip()
        for pkg in data.get("access_packages", []):
            owners = pkg.get("authorization_owners", [])
            existing_owners = [str(o).lower().strip() for o in owners]
            if new_owner_norm not in existing_owners:
                owners.append(new_owner.strip())
                changed = True
        return changed

    def replace_group_reference(self, data: Dict[str, Any], old_group: str, new_group: str) -> bool:
        """Met à jour le nom d'un groupe de sécurité Entra ID (insensible à la casse)."""
        changed = False
        old_group_norm = old_group.lower().strip()
        for pkg in data.get("access_packages", []):
            for res in pkg.get("resources", []):
                if res.get("resource_type") == "EntraID Group":
                    curr_grp = str(res.get("group_name", "")).lower().strip()
                    if curr_grp == old_group_norm:
                        res["group_name"] = new_group.strip()
                        changed = True
        return changed

    def display_diff(self, file_path: Path, original_text: str, modified_text: str):
        """Affiche un différentiel coloré dans la console."""
        print(f"\n📄 Différentiel pour : {file_path.relative_to(self.declaration_dir.parent)}")
        diff = difflib.unified_diff(
            original_text.splitlines(),
            modified_text.splitlines(),
            fromfile=f"a/{file_path.name}",
            tofile=f"b/{file_path.name}",
            lineterm=""
        )
        for line in diff:
            if line.startswith("+") and not line.startswith("+++"):
                print(f"\033[92m{line}\033[0m")
            elif line.startswith("-") and not line.startswith("---"):
                print(f"\033[91m{line}\033[0m")
            elif line.startswith("@"):
                print(f"\033[94m{line}\033[0m")
            else:
                print(line)

    def validate_content(self, file_path: Path, data: Dict[str, Any]) -> bool:
        """Vérifie la conformité avec le JSON Schema."""
        if not self.schema:
            return True
        try:
            jsonschema.validate(instance=data, schema=self.schema)
            return True
        except jsonschema.ValidationError as err:
            print(f"❌ [Erreur Schéma] {file_path.name} : {err.message}")
            return False

    def create_zip_package(self, output_zip: str = None) -> Path:
        """Compresse uniquement les fichiers modifiés dans une archive ZIP."""
        if not self.modified_files:
            print("ℹ️ Aucun fichier modifié à archiver.")
            return None

        if not output_zip:
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            output_zip = f"bulk_update_{timestamp}.zip"

        zip_path = Path(output_zip)
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zipf:
            for file_path in self.modified_files:
                # Ajoute le fichier à la racine de l'archive ZIP
                zipf.write(file_path, arcname=file_path.name)

        print(f"\n📦 Archive ZIP générée avec succès : \033[1m{zip_path.resolve()}\033[0m")
        print(f"👉 Contient {len(self.modified_files)} fichier(s) YAML modifiés.")
        print("💡 Prochaine étape : Glissez-déposez ce fichier ZIP dans l'Issue GitHub [ADMIN ONLY] ⚡ Modification en Masse.")
        return zip_path


def main():
    parser = argparse.ArgumentParser(description="Modification en masse locale des fichiers YAML GitOps")
    parser.add_argument("--apps", nargs="+", help="Noms des applications ciblées")
    parser.add_argument("--dry-run", action="store_true", help="Prévisualise les changements sans modifier les fichiers")
    parser.add_argument("--zip", action="store_true", help="Génère automatiquement l'archive .zip pour l'Issue GitHub")
    parser.add_argument("--declaration-dir", default="declaration", help="Répertoire racine declaration/ (défaut: declaration)")

    group = parser.add_argument_group("Opérations métier")
    group.add_argument("--replace-owner", nargs=2, metavar=("OLD", "NEW"), help="Remplace un email d'approbateur")
    group.add_argument("--add-owner", metavar="EMAIL", help="Ajoute un email d'approbateur")
    group.add_argument("--replace-group", nargs=2, metavar=("OLD_GRP", "NEW_GRP"), help="Met à jour un nom de groupe Entra ID")

    args = parser.parse_args()
    modifier = MassYamlModifier(declaration_dir=args.declaration_dir)

    target_files = modifier.discover_files(args.apps)
    print(f"🔍 {len(target_files)} application(s) identifiée(s) dans '{args.declaration_dir}/'.")

    for file_path in target_files:
        with open(file_path, "r", encoding="utf-8") as f:
            raw_content = f.read()
        data = modifier.yaml.load(raw_content)

        changed = False
        if args.replace_owner:
            changed |= modifier.replace_owner(data, args.replace_owner[0], args.replace_owner[1])
        if args.add_owner:
            changed |= modifier.add_owner(data, args.add_owner)
        if args.replace_group:
            changed |= modifier.replace_group_reference(data, args.replace_group[0], args.replace_group[1])

        if changed:
            from io import StringIO
            stream = StringIO()
            modifier.yaml.dump(data, stream)
            new_content = stream.getvalue()

            if args.dry_run:
                modifier.display_diff(file_path, raw_content, new_content)
            else:
                if not modifier.validate_content(file_path, data):
                    print(f"⛔ Abandon de la modification sur {file_path.name} (échec validation schéma).")
                    continue

                with open(file_path, "w", encoding="utf-8") as f:
                    f.write(new_content)
                modifier.modified_files.append(file_path)
                print(f"✅ Modifié : {file_path.name}")

    if args.zip and not args.dry_run:
        modifier.create_zip_package()


if __name__ == "__main__":
    main()
