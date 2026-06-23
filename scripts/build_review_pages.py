#!/usr/bin/env python3
"""Programmatic SEO: generate a static review page per movie / TV show.

For a curated set of well-known titles (TMDB "top rated", which is evergreen and
exactly what people search "<title> review" for) this fetches the real synopsis,
cast, community rating, and where-to-watch data, and emits a unique static page
at /reviews/<slug>/. Each page is genuinely distinct — real overview, real cast,
real streaming availability — which is what keeps programmatic pages out of
Google's "thin content" bucket. It also writes the /reviews/ index, sitemap.xml,
and robots.txt.

Pages are committed (not built at deploy time) so the published site never
depends on a live TMDB call. Re-run this to refresh or grow the set:

    python3 scripts/build_review_pages.py

The TMDB v3 key is the committed client key (same one the app ships).
"""
import html
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE = "https://trycini.com"
APP_STORE = "https://apps.apple.com/us/app/cini-rank-every-film/id6778975898"
OUT = os.path.join(ROOT, "reviews")
TODAY = time.strftime("%Y-%m-%d")
IMG = "https://image.tmdb.org/t/p"


def tmdb_key():
    text = open(os.path.join(ROOT, "Cini/Resources/Secrets.xcconfig")).read()
    return re.search(r"^TMDB_API_KEY\s*=\s*(\S+)", text, re.M).group(1)


KEY = tmdb_key()


def get(path, **params):
    params["api_key"] = KEY
    url = f"https://api.themoviedb.org/3{path}?{urllib.parse.urlencode(params)}"
    for attempt in range(4):
        try:
            with urllib.request.urlopen(url, timeout=30) as r:
                return json.loads(r.read().decode())
        except Exception as e:  # noqa: BLE001 — transient network/rate limits
            if attempt == 3:
                print(f"  ! failed {path}: {e}")
                return None
            time.sleep(1.5 * (attempt + 1))


def slugify(text, year):
    base = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return f"{base}-{year}" if year else base


def esc(s):
    return html.escape(s or "", quote=True)


def providers(detail):
    """US 'where to watch' names, de-duped, stream/rent/buy in that order.
    TMDB provider data is powered by JustWatch (attribution shown on page)."""
    us = (detail.get("watch/providers") or {}).get("results", {}).get("US", {})
    seen, names = set(), []
    for bucket in ("flatrate", "free", "ads", "rent", "buy"):
        for p in us.get(bucket, []) or []:
            n = p.get("provider_name")
            if n and n not in seen:
                seen.add(n)
                names.append(n)
    return names


def fetch_titles():
    """Curated, stable, high-intent set: top-rated films + shows."""
    items = []
    for page in (1, 2):
        data = get("/movie/top_rated", language="en-US", page=page) or {}
        items += [("movie", m["id"]) for m in data.get("results", [])]
    data = get("/tv/top_rated", language="en-US", page=1) or {}
    items += [("tv", m["id"]) for m in data.get("results", [])]
    return items


def normalize(kind, d):
    """Flatten a TMDB detail payload into the fields the template needs."""
    if kind == "movie":
        title = d.get("title") or d.get("original_title") or ""
        date = d.get("release_date") or ""
        runtime = d.get("runtime")
        crew = (d.get("credits") or {}).get("crew", [])
        director = next((c["name"] for c in crew if c.get("job") == "Director"), None)
        maker_label, maker = "Director", director
        type_label, schema_type = "Movie", "Movie"
    else:
        title = d.get("name") or d.get("original_name") or ""
        date = d.get("first_air_date") or ""
        rts = d.get("episode_run_time") or []
        runtime = rts[0] if rts else None
        creators = [c["name"] for c in (d.get("created_by") or [])]
        maker_label, maker = "Created by", ", ".join(creators) if creators else None
        type_label, schema_type = "TV Series", "TVSeries"
    year = date[:4] if date else ""
    cast = [c["name"] for c in (d.get("credits") or {}).get("cast", [])[:5]]
    return {
        "kind": kind, "title": title, "year": year, "date": date,
        "overview": d.get("overview") or "",
        "genres": [g["name"] for g in d.get("genres", [])],
        "runtime": runtime, "maker_label": maker_label, "maker": maker,
        "cast": cast, "poster": d.get("poster_path"), "backdrop": d.get("backdrop_path"),
        "vote": d.get("vote_average") or 0, "votes": d.get("vote_count") or 0,
        "providers": providers(d), "type_label": type_label, "schema_type": schema_type,
        "slug": slugify(title, year),
    }


