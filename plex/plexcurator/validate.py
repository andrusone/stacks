"""Config validation. Read-only: filesystem checks and GET requests only (never writes to Plex/Radarr)."""

import os
import re
import shutil
import sys
import math

from . import clients, config, libraries

_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]*$")


def _check_days(value, name, errors):
    if type(value) is not int or value < 1:
        errors.append(f"{name} must be an integer of at least 1")


def _writable_dir(path):
    """Existing dir that is writable, or a missing dir whose nearest existing parent is writable."""
    p = path
    while p and not os.path.exists(p):
        parent = os.path.dirname(p)
        if parent == p:
            break
        p = parent
    return os.path.isdir(p) and os.access(p, os.W_OK)


def _nested(a, b):
    a, b = os.path.normpath(a), os.path.normpath(b)
    return a == b or a.startswith(b + os.sep) or b.startswith(a + os.sep)


def _check_hdr(cfg, errors):
    seen = {}
    for key, spec in cfg["hdr"].items():
        if key not in ("dv", "hdr10plus", "hdr10", "hlg", "sdr"):
            errors.append(
                f"[hdr] unknown type {key!r} (types: dv, hdr10plus, hdr10, hlg, sdr)"
            )
            continue
        tag = str(spec.get("tag", ""))
        if re.search(r'[\s\[\]<>:"/\\|?*{}\x00-\x1f]', tag):
            errors.append(
                f"[hdr.{key}] tag {tag!r} must not contain spaces, brackets, braces or characters unusable in a file name"
            )
        if tag and tag in seen:
            errors.append(
                f"[hdr.{key}] tag {tag!r} is already used by {seen[tag]}; tags must be unique so names can be parsed back"
            )
        if tag:
            seen[tag] = key


def _check_plex_libraries(cfg, errors):
    selection = cfg["plex"].get("libraries", "configured")
    if selection in ("configured", "all"):
        return
    if not isinstance(selection, list) or not selection:
        errors.append(
            "[plex] libraries must be 'configured', 'all', or a non-empty list of library titles"
        )
        return
    if any(not isinstance(title, str) or not title.strip() for title in selection):
        errors.append("[plex] libraries list must contain non-empty library titles")
        return
    if len(set(selection)) != len(selection):
        errors.append("[plex] libraries list must not contain duplicate titles")


def _check_table(cfg, errors, name, key):
    table = cfg[name]
    if not table:
        errors.append(f"[{name}] needs at least one class")
        return
    for cls, spec in table.items():
        if not _NAME.match(cls):
            errors.append(f"[{name}] class name {cls!r} is not usable as a folder name")
        if key not in spec:
            errors.append(f"[{name}] {cls} needs {key}")
    if not any(spec.get(key, -1) == 0 for spec in table.values()):
        errors.append(
            f"[{name}] the lowest class must have {key} = 0 so every file matches a class"
        )


