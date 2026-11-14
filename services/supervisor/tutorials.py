"""Tutorial storage: the tutorials table and the snapshot files below <data>/tutorials.

A tutorial lives in <data>/tutorials/<status>/<id>/ with meta.json (title, description, author, map,
build, created, updated, source world) and save/ (one checkpoint generation: state.json and the map
files). Accepting a pending tutorial renames its directory to published/ on the same filesystem, so
a tutorial is always complete in exactly one place. Nothing below <data>/tutorials may be a symbolic
link, and no snapshot copied in or out may contain one.
"""
import json
import os
from pathlib import Path
import re
import secrets
import shutil

from constants import TUTORIAL_SNAPSHOT_MARKER
from world_storage import TUTORIAL_ID_RE

STATUSES = ("pending", "published")
GENERATION_RE = re.compile(r"save-\d{8}-\d{6}-\d+")

SCHEMA = """
    CREATE TABLE IF NOT EXISTS tutorials (
      id TEXT PRIMARY KEY, title TEXT NOT NULL, description TEXT NOT NULL, author TEXT NOT NULL,
      status TEXT NOT NULL, map TEXT NOT NULL, build TEXT NOT NULL, created REAL NOT NULL,
      updated REAL NOT NULL, reviewed_by TEXT, source_world TEXT, based_on TEXT);
    CREATE TABLE IF NOT EXISTS tutorial_cooldowns (author TEXT PRIMARY KEY, submitted REAL NOT NULL);
"""


class TutorialError(ValueError):
    pass


def is_link(path):
    return path.is_symlink() or getattr(path, "is_junction", lambda: False)()


def walk(base, *parts):
    """base/parts..., refusing any symbolic link from base downwards (base itself included)."""
    path = Path(base)
    if is_link(path):
        raise TutorialError("Unsafe tutorial path")
    for part in parts:
        if part in ("", ".", "..") or "/" in part or "\\" in part:
            raise TutorialError("Unsafe tutorial path")
        path = path / part
        if is_link(path):
            raise TutorialError("Unsafe tutorial path")
    return path


def copy_snapshot(source, target):
    """Copies a checkpoint directory. Only plain files and directories are copied: a link (or
    anything else) inside the snapshot refuses the whole copy, so nothing outside it is read."""
    target.mkdir(parents=True)
    for entry in source.iterdir():
        destination = target / entry.name
        if is_link(entry):
            raise TutorialError("The save contains a link")
        if entry.name == TUTORIAL_SNAPSHOT_MARKER:
            # The world's "not a checkpoint" mark: the copy is a tutorial's save, or a world's first checkpoint.
            continue
        if entry.is_dir():
            copy_snapshot(entry, destination)
        elif entry.is_file():
            shutil.copy2(entry, destination)
        else:
            raise TutorialError("The save contains an unexpected file")


def snapshot_state(save):
    """The state.json of a snapshot directory as a dict with a valid generation name."""
    try:
        state = json.loads((walk(save, "state.json")).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise TutorialError("The save has no readable state.json") from None
    if not isinstance(state, dict) or not GENERATION_RE.fullmatch(str(state.get("generation", ""))):
        raise TutorialError("The save's state.json names no checkpoint generation")
    return state


def write_json(path, value):
    temporary = path.with_name("." + path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=1), encoding="utf-8")
    os.replace(temporary, path)


