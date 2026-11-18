# Groundwork validation

Validated locally on 2026-11-09, based on upstream master
`58cd83015ba7a528c87ad4c894785caa6e655265`.

- Dream Maker 516.1686: `babylon-test.dme -DCBT`, zero errors/warnings.
- Dream Maker 516.1686: `babylon.dme -DCBT`, zero errors/warnings.
- Dream Maker 516.1686: ordinary `tgstation.dme -DCBT`, zero errors/warnings.
- Upstream TGUI dependencies installed with the frozen lockfile and
  `bun run tgui:build` completed successfully.
- A separate localhost test process loaded the canonical upstream Babylon
  wreck, saved a seeded world, stopped, prepared that checkpoint, and reloaded.
- The comparison covered 3,304 saved objects and 2,474 room tiles. It checked
  nested/held inventory, appearance, airlock board settings and reconstructed
  cycle groups, nondefault vent pressure/direction, expanded scrubber range,
  and exact saved room/device/pipeline gas data.
- The owner was configured through world parameters using a test identity;
  no personal owner account is compiled into the module.
- `tgstation.dme` is unchanged. Core integration changes are limited to the six
  files listed in [UPSTREAM_HOOKS.md](UPSTREAM_HOOKS.md) at that initial milestone;
  cluster admission adds a seventh guarded upstream hook.
- All 30 previously active workflow YAML files were renamed with `.disabled`;
  repository Actions were disabled separately.

The earlier local prototype had additional reactor-running, pipe-expansion,
lathe-material, autosave-countdown and drone-recovery tests. Those results do
not substitute for repeating coverage against this fork after future changes.
This initial smoke test is not a full persistence or multiplayer certification.

## Lobby/supervisor milestone (2026-11-09)

- All four builds compile with zero errors/warnings on 516.1686: ordinary
  upstream `tgstation.dme`, production `babylon.dme`, privileged local
  `babylon-test.dme`, and independent `babylon-lobby.dme`.
- Twelve supervisor tests pass: private/password/member/admin access, offline
  editing and validation, per-owner/global quotas, concurrent starts, pending
  and redeemed capacity reservations, ticket binding/expiry/replay, membership
  removal, supervisor restart and save failure retention.
- Real DreamDaemon native smoke passes: fresh startup, DM HTTP ticket
  redemption, replay rejection, administrator admission to a private world,
  final save/exit, restart and two separate player roster entries. A second
  drone enclosed inside a locker retains its held backpack and pending respawn.
- The earlier persistence regression passes after the roster refactor:
  3,334 objects, 2,474 room tiles, nested/held inventory, vent settings,
  scrubber widenet, airlock electronics/groups, and exact room/device/pipe gas.
- The menu was opened in a real DreamSeeker client and visually checked. It
  uses a dedicated browser-only skin with no map or SS13 gameplay controls.
- A production child admitted an actual authenticated DreamSeeker client
  using a supervisor-issued ticket; the player appeared in its live roster.
  Owner stop then committed a checkpoint and disconnected the client.
- The separate private prototype on port 1339 was not restarted or changed.

Generated logs/results are ignored under `data/babylon-supervisor/` in the
developer checkout. See [CLUSTER.md](CLUSTER.md) for repeatable commands and
remaining operational limitations. These checks are not a public-hosting or
multi-client load certification.

## Checkpoint retention and rollback

- Twenty-six supervisor/storage tests pass, including the existing twelve
  policy tests. Coverage adds default/custom retention, numeric generation
  ordering, commit/busy boundaries, owner/admin and stopped-world restrictions,
  required destructive confirmation, stale selections, interrupted rollback
  recovery, damaged heads, filesystem path/symlink confinement, and staging the
  selected map/state on the next start.
- The independent lobby build compiles with zero errors/warnings after adding
  the stopped-world checkpoint selection and deletion-warning confirmation.

## Repeating the smoke test

The 2026-11-10 builder update additionally passed 38 Python tests, including
inactivity expiry, interrupted deletion, migration of existing activity data,
path confinement, and preservation of the upstream map under six lore additions.
The production, test and lobby builds compile with zero errors/warnings.
Native smoke checks cover empty replacement equipment through the real respawn
path, Return-before-Self-destruct action order, removal of ghost role/minigame
HUD entries, retained DNR/re-entry, zero physical cafe turfs, and all six paper
items surviving save/reload. The lobby's selected tab was checked in DreamSeeker;
Join displayed its loading panel immediately in a real client before startup.

