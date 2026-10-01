"""Tests for backend/immich-photos. No Docker and no running Immich needed.

Run with: python3 -B -m unittest discover -s tests
"""

import sys

sys.dont_write_bytecode = True

import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import stat
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from unittest import mock

BACKEND = Path(__file__).resolve().parent.parent / "backend" / "immich-photos"
loader = importlib.machinery.SourceFileLoader("immich_photos", str(BACKEND))
spec = importlib.util.spec_from_loader("immich_photos", loader)
ip = importlib.util.module_from_spec(spec)
loader.exec_module(ip)

GIB = 1024**3


def fake_mount(fstype="ext4", target="/", options="rw,relatime", source="/dev/sda1"):
    return lambda path: {"target": target, "source": source, "fstype": fstype, "options": options.split(",")}


def fake_usage(free=500 * GIB, total=1000 * GIB):
    return lambda path: {"totalBytes": total, "freeBytes": free, "usedBytes": total - free}


class IsolatedHome(unittest.TestCase):
    """Points HOME and the XDG directories at a temporary directory."""

    def setUp(self):
        # Not /tmp: the storage check rightly refuses temporary filesystems.
        cache = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache")
        cache.mkdir(parents=True, exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="immich-photos-test-", dir=cache)
        self.home = Path(self.tmp.name)
        patcher = mock.patch.dict(os.environ, {
            "HOME": str(self.home),
            "XDG_CONFIG_HOME": str(self.home / ".config"),
            "XDG_DATA_HOME": str(self.home / ".local/share"),
        })
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.tmp.cleanup)


class StoragePathValidation(IsolatedHome):
    def check(self, path, purpose="media", mount=None, usage=None):
        return ip.check_storage(path, purpose, mount or fake_mount(), usage or fake_usage())

    def test_new_folder_on_suitable_disk_is_accepted(self):
        result = self.check(self.home / "Pictures/Immich", mount=fake_mount("btrfs", "/home"))
        self.assertTrue(result["ok"], result["errors"])
        self.assertFalse(result["exists"])
        self.assertEqual(result["filesystem"], "btrfs")
        self.assertEqual(result["freeBytes"], 500 * GIB)

    def test_nothing_is_created_by_a_check(self):
        target = self.home / "Pictures/Immich"
        self.check(target)
        self.assertFalse(target.exists())

    def test_relative_path_is_invalid(self):
        result = self.check("Pictures/Immich")
        self.assertFalse(result["ok"])
        self.assertIn("absolute", result["errors"][0])

    def test_empty_path_is_invalid(self):
        self.assertFalse(self.check("  ")["ok"])

    def test_root_and_system_directories_are_invalid(self):
        for path in ("/", "/etc/immich", "/boot/photos", "/tmp/immich", "/var/lib/docker/immich"):
            with self.subTest(path=path):
                self.assertFalse(self.check(path)["ok"])

    def test_path_that_is_a_file_is_invalid(self):
        target = self.home / "photos"
        target.write_text("not a directory")
        result = self.check(target)
        self.assertFalse(result["ok"])
        self.assertIn("not a directory", result["errors"][0])

    def test_disk_not_mounted(self):
        # /mnt/photos resolves to the root filesystem: the drive is not mounted.
        result = self.check("/mnt/photos/Immich", mount=fake_mount("btrfs", "/"))
        self.assertFalse(result["ok"])
        self.assertFalse(result["mounted"])
        self.assertIn("No disk is mounted", result["errors"][0])

    def test_mounted_disk_under_mnt_is_accepted(self):
        with mock.patch.object(ip.os, "access", return_value=True):
            result = self.check("/mnt/photos/Immich", mount=fake_mount("ext4", "/mnt/photos"))
        self.assertTrue(result["ok"], result["errors"])
        self.assertTrue(result["mounted"])

    def test_storage_full(self):
        result = self.check(self.home / "Immich", usage=fake_usage(free=200 * 1024**2))
        self.assertFalse(result["ok"])
        self.assertTrue(any("Storage is full" in error for error in result["errors"]))

    def test_low_space_is_a_warning_not_an_error(self):
        result = self.check(self.home / "Immich", usage=fake_usage(free=5 * GIB))
        self.assertTrue(result["ok"])
        self.assertTrue(any("free" in warning for warning in result["warnings"]))

    def test_filesystem_without_permissions_is_rejected(self):
        for fstype in ("vfat", "exfat", "ntfs3", "fuseblk"):
            with self.subTest(fstype=fstype):
                self.assertFalse(self.check(self.home / "Immich", mount=fake_mount(fstype))["ok"])

    def test_read_only_mount_is_rejected(self):
        result = self.check(self.home / "Immich", mount=fake_mount(options="ro,relatime"))
        self.assertTrue(any("read-only" in error for error in result["errors"]))

    def test_network_share_allowed_for_media_but_not_database(self):
        media = self.check(self.home / "Immich", "media", fake_mount("nfs4"))
        database = self.check(self.home / "Immich", "database", fake_mount("nfs4"))
        self.assertTrue(media["ok"])
        self.assertTrue(media["network"])
        self.assertTrue(media["warnings"])
        self.assertFalse(database["ok"])

    def test_not_writable(self):
        with mock.patch.object(ip.os, "access", return_value=False):
            result = self.check(self.home / "Immich")
        self.assertFalse(result["ok"])
        self.assertFalse(result["writable"])

    def test_unknown_filesystem_is_an_error(self):
        result = ip.check_storage(self.home / "Immich", "media", lambda path: None, fake_usage())
        self.assertFalse(result["ok"])

    def test_existing_library_is_detected(self):
        target = self.home / "Immich"
        (target / "upload/user-1/ab").mkdir(parents=True)
        (target / "upload/user-1/ab/photo.heic").write_text("x")
        result = self.check(target)
        self.assertTrue(result["existingLibrary"])
        self.assertFalse(result["empty"])

    def test_fresh_immich_folders_are_not_a_library(self):
        target = self.home / "Immich"
        for name in ("library", "upload", "thumbs"):
            (target / name).mkdir(parents=True)
        self.assertFalse(self.check(target)["existingLibrary"])


