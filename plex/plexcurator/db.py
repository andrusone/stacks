"""SQLite schema (v2) and helpers. movie.id is the key; external ids, one raw record per metadata source,
normalized file/stream tables derived from that raw JSON, and an append-only event table.
"""

import json
import logging
import sqlite3
import time
from pathlib import Path

from . import backup, probe
from .version import APP_VERSION, SCHEMA_VERSION

log = logging.getLogger("plexcurator")

SCHEMA = """
CREATE TABLE IF NOT EXISTS movie (
  id               INTEGER PRIMARY KEY,
  title            TEXT,
  year             INTEGER,
  state            TEXT NOT NULL DEFAULT 'present' CHECK (state IN ('present','retired')),
  unidentified     INTEGER NOT NULL DEFAULT 0,   -- no trustworthy external id: never moved, renamed or deleted
  multi_version    INTEGER NOT NULL DEFAULT 0,   -- Plex holds several files for it: anomaly, never touched
  life             INTEGER NOT NULL DEFAULT 0,   -- 0 = first life; +1 per reborn
  plex_rating_key  TEXT,                         -- ephemeral, refreshed every sync
  radarr_id        INTEGER,                      -- ephemeral
  born_at          INTEGER,
  retired_at       INTEGER,
  watchlisted_at   INTEGER,                      -- first watchlist date
  rating           REAL,                         -- Plex 0-10 as last seen; NULL = none
  rated_at         INTEGER,
  peak_percent     REAL NOT NULL DEFAULT 0,      -- curator-owned watch percent
  watched          INTEGER NOT NULL DEFAULT 0,   -- peak_percent reached watched_pct once; never reverts
  first_watched_at INTEGER,
  play_count       INTEGER NOT NULL DEFAULT 0,   -- Plex viewCount as last seen (fallback / new-play detector)
  first_seen_at    INTEGER NOT NULL,
  updated_at       INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS external_id (
  movie_id INTEGER NOT NULL REFERENCES movie(id),
  provider TEXT NOT NULL,                        -- tmdb, imdb, ...
  value    TEXT NOT NULL,
  PRIMARY KEY (movie_id, provider),
  UNIQUE (provider, value)
);
CREATE TABLE IF NOT EXISTS source_record (       -- one current record per movie + source
  movie_id INTEGER NOT NULL REFERENCES movie(id),
  source   TEXT NOT NULL,                        -- plex, ffprobe, mediainfo, future ones
  fetched_at INTEGER NOT NULL,
  raw_json TEXT NOT NULL,
  PRIMARY KEY (movie_id, source)
);
CREATE TABLE IF NOT EXISTS file (                -- the movie's current file (one per movie)
  id INTEGER PRIMARY KEY,
  movie_id INTEGER NOT NULL UNIQUE REFERENCES movie(id),
  path TEXT NOT NULL, size INTEGER NOT NULL, mtime INTEGER NOT NULL,
  fingerprint TEXT NOT NULL,                     -- sha256(size + head/middle/tail 1MiB); same-file check, not identity
  present INTEGER NOT NULL DEFAULT 1,
  zone TEXT,                                     -- unmanaged | watchlist | watched | other
  first_seen_at INTEGER NOT NULL, last_seen_at INTEGER NOT NULL,
  duration_s REAL, bitrate INTEGER, hdr TEXT,
  width INTEGER, height INTEGER, channels INTEGER,   -- best video width/height, best audio channels
  video_class TEXT, audio_class TEXT,
  probed_at INTEGER
);
CREATE INDEX IF NOT EXISTS file_fp ON file(fingerprint);
CREATE TABLE IF NOT EXISTS format (
  file_id INTEGER PRIMARY KEY REFERENCES file(id) ON DELETE CASCADE,
  format_name TEXT, format_long_name TEXT, duration_s REAL, size INTEGER, bit_rate INTEGER,
  nb_streams INTEGER, probe_score INTEGER, tags_json TEXT
);
CREATE TABLE IF NOT EXISTS video_stream (
  file_id INTEGER NOT NULL REFERENCES file(id) ON DELETE CASCADE, idx INTEGER NOT NULL,
  codec_name TEXT, profile TEXT, width INTEGER, height INTEGER, fps REAL, pix_fmt TEXT, bit_depth INTEGER,
  color_space TEXT, color_transfer TEXT, color_primaries TEXT, hdr TEXT, bit_rate INTEGER,
  display_aspect_ratio TEXT, language TEXT,
  PRIMARY KEY (file_id, idx)
);
CREATE TABLE IF NOT EXISTS audio_stream (
  file_id INTEGER NOT NULL REFERENCES file(id) ON DELETE CASCADE, idx INTEGER NOT NULL,
  codec_name TEXT, profile TEXT, channels INTEGER, channel_layout TEXT, sample_rate INTEGER, bit_rate INTEGER,
  language TEXT, title TEXT, is_default INTEGER,
  PRIMARY KEY (file_id, idx)
);
CREATE TABLE IF NOT EXISTS subtitle_stream (
  file_id INTEGER NOT NULL REFERENCES file(id) ON DELETE CASCADE, idx INTEGER NOT NULL,
  codec_name TEXT, language TEXT, title TEXT, is_default INTEGER, is_forced INTEGER,
  PRIMARY KEY (file_id, idx)
);
CREATE TABLE IF NOT EXISTS event (
  id INTEGER PRIMARY KEY, movie_id INTEGER NOT NULL REFERENCES movie(id),
  ts INTEGER NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('born','watchlisted','watched','rated','moved','retired','reborn','selected')),
  life INTEGER NOT NULL DEFAULT 0,
  value TEXT,                                    -- watched: percent; rated: stars 0-5; moved: new path
  detail TEXT
);
CREATE INDEX IF NOT EXISTS event_movie ON event(movie_id, ts);
CREATE UNIQUE INDEX IF NOT EXISTS event_one_born ON event(movie_id) WHERE kind = 'born';
CREATE UNIQUE INDEX IF NOT EXISTS event_one_retired_per_life ON event(movie_id, life) WHERE kind = 'retired';
CREATE TABLE IF NOT EXISTS watchlist (           -- Plex watchlist membership by external id (movie may not be owned yet)
  provider TEXT NOT NULL, value TEXT NOT NULL,
  first_seen_at INTEGER NOT NULL, last_seen_at INTEGER NOT NULL, present INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY (provider, value)
);
CREATE TABLE IF NOT EXISTS issue (               -- WARN/ERROR lines from Plex logs
  id INTEGER PRIMARY KEY, movie_id INTEGER REFERENCES movie(id),
  ts INTEGER, level TEXT, source TEXT, message TEXT, line_hash TEXT NOT NULL UNIQUE
);
CREATE INDEX IF NOT EXISTS issue_movie ON issue(movie_id);
CREATE TABLE IF NOT EXISTS deletion (            -- reclaim audit: why selected, which steps finished
  id INTEGER PRIMARY KEY, movie_id INTEGER NOT NULL REFERENCES movie(id),
  selected_at INTEGER NOT NULL, rule TEXT NOT NULL, reason TEXT NOT NULL, size_bytes INTEGER,
  status TEXT NOT NULL DEFAULT 'planned' CHECK (status IN ('planned','done','failed','skipped')),
  executed_at INTEGER, radarr_done INTEGER DEFAULT 0, files_done INTEGER DEFAULT 0, error TEXT
);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);

CREATE VIEW IF NOT EXISTS v_movie AS
  SELECT m.*, CAST(COALESCE(m.rating, 0) / 2 AS INTEGER) AS stars,
         (SELECT value FROM external_id e WHERE e.movie_id = m.id AND e.provider = 'tmdb') AS tmdb,
         (SELECT value FROM external_id e WHERE e.movie_id = m.id AND e.provider = 'imdb') AS imdb,
         f.id AS file_id, f.path, f.size, f.zone, f.video_class, f.audio_class, f.hdr, f.width, f.height,
         f.channels, f.duration_s, f.bitrate, f.present AS file_present
  FROM movie m LEFT JOIN file f ON f.movie_id = m.id;
CREATE VIEW IF NOT EXISTS v_audio AS
  SELECT f.movie_id, a.* FROM audio_stream a JOIN file f ON f.id = a.file_id;
CREATE VIEW IF NOT EXISTS v_video AS
  SELECT f.movie_id, v.* FROM video_stream v JOIN file f ON f.id = v.file_id;
"""


