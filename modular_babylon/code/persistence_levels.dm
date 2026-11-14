// Station checkpoints: the shared save engine (persistence.dm) on several z-levels.
// Compiled only into babylon-station.dmb.
//
// A save writes every persistent level as z<N>.dmm: the station's levels, the map's own extra
// levels (mining, wilderness), lavaland and the space ruin levels. CentCom, transit/reserved
// levels and the Interlink are rebuilt on every start and never saved. state.json gets each
// level's traits as loaded ("levels"), the map json ("map_config"), the round ("round"), the
// per-player records ("players") and the players' characters ("characters", station_characters.dm).
//
// The supervisor (Driver.prepare_station) stages the saved levels in _maps/babylon/saved and
// writes data/next_map.json naming them. A restoring world then loads exactly those levels with
// their saved traits and generates nothing on top: no lavaland, space or wilderness levels, no
// ruins, no cave or river generation, no minor mapping (mice, trash, weakpoints).
//
// Shuttles are not saved: their tiles are written as what lies beneath them and every shuttle
// loads again at its roundstart dock, idle. Players' bodies are saved apart from the levels, as
// their characters (station_characters.dm); other living things (animals, monsters, bots,
// monkeys; not NPC humans) are saved by type and core fields.

/// _maps/<path> of the levels the supervisor stages from a save (Driver.prepare_station).
#define BABYLON_SAVED_MAP_PATH "babylon/saved"
/// Longest a save waits for a moving tram to reach a platform.
#define BABYLON_TRAM_SAVE_WAIT (20 SECONDS)

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

/datum/babylon_save/save_format_version()
	return BABYLON_STATION_STATE_VERSION

/// Station checkpoints: a z<N>.dmm per level, records and turfs with their z.
/datum/babylon_save/writes_level_files()
	return TRUE

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
	// A shuttle players built has no template to come back from: it is saved with its port.
	if(istype(thing, /obj/docking_port/mobile))
		return list("shuttle_id", "width", "height", "dwidth", "dheight", "area_type", "port_direction", "preferred_direction")
	if(is_scenery(thing))
		return list("color")
	return list()

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
	// Effects that are only a moment's visual, a fired spawner or a helper that did its work
	// when the map first loaded. Everything else stays: every landmark (job starts, transport
	// ids, tram beacons, ruins ...), ghost-role spawners, lift music zones, step triggers.
	var/static/list/passing_effects = typecacheof(list(
		/obj/effect/temp_visual,
		/obj/effect/overlay,
		/obj/effect/particle_effect,
		/obj/effect/hotspot,
		/obj/effect/projectile,
		/obj/effect/ebeam,
		/obj/effect/beam,
		/obj/effect/spawner,
		/obj/effect/mapping_helpers,
		/obj/effect/forcefield,
		/obj/effect/anomaly,
		/obj/effect/light_emitter,
		/obj/effect/landmark/latejoin,
	))
	if(istype(effect, /obj/effect/abstract))
		return istype(effect, /obj/effect/abstract/elevator_music_zone)
	return !is_type_in_typecache(effect, passing_effects)

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
		// Built by players: no roundstart dock brings it back, so it is saved like the station.
		if(istype(shuttle, /obj/docking_port/mobile/custom))
			continue
		var/obj/docking_port/stationary/dock = shuttle.get_docked()
		var/beneath_area = dock?.area_type || SHUTTLE_DEFAULT_UNDERLYING_AREA
		for(var/turf/tile as anything in shuttle.return_ordered_turfs(shuttle.x, shuttle.y, shuttle.z, shuttle.dir))
			if(!tile || !istype(tile.loc, shuttle.area_type))
				continue
			skipped[tile] = list(beneath_turf_type(tile), beneath_area)
	return skipped

/// A lift's or tram's id comes from a transport_id landmark on its platform, which the
/// controller deletes once read: one is written back on a platform of every identified transport.
/datum/babylon_save/checkpoint_tile_extras()
	var/list/extras = list()
	var/list/levels = persisted_levels()
	for(var/transport_type in SStransport.transports_by_type)
		for(var/datum/transport_controller/linear/controller as anything in SStransport.transports_by_type[transport_type])
			if(!controller.specific_transport_id || !length(controller.transport_modules))
				continue
			var/obj/structure/transport/linear/platform = controller.transport_modules[1]
			var/turf/tile = platform?.loc
			if(!isturf(tile) || !(tile.z in levels))
				continue
			if(!extras[tile])
				extras[tile] = list()
			var/list/entries = extras[tile]
			entries += "/obj/effect/landmark/transport/transport_id{\n\tspecific_transport_id = [tgm_encode(controller.specific_transport_id)]\n\t}"
			if(controller.create_modular_set)
				add_merged_module_entries(controller, extras, levels)
	return extras

