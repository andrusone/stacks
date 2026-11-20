"""Config: a handful of owner decisions in TOML; everything else defaults here (see [advanced] for overrides)."""

import copy
import os
import tomllib

MODES = ("observe", "organize", "reclaim")
RULES = ("one_star", "two_star", "stale_watchlist", "stale_unmanaged")

DEFAULTS = {
    "mode": "observe",
    "watched_pct": 50,
    "alert_unidentified": "warn",
    "plex": {
        "url": "http://127.0.0.1:32400",
        "token": "",
        "path_map": {},
        "libraries": "configured",
    },
    "radarr": {"url": "", "api_key": "", "path_map": {}},
    "storage": {
        "min_free_pct": 35,
        "reclaim_to_pct": 40,
        "backup_dir": "",
        "measure_path": "",
    },
    "folders": {"managed": "", "unmanaged": []},
    "video": {
        "4khd": {"min_width": 3000},
        "1080hd": {"min_width": 1700},
        "720hd": {"min_width": 1200},
        "sd": {"min_width": 0},
    },
    "audio": {
        "7ch": {"min_channels": 7},
        "5ch": {"min_channels": 5},
        "2ch": {"min_channels": 0},
    },
    # HDR type -> display label and the tag shown in curated file names ("" = no tag). Priority is fixed in hdr.py
    # (Dolby Vision > HDR10+ > HDR10 > HLG > SDR); a [hdr.<type>] table in the config overrides single values.
    "hdr": {
        "dv": {"label": "Dolby Vision", "tag": "DV"},
        "hdr10plus": {"label": "HDR10+", "tag": "HDR10+"},
        "hdr10": {"label": "HDR10", "tag": "HDR10"},
        "hlg": {"label": "HLG", "tag": "HLG"},
        "sdr": {"label": "SDR", "tag": ""},
    },
    "lifecycle": {"stale_days": 365, "rules": list(RULES), "age_only": []},
    # Not in config.example.toml on purpose; override only on odd hosts.
    "advanced": {
        "db_path": "/var/lib/plexcurator/plexcurator.db",
        "alert_file": "/var/lib/plexcurator/ALERT",
        "plex_log_dir": "/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Logs",
        "backup_keep": 14,
        "ffprobe": "ffprobe",
        "mediainfo": "mediainfo",
        "max_deletions_per_run": 10,
        "max_sync_age_hours": 26,
        "video_exts": [
            ".mkv",
            ".mp4",
            ".m4v",
            ".avi",
            ".mov",
            ".wmv",
            ".ts",
            ".m2ts",
            ".mpg",
            ".mpeg",
        ],
    },
}


def _merge(base, over):
    out = copy.deepcopy(base)
    for k, v in over.items():
        if k in ("video", "audio"):  # class tables replace the defaults wholesale
            out[k] = v
        elif isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = _merge(out[k], v)
        else:
            out[k] = v
    return out


def normalize(cfg):
    unmanaged = []
    for folder in cfg["folders"]["unmanaged"]:
        entry = {
            "path": os.path.normpath(folder["path"]),
            "lifecycle": bool(folder.get("lifecycle", False)),
        }
        if "stale_days" in folder:
            entry["stale_days"] = folder["stale_days"]
        if "age_only" in folder:
            entry["age_only"] = folder["age_only"]
        unmanaged.append(entry)
    cfg["folders"]["unmanaged"] = unmanaged
    if cfg["folders"]["managed"]:
        cfg["folders"]["managed"] = os.path.normpath(cfg["folders"]["managed"])
    return cfg


def load(path=None, overrides=None):
    cfg = copy.deepcopy(DEFAULTS)
    supplied_lifecycle = {}
    if path:
        with open(path, "rb") as fh:
            loaded = tomllib.load(fh)
        supplied_lifecycle.update(loaded.get("lifecycle", {}))
        cfg = _merge(cfg, loaded)
    if overrides:
        supplied_lifecycle.update(overrides.get("lifecycle", {}))
        cfg = _merge(cfg, overrides)
    if "stale_months" in supplied_lifecycle and "stale_days" not in supplied_lifecycle:
        cfg["lifecycle"].pop("stale_days", None)
    return normalize(cfg)


def managed_dirs(cfg):
    """(Watchlist dir, Watched dir) under the managed root."""
    m = cfg["folders"]["managed"]
    return os.path.join(m, "Watchlist"), os.path.join(m, "Watched")


def measure_path(cfg):
    return cfg["storage"]["measure_path"] or cfg["folders"]["managed"]
