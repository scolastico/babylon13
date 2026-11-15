// Defines shared by every Babylon cluster build (babylon.dme, babylon-station.dme). Included
// before modular_babylon/code/*.dm.

// Exactly one game build define: BABYLON_DRONE (babylon.dme) or BABYLON_STATION
// (babylon-station.dme). Code for one build tests its own define, never the absence of the other.
#if defined(BABYLON_DRONE) && defined(BABYLON_STATION)
#error Babylon: define only one of BABYLON_DRONE (babylon.dme) and BABYLON_STATION (babylon-station.dme).
#endif
#if !defined(BABYLON_DRONE) && !defined(BABYLON_STATION)
#error Babylon: define BABYLON_DRONE (babylon.dme) or BABYLON_STATION (babylon-station.dme).
#endif

/// state.json "version" written by Babylon (drone builder) checkpoints, for migrations only. The
/// layout (one map.dmm) is /datum/babylon_save/proc/writes_level_files(), not this number.
#define BABYLON_STATE_VERSION 7
/// state.json "version" written by station-build checkpoints, for migrations only. The layout
/// (z<N>.dmm per level and "levels", services/supervisor/fixtures/README.md) is writes_level_files().
#define BABYLON_STATION_STATE_VERSION 8

/// Sent by /datum/babylon_save/tick_world() once a second, after the build's player loop:
/// (datum/babylon_save/session). Modules step with it through a /datum/babylon_tick_listener (state.dm)
/// instead of overriding tick_world (guarded by tools/babylon/test_tick_override.py).
#define COMSIG_BABYLON_WORLD_TICK "babylon_world_tick"

/// How long a world waits for the supervisor's answer to an ordinary request (redeem, world
/// management, round end, adminhelp relays): babylon_supervisor_request_within().
#define BABYLON_SUPERVISOR_TIMEOUT (30 SECONDS)
/// Largest piece a save file is written in (babylon_write_pieces()): large DM strings written at
/// once came out truncated or damaged.
#define BABYLON_SAVE_PIECE_BYTES 1048576
