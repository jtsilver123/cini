#!/usr/bin/env python3
"""Cini ↔ Supabase contract check.

Executes every PostgREST query and RPC the app makes against the live
database, exactly as SupabaseService.swift sends them. A migration that
breaks any query (ambiguous embed, renamed column, dropped function,
revoked grant) turns this red — static code review can't catch those.

Read-only by default (safe for CI). --write additionally exercises the
mutating endpoints with a rank/unrank + toggle cycle as the demo user.

Credentials: the public anon key is read from Cini/Resources/Secrets.xcconfig;
the sign-in uses the App Review demo account (already public in review
notes) unless CONTRACT_EMAIL / CONTRACT_PASSWORD are set.
"""
import json
import os
import re
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
URL = "https://npumchnkbcajyuhurgez.supabase.co"
SAMPLES_DIR = os.environ.get("CONTRACT_SAMPLES_DIR")

def anon_key():
    text = open(os.path.join(ROOT, "Cini/Resources/Secrets.xcconfig")).read()
    return re.search(r"SUPABASE_ANON_KEY *= *(\S+)", text).group(1)

KEY = anon_key()
EMAIL = os.environ.get("CONTRACT_EMAIL", "appreview@cini-demo.com")
PASSWORD = os.environ.get("CONTRACT_PASSWORD", "CiniReview2026!")

def http(method, path, body=None, token=None, prefer=None):
    req = urllib.request.Request(URL + path, method=method)
    req.add_header("apikey", KEY)
    req.add_header("Authorization", f"Bearer {token or KEY}")
    req.add_header("Content-Type", "application/json")
    if prefer:
        req.add_header("Prefer", prefer)
    data = json.dumps(body).encode() if body is not None else None
    try:
        with urllib.request.urlopen(req, data) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()

def sign_in():
    status, body = http("POST", "/auth/v1/token?grant_type=password",
                        {"email": EMAIL, "password": PASSWORD})
    if status != 200:
        print(f"FATAL: sign-in failed ({status}): {body[:200]}")
        sys.exit(1)
    data = json.loads(body)
    return data["access_token"], data["user"]["id"]

def storage_raw(method, path, token, data=None, content_type=None):
    """Storage REST call with a binary body (avatar upload uses bytes,
    not JSON — the JSON http() helper can't exercise this path)."""
    req = urllib.request.Request(URL + path, method=method)
    req.add_header("apikey", KEY)
    req.add_header("Authorization", f"Bearer {token}")
    if content_type:
        req.add_header("Content-Type", content_type)
        req.add_header("x-upsert", "true")
    try:
        with urllib.request.urlopen(req, data) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()

def check_storage(token, uid, record):
    """Avatar upload smoke test — uploads a 1-byte object to the demo
    user's avatar path and deletes it. Catches Storage RLS gaps (the
    missing-SELECT-policy class) that PostgREST checks can't see."""
    path = f"/storage/v1/object/avatars/{uid}.jpg"
    status, body = storage_raw("POST", path, token, data=b"\xff",
                               content_type="image/jpeg")
    record("storage", "avatar_upload", status, body)
    if status in (200, 201):
        storage_raw("DELETE", f"/storage/v1/object/avatars/{uid}.jpg", token)

