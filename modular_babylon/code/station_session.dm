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

/// Restores the world's station checkpoint (data/babylon/resume-state.json, staged by the
/// supervisor) before the simulation starts. A no-op until station saves exist (Task D1).
/datum/babylon_save/proc/restore_station()
	return

/// Station checkpoints: a z<N>.dmm per level, records and turfs with their z.
/datum/babylon_save/save_format_version()
	return BABYLON_STATION_STATE_VERSION

/// The station's levels. Task D1 adds mining, space and ruin levels and leaves out CentCom,
/// transit and reserved levels; station saves stay refused until then (save_world()).
/datum/babylon_save/persisted_levels()
	return SSmapping.levels_by_trait(ZTRAIT_STATION).Copy()

/datum/babylon_save/proc/station_boot()
	while(!babylon_world_ready())
		if(boot_error)
			return
		sleep(1 SECONDS)
	ready = TRUE
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

/datum/babylon_save/tick_world()
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
		catch(var/exception/error)
			babylon_loop_failed("player [student?.ckey]", error)

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
