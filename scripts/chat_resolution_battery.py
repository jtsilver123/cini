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
