// What this world is, as the supervisor started it. Shared by both game builds.
// The supervisor passes babylon-build, babylon-persistent, babylon-creative, babylon-kind,
// babylon-tutorial, babylon-tutorial-title and babylon-map (services/supervisor/supervisor.py, Driver.start).

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
	/// That tutorial's title (shown when a player completes it), else null.
	var/tutorial_title
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
		// The supervisor cleans it (Driver.tutorial_title); kept to one line of at most 60 characters.
		var/requested_title = params["babylon-tutorial-title"]
		if(istext(requested_title) && length(requested_title))
			tutorial_title = copytext_char(replacetext(replacetext(requested_title, "\n", " "), ascii2text(13), " "), 1, 61)
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
#elif defined(BABYLON_DRONE)
	return FALSE
#endif

// ---------------------------------------------------------------------------------------------
// The world-type policy: every rule that depends on what kind of world this is lives here, in one
// table, as methods of /datum/babylon_world (read from build, persistent, creative, kind and the
// map). The supervisor keeps a copy (services/supervisor/constants.py world_policy());
// services/supervisor/test_contracts.py evaluates both for every world type and fails if they
// differ, so keep each method a single "return" of a plain expression over those fields.
// A new kind or map group is added here, and nowhere else.

/// Every player gets the Creative panel.
/datum/babylon_world/proc/creative_enabled()
	return creative

/// Tutorials can be played and edited here: the station build with Creative enabled.
/datum/babylon_world/proc/tutorial_capable()
	return build == "station" && creative

/// A tutorial can be submitted from here (G1b): a tutorial-capable ordinary world.
/datum/babylon_world/proc/can_submit_tutorial()
	return tutorial_capable() && kind == "world"

/// A save goes back to the pending tutorial from here (G1b): an admin's tutorial edit world.
/datum/babylon_world/proc/can_save_back_tutorial()
	return kind == "tutorial_edit"

/// The creative machines' infinite behaviour runs (creative/machines.dm): Creative worlds,
/// tutorial instances (an authored scenario keeps its creative power and air, though its players
/// have no Creative panel) and Creative Plane maps (the map's own power and air, whatever the
/// Creative flag).
/datum/babylon_world/proc/creative_machines_active()
	return creative || is_tutorial() || is_creative_plane()

/// A supermatter delamination only explodes: no singularity, tesla ball or resonance cascade
/// (creative/supermatter.dm). Wherever creative machines run, so a Creative Plane map always
/// contains it, with or without the Creative flag.
/datum/babylon_world/proc/delam_contained()
	return creative || is_tutorial() || is_creative_plane()

/// Only the inert Babylon storyteller runs, with no random events (storyteller.dm): the Babylon
/// build, tutorial instances and Creative Plane maps.
/datum/babylon_world/proc/storyteller_inert()
	return build == "babylon" || is_tutorial() || is_creative_plane()

/// Fresh Creative Planes preserve their authored floors and continuous perimeter catwalk.
/// Ordinary maps keep Skyrat's configured startup decay, including in Creative worlds.
/datum/babylon_world/proc/startup_decay_enabled()
	return !is_creative_plane()

/// Checkpoints are written (autosaves, the owner's save, a save on stop): persistent worlds that
/// are not tutorial instances. A forced save (a tutorial submission) ignores it.
/datum/babylon_world/proc/saves()
	return persistent && !is_tutorial()

/// A managed stop saves first: exactly the worlds that save.
/datum/babylon_world/proc/stop_saves()
	return saves()

/// The round starts by itself as soon as the world is up, with no owner hold (station_round.dm):
/// tutorial instances.
/datum/babylon_world/proc/round_starts_at_once()
	return is_tutorial()

/// A player who joins is put into the tutorial's flow (station_round.dm): play instances. Admins
/// editing a tutorial test-run it themselves.
/datum/babylon_world/proc/plays_tutorial_on_join()
	return kind == "tutorial"

/// A checkpoint keeps the players' characters (bodies, inventories) and per-player records
/// (station_characters.dm, state.dm): every world but tutorial instances. A forced tutorial
/// snapshot never keeps them either (babylon_world_saves_characters(for_tutorial)).
/datum/babylon_world/proc/saves_characters()
	return !is_tutorial()

/// The stop message says the world is a tutorial, which is never saved (admission.dm).
/datum/babylon_world/proc/unsaved_as_tutorial()
	return is_tutorial()

// Global shorthands of the policy table, safe before GLOB.babylon_world exists.

/proc/babylon_creative_enabled()
	return !!GLOB.babylon_world?.creative_enabled()

/proc/babylon_persistence_enabled()
	return !!GLOB.babylon_world?.persistent

/proc/babylon_tutorial_capable()
	return !!GLOB.babylon_world?.tutorial_capable()

/proc/babylon_creative_machines_active()
	return !!GLOB.babylon_world?.creative_machines_active()

