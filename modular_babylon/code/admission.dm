// Trusted server-to-server API. Player input never supplies the actor or credential.
/proc/babylon_supervisor_request(list/query)
	var/api = world.params["babylon-api"]
	if(!api || !findtext(api, "http://127.0.0.1:"))
		return null
	query["run"] = world.params["babylon-run"]
	query["secret"] = world.params["babylon-secret"]
	var/list/response = world.Export("[api]/api?[list2params(query)]")
	if(!response || !response["CONTENT"])
		return null
	try
		return json_decode(file2text(response["CONTENT"]))
	catch
		return null

/client/proc/babylon_admit(topic_data)
	if(!world.params["babylon-world"])
		return ckey == ckey(world.params["babylon-owner"])
	if(!babylon_world_ready() || GLOB.babylon_save.draining || !ckey || findtext(ckey, "guest") == 1)
		return FALSE
	var/list/params = params2list(topic_data)
	var/ticket = params["babylon_ticket"]
	if(!istext(ticket) || length(ticket) > 128)
		return FALSE
	var/list/result = babylon_supervisor_request(list("action" = "redeem", "ticket" = ticket, "actor" = ckey))
	if(!result?["ok"] || result["world"] != world.params["babylon-world"] || result["run"] != world.params["babylon-run"] || !(result["mode"] in list("player", "showcase", "spectator")))
		return FALSE
	// The redemption blocks; the world may have begun stopping (a round's end) meanwhile. Refused,
	// the client is sent to the lobby (client_procs.dm) instead of being dropped by the exit.
	if(GLOB.babylon_save.draining || GLOB.babylon_save.round_ending)
		return FALSE
	// Only the authenticated supervisor response can grant a play mode.
	babylon_showcase_visitor = result["mode"] == "showcase"
	babylon_admin_spectator = result["mode"] == "spectator" && result["role"] == "admin"
	babylon_world_role = result["role"]
	if(result["role"] == "admin")
		babylon_grant_admin(ckey)
	if(babylon_showcase_visitor)
		babylon_restrict_visitor_verbs()
	return TRUE

/client/verb/babylon_return_lobby()
	set name = "Return to Babylon lobby"
	set category = "Babylon"
	if(world.params["babylon-lobby"])
		src << link(world.params["babylon-lobby"])

/// Whether station worlds can save and resume their round: the multi-z save engine
/// (persistence_levels.dm). The stop and round-end messages depend on it.
/proc/babylon_station_saving_available()
	return TRUE

/// Whether a managed stop saves first: only worlds that are saved (persistent, not tutorials).
/proc/babylon_stop_saves()
	if(!babylon_world_saves())
		return FALSE
	return !babylon_is_station_build() || babylon_station_saving_available()

/// The chat line players see when the world stops; says truthfully whether it is saved.
/proc/babylon_stop_message(saves)
	if(saves)
		return "This world is stopping. Saving progress and returning players to the lobby."
	if(GLOB.babylon_world?.is_tutorial())
		return "This tutorial is stopping; tutorial worlds are not saved. Returning you to the lobby."
	return "This world is stopping without a save (saving is off for this world). Returning you to the lobby."

/datum/babylon_save
	/// A managed stop is waiting for a save in progress to finish.
	var/stop_pending = FALSE

/datum/babylon_save/proc/managed_stop()
	if(draining)
		// A world whose round ended is already on its way out, without a save.
		if(round_ending)
			return list("ok" = TRUE, "saved" = FALSE)
		return list("error" = "Already stopping")
	if(stop_pending)
		// The first stop saves and stops the world once the running save is done: nothing failed.
		return list("ok" = TRUE, "pending" = TRUE)
	// An autosave in progress finishes first (it releases the world as usual); then the final save.
	stop_pending = TRUE
	var/idle = await_save_idle(120 SECONDS)
	stop_pending = FALSE
	if(!idle)
		return list("error" = "A save is still running; try stopping again in a moment")
	draining = TRUE
	var/list/result
	var/saves = babylon_stop_saves()
	if(saves && (!ready || boot_error))
		// It never finished starting (or failed to): there is nothing new to save, and refusing
		// would leave the world stuck in an error state.
		saves = FALSE
		to_chat(world, span_notice("This world is stopping before it finished starting; nothing is saved. Returning you to the lobby."))
	else
		to_chat(world, span_notice(babylon_stop_message(saves)))
	if(saves)
		// save_world keeps both physics and player controls paused until process exit.
		result = save_world()
	else
		// Worlds that are not saved stop at once and report success: the supervisor would
		// otherwise keep them in an error state and never clean them up.
		result = list("ok" = TRUE, "saved" = FALSE)
	if(!result["ok"])
		draining = FALSE
		return result
	for(var/client/player in GLOB.clients.Copy())
		if(world.params["babylon-lobby"])
			player << link(world.params["babylon-lobby"])
	// The master (including its timer subsystem) is paused after the snapshot.
	// BYOND spawn still runs, so exit cannot depend on a subsystem timer here.
	spawn(3 SECONDS)
		stop_world()
	return result