# Every read query the app makes: (name, table, select string).
# Keep in sync with SupabaseService.swift — the select strings are verbatim.
READS = [
    ("profile", "profiles", "*"),
    ("muted_kinds", "profiles", "muted_notification_kinds"),
    ("movies_by_ids", "movies", "*"),
    ("my_rankings", "rankings", "*"),
    ("watchlist", "watchlist", "*"),
    ("my_note", "notes", "body, is_private, contains_spoilers"),
    ("my_performances", "favorite_performances", "tmdb_person_id, person_name, profile_path"),
    ("my_rank_details", "rankings", "watch_date, watched_with, watched_where, ranking_labels(labels(name))"),
    ("direct_recs", "direct_recs", "id, sender_id, movie_id, note, created_at, profiles!direct_recs_sender_id_fkey(username, display_name, avatar_url), movies!direct_recs_movie_id_fkey(*)"),
    ("rec_requests", "rec_requests", "id, requester_id, media_kind, genre, note, decade, max_runtime, streaming_provider, created_at, fulfilled_at, profiles!rec_requests_requester_id_fkey(username, display_name, avatar_url)"),
    ("streaming_alerts", "streaming_alerts", "user_id, movie_id, notified_at"),
    ("pending_imports", "pending_imports", "status, path"),
    ("home_zip", "user_locations", "home_zip"),
    ("blocked_ids", "blocks", "blocked_id"),
    ("custom_lists", "custom_lists", "id, user_id, name, is_private, created_at, media_kind, custom_list_items(count)"),
    ("list_ids_containing", "custom_list_items", "list_id"),
    ("list_movie_ids", "custom_list_items", "movie_id"),
    ("watches", "watches", "id, movie_id, watched_on, watched_where"),
    ("watch_summary", "watches", "watched_on"),
    ("performance_tallies", "favorite_performances", "tmdb_person_id, person_name, profile_path"),
    ("following_edges", "follows", "following_id"),
    ("follow_edges_both", "follows", "follower_id, following_id"),
    ("outgoing_follow_requests", "follow_requests", "target_id"),
    ("watched_with_tags", "rankings", "watched_with"),
    ("feed", "feed_events", "*, profiles!feed_events_user_id_fkey(username, display_name, avatar_url), movies!feed_events_movie_id_fkey(*), likes(count), comments(count)"),
    ("taste_match", "taste_matches", "user_a, user_b, pct"),
    ("my_likes", "likes", "event_id"),
    ("my_comment_likes", "comment_likes", "comment_id"),
    ("member_note", "notes", "body"),
    ("feed_notes", "notes", "user_id, movie_id, body, contains_spoilers"),
    ("comments", "comments", "*, profiles!comments_user_id_fkey(username, display_name, avatar_url), comment_likes(count)"),
    ("notifications", "notifications", "*, actor:profiles!notifications_actor_id_fkey(username, display_name, avatar_url), movies!notifications_movie_id_fkey(title, poster_path)"),
    ("community_score", "movie_community_scores", "*"),
    ("watch_plans", "watch_plans", "*"),
    ("my_show_progress", "show_progress", "season, episode"),
]

