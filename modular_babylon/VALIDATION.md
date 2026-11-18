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

## Lobby layout and responsive dialogs (2026-11-18)

The reported card mismatch reproduced with the actual catalog, CSS and browser
script. Separate group containers placed the Creative Plane preview about 22 px
below Babylon and gave the cards heights of about 223 and 196 px. Group help and
card descriptions now occupy shared grid rows. All map-pick buttons use a column
layout, so stretching a card cannot vertically center its preview/text. A lone
available group fills its row. Narrow screens visually stack each introduction
with its card. The DOM retains both introductions before the cards, and each
card group references its help paragraph through `aria-describedby`. Heading
IDs use a separate namespace from card-button IDs so labels and focus targets
remain unique. These changes use the grid/flex features already present
in the lobby; no subgrid, display:contents or new JavaScript syntax is required.

Audit findings and every affected occurrence fixed:

- Card sizing/alignment: single-card group introductions and cards share rows;
  `.map-pick`, `.map-preview` and `.map-body` keep previews and text at the top
  across both builder and station cards, even with unequal descriptions.
- Selected Creative Plane: `.map-card.selected` paints the entire content area,
  including the space between/around size buttons. Body bottom padding provides
  at least 12 px between description and controls. Size focus is inset; card
  focus is dashed and inset, separate from the outer selection border.
- Narrow picker: Stations retains its existing auto-fill columns, including two
  columns at 600 px and one at 320–375 px. Tutorial grids use one shrinkable
  column only at 400 px and below, where their 340 px minimum may not fit.
  Size buttons may wrap, and their intended 14 px font is no longer overwritten
  by the later `font` shorthand.
- Long unbroken text: inherited wrapping covers world names/descriptions,
  notices, modal text/titles, errors, loading/reconnect messages and toasts.
  Flex items that previously forced overflow now shrink: world-card headings
  and errors, Discord bar spans, modal heading content and footer errors,
  Discord command inputs, toggle text, chosen-map summaries, member names,
  checkpoint dates and toast text. The modal close and member-remove buttons
  keep their size and remain reachable.
- Lobby header: the heading and New world action wrap with spacing instead of
  compressing each other at narrow widths.
- Chosen-map summary: preview/text retain usable widths, and Change map wraps
  onto another line when needed. This also fixes the shared tutorial summary.
- Details footer: smaller side padding/button margins fit its four actions into
  two rows at 320 px, down from three rows (about 191 px high).
  Long repeated footer errors scroll within three lines, keeping the form and
  actions visible; the complete error also remains in the dialog body.
- Checkpoint picker: dates, object counts and Current badges wrap within rows
  rather than forcing the dialog wider.
- Tutorial previews: map/review/play badges share a wrapping overlay container;
  Pending review no longer overlaps Babylon at 320 px. Their existing colors
  and preview style are preserved.
- Toasts: the fixed container is bounded by both viewport edges and its text
  can shrink/wrap; long errors no longer extend beyond the screen. A stack of
  three long messages scrolls within half the viewport height. Padding leaves
  room for toast shadows inside that scrolling container. The shared root is
  hidden when empty so its padding cannot intercept clicks on dialog actions,
  including after the final dismissal, timeout or overlay cleanup. Loading,
  intentional handoff and lost-connection screens clear stale toasts alongside
  the modal, as `lobbyHideOverlays` promises.

`tools/babylon/test_lobby_layout.cjs` serves a disposable HTTP fixture on a
loopback port, uses the actual lobby CSS/JS/catalog/previews, and extracts the
static page/loading/world-card/header/empty/Discord HTML from `lobby.dm`, replacing
DM interpolations with fixture values. It does not execute DM or contact a game
server. A small representative world-action row supplies controls. Single-line
inputs may scroll their values and decorative preview art may clip intentionally;
their element bounds must still fit. No mock DOM is used for geometry.

Reproduce the focused browser checks with Node and Playwright (installed only
in ignored runtime scratch space):

```sh
npm install --prefix data/babylon-supervisor/lobby-layout/browser --no-package-lock --no-audit --no-fund playwright@1.61.1
data/babylon-supervisor/lobby-layout/browser/node_modules/.bin/playwright install chromium
NODE_PATH="$PWD/data/babylon-supervisor/lobby-layout/browser/node_modules" \
  LOBBY_SCREENSHOT_DIR=data/babylon-supervisor/lobby-layout/after \
  node tools/babylon/test_lobby_layout.cjs
```

An existing Chromium executable can be supplied with `CHROMIUM_EXECUTABLE`,
for example the Playwright Chromium path on the test host.
The final run passed 208 checks at widths 320, 375, 600, 640, 641, 768 and 1920 px
(740 px tall below desktop; desktop 1920×1080). Checks cover neither/Babylon/
Creative Plane S/M/L selection, equal preview/title/description tops and card
heights, unequal help/description lengths, the selected background and spacing,
inset keyboard focus on both card buttons and sizes, unique modal IDs and
associated group help, radio arrows, Tab/Shift+Tab containment, retained name and
description across steps, world/empty lists, navigation tabs, Discord bar, both
wizard steps, busy/error states, members, long Join titles, danger confirmations,
Discord copy controls, checkpoint loading/list, tutorials/badges, toasts and
loading/reconnect screens. The card/color/focus/overflow guards failed before
the fixes; separate new guards also caught the badge overlap, footer height
and lone-group sizing before those fixes.
Vertical overflow guards also failed on oversized footer errors and toast
stacks, and the DOM test caught stale toasts surviving overlay cleanup. Review
guards also reproduced lost Stations columns at 600 px, missing shadow space
and the colliding Creative Plane heading/button IDs before their fixes. The
spacing assertion requires at least 12 px, matching the intended padding.
At 320/375 px, lower-edge hit tests and actual mouse clicks send real create
requests before any toast and after the final toast dismissal; these four
checks reproduced the invisible padded-root blocker before the `:empty` fix.
Long-message stack scrolling and actual dismiss buttons are exercised at every
width so hiding an empty root does not hide active notifications.

Browser screenshots were inspected at desktop and narrow widths, including
`desktop-map-unselected.png`, `desktop-map-selected.png`, `320-map.png`,
`320-details.png`, `320-tutorials.png`, and the corresponding 375 px files.
Review follow-up evidence includes `600-stations.png` (two columns) and
`600-toast.png`/`320-toast.png` (shadows with room inside the container).
Before/after PNGs remain ignored under
`data/babylon-supervisor/lobby-layout/{before,after,review}/`; representative final
images accompany the review hand-in.

Other verification:

- `node tools/babylon/test_lobby_ui.cjs`: passed (including wizard payloads,
  limits, accessibility attributes, confirmations and poll preservation).
- `node tools/babylon/test_lobby_loading.cjs`: passed (including stale polls,
  scroll preservation, outages and intentional handoff).
- `python3 -m unittest discover -s tools/babylon -p 'test_*.py' -v`: 60 tests,
  OK; the one native BYOND connection-routing test skipped on this host.
- `node --check modular_babylon/lobby/lobby.js` and `git diff --check`: passed.

Limitations: rendering was verified in standalone Chromium, not the embedded
DreamSeeker browser. No native game build or full game end-to-end suite ran for
these browser-only changes. Window lifecycle hooks, DM markup and map catalog/
PNG generation were left to their separate work streams.