Use a **disposable checkout**, supply the pinned BYOND/native dependencies and
build the TGUI assets. Compile `babylon-test.dme` first. Supply your own local
configuration directory with a fresh COMMS_KEY; do not commit it.

```powershell
powershell -File tools/babylon/Test-Persistence.ps1 `
  -DreamDaemon C:\BYOND\bin\dd.exe `
  -ConfigDirectory C:\BabylonTestConfig `
  -Port 1351
```

The test refuses an occupied port, the private prototype's port, or an existing
saved world. It only stops the process it launched. Generated results, logs,
map and checkpoint files remain ignored in the disposable checkout.

## Lore, vault annex and survival (2026-11-10)

- `babylon.dme -DCBT` and `babylon-test.dme -DCBT` compile with zero
  errors/warnings on Dream Maker 516 after adding `vault.dm`, `survival.dm`,
  the rewritten `lore.dm` and the VaultController TGUI change; the TGUI bundle
  rebuilt successfully with `bun run tgui:build`.
- All 38 supervisor Python tests pass. The map overlay test now checks the
  46-tile vault annex patch, the 14 lore placements, that lore only lands on
  floor tiles, and that the annex is enclosed by indestructible walls.
- Not yet exercised at runtime: a fresh world with the annex loaded, the
  generation interlock against a running reactor, the one-hour pulse sequence,
  the saved `lore` state across a checkpoint, and lethal hunger/thirst on a
  human. Run the native smoke test in a disposable world before hosting.

## Lore placement fixes (2026-11-11)

- The hidden satchels no longer land on bare plating: the overlay rejects
  plating and broken/burnt turfs for hidden recipes, and the cell note moved
  from north solar control (no intact floor) to the engine room. The test
  asserts every satchel tile is an intact floor.
- The interlock memo, transcript and Vale's final letter ship in archive boxes
  whose storage refuses observers; Babylon lore papers close their UI for
  non-admin ghosts. The test asserts no loose paper in either vault chamber.
- The continuity interlock moved from the tile in front of the inner doors to
  the tile beside it; the displaced plastic crate moved to the vault's
  south-east corner. The test asserts the doorway tile holds no blocker.
- `babylon.dme -DCBT` and `babylon-test.dme -DCBT` compile with zero
  errors/warnings; all 42 supervisor Python tests pass. Not exercised at
  runtime: a ghost clicking a lore box or paper, and the new tile layout.

## Local persistence fixes ported to the multiplayer fork (2026-11-10)

- Production `babylon.dme`, `babylon-test.dme`, and ordinary `tgstation.dme`
  compile with zero errors and warnings on Dream Maker 516.1686. All 38
  supervisor Python tests pass.
- `smoke_reload_fixes.py` passes against a read-only copy of the original PoC
  workshop checkpoint, with new persistence fields deliberately removed in
  the disposable copy. It verifies no critter reseeding; consistent door
  collision/animation; alarm threshold and mode persistence; cycling-pump
  targets, side links and removability; bidirectional canister attachments
  and deliberate detachment; real circuit extraction/reinstallation and
  console completion; invalid-material UI recovery without changing stock;
  and a second player's saved roster entry.
- Evidence: ignored local artifact
  `data/babylon-supervisor/ported-reload-fixes-2/result.json`; checkpoint
  generations `save-20261110-235443-100` and `save-20261110-235625-101`.
- The managed native smoke also passes HTTP ticket redemption/replay checks,
  admin admission, two-player inventories, empty respawn, trimmed ghost HUD,
  return-button order, no physical cafe, and real save/stop/restart. Evidence:
  `data/babylon-supervisor/ported-managed-2/result.json`.
- The fresh managed test loads the newer annex and retains its 12 immediately
  available lore papers through reload. The two sealed lore crates populate
  on first opening and are excluded from that initial-paper count. The pulse
  sequence, interlock behavior and human survival scenarios remain separate
  tests; this port does not change their implementation.
- Test children exit after completion. No private player save, live world,
  credential, or generated binary is committed.

## Lobby loading and scroll behavior (2026-11-11)

- `babylon-lobby.dme` compiles with zero errors/warnings.
- `node tools/babylon/test_lobby_loading.cjs` checks immediate loading,
  duplicate-click blocking, late-poll rejection, completion/cancellation,
  unchanged-content rendering, and scroll retention across updates and tabs.
- An isolated native lobby/browser on port 1371 confirmed real DM-to-browser
  callbacks, tab switching, stable scrolling across the five-second poll,
  a visible loading panel behind deletion confirmation, cancellation, and
  the deletion progress message followed by the updated map list. Only a
  disposable probe world was deleted; its runtime files were removed too.
- The primary lobby was restarted on port 1361. The supervisor and game-world
  processes do not need a restart for these browser changes.

## Windows cluster launchers (2026-11-11)

- Both root `.cmd` launchers were exercised from a different working directory,
  including their Python auto-detection and double-click-style pause behavior.
  Duplicate Start and repeated Stop were verified.
- A disposable real world was started, saved/stopped through the shutdown
  helper, and its committed map/state checkpoint verified before cleanup.
  The test world was then deleted through the normal supervisor API.
- All 47 Python tests pass, including startup waiting, multi-world stop
  requests, save-failure retention, and timeout retention. No launcher can
  force-kill a child world. The cluster was left stopped after validation.

## Worlds, creative and tutorials: container end-to-end run (H1, 2026-11-15)

Run on the real runtime image (`docker build --target runtime`, tree of `feat/world-types`
after the H1 fixes) with a prod-like environment: the production compose values
(`MAX_RUNNING_WORLDS=6`, `MAX_WORLDS_PER_PLAYER=3`, `MAX_RUNNING_WORLDS_PER_PLAYER=1`,
`MAX_PLAYERS_PER_WORLD=20`, `SHUTDOWN_TIMEOUT_SECONDS=180`), except
`EMPTY_GRACE_SECONDS=3600` so that worlds nobody joins are not stopped by the empty-world
timer during the checks. Data on a bind mount, the default container config
(`container/default-config`). No BYOND client: the driver talked to the supervisor's
`/api` with the lobby secret (as the lobby does), to its child HTTP actions as a world
does (redeem), and to the worlds over their authenticated Topic control (`status`,
`save`). For the tutorial flow the station build was replaced by
`babylon-station-test.dmb` (bind-mounted over `babylon-station.dmb`) for its `call`,
`spawn` and `find` helpers; everything else ran the production programs.

Exercised, all passing unless noted:

- **World types.** One world each of Babylon (drone), MetaStation, IceBox Station
  (multi-level) and Creative Plane S with Creative, started in parallel by different
  owners. Each: Join answered `pending` (background start), ready after 21 s, 84 s,
  120-156 s and 30 s; a checkpoint through Topic `save` (2.6 s, 53 s, 70-75 s, 1 s);
  Stop saved again; a second start resumed from that generation (status `last_save`), a
  third save had `save_count + 1`, the same level count and `next_id` not lower.
- **Restore fidelity (record counts by type between the stop's save and the save after the
  restart).** Creative Plane S unchanged (166 records). See "Found" for the others.
- **Tutorial flow** (Creative Plane S, Creative, not persistent): round started as the
  owner; a `start` marker, a Message action, a Complete action, a Tutorial-starts trigger
  and a Zone trigger placed through the test helpers; submitted through the DM path
  (`test_tutorial_submit_live`: the panel's `submissions.begin/submit` and the real
  supervisor): stored under `pending/`, meta title/author/map/source world correct,
  `characters` and `players` empty, 5 tutorial records, the snapshot removed from the
  world, `latest.json` untouched, cooldown started and a second submission refused. A
  player did not see the pending tutorial; the admin's Accept moved it to `published/` and
  the player saw it. **Play** made a private `tutorial` world (persistent 0), running after
  30 s with its round started and the five objects at their places; Stop deleted its row
  and directory. **Copy to my worlds** made the player a Creative, persistent world whose
  first checkpoint is the tutorial (round started, 163 records); it started from that
  seed with the objects in place, and its Stop saved a new generation.
- **Stop during prepare**: Join then Stop at once (state `starting`, no pid): the launch was
  cancelled before a process started, nothing saved; the starter's next Join was told
  "The world's start was cancelled: it was stopped." once, and the Join after it started
  the world normally (a cancel has no back-off).
- **Failed start with back-off** (IceBox, its checkpoint's `state.json` hidden): the starter
  heard "The saved state is missing or corrupt" once; the next Join of the starter and of
  an admin answered "... Try again in 30 seconds." with no run; after the file came back
  and 30 s passed, Join started it and it resumed from the same generation.
- **Late login**: a redeem with `wait_seconds=0.001` was refused with `admission_timeout`
  without spending the ticket; the same ticket then redeemed (`mode player`, role owner);
  a replay was refused.
- **Limits** (non-admin owner, defaults above): 3 persistent worlds, the 4th refused ("Your
  world limit has been reached"); 17 non-persistent worlds up to the total of 20, the 21st
  refused ("Your total world limit has been reached"); turning Persistent on for an
  unsaved world refused by the saved-world limit; a second running world of the owner
  refused ("This owner's running-world limit has been reached"). All 20 deleted again.
- **Container shutdown** (`docker stop -t 600`, the production `stop_grace_period` of 10m)
  with Babylon, Creative Plane S, MetaStation and IceBox running: 127 s in all, exit code
  0: the 30 s countdown, then the four final saves in parallel (2 s, 1 s, 54 s, 81 s); the
  last world exited 94 s after the countdown, inside the production
  `BABYLON_SHUTDOWN_TIMEOUT_SECONDS=180`. Every world's `latest.json` named the new save.

Found and fixed (details in the commit messages):

- An IceBox checkpoint (a full capture after a restart) had a damaged `z4.dmm` ("Undefined
  model key"). The next start ran without that level and its shutdown save wrote the loss
  over the world (366 objects fewer). Level maps were one huge string written unchecked,
  the class `state.json` was fixed for earlier. They are now written in checked 1 MB
  pieces, with a size check. A restore whose saved map did not load fails the start, so
  nothing gets saved over it. The damaged file itself was deleted with the run data before
  this was noticed, so the root cause is not confirmed; it did not recur in the later runs.
- Every Babylon restart gave each restored light a second backup cell (63 per restart):
  the restored cell is now adopted. Every restart also added about 400 dirt decals, and
  station restarts added cobwebs and rat or spider nests: upstream's mapload dirt and
  Skyrat's round-start decay ran again over the saved level. Decay is skipped for a world
  that resumes a save, and dirt, disposal-bin animals and the MULEbot swap stand back for a
  saved map, like lights and cameras. A contract test lists every random mapload default
  in upstream code. Re-checked: a Babylon restart now changes only the companion objects
  below (3342 -> 3355 records, before: about +480).
- The combined suite afterwards caught a station world reporting ready up to a second
  before it could save (a stop in that window skipped its save). Status ready is now the
  session's ready flag in both builds.
- The back-off refusal read "...corrupt Try again in 30 seconds." (missing full stop).

Follow-up (H1b): objects a world makes again on every load are no longer saved, and older
saves lose their extra copies on their next start:
- objects another object makes in its Initialize (marked when they are made);
- CentCom's objects;
- round-start area spawns.

`smoke_stability.py` restores a world three times; the full smoke run passed with it:
- Babylon (test build, in smoke_native): 5826 records on every save, from the first one on.
- MetaStation: its restored saves are identical, type by type (87601 records). Its first
  restore differs from the fresh save only by 6 sheets of reinforced glass and one lavaland
  sliding puzzle piece.
- Before H1b, every MetaStation restart added about 30 objects and every IceBox restart about
  260.

The Babylon fixtures of the native smoke are old saves. Their first start removed the copies
they held (5 CentCom floor lights, 8 gravity generator parts).

The readiness fix was re-checked in the container: three Creative Plane S worlds and one
MetaStation world, each stopped the moment the supervisor saw it running, all saved.

Not exercised (needs a real client): joining a world, the lobby page itself, the Creative
panel and tutorial wand UI, playing a tutorial to its end, rejoining a saved character,
AFK return, the restart screen hand-off with players connected, Discord.

## Final review fixes (H2, 2026-11-16)

The fix round after the final whole-branch review. The full suite ran on `8b8527e1a77`:
- all five builds through `tools/babylon/build_dme.py`, which now fails a build that shows the
  BYOND 516.1686 slot quirk: 0 errors, 0 warnings each;
- `smoke_native.py`: passed, including the Babylon stability step (6017 records on every save);
- `smoke_station.py`, full matrix: passed. MetaStation, the Creative Planes S/M/L (including a
  tutorial instance started from the submitted snapshot), the tutorial world with every
  tutorial test, characters, the tramstation restore, IceBox multi-z and MetaStation
  stability. Stability is now identical from the first restore on (84389 records, no
  differences). The first-restore loss of 6 reinforced glass sheets and a lavaland puzzle
  piece is gone: stacks no longer merge while a save loads;
- supervisor (281, 16 skipped without discord.py), tools (59), node lobby and container tests,
  tgui (106 tests, tsc, biome, tgui:build).

Newly covered:
- a tutorial started from a snapshot taken in a running round starts its tutorial;
- a character on CentCom (a level that is not saved) is kept and arrives at arrivals;
- a restored character can't be put into cryo by someone else before its player returned;
- research (a node, its designs, the point bank) and the cargo budget survive a restart;
- Reboot World saves a running round;
- Preview is refused for world-changing actions;
- a pAI card (station) or a box with a mouse (Babylon) is never deleted with an inventory;
- Give item shares the run's object cap;
- no snapshot during a test run, and none that reuses an old level;
- the supervisor's snapshot pruning, hung-instance stop, shutdown order, damaged pointer,
  audit index and copy journal.

Known limitation: cyborgs and the station AI are not saved (their player late-joins after a
restart).

Not exercised (needs a real client): the Preview button's disabled state in game, the cryo
refusal with real players, Reboot World from the admin verb, a tutorial player actually
spawning at the start marker from a snapshot instance.

## Complete playable station catalog and vault preview (2026-11-18)

The complete top-level config audit found exactly eight omitted playable stations.
All eight now use the station build, their original JSON configs and committed
256×128 previews. Existing BoxStation, MetaStation, DeltaStation, IceBox,
Tramstation, KiloStation, North Star and PubbyStation remain available.
Runtime Station, minimal runtime, multi-z debug and gateway test remain excluded;
Babylon still uses the Babylon build with `map_json: null`.

Paths below are relative to `_maps/`; preview filenames are under
`_maps/babylon/previews/`. Level counts were checked against both the actual DMM
grids and config traits, rather than inferred from names.

| Added station / config | Source DMM | Levels / multiz | Preview |
| --- | --- | --- | --- |
| Biodome / `biodome.json` | `map_files/biodome/biodome.dmm` | 2 / yes | `biodome.png` |
| Blueshift / `blueshift.json` | `map_files/Blueshift/Blueshift.dmm` | 2 / yes | `blueshift.png` |
| Cardinal Station / `cardinalstation.json` | `map_files/CardinalStation/CardinalStation.dmm` | 1 / no | `cardinalstation.png` |
| Catwalk Station / `catwalkstation.json` | `map_files/CatwalkStation/CatwalkStation_2023.dmm` | 2 / yes | `catwalkstation.png` |
| Moon Station / `moonstation.json` | `map_files/moonstation/moonstation.dmm` | 3 / yes | `moonstation.png` |
| Nebula Station / `nebulastation.json` | `map_files/NebulaStation/NebulaStation.dmm` | 2 / yes | `nebulastation.png` |
| Ouroboros / `ouroboros.json` | `map_files/Ouroboros/Ouroboros.dmm` | 2 / yes | `ouroboros.png` |
| Void Raptor / `voidraptor.json` | `map_files/VoidRaptor/VoidRaptor.dmm` | 1 / no | `voidraptor.png` |

The source/config scan found no additional playable omissions. The prepare test
checks **all sixteen** stations through the real driver's selection/build and
`prepare_station` paths: `data/next_map.json` matches the shipped config byte for
byte. That preserves case-sensitive automapper `required_map` matching, including
Catwalk's `_2023` filename. No upstream map or automapper edits were necessary.

The unsupported renderer-input class was the first-`map_file`-only resolver,
combined with silent skips for missing configs/files. Its only implementation
and its test consumer were replaced together. All files and all their levels
now participate in deck selection; independent dictionaries prevent colliding
keys in separate files from changing tiles. Fixtures cover mixed multi-z files,
key collisions, missing second files, empty/invalid lists, case mismatches and
unsafe source paths. Every catalog entry, including Babylon, must have a PNG.

The native Moon run also exposed a related arrival-list assumption: its ten
map-authored cryopod arrivals live in `SSjob.latejoin_override_trackers`.
The existing late-join test counted only ordinary points and falsely failed
capacity despite a valid assistant arrival. The whole-code scan found three
Babylon production fallbacks with the same omission: `character_arrival_turf`
(returning bodies), `babylon_tutorial_start_turf` (without a tutorial marker),
and `station_spawn_turf` (without an observer landmark). They now share
`babylon_latejoin_points`, which follows upstream job spawning's override-before-
default priority. Observer landmarks and tutorial markers still have priority.
`ensure_latejoin_points`, station info/capacity checks, restored-character
arrival checks and Creative Plane arrival diagnostics use the same helper.
Remaining direct writes intentionally populate the ordinary fallback list.

Before the fix, the native `test_station_arrival_overrides` failed all three
override cases while all three no-override cases passed. It restores the original
lists after its synchronous probes. The final matrix below reruns that guard
on each station, alongside real admission and the map's actual late-join checks.

As clarified during the task, the new station cards retain the existing
**department-color schematic** style; Creative Plane retains its special grid,
ring and spawn palette. Regenerating every station/plane with
`python3 tools/babylon/render_map_previews.py` leaves all twenty PNG hashes
unchanged, including the separately generated Babylon preview.

Babylon's former null preview/B13 fallback is now `babylon.png`: an actual
SPLURT atlas sprite rendering of the prepared fresh wreck from
`RandomRuins/SpaceRuins/skyrat/drones_derelict.dmm`, including both Babylon
map overlays. `session.dm` selects the secure-engineering drone shell at
(41,53), in front of the outer vault doors at (41,56–57) and the generation
controller at (42,55). The crop is inclusive x33–52/y49–58/z1 (20×10 tiles),
composited from full-resolution base/foreground strips and downsampled to
256×128. It is a static atlas reconstruction, not a running-game screenshot.

`python3 tools/babylon/render_babylon_preview.py` uses the pinned atlas image
`ghcr.io/scolastico/splurt-atlas@sha256:6f7f94eedd4a950f18294d8be0731ffcbfa97d078aabda3004029b0d00697148`.
It mounts the checkout read-only and stages the exact same fresh-map overlay as
the supervisor. Two independent full atlas runs produced the same PNG SHA256
`c5d40c5ee69c82d7b5b1ae734bab5531db3d91e756cc2c108cb697f04b3f3827`.
`babylon.render.json` records source revision, renderer/crop/layers, prepared-map
hash and image hash. The atlas reported zero missing icons and one missing
`nun_hood` state while rendering the full wreck; that state is outside this crop.
All nine new images were visually inspected. The crop fixture checks exact
pixels across chunk boundaries, DMM y orientation, foreground composition,
hidden utilities, deterministic output, resizing and out-of-range rejection.

Checks run:

- `python3 -m unittest discover -s services/supervisor -v`: 284 tests, passing;
  16 optional Discord tests skipped without discord.py. This includes all six
  catalog tests, the map-overlay test and all 22 driver/prepare tests.
- `python3 -m unittest discover -s tools/babylon -p 'test_*.py' -v`: 65 tests,
  passing; one native BYOND routing test skips on the host (BYOND is in Docker).
  The nine renderer tests parse every catalog station's actual source levels.
  The skipped routing test was also run separately in the native Docker image
  and passed (one test, no skips).
- Pinned atlas container: `node --test /source/tools/babylon/test_atlas_preview.mjs`
  passes. `CLUSTER.md` includes the complete Docker command.
- `node tools/babylon/test_lobby_ui.cjs`: passing. The existing lobby already
  sends every catalog PNG with `browse_rsc`; no JS/CSS changes were required.
- `python3 tools/babylon/build_dme.py babylon-station.dme babylon-station-test.dme`
  in the native image: both compile on BYOND 516.1686 with zero errors/warnings.
- Independent read-only code review approved with no important/critical findings.

The final focused native matrix passed for every addition on the rebuilt
station-test binary. Both independent batches exited successfully after stopping
each nonpersistent disposable world normally. Each row checked the actual loaded
DM map name against its source config, native Topic readiness/run/world identity,
a reachable child listener, the real DM routing helper, fresh and running DM
HTTP ticket admission, replay rejection, effective arrival points and an Assistant
spawn on a station level. All seven override/default regression checks passed
on every map; Moon reports its ten actual map-authored cryopod arrival points.

| Map | Ready after | Effective arrival points | Native admission / arrivals / override regression |
| --- | ---: | ---: | --- |
| Biodome | 102.2 s | 6 | pass / pass / 7 checks pass |
| Blueshift | 112.2 s | 22 | pass / pass / 7 checks pass |
| Cardinal Station | 90.2 s | 170 | pass / pass / 7 checks pass |
| Catwalk Station | 112.2 s | 12 | pass / pass / 7 checks pass |
| Moon Station | 116.2 s | 10 | pass / pass / 7 checks pass |
| NebulaStation | 114.3 s | 8 | pass / pass / 7 checks pass |
| Ouroboros | 106.2 s | 8 | pass / pass / 7 checks pass |
| Void Raptor | 100.2 s | 91 | pass / pass / 7 checks pass |

Reproduce from a source checkout with compiled test resources and native libraries
available in the runtime template (use a new empty data directory):

```sh
python3 services/supervisor/smoke_handoff.py \
  --dreamdaemon /opt/byond/bin/DreamDaemon \
  --config-directory container/default-config \
  --template-directory /path/to/staged-runtime-template \
  --data-directory data/babylon-supervisor/catalog-smoke-new \
  --maps biodome blueshift cardinalstation catwalkstation \
         moonstation nebulastation ouroboros voidraptor
