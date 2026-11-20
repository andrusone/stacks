import json
import threading
import urllib.parse
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import unittest
from unittest import mock

from plexcurator import clients


class Resp:
    def __init__(self, raw=b""):
        self.raw = raw

    def read(self):
        return self.raw

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class ReqBody(unittest.TestCase):
    def sent(self, method, body=None):
        with mock.patch.object(
            clients.urllib.request, "urlopen", return_value=Resp()
        ) as op:
            clients._req("http://x/y", method, None, body)
        return op.call_args[0][0]

    def test_put_without_a_body_sends_an_empty_one(self):
        # Plex returns 404 for a PUT with no body (emptyTrash, /:/rate).
        self.assertEqual(self.sent("PUT").data, b"")
        self.assertEqual(self.sent("POST").data, b"")

    def test_get_and_delete_send_no_body(self):
        self.assertIsNone(self.sent("GET").data)
        self.assertIsNone(self.sent("DELETE").data)

    def test_request_uses_the_requested_http_method(self):
        for method in ("GET", "PUT", "POST", "DELETE"):
            with self.subTest(method=method):
                self.assertEqual(self.sent(method).get_method(), method)

    def test_empty_trash_uses_the_plex_put_contract_with_a_stub(self):
        with mock.patch.object(
            clients.urllib.request, "urlopen", return_value=Resp()
        ) as op:
            clients.Plex("http://plex.test", "fake-token").empty_trash("7")

        request = op.call_args[0][0]
        self.assertEqual(request.get_method(), "PUT")
        self.assertEqual(
            urllib.parse.urlparse(request.full_url).path,
            "/library/sections/7/emptyTrash",
        )
        self.assertEqual(request.data, b"")
        self.assertEqual(
            urllib.parse.parse_qs(urllib.parse.urlparse(request.full_url).query),
            {"X-Plex-Token": ["fake-token"]},
        )

    def test_a_json_body_is_still_sent_as_json(self):
        r = self.sent("PUT", {"a": 1})
        self.assertEqual(r.data, b'{"a": 1}')
        self.assertEqual(r.get_header("Content-type"), "application/json")


class APIHandler(BaseHTTPRequestHandler):
    requests = []
    writes = []
    count = 450
    radarr_movies = []
    radarr_movie = {}
    radarr_put_status = 200

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)
        self.requests.append((parsed.path, params))
        if parsed.path == "/library/sections/1/all":
            start = int(params["X-Plex-Container-Start"][0])
            size = int(params["X-Plex-Container-Size"][0])
            body = {
                "MediaContainer": {
                    "totalSize": self.count,
                    "Metadata": [
                        {"ratingKey": str(index)}
                        for index in range(start, min(start + size, self.count))
                    ],
                }
            }
        elif parsed.path == "/api/v3/movie":
            body = self.radarr_movies
        elif parsed.path == "/api/v3/movie/42":
            body = self.radarr_movie
        elif parsed.path == "/watchlist":
            start = int(params["X-Plex-Container-Start"][0])
            size = int(params["X-Plex-Container-Size"][0])
            body = {
                "MediaContainer": {
                    "totalSize": self.count,
                    "Metadata": [
                        {
                            "ratingKey": str(index),
                            "Guid": [{"id": f"tmdb://{index}"}],
                        }
                        for index in range(start, min(start + size, self.count))
                    ],
                }
            }
        else:
            self.send_error(404)
            return
        raw = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_PUT(self):
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.writes.append((parsed.path, params, raw))
        if parsed.path == "/api/v3/movie":
            body = b'{"message":"MovieExistsValidator: movie already exists"}'
            self.send_response(400)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif parsed.path == "/api/v3/movie/42":
            self.send_response(self.radarr_put_status)
            self.end_headers()
        else:
            self.send_error(404)

    def log_message(self, *_):
        pass


