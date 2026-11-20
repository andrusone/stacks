"""Filesystem walk of unmanaged + managed folders: a safety net beside the Plex-driven sync.
Finds video files nobody knows yet and collects their data. Identification: a {tmdb-N}/{imdb-tt} tag in the
name, then Radarr's tmdbId for the path; otherwise the movie is `unidentified` (and an alert is raised).
"""

import logging
import os
import re
import time

from . import collect, identity, naming, sync
from . import probe as P

log = logging.getLogger("plexcurator")
_SKIP_DIRS = ("@eaDir", "#recycle", ".Trash")
_YEAR = re.compile(r"[\(\.\s]((?:19|20)\d\d)[\)\.\s]")
_NOISE = re.compile(r"\{[^}]*\}|\[[^\]]*\]")


def walk(cfg):
    roots = [u["path"] for u in cfg["folders"]["unmanaged"]]
    if cfg["folders"]["managed"]:
        roots.append(cfg["folders"]["managed"])
    exts = set(cfg["advanced"]["video_exts"])
    for root in roots:
        for dirpath, dirnames, files in os.walk(root):
            dirnames[:] = sorted(
                d for d in dirnames if not d.startswith(".") and d not in _SKIP_DIRS
            )
            for f in sorted(files):
                if os.path.splitext(f)[1].lower() in exts and not f.startswith("."):
                    yield os.path.join(dirpath, f)


def title_year(path):
    stem = _NOISE.sub(" ", os.path.splitext(os.path.basename(path))[0])
    folder = _NOISE.sub(" ", os.path.basename(os.path.dirname(path)))
    if not _YEAR.search(stem + " ") and _YEAR.search(folder + " "):
        stem = folder  # the folder carries "Title (Year)", the file name does not
    m = _YEAR.search(stem + " ")
    year = int(m.group(1)) if m else None
    title = stem[: m.start()] if m else stem
    return (
        naming.clean(title.replace(".", " ").replace("_", " ")) or naming.clean(stem),
        year,
    )


def discover(
    conn, cfg, radarr=None, now=None, fp_fn=P.fingerprint, probe_fn=None, do_probe=True
):
    now = int(now or time.time())
    probe_fn = probe_fn or sync._default_probe(cfg)
    ridx = identity.radarr_index(cfg, radarr.movies() if radarr else [])
    stats = {"new": 0, "unidentified": 0, "duplicates": 0, "missing": 0, "probed": 0}
    known = {r["path"] for r in conn.execute("SELECT path FROM file WHERE present=1")}
    for path in walk(cfg):
        if path in known:
            continue
        st, fp = sync.file_state(conn, path, fp_fn)
        if st is None:
            continue
        same = conn.execute(
            "SELECT movie_id, path FROM file WHERE fingerprint=?", (fp,)
        ).fetchone()
        if (
            same
            and os.path.exists(same["path"])
            and os.path.normpath(same["path"]) != os.path.normpath(path)
        ):
            log.warning(
                "anomaly: %s is an identical copy of %s; ignoring the copy",
                path,
                same["path"],
            )
            stats["duplicates"] += 1
            continue
        ids = identity.from_name(path)
        radarr_id = None
        if not ids:
            ids, radarr_id = identity.from_radarr(ridx, path)
        mid = identity.find_movie(conn, ids, fp)
        if mid is not None:
            have = conn.execute(
                "SELECT path FROM file WHERE movie_id=?", (mid,)
            ).fetchone()
            if have and have["path"] != path and os.path.exists(have["path"]):
                log.warning(
                    "anomaly: %s looks like a second file for movie %s (%s); ignoring it",
                    path,
                    mid,
                    have["path"],
                )
                stats["duplicates"] += 1
                continue
            identity.attach_ids(conn, mid, ids)
        else:
            title, year = title_year(path)
            born = min(now, int(st.st_mtime))
            mid = identity.create_movie(conn, title, year, ids, now, born)
            stats["new"] += 1
            if not ids:
                stats["unidentified"] += 1
        if radarr_id:
            conn.execute("UPDATE movie SET radarr_id=? WHERE id=?", (radarr_id, mid))
        fid, need = sync.upsert_file(conn, cfg, mid, path, st, fp, now)
        if need and do_probe:
            try:
                pj, mi = probe_fn(path)
                collect.store_probe(conn, cfg, mid, fid, pj, mi, now)
                stats["probed"] += 1
            except Exception as e:
                conn.execute(
                    "INSERT OR IGNORE INTO issue(movie_id,ts,level,source,message,line_hash) VALUES (?,?,?,?,?,?)",
                    (mid, now, "ERROR", "probe", f"ffprobe failed: {e}", f"probe:{fp}"),
                )
        conn.commit()
    for r in conn.execute(
        "SELECT f.id, f.path, m.title FROM file f JOIN movie m ON m.id=f.movie_id "
        "WHERE f.present=1 AND m.state='present'"
    ).fetchall():
        if not os.path.exists(r["path"]):
            log.warning(
                "anomaly: file for %r is gone from disk: %s", r["title"], r["path"]
            )
            conn.execute("UPDATE file SET present=0 WHERE id=?", (r["id"],))
            stats["missing"] += 1
    conn.commit()
    return stats