def runtime_text(m):
    r = m["runtime"]
    if not r:
        return None
    return f"{r // 60}h {r % 60}m" if r >= 60 else f"{r}m"


def meta_line(m):
    parts = [m["type_label"]]
    if m["year"]:
        parts.append(m["year"])
    if m["genres"]:
        parts.append(", ".join(m["genres"][:3]))
    rt = runtime_text(m)
    if rt:
        parts.append(rt)
    return " · ".join(parts)


def page_html(m, related):
    title, year = m["title"], m["year"]
    yr = f" ({year})" if year else ""
    slug = m["slug"]
    canonical = f"{SITE}/reviews/{slug}/"
    poster_url = f"{IMG}/w500{m['poster']}" if m["poster"] else f"{SITE}/og.png"
    og_img = f"{IMG}/w780{m['backdrop']}" if m["backdrop"] else poster_url
    page_title = f"{title}{yr} Review — Ratings & Where to Watch | Cini"
    desc_src = m["overview"] or f"Read about {title} and rank it on Cini."
    desc = (desc_src[:150].rsplit(" ", 1)[0] + "…") if len(desc_src) > 150 else desc_src
    desc = f"{title}{yr}: {desc} See where to watch and rank it yourself on Cini."

    # JSON-LD: the work itself (with TMDB community rating) + breadcrumbs.
    work = {
        "@context": "https://schema.org",
        "@type": m["schema_type"],
        "name": title,
        "url": canonical,
        "description": m["overview"] or None,
        "genre": m["genres"] or None,
        "image": poster_url,
    }
    if year:
        work["datePublished"] = m["date"]
    if m["maker"] and m["kind"] == "movie":
        work["director"] = {"@type": "Person", "name": m["maker"]}
    if m["cast"]:
        work["actor"] = [{"@type": "Person", "name": n} for n in m["cast"]]
    if m["votes"] >= 10:
        work["aggregateRating"] = {
            "@type": "AggregateRating",
            "ratingValue": round(m["vote"], 1),
            "bestRating": 10, "worstRating": 1,
            "ratingCount": m["votes"],
        }
    work = {k: v for k, v in work.items() if v is not None}
    breadcrumb = {
        "@context": "https://schema.org",
        "@type": "BreadcrumbList",
        "itemListElement": [
            {"@type": "ListItem", "position": 1, "name": "Home", "item": SITE + "/"},
            {"@type": "ListItem", "position": 2, "name": "Reviews", "item": SITE + "/reviews/"},
            {"@type": "ListItem", "position": 3, "name": title, "item": canonical},
        ],
    }

    rating_block = ""
    if m["votes"] >= 10:
        rating_block = (
            f'<div class="rv-rating"><span class="rv-score">{m["vote"]:.1f}</span>'
            f'<span class="rv-out">/10</span>'
            f'<span class="rv-count">community rating · {m["votes"]:,} votes</span></div>'
        )

    where = ""
    if m["providers"]:
        chips = "".join(f'<span class="rv-chip">{esc(p)}</span>' for p in m["providers"][:8])
        where = (
            f'<section class="rv-sec"><h2>Where to watch {esc(title)}</h2>'
            f'<div class="rv-chips">{chips}</div>'
            f'<p class="rv-fine">Streaming availability for the US, powered by '
            f'JustWatch via TMDB. Cini shows live where-to-watch and nearby '
            f'showtimes in the app.</p></section>'
        )

    cast = ""
    if m["cast"]:
        cast = (
            f'<section class="rv-sec"><h2>Cast</h2>'
            f'<p class="rv-cast">{esc(", ".join(m["cast"]))}</p></section>'
        )
    maker = ""
    if m["maker"]:
        maker = f'<p class="rv-maker">{esc(m["maker_label"])}: <b>{esc(m["maker"])}</b></p>'

    overview = ""
    if m["overview"]:
        overview = (
            f'<section class="rv-sec"><h2>What {esc(title)} is about</h2>'
            f'<p>{esc(m["overview"])}</p></section>'
        )

    related_links = "".join(
        f'<a class="rv-rel" href="/reviews/{r["slug"]}/">'
        f'<span class="rv-rel-poster" style="background-image:url(\'{IMG}/w185{r["poster"]}\')"></span>'
        f'<span class="rv-rel-t">{esc(r["title"])}</span></a>'
        for r in related if r["poster"]
    )

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta name="theme-color" content="#131011">
<meta name="description" content="{esc(desc)}">
<title>{esc(page_title)}</title>
<link rel="canonical" href="{canonical}">
<meta property="og:type" content="video.{'movie' if m['kind']=='movie' else 'tv_show'}">
<meta property="og:site_name" content="Cini">
<meta property="og:title" content="{esc(title)}{esc(yr)} Review | Cini">
<meta property="og:description" content="{esc(desc)}">
<meta property="og:url" content="{canonical}">
<meta property="og:image" content="{og_img}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{esc(title)}{esc(yr)} Review | Cini">
<meta name="twitter:description" content="{esc(desc)}">
<meta name="twitter:image" content="{og_img}">
<link href="https://fonts.googleapis.com/css2?family=DM+Serif+Display&family=Limelight&display=swap" rel="stylesheet">
<link rel="icon" type="image/png" href="/favicon.png">
<link rel="stylesheet" href="/site.css">
<script type="application/ld+json">
{json.dumps(work, ensure_ascii=False)}
</script>
<script type="application/ld+json">
{json.dumps(breadcrumb, ensure_ascii=False)}
</script>
</head>
<body>
<header class="nav">
  <a class="wordmark" href="/">cini</a>
  <nav>
    <a href="/reviews/">Reviews</a>
    <a href="/#how">How it works</a>
    <a href="{APP_STORE}">Get the app</a>
  </nav>
