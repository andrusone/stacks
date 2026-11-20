"""Plex (+Radarr) -> DB sync. Resolves identity, records dated events, owns the watch percentage."""

import itertools
import json
import logging
import os
import time

from . import collect, identity, libraries, zones
from . import probe as P
from .db import add_event, stars

log = logging.getLogger("plexcurator")


def _library_items(plex, sections):
    """Yield one Plex page at a time when the client supports streaming."""
    for section in sections:
        iterator = getattr(plex, "iter_movies", None)
        if iterator:
            yield from iterator(section["key"])
        else:
            yield from plex.movies(section["key"])


def percent_of(item):
    """Resume position as a percent, or None when Plex has no offset (never played, or finished: offset is cleared)."""
    dur, off = item.get("duration") or 0, item.get("viewOffset") or 0
    return min(100.0, round(100.0 * off / dur, 1)) if dur and off else None


def _default_probe(cfg):
    a = cfg["advanced"]
    return lambda path: (
        P.run_ffprobe(path, a["ffprobe"]),
        P.run_mediainfo(path, a["mediainfo"]),
    )


def file_state(conn, path, fp_fn):
    try:
        st = os.stat(path)
    except OSError:
        return None, None
    row = conn.execute(
        "SELECT fingerprint FROM file WHERE path=? AND size=? AND mtime=?",
        (path, st.st_size, int(st.st_mtime)),
    ).fetchone()
    return st, row[0] if row else fp_fn(path, st.st_size)


def upsert_file(conn, cfg, mid, path, st, fp, now):
    """One current file per movie. Returns (file_id, needs_probe)."""
    zone = zones.zone_of(cfg, path)
    f = conn.execute("SELECT * FROM file WHERE movie_id=?", (mid,)).fetchone()
    if f is None:
        fid = conn.execute(
            """INSERT INTO file(movie_id,path,size,mtime,fingerprint,zone,first_seen_at,last_seen_at)
                              VALUES (?,?,?,?,?,?,?,?)""",
            (mid, path, st.st_size, int(st.st_mtime), fp, zone, now, now),
        ).lastrowid
        return fid, True
    if f["path"] != path:
        log.info("movie %s: file now at %s (was %s)", mid, path, f["path"])
    conn.execute(
        "UPDATE file SET path=?, size=?, mtime=?, fingerprint=?, zone=?, present=1, last_seen_at=? WHERE id=?",
        (path, st.st_size, int(st.st_mtime), fp, zone, now, f["id"]),
    )
    return f["id"], f["fingerprint"] != fp or f["probed_at"] is None


def _update_watch(conn, cfg, m, item, now):
    vc = item.get("viewCount") or 0
    ts = item.get("lastViewedAt") or now
    peak, pct, new_peak = m["peak_percent"], percent_of(item), m["peak_percent"]
    if (
        vc > m["play_count"]
    ):  # a play completed (or the library was already watched): 100
        new_peak = 100.0
        add_event(conn, m["id"], ts, "watched", 100, json.dumps({"viewCount": vc}))
    elif pct is not None and pct >= peak + 1:
        new_peak = pct
        add_event(conn, m["id"], ts, "watched", pct)
    sets, args = ["peak_percent=?", "play_count=MAX(play_count, ?)"], [new_peak, vc]
    if new_peak >= cfg["watched_pct"] and not m["watched"]:
        sets += ["watched=1", "first_watched_at=?"]
        args.append(ts)
    conn.execute(f"UPDATE movie SET {', '.join(sets)} WHERE id=?", [*args, m["id"]])
    return vc


def _update_rating(conn, plex, m, item, new_item, restore, now):
    rating, old = item.get("userRating"), m["rating"]
    if restore and old and not rating and stars(old) > 0:
        plex.set_rating(
            item["ratingKey"], old
        )  # Plex recreated the item and lost the rating
        return
    if rating == old:
        return
    if stars(rating) != stars(old):
        when = item.get("lastRatedAt") or now
        add_event(
            conn, m["id"], when, "rated", stars(rating), json.dumps({"rating": rating})
        )
        conn.execute(
            "UPDATE movie SET rating=?, rated_at=? WHERE id=?", (rating, when, m["id"])
        )
    else:
        conn.execute("UPDATE movie SET rating=? WHERE id=?", (rating, m["id"]))


