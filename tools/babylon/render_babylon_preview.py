"""Render the fresh Babylon vault entrance with the real SPLURT sprite atlas.

    python3 tools/babylon/render_babylon_preview.py

Requires Docker; pulls the pinned atlas image if absent. The checkout is read-only
inside the renderer. A private source overlay supplies map_overlay.prepare_fresh_map's
active.dmm, exactly as a fresh builder world does. No running world is touched.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'services/supervisor'))
from map_overlay import prepare_fresh_map  # noqa: E402

ATLAS_IMAGE = ('ghcr.io/scolastico/splurt-atlas@sha256:'
               '6f7f94eedd4a950f18294d8be0731ffcbfa97d078aabda3004029b0d00697148')
# Inclusive source-map coordinates, z1. Spawn (41,53), generation controller
# (42,55), outer vault doors (41,56) and (41,57). 20x10 tiles, south of the vault.
CROP = (33, 49, 52, 58)
PREVIEW = '_maps/babylon/previews/babylon.png'
SOURCE = '_maps/RandomRuins/SpaceRuins/skyrat/drones_derelict.dmm'


def prepare_source(root, stage):
    """Stage container-relative links and a private copy of the prepared fresh map."""
    stage.mkdir()
    for directory, excluded in (('', '_maps'), ('_maps', 'babylon'), ('_maps/babylon', 'active.dmm')):
        destination = stage / directory
        destination.mkdir(exist_ok=True)
        for source in (root / directory).iterdir():
            if source.name != excluded:
                (destination / source.name).symlink_to(
                    Path('/source') / directory / source.name, target_is_directory=source.is_dir())
    active = stage / '_maps/babylon/active.dmm'
    prepare_fresh_map(root, active)
    return active


def main():
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    with tempfile.TemporaryDirectory(prefix='babylon-atlas-') as temporary:
        work = Path(temporary)
        stage, output = work / 'source', work / 'output'
        active = prepare_source(ROOT, stage)
        output.mkdir()
        # Run with the invoking user's uid, so all output can be read/removed normally.
        docker = ['docker', 'run', '--rm', '--network', 'none', '--cap-drop', 'ALL',
                  '--security-opt', 'no-new-privileges', '--user', '%d:%d' % (os.getuid(), os.getgid()),
                  '-v', str(ROOT) + ':/source:ro', '-v', str(stage) + ':/staged-source:ro',
                  '-v', str(output) + ':/output']
        # Atlas writes its cache in its installation; give this disposable container a tmpfs.
        subprocess.run(docker + ['--tmpfs', '/opt/atlas/.cache:mode=1777', ATLAS_IMAGE,
                                '--source', '/staged-source', '--output', '/output',
                                '--maps', 'babylon13', '--dme', 'babylon.dme', '--workers', '2',
                                '--revision', revision], check=True)
        subprocess.run(docker + ['--entrypoint', 'node', ATLAS_IMAGE,
                                '/source/tools/babylon/atlas_preview.mjs', '/output/babylon13',
                                '/output/babylon.png', ','.join(map(str, CROP))], check=True)
        target = ROOT / PREVIEW
        target.write_bytes((output / 'babylon.png').read_bytes())
        provenance = dict(
            renderer=ATLAS_IMAGE, source_revision=revision, dme='babylon.dme', source=SOURCE,
            overlays=['_maps/babylon/vault_annex.json', '_maps/babylon/lore.json'],
            prepared_map_sha256=hashlib.sha256(active.read_bytes()).hexdigest(),
            z=1, crop_inclusive=list(CROP), channels=['base', 'foreground'],
            size=[256, 128], png_sha256=hashlib.sha256(target.read_bytes()).hexdigest())
        target.with_suffix('.render.json').write_text(json.dumps(provenance, indent=2) + '\n')
        catalog_path = ROOT / '_maps/babylon/catalog.json'
        catalog = json.loads(catalog_path.read_text())
        next(entry for entry in catalog['maps'] if entry['id'] == 'babylon')['preview'] = PREVIEW
        catalog_path.write_text(json.dumps(catalog, indent=2) + '\n')
        print(PREVIEW)


if __name__ == '__main__':
    main()
