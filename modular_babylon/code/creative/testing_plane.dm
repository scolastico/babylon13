// Integration tests for the Creative Plane maps (creative/plane.dm), station test build only.
// Asserted from services/supervisor/smoke_station.py; every check must be TRUE.

/// The floor size of a Creative Plane catalog id (gen_creative_plane.py SIZES).
/proc/babylon_creative_plane_size(map_id)
	switch(map_id)
		if("creative_plane_s")
			return 50
		if("creative_plane_m")
			return 100
		if("creative_plane_l")
			return 200

/// The atom is on the Creative Plane (its floor or its utility corner).
/proc/babylon_on_plane(atom/thing)
	return istype(get_area(thing), /area/station/babylon/creative_plane)

/// The APCs of the plane's two areas.
/proc/babylon_plane_apcs()
	var/list/apcs = list()
	for(var/area_type in list(/area/station/babylon/creative_plane, /area/station/babylon/creative_plane/utilities))
		var/area/plane_area = GLOB.areas_by_type[area_type]
		apcs += plane_area?.apc
	return apcs

/// A fresh Creative Plane world, still held before its round: the map, its landmarks, air,
/// gravity, power wiring and atmos layout, the inert storyteller and the refused shuttle.
/// Machines and air only process once the round runs (test_creative_plane_round).
/datum/babylon_save/proc/test_creative_plane()
	var/list/result = list()
	var/datum/babylon_world/flags = GLOB.babylon_world
	var/size = babylon_creative_plane_size(flags.map_id)
	result["creative_plane_world"] = flags.is_creative_plane() && !!size
	result["map_loaded"] = SSmapping.current_map?.map_name == "Creative Plane [uppertext(copytext(flags.map_id, -1))]"
	if(!size)
		return result
	result["inert_storyteller"] = babylon_storyteller_inert() && (SSgamemode.storyteller?.type || SSgamemode.voted_storyteller) == /datum/storyteller/babylon
	result["no_mining_level"] = !length(SSmapping.levels_by_trait(ZTRAIT_MINING))

	// The floor: size x size open turfs, centred on the 255x255 level, inside a wall ring.
	var/area/plane = GLOB.areas_by_type[/area/station/babylon/creative_plane]
	result["plane_area"] = !!plane && (plane.type in GLOB.the_station_areas)
	if(!plane)
		return result
	var/low_x = world.maxx
	var/low_y = world.maxy
	var/high_x = 0
	var/high_y = 0
	for(var/turf/open/floor in get_area_turfs(/area/station/babylon/creative_plane, station_z, TRUE))
		low_x = min(low_x, floor.x)
		low_y = min(low_y, floor.y)
		high_x = max(high_x, floor.x)
		high_y = max(high_y, floor.y)
	var/start = round((255 - size) / 2) + 1
	result["floor_size"] = high_x - low_x + 1 == size && high_y - low_y + 1 == size
	result["floor_centred"] = low_x == start && low_y == start
	// The ring cannot be breached (it would vent the whole plane); the utility room's walls can.
	result["indestructible_ring"] = istype(locate(low_x - 1, low_y + 10, station_z), /turf/closed/indestructible/reinforced) && istype(locate(high_x + 1, high_y, station_z), /turf/closed/indestructible/reinforced) && istype(locate(low_x + 3, high_y + 1, station_z), /turf/closed/indestructible/reinforced)
	result["room_walls_ordinary"] = istype(locate(low_x + 1, low_y + 1, station_z), /turf/closed/wall)
	var/west_catwalk_open = TRUE
	for(var/y in low_y to high_y)
		if(!istype(locate(low_x, y, station_z), /turf/open/floor/catwalk_floor/iron))
			west_catwalk_open = FALSE
	result["west_catwalk_open"] = west_catwalk_open
	result["utility_area"] = istype(GLOB.areas_by_type[/area/station/babylon/creative_plane/utilities], /area/station/babylon/creative_plane/utilities)
	// Creative Plane machines run whatever the Creative flag; their settings stay Creative-only.
	result["machines_active"] = babylon_creative_machines_active()
	result["space_around"] = isspaceturf(locate(low_x - 5, low_y - 5, station_z)) && isspaceturf(locate(high_x + 5, high_y + 5, station_z))
	result["fullbright"] = !plane.static_lighting && plane.base_lighting_alpha == 255

	// Air, gravity and power on sample tiles: the middle, a far corner and inside the atmos room.
	var/list/samples = list(locate(low_x + round(size / 2) + 3, low_y + round(size / 2), station_z), locate(high_x, high_y, station_z), locate(low_x + 3, low_y + 4, station_z))
	var/air_ok = TRUE
	var/gravity_ok = TRUE
	for(var/turf/open/sample in samples)
		var/datum/gas_mixture/air = sample.return_air()
		var/pressure = air.return_pressure()
		var/total = air.total_moles()
		var/oxygen = air.moles[/datum/gas/oxygen] || 0
		if(pressure < 90 || pressure > 120 || !total || oxygen / total * pressure < 16)
			air_ok = FALSE
		if(sample.has_gravity() <= 0)
			gravity_ok = FALSE
	result["three_open_samples"] = length(samples) == 3 && !(null in samples) && isopenturf(samples[1]) && isopenturf(samples[2]) && isopenturf(samples[3])
	result["breathable_air"] = air_ok
	result["gravity"] = gravity_ok
	var/list/apcs = babylon_plane_apcs()
	var/apcs_ok = length(apcs) == 2 && !(null in apcs)
	for(var/obj/machinery/power/apc/apc as anything in apcs)
		if(!apc?.operating || !apc.cell || !apc.area.powered(AREA_USAGE_EQUIP) || !apc.area.powered(AREA_USAGE_ENVIRON))
			apcs_ok = FALSE
	result["two_apcs_powered_areas"] = apcs_ok

	var/list/smeses = SSmachines.get_machines_by_type(/obj/machinery/power/smes/babylon_creative)
	var/obj/machinery/power/smes/babylon_creative/smes = length(smeses) == 1 ? smeses[1] : null
	result["one_creative_smes"] = !!smes && babylon_on_plane(smes)
	result["smes_source_with_terminal"] = !!smes && smes.creative_mode == "source" && !!smes.terminal && smes.output_attempt
	var/feeds = !!smes?.powernet && apcs_ok
	for(var/obj/machinery/power/apc/apc as anything in apcs)
		if(apc?.terminal?.powernet != smes?.powernet)
			feeds = FALSE
	result["smes_feeds_both_apcs"] = feeds
	result["smes_charged"] = !!smes && smes.output_attempt && smes.total_charge() > 0

	// Atmos: O2 and N2 sources and a void, each on its port; mixer, two vents, two scrubbers.
	var/list/canisters = list()
	for(var/obj/machinery/portable_atmospherics/canister/babylon_creative/canister as anything in SSmachines.get_machines_by_type_and_subtypes(/obj/machinery/portable_atmospherics/canister/babylon_creative))
		if(babylon_on_plane(canister))
			canisters += canister
	var/sources = list()
	var/voids = 0
	var/connected = TRUE
	for(var/obj/machinery/portable_atmospherics/canister/babylon_creative/canister as anything in canisters)
		if(!canister.connected_port)
			connected = FALSE
		if(canister.creative_mode == "void")
			voids++
		else
			sources += canister.creative_gas
	result["three_canisters_connected"] = length(canisters) == 3 && connected
	result["oxygen_and_nitrogen_sources"] = (/datum/gas/oxygen in sources) && (/datum/gas/nitrogen in sources) && length(sources) == 2
	result["one_void"] = voids == 1
	var/list/mixers = SSmachines.get_machines_by_type(/obj/machinery/atmospherics/components/trinary/mixer/airmix)
	var/obj/machinery/atmospherics/components/trinary/mixer/airmix/mixer = length(mixers) == 1 ? mixers[1] : null
	result["air_mixer_connected"] = !!mixer && mixer.on && !!mixer.nodes[1] && !!mixer.nodes[2] && !!mixer.nodes[3]
	// Two vents and two scrubbers in the atmos room, and (spec #13) a spread of them in the main
	// room, every one connected to its pipe.
	var/vents = 0
	var/scrubbers = 0
	var/room_vents = 0
	var/room_scrubbers = 0
	var/connected_all = TRUE
	for(var/obj/machinery/atmospherics/components/unary/vent_pump/vent as anything in SSmachines.get_machines_by_type_and_subtypes(/obj/machinery/atmospherics/components/unary/vent_pump))
		if(!babylon_on_plane(vent))
			continue
		if(!vent.on || !vent.nodes[1])
			connected_all = FALSE
			continue
		vents++
		if(istype(get_area(vent), /area/station/babylon/creative_plane/utilities))
			room_vents++
	for(var/obj/machinery/atmospherics/components/unary/vent_scrubber/scrubber as anything in SSmachines.get_machines_by_type_and_subtypes(/obj/machinery/atmospherics/components/unary/vent_scrubber))
		if(!babylon_on_plane(scrubber))
			continue
		if(!scrubber.on || !scrubber.nodes[1])
			connected_all = FALSE
			continue
		scrubbers++
		if(istype(get_area(scrubber), /area/station/babylon/creative_plane/utilities))
			room_scrubbers++
	result["two_vents_two_scrubbers"] = room_vents == 2 && room_scrubbers == 2
	result["main_room_vents_and_scrubbers"] = connected_all && vents - room_vents >= 8 && scrubbers - room_scrubbers >= 8
	// The canisters reconnect to their ports by themselves (mapload, restored saves), but a
	// player's wrench sticks. Exercised on the void canister, then restored.
	var/obj/machinery/portable_atmospherics/canister/babylon_creative/void
	for(var/obj/machinery/portable_atmospherics/canister/babylon_creative/canister as anything in canisters)
		if(canister.creative_mode == "void")
			void = canister
	if(void)
		var/obj/machinery/atmospherics/components/unary/portables_connector/port = void.connected_port
		void.disconnect()
		result["wrench_sticks"] = !void.connected_port && !void.babylon_port_wanted && (void.process_atmos() || TRUE) && !void.connected_port
		void.babylon_port_wanted = TRUE
		void.process_atmos()
		result["reconnects_lazily"] = void.connected_port == port
		void.disconnect()
		result["reconnect_proc"] = void.babylon_reconnect_port() && void.connected_port == port && void.babylon_port_wanted

	// The tutorial wand's area tools (tutorial/area_tools.dm) never change the ring: a Fill over
	// a stretch of it changes nothing and counts every tile as locked.
	var/list/ring_rect = list(low_x - 1, low_y + 10, low_x - 1, low_y + 14, station_z)
	var/list/ring = babylon_area_tiles(low_x - 1, low_y + 10, low_x - 1, low_y + 14, station_z)
	var/list/journal = list("turfs" = list(), "made" = list())
	var/list/counts = babylon_area_put(ring, /turf/open/floor/plating, FALSE, ring_rect, journal)
	var/ring_kept = length(ring) == 5
	for(var/turf/tile as anything in ring)
		if(!istype(tile, /turf/closed/indestructible/reinforced) || !babylon_area_locked(tile))
			ring_kept = FALSE
	result["area_tools_leave_ring"] = ring_kept && counts["locked"] == 5 && !counts["changed"] && !length(journal["turfs"])

	// Landmarks: late-join points (the B2 setup uses the map's own), Assistant starts, observer.
	var/latejoins_on_plane = length(babylon_latejoin_points()) >= 4
	for(var/turf/point as anything in babylon_latejoin_points())
		if(get_area(point) != plane)
			latejoins_on_plane = FALSE
	result["latejoin_points_on_plane"] = latejoins_on_plane && latejoin_source == "map"
	var/assistant_starts = 0
	for(var/obj/effect/landmark/start/landmark as anything in GLOB.start_landmarks_list)
		if(landmark.name == JOB_ASSISTANT && get_area(landmark) == plane)
			assistant_starts++
	result["assistant_starts"] = assistant_starts >= 4
	result["observer_start_on_plane"] = get_area(respawn_turf) == plane
	var/datum/job/assistant = SSjob.get_job_type(/datum/job/assistant)
	result["assistant_spawns_on_plane"] = get_area(assistant.get_roundstart_spawn_point()) == plane && get_area(assistant.get_latejoin_spawn_point()) == plane
	// Jobs without a landmark here fall back to the late-join points (tg's job code).
	var/datum/job/engineer = SSjob.get_job_type(/datum/job/station_engineer)
	result["other_jobs_fall_back_to_latejoin"] = get_area(engineer.get_roundstart_spawn_point()) == plane
	result["tutorial_start_on_plane"] = get_area(babylon_tutorial_start_turf()) == plane

	// No emergency dock: no call, no autocall, the shuttle stays idle.
	result["no_emergency_dock"] = babylon_emergency_dock_missing()
	result["evac_refused"] = SSshuttle.canEvac() == BABYLON_NO_EMERGENCY_DOCK_TEXT
	if(SSshuttle.emergency)
		SSshuttle.emergency.request(null, set_coefficient = 1)
		result["request_refused"] = SSshuttle.emergency.mode == SHUTTLE_IDLE
	// Nor the supply shuttle: its console refuses, and a request to the missing dock is ignored.
	result["no_cargo_dock"] = babylon_dock_missing("cargo_home")
	if(SSshuttle.supply)
		var/obj/machinery/computer/cargo/console = new(respawn_turf)
		console.ui_act("send", list(), null, null)
		SSshuttle.supply.request(SSshuttle.getDock("cargo_home"))
		result["supply_refused"] = SSshuttle.supply.mode == SHUTTLE_IDLE
		qdel(console)
	return result

