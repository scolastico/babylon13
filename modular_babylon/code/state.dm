// Babylon session and persistence engine state, shared by both game builds
// (babylon.dmb and babylon-station.dmb). Babylon's own world rules are in rules.dm.
GLOBAL_DATUM_INIT(babylon_save, /datum/babylon_save, new)

/world
	sleep_offline = FALSE

/datum/controller/master
	sleep_offline_after_initializations = FALSE

/atom
	var/babylon_save_id = null

/datum/babylon_save
	var/ready = FALSE
	var/busy = FALSE
	var/last_save = null
	var/boot_error = null
	var/save_count = 0
	var/next_id = 1
	var/station_z
	var/owner_ckey
	/// ckey -> /datum/babylon_player: everyone who has played this world, the owner included.
	var/list/player_sessions = list()
	var/draining = FALSE
	/// The round is over (station worlds, station_round.dm): the world stops without saving again.
	var/round_ending = FALSE
	var/afk_timeout = 15 MINUTES
	var/list/restored_atoms = list()
	var/list/resume_data
	var/list/resume_records = list()
	var/list/migration_notes = list()
	var/prepared = FALSE
	var/checkpoint_processing
	var/checkpoint_started
	var/checkpoint_capture_ms = 0
	var/list/programs_to_resume = list()
	var/list/capture_fields_by_type = list()
	var/list/metadata_fields_by_type = list()
	var/next_autosave_at = 0
	var/autosave_countdown_active = FALSE
	var/list/autosave_notices = list()
	var/turf/respawn_turf
	var/list/structural_fields = list("dir", "name", "pixel_x", "pixel_y", "pixel_z", "layer", "plane", "alpha", "anchored", "density", "opacity", "amount", "icon_state", "cable_layer", "cable_color", "linked_dirs", "banned_links", "piping_layer", "pipe_color", "initialize_directions", "flipped", "welded", "hide", "id_tag", "door_id", "mineral", "glass", "heat_proof_finished", "state", "d_state", "req_access", "req_one_access", "closeOtherId", "pipe_layer", "p_init_dir", "rotation_angle", "can_rotate")
	var/list/extra_fields = list("passed_name", "passed_cycle_id", "one_access", "unres_sides", "unres_latch", "shell", "autoclose", "normalspeed", "autoname", "cyclelinkeddir", "picked", "colour", "icon_living", "icon_dead", "track", "azimuth_target", "azimuth_current", "azimuth_rate", "power_tier", "needs_to_turn", "needs_to_update_solar_exposure", "chamber_id", "inlet_id", "outlet_id", "fan_overclocked", "active", "filter_type", "transfer_rate", "volume_rate", "flipped", "initialize_directions", "layer", "plane", "alpha", "pixel_z", "hide", "pump_direction", "pressure_checks", "external_pressure_bound", "internal_pressure_bound", "widenet", "research_disabled", "working", "internal_energy", "external_power_trickle", "external_power_immediate", "external_damage_immediate", "activation_logged", "absorption_ratio", "gas_percentage", "gas_heat_modifier", "gas_heat_resistance", "gas_powerloss_inhibition", "gas_power_transmission_rate", "gas_heat_power_generation", "waste_multiplier", "final_countdown", "disable_damage", "disable_gas", "disable_power_change", "production_speed", "closeOtherId", "pipe_layer", "p_init_dir", "color", "deconstruction_state", "disable_process", "damage", "power_transmission", "safeties", "direction", "accesses", "filter_types", "scrubbing", "fuel_type", "loading", "chargecount")
	var/list/state_fields = list("name", "desc", "dir", "pixel_x", "pixel_y", "density", "opacity", "anchored", "amount", "atom_integrity", "max_integrity", "panel_open", "opened", "locked", "welded", "bolts", "safe", "operating", "chargemode", "coverlocked", "has_electronics", "lighting", "equipment", "environ", "aidisabled", "shorted", "on", "enabled", "use_power", "target_pressure", "pressure_setting", "release_pressure", "valve_open", "input_level", "input_attempt", "output_level", "output_attempt", "charge", "maxcharge", "fuel", "lit", "welding", "max_fuel", "state", "d_state", "glass", "heat_proof_finished", "mineral", "created_name", "base_name", "cell_type", "cable_layer", "cable_color", "linked_dirs", "banned_links", "piping_layer", "pipe_color", "init_dir", "frequency", "id", "id_tag", "door_id", "siphoned_power", "siphon_max", "probability_mod", "health", "maxHealth", "real_name", "visualAppearance", "active_hand_index", "machine_stat", "stat", "mode", "temperature", "target_temperature", "thermostat", "build_type", "amount_per_transfer_from_this", "volume", "custom_price", "credits", "power_charge", "power_charge_max", "moles", "icon_state", "req_access", "req_one_access", "maximum_volume")
	var/list/reference_fields = list("cell", "electronics", "circuit", "internal_storage", "head", "held_items", "stored_id", "inserted_disk", "connected_sensor", "cyclelinkedairlock", "close_others", "closeOther")
	var/list/list_fields = list("req_access", "req_one_access", "accesses", "filter_types", "filter_type", "scrubbing", "ore_chance", "gas_percentage")

