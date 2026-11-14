// Station checkpoints: the shared save engine (persistence.dm) on several z-levels.
// Compiled only into babylon-station.dmb.
//
// A save writes every persistent level as z<N>.dmm: the station's levels, the map's own extra
// levels (mining, wilderness), lavaland and the space ruin levels. CentCom, transit/reserved
// levels and the Interlink are rebuilt on every start and never saved. state.json gets each
// level's traits as loaded ("levels"), the map json ("map_config"), the round ("round") and,
// from Task D2, the players' characters ("characters").
//
// The supervisor (Driver.prepare_station) stages the saved levels in _maps/babylon/saved and
// writes data/next_map.json naming them. A restoring world then loads exactly those levels with
// their saved traits and generates nothing on top: no lavaland, space or wilderness levels, no
// ruins, no cave or river generation, no minor mapping (mice, trash, weakpoints).
//
// Shuttles are not saved: their tiles are written as what lies beneath them and every shuttle
// loads again at its roundstart dock, idle. Players' own bodies are not saved yet (Task D2);
// other living things (animals, monsters, bots, NPC humans) are saved by type and core fields.

/// _maps/<path> of the levels the supervisor stages from a save (Driver.prepare_station).
#define BABYLON_SAVED_MAP_PATH "babylon/saved"

/datum/babylon_save
	/// Saved level z (as text) -> the z it was loaded at in this world (restore only).
	var/list/saved_level_zs = list()
	/// Station time (deciseconds since round start) of a resumed round, else null.
	var/resumed_station_time
	/// Living bodies frozen for the current checkpoint.
	var/list/checkpoint_frozen = list()

/// This world loads its levels from a station save (data/next_map.json names the saved levels).
/proc/babylon_restoring_saved_levels()
	return SSmapping.current_map?.map_path == BABYLON_SAVED_MAP_PATH && fexists("data/babylon/resume-state.json")

/// Station checkpoints: a z<N>.dmm per level, records and turfs with their z.
/datum/babylon_save/save_format_version()
	return BABYLON_STATION_STATE_VERSION

/// Every level a round can change: all but CentCom, transit/reserved levels and the Interlink,
/// which every start rebuilds.
/datum/babylon_save/persisted_levels()
	var/list/levels = list()
	for(var/datum/space_level/level as anything in SSmapping.z_list)
		var/list/traits = level.traits
		if(traits[ZTRAIT_CENTCOM] || traits[ZTRAIT_RESERVED] || findtext(level.name, "Interlink"))
			continue
		levels += level.z_value
	return levels

/// The docking ports' setup goes into the saved map, so shuttles load again at their docks.
/// Scenery without a record keeps its colour there; machines keep the ids they link up by.
/datum/babylon_save/type_metadata_fields(atom/thing)
	if(istype(thing, /obj/docking_port/stationary) && !istype(thing, /obj/docking_port/stationary/transit))
		return list("shuttle_id", "width", "height", "dwidth", "dheight", "roundstart_template", "json_key", "area_type", "hidden", "override_can_dock_checks")
	if(is_scenery(thing))
		return list("color")
	// Lifts, their buttons and panels find each other by these ids while they initialize.
	return list("id", "transport_id", "linked_elevator_id")

/// Plants, rocks and decals: nothing about them but their map entry needs saving.
/datum/babylon_save/proc/is_scenery(atom/thing)
	return istype(thing, /obj/structure/flora) || istype(thing, /obj/effect/decal) || istype(thing, /obj/effect/turf_decal)

/datum/babylon_save/saves_record(obj/object)
	return !is_scenery(object)

/// Landmarks a round looks for (job starts, the observer start, event spawns ...) are kept;
/// other effects (spawners, helpers) did their work when the map first loaded.
/datum/babylon_save/saves_effect(obj/effect/effect)
	if(..())
		return TRUE
	var/static/list/kept_landmarks = typecacheof(list(
		/obj/effect/landmark/start,
		/obj/effect/landmark/observer_start,
		/obj/effect/landmark/carpspawn,
		/obj/effect/landmark/blobstart,
		/obj/effect/landmark/secequipment,
		/obj/effect/landmark/prisonwarp,
		/obj/effect/landmark/event_spawn,
		/obj/effect/landmark/generic_maintenance_landmark,
		/obj/effect/landmark/navigate_destination,
		/obj/effect/landmark/latejoin_override,
	))
	return is_type_in_typecache(effect, kept_landmarks)

/// Planetary air resets itself and the map's initial_gas_mix holds every tile's air: only
/// station-like air and walls that are warmer or colder than they start get a turf record.
/// Without this, ice moon and lavaland levels wrote some 60 000 turf records each.
/datum/babylon_save/saves_turf_air(turf/tile)
	if(isopenturf(tile))
		var/turf/open/open = tile
		return !open.planetary_atmos
	return tile.temperature != initial(tile.temperature)