/// After the owner's Start round on a Creative Plane, a few seconds into the round (machines and
/// air process now): the SMES powers the APC, the mixer fills the supply line from the creative
/// sources, the round stays inert and no shuttle comes.
/datum/babylon_save/proc/test_creative_plane_round()
	var/list/result = list()
	result["round_running"] = SSticker.current_state == GAME_STATE_PLAYING
	var/list/apcs = babylon_plane_apcs()
	var/apcs_ok = length(apcs) == 2 && !(null in apcs)
	for(var/obj/machinery/power/apc/apc as anything in apcs)
		if(!apc?.operating || apc.main_status != APC_HAS_POWER || !apc.area.powered(AREA_USAGE_EQUIP))
			apcs_ok = FALSE
	result["apcs_have_power"] = apcs_ok
	var/list/smeses = SSmachines.get_machines_by_type(/obj/machinery/power/smes/babylon_creative)
	var/obj/machinery/power/smes/babylon_creative/smes = length(smeses) == 1 ? smeses[1] : null
	result["smes_outputs"] = !!smes && smes.outputting && smes.powernet?.avail > 0
	if(babylon_creative_machines_active())
		var/capacity = 0
		for(var/obj/item/stock_parts/power_store/cell in smes?.component_parts)
			capacity += cell.max_charge()
		result["smes_stays_full"] = capacity > 0 && smes.total_charge() >= capacity * 0.99
		var/distro_pressure = 0
		var/oxygen_share = 0
		// Spec #13: the main room's vents (outside the atmos room) get the mixer's air through
		// the long supply run, not only the vents beside the mixer.
		var/main_vents = 0
		var/main_vents_supplied = TRUE
		for(var/obj/machinery/atmospherics/components/unary/vent_pump/vent as anything in SSmachines.get_machines_by_type_and_subtypes(/obj/machinery/atmospherics/components/unary/vent_pump))
			if(babylon_on_plane(vent))
				var/datum/gas_mixture/pipe_air = vent.airs[1]
				distro_pressure = max(distro_pressure, pipe_air.return_pressure())
				var/total = pipe_air.total_moles()
				oxygen_share = total ? (pipe_air.moles[/datum/gas/oxygen] || 0) / total : 0
				if(!istype(get_area(vent), /area/station/babylon/creative_plane/utilities))
					main_vents++
					if(pipe_air.return_pressure() < 100 || oxygen_share < 0.18 || oxygen_share > 0.24)
						main_vents_supplied = FALSE
		result["main_room_vents_supplied"] = main_vents >= 8 && main_vents_supplied
		result["distro_pressurised"] = distro_pressure > 1000
		// The air mixer's 21 % oxygen / 79 % nitrogen.
		result["distro_is_air"] = oxygen_share > 0.18 && oxygen_share < 0.24
	// Spec #13: every main-room scrubber is on the one pipeline that ends at the void canister's port,
	// so what they take in really drains.
	var/obj/machinery/portable_atmospherics/canister/babylon_creative/void
	for(var/obj/machinery/portable_atmospherics/canister/babylon_creative/canister as anything in SSmachines.get_machines_by_type_and_subtypes(/obj/machinery/portable_atmospherics/canister/babylon_creative))
		if(babylon_on_plane(canister) && canister.creative_mode == "void")
			void = canister
	var/datum/pipeline/drain = void?.connected_port?.parents?[1]
	var/main_scrubbers = 0
	var/main_scrubbers_drain = !!drain
	for(var/obj/machinery/atmospherics/components/unary/vent_scrubber/scrubber as anything in SSmachines.get_machines_by_type_and_subtypes(/obj/machinery/atmospherics/components/unary/vent_scrubber))
		if(babylon_on_plane(scrubber) && !istype(get_area(scrubber), /area/station/babylon/creative_plane/utilities))
			main_scrubbers++
			if(scrubber.parents[1] != drain)
				main_scrubbers_drain = FALSE
	result["main_room_scrubbers_drain_to_void"] = main_scrubbers >= 8 && main_scrubbers_drain
	var/turf/open/middle = get_turf(respawn_turf)
	var/datum/gas_mixture/air = middle?.return_air()
	result["still_breathable"] = !!air && air.return_pressure() > 90 && air.return_pressure() < 120
	result["inert_storyteller"] = SSgamemode.storyteller?.type == /datum/storyteller/babylon
	result["no_antagonists"] = !length(GLOB.antagonists)
	SSshuttle.CheckAutoEvac()
	result["no_autocall"] = !SSshuttle.emergency_no_recall && (!SSshuttle.emergency || SSshuttle.emergency.mode == SHUTTLE_IDLE)
	return result