class SpaceCalculation(unittest.TestCase):
    def test_used_counts_like_df(self):
        stats = mock.Mock(f_blocks=1000, f_bfree=400, f_bavail=350, f_frsize=4096)
        self.assertEqual(ip.compute_used(stats), 600 * 4096)

    def test_disk_usage_reports_space_available_to_the_user(self):
        stats = mock.Mock(f_blocks=1000, f_bfree=400, f_bavail=350, f_frsize=4096)
        with mock.patch.object(ip.os, "statvfs", return_value=stats):
            usage = ip.disk_usage("/anywhere")
        self.assertEqual(usage, {"totalBytes": 1000 * 4096, "freeBytes": 350 * 4096, "usedBytes": 600 * 4096})

    def test_format_bytes(self):
        self.assertEqual(ip.format_bytes(None), "unknown")
        self.assertEqual(ip.format_bytes(0), "0 B")
        self.assertEqual(ip.format_bytes(1536), "1.5 KB")
        self.assertEqual(ip.format_bytes(183 * GIB), "183 GB")
        self.assertEqual(ip.format_bytes(45.2 * GIB), "45.2 GB")
        self.assertEqual(ip.format_bytes(2 * 1024 * GIB), "2.0 TB")


class ConfigParsing(IsolatedHome):
    ENV = """
# comment
UPLOAD_LOCATION=/mnt/photos/Immich
DB_DATA_LOCATION=./postgres
# TZ=Etc/UTC
TZ="Europe/Vienna"
IMMICH_VERSION=v3   # pinned
DB_PASSWORD=abc123
export EXTRA='quoted value'
not a variable line
"""

    def test_parse_env(self):
        env = ip.parse_env(self.ENV)
        self.assertEqual(env["UPLOAD_LOCATION"], "/mnt/photos/Immich")
        self.assertEqual(env["TZ"], "Europe/Vienna")
        self.assertEqual(env["IMMICH_VERSION"], "v3")
        self.assertEqual(env["EXTRA"], "quoted value")
        self.assertEqual(len(env), 6)

    def test_host_port(self):
        self.assertEqual(ip.parse_host_port("ports:\n      - '2283:2283'\n"), 2283)
        self.assertEqual(ip.parse_host_port("ports:\n      - 8080:2283\n"), 8080)
        self.assertEqual(ip.parse_host_port('ports:\n  - "127.0.0.1:9000:2283"\n'), 9000)
        self.assertEqual(ip.parse_host_port("no ports here"), 2283)

    def test_installation_resolves_relative_locations(self):
        stack = self.home / "immich-app"
        stack.mkdir()
        (stack / "docker-compose.yml").write_text("services:\n  immich-server:\n    ports:\n      - '2284:2283'\n")
        (stack / ".env").write_text(self.ENV)
        installation = ip.Installation(stack)
        self.assertTrue(installation.installed)
        self.assertEqual(installation.port, 2284)
        self.assertEqual(installation.media_path, Path("/mnt/photos/Immich"))
        self.assertEqual(installation.db_path, (stack / "postgres").resolve())

    def test_directory_without_compose_file_is_not_an_installation(self):
        installation = ip.Installation(self.home)
        self.assertFalse(installation.installed)
        self.assertIsNone(installation.media_path)

    def test_existing_installation_is_found_in_common_place(self):
        stack = self.home / "immich-app"
        stack.mkdir()
        (stack / "docker-compose.yml").write_text("services:\n  immich-server:\n")
        with mock.patch.object(ip, "running_compose_dirs", return_value=[]):
            self.assertEqual(ip.find_installation().compose_dir, stack)

    def test_render_env_only_sets_known_variables(self):
        template = "UPLOAD_LOCATION=./library\n# TZ=Etc/UTC\nDB_PASSWORD=postgres\n"
        text, applied = ip.render_env(template, {"UPLOAD_LOCATION": "/data", "TZ": "Europe/Vienna",
                                                 "DB_PASSWORD": "s3cret", "REMOVED_SETTING": "x"})
        self.assertEqual(text, "UPLOAD_LOCATION=/data\nTZ=Europe/Vienna\nDB_PASSWORD=s3cret\n")
        self.assertEqual(applied, {"UPLOAD_LOCATION", "TZ", "DB_PASSWORD"})

    def test_generated_password_uses_only_allowed_characters(self):
        password = ip.generate_password()
        self.assertEqual(len(password), 40)
        self.assertRegex(password, r"^[A-Za-z0-9]+$")
        self.assertNotEqual(password, ip.generate_password())

    def test_config_is_private(self):
        ip.save_config({"composeDir": "/x"})
        path = ip.config_dir() / "config.json"
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(ip.load_config(), {"composeDir": "/x"})

    def test_broken_config_is_ignored(self):
        ip.config_dir().mkdir(parents=True)
        (ip.config_dir() / "config.json").write_text("{broken")
        self.assertEqual(ip.load_config(), {})