</header>

<main class="rv">
  <nav class="rv-crumb" aria-label="Breadcrumb">
    <a href="/">Home</a> › <a href="/reviews/">Reviews</a> › <span>{esc(title)}</span>
  </nav>

  <div class="rv-hero">
    <div class="rv-poster" style="background-image:url('{poster_url}')"></div>
    <div class="rv-head">
      <h1 class="serif">{esc(title)}{esc(yr)}</h1>
      <p class="rv-meta">{esc(meta_line(m))}</p>
      {maker}
      {rating_block}
      <p class="rv-cta-row"><a class="cta" href="{APP_STORE}">Rank {esc(title)} on Cini</a></p>
      <p class="cta-note">Free on the App Store · iPhone</p>
    </div>
  </div>

  {overview}
  {where}
  {cast}

  <section class="rv-sec rv-explain">
    <h2>How Cini scores {esc(title)}</h2>
    <p>Star ratings flatten everything into the same 7-or-8. Cini does it
    differently: instead of asking how many stars {esc(title)} deserves, it asks
    which films you liked <i>more</i>. A few quick head-to-head comparisons slot
    {esc(title)} into your personal ranking, and its score out of 10 comes from
    where it actually lands for <i>you</i> — then Cini predicts how much you'll
    like what you haven't seen yet.</p>
    <p class="rv-cta-row"><a class="cta" href="{APP_STORE}">Start ranking on Cini</a></p>
  </section>

  <section class="rv-sec">
    <h2>More to rank</h2>
    <div class="rv-rels">{related_links}</div>
    <p class="rv-fine"><a href="/reviews/">Browse all reviews →</a></p>
  </section>
</main>

<footer>
  <div class="foot">
    <span>© 2026 Cini</span>
    <a href="/privacy.html">Privacy Policy</a>
    <a href="/terms.html">Terms of Use</a>
    <a href="mailto:jtsilver123@gmail.com?subject=Cini%20support">Support</a>
    <span class="tmdb">Movie data from TMDB. This product uses the TMDB API but is not endorsed or certified by TMDB. Streaming availability by JustWatch.</span>
  </div>
