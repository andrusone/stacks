"""HDR detection from ffprobe stream JSON and (optionally) mediainfo's Video track.

A file can carry several formats at once (Dolby Vision with an HDR10 base layer, HDR10+ is HDR10 plus dynamic metadata),
so detection yields separate flags; `canonical()` picks the single label by the fixed priority below.
Label text and filename tags are data: config [hdr] (defaults in config.DEFAULTS), keyed by these names.
"""

import re

PRIORITY = (
    "dv",
    "hdr10plus",
    "hdr10",
    "hlg",
)  # Dolby Vision > HDR10+ > HDR10 > HLG; anything else is "sdr"
SDR = "sdr"

# dv_bl_signal_compatibility_id -> what the base layer plays as without a Dolby Vision decoder
_DV_FALLBACK = {
    1: "hdr10",
    6: "hdr10",
    2: "sdr",
    4: "hlg",
}  # 0 (profile 5) has no usable fallback

_DV_PROFILE = re.compile(r"dv[a-z0-9]{2}\.(\d+)", re.I)


def _int(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def _from_ffprobe(s):
    f = dict(dv=0, hdr10plus=0, hdr10=0, hlg=0, dv_profile=None, dv_fallback=None)
    transfer = s.get("color_transfer")
    compat = None
    for sd in s.get("side_data_list") or []:
        kind = str(sd.get("side_data_type", ""))
        if kind.startswith("DOVI") or "Dolby Vision" in kind:
            f["dv"] = 1
            f["dv_profile"] = _int(sd.get("dv_profile"))
            compat = _int(sd.get("dv_bl_signal_compatibility_id"))
            f["dv_fallback"] = _DV_FALLBACK.get(compat)
        elif "2094-40" in kind or "HDR10+" in kind:
            f["hdr10plus"] = 1
    if f["dv"]:
        # profile 5 (compat 0) is not HDR10-compatible even if a tool reports PQ; trust the record when it exists
        f["hdr10"] = int(
            compat is None and transfer == "smpte2084" or f["dv_fallback"] == "hdr10"
        )
        f["hlg"] = int(transfer == "arib-std-b67" or f["dv_fallback"] == "hlg")
    else:
        f["hdr10"] = int(transfer == "smpte2084")
        f["hlg"] = int(transfer == "arib-std-b67")
    if f["hdr10plus"]:
        f["hdr10"] = 1  # HDR10+ is HDR10 plus dynamic metadata
    return f


def _video_track(mediainfo):
    for t in ((mediainfo or {}).get("media") or {}).get("track") or []:
        if t.get("@type") == "Video":
            return t
    return None


def _from_mediainfo(mediainfo):
    t = _video_track(mediainfo)
    f = dict(dv=0, hdr10plus=0, hdr10=0, hlg=0, dv_profile=None, dv_fallback=None)
    if not t:
        return f
    fmt = str(t.get("HDR_Format", "")).lower()
    compat = str(t.get("HDR_Format_Compatibility", "")).lower()
    text = fmt + " / " + compat
    f["dv"] = int("dolby vision" in text)
    f["hdr10plus"] = int("2094-40" in text or "2094 app 4" in text or "hdr10+" in text)
    f["hdr10"] = int(
        "hdr10" in text.replace("hdr10+", "")
        or f["hdr10plus"]
        or ("2086" in text and not f["dv"])
    )
    f["hlg"] = int("hlg" in text)
    if f["dv"]:
        m = _DV_PROFILE.search(str(t.get("HDR_Format_Profile", "")))
        f["dv_profile"] = int(m.group(1)) if m else None
        if f["hdr10"]:
            f["dv_fallback"] = "hdr10"
        elif f["hlg"]:
            f["dv_fallback"] = "hlg"
        elif "sdr" in compat:
            f["dv_fallback"] = "sdr"
        else:
            f["dv_fallback"] = None
        if f["dv_fallback"] != "hdr10":
            f["hdr10"] = 0
        if f["dv_fallback"] != "hlg":
            f["hlg"] = 0
    return f


def detect(stream, mediainfo=None):
    """Flags for one video stream (ffprobe JSON) merged with mediainfo's view of the file's video track.

    Either source can add a format; ffprobe's Dolby Vision profile/fallback wins when both know them.
    mediainfo matters mostly for HDR10+, whose per-frame metadata ffprobe does not list at stream level.
    """
    a, b = _from_ffprobe(stream), _from_mediainfo(mediainfo)
    out = {k: int(bool(a[k] or b[k])) for k in ("dv", "hdr10plus", "hdr10", "hlg")}
    if out["dv"]:
        src = a if a["dv"] else b
        out["dv_profile"], out["dv_fallback"] = src["dv_profile"], src["dv_fallback"]
        if a["dv"] and b["dv"]:
            out["dv_profile"] = (
                a["dv_profile"] if a["dv_profile"] is not None else b["dv_profile"]
            )
            out["dv_fallback"] = a["dv_fallback"] or b["dv_fallback"]
        # the base layer decides HDR10/HLG compatibility, whichever source said so
        out["hdr10"] = int(out["dv_fallback"] == "hdr10" or out["hdr10plus"])
        out["hlg"] = int(out["dv_fallback"] == "hlg")
    else:
        out["dv_profile"] = out["dv_fallback"] = None
    return out


def canonical(flags):
    """The single label key for a flag set: dv, hdr10plus, hdr10, hlg, else sdr."""
    for k in PRIORITY:
        if flags.get(k):
            return k
    return SDR


def tag(key, cfg):
    """Filename tag for a label key; '' (no tag) for SDR or anything unknown/NULL."""
    return str((cfg["hdr"].get(key) or {}).get("tag", "")) if key else ""


def label(key, cfg):
    return str((cfg["hdr"].get(key) or {}).get("label", key or ""))