class StatusParsing(unittest.TestCase):
    def test_state_docker_not_installed(self):
        state, message, suggestion = ip.derive_state(False, False, False, False, False)
        self.assertEqual(state, "no-docker")
        self.assertIn("omarchy pkg add docker", suggestion)

    def test_state_not_installed(self):
        self.assertEqual(ip.derive_state(False, True, True, False, False)[0], "not-installed")

    def test_state_online_and_busy(self):
        self.assertEqual(ip.derive_state(True, True, True, True, True)[0], "online")
        self.assertEqual(ip.derive_state(True, True, True, True, True, pending_jobs=24)[0], "busy")

    def test_state_maintenance_is_a_problem(self):
        self.assertEqual(ip.derive_state(True, True, True, True, True, maintenance=True)[0], "problem")

    def test_state_stopped_names_the_cause_and_the_fix(self):
        state, message, suggestion = ip.derive_state(True, True, True, False, False)
        self.assertEqual(state, "stopped")
        self.assertIn("immich_server is stopped", message)
        self.assertEqual(suggestion, "immich-photos server start")
        state, message, _ = ip.derive_state(True, True, False, False, False)
        self.assertIn("Docker daemon is not running", message)

    def test_state_port_open_but_no_answer(self):
        state, _, suggestion = ip.derive_state(True, True, True, True, False)
        self.assertEqual(state, "problem")
        self.assertEqual(suggestion, "immich-photos server logs")

    def test_queue_summary(self):
        queues = [
            {"name": "thumbnailGeneration", "isPaused": False,
             "statistics": {"active": 2, "waiting": 20, "delayed": 0, "failed": 1, "paused": 0, "completed": 9}},
            {"name": "videoConversion", "isPaused": True,
             "statistics": {"active": 0, "waiting": 2, "delayed": 0, "failed": 0, "paused": 2, "completed": 0}},
            {"name": "search", "isPaused": False,
             "statistics": {"active": 0, "waiting": 0, "delayed": 0, "failed": 0, "paused": 0, "completed": 5}},
        ]
        summary = ip.summarize_queues(queues)
        self.assertEqual(summary["active"], 2)
        self.assertEqual(summary["waiting"], 22)
        self.assertEqual(summary["failed"], 1)
        self.assertEqual(summary["pending"], 26)
        self.assertEqual([queue["name"] for queue in summary["queues"]], ["thumbnailGeneration", "videoConversion"])
        self.assertEqual(summary["queues"][0], {"name": "thumbnailGeneration", "pending": 22, "active": 2,
                                                "waiting": 20, "paused": False})
        self.assertEqual(summary["queues"][1]["pending"], 4)
        self.assertEqual(sum(queue["pending"] for queue in summary["queues"]), summary["pending"])

    def test_queue_summary_of_idle_server(self):
        self.assertEqual(ip.summarize_queues([])["pending"], 0)

    def test_sessions_newest_first_and_phone_app_detected(self):
        sessions = [
            {"deviceType": "Chrome", "deviceOS": "Linux", "updatedAt": "2026-10-01T08:00:00Z", "appVersion": None},
            {"deviceType": "iPhone", "deviceOS": "iOS", "updatedAt": "2026-10-01T09:30:00Z", "appVersion": "3.2.4"},
            {"deviceType": "", "deviceOS": "", "updatedAt": "2026-10-01T10:00:00Z"},
        ]
        devices = ip.summarize_sessions(sessions)
        self.assertEqual(len(devices), 2)
        self.assertEqual(devices[0]["deviceOS"], "iOS")
        self.assertTrue(ip.is_phone_app(devices[0]))
        self.assertFalse(ip.is_phone_app(devices[1]))

    def test_android_app_counts_and_mobile_browser_does_not(self):
        devices = ip.summarize_sessions([
            {"deviceType": "Pixel 8", "deviceOS": "Android", "appVersion": "3.2.1", "updatedAt": "2026-10-01T08:00:00Z"},
            {"deviceType": "Mobile Safari", "deviceOS": "iOS", "appVersion": None, "updatedAt": "2026-10-01T09:00:00Z"},
        ])
        self.assertEqual([ip.is_phone_app(device) for device in devices], [False, True])

    def test_compose_ps_array_and_lines(self):
        row = {"Name": "immich_server", "Service": "immich-server", "State": "running", "Health": "healthy"}
        expected = [{"name": "immich_server", "service": "immich-server", "state": "running", "health": "healthy"}]
        self.assertEqual(ip.parse_compose_ps(json.dumps([row])), expected)
        self.assertEqual(ip.parse_compose_ps(json.dumps(row) + "\n" + json.dumps(row)), expected * 2)
        self.assertEqual(ip.parse_compose_ps(""), [])
        self.assertEqual(ip.parse_compose_ps("garbage"), [])