/// Ordinary station maps keep their emergency shuttle (plane.dm only refuses dockless maps).
/datum/babylon_save/proc/test_station_emergency_dock()
	var/list/result = list()
	result["dock_found"] = !babylon_emergency_dock_missing()
	result["evac_not_refused_by_babylon"] = SSshuttle.canEvac() != BABYLON_NO_EMERGENCY_DOCK_TEXT
	return result

/datum/babylon_save/proc/test_creative_plane_round_info()
	return test_creative_plane_info()

/// Numbers behind the Creative Plane tests' power and atmos checks, for the smoke report (not asserted).
/datum/babylon_save/proc/test_creative_plane_info()
	var/list/result = list()
	for(var/obj/machinery/power/apc/apc as anything in babylon_plane_apcs())
		if(!apc)
			continue
		result["apc_main_status"] = apc.main_status
		result["apc_operating"] = apc.operating
		result["apc_avail"] = apc.avail()
		result["apc_surplus"] = apc.surplus()
		result["apc_cell"] = apc.cell ? "[apc.cell.charge()]/[apc.cell.maxcharge]" : "none"
		result["apc_charging"] = apc.charging
	for(var/obj/machinery/power/smes/babylon_creative/smes as anything in SSmachines.get_machines_by_type(/obj/machinery/power/smes/babylon_creative))
		result["smes_charge"] = smes.total_charge()
		result["smes_output_level"] = smes.output_level
		result["smes_output_used"] = smes.output_used
		result["smes_outputting"] = smes.outputting
		result["powernet_avail"] = smes.powernet?.avail
		result["powernet_load"] = smes.powernet?.load
	for(var/obj/machinery/portable_atmospherics/canister/babylon_creative/canister as anything in SSmachines.get_machines_by_type_and_subtypes(/obj/machinery/portable_atmospherics/canister/babylon_creative))
		result["canister [canister.creative_mode] [canister.creative_gas]"] = round(canister.air_contents.return_pressure())
	for(var/obj/machinery/atmospherics/components/trinary/mixer/airmix/mixer as anything in SSmachines.get_machines_by_type(/obj/machinery/atmospherics/components/trinary/mixer/airmix))
		for(var/index in 1 to 3)
			var/datum/gas_mixture/air = mixer.airs[index]
			result["mixer air[index]"] = round(air.return_pressure())
		result["mixer on"] = mixer.on
		result["mixer operational"] = mixer.is_operational
	var/vent_index = 0
	for(var/obj/machinery/atmospherics/components/unary/vent_pump/vent as anything in SSmachines.get_machines_by_type_and_subtypes(/obj/machinery/atmospherics/components/unary/vent_pump))
		if(!babylon_on_plane(vent))
			continue
		vent_index++
		var/datum/gas_mixture/air = vent.airs[1]
		result["vent [vent_index] pipe"] = round(air.return_pressure())
	return result

