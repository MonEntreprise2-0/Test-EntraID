#!/usr/bin/env python3
"""
process-bulk-zip.py - Traite et deploie l'archive ZIP pour le Scenario C (Modification de masse).

Contraintes et verifications :
1. Inspection anti-traversée (Anti Zip-Slip).
2. Seuls les fichiers .yaml ou .yml sont acceptes.
3. Règle absolue : Ce scénario ne permet PAS de créer de nouvelles applications.
   Chaque application contenue dans le ZIP DOIT déjà exister dans `declaration/<nomapp>/`.
   Si une application est absente du repo, l'exécution s'interrompt avec une erreur bloquante.
4. Déploie chaque fichier dans son répertoire cible : declaration/<nomapp>/<nomapp>.yaml.
"""

import argparse
import os
import sys
import zipfile
import yaml


def process_bulk_zip(zip_path: str, declaration_dir: str = "declaration") -> list:
    """Decompresse, verifie et deploie les fichiers de l'archive ZIP."""
    if not os.path.isfile(zip_path):
        print(f"❌ Erreur : Fichier ZIP introuvable : {zip_path}", file=sys.stderr)
        sys.exit(1)

    declaration_dir = os.path.abspath(declaration_dir)
    modified_apps = []

    print(f"📦 Ouverture de l'archive : {zip_path}")
    with zipfile.ZipFile(zip_path, "r") as zf:
        # 1. Verification de sécurité
        for member in zf.infolist():
            # Anti Zip-Slip
            filename = member.filename
            if ".." in filename or filename.startswith("/") or filename.startswith("\\"):
                print(f"⛔ Alerte de securite : Chemin suspect detecte ({filename}). Traitement avorte.", file=sys.stderr)
                sys.exit(1)

            # Ignorer les dossiers ou fichiers caches MacOS / OS
            if member.is_dir() or os.path.basename(filename).startswith(".") or "__MACOSX" in filename:
                continue

            # Verifier l'extension
            if not (filename.lower().endswith(".yaml") or filename.lower().endswith(".yml")):
                print(f"❌ Erreur : Fichier non autorise dans l'archive : {filename}. Seuls les fichiers .yaml sont acceptes.", file=sys.stderr)
                sys.exit(1)

        # 2. Extraction en memoire et controle de pre-existence
        for member in zf.infolist():
            if member.is_dir() or os.path.basename(member.filename).startswith(".") or "__MACOSX" in member.filename:
                continue

            raw_bytes = zf.read(member)
            try:
                content = yaml.safe_load(raw_bytes.decode("utf-8"))
            except Exception as e:
                print(f"❌ Erreur de syntaxe YAML dans {member.filename} : {e}", file=sys.stderr)
                sys.exit(1)

            if not isinstance(content, dict):
                print(f"❌ Erreur : {member.filename} n'est pas un dictionnaire YAML valide.", file=sys.stderr)
                sys.exit(1)

            app_name = str(content.get("app_name") or content.get("application_name", "")).strip()
            if not app_name:
                # Si non specifie, tenter le nom du fichier sans extension
                app_name = os.path.splitext(os.path.basename(member.filename))[0]

            app_dir = os.path.join(declaration_dir, app_name.lower())

            # Verification de pre-existence (REGLE STRICTE SCENARIO C)
            if not os.path.isdir(app_dir):
                print(f"❌ Erreur bloquante : L'application '{app_name}' n'existe pas dans '{declaration_dir}'.", file=sys.stderr)
                print(f"   👉 Le scénario de modification de masse ne permet que de modifier des applications existantes.", file=sys.stderr)
                print(f"   Pour créer une nouvelle application, utilisez le scénario B (Création d'application).", file=sys.stderr)
                sys.exit(1)

            # 3. Ecriture du fichier dans declaration/<app_name>/<app_name>.yaml
            target_file = os.path.join(app_dir, f"{app_name.lower()}.yaml")
            with open(target_file, "wb") as f:
                f.write(raw_bytes)

            print(f"✅ Application mise à jour : {target_file}")
            modified_apps.append(app_name.lower())

    print(f"\n🎉 Décompression terminée avec succès : {len(modified_apps)} application(s) mise(s) à jour.")
    return modified_apps


def main():
    parser = argparse.ArgumentParser(description="Traite et deploie une archive ZIP de modification de masse")
    parser.add_argument("--zip-file", required=True, help="Chemin vers le fichier .zip")
    parser.add_argument("--declaration-dir", default="declaration", help="Dossier declaration/ (defaut: declaration)")
    parser.add_argument("--output-list", help="Fichier texte pour enregistrer la liste des apps modifiees")
    args = parser.parse_args()

    apps = process_bulk_zip(args.zip_file, args.declaration_dir)

    if args.output_list:
        with open(args.output_list, "w", encoding="utf-8") as f:
            for app in apps:
                f.write(f"{app}\n")


if __name__ == "__main__":
    main()