class NetworkAddress(unittest.TestCase):
    def test_private_addresses_are_offered(self):
        for address in ("192.168.0.12", "10.0.0.5", "172.20.1.9"):
            self.assertEqual(ip.lan_ip(address), address)

    def test_vpn_public_and_loopback_addresses_are_not_offered(self):
        for address in ("100.64.1.2", "8.8.8.8", "127.0.0.1", "169.254.3.4", "fe80::1", "", "nonsense"):
            with self.subTest(address=address):
                self.assertIsNone(ip.lan_ip(address))

    def test_no_network(self):
        with mock.patch.object(ip, "outbound_address", return_value=None):
            self.assertIsNone(ip.lan_ip())


class FakeImmich(BaseHTTPRequestHandler):
    routes = {}
    writes = []

    def do_GET(self):
        status, body, needs_key = self.routes.get(self.path, (404, {"message": "Not found"}, False))
        if needs_key and self.headers.get("x-api-key") != "valid-key":
            status, body = 401, {"message": "Invalid API key"}
        payload = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def respond_to_write(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"null")
        FakeImmich.writes.append((self.command, self.path, body))
        key = "%s %s" % (self.command, self.path)
        status, answer, needs_key = self.routes.get(key, (404, {"message": "Not found"}, False))
        if needs_key and self.headers.get("x-api-key") != "valid-key":
            status, answer = 401, {"message": "Invalid API key"}
        payload = b"" if answer is None else json.dumps(answer).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    do_POST = do_PUT = do_DELETE = respond_to_write

    def log_message(self, *args):
        pass


class WithFakeImmich(IsolatedHome):
    ROUTES = {
        "/api/server/ping": (200, {"res": "pong"}, False),
        "/api/server/version": (200, {"major": 3, "minor": 2, "patch": 4, "prerelease": None}, False),
        "/api/server/config": (200, {"isInitialized": True, "maintenanceMode": False}, False),
        "/api/server/statistics": (200, {"photos": 12483, "videos": 1204, "usage": 183 * GIB}, True),
        "/api/assets/statistics": (200, {"images": 100, "videos": 7, "total": 107}, True),
        "/api/queues": (200, [{"name": "thumbnailGeneration", "isPaused": False, "statistics": {
            "active": 4, "waiting": 20, "delayed": 0, "failed": 0, "paused": 0, "completed": 1}}], True),
        "/api/sessions": (200, [{"deviceType": "iPhone", "deviceOS": "iOS", "appVersion": "3.2.4",
                                 "updatedAt": "2026-10-01T09:30:00.000Z"}], True),
    }

    def setUp(self):
        super().setUp()
        FakeImmich.routes = dict(self.ROUTES)
        FakeImmich.writes = []
        self.server = HTTPServer(("127.0.0.1", 0), FakeImmich)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.url = "http://127.0.0.1:%d" % self.port

    def installation(self, port=None):
        stack = self.home / "stack"
        stack.mkdir(exist_ok=True)
        media = self.home / "media"
        media.mkdir(exist_ok=True)
        (stack / "docker-compose.yml").write_text(
            "services:\n  immich-server:\n    ports:\n      - '%d:2283'\n" % (port or self.port))
        (stack / ".env").write_text("UPLOAD_LOCATION=%s\nDB_PASSWORD=topsecretpassword\n" % media)
        return ip.Installation(stack)

    def status(self, installation=None, **docker):
        defaults = {"docker_installed": True, "docker_daemon_active": True, "docker_direct": False,
                    "docker_enabled_at_boot": True}
        defaults.update(docker)
        with contextlib.ExitStack() as stack:
            for name, value in defaults.items():
                stack.enter_context(mock.patch.object(ip, name, return_value=value))
            stack.enter_context(mock.patch.object(ip, "lan_ip", return_value="192.168.0.12"))
            return ip.collect_status(installation or self.installation())

    def set_key(self, key):
        ip.config_dir().mkdir(parents=True, exist_ok=True)
        (ip.config_dir() / "api-key").write_text(key + "\n")