/// The floor's south-west tile on a Creative Plane (gen_creative_plane.py centres the floor).
/datum/babylon_save/proc/creative_plane_origin()
	var/size = babylon_creative_plane_size(GLOB.babylon_world.map_id)
	if(!size)
		return null
	var/start = round((255 - size) / 2) + 1
	return locate(start, start, station_z)

/// Before a Creative Plane save: a tutorial NPC spawner with its NPC, one of the NPC's outfit
/// items dropped on another tile next to an ordinary wrench, a changed creative canister
/// setting and two spawned cleanbots (possession off and on). test_creative_plane_restored checks
/// what came back.
/datum/babylon_save/proc/test_creative_plane_save_setup()
	var/list/result = list()
	var/turf/origin = creative_plane_origin()
	result["on_plane"] = !!origin
	if(!origin)
		return result
	var/turf/spawn_tile = locate(origin.x + 20, origin.y + 20, origin.z)
	var/turf/drop_tile = locate(origin.x + 24, origin.y + 20, origin.z)
	var/obj/babylon_tutorial/npc_spawner/spawner = babylon_tutorial_place_npc(spawn_tile, "guide")
	var/mob/living/carbon/human/npc = spawner?.current_npc()
	result["npc_spawned"] = !!npc && npc.babylon_tutorial_npc
	result["spawn_at_start"] = !!spawner && !spawner.set_setting("spawn_at_start", 1) && spawner.setting("spawn_at_start")
	var/obj/item/outfit_item = npc?.w_uniform || npc?.shoes
	if(outfit_item)
		npc.dropItemToGround(outfit_item, force = TRUE)
		outfit_item.forceMove(drop_tile)
	result["outfit_item_dropped"] = !!outfit_item && outfit_item.loc == drop_tile && outfit_item.babylon_tutorial_npc_item
	result["skip_hook_npc"] = !!npc && npc.babylon_skip_save() && outfit_item?.babylon_skip_save() && !spawner.babylon_skip_save()
	var/obj/item/wrench/wrench = new(drop_tile)
	result["control_item"] = !wrench.babylon_skip_save()
	var/obj/machinery/portable_atmospherics/canister/babylon_creative/nitrogen
	for(var/obj/machinery/portable_atmospherics/canister/babylon_creative/canister as anything in SSmachines.get_machines_by_type_and_subtypes(/obj/machinery/portable_atmospherics/canister/babylon_creative))
		if(babylon_on_plane(canister) && canister.creative_gas == /datum/gas/nitrogen)
			nitrogen = canister
	if(nitrogen)
		nitrogen.creative_pressure = 3210
	result["canister_setting_changed"] = nitrogen?.creative_pressure == 3210
	// A player unwrenches the void canister and leaves it on its port's tile.
	var/obj/machinery/portable_atmospherics/canister/babylon_creative/void_canister
	for(var/obj/machinery/portable_atmospherics/canister/babylon_creative/canister as anything in SSmachines.get_machines_by_type_and_subtypes(/obj/machinery/portable_atmospherics/canister/babylon_creative))
		if(babylon_on_plane(canister) && canister.creative_mode == "void")
			void_canister = canister
	void_canister?.disconnect()
	result["void_canister_unwrenched"] = !!void_canister && !void_canister.connected_port && !void_canister.babylon_port_wanted \
		&& !!(locate(/obj/machinery/atmospherics/components/unary/portables_connector) in void_canister.loc)
	// Two spawned cleanbots (as the Creative panel spawns them): one as spawned, without ghost
	// possession, and one whose personality setting a player switched on.
	var/mob/living/basic/bot/cleanbot/bot_off = new(locate(origin.x + 28, origin.y + 20, origin.z))
	bot_off.name = "babylon test bot off"
	bot_off.real_name = bot_off.name
	var/mob/living/basic/bot/cleanbot/bot_on = new(locate(origin.x + 30, origin.y + 20, origin.z))
	bot_on.name = "babylon test bot on"
	bot_on.real_name = bot_on.name
	bot_on.enable_possession(mapload = TRUE)
	result["bots_spawned"] = !bot_off.can_be_possessed && !bot_off.GetComponent(/datum/component/ghost_direct_control) \
		&& bot_on.can_be_possessed && !!bot_on.GetComponent(/datum/component/ghost_direct_control)
	result["spawner_id"] = spawner?.tutorial_id
	result["outfit_type"] = "[outfit_item?.type]"
	return result