_HDR_COLS = (
    "dolby_vision INTEGER",
    "hdr10plus INTEGER",
    "hdr10 INTEGER",
    "hlg INTEGER",
    "dv_profile INTEGER",
    "dv_fallback TEXT",
)  # NULL = not probed

_V_MOVIE = """CREATE VIEW v_movie AS
  SELECT m.*, CAST(COALESCE(m.rating, 0) / 2 AS INTEGER) AS stars,
         (SELECT value FROM external_id e WHERE e.movie_id = m.id AND e.provider = 'tmdb') AS tmdb,
         (SELECT value FROM external_id e WHERE e.movie_id = m.id AND e.provider = 'imdb') AS imdb,
         f.id AS file_id, f.path, f.size, f.zone, f.video_class, f.audio_class, f.width, f.height,
         f.hdr, f.dolby_vision, f.hdr10plus, f.hdr10, f.hlg, f.dv_profile, f.dv_fallback,
         f.channels, f.duration_s, f.bitrate, f.present AS file_present
  FROM movie m LEFT JOIN file f ON f.movie_id = m.id"""


def _v2_hdr_types(conn):
    """HDR type detection: separate format flags on file and video_stream, `hdr` becomes the canonical key
    (dv, hdr10plus, hdr10, hlg, sdr). Backfilled from the stored raw ffprobe/mediainfo JSON; nothing is re-probed.
    """
    for table in ("file", "video_stream"):
        for col in _HDR_COLS:
            conn.execute(f"ALTER TABLE {table} ADD COLUMN {col}")
        conn.execute(
            f"UPDATE {table} SET hdr = CASE hdr WHEN 'DV' THEN 'dv' WHEN 'HDR10' THEN 'hdr10' "
            "WHEN 'HLG' THEN 'hlg' ELSE hdr END"
        )  # rows with no stored JSON keep their old meaning
    conn.execute("DROP VIEW IF EXISTS v_movie")
    conn.execute("DROP VIEW IF EXISTS v_video")  # v.* was expanded when it was created
    conn.execute(_V_MOVIE)
    conn.execute(
        "CREATE VIEW v_video AS SELECT f.movie_id, v.* FROM video_stream v JOIN file f ON f.id = v.file_id"
    )
    cols = probe.HDR_FIELDS
    for f in conn.execute("SELECT f.id, f.movie_id FROM file f").fetchall():
        raw = {
            r[0]: r[1]
            for r in conn.execute(
                "SELECT source, raw_json FROM source_record WHERE movie_id=? "
                "AND source IN ('ffprobe','mediainfo')",
                (f["movie_id"],),
            )
        }
        try:
            n = probe.normalize(
                json.loads(raw["ffprobe"]),
                json.loads(raw["mediainfo"]) if "mediainfo" in raw else None,
            )
        except (KeyError, ValueError):
            log.warning(
                "schema 2: no usable stored ffprobe JSON for file %s; HDR left as it was",
                f["id"],
            )
            continue
        for v in n["video"]:
            conn.execute(
                f"UPDATE video_stream SET {', '.join(c + '=?' for c in cols)} WHERE file_id=? AND idx=?",
                (*(v[c] for c in cols), f["id"], v["idx"]),
            )
        conn.execute(
            f"UPDATE file SET {', '.join(c + '=?' for c in cols)} WHERE id=?",
            (*(n["summary"][c] for c in cols), f["id"]),
        )