/// One player's record in this world (GLOB.babylon_save.player_sessions[ckey]). Babylon adds the
/// player's drone (session.dm), play_time.dm their play time.
/datum/babylon_player
	var/ckey

/datum/babylon_player/New(ckey)
	src.ckey = ckey

/// The world owner's record, once they have one (Babylon: from SSbabylon_builder's start on).
/datum/babylon_save/proc/owner_player()
	RETURN_TYPE(/datum/babylon_player)
	return player_sessions[owner_ckey]

/// One step of the world's loop, once a second while the world runs: the build's player loop,
/// then COMSIG_BABYLON_WORLD_TICK for the modules' own steps (play time, round control ...).
/// Defined only here; modules register for the signal (tools/babylon/test_tick_override.py).
/datum/babylon_save/proc/tick_world()
	SHOULD_NOT_OVERRIDE(TRUE)
	tick_players()
	SEND_SIGNAL(src, COMSIG_BABYLON_WORLD_TICK)

/// The build's player loop (session.dm, station_session.dm), once per world tick.
/datum/babylon_save/proc/tick_players()
	return

/datum/babylon_save
	/// One /datum/babylon_tick_listener per module that steps with the world tick.
	var/list/tick_listeners = list()

/// Runs a module's step on every COMSIG_BABYLON_WORLD_TICK. Each module listens through its own
/// listener: a datum can hold only one handler per signal and source, so two modules registering
/// the session itself would silently replace each other's handler.
/datum/babylon_tick_listener
	var/datum/callback/step

/datum/babylon_tick_listener/New(datum/babylon_save/session, datum/callback/step)
	src.step = step
	RegisterSignal(session, COMSIG_BABYLON_WORLD_TICK, PROC_REF(on_world_tick))

/datum/babylon_tick_listener/proc/on_world_tick(datum/babylon_save/source)
	SIGNAL_HANDLER
	step.Invoke()

/// Reads babylon-afk-timeout into afk_timeout. FALSE (with boot_error set) when it is invalid.
/datum/babylon_save/proc/read_afk_timeout()
	var/raw_afk_timeout = world.params["babylon-afk-timeout"]
	if(isnull(raw_afk_timeout))
		return TRUE
	var/seconds = text2num(raw_afk_timeout)
	if(isnull(seconds) || seconds < 0 || seconds != round(seconds))
		boot_error = "babylon-afk-timeout must be a nonnegative integer in seconds (0 disables AFK kicks)."
		return FALSE
	afk_timeout = seconds SECONDS
	return TRUE

/// The client once /client/New() has finished, else null. GLOB.clients lists a client from
/// early in New(), which then still waits on the player's game (window checks, the chat panel)
/// for a while on a slow first load. Possessing the drone and deleting the new-player mob in
/// that window left the rest of New() working on a deleted mob: a half set-up client stuck on
/// a black screen with only the title music playing, until the player reconnected.
/proc/babylon_ready_client(client/student)
	return student?.fully_created ? student : null

/// Logs a failed loop step once a minute per step, so a recurring error cannot flood the log.
/proc/babylon_loop_failed(step, exception/error)
	var/static/list/last_logged = list()
	if(world.time < (last_logged[step] || -INFINITY) + 1 MINUTES)
		return
	last_logged[step] = world.time
	log_world("Babylon [step] failed: [error] ([error?.file]:[error?.line])")
	log_runtime("Babylon [step] failed: [error] ([error?.file]:[error?.line])")