class TutorialStore:
    def __init__(self, data_directory):
        self.data = Path(data_directory).resolve()
        self.root = self.data / "tutorials"

    def directory(self, status, tid):
        if status not in STATUSES:
            raise TutorialError("Unknown tutorial status")
        if not isinstance(tid, str) or not TUTORIAL_ID_RE.fullmatch(tid):
            raise TutorialError("Invalid tutorial id")
        return walk(self.data, "tutorials", status, tid)

    def status_root(self, status):
        root = walk(self.data, "tutorials", status)
        root.mkdir(parents=True, exist_ok=True)
        return root

    def create_pending(self, tid, source, meta):
        """Copies the generation directory ``source`` to pending/<tid>/save and writes meta.json.

        The copy is staged next to its final place and renamed in one step, so a failed copy
        leaves nothing behind."""
        final = self.directory("pending", tid)
        if final.exists():
            raise TutorialError("A tutorial with this id exists")
        staging = walk(self.status_root("pending"), "." + tid + ".staging")
        shutil.rmtree(staging, ignore_errors=True)
        try:
            copy_snapshot(source, staging / "save")
            snapshot_state(staging / "save")
            write_json(staging / "meta.json", meta)
            staging.rename(final)
        except (OSError, TutorialError):
            shutil.rmtree(staging, ignore_errors=True)
            raise

    def replace_save(self, tid, source):
        """Replaces pending/<tid>/save with a copy of ``source``: staged, then swapped."""
        directory = self.directory("pending", tid)
        if not directory.is_dir():
            raise TutorialError("The pending tutorial's files are missing")
        save, staging, old = (walk(directory, name) for name in ("save", "save.staging", "save.old"))
        # A swap interrupted between its two renames left the previous snapshot only in save.old.
        if old.is_dir() and not save.exists():
            old.rename(save)
        shutil.rmtree(staging, ignore_errors=True)
        shutil.rmtree(old, ignore_errors=True)
        try:
            copy_snapshot(source, staging)
            snapshot_state(staging)
        except (OSError, TutorialError):
            shutil.rmtree(staging, ignore_errors=True)
            raise
        if save.exists():
            save.rename(old)
        staging.rename(save)
        shutil.rmtree(old, ignore_errors=True)

    def update_meta(self, status, tid, **changes):
        path = walk(self.directory(status, tid), "meta.json")
        try:
            meta = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            meta = {}
        meta.update(changes)
        write_json(path, meta)

    def publish(self, tid):
        """Moves pending/<tid> to published/<tid> with one rename on the same filesystem."""
        source = self.directory("pending", tid)
        if not source.is_dir():
            raise TutorialError("The pending tutorial's files are missing")
        self.status_root("published")
        target = self.directory("published", tid)
        if target.exists():
            raise TutorialError("A published tutorial with this id exists")
        source.rename(target)

    def unpublish(self, tid):
        """Undoes publish() (its database update failed): published/<tid> back to pending/<tid>."""
        source = self.directory("published", tid)
        target = self.directory("pending", tid)
        if source.is_dir() and not target.exists():
            source.rename(target)

    def remove(self, status, tid, purge=True):
        """Deletes a tutorial's directory: renamed out of the way first, so a half-deleted tutorial
        is never found by its id. purge=False only renames it into deleted/ (one quick rename under
        the supervisor's lock); clean_trash() deletes it later, without the lock."""
        source = self.directory(status, tid)
        if not source.exists():
            return
        trash = walk(self.status_root("deleted"), tid + "-" + secrets.token_hex(4))
        source.rename(trash)
        if purge:
            shutil.rmtree(trash, ignore_errors=True)

    def clean_trash(self):
        trash = self.root / "deleted"
        if trash.is_dir() and not is_link(trash):
            for entry in trash.iterdir():
                if is_link(entry):
                    entry.unlink()
                else:
                    shutil.rmtree(entry, ignore_errors=True)


def reconcile_store(store, known_ids):
    """Startup repair of what an interrupted supervisor left in the tutorial store (the copies run
    outside its lock): staging copies are deleted, tutorials without a database row (known_ids:
    every row's id) go to the trash, and an interrupted save-back swap is undone. Returns what it
    did, as (action, path) pairs for the log."""
    done = []
    for status in STATUSES:
        root = store.root / status
        if not root.is_dir() or is_link(root):
            continue
        for entry in root.iterdir():
            if is_link(entry):
                continue
            if entry.name.startswith(".") and entry.name.endswith(".staging"):
                shutil.rmtree(entry, ignore_errors=True)
                done.append(("removed staging copy", entry))
                continue
            if not TUTORIAL_ID_RE.fullmatch(entry.name) or not entry.is_dir():
                continue
            if entry.name not in known_ids:
                store.remove(status, entry.name, purge=False)
                done.append(("moved a tutorial without a database row to the trash", entry))
                continue
            save, staging, old = entry / "save", entry / "save.staging", entry / "save.old"
            if old.is_dir() and not is_link(old) and not save.exists():
                old.rename(save)
                done.append(("restored the save of an interrupted save back", entry))
            for leftover in (staging, old):
                if leftover.exists() and not is_link(leftover):
                    shutil.rmtree(leftover, ignore_errors=True)
                    done.append(("removed " + leftover.name, entry))
    store.clean_trash()
    return done


def seed_first_save(snapshot, saves):
    """Makes a tutorial snapshot the first checkpoint of a new world: saves/<generation>/ plus
    latest.json, as a world save writes them, so the world's first start restores it."""
    state = snapshot_state(snapshot)
    generation = state["generation"]
    saves.mkdir(parents=True, exist_ok=True)
    if is_link(saves):
        raise TutorialError("Unsafe save directory")
    target = walk(saves, generation)
    if target.exists():
        raise TutorialError("The world already has this checkpoint")
    copy_snapshot(snapshot, target)
    records = state.get("records")
    stamp = re.fullmatch(r"save-(\d{4})(\d\d)(\d\d)-(\d\d)(\d\d)(\d\d)-\d+", generation).groups()
    saved_at = "%s-%s-%s %s:%s:%s" % stamp
    write_json(saves / "latest.json", {"generation": generation, "saved_at": saved_at,
                                       "objects": len(records) if isinstance(records, list) else 0})
    return generation
