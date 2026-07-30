#!/usr/bin/env python3
"""Live production round trip of the ENTIRE social flow, mirroring the app's queries exactly.

Two throwaway users: A posts (public + photo), B discovers/follows/reacts/comments.
Every step asserts; users are deleted at the end (cascade wipes their rows).
"""
import json, subprocess, sys, time, urllib.request, urllib.error, uuid, base64, datetime

REF = "hhhlrqngutmyccfpgdoq"
BASE = f"https://{REF}.supabase.co"

def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout.strip()

# Keys — anon from Secrets.xcconfig, service via the CLI token (the e2e script's trick).
anon = sh("grep SUPABASE_ANON_KEY /Users/ephraimbelachew/momentum/Secrets.xcconfig").split("=", 1)[1].strip()
rows = sh(f"supabase projects api-keys --project-ref {REF} -o json")
service = next(k["api_key"] for k in json.loads(rows) if k.get("name") == "service_role")

results = []
def check(name, ok, detail=""):
    results.append((name, ok, detail))
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  — {detail}" if detail and not ok else ""))

def call(method, path, token, body=None, headers=None, raw=False, base=BASE):
    h = {"apikey": anon, "Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    h.update(headers or {})
    data = body if raw else (json.dumps(body).encode() if body is not None else None)
    r = urllib.request.Request(base + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(r) as resp:
            raw_out = resp.read()
            return resp.status, (json.loads(raw_out) if raw_out and not raw else raw_out), dict(resp.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:400], {}

def admin(method, path, body=None):
    h = {"apikey": service, "Authorization": f"Bearer {service}", "Content-Type": "application/json"}
    r = urllib.request.Request(BASE + path, data=json.dumps(body).encode() if body else None,
                               method=method, headers=h)
    try:
        with urllib.request.urlopen(r) as resp:
            out = resp.read()
            return resp.status, json.loads(out) if out else {}
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:400]

ts = int(time.time())
users = {}
try:
    # ── Users ────────────────────────────────────────────────────────────────
    for who in ("a", "b"):
        st, u = admin("POST", "/auth/v1/admin/users",
                      {"email": f"e2e.audit.{who}{ts}@example.com", "password": "Audit-12345",
                       "email_confirm": True})
        assert st == 200, (st, u)
        st, tokr, _ = call("POST", "/auth/v1/token?grant_type=password", anon,
                           {"email": f"e2e.audit.{who}{ts}@example.com", "password": "Audit-12345"})
        assert st == 200, (st, tokr)
        users[who] = {"id": u["id"], "jwt": tokr["access_token"]}
    check("auth: admin create + password sign-in (2 users)", True)

    A, B = users["a"], users["b"]
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    # ── Profiles (claimProfile shape) ───────────────────────────────────────
    for who, handle, pro in (("a", f"audita{ts}", True), ("b", f"auditb{ts}", False)):
        u = users[who]
        st, out, _ = call("POST", "/rest/v1/profiles", u["jwt"],
                          {"id": u["id"], "handle": handle, "display_name": f"Audit {who.upper()}",
                           "bio": "e2e audit", "public_location": "Austin, TX",
                           "avatar_path": None, "discoverable": True, "is_pro": pro,
                           "updated_at": now},
                          headers={"Prefer": "resolution=merge-duplicates"})
        check(f"profiles upsert ({who})", st in (200, 201, 204), f"{st} {out}")
        users[who]["handle"] = handle

    # handle_available RPC (anon-callable, as the onboarding probe uses it)
    st, out, _ = call("POST", "/rest/v1/rpc/handle_available", anon, {"p_handle": A["handle"]})
    check("rpc handle_available (taken → false)", st == 200 and out is False, f"{st} {out}")
    st, out, _ = call("POST", "/rest/v1/rpc/handle_available", anon, {"p_handle": f"free{ts}"})
    check("rpc handle_available (free → true)", st == 200 and out is True, f"{st} {out}")

    # ── Publish: photo upload + posts upsert (publish() shape) ──────────────
    post_id = str(uuid.uuid4()).lower()
    photo_path = f"{A['id']}/{post_id}/0.jpg"
    jpeg = base64.b64decode(  # 1x1 white jpeg
        "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0a"
        "HBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAA"
        "AAAAAAAAAAAAAv/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AN//Z")
    st, out, _ = call("POST", f"/storage/v1/object/post-photos/{photo_path}", A["jwt"],
                      jpeg, headers={"Content-Type": "image/jpeg", "x-upsert": "true"}, raw=True)
    check("storage: post photo upload", st == 200, f"{st} {out}")

    st, out, _ = call("POST", "/rest/v1/posts", A["jwt"],
                      {"id": post_id, "author_id": A["id"], "visibility": "public",
                       "workout_type": "run", "started_at": now, "title": "Audit tempo",
                       "caption": "backend audit", "stat_line": "5.02 mi · 38:12 · 7:37 /mi",
                       "distance_m": 8080.0, "duration_s": 2292.0, "total_volume_kg": None,
                       "total_sets": None, "avg_pace_s_per_km": 283.7, "pr_badge": None,
                       "muscles": None, "route": [[30.26, -97.74], [30.27, -97.75]],
                       "map_style": "standard", "ai_read": None, "photo_paths": [photo_path]},
                      headers={"Prefer": "resolution=merge-duplicates"})
    check("posts upsert (public post w/ photo + route)", st in (200, 201, 204), f"{st} {out}")

    # ── Discovery as B ──────────────────────────────────────────────────────
    st, rows, _ = call("POST", "/rest/v1/rpc/feed_page", B["jwt"],
                       {"p_scope": "everyone", "p_cursor_created": None, "p_cursor_id": None,
                        "p_limit": 20})
    hit = next((r for r in (rows if st == 200 else []) if r.get("id") == post_id), None)
    check("rpc feed_page everyone → post visible to B (handle+pro+photo on the row)",
          hit is not None and hit.get("author_handle") == A["handle"]
          and hit.get("author_pro") is True and hit.get("photo_paths") == [photo_path],
          f"{st} {str(rows)[:200]}")

    st, rows, _ = call("GET",
                       f"/rest/v1/profiles?select=handle,display_name,public_location,avatar_path"
                       f"&discoverable=eq.true&handle=neq.&or=(handle.ilike.%25audita{ts}%25,display_name.ilike.%25audita{ts}%25)&limit=12",
                       B["jwt"])
    check("searchAthletes (discoverable ilike)", st == 200 and len(rows) == 1, f"{st} {rows}")

    # athletePage: profile single + author-scoped feed_page
    st, prow, _ = call("GET",
                       f"/rest/v1/profiles?select=id,handle,display_name,bio,public_location,avatar_path"
                       f"&handle=eq.{A['handle']}", B["jwt"],
                       headers={"Accept": "application/vnd.pgrst.object+json"})
    ok = st == 200 and prow.get("id") == A["id"]
    st2, arows, _ = call("POST", "/rest/v1/rpc/feed_page", B["jwt"],
                         {"p_scope": "everyone", "p_limit": 50, "p_author": A["id"]})
    check("athletePage (profile single + feed_page p_author)",
          ok and st2 == 200 and any(r["id"] == post_id for r in arows), f"{st}/{st2}")

    # ── Follow graph ────────────────────────────────────────────────────────
    st, out, _ = call("POST", "/rest/v1/follows", B["jwt"],
                      {"follower_id": B["id"], "followee_id": A["id"]},
                      headers={"Prefer": "resolution=merge-duplicates"})
    check("setFollow (B → A upsert)", st in (200, 201, 204), f"{st} {out}")

    st, rows, _ = call("GET",
                       f"/rest/v1/follows?select=profiles!follows_followee_id_fkey(handle)&follower_id=eq.{B['id']}",
                       B["jwt"])
    check("pullFollowing (followee join)",
          st == 200 and [r["profiles"]["handle"] for r in rows] == [A["handle"]], f"{st} {rows}")

    st, rows, _ = call("GET",
                       f"/rest/v1/follows?select=profiles!follows_follower_id_fkey(handle,display_name,public_location,avatar_path)&followee_id=eq.{A['id']}",
                       A["jwt"])
    check("pullFollowers (follower join — NEW)",
          st == 200 and [r["profiles"]["handle"] for r in rows] == [B["handle"]], f"{st} {rows}")

    for who, want in (("a", (1, 0)), ("b", (0, 1))):
        u = users[who]
        _, _, h1 = call("GET", f"/rest/v1/follows?select=*&followee_id=eq.{u['id']}", u["jwt"],
                        headers={"Prefer": "count=exact", "Range": "0-0"})
        _, _, h2 = call("GET", f"/rest/v1/follows?select=*&follower_id=eq.{u['id']}", u["jwt"],
                        headers={"Prefer": "count=exact", "Range": "0-0"})
        got = (int(h1.get("Content-Range", "/0").split("/")[1]),
               int(h2.get("Content-Range", "/0").split("/")[1]))
        check(f"followCounts ({who}: followers={want[0]} following={want[1]})", got == want, f"{got}")

    st, rows, _ = call("POST", "/rest/v1/rpc/feed_page", B["jwt"],
                       {"p_scope": "following", "p_cursor_created": None, "p_cursor_id": None,
                        "p_limit": 20})
    check("rpc feed_page following → followed athlete's post",
          st == 200 and any(r["id"] == post_id for r in rows), f"{st} {str(rows)[:160]}")

    # ── Engagement ──────────────────────────────────────────────────────────
    st, out, _ = call("POST", "/rest/v1/reactions", B["jwt"],
                      {"post_id": post_id, "user_id": B["id"]},
                      headers={"Prefer": "resolution=merge-duplicates"})
    check("reaction upsert", st in (200, 201, 204), f"{st} {out}")

    comment_id = str(uuid.uuid4())
    st, out, _ = call("POST", "/rest/v1/comments", B["jwt"],
                      {"id": comment_id, "post_id": post_id, "author_id": B["id"],
                       "body": "Strong pace.", "created_at": now},
                      headers={"Prefer": "resolution=merge-duplicates"})
    check("comment push", st in (200, 201, 204), f"{st} {out}")

    st, rows, _ = call("GET",
                       f"/rest/v1/comments?select=id,post_id,body,created_at,profiles(display_name,handle)&post_id=eq.{post_id}&order=created_at.asc",
                       A["jwt"])
    check("comment pull (author join) as A",
          st == 200 and rows and rows[0]["profiles"]["handle"] == B["handle"], f"{st} {rows}")

    # feed row carries the counts + viewer state
    st, rows, _ = call("POST", "/rest/v1/rpc/feed_page", B["jwt"],
                       {"p_scope": "everyone", "p_limit": 20})
    hit = next((r for r in (rows if st == 200 else []) if r.get("id") == post_id), {})
    check("feed row aggregates (reaction_count=1, comment_count=1, viewer_reacted)",
          hit.get("reaction_count") == 1 and hit.get("comment_count") == 1
          and hit.get("viewer_reacted") is True, f"{str(hit)[:200]}")

    # signed photo URL (the feed's photo fetch)
    st, out, _ = call("POST", f"/storage/v1/object/sign/post-photos/{photo_path}", B["jwt"],
                      {"expiresIn": 3600})
    check("storage: signed photo URL for viewer", st == 200 and "signedURL" in out, f"{st} {out}")

    # report + block (safety)
    st, out, _ = call("POST", "/rest/v1/reports", B["jwt"],
                      {"reporter_id": B["id"], "post_id": post_id, "comment_id": None,
                       "target_handle": A["handle"], "reason": "other", "details": "audit"})
    check("report insert", st in (200, 201, 204), f"{st} {out}")
    st, out, _ = call("POST", "/rest/v1/blocks", B["jwt"],
                      {"blocker_id": B["id"], "blocked_id": A["id"]},
                      headers={"Prefer": "resolution=merge-duplicates"})
    blocked_ok = st in (200, 201, 204)
    st, rows, _ = call("POST", "/rest/v1/rpc/feed_page", B["jwt"],
                       {"p_scope": "everyone", "p_limit": 20})
    check("block hides the author from B's feed",
          blocked_ok and st == 200 and not any(r["id"] == post_id for r in rows),
          f"{st} {str(rows)[:160]}")
    call("DELETE", f"/rest/v1/blocks?blocker_id=eq.{B['id']}&blocked_id=eq.{A['id']}", B["jwt"])

    # ── Visibility change + unpublish ───────────────────────────────────────
    st, out, _ = call("PATCH", f"/rest/v1/posts?id=eq.{post_id}", A["jwt"],
                      {"visibility": "friends"})
    st2, rows, _ = call("POST", "/rest/v1/rpc/feed_page", B["jwt"],
                        {"p_scope": "everyone", "p_limit": 20})
    # B follows A but A doesn't follow back — 'friends' requires the follow, which B has.
    check("visibility → friends still reaches follower B",
          st in (200, 204) and any(r["id"] == post_id for r in rows), f"{st}/{st2}")

    st, out, _ = call("DELETE", f"/rest/v1/posts?id=eq.{post_id}", A["jwt"])
    st2, rows, _ = call("POST", "/rest/v1/rpc/feed_page", B["jwt"],
                        {"p_scope": "everyone", "p_limit": 20})
    check("unpublish deletes + vanishes from feed",
          st in (200, 204) and not any(r["id"] == post_id for r in rows), f"{st}")

except Exception:
    import traceback; traceback.print_exc()
finally:
    # ── Cleanup: delete both users; cascades wipe profiles/posts/follows/etc.
    for who, u in users.items():
        st, _ = admin("DELETE", f"/auth/v1/admin/users/{u['id']}")
        print(f"cleanup: user {who} delete → {st}")

ok_all = bool(results) and all(ok for _, ok, _ in results)
print(f"\n{'ALL PASS' if ok_all else 'FAILURES PRESENT'} — {sum(ok for _, ok, _ in results)}/{len(results)}")
sys.exit(0 if ok_all else 1)
