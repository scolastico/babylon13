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
	for(var/turf/open/floor in get_area_turfs(plane, station_z))
		low_x = min(low_x, floor.x)
		low_y = min(low_y, floor.y)
		high_x = max(high_x, floor.x)
		high_y = max(high_y, floor.y)
	var/start = round((255 - size) / 2) + 1
	result["floor_size"] = high_x - low_x + 1 == size && high_y - low_y + 1 == size
	result["floor_centred"] = low_x == start && low_y == start
	result["walled_in"] = istype(locate(low_x - 1, low_y + 10, station_z), /turf/closed/wall) && istype(locate(high_x + 1, high_y, station_z), /turf/closed/wall)
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
	var/obj/machinery/power/apc/apc = plane.apc
	result["apc"] = !!apc && apc.operating && !!apc.cell
	result["area_powered"] = plane.powered(AREA_USAGE_EQUIP) && plane.powered(AREA_USAGE_ENVIRON)

	var/list/smeses = SSmachines.get_machines_by_type(/obj/machinery/power/smes/babylon_creative)
	var/obj/machinery/power/smes/babylon_creative/smes = length(smeses) == 1 ? smeses[1] : null
	result["one_creative_smes"] = !!smes && get_area(smes) == plane
	result["smes_source_with_terminal"] = !!smes && smes.creative_mode == "source" && !!smes.terminal && smes.output_attempt
	result["smes_feeds_the_apc"] = !!smes && !!smes.powernet && smes.powernet == apc?.terminal?.powernet
	result["smes_charged"] = !!smes && smes.output_attempt && smes.total_charge() > 0

	// Atmos: O2 and N2 sources and a void, each on its port; mixer, two vents, two scrubbers.
	var/list/canisters = list()
	for(var/obj/machinery/portable_atmospherics/canister/babylon_creative/canister as anything in SSmachines.get_machines_by_type_and_subtypes(/obj/machinery/portable_atmospherics/canister/babylon_creative))
		if(get_area(canister) == plane)
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
	var/vents = 0
	for(var/obj/machinery/atmospherics/components/unary/vent_pump/vent as anything in SSmachines.get_machines_by_type_and_subtypes(/obj/machinery/atmospherics/components/unary/vent_pump))
		if(get_area(vent) == plane && vent.on && vent.nodes[1])
			vents++
	var/scrubbers = 0
	for(var/obj/machinery/atmospherics/components/unary/vent_scrubber/scrubber as anything in SSmachines.get_machines_by_type_and_subtypes(/obj/machinery/atmospherics/components/unary/vent_scrubber))
		if(get_area(scrubber) == plane && scrubber.on && scrubber.nodes[1])
			scrubbers++
	result["two_vents_two_scrubbers"] = vents == 2 && scrubbers == 2

	// Landmarks: late-join points (the B2 setup uses the map's own), Assistant starts, observer.
	var/latejoins_on_plane = length(SSjob.latejoin_trackers) >= 4
	for(var/turf/point as anything in SSjob.latejoin_trackers)
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
	return result

/// After the owner's Start round on a Creative Plane, a few seconds into the round (machines and
/// air process now): the SMES powers the APC, the mixer fills the supply line from the creative
/// sources, the round stays inert and no shuttle comes.
/datum/babylon_save/proc/test_creative_plane_round()
	var/list/result = list()
	result["round_running"] = SSticker.current_state == GAME_STATE_PLAYING
	var/area/plane = GLOB.areas_by_type[/area/station/babylon/creative_plane]
	var/obj/machinery/power/apc/apc = plane?.apc
	result["apc_has_power"] = !!apc && apc.operating && apc.main_status == APC_HAS_POWER && plane.powered(AREA_USAGE_EQUIP)
	var/list/smeses = SSmachines.get_machines_by_type(/obj/machinery/power/smes/babylon_creative)
	var/obj/machinery/power/smes/babylon_creative/smes = length(smeses) == 1 ? smeses[1] : null
	result["smes_outputs"] = !!smes && smes.outputting && smes.powernet?.avail > 0
	if(babylon_creative_machines_active())
		var/capacity = 0
		for(var/obj/item/stock_parts/power_store/cell in smes?.component_parts)
			capacity += cell.max_charge()
		result["smes_stays_full"] = capacity > 0 && smes.total_charge() >= capacity * 0.99
		var/distro_pressure = 0
		for(var/obj/machinery/atmospherics/components/unary/vent_pump/vent as anything in SSmachines.get_machines_by_type_and_subtypes(/obj/machinery/atmospherics/components/unary/vent_pump))
			if(get_area(vent) == plane)
				var/datum/gas_mixture/pipe_air = vent.airs[1]
				distro_pressure = max(distro_pressure, pipe_air.return_pressure())
		result["distro_pressurised"] = distro_pressure > 1000
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
	var/area/plane = GLOB.areas_by_type[/area/station/babylon/creative_plane]
	var/obj/machinery/power/apc/apc = plane?.apc
	if(apc)
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
		if(get_area(vent) != plane)
			continue
		vent_index++
		var/datum/gas_mixture/air = vent.airs[1]
		result["vent [vent_index] pipe"] = round(air.return_pressure())
	return result
