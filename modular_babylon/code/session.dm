// Babylon's drone-builder session. Compiled only into babylon.dmb.

/// A player's drone. The owner's record keeps the fields older saves wrote at the top of
/// state.json ("builder", "player"); capture_session_state() still writes them from it.
/datum/babylon_player
	var/mob/living/basic/drone/babylon/builder
	var/turf/respawn_turf
	var/respawn_pending = FALSE
	var/respawn_ready_at = 0
	var/list/drone_profile = list()
	var/datum/action/babylon_self_destruct/destruct_action
	var/datum/action/babylon_return_to_lobby/return_action
	var/datum/action/babylon_respawn/respawn_action

/datum/babylon_save/proc/boot()
	try
		boot_impl()
	catch(var/exception/error)
		boot_error = "[error]"
		log_world("BABYLON STARTUP ERROR: [error]")

/datum/babylon_save/proc/boot_impl()
	while(Master.init_stage_completed < INITSTAGE_MAX)
		sleep(1 SECONDS)
	station_z = SSmapping.levels_by_trait(ZTRAIT_STATION)[1]
	if(!prepared)
		CRASH("Babylon restoration did not complete before simulation startup")
	var/datum/babylon_player/owner = owner_player()
	// The owner's spawn point is the world's (older saves kept the two in one field).
	if(!respawn_turf)
		respawn_turf = owner.respawn_turf
	// Pick the original engineering spawn before removing all ghost-role props.
	for(var/obj/effect/mob_spawn/ghost_role/drone/derelict/babylon/shell in world)
		if(shell.z != station_z)
			continue
		if(!respawn_turf && istype(get_area(shell), /area/ruin/space/bb13/engineering/sec_eng))
			respawn_turf = get_turf(shell)
		qdel(shell)
	if(!valid_respawn_tile(respawn_turf))
		respawn_turf = find_respawn_tile()
	if(!owner.builder && !owner.respawn_pending && respawn_turf)
		owner.builder = new(respawn_turf)
	if(!owner.builder && !owner.respawn_pending)
		for(var/turf/open/floor/tile in world)
			if(tile.z == station_z && istype(get_area(tile), /area/ruin/space/bb13/engineering/sec_eng))
				var/blocked = FALSE
				for(var/atom/movable/obstacle in tile)
					if(obstacle.density)
						blocked = TRUE
				if(!blocked)
					owner.builder = new(tile)
					break
	if(!owner.builder && !owner.respawn_pending)
		CRASH("No safe Babylon drone spawn was found")
	if(owner.builder && !respawn_turf)
		respawn_turf = get_turf(owner.builder)
	owner.respawn_turf = respawn_turf
	if(owner.builder)
		if(owner.builder.stat == DEAD && !owner.respawn_pending)
			owner.begin_respawn(owner.builder)
		else if(!owner.respawn_pending)
			owner.install_drone_actions()
	SSticker.start_immediately = TRUE
	for(var/obj/item/modular_computer/computer as anything in programs_to_resume)
		var/list/record = programs_to_resume[computer]
		for(var/filename in record["background_programs"])
			var/datum/computer_file/program/program = computer.find_file_by_name(filename)
			if(program)
				computer.open_program(null, program, FALSE)
		var/datum/computer_file/program/program = computer.find_file_by_name(record["active_program"])
		if(program)
			computer.open_program(null, program, FALSE)
	ready = TRUE
	next_autosave_at = world.time + 15 MINUTES
	// One runtime error would otherwise end this loop for the rest of the run: nobody joining
	// afterwards is put into a drone, and they stay on the title screen with its music.
	while(TRUE)
		try
			tick_world()
		catch(var/exception/error)
			babylon_loop_failed("world tick", error)
		sleep(1 SECONDS)

/datum/babylon_save/tick_players()
	if(!draining)
		for(var/client/student in GLOB.clients)
			if(!babylon_ready_client(student))
				continue
			// Each player on their own, so one player's error cannot block everyone else.
			try
				if(student.babylon_showcase_visitor)
					ensure_showcase_visitor(student)
				else if(student.babylon_admin_spectator)
					ensure_admin_spectator(student)
				else
					ensure_player(student.ckey)
				if(!busy)
					student.babylon_check_afk(afk_timeout)
				student.babylon_update_music()
			catch(var/exception/error)
				babylon_loop_failed("player [student?.ckey]", error)
		for(var/player_key in player_sessions)
			var/datum/babylon_player/player = player_sessions[player_key]
			try
				tick_player(player, babylon_ready_client(GLOB.directory[player_key]))
			catch(var/exception/error)
				babylon_loop_failed("player [player_key]", error)
		tick_survival()
	schedule_autosave()

SUBSYSTEM_DEF(babylon_builder)
	name = "Babylon Saves"
	init_stage = INITSTAGE_LAST
	ss_flags = SS_NO_FIRE