class ClientPaging(unittest.TestCase):
    def setUp(self):
        APIHandler.requests = []
        APIHandler.writes = []
        APIHandler.radarr_movies = []
        APIHandler.radarr_movie = {}
        APIHandler.radarr_put_status = 200
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), APIHandler)
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def test_plex_iterator_yields_before_fetching_all_pages(self):
        movies = clients.Plex(self.url, "fake").iter_movies("1")
        self.assertEqual(next(movies), {"ratingKey": "0"})
        self.assertEqual(len(APIHandler.requests), 1)
        remaining = list(movies)
        self.assertEqual(len(remaining), 449)
        self.assertEqual(
            [
                request[1]["X-Plex-Container-Start"][0]
                for request in APIHandler.requests
            ],
            ["0", "200", "400"],
        )

    def test_plex_movies_keeps_list_compatibility(self):
        movies = clients.Plex(self.url, "fake").movies("1")
        self.assertEqual(len(movies), 450)
        self.assertEqual(movies[-1]["ratingKey"], "449")

    def test_radarr_excludes_local_cover_data(self):
        self.assertEqual(clients.Radarr(self.url, "fake").movies(), [])
        self.assertEqual(
            APIHandler.requests[0],
            ("/api/v3/movie", {"excludeLocalCovers": ["true"]}),
        )

    def test_radarr_selftest_puts_one_existing_movie_without_changing_it(self):
        movie = {
            "id": 42,
            "title": "Fixture Movie",
            "path": "/movies/Fixture Movie",
            "monitored": True,
        }
        APIHandler.radarr_movies = [movie]
        APIHandler.radarr_movie = movie

        clients.Radarr(self.url, "fake").selftest()

        self.assertEqual(len(APIHandler.writes), 1)
        path, params, raw = APIHandler.writes[0]
        self.assertEqual(path, "/api/v3/movie/42")
        self.assertEqual(params, {"moveFiles": ["false"]})
        self.assertEqual(json.loads(raw), movie)

    def test_radarr_selftest_fails_clearly_when_library_is_empty(self):
        with self.assertRaisesRegex(RuntimeError, "needs at least one existing movie"):
            clients.Radarr(self.url, "fake").selftest()
        self.assertEqual(APIHandler.writes, [])

    def test_radarr_by_id_put_405_is_empty_and_has_no_fallback_retry(self):
        APIHandler.radarr_put_status = 405
        APIHandler.radarr_movie = {
            "id": 42,
            "title": "Fixture Movie",
            "path": "/movies/Fixture Movie",
            "monitored": True,
        }

        with self.assertRaises(urllib.error.HTTPError) as raised:
            clients.Radarr(self.url, "fake").track_at(42, "/new/Fixture Movie")

        self.assertEqual(raised.exception.code, 405)
        self.assertEqual(raised.exception.read(), b"")
        raised.exception.close()
        self.assertEqual(
            [(path, params) for path, params, _ in APIHandler.writes],
            [("/api/v3/movie/42", {"moveFiles": ["false"]})],
        )

    def test_radarr_put_without_id_models_movie_exists_validator_400(self):
        with self.assertRaises(urllib.error.HTTPError) as raised:
            clients._req(
                f"{self.url}/api/v3/movie",
                "PUT",
                {"X-Api-Key": "fake"},
                {"title": "Fixture Movie"},
            )

        self.assertEqual(raised.exception.code, 400)
        self.assertIn(b"MovieExistsValidator", raised.exception.read())
        raised.exception.close()

    def test_watchlist_iterator_yields_before_fetching_all_pages(self):
        with mock.patch.object(clients, "WATCHLIST_URL", f"{self.url}/watchlist"):
            movies = clients.Plex(self.url, "fake").iter_watchlist()
            self.assertEqual(next(movies)["ratingKey"], "0")
            self.assertEqual(len(APIHandler.requests), 1)
            self.assertEqual(len(list(movies)), 449)


if __name__ == "__main__":
    unittest.main()
