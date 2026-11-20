"""Space reclamation. plan() is pure (DB + numbers in, ordered list out) so it is fixture-testable.

Rules run in the configured order, each only while more space is needed, oldest date first:
  one_star         rated 1 star            (by rating date)
  two_star         rated 2 stars           (by rating date)
  stale_watchlist  unwatched, unrated, first watchlisted more than watchlist_stale_days ago (by first watchlist date)
  stale_unmanaged  unwatched, unrated, in an unmanaged folder with lifecycle = true, born more than stale_days ago (by born date)
Invariants that no config can change: 3-5 star movies are never candidates; unidentified, multi-version and
file-less movies are never candidates; only managed folders and unmanaged folders with lifecycle = true are touched.
"""

import json
import hashlib
import logging
import os
import shutil
import time

from . import config, layout, libraries, zones
from .db import add_event, stars

log = logging.getLogger("plexcurator")
DAY = 86400
MONTH_DAYS = 30.44


def usage(path):
    u = shutil.disk_usage(path)
    return u.free, u.total


def human(n):
    return f"{n / 1e12:.2f} TB" if n >= 1e12 else f"{n / 1e9:.1f} GB"


def protected(m):
    """The code-level invariants."""
    return bool(
        stars(m["rating"]) >= 3
        or m["unidentified"]
        or m["multi_version"]
        or m["state"] != "present"
        or not m["file_present"]
        or m["zone"] not in ("unmanaged", "watchlist", "watched")
    )


def _deletable_location(cfg, m):
    if m["zone"] in ("watchlist", "watched"):
        return True
    u = zones.unmanaged_entry(cfg, m["path"])
    return bool(u and u["lifecycle"])


def _day(ts):
    return time.strftime("%Y-%m-%d", time.gmtime(ts))


def _rule_one_star(cfg, m, cutoff):
    if stars(m["rating"]) == 1:
        d = m["rated_at"] or m["born_at"] or 0
        return d, f"rated 1 star on {_day(d)}"


def _rule_two_star(cfg, m, cutoff):
    if stars(m["rating"]) == 2:
        d = m["rated_at"] or m["born_at"] or 0
        return d, f"rated 2 stars on {_day(d)}"


def _untouched(m):
    return not m["watched"] and not (m["rating"] or 0) > 0 and m["peak_percent"] == 0


def _default_stale_days(cfg):
    lc = cfg["lifecycle"]
    if "stale_days" in lc:
        return lc["stale_days"]
    return lc["stale_months"] * MONTH_DAYS


def _age_policy(cfg, rule, path):
    lc = cfg["lifecycle"]
    if rule == "stale_watchlist":
        if "watchlist_stale_days" in lc:
            return lc["watchlist_stale_days"], "rule"
    elif rule == "stale_unmanaged":
        folder = zones.unmanaged_entry(cfg, path)
        if folder and "stale_days" in folder:
            return folder["stale_days"], "folder"
    return _default_stale_days(cfg), "default"


def _age_only(cfg, rule, path):
    if rule == "stale_unmanaged":
        folder = zones.unmanaged_entry(cfg, path)
        if folder and "age_only" in folder:
            return folder["age_only"]
    return rule in cfg["lifecycle"].get("age_only", [])


def _rule_stale_watchlist(cfg, m, now):
    days, _ = _age_policy(cfg, "stale_watchlist", m["path"])
    cutoff = now - days * DAY
    if m["watchlisted_at"] and m["watchlisted_at"] <= cutoff and _untouched(m):
        return (
            m["watchlisted_at"],
            f"on the watchlist since {_day(m['watchlisted_at'])}, never watched or rated",
        )


def _rule_stale_unmanaged(cfg, m, now):
    days, _ = _age_policy(cfg, "stale_unmanaged", m["path"])
    cutoff = now - days * DAY
    if (
        m["zone"] == "unmanaged"
        and m["born_at"]
        and m["born_at"] <= cutoff
        and _untouched(m)
        and not m["watchlisted_at"]
    ):
        return (
            m["born_at"],
            f"unmanaged since {_day(m['born_at'])}, never watched, rated or watchlisted",
        )


RULES = {
    "one_star": _rule_one_star,
    "two_star": _rule_two_star,
    "stale_watchlist": _rule_stale_watchlist,
    "stale_unmanaged": _rule_stale_unmanaged,
}


