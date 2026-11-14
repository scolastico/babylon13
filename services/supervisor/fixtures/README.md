# Supervisor test fixtures

## station_state.json

The save contract of a station-build world (`babylon-station.dmb`): a minimal but complete
example of one checkpoint's `state.json`, as `data/babylon/saves/<generation>/state.json`. Next
to it, a station checkpoint holds one map file per saved level (`z2.dmm`, `z3.dmm`, ...).
`test_station_save_contract.py` checks the fixture against this description and feeds it through
`Driver.prepare_station`.

Writers and readers:

- **DM** is `modular_babylon/code/persistence.dm` (shared save engine) and the station session
  (`station_session.dm`, `station_round.dm`). DM writes every key when it saves and reads them back
  in `restore_world()` from `data/babylon/resume-state.json`.
- **Supervisor** is `services/supervisor`: `Driver.prepare_station` (supervisor.py) and
  `checkpoints.py`.

The layout and the version are separate things:

- **Layout** is a property of the build. A Babylon (`babylon.dmb`) checkpoint has one `map.dmm`, no
  `levels` key, and records and turfs without `z`. A station checkpoint has one `z<N>.dmm` per
  saved level, a `levels` key, and a `z` on every record and turf. The DM writer picks it with
  `writes_level_files()` (persistence.dm, overridden by the station build), and the supervisor's
  `Driver.prepare` picks the reader by the world's build (`build_of`, from the map catalog). The DM
  restore reads it from the keys (`z` present or not).
- **Version** is only for migrations within a build's own format: the DM restore branches on it
  to repair older saves (`version < 2`, `< 7`, ...). Bumping either build's version never changes
  the layout. Babylon checkpoints are at version 7, station checkpoints at version 8. The DM
  constants are `BABYLON_STATE_VERSION` and `BABYLON_STATION_STATE_VERSION` in
  `modular_babylon/__DEFINES/babylon.dm`.

| Key | Written by | Read by | Meaning |
| --- | --- | --- | --- |
| `version` | DM | DM restore | Format version: 8 for station saves (Babylon: 7). |
| `generation` | DM | DM (last save), checkpoints.py | Directory name `save-YYYYMMDD-hhmmss-N`. `latest.json` names the current one. |
| `next_id` | DM | DM | Next free `babylon_save_id` number (`bb<N>`). |
| `save_count` | DM | DM | Saves so far; the `N` in the generation name. |
| `records` | DM | DM, checkpoints.py (count) | Saved objects. Each has `id`, `type`, `parent` (the id of the container, or null for objects on a turf), `x`, `y`, `z`, `fields`, `references`, plus type-specific keys. A record without `z` (Babylon) belongs to the station level. |
| `turfs` | DM | DM | Temperature and air of non-space turfs: `x`, `y`, `z`, `temperature`, optional `gas`. A turf without `z` (Babylon) belongs to the station level. |
| `levels` | DM | Supervisor (`prepare_station`), DM restore | The saved levels in load order: `file` (`z<N>.dmm`, N is the level's z in the saving world) and `traits` (that level's tg z-level traits exactly as loaded, the same shape as one entry of a map json's `traits`; the supervisor also accepts a list of such objects for a file holding several z). The restoring world loads the levels with these traits, not with the map json's. |
| `map_config` | DM | Supervisor (`prepare_station`) | The map's tg map json as the world loaded it. The supervisor rewrites `map_path`, `map_file` and `traits` from `levels` into `data/next_map.json`, so the world loads the saved levels instead. |
| `round` | DM | DM (`station_round.dm`) | `started`: the round had started (the next start resumes it). `station_time`: the station clock in deciseconds. |
| `players` | DM (shared engine) | DM | Per-player records by ckey, the same path in both builds (`capture_players`/`restore_players`, state.dm): `play_time` (deciseconds), plus the Babylon build's drone fields. Empty in a tutorial snapshot. |
| `characters` | DM | DM; blanked by the supervisor's tutorial copies (`tutorials.py`) | Player bodies by ckey (`station_characters.dm`), saved apart from the levels' `records` (a reused level never carries them): `id`, `type`, `x`, `y`, `z`, `real_name`, `gender`, `physique`, `age`, `species`, `dna` (enzymes, identity, features, mutant parts, markings, blood type), `job`, `stat`, `ghost` (the player comes back as its ghost), `bodyparts` (`zone`, `brute`, `burn`), `tox`, `oxy` and `records`: the items, as records whose `parent` is the character (worn ones with a `slot` flag or a `hand` index) or one of its items. Rebuilt only when `round.started`. Always `{}` in a tutorial snapshot (`babylon_world_saves_characters()`, world_flags.dm). |
| `sun` | DM (shared engine) | DM | `SSsun` azimuth, azimuth_mod and base_rotation. |
| `play_time` | DM (shared engine) | DM | Deciseconds the world was played. |

DM writes booleans as `1`/`0` (BYOND `json_encode`). Readers accept `true` and `1` alike.

## babylon_v7 and babylon_v5

Golden checkpoints of the Babylon (drone builder) build from before the station rework, kept to
prove that existing worlds still load. `babylon_v7/` (`map.dmm` and `state.json`, generation
`save-20261114-165619-1`) was written unchanged by the `a9c41016abe` build of `babylon-test.dme`,
with a scratch setup proc that only placed content before an ordinary managed stop saved the
world (owner `fixtureowner`):

- the owner's drone "Fixture owner drone" (`builder` `bb1620`) and a second player's drone
  "Fixture friend drone" (`fixturefriend`) holding a wrench;
- a closed "Fixture locker" with 7 iron sheets and a crowbar;
- a secured "Fixture frame" with a tesla coil board and one capacitor already inserted;
- the airlocks "Fixture airlock A" and "Fixture airlock B", paired by `closeOtherId`
  `fixture_pair`;
- research: `gas_compression` researched, `circuit_shells` the current target with 5 points.

`babylon_v5/state.json` is the same checkpoint in the version 5 shape: `version` 5 and no
`players` key, so the owner's record is the top-level `player` with the top-level `builder` (the
legacy owner mapping). It loads with `babylon_v7/map.dmm`.

`test_driver.py` checks that `Driver.prepare` stages both unchanged; `smoke_native.py` restores
both in a real world (`test_legacy_babylon_restore`, testing.dm) and checks the content above.
Never regenerate them with a newer build: their point is the old writer's output.