def validate(cfg, online=True, tools=True, plex=None, radarr=None):
    """Returns (errors, warnings). plex/radarr can be injected for tests."""
    errors, warnings = [], []
    if cfg["mode"] not in config.MODES:
        errors.append(f"mode must be one of {', '.join(config.MODES)}")
    if cfg["alert_unidentified"] not in ("warn", "fail"):
        errors.append("alert_unidentified must be 'warn' or 'fail'")
    if not 1 <= cfg["watched_pct"] <= 100:
        errors.append("watched_pct must be between 1 and 100")
    for sec, key in (
        ("plex", "url"),
        ("plex", "token"),
        ("radarr", "url"),
        ("radarr", "api_key"),
    ):
        if not str(cfg[sec].get(key, "")).strip() or cfg[sec][key] == "...":
            errors.append(f"[{sec}] {key} is required")
    _check_plex_libraries(cfg, errors)
    st = cfg["storage"]
    if not 0 < st["min_free_pct"] < st["reclaim_to_pct"] < 100:
        errors.append(
            "[storage] needs 0 < min_free_pct < reclaim_to_pct < 100 (defaults 35 / 40)"
        )
    bd = str(st["backup_dir"]).strip()
    if not bd or bd == "...":
        errors.append("[storage] backup_dir is required (a writable NAS path)")
    elif not _writable_dir(bd):
        errors.append(
            f"[storage] backup_dir {bd} is not writable (or its parent does not exist)"
        )

    managed = cfg["folders"]["managed"]
    if not managed:
        errors.append("[folders] managed is required")
    elif not _writable_dir(managed):
        errors.append(
            f"[folders] managed {managed} is not writable (or its parent does not exist)"
        )
    paths = [u["path"] for u in cfg["folders"]["unmanaged"]]
    if not paths:
        warnings.append(
            "no [[folders.unmanaged]] configured: nothing to curate or reclaim yet"
        )
    for p in paths:
        if not os.path.isdir(p):
            errors.append(f"unmanaged folder {p} does not exist (NAS not mounted?)")
        if managed and _nested(p, managed):
            errors.append(f"unmanaged folder {p} overlaps the managed folder {managed}")
    for i, a in enumerate(paths):
        for b in paths[i + 1 :]:
            if _nested(a, b):
                errors.append(f"unmanaged folders {a} and {b} overlap")
    if st["measure_path"] and not os.path.exists(st["measure_path"]):
        errors.append(f"[storage] measure_path {st['measure_path']} does not exist")

    _check_table(cfg, errors, "video", "min_width")
    _check_table(cfg, errors, "audio", "min_channels")
    _check_hdr(cfg, errors)
    lc = cfg["lifecycle"]
    has_days, has_months = "stale_days" in lc, "stale_months" in lc
    if has_days and has_months:
        errors.append("[lifecycle] stale_days and stale_months cannot both be set")
    if has_days:
        _check_days(lc["stale_days"], "[lifecycle] stale_days", errors)
    elif has_months:
        months = lc["stale_months"]
        if type(months) not in (int, float) or not math.isfinite(months) or months < 1:
            errors.append("[lifecycle] stale_months must be a positive number")
        if not has_days:
            warnings.append(
                "[lifecycle] stale_months is deprecated; use stale_days "
                "(30.44 days per month)"
            )
    else:
        errors.append("[lifecycle] stale_days is required")
    if "watchlist_stale_days" in lc:
        _check_days(
            lc["watchlist_stale_days"],
            "[lifecycle] watchlist_stale_days",
            errors,
        )
    age_only_rules = lc.get("age_only", [])
    if not isinstance(age_only_rules, list):
        errors.append("[lifecycle] age_only must be a list of stale rules")
    else:
        for rule in age_only_rules:
            if rule not in ("stale_watchlist", "stale_unmanaged"):
                errors.append(
                    f"[lifecycle] age_only rule {rule!r} is not age-based; valid: "
                    "stale_watchlist, stale_unmanaged"
                )
    for folder in cfg["folders"]["unmanaged"]:
        if "stale_days" in folder:
            _check_days(
                folder["stale_days"],
                f"unmanaged folder {folder['path']} stale_days",
                errors,
            )
            if not folder["lifecycle"]:
                errors.append(
                    f"unmanaged folder {folder['path']} stale_days requires lifecycle = true"
                )
        if "age_only" in folder:
            if type(folder["age_only"]) is not bool:
                errors.append(
                    f"unmanaged folder {folder['path']} age_only must be true or false"
                )
            elif folder["age_only"] and not folder["lifecycle"]:
                errors.append(
                    f"unmanaged folder {folder['path']} age_only requires lifecycle = true"
                )
    for r in lc["rules"]:
        if r not in config.RULES:
            errors.append(
                f"[lifecycle] unknown rule {r!r}; valid: {', '.join(config.RULES)}"
            )
    if not os.path.isdir(
        os.path.dirname(cfg["advanced"]["db_path"])
    ) and not _writable_dir(os.path.dirname(cfg["advanced"]["db_path"])):
        warnings.append(
            "database directory is not writable yet (the build script creates it)"
        )
    if tools:
        for name in (cfg["advanced"]["ffprobe"], cfg["advanced"]["mediainfo"]):
            if not shutil.which(name):
                errors.append(f"{name} not found on PATH")
    if sys.version_info < (3, 11):
        errors.append("Python 3.11+ required")

    if online and not errors:
        plex = plex or clients.Plex(cfg["plex"]["url"], cfg["plex"]["token"])
        try:
            secs = [s for s in plex.sections() if s["type"] == "movie"]
            if not secs:
                errors.append("Plex has no movie library")
            for want in [managed, *paths]:
                if secs and not any(
                    libraries.section_overlaps_folder(cfg, section, want)
                    for section in secs
                ):
                    warnings.append(
                        f"{want} is not a folder of any Plex movie library; add it in Plex "
                        "(Edit library > Add folders)"
                    )
        except Exception as e:
            errors.append(f"Plex unreachable or token rejected: {e}")
        radarr = radarr or clients.Radarr(
            cfg["radarr"]["url"], cfg["radarr"]["api_key"]
        )
        try:
            radarr.status()
        except Exception as e:
            errors.append(f"Radarr unreachable or API key rejected: {e}")
    return errors, warnings


def report(cfg, **kw):
    errors, warnings = validate(cfg, **kw)
    for w in warnings:
        print("WARN ", w)
    for e in errors:
        print("ERROR", e)
    print("config OK" if not errors else f"config INVALID ({len(errors)} error(s))")
    return 1 if errors else 0
