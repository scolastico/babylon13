// Defines shared by every Babylon cluster build (babylon.dme, babylon-station.dme). Included
// before modular_babylon/code/*.dm.

/// state.json "version" written by Babylon (drone builder) checkpoints: one map.dmm.
#define BABYLON_STATE_VERSION 7
/// state.json "version" written by station-build checkpoints: z<N>.dmm per level and "levels"
/// (services/supervisor/fixtures/README.md). Readers branch on version and keys, never on build.
#define BABYLON_STATION_STATE_VERSION 8
