#!/usr/bin/env bash
# Assemble the public web root into _site/ — the static half of the site
# (marketing, legal, prototype, admin, reviews, and the public /u /l /m /charts
# /match pages). Used as the Cloudflare Pages build command so Cloudflare serves
# ONLY these files (never the whole repo: Swift sources, supabase/, etc.). The
# Cloudflare Pages Functions in /functions/ are picked up automatically and
# server-render /u, /m, /l on top of these static fallbacks.
#
# Mirrors what .github/workflows/pages.yml copies for GitHub Pages.
set -euo pipefail
cd "$(dirname "$0")/.."

rm -rf _site
mkdir -p _site

cp CNAME _site/CNAME 2>/dev/null || true
cp index.html site.css favicon.png og.png privacy.html terms.html robots.txt sitemap.xml _site/

mkdir -p _site/prototype && cp prototype/index.html _site/prototype/index.html && cp favicon.png _site/prototype/favicon.png
mkdir -p _site/import   && cp import.html _site/import/index.html && cp favicon.png _site/import/favicon.png
mkdir -p _site/admin    && cp admin/index.html _site/admin/index.html && cp favicon.png _site/admin/favicon.png
mkdir -p _site/i        && cp i/index.html _site/i/index.html && cp favicon.png _site/i/favicon.png
mkdir -p _site/l        && cp l/index.html _site/l/index.html && cp favicon.png _site/l/favicon.png
mkdir -p _site/u        && cp u/index.html _site/u/index.html && cp favicon.png _site/u/favicon.png
mkdir -p _site/m        && cp m/index.html _site/m/index.html && cp favicon.png _site/m/favicon.png
mkdir -p _site/charts   && cp charts/index.html _site/charts/index.html && cp favicon.png _site/charts/favicon.png
mkdir -p _site/match    && cp match/index.html _site/match/index.html && cp favicon.png _site/match/favicon.png
mkdir -p _site/search   && cp search/index.html _site/search/index.html && cp favicon.png _site/search/favicon.png

mkdir -p _site/.well-known && cp .well-known/apple-app-site-association _site/.well-known/apple-app-site-association
cp -R reviews _site/reviews

echo "Built _site/ ($(find _site -type f | wc -l | tr -d ' ') files)"
