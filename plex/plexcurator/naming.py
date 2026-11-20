"""Curated names carry their tags outside the folder: Title (Year) {tmdb-123} [1080hd 5ch HDR10]."""

import os
import re

from . import hdr

_BAD = re.compile(r'[<>:"/\\|?*\x00-\x1f]')
_SPACE = re.compile(r"\s+")


def clean(s):
    return _SPACE.sub(" ", _BAD.sub("", s or "")).strip(" .")


def id_tag(m):
    if m["tmdb"]:
        return f"{{tmdb-{m['tmdb']}}}"
    if m["imdb"]:
        return f"{{imdb-{m['imdb']}}}"
    return None


def curated_stem(m, cfg):
    """None when the movie lacks an id or classes (then it is not renamed). SDR/unknown HDR has no tag."""
    tag = id_tag(m)
    if not tag or not m["video_class"] or not m["audio_class"]:
        return None
    title = clean(m["title"])[:120] or "Untitled"
    year = f" ({m['year']})" if m["year"] else ""
    extra = hdr.tag(m["hdr"], cfg)
    return f"{title}{year} {tag} [{m['video_class']} {m['audio_class']}{' ' + extra if extra else ''}]"


_TECH = re.compile(r"\[(?P<video>\S+) (?P<audio>\S+)(?: (?P<tag>\S+))?\]$")


def parse_tech(stem, cfg):
    """Inverse of the bracket in curated_stem: (video_class, audio_class, hdr key) or None. A missing tag means sdr;
    a tag that no configured type uses gives hdr None (so the caller can tell it from SDR).
    """
    m = _TECH.search(stem)
    if not m:
        return None
    key = next(
        (k for k, v in cfg["hdr"].items() if v.get("tag") and v["tag"] == m["tag"]),
        None,
    )
    return m["video"], m["audio"], hdr.SDR if m["tag"] is None else key


def curated_file(m, cfg):
    stem = curated_stem(m, cfg)
    return None if stem is None else stem + os.path.splitext(m["path"])[1]
