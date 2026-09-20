#!/usr/bin/env python3
"""Score `VaultClassifierEval needs --all --dump-json` against eval-oracle-terms.json.

usage: score-term-emission.py eval-library.json eval-oracle-terms.json needs.json [judged.json]

Recall  = of the videos whose title holds an OBSCURE oracle term, how many had it emitted.
Precision needs a human/LLM judgement of every emitted term that is not an oracle
term: pass judged.json = {"term": "good|word|title|fragment|garbage|known"}; terms
missing from it are listed so they can be judged.
"""
import json, sys, collections

def cjk(s): return any('぀' <= c <= '鿿' for c in s)
def match(sub, title):
    t, s = title.lower(), sub.lower(); i = t.find(s)
    while i >= 0:
        if cjk(s): return True
        b = t[i-1] if i > 0 else " "; a = t[i+len(s)] if i+len(s) < len(t) else " "
        if not (b.isalnum() or b == "_") and not (a.isalnum() or a == "_"): return True
        i = t.find(s, i+1)
    return False
def same(a, b):
    a, b = a.lower().strip(), b.lower().strip()
    return a == b or (len(a) >= 3 and a in b) or (len(b) >= 3 and b in a)

lib = {i["entryID"]: i for i in json.load(open(sys.argv[1]))["items"]}
oracle = json.load(open(sys.argv[2]))
rows = json.load(open(sys.argv[3]))
judged = json.load(open(sys.argv[4])) if len(sys.argv) > 4 else {}
FLOOR = 4

print(f"videos {len(rows)}   emitted >=1 term: {sum(1 for r in rows if r['terms'])}   total terms: {sum(len(r['terms']) for r in rows)}")
print("urgency:", dict(sorted(collections.Counter(r["urgency"] for r in rows).items())))

for label, keep in (("ALL videos (asked every time)", lambda r: True), (f"TRIGGERED only (urgency >= {FLOOR}, as shipped)", lambda r: r["urgency"] >= FLOOR)):
    need = found = 0; missed = []
    for r in rows:
        title = lib[r["entryID"]]["title"]
        want = [o["subject"] for o in oracle if o["obscure"] and match(o["subject"], title)]
        if not want: continue
        need += 1
        if keep(r) and any(same(t, w) for t in r["terms"] for w in want): found += 1
        else: missed.append((title, want, r["terms"], r["urgency"]))
    print(f"\n== {label} ==\n  RECALL: {found}/{need} videos with an unknown term had it named ({found/max(1,need):.0%})")
    if label.startswith("ALL"):
        for title, want, got, u in missed[:60]:
            print(f"   missed | u{u} | {title[:56]:56s} | wanted {want} | got {got}")

    cats = collections.Counter(); unjudged = []
    for r in rows:
        if not keep(r): continue
        for t in r["terms"]:
            if any(same(t, o["subject"]) for o in oracle): cats["good (oracle term)" if any(o["obscure"] and same(t, o["subject"]) for o in oracle) else "known (oracle, not obscure)"] += 1
            elif t in judged: cats[judged[t]] += 1
            else: cats["UNJUDGED"] += 1; unjudged.append((t, lib[r["entryID"]]["title"]))
    total = sum(cats.values()) or 1
    print("  PRECISION of emitted terms:")
    for k, v in cats.most_common(): print(f"    {k:28s} {v:4d}  {v/total:5.1%}")
    if label.startswith("ALL") and unjudged:
        print("\n  -- unjudged terms --")
        for t, title in unjudged: print(f"   {t!r:40s} | {title[:70]}")
