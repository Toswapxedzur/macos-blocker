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
classifier_strings = (ROOT / "classifier/Sources/VaultClassifierApp/WebAssets/strings.js").read_text()
classifier_pairs = re.findall(r'^  "([^"]+)": "((?:[^"\\]|\\.)*)",?$', classifier_strings, re.MULTILINE)
check(len(classifier_pairs) >= 300, "Classifier string source could not be read completely")
for key, encoded_value in classifier_pairs:
    value = json.loads('"' + encoded_value + '"')
    check(english.get("classifier." + key) == value, f"classifier.{key}: English catalog differs from UI source")
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
        check(not re.search(r"(?m)\S[ \t]+## ", text), f"{path}: heading embedded in a paragraph")
        if folder == "manual":
            main_sections = re.split(r"(?m)^## ", text)[1:]
            check(len(main_sections) == 8, f"{path}: user-guide sections differ")
            english_main_headings = set(re.findall(r"(?m)^## .+$", source))
            shared_english = english_main_headings & set(re.findall(r"(?m)^## .+$", text))
            check(not shared_english, f"{path}: untranslated guide heading: {sorted(shared_english)}")
            for index, section in enumerate(main_sections):
                before_subheading = re.split(r"(?m)^### ", section, maxsplit=1)[0]
                body = before_subheading.split("\n", 1)[-1].strip()
                check(len(body) >= 30, f"{path}: section {index + 1} has no explanation")
            check(
                all(line.count("ChatGPT subscription") <= 1 for line in text.splitlines()),
                f"{path}: repeated provider list in one paragraph",
            )
        if folder == "code-manual":
            check(FENCE.findall(text) == source_fences, f"{path}: executable examples differ")
            for literal in ("v.ai({", "v.store(", "v.panel(", "v.file("):
                check(literal in text, f"{path}: {literal} reference missing")
            sections = re.split(r"(?m)^## ", text)[1:]
            check("`v.store(request)`" in sections[6], f"{path}: Group records is out of order")
            check("store-conflict" in sections[6], f"{path}: Group records is incomplete")
            check("`v.ai({ prompt, input? })`" in sections[-1], f"{path}: AI calls is out of order")

print(f"Mac Vault localization structure verified: English + {len(LOCALES)} locales")
