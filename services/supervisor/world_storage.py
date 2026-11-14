"""Filesystem half of journaled, stopped-world expiry."""
from pathlib import Path
import re
import shutil


def delete_world_data(data_directory, world):
    if not re.fullmatch(r"[a-f0-9]{32}", str(world)):
        raise ValueError("Invalid world identifier")
    data = Path(data_directory).resolve()
    worlds, trash = data / "worlds", data / "deleted-worlds"
    for parent in (worlds, trash):
        if parent.resolve().parent != data:
            raise ValueError("World storage escapes its configured data directory")
    source, target = worlds / world, trash / world

    def checked(path, parent):
        if path.is_symlink() or getattr(path, "is_junction", lambda: False)() or path.resolve().parent != parent.resolve():
            raise ValueError("Unsafe world deletion target")

    checked(source, worlds)
    checked(target, trash)
    if source.exists():
        if target.exists():
            raise ValueError("World deletion has conflicting source and trash directories")
        trash.mkdir(parents=True, exist_ok=True)
        # Both final absolute move targets were checked above; neither is supplied by a player.
        source.rename(target)
    if target.exists():
        checked(target, trash)  # Recheck immediately before recursive deletion.
        shutil.rmtree(target)


def reset_world_data(root):
    """Remove a stopped world's saves so its next start is fresh.

    Removes data/babylon (checkpoints, resume state), _maps/babylon/active.dmm and
    _maps/babylon/saved/ below the world directory ``root``. Nothing else is touched.
    """
    root = Path(root)
    if root.is_symlink() or not root.exists():
        if root.is_symlink():
            raise ValueError("Unsafe world reset target")
        return
    resolved = root.resolve()
    targets = (Path("data/babylon"), Path("_maps/babylon/active.dmm"), Path("_maps/babylon/saved"))
    for relative in targets:
        path = root / relative
        # No part of the path below the world may be a link: it could point outside the world.
        walked = root
        for part in relative.parts:
            walked = walked / part
            if walked.is_symlink() or getattr(walked, "is_junction", lambda: False)():
                raise ValueError("Unsafe world reset target")
        if path.exists() and resolved not in path.resolve().parents:
            raise ValueError("Unsafe world reset target")
    for relative in targets:
        path = root / relative
        if path.is_dir():
            shutil.rmtree(path)
        else:
            path.unlink(missing_ok=True)