</footer>
</body>
</html>
"""


def index_html(movies):
    cards = "".join(
        f'<a class="rv-card" href="/reviews/{m["slug"]}/">'
        f'<span class="rv-card-poster" style="background-image:url(\'{IMG}/w342{m["poster"]}\')"></span>'
        f'<span class="rv-card-t">{esc(m["title"])}</span>'
        f'<span class="rv-card-y">{esc(m["year"])}</span></a>'
        for m in movies if m["poster"]
    )
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta name="theme-color" content="#131011">
<meta name="description" content="Reviews, ratings, and where to watch the best movies and TV shows — then rank them yourself on Cini, no star ratings required.">
<title>Movie & TV Reviews — Ranked by Your Taste | Cini</title>
<link rel="canonical" href="{SITE}/reviews/">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Cini">
<meta property="og:title" content="Movie & TV Reviews | Cini">
<meta property="og:description" content="Reviews, ratings, and where to watch the best movies and TV shows.">
<meta property="og:url" content="{SITE}/reviews/">
<meta property="og:image" content="{SITE}/og.png">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:image" content="{SITE}/og.png">
<link href="https://fonts.googleapis.com/css2?family=DM+Serif+Display&family=Limelight&display=swap" rel="stylesheet">
<link rel="icon" type="image/png" href="/favicon.png">
<link rel="stylesheet" href="/site.css">
</head>
<body>
<header class="nav">
  <a class="wordmark" href="/">cini</a>
  <nav>
    <a href="/#how">How it works</a>
    <a href="/#features">Features</a>
    <a href="{APP_STORE}">Get the app</a>
  </nav>
</header>
<main class="rv">
  <div class="rv-index-head">
    <h1 class="serif">Reviews, ranked by taste</h1>
    <p class="sub">Synopsis, community ratings, and where to watch the films and
    shows people love — then skip the stars and rank them yourself on Cini.</p>
  </div>
  <div class="rv-grid">{cards}</div>
</main>
<footer>
  <div class="foot">
    <span>© 2026 Cini</span>
    <a href="/privacy.html">Privacy Policy</a>
    <a href="/terms.html">Terms of Use</a>
    <a href="mailto:jtsilver123@gmail.com?subject=Cini%20support">Support</a>
    <span class="tmdb">Movie data from TMDB. This product uses the TMDB API but is not endorsed or certified by TMDB. Streaming availability by JustWatch.</span>
  </div>
</footer>
</body>
</html>
"""


def sitemap(movies):
    urls = [(SITE + "/", "1.0"), (SITE + "/reviews/", "0.8"),
            (SITE + "/charts/", "0.9"), (SITE + "/search/", "0.6"),
            (SITE + "/import/", "0.5"), (SITE + "/privacy.html", "0.3"),
            (SITE + "/terms.html", "0.3")]
    # Canonical title URL is the server-rendered /title/<slug> (migration 0106 +
    # functions/title); the old /reviews/<slug>/ 301-redirect there.
    urls += [(f"{SITE}/title/{m['slug']}", "0.7") for m in movies]
    rows = "\n".join(
        f"  <url><loc>{u}</loc><lastmod>{TODAY}</lastmod>"
        f"<priority>{p}</priority></url>" for u, p in urls)
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
            f"{rows}\n</urlset>\n")


def main():
    print("Fetching curated title set from TMDB…")
    ids = fetch_titles()
    seen, movies = set(), []
    for kind, tid in ids:
        if (kind, tid) in seen:
            continue
        seen.add((kind, tid))
        d = get(f"/{kind}/{tid}", language="en-US",
                append_to_response="credits,watch/providers")
        if not d:
            continue
        m = normalize(kind, d)
        if not m["title"] or not m["poster"] or not m["overview"]:
            continue  # skip anything too sparse to make a real page
        movies.append(m)
        print(f"  ✓ {m['title']} ({m['year']}) -> /reviews/{m['slug']}/")

    # De-dupe slugs (rare title+year collisions).
    by_slug = {}
    for m in movies:
        by_slug.setdefault(m["slug"], m)
    movies = list(by_slug.values())

    os.makedirs(OUT, exist_ok=True)
    for i, m in enumerate(movies):
        # Related = a rolling window of neighbours, kept on the same media kind
        # where possible, for sensible internal links.
        same = [x for x in movies if x["kind"] == m["kind"] and x["slug"] != m["slug"]]
        related = (same + movies)[i % max(len(same), 1):][:6] or movies[:6]
        d = os.path.join(OUT, m["slug"])
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "index.html"), "w") as f:
            f.write(page_html(m, related[:6]))

    with open(os.path.join(OUT, "index.html"), "w") as f:
        f.write(index_html(movies))
    with open(os.path.join(ROOT, "sitemap.xml"), "w") as f:
        f.write(sitemap(movies))
    with open(os.path.join(ROOT, "robots.txt"), "w") as f:
        f.write("User-agent: *\nAllow: /\n\nSitemap: %s/sitemap.xml\n" % SITE)

    print(f"\nGenerated {len(movies)} review pages + index, sitemap.xml, robots.txt.")


if __name__ == "__main__":
    main()
