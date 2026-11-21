// Authenticated integration tests for babylon.dmb only (babylon-test.dme). Shared helpers
// and tests are in testing_common.dm.

/datum/babylon_save/proc/test_builder_experience()
	var/mob/living/basic/drone/babylon/replacement/empty = new(respawn_turf)
	var/item_count = 0
	for(var/obj/item/item in empty.contents)
		item_count++
	var/list/result = list("replacement_items" = item_count, "replacement_storage" = !!empty.internal_storage, "replacement_head" = !!empty.head, "station_confinement" = !!empty.GetComponent(/datum/component/stationstuck))
	qdel(empty)
	var/mob/dead/observer/ghost = new(respawn_turf)
	var/datum/hud/ghost/babylon/hud = new(ghost)
	result["spawners_hidden"] = !hud.screen_objects[HUD_GHOST_SPAWNERS]
	result["minigames_hidden"] = !hud.screen_objects[HUD_GHOST_MINIGAMES]
	result["dnr_present"] = !!hud.screen_objects[HUD_GHOST_DNR]
	result["reenter_present"] = !!hud.screen_objects[HUD_GHOST_REENTER_CORPSE]
	result["physical_cafe_turfs"] = length(get_area_turfs(/area/centcom/holding/cafe, subtypes = TRUE))
	var/papers = 0
	for(var/obj/item/paper/babylon/paper in world)
		papers++
	result["lore_papers"] = papers
	var/datum/babylon_player/owner = owner_player()
	result["return_before_destruct"] = owner.builder.actions.Find(owner.return_action) && owner.builder.actions.Find(owner.return_action) < owner.builder.actions.Find(owner.destruct_action)
	qdel(hud)
	qdel(ghost)
	return result

/datum/babylon_save/proc/test_research()
	var/list/result = list()
	var/datum/techweb/science/web = locate(/datum/techweb/science) in SSresearch.techwebs
	var/list/candidates = list()
	for(var/id in web?.available_nodes)
		var/datum/techweb_node/node = SSresearch.techweb_node_by_id(id)
		var/list/price = node.get_price(web)
		if(!web.researched_nodes[id] && !web.hidden_nodes[id] && !length(node.required_experiments) && price[TECHWEB_POINT_TYPE_GENERIC] > 10 && length(price) == 1)
			candidates += node
	result["two_candidate_nodes"] = length(candidates) >= 2
	if(length(candidates) < 2)
		return result
	var/datum/techweb_node/first = candidates[1]
	var/datum/techweb_node/second = candidates[2]
	var/first_price = first.get_price(web)[TECHWEB_POINT_TYPE_GENERIC]
	var/saved_target = web.babylon_target
	web.babylon_target = null
	web.add_point_list(list(TECHWEB_POINT_TYPE_GENERIC = 5))
	result["no_target_no_bank"] = web.research_points[TECHWEB_POINT_TYPE_GENERIC] == 0
	result["queue_refused"] = !web.enqueue_node(first.id, null) && !length(web.research_queue_nodes)
	result["selected"] = web.babylon_select(first.id) && web.babylon_target == first.id
	web.add_point_list(list(TECHWEB_POINT_TYPE_GENERIC = 5))
	result["income_counts_for_target"] = web.research_points[TECHWEB_POINT_TYPE_GENERIC] == 5
	web.babylon_select(second.id)
	result["switching_resets_progress"] = web.research_points[TECHWEB_POINT_TYPE_GENERIC] == 0 && web.babylon_target == second.id
	web.babylon_select(first.id)
	web.add_point_list(list(TECHWEB_POINT_TYPE_GENERIC = first_price * 10))
	result["researched_when_paid"] = !!web.researched_nodes[first.id] && !web.babylon_target
	result["excess_not_banked"] = web.research_points[TECHWEB_POINT_TYPE_GENERIC] == 0
	web.unresearch_node(first)
	web.babylon_target = saved_target
	return result

