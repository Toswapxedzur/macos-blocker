#!/usr/bin/env python3
"""Check Mac Vault's fixed release locale set and guide structure."""

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "Sources/MacBlockerWebUI/WebAssets"
LOCALES = "ar bn de es fr hi id it ja ko nl pa pl pt ru th tr vi zh".split()
PLACEHOLDER = re.compile(r"\{[A-Za-z0-9_]+\}")
HEADING = re.compile(r"^(#{2,3}) ", re.MULTILINE)
FENCE = re.compile(r"^```[^\n]*\n.*?^```", re.MULTILINE | re.DOTALL)


def check(condition, message):
    if not condition:
        raise ValueError(message)


english = json.loads((ASSETS / "translation/en.json").read_text())
for locale in LOCALES:
    path = ASSETS / "translation" / f"{locale}.json"
    localized = json.loads(path.read_text())
    check(localized.keys() == english.keys(), f"{locale}: catalog keys differ")
    for key, source in english.items():
        value = localized[key]
        check(isinstance(value, str) and bool(value.strip()), f"{locale}/{key}: empty")
        check(
            set(PLACEHOLDER.findall(value)) == set(PLACEHOLDER.findall(source)),
            f"{locale}/{key}: placeholders differ",
        )

for folder, other in (("manual", "code-manual"), ("code-manual", "manual")):
    source = (ASSETS / folder / "en.md").read_text()
    source_headings = HEADING.findall(source)
    source_fences = FENCE.findall(source)
    for locale in LOCALES:
        path = ASSETS / folder / f"{locale}.md"
        text = path.read_text()
        check(HEADING.findall(text) == source_headings, f"{path}: section structure differs")
        check(f"../{other}/{locale}.md" in text, f"{path}: locale guide link missing")
        if folder == "code-manual":
            check(FENCE.findall(text) == source_fences, f"{path}: executable examples differ")
            for literal in ("v.ai({", "v.store(", "v.panel(", "v.file("):
                check(literal in text, f"{path}: {literal} reference missing")

print(f"Mac Vault localization structure verified: English + {len(LOCALES)} locales")