def candidates(conn, cfg, now):
    rows = [
        m
        for m in conn.execute(
            "SELECT * FROM v_movie WHERE state='present' AND file_id IS NOT NULL"
        ).fetchall()
        if not protected(m) and _deletable_location(cfg, m)
    ]
    out, taken = [], set()
    for rule in cfg["lifecycle"]["rules"]:
        hits = []
        for m in rows:
            if m["id"] in taken:
                continue
            r = RULES[rule](cfg, m, now)
            if r:
                hits.append((r[0], m["id"], r[1], m))
        for age_at, _, why, m in sorted(hits, key=lambda t: (t[0], t[1])):
            taken.add(m["id"])
            age_days = max(0, (now - age_at) // DAY)
            age_only = _age_only(cfg, rule, m["path"])
            threshold_days = (
                _age_policy(cfg, rule, m["path"])[0]
                if rule in ("stale_watchlist", "stale_unmanaged")
                else None
            )
            reason = why
            if age_only:
                reason = (
                    f"age only: {rule}, {age_days} days old "
                    f"(threshold {threshold_days:g} days); {why}"
                )
            out.append(
                {
                    "movie_id": m["id"],
                    "title": m["title"],
                    "year": m["year"],
                    "rule": rule,
                    "reason": reason,
                    "age_at": age_at,
                    "age_days": age_days,
                    "age_threshold_days": threshold_days,
                    "age_only": age_only,
                    "size": m["size"] or 0,
                    "tmdb": m["tmdb"],
                    "radarr_id": m["radarr_id"],
                    "rating_key": m["plex_rating_key"],
                    "path": m["path"],
                }
            )
    return out


def preview_candidates(conn, cfg, now=None):
    """Return all eligible candidates and read-only summary groups, regardless of free space."""
    now = int(now or time.time())
    planned = candidates(conn, cfg, now)
    watchlist_dir, watched_dir = config.managed_dirs(cfg)
    grouped = {}
    for candidate in planned:
        zone = zones.zone_of(cfg, candidate["path"])
        if zone == "unmanaged":
            entry = zones.unmanaged_entry(cfg, candidate["path"])
            if not entry:
                raise ValueError(
                    f"no configured unmanaged folder for {candidate['path']}"
                )
            folder = entry["path"]
        elif zone == "watchlist":
            folder = watchlist_dir
        elif zone == "watched":
            folder = watched_dir
        else:
            raise ValueError(
                f"candidate is outside configured folders: {candidate['path']}"
            )
        candidate["folder"] = folder
        candidate["age_days"] = max(0, (now - candidate["age_at"]) // 86400)
        candidate["age_since"] = _day(candidate["age_at"])
        if candidate["rule"] in ("one_star", "two_star"):
            candidate["age_basis"] = "rating date"
            candidate["age_source"] = "rule"
            candidate["age_threshold"] = None
        else:
            candidate["age_basis"] = (
                "first watchlist date"
                if candidate["rule"] == "stale_watchlist"
                else "added date"
            )
            days, source = _age_policy(cfg, candidate["rule"], candidate["path"])
            candidate["age_source"] = source
            candidate["age_threshold"] = f"{days:g} days"
        key = (folder, candidate["rule"])
        group = grouped.setdefault(
            key,
            {
                "folder": folder,
                "rule": candidate["rule"],
                "count": 0,
                "size": 0,
                "oldest_age_days": 0,
            },
        )
        group["count"] += 1
        group["size"] += candidate["size"]
        group["oldest_age_days"] = max(group["oldest_age_days"], candidate["age_days"])
    rule_order = {rule: i for i, rule in enumerate(cfg["lifecycle"]["rules"])}
    groups = sorted(
        grouped.values(),
        key=lambda group: (
            group["folder"],
            rule_order.get(group["rule"], len(rule_order)),
        ),
    )
    return planned, groups


def alert_text(cfg, free, total, planned_bytes):
    st = cfg["storage"]
    needed = max(0, st["reclaim_to_pct"] / 100.0 * total - free)
    return (
        f"storage {human(total)} total, {human(free)} free ({100.0 * free / total:.1f}%), threshold "
        f"{st['min_free_pct']}% free (reclaim to {st['reclaim_to_pct']}%); {human(needed)} needed, rules could free "
        f"only {human(planned_bytes)}. All lifecycle rules are exhausted "
        f"({', '.join(cfg['lifecycle']['rules']) or 'none enabled'}): manual aggressive intervention is required."
    )


def plan(conn, cfg, free, total, now=None):
    """-> (selected, alert), with age-only rules independent of the free-space threshold."""
    now = int(now or time.time())
    st, adv = cfg["storage"], cfg["advanced"]
    cands = candidates(conn, cfg, now)
    age_candidates = [c for c in cands if c["age_only"]]
    space_candidates = [c for c in cands if not c["age_only"]]
    selected, projected, capped = [], free, []
    limit = adv["max_deletions_per_run"]

    for candidate in age_candidates:
        if len(selected) >= limit:
            capped.append(candidate)
            continue
        selected.append(candidate)
        projected += candidate["size"]

    space_low = 100.0 * free / total < st["min_free_pct"]
    if space_low:
        target = st["reclaim_to_pct"]
        for index, candidate in enumerate(space_candidates):
            if 100.0 * projected / total >= target:
                break
            if len(selected) >= limit:
                remaining = space_candidates[index:]
                for later in remaining:
                    if 100.0 * projected / total >= target:
                        break
                    capped.append(later)
                    projected += later["size"]
                break
            selected.append(candidate)
            projected += candidate["size"]

    messages = []
    if capped:
        sample = "; ".join(f"{c['title']} ({c['rule']})" for c in capped[:5])
        messages.append(
            f"reclaim limit reached at {limit} deletion(s) per run; "
            f"{len(capped)} eligible candidate(s) remain for a later run: {sample}"
            + (" ..." if len(capped) > 5 else "")
        )
    if space_low and 100.0 * projected / total < st["reclaim_to_pct"] and not capped:
        messages.append(alert_text(cfg, free, total, sum(c["size"] for c in selected)))
    return selected, "\n".join(messages) or None


def _age_only_policy_hash(cfg):
    policy = {
        "rules": sorted(cfg["lifecycle"].get("age_only", [])),
        "folders": sorted(
            (folder["path"], folder["age_only"])
            for folder in cfg["folders"]["unmanaged"]
            if "age_only" in folder
        ),
    }
    return hashlib.sha256(
        json.dumps(policy, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def _age_only_candidates_hash(candidates):
    values = [
        {
            "movie_id": c["movie_id"],
            "rule": c["rule"],
            "path": c["path"],
            "size": c["size"],
        }
        for c in candidates
    ]
    return hashlib.sha256(
        json.dumps(values, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def _meta_value(conn, key):
    row = conn.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
    return row[0] if row else None


def _set_meta(conn, key, value):
    conn.execute(
        "INSERT INTO meta(key,value) VALUES (?,?) "
        "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        (key, value),
    )


def age_only_confirmation(conn, cfg, planned, confirm=False):
    """Guard a new age-only policy until its current candidate list is explicitly confirmed."""
    age_candidates = [c for c in planned if c["age_only"]]
    if not age_candidates:
        if confirm:
            raise RuntimeError("there are no age-only candidates to confirm")
        return None

    policy_hash = _age_only_policy_hash(cfg)
    if _meta_value(conn, "age_only_confirmed_policy") == policy_hash:
        return None

    candidates_hash = _age_only_candidates_hash(age_candidates)
    if confirm:
        if (
            _meta_value(conn, "age_only_pending_policy") != policy_hash
            or _meta_value(conn, "age_only_pending_candidates") != candidates_hash
        ):
            raise RuntimeError(
                "the age-only candidates differ from the pending confirmation; "
                "run reclaim once to review the current list"
            )
        _set_meta(conn, "age_only_confirmed_policy", policy_hash)
        conn.execute(
            "DELETE FROM meta WHERE key IN "
            "('age_only_pending_policy', 'age_only_pending_candidates')"
        )
        conn.commit()
        return None

    _set_meta(conn, "age_only_pending_policy", policy_hash)
    _set_meta(conn, "age_only_pending_candidates", candidates_hash)
    conn.commit()
    rows = "\n".join(
        f"- {c['title']} ({c['year']}): would delete by age only; "
        f"{c['rule']}, {c['age_days']} days old, {human(c['size'])}"
        for c in age_candidates
    )
    return (
        "age-only reclaim has not been confirmed; no movies were deleted. "
        "Review the candidates below, then run `plexcurator reclaim --confirm-age-only` "
        "once to enable this policy:\n"
        f"{rows}\nCandidate list SHA-256: {candidates_hash}"
    )


def preflight(conn, cfg, now):
    """Refuse to delete on stale data or unmounted folders."""
    row = conn.execute("SELECT value FROM meta WHERE key='last_sync_ok'").fetchone()
    if not row or now - int(row[0]) > cfg["advanced"]["max_sync_age_hours"] * 3600:
        return "last successful sync is missing or too old"
    for d in [u["path"] for u in cfg["folders"]["unmanaged"]] + [
        cfg["folders"]["managed"]
    ]:
        if not os.path.isdir(d):
            return f"{d} is missing (NAS not mounted?)"
    return None


def _live_veto(plex, c, cfg):
    """Re-ask Plex right before deleting; the DB may be a day old."""
    it = plex.item(c["rating_key"]) if c["rating_key"] else None
    if it is None:
        return "not found in Plex"
    live = stars(it.get("userRating"))
    if live >= 3:
        return f"live Plex rating is {live} stars"
    if c["rule"] == "one_star" and live != 1:
        return f"live Plex rating is {live} stars, no longer 1"
    if c["rule"] == "two_star" and live != 2:
        return f"live Plex rating is {live} stars, no longer 2"
    if c["rule"] in ("stale_watchlist", "stale_unmanaged") and (
        it.get("viewCount") or it.get("viewOffset") or (it.get("userRating") or 0) > 0
    ):
        return "live Plex shows it was watched or rated"
    return None


def _targets(conn, cfg, c):
    """Folder (if the movie owns one) or the movie file plus its same-stem siblings."""
    path = c["path"]
    if zones.zone_of(cfg, path) == "other":
        raise ValueError(f"{path} is outside the managed and unmanaged folders")
    folder = layout.own_folder(cfg, path)
    if folder:
        return folder, True
    stem = os.path.splitext(os.path.basename(path))[0]
    d = os.path.dirname(path)
    return [
        os.path.join(d, n)
        for n in os.listdir(d)
        if n == stem or n.startswith(stem + ".")
    ], False


def execute(
    conn, cfg, planned, plex, radarr=None, now=None, usage_fn=None, log_fn=print
):
    """Deletes for real. Only in mode = reclaim, and the caller must not be in dry-run."""
    if cfg["mode"] != "reclaim":
        raise RuntimeError("deletion needs mode = reclaim")
    now = int(now or time.time())
    problem = preflight(conn, cfg, now)
    if problem:
        raise RuntimeError(f"refusing to delete: {problem}")
    usage_fn = usage_fn or (lambda: usage(config.measure_path(cfg)))
    results = []
    for c in planned[: cfg["advanced"]["max_deletions_per_run"]]:
        free, total = usage_fn()
        if (
            not c["age_only"]
            and 100.0 * free / total >= cfg["storage"]["reclaim_to_pct"]
        ):
            log_fn("target reached; stopping")
            break
        did = conn.execute(
            "INSERT INTO deletion(movie_id,selected_at,rule,reason,size_bytes) VALUES (?,?,?,?,?)",
            (c["movie_id"], now, c["rule"], c["reason"], c["size"]),
        ).lastrowid
        add_event(conn, c["movie_id"], now, "selected", c["rule"], c["reason"])
        conn.commit()
        try:
            veto = _live_veto(plex, c, cfg)
            if veto:
                conn.execute(
                    "UPDATE deletion SET status='skipped', error=? WHERE id=?",
                    (veto, did),
                )
                conn.commit()
                results.append((c, f"skipped: {veto}"))
                log_fn(f"skip {c['title']}: {veto}")
                continue
            target, is_folder = _targets(conn, cfg, c)
            if radarr:  # reversible steps first; the ban stops any list re-adding it
                if c["radarr_id"]:
                    radarr.delete_with_exclusion(c["radarr_id"])
                elif c["tmdb"]:
                    radarr.add_exclusion(int(c["tmdb"]), c["title"], c["year"])
                else:
                    log.warning(
                        "no Radarr id or tmdb id for %r: it cannot be banned in Radarr",
                        c["title"],
                    )
                conn.execute("UPDATE deletion SET radarr_done=1 WHERE id=?", (did,))
            if is_folder:
                shutil.rmtree(target)
            else:
                for p in target:
                    os.remove(p)
            conn.execute("UPDATE deletion SET files_done=1 WHERE id=?", (did,))
            life = conn.execute(
                "SELECT life FROM movie WHERE id=?", (c["movie_id"],)
            ).fetchone()[0]
            conn.execute(
                "UPDATE movie SET state='retired', retired_at=?, updated_at=? WHERE id=?",
                (now, now, c["movie_id"]),
            )
            conn.execute("UPDATE file SET present=0 WHERE movie_id=?", (c["movie_id"],))
            add_event(
                conn,
                c["movie_id"],
                now,
                "retired",
                c["rule"],
                json.dumps({"reason": c["reason"]}),
                life=life,
            )
            conn.execute(
                "UPDATE deletion SET status='done', executed_at=? WHERE id=?",
                (now, did),
            )
            conn.commit()
            results.append((c, "retired"))
            log_fn(f"retired {c['title']} ({c['rule']}): {c['reason']}")
        except Exception as e:  # stop touching this movie, keep going with the next
            conn.execute(
                "UPDATE deletion SET status='failed', error=? WHERE id=?", (str(e), did)
            )
            conn.commit()
            results.append((c, f"failed: {e}"))
            log_fn(f"FAILED {c['title']}: {e}")
    if any(s == "retired" for _, s in results):
        for sec in libraries.selected_movie_sections(cfg, plex):
            plex.scan(sec["key"])
            plex.empty_trash(sec["key"])
    return results
