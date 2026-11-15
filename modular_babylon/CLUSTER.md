# Babylon13 cluster: lobby, supervisor and worlds

Babylon13 runs many small game worlds behind one lobby. Players pick or create a world in
the lobby; the supervisor starts it as its own DreamDaemon process, admits the player with
a one-time ticket, saves the world while it runs and stops it again when it is empty. This
document describes what players, owners and administrators can do, how worlds are saved,
and how to run the cluster. The private Babylon prototype is separate and is not migrated
or restarted. [VALIDATION.md](VALIDATION.md) records what was tested and how;
[UPSTREAM_HOOKS.md](UPSTREAM_HOOKS.md) lists the upstream files Babylon changes.

## Components

- **Lobby** (`babylon-lobby.dme`): a standalone, one-tile BYOND menu. It includes no SS13
  code, maps, subsystems, TGUI build or native libraries. Its browser page lists active,
  owned, shared and discoverable worlds and the tutorials, with creation and owner
  controls ([The lobby](#the-lobby)).
- **Supervisor** (`services/supervisor/supervisor.py`): Python 3.11+, standard library and
  SQLite (the optional Discord bot needs discord.py). It owns world metadata, roles,
  limits, ports, child processes, admission tickets, checkpoints and the tutorial store.
  Its HTTP API binds only to loopback.
- **Babylon build** (`babylon.dme`): one Babylon world per process, on the derelict
  Babylon station, with drones as players.
- **Station build** (`babylon-station.dme`): one world per process on a tg station map or a
  Creative Plane, running normal tg rounds.
- **Test builds** (`babylon-test.dme`, `babylon-station-test.dme`): the two game builds
  with authenticated test hooks, for the smoke tests only. Never host them.

Each world talks to the supervisor through native Topic control (status, save, stop) and
a small early client-admission hook, and through a few authenticated HTTP requests of its
own (ticket redemption, adminhelp relays, world management, round end, tutorial
submissions).

## World types

A world is defined by its **map**, two switches (**Persistent** and **Creative**) and its
**kind**. The map and the kind are fixed when the world is created. The switches are
chosen in the New world wizard and can be changed in the world's settings while it is
stopped.

Maps (`_maps/babylon/catalog.json`), grouped as in the wizard:

| Group | Maps | Build | Players are |
| --- | --- | --- | --- |
| Babylon | Babylon | `babylon.dme` | drones ([Babylon worlds](#babylon-worlds-persistence-and-size)) |
| Stations | BoxStation, MetaStation, DeltaStation, KiloStation, PubbyStation; multi-level: IceBox Station, Tramstation, North Star | `babylon-station.dme` | their preferences characters, in a normal tg round ([Rounds in station worlds](#rounds-in-station-worlds)) |
| Creative Plane | S (50x50), M (100x100), L (200x200) | `babylon-station.dme` | their preferences characters, on an empty floor ([Creative Plane](#creative-plane)) |

Switches:

- **Persistent** (default on): the world is saved (autosave, the owner's Save verbs, and a
  final save when it stops) and every start resumes from its latest checkpoint. Off: the
  world is never saved, and every start begins from the fresh map.
- **Creative** (default off): every player in a body gets the Creative panel and the
  tutorial wand ([Creative mode](#creative-mode)). Works on every map.

Kinds are set by the supervisor, never by a lobby request:

- `world`: an ordinary world that a player created.
- `tutorial`: a player's private run of a published tutorial (**Play**). Never saved;
  deleted with its files when it stops.
- `tutorial_edit`: an administrator's edit world of a pending tutorial (**Edit**).
  Creative, never saved, deleted when it stops.

What follows from the type is one table, `/datum/babylon_world` in
`modular_babylon/code/world_flags.dm`, mirrored by `world_policy()` in
`services/supervisor/constants.py`. `test_contracts.py` checks that both give the same
answers for every combination.

| Rule | Applies to |
| --- | --- |
| Saved (autosave, save verbs, save on stop) | Persistent worlds of kind `world` |
| Creative panel and tutorial wand | Creative worlds |
| Creative machines work | Creative worlds, tutorial kinds, every Creative Plane map |
| Supermatter delamination contained (no singularity, tesla or cascade) | the same as creative machines |
| Inert storyteller (no random events or antagonists) | Babylon worlds, tutorial kinds, Creative Plane maps |
| Round starts at once (no owner hold) | tutorial kinds, and resumed rounds |
| Can submit a tutorial | Creative station-build worlds of kind `world` (Creative Plane or station) |
| Can save a tutorial back | `tutorial_edit` |
| Players' characters saved | every kind except the tutorial kinds |

## Limits

| Limit | Setting (Docker / supervisor JSON) | Compose default | What counts |
| --- | --- | --- | --- |
| Running worlds | `BABYLON_MAX_RUNNING_WORLDS` / `max_running_worlds` | 4 | every running world (tutorial runs included), except worlds owned by an admin |
| Running worlds per owner | `BABYLON_MAX_RUNNING_WORLDS_PER_PLAYER` / `max_running_worlds_per_player` | 1 | the owner's running worlds, including their tutorial runs; a member who starts someone else's world uses that owner's quota |
| Saved worlds per owner | `BABYLON_MAX_WORLDS_PER_PLAYER` / `max_worlds_per_player` | 3 | the owner's Persistent worlds: checked when creating one, when turning Persistent on, and by **Copy to my worlds** |
| All worlds per owner | `BABYLON_MAX_TOTAL_WORLDS_PER_PLAYER` / `max_total_worlds_per_player` | 20 | all the owner's worlds of kind `world`, Persistent or not (tutorial runs and edit worlds do not count) |
| Players per world | `BABYLON_MAX_PLAYERS_PER_WORLD` / `max_players_per_world` | 4 | the highest capacity an owner can set; pending tickets count |
| Tutorial submissions | `BABYLON_TUTORIAL_SUBMIT_COOLDOWN_HOURS` / `tutorial_submit_cooldown_hours` | 6 | hours between two submissions of one player; `0` turns it off |

Server administrators (`BABYLON_ADMINS`) are exempt from the per-owner limits: they create
as many worlds as they like, run several at once, and may start another person's world even
when its owner's running quota is used up (a player's world still counts towards the global
limit). Worlds owned by an admin do not count towards the global running limit; they only
need a free port, and the Discord status shows them separately, for example "2/4 (+1)"
(the hub status counts them as running worlds).
Admins bypass a world's player capacity. A refused action says which limit applies ("Your
world limit has been reached", "Your total world limit has been reached", "This owner's
running-world limit has been reached", "The server's running-world limit has been reached").

## Rules and controls

- Private worlds are visible only to their owner, members and server admins.
  Public worlds accept signed-in accounts; password worlds are discoverable
  and require a password for guests. Explicit members bypass passwords.
- Guests can join worlds that are already running, but cannot start stopped
  worlds. Only owners, members and server admins can start a world.
- The selected lobby tab has a heading, description and active highlight.
  World cards distinguish online/offline/startup/error states and show the
  player's role. Join immediately displays progress before server preparation.
- Owners create worlds, edit settings while stopped, grant/remove members,
  and request an immediate save-and-stop. Admins can see/join/manage every
  world regardless of visibility/password, and are full game admins inside
  every world they join. Managers and delegated permissions are not yet added.
- Limits on worlds and players are described under [Limits](#limits). Admins bypass
  join capacity so they can investigate a full world.
- Admins can also **Spectate** (or **Start and spectate**) a world from the
  lobby: they enter as an ordinary admin ghost, invisible to players, instead
  of a drone, so checking on a world leaves no empty admin drone behind. The
  ghost is deleted when they leave; a drone from an earlier visit stays as it
  was. Only the supervisor grants this mode, for admin tickets that asked to
  spectate and only while the account is still an admin.
- Concurrent join requests share one startup. Settings are validated by the
  supervisor; the browser cannot choose filesystem paths or executable options.
- Tickets are random, stored as hashes, single use and expire after 60 seconds
  by default. They bind the authenticated ckey, world ID and run ID. Capacity
  includes pending tickets and recently redeemed admissions. Access is checked
  again at redemption. Direct connections without a ticket fail before normal
  client setup. A disconnected player obtains a new ticket through the lobby.
- Empty worlds save and stop after a configurable grace period (default 120s).
  Connected ghosts count; abandoned bodies do not. Pending tickets/admissions
  postpone empty shutdown. Normal physics and drone controls remain paused
  from final checkpoint through exit. Save failure keeps the child alive and
  displays an error; the owner can inspect logs and retry Stop.
- Force stop blocks new admissions immediately, saves, offers connected
  players a redirect to the lobby, and exits three seconds later, disconnecting
  anyone who declines the redirect. It does not discard unsaved progress.
- `kept_save_points_per_world` controls retained checkpoints, including the
  current one, and defaults to **4**. It must be a positive integer. Older
  committed generations are removed after a completed save and on startup for
  stopped worlds. Only complete generations at or before the current checkpoint
  are offered for restore.
- Owners/admins can select **Saved checkpoints / rollback** on a stopped world.
  The confirmation warns that the entire world is rewound and **all newer
  checkpoints are permanently deleted**. Members/guests cannot rewind it.
  A stale selection is rejected if the history changed while confirming.
  Rollback atomically changes the current checkpoint; a recovery journal
  completes interrupted deletions before another start. The next Join stages
  the selected map and state, replacing cached startup data.
- `delete_unused_worlds_after_days` defaults to **60**; set **0** to disable
  automatic expiry. The supervisor checks hourly and only expires stopped
  worlds. Starting, joining, connected players and owner management actions
  update activity; merely browsing the list does not. Expiry removes the world,
  all checkpoints and memberships. A persistent deletion queue safely resumes
  interrupted filesystem cleanup. Existing databases migrate activity from
  their creation time and recorded actions.

## The lobby

Every lobby prompt is an in-page dialog (no BYOND system popups): the
New world wizard (map cards grouped into Babylon, Creative Plane with an
S/M/L size choice, and Stations, with a Multi-level badge for multi-z maps
and a top-down preview rendered by `tools/babylon/render_map_previews.py`
into `_maps/babylon/previews` (rerun it when a station map changes); then name, description, who can join, password, capacity and the Creative and
Persistent switches, with the owner's saved/total world counters), world
settings, members, saved checkpoints, the join password, Discord link/unlink
and the stop/delete/reset/rollback confirmations. Delete and Reset need the
world's name typed; confirmations never trigger on Enter. Esc or a click
beside the dialog cancels (not while a request runs); errors appear inside the
dialog, which stays open. Members lists the current members with a remove
button and works while the world runs. A station world whose round ended shows
"Round over" while it shuts down. Status polls never redraw an open dialog, so typing is kept.
Joining and stopping show the loading panel; shutdown stays on it until the
final save and process exit are confirmed, or an error or timeout is reported.
Background status polls update the existing browser document only when its
content changes; each tab keeps its scroll position. Late poll responses
cannot overwrite an action's loading state.

## Deleting worlds

Owners and server admins can permanently delete a stopped world using
**Delete world** on its lobby card. The confirmation covers every checkpoint.
Running worlds must be saved/stopped first. Deletion revokes memberships,
tickets and sessions, releases the owner's world quota, and removes that
world's data directory. Filesystem failures retain a cleanup journal for retry.

## Babylon worlds: persistence and size

Every world gets its own UUID directory, config and control key. On startup,
the driver stages the canonical wreck or its last committed checkpoint.
Mutable maps, data, logs, config and assets are isolated between children.
The current deployment copies map/asset directories; shared immutable asset
distribution and binary-version pinning/upgrades remain future work.

Checkpoint format 6 adds a ckey-indexed drone roster. Inventories, appearance
and respawn cooldown belong to each player; legacy format-5 owner data can
still load. Disconnected drones remain in the world and can be damaged. On
reconnect the player receives their saved drone or pending respawn state.
An enclosed drone is restored on its enclosing floor tile, preserving its
inventory without trying to reconstruct an active ventcrawl/container session.

Only a player's first chassis receives starter equipment. Respawn constructs
an empty replacement, including no replacement bag or holiday hat. Recover
dropped tools, craft replacements, or restore/reset the world if necessary.
The Return to lobby HUD action comes before Self-destruct and is also available
while waiting as a ghost. Returning leaves the body and inventory in the world.
Ghost spawner/minigame interfaces are disabled; DNR and corpse re-entry remain.

Fresh-map preparation derives the upstream wreck and applies two Babylon-only
overlays with `map_overlay.py`: `_maps/babylon/vault_annex.json` splices the
generation interlock, the inner vault doors and the sealed continuity annex
north of the vault into the map, and `_maps/babylon/lore.json` places fourteen
lore objects (open papers, flat satchels hidden under floor tiles, sealed
crates in the vault, and archive boxes in the annex). Hidden satchels only go
under intact floor tiles, never bare plating, and ghosts can neither read a lore
paper nor look inside a lore box. Existing saved builds are not
overwritten or reseeded. Draft text and the canon live in `modular_babylon/lore/`.
Their types and locations persist through saves; there is no separate
repeatable paper spawner.

Vault progression: the outer vault's generation interlock stores and consumes
nothing. It reads live generation on the cable beneath it, subtracts SMES
output on that powernet, and releases the locks only after that figure holds
at or above 2 MW for 30 seconds, which in practice means a running reactor.
The inner doors are on a separate continuity interlock in the first chamber: a
conscious human starts a 60-minute real-time sequence and must stay alive for
all of it, or it resets. Once opened, the inner doors stay open and the fact is
saved with the world. The watchdog server in the annex prints a core log built
from the world's own re-seat and unlock history.

Survival: in Babylon, hunger and thirst are lethal for living crew. Below the
starving and parched thresholds a human takes ramping brute and toxin damage
each second, with a chat warning every 30 seconds. Drones are unaffected.
The standalone preparation script now also requires Python 3.11+ (`-Python`
can supply its path; otherwise it uses uv's Python or the installed `python`).

Babylon uses one station floor with no vertical adjacency, no mining map,
no generated space/away-mission levels, events, gamemode tracks or weather.
`ABSOLUTE_MINIMUM` disables the separate upstream Interlink/cafe loader and its
associated round-start shuttles. Lavaland is not loaded; a future exploration/
shuttle extension can add it without reintroducing unrelated station maps.
Atmospherics, power, machinery, research and construction remain active.
Minimal CentCom/reservation support levels and upstream plane bookkeeping
remain because SS13 systems depend on them. This does not yet remove all
unused upstream types or make a one-z DreamDaemon. The lobby itself contains
none of those systems.

## Showcase worlds

Visibility choices are **private**, **showcase**, **password**, and **public**.
Showcase worlds are listed in the lobby. Owners, members and server admins
join as normal players; guests can **Visit showcase** while it is online.
Guests cannot start an offline world.

Visitors appear to living players as visible, nonphysical ghosts. They can
move through the station and chat locally with nearby players, or use OOC.
They cannot operate machinery, use items, drag objects, enter a body, use
ghost powers, or trigger object/context verbs. Chat is sent only to clients
and cannot activate speech-controlled machinery. The visitor HUD has a
Return to lobby button. Visitor bodies are temporary and never receive a
drone, inventory or persistent player-roster entry. Existing saved bodies
remain untouched when a former player visits as a guest.

The supervisor selects the play mode when redeeming the single-use ticket;
connection parameters cannot request builder access. Members added while
visiting must reconnect through the lobby to enter as players. Visitors count
toward the world capacity and online population and follow its AFK timeout.

## Rounds in station worlds

Worlds on station maps run normal tg rounds, with Babylon's round control:

- **Start round.** The round never starts by itself: there is no lobby countdown. The
  title screen menu (Babylon colours) and the Status tab say what the round waits
  for: the owner and administrators read "You start this round. Press START ROUND when
  everyone is ready."; everyone else reads "Waiting for <owner> to start the round" (or
  that the owner is offline and only they or an admin can start it). The owner and
  server administrators get a **START ROUND (2 of 3 ready)** button at the top of the
  menu (and a `Start round` verb in the Babylon tab); the server checks the
  permission, so nobody else can start it. Members can start the *world*, but only
  the owner or an admin starts its *round*. The starter is marked READY so that they
  get a job too. The round then starts normally: roundstart jobs for players who are ready, the storyteller's roundstart
  events and antagonists. Creative Plane worlds hold for their owner too.
- **Round end.** When the round ends (shuttle at CentCom, nuke, an admin's end round)
  the normal round-end report opens. Players keep it for the normal restart delay
  (`ROUND_END_COUNTDOWN`), at most 60 seconds, then everyone is sent back to the
  lobby and the world stops **without** a save. The supervisor records this as an
  ordinary stop (the world reports `round_ended`; the lobby shows the world as
  stopping and admits nobody in the meantime). In a saved world the owner is told
  that the next start picks up from the last autosave before the round ended, and
  that resetting or rolling back the world in the lobby begins fresh; worlds that are
  not saved (Persistent off, tutorials) say "Next time this world starts, it begins a
  fresh round."
  An administrator's Reboot World ends the world the same way (a reboot would restart
  the run behind the supervisor's back).
- **Resumed rounds.** A world whose save contains a started round resumes it at once,
  without roundstart job assignment or antagonist rolls, and the station clock goes on
  from the saved station time. A returning player who had a character when the world was
  saved is put straight back into it (or back as its ghost, if it was dead or they were
  watching as a ghost); everyone else uses the normal late-join menu.
- **Tutorials** (play instances and admin edits) start their round at once. The joining
  player spawns as their preferences character, job Assistant, without antagonists, at
  the tutorial's start.
- **Late-join.** SPLURT's late-joiners arrive on the Interlink (its own z-level with the
  arrivals shuttle and all late-join landmarks), which station worlds do not load; the
  station maps' arrivals docks have no landmarks of their own. Station worlds therefore
  seat late-joiners in the station's arrivals hallway (its chairs and benches, else its
  floor, else the observer start). Maps with fewer than four arrival seats (Pubbystation)
  also get their free hallway floor as arrival points, so a group does not share one bench.
- **Failed starts.** If the round cannot start, the world says so and the owner may press
  Start round again; tutorial worlds show a RETRY TUTORIAL button after three failed
  spawns of a player.

## Saving station worlds

Station worlds are saved like Babylon worlds: an autosave while players are connected
(every `BABYLON_STATION_AUTOSAVE_MINUTES`, default 30; Babylon worlds keep 15), a final
save when the world is stopped from the lobby, and the owner's **Save world** (at most
once every 5 minutes) and **Save and stop world** verbs in the Babylon tab. The
30/10/5/1 second countdown says how long the world will pause (the last save's time),
"Saving... the world is paused for about N seconds" appears when it starts and "Saved.
Play resumes." when it is done. A stop while an autosave runs waits for it (up to two
minutes) and then saves again. A save writes every level a round can change as
`z<N>.dmm` in the checkpoint: the station's levels, the map's own extra levels (the
ice moon's wilderness, mining levels), lavaland and the space levels with their ruins.
CentCom, transit levels and the Interlink are rebuilt on every start and never saved.
`state.json` (format 8, see `services/supervisor/fixtures/README.md`) holds each level's
traits, the map json, whether the round had started and its station time.

When the world starts again, the supervisor stages the saved levels and the world loads
exactly those, with their saved traits: lavaland, space ruins, ice moon caves and rivers
are not generated again, and no new mice, trash or weakpoints appear.

What a save keeps and what it does not:

- Kept: turfs and their floor decals, objects, machines and items with their settings
  and contents (an emptied locker stays empty), room air (planet tiles keep their
  planet's air), the ids and areas objects link up by (APCs, doors, shutters, cameras,
  lifts, the tram), every landmark and ghost-role spawner, and living things without a player (animals, monsters,
  bots, monkeys) by type, name, health and whether they are dead. NPC humans (ruin
  corpses) are not kept yet. Scenery (plants,
  rocks, decals, dirt) keeps only its place, look and colour. A restart decides nothing
  anew that a fresh map would (no new dirt, decay, webs or nests, no animals hidden in
  disposal bins): lights keep their tubes (working, empty, broken or burned
  out, also in fixtures players built), cameras stay on or off, half-built fire and air
  alarms stay half-built, and bots keep their personality setting. Every deck of a
  multi-deck station keeps its own rendering layer. Vending machines still restock. Known gap: objects another object makes when it is created
  (gravity generator parts, turret covers, wide airlocks' fillers and the like) are restored
  and made again, so each restart adds a copy of them.
- Not kept: shuttles. Their tiles are saved as the dock beneath them and every shuttle
  (cargo, mining, escape pods, the emergency shuttle) loads again at its roundstart dock,
  idle; whatever was aboard is lost. Shuttles players built themselves are saved where
  they are. Antagonists, ongoing events, the crew manifest
  beyond names and jobs, and bank balances are not saved either.
- Players' characters: each player's body is kept in its world, by account, with its
  name, species and look, job, injuries and lost limbs, where it stood, and everything it
  wore, held or carried (backpack contents included). ID cards keep their job design,
  access, holder and assignment (also cards lying anywhere on the station), and a
  character's bank account comes back with its balance. Bodies are saved on every save,
  also when nothing else on their deck changed. They come back only when the save's round
  had started; the restored characters keep their job (counted in its slots), are on the
  crew manifest again and get their job's implants (mindshields) back. A body comes back
  asleep until its player returns, so the usual cryo rules can free its job. A dead body
  comes back dead, and its player rejoins as its ghost. A body saved aboard a shuttle (which
  returns to its dock on a restart) comes back at the arrivals point. Bodies players left
  behind (a corpse whose player now plays someone else) are kept too, with their items, and
  belong to nobody. Bodies stay in their world: the character editor's preferences are
  shared between worlds, bodies are not. Not kept: quirks, scars, implants other than the
  job's, alternative job titles, memories, handcuffs and legcuffs, organ and brain damage,
  blood volume and chemicals in the body, prosthetic limbs (they come back as normal limbs)
  and how items are attached to each other (a jumpsuit's accessories come back loose
  inside it). Tutorials never contain characters: a submitted or saved-back tutorial and
  every copy made from one start without anyone's body.

A save pauses the world's simulation while it is captured; the time is logged as
`Babylon saved <generation>: ... capture <ms> ms, total <ms> ms` in the world's log.
Large maps with many levels take longer than a Babylon world (a full metastation save
about 35 seconds). Levels nothing changed since the last save in this run are not
captured again: their map file and records are copied from that save. A level counts as
changed while a player's body is on it, when a shuttle arrives on or leaves it, and the
station's own levels whenever the round runs with anyone connected. The first save
after a start captures every level. (Changes on a level nobody visited, such as monsters
wandering on lavaland, are not kept until a player goes there.)

Worlds with **Persistent** off, and tutorial worlds, are never saved: no autosave and no
countdown, no save verbs, and stopping them ends at once without a save (and never
leaves them in an error state). A world stopped before it finished starting is not
saved either.

## Creative mode

Worlds with the **Creative** flag (any map) give every player in a body a **Creative**
action button and a **Creative panel** verb (Babylon tab). Showcase visitors, spectating
admins, ghosts and the new-player lobby get neither. The panel's tabs:

- **Self**: godmode, noclip (turning it off moves you out of any wall to the nearest
  free spot) and a full heal that also revives. Godmode and noclip also sit as quick
  toggles at the right of the tab row.
- **Spawn**: curated categories (creative machines, tools, construction materials,
  machines, structures, items, floors & walls, atmospherics, medical & chemistry,
  clothing & armor, food & kitchen, lighting & decor, security, mobs) and a search over
  everything spawnable (common nicknames such as "metal", "rglass" or "insuls" work too),
  into your hands or at your feet. Stacks spawn as one stack (a full stack unless you
  pick an amount); anything else up to 10 copies. At most 20 spawns every 10 seconds per
  player, and at most 50 living creative-spawned mobs per world. Not spawnable
  (`babylon_creative_spawn_blocked`, `modular_babylon/code/creative/spawning.dm`): ERP
  content (`babylon_type_is_erp`, `sfw.dm`), debug and admin items, abstract types, the
  nuke and its disk, the station charter, antagonist summoners, cluster and spawner
  grenades, endless mob nests, singularities, tesla balls and the singularity beacon,
  spreading cores (mold, fleshmind, vines, xeno weed nodes), shuttle consoles and
  dockers, CentCom/ERT/deathsquad IDs, mobs that make more mobs (legions, regal rats,
  broodmothers, eggs, positronic brains), everything that asks ghosts to take a body or a
  role, hand gestures, mob holders, the Hilbert's hotel sphere, and the circuit board of
  anything blocked. Simple bots (cleanbots, medbots and the like) can be spawned: a spawned
  bot asks no ghost to take it over; that only becomes possible once a player switches on its
  personality setting. A saved world keeps that setting for every bot across restarts. This is the one spawn blocklist: the creative disposal unit and the
  tutorial wand's item fields and Give item action use it too, each with a few extra
  restrictions of its own (the disposal unit and Give item never make grenades, bombs or brain
  holders).
- **Teleport**: to coordinates, an area, another player in this world, a tutorial
  marker, or back to where you were before the last teleport; only this world's own
  levels (never CentCom or transit space). Without noclip you land on the nearest free
  spot. Teleporting takes you out of chairs, vehicles, mechs and closets.
- **Events**: tg round events that may run here, at most 3 every 30 seconds per player.
  Antagonist, ghost-role and player-targeting events, spreading events (vines,
  fleshmind, mold), shuttle events, dynamic tweaks, level-wide disasters (dark
  matt-eor, sandstorms, ICARUS sunbeam, armageddon CME) and admin-only events (weight
  or max occurrences 0) are not offered. Babylon worlds never fire events on their own;
  ones started here still run.
- **Kits**: a tool kit (toolbelt, insulated gloves, loaded RCD, RPD) and the tutorial
  wand.

The **supermatter** stays spawnable (engine tutorials), but in creative and tutorial
worlds, and on every Creative Plane map (with or without Creative, like its creative
machines), a delamination only explodes, irradiates and causes hallucinations: it never
makes a singularity, a tesla ball or a resonance cascade.

Creative players can still end a station round the normal way (calling the shuttle at
a communications console); that is allowed and works like in any round.

The panel has no VV, proc calls, SDQL, bans or announcements and only acts on the
player's own body. Every action is in the game log as `BABYLON CREATIVE:` with the
player's key. If Creative is switched off while the world runs, panels close, powers
and buttons are taken back and events started from panels end.

### Creative machines

Creative worlds can spawn four creative machines from the Creative panel (purple tint,
"creative" in the name). Only the Creative Plane maps come with some; research and cargo
never provide them. They work in Creative worlds, on the Creative Plane maps (whatever the
Creative setting: they are the plane's power and air) and in tutorials (a tutorial keeps its creative power and air, though its players have
no Creative panel). In any other world they are ordinary machines that do nothing special and
say "Creative mode is off in this world" when examined. In a Creative world,
**Ctrl + Shift + click** one to change its mode and setting.

- **Creative SMES.** *Source*: never runs out of charge and puts out its output level (set
  in the normal SMES window, up to 10 MW). *Sink*: soaks up the power nobody else on its
  cable or terminal network used, so it never takes power away from APCs. It needs no
  terminal.
- **Creative canister.** *Source*: refills itself with one gas (any gas in the standard
  list; oxygen by default, a nitrogen preset exists) to a fill pressure (default 4500 kPa,
  100-9000), so its valve or a connector port never runs dry. Changing only the pressure
  keeps the gas inside. *Void*: deletes all gas inside it; on a connector port it drains the
  pipe network, for example as the scrubbers' outlet.
- **Creative fluid tank** (plumbing: wrench it down; input west, output east, like the
  chemical tank). *Source*: stays full (400 u) of one reagent. Only reagents a chem
  synthesizer could make are offered, so no admin-only or ERP reagents. *Void*: destroys
  everything its input pulls in.
- **Creative disposal unit.** *Source*: placed on a disposal trunk, it sends one item down
  the pipe every N seconds (default 10, 2-600) without needing pressure. Pick the item by
  name (e.g. "iron", "crowbar"). Grenades, bombs, nuclear disks, MMIs, mob holders,
  lewd items and the like are not offered and are removed from containers it makes. It
  pauses while 100 of its items still exist and says so when examined. *Void*: deletes
  everything that reaches it by pipe or is put inside; living beings are put out on the
  floor, never deleted.

The settings are saved with the world.

### Creative Plane

The **Creative Plane** maps (S, M, L) are an empty floor to try things out on, best with
Creative mode on. They are station-build worlds: the owner starts the round, and players
arrive as their preferences character.

- **Floor.** A square iron floor (S 50x50, M 100x100, L 200x200 tiles) in the middle of a
  255x255 space level, closed by a ring of indestructible reinforced walls. Every floor
  tile starts with normal air, and the plane relies on that initial air: nothing refills
  the floor (the vents only condition the utility room), and the ring cannot be breached,
  so it never vents. The whole plane has gravity and full light (fullbright, no lights
  needed). Space lies outside the walls.
- **Power.** A creative SMES (source, 1 MW output) at the south edge feeds the main cable,
  which runs along the whole south edge and up the middle column on catwalk floor (the
  cable is visible and reachable there). One APC on the south wall powers the whole floor;
  anything placed anywhere on it is powered. The utility corner has its own APC. The SMES has a terminal on its north side
  with no cable: wire it to give a sink SMES an input grid.
- **Utility room** (south-west corner, glass door south, the "Creative Plane Utilities"
  area together with the SMES; a plaque explains it). The simplest vent and scrubber cycle:
  a creative oxygen source and a creative nitrogen source canister on connector ports feed
  an air mixer (79% nitrogen, 21% oxygen), whose supply line runs two vents; two
  scrubbers drain into a creative void canister. Ordinary pipes; the air alarm controls
  the vents and scrubbers. The canisters connect to their ports by themselves (also after
  a restore); unwrenching one keeps it off its port, also across saves and restarts.
- **Spawn pad** (dark 5x5 square at the south edge, on the middle cable). Late-joiners
  arrive here, Assistants start here, and visitors and spectators appear in its middle.
  Players whose job has no start point on the plane arrive on the pad as well.
- **Round.** No random events or antagonists (the inert Babylon storyteller), and no
  emergency shuttle dock: the round never ends by shuttle; calling it is refused. The
  supply shuttle has no dock either: a cargo console says so instead of calling it.
- **Without Creative mode** the plane's creative machines still work (infinite power and
  gas); only changing their settings needs Creative mode.

The maps are generated: change `tools/babylon/gen_creative_plane.py` and run it (it also
renders the lobby previews); never edit the `.dmm` files by hand. Its test fails when the
committed maps differ from the script's output.

## Tutorials

Players build a tutorial in a **Creative** world on a **station map** (a Creative
Plane or a station; Babylon worlds can build but not submit) and submit it from the
Creative panel's **Tutorial** tab. The world's owner submits it with a title (1-60
characters) and a short description (up to 500); the tutorial needs a marker with the
id `start` (where players begin), and the tab says why Submit is disabled (no start
marker, the cooldown with the time left, not the owner, not a Creative station world).
Submitting saves the world as it is (the world pauses, as for any save; also in an
unsaved world) and the supervisor copies that save into
`<data>/tutorials/pending/<id>/` (`meta.json` plus `save/`). The world keeps no trace
of it: the submission's save never becomes the world's checkpoint, so turning **Saved**
on later does not resume from it, and it holds no player characters. The submitted
copy can't be changed by its author afterwards. Each player can submit once every
`BABYLON_TUTORIAL_SUBMIT_COOLDOWN_HOURS` hours (default 6, `0` turns the cooldown
off; supervisor JSON: `tutorial_submit_cooldown_hours`). A submission that fails
(for example a save that can't be copied) starts no cooldown.

The lobby's **Tutorials** tab lists the published tutorials as cards with the map's
preview, title, author and description:

- **Play** starts a private, unsaved copy for the player and joins it. It counts
  towards the running-world limits but not towards the world limits, and it is
  deleted as soon as it stops. A player has one tutorial at a time: Play on the same
  tutorial rejoins the running copy, another tutorial waits until that one has ended.
  A copy that runs into an error (a failed start, a crash report) and stays empty for
  `empty_grace_seconds` is ended and deleted by the supervisor; ordinary worlds in error
  keep their process for inspection.
- **Copy to my worlds** creates a new **Creative, saved** world of the player's own
  whose first checkpoint is the tutorial. It counts against the world limits like any
  saved world.

Server administrators also see **Pending tutorials** (the tab shows how many wait):
**Play** it as a player, **Edit** it (an admin-owned, Creative, unsaved world started
from the pending copy; there is one per tutorial and other admins join it; **Save back
to the pending tutorial** in the Creative panel's Tutorial tab overwrites the pending
copy after a confirmation, again without player characters;
the world is deleted when it stops), **Accept** (moves it to `published/`) or
**Reject** (deletes it). Published tutorials have a **Delete** button for admins.
Deleting or accepting a tutorial does not disturb copies that are running: every
copy is prepared from its own files when it starts.

### Building a tutorial: the tutorial wand

A tutorial is made of hidden **tutorial objects** placed in the world with the
**tutorial wand** (Creative panel → Tools). The wand works in every Creative world.
While it is in your hand you see every tutorial object as a small icon with its id;
nobody else does, and players of a tutorial never see them. Use the wand in your hand
to open its window and choose what a click does:

- **Place**: pick an object from the palette (grouped Triggers / Actions / Markers,
  each with a one-line description) and click a tile. Its settings open at once.
- **Configure**: click an object (or an NPC) to open its settings. Several objects on
  one tile offer a list.
- **NPC**: pick a preset (Guide, Bystander, bruised/burned/poisoned/bleeding/sick or
  unconscious patient, broken leg) and click a tile; the NPC appears at once.
- **Delete**: click an object (or an NPC) to remove it.
- **Select** (area tools, a small WorldEdit): click one corner, then the opposite
  corner; the selection is outlined for you and its size shown ("12×8 (96 tiles)").
  The window then offers:
  - **Copy** the selection to your clipboard (tiles, objects with what is inside
    closets and boxes, reagents, tutorial objects).
  - **Paste…**, then click the tile that becomes the copy's **bottom-left (south-west)**
    corner; the footprint is outlined (red where it can't go) and **Confirm paste**
    builds it. Paste stays on, so a room can be pasted several times side by side.
    Tutorial objects in the copy get an **id suffix** (Auto: the first free `_2`, `_3`
    …; Custom; or Keep ids when they are free), and their links to each other (actions,
    After, targets …) and their zones follow; links to objects outside the copy stay.
    "Keep the target where the copy has space" (on by default) leaves those tiles alone.
  - **Fill** or **Border** with a floor, wall or structure picked from a searchable
    list (optionally only empty tiles).
  - **Clear**: removes objects, mobs and tutorial objects, tiles become plating (or the
    picked floor or wall). It asks first.
  - **Undo** your last paste, fill, border or clear (one step; any new operation replaces
    it, and the window says so). Undoing a fill or border is exact. Undoing a paste or
    clear rebuilds the whole rectangle as it was before, so later changes there are undone
    too, and it is approximate: floor markings and machine settings are lost. Tutorial ids
    taken in the meantime get a suffix instead of being duplicated.

  Limits: at most 10,000 tiles and 20,000 objects at once, on one deck, inside the map.
  Protected tiles and objects (indestructible: the Creative Plane's edge, vault parts,
  unique machines) are never changed, copied or removed; they are outlined in red, and a
  paste over a protected tile is refused. A copy turns floors and walls the tools can't
  build (lava, airless floors …) into plating. Players are never deleted, including a
  ghosted player's body: they are moved to the nearest free tile outside the area. After
  an operation you wait 2 seconds plus 1 second per 1000 tiles; only one operation runs
  in the world at a time. Every operation is logged. Rotating a paste is not supported.
  A paste keeps the target's areas (rooms) and leaves a copied APC out where the area
  already has one; copied floor markings and machine settings beyond their build state
  are not carried over. Mobs are not copied; NPC spawners come along and make their NPC
  again.

Right-clicking the wand while holding it switches to the next mode.

Every object has an **id** (letters, digits, `_` and `-`); objects refer to each
other by id, like airlock ids. A marker with the id **start** is where players begin
(without one they start at the arrivals). Renaming an object updates every link to it;
an id that is already taken is refused. The settings window offers the existing ids in
searchable drop-downs (with what each object does), opens a linked object with one
click and points out problems inline (an id nobody has, a trigger where an action is
expected, a target with nothing on its tile). A trigger's action list can also create
a new action right there ("+ New Message" ...). The wand's **Overview** lists every object with
its problems and warns about a missing start marker, triggers that can never fire,
unused actions and a tutorial without a Complete action; **Go there** jumps to an
object.

**Triggers** wait for the player and then run their **actions** in order:

| Trigger | Fires when |
| --- | --- |
| Tutorial starts | the tutorial starts for the player (once) |
| Zone | the player enters a rectangle (Pick corners, then click two tiles) |
| Holding | the player holds an item of a type (optionally exactly that type) |
| Used on | the player uses an item of a type on a marker's object or an NPC |
| Condition | gas in a zone, power (area power, APC or SMES charge), fluid in a container, a structure at a marker, an NPC's health/damage/alive/dead/disease/awake state becomes true |
| Button | the player presses it (a visible button) |
| Say | the player says a phrase (any part, case ignored) |
| Timer | some seconds after it was enabled |

Every trigger has: **Actions** (ordered ids), **Fire only once**, **Starts listening**
(at the beginning, after another trigger fired, or when an Enable action switches it
on), **Cooldown** and **Delay**. A newly placed trigger listens after the trigger placed
before it, so steps chain in the order you build them. Zone, holding and condition
triggers fire when their condition *becomes* true; a gas zone covers at most 1000
tiles.

| Action | Does |
| --- | --- |
| Message | a green "Guide" box in the player's chat, or a speaker (NPC or marked object) says it to the player (a Guide box with the speaker's name when the player is too far away or the speaker is out cold); `[player]` becomes the player's name; optional **objective** that stays on the player's screen until the next one |
| Point | a bouncing arrow over the target for the player; optionally a speaker points at it again and again |
| Highlight | outlines the target (only the player sees it) |
| Make NPC vulnerable | an NPC that was unhurtable can be hurt from now on |
| Teleport | moves the player to a marker |
| Spawn NPC | (re)creates an NPC spawner's NPC |
| Give item | puts an item in the player's hand |
| Enable/disable triggers | chains steps: only the next step's triggers listen |
| Sound | plays one of a dozen sounds for the player |
| Complete | the "Tutorial complete!" screen with **Back to lobby** |

Point and Highlight last until the next step's trigger fires (or some seconds, or a
chosen trigger). Each action can wait (**Delay**) after the ones before it. **Preview**
in an action's settings runs it for you alone. Everything a tutorial shows or says goes
to its player only, so several players in one world never see each other's steps; NPCs
spawned by an action are shared by everyone in the world.

**NPC spawners** create a human standing still (no AI): name, outfit (common job
outfits or a search; ids and gear are left out), species, facing, **Spawn at the
start**, **Unhurtable until made vulnerable**, and **effects**, each with a chance from
0 to 100 %: brute/burn damage on a body part, toxin and suffocation damage, a wound, a
disease (never contagious), a reagent in the blood (from a list of medicines, common
poisons and a few drugs), unconsciousness for some seconds, bleeding. Names allow
letters, digits, spaces and simple punctuation. The spawner is saved, never its NPC; the
NPC is created again when the world starts and for every run.

**Test run** (wand window) plays your tutorial for you alone, from the start marker
or where you stand, and shows which triggers listen now; other builders can test at
the same time without crossing. **Reset NPCs** (on by default) creates the NPCs again
when a test starts. Stop resets the run, not the world. In a tutorial play instance the run starts by itself
when the player arrives at the start marker.

## AFK return to the lobby

Worlds send inactive players back to the lobby after 900 seconds (15 minutes) by default.
Set `afk_timeout_seconds` in the supervisor JSON, or
`BABYLON_AFK_TIMEOUT_SECONDS` in Docker/Compose; `0` disables it. Changes apply
when a world next starts. Standalone worlds accept the world parameter
`babylon-afk-timeout=<seconds>` with the same default.

Players receive one chat warning up to 60 seconds before that. Moving
or interacting resets BYOND's inactivity counter and cancels the countdown.
The policy includes ghosts, owners and admins, and replaces SPLURT's separate
`KICK_INACTIVE` setting in Babylon worlds. Bodies and equipment are preserved;
players join the world again from the lobby (standalone worlds without a
lobby disconnect them instead). Once everyone has left, the normal
empty-world grace period triggers saving and shutdown. Lobby menu connections
are not subject to this world timeout.

## Server music

Worlds can play music that lives only on the server, never in this repository, so
licensed tracks (for example from a music subscription) stay server specific. Put
tracks into the `babylon-music` volume (mounted read only at `/music`; another path
with `BABYLON_MUSIC_DIRECTORY`). The folder a track is in decides the mood it plays in.
Players rebuild the station as they like (a reactor may stand in the old chapel), so the
mood follows what is around the player, not the room's original name:

```
/music/vault/      inside the Continuity Vault, the watchdog server's room
/music/space/      outside the hull
/music/engine/     near a power generator, wherever it was built
/music/derelict/   inside, where the air is too thin to breathe (below 50 kPa)
/music/station/    inside, with air
```

The checks run in that order. Generators are supermatter crystals, tesla coils and
grounding rods, portable generators (P.A.C.M.A.N. ...), thermoelectric generators, RTGs,
turbines, RBMK reactors, stirling generators and wind turbines; solar panels and power
storage do not count, nor generators packed in a crate. An empty `vault/` uses the other
moods' rules; an empty `engine/` or `derelict/`
falls back to the derelict or station music; an empty `space/` or `station/` is silent
there. Other folders and files directly in `/music` are ignored (a world logs folders it
does not know). Formats: `.ogg`, `.mp3` and `.wav`.

| Variable | Default | Meaning |
| --- | --- | --- |
| `BABYLON_MUSIC_ENGINE_RADIUS` | `10` | tiles around a generator that play `engine/` music (10 = a 21×21 square); `0` turns it off |
| `BABYLON_MUSIC_DEBOUNCE_SECONDS` | `20` | how long a player stays in a new mood before its music takes over |

Tracks play one after another in random order with a 30-second pause. A new mood's music
takes over only after the player has stayed in it for the debounce time, so a short trip
outside or past a generator keeps the current track; with nothing playing it starts at
once. Players set the volume (or turn it off with 0) with **Server music volume**
in the game preferences, or mute and unmute it with **Toggle Server Music** in the OOC
tab. While a track plays, the status tab shows its file name (without the extension,
underscores as spaces), so name files the way players should see them. Its **[?]**
explains in chat that the server's tracks have their own licenses and that players who
record or stream should mute them. Worlds scan the folder when they start, so new tracks reach a
world on its next start. Without the folder nothing plays and nothing else changes.

To fill the volume on the host, for example:

```sh
docker volume inspect <project>_babylon-music --format '{{ .Mountpoint }}'
sudo mkdir -p <mountpoint>/space && sudo cp my-tracks/*.ogg <mountpoint>/space/
```

### Loop sets

Music sold as loops or stems (separate drums, pad, lead, ... of the same piece) goes into a
subfolder of a mood folder with an `index.json`, for example `/music/space/drifting/`.
The game builds a track from it: a few loops play at once, each repeating, and every so
often one joins, leaves or is swapped for another. A loop set takes its turn in the mood like
one plain track; after it ends (and the 30-second pause) the mood picks again. Every audio
file in the folder is a loop, except the intro and outro. All keys are optional; times are
seconds, and a range is `{"min": a, "max": b}` or a single number:

```json
{
  "title": "Drifting",
  "weight": 2,
  "layers": {"min": 2, "max": 4},
  "duration": {"min": 180, "max": 420},
  "change_every": {"min": 20, "max": 45},
  "overlap": 4,
  "sync": true,
  "always": ["pad.ogg"],
  "never_together": [["drums_a.ogg", "drums_b.ogg"], ["lead_1.ogg", "lead_2.ogg", "lead_3.ogg"]],
  "loops": {"lead_1.ogg": {"volume": 70, "weight": 2}, "fx.ogg": {"weight": 0}},
  "intro": "intro.ogg",
  "outro": "outro.ogg"
}
```

| Key | Default | Meaning |
| --- | --- | --- |
| `title` | folder name | name in the status tab |
| `weight` | `1` | chance against the mood's other entries (a plain track weighs 1); `0` never plays |
| `layers` | `1` | loops playing at once (at most 6) |
| `duration` | `180`-`300` | how long the set plays before the mood picks again |
| `change_every` | `30`-`60` | time between changes: with more layers wanted one joins, with fewer one leaves, otherwise one is swapped |
| `overlap` | `4` | seconds a joining loop fades in while a leaving one fades out (also the fade at the end); `0` cuts |
| `sync` | `true` | a loop joining later starts where it would be had it played from the start, so loops of the same tempo stay on the beat; `false` starts it from its beginning |
| `always` | none | loops that play the whole time (they count toward `layers`) |
| `never_together` | none | groups of loops of which at most one plays at a time |
| `loops` | none | per loop: `volume` 0-100 (default 100) and `weight`, its chance to be picked (default 1; `0` plays it only through `always`) |
| `intro`, `outro` | none | played once before the loops start, and while they fade out at the end |

Mistakes (unknown files, bad numbers) are logged when a world starts; a set whose
`index.json` is not valid JSON, or that has no loops, is skipped. For `sync`, cut loops to
whole bars of the same tempo, ideally the same length or multiples of it.

## Restarts and shutdown

When the container stops (a deploy or `docker stop`), new worlds and joins are refused and
every world counts down in chat (`BABYLON_RESTART_WARNING_SECONDS`, default 30, at the
start and at 10 and 5 seconds); the lobby shows the same notice. Then each world saves and
sends its players to the lobby. The lobby stays up until each of them has received its
restart screen (at most 60 seconds, for players whose BYOND is slow to connect or who
closed it), plus 3 seconds to show it. Only then does the lobby stop, so players are
connected to the lobby address and its Reconnect button brings them back once the server is
up again. The whole shutdown has to fit Docker's
`stop_grace_period`.

SIGTERM closes the lobby, saves/stops worlds, and waits for confirmed child
exits for up to `BABYLON_SHUTDOWN_TIMEOUT_SECONDS` (default 600: a station
world's final save takes about a minute). Docker's stop grace period must be at
least the restart warning + that shutdown timeout + the lobby handoff, about
12 minutes with the defaults: Compose grants `BABYLON_STOP_GRACE_PERIOD`
(default 12m). Deployments that set `stop_grace_period` themselves must raise it
accordingly. For plain Docker use `docker stop --time 720`; Docker's default short timeout can kill a
world during its save. On save failure the process stays alive and retries;
Docker can still force-kill it when its grace period expires.

Measured in the H1 container run (no players connected, [VALIDATION.md](VALIDATION.md)):
`docker stop` with a Babylon world, a Creative Plane S, MetaStation and IceBox running took
127 seconds in all: the 30-second countdown, then the four final saves in parallel (Babylon
2 s, Creative Plane 1 s, MetaStation 54 s, IceBox 81 s; the last world exited 94 seconds
after the countdown). A single station save measured 53 to 80 seconds. Players' characters
add to a station save. With the production values (`BABYLON_SHUTDOWN_TIMEOUT_SECONDS=180`,
`stop_grace_period: 10m`) this fits; keep the shutdown timeout at least twice the slowest
world's save time, since saves run in parallel and slow each other down. If the timeout
runs out, the container keeps the unsaved worlds alive and retries until Docker's grace
period kills it, so raise `stop_grace_period` with it.

## Deployment

### Docker on Linux (amd64)

The root Dockerfile builds the pinned BYOND version, native rust-g/dreamluau
libraries, TGUI, behavior trees, and the three production programs (the Babylon,
station and lobby builds). The final image
runs as UID 10001 and keeps the supervisor API inside the container. The lobby
and child DreamDaemon ports are the only published endpoints.

Copy `.env.example` to `.env`, set `BABYLON_PUBLIC_HOST` to the hostname/IP
players can reach, and set `BABYLON_ADMINS` to a comma-separated list of BYOND
accounts. These grant lobby administration and full game-admin rights in every
world they join (granted on admission, for that world's run).

```sh
# Local checkout: automatically includes compose.override.yml, builds :local.
docker compose up -d --build
docker compose logs -f
docker compose down

# Published image: explicitly omit the automatic local override.
BABYLON_IMAGE_TAG=unstable docker compose -f compose.yml up -d
# After a release exists, use latest or a literal release tag such as 1.0.0.
BABYLON_IMAGE_TAG=1.0.0 docker compose -f compose.yml up -d
```

Compose 2.24.4+ is required. `compose.override.yml` uses
`image: !override ghcr.io/scolastico/babylon13:local` and `pull_policy: build`;
it cannot select a downloaded game image even if `BABYLON_IMAGE_TAG` is set.
Base images and pinned build dependencies are still downloaded when building.
CI selects the independent kernel.org Ubuntu mirror with the Docker build
argument `UBUNTU_MIRROR` to avoid the current Canonical DNS outage. A normal
local build keeps Ubuntu's default mirrors; all mirrors use Ubuntu's signed
repository metadata and the image's existing Ubuntu archive keys.

The named `babylon-data` volume holds the database, worlds, logs and every
checkpoint. Keep it when replacing images; `down -v` deletes this volume.
The container locks its data volume so two instances cannot manage it at once.
For a bind mount, make the directory writable by UID 10001. Existing private
PoC saves are not automatically imported.

Set `BABYLON_HUB_LISTED=true` to list the lobby on the BYOND hub (default:
upstream's shared `Exadv1.spacestation13` entry; override with `BABYLON_HUB` and
`BABYLON_HUB_PASSWORD`). Child worlds always start with DreamDaemon's
`-invisible` flag, because they only admit lobby tickets. The hub's own player
counter only sees lobby connections, so the lobby refreshes its hub status every
30 seconds with the total across the lobby and all running worlds. The lobby
never sleeps while empty, so the entry stays listed without players. It starts
invisible and only becomes visible once the configured hub password is set: a
world first announced with a wrong password is listed only while someone is
connected.

The status line is the HTML template `BABYLON_HUB_STATUS`, so links and wording
can be changed without a rebuild. Placeholders: `{name}` (`BABYLON_SERVER_NAME`),
`{players}` (total), `{lobby_players}`, `{world_players}`, `{running_worlds}`,
`{running_worlds_label}` (for example "2 running worlds"; both count admin worlds
like any other), `{admin_worlds}` (how many of them are admin worlds),
`{max_running_worlds}` and `{address}` (the lobby's byond:// address). The
default is
`<b>{name}</b> &#8212; persistent station building<br>Players: <b>{players}</b> ({world_players} in {running_worlds_label}, {lobby_players} in the lobby)`.

Logs: `docker logs` is the single log of the cluster. Every line is prefixed
with its source: `[supervisor]` (world starts, stops, saves, joins and every
lobby action, plus errors), `[lobby]` (the lobby's DreamDaemon: connects,
handoffs to worlds, failed actions) and `[world <name> <id>]` (each child
world's DreamDaemon output, including its round `dd.log` with runtime errors).
The per-world files under `/data/worlds/<id>/` stay as before.

### Configuration

The container reads only environment variables; it writes the supervisor's and the lobby's
JSON configuration itself (under `/run/babylon`, never into the data volume). Every
variable is listed with its default in `.env.example` and passed through by `compose.yml`.
Numbers must be whole numbers. A native (Windows or manual) installation sets the limits
and timeouts as keys of `babylon-supervisor-config.json` (see
`services/supervisor/config.example.json`): the key is the variable's name without
`BABYLON_`, in lower case (`BABYLON_MAX_TOTAL_WORLDS_PER_PLAYER` is
`max_total_worlds_per_player`). The ports are `listen_port`, `port_first` and `port_last`
there.

| Variable | Default | Meaning |
| --- | --- | --- |
| `BABYLON_PUBLIC_HOST` | `127.0.0.1` | address players connect to (no scheme, no port) |
| `BABYLON_SERVER_NAME` | `Babylon13` | lobby and game name |
| `BABYLON_ADMINS` | empty | BYOND accounts, comma-separated: lobby admins and full game admins in every world they join |
| `BABYLON_HUB_LISTED`, `BABYLON_HUB`, `BABYLON_HUB_PASSWORD`, `BABYLON_HUB_STATUS` | `false`, upstream's entry | BYOND hub listing of the lobby (see above) |
| `BABYLON_LOBBY_PORT`, `BABYLON_API_PORT` | `1361`, `1360` | lobby port (published) and the supervisor's internal API port (never published) |
| `BABYLON_WORLD_PORT_FIRST`, `BABYLON_WORLD_PORT_LAST` | `1400`, `1420` | world ports; publish them with the same host and container numbers |
| `BABYLON_MAX_RUNNING_WORLDS`, `_MAX_RUNNING_WORLDS_PER_PLAYER`, `_MAX_WORLDS_PER_PLAYER`, `_MAX_TOTAL_WORLDS_PER_PLAYER`, `_MAX_PLAYERS_PER_WORLD` | `4`, `1`, `3`, `20`, `4` | [Limits](#limits) |
| `BABYLON_KEPT_SAVE_POINTS_PER_WORLD` | `4` | checkpoints kept per world, the current one included |
| `BABYLON_DELETE_UNUSED_WORLDS_AFTER_DAYS` | `60` | stopped worlds unused this long are deleted; `0` never |
| `BABYLON_EMPTY_GRACE_SECONDS` | `120` | an empty world saves and stops after this |
| `BABYLON_AFK_TIMEOUT_SECONDS` | `900` | inactive players go back to the lobby; `0` never |
| `BABYLON_STARTUP_TIMEOUT_SECONDS` | `300` | a Babylon world must be ready within this |
| `BABYLON_STATION_STARTUP_TIMEOUT_SECONDS` | `600` | the same for station-build worlds (the larger of the two applies) |
| `BABYLON_TICKET_LIFETIME_SECONDS` | `60` | how long a join ticket is valid |
| `BABYLON_STATION_AUTOSAVE_MINUTES` | `30` | autosave interval of station-build worlds (Babylon worlds: 15 minutes) |
| `BABYLON_TUTORIAL_SUBMIT_COOLDOWN_HOURS` | `6` | hours between two tutorial submissions of one player; `0` off |
| `BABYLON_SHUTDOWN_TIMEOUT_SECONDS` | `600` | how long a container stop waits for the worlds' final saves ([Restarts and shutdown](#restarts-and-shutdown)) |
| `BABYLON_RESTART_WARNING_SECONDS` | `30` | countdown in every world before a container stop; `0` skips it |
| `BABYLON_STOP_GRACE_PERIOD` | `12m` | Compose only: Docker's `stop_grace_period` |
| `BABYLON_MUSIC_DIRECTORY`, `BABYLON_MUSIC_ENGINE_RADIUS`, `BABYLON_MUSIC_DEBOUNCE_SECONDS` | `/music`, `10`, `20` | [Server music](#server-music) |
| `BABYLON_DISCORD_*`, `BABYLON_JOIN_URL`, `BABYLON_RULES_URL`, `BABYLON_REQUIRE_DISCORD_TO_CREATE`, `BABYLON_REQUIRE_DISCORD_TO_JOIN` | empty | [Discord](#discord), including `BABYLON_DISCORD_TUTORIAL_REVIEW_CHANNEL` for tutorial submissions |
| `BABYLON_CONFIG_DIRECTORY` | `container/default-config` | a custom SPLURT config directory (below) |
| `BABYLON_DATA_DIRECTORY` | `/data` | database, worlds, checkpoints, tutorials and logs |
| `BABYLON_MAP_CATALOG` | the image's `_maps/babylon/catalog.json` | the map catalog |

All supported settings and defaults are listed in `.env.example`: lobby and
world ports, internal API port, admin CSV, global/per-owner world limits,
player limits, retained checkpoints, unused-world expiry, admission lifetime,
empty grace and startup/shutdown timeouts. World port mappings must use the
same host/container numbers because those ports are advertised to clients.
Worlds on station maps (normal tg rounds, several z-levels) boot much longer than
Babylon worlds (about 1.5 to 3 minutes measured); they use
`BABYLON_STATION_STARTUP_TIMEOUT_SECONDS` (default 600) instead of
`BABYLON_STARTUP_TIMEOUT_SECONDS` (default 300), whichever is larger.
For an advanced custom SPLURT config, mount a directory read-only and set
`BABYLON_CONFIG_DIRECTORY` to its container path; it must contain `config.txt`
including `comms.txt`. The supervisor generates each child's control key.
`BABYLON_DATA_DIRECTORY` defaults to `/data` and should remain on a volume.

### Discord

The supervisor also runs an optional Discord bot (discord.py, in the same
process). It starts when `BABYLON_DISCORD_TOKEN` and `BABYLON_DISCORD_GUILD_ID`
are set; `BABYLON_DISCORD_FEATURES` picks what it does:

| Feature | What it does | Needs |
| --- | --- | --- |
| `link` | `/link`, `/unlink`; moderators get `/whois`. Links a Discord account to a BYOND account. | |
| `roles` | Buttons with `custom_id` `babylon:role:<role id>` toggle a role from `BABYLON_DISCORD_SELF_ROLES`; `babylon:color:<role id>` picks one of `BABYLON_DISCORD_COLOR_ROLES` (exclusive), `babylon:color:none` removes it. | role IDs |
| `voice` | Joining the voice lobby creates a room for the member, which is deleted when empty. | `_VOICE_LOBBY_CHANNEL` |
| `logs` | Member, message, voice and moderation logs, each in its own channel (unset channels are skipped). | log channels |
| `status` | A status message (players, running worlds; private worlds stay anonymous), updated every minute and marked offline on shutdown. | `_STATUS_CHANNEL` |
| `gamelog` | Every `[supervisor]` log line, batched into a channel. | `_GAME_LOG_CHANNEL` |
| `ahelp` | Every adminhelp from a world becomes a message with a thread in a staff channel: the player's messages and replies, and in-game admins' answers. Staff answer with the "Reply" button; the player gets it as an admin PM (shown as "Administrator" unless `SHOW_IRC_NAME` is set). "Close ticket" closes it in the world and archives the thread. The player is told "Created an adminhelp for you." and, if any member of `_AHELP_ROLES` (default: the staff roles) is online on Discord, how many; that count needs the bot's Presence Intent, without it the bot runs and the count is left out. | `_AHELP_CHANNEL`, `_STAFF_ROLES`, optional `_AHELP_ROLES` |
| `tickets` | An "Open a ticket" button in a read-only channel opens a private channel for the member and `BABYLON_DISCORD_STAFF_ROLES`. Creator and staff can add people; closing it sends a `.txt` transcript to the creator by DM and to the ticket log. | `_TICKET_PANEL_CHANNEL`, `_TICKET_LOG_CHANNEL`, `_TICKET_CATEGORY`, `_STAFF_ROLES` |

`BABYLON_DISCORD_TUTORIAL_REVIEW_CHANNEL` (no feature needed) is a staff channel
that gets a "New tutorial submitted" message with the title, author, map and
description of every submitted tutorial and a hint to review it in the lobby.
Without it (or without the bot) a submission is only logged; it still waits in
the lobby under **Pending tutorials**.

`/status` is always available. In the developer portal, enable the
**Server Members Intent** for `link`, `logs` and `ahelp`, and the **Message
Content Intent** for `logs`; without them Discord refuses the connection and the
bot stays off (the game keeps running). The **Presence Intent** is optional: with
`ahelp`, the bot asks for it to count online admins and runs without the count
when it is not enabled. The bot's role must be above every role it
assigns. Voice rooms and open tickets are remembered in the data volume.

Linking: **Link Discord** in the lobby shows a one-time code (valid 10
minutes) to type as `/link code:ABCD-EFGH`. One Discord account links to one
BYOND account. `BABYLON_REQUIRE_DISCORD_TO_CREATE` and
`BABYLON_REQUIRE_DISCORD_TO_JOIN` (both off by default, independent) make a
linked account a condition for creating, and for joining or starting worlds;
lobby admins are exempt. While the bot's member cache is ready, a linked
account must also still be on the Discord server. The lobby shows the link
state and the requirements, with Link, Unlink and Discord invite buttons.

`BABYLON_DISCORD_INVITE` also adds a **Discord** button to the in-game escape
menu (Resources); `BABYLON_RULES_URL` sets its **Rules** button. Babylon hides
upstream's /tg/station wiki, forum, rules and config links.

### Image publishing

`.github/workflows/babylon-containers.yml` compiles production, test and
ordinary upstream builds and runs Python/browser tests for PRs and pushes to
`main`/`master`. Publication is restricted to the default branch (currently
`master`) and published GitHub releases. PRs never log into GHCR.

- A successful default-branch push replaces `:unstable`. A temporary
  `:unstable-<commit>` marker permits cleanup even after a cancelled run; all
  older marked unstable image versions are deleted after successful publishing.
- Publishing release tag `1.0.0` attaches both `:1.0.0` and `:latest` to the
  same image. If the released commit already has an `:unstable-<commit>` image
  (normally: the release is the latest default-branch commit), the release waits
  for that commit's push run, then only retags that image instead of compiling
  and building again. Tag changes of all runs share one concurrency group.
- After a successful release, the workflow can trigger a Komodo procedure (for
  example a redeploy) through its GitLab-style webhook. Set the action secrets
  `KOMODO_WEBHOOK_URL` (listener URL ending in `/<default branch>`) and
  `KOMODO_WEBHOOK_SECRET`; without both the step is skipped. Set the action variable
  `KOMODO_NOTIFY_UNSTABLE` to `true` to also trigger it after every published
  unstable build of the default branch (for deployments tracking `:unstable`). Release tags are literal Docker tags; `v1.0.0` remains `:v1.0.0`.
- The separate `Discord changelog` workflow posts to a Discord channel as embed
  cards. Set the action secret `DISCORD_CHANGELOG_WEBHOOK` (the channel's webhook
  URL) and the action variable `DISCORD_CHANGELOG`: `commit` posts every commit of
  each push to the default branch (all of them when several are pushed at once,
  continued on further cards when one is not enough), `release` posts each published
  release's description. Unset, nothing is posted. The optional variable
  `DISCORD_CHANGELOG_ROLE` (a role ID) is mentioned above each post.
- Main/default-branch runs cancel older runs in their concurrency group. PRs
  are grouped by ref; release runs use separate groups and are not cancelled.
- Cleanup never deletes versions with `latest`, a release tag, or any other
  non-unstable tag. Images use a single amd64 manifest without extra attestation
  manifests, so obsolete unstable versions do not leave dangling child images.

The workflow uses `GITHUB_TOKEN` with package-write permission and an OCI
source label linking the package to this repository. For a pre-existing GHCR
package, the repository must have package-admin access for cleanup. GHCR
visibility is managed in the package's settings; a public repository does not
automatically make a newly created package public. Private images need registry
login. Existing documentation and map-viewer workflows are unchanged.

Players authenticate with BYOND; ckeys are taken from server-side clients.
The API trusts the lobby credential, not arbitrary HTTP callers claiming ckeys.
Do not expose the supervisor API to the internet or publish configuration files.
Public connections use the lobby port and the configured child port range.
The example binds game ports to loopback too. To host for other machines, set
`public_host` to the reachable hostname and `bind_address` to the desired
interface (for example `0.0.0.0`), and update `lobby_address` accordingly.

### Windows setup

Build `babylon.dme -DCBT` with the pinned BYOND version, native dependencies and
upstream TGUI assets as described in the repository build instructions. Compile
`babylon-lobby.dme` too. Supply a clean, operator-controlled SPLURT configuration
directory; inherited SQL, external integrations, hub settings, bans and admin
configuration remain the operator's responsibility. Do not use a production
server's live configuration or secrets for a test cluster.

```powershell
powershell -File tools/babylon/Initialize-Cluster.ps1 `
  -DreamDaemon C:\BYOND\bin\dd.exe `
  -ConfigDirectory C:\BabylonConfig `
  -Admins YourByondAccount

# Review babylon-supervisor-config.json, especially paths, host and quotas.
powershell -File tools/babylon/Start-Cluster.ps1 -Python C:\Python\python.exe
```

Initialization generates a fresh shared lobby credential in two ignored JSON
files. It refuses to overwrite them. Admin accounts come only from the supplied
`-Admins` list; no account is automatically granted access.

Once configured and compiled, double-click **Start Babylon Server.cmd** or
**Stop Babylon Server.cmd** in the repository root. They find Python through
`uv`, the Windows `py` launcher, or `python` on PATH. The PowerShell entry points
also accept `-Python` for an explicit executable path.

Start reports an already-running cluster instead of launching duplicates.
Stop closes the lobby to prevent new starts, waits for any starting worlds to
initialize, requests a final save/stop for every running world, and waits for
confirmed exits before stopping the supervisor. A save failure or timeout
leaves the supervisor and affected children running for recovery; it never
force-kills a world. The scripts do not delete worlds or checkpoints.

For manual operation, run Python with
`services/supervisor/supervisor.py --config babylon-supervisor-config.json` and
DreamDaemon with `babylon-lobby.dmb 1361 -trusted -close -params
"lobby-config=babylon-lobby-config.json"` from the checkout root. On Linux,
configure the native-library/executable paths and use these manual commands.

The supervisor can restart while children remain alive. It stores run IDs,
per-run control credentials and PIDs in SQLite and checks authenticated child
identity before trusting status. Keep its data directory private. Lobby and
supervisor process IDs/logs are under that directory. Stop worlds through the
lobby before stopping the cluster processes. Do not kill a child to save it.

## Validation

```powershell
python -m unittest discover -s services/supervisor -v

# Compile babylon-test.dme first. Disposable worlds only; never publicly host it.
python services/supervisor/smoke_native.py `
  --dreamdaemon C:\BYOND\bin\dd.exe `
  --config-directory C:\BabylonTestConfig `
  --data-directory C:\BabylonTests\new-empty-test-directory
```

The explicit native smoke starts a fresh real child, exercises authenticated
HTTP admission from DM, ticket replay rejection, a second drone/inventory and
its death/respawn state, then saves/stops/restarts and checks the roster again.
It leaves logs/checkpoints for inspection. It refuses an existing test directory
and occupied API/child ports. Unit tests cover access, limits, concurrency,
offline edits, membership removal, restart reconciliation and failed saves.

Still needed before public hosting: real multi-client UI/admission playtesting,
abuse/load testing, operational backup/restore tooling, stronger crash/launch
reconciliation, schema migrations, moderation/bans, delegated manager roles,
and a controlled update policy for worlds saved by older game builds. Worlds
are isolated processes/directories, not an OS security sandbox.

## Persistence repairs carried over from the local prototype

Checkpoints retain air-alarm threshold datums and selected mode, cycling-pump
targets/side links/removability, portable-canister connector attachments, and
computer/frame circuit-board references. Restored doors settle interrupted
animations at their saved physical position. Saved pumps rebuild their links
without running fresh-install door-opening sequences. Reopening a world does
not seed round-start vermin, hidden loot, or weakpoints.

Older saves recover missing circuit references from their saved contents and
missing canister attachments from an anchored device on the same connector
tile. An explicit disconnected state in a newer save stays disconnected.
Legacy Babylon cycling pumps are recoverable as removable player-built pumps;
the original wreck contains no such pumps. Settings never recorded by an older
save, such as custom alarm thresholds, cannot be reconstructed retroactively.

Invalid material entries are removed before UI generation and stock accounting
without changing valid material quantities. This prevents the autolathe's
`materials: null` UI crash. Fault injection and arbitrary inspection remain
confined to the separate `babylon-test.dme` build.

The explicit legacy regression uses an external workshop checkpoint read-only
and stages its own world/config/binaries under a new test directory:

```powershell
python services/supervisor/smoke_reload_fixes.py `
  --dreamdaemon C:\BYOND\bin\dd.exe `
  --config-directory C:\BabylonTestConfig `
  --checkpoint C:\BabylonFixtures\workshop-save `
  --data-directory data\babylon-supervisor\reload-regression-1 `
  --port 1459
```

Compile `babylon.dme` and `babylon-test.dme` first. The fixture needs an R&D
console, autolathe, alarm, cycling airlock pump, and at least two connected
canisters. The regression strips the newly added fields in its disposable
copy, then checks legacy recovery, real tool operations, a second player's
inventory, and a save/reload with the new fields. It refuses occupied ports
and existing test directories and never writes to the supplied checkpoint.
