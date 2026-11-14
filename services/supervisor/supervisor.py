"""Babylon supervisor: Python 3.11+, standard library only.

The HTTP API is for trusted BYOND servers, not browsers or player-supplied ckeys.
Run: python services/supervisor/supervisor.py --config <private-config.json>
"""
import argparse
import hashlib
import hmac
import html
import json
import math
import os
from pathlib import Path
import re
import secrets
import shutil
import sqlite3
import subprocess
import threading
import time
import unicodedata
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

from protocol import topic
from checkpoints import Checkpoints, CheckpointError
from map_overlay import prepare_fresh_map
from world_storage import delete_world_data, reset_world_data, tutorial_snapshot_dir
from constants import DEFAULTS, TUTORIAL_KINDS, WORLD_KIND
from tutorials import SCHEMA as TUTORIAL_SCHEMA, GENERATION_RE, TutorialError, TutorialStore, seed_first_save, walk
from catalog import load_catalog, public_catalog
from logstream import Follower, log, world_source


class Denied(ValueError):
    pass


# Link codes avoid look-alike characters (0/O, 1/I) because players type them.
LINK_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
LINK_CODE_SECONDS = 600


def plain_text(value):
    """Game chat text as plain text: tags removed and entities decoded (ahelp relays)."""
    return html.unescape(re.sub(r"<[^>]*>", "", value)).strip()


def clean_text(value, multiline=False):
    """Player-written text (world names, descriptions): no control or bidirectional-override
    characters, which could spoof how a name looks. HTML/Markdown is escaped where it is shown."""
    if multiline:
        value = re.sub(r"\r\n?", "\n", value)
    kept = []
    for char in value:
        if char == "\n" and multiline:
            kept.append(char)
        elif char in "\t\n\r":
            kept.append(" ")
        elif unicodedata.category(char) not in ("Cc", "Cf", "Cs", "Co", "Cn"):
            kept.append(char)
    return "".join(kept).strip()


def link_code_hash(code):
    return hashlib.sha256(re.sub(r"[^A-Z0-9]", "", str(code).upper()).encode()).hexdigest()


def ckey(value):
    return re.sub(r"[^a-z0-9]", "", str(value).lower())


def password_hash(password):
    if not password:
        return None
    salt = secrets.token_hex(16)
    digest = hashlib.scrypt(password.encode(), salt=bytes.fromhex(salt), n=16384, r=8, p=1)
    return salt + ":" + digest.hex()


def password_matches(password, stored):
    if not stored:
        return False
    salt, digest = stored.split(":")
    actual = hashlib.scrypt(password.encode(), salt=bytes.fromhex(salt), n=16384, r=8, p=1)
    return hmac.compare_digest(actual.hex(), digest)


def world_flag(value, name):
    """A boolean from a lobby payload: true/false, 1/0 or "1"/"0"; anything else is refused."""
    if value is True or value == "1" or (type(value) is int and value == 1):
        return 1
    if value is False or value == "0" or (type(value) is int and value == 0):
        return 0
    raise Denied("%s must be on or off" % name)


# Shipped with the repository; used when the configuration names no catalog.
DEFAULT_CATALOG = Path(__file__).resolve().parents[2] / "_maps/babylon/catalog.json"


def merge_missing(source, target):
    """Move files from source into target, never replacing a file target already has."""
    target.mkdir(parents=True, exist_ok=True)
    for entry in source.iterdir():
        destination = target / entry.name
        if entry.is_dir() and not entry.is_symlink() and (destination.is_dir() or not destination.exists()):
            merge_missing(entry, destination)
        elif not destination.exists():
            shutil.move(str(entry), str(destination))


def catalog_path(config):
    if config.get("map_catalog"):
        return Path(config["map_catalog"])
    if config.get("template_directory"):
        return Path(config["template_directory"]) / "_maps/babylon/catalog.json"
    return DEFAULT_CATALOG


def build_of(catalog, map_id):
    """The build (babylon or station) a map runs on; the Babylon builder map has none in the catalog."""
    if map_id == "babylon":
        return "babylon"
    entry = catalog.get(map_id)
    if not entry:
        raise Denied("Unknown map " + str(map_id))
    return entry["build"]


def level_trait_sets(traits):
    """A saved level's z-level traits as tg map jsons have them: one object per z ({"Station": 1, ...}),
    or a list of such objects for a level file holding several z. Returns the list of objects, or None."""
    sets = [traits] if isinstance(traits, dict) else traits
    if not isinstance(sets, list) or not sets:
        return None
    for entry in sets:
        if not isinstance(entry, dict) or not all(isinstance(key, str) for key in entry):
            return None
    return sets


