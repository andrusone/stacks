"""Video/audio classes are data (config tables). Widest/most-channels first; first match wins."""


def video_table(cfg):
    rows = [
        (n, int(v.get("min_width", 0)), int(v.get("min_height", 0)))
        for n, v in cfg["video"].items()
    ]
    return sorted(rows, key=lambda r: (-r[1], -r[2], r[0]))


def audio_table(cfg):
    rows = [(n, int(v.get("min_channels", 0))) for n, v in cfg["audio"].items()]
    return sorted(rows, key=lambda r: (-r[1], r[0]))


def classify_video(width, height, cfg):
    if not width:
        return None
    for name, mw, mh in video_table(cfg):
        if width >= mw and (height or 0) >= mh:
            return name
    return video_table(cfg)[-1][0]


def classify_audio(channels, cfg):
    if channels is None:
        return None
    for name, mc in audio_table(cfg):
        if channels >= mc:
            return name
    return audio_table(cfg)[-1][0]
