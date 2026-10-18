#!/usr/bin/env python3
"""Sync Localization/Localizable.xcstrings with the strings in the code.

    Scripts/sync-strings.py            # build, merge, report what's untranslated
    Scripts/sync-strings.py --check    # same on a scratch copy (read-only), exit 1 if any key lacks a translation

The compiler knows every localizable string — SwiftUI literals, String(localized:)
— with the exact key it looks up ("Now %@", "%lld words"). A build with
-emit-localized-strings writes them out per source file; `xcstringstool sync`
merges them into the catalog the way Xcode does: new keys are added, keys the
code no longer has are marked stale (or dropped, if nothing translates them),
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
    # Only the app's own files: on a fresh scratch path the dependencies
    # compile with the same flag and write theirs here too.
    return [f for f in glob.glob(os.path.join(OUT, "*.stringsdata"))
            if json.load(open(f))["source"].startswith(SOURCES)]


def main():
    check = "--check" in sys.argv
    stringsdata = extract()
    # No files means the extraction broke, not that the app has no strings:
    # --check would pass on "0 keys", and a sync would mark every key stale.
    if not stringsdata:
        sys.exit(f"no .stringsdata for {SOURCES} in {OUT} — string extraction failed")
    # --check never writes the catalog: it syncs a copy in the scratch path.
    path = shutil.copy(CATALOG, SCRATCH) if check else CATALOG
    subprocess.run(["xcrun", "xcstringstool", "sync", path, "--stringsdata", *stringsdata], check=True)
    catalog = json.load(open(path))
    strings = catalog["strings"]
    # Pure placeholders ("%@%@") are Text composition, not words. Written back
    # only when a new one appeared; sync keeps the flag on the ones it has.
    pure = [e for k, e in strings.items()
            if not k.replace("%@", "").replace("%lld", "").strip() and e.get("shouldTranslate", True)]
    if pure:
        for entry in pure:
            entry["shouldTranslate"] = False
        with open(path, "w") as f:
            json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : "))

    languages = sorted({lang for e in strings.values() for lang in e.get("localizations", {})} - {"en"})
    missing = {lang: [k for k, e in strings.items()
                      if e.get("shouldTranslate", True) and e.get("extractionState") != "stale"
                      and lang not in e.get("localizations", {})]
               for lang in languages}
    stale = sum(e.get("extractionState") == "stale" for e in strings.values())
    print(f"{len(strings) - stale} keys in the code, {stale} stale in the catalog")
    for lang, ks in missing.items():
        print(f"{lang}: {len(ks)} untranslated")
        for k in ks[:20]:
            print(f"    {k!r}")
    if check and any(missing.values()):
        sys.exit(1)


if __name__ == "__main__":
    main()