class Driver:
    def __init__(self, config, catalog=None):
        self.config = config
        self.catalog = catalog
        self.processes = {}

    def music_param(self):
        """The server's music folder for the worlds, only if it exists (it is optional)."""
        music = self.config.get("music_directory")
        if music and Path(music).is_dir():
            return {"babylon-music": str(Path(music).resolve())}
        return {}

    @staticmethod
    def field(world, key, default=None):
        """A world column from a dict or sqlite row; older callers may not pass every column."""
        try:
            value = world[key]
        except (KeyError, IndexError):
            return default
        return default if value is None else value

    def loaded_catalog(self):
        # The supervisor passes its catalog in; a bare Driver (tests, tools) loads its own.
        if self.catalog is None:
            self.catalog = load_catalog(catalog_path(self.config))
        return self.catalog

    def catalog_entry(self, map_id):
        entry = self.loaded_catalog().get(map_id)
        if not entry:
            raise Denied("Unknown map " + str(map_id))
        return entry

    def build_of(self, world):
        map_id = self.field(world, "map", "babylon")
        return build_of({} if map_id == "babylon" else self.loaded_catalog(), map_id)

    def data_root(self):
        return Path(self.config["data_directory"]).resolve()

    def restore_source(self, world):
        """The generation or tutorial snapshot directory a world starts from, or None for a fresh map."""
        kind = self.field(world, "kind", WORLD_KIND)
        tutorial = self.field(world, "tutorial", "")
        data = self.data_root()
        if kind in TUTORIAL_KINDS:
            try:
                snapshot = tutorial_snapshot_dir(data, tutorial)
            except ValueError:
                raise Denied("Invalid tutorial id")
            if snapshot:
                return snapshot
            raise Denied("The tutorial snapshot is missing")
        if not self.field(world, "persistent", 1):
            return None
        latest = data / "worlds" / world["id"] / "data/babylon/saves/latest.json"
        if not latest.exists():
            return None
        generation = json.loads(latest.read_text())["generation"]
        if not re.fullmatch(r"save-\d{8}-\d{6}-\d+", generation):
            raise Denied("Invalid checkpoint generation")
        return latest.parent / generation

    def link_player_saves(self, root):
        central = self.data_root() / "player_saves"
        central.mkdir(parents=True, exist_ok=True)
        link = root / "data/player_saves"
        link.parent.mkdir(parents=True, exist_ok=True)
        if link.is_symlink():
            if link.resolve() == central:
                return
            link.unlink()
        elif link.is_dir():
            merge_missing(link, central)
            shutil.rmtree(link)
        elif link.exists():
            link.unlink()
        if os.name == "nt":
            log("player_saves symlink skipped on Windows; characters are not shared")
            link.mkdir(exist_ok=True)
            return
        link.symlink_to(central, target_is_directory=True)

    @staticmethod
    def read_state(source):
        """A saved generation's state.json as a dict; anything unreadable is a clean denial."""
        try:
            state = json.loads((source / "state.json").read_text())
        except (OSError, ValueError):
            raise Denied("The saved state is missing or corrupt")
        if not isinstance(state, dict):
            raise Denied("The saved state is missing or corrupt")
        return state

    def prepare_station(self, world, root, entry, source):
        data = root / "data"
        saved = root / "_maps/babylon/saved"
        resume = data / "babylon/resume-state.json"
        next_map = data / "next_map.json"
        next_map.parent.mkdir(parents=True, exist_ok=True)
        if source is None:
            map_json = root / "_maps" / entry["map_json"]
            if not map_json.is_file():
                raise Denied("The map file %s is missing; generate it first" % entry["map_json"])
            shutil.rmtree(saved, ignore_errors=True)
            next_map.write_text(map_json.read_text(encoding="utf-8"), encoding="utf-8")
            resume.unlink(missing_ok=True)
            return
        state = self.read_state(source)
        levels = state.get("levels")
        config = state.get("map_config")
        if not isinstance(levels, list) or not levels or not isinstance(config, dict):
            raise Denied("The saved state has no level list")
        files, traits = [], []
        for level in levels:
            name = level.get("file") if isinstance(level, dict) else None
            if (not isinstance(name, str) or not re.fullmatch(r"z\d+\.dmm", name)
                    or (source / name).is_symlink() or not (source / name).is_file()):
                raise Denied("The saved state lists an invalid level file")
            level_traits = level_trait_sets(level.get("traits", {}))
            if level_traits is None:
                raise Denied("The saved state lists invalid level traits")
            files.append(name)
            traits.extend(level_traits)
        # Everything is validated; stage the levels aside so a failed copy never leaves saved/ half-cleared.
        staging = saved.with_name("saved.staging")
        shutil.rmtree(staging, ignore_errors=True)
        staging.mkdir(parents=True)
        try:
            for name in files:
                shutil.copy2(source / name, staging / name)
        except OSError:
            shutil.rmtree(staging, ignore_errors=True)
            raise Denied("The saved levels could not be copied")
        shutil.rmtree(saved, ignore_errors=True)
        staging.rename(saved)
        next_map.write_text(json.dumps(dict(config, map_path="babylon/saved", map_file=files, traits=traits)))
        resume.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / "state.json", resume)

    def prepare(self, world, run):
        template = Path(self.config["template_directory"]).resolve()
        root = self.data_root() / "worlds" / world["id"]
        root.mkdir(parents=True, exist_ok=True)
        # Separate mutable assets/config per world. Do not copy source saves, logs or credentials.
        for name in ("_maps", "strings", "icons", "sound", "html", "tgui/public", "build/behavior_trees",
                     "code", "modular_skyrat", "modular_zubbers", "modular_zzplurt"):
            source = template / name
            if source.exists():
                shutil.copytree(source, root / name, dirs_exist_ok=True,
                                ignore=shutil.ignore_patterns("active.dmm", "*.lk", "*.dm", "node_modules"))
        for name in ("babylon.dmb", "babylon.rsc", "babylon-station.dmb", "babylon-station.rsc", "rust_g.dll",
                     "auxlua.dll", "dreamluau.dll", "librust_g.so", "libauxlua.so", "libdreamluau.so"):
            if (template / name).exists():
                shutil.copy2(template / name, root / name)
        build = self.build_of(world)
        if build == "station":
            if not (root / "babylon-station.dmb").is_file():
                raise Denied("Compile babylon-station.dme before starting this map")
            entry = self.catalog_entry(self.field(world, "map", "babylon"))
        elif not (root / "babylon.dmb").is_file():
            raise Denied("Compile babylon.dme before starting worlds")
        config_dir = root / "babylon-config"
        shutil.copytree(self.config["config_directory"], config_dir, dirs_exist_ok=True)
        # Each child has its own native control key; never use the lobby credential.
        (config_dir / "comms.txt").write_text("COMMS_KEY " + run["secret"] + "\n")
        saves = root / "data/babylon"
        saves.mkdir(parents=True, exist_ok=True)
        self.link_player_saves(root)
        source = self.restore_source(world)
        resume = saves / "resume-state.json"
        if build == "station":
            self.prepare_station(world, root, entry, source)
            return root
        active = root / "_maps/babylon/active.dmm"
        active.parent.mkdir(parents=True, exist_ok=True)
        if source is not None:
            self.read_state(source)
            if (source / "map.dmm").is_symlink() or not (source / "map.dmm").is_file():
                raise Denied("The saved snapshot has no map.dmm")
            shutil.copy2(source / "map.dmm", active)
            shutil.copy2(source / "state.json", resume)
        else:
            prepare_fresh_map(template, active)
            resume.unlink(missing_ok=True)
        return root

    def start(self, world, run):
        root = self.prepare(world, run)
        from urllib.parse import urlencode
        build = self.build_of(world)
        params = urlencode({"config-directory": str(root / "babylon-config"),
                            "babylon-owner": world["owner"], "babylon-world": world["id"], "babylon-name": world["name"],
                            "babylon-run": run["id"], "babylon-secret": run["secret"],
                            "babylon-api": f"http://127.0.0.1:{self.config['listen_port']}",
                            "babylon-lobby": self.config["lobby_address"],
                            "babylon-afk-timeout": self.config.get("afk_timeout_seconds", DEFAULTS["afk_timeout_seconds"]),
                            "babylon-build": build,
                            "babylon-persistent": 1 if self.field(world, "persistent", 1) else 0,
                            "babylon-creative": 1 if self.field(world, "creative", 0) else 0,
                            "babylon-kind": self.field(world, "kind", WORLD_KIND),
                            "babylon-tutorial": self.field(world, "tutorial", ""),
                            "babylon-map": self.field(world, "map", "babylon"),
                            **self.music_param(), **self.autosave_param(build)})
        dmb = "babylon-station.dmb" if build == "station" else "babylon.dmb"
        log = open(root / "daemon.log", "ab", buffering=0)
        try:
            process = subprocess.Popen([self.config["dreamdaemon"], dmb, str(run["port"]),
                                        "-ip", self.config.get("bind_address", "127.0.0.1"),
                                        # Worlds only admit lobby tickets: never list them on the BYOND hub.
                                        "-trusted", "-close", "-invisible", "-params", params], cwd=root,
                                       stdout=log, stderr=log,
                                       creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        finally:
            log.close()
        self.processes[run["id"]] = process
        # Mirror the child's own log files into the container log, prefixed.
        Follower(world_source(world), root, lambda: process.poll() is None).start()
        return process.pid

    def autosave_param(self, build):
        """Station worlds autosave less often than Babylon's 15 minutes (a save pauses them longer)."""
        if build != "station":
            return {}
        return {"babylon-autosave-minutes": self.config.get("station_autosave_minutes",
                                                            DEFAULTS["station_autosave_minutes"])}

    def alive(self, run):
        process = self.processes.get(run["id"])
        if process:
            return process.poll() is None
        pid = run["pid"]
        if not pid:
            return False
        if os.name == "nt":
            import ctypes
            from ctypes import wintypes
            kernel = ctypes.WinDLL("kernel32", use_last_error=True)
            kernel.OpenProcess.restype = wintypes.HANDLE
            kernel.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
            kernel.CloseHandle.argtypes = [wintypes.HANDLE]
            handle = kernel.OpenProcess(0x1000, False, pid)
            if not handle:
                return False
            try:
                code = wintypes.DWORD()
                return bool(kernel.GetExitCodeProcess(handle, ctypes.byref(code))) and code.value == 259
            finally:
                kernel.CloseHandle(handle)
        try:
            os.kill(pid, 0)
            # PIDs can be reused after a container restart. A live unrelated
            # process must not keep an old world stuck in the running table.
            command = Path(f"/proc/{pid}/cmdline").read_bytes().decode(errors="replace")
            return ("babylon.dmb" in command or "babylon-station.dmb" in command) and run["id"] in command and run["world"] in command
        except (ProcessLookupError, FileNotFoundError):
            return False

    def status(self, run):
        return topic(run["port"], run["secret"], "status")

    def stop(self, run):
        # The final save of a station world (every level) can take minutes.
        return topic(run["port"], run["secret"], "managed_stop", timeout=600)

    def ahelp_reply(self, run, payload):
        return topic(run["port"], run["secret"], "ahelp_reply", payload)

    def ahelp_close(self, run, payload):
        return topic(run["port"], run["secret"], "ahelp_close", payload)

    def announce(self, run, message):
        return topic(run["port"], run["secret"], "announce", {"message": message})


class Supervisor:
    def __init__(self, config, driver=None, clock=time.time):
        self.config = config
        for key in ("max_total_worlds_per_player", "station_startup_timeout_seconds", "tutorial_submit_cooldown_hours",
                    "station_autosave_minutes"):
            config.setdefault(key, DEFAULTS[key])
        self.clock = clock
        self.lock = threading.RLock()
        self.deletion_lock = threading.Lock()
        # A malformed catalog is a clear error at supervisor start.
        self.catalog = load_catalog(catalog_path(config))
        self.driver = driver or Driver(config, self.catalog)
        self.admins = {ckey(k) for k in config.get("admins", [])}
        Path(config["data_directory"]).mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(Path(config["data_directory"]) / "supervisor.sqlite3", check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.executescript("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS worlds (
              id TEXT PRIMARY KEY, owner TEXT NOT NULL, name TEXT NOT NULL,
              description TEXT NOT NULL, visibility TEXT NOT NULL, password TEXT,
              max_players INTEGER NOT NULL, created REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS members (world TEXT, ckey TEXT, role TEXT,
              PRIMARY KEY(world,ckey));
            CREATE TABLE IF NOT EXISTS runs (
              id TEXT PRIMARY KEY, world TEXT UNIQUE, port INTEGER UNIQUE, secret TEXT,
              pid INTEGER, state TEXT, started REAL, empty_since REAL, error TEXT,
              players TEXT DEFAULT '[]', last_save TEXT);
            CREATE TABLE IF NOT EXISTS tickets (
              hash TEXT PRIMARY KEY, ckey TEXT, world TEXT, run TEXT, expires REAL,
              password_hash TEXT, admin INTEGER);
            CREATE TABLE IF NOT EXISTS sessions (ckey TEXT PRIMARY KEY, world TEXT, run TEXT);
            CREATE TABLE IF NOT EXISTS audit (at REAL, actor TEXT, action TEXT, world TEXT);
            CREATE TABLE IF NOT EXISTS world_deletions (world TEXT PRIMARY KEY);
            CREATE TABLE IF NOT EXISTS discord_links (ckey TEXT PRIMARY KEY, discord_id TEXT UNIQUE NOT NULL,
              discord_name TEXT, linked REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS discord_codes (hash TEXT PRIMARY KEY, ckey TEXT NOT NULL, expires REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS world_bans (world TEXT NOT NULL, ckey TEXT NOT NULL, by TEXT NOT NULL,
              reason TEXT NOT NULL, at REAL NOT NULL, PRIMARY KEY(world, ckey));
        """ + TUTORIAL_SCHEMA)
        columns = {row[1] for row in self.db.execute("PRAGMA table_info(worlds)")}
        if "last_used" not in columns:
            self.db.execute("ALTER TABLE worlds ADD COLUMN last_used REAL")
        for column, definition in (("map", "TEXT NOT NULL DEFAULT 'babylon'"), ("creative", "INTEGER NOT NULL DEFAULT 0"),
                                   ("persistent", "INTEGER NOT NULL DEFAULT 1"), ("kind", "TEXT NOT NULL DEFAULT 'world'"),
                                   ("tutorial", "TEXT"), ("copied_from", "TEXT")):
            if column not in columns:
                self.db.execute("ALTER TABLE worlds ADD COLUMN %s %s" % (column, definition))
        # A world copied from a tutorial remembers it (JSON: id, title, author); submitting such a
        # world again credits the original as based_on.
        if "based_on" not in {row[1] for row in self.db.execute("PRAGMA table_info(tutorials)")}:
            self.db.execute("ALTER TABLE tutorials ADD COLUMN based_on TEXT")
        # Admin tickets may ask to spectate (an observer instead of a drone).
        if "spectate" not in {row[1] for row in self.db.execute("PRAGMA table_info(tickets)")}:
            self.db.execute("ALTER TABLE tickets ADD COLUMN spectate INTEGER DEFAULT 0")
        self.db.execute("UPDATE worlds SET last_used=max(created,coalesce((SELECT max(at) FROM audit WHERE world=worlds.id),created)) WHERE last_used IS NULL")
        self.db.commit()
        self.stop_workers = set()
        self.next_cleanup = 0
        # Set by the Discord bot: membership(discord_id) -> True/False/None (unknown),
        # from its member cache only, because it is called while holding the lock.
        self.discord_membership = None
        # Set by the Discord bot: called with (ckey, discord_id, linked) after a change.
        self.discord_link_changed = None
        # Called with each adminhelp event from a child world (the Discord bot relays them).
        self.ahelp_relay = None
        # Set while the container shuts down: no new worlds or joins, and a notice for the lobby.
        self.shutting_down = False
        self.server_notice = None
        # Players whose lobby has received the restart screen; the container waits for them.
        self.restart_screen_shown = set()
        # Returns how many admins are online on Discord (or None), for the player's ahelp notice.
        self.ahelp_admins_online = None
        self.checkpoints = Checkpoints(config["data_directory"], config.get("kept_save_points_per_world", 4))
        self.tutorials = TutorialStore(config["data_directory"])
        # Set by the Discord bot: called with a submitted tutorial (a dict) to tell the reviewers.
        self.tutorial_notify = None
        self.tutorials.clean_trash()
        # Tutorial instances end with their run. One without a run is left from a supervisor that
        # stopped while it ran; tick's cleanup deletes it.
        with self.db:
            for row in self.db.execute("SELECT id FROM worlds WHERE kind<>? AND id NOT IN (SELECT world FROM runs)",
                                       (WORLD_KIND,)).fetchall():
                self.queue_world_deletion(row[0], "supervisor", "tutorial_instance_ended")
        # Running children are reconciled by tick; stopped worlds have no writers.
        for row in self.db.execute("SELECT id FROM worlds WHERE id NOT IN (SELECT world FROM runs)"):
            self.maintain_checkpoints(row[0])

    def cleanup_unused_worlds(self):
        with self.lock, self.db:
            if self.clock() < self.next_cleanup:
                return
            self.next_cleanup = self.clock() + 3600
            days = self.config.get("delete_unused_worlds_after_days", DEFAULTS["delete_unused_worlds_after_days"])
            if days:
                expired = self.db.execute("SELECT id FROM worlds WHERE last_used<=? AND id NOT IN (SELECT world FROM runs)",
                                          (self.clock() - days * 86400,)).fetchall()
                for row in expired:
                    world = row[0]
                    self.queue_world_deletion(world, "supervisor", "expire_unused_world")
            pending = [row[0] for row in self.db.execute("SELECT world FROM world_deletions")]
        # Deleting runtime assets can take time. Do not hold the admission/database lock.
        for world in pending:
            self.finish_world_deletion(world)

    def queue_world_deletion(self, world, actor, action):
        # Called inside the admission lock/transaction: revoke access and commit
        # the retry journal before any filesystem operation can begin.
        self.db.execute("INSERT OR IGNORE INTO world_deletions VALUES(?)", (world,))
        for table in ("members", "tickets", "sessions", "world_bans"):
            self.db.execute(f"DELETE FROM {table} WHERE world=?", (world,))
        self.db.execute("DELETE FROM worlds WHERE id=?", (world,))
        self.audit(actor, action, world)
        self.checkpoints.maintained.pop(world, None)

    def finish_world_deletion(self, world):
        # Expiry and manual deletion may run concurrently. Serialize file
        # cleanup without holding the database/admission lock.
        with self.deletion_lock:
            try:
                delete_world_data(self.config["data_directory"], world)
            except (OSError, ValueError):
                log(f"World cleanup pending for {world}; will retry")
                return False
            with self.lock, self.db:
                self.db.execute("DELETE FROM world_deletions WHERE world=?", (world,))
        return True

    def delete_world(self, actor, data):
        with self.lock, self.db:
            world = self.world(data.get("world"))
            if self.role(actor, world) not in ("owner", "admin"):
                raise Denied("Only the owner or a server administrator can delete a world")
            if data.get("confirm_delete") not in (True, 1):
                raise Denied("Confirm permanent deletion of this world and all its checkpoints")
            if self.row("SELECT * FROM runs WHERE world=?", (world["id"],)):
                raise Denied("Stop the world before deleting it")
            self.queue_world_deletion(world["id"], actor, "delete_world")
        return {"ok": True, "cleanup_pending": not self.finish_world_deletion(world["id"])}

    def maintain_checkpoints(self, world, expected=None):
        try:
            self.checkpoints.retain(world, expected)
        except (CheckpointError, OSError, ValueError, KeyError):
            # A damaged history must not prevent unrelated worlds from running.
            log(f"Checkpoint maintenance failed for world {world}; history retained for inspection")

    def row(self, sql, args=()):
        result = self.db.execute(sql, args).fetchone()
        return dict(result) if result else None

    def world(self, world_id):
        world = self.row("SELECT * FROM worlds WHERE id=?", (world_id,))
        if not world:
            raise Denied("World does not exist or is unavailable")
        return world

    def role(self, actor, world):
        if actor in self.admins:
            return "admin"
        if actor == world["owner"]:
            return "owner"
        member = self.row("SELECT role FROM members WHERE world=? AND ckey=?", (world["id"], actor))
        return member["role"] if member else "guest"

    def banned(self, world_id, actor):
        """World bans are set by the world's owner and apply to that world only; admins are exempt."""
        return actor not in self.admins and bool(self.row("SELECT 1 FROM world_bans WHERE world=? AND ckey=?", (world_id, actor)))

    WORLD_OPS = ("list", "member_add", "member_remove", "ban", "unban")

    def manage_world(self, run_id, secret, data):
        """An owner (or admin) managing members and bans from inside their running world."""
        with self.lock, self.db:
            run = self.child(run_id, secret)
            world = self.world(run["world"])
            actor = ckey(str(data.get("actor", "")))
            if self.role(actor, world) not in ("owner", "admin"):
                raise Denied("Only the world's owner or a server administrator can manage its players")
            op = data.get("op")
            if op not in self.WORLD_OPS:
                raise Denied("Unknown world action")
            if op == "list":
                members = [r["ckey"] for r in self.db.execute("SELECT ckey FROM members WHERE world=? ORDER BY ckey", (world["id"],))]
                bans = [dict(r) for r in self.db.execute("SELECT ckey, by, reason FROM world_bans WHERE world=? ORDER BY at", (world["id"],))]
                return {"ok": True, "owner": world["owner"], "members": members, "bans": bans}
            target = ckey(str(data.get("target", "")))
            if not target:
                raise Denied("Name a BYOND account")
            if op in ("member_remove", "ban") and (target == world["owner"] or target in self.admins):
                raise Denied("The world's owner and server administrators can't be removed or banned")
            if op == "member_add":
                if target == world["owner"]:
                    raise Denied("The owner is already part of this world")
                if self.banned(world["id"], target):
                    raise Denied("Unban that player first")
                self.db.execute("INSERT OR REPLACE INTO members VALUES(?,?,?)", (world["id"], target, "member"))
            elif op == "member_remove":
                self.db.execute("DELETE FROM members WHERE world=? AND ckey=?", (world["id"], target))
            elif op == "ban":
                reason = clean_text(str(data.get("reason", "")))[:200] or "No reason given"
                self.db.execute("DELETE FROM members WHERE world=? AND ckey=?", (world["id"], target))
                self.db.execute("INSERT OR REPLACE INTO world_bans VALUES(?,?,?,?,?)", (world["id"], target, actor, reason, self.clock()))
            else:
                self.db.execute("DELETE FROM world_bans WHERE world=? AND ckey=?", (world["id"], target))
            if op in ("member_remove", "ban"):
                self.db.execute("DELETE FROM tickets WHERE world=? AND ckey=?", (world["id"], target))
            self.audit(actor, f"{op}:{target}", world["id"])
            return {"ok": True}

    def audit(self, actor, action, world_id):
        self.db.execute("INSERT INTO audit VALUES(?,?,?,?)", (self.clock(), actor, action, world_id))
        log("%s: %s %s" % (actor, action, self.describe(world_id)))

    def describe(self, world_id):
        world = self.row("SELECT id, name FROM worlds WHERE id=?", (world_id,)) if world_id else None
        return world_source(dict(world)).split(" ", 1)[1] if world else (world_id or "")

    def settings(self, data, current=None):
        current = current or {}
        name = clean_text(str(data.get("name", current.get("name", "Babylon"))))
        description = clean_text(str(data.get("description", current.get("description", ""))), multiline=True)
        visibility = data.get("visibility", current.get("visibility", "private"))
        if not 1 <= len(name) <= 60 or len(description) > 500:
            raise Denied("Use a name of 1–60 characters and a description up to 500 characters")
        if visibility not in ("public", "private", "showcase", "password"):
            raise Denied("Invalid visibility")
        maximum = int(data.get("max_players", current.get("max_players", self.config["max_players_per_world"])))
        if not 1 <= maximum <= self.config["max_players_per_world"]:
            raise Denied("Player limit exceeds the server limit")
        password = current.get("password")
        if "password" in data:
            if len(str(data["password"])) > 128:
                raise Denied("Password too long")
            password = password_hash(str(data["password"]))
        if visibility == "password" and not password:
            raise Denied("A password is required")
        return name, description, visibility, password, maximum

    # --- Discord account links -------------------------------------------------

    def discord_settings(self):
        return self.config.get("discord") or {}

    def discord_link(self, account):
        row = self.row("SELECT * FROM discord_links WHERE ckey=?", (ckey(account),))
        return dict(row) if row else None

    def discord_state(self, actor):
        settings = self.discord_settings()
        link = self.discord_link(actor) if settings.get("link") else None
        return {"link": bool(settings.get("link")), "linked": bool(link),
                "name": link["discord_name"] if link else None,
                "require_create": bool(settings.get("require_create")),
                "require_join": bool(settings.get("require_join")),
                "invite": settings.get("invite") or None}

    def require_discord(self, actor, purpose):
        """Raise Denied if the server requires a linked Discord account for purpose."""
        settings = self.discord_settings()
        if not settings.get("require_" + purpose) or actor in self.admins:
            return
        verb = "create" if purpose == "create" else "join"
        link = self.discord_link(actor)
        if not link:
            raise Denied(f"Link your Discord account to {verb} worlds: use Link Discord at the top of the lobby.")
        membership = self.discord_membership
        if membership and membership(link["discord_id"]) is False:
            raise Denied(f"Your linked Discord account is not on our Discord server. Rejoin it to {verb} worlds.")

    def discord_code(self, actor):
        if not self.discord_settings().get("link"):
            raise Denied("Discord linking is not enabled on this server")
        code = "".join(secrets.choice(LINK_ALPHABET) for _ in range(8))
        with self.lock, self.db:
            self.db.execute("DELETE FROM discord_codes WHERE ckey=? OR expires<=?", (actor, self.clock()))
            self.db.execute("INSERT INTO discord_codes VALUES(?,?,?)",
                            (link_code_hash(code), actor, self.clock() + LINK_CODE_SECONDS))
        log(f"{actor}: requested a Discord link code")
        return {"ok": True, "code": code[:4] + "-" + code[4:], "expires_in": LINK_CODE_SECONDS,
                "invite": self.discord_settings().get("invite") or None}

    def redeem_discord_code(self, code, discord_id, discord_name):
        """Called by the bot for /link. Returns the linked ckey."""
        discord_id = str(discord_id)
        if not re.fullmatch(r"\d{5,25}", discord_id):
            raise Denied("Invalid Discord account")
        with self.lock, self.db:
            row = self.row("SELECT * FROM discord_codes WHERE hash=? AND expires>?", (link_code_hash(code), self.clock()))
            if not row:
                raise Denied("This code is invalid or has expired. Get a new one with Link Discord in the lobby.")
            account = row["ckey"]
            previous = self.row("SELECT ckey FROM discord_links WHERE discord_id=? AND ckey<>?", (discord_id, account))
            self.db.execute("DELETE FROM discord_codes WHERE ckey=?", (account,))
            # One Discord account per BYOND account and the other way round.
            self.db.execute("DELETE FROM discord_links WHERE ckey=? OR discord_id=?", (account, discord_id))
            self.db.execute("INSERT INTO discord_links VALUES(?,?,?,?)",
                            (account, discord_id, str(discord_name)[:100], self.clock()))
            self.audit(account, "discord_link", None)
        if previous:
            log(f"{previous['ckey']}: Discord link replaced by {account}")
        self.notify_discord_link(account, discord_id, True)
        return account

    def unlink_discord(self, account=None, discord_id=None):
        """Remove a link by ckey or Discord id. Returns the removed link or None."""
        with self.lock, self.db:
            if account is not None:
                row = self.row("SELECT * FROM discord_links WHERE ckey=?", (ckey(account),))
            else:
                row = self.row("SELECT * FROM discord_links WHERE discord_id=?", (str(discord_id),))
            if not row:
                return None
            row = dict(row)
            self.db.execute("DELETE FROM discord_links WHERE ckey=?", (row["ckey"],))
            self.audit(row["ckey"], "discord_unlink", None)
        self.notify_discord_link(row["ckey"], row["discord_id"], False)
        return row

    def discord_link_by_id(self, discord_id):
        with self.lock:
            row = self.row("SELECT * FROM discord_links WHERE discord_id=?", (str(discord_id),))
        return dict(row) if row else None

    def notify_discord_link(self, account, discord_id, linked):
        callback = self.discord_link_changed
        if callback:
            try:
                callback(account, discord_id, linked)
            except Exception as error:
                log(f"Discord link notification failed: {error}")

    AHELP_KINDS = ("new", "message", "reply", "admin")

    def relay_ahelp(self, run_id, secret, data):
        """An adminhelp event from a child world, authenticated with that run's credentials."""
        with self.lock:
            run = self.child(run_id, secret)
            world = self.world(run["world"])
        kind = data.get("kind")
        if kind not in self.AHELP_KINDS:
            raise Denied("Unknown adminhelp event")
        ticket = str(data.get("ticket") or "")
        event = dict(run=run["id"], world=world["name"] if world else "Unknown world", kind=kind,
                     ticket=int(ticket) if ticket.isdigit() else None, ckey=ckey(str(data.get("ckey", ""))),
                     key=str(data.get("key") or data.get("ckey") or "")[:64],
                     sender=str(data.get("sender") or "")[:64], message=plain_text(str(data.get("message", "")))[:4000])
        log("Adminhelp %s #%s from %s in %s" % (kind, event["ticket"], event["ckey"], event["world"]))
        result = {"ok": True, "relayed": False}
        callback = self.ahelp_relay
        if callback:
            try:
                callback(event)
                result["relayed"] = True
            except Exception as error:
                log(f"Relaying an adminhelp failed: {error}")
        if kind == "new" and self.ahelp_admins_online:
            try:
                online = self.ahelp_admins_online()
                if isinstance(online, int) and online > 0:
                    result["admins_online"] = online
            except Exception as error:
                log(f"Counting online admins failed: {error}")
        return result

    def ahelp_close(self, run_id, ticket, sender):
        """Closes a world's adminhelp ticket from outside the game."""
        with self.lock:
            run = self.row("SELECT * FROM runs WHERE id=?", (run_id,))
        if not run or run["state"] != "running":
            raise Denied("That world is no longer running")
        result = self.driver.ahelp_close(dict(run), {"ticket": int(ticket), "sender": str(sender)[:64]})
        if not result.get("ok"):
            raise Denied(str(result.get("result") or result.get("error") or "The ticket could not be closed"))
        return result

    def ahelp_reply(self, run_id, target, sender, message):
        """A staff reply from outside the game, delivered as an admin PM in that world."""
        message = str(message).strip()
        if not message:
            raise Denied("The reply is empty")
        if message.lower().startswith("ticket "):
            raise Denied("Replies starting with 'ticket ' are read as ticket commands by the game")
        with self.lock:
            run = self.row("SELECT * FROM runs WHERE id=?", (run_id,))
        if not run or run["state"] != "running":
            raise Denied("That world is no longer running")
        result = self.driver.ahelp_reply(dict(run), {"ckey": ckey(target), "sender": str(sender)[:64], "message": message[:1024]})
        if not result.get("ok"):
            raise Denied(str(result.get("result") or result.get("error") or "The reply could not be delivered"))
        return result

    def announce(self, message):
        """A notice in the chat of every running world (shutdown countdown)."""
        with self.lock:
            runs = [dict(r) for r in self.db.execute("SELECT * FROM runs WHERE state='running'")]
        for run in runs:
            try:
                self.driver.announce(run, message)
            except Exception as error:
                log(f"Announcing to {self.describe(run['world'])} failed: {error}")

    def player_keys_in_worlds(self):
        with self.lock:
            return {ckey(p) for r in self.db.execute("SELECT players FROM runs") for p in json.loads(r["players"] or "[]")}

    def status_snapshot(self):
        """Server-wide state for the Discord status message. Private worlds stay anonymous."""
        with self.lock:
            rows = self.db.execute("SELECT w.name, w.visibility, w.max_players, w.owner, r.state, r.players FROM runs r "
                                   "JOIN worlds w ON w.id=r.world ORDER BY r.started").fetchall()
            total = self.row("SELECT count(*) n FROM worlds")["n"]
        worlds = [{"name": row["name"] if row["visibility"] != "private" else None,
                   "visibility": row["visibility"], "state": row["state"], "max_players": row["max_players"],
                   "players": len(json.loads(row["players"] or "[]")), "admin": row["owner"] in self.admins}
                  for row in rows]
        active = [w for w in worlds if w["state"] in ("starting", "running")]
        return {"worlds": worlds, "total_worlds": total, "max_running_worlds": self.config["max_running_worlds"],
                "running_worlds": sum(not w["admin"] for w in active), "admin_worlds": sum(w["admin"] for w in active),
                "players": sum(w["players"] for w in active)}

    def summary(self):
        """Cluster-wide counts for the lobby's hub status; no per-world details."""
        with self.lock:
            runs = self.db.execute("SELECT r.state, r.players, w.owner FROM runs r LEFT JOIN worlds w ON w.id=r.world").fetchall()
        active = [run for run in runs if run["state"] in ("starting", "running")]
        # Admin worlds run outside the limit and are reported separately ("2 running worlds (+1)").
        return {"ok": True, "running_worlds": sum(run["owner"] not in self.admins for run in active),
                "admin_worlds": sum(run["owner"] in self.admins for run in active),
                "players": sum(len(json.loads(run["players"] or "[]")) for run in active)}

    def dispatch(self, actor, action, data):
        if action == "summary":
            return self.summary()
        actor = ckey(actor)
        if not actor or actor.startswith("guest"):
            raise Denied("Sign in with a BYOND account")
        if action == "delete":
            return self.delete_world(actor, data)
        if action == "discord_code":
            return self.discord_code(actor)
        if action == "discord_unlink":
            return {"ok": True, "unlinked": bool(self.unlink_discord(actor))}
        if action in self.TUTORIAL_LOBBY_ACTIONS:
            return self.tutorial_lobby(actor, action, data)
        with self.lock, self.db:
            if action == "list":
                worlds = []
                for item in self.db.execute("SELECT * FROM worlds ORDER BY created DESC").fetchall():
                    world = dict(item)
                    role = self.role(actor, world)
                    if world["visibility"] == "private" and role == "guest":
                        continue
                    # Tutorial instances belong to their player alone.
                    if world["kind"] != WORLD_KIND and role not in ("owner", "admin"):
                        continue
                    run = self.row("SELECT * FROM runs WHERE world=?", (world["id"],))
                    worlds.append({k: world[k] for k in ("id", "owner", "name", "description", "visibility", "max_players",
                                                       "map", "creative", "persistent", "kind")})
                    worlds[-1].update(role=role, state=run["state"] if run else "stopped",
                                      players=len(json.loads(run["players"])) if run else 0,
                                      last_save=run["last_save"] if run else self.last_save(world["id"]),
                                      error=run["error"] if run else None,
                                      last_active=time.strftime("%Y-%m-%d %H:%M", time.localtime(world["last_used"])))
                    # A station round that ended stops its world by itself; the lobby says so.
                    if run and run["state"] == "stopping" and self.row(
                            "SELECT 1 FROM audit WHERE world=? AND action='round_ended' AND at>=?", (world["id"], run["started"])):
                        worlds[-1]["stop_reason"] = "round_ended"
                    # Owners and admins manage members from the lobby, so they see the list.
                    if role in ("owner", "admin"):
                        worlds[-1]["members"] = [r["ckey"] for r in self.db.execute(
                            "SELECT ckey FROM members WHERE world=? ORDER BY ckey", (world["id"],))]
                if self.shutting_down:
                    self.restart_screen_shown.add(actor)
                result = {"ok": True, "worlds": worlds, "maps": public_catalog(self.catalog), "admin": actor in self.admins, "server_notice": self.server_notice,
                        "restarting": self.shutting_down, "discord": self.discord_state(actor),
                        "delete_unused_worlds_after_days": self.config.get("delete_unused_worlds_after_days", DEFAULTS["delete_unused_worlds_after_days"]),
                        "limits": {k: v for k, v in self.config.items() if k.startswith("max_")}}
                # Admins see how many tutorials wait for their review (the lobby's Tutorials tab).
                if actor in self.admins:
                    result["pending_tutorials"] = self.row("SELECT count(*) n FROM tutorials WHERE status='pending'")["n"]
                return result
            if action in ("create", "join") and self.shutting_down:
                raise Denied("The server is restarting. Try again in a minute.")
            if action == "create":
                self.require_discord(actor, "create")
                map_id = data.get("map", "babylon")
                if not isinstance(map_id, str) or map_id not in self.catalog:
                    raise Denied("Unknown map")
                creative = world_flag(data.get("creative", 0), "Creative mode")
                persistent = world_flag(data.get("persistent", 1), "Persistence")
                # Server administrators are not bound by the per-owner limits.
                if actor not in self.admins:
                    self.check_world_limits(actor, persistent)
                fields = self.settings(data)
                world_id = secrets.token_hex(16)
                # Tutorial rows are made by the supervisor itself, never from a payload.
                self.db.execute("INSERT INTO worlds(id,owner,name,description,visibility,password,max_players,created,last_used,map,creative,persistent) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                                (world_id, actor, *fields, self.clock(), self.clock(), map_id, creative, persistent))
                self.audit(actor, action, world_id)
                return {"ok": True, "id": world_id}
            world = self.world(data.get("world"))
            role = self.role(actor, world)
            if action in ("edit", "stop", "member", "checkpoints", "rollback", "reset"):
                if role not in ("owner", "admin"):
                    raise Denied("Only the owner or a server administrator can do that")
                run = self.row("SELECT * FROM runs WHERE world=?", (world["id"],))
                if action in ("checkpoints", "rollback"):
                    if run:
                        raise Denied("Stop the world before browsing or restoring checkpoints")
                    try:
                        self.checkpoints.retain(world["id"])
                        if action == "checkpoints":
                            return {"ok": True, **self.checkpoints.list(world["id"])}
                        if data.get("confirm_delete_newer") not in (True, 1):
                            raise Denied("Confirm that all newer checkpoints will be permanently deleted")
                        result = self.checkpoints.rollback(world["id"], data.get("generation"), data.get("expected_latest"))
                    except CheckpointError as error:
                        raise Denied(str(error)) from None
                    self.db.execute("DELETE FROM tickets WHERE world=?", (world["id"],))
                    self.db.execute("UPDATE worlds SET last_used=? WHERE id=?", (self.clock(), world["id"]))
                    self.audit(actor, "rollback:" + result["generation"], world["id"])
                    return result
                elif action == "reset":
                    if data.get("confirm") not in (True, 1, "1"):
                        raise Denied("Confirm that all saves of this world will be permanently deleted")
                    if run:
                        raise Denied("Stop the world before resetting it")
                    try:
                        reset_world_data(Path(self.config["data_directory"]) / "worlds" / world["id"])
                    except (OSError, ValueError) as error:
                        log("Resetting %s failed: %s" % (self.describe(world["id"]), error))
                        raise Denied("The world's data could not be reset") from None
                    self.db.execute("DELETE FROM tickets WHERE world=?", (world["id"],))
                elif action == "edit":
                    # Every setting, the creative/persistent flags included, needs a stopped world.
                    if run:
                        raise Denied("Stop the world before editing its settings")
                    fields = self.settings(data, world)
                    creative = world_flag(data.get("creative", world["creative"]), "Creative mode")
                    persistent = world_flag(data.get("persistent", world["persistent"]), "Persistence")
                    if persistent and not world["persistent"] and actor not in self.admins:
                        self.check_world_limits(world["owner"], 1, ignore=world["id"])
                    # The map and kind are fixed at creation.
                    self.db.execute("UPDATE worlds SET name=?,description=?,visibility=?,password=?,max_players=?,creative=?,persistent=? WHERE id=?",
                                    (*fields, creative, persistent, world["id"]))
                    self.db.execute("DELETE FROM tickets WHERE world=?", (world["id"],))
                elif action == "member":
                    who = ckey(data.get("member", ""))
                    member_role = data.get("role", "member")
                    if not who or who == world["owner"] or member_role not in ("member", "remove"):
                        raise Denied("Invalid membership change")
                    self.db.execute("DELETE FROM members WHERE world=? AND ckey=?", (world["id"], who))
                    if member_role == "member":
                        self.db.execute("INSERT INTO members VALUES(?,?,?)", (world["id"], who, "member"))
                    self.db.execute("DELETE FROM tickets WHERE world=? AND ckey=?", (world["id"], who))
                else:
                    if run:
                        self.begin_stop(run)
                self.audit(actor, action, world["id"])
                self.db.execute("UPDATE worlds SET last_used=? WHERE id=?", (self.clock(), world["id"]))
                return {"ok": True}
            if action != "join":
                raise Denied("Unknown action")
            self.require_discord(actor, "join")
            spectate = data.get("spectate") in (True, 1, "1", "true")
            if spectate and role != "admin":
                raise Denied("Only server administrators can spectate")
            if self.banned(world["id"], actor):
                raise Denied("You are banned from this world")
            authorized = role != "guest" or world["visibility"] in ("public", "showcase")
            if not authorized and world["visibility"] == "password":
                authorized = password_matches(str(data.get("password", "")), world["password"])
            if not authorized:
                raise Denied("This world is private or the password is incorrect")
            run = self.row("SELECT * FROM runs WHERE world=?", (world["id"],))
            if not run:
                if role == "guest":
                    raise Denied("This world is offline. Only its owner, members or a server administrator can start it")
                self.start(world, actor)
                return {"ok": True, "pending": True}
            if run["state"] == "starting":
                return {"ok": True, "pending": True}
            if run["state"] != "running":
                raise Denied(run["error"] or "World is stopping; try again shortly")
            players = set(json.loads(run["players"]))
            players.update(r[0] for r in self.db.execute("SELECT ckey FROM sessions WHERE run=?", (run["id"],)))
            # A player's current ticket can be replaced without reserving another slot.
            self.db.execute("DELETE FROM tickets WHERE ckey=? OR expires<=?", (actor, self.clock()))
            reserved = self.row("SELECT count(*) n FROM tickets WHERE run=? AND ckey NOT IN (SELECT ckey FROM sessions WHERE run=?)",
                                (run["id"], run["id"]))["n"]
            if actor not in players and len(players) + reserved >= world["max_players"] and role != "admin":
                raise Denied("World is full")
            token = secrets.token_urlsafe(32)
            self.db.execute("INSERT INTO tickets(hash,ckey,world,run,expires,password_hash,admin,spectate) VALUES(?,?,?,?,?,?,?,?)",
                            (hashlib.sha256(token.encode()).hexdigest(), actor, world["id"], run["id"],
                             self.clock() + self.config["ticket_lifetime_seconds"], world["password"], role == "admin", spectate))
            self.db.execute("UPDATE runs SET empty_since=NULL WHERE id=?", (run["id"],))
            self.audit(actor, "ticket", world["id"])
            return {"ok": True, "address": f"byond://{self.config['public_host']}:{run['port']}?babylon_ticket={token}"}

    # --- Tutorials -------------------------------------------------------------------
    # Submitted from a running creative station world (child actions), reviewed by admins and played
    # or copied by everyone from the lobby. Storage: tutorials.py.

    TUTORIAL_LOBBY_ACTIONS = ("tutorials", "tutorial_play", "tutorial_copy", "tutorial_edit", "tutorial_accept",
                              "tutorial_reject", "tutorial_delete")

    @staticmethod
    def duration(seconds):
        """3 h 20 min as "3 hours 20 minutes"; below a minute "less than a minute"."""
        minutes = math.ceil(seconds / 60)
        hours, minutes = divmod(minutes, 60)
        parts = ["%d hour%s" % (hours, "" if hours == 1 else "s")] if hours else []
        if minutes:
            parts.append("%d minute%s" % (minutes, "" if minutes == 1 else "s"))
        return " ".join(parts) or "less than a minute"

    def tutorial_row(self, tid):
        row = self.row("SELECT * FROM tutorials WHERE id=?", (tid,)) if isinstance(tid, str) else None
        if not row:
            raise Denied("This tutorial does not exist or is no longer available")
        return row

    def tutorial_capable(self, world):
        """Tutorials come from normal creative worlds on the station build (spec 10)."""
        if world["kind"] != WORLD_KIND:
            raise Denied("A tutorial can't be submitted from a tutorial run")
        try:
            station = build_of(self.catalog, world["map"]) == "station"
        except Denied:
            station = False
        if not station or not world["creative"]:
            raise Denied("Tutorials can only be submitted from a Creative world on a station map "
                         "(a Creative Plane or a station). Babylon worlds can build, but not submit.")

    def submit_wait(self, author):
        """Seconds until ``author`` may submit another tutorial (0: now)."""
        hours = self.config.get("tutorial_submit_cooldown_hours", DEFAULTS["tutorial_submit_cooldown_hours"])
        row = self.row("SELECT submitted FROM tutorial_cooldowns WHERE author=?", (author,))
        if not hours or not row:
            return 0
        return max(0, math.ceil(row["submitted"] + hours * 3600 - self.clock()))

    def submitter(self, run_id, secret, data):
        """The run's world and the in-world actor, who must own it. Call under the lock."""
        run = self.child(run_id, secret)
        world = self.world(run["world"])
        actor = ckey(str(data.get("actor", "")))
        if not actor or actor != world["owner"]:
            raise Denied("Only the world's owner can submit it as a tutorial")
        self.tutorial_capable(world)
        return world, actor

    def generation_source(self, world_id, generation):
        """The checkpoint directory worlds/<world>/data/babylon/saves/<generation>, with no link on the way."""
        if not isinstance(generation, str) or not GENERATION_RE.fullmatch(generation):
            raise Denied("Invalid checkpoint generation")
        try:
            source = walk(Path(self.config["data_directory"]).resolve(), "worlds", world_id, "data", "babylon",
                          "saves", generation)
        except TutorialError:
            raise Denied("The saved snapshot is not usable") from None
        if not source.is_dir():
            raise Denied("The saved snapshot %s does not exist" % generation)
        return source

    def tutorial_submit_check(self, run_id, secret, data):
        """Whether the world's owner may submit now: {ok, wait_seconds}; refused for worlds that can't."""
        with self.lock, self.db:
            world, actor = self.submitter(run_id, secret, data)
            return {"ok": True, "wait_seconds": self.submit_wait(actor)}

    def tutorial_submit(self, run_id, secret, data):
        """Copies a snapshot generation of the world into pending/<id>/ for review.

        The cooldown starts only once the tutorial is stored: a failed copy can be retried at once."""
        with self.lock, self.db:
            world, actor = self.submitter(run_id, secret, data)
            title = clean_text(str(data.get("title", "")))
            description = clean_text(str(data.get("description", "")), multiline=True)
            if not 1 <= len(title) <= 60 or len(description) > 500:
                raise Denied("Use a title of 1–60 characters and a description up to 500 characters")
            wait = self.submit_wait(actor)
            if wait:
                raise Denied("You can submit another tutorial in %s" % self.duration(wait))
            source = self.generation_source(world["id"], data.get("generation"))
            tid = secrets.token_hex(16)
            now = self.clock()
            tutorial = dict(id=tid, title=title, description=description, author=actor, status="pending",
                            map=world["map"], build=build_of(self.catalog, world["map"]), created=now, updated=now,
                            reviewed_by=None, source_world=world["id"], based_on=world.get("copied_from"))
            try:
                self.tutorials.create_pending(tid, source, dict(tutorial, generation=data["generation"],
                                                                based_on=self.based_on(tutorial)))
            except (OSError, TutorialError) as error:
                log("Storing the tutorial from %s failed: %s" % (self.describe(world["id"]), error))
                raise Denied("The tutorial could not be stored: %s" % (
                    error if isinstance(error, TutorialError) else "the save could not be copied")) from None
            try:
                self.db.execute("INSERT INTO tutorials(id,title,description,author,status,map,build,created,updated,reviewed_by,source_world,based_on)"
                                " VALUES(:id,:title,:description,:author,:status,:map,:build,:created,:updated,:reviewed_by,:source_world,:based_on)",
                                tutorial)
                self.db.execute("INSERT OR REPLACE INTO tutorial_cooldowns VALUES(?,?)", (actor, now))
                self.audit(actor, "tutorial_submit:" + tid, world["id"])
            except Exception:
                self.tutorials.remove("pending", tid)
                raise
        self.notify_tutorial(tutorial)
        return {"ok": True, "tutorial": tid}

    @staticmethod
    def based_on(row):
        """The tutorial a world (copied_from) or tutorial (based_on) was copied from: {id, title, author} or None."""
        try:
            value = json.loads(row.get("based_on") or row.get("copied_from") or "null")
        except (TypeError, ValueError):
            return None
        if not isinstance(value, dict) or not all(isinstance(value.get(k), str) for k in ("id", "title", "author")):
            return None
        return {k: value[k] for k in ("id", "title", "author")}

    def notify_tutorial(self, tutorial):
        log("Tutorial submitted for review: %s by %s (%s)" % (tutorial["title"], tutorial["author"], tutorial["id"]))
        callback = self.tutorial_notify
        if callback:
            try:
                callback(dict(tutorial, map_name=self.catalog.get(tutorial["map"], {}).get("name", tutorial["map"])))
            except Exception as error:
                log(f"Telling the reviewers about a tutorial failed: {error}")

    def tutorial_save_back(self, run_id, secret, data):
        """An admin in an edit world overwrites the pending tutorial's snapshot with a new generation."""
        with self.lock, self.db:
            run = self.child(run_id, secret)
            world = self.world(run["world"])
            if world["kind"] != "tutorial_edit":
                raise Denied("Only a world that edits a pending tutorial can save back to it")
            actor = ckey(str(data.get("actor", "")))
            if actor not in self.admins:
                raise Denied("Only server administrators can save back to a pending tutorial")
            tutorial = self.tutorial_row(world["tutorial"])
            if tutorial["status"] != "pending":
                raise Denied("This tutorial is no longer pending, so it can't be changed from here")
            source = self.generation_source(world["id"], data.get("generation"))
            try:
                self.tutorials.replace_save(tutorial["id"], source)
                self.tutorials.update_meta("pending", tutorial["id"], updated=self.clock(), generation=data["generation"])
            except (OSError, TutorialError) as error:
                log("Saving back tutorial %s failed: %s" % (tutorial["id"], error))
                raise Denied("The tutorial could not be saved back; the pending copy is unchanged") from None
            self.db.execute("UPDATE tutorials SET updated=? WHERE id=?", (self.clock(), tutorial["id"]))
            self.audit(actor, "tutorial_save_back:" + tutorial["id"], world["id"])
            return {"ok": True, "tutorial": tutorial["id"]}

    def tutorial_list(self, actor):
        admin = actor in self.admins
        # The player's own play instances and every edit world, with their run states, in one query.
        playing, editing = {}, {}
        for run in self.db.execute("SELECT w.kind, w.owner, w.tutorial, r.state FROM worlds w JOIN runs r ON r.world=w.id "
                                   "WHERE w.kind='tutorial_edit' OR (w.kind='tutorial' AND w.owner=?)", (actor,)):
            (editing if run["kind"] == "tutorial_edit" else playing)[run["tutorial"]] = run["state"]
        items = []
        for row in self.db.execute("SELECT * FROM tutorials ORDER BY created DESC").fetchall():
            if row["status"] != "published" and not admin:
                continue
            item = {key: row[key] for key in ("id", "title", "description", "author", "map", "status", "created", "updated")}
            item["map_name"] = self.catalog.get(row["map"], {}).get("name", row["map"])
            # The state of the player's own copy of it, so the lobby can say "Rejoin".
            item["playing"] = playing.get(row["id"])
            if admin:
                item["editing"] = editing.get(row["id"])
                item["based_on"] = self.based_on(dict(row))
            items.append(item)
        return items

    def tutorial_lobby(self, actor, action, data):
        """The lobby's tutorial actions: list, play, copy, and the admins' review."""
        admin = actor in self.admins
        cleanup = []
        try:
            with self.lock, self.db:
                if action == "tutorials":
                    return {"ok": True, "tutorials": self.tutorial_list(actor), "admin": admin}
                if action in ("tutorial_play", "tutorial_copy", "tutorial_edit") and self.shutting_down:
                    raise Denied("The server is restarting. Try again in a minute.")
                tutorial = self.tutorial_row(data.get("tutorial"))
                pending = tutorial["status"] == "pending"
                if pending and not admin:
                    # Pending tutorials are invisible to players.
                    raise Denied("This tutorial does not exist or is no longer available")
                if action == "tutorial_play":
                    return self.play_tutorial(actor, tutorial, cleanup)
                if action == "tutorial_copy":
                    if pending:
                        raise Denied("Only published tutorials can be copied")
                    return self.copy_tutorial(actor, tutorial)
                if not admin:
                    raise Denied("Only server administrators can review tutorials")
                if action == "tutorial_edit":
                    if not pending:
                        raise Denied("Only pending tutorials can be edited")
                    return self.edit_tutorial(actor, tutorial, cleanup)
                if action in ("tutorial_reject", "tutorial_delete") and data.get("confirm") not in (True, 1, "1"):
                    raise Denied("Confirm that the tutorial will be permanently deleted")
                if action == "tutorial_accept":
                    if not pending:
                        raise Denied("This tutorial is already published")
                    try:
                        self.tutorials.publish(tutorial["id"])
                    except (OSError, TutorialError) as error:
                        log("Publishing tutorial %s failed: %s" % (tutorial["id"], error))
                        raise Denied("The tutorial could not be published") from None
                    try:
                        self.db.execute("UPDATE tutorials SET status='published',reviewed_by=?,updated=? WHERE id=?",
                                        (actor, self.clock(), tutorial["id"]))
                    except Exception:
                        # The row stays pending (rolled back), so its files go back to pending too.
                        self.tutorials.unpublish(tutorial["id"])
                        raise
                elif action == "tutorial_reject" and not pending:
                    raise Denied("Only pending tutorials can be rejected; delete a published one instead")
                else:
                    # Running play or edit instances keep going: their world was prepared from a copy.
                    self.db.execute("DELETE FROM tutorials WHERE id=?", (tutorial["id"],))
                    try:
                        self.tutorials.remove(tutorial["status"], tutorial["id"])
                    except (OSError, TutorialError) as error:
                        log("Removing the files of tutorial %s failed: %s" % (tutorial["id"], error))
                self.audit(actor, "%s:%s" % (action, tutorial["id"]), None)
                return {"ok": True, "title": tutorial["title"]}
        finally:
            for world in cleanup:
                self.finish_world_deletion(world)

    def tutorial_instance(self, owner, kind, tutorial, name, creative, max_players):
        world = dict(id=secrets.token_hex(16), owner=owner, name=clean_text(name)[:60] or "Tutorial",
                     description=tutorial["description"], visibility="private", password=None, max_players=max_players,
                     created=self.clock(), last_used=self.clock(), map=tutorial["map"], creative=creative, persistent=0,
                     kind=kind, tutorial=tutorial["id"])
        self.db.execute("INSERT INTO worlds(id,owner,name,description,visibility,password,max_players,created,last_used,map,"
                        "creative,persistent,kind,tutorial) VALUES(:id,:owner,:name,:description,:visibility,:password,"
                        ":max_players,:created,:last_used,:map,:creative,:persistent,:kind,:tutorial)", world)
        return world

    def start_instance(self, world, actor, cleanup):
        """Starts a tutorial instance; one that can't start is deleted again (row and files)."""
        try:
            self.start(world, actor)
        except Denied:
            self.queue_world_deletion(world["id"], "supervisor", "tutorial_instance_failed")
            self.db.commit()
            cleanup.append(world["id"])
            raise
        self.audit(actor, "tutorial_instance:" + world["tutorial"], world["id"])
        return {"ok": True, "world": world["id"], "name": world["name"], "pending": True}

    def stale_instance(self, world, cleanup):
        """A tutorial instance without a run is left over (its start failed half-way): delete it.
        Committed at once, so a later refusal in the same request does not bring it back."""
        self.queue_world_deletion(world["id"], "supervisor", "tutorial_instance_ended")
        self.db.commit()
        cleanup.append(world["id"])

    def play_tutorial(self, actor, tutorial, cleanup):
        """A private, unsaved instance for the player. Their running one is reused for the same
        tutorial; a different tutorial waits until that one has ended."""
        self.require_discord(actor, "join")
        if tutorial["map"] not in self.catalog:
            raise Denied("This tutorial's map is no longer available")
        for world in [dict(r) for r in self.db.execute("SELECT * FROM worlds WHERE kind='tutorial' AND owner=?", (actor,))]:
            run = self.row("SELECT state FROM runs WHERE world=?", (world["id"],))
            if not run:
                self.stale_instance(world, cleanup)
            elif run["state"] == "error":
                raise Denied("Your tutorial \"%s\" ran into a problem. Stop it under My worlds, then press Play again."
                             % world["name"])
            elif world["tutorial"] != tutorial["id"]:
                raise Denied("Finish or leave your current tutorial first")
            elif run["state"] in ("starting", "running"):
                return {"ok": True, "world": world["id"], "name": world["name"], "pending": run["state"] == "starting",
                        "reused": True}
            else:
                raise Denied("Your last run of this tutorial is still ending. Try again in a moment.")
        world = self.tutorial_instance(actor, "tutorial", tutorial, tutorial["title"], 0, 1)
        return self.start_instance(world, actor, cleanup)

    def edit_tutorial(self, actor, tutorial, cleanup):
        """An admin-owned creative world started from the pending snapshot. There is one per tutorial,
        so two admins never save back over each other; others join the running one."""
        if tutorial["map"] not in self.catalog:
            raise Denied("This tutorial's map is no longer available")
        for world in [dict(r) for r in self.db.execute("SELECT * FROM worlds WHERE kind='tutorial_edit' AND tutorial=?",
                                                       (tutorial["id"],))]:
            run = self.row("SELECT state FROM runs WHERE world=?", (world["id"],))
            if not run:
                self.stale_instance(world, cleanup)
            elif run["state"] in ("starting", "running"):
                return {"ok": True, "world": world["id"], "name": world["name"], "pending": run["state"] == "starting",
                        "reused": True}
            else:
                raise Denied("The last edit session of this tutorial is still ending. Try again in a moment.")
        world = self.tutorial_instance(actor, "tutorial_edit", tutorial, "Editing: " + tutorial["title"], 1,
                                       self.config["max_players_per_world"])
        return self.start_instance(world, actor, cleanup)

    def copy_tutorial(self, actor, tutorial):
        """A new creative, saved world of the player's own whose first checkpoint is the tutorial."""
        self.require_discord(actor, "create")
        if tutorial["map"] not in self.catalog:
            raise Denied("This tutorial's map is no longer available")
        if actor not in self.admins:
            self.check_world_limits(actor, 1)
        try:
            snapshot = self.tutorials.directory("published", tutorial["id"]) / "save"
            if not snapshot.is_dir() or snapshot.is_symlink():
                raise TutorialError("The tutorial's snapshot is missing")
        except TutorialError as error:
            raise Denied(str(error)) from None
        world_id = secrets.token_hex(16)
        root = Path(self.config["data_directory"]) / "worlds" / world_id
        try:
            seed_first_save(snapshot, root / "data/babylon/saves")
        except (OSError, TutorialError) as error:
            log("Copying tutorial %s failed: %s" % (tutorial["id"], error))
            shutil.rmtree(root, ignore_errors=True)
            raise Denied("The tutorial could not be copied") from None
        name = clean_text(tutorial["title"])[:60] or "Tutorial copy"
        copied_from = json.dumps({k: tutorial[k] for k in ("id", "title", "author")})
        try:
            self.db.execute("INSERT INTO worlds(id,owner,name,description,visibility,password,max_players,created,last_used,map,"
                            "creative,persistent,copied_from) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                            (world_id, actor, name, tutorial["description"], "private", None, self.config["max_players_per_world"],
                             self.clock(), self.clock(), tutorial["map"], 1, 1, copied_from))
            self.audit(actor, "tutorial_copy:" + tutorial["id"], world_id)
        except Exception:
            # The row is rolled back; its seeded files must not stay behind without it.
            shutil.rmtree(root, ignore_errors=True)
            raise
        return {"ok": True, "id": world_id, "name": name}

    def check_world_limits(self, owner, persistent, ignore=None):
        """Persistent worlds count against max_worlds_per_player, all normal worlds against the total."""
        rows = self.db.execute("SELECT persistent FROM worlds WHERE owner=? AND kind='world' AND id IS NOT ?",
                               (owner, ignore)).fetchall()
        if persistent and sum(r[0] == 1 for r in rows) >= self.config["max_worlds_per_player"]:
            raise Denied("Your world limit has been reached")
        if len(rows) >= self.config.get("max_total_worlds_per_player", DEFAULTS["max_total_worlds_per_player"]):
            raise Denied("Your total world limit has been reached")

    def last_save(self, world_id):
        path = Path(self.config["data_directory"]) / "worlds" / world_id / "data/babylon/saves/latest.json"
        try:
            return json.loads(path.read_text())["generation"]
        except (FileNotFoundError, ValueError, KeyError):
            return None

    def start(self, world, actor=None):
        # Finish any interrupted rollback before a child can read its startup files.
        try:
            self.checkpoints.retain(world["id"])
        except CheckpointError as error:
            raise Denied(str(error)) from None
        if world["map"] not in self.catalog:
            raise Denied("This world's map is no longer available")
        runs = [dict(r) for r in self.db.execute("SELECT r.*, w.owner FROM runs r LEFT JOIN worlds w ON w.id=r.world")]
        # Admin worlds run outside the limit; they only need a free port.
        if world["owner"] not in self.admins and sum(r["owner"] not in self.admins for r in runs) >= self.config["max_running_worlds"]:
            raise Denied("The server's running-world limit has been reached")
        owned = self.row("SELECT count(*) n FROM runs r JOIN worlds w ON w.id=r.world WHERE w.owner=?", (world["owner"],))["n"]
        # The per-owner limit binds neither admin-owned worlds nor worlds an administrator starts.
        exempt = world["owner"] in self.admins or actor in self.admins
        if not exempt and owned >= self.config["max_running_worlds_per_player"]:
            raise Denied("This owner's running-world limit has been reached")
        ports = {r["port"] for r in runs}
        port = next((p for p in range(self.config["port_first"], self.config["port_last"] + 1) if p not in ports), None)
        if port is None:
            raise Denied("No child port is available")
        run = dict(id=secrets.token_hex(16), world=world["id"], port=port,
                   secret=secrets.token_urlsafe(32), state="starting", started=self.clock(), pid=None)
        self.db.execute("INSERT INTO runs(id,world,port,secret,state,started) VALUES(:id,:world,:port,:secret,:state,:started)", run)
        self.db.execute("UPDATE worlds SET last_used=? WHERE id=?", (self.clock(), world["id"]))
        # Commit the launch intent before starting a child so supervisor restarts can reconcile it.
        self.db.commit()
        try:
            pid = self.driver.start(world, run)
            self.db.execute("UPDATE runs SET pid=? WHERE id=?", (pid, run["id"]))
            log("Starting %s on port %s (pid %s)" % (self.describe(world["id"]), port, pid))
        except Exception as error:
            log("Starting %s failed: %s" % (self.describe(world["id"]), error))
            self.db.execute("DELETE FROM runs WHERE id=?", (run["id"],))
            self.db.commit()
            raise Denied("Child startup failed; check the supervisor and daemon logs")

    def child(self, run_id, secret):
        run = self.row("SELECT * FROM runs WHERE id=?", (run_id,))
        if not run or not hmac.compare_digest(str(secret), run["secret"]):
            raise Denied("Invalid child credentials")
        return run

    def redeem(self, run_id, secret, token, actor):
        with self.lock, self.db:
            run = self.child(run_id, secret)
            ticket = self.row("SELECT * FROM tickets WHERE hash=?", (hashlib.sha256(token.encode()).hexdigest(),))
            if not ticket or ticket["run"] != run_id or ticket["world"] != run["world"] or ticket["ckey"] != ckey(actor) or ticket["expires"] <= self.clock() or run["state"] != "running":
                raise Denied("Admission expired or invalid; reconnect through the lobby")
            world = self.world(run["world"])
            role = self.role(ckey(actor), world)
            if self.banned(world["id"], ckey(actor)):
                raise Denied("You are banned from this world")
            if role == "guest" and world["visibility"] not in ("public", "showcase") and not (world["visibility"] == "password" and ticket["password_hash"] == world["password"]):
                raise Denied("Access has changed")
            players = set(json.loads(run["players"]))
            sessions = {r[0] for r in self.db.execute("SELECT ckey FROM sessions WHERE run=?", (run_id,))}
            if ckey(actor) not in players | sessions and len(players | sessions) >= world["max_players"] and role != "admin":
                raise Denied("World is full")
            self.db.execute("DELETE FROM tickets WHERE hash=?", (ticket["hash"],))
            self.db.execute("INSERT OR REPLACE INTO sessions VALUES(?,?,?)", (ckey(actor), world["id"], run_id))
            self.db.execute("UPDATE worlds SET last_used=? WHERE id=?", (self.clock(), world["id"]))
            self.db.execute("UPDATE runs SET empty_since=NULL WHERE id=?", (run_id,))
            self.audit(ckey(actor), "admit", world["id"])
            if role == "guest" and world["visibility"] == "showcase":
                mode = "showcase"
            elif role == "admin" and ticket["spectate"]:
                mode = "spectator"  # Checked again here: admin rights may have ended since the join.
            else:
                mode = "player"
            return {"ok": True, "world": world["id"], "run": run_id, "role": role, "mode": mode}

    def round_ended(self, run_id, secret):
        """A station world whose round is over stops itself without a save (it returns its players
        to the lobby and exits once the round-end report has been read). The run is marked as
        stopping, so no one is admitted any more and its process exit is an ordinary stop."""
        with self.lock, self.db:
            run = self.child(run_id, secret)
            if run["state"] == "stopping":
                return {"ok": True}
            self.db.execute("UPDATE runs SET state='stopping',error=NULL WHERE id=?", (run["id"],))
            self.db.execute("DELETE FROM tickets WHERE run=?", (run["id"],))
            # Logged as "world: round_ended <world>"; its process exit is then logged as stopped.
            self.audit("world", "round_ended", run["world"])
            return {"ok": True}

    def begin_stop(self, run):
        if run["id"] in self.stop_workers:
            return
        self.stop_workers.add(run["id"])
        world = self.row("SELECT persistent, kind FROM worlds WHERE id=?", (run["world"],))
        saved = bool(world) and world["persistent"] and world["kind"] not in TUTORIAL_KINDS
        log("Stopping %s (port %s): %s" % (self.describe(run["world"]), run["port"], "saving" if saved else "not saved"))
        self.db.execute("UPDATE runs SET state='stopping',error=NULL WHERE id=?", (run["id"],))
        self.db.execute("DELETE FROM tickets WHERE run=?", (run["id"],))
        self.db.commit()

        def stop():
            try:
                response = self.driver.stop(run)
                if not response.get("ok"):
                    raise Denied("Final save failed; child has been kept alive")
            except Exception as error:
                log("Stopping %s failed, process retained: %s" % (self.describe(run["world"]), error))
                with self.lock, self.db:
                    self.db.execute("UPDATE runs SET state='error',error=? WHERE id=?",
                                    ("Stop/save failed; process retained. Inspect logs and retry Stop.", run["id"]))
            finally:
                with self.lock:
                    self.stop_workers.discard(run["id"])
        threading.Thread(target=stop, daemon=True).start()

    def startup_timeout(self, run):
        """Seconds a starting child may take: station maps (tg rounds, several levels) load far longer."""
        with self.lock:
            world = self.row("SELECT * FROM worlds WHERE id=?", (run["world"],))
        try:
            station = world is not None and build_of(self.catalog, world["map"]) == "station"
        except Denied:
            station = False
        if station:
            return max(self.config["startup_timeout_seconds"], self.config["station_startup_timeout_seconds"])
        return self.config["startup_timeout_seconds"]

    def on_run_exited(self, run):
        """The single place a run's end is handled: its process is gone (a stop, a round end or a crash).

        Drops the run with its tickets and sessions and refreshes the world's checkpoints. A tutorial
        instance (play or edit) is deleted with its files: it only lives while it runs. Anything that
        must happen once a world instance has ended belongs here."""
        if run["state"] == "stopping":
            log("%s stopped (port %s)" % (self.describe(run["world"]), run["port"]))
        else:
            log("%s exited (port %s)" % (self.describe(run["world"]), run["port"]))
        with self.lock, self.db:
            self.db.execute("DELETE FROM runs WHERE id=?", (run["id"],))
            self.db.execute("DELETE FROM tickets WHERE run=?", (run["id"],))
            self.db.execute("DELETE FROM sessions WHERE run=?", (run["id"],))
            world = self.row("SELECT kind FROM worlds WHERE id=?", (run["world"],))
            instance = bool(world) and world["kind"] in TUTORIAL_KINDS
            if instance:
                self.queue_world_deletion(run["world"], "supervisor", "tutorial_instance_ended")
            else:
                self.maintain_checkpoints(run["world"])
        if instance:
            # The files can take a moment; never under the lock. A failure is retried by cleanup.
            self.finish_world_deletion(run["world"])

    def tick(self):
        self.cleanup_unused_worlds()
        # Never hold the DB lock during network requests: a child may be redeeming a ticket.
        with self.lock:
            runs = [dict(r) for r in self.db.execute("SELECT * FROM runs")]
        for run in runs:
            try:
                status = self.driver.status(run)
                if status.get("run") != run["id"] or status.get("world") != run["world"]:
                    raise Denied("Child identity mismatch")
            except Exception:
                if self.driver.alive(run) or not run["pid"]:
                    timeout = self.startup_timeout(run)
                    if self.clock() - run["started"] > timeout and run["state"] == "starting":
                        with self.lock, self.db:
                            self.db.execute("UPDATE runs SET state='error',error='Startup timed out; process retained' WHERE id=?", (run["id"],))
                        log("%s did not start within %ss; process retained" % (self.describe(run["world"]), timeout))
                    continue
                self.on_run_exited(run)
                continue
            with self.lock, self.db:
                current = self.row("SELECT * FROM runs WHERE id=?", (run["id"],))
                if not current:
                    continue
                players = [ckey(p) for p in status.get("players", [])]
                if players:
                    self.db.execute("UPDATE worlds SET last_used=? WHERE id=?", (self.clock(), run["world"]))
                state = current["state"]
                if state == "starting" and status.get("ready"):
                    state = "running"
                stuck = (state == "stopping" and run["id"] not in self.stop_workers
                         and not status.get("draining"))
                if stuck:
                    # No stop is running and the world is not on its way out: the stop failed or
                    # timed out. Error (with the world kept) lets the owner or an admin retry Stop.
                    state = "error"
                if status.get("error"):
                    state = "error"
                if state != current["state"]:
                    log("%s is %s%s" % (self.describe(run["world"]), state,
                                        ": " + str(status["error"]) if status.get("error") else ""))
                self.db.execute("DELETE FROM tickets WHERE expires<=?", (self.clock(),))
                # Admissions get a short interval to complete client.New after redemption.
                active = {r[0] for r in self.db.execute("SELECT actor FROM audit WHERE action='admit' AND world=? AND at>?", (run["world"], self.clock() - 30))}
                for session in self.db.execute("SELECT ckey FROM sessions WHERE run=?", (run["id"],)).fetchall():
                    if session[0] not in players and session[0] not in active:
                        self.db.execute("DELETE FROM sessions WHERE ckey=? AND run=?", (session[0], run["id"]))
                pending = self.row("SELECT count(*) n FROM tickets WHERE run=?", (run["id"],))["n"]
                empty = None if players or pending or active else (current["empty_since"] or self.clock())
                error = status.get("error") or current["error"]
                if stuck:
                    error = "The stop did not complete; the world is still running. Press Stop again."
                self.db.execute("UPDATE runs SET state=?,players=?,empty_since=?,last_save=?,error=? WHERE id=?",
                                (state, json.dumps(players), empty, status.get("last_save"), error, run["id"]))
                if status.get("last_save") and not status.get("busy"):
                    self.maintain_checkpoints(run["world"], expected=status["last_save"])
                if state == "running" and empty and self.clock() - empty >= self.config["empty_grace_seconds"]:
                    self.begin_stop(current)


def load_config(path):
    config = json.loads(Path(path).read_text(encoding="utf-8-sig"))
    for key in ("kept_save_points_per_world", "delete_unused_worlds_after_days", "afk_timeout_seconds",
                "max_total_worlds_per_player", "station_startup_timeout_seconds", "tutorial_submit_cooldown_hours",
                "station_autosave_minutes"):
        config.setdefault(key, DEFAULTS[key])
    if type(config["tutorial_submit_cooldown_hours"]) is not int or config["tutorial_submit_cooldown_hours"] < 0:
        raise ValueError("tutorial_submit_cooldown_hours must be a nonnegative integer (0 disables the cooldown)")
    if type(config["max_total_worlds_per_player"]) is not int or config["max_total_worlds_per_player"] < 1:
        raise ValueError("max_total_worlds_per_player must be a positive integer")
    if type(config["afk_timeout_seconds"]) is not int or config["afk_timeout_seconds"] < 0:
        raise ValueError("afk_timeout_seconds must be a nonnegative integer (0 disables AFK kicks)")
    if type(config["delete_unused_worlds_after_days"]) is not int or config["delete_unused_worlds_after_days"] < 0:
        raise ValueError("delete_unused_worlds_after_days must be a nonnegative integer (0 disables expiry)")
    if config.get("listen_host") != "127.0.0.1":
        raise ValueError("The trusted API must bind to 127.0.0.1")
    if len(config.get("lobby_secret", "")) < 32 or config["lobby_secret"].startswith("REPLACE"):
        raise ValueError("Set a random lobby_secret of at least 32 characters")
    for key in ("listen_port", "port_first", "port_last", "max_running_worlds", "max_players_per_world",
                "max_worlds_per_player", "max_running_worlds_per_player", "empty_grace_seconds",
                "startup_timeout_seconds", "station_startup_timeout_seconds", "ticket_lifetime_seconds",
                "kept_save_points_per_world", "station_autosave_minutes"):
        if type(config.get(key)) is not int or config[key] < 1:
            raise ValueError(f"{key} must be a positive integer")
    if config["port_last"] < config["port_first"] or config["port_last"] > 65535:
        raise ValueError("Invalid child port range")
    if not re.fullmatch(r"[A-Za-z0-9.-]+", config["public_host"]):
        raise ValueError("public_host must be a hostname or IPv4 address")
    for key in ("data_directory", "template_directory", "config_directory", "dreamdaemon"):
        config[key] = str(Path(config[key]).resolve())
    config["map_catalog"] = str(Path(config.get("map_catalog") or
                                     Path(config["template_directory"]) / "_maps/babylon/catalog.json").resolve())
    return config


# Actions a world child may call with its run id and secret. serve() authenticates each of them with
# Supervisor.child() before the handler runs; every other action needs the lobby secret instead.
CHILD_ACTIONS = {
    "redeem": lambda service, data: service.redeem(data.get("run"), data.get("secret", ""), data.get("ticket", ""), data.get("actor", "")),
    "ahelp": lambda service, data: service.relay_ahelp(data.get("run"), data.get("secret", ""), data),
    "world_manage": lambda service, data: service.manage_world(data.get("run"), data.get("secret", ""), data),
    "round_ended": lambda service, data: service.round_ended(data.get("run"), data.get("secret", "")),
    "tutorial_submit_check": lambda service, data: service.tutorial_submit_check(data.get("run"), data.get("secret", ""), data),
    "tutorial_submit": lambda service, data: service.tutorial_submit(data.get("run"), data.get("secret", ""), data),
    "tutorial_save_back": lambda service, data: service.tutorial_save_back(data.get("run"), data.get("secret", ""), data),
}


def serve(config, service=None):
    service = service or Supervisor(config)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass  # URL/body contain secrets. Audit actions, never raw requests.

        def do_POST(self):
            self.handle_api()

        def do_GET(self):
            # BYOND world.Export uses URL-encoded GET; loopback-only, never log query strings.
            self.handle_api()

        def handle_api(self):
            try:
                if self.command == "POST":
                    size = int(self.headers.get("Content-Length", "0"))
                    if not 0 < size <= 16384:
                        raise Denied("Invalid request size")
                    data = json.loads(self.rfile.read(size))
                else:
                    if len(self.path) > 16384:
                        raise Denied("Request too large")
                    data = {k: v[-1] for k, v in parse_qs(urlsplit(self.path).query, keep_blank_values=True).items()}
                handler = CHILD_ACTIONS.get(data.get("action"))
                if handler:
                    # Each handler authenticates itself (Supervisor.child under the service lock);
                    # test_contracts checks that every entry rejects bad credentials.
                    result = handler(service, data)
                else:
                    if not hmac.compare_digest(str(data.get("secret", "")), config["lobby_secret"]):
                        raise Denied("Invalid lobby credentials")
                    payload = data.get("payload", {})
                    if isinstance(payload, str):
                        payload = json.loads(payload)
                    result = service.dispatch(data.get("actor", ""), data.get("action"), payload)
                code = 200
            except (Denied, ValueError, TypeError, KeyError):
                # Return useful expected errors, but never tracebacks/secrets to the client.
                import sys
                error = sys.exc_info()[1]
                result = {"ok": False, "error": str(error) if isinstance(error, Denied) else "Invalid request"}
                code = 403
            except Exception:
                result, code = {"ok": False, "error": "Supervisor error; consult server logs"}, 500
                import traceback
                log(traceback.format_exc())
            encoded = json.dumps(result).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

    server = ThreadingHTTPServer((config["listen_host"], config["listen_port"]), Handler)
    server.daemon_threads = True

    def monitor():
        while True:
            try:
                service.tick()
            except Exception:
                import traceback
                log(traceback.format_exc())
            time.sleep(2)

    threading.Thread(target=monitor, daemon=True).start()
    log(f"Listening on 127.0.0.1:{config['listen_port']}")
    server.serve_forever()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    serve(load_config(parser.parse_args().config))
