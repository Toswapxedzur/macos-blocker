#!/usr/bin/env python3
"""Score `VaultClassifierEval score --dump-json` predictions against eval-library.json.

usage: score-research-ab.py eval-library.json pred-all.json pred-none.json [pred-*.json ...]

The first prediction file is the production arm; every other file is compared
with it. Scoring is label-cardinality safe (the library carries one primary
label per video, the model may emit up to three):
  hit  = the video's primary label, or one of its ancestors/descendants, was predicted
  bad  = a predicted tag that is neither the label, an ancestor of it, nor listed
         as `alsoAcceptable`
A no-tag video is right only when the model declines.
"""
import json, sys

PARENT = {
    "Minecraft": "Gaming", "Clash Royale": "Gaming", "Speedruns": "Gaming",
    "AI & Software": "Technology", "Hardware Reviews": "Technology",
    "Comedy & Memes": "Entertainment", "Movies & TV": "Entertainment",
    "Food & Cooking": "Lifestyle", "Travel": "Lifestyle",
}

def related(a, b):
    return a == b or PARENT.get(a) == b or PARENT.get(b) == a

def judge(item, tags):
    truth, okay = item["trueTags"], item.get("alsoAcceptable", [])
    names = [t["name"] for t in tags]
    if not truth:
        return {"hit": not names, "exact": not names, "bad": sum(1 for n in names if n not in okay), "n": len(names)}
    hit = any(related(n, t) for n in names for t in truth)
    exact = any(n in truth for n in names)
    bad = sum(1 for n in names if not any(related(n, t) for t in truth) and n not in okay)
    return {"hit": hit, "exact": exact, "bad": bad, "n": len(names)}

def summarize(rows):
    n = len(rows) or 1
    tags = sum(r["n"] for r in rows) or 1
    return (f"n={len(rows):3d}  hit {sum(r['hit'] for r in rows)/n:5.1%}  exact-leaf {sum(r['exact'] for r in rows)/n:5.1%}"
            f"  wrong-tags {sum(r['bad'] for r in rows)/tags:5.1%} of {tags} emitted"
            f"  declined {sum(1 for r in rows if r['n'] == 0)/n:5.1%}")

library = {i["entryID"]: i for i in json.load(open(sys.argv[1]))["items"]}
arms = {p: {r["entryID"]: r for r in json.load(open(p))} for p in sys.argv[2:]}
base_path = sys.argv[2]
base = arms[base_path]
touched = {e for e, r in base.items() if r["knowledgeRefs"]}
term_touched = {e for e, r in base.items() if any(not k.startswith("creator:") for k in r["knowledgeRefs"])}
creator_touched = touched - term_touched

groups = [("all videos", set(library)), ("research touched", touched), ("  term knowledge in prompt", term_touched),
          ("  creator description only", creator_touched), ("research untouched", set(library) - touched),
          ("confident labels only", {e for e, i in library.items() if not i.get("uncertain")})]
for label, ids in groups:
    print(f"\n== {label} ==")
    for path, preds in arms.items():
        print(f"  {path.split('/')[-1]:20s} {summarize([judge(library[e], preds[e]['tags']) for e in ids if e in preds])}")

for path, preds in arms.items():
    if path == base_path: continue
    fixed = broke = changed = 0
    examples = {"fixed": [], "broke": []}
    for e in library:
        a, b = judge(library[e], base[e]["tags"]), judge(library[e], preds[e]["tags"])
        if [t["name"] for t in base[e]["tags"]] != [t["name"] for t in preds[e]["tags"]]: changed += 1
        good_a, good_b = a["hit"] and not a["bad"], b["hit"] and not b["bad"]
        if good_a and not good_b: fixed += 1; examples["fixed"].append(e)
        if good_b and not good_a: broke += 1; examples["broke"].append(e)
    print(f"\n== {base_path.split('/')[-1]} vs {path.split('/')[-1]} ==")
    print(f"  predictions that differ: {changed}   research FIXED: {fixed}   research BROKE: {broke}")
    for kind in ("fixed", "broke"):
        for e in examples[kind][:40]:
            i = library[e]
            fmt = lambda r: ", ".join(f"{t['name']}·{t['confidence']}" for t in r["tags"]) or "declined"
            print(f"   {kind:5s} | {i['title'][:60]:60s} | truth {'/'.join(i['trueTags']) or 'none':22s} | with: {fmt(base[e]):34s} | without: {fmt(preds[e])}")