# Numbered, ordered migration steps, all in one place: a SQL script or a function(conn). Step N takes a version N-1
# database to N. Step 1 is the whole v2-design schema. Never edit a released step: add step N+1 and bump
# version.SCHEMA_VERSION.
MIGRATIONS = {1: SCHEMA, 2: _v2_hdr_types}


class SchemaError(RuntimeError):
    pass


def _user_version(conn):
    return conn.execute("PRAGMA user_version").fetchone()[0]


def _has_tables(conn):
    return (
        conn.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' LIMIT 1"
        ).fetchone()
        is not None
    )


def migrate(conn, path, backup_dir=None, now=None, backup_keep=14):
    """Bring the database to SCHEMA_VERSION. Newer than the app knows: refuse. Older: back up first, then step."""
    have, want = _user_version(conn), SCHEMA_VERSION
    if sorted(MIGRATIONS) != list(range(1, want + 1)):
        raise SchemaError(
            f"migration steps {sorted(MIGRATIONS)} do not match SCHEMA_VERSION {want}"
        )
    if have > want:
        raise SchemaError(
            f"database schema is version {have} but this plexcurator (app {APP_VERSION}) only knows "
            f"version {want}; refusing to run. Install a newer plexcurator or restore a backup."
        )
    if have == want:
        return []
    if have == 0 and _has_tables(conn):
        raise SchemaError(
            "database has tables but no schema version; refusing to guess. Restore a backup or start a new database."
        )
    if have > 0:
        if not backup_dir:
            raise SchemaError(
                f"database is at schema {have}, app needs {want}: set storage.backup_dir so it can be backed up first"
            )
        conn.commit()
        dest = backup.backup(path, backup_dir, backup_keep, now)
        log.info("schema %s -> %s: backed up to %s first", have, want, dest)
    conn.execute(
        "CREATE TABLE IF NOT EXISTS schema_migration (version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL, "
        "app_version TEXT NOT NULL)"
    )
    applied = []
    for v in range(have + 1, want + 1):
        step = MIGRATIONS[v]
        if callable(step):  # one transaction: a failed step leaves version v-1 intact
            conn.execute("BEGIN")
            try:
                step(conn)
                conn.execute(
                    "INSERT INTO schema_migration(version, applied_at, app_version) VALUES (?,?,?)",
                    (v, int(now or time.time()), APP_VERSION),
                )
                conn.execute(f"PRAGMA user_version = {v}")
                conn.commit()
            except Exception:
                conn.rollback()
                raise
        else:
            conn.executescript(step)
            conn.execute(
                "INSERT INTO schema_migration(version, applied_at, app_version) VALUES (?,?,?)",
                (v, int(now or time.time()), APP_VERSION),
            )
            conn.execute(f"PRAGMA user_version = {v}")
            conn.commit()
        applied.append(v)
    return applied