/datum/controller/subsystem/babylon_builder/Initialize()
	var/datum/babylon_save/session = GLOB.babylon_save
	session.owner_ckey = ckey(world.params["babylon-owner"])
	if(!session.owner_ckey)
		session.boot_error = "Set babylon-owner=<BYOND ckey> in world parameters. A world owner is required."
		return SS_INIT_FAILURE
	session.player_sessions[session.owner_ckey] = new /datum/babylon_player(session.owner_ckey)
	babylon_apply_world_name()
	if(!session.read_afk_timeout())
		return SS_INIT_FAILURE
	// Babylon owns this policy, including ghosts and administrators.
	CONFIG_SET(flag/kick_inactive, FALSE)
	session.station_z = SSmapping.levels_by_trait(ZTRAIT_STATION)[1]
	try
		session.restore_world()
		session.prepared = TRUE
	catch(var/exception/error)
		session.boot_error = "Restore failed: [error]"
		return SS_INIT_FAILURE
	INVOKE_ASYNC(GLOB.babylon_save, TYPE_PROC_REF(/datum/babylon_save, boot))
	return SS_INIT_SUCCESS

/datum/babylon_save/checkpoint_hold(frozen)
	for(var/player_key in player_sessions)
		var/datum/babylon_player/player = player_sessions[player_key]
		if(QDELETED(player.builder))
			continue
		if(frozen)
			ADD_TRAIT(player.builder, TRAIT_IMMOBILIZED, "babylon_checkpoint")
			ADD_TRAIT(player.builder, TRAIT_UI_BLOCKED, "babylon_checkpoint")
		else
			REMOVE_TRAIT(player.builder, TRAIT_IMMOBILIZED, "babylon_checkpoint")
			REMOVE_TRAIT(player.builder, TRAIT_UI_BLOCKED, "babylon_checkpoint")

/datum/babylon_save/checkpoint_mobs()
	// A drone can be inside a locker or vent. Save it at the enclosing tile
	// rather than silently dropping its body and inventory from the checkpoint.
	var/list/drones_by_turf = list()
	for(var/mob/living/basic/drone/babylon/drone in GLOB.mob_list)
		var/turf/tile = get_turf(drone)
		if(QDELETED(drone) || tile?.z != station_z)
			continue
		if(!drones_by_turf[tile])
			drones_by_turf[tile] = list()
		var/list/drones = drones_by_turf[tile]
		drones += drone
	return drones_by_turf

/datum/babylon_save/capture_session_state(list/state, for_tutorial = FALSE)
	// The owner's drone, also at the top level, as saves before multiplayer had it.
	var/datum/babylon_player/owner = owner_player()
	state["builder"] = !QDELETED(owner.builder) ? owner.builder?.babylon_save_id : null
	state["player"] = list("respawn_pending" = owner.respawn_pending, "respawn_remaining" = max(0, owner.respawn_ready_at - world.time), "spawn_x" = owner.respawn_turf?.x, "spawn_y" = owner.respawn_turf?.y, "profile" = owner.respawn_pending ? owner.drone_profile.Copy() : owner.capture_drone_profile())
	var/list/players = list()
	for(var/player_key in player_sessions)
		players[player_key] = player_snapshot(player_sessions[player_key])
	state["players"] = players
	var/datum/techweb/science/research = locate(/datum/techweb/science) in SSresearch.techwebs
	if(research)
		state["research"] = list("nodes" = research.researched_nodes.Copy(), "designs" = research.researched_designs.Copy(), "points" = research.research_points.Copy(), "target" = research.babylon_target, "target_by" = research.babylon_target_by, "target_location" = research.babylon_target_location)
	state["lore"] = GLOB.babylon_lore.snapshot()

/datum/babylon_save/restore_session_state(list/state)
	var/list/players = state["players"]
	if(!players)
		var/list/legacy_player = state["player"] || list()
		legacy_player["builder"] = state["builder"]
		players = list()
		players[owner_ckey] = legacy_player
	for(var/player_key in players)
		var/datum/babylon_player/player = player_sessions[player_key]
		if(!player)
			player = new(player_key)
			player_sessions[player_key] = player
		restore_player(player, players[player_key])
	var/datum/techweb/science/research = locate(/datum/techweb/science) in SSresearch.techwebs
	var/list/research_data = state["research"]
	if(research && research_data)
		for(var/node in research_data["nodes"])
			research.research_node_id(node, TRUE, FALSE, FALSE)
		for(var/design in research_data["designs"])
			research.add_design_by_id(design)
		research.research_points = research_data["points"]
		research.recalculate_nodes()
		// research_points is the progress towards the saved target (research.dm). Older saves
		// have no target, so their banked points are dropped; an invalid target is cleared.
		research.babylon_target = research_data["target"]
		research.babylon_target_by = research_data["target_by"]
		research.babylon_target_location = research_data["target_location"]
		research.babylon_try_finish()
	GLOB.babylon_lore.restore(state["lore"])
	if((state["version"] || 1) < 7)
		restore_lost_supermatter()

