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

/datum/babylon_save/proc/managed_stop()
	if(draining)
		return list("error" = "Already stopping")
	draining = TRUE
	var/list/result
	if(babylon_is_station_build())
		// Station worlds cannot save yet (multi-z persistence comes later): stop without one.
		to_chat(world, span_notice("This world is stopping. Returning players to the lobby."))
		result = list("ok" = TRUE, "saved" = FALSE)
	else
		to_chat(world, span_notice("This world is stopping. Saving progress and returning players to the lobby."))
		// save_world keeps both physics and player controls paused until process exit.
		result = save_world()
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
