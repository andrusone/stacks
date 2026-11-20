"""Plex watchlist ingestion. Membership is kept by external id (the movie may not be on the NAS yet);
the first date a movie's id was seen on a watchlist becomes its `watchlisted` event and watchlisted_at.
"""

import logging
import time

from . import identity
from .db import add_event

log = logging.getLogger("plexcurator")


def sync_watchlist(conn, plex, now=None):
    now = int(now or time.time())
    stats = {"items": 0, "unmatched": 0, "readded": 0, "linked": 0, "error": None}
    try:
        iterator = getattr(plex, "iter_watchlist", None)
        items = iterator() if iterator else plex.watchlist()
    except Exception as e:  # plex.tv is a cloud call; never fail the run for it
        stats["error"] = str(e)
        log.warning("watchlist not available: %s", e)
        return stats
    seen, readded = set(), set()
    for it in items:
        ids = identity.from_guids(it)
        stats["items"] += 1
        if not ids:
            stats["unmatched"] += 1
            continue
        for provider, value in ids.items():
            seen.add((provider, value))
            row = conn.execute(
                "SELECT present FROM watchlist WHERE provider=? AND value=?",
                (provider, value),
            ).fetchone()
            if row is None:
                conn.execute(
                    "INSERT INTO watchlist VALUES (?,?,?,?,1)",
                    (provider, value, now, now),
                )
            else:
                if not row["present"]:
                    readded.add((provider, value))
                conn.execute(
                    "UPDATE watchlist SET present=1, last_seen_at=? WHERE provider=? AND value=?",
                    (now, provider, value),
                )
    if stats["items"]:  # an empty answer may be a blip: do not mark everything absent
        for r in conn.execute(
            "SELECT provider, value FROM watchlist WHERE present=1"
        ).fetchall():
            if (r["provider"], r["value"]) not in seen:
                conn.execute(
                    "UPDATE watchlist SET present=0 WHERE provider=? AND value=?",
                    (r["provider"], r["value"]),
                )
    linked_readds = set()
    for r in conn.execute(
        "SELECT provider, value, first_seen_at FROM watchlist WHERE present=1"
    ).fetchall():
        mid = identity.find_movie(conn, {r["provider"]: r["value"]})
        if mid is None:
            continue
        m = conn.execute(
            "SELECT watchlisted_at FROM movie WHERE id=?", (mid,)
        ).fetchone()
        if m["watchlisted_at"] is None:
            conn.execute(
                "UPDATE movie SET watchlisted_at=? WHERE id=?",
                (r["first_seen_at"], mid),
            )
            add_event(conn, mid, r["first_seen_at"], "watchlisted")
            stats["linked"] += 1
        elif (r["provider"], r["value"]) in readded and mid not in linked_readds:
            add_event(conn, mid, now, "watchlisted", detail="re-added")
            linked_readds.add(mid)
            stats["readded"] += 1
    conn.commit()
    return stats
