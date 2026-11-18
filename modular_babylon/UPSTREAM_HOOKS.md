# Upstream integration hooks

Babylon is opt-in: compile `babylon.dme` (the drone builder) and
`babylon-station.dme` (normal tg rounds on the map catalog's station maps). The
upstream `tgstation.dme` is unchanged. The fifteen modified upstream DM files use
hooks guarded by `BABYLON_BUILDER` and marked `BABYLON13`. Ordinary SPLURT builds
compile those blocks out.

Both Babylon builds define `BABYLON_BUILDER` (any Babylon cluster world). Each also
defines exactly one game build define, checked at compile time in
`modular_babylon/__DEFINES/babylon.dm`: `BABYLON_DRONE` (`babylon.dme`, the drone
builder) or `BABYLON_STATION` (`babylon-station.dme`). Hooks that only fit the drone
builder are guarded with the positive `#ifdef BABYLON_DRONE`, never with "not
`BABYLON_STATION`", so a third build gets none of them by accident: the announcement
suppression (`priority_announce.dm`), the round-start divergency report, and
the 255x255 single-level sizing in `mapping.dm`. All other hooks (admission,
showcase visitors, persistence preloading, material pruning, the Discord button,
the SQL message guard, the master's restore wait) apply to both builds. The
station build keeps the full CentCom map (its shuttle docks are needed for a
round) and skips the Interlink (`ABSOLUTE_MINIMUM`).

Module split: `world_flags.dm` (`GLOB.babylon_world`, the supervisor's world
parameters and `babylon_world_ready()`), `state.dm`, `persistence.dm` (engine,
with per-build hooks `checkpoint_hold`, `checkpoint_mobs`,
`capture_session_state`, `restore_session_state`), admission, control, AFK,
showcase, spectator, SFW, links, storyteller, moderation, world players,
interface, music and play time are in both builds. `rules.dm` (Babylon's world
rules: one 255x255 level, no events, storyteller subsystem, weather or minor
mapping), `session.dm`, drone recovery, builder experience, lore, vault,
survival, silicons and research are only in `babylon.dme`;
`station_session.dm` only in `babylon-station.dme`.

The wrapper also defines upstream's `ABSOLUTE_MINIMUM` flag to skip the
separate Interlink/cafe map loader. Builder behavior, restricted observer
interfaces and lore papers live under `modular_babylon`; lore placements are
applied to the fresh upstream map at preparation time, without a copied map.

Babylon is safe for work. `modular_babylon/code/sfw.dm` disables inherited
ERP content through proc and var overrides only (no upstream edits): it locks
`DISABLE_ERP_PREFERENCES`/`DISABLE_LEWD_ITEMS` on, filters lewd interactions,
emotes, research designs and chemistry, removes the Plug13 verb, and opens the
new Babylon-only `tgui/packages/tgui/interfaces/BabylonInteraction.tsx`
instead of SPLURT's `MobInteraction` window. After an upstream merge, re-check
newly added lewd interactions, designs, reactions and verbs against it.

The Creative panel (`modular_babylon/code/creative/`, both builds) adds the new
Babylon-only `tgui/packages/tgui/interfaces/BabylonCreative.tsx` (with its
`BabylonCreative.test.tsx`); no upstream file is edited. After an upstream
merge, re-check new round events and spawnable types against its blacklists
(`babylon_creative_event_blocked`, `babylon_creative_spawn_blocked`).

Babylon has no storyteller yet. `modular_babylon/code/storyteller.dm` runs an
inert `/datum/storyteller/babylon` in every Babylon world (no events, no
antagonists), refuses the storyteller vote and any other storyteller, and keeps
tgstation's random events off, again through overrides only. Station worlds run
SPLURT's storytellers without a vote: `DEFAULT_STORYTELLER` from the config,
else `/datum/storyteller/default` (SSgamemode's choice without a vote); Creative
Plane maps and tutorial worlds are inert like Babylon. After an upstream merge,
re-check `SSgamemode`'s `set_storyteller`/`init_storyteller`, the storyteller
vote and `SSevents.spawnEvent` against it; the native smoke test asserts it.

Round control in station worlds (`modular_babylon/code/station_round.dm`,
station build only) needs no upstream edits either; it overrides procs:
`SSticker` `setup`, `standard_reboot` and `fire` (the reboot HUD text), `/world/Reboot`,
`SSgamemode` `handle_pre_setup_roundstart_events`/`handle_post_setup_roundstart_events`,
`SSdynamic.on_latejoin`, and on the title screen (Skyrat's
`modular_skyrat/modules/title_screen`) `/mob/dead/new_player` `get_title_html`
(it inserts Babylon's colours/font, the round status and the owner's Start round
button after the menu's `<div class="container_nav">`), `Topic` and `Login`, plus
`/mob/dead/get_status_tab_items` and the tg lobby HUD's `time_remaining_str`.
The round is held with `SSticker.SetTimeLeft(-1)` and started with
`start_immediately`. After an upstream merge, re-check the title screen markup
(`container_nav`), `declare_completion` → `standard_reboot`, the ticker's
pre-game countdown and `setup()`, and the storyteller's roundstart event procs.

Station saves (`modular_babylon/code/persistence_levels.dm`, station build only)
need no upstream edits either. A world restoring from a save (its
`data/next_map.json` names `_maps/babylon/saved`) overrides `SSmapping`
`Initialize` (the map config's level traits come from the save, no height
autosetup, no space/wilderness levels), `LoadGroup` (only the "Station" group
loads), `setup_ruins`, `setup_rivers`, `run_map_terrain_generation`,
`run_map_terrain_population` and `SSminor_mapping.Initialize`; every override
falls through to tg's proc otherwise. Shuttles are saved as the turf beneath
them (`baseturf_skipover/shuttle` in the tile's baseturfs) and stationary docks
keep `shuttle_id`, size, `roundstart_template` and `json_key` in the saved map.
After an upstream merge, re-check `SSmapping.Initialize`/`loadWorld` (new
generated levels or terrain steps must be skipped when restoring), the
stationary port vars and `/obj/docking_port/mobile/jumpToNullSpace` (how a
shuttle tile's underlying turf and area are found), and
`/datum/map_config/LoadConfig`'s trait defaults.
The master's restore-wait hook (`code/controllers/master.dm`, both builds)
counts its waiting rounds as loop iterations: a station restore takes long
enough that the failsafe otherwise restarted the controller in the middle of
initialization.

The Creative Plane maps (`modular_babylon/code/creative/plane.dm`, station build
only; maps generated by `tools/babylon/gen_creative_plane.py`) have no shuttle
docks. On any map without the `emergency_home` dock the module overrides
`SSshuttle.canEvac` (refused with a message), `SSshuttle.CheckAutoEvac` (no
crew-death autocall) and `/obj/docking_port/mobile/emergency/request` (any other
call is refused and logged); without `cargo_home`, the cargo console's `ui_act`
refuses "send"/"loan" with a message; and `/obj/docking_port/mobile/request`
ignores a request to a missing (null) dock. Maps with the docks are unchanged.
The creative canister (`creative/machines.dm`) overrides
`portable_atmospherics` `connect`/`disconnect` to reconnect itself to the port on
its tile (mapped plane, restored saves). After an upstream merge, re-check those
shuttle procs, the cargo console's actions and `portable_atmospherics/connect`;
the station smoke asserts them on every Creative Plane map.

`modular_babylon/code/moderation.dm` grants lobby admins (`BABYLON_ADMINS`) full
game-admin rights on admission, removes mentors (no mentor is loaded, admins
are not made mentors, Mentorhelp and Mentorwho are gone) and relays adminhelps
to the supervisor for the Discord `ahelp` feature; Discord replies use the
game's external admin PM (`TgsPm`). All through overrides. After an upstream
merge, re-check `MessageNoRecipient`, `reply_to_admins_notification`,
`receive_ahelp`, `TgsPm` and the Skyrat mentor module against it.

`modular_babylon/code/research.dm` replaces the research point bank and queue:
a techweb researches one selected node at a time, all income (through
`add_point_list`) goes towards it capped at its price, `research_points` holds
that progress, income without a target is dropped and switching targets starts
over. The target is saved with the world. After an upstream merge, re-check
`add_point_list`, `research_node`, `complete_experiment`, the queue procs and
the R&D console / PDA `research_node` and `ui_data` against it. `sfw.dm` (both
builds) removes designs no world offers (ERP; in Babylon also pAI, AI core, MMI,
positronic brain) from every node in
`SSresearch.calculate_techweb_nodes` and refuses them in `/datum/techweb/add_design`;
`/datum/techweb_node/Initialize` is not usable for that, because upstream's
`initialize_all_techweb_nodes` calls it on the old, empty node list.

`modular_babylon/code/silicons.dm` removes pAIs, station AIs, MMIs and positronic
brains, which no one can play: pAI cards, AI cores and loose MMIs/posibrains delete
themselves on creation (wreck, saves, loot), their designs are removed,
the plasteel "AI core" recipe and the PDA vendor's pAI cards are gone, and ghosts
get no "Enter Soulcatcher" button. After an upstream merge, re-check new sources
of pAI cards, AI cores and ghost-joinable silicons against it.

`modular_babylon/code/interface.dm` trims the game window through overrides and
runtime winsets (the shared `interface/skin.dmf` is unchanged): the top bar keeps
Menu, Settings, Fullscreen and Reconnect in four evenly sized columns, measured again
on resize; world verbs appear in **World Controls**, directly after Status (including
for non-admins). The station is named after the world
(`babylon-name`, markup characters removed); the status tab drops the round ID;
and verbs for systems Babylon lacks (antag tickets, OPFOR, round-end reports,
votes, respawn, relays, forum/Discord-DB linking ...) are removed. After an
upstream merge, check new player verbs and the `infobuttons` controls.

| Upstream file | Purpose |
| --- | --- |
| `code/controllers/master.dm` | Wait for restoration and final subsystem initialization before physics runs; support the isolated-test hold parameter. |
| `code/controllers/subsystem/mapping.dm` | Size the standalone map for Babylon and account for already allocated, unregistered lobby levels (not in the station build). |
| `code/modules/mapping/preloader.dm` | Apply saved structural properties before atom initialization builds pipes and power networks. |
| `code/game/machinery/computer/atmos_computers/_air_sensor.dm` | Skip fresh-map automatic vent claiming for restored sensors. |
| `code/__HELPERS/priority_announce.dm` | Suppress round announcements and command reports in the builder world (not in the station build). |
| `modular_zubbers/code/modules/storyteller/divergency_report.dm` | Suppress round-start station-trait reporting (not in the station build). |
| `code/modules/client/client_procs.dm` | Validate single-use lobby admission before registering a child client or creating an avatar; a refused client goes back to the lobby with the refusal's notice (`babylon_lobby_link()`). Enforce showcase play mode and restrict visitor Topics/clicks before target dispatch. Standalone builds restrict access to their configured owner. |
| `code/modules/escape_menu/escape_menu.dm` | Add the Discord button (`modular_babylon/code/links.dm`) to Resources when `DISCORDURL` is set. |
| `code/controllers/subsystem/verbs.dm` | Enforce the visitor verb allowlist for native/context verbs, including verbs belonging to world objects. |
| `code/_onclick/drag_drop.dm` | Reject showcase visitor mouse-down/up, drag and drop before target handlers or signals run. |
| `code/modules/keybindings/bindings_client.dm` | Limit visitor shortcuts to chat and harmless display controls; normal movement handling remains available. |
| `code/modules/mob/mob_movement.dm` | Enforce the visitor body before accepting movement, including reconnects from a former playable body. |
| `code/modules/atmospherics/machinery/components/unary_devices/airlock_pump.dm` | Skip fresh-install door animations for saved pumps; rebuild their saved connections after restoration. |
| `code/datums/materials/material_container/material_container.dm` | Discard invalid material keys before UI generation and stock accounting, preserving valid quantities. |
| `tgui/packages/tgui-panel/settings/atoms.ts`, `migration.ts` | Default the chat panel (and with it the window) to the dark theme, and apply the default theme on a player's first start. Players' saved choices are kept. |
| `tgui/packages/tgui/interfaces/Techweb/Content.tsx`, `nodes/TechNode.tsx`, `types.ts` | When the server sends `babylon_research`, show the node being researched instead of point balances and the queue, a Research / Researching button instead of research and queue buttons, and progress only on that node. Without it, the upstream screens are unchanged. |
| `tgui/packages/tgui-escape-menu/EscapeMenu.tsx`, `pages/PlayersPage.tsx` | When the server sends `babylon`, hide the Round ID line and the "No Admins Online!" heading. Unchanged otherwise. |
| `html/statbrowser.js` | Place World Controls immediately after Status, before MC and Admin. Verb categories are defined in modular Babylon code. |
| `code/modules/admin/sql_message_system.dm` | Without a database (`SQL_ENABLED` off), `get_message_output` returns quietly instead of telling every player at login that the database connection failed. |
| `tgui/packages/tgui/interfaces/VaultController.tsx` | Render the Babylon generation interlock (live generation, ignored battery output, hold timer) when the controller sends those fields; the upstream charge view is unchanged otherwise. Rebuild the TGUI bundle after editing. |

Keep these patches small. Do not copy complete upstream files from the local
prototype. When upstream changes a hook's surrounding procedure, review its
execution order, not just whether Git merges the text cleanly. In particular,
moving restoration after simulation startup reintroduces reactor/network bugs.

Two SPLURT pull requests are merged here ahead of upstream: #1395 (rough player
positions through the tgui panel's websocket relay: `tgstation.dme`,
`config/splurt/game_options.txt`, `modular_zzplurt/.../atlas_position.dm`,
`tgui/packages/tgui-panel/websocket/helpers.ts`) and #1396 (the stat panel's map
entry links to the SPLURT atlas: `code/modules/client/client_procs.dm`
`openWebMap`, `config/maps.txt` `webmap_url`s). They are not Babylon hooks: when
upstream merges them, take upstream's version. Babylon worlds use
`container/default-config`, which has no `maps.txt`, so their stat panel shows no
map link and send no position updates (both need the map's atlas URL). The link uses
the z within the station levels (`atlas_station_z()`); position updates send both the
world z (`z`) and that station z (`station_z`), plus the map's name (`map`) and atlas
key (`map_key`); a `webmap_url` without a `#` fragment still gets a working link. These follow-up
fixes are their own commits, so they can be offered to the two pull requests.

Upstream bug fixes (not Babylon hooks, no `BABYLON13` marker; report them upstream and take
upstream's version once it has its own fix): a shared list (a proc's `var/static/list` or a
`GLOB` list) was assigned to a variable and then changed in place, so the change reached every
user of the shared list. Each assignment now takes a `.Copy()`:
`code/modules/antagonists/cult/cult_structure_altar.dm`, `cult_structure_archives.dm` and
`cult_structure_forge.dm` (`options += extra_item` added the unlocked orb, medallion or cursed blade
again on every use), `code/modules/fishing/fishing_portal_machine.dm` (the "all destinations"
menu wrote the linked fishing spots into `GLOB.preset_fish_sources`),
`code/modules/clothing/suits/armor.dm` (subtypes such as the durathread vest and the elder
atmosian armor added their items to `GLOB.security_vest_allowed`, so to every armor vest) and
`code/modules/mining/lavaland/mining_loot/berserker.dm` (the gatsu armor added the dragonslayer
to `GLOB.mining_suit_allowed`). `tools/babylon/test_shared_list_aliases.py` fails when the
pattern comes back; the cases it allows are listed there with their reason.

Core-proc overrides of the tutorial module (modular, no upstream edit; merge upstream signature
changes into them): `modular_babylon/code/tutorial/room_reset.dm` re-declares
`/obj/item/melee_attack_chain` and `/atom/base_ranged_item_interaction` (every item use on an
atom, near and at range) to refuse item use inside a live Paste area's protected source while a
tutorial runs (`babylon_tutorial_blocks_building`; builder wands, mobs and carried items are
exempt). `tutorial/npc.dm` overrides `/mob/living/CanAllowThrough`,
`/mob/living/carbon/attach_rot` and `/obj/item/organ/on_death` for anchored and spawn-dead
tutorial NPCs.

Persistence overrides (both builds; modular, no upstream edit; merge upstream signature changes
into them and re-check what each one relies on after every upstream merge):
- `modular_babylon/code/persistence.dm`:
  - `/datum/controller/subsystem/atoms/InitAtom`: a hot path with a copied argument list
    (`atom/A, from_template, list/arguments`) and the `INITIALIZE_HINT_*` contract. It marks
    companions (objects made during another atom's Initialize). Check its argument list and the
    hint handling first.
  - `/datum/controller/subsystem/mapping/LoadGroup` (saved levels instead of the fresh map).
  - `/turf/open/floor/MakeDirty`, `/datum/controller/subsystem/processing/station/SetupTraits`,
    `/datum/controller/subsystem/decay/Initialize` and `/datum/controller/subsystem/area_spawn/Initialize`
    (fresh-map rolls that stand back for a resumed world).
  - Mapload defaults that stand back while a save loads (`babylon_loading_saved_map()`):
    `/obj/structure/closet/emcloset/Initialize`, `/obj/item/stack/merge_with_loc` (no stack
    merging while a save loads), `/obj/machinery/disposal/bin/spawn_contained_animal`,
    `/mob/living/basic/bot/mulebot/Initialize`, `/obj/machinery/light/Initialize`,
    `/obj/machinery/camera/Initialize`, `/obj/structure/reflector/Initialize`.
  - `babylon_after_restore` / `babylon_capture_settings` on lights, cameras, bots, ID cards and
    mechs (`/obj/vehicle/sealed/mecha`): they read upstream variables (`cell`, `has_mock_cell`,
    `camera_enabled`, `can_be_possessed`, `trim`, equipment slots).
- `modular_babylon/code/station_round.dm`: `/world/Reboot` (saves a running round, then stops),
  `/datum/controller/subsystem/ticker/standard_reboot` and `fire`.
- `modular_babylon/code/station_characters.dm`: `/obj/machinery/cryopod/mouse_drop_receive`
  (Skyrat's cryopod: a restored character waits for its player).

The restore paths run without a `try` in some places and under the subsystem's `try` in others:
a new harmless `stack_trace` in a restore path makes worlds refuse to start ("Restore failed")
until it is fixed. That is deliberate (a half restore would be written over the world by the
next save), so run `smoke_native.py` and `smoke_station.py` (including its stability step) after
every upstream merge.

## BYOND 516.1686 slot quirk

DreamMaker 516.1686 (`.tgs.yml`) sometimes mishandles whichever variable lands on one
particular internal slot. It has shown up as a proc's static list that is "invalid"
(`code/modules/antagonists/cult/cult_structure_altar.dm:41: error: altar_items:
invalid variable`, `archive_items` in `cult_structure_archives.dm`) and as a local that is
plainly used but reported as `warning (unused_var)` (`suspect_gloves` in
`forensics_helpers.dm`, `loser_controller` in `cat_bt.dm`, `plant_smudge` in
`plant_genes.dm`). The reported file is never the cause: any change that adds or removes
a variable anywhere in the build moves the slot onto another variable, so the same
change can break one build and not the other three. Treat a build that shows it as
possibly miscompiled, not as noise: the slot is used for code generation too, and a
clean build only means that whichever variable holds the slot now gives no diagnostic.
A local that really is never read is an ordinary warning, not the quirk.
It can also miscompile with no diagnostic at all: in the final review (H2) a clean
`babylon-station-test.dme` build failed one tutorial test (an NPC's "All doors" walk)
three times in a row, and the same code passed once a padding global moved the slot. A
test that fails for no visible reason after an unrelated change is worth one pad move.

Recipe: add or remove one padding global (`var/global/babylon_byond_1686_slot_pad_<n>`)
in the block for the affected build at the end of `modular_babylon/code/world_flags.dm`,
then compile all four builds again (repeat until all are clean). The pads do nothing
else; remove the block once a BYOND build fixes the quirk (check newer 516 builds when
bumping `.tgs.yml`). `tools/babylon/build_dme.py`, which the Dockerfile uses for every
DreamMaker run, prints this recipe when a build log shows the quirk's signature, and then
fails the build (exit 1), so an image is never built from a possibly miscompiled build. A
maintainer who checked that the warning is a real unused local (not the quirk) and fixed it
does not need the escape hatch; `BABYLON_ALLOW_SLOT_QUIRK=1` lets such a build pass anyway.

## Updating upstream

```sh
git remote add upstream https://github.com/SPLURT-Station/S.P.L.U.R.T-tg.git
git fetch upstream
git merge upstream/master
```

Skip `remote add` if the remote already exists. Preserve upstream history;
do not squash upstream into this repository or force-push over its branches.

After every merge:

1. Review every `BABYLON13` marker and the standalone wrapper.
2. Rename newly introduced `.github/workflows/*.yml` / `*.yaml` files with a
   `.disabled` suffix before pushing. Keep repository Actions disabled too.
3. Compile ordinary `tgstation.dme`, production `babylon.dme`, and the local
   `babylon-test.dme` test build.
4. Exercise a fresh wreck, a save/reload, pipe expansion, vent/alarm links,
   materials, airlock groups, and drone death/respawn. Use an isolated process
   and disposable world; never point tests at a player's running instance.
5. Run `services/supervisor/smoke_native.py` and `smoke_station.py` (with its stability
   step): a new upstream `stack_trace` in a restore path stops worlds from starting, and a
   new random roll in an `Initialize` changes saved worlds on every restart.

The private prototype's six upstream hooks were carried forward. Its chat
transcript patch, personal config, owner name, repair object IDs, saved world,
and training/admin subsystem were deliberately not imported.
