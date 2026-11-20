"""Check and optionally repair Radarr paths for movies plexcurator has moved."""

import os
from dataclasses import dataclass, field

from . import clients, zones


@dataclass
class CheckResult:
    checked: int = 0
    drifted: int = 0
    repaired: int = 0
    skipped: int = 0
    findings: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)
    skipped_reason: str | None = None


def check(conn, cfg, radarr, fix=False, moved_before=None):
    result = CheckResult()
    if radarr is None:
        result.skipped_reason = "Radarr is not configured"
        return result

    try:
        radarr_movies = radarr.movies()
    except Exception as error:
        result.errors.append(f"Radarr path check failed: {clients.error_status(error)}")
        return result
    if not isinstance(radarr_movies, list):
        result.errors.append("Radarr path check failed: invalid movie list")
        return result

    by_id, by_tmdb = {}, {}
    for movie in radarr_movies:
        if not isinstance(movie, dict):
            continue
        radarr_id = movie.get("id")
        if isinstance(radarr_id, int) and not isinstance(radarr_id, bool):
            by_id[radarr_id] = movie
        tmdb_id = movie.get("tmdbId")
        if tmdb_id is not None:
            by_tmdb[str(tmdb_id)] = movie

    recent_move_clause = ""
    params = []
    if moved_before is not None:
        recent_move_clause = """
              AND NOT EXISTS (
                  SELECT 1 FROM event e2
                  WHERE e2.movie_id=m.id AND e2.kind='moved' AND e2.ts >= ?
              )"""
        params.append(moved_before)
    rows = conn.execute(
        f"""SELECT m.id, m.title, m.radarr_id,
                   (SELECT value FROM external_id
                    WHERE movie_id=m.id AND provider='tmdb') AS tmdb,
                   f.path
            FROM movie m
            JOIN file f ON f.movie_id=m.id
            WHERE m.state='present' AND f.present=1
              AND EXISTS (
                  SELECT 1 FROM event e
                  WHERE e.movie_id=m.id AND e.kind='moved'
              ){recent_move_clause}
            ORDER BY m.id""",
        params,
    ).fetchall()

    path_map = cfg["radarr"]["path_map"]
    for row in rows:
        movie = by_tmdb.get(str(row["tmdb"])) if row["tmdb"] else None
        if movie is None and row["radarr_id"] is not None:
            candidate = by_id.get(row["radarr_id"])
            candidate_tmdb = candidate.get("tmdbId") if candidate else None
            if candidate is not None and (
                not row["tmdb"]
                or candidate_tmdb is None
                or str(candidate_tmdb) == str(row["tmdb"])
            ):
                movie = candidate
        if movie is None:
            result.skipped += 1
            continue

        result.checked += 1
        expected = os.path.normpath(os.path.dirname(row["path"]))
        radarr_path = movie.get("path")
        actual = (
            os.path.normpath(zones.map_path(path_map, radarr_path))
            if isinstance(radarr_path, str) and radarr_path
            else None
        )
        if actual == expected:
            continue

        result.drifted += 1
        title = row["title"] or "untitled"
        message = (
            f"Radarr path drift for {title!r}: Radarr has "
            f"{actual or '(no path)'}, file folder is {expected}"
        )
        if not fix:
            result.findings.append(message)
            continue

        radarr_id = movie.get("id")
        if not isinstance(radarr_id, int) or isinstance(radarr_id, bool):
            result.errors.append(f"{message}; Radarr movie has no valid id")
            continue
        try:
            radarr.track_at(radarr_id, zones.unmap_path(path_map, expected))
        except Exception as error:
            result.errors.append(
                f"{message}; repair failed: {clients.error_status(error)}"
            )
            continue
        result.repaired += 1
        result.findings.append(f"{message}; repaired")

    return result