/// A tram merges its one-tile modules into one multi-tile module per level when it loads (the
/// others become its overlays). That module is saved once, on its corner tile; every other tile
/// it covers gets a module entry again, with the look it had, so the next load merges it anew.
/datum/babylon_save/proc/add_merged_module_entries(datum/transport_controller/linear/controller, list/extras, list/levels)
	for(var/obj/structure/transport/linear/module as anything in controller.transport_modules)
		var/turf/corner = module.loc
		if(!isturf(corner) || !(corner.z in levels) || length(module.locs) < 2)
			continue
		// The absorbed modules' looks, by their offset from the corner.
		var/list/states = list()
		for(var/image/part as anything in module.overlays)
			states["[round(part.pixel_x / ICON_SIZE_X)],[round(part.pixel_y / ICON_SIZE_Y)]"] = part.icon_state
		for(var/turf/tile as anything in module.locs)
			if(tile == corner)
				continue
			var/state = states["[tile.x - corner.x],[tile.y - corner.y]"]
			var/list/vars_text = list("transport_id = [tgm_encode(module.transport_id)]")
			if(istext(state))
				vars_text += "icon_state = [tgm_encode(state)]"
			if(!extras[tile])
				extras[tile] = list()
			var/list/entries = extras[tile]
			entries += "[module.type]{\n\t[vars_text.Join(";\n\t")]\n\t}"

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

/// Living things without a player, on their tile: animals, monsters, bots, monkeys. Players'
/// bodies (a ckey or a mind with a key) are saved as characters (station_characters.dm), never
/// with a level; silicons carry laws and links, and holograms vanish with their projector.
/datum/babylon_save/checkpoint_mobs()
	var/list/mobs_by_turf = list()
	var/list/levels = persisted_levels()
	for(var/mob/living/creature as anything in GLOB.mob_living_list)
		if(QDELETED(creature) || !isturf(creature.loc) || !(creature.z in levels))
			continue
		// NPC humans (ruin corpses) are left out: a human rebuilt from the map has no DNA yet when
		// the level loads (runtimes in gravity checks), and without its outfit it is only a naked
		// "Unknown". Players' humans are characters (station_characters.dm).
		if(creature.ckey || creature.mind?.key || issilicon(creature) || ishuman(creature) || (creature.flags_1 & HOLOGRAM_1) || creature.babylon_skip_save())
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

/datum/babylon_save/capture_session_state(list/state, for_tutorial = FALSE)
	var/list/levels = list()
	for(var/z in persisted_levels())
		var/datum/space_level/level = SSmapping.z_list[z]
		// The traits exactly as loaded: tg files a level under every trait key it has.
		levels += list(list("file" = level_file(z), "traits" = level.traits.Copy()))
	state["levels"] = levels
	state["map_config"] = saved_map_config()
	var/started = SSticker.HasRoundStarted()
	state["round"] = list("started" = started ? TRUE : FALSE, "station_time" = started ? STATION_TIME_PASSED() : 0)
	capture_players(state, for_tutorial)
	state["characters"] = capture_characters(for_tutorial)

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

/// The saved z (as restored_level_z() takes it) of level z in this world.
/datum/babylon_save/proc/saved_level_of(z)
	for(var/saved_z in saved_level_zs)
		if(saved_level_zs[saved_z] == z)
			return text2num(saved_z)
	return z

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
			// Dead already: no death again (no loot drops, death sounds or messages).
			creature.set_stat(DEAD)
		else
			creature.updatehealth()
		CHECK_TICK
	restore_players(state["players"])
	if(babylon_state_round_started(state))
		var/list/round_state = state["round"]
		if(isnum(round_state["station_time"]))
			resumed_station_time = max(0, round_state["station_time"])
		RegisterSignal(SSticker, COMSIG_TICKER_ROUND_STARTING, PROC_REF(resumed_round_starting))