def sync(
    conn,
    cfg,
    plex,
    radarr=None,
    now=None,
    fp_fn=P.fingerprint,
    probe_fn=None,
    do_probe=True,
    restore=True,
):
    now = int(now or time.time())
    probe_fn = probe_fn or _default_probe(cfg)
    sections = libraries.selected_movie_sections(cfg, plex)
    if cfg["plex"]["libraries"] == "configured" and not sections:
        log.warning(
            "no Plex movie libraries overlap the configured folders; no library movies were synced"
        )
    items = iter(_library_items(plex, sections))
    first_item = next(items, None)
    if (
        first_item is None
        and conn.execute("SELECT 1 FROM movie WHERE state='present' LIMIT 1").fetchone()
    ):
        raise RuntimeError(
            "Plex returned no movies but the DB has present ones; refusing to continue (Plex down?)"
        )
    if first_item is not None:
        items = itertools.chain((first_item,), items)

    rmovies = radarr.movies() if radarr else []
    ridx = identity.radarr_index(cfg, rmovies)
    rid_by_tmdb = {str(m["tmdbId"]): m["id"] for m in rmovies if m.get("tmdbId")}
    del rmovies
    seen, stats = (
        set(),
        {
            "new": 0,
            "reborn": 0,
            "unidentified": 0,
            "probed": 0,
            "restored": 0,
            "multi_version": 0,
        },
    )

    for it in items:
        pmap = cfg["plex"]["path_map"]
        paths = [
            zones.map_path(pmap, pt["file"])
            for md in it.get("Media", [])
            for pt in md.get("Part", [])
            if pt.get("file")
        ]
        path = paths[0] if paths else None
        st, fp = file_state(conn, path, fp_fn) if path else (None, None)

        ids = identity.from_guids(it) or (identity.from_name(path) if path else {})
        radarr_id = None
        if not ids and path:
            ids, radarr_id = identity.from_radarr(ridx, path)
        mid = identity.find_movie(conn, ids, fp)
        if (
            mid is None and not ids
        ):  # unidentified and unreadable: don't duplicate every run
            r = conn.execute(
                "SELECT id FROM movie WHERE unidentified=1 AND plex_rating_key=?",
                (str(it["ratingKey"]),),
            ).fetchone()
            mid = r[0] if r else None
        new = mid is None
        if new:
            mid = identity.create_movie(
                conn, it.get("title"), it.get("year"), ids, now, it.get("addedAt")
            )
            stats["new"] += 1
        else:
            identity.attach_ids(conn, mid, ids)
        seen.add(mid)
        m = conn.execute("SELECT * FROM movie WHERE id=?", (mid,)).fetchone()

        if m["state"] == "retired":  # rare second life
            conn.execute(
                "UPDATE movie SET state='present', retired_at=NULL, life=life+1 WHERE id=?",
                (mid,),
            )
            add_event(conn, mid, now, "reborn", life=m["life"] + 1)
            stats["reborn"] += 1
            m = conn.execute("SELECT * FROM movie WHERE id=?", (mid,)).fetchone()

        key_changed = bool(m["plex_rating_key"]) and m["plex_rating_key"] != str(
            it["ratingKey"]
        )
        if (
            key_changed
            and restore
            and m["play_count"]
            and not (it.get("viewCount") or 0)
        ):
            plex.scrobble(it["ratingKey"])
            it = dict(it, viewCount=m["play_count"])
            stats["restored"] += 1
        _update_watch(conn, cfg, m, it, now)
        _update_rating(conn, plex, m, it, new, restore and key_changed, now)
        multi = int(len(set(paths)) > 1)
        stats["multi_version"] += multi
        rid = radarr_id or rid_by_tmdb.get(ids.get("tmdb", ""))
        conn.execute(
            """UPDATE movie SET title=?, year=?, plex_rating_key=?, radarr_id=COALESCE(?, radarr_id),
                        multi_version=?, updated_at=? WHERE id=?""",
            (
                it.get("title"),
                it.get("year"),
                str(it["ratingKey"]),
                rid,
                multi,
                now,
                mid,
            ),
        )
        collect.put_source(conn, mid, "plex", it, now)

        if st is not None:
            fid, need = upsert_file(conn, cfg, mid, path, st, fp, now)
            if need and do_probe:
                try:
                    pj, mi = probe_fn(path)
                    collect.store_probe(conn, cfg, mid, fid, pj, mi, now)
                    stats["probed"] += 1
                except Exception as e:  # a probe failure is data too
                    conn.execute(
                        "INSERT OR IGNORE INTO issue(movie_id,ts,level,source,message,line_hash) "
                        "VALUES (?,?,?,?,?,?)",
                        (
                            mid,
                            now,
                            "ERROR",
                            "probe",
                            f"ffprobe failed: {e}",
                            f"probe:{fp}",
                        ),
                    )
        else:
            log.warning(
                "anomaly: Plex lists %r but %s is not readable from this host",
                it.get("title"),
                path,
            )
        if multi:
            log.warning(
                "anomaly: %r has several versions in Plex; it will not be curated",
                it.get("title"),
            )

    for r in conn.execute(
        "SELECT id, title FROM movie WHERE state='present'"
    ).fetchall():
        if r["id"] not in seen:
            log.warning(
                "anomaly: %r (movie %s) is no longer listed by Plex",
                r["title"],
                r["id"],
            )
    stats["unidentified"] = conn.execute(
        "SELECT COUNT(*) FROM movie WHERE unidentified=1 AND state='present'"
    ).fetchone()[0]
    conn.execute("INSERT OR REPLACE INTO meta VALUES ('last_sync_ok', ?)", (str(now),))
    conn.commit()
    return stats