class ApiErrors(WithFakeImmich):
    def error(self, path, **kwargs):
        with self.assertRaises(ip.ApiError) as caught:
            ip.ImmichApi(self.url, **kwargs).get(path, authenticated="api_key" in kwargs)
        return caught.exception

    def test_ping_and_version(self):
        api = ip.ImmichApi(self.url)
        self.assertTrue(api.ping())
        self.assertEqual(api.version(), "3.2.4")

    def test_rejected_key(self):
        self.assertEqual(self.error("/server/statistics", api_key="wrong").kind, "unauthorized")

    def test_missing_key_never_sends_a_request(self):
        with self.assertRaises(ip.ApiError) as caught:
            ip.ImmichApi(self.url).get("/server/statistics", authenticated=True)
        self.assertEqual(caught.exception.kind, "no-key")

    def test_missing_permission(self):
        FakeImmich.routes["/api/queues"] = (403, {"message": "Forbidden"}, False)
        self.assertEqual(self.error("/queues", api_key="valid-key").kind, "forbidden")

    def test_server_error(self):
        FakeImmich.routes["/api/server/version"] = (500, {"message": "boom"}, False)
        error = self.error("/server/version")
        self.assertEqual((error.kind, error.status), ("http", 500))

    def test_unknown_endpoint(self):
        self.assertEqual(self.error("/does/not/exist").status, 404)

    def test_response_that_is_not_json(self):
        FakeImmich.routes["/api/server/version"] = (200, b"<html>login</html>", False)
        self.assertEqual(self.error("/server/version").kind, "invalid")

    def test_unreachable(self):
        self.server.shutdown()
        self.server.server_close()
        self.assertEqual(self.error("/server/ping").kind, "unreachable")

    def test_error_messages_never_contain_the_key(self):
        error = self.error("/server/statistics", api_key="wrong-secret-key")
        self.assertNotIn("wrong-secret-key", str(error))


class StatusCollection(WithFakeImmich):
    def test_online_without_key_shows_no_counts(self):
        status = self.status()
        self.assertEqual(status["state"], "online")
        self.assertEqual(status["server"]["version"], "3.2.4")
        self.assertEqual(status["server"]["url"], "http://192.168.0.12:%d" % self.port)
        self.assertIsNone(status["library"])
        self.assertIsNone(status["jobs"])
        self.assertFalse(status["capabilities"]["apiKey"])

    def test_admin_key_gives_counts_jobs_and_last_activity(self):
        self.set_key("valid-key")
        status = self.status()
        self.assertEqual(status["state"], "busy")
        self.assertEqual(status["library"], {"photos": 12483, "videos": 1204, "scope": "server"})
        self.assertEqual(status["jobs"]["pending"], 24)
        self.assertEqual(status["storage"]["libraryBytes"], 183 * GIB)
        self.assertEqual(status["lastActivity"], "2026-10-01T09:30:00.000Z")
        self.assertTrue(status["capabilities"]["adminApi"])

    def test_non_admin_key_falls_back_to_own_statistics(self):
        self.set_key("valid-key")
        FakeImmich.routes["/api/server/statistics"] = (403, {"message": "Forbidden"}, False)
        FakeImmich.routes["/api/queues"] = (403, {"message": "Forbidden"}, False)
        status = self.status()
        self.assertEqual(status["library"], {"photos": 100, "videos": 7, "scope": "user"})
        self.assertIsNone(status["jobs"])
        self.assertIsNone(status["storage"]["libraryBytes"])
        self.assertFalse(status["capabilities"]["adminApi"])
        self.assertEqual(status["state"], "online")

    def test_rejected_key_is_reported_and_nothing_is_invented(self):
        self.set_key("revoked-key")
        status = self.status()
        self.assertIsNone(status["library"])
        self.assertTrue(any("rejected" in note["text"] for note in status["notes"]))

    def test_server_without_admin_account(self):
        FakeImmich.routes["/api/server/config"] = (200, {"isInitialized": False, "maintenanceMode": False}, False)
        status = self.status()
        self.assertFalse(status["server"]["initialized"])
        self.assertTrue(any("admin account" in note["text"] for note in status["notes"]))

    def test_immich_offline(self):
        installation = self.installation()
        self.server.shutdown()
        self.server.server_close()
        status = self.status(installation)
        self.assertEqual(status["state"], "stopped")
        self.assertFalse(status["server"]["online"])
        self.assertIsNone(status["server"]["version"])
        self.assertEqual(status["database"]["status"], "unknown")
        self.assertEqual(status["suggestion"], "immich-photos server start")
        self.assertIsNotNone(status["storage"]["freeBytes"])

    def test_docker_not_installed(self):
        status = self.status(ip.Installation(self.home / "nothing"), docker_installed=False,
                             docker_daemon_active=False)
        self.assertEqual(status["state"], "no-docker")
        self.assertFalse(status["installed"])
        self.assertIsNone(status["storage"])

    def test_missing_media_folder_is_reported(self):
        installation = self.installation()
        (self.home / "media").rmdir()
        status = self.status(installation)
        self.assertFalse(status["storage"]["exists"])
        self.assertIsNone(status["storage"]["freeBytes"])
        self.assertTrue(any("does not exist" in note["text"] for note in status["notes"]))

    def test_status_never_contains_secrets(self):
        self.set_key("valid-key")
        text = json.dumps(self.status())
        self.assertNotIn("valid-key", text)
        self.assertNotIn("topsecretpassword", text)