/// The resumed round starts: its clock goes on from the saved station time, and the restored
/// characters take their jobs again (station_characters.dm).
/datum/babylon_save/proc/resumed_round_starting(datum/source, start_time)
	SIGNAL_HANDLER
	UnregisterSignal(SSticker, COMSIG_TICKER_ROUND_STARTING)
	if(!isnull(resumed_station_time))
		SSticker.round_start_time = world.time - resumed_station_time
	INVOKE_ASYNC(src, PROC_REF(register_restored_characters))

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
			// One trait object per z; a file holding several z has a list of them (as the
			// supervisor accepts).
			var/list/saved_traits = level["traits"]
			var/list/trait_sets = list()
			if(islist(saved_traits) && length(saved_traits) && islist(saved_traits[1]))
				trait_sets = saved_traits
			else
				trait_sets += list(saved_traits)
			for(var/list/one_level as anything in trait_sets)
				var/list/level_traits = islist(one_level) ? one_level.Copy() : list()
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


// Unchanged levels. A level counts as changed while a player's body is on it, when a shuttle
// arrives on or leaves it, and (station levels) whenever the round runs with anyone connected:
// events, machines and the crew's work reach the station from anywhere. A save captures only
// changed levels; the others reuse the last save's map file and records (save_world_impl()).
// The first save after a start captures everything.

/datum/babylon_save
	/// z (as text) -> TRUE: changed since the last save.
	var/list/dirty_levels = list()
	/// The changed levels the save in progress went by (taken when its capture began).
	var/list/capturing_dirty
	/// z (as text) -> what first changed it since the last save (test diagnostics).
	var/list/dirty_causes = list()
	var/list/last_dirty_causes = list()
	/// REF(mobile port) -> its last "x,y,z".
	var/list/shuttle_positions = list()

/datum/babylon_save/New()
	. = ..()
	tick_listeners += new /datum/babylon_tick_listener(src, CALLBACK(src, PROC_REF(track_dirty_levels)))

/datum/babylon_save/proc/track_dirty_levels()
	var/someone_connected = FALSE
	for(var/client/player in GLOB.clients)
		var/mob/body = player.mob
		if(!body || isdead(body))
			continue
		someone_connected = TRUE
		var/turf/tile = get_turf(body)
		if(tile)
			mark_level_changed(tile.z, body)
	if(length(GLOB.clients))
		someone_connected = TRUE
	if(someone_connected && SSticker.HasRoundStarted())
		for(var/z in SSmapping.levels_by_trait(ZTRAIT_STATION))
			mark_level_changed(z, null)
	for(var/obj/docking_port/mobile/shuttle as anything in SSshuttle.mobile_docking_ports)
		if(QDELETED(shuttle))
			continue
		var/key = REF(shuttle)
		var/where = "[shuttle.x],[shuttle.y],[shuttle.z]"
		var/was = shuttle_positions[key]
		if(was == where)
			continue
		if(was)
			var/list/old_coords = splittext(was, ",")
			mark_level_changed(text2num(old_coords[3]), shuttle)
		mark_level_changed(shuttle.z, shuttle)
		shuttle_positions[key] = where

/datum/babylon_save/reusable_level(z)
	var/source = saved_level_source["[z]"]
	// During a capture the decision uses the set taken when it began; otherwise (the pause
	// estimate) the changes so far.
	var/list/changed = capturing_dirty || dirty_levels
	if(!source || changed["[z]"] || !islist(saved_level_json["[z]"]))
		return null
	if(!fexists("data/babylon/saves/[source]/[level_file(z)]"))
		return null
	return source

/datum/babylon_save/begin_level_capture()
	capturing_dirty = dirty_levels
	dirty_levels = list()
	last_dirty_causes = dirty_causes
	dirty_causes = list()
	// Whoever is on a level now keeps changing it.
	track_dirty_levels()

/datum/babylon_save/level_saved()
	capturing_dirty = null

/datum/babylon_save/level_save_failed()
	if(capturing_dirty)
		dirty_levels |= capturing_dirty
	capturing_dirty = null

/// Anything that changes level marks both levels as changed: drifting through space, falling
/// through open space, teleports and launchpads, a monster walking from one level to another.
/// Without it, an object moved off a level nobody stood on was lost, or kept twice.
/atom/movable/on_changed_z_level(turf/old_turf, turf/new_turf, same_z_layer, notify_contents = TRUE)
	var/datum/babylon_save/session = GLOB.babylon_save
	// Only what a save keeps: objects, the effects it keeps and living things (not passing
	// effects, ghosts, eyes or other abstract movables, which hop levels all the time).
	if(session && old_turf && new_turf && old_turf.z != new_turf.z && (isliving(src) || (isobj(src) && (!iseffect(src) || session.saves_effect(src)))))
		session.mark_level_changed(old_turf.z, src)
		session.mark_level_changed(new_turf.z, src)
	return ..()

