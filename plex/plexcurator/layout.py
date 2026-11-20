"""Managed folder layout and moves.

<managed>/Watchlist/<stem>/<stem>.<ext>                       flat
<managed>/Watched/<video>/<audio>/<0-5>/<stem>/<stem>.<ext>   why it is kept is the path
Unmanaged folders are only ever moved OUT of; nothing is moved back into them.
"""

import json
import logging
import os
import shutil
import time

from . import classes, clients, collect, config, libraries, naming, zones
from .db import add_event, stars

log = logging.getLogger("plexcurator")


def tree(cfg):
    """Every directory the managed root can hold (many stay empty; that is intended)."""
    wl, wd = config.managed_dirs(cfg)
    out = [cfg["folders"]["managed"], wl, wd]
    for v, *_ in classes.video_table(cfg):
        for a, _ in classes.audio_table(cfg):
            out += [os.path.join(wd, v, a, str(s)) for s in range(6)]
    return out


def ensure_tree(cfg, create=True):
    """Create missing managed directories. Never deletes. Returns the ones that were (or would be) created."""
    todo = [d for d in tree(cfg) if not os.path.isdir(d)]
    if create:
        for d in todo:
            os.makedirs(d, exist_ok=True)
    return todo


def _video_files(folder, cfg):
    exts = set(cfg["advanced"]["video_exts"])
    try:
        return [f for f in os.listdir(folder) if os.path.splitext(f)[1].lower() in exts]
    except OSError:
        return []


def _roots(cfg):
    return {
        os.path.normpath(p)
        for p in [*tree(cfg), *(u["path"] for u in cfg["folders"]["unmanaged"])]
    }


def own_folder(cfg, path):
    """The movie's own folder (one video file, not a library/layout root), else None: then only the file is handled."""
    folder = os.path.normpath(os.path.dirname(path))
    return (
        folder
        if folder not in _roots(cfg) and len(_video_files(folder, cfg)) == 1
        else None
    )


def desired_dir(cfg, m):
    """(directory the movie's own folder belongs in, reason) or None to leave it alone."""
    if (
        m["unidentified"]
        or m["multi_version"]
        or m["state"] != "present"
        or not m["file_present"]
        or m["zone"] not in ("unmanaged", "watchlist", "watched")
        or not m["video_class"]
        or not m["audio_class"]
    ):
        return None
    wl, wd = config.managed_dirs(cfg)
    stars_ = stars(m["rating"])
    if m["zone"] == "watched" or m["watched"] or stars_ > 0:
        if m["zone"] == "watched":
            reason = "refile"
        elif m["watched"]:
            reason = "watched"
        else:
            reason = "rated"
        return os.path.join(wd, m["video_class"], m["audio_class"], str(stars_)), reason
    if m["zone"] == "watchlist":
        return wl, "refile"
    if m["zone"] == "unmanaged" and m["on_watchlist"]:
        return wl, "watchlisted"
    return None


def plan_moves(conn, cfg):
    out = []
    rows = conn.execute(
        """SELECT v.*, EXISTS (SELECT 1 FROM external_id e JOIN watchlist w
                              ON w.provider = e.provider AND w.value = e.value AND w.present = 1
                              WHERE e.movie_id = v.id) AS on_watchlist
                           FROM v_movie v WHERE v.state='present' AND v.file_id IS NOT NULL"""
    ).fetchall()
    for m in rows:
        want = desired_dir(cfg, m)
        stem = naming.curated_stem(m, cfg)
        if want is None or stem is None:
            continue
        dst_dir, reason = want
        new_folder = os.path.join(dst_dir, stem)
        new_file = os.path.join(new_folder, naming.curated_file(m, cfg))
        if os.path.normpath(new_file) == os.path.normpath(m["path"]):
            continue
        folder = own_folder(cfg, m["path"])
        out.append(
            {
                "movie_id": m["id"],
                "title": m["title"],
                "reason": reason,
                "src_file": m["path"],
                "src_folder": folder,
                "dst_folder": new_folder,
                "dst_file": new_file,
                "radarr_id": m["radarr_id"],
                "video": m["video_class"],
                "audio": m["audio_class"],
                "stars": stars(m["rating"]),
            }
        )
    return out


