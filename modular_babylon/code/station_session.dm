// The station build's session: a normal tg round world on a catalog map, run by the supervisor.
// Compiled only into babylon-station.dmb; Babylon's drone-builder session is session.dm.
// Players arrive through supervisor tickets (admission.dm) at tg's new-player menu. The loop
// below adds what every Babylon cluster world has: showcase visitors, spectating admins, AFK
// returns to the lobby, server music and play time.

SUBSYSTEM_DEF(babylon_station)
	name = "Babylon World"
	init_stage = INITSTAGE_LAST
	ss_flags = SS_NO_FIRE

/datum/controller/subsystem/babylon_station/Initialize()
	var/datum/babylon_save/session = GLOB.babylon_save
	session.owner_ckey = GLOB.babylon_world.owner_ckey
	if(!session.owner_ckey)
		session.boot_error = "Set babylon-owner=<BYOND ckey> in world parameters. A world owner is required."
		return SS_INIT_FAILURE
	babylon_apply_world_name()
	if(!session.read_afk_timeout())
		return SS_INIT_FAILURE
	session.read_autosave_interval()
	// Babylon owns this policy, including ghosts and administrators.
	CONFIG_SET(flag/kick_inactive, FALSE)
	session.station_z = SSmapping.levels_by_trait(ZTRAIT_STATION)[1]
	// Before the world reports ready: an admitted visitor or spectator appears here at once.
	session.respawn_turf = session.station_spawn_turf()
	// Hold the round for its owner, or start it at once (tutorials, resumed rounds).
	session.setup_round_control()
	// No vote: the round starts with the world's fixed storyteller (storyteller.dm).
	SSgamemode.voted_storyteller = babylon_world_storyteller()
	try
		session.restore_station()
	catch(var/exception/error)
		session.boot_error = "Restore failed: [error]"
		return SS_INIT_FAILURE
	// Restored (or fresh): the master controller may start the simulation.
	session.prepared = TRUE
	INVOKE_ASYNC(session, TYPE_PROC_REF(/datum/babylon_save, station_boot))
	return SS_INIT_SUCCESS

/datum/babylon_save/proc/station_boot()
	while(!babylon_world_ready())
		if(boot_error)
			return
		sleep(1 SECONDS)
	ready = TRUE
	next_autosave_at = world.time + 15 MINUTES
	// One runtime error must not end this loop for the rest of the run.
	while(TRUE)
		try
			tick_world()
		catch(var/exception/error)
			babylon_loop_failed("world tick", error)
		sleep(1 SECONDS)

/// Where visitors and spectating admins appear: the observer start, else a late-join spawn.
/datum/babylon_save/proc/station_spawn_turf()
	var/obj/effect/landmark/observer_start/start = locate() in GLOB.landmarks_list
	if(start)
		return get_turf(start)
	if(length(SSjob.latejoin_trackers))
		return get_turf(pick(SSjob.latejoin_trackers))
	return locate(round(world.maxx / 2), round(world.maxy / 2), station_z)

/datum/babylon_save/tick_players()
	if(draining)
		return
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
				ensure_station_player(student.ckey)
			if(!busy)
				student.babylon_check_afk(afk_timeout)
			student.babylon_update_music()
			student.babylon_update_save_verbs()
		catch(var/exception/error)
			babylon_loop_failed("player [student?.ckey]", error)
	schedule_autosave()

/// A player's record in this world (their play time); the character itself is tg's.
/datum/babylon_save/proc/ensure_station_player(player_key)
	player_key = ckey(player_key)
	if(!player_key)
		return null
	var/datum/babylon_player/player = player_sessions[player_key]
	if(!player)
		player = new(player_key)
		player_sessions[player_key] = player
	return player

/client
	/// The owner's Save world verbs are currently given to this client.
	var/babylon_save_verbs_shown = FALSE

/// The world's owner gets Save world and Save and stop world while the world is saved
/// (babylon_world_saves()); everyone else, and worlds without saving, never see them.
/client/proc/babylon_update_save_verbs()
	var/show = babylon_world_saves() && ckey == GLOB.babylon_world.owner_ckey && !babylon_showcase_visitor && !babylon_admin_spectator
	if(show == babylon_save_verbs_shown)
		return
	babylon_save_verbs_shown = show
	var/list/save_verbs = list(/client/proc/babylon_save_world_verb, /client/proc/babylon_save_stop_world_verb)
	if(show)
		add_verb(src, save_verbs)
	else
		remove_verb(src, save_verbs)

/client/proc/babylon_save_world_verb()
	set name = "Save world"
	set category = "Babylon"
	if(ckey != GLOB.babylon_world.owner_ckey)
		return
	GLOB.babylon_save.request_manual_save(src)

/datum/babylon_save
	/// world.time from which the owner may save by hand again.
	var/next_manual_save_at = 0

/// The owner's Save world: at most once every 5 minutes, as a save pauses everyone's game.
/// Returns the save's result, or list("error") when refused.
/datum/babylon_save/proc/request_manual_save(client/requester)
	if(world.time < next_manual_save_at)
		var/wait = round((next_manual_save_at - world.time) / (1 MINUTES), 1) || 1
		var/refusal = "You can save again in about [wait] minute\s. Each save pauses the world for about [estimated_pause_seconds()] seconds."
		to_chat(requester, span_warning(refusal))
		return list("error" = refusal)
	to_chat(requester, span_notice("Saving the world pauses it for everyone for about [estimated_pause_seconds()] seconds."))
	var/list/result = save_world()
	if(result["ok"])
		next_manual_save_at = world.time + 5 MINUTES
	else
		to_chat(requester, span_warning(result["error"]))
	return result

/client/proc/babylon_save_stop_world_verb()
	set name = "Save and stop world"
	set category = "Babylon"
	if(ckey != GLOB.babylon_world.owner_ckey)
		return
	var/list/result = GLOB.babylon_save.managed_stop()
	if(result["error"])
		to_chat(src, span_warning(result["error"]))