/// Marks level z as changed; remembers the first thing that did (diagnostics for the tests).
/datum/babylon_save/proc/mark_level_changed(z, atom/cause)
	if(!dirty_levels["[z]"])
		dirty_causes["[z]"] = "[cause?.type]"
	dirty_levels["[z]"] = TRUE

/// A tram saved between stations has no platform under it and cannot start after a restore:
/// a save waits up to 20 seconds for moving trams to arrive. (A tram stopped on the line, by an
/// emergency stop or damage, is saved where it is; test_station_links reports it.)
/datum/babylon_save/before_checkpoint()
	// A stop does not wait: its save may catch the tram between stations, which the restore
	// handles (reset_stray_trams()).
	if(draining || stop_pending || !babylon_tram_travelling())
		return
	to_chat_immediate(world, span_notice("Waiting for the tram to arrive before saving..."))
	var/waited = 0
	while(waited < BABYLON_TRAM_SAVE_WAIT && babylon_tram_travelling() && !draining && !stop_pending)
		sleep(1 SECONDS)
		waited += 1 SECONDS

/// After a restore: a tram saved between stations (or stopped on the line) knows where it is
/// (its nav beacon rides with it) but not its platform. It drives to the nearest platform, as
/// tg's own controller reset does, once its control cabinet is paired. A tram that cannot be
/// reset, or whose cabinet never pairs, is logged and the players are told; a control cabinet
/// paired with no tram is logged.
/datum/babylon_save/proc/reset_stray_trams()
	if(!babylon_restoring_saved_levels())
		return
	var/list/stray = list()
	var/list/unpaired = list()
	var/list/failed = list()
	for(var/datum/transport_controller/linear/tram/tram as anything in SStransport.transports_by_type[TRANSPORT_TYPE_TRAM])
		if(!tram.paired_cabinet)
			unpaired += tram
		if(!tram.idle_platform && tram.nav_beacon)
			stray += tram
	var/waited = 0
	while((length(stray) || length(unpaired)) && waited < 2 MINUTES)
		for(var/datum/transport_controller/linear/tram/tram as anything in unpaired.Copy())
			if(QDELETED(tram) || tram.paired_cabinet)
				unpaired -= tram
		for(var/datum/transport_controller/linear/tram/tram as anything in stray.Copy())
			if(QDELETED(tram))
				stray -= tram
				continue
			if(!tram.paired_cabinet || tram.controller_active)
				continue
			stray -= tram
			if(!reset_stray_tram(tram))
				failed += tram
		sleep(1 SECONDS)
		waited += 1 SECONDS
	var/list/problems = list()
	for(var/datum/transport_controller/linear/tram/tram as anything in unpaired)
		if(QDELETED(tram))
			continue
		problems += tram
		log_world("Babylon: tram [tram.specific_transport_id] has no control cabinet after the restore[(tram in stray) ? " and is stuck between stations" : ""]; it cannot be called.")
		message_admins("Babylon: tram [tram.specific_transport_id] has no control cabinet after the restore; it cannot be called.")
	for(var/datum/transport_controller/linear/tram/tram as anything in failed)
		if(!QDELETED(tram) && !(tram in problems))
			problems += tram
	for(var/obj/machinery/transport/tram_controller/cabinet as anything in SSmachines.get_machines_by_type_and_subtypes(/obj/machinery/transport/tram_controller))
		if(!cabinet.controller_datum)
			log_world("Babylon: tram control cabinet [cabinet.type] at ([cabinet.x], [cabinet.y], [cabinet.z]) is not paired with any tram after the restore (wanted [cabinet.configured_transport_id]).")
	if(length(problems))
		INVOKE_ASYNC(src, PROC_REF(tell_tram_problem), problems)