class DockerControl(IsolatedHome):
    def installation(self):
        stack = self.home / "stack"
        stack.mkdir()
        (stack / "docker-compose.yml").write_text("services:\n  immich-server:\n")
        return ip.Installation(stack)

    def test_pkexec_is_used_without_socket_access_and_terminal(self):
        with mock.patch.object(ip, "docker_direct", return_value=False), \
                mock.patch.object(ip.sys.stdin, "isatty", return_value=False):
            command = ip.compose_command(self.installation(), "up", "-d")
        self.assertEqual(command[:3], ["pkexec", "docker", "compose"])
        self.assertEqual(command[-2:], ["up", "-d"])

    def test_sudo_is_used_in_a_terminal(self):
        with mock.patch.object(ip, "docker_direct", return_value=False), \
                mock.patch.object(ip.sys.stdin, "isatty", return_value=True), \
                mock.patch.object(ip.shutil, "which", return_value="/usr/bin/sudo"):
            command = ip.compose_command(self.installation(), "stop")
        self.assertEqual(command[:2], ["sudo", "docker"])

    def test_direct_access_needs_no_prompt(self):
        with mock.patch.object(ip, "docker_direct", return_value=True):
            command = ip.compose_command(self.installation(), "stop")
        self.assertEqual(command[0], "docker")

    def test_start_without_docker_explains_what_to_do(self):
        stderr = io.StringIO()
        with mock.patch.object(ip, "docker_installed", return_value=False), \
                contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit):
            ip.run_compose(self.installation(), "up", "-d")
        self.assertIn("Docker is not installed", stderr.getvalue())
        self.assertIn("Suggested action", stderr.getvalue())


class Setup(IsolatedHome):
    COMPOSE = "services:\n  immich-server:\n    ports:\n      - '2283:2283'\n"
    TEMPLATE = "UPLOAD_LOCATION=./library\nDB_DATA_LOCATION=./postgres\n# TZ=Etc/UTC\nDB_PASSWORD=postgres\n"

    def run_setup(self, media, fetch=None, port_in_use=False):
        fetch = fetch or (lambda name: self.COMPOSE if name == "docker-compose.yml" else self.TEMPLATE)
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(ip, "running_compose_dirs", return_value=[]), \
                mock.patch.object(ip, "port_listening", return_value=port_in_use), \
                mock.patch.object(ip, "system_timezone", return_value="Europe/Vienna"), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                code = ip.setup(media, fetch=fetch)
            except SystemExit as exit_:
                code = exit_.code
        return code, out.getvalue() + err.getvalue()

    def test_fresh_setup_writes_private_env(self):
        media = self.home / "Pictures/Immich"
        code, output = self.run_setup(media)
        self.assertEqual(code, 0, output)
        stack = ip.default_compose_dir()
        env = ip.parse_env((stack / ".env").read_text())
        self.assertEqual(env["UPLOAD_LOCATION"], str(media))
        self.assertEqual(env["TZ"], "Europe/Vienna")
        self.assertRegex(env["DB_PASSWORD"], r"^[A-Za-z0-9]{40}$")
        self.assertEqual(stat.S_IMODE((stack / ".env").stat().st_mode), 0o600)
        self.assertEqual((stack / "docker-compose.yml").read_text(), self.COMPOSE)
        self.assertTrue((stack / ip.OWNERSHIP_MARKER).is_file())
        self.assertNotIn(env["DB_PASSWORD"], output)
        self.assertTrue(media.is_dir())

    def test_existing_installation_is_never_overwritten(self):
        self.run_setup(self.home / "Pictures/Immich")
        env_file = ip.default_compose_dir() / ".env"
        before = env_file.read_text()
        code, output = self.run_setup(self.home / "Other")
        self.assertEqual(code, 3)
        self.assertIn("already installed", output)
        self.assertEqual(env_file.read_text(), before)
        self.assertFalse((self.home / "Other").exists())

    def test_port_in_use_stops_setup(self):
        code, output = self.run_setup(self.home / "Pictures/Immich", port_in_use=True)
        self.assertEqual(code, 3)
        self.assertFalse(ip.default_compose_dir().exists())

    def test_invalid_target_stops_setup(self):
        code, output = self.run_setup("/etc/immich")
        self.assertEqual(code, 2)
        self.assertIn("system directory", output)
        self.assertFalse(ip.default_compose_dir().exists())

    def test_unexpected_release_files_stop_setup(self):
        code, output = self.run_setup(self.home / "Immich", fetch=lambda name: "<html>404</html>")
        self.assertEqual(code, 1)
        self.assertFalse((ip.default_compose_dir() / ".env").exists())

    def test_release_without_expected_variable_stops_setup(self):
        template = self.TEMPLATE.replace("DB_DATA_LOCATION", "DATABASE_DIR")
        fetch = lambda name: self.COMPOSE if name == "docker-compose.yml" else template
        code, output = self.run_setup(self.home / "Immich", fetch=fetch)
        self.assertEqual(code, 1)
        self.assertIn("DB_DATA_LOCATION", output)