/mob/living/basic/drone/babylon/verb/save_babylon()
	set name = "Save Babylon"
	set category = "Babylon"
	if(ckey == GLOB.babylon_save.owner_ckey)
		GLOB.babylon_save.save_world()

/mob/living/basic/drone/babylon/verb/save_stop_babylon()
	set name = "Save and Stop Babylon"
	set category = "Babylon"
	if(ckey != GLOB.babylon_save.owner_ckey)
		return
	GLOB.babylon_save.managed_stop()

/// Worlds that are not saved (babylon_world_saves()) show no save verbs.
/datum/babylon_save/proc/hide_save_verbs(mob/living/basic/drone/babylon/drone)
	if(drone && !babylon_world_saves())
		remove_verb(drone, list(/mob/living/basic/drone/babylon/verb/save_babylon, /mob/living/basic/drone/babylon/verb/save_stop_babylon))

/datum/babylon_save/proc/player_for_drone(mob/living/basic/drone/babylon/drone)
	RETURN_TYPE(/datum/babylon_player)
	for(var/player_key in player_sessions)
		var/datum/babylon_player/player = player_sessions[player_key]
		if(player.builder == drone)
			return player
	return null

/datum/babylon_save/proc/ensure_player(player_key)
	player_key = ckey(player_key)
	if(!player_key)
		return null
	var/client/student = GLOB.directory[player_key]
	if(student?.babylon_showcase_visitor || student?.babylon_admin_spectator)
		return null
	var/datum/babylon_player/player = player_sessions[player_key]
	if(player)
		return player
	var/turf/spawn_point = find_respawn_tile()
	if(!spawn_point)
		return null
	player = new(player_key)
	player.respawn_turf = spawn_point
	player.builder = new(spawn_point)
	player_sessions[player_key] = player
	return player

/datum/babylon_save/proc/player_snapshot(datum/babylon_player/player)
	return list("builder" = !QDELETED(player.builder) ? player.builder.babylon_save_id : null, "respawn_pending" = player.respawn_pending, "respawn_remaining" = max(0, player.respawn_ready_at - world.time), "spawn_x" = player.respawn_turf?.x, "spawn_y" = player.respawn_turf?.y, "profile" = player.respawn_pending ? player.drone_profile.Copy() : player.capture_drone_profile(), "play_time" = player.play_time)

/datum/babylon_save/proc/restore_player(datum/babylon_player/player, list/snapshot)
	player.builder = restored_atoms[snapshot["builder"]]
	player.respawn_pending = snapshot["respawn_pending"]
	player.respawn_ready_at = player.respawn_pending ? world.time + snapshot["respawn_remaining"] : 0
	player.drone_profile = snapshot["profile"] || list()
	player.play_time = isnum(snapshot["play_time"]) ? snapshot["play_time"] : 0
	if(snapshot["spawn_x"] && snapshot["spawn_y"])
		player.respawn_turf = locate(snapshot["spawn_x"], snapshot["spawn_y"], station_z)
	var/mob/living/basic/drone/babylon/drone = player.builder
	if(!drone)
		return
	var/list/hands = drone.held_items.Copy()
	drone.held_items = new /list(length(hands))
	for(var/index in 1 to length(hands))
		var/obj/item/item = hands[index]
		if(item)
			drone.put_in_hand(item, index, forced = TRUE)
	if(!("picked" in resume_records[drone.babylon_save_id]["fields"]))
		drone.picked = TRUE
	drone.update_held_items()
	drone.update_inv_internal_storage()
	drone.update_worn_head()

/datum/babylon_save/proc/tick_player(datum/babylon_player/player, client/student)
	// A spectating admin may still own a drone from an earlier visit; it is not taken over.
	if(student?.babylon_showcase_visitor || student?.babylon_admin_spectator)
		return
	if(!player.respawn_turf)
		player.respawn_turf = respawn_turf
	if(!player.respawn_pending && QDELETED(player.builder))
		player.begin_respawn()
	if(player.builder?.stat == DEAD && !player.respawn_pending)
		player.begin_respawn(player.builder)
	if(player.respawn_pending)
		player.update_respawn_player(student)
	else if(student && student.mob != player.builder)
		var/mob/previous = student.mob
		if(isnewplayer(previous))
			var/mob/dead/new_player/lobby = previous
			lobby.spawning = TRUE
			lobby.hide_title_screen()
		player.builder.PossessByPlayer(student.ckey)
		player.install_drone_actions()
		hide_save_verbs(player.builder)
		if(previous && isnewplayer(previous))
			qdel(previous)
	if(student)
		winset(student, "title_browser", "is-disabled=true;is-visible=false")
		winset(student, "status_bar", "is-visible=true")
