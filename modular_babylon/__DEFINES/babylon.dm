// Defines shared by every Babylon cluster build (babylon.dme, babylon-station.dme). Included
// before modular_babylon/code/*.dm.

/// state.json "version" written by Babylon (drone builder) checkpoints: one map.dmm.
#define BABYLON_STATE_VERSION 7
/// state.json "version" written by station-build checkpoints: z<N>.dmm per level and "levels"
/// (services/supervisor/fixtures/README.md). Readers branch on version and keys, never on build.
#define BABYLON_STATION_STATE_VERSION 8

/// Sent by /datum/babylon_save/tick_world() once a second, after the build's player loop:
/// (datum/babylon_save/session). Modules register a handler on GLOB.babylon_save instead of
/// overriding tick_world (guarded by tools/babylon/test_tick_override.py).
#define COMSIG_BABYLON_WORLD_TICK "babylon_world_tick"
