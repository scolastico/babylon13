// Trusted server-to-server API. Player input never supplies the actor or credential.
/// Blocks until the supervisor answers (world.Export has no timeout): only
/// /datum/babylon_supervisor_call calls it. Everything else uses
/// babylon_supervisor_request_within() (test_contracts.py checks this).
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

/// One supervisor request run in the background (babylon_supervisor_request_within()).
/datum/babylon_supervisor_call
	var/list/query
	/// Called with the answer (or null) once world.Export returns, however late.
	var/datum/callback/on_answer
	var/done = FALSE
	var/list/answer

/datum/babylon_supervisor_call/New(list/query, datum/callback/on_answer)
	src.query = query
	src.on_answer = on_answer

/datum/babylon_supervisor_call/proc/perform()
	finish(babylon_supervisor_request(query))

/datum/babylon_supervisor_call/proc/finish(list/result)
	answer = result
	done = TRUE
	on_answer?.Invoke(answer)

/// babylon_supervisor_request(), but waits at most `timeout` deciseconds. world.Export has no
/// timeout of its own: the request goes on in the background, and on_answer is called with its
/// answer whenever it arrives. Returns the answer, or list("ok" = FALSE, "error" = ..., "timeout" = TRUE).
/// Sleeps: call it from a background proc (INVOKE_ASYNC), never from a ui_act. call_type: tests
/// put in a call that answers late.
/proc/babylon_supervisor_request_within(list/query, timeout = BABYLON_SUPERVISOR_TIMEOUT, datum/callback/on_answer, call_type = /datum/babylon_supervisor_call)
	var/datum/babylon_supervisor_call/request = new call_type(query, on_answer)
	INVOKE_ASYNC(request, TYPE_PROC_REF(/datum/babylon_supervisor_call, perform))
	var/deadline = world.time + timeout
	while(!request.done && world.time < deadline)
		sleep(1)
	if(!request.done)
		return list("ok" = FALSE, "error" = "The server did not answer in time", "timeout" = TRUE)
	return request.answer || list("ok" = FALSE, "error" = "The server could not be reached")

/client
	/// Why babylon_admit() refused this client, for the lobby to tell them (a code it knows), else null.
	var/babylon_admit_notice

/// The lobby address a refused client is sent back to, with the refusal's notice if there is one.
/client/proc/babylon_lobby_link(reason = null)
	var/lobby = babylon_server_link(world.params["babylon-lobby"])
	if(!lobby)
		return null
	var/list/query = list("babylon_from_world" = world.params["babylon-world"], "babylon_from_name" = world.params["babylon-name"] || world.name,
		"babylon_leave_reason" = reason || babylon_session_leave_reason || "unknown")
	if(babylon_admit_notice)
		query["babylon_notice"] = babylon_admit_notice
	return "[lobby][findtext(lobby, "?") ? "&" : "?"][list2params(query)]"

/// Every refusal records its actual reason without exposing the admission credential.
/client/proc/babylon_refuse_admission(reason)
	babylon_session_leave_reason = reason
	babylon_log_session("refused", reason)
	return FALSE