```

The recorded run used two independent containers from the local native runtime
image, splitting the map list four/four. Runtime templates linked the current
checkout's source assets/test binaries and the image's native libraries. Evidence
is ignored under `data/babylon-supervisor/catalog-final-{a,b}/result.json`; compile
and per-world logs are under `catalog-work/`. The live cluster and existing player
data were not touched. This uses real Supervisor/Driver preparation and real
DreamDaemon children; the driver subclass only stages the test build in place of
the production executable. It is not fake-driver load evidence.

Observed runtime caveats: all eight boots logged the upstream tracking-collar
`Cannot read null.tracking` overlay error during preference asset generation.
Moon also logged five ore-generation mineral-budget exhaustion errors. These
were present before the arrival fix and did not prevent readiness, either native
admission phase, or any required spawn check. Early emergency-shuttle lookup
warnings and fixed arrivals rooms without a mobile arrivals shuttle also occur;
station arrivals fallbacks were checked explicitly. Per supervisor direction,
these upstream gameplay defects remain outside this catalog/arrival change.

No full end-to-end suite or real DreamSeeker client was exercised by this task.
The native matrix does not certify client.New, game-window readiness, long-round
gameplay, or mining/ore-vent correctness. The story's review owns full E2E and
real-client validation.

## Remote lobby/world routing (2026-11-18)

The reported failed join was a destination error: a separate Windows DreamSeeker
reached the Linux host's lobby over the LAN, but the supervisor's default
`public_host=127.0.0.1` sent it to its own machine for the child connection.
The original child reached ready, remained alive and saved/stopped normally;
there was no admission. The quoted restart message came from the stale lobby
browser's 15-second heartbeat watchdog after the intentional disconnect.

`modular_babylon/connection.dm`, included by the lobby and both game builds,
validates destinations and routes default loopback links through the server
IP:port returned by BYOND's `winget(client, null, "url")`. It preserves the
configured target port and ticket query. Non-loopback public addresses remain
authoritative. Invalid endpoints fail closed. This uses the connected server
address, never `client.address` (the player's address). BYOND documents the
special call in <https://www.byond.com/docs/ref/skinparams.html>.

Every shared occurrence found is covered:

- Lobby `join_world`: ordinary Join/Create, tutorial Play/Edit, admin
  spectating and the existing rejoin flow all use this common handoff. Tutorial
  copies use ordinary Join from My worlds.
- `babylon_lobby_link`: admission refusal and timeout notices.
- The explicit Return to Babylon lobby verb and the drone/ghost HUD return action.
- Managed save/stop and the station round-end return loop.
- Moderation removal and the AFK path that calls it.
- The existing hidden-window rejoin path, including its spectator query.

The lobby logs the offered endpoint without its ticket, rather than claiming
that sending `link()` was a successful join. Its browser now has an explicit
handoff state and a direct return-to-lobby link; late polls and missing lobby
heartbeats cannot replace this with the restart error. Real outages still show
the existing reconnect screen.

Regression and build checks:

- `python3 -m unittest discover -s services/supervisor -v`: 282 tests, passing;
  16 Discord tests skipped without discord.py. The new contract guard caught
  direct loopback return paths before they were changed.
- `python3 -m unittest discover -s tools/babylon -p 'test_*.py' -v`: 60 tests,
  passing in the native BYOND environment. On the host, the one native-only
  routing test skips because BYOND is supplied in Docker.
- `node tools/babylon/test_lobby_loading.cjs`,
  `node tools/babylon/test_lobby_ui.cjs` and `node container/test_cleanup.cjs`:
  passing. The handoff test failed before the new browser state existed.
- `python3 tools/babylon/build_dme.py babylon-lobby.dme babylon.dme
  babylon-station.dme babylon-test.dme babylon-station-test.dme`: all five
  compile on BYOND 516.1686 with zero errors and warnings.
- `tools/babylon/test_connection_routes.py` executes the actual shared DM
  helper in a disposable native world. Cases cover LAN/local routing, explicit
  public hosts, target ports, unchanged ticket/notice/rejoin queries and invalid
  destinations/endpoints, including unusable ports and injected URL syntax.

Native and real-client evidence are recorded separately below. Test data,
compiled resources and packet summaries stay ignored under
`data/babylon-supervisor/handoff-diagnosis/`; no credentials, ticket values or
private LAN address are committed. The existing live cluster was not modified.

The focused `services/supervisor/smoke_handoff.py` passed on the rebuilt test
binaries with the real supervisor, native Topic readiness/listeners, shared DM
router, and each world's DM HTTP redemption procedure. It checked both the
first ready join and another join of the running world, unchanged ticket and
port, reachable routed hostname, child identity, and refused ticket replay:

| Map | Ready after | Fresh DM admission | Running DM admission |
| --- | ---: | --- | --- |
| Babylon | 22.3 s | pass | pass |
| Creative Plane S | 26.1 s | pass | pass |
| Creative Plane M | 28.1 s | pass | pass |
| Creative Plane L | 30.2 s | pass | pass |
| MetaStation | 80.2 s | pass | pass |

Reproduce in a source tree with the native/runtime assets and both test builds:

```sh
python3 services/supervisor/smoke_handoff.py \
  --dreamdaemon /opt/byond/bin/DreamDaemon \
  --config-directory container/default-config \
  --data-directory data/babylon-supervisor/handoff-new
