#!/usr/bin/env python3
"""Ask Cini title-resolution battery: mirrors ChatAgentBridge.resolveMovie
exactly and runs casual phrasings against live TMDB. Run after touching
the resolver; every line should name the obviously-intended title."""
import json, urllib.request, urllib.parse
import os, re as _re
_cfg = open(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                         "Cini/Resources/Secrets.xcconfig")).read()
KEY = _re.search(r"TMDB_API_KEY *= *(\S+)", _cfg).group(1)

def rows(q):
    url = ("https://api.themoviedb.org/3/search/multi?query="
           + urllib.parse.quote(q) + "&api_key=" + KEY)
    with urllib.request.urlopen(url, timeout=15) as r:
        out = []
        for row in json.load(r)["results"]:
            if row.get("media_type") in ("movie", "tv"):
                name = row.get("title") or row.get("name")
                year = (row.get("release_date") or row.get("first_air_date") or "")[:4]
                out.append((name, year, row["media_type"]))
        return out

def best_hit(q, want_year=None):
    results = rows(q)
    if want_year:
        results = [r for r in results if not r[1] or r[1] == str(want_year)]
    if not results: return None
    needle = q.lower()
    for name, year, kind in results[:10]:
        if name.lower() == needle:
            return f"{name} ({year}, {kind})"
    name, year, kind = results[0]
    return f"{name} ({year}, {kind})"

STOP = {"that","this","with","from","about","movie","film","show","new","old","one","the"}

def resolve(title):
    q = title.strip()
    # mirrors Swift: trailing year becomes a filter, not a search term
    year = None
    changed = True
    while changed:
        changed = False
        for p in ["the movie ", "the film ", "the tv show ", "the show ", "the new ", "that new ", "new "]:
            if q.lower().startswith(p) and len(q) > len(p):
                q = q[len(p):]; changed = True
    for s in [" the movie", " the film", " movie", " film", " tv show", " show"]:
        if q.lower().endswith(s): q = q[: -len(s)]
    parts = q.split()
    if len(parts) > 1 and len(parts[-1]) == 4 and parts[-1].isdigit():
        year = int(parts[-1]); q = " ".join(parts[:-1])
    hit = best_hit(q, year)
    if hit: return hit
    if len(q) > 5:
        for drop in (1, 2):
            hit = best_hit(q[:-drop], year)
            if hit: return hit
    lowered = q.lower()
    longest = ""
    for w in lowered.split():
        if len(w) > 3 and w not in STOP and len(w) > len(longest):
            longest = w
    if longest and longest != lowered:
        return best_hit(longest, year)
    return None

for phrase in ["friends", "the tv show friends", "the new dune movie", "dune 2021",
               "oppenhiemer", "that anatomy courtroom one", "the bear", "it", "up",
               "her", "interstellar", "the office", "lotr", "white lotus",
               "everything everywhere", "the new spiderman"]:
    print(f"{phrase!r:36} -> {resolve(phrase)}")

# --- List-name matcher battery: mirrors ChatAgentBridge.listMatchScore ---
import difflib

LIST_STOP = {"my","the","a","of","list","lists","movie","movies","film","films",
             "that","this","with","one","ones","for","me"}

def norm(w):
    return w[:-1] if len(w) > 3 and w.endswith("s") else w

def sig_words(text):
    return {norm(w) for w in text.lower().split() if w not in LIST_STOP}

def list_score(needle, candidate):
    score = difflib.SequenceMatcher(None, needle.lower(), candidate.lower()).ratio()
    if needle.lower() in candidate.lower() or candidate.lower() in needle.lower():
        score = max(score, 0.85)
    overlap = sig_words(needle) & sig_words(candidate)
    if overlap:
        score = max(score, 0.65 + 0.15 * len(overlap))
    return score

LISTS = ["Best Heist Movies", "Date Night", "Cozy Fall Watches", "A24 Bangers",
         "Movies That Made Me Cry", "Oscar Bait 2026", "Comfort Shows"]

def resolve_list(name):
    best, best_score = None, 0.0
    for cand in LISTS:
        s = list_score(name, cand)
        if s > best_score:
            best, best_score = cand, s
    return f"{best} ({best_score:.2f})" if best_score >= 0.6 else None

print()
# Last phrase is a deliberate no-match: no horror list exists, so None is right.
for phrase in ["my heist list", "that list with the heists", "heist movies",
               "date night list", "the cozy one", "a24 list", "the made me cry one",
               "oscar bait", "comfort show list", "my horror list"]:
    print(f"{phrase!r:36} -> {resolve_list(phrase)}")

# --- Consent-gate battery: mirrors ChatAgentBridge.promptAsksToSave ---
import re as _re2

def asks_to_save(prompt):
    p = prompt.lower()
    words = set(_re2.split(r"[^a-z]+", p))
    save_words = {"save","add","bookmark","watchlist","queue","yes","yeah","sure","okay","ok","yep"}
    if words & save_words: return True
    return "my list" in p or "do it" in p

print()
CASES = [  # (prompt, should the save tool be allowed to fire?)
    ("i want to watch a movie with my gf but it can't be scary. what are some options", False),
    ("what should i watch tn", False),
    ("recommend me something funny", False),
    ("is dune good", False),
    ("something like heat but i haven't seen", False),
    ("what do my friends want to watch", False),
    ("add dune to my watchlist", True),
    ("save oppenheimer for later", True),
    ("bookmark the bear", True),
    ("put severance on my list", True),
    ("yes", True),
    ("sure, do it", True),
    ("yeah save it", True),
    ("queue up alien", True),
    ("ok add it", True),
    ("look up the godfather", False),     # 'look' must not match 'ok'
    ("show me horror options", False),
    ("who directed parasite", False),
]
bad = 0
for prompt, expected in CASES:
    got = asks_to_save(prompt)
    mark = "ok " if got == expected else "FAIL"
    if got != expected: bad += 1
    print(f"  [{mark}] gate={'save' if got else 'block'}  {prompt!r}")
print("consent gate:", "all correct" if bad == 0 else f"{bad} WRONG")