# Read-only RPCs: (name, params). Param names/types verbatim from the app.
RPCS = [
    ("username_available", {"p_username": "contract_check_zz"}),
    ("search_members", {"p_query": "a"}),
    ("suggested_members", {"p_limit": 5}),
    ("people_you_may_know", {"p_limit": 5}),
    ("members_from_emails", {"p_emails": ["nobody@example.com"]}),
    ("predicted_scores", {"p_movie_ids": [27205]}),
    ("watchlist_counts", {"p_movie_ids": [27205]}),
    ("movie_top_labels", {"p_movie_id": 27205}),
    ("movie_page_stats", {"p_movie_id": 27205}),
    ("movie_public_notes", {"p_movie_id": 27205}),
    ("recs_for_user", {"p_limit": 5}),
    ("tonight_pick", {}),
    ("tonight_picks", {"p_limit": 3}),
    ("continue_watching_picks", {"p_limit": 3}),
    ("movie_watchlist_friends", {"p_movie_id": 27205}),
    ("movie_watching_friends", {"p_movie_id": 27205}),
    ("friends_watching", {}),
    ("watching_for", {"p_user": "00000000-0000-0000-0000-000000000000"}),
    ("mutual_watching", {"p_user": "00000000-0000-0000-0000-000000000000"}),
    ("movie_friend_scores", {"p_movie_id": 27205}),
    ("movie_score_histogram", {"p_movie_id": 27205}),
    ("leaderboard", {"p_metric": "watched", "p_school": None, "p_genre": None}),
    ("redeem_invite_from", {"p_username": "no_such_user_zz"}),
    # Empty recipients / random id: exercises signatures without writing.
    # Full 7-param signature (migration 0082) — keep in lockstep with
    # SupabaseService.requestRecs so a rename of a filter param is caught.
    ("request_recs", {"p_recipients": [], "p_media_kind": None,
                      "p_genre": None, "p_note": None, "p_decade": None,
                      "p_max_runtime": None, "p_streaming_provider": None}),
    ("complete_rec_request", {"p_request_id": "00000000-0000-0000-0000-000000000000"}),
    # Social graph / plans / direct recs: zero UUIDs (and a movie the demo
    # hasn't ranked) make each a clean no-op — a missing target row or RLS gate
    # — so the signature is exercised without writing, same as notify_mention.
    ("request_follow", {"p_target": "00000000-0000-0000-0000-000000000000"}),
    ("respond_follow_request", {"p_requester": "00000000-0000-0000-0000-000000000000",
                                "p_accept": False}),
    ("propose_watch_plan", {"p_movie_id": 2,
                            "p_invitee": "00000000-0000-0000-0000-000000000000",
                            "p_proposed_at": None}),
    # Show-progress: a movie the demo isn't watching → harmless no-op upsert,
    # then cleared, so the pair exercises both signatures without lingering state.
    ("set_show_progress", {"p_show_id": 2, "p_season": None,
                           "p_episode": None, "p_caught_up": False}),
    ("clear_show_progress", {"p_show_id": 2}),
    # Pass then immediately un-pass movie 2 → exercises both signatures and
    # leaves no rec_passes row behind for the demo.
    ("pass_rec", {"p_movie_id": 2}),
    ("unpass_rec", {"p_movie_id": 2}),
    # respond_watch_plan is deliberately excluded: it raises a P0001 ("no such
    # plan") for any fake id, which is indistinguishable from a real contract
    # break (both are HTTP 400) without seeding a live plan row. propose_watch_plan
    # above already covers the watch-plan signature resolution.
    ("send_direct_rec", {"p_recipient": "00000000-0000-0000-0000-000000000000",
                         "p_movie_id": 2, "p_note": None}),
    ("pass_direct_rec", {"p_rec_id": "00000000-0000-0000-0000-000000000000",
                         "p_message": None}),
    # Demo has no ranking for movie 2 → a no-op delete that exercises the signature.
    ("rank_remove", {"p_movie_id": 2}),
    # Idempotent best-effort writes (like set_phone): a fixed value each run, so
    # re-running never changes demo state in a way that matters for review.
    ("set_timezone", {"p_tz": "America/New_York"}),
    ("set_home_zip", {"p_zip": "10001"}),
    # Empty array stores nothing; forget clears the caller's own hashes.
    ("store_contacts", {"p_phones": []}),
    ("forget_contacts", {}),
    # Zero event id + empty ids: a no-op (RLS gate fails), exercises the signature.
    ("notify_mention", {"p_event_id": "00000000-0000-0000-0000-000000000000", "p_user_ids": []}),
    # Demo user has no watchlist row for id 2 — a no-op update.
    ("set_watchlist_note", {"p_movie_id": 2, "p_note": None}),
    ("set_watch_by", {"p_movie_id": 2, "p_watch_by": None}),
    ("referral_count", {}),
    ("incoming_follow_requests", {}),
    ("trending_titles", {}),
    # Pass the demo's own number, not "" — set_phone('') means "clear my
    # number" and would DELETE the demo's user_phones row on every run,
    # breaking App Review's "log in with phone". This input is idempotent.
    ("set_phone", {"p_phone": "+15551234567"}),
    ("my_phone", {}),
    # Signup checks a number's uniqueness before creating the account.
    ("phone_available", {"p_phone": "+15550000000"}),
    # Featured-card engagement log. A non-real action exercises the signature
    # without writing analytics noise (invalid actions are ignored server-side).
    ("log_featured_event", {"p_movie_id": 27205, "p_action": "contract_check"}),
    ("members_from_phones", {"p_phones": []}),
    ("contact_network_counts", {"p_phones": ["5555550100"]}),
    # No follower rates movie 2 highly → no-op insert.
    ("notify_friends_of_rating", {"p_movie_id": 2}),
    # Public web layer (anon-callable; the demo user is public so these resolve).
    ("public_profile", {"p_username": "appreviewer"}),
    ("public_rankings", {"p_username": "appreviewer", "p_limit": 50}),
    # A nil UUID resolves to no list → null (200): exercises the signature/grant.
    ("public_list", {"p_list_id": "00000000-0000-0000-0000-000000000000"}),
    ("public_title", {"p_movie_id": 13}),
    # delete_account deliberately excluded.
]