/datum/babylon_save/proc/test_closet_contents()
	var/list/result = list()
	result["station_has_supermatter"] = length(SSmachines.get_machines_by_type_and_subtypes(/obj/machinery/power/supermatter_crystal)) > 0
	var/obj/structure/closet/crate/secure/engineering/crate = new(respawn_turf)
	var/obj/machinery/power/supermatter_crystal/shard/shard = new(crate)
	shard.warning_channel = null
	var/list/records = list()
	capture(crate, records, null)
	var/saved = FALSE
	for(var/list/record as anything in records)
		if(record["type"] == "[shard.type]" && record["parent"])
			saved = TRUE
	result["machine_in_crate_saved"] = saved
	qdel(shard)
	qdel(crate)
	return result

/// Reflectors keep their angle and rotation lock through a save, with the mirror turned.
/datum/babylon_save/proc/test_reflectors()
	var/list/result = list()
	var/obj/structure/reflector/single/turned = new(respawn_turf)
	turned.set_angle(135)
	turned.can_rotate = FALSE
	var/map_entry = metadata(turned)
	result["angle_in_map"] = findtext(map_entry, "rotation_angle = 135") && findtext(map_entry, "can_rotate = 0")
	// As the map loader creates it from those entries.
	world.preloader_setup(list("rotation_angle" = 135, "can_rotate" = 0), /obj/structure/reflector/single)
	var/obj/structure/reflector/single/loaded = new(respawn_turf)
	result["angle_restored"] = loaded.rotation_angle == 135 && !loaded.can_rotate
	result["mirror_turned"] = loaded.deflector_overlay?.transform ~= turn(matrix(), 135)
	qdel(turned)
	qdel(loaded)
	return result

/// A machine frame with its board and some parts survives a save and can still be finished,
/// and one from an older save (board only) can be emptied again.
/datum/babylon_save/proc/test_machine_frames()
	var/list/result = list()
	var/turf/place = respawn_turf
	var/obj/structure/frame/machine/secured/frame = new(place)
	var/obj/item/circuitboard/machine/tesla_coil/board = new(frame)
	frame.circuit = board
	frame.circuit_added(board)
	frame.components += GLOB.stock_part_datums[/datum/stock_part/capacitor]
	frame.req_components[/datum/stock_part/capacitor]--
	var/list/records = list()
	capture(frame, records, null)
	var/list/record = records[1]
	result["progress_saved"] = length(record["frame_parts"]) == 2 && record["frame_required"]["[/datum/stock_part/capacitor]"] == 0
	// As the load leaves it: the board inside and set as circuit, the part lists gone.
	var/obj/structure/frame/machine/secured/loaded = new(place)
	var/obj/item/circuitboard/machine/tesla_coil/loaded_board = new(loaded)
	loaded.circuit = loaded_board
	loaded.state = FRAME_STATE_BOARD_INSTALLED
	restored_atoms[board.babylon_save_id] = loaded_board
	restore_machine_frame(loaded, record, list(loaded_board))
	result["progress_restored"] = loaded.req_components?[/datum/stock_part/capacitor] == 0 \
		&& (GLOB.stock_part_datums[/datum/stock_part/capacitor] in loaded.components) && (loaded_board in loaded.components)
	frame.components = null // Destroy would qdel the stock part singleton.
	qdel(frame)
	var/obj/item/screwdriver/screwdriver = new(place)
	result["can_be_finished"] = loaded.finalize_construction(null, screwdriver) && !!(locate(/obj/machinery/power/energy_accumulator/tesla_coil) in place)
	for(var/obj/machinery/power/energy_accumulator/tesla_coil/coil in place)
		qdel(coil)
	var/obj/structure/frame/machine/secured/legacy = new(place)
	var/obj/item/circuitboard/machine/tesla_coil/legacy_board = new(legacy)
	legacy.circuit = legacy_board
	legacy.state = FRAME_STATE_BOARD_INSTALLED
	restore_machine_frame(legacy, list("references" = list()), list(legacy_board))
	result["legacy_needs_parts"] = legacy.req_components?[/datum/stock_part/capacitor] == 1 && length(legacy.components) == 1
	legacy.dump_contents()
	result["legacy_can_be_emptied"] = legacy_board.loc == place && isnull(legacy.components)
	qdel(legacy_board)
	qdel(legacy)
	qdel(screwdriver)
	return result