/// After the save above was restored: the creative source canisters are back on their ports with
/// their settings and the unwrenched void canister is not, the NPC spawner came back and made its
/// NPC once (the NPC and the dropped outfit item were never saved), the ordinary item next to it
/// was saved, and the two cleanbots kept their possession setting.
/datum/babylon_save/proc/test_creative_plane_restored(spawner_id, outfit_type)
	var/list/result = list()
	var/turf/origin = creative_plane_origin()
	result["on_plane"] = !!origin
	if(!origin)
		return result
	var/turf/drop_tile = locate(origin.x + 24, origin.y + 20, origin.z)
	var/list/canisters = list()
	var/ports_right = TRUE
	var/ports_right_at_restore = TRUE
	var/pressure_kept = FALSE
	for(var/obj/machinery/portable_atmospherics/canister/babylon_creative/canister as anything in SSmachines.get_machines_by_type_and_subtypes(/obj/machinery/portable_atmospherics/canister/babylon_creative))
		if(!babylon_on_plane(canister))
			continue
		canisters += canister
		// The two sources are back on their ports; the void canister, unwrenched before the save,
		// stays off its port (now and as the restore left it, before any atmos tick).
		var/wanted = canister.creative_mode != "void"
		var/on_port = !!canister.connected_port && canister.connected_port.loc == canister.loc
		if(canister.babylon_port_wanted != wanted || on_port != wanted)
			ports_right = FALSE
		var/list/at_restore = creative_canister_ports_after_restore?[canister.babylon_save_id]
		if(!at_restore || !!at_restore[1] != wanted || !!at_restore[2] != wanted)
			ports_right_at_restore = FALSE
		if(canister.creative_gas == /datum/gas/nitrogen && canister.creative_pressure == 3210)
			pressure_kept = TRUE
	result["canister_ports_as_saved"] = length(canisters) == 3 && ports_right
	result["canister_ports_as_saved_at_restore"] = length(canisters) == 3 && ports_right_at_restore
	result["canister_setting_restored"] = pressure_kept
	var/obj/babylon_tutorial/npc_spawner/spawner = babylon_tutorial_find(spawner_id)
	result["spawner_restored"] = istype(spawner) && spawner.setting("npc_name") == "Guide"
	var/npcs = 0
	for(var/mob/living/carbon/human/body in GLOB.mob_living_list)
		if(body.babylon_tutorial_npc && !QDELETED(body))
			npcs++
	result["npc_respawned_once"] = npcs == 1 && istype(spawner) && !!spawner.current_npc()
	var/outfit_path = text2path(outfit_type)
	result["dropped_outfit_not_saved"] = !!outfit_path && !(locate(outfit_path) in drop_tile)
	result["control_item_saved"] = !!(locate(/obj/item/wrench) in drop_tile)
	// The restored bots load as mapped station bots; they keep their saved possession setting.
	var/mob/living/basic/bot/cleanbot/bot_off
	var/mob/living/basic/bot/cleanbot/bot_on
	for(var/mob/living/basic/bot/cleanbot/bot in GLOB.mob_living_list)
		if(bot.name == "babylon test bot off")
			bot_off = bot
		else if(bot.name == "babylon test bot on")
			bot_on = bot
	result["bot_possession_off_kept"] = !!bot_off && !bot_off.can_be_possessed && !bot_off.GetComponent(/datum/component/ghost_direct_control)
	result["bot_possession_on_kept"] = !!bot_on && bot_on.can_be_possessed && !!bot_on.GetComponent(/datum/component/ghost_direct_control)
	return result