```

The run used `--template-directory /opt/babylon` for the staged runtime assets
and `--client-endpoint handoff-smoke:15561` inside a container with that hostname.
The source remained mounted read-only. Evidence is the ignored
`focused-smoke-2/result.json`. An earlier attempt to probe the host's LAN
endpoint from inside Docker timed out on that container-to-host hairpin route;
it stopped its disposable child normally. It is not counted as a passing LAN
check. No full gameplay end-to-end suite was run.

A separate Windows DreamSeeker did successfully create and join Creative Plane S
on an isolated patched cluster (test lobby 15361, child 15400). The user confirmed
that the game connected without issues. Header-only tcpdump summaries show the
lobby TCP close followed by a successful TCP handshake and resource traffic to
the Linux host's published child port. Matching logs show the LAN endpoint
being offered, supervisor admission and completed client.New. This confirms
the actual remote-client failure boundary, rather than inferring it from link().

The other four production worlds are ready on ports 15401–15404. Their Windows
client windows and manual Return to lobby/rejoin remain unconfirmed at the time
of this record. The user has been asked to open each through the test lobby and
return through the Babylon tab between them. A repeatable manual check is:
connect DreamSeeker from another machine to the host's LAN address on the test
lobby port, create/join S, return/rejoin S, then join Babylon, M, L and MetaStation
from Active worlds and return between them. Confirm each game window opens and
match its offered host/port, TCP connection, admission and completed-client log.