/datum/babylon_save/proc/test_music_folders()
	var/list/result = list()
	var/datum/babylon_music/music = new
	music.root = "data/babylon_music_test/"
	fdel(music.root)
	for(var/track in list("space/a.ogg", "station/b.mp3", "derelict/c.wav", "engine/d.ogg", "vault/e.ogg", "loose.ogg", "station/notes.txt"))
		text2file("", "[music.root][track]")
	music.scan_folder("", 0)
	result["folders_scanned"] = length(music.tracks) == 5 && length(music.tracks["station"]) == 1
	var/turf/void
	for(var/turf/open/space/candidate in block(locate(1, 1, station_z), locate(world.maxx, 5, station_z)))
		void = candidate
		break
	result["space_folder"] = !!void && music.folder_for(void) == "space"
	var/turf/vault = locate(/obj/structure/babylon_watchdog_server) in world
	vault = get_turf(vault)
	result["vault_folder"] = !!vault && music.folder_for(vault) == "vault"
	music.tracks -= "vault"
	result["empty_vault_falls_back"] = !!vault && music.folder_for(vault) != "vault" && !isnull(music.folder_for(vault))
	music.tracks["vault"] = list("[music.root]vault/e.ogg")
	// A floor away from the wreck's own generators; its air decides derelict or station.
	music.engine_radius = 3
	var/turf/open/floor/floor
	for(var/turf/open/floor/candidate in get_area_turfs(/area/ruin/space/bb13/hallway, station_z, TRUE))
		if(!music.near_engine(candidate))
			floor = candidate
			break
	result["floor_found"] = !!floor
	if(floor)
		var/datum/gas_mixture/air = floor.return_air()
		var/datum/gas_mixture/original = air.copy()
		air.remove_ratio(1)
		result["airless_room_is_derelict"] = music.folder_for(floor) == "derelict"
		air.copy_from(SSair.parse_gas_string(OPENTURF_DEFAULT_ATMOS))
		result["room_with_air_is_station"] = music.folder_for(floor) == "station"
		// Any generator, wherever it was built, plays engine music; packed in a crate it does not.
		var/obj/machinery/power/rtg/generator = new(floor)
		result["generator_plays_engine"] = music.folder_for(floor) == "engine"
		var/obj/machinery/power/solar/panel = new(floor)
		generator.forceMove(new /obj/structure/closet/crate(floor))
		result["crated_generator_and_solar_do_not"] = music.folder_for(floor) == "station"
		var/obj/structure/closet/crate/crate = generator.loc
		qdel(generator)
		qdel(crate)
		qdel(panel)
		music.tracks -= "derelict"
		air.remove_ratio(1)
		result["empty_derelict_falls_back_to_station"] = music.folder_for(floor) == "station"
		air.copy_from(original)
	// A short trip keeps the playing track; staying for the debounce time switches.
	music.debounce = 20 SECONDS
	var/list/pending = list(null, 0)
	var/list/steps = list(
		music.debounced(null, "station", pending, 0) == "station",
		music.debounced("station", "space", pending, 10) == "station",
		music.debounced("station", "station", pending, 20) == "station",
		music.debounced("station", "space", pending, 30) == "station",
		music.debounced("station", "space", pending, 30 + 19 SECONDS) == "station",
		music.debounced("station", "space", pending, 30 + 20 SECONDS) == "space",
	)
	result["debounce_keeps_then_switches"] = !(FALSE in steps)
	result["title_from_file_name"] = babylon_music_title("/music/space/Deep_Space Drift.v2.ogg") == "Deep Space Drift.v2"
	fdel(music.root)
	return result

/// Capture the crossing in the movement callback, rather than polling a transient position.
/datum/babylon_test_drift_crossing
	var/atom/movable/drifter
	var/target_z
	var/crossed = FALSE
	var/datum/drift_handler/crossing_handler
	var/kept_momentum = FALSE