/// Shuttles on saved levels: their tiles become what lies beneath them, without contents.
/datum/babylon_save/checkpoint_skipped_tiles()
	var/list/skipped = list()
	var/list/levels = persisted_levels()
	for(var/obj/docking_port/mobile/shuttle as anything in SSshuttle.mobile_docking_ports)
		if(QDELETED(shuttle) || !(shuttle.z in levels))
			continue
		var/obj/docking_port/stationary/dock = shuttle.get_docked()
		var/beneath_area = dock?.area_type || SHUTTLE_DEFAULT_UNDERLYING_AREA
		for(var/turf/tile as anything in shuttle.return_ordered_turfs(shuttle.x, shuttle.y, shuttle.z, shuttle.dir))
			if(!tile || !istype(tile.loc, shuttle.area_type))
				continue
			skipped[tile] = list(beneath_turf_type(tile), beneath_area)
	return skipped

/// The turf a shuttle tile leaves behind when the shuttle flies off.
/datum/babylon_save/proc/beneath_turf_type(turf/tile)
	var/list/stack = islist(tile.baseturfs) ? tile.baseturfs : list(tile.baseturfs)
	var/index = stack.Find(/turf/baseturf_skipover/shuttle)
	var/beneath = index > 1 ? stack[index - 1] : /turf/baseturf_bottom
	while(ispath(beneath, /turf/baseturf_skipover) && index > 1)
		index--
		beneath = index > 1 ? stack[index - 1] : /turf/baseturf_bottom
	if(beneath == /turf/baseturf_bottom || ispath(beneath, /turf/baseturf_skipover))
		beneath = SSmapping.level_trait(tile.z, ZTRAIT_BASETURF) || /turf/open/space
		if(!ispath(beneath))
			beneath = text2path(beneath) || /turf/open/space
	return beneath

/// Living things without a player, on their tile: animals, monsters, bots, NPC humans. Players'
/// bodies (a ckey or a mind with a key) are Task D2's; silicons carry laws and links, and
/// holograms vanish with their projector.
/datum/babylon_save/checkpoint_mobs()
	var/list/mobs_by_turf = list()
	var/list/levels = persisted_levels()
	for(var/mob/living/creature as anything in GLOB.mob_living_list)
		if(QDELETED(creature) || !isturf(creature.loc) || !(creature.z in levels))
			continue
		if(creature.ckey || creature.mind?.key || issilicon(creature) || (creature.flags_1 & HOLOGRAM_1))
			continue
		var/turf/tile = creature.loc
		if(!mobs_by_turf[tile])
			mobs_by_turf[tile] = list()
		var/list/creatures = mobs_by_turf[tile]
		creatures += creature
	return mobs_by_turf

/// Players' bodies do not move or act while the world is captured.
/datum/babylon_save/checkpoint_hold(frozen)
	if(frozen)
		checkpoint_frozen = list()
		for(var/client/player in GLOB.clients)
			var/mob/living/body = player.mob
			if(!isliving(body))
				continue
			ADD_TRAIT(body, TRAIT_IMMOBILIZED, "babylon_checkpoint")
			ADD_TRAIT(body, TRAIT_UI_BLOCKED, "babylon_checkpoint")
			checkpoint_frozen += body
		return
	for(var/mob/living/body as anything in checkpoint_frozen)
		if(QDELETED(body))
			continue
		REMOVE_TRAIT(body, TRAIT_IMMOBILIZED, "babylon_checkpoint")
		REMOVE_TRAIT(body, TRAIT_UI_BLOCKED, "babylon_checkpoint")
	checkpoint_frozen = list()

/datum/babylon_save/capture_session_state(list/state)
	var/list/levels = list()
	for(var/z in persisted_levels())
		var/datum/space_level/level = SSmapping.z_list[z]
		// The traits exactly as loaded: tg files a level under every trait key it has.
		levels += list(list("file" = level_file(z), "traits" = level.traits.Copy()))
	state["levels"] = levels
	state["map_config"] = saved_map_config()
	var/started = SSticker.HasRoundStarted()
	state["round"] = list("started" = started ? TRUE : FALSE, "station_time" = started ? STATION_TIME_PASSED() : 0)
	// Task D2 saves the players' characters here.
	state["characters"] = list()

/// The map's tg map json as this world was first started from it (a restored world keeps the
/// one its save had; data/next_map.json then names the saved levels instead).
/datum/babylon_save/proc/saved_map_config()
	var/list/saved = resume_data ? resume_data["map_config"] : null
	if(islist(saved) && babylon_restoring_saved_levels())
		return saved
	var/datum/map_config/config = SSmapping.current_map
	if(config?.config_filename && fexists(config.config_filename))
		try
			var/list/loaded = json_decode(file2text(config.config_filename))
			if(islist(loaded))
				return loaded
		catch(var/exception/error)
			log_world("Babylon: could not read [config.config_filename] for the save: [error]")
	return list("version" = MAP_CURRENT_VERSION, "map_name" = config?.map_name, "map_path" = config?.map_path, "map_file" = config?.map_file, "shuttles" = config?.shuttles)