class ReleasePinning(unittest.TestCase):
    def test_file_with_expected_checksum_is_accepted(self):
        data = b"services:\n"
        digest = ip.hashlib.sha256(data).hexdigest()
        with mock.patch.dict(ip.RELEASE_SHA256, {"docker-compose.yml": digest}):
            self.assertEqual(ip.verify_release_file("docker-compose.yml", data), "services:\n")

    def test_changed_or_unknown_file_is_refused(self):
        for name in ("docker-compose.yml", "something-else.yml"):
            with self.subTest(name=name), contextlib.redirect_stderr(io.StringIO()) as stderr, \
                    self.assertRaises(SystemExit):
                ip.verify_release_file(name, b"tampered")
            self.assertIn("checksum", stderr.getvalue())

    def test_download_url_is_pinned_to_a_release(self):
        self.assertIn("/releases/download/%s/" % ip.IMMICH_RELEASE, ip.RELEASE_URL)
        self.assertNotIn("latest", ip.RELEASE_URL)
        self.assertRegex(ip.IMMICH_RELEASE, r"^v\d+\.\d+\.\d+$")


class BackupStatus(IsolatedHome):
    def test_nothing_configured_is_reported_honestly(self):
        stack = self.home / "stack"
        stack.mkdir()
        (stack / "docker-compose.yml").write_text("services:\n  immich-server:\n")
        (stack / ".env").write_text("UPLOAD_LOCATION=%s\n" % (self.home / "media"))
        result = ip.backup_status(ip.Installation(stack))
        self.assertFalse(result["media"]["configured"])
        self.assertFalse(result["database"]["configured"])
        self.assertIsNone(result["lastVerified"])

    def test_database_dumps_are_counted(self):
        stack = self.home / "stack"
        dumps = self.home / "media/backups"
        stack.mkdir()
        dumps.mkdir(parents=True)
        (dumps / "immich-db-backup-1.sql.gz").write_text("x")
        (stack / "docker-compose.yml").write_text("services:\n  immich-server:\n")
        (stack / ".env").write_text("UPLOAD_LOCATION=%s\n" % (self.home / "media"))
        result = ip.backup_status(ip.Installation(stack))
        self.assertTrue(result["database"]["configured"])
        self.assertEqual(result["database"]["count"], 1)
        self.assertFalse(result["media"]["configured"])


PHOTO = "11111111-1111-4111-8111-111111111111"
VIDEO = "22222222-2222-4222-8222-222222222222"
ALBUM = "33333333-3333-4333-8333-333333333333"


