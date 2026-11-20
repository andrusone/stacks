"""Where a path sits: an unmanaged folder, the managed Watchlist/Watched trees, or elsewhere."""

import os

from . import config


def _under(path, folder):
    p, f = os.path.normpath(path), os.path.normpath(folder)
    return p == f or p.startswith(f + os.sep)


def unmanaged_entry(cfg, path):
    for u in cfg["folders"]["unmanaged"]:
        if _under(path, u["path"]):
            return u
    return None


def zone_of(cfg, path):
    """'unmanaged' | 'watchlist' | 'watched' | 'other'."""
    if not path:
        return "other"
    wl, wd = config.managed_dirs(cfg)
    if cfg["folders"]["managed"]:
        if _under(path, wl):
            return "watchlist"
        if _under(path, wd):
            return "watched"
    if unmanaged_entry(cfg, path):
        return "unmanaged"
    return "other"


def map_path(mapping, path):
    """Translate a path as another service sees it into this host's path (prefix map)."""
    for src, dst in mapping.items():
        if path == src or path.startswith(src.rstrip("/") + "/"):
            return dst.rstrip("/") + path[len(src.rstrip("/")) :]
    return path


def unmap_path(mapping, path):
    """Inverse of map_path: this host's path -> the other service's view."""
    return map_path({dst: src for src, dst in mapping.items()}, path)
