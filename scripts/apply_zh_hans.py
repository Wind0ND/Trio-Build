"""Apply Trio's Chinese overlay to the checked-out upstream localization tables."""

import argparse
import hashlib
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OVERLAY = ROOT / "Trio/Sources/Localizations/Dependencies/zh-Hans.json"
STRING_PAIR = re.compile(r'"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;')


def string_pairs(raw):
    encoding = "utf-16" if raw.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig"
    return {
        json.loads(f'"{key}"'): json.loads(f'"{value}"')
        for key, value in STRING_PAIR.findall(raw.decode(encoding))
    }


def source_for(key, entry):
    return entry.get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value", key)


def fingerprint(sources):
    canonical = json.dumps(sources, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def target_for(root, rel, item):
    path = (root / rel).resolve()
    if not path.is_relative_to(root) or not path.is_file():
        raise ValueError(f"Missing dependency resource: {rel} (initialize submodules first)")
    translations = item["strings"]

    if path.suffix == ".xcstrings":
        catalog = json.loads(path.read_bytes())
        entries = catalog["strings"]
        eligible = {key for key, entry in entries.items()
                    if key.strip() and entry.get("shouldTranslate") is not False}
        if eligible != translations.keys():
            raise ValueError(f"English catalog keys changed: {rel}. Review the overlay's coverage.")
        source = {key: source_for(key, entries[key]) for key in translations}
        if item["sourceSHA256"] != fingerprint(source):
            raise ValueError(f"English source changed: {rel}. Review translations before updating the overlay.")
        for key, translation in translations.items():
            entries[key].setdefault("localizations", {})["zh-Hans"] = {
                "stringUnit": {"state": "translated", "value": translation}
            }
        return path, json.dumps(catalog, ensure_ascii=False, indent=2).encode("utf-8") + b"\n"

    if path.suffix != ".strings" or path.parent.name != "en.lproj":
        raise ValueError(f"Unsupported dependency resource: {rel}")
    entries = string_pairs(path.read_bytes())
    if {key for key in entries if key.strip()} != translations.keys():
        raise ValueError(f"English table keys changed: {rel}. Review the overlay's coverage.")
    source = {key: entries[key] for key in translations}
    if item["sourceSHA256"] != fingerprint(source):
        raise ValueError(f"English source changed: {rel}. Review translations before updating the overlay.")

    path = path.parent.parent / "zh-Hans.lproj" / path.name
    existing = string_pairs(path.read_bytes()) if path.is_file() else {}
    existing.update(translations)
    result = "// Simplified Chinese localization maintained by Trio.\n"
    for key, value in sorted(existing.items()):
        result += f"{json.dumps(key, ensure_ascii=False)} = {json.dumps(value, ensure_ascii=False)};\n"
    return path, result.encode("utf-8")


def generated_catalog(root, rel, entries):
    path = (root / rel).resolve()
    if not path.is_relative_to(root) or path.suffix != ".xcstrings" or not path.parent.parent.is_dir():
        raise ValueError(f"Invalid new catalog path: {rel}")
    catalog = {
        "sourceLanguage": "en",
        "strings": {
            key: {"extractionState": "manual", "localizations": {
                "zh-Hans": {"stringUnit": {"state": "translated", "value": value}}
            }}
            for key, value in sorted(entries.items())
        },
        "version": "1.0",
    }
    raw = json.dumps(catalog, ensure_ascii=False, indent=2).encode("utf-8") + b"\n"
    if path.is_file() and path.read_bytes() != raw:
        raise ValueError(f"Upstream already owns {rel}. Integrate its new catalog into the overlay.")
    return path, raw


def patched_source(root, rel, replacements):
    path = (root / rel).resolve()
    if not path.is_relative_to(root) or path.suffix not in (".swift", ".pbxproj"):
        raise ValueError(f"Unsupported localization patch path: {rel}")
    raw = path.read_bytes()
    linebreak = "\r\n" if b"\r\n" in raw and b"\n" not in raw.replace(b"\r\n", b"") else "\n"
    contents = raw.decode("utf-8").replace("\r\n", "\n")
    for patch in replacements:
        before, after = patch["before"], patch["after"]
        if after in contents and before not in contents.replace(after, ""):
            continue
        if before not in contents or after in contents:
            raise ValueError(f"Source changed: {rel}. Review its localized call sites.")
        contents = contents.replace(before, after)
    return path, contents.replace("\n", linebreak).encode("utf-8")


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--check", action="store_true", help="Validate sources and translations without writing.")
    args = cli.parse_args()
    manifest = json.loads(OVERLAY.read_bytes())
    if manifest.get("language") != "zh-Hans" or manifest.get("version") != 1:
        cli.exit(1, "Unsupported localization overlay format.\n")
    mod_paths = set(re.findall(r"^\s*path\s*=\s*(\S+)\s*$", (ROOT / ".gitmodules").read_text(), re.M))
    staged = []
    for path, entry in manifest["files"].items():
        if Path(path).parts[0] not in mod_paths:
            cli.exit(1, f"Unexpected overlay dependency: {path}\n")
        try:
            staged.append(target_for(ROOT, path, entry))
        except (ValueError, KeyError, OSError) as err:
            cli.exit(1, f"Cannot apply localization to {path}: {err}\n")
    for field, transform in (
        ("generatedCatalogs", generated_catalog),
        ("sourcePatches", patched_source),
    ):
        for path, entry in manifest.get(field, {}).items():
            if Path(path).parts[0] != "SyaiKit":
                cli.exit(1, f"Unexpected {field} dependency: {path}\n")
            try:
                staged.append(transform(ROOT, path, entry))
            except (ValueError, KeyError, OSError) as err:
                cli.exit(1, f"Cannot prepare localization for {path}: {err}\n")
    if not args.check:
        for path, raw in staged:
            if not path.is_file() or path.read_bytes() != raw:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(raw)
    count = sum(len(f["strings"]) for f in manifest["files"].values())
    count += sum(len(entries) for entries in manifest.get("generatedCatalogs", {}).values())
    tables = len(manifest["files"]) + len(manifest.get("generatedCatalogs", {}))
    print(f"{'Validated' if args.check else 'Applied'} {count} zh-Hans translations in {tables} dependency tables.")


if __name__ == "__main__":
    main()