/// Restores the world's station checkpoint (data/babylon/resume-state.json, staged by the
/// supervisor with its levels) before the simulation starts. Called by SSbabylon_station.
/datum/babylon_save/proc/restore_station()
	if(!fexists("data/babylon/resume-state.json"))
		return
	// Saved objects must never be laid over a freshly generated map.
	if(!babylon_restoring_saved_levels())
		CRASH("The save's levels were not loaded (data/next_map.json does not name them)")
	var/list/state = load_resume_data()
	var/list/levels = state["levels"]
	if(!length(levels))
		CRASH("The save lists no levels")
	var/first_z = SSmapping.station_start
	if(first_z + length(levels) - 1 > world.maxz)
		CRASH("The save has [length(levels)] levels, but only [world.maxz - first_z + 1] were loaded")
	for(var/index in 1 to length(levels))
		var/list/level = levels[index]
		var/saved_z = text2num(copytext(level["file"], 2, -4))
		saved_level_zs["[saved_z]"] = first_z + index - 1
	restore_world()

/datum/babylon_save/restored_level_z(saved_z)
	return saved_level_zs["[saved_z]"] || saved_z

/datum/babylon_save/restore_session_state(list/state)
	// Living things were rebuilt with their saved health and stat set directly: let them die
	// properly, or settle their stat from their health.
	for(var/list/record as anything in state["records"])
		var/mob/living/creature = restored_atoms[record["id"]]
		if(!isliving(creature) || record["parent"])
			continue
		var/list/fields = record["fields"]
		var/saved_stat = (islist(fields) && ("stat" in fields)) ? fields["stat"] : null
		creature.stat = STABLE
		if(saved_stat == DEAD)
			creature.death()
		else
			creature.updatehealth()
		CHECK_TICK
	var/list/round_state = state["round"]
	if(babylon_state_round_started(state) && islist(round_state) && isnum(round_state["station_time"]))
		resumed_station_time = max(0, round_state["station_time"])
		RegisterSignal(SSticker, COMSIG_TICKER_ROUND_STARTING, PROC_REF(resume_station_time))

/// The resumed round's clock goes on from the saved station time.
/datum/babylon_save/proc/resume_station_time(datum/source, start_time)
	SIGNAL_HANDLER
	if(isnull(resumed_station_time))
		return
	SSticker.round_start_time = world.time - resumed_station_time
	UnregisterSignal(SSticker, COMSIG_TICKER_ROUND_STARTING)

// A restoring world loads exactly its saved levels, with their saved traits, and generates
// nothing on top of them. Each override falls through to tg's proc in every other world.

/datum/controller/subsystem/mapping/Initialize()
	if(!initialized && babylon_restoring_saved_levels())
		GLOB.babylon_save.prepare_saved_levels(current_map)
	return ..()

/// Loads the saved levels as the "Station" group with their traits as saved (tg's map config
/// would add the station trait to every one and stack Up/Down links over all of them).
/datum/babylon_save/proc/prepare_saved_levels(datum/map_config/config)
	var/list/state = load_resume_data()
	var/list/levels = islist(state) ? state["levels"] : null
	if(length(levels))
		var/list/traits = list()
		for(var/list/level as anything in levels)
			var/list/saved_traits = level["traits"]
			var/list/level_traits = islist(saved_traits) ? saved_traits.Copy() : list()
			var/baseturf = level_traits[ZTRAIT_BASETURF]
			if(istext(baseturf))
				level_traits[ZTRAIT_BASETURF] = text2path(baseturf) || baseturf
			traits += list(level_traits)
		config.traits = traits
	config.height_autosetup = FALSE
	config.space_ruin_levels = 0
	config.space_empty_levels = 0
	config.wilderness_levels = 0
	config.wilderness_maps_to_spawn = list()
	config.load_all_away_missions = FALSE
	log_world("Babylon: loading [length(levels)] saved level(s) instead of generating the map.")

/datum/controller/subsystem/mapping/LoadGroup(list/errorList, name, path, files, list/traits, list/default_traits, silent = FALSE, height_autosetup = TRUE)
	// Lavaland and wilderness levels are among the saved ones.
	if(name != "Station" && babylon_restoring_saved_levels())
		return list()
	return ..()

/datum/controller/subsystem/mapping/setup_ruins()
	if(babylon_restoring_saved_levels())
		return
	return ..()

/datum/controller/subsystem/mapping/setup_rivers()
	if(babylon_restoring_saved_levels())
		return
	return ..()

/datum/controller/subsystem/mapping/run_map_terrain_generation()
	if(babylon_restoring_saved_levels())
		return
	return ..()

/datum/controller/subsystem/mapping/run_map_terrain_population()
	if(babylon_restoring_saved_levels())
		return
	return ..()

/datum/controller/subsystem/minor_mapping/Initialize()
	// The saved levels already have their critters, loot and weakpoints.
	if(babylon_restoring_saved_levels())
		return SS_INIT_NO_NEED
	return ..()

#undef BABYLON_SAVED_MAP_PATH