def _rename_prefix(folder, old_stem, new_stem):
    for name in os.listdir(folder):
        if name == old_stem or name.startswith(old_stem + "."):
            new = new_stem + name[len(old_stem) :]
            if new != name:
                os.rename(os.path.join(folder, name), os.path.join(folder, new))


def _do_move(p):
    old_stem = os.path.splitext(os.path.basename(p["src_file"]))[0]
    new_stem = os.path.basename(p["dst_folder"])
    if os.path.exists(p["dst_folder"]) and os.path.normpath(
        p["dst_folder"]
    ) != os.path.normpath(p["src_folder"] or ""):
        raise FileExistsError(p["dst_folder"])
    if p["src_folder"]:
        if os.path.normpath(p["src_folder"]) != os.path.normpath(p["dst_folder"]):
            os.makedirs(os.path.dirname(p["dst_folder"]), exist_ok=True)
            shutil.move(p["src_folder"], p["dst_folder"])
        _rename_prefix(p["dst_folder"], old_stem, new_stem)
        if not os.path.exists(
            p["dst_file"]
        ):  # the movie file itself did not share the folder's stem
            src = os.path.join(p["dst_folder"], os.path.basename(p["src_file"]))
            os.rename(src, p["dst_file"])
    else:  # loose file: take it and its same-stem siblings
        os.makedirs(p["dst_folder"])
        src_dir = os.path.dirname(p["src_file"])
        for name in os.listdir(src_dir):
            if name == old_stem or name.startswith(old_stem + "."):
                shutil.move(
                    os.path.join(src_dir, name),
                    os.path.join(p["dst_folder"], new_stem + name[len(old_stem) :]),
                )


def apply_moves(
    conn,
    cfg,
    plan,
    execute=False,
    radarr=None,
    plex=None,
    probe_fn=None,
    now=None,
    radarr_errors=None,
):
    """Execute (or just describe) the plan. Returns [(item, status)]."""
    now = int(now or time.time())
    done = []
    for p in plan:
        if not execute:
            done.append((p, "dry-run"))
            continue
        try:
            _do_move(p)
        except Exception as e:
            log.error("move failed for %r: %s", p["title"], e)
            done.append((p, f"failed: {e}"))
            continue
        zone = zones.zone_of(cfg, p["dst_file"])
        conn.execute(
            "UPDATE file SET path=?, zone=? WHERE movie_id=?",
            (p["dst_file"], zone, p["movie_id"]),
        )
        add_event(
            conn,
            p["movie_id"],
            now,
            "moved",
            p["dst_file"],
            json.dumps(
                {
                    "from": p["src_file"],
                    "reason": p["reason"],
                    "video": p["video"],
                    "audio": p["audio"],
                    "stars": p["stars"],
                }
            ),
        )
        conn.commit()
        if probe_fn:  # metadata recollected at the new location
            try:
                f = conn.execute(
                    "SELECT id FROM file WHERE movie_id=?", (p["movie_id"],)
                ).fetchone()
                pj, mi = probe_fn(p["dst_file"])
                collect.store_probe(conn, cfg, p["movie_id"], f["id"], pj, mi, now)
                conn.commit()
            except Exception as e:
                log.warning("re-probe after move failed for %r: %s", p["title"], e)
        if radarr and p["radarr_id"]:
            radarr_path = p["dst_folder"]
            try:
                radarr_path = zones.unmap_path(
                    cfg["radarr"]["path_map"], p["dst_folder"]
                )
                radarr.track_at(
                    p["radarr_id"],
                    radarr_path,
                )
            except Exception as e:
                message = (
                    f"Radarr update failed for {p['title']!r} (file already moved to "
                    f"{radarr_path}; no retry attempted): {clients.error_status(e)}"
                )
                log.error("%s", message)
                if radarr_errors is not None:
                    radarr_errors.append(message)
        done.append((p, "moved"))
    if execute and plex and any(s == "moved" for _, s in done):
        for sec in libraries.selected_movie_sections(cfg, plex):
            plex.scan(sec["key"])
    return done