/datum/babylon_test_drift_crossing/New(atom/movable/drifter, target_z)
	. = ..()
	src.drifter = drifter
	src.target_z = target_z
	RegisterSignal(drifter, COMSIG_MOVABLE_MOVED, PROC_REF(on_moved))

/datum/babylon_test_drift_crossing/Destroy()
	UnregisterSignal(drifter, COMSIG_MOVABLE_MOVED)
	drifter = null
	crossing_handler = null
	return ..()

/datum/babylon_test_drift_crossing/proc/on_moved(atom/movable/source, atom/old_loc)
	SIGNAL_HANDLER
	if(!crossed && source.z == target_z && source.x > world.maxx / 2)
		crossed = TRUE
		crossing_handler = source.drift_handler
		return
	// A subsequent westward step proves the crossing did not cancel its original drift.
	if(crossed && old_loc?.z == target_z && old_loc.x > world.maxx / 2 && source.z == target_z && source.x < old_loc.x && !QDELETED(crossing_handler) && source.drift_handler == crossing_handler)
		kept_momentum = TRUE

/datum/babylon_test_drift_crossing/proc/complete()
	return crossed && kept_momentum

/datum/babylon_save/proc/test_space_wrap()
	var/list/result = list()
	var/middle = round(world.maxy / 2)
	var/turf/open/west = locate(1, middle, station_z)
	var/turf/open/east = locate(world.maxx, middle, station_z)
	var/turf/open/north = locate(round(world.maxx / 2), world.maxy, station_z)
	result["west_edge_leads_east"] = istype(west) && west.destination_z == station_z && west.destination_x > world.maxx / 2
	result["east_edge_leads_west"] = istype(east) && east.destination_z == station_z && east.destination_x < world.maxx / 2
	result["north_edge_leads_south"] = istype(north) && north.destination_z == station_z && north.destination_y < world.maxy / 2
	// Drift west into the border: arrive on the east side, still drifting.
	var/obj/item/stack/rods/drifter = new(locate(TRANSITIONEDGE + 3, middle, station_z))
	var/datum/babylon_test_drift_crossing/crossing = new(drifter, station_z)
	drifter.newtonian_move(dir2angle(WEST), drift_force = 5 NEWTONS)
	babylon_tutorial_test_wait_for(CALLBACK(crossing, TYPE_PROC_REF(/datum/babylon_test_drift_crossing, complete)))
	result["drift_wraps_to_the_other_side"] = crossing.crossed
	result["drift_keeps_momentum"] = crossing.kept_momentum
	qdel(crossing)
	qdel(drifter)
	return result

/datum/babylon_save/proc/test_no_storyteller()
	var/list/result = list()
	result["babylon_storyteller"] = SSgamemode.storyteller?.type == /datum/storyteller/babylon
	result["no_vote_running"] = !istype(SSvote.current_vote, /datum/vote/storyteller)
	result["vote_refused"] = !SSvote.initiate_vote(/datum/vote/storyteller, "Babylon test", forced = TRUE)
	SSgamemode.set_storyteller(/datum/storyteller/high, TRUE, "babylon-test")
	result["other_storyteller_refused"] = SSgamemode.storyteller?.type == /datum/storyteller/babylon
	result["no_scheduled_events"] = !length(SSgamemode.scheduled_events)
	return result

