"""File fingerprint, ffprobe/mediainfo capture, and normalisation of ffprobe JSON into rows."""

import hashlib
import json
import os
import shutil
import subprocess

from . import hdr as H

CHUNK = 1 << 20


def fingerprint(path, size=None):
    """sha256 of size + head/middle/tail 1 MiB: survives rename/move, cheap over SMB."""
    size = os.path.getsize(path) if size is None else size
    h = hashlib.sha256(str(size).encode())
    with open(path, "rb") as fh:
        for off in sorted({0, max(0, size // 2 - CHUNK // 2), max(0, size - CHUNK)}):
            fh.seek(off)
            h.update(fh.read(CHUNK))
    return h.hexdigest()


def run_ffprobe(path, exe="ffprobe"):
    out = subprocess.run(
        [
            exe,
            "-v",
            "quiet",
            "-print_format",
            "json",
            "-show_format",
            "-show_streams",
            path,
        ],
        capture_output=True,
        text=True,
        check=True,
        timeout=300,
    ).stdout
    return json.loads(out)


def run_mediainfo(path, exe="mediainfo"):
    if not shutil.which(exe):
        return None
    out = subprocess.run(
        [exe, "--Output=JSON", path], capture_output=True, text=True, timeout=300
    ).stdout
    return json.loads(out) if out.strip() else None


def _int(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def _float(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


HDR_FIELDS = (
    "hdr",
    "dolby_vision",
    "hdr10plus",
    "hdr10",
    "hlg",
    "dv_profile",
    "dv_fallback",
)


def hdr_fields(stream, mediainfo=None):
    """Row fields for one video stream: canonical label key plus the separate format flags."""
    f = H.detect(stream, mediainfo)
    return dict(
        hdr=H.canonical(f),
        dolby_vision=f["dv"],
        hdr10plus=f["hdr10plus"],
        hdr10=f["hdr10"],
        hlg=f["hlg"],
        dv_profile=f["dv_profile"],
        dv_fallback=f["dv_fallback"],
    )


def _fps(s):
    try:
        n, d = s.get("avg_frame_rate", "0/1").split("/")
        return round(int(n) / int(d), 3) if int(d) else None
    except ValueError:
        return None


def normalize(pj, mediainfo=None):
    """ffprobe JSON (+ mediainfo JSON, optional) -> {'format', 'video', 'audio', 'subs', 'summary'} rows for the normalized tables."""
    streams, fmt = pj.get("streams", []), pj.get("format", {})
    video, audio, subs = [], [], []
    for s in streams:
        lang = s.get("tags", {}).get("language")
        disp = s.get("disposition", {})
        t = s.get("codec_type")
        if t == "video" and not disp.get("attached_pic"):
            video.append(
                dict(
                    idx=s["index"],
                    codec_name=s.get("codec_name"),
                    profile=s.get("profile"),
                    width=s.get("width"),
                    height=s.get("height"),
                    fps=_fps(s),
                    pix_fmt=s.get("pix_fmt"),
                    bit_depth=_int(s.get("bits_per_raw_sample")),
                    color_space=s.get("color_space"),
                    color_transfer=s.get("color_transfer"),
                    color_primaries=s.get("color_primaries"),
                    bit_rate=_int(s.get("bit_rate")),
                    display_aspect_ratio=s.get("display_aspect_ratio"),
                    language=lang,
                    **hdr_fields(s, mediainfo),
                )
            )
        elif t == "audio":
            audio.append(
                dict(
                    idx=s["index"],
                    codec_name=s.get("codec_name"),
                    profile=s.get("profile"),
                    channels=s.get("channels"),
                    channel_layout=s.get("channel_layout"),
                    sample_rate=_int(s.get("sample_rate")),
                    bit_rate=_int(s.get("bit_rate")),
                    language=lang,
                    title=s.get("tags", {}).get("title"),
                    is_default=disp.get("default", 0),
                )
            )
        elif t == "subtitle":
            subs.append(
                dict(
                    idx=s["index"],
                    codec_name=s.get("codec_name"),
                    language=lang,
                    title=s.get("tags", {}).get("title"),
                    is_default=disp.get("default", 0),
                    is_forced=disp.get("forced", 0),
                )
            )
    f = dict(
        format_name=fmt.get("format_name"),
        format_long_name=fmt.get("format_long_name"),
        duration_s=_float(fmt.get("duration")),
        size=_int(fmt.get("size")),
        bit_rate=_int(fmt.get("bit_rate")),
        nb_streams=_int(fmt.get("nb_streams")),
        probe_score=_int(fmt.get("probe_score")),
        tags_json=json.dumps(fmt.get("tags")) if fmt.get("tags") else None,
    )
    best_v = max(video, key=lambda v: v["width"] or 0, default={})
    best_a = max(audio, key=lambda a: a["channels"] or 0, default={})
    summary = dict(
        width=best_v.get("width"),
        height=best_v.get("height"),
        channels=best_a.get("channels"),
        duration_s=f["duration_s"],
        bitrate=f["bit_rate"],
        **{k: best_v.get(k) for k in HDR_FIELDS},
    )
    return {
        "format": f,
        "video": video,
        "audio": audio,
        "subs": subs,
        "summary": summary,
    }
