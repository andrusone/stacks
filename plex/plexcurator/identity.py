"""Who is this movie? External ids from Plex guids, Radarr (by path) or a {tmdb-123} tag in the file name.
A movie with none of them is `unidentified`: tracked, never moved, renamed or deleted.
"""

import os
import re

from . import zones
from .db import add_event

TAG = re.compile(r"\{(tmdb|imdb)-([A-Za-z0-9]+)\}")
PROVIDERS = ("tmdb", "imdb")


def from_guids(item):
    ids = {}
    for g in item.get("Guid", []):
        k, _, v = g.get("id", "").partition("://")
        if k == "tmdb" and v.isdigit():
            ids["tmdb"] = v
        elif k == "imdb" and v.startswith("tt"):
            ids["imdb"] = v
    return ids


def from_name(path):
    return {
        k: v
        for k, v in TAG.findall(os.path.basename(path))
        + TAG.findall(os.path.basename(os.path.dirname(path)))
    }


def radarr_index(cfg, movies):
    """[(folder as this host sees it, tmdb id, radarr id)] longest folder first."""
    out = []
    for m in movies or []:
        if m.get("path") and m.get("tmdbId"):
            out.append(
                (
                    os.path.normpath(
                        zones.map_path(cfg["radarr"]["path_map"], m["path"])
                    ),
                    str(m["tmdbId"]),
                    m["id"],
                )
            )
    return sorted(out, key=lambda t: -len(t[0]))


def from_radarr(idx, path):
    p = os.path.normpath(path)
    for folder, tmdb, rid in idx:
        if p == folder or p.startswith(folder + os.sep):
            return {"tmdb": tmdb}, rid
    return {}, None


def find_movie(conn, ids, fingerprint=None):
    for provider in PROVIDERS:
        if ids.get(provider):
            r = conn.execute(
                "SELECT movie_id FROM external_id WHERE provider=? AND value=?",
                (provider, ids[provider]),
            ).fetchone()
            if r:
                return r[0]
    if fingerprint:
        r = conn.execute(
            "SELECT movie_id FROM file WHERE fingerprint=?", (fingerprint,)
        ).fetchone()
        if r:
            return r[0]
    return None


def attach_ids(conn, movie_id, ids):
    """Add ids the movie lacks; an id that belongs to another movie is ignored (never stolen)."""
    for provider, value in ids.items():
        conn.execute(
            "INSERT OR IGNORE INTO external_id(movie_id, provider, value) VALUES (?,?,?)",
            (movie_id, provider, value),
        )
    if (
        any(ids.get(p) for p in PROVIDERS)
        and conn.execute(
            "SELECT 1 FROM external_id WHERE movie_id=?", (movie_id,)
        ).fetchone()
    ):
        conn.execute("UPDATE movie SET unidentified=0 WHERE id=?", (movie_id,))


def create_movie(conn, title, year, ids, now, born_at=None):
    cur = conn.execute(
        "INSERT INTO movie(title, year, unidentified, born_at, first_seen_at, updated_at) "
        "VALUES (?,?,?,?,?,?)",
        (title, year, 0 if ids else 1, born_at or now, now, now),
    )
    mid = cur.lastrowid
    attach_ids(conn, mid, ids)
    add_event(conn, mid, born_at or now, "born", detail=None if ids else "unidentified")
    return mid