/// No pAI, station AI, MMI or positronic brain can be researched, built or found (silicons.dm).
/datum/babylon_save/proc/test_no_unplayable_silicons()
	var/list/result = list()
	var/designs = FALSE
	for(var/node_id in SSresearch.techweb_nodes)
		var/datum/techweb_node/node = SSresearch.techweb_nodes[node_id]
		for(var/design_id in node.design_ids)
			if(babylon_unplayable_design(SSresearch.techweb_design_by_id(design_id)))
				designs = TRUE
	result["no_pai_or_ai_designs"] = !designs
	var/datum/techweb/web = new /datum/techweb
	result["saved_research_cannot_add_them"] = !web.add_design_by_id("paicard") && !web.add_design_by_id("aicore")
	qdel(web)
	var/obj/item/stack/sheet/plasteel/sheets = new(respawn_turf)
	var/recipe = FALSE
	for(var/datum/stack_recipe/entry in sheets.get_main_recipes())
		if(ispath(entry.result_type, /obj/structure/ai_core))
			recipe = TRUE
	result["no_ai_core_recipe"] = !recipe
	qdel(sheets)
	var/obj/item/pai_card/card = new(respawn_turf)
	result["pai_cards_are_removed"] = QDELETED(card)
	var/obj/structure/ai_core/core = new(respawn_turf)
	result["ai_cores_are_removed"] = QDELETED(core)
	var/obj/item/mmi/mmi = new(respawn_turf)
	var/obj/item/mmi/posibrain/posibrain = new(respawn_turf)
	result["loose_mmis_and_posibrains_are_removed"] = QDELETED(mmi) && QDELETED(posibrain)
	var/datum/techweb/brains = new /datum/techweb
	result["no_mmi_or_posibrain_research"] = !brains.add_design_by_id("mmi") && !brains.add_design_by_id("mmi_posi") && !brains.add_design_by_id("posisphere")
	qdel(brains)
	var/mob/dead/observer/ghost = new(respawn_turf)
	var/datum/action/innate/join_soulcatcher/join = new(ghost)
	join.Grant(ghost)
	result["no_soulcatcher_button"] = !(join in ghost.actions)
	qdel(join)
	qdel(ghost)
	return result

/// A checkpoint written by the build before the station rework (a9c41016abe, fixtures/babylon_v7,
/// or its version 5 shape in fixtures/babylon_v5) restored into this build: the drones and their
/// players, a closed locker with its contents, a machine frame with its board and progress, an
/// airlock pair and research. version: the fixture's state.json version (5 or 7).
/datum/babylon_save/proc/test_legacy_babylon_restore(version, researched, target)
	var/list/result = list()
	result["resumed_from_fixture"] = last_save == "save-20261114-165619-1"
	var/datum/babylon_player/owner = owner_player()
	result["owner_drone_restored"] = owner?.builder?.name == "Fixture owner drone" && !QDELETED(owner.builder)
	var/datum/babylon_player/friend = player_sessions["fixturefriend"]
	if(version >= 6)
		result["friend_player_restored"] = friend?.builder?.name == "Fixture friend drone" && !!(locate(/obj/item/wrench) in friend.builder.get_all_contents())
	else
		// Version 5 has one player: the owner, from the top-level "player" and "builder".
		result["only_the_owner_mapped"] = isnull(friend) && length(player_sessions) == 1
	var/obj/structure/closet/locker
	var/obj/structure/frame/machine/frame
	var/list/airlocks = list()
	for(var/atom/movable/thing in world)
		switch(thing.name)
			if("Fixture locker")
				locker = thing
			if("Fixture frame")
				frame = thing
			if("Fixture airlock A", "Fixture airlock B")
				airlocks += thing
	var/obj/item/stack/sheet/iron/iron = locker && (locate() in locker)
	result["locker_contents"] = istype(locker) && !locker.opened && iron?.amount == 7 && !!(locate(/obj/item/crowbar) in locker)
	result["frame_progress"] = istype(frame) && istype(frame.circuit, /obj/item/circuitboard/machine/tesla_coil) && frame.circuit.loc == frame \
		&& frame.req_components?[/datum/stock_part/capacitor] == 0
	var/paired = length(airlocks) == 2
	for(var/obj/machinery/door/airlock/door as anything in airlocks)
		paired = paired && door.closeOtherId == "fixture_pair" && length(door.close_others) == 1 && (door.close_others[1] in airlocks)
	result["airlock_pair"] = paired
	var/datum/techweb/science/web = locate(/datum/techweb/science) in SSresearch.techwebs
	result["research"] = !!web?.researched_nodes[researched] && web.babylon_target == target
	return result
