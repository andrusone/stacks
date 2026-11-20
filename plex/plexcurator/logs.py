"""Plex log scraper: WARN/ERROR lines attributed to a movie by file name or /library/metadata/<key>."""

import glob
import hashlib
import os
import re
import time
from datetime import datetime

LINE = re.compile(
    r"^(\w{3} \d{2}, \d{4} \d{2}:\d{2}:\d{2}\.\d{3}) \[[^\]]*\] (WARN|ERROR|CRITICAL) - (.*)$"
)
KEY = re.compile(r"/library/metadata/(\d+)")


def _ts(s):
    try:
        return int(datetime.strptime(s, "%b %d, %Y %H:%M:%S.%f").timestamp())
    except ValueError:
        return None


def scan(conn, log_dir, now=None):
    now = int(now or time.time())
    by_name = {}
    for r in conn.execute("SELECT movie_id, path FROM file"):
        base = os.path.basename(r["path"])
        if len(base) >= 8:
            by_name[base] = r["movie_id"]
    by_key = {
        r["plex_rating_key"]: r["id"]
        for r in conn.execute(
            "SELECT id, plex_rating_key FROM movie WHERE plex_rating_key IS NOT NULL"
        )
    }
    added = matched = 0
    for path in sorted(
        glob.glob(os.path.join(log_dir, "Plex*Server*.log*"))
        + glob.glob(os.path.join(log_dir, "Plex Transcoder*.log*"))
    ):
        with open(path, errors="replace") as fh:
            for raw in fh:
                m = LINE.match(raw.rstrip("\n"))
                if not m:
                    continue
                stamp, level, msg = m.groups()
                mid = next((i for n, i in by_name.items() if n in msg), None)
                if mid is None:
                    k = KEY.search(msg)
                    mid = by_key.get(k.group(1)) if k else None
                h = hashlib.sha1(f"{stamp}|{level}|{msg}".encode()).hexdigest()
                cur = conn.execute(
                    "INSERT OR IGNORE INTO issue(movie_id,ts,level,source,message,line_hash) "
                    "VALUES (?,?,?,?,?,?)",
                    (mid, _ts(stamp), level, os.path.basename(path), msg, h),
                )
                added += cur.rowcount
                matched += cur.rowcount and mid is not None
    conn.commit()
    return {"issues_added": added, "matched_to_movie": matched}
