"""Thin stdlib HTTP clients for Plex and Radarr. Network code only; no decisions here.
Field and endpoint names are from API knowledge and UNVERIFIED against live instances (see docs).
"""

import json
import urllib.error
import urllib.parse
import urllib.request

WATCHLIST_URL = "https://discover.provider.plex.tv/library/sections/watchlist/all"


def _req(url, method="GET", headers=None, body=None, timeout=60):
    data = json.dumps(body).encode() if body is not None else None
    if data is None and method in ("PUT", "POST"):
        # Plex answers 404 to a PUT with no body at all (emptyTrash, rate); an empty body is accepted.
        data = b""
    h = {"Accept": "application/json", **(headers or {})}
    if data:
        h["Content-Type"] = "application/json"
    with urllib.request.urlopen(
        urllib.request.Request(url, data, h, method=method), timeout=timeout
    ) as r:
        raw = r.read()
    return json.loads(raw) if raw.strip() else None


def error_status(error):
    if isinstance(error, urllib.error.HTTPError):
        return f"HTTP {error.code}"
    return str(error) or type(error).__name__


class Plex:
    def __init__(self, url, token):
        self.url, self.token = url.rstrip("/"), token

    def _get(self, path, method="GET", base=None, **params):
        q = urllib.parse.urlencode({**params, "X-Plex-Token": self.token})
        return _req(f"{base or self.url}{path}?{q}", method)

    def sections(self):
        return self._get("/library/sections")["MediaContainer"].get("Directory", [])

    def movie_sections(self, only=()):
        return [
            s
            for s in self.sections()
            if s["type"] == "movie"
            and (not only or s["title"] in only or s["key"] in only)
        ]

    def iter_movies(self, section_key):
        start, size = 0, 200
        while True:
            mc = self._get(
                f"/library/sections/{section_key}/all",
                includeGuids=1,
                type=1,
                **{"X-Plex-Container-Start": start, "X-Plex-Container-Size": size},
            )["MediaContainer"]
            yield from mc.get("Metadata", [])
            start += size
            if start >= mc.get("totalSize", mc.get("size", 0)):
                return

    def movies(self, section_key):
        return list(self.iter_movies(section_key))

    def item(self, rating_key):
        md = self._get(f"/library/metadata/{rating_key}")["MediaContainer"].get(
            "Metadata", []
        )
        return md[0] if md else None

    def iter_watchlist(self):
        """Movies on the account's Plex watchlist (plex.tv cloud). Items carry Guid ids when includeGuids works."""
        start, size = 0, 100
        while True:
            mc = self._get(
                "",
                base=WATCHLIST_URL,
                includeGuids=1,
                type=1,
                **{"X-Plex-Container-Start": start, "X-Plex-Container-Size": size},
            )["MediaContainer"]
            yield from (
                movie
                for movie in mc.get("Metadata", [])
                if movie.get("type", "movie") == "movie"
            )
            start += size
            if start >= mc.get("totalSize", mc.get("size", 0)):
                return

    def watchlist(self):
        return list(self.iter_watchlist())

    def set_rating(self, rating_key, rating):
        self._get(
            "/:/rate",
            method="PUT",
            key=rating_key,
            rating=rating,
            identifier="com.plexapp.plugins.library",
        )

    def scrobble(self, rating_key):
        self._get(
            "/:/scrobble", key=rating_key, identifier="com.plexapp.plugins.library"
        )

    def scan(self, section_key):
        self._get(f"/library/sections/{section_key}/refresh")

    def empty_trash(self, section_key):
        self._get(f"/library/sections/{section_key}/emptyTrash", method="PUT")


class Radarr:
    def __init__(self, url, api_key):
        self.url, self.h = url.rstrip("/") + "/api/v3", {"X-Api-Key": api_key}

    def status(self):
        return _req(f"{self.url}/system/status", headers=self.h)

    def movies(self):
        return _req(
            f"{self.url}/movie?excludeLocalCovers=true",
            headers=self.h,
        )

    def get(self, rid):
        return _req(f"{self.url}/movie/{rid}", headers=self.h)

    def track_at(self, rid, path):
        """Set a movie's folder and request a Radarr rescan."""
        m = self.get(rid)
        m["path"], m["monitored"] = path, False
        _req(f"{self.url}/movie/{rid}?moveFiles=false", "PUT", self.h, m)
        _req(
            f"{self.url}/command",
            "POST",
            self.h,
            {"name": "RescanMovie", "movieId": rid},
        )

    def selftest(self):
        """Make one unchanged update with the current PUT-by-id call."""
        movies = self.movies()
        if not movies:
            raise RuntimeError(
                "Radarr write selftest needs at least one existing movie"
            )
        rid = movies[0].get("id")
        if type(rid) is not int or rid < 1:
            raise RuntimeError("Radarr write selftest could not find a valid movie id")
        movie = self.get(rid)
        if not isinstance(movie, dict):
            raise RuntimeError(f"Radarr write selftest could not read movie {rid}")
        _req(f"{self.url}/movie/{rid}?moveFiles=false", "PUT", self.h, movie)

    def delete_with_exclusion(self, rid):
        """Retire: remove from Radarr (files are deleted by us) and ban it so no list can re-add it."""
        _req(
            f"{self.url}/movie/{rid}?deleteFiles=false&addImportExclusion=true",
            "DELETE",
            self.h,
        )

    def add_exclusion(self, tmdb_id, title, year):
        """For movies Radarr no longer knows: ban the tmdb id directly."""
        _req(
            f"{self.url}/exclusions",
            "POST",
            self.h,
            {"tmdbId": tmdb_id, "movieTitle": title, "movieYear": year},
        )
