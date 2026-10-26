#!/usr/bin/env python3
import re, sys

stems = {
    "colour": "color", "behaviour": "behavior", "favourite": "favorite", "honour": "honor",
    "neighbour": "neighbor", "flavour": "flavor", "harbour": "harbor", "humour": "humor", "rumour": "rumor",
    "labour": "labor", "vapour": "vapor", "armour": "armor", "endeavour": "endeavor", "savour": "savor",
    "centre": "center", "licence": "license", "catalogue": "catalog", "artefact": "artifact",
    "judgement": "judgment", "defence": "defense", "offence": "offense", "grey": "gray", "whilst": "while",
    "programme": "program", "manoeuvre": "maneuver", "aluminium": "aluminum", "cheque": "check",
    "labelled": "labeled", "labelling": "labeling", "modelled": "modeled", "modelling": "modeling",
    "travelled": "traveled", "travelling": "traveling", "signalled": "signaled", "signalling": "signaling",
    "levelled": "leveled", "cancelling": "canceling", "fulfil": "fulfill", "enrol": "enroll",
    "analyse": "analyze", "analysed": "analyzed", "analysing": "analyzing", "paralyse": "paralyze",
}
ise_roots = ["organis", "recognis", "realis", "optimis", "initialis", "normalis", "customis", "minimis", "maximis",
             "prioritis", "summaris", "apologis", "utilis", "synchronis", "serialis", "deserialis", "visualis",
             "capitalis", "emphasis", "finalis", "authoris", "categoris", "standardis", "specialis", "stabilis",
             "sanitis", "memoris", "localis", "personalis", "materialis", "randomis", "tokenis", "parallelis",
             "criticis", "neutralis", "centralis", "generalis", "rasteris", "symbolis", "harmonis", "itemis",
             "penalis", "legitimis", "characteris", "amortis", "digitis", "virtualis", "containeris",
             "favouritis", "modernis", "rationalis", "summaris", "theoris", "trivialis", "vectoris", "jeopardis",
             "polaris", "patronis", "publicis", "scrutinis", "terroris", "unrecognis", "reorganis", "resynchronis",
             "reinitialis", "re-initialis", "desynchronis", "decentralis", "anonymis"]
endings = {"e": "e", "es": "es", "ed": "ed", "ing": "ing", "er": "er", "ers": "ers", "ation": "ation",
           "ations": "ations", "able": "able"}

def build():
    table = {}
    for k, v in stems.items():
        table[k] = v
        for suf in ["s", "ed", "ing", "ful", "less", "ings", "ists", "ist", "ize"]:
            if k.endswith("our") or k in ("grey",):
                table[k + suf] = v + suf
        if k == "centre":
            table["centres"] = "centers"; table["centred"] = "centered"; table["centring"] = "centering"
        if k == "licence":
            table["licences"] = "licenses"; table["licenced"] = "licensed"
        if k == "catalogue":
            table["catalogues"] = "catalogs"
        if k == "artefact":
            table["artefacts"] = "artifacts"
        if k == "programme":
            table["programmes"] = "programs"
        if k == "defence":
            table["defences"] = "defenses"
        if k == "cheque":
            table["cheques"] = "checks"
    for r in ise_roots:
        if r == "emphasis":
            for e in ["e", "es", "ed", "ing"]:
                table["emphasis" + e] = "emphasiz" + e
            continue
        for e in endings:
            table[r + e] = r[:-1] + "z" + e
    table.pop("emphasis", None)
    return table

table = build()
word = re.compile(r"\b(" + "|".join(sorted(map(re.escape, table), key=len, reverse=True)) + r")\b", re.IGNORECASE)

def fix_word(m):
    w = m.group(0)
    rep = table[w.lower()]
    if w.isupper():
        return rep.upper()
    if w[0].isupper():
        return rep[0].upper() + rep[1:]
    return rep

protect = re.compile(r"(`[^`\n]*`|https?://\S+|\]\([^)]*\)|<[^>\n]*>|\"[^\"\n]*\")")

def fix_text(text):
    out, fenced = [], False
    for line in text.split("\n"):
        if line.lstrip().startswith("```"):
            fenced = not fenced
            out.append(line)
            continue
        if fenced:
            out.append(line)
            continue
        parts = protect.split(line)
        out.append("".join(p if i % 2 else word.sub(fix_word, p) for i, p in enumerate(parts)))
    return "\n".join(out)

if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
    print("usage: python3 scripts/us-spelling.py <file.md>...  rewrites British spellings in prose to US English, leaving code spans, fenced blocks, links, tags and quoted text alone")
    sys.exit(0 if len(sys.argv) > 1 else 64)

changed = 0
for path in sys.argv[1:]:
    s = open(path, encoding="utf-8").read()
    t = fix_text(s)
    if t != s:
        open(path, "w", encoding="utf-8").write(t)
        changed += 1
print("files changed:", changed)