/// Drives a stray tram to the nearest platform: inbound first (tg's direction after a restore,
/// which does not save travel_direction), else outbound. FALSE, logged, if it cannot.
/datum/babylon_save/proc/reset_stray_tram(datum/transport_controller/linear/tram/tram)
	var/direction = babylon_tram_reset_direction(tram, tram.nav_beacon)
	if(!direction)
		log_world("Babylon: tram [tram.specific_transport_id] was saved between stations at ([tram.nav_beacon.x], [tram.nav_beacon.y], [tram.nav_beacon.z]) and no platform lies on its line in either direction; it cannot be reset.")
		message_admins("Babylon: tram [tram.specific_transport_id] could not be reset after the restore (no platform on its line) at [ADMIN_JMP(tram.nav_beacon)].")
		return FALSE
	log_world("Babylon: tram [tram.specific_transport_id] was saved between stations; driving it to the nearest platform ([direction == INBOUND ? "inbound" : "outbound"]).")
	// check_starting_landmark() turns the transport subsystem on only for a tram found on a
	// platform; without this the reset trip never moves.
	SStransport.can_fire = TRUE
	// reset_position() takes its direction from travel_direction (EAST/NORTH outbound).
	tram.travel_direction = direction == OUTBOUND ? EAST : WEST
	tram.reset_position()
	if(!tram.controller_active)
		log_world("Babylon: tram [tram.specific_transport_id] did not start its reset trip ([direction == INBOUND ? "inbound" : "outbound"]); it stays between stations.")
		return FALSE
	return TRUE

/// The direction a reset trip from origin takes: INBOUND if a platform lies that way (what tg
/// does), else OUTBOUND, else null.
/proc/babylon_tram_reset_direction(datum/transport_controller/linear/tram/tram, atom/origin)
	if(babylon_tram_platforms_towards(tram, INBOUND, origin))
		return INBOUND
	if(babylon_tram_platforms_towards(tram, OUTBOUND, origin))
		return OUTBOUND
	return null

/// How many of the tram's platforms lie on its line from origin in direction (INBOUND/OUTBOUND),
/// by the rule of tg's closest_nav_in_travel_dir() (the line runs along the nav beacon's dir),
/// which stack_traces when there are none.
/proc/babylon_tram_platforms_towards(datum/transport_controller/linear/tram/tram, direction, atom/origin)
	var/obj/effect/landmark/transport/nav_beacon/tram/nav = tram.nav_beacon
	. = 0
	if(!nav || !origin?.z)
		return
	for(var/obj/effect/landmark/transport/nav_beacon/tram/candidate in SStransport.nav_beacons[tram.specific_transport_id])
		if(candidate.z != origin.z)
			continue
		var/inbound
		switch(nav.dir)
			if(EAST, WEST)
				if(candidate.y != origin.y)
					continue
				inbound = candidate.x < origin.x
			if(NORTH, SOUTH)
				if(candidate.x != origin.x)
					continue
				inbound = candidate.y < origin.y
			else
				continue
		if(inbound == (direction == INBOUND))
			.++

/// Tells everyone in the world, and everyone who joins later, that a tram could not be reset
/// after the restart, until each such tram stands at a platform with its cabinet again.
/datum/babylon_save/proc/tell_tram_problem(list/trams)
	var/list/told = list()
	while(TRUE)
		var/still_broken = FALSE
		for(var/datum/transport_controller/linear/tram/tram as anything in trams)
			if(!QDELETED(tram) && (!tram.idle_platform || !tram.paired_cabinet))
				still_broken = TRUE
		if(!still_broken)
			return
		for(var/client/player in GLOB.clients)
			if(player.ckey in told)
				continue
			told += player.ckey
			to_chat(player, span_warning("The tram could not be reset after the world restarted. It is stuck where it was saved and cannot be called. An admin can fix it."))
		sleep(5 SECONDS)

/proc/babylon_tram_travelling()
	for(var/datum/transport_controller/linear/tram/tram as anything in SStransport.transports_by_type[TRANSPORT_TYPE_TRAM])
		if(tram.controller_active)
			return TRUE
	return FALSE

/// Station worlds autosave every babylon-autosave-minutes (the supervisor's
/// station_autosave_minutes, default 30): a save pauses them far longer than a Babylon world.
/datum/babylon_save/proc/read_autosave_interval()
	var/minutes = text2num(world.params["babylon-autosave-minutes"])
	autosave_interval = (isnum(minutes) && minutes >= 1) ? round(minutes) MINUTES : 30 MINUTES

#undef BABYLON_SAVED_MAP_PATH
#undef BABYLON_TRAM_SAVE_WAIT
