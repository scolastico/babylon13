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

Readers branch on `version` and on which keys are present, never on the build. Babylon
(`babylon.dmb`) checkpoints stay at version 7, with one `map.dmm` and no `levels` key. Station
checkpoints start at version 8. The DM constants are `BABYLON_STATE_VERSION` and
`BABYLON_STATION_STATE_VERSION` in `modular_babylon/__DEFINES/babylon.dm`.

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
| `characters` | DM | DM | Player characters by ckey (Task D2). Empty (`{}`) until then. |
| `sun` | DM (shared engine) | DM | `SSsun` azimuth, azimuth_mod and base_rotation. |
| `play_time` | DM (shared engine) | DM | Deciseconds the world was played. |

DM writes booleans as `1`/`0` (BYOND `json_encode`). Readers accept `true` and `1` alike.
