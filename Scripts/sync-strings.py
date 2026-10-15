#!/usr/bin/env python3
"""Sync Localization/Localizable.xcstrings with the strings in the code.

    Scripts/sync-strings.py            # build, merge, report what's untranslated
    Scripts/sync-strings.py --check    # same, but exit 1 if any key lacks a translation

The compiler knows every localizable string — SwiftUI literals, String(localized:)
— with the exact key it looks up ("Now %@", "%lld words"). A build with
-emit-localized-strings writes them out per source file; this merges them into
the catalog: new keys are added, keys the code no longer has are marked stale,
translations are never touched. Translate in Xcode (open the .xcstrings file)
or by editing the JSON. The package's catalog lives outside the target so
SwiftPM leaves it alone and lookups stay on Bundle.main; make-app.sh compiles it.
"""
import glob
import json
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "Localization", "Localizable.xcstrings")
SCRATCH = os.path.join(ROOT, ".build", "l10n")
OUT = os.path.join(SCRATCH, "strings")
SOURCES = os.path.join(ROOT, "Sources", "Pretype") + os.sep


def extract():
    os.makedirs(OUT, exist_ok=True)
    for f in glob.glob(os.path.join(OUT, "*.stringsdata")):
        os.remove(f)
    # Recompile the app module from scratch every run (its own scratch path,
    # so the dev build is untouched): incremental builds only re-extract the
    # files they recompile, which would hide the rest of the keys.
    # realpath: `**` follows the debug -> <triple>/debug symlink, so one tree
    # can match twice, and the second rmtree would find it gone.
    for d in {os.path.realpath(p) for p in
              glob.glob(os.path.join(SCRATCH, "**", "Pretype.build"), recursive=True)}:
        shutil.rmtree(d)
    build = subprocess.run(["swift", "build", "--scratch-path", SCRATCH,
                            "-Xswiftc", "-emit-localized-strings",
                            "-Xswiftc", "-emit-localized-strings-path", "-Xswiftc", OUT],
                           cwd=ROOT, capture_output=True, text=True)
    if build.returncode:
        sys.exit(build.stdout[-3000:] + build.stderr[-3000:] + "\nbuild failed")
    keys = {}
    for f in glob.glob(os.path.join(OUT, "*.stringsdata")):
        data = json.load(open(f))
        if not data["source"].startswith(SOURCES):
            continue  # a dependency's strings
        for table, items in data["tables"].items():
            if table != "Localizable":
                continue
            for item in items:
                keys.setdefault(item["key"], item.get("comment", ""))
    return keys


def main():
    keys = extract()
    catalog = (json.load(open(CATALOG)) if os.path.exists(CATALOG)
               else {"sourceLanguage": "en", "strings": {}, "version": "1.0"})
    strings = catalog["strings"]
    for key, comment in keys.items():
        entry = strings.setdefault(key, {})
        entry.pop("extractionState", None)
        if comment:
            entry["comment"] = comment
        # Pure placeholders ("%@%@") are Text composition, not words.
        if not key.replace("%@", "").replace("%lld", "").strip():
            entry["shouldTranslate"] = False
    for key, entry in strings.items():
        if key not in keys:
            entry["extractionState"] = "stale"
    with open(CATALOG, "w") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : "))
        f.write("\n")

    languages = sorted({lang for e in strings.values() for lang in e.get("localizations", {})} - {"en"})
    missing = {lang: [k for k, e in strings.items()
                      if e.get("shouldTranslate", True) and e.get("extractionState") != "stale"
                      and lang not in e.get("localizations", {})]
               for lang in languages}
    stale = sum(e.get("extractionState") == "stale" for e in strings.values())
    print(f"{len(keys)} keys in the code, {stale} stale in the catalog")
    for lang, ks in missing.items():
        print(f"{lang}: {len(ks)} untranslated")
        for k in ks[:20]:
            print(f"    {k!r}")
    if "--check" in sys.argv and any(missing.values()):
        sys.exit(1)


if __name__ == "__main__":
    main()