/client/proc/babylon_admit(topic_data)
	babylon_session_connected = TRUE
	babylon_log_session("connect")
	if(!world.params["babylon-world"])
		return ckey == ckey(world.params["babylon-owner"]) || babylon_refuse_admission("Only the local world owner may connect")
	if(!babylon_world_ready())
		return babylon_refuse_admission("World is still loading")
	if(GLOB.babylon_save.draining)
		return babylon_refuse_admission("World is stopping")
	if(!ckey || findtext(ckey, "guest") == 1)
		return babylon_refuse_admission("A BYOND account is required")
	var/list/params = params2list(topic_data)
	var/ticket = params["babylon_ticket"]
	if(!istext(ticket) || length(ticket) > 128)
		return babylon_refuse_admission("Missing or invalid admission ticket")
	// The supervisor refuses a redeem it only reaches after this wait, without spending the ticket
	// (wait_seconds). Either way the player goes back to the lobby, which says why.
	var/list/result = babylon_supervisor_request_within(list("action" = "redeem", "ticket" = ticket, "actor" = ckey, "wait_seconds" = BABYLON_SUPERVISOR_TIMEOUT / (1 SECONDS)))
	if(result["timeout"] || result["code"] == "admission_timeout")
		babylon_admit_notice = "admission_timeout"

	if(!result?["ok"])
		return babylon_refuse_admission(result?["error"] || "Admission failed")
	if(result["world"] != world.params["babylon-world"] || result["run"] != world.params["babylon-run"] || !(result["mode"] in list("player", "showcase", "spectator")))
		return babylon_refuse_admission("Admission identity or mode mismatch")
	// The redemption blocks; the world may have begun stopping (a round's end) meanwhile. Refused,
	// the client is sent to the lobby (client_procs.dm) instead of being dropped by the exit.
	if(GLOB.babylon_save.draining || GLOB.babylon_save.round_ending)
		return babylon_refuse_admission("World stopped during admission")
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
	set category = "World Controls"
	var/lobby = babylon_lobby_link("quit")
	if(lobby)
		babylon_set_leave_reason("quit")
		src << link(lobby)

/// The chat line players see when the world stops; says truthfully whether it is saved.
/proc/babylon_stop_message(saves)
	if(saves)
		return "This world is stopping. Saving progress and returning players to the lobby."
	if(GLOB.babylon_world?.unsaved_as_tutorial())
		return "This tutorial is stopping; tutorial worlds are not saved. Returning you to the lobby."
	return "This world is stopping without a save (saving is off for this world). Returning you to the lobby."

/datum/babylon_save
	/// A managed stop is under way (waiting for a save in progress, or saving).
	var/stop_pending = FALSE
	/// What the last managed stop answered (a second stop meanwhile returns it too).
	var/list/last_stop_result

/datum/babylon_save/proc/managed_stop()
	if(stop_pending)
		// Another stop is under way: this one answers with its outcome, never a bare "pending"
		// (the supervisor would otherwise keep the run stopping for good if that stop fails).
		var/waited = 0
		while(stop_pending && waited < 10 MINUTES)
			sleep(1 SECONDS)
			waited += 1 SECONDS
		return last_stop_result || list("error" = "The stop did not finish")
	if(draining)
		// A world whose round ended is already on its way out, without a save.
		if(round_ending)
			return list("ok" = TRUE, "saved" = FALSE)
		return last_stop_result || list("error" = "Already stopping")
	// An autosave in progress finishes first (it releases the world as usual); then the final save.
	stop_pending = TRUE
	last_stop_result = null
	// A runtime must not leave the stop pending: every later stop would wait for it in vain.
	try
		. = managed_stop_now()
	catch(var/exception/error)
		log_world("Babylon managed stop failed: [error] ([error?.file]:[error?.line])")
		. = list("error" = "The stop failed: [error]")
	last_stop_result = .
	stop_pending = FALSE

/datum/babylon_save/proc/managed_stop_now()
	// A running save ends its tram wait as soon as this stop is pending (before_checkpoint()), so
	// this covers its capture and writes.
	var/idle = await_save_idle(240 SECONDS)
	if(!idle)
		return list("error" = "A save is still running; try stopping again in a moment")
	draining = TRUE
	var/list/result
	// A runtime before the outcome is known must not leave the world draining (no more saves,
	// players no longer looked after): it counts as a failed stop.
	try
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
	catch(var/exception/error)
		log_world("Babylon managed stop failed: [error] ([error?.file]:[error?.line])")
		result = list("error" = "The stop failed: [error]")
	if(!result["ok"])
		draining = FALSE
		return result
	for(var/client/player in GLOB.clients.Copy())
		player.babylon_set_leave_reason("world_stopped")
		var/lobby = player.babylon_lobby_link("world_stopped")
		if(lobby)
			player << link(lobby)
	// The master (including its timer subsystem) is paused after the snapshot.
	// BYOND spawn still runs, so exit cannot depend on a subsystem timer here.
	spawn(3 SECONDS)
		stop_world()
	return result