/proc/babylon_delam_contained()
	return !!GLOB.babylon_world?.delam_contained()

/proc/babylon_storyteller_inert()
	return !!GLOB.babylon_world?.storyteller_inert()

/proc/babylon_startup_decay_enabled()
	return !!GLOB.babylon_world?.startup_decay_enabled()

/proc/babylon_world_saves()
	return !!GLOB.babylon_world?.saves()

/proc/babylon_stop_saves()
	return !!GLOB.babylon_world?.stop_saves()

/// The policy table's saves_characters(), and never for a forced tutorial snapshot (for_tutorial: a
/// submission or save-back, from any world): the one rule for "tutorial snapshots carry no
/// characters". The supervisor's copy is world_policy()["saves_characters"] (constants.py), and
/// tutorials.py blanks them again in every snapshot it copies.
/proc/babylon_world_saves_characters(for_tutorial = FALSE)
	return !for_tutorial && !!GLOB.babylon_world?.saves_characters()

/// The world can admit players and answer the supervisor's status as ready: the session's own
/// ready flag, which also lets it save. Reporting ready before that flag was set (up to a second
/// later on station worlds) made a stop right after the start skip its save as "not finished
/// starting", and the smoke's ready check fail now and then.
/proc/babylon_world_ready()
	return !!GLOB.babylon_save?.ready

#ifdef BABYLON_STATION
/// Station: when station_boot() sets ready. The master controller has initialized everything,
/// the visitor/spectator spawn point is set and the ticker reached the pre-round lobby (or a
/// later state); worlds whose round starts at once (tutorials, resumed rounds: station_round.dm)
/// once it runs, so nobody arrives during its setup.
/proc/babylon_station_boot_complete()
	var/datum/babylon_save/session = GLOB.babylon_save
	return session && !session.boot_error && session.prepared && session.respawn_turf && Master.init_stage_completed >= INITSTAGE_MAX && SSticker.current_state >= (session.round_mode == "hold" ? GAME_STATE_PREGAME : GAME_STATE_PLAYING)
#endif

// ---------------------------------------------------------------------------------------------
// BYOND 516.1686 slot quirk (modular_babylon/UPSTREAM_HOOKS.md, "BYOND 516.1686 slot quirk"):
// DreamMaker mishandles whichever variable lands on one particular slot ("<static>: invalid
// variable", or a used local reported as "unused_var"). These padding globals do nothing; they only
// move that slot. If a build shows the quirk, add or remove one pad in that build's block below and
// compile all four builds again. Remove the block once a BYOND build fixes the quirk.
var/global/babylon_byond_1686_slot_pad_shared
#if defined(BABYLON_DRONE) && defined(BABYLON_TESTING)
// babylon-test.dme
var/global/babylon_byond_1686_slot_pad_drone_test_1
var/global/babylon_byond_1686_slot_pad_drone_test_2
var/global/babylon_byond_1686_slot_pad_drone_test_3
#elif defined(BABYLON_DRONE)
// babylon.dme
var/global/babylon_byond_1686_slot_pad_drone_1
var/global/babylon_byond_1686_slot_pad_drone_2
#elif defined(BABYLON_STATION) && defined(BABYLON_TESTING)
// babylon-station-test.dme
var/global/babylon_byond_1686_slot_pad_station_test_1
var/global/babylon_byond_1686_slot_pad_station_test_2
var/global/babylon_byond_1686_slot_pad_station_test_3
var/global/babylon_byond_1686_slot_pad_station_test_4
var/global/babylon_byond_1686_slot_pad_station_test_5
var/global/babylon_byond_1686_slot_pad_station_test_6
var/global/babylon_byond_1686_slot_pad_station_test_7
var/global/babylon_byond_1686_slot_pad_station_test_8
var/global/babylon_byond_1686_slot_pad_station_test_9
var/global/babylon_byond_1686_slot_pad_station_test_10
var/global/babylon_byond_1686_slot_pad_station_test_11
var/global/babylon_byond_1686_slot_pad_station_test_12
var/global/babylon_byond_1686_slot_pad_station_test_13
var/global/babylon_byond_1686_slot_pad_station_test_14
var/global/babylon_byond_1686_slot_pad_station_test_15
var/global/babylon_byond_1686_slot_pad_station_test_16
var/global/babylon_byond_1686_slot_pad_station_test_17
var/global/babylon_byond_1686_slot_pad_station_test_18
var/global/babylon_byond_1686_slot_pad_station_test_19
var/global/babylon_byond_1686_slot_pad_station_test_20
#elif defined(BABYLON_STATION)
// babylon-station.dme
var/global/babylon_byond_1686_slot_pad_station_1
var/global/babylon_byond_1686_slot_pad_station_2
var/global/babylon_byond_1686_slot_pad_station_3
var/global/babylon_byond_1686_slot_pad_station_4
#endif