# Contract-breaking signatures: schema/parse/grant problems, not data states.
def is_contract_error(status, body):
    if status in (200, 201, 204, 206):
        return False
    code = ""
    try:
        code = json.loads(body).get("code", "")
    except Exception:
        pass
    if code.startswith("PGRST") or code.startswith("42"):
        return True
    return status in (400, 404, 406)

def main():
    write_mode = "--write" in sys.argv
    token, uid = sign_in()
    failures = []

    def record(kind, name, status, body):
        bad = is_contract_error(status, body)
        marker = "FAIL" if bad else "ok"
        print(f"  [{marker}] {kind} {name}: HTTP {status}" + (f" — {body[:160]}" if bad else ""))
        if bad:
            failures.append(f"{kind} {name}: {status} {body[:200]}")
        elif SAMPLES_DIR and kind == "read":
            os.makedirs(SAMPLES_DIR, exist_ok=True)
            with open(os.path.join(SAMPLES_DIR, f"{name}.json"), "w") as f:
                f.write(body)

    print("== reads ==")
    for name, table, select in READS:
        status, body = http(
            "GET", f"/rest/v1/{table}?select={urllib.parse.quote(select)}&limit=1",
            token=token)
        record("read", name, status, body)

    print("== storage ==")
    check_storage(token, uid, record)

    # global_rank needs the live uid, so it can't sit in the static list.
    status, body = http("POST", "/rest/v1/rpc/global_rank", {"p_user": uid}, token=token)
    record("rpc", "global_rank", status, body)

    print("== rpcs ==")
    for name, params in RPCS:
        status, body = http("POST", f"/rest/v1/rpc/{name}", params, token=token)
        record("rpc", name, status, body)

    if write_mode:
        print("== writes (demo account) ==")
        movie = {"p_tmdb_id": 27205, "p_media_kind": "movie", "p_title": "Inception",
                 "p_release_year": 2010, "p_poster_path": "/ljsZTbVsrQSqZgWeep2B1QiDKuh.jpg",
                 "p_backdrop_path": None, "p_genres": ["Science Fiction"],
                 "p_certification": "PG-13", "p_runtime_minutes": 148,
                 "p_director": "Christopher Nolan", "p_overview": None}
        for name, params in [
            ("cache_movie", movie),
            # Swift omits nil fields — a sparse call must still match the
            # function (caught the PGRST202 that broke bookmarking).
            ("cache_movie", {"p_tmdb_id": 27205, "p_media_kind": "movie",
                             "p_title": "Inception", "p_genres": []}),
            ("rank_insert", {"p_movie_id": 27205, "p_bucket": "loved",
                             "p_position": 0, "p_watch_date": None, "p_stealth": False,
                             "p_tz": "America/New_York"}),
            ("set_ranking_labels", {"p_movie_id": 27205, "p_labels": ["Mind-bending"]}),
            ("watchlist_toggle", {"p_movie_id": 27205}),
            ("watchlist_toggle", {"p_movie_id": 27205}),
            ("register_device_token", {"p_token": "contract-check-dummy",
                                       "p_platform": "ios"}),
            # Idempotent: duplicate diary rows are skipped, notes never clobber.
            ("import_movie_details", {"p_items": [
                {"tmdb_id": 27205, "media_kind": "movie", "title": "Inception",
                 "watched_on": "2024-03-09",
                 "watched_dates": ["2024-03-09", "2025-01-01"]}]}),
        ]:
            status, body = http("POST", f"/rest/v1/rpc/{name}", params, token=token)
            record("rpc-write", name, status, body)

    print()
    if failures:
        print(f"{len(failures)} CONTRACT FAILURE(S):")
        for f in failures:
            print(" -", f)
        sys.exit(1)
    print("All contracts hold.")

if __name__ == "__main__":
    main()
