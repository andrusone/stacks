"""Shared fixtures: a temp NAS tree, fake Plex/Radarr clients, fake probe output."""

import os
import sqlite3
import tempfile
import unittest

from plexcurator import config, db

NOW = 1_800_000_000
DAY = 86400
GB = 10**9


def add_missing_plex_fts_tokenizer(database_path):
    connection = sqlite3.connect(database_path)
    try:
        connection.execute("CREATE TABLE IF NOT EXISTS library_fixture (id INTEGER)")
        connection.execute(
            "CREATE VIRTUAL TABLE search_fixture USING fts5(title, tokenize='unicode61')"
        )
        connection.execute("INSERT INTO search_fixture(title) VALUES ('fixture row')")
        sql = connection.execute(
            "SELECT sql FROM sqlite_master WHERE name='search_fixture'"
        ).fetchone()[0]
        connection.execute("PRAGMA writable_schema=ON")
        connection.execute(
            "UPDATE sqlite_master SET sql=? WHERE name='search_fixture'",
            (sql.replace("unicode61", "collating"),),
        )
        connection.execute("PRAGMA writable_schema=OFF")
        connection.commit()
    finally:
        connection.close()


def fake_probe(
    width=1920, height=1080, channels=6, transfer=None, side_data=None, mediainfo=None
):
    def probe(path):
        v = {
            "index": 0,
            "codec_type": "video",
            "codec_name": "h264",
            "width": width,
            "height": height,
            "avg_frame_rate": "24000/1001",
            "pix_fmt": "yuv420p",
        }
        if transfer:
            v["color_transfer"] = transfer
        if side_data:
            v["side_data_list"] = side_data
        return (
            {
                "streams": [
                    v,
                    {
                        "index": 1,
                        "codec_type": "audio",
                        "codec_name": "ac3",
                        "channels": channels,
                        "tags": {"language": "eng"},
                        "disposition": {"default": 1},
                    },
                    {
                        "index": 2,
                        "codec_type": "subtitle",
                        "codec_name": "subrip",
                        "tags": {"language": "eng"},
                    },
                ],
                "format": {
                    "format_name": "matroska,webm",
                    "duration": "7000.5",
                    "bit_rate": "8000000",
                    "size": "123",
                    "nb_streams": 3,
                },
            },
            mediainfo,
        )

    return probe


class FakePlex:
    def __init__(self, items=None, live=None, watchlist=None):
        self.items, self.live, self.wl, self.calls = (
            items or [],
            live or {},
            watchlist or [],
            [],
        )

    def sections(self):
        return [{"key": "1", "title": "Movies", "type": "movie", "Location": []}]

    def movie_sections(self, only=()):
        return self.sections()

    def movies(self, key):
        return self.items

    def watchlist(self):
        return self.wl

    def item(self, rk):
        return self.live.get(str(rk), {"ratingKey": rk})

    def set_rating(self, rk, r):
        self.calls.append(("rate", str(rk), r))

    def scrobble(self, rk):
        self.calls.append(("scrobble", str(rk)))

    def scan(self, k):
        self.calls.append(("scan", k))

    def empty_trash(self, k):
        self.calls.append(("trash", k))


class FakeRadarr:
    def __init__(self, movies=None, fail=False, track_error=None):
        self.movie_list, self.calls, self.fail = movies or [], [], fail
        self.track_error = track_error

    def status(self):
        if self.fail:
            raise OSError("radarr down")
        return {}

    def movies(self):
        if self.fail:
            raise OSError("radarr down")
        return self.movie_list

    def track_at(self, rid, path):
        self.calls.append(("track_at", rid, path))
        if self.track_error:
            raise self.track_error
        for movie in self.movie_list:
            if movie.get("id") == rid:
                movie["path"] = path
                movie["monitored"] = False
                movie["hasFile"] = True

    def delete_with_exclusion(self, rid):
        if self.fail:
            raise OSError("radarr down")
        self.calls.append(("delete_excl", rid))

    def add_exclusion(self, tmdb, title, year):
        self.calls.append(("add_excl", tmdb))


def plex_item(
    rk,
    title,
    path,
    tmdb=None,
    imdb=None,
    year=2000,
    added=NOW - 100 * DAY,
    rating=None,
    views=0,
    offset=None,
    duration=7_000_000,
    last_viewed=None,
    last_rated=None,
):
    it = {
        "ratingKey": str(rk),
        "title": title,
        "year": year,
        "addedAt": added,
        "viewCount": views,
        "duration": duration,
        "Guid": [],
        "Media": [{"Part": [{"file": path}]}],
    }
    if tmdb:
        it["Guid"].append({"id": f"tmdb://{tmdb}"})
    if imdb:
        it["Guid"].append({"id": f"imdb://{imdb}"})
    for k, v in (
        ("userRating", rating),
        ("viewOffset", offset),
        ("lastViewedAt", last_viewed),
        ("lastRatedAt", last_rated),
    ):
        if v is not None:
            it[k] = v
    return it


class Base(unittest.TestCase):
    """Temp NAS: <root>/Movies (unmanaged, lifecycle), <root>/Other (unmanaged, no lifecycle), <root>/Curated."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        for d in ("Movies", "Other", "Curated"):
            os.makedirs(os.path.join(self.root, d))
        self.cfg = config.load(
            overrides={
                # Generic Plex fixtures omit Location; scope tests supply it explicitly.
                "plex": {"libraries": "all"},
                "folders": {
                    "managed": os.path.join(self.root, "Curated"),
                    "unmanaged": [
                        {"path": os.path.join(self.root, "Movies"), "lifecycle": True},
                        {"path": os.path.join(self.root, "Other"), "lifecycle": False},
                    ],
                },
                "storage": {"backup_dir": os.path.join(self.root, "bk")},
                "advanced": {
                    "db_path": os.path.join(self.root, "t.db"),
                    "alert_file": os.path.join(self.root, "ALERT"),
                },
            }
        )
        self.conn = db.connect(self.cfg["advanced"]["db_path"])

    def tearDown(self):
        self.conn.close()
        self.tmp.cleanup()

    def mkfile(self, rel, data=b"x"):
        p = os.path.join(self.root, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as fh:
            fh.write(data)
        return p