def connect(path, backup_dir=None, now=None):
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("PRAGMA journal_mode=WAL")
    try:
        migrate(conn, path, backup_dir, now)
    except Exception:
        conn.close()
        raise
    return conn


def connect_read_only(path):
    """Open an existing current-schema database without creating, migrating, or journaling it."""
    resolved = Path(path).resolve()
    if not resolved.is_file():
        raise SchemaError(
            f"database does not exist at {path}; read-only preview will not create it"
        )
    try:
        conn = sqlite3.connect(f"{resolved.as_uri()}?mode=ro", uri=True)
    except sqlite3.Error as e:
        raise SchemaError(f"cannot open database read-only at {path}: {e}") from e
    conn.row_factory = sqlite3.Row
    try:
        conn.execute("PRAGMA foreign_keys=ON")
        conn.execute("PRAGMA query_only=ON")
        have = _user_version(conn)
        if have != SCHEMA_VERSION:
            raise SchemaError(
                f"database schema is version {have}, but read-only preview needs "
                f"version {SCHEMA_VERSION}; run a normal plexcurator command to migrate it"
            )
    except sqlite3.Error as e:
        conn.close()
        raise SchemaError(f"cannot read database read-only at {path}: {e}") from e
    except SchemaError:
        conn.close()
        raise
    return conn


def stars(rating):
    """Plex rating 0-10 (half stars are odd numbers) -> whole stars 0-5, rounding DOWN. None/0 -> 0."""
    if not rating or rating <= 0:
        return 0
    return min(5, int(rating // 2))


def add_event(conn, movie_id, ts, kind, value=None, detail=None, life=None):
    if life is None:
        life = conn.execute(
            "SELECT life FROM movie WHERE id=?", (movie_id,)
        ).fetchone()[0]
    conn.execute(
        "INSERT INTO event(movie_id,ts,kind,life,value,detail) VALUES (?,?,?,?,?,?)",
        (movie_id, ts, kind, life, None if value is None else str(value), detail),
    )
