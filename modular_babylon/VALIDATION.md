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

`smoke_stability.py` restores a world three times. A Babylon world keeps 3351 records on
every save. MetaStation's restored saves are identical, type by type (90972 records). Its
first restore differs from the fresh save only by lavaland monsters that were still digging
out, a sliding puzzle, and 6 sheets of reinforced glass. Before H1b, every MetaStation restart
added about 30 objects and every IceBox restart about 260.

The readiness fix was re-checked in the container: three Creative Plane S worlds and one
MetaStation world, each stopped the moment the supervisor saw it running, all saved.

Not exercised (needs a real client): joining a world, the lobby page itself, the Creative
panel and tutorial wand UI, playing a tutorial to its end, rejoining a saved character,
AFK return, the restart screen hand-off with players connected, Discord.
