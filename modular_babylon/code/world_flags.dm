// What this world is, as the supervisor started it. Shared by both game builds.
// The supervisor passes babylon-build, babylon-persistent, babylon-creative, babylon-kind,
// babylon-tutorial and babylon-map (services/supervisor/supervisor.py, Driver.start).

GLOBAL_DATUM_INIT(babylon_world, /datum/babylon_world, new)

/datum/babylon_world
	/// "babylon" (drone builder, babylon.dmb) or "station" (tg rounds, babylon-station.dmb).
	/// Always the compiled build; a babylon-build parameter that disagrees is only logged.
	var/build
	/// Saves and autosaves are enabled.
	var/persistent = TRUE
	/// Every player gets the Creative panel.
	var/creative = FALSE
	/// "world" (an ordinary world), "tutorial" (a throwaway play instance) or "tutorial_edit"
	/// (an admin editing a pending tutorial).
	var/kind = "world"
	/// The tutorial a tutorial or tutorial_edit world plays, else null.
	var/tutorial_id
	/// The map catalog id (_maps/babylon/catalog.json), e.g. "babylon", "metastation".
	var/map_id
	/// The world owner's ckey.
	var/owner_ckey

/datum/babylon_world/New()
	. = ..()
	var/list/params = world.params
	build = babylon_is_station_build() ? "station" : "babylon"
	var/requested_build = params["babylon-build"]
	if(requested_build && requested_build != build)
		log_world("Babylon: started with babylon-build=[requested_build], but this is the [build] build.")
	persistent = babylon_param_flag(params["babylon-persistent"], TRUE)
	creative = babylon_param_flag(params["babylon-creative"], FALSE)
	var/requested_kind = params["babylon-kind"]
	kind = (requested_kind in list("world", "tutorial", "tutorial_edit")) ? requested_kind : "world"
	var/requested_tutorial = params["babylon-tutorial"]
	if(kind != "world" && babylon_safe_id(requested_tutorial))
		tutorial_id = requested_tutorial
	var/requested_map = params["babylon-map"]
	map_id = babylon_safe_id(requested_map) ? requested_map : (build == "babylon" ? "babylon" : null)
	owner_ckey = ckey(params["babylon-owner"])

/datum/babylon_world/proc/is_tutorial()
	return kind == "tutorial" || kind == "tutorial_edit"

/// Creative Plane worlds (catalog group "creative_plane": ids creative_plane_s/m/l).
/datum/babylon_world/proc/is_creative_plane()
	return findtext(map_id, "creative_plane") == 1

/// "1"/"0" world parameters; anything else (or none) is the default.
/proc/babylon_param_flag(value, default_value)
	if(value == "1")
		return TRUE
	if(value == "0")
		return FALSE
	return default_value

/// Catalog and tutorial ids: letters, digits, _ and -, at most 64 characters.
/proc/babylon_safe_id(value)
	if(!istext(value) || !length(value) || length(value) > 64)
		return FALSE
	// Runs during global init (GLOB.babylon_world), before static vars exist: no static regex.
	var/regex/allowed = regex(@"^[A-Za-z0-9_-]+$")
	return allowed.Find(value) != 0

/// This process is the station build (babylon-station.dme).
/proc/babylon_is_station_build()
#ifdef BABYLON_STATION
	return TRUE
#else
	return FALSE
#endif

/proc/babylon_creative_enabled()
	return !!GLOB.babylon_world?.creative

/proc/babylon_persistence_enabled()
	return !!GLOB.babylon_world?.persistent

/// The world can admit players and answer the supervisor's status as ready. Babylon: the
/// builder session has restored the world and booted. Station: the master controller has
/// initialized everything, the visitor/spectator spawn point is set and the ticker reached the
/// pre-round lobby (or a later state); worlds whose round starts at once (tutorials, resumed
/// rounds: station_round.dm) are ready once it runs, so nobody arrives during its setup.
/proc/babylon_world_ready()
	var/datum/babylon_save/session = GLOB.babylon_save
#ifdef BABYLON_STATION
	return session && !session.boot_error && session.prepared && session.respawn_turf && Master.init_stage_completed >= INITSTAGE_MAX && SSticker.current_state >= (session.round_mode == "hold" ? GAME_STATE_PREGAME : GAME_STATE_PLAYING)
#else
	return !!session?.ready
#endif
