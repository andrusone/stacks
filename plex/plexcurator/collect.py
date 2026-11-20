"""Store raw probe output (one record per source) and the normalized tables derived from it."""

import json

from . import classes
from . import probe as P

_TABLES = (
    ("video_stream", "video"),
    ("audio_stream", "audio"),
    ("subtitle_stream", "subs"),
)


def _insert(conn, table, file_id, row):
    cols = ["file_id", *row]
    conn.execute(
        f"INSERT INTO {table}({','.join(cols)}) VALUES ({','.join('?' * len(cols))})",
        [file_id, *row.values()],
    )


def put_source(conn, movie_id, source, raw, now):
    conn.execute(
        "INSERT OR REPLACE INTO source_record(movie_id, source, fetched_at, raw_json) VALUES (?,?,?,?)",
        (movie_id, source, now, json.dumps(raw)),
    )


def store_probe(conn, cfg, movie_id, file_id, ffprobe_json, mediainfo_json, now):
    """Replace the movie's ffprobe/mediainfo records and rebuild the file's normalized rows."""
    put_source(conn, movie_id, "ffprobe", ffprobe_json, now)
    if mediainfo_json:
        put_source(conn, movie_id, "mediainfo", mediainfo_json, now)
    n = P.normalize(ffprobe_json, mediainfo_json)
    conn.execute("DELETE FROM format WHERE file_id=?", (file_id,))
    for t, _ in _TABLES:
        conn.execute(f"DELETE FROM {t} WHERE file_id=?", (file_id,))
    _insert(conn, "format", file_id, n["format"])
    for t, key in _TABLES:
        for row in n[key]:
            _insert(conn, t, file_id, row)
    s = n["summary"]
    conn.execute(
        f"""UPDATE file SET duration_s=?, bitrate=?, width=?, height=?, channels=?,
                     video_class=?, audio_class=?, probed_at=?, {', '.join(f + '=?' for f in P.HDR_FIELDS)} WHERE id=?""",
        (
            s["duration_s"],
            s["bitrate"],
            s["width"],
            s["height"],
            s["channels"],
            classes.classify_video(s["width"], s["height"], cfg),
            classes.classify_audio(s["channels"], cfg),
            now,
            *(s[f] for f in P.HDR_FIELDS),
            file_id,
        ),
    )


def reclassify(conn, cfg):
    """Re-derive classes from stored width/height/channels (no re-probe). Returns number of files changed."""
    changed = 0
    for f in conn.execute(
        "SELECT id, width, height, channels, video_class, audio_class FROM file"
    ).fetchall():
        v, a = (
            classes.classify_video(f["width"], f["height"], cfg),
            classes.classify_audio(f["channels"], cfg),
        )
        if (v, a) != (f["video_class"], f["audio_class"]):
            conn.execute(
                "UPDATE file SET video_class=?, audio_class=? WHERE id=?",
                (v, a, f["id"]),
            )
            changed += 1
    conn.commit()
    return changed