class Gallery(WithFakeImmich):
    def setUp(self):
        super().setUp()
        patcher = mock.patch.dict(os.environ, {"XDG_CACHE_HOME": str(self.home / ".cache")})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.set_key("valid-key")
        FakeImmich.routes.update({
            "POST /api/search/metadata": (200, {"assets": {"total": 2, "nextPage": None, "items": [
                {"id": PHOTO, "type": "IMAGE", "originalFileName": "IMG_1.HEIC", "isFavorite": True,
                 "localDateTime": "2026-10-01T10:00:00.000Z"},
                {"id": VIDEO, "type": "VIDEO", "originalFileName": "IMG_2.MOV", "isFavorite": False,
                 "localDateTime": "2026-09-30T10:00:00.000Z", "duration": "00:00:07.000"},
                {"id": "../../etc/passwd", "type": "IMAGE"},
            ]}}, True),
            "/api/assets/%s/thumbnail?size=thumbnail" % PHOTO: (200, b"thumb-1", True),
            "/api/assets/%s/thumbnail?size=thumbnail" % VIDEO: (200, b"thumb-2", True),
            "/api/assets/%s/thumbnail?size=preview" % PHOTO: (200, b"preview-1", True),
            "DELETE /api/assets": (204, None, True),
            "PUT /api/assets": (204, None, True),
            "POST /api/trash/restore/assets": (200, {"count": 1}, True),
            "/api/albums": (200, [{"id": ALBUM, "albumName": "Urlaub", "assetCount": 3},
                                  {"id": PHOTO, "albumName": "alpen", "assetCount": 1}], True),
            "PUT /api/albums/%s/assets" % ALBUM: (200, [{"id": PHOTO, "success": True}], True),
            "POST /api/albums": (201, {"id": ALBUM, "albumName": "Neu"}, True),
        })

    def gallery(self, action, *arguments):
        return ip.gallery_command(self.installation(), action, list(arguments))

    def error(self, action, *arguments):
        with self.assertRaises(ip.GalleryError) as caught:
            self.gallery(action, *arguments)
        return caught.exception

    def test_list_returns_items_with_cached_thumbnails(self):
        result = self.gallery("list")
        self.assertEqual([item["id"] for item in result["items"]], [PHOTO, VIDEO])
        self.assertEqual(result["items"][0]["type"], "image")
        self.assertTrue(result["items"][0]["favorite"])
        self.assertEqual(result["items"][1]["type"], "video")
        self.assertEqual(Path(result["items"][0]["thumb"]).read_bytes(), b"thumb-1")
        self.assertIsNone(result["nextPage"])
        self.assertEqual(result["items"][1]["duration"], "0:07")
        self.assertEqual(FakeImmich.writes[0][2],
                         {"page": 1, "size": 150, "order": "desc", "visibility": "timeline"})

    def test_duration_formats(self):
        self.assertEqual(ip.format_duration(1900), "0:02")
        self.assertEqual(ip.format_duration(125000), "2:05")
        self.assertEqual(ip.format_duration("01:02:03.500"), "1:02:04")
        self.assertIsNone(ip.format_duration(None))
        self.assertIsNone(ip.format_duration("soon"))

    def test_ids_that_are_not_uuids_never_reach_a_path_or_url(self):
        self.gallery("list")
        self.assertFalse(any("passwd" in str(path) for path in ip.cache_dir().rglob("*")))
        self.assertEqual(self.error("preview", "../../etc/passwd").kind, "usage")
        self.assertEqual(self.error("trash", "abc; rm -rf").kind, "usage")
        self.assertEqual(FakeImmich.writes[1:], [])

    def test_cache_is_private_and_reused(self):
        first = self.gallery("preview", PHOTO)["previews"][PHOTO]
        self.assertEqual(stat.S_IMODE(os.stat(first).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(Path(first).parent).st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(os.stat(ip.cache_dir()).st_mode), 0o700)
        del FakeImmich.routes["/api/assets/%s/thumbnail?size=preview" % PHOTO]
        self.assertEqual(self.gallery("preview", PHOTO)["previews"][PHOTO], first)

    def test_old_previews_are_pruned(self):
        folder = ip.cache_dir() / "previews"
        folder.mkdir(parents=True)
        for number in range(5):
            (folder / ("%d.img" % number)).write_text("x")
            os.utime(folder / ("%d.img" % number), (number, number))
        ip.prune_previews(limit=2)
        self.assertEqual(sorted(entry.name for entry in folder.iterdir()), ["3.img", "4.img"])

    def test_trash_never_deletes_permanently(self):
        self.assertEqual(self.gallery("trash", PHOTO, VIDEO), {"trashed": [PHOTO, VIDEO]})
        self.assertEqual(FakeImmich.writes, [("DELETE", "/api/assets", {"ids": [PHOTO, VIDEO], "force": False})])

    def test_restore_from_trash(self):
        self.gallery("restore", PHOTO)
        self.assertEqual(FakeImmich.writes, [("POST", "/api/trash/restore/assets", {"ids": [PHOTO]})])

    def test_favorite_and_archive(self):
        self.gallery("favorite", "on", PHOTO)
        self.gallery("archive", "on", PHOTO)
        self.gallery("archive", "off", PHOTO)
        self.assertEqual([write[2] for write in FakeImmich.writes], [
            {"isFavorite": True, "ids": [PHOTO]},
            {"visibility": "archive", "ids": [PHOTO]},
            {"visibility": "timeline", "ids": [PHOTO]},
        ])
        self.assertEqual(self.error("favorite", "maybe", PHOTO).kind, "usage")

    def test_albums_sorted_by_name(self):
        self.assertEqual([album["name"] for album in self.gallery("albums")["albums"]], ["alpen", "Urlaub"])

    def test_add_to_album_and_create_album(self):
        self.gallery("album-add", ALBUM, PHOTO, VIDEO)
        self.gallery("album-create", "Neu", PHOTO)
        self.assertEqual(FakeImmich.writes, [
            ("PUT", "/api/albums/%s/assets" % ALBUM, {"ids": [PHOTO, VIDEO]}),
            ("POST", "/api/albums", {"albumName": "Neu", "assetIds": [PHOTO]}),
        ])
        self.assertEqual(self.error("album-add", ALBUM).kind, "usage")
        self.assertEqual(self.error("album-create", " ", PHOTO).kind, "usage")

    def test_missing_permission_names_what_the_key_needs(self):
        FakeImmich.routes["POST /api/search/metadata"] = (403, {"message": "Forbidden"}, False)
        error = self.error("list")
        self.assertEqual(error.kind, "permissions")
        self.assertIn("asset.delete", str(error))

    def test_no_key(self):
        (ip.config_dir() / "api-key").unlink()
        self.assertEqual(self.error("list").kind, "no-key")

    def test_original_must_lie_inside_the_media_folder(self):
        installation = self.installation()
        media = installation.media_path
        (media / "upload").mkdir()
        (media / "upload/clip.mov").write_text("x")
        self.assertEqual(ip.local_original(installation, "/data/upload/clip.mov"), media / "upload/clip.mov")
        self.assertIsNone(ip.local_original(installation, "/data/../../etc/passwd"))
        self.assertIsNone(ip.local_original(installation, "/etc/passwd"))
        self.assertIsNone(ip.local_original(installation, "/data/upload/missing.mov"))


if __name__ == "__main__":
    unittest.main()
