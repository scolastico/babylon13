// Submitting a tutorial for review and saving an edited one back: the Creative panel's Tutorial
// tab (tgui BabylonCreative, TutorialTab). Shared by both builds; only the world-type policy
// (world_flags.dm can_submit_tutorial(), can_save_back_tutorial()) decides where it works.
//
// Submit (the owner of a tutorial-capable ordinary world): the supervisor's cooldown is asked
// (tutorial_submit_check), the world writes a tutorial snapshot (save_world(for_tutorial =
// TRUE): forced even in a non-persistent world, no characters, never the world's checkpoint) and
// the supervisor copies it into pending/ (tutorial_submit). Save back (an admin in a tutorial
// edit world): the same snapshot replaces the pending tutorial's save (tutorial_save_back). Both
// need the tutorial's "start" marker. The snapshot's generation is deleted once the supervisor
// answered, however late.
//
// The requests run in a background proc with a timeout (world.Export blocks; the copy of a station
// save takes a while): the panel action only starts it and shows "Submitting...". One snapshot
// runs at a time per world; a second click meanwhile does nothing.

/// Longest title and description (characters), as the supervisor allows (constants.py
/// TUTORIAL_TITLE_MAX / TUTORIAL_DESCRIPTION_MAX; test_contracts.py checks they match).
#define BABYLON_TUTORIAL_TITLE_MAX 60
#define BABYLON_TUTORIAL_DESCRIPTION_MAX 500
/// The cooldown is asked again at most this often per panel (and after every submission).
#define BABYLON_TUTORIAL_CHECK_INTERVAL (1 MINUTES)

GLOBAL_DATUM_INIT(babylon_tutorial_submissions, /datum/babylon_tutorial_submissions, new)

/// The world's tutorial submissions and save backs (one at a time).
/datum/babylon_tutorial_submissions
	/// The ckey whose submission or save back runs now, else null.
	var/busy_ckey
	/// How long the world waits for the cooldown check, and for the supervisor's copy of a snapshot.
	var/check_timeout = 30 SECONDS
	var/copy_timeout = 3 MINUTES
	/// The supervisor's cooldown between submissions (hours), as its last check said.
	var/cooldown_hours = 6
	/// The request type (tests use one that answers late).
	var/call_type = /datum/babylon_supervisor_call

/// Asks the supervisor (tests replace this to answer themselves).
/datum/babylon_tutorial_submissions/proc/request(list/query, timeout, datum/callback/on_answer)
	return babylon_supervisor_request_within(query, timeout, on_answer, call_type)

/// Reserves the world's one snapshot slot for ckey. FALSE while another runs.
/datum/babylon_tutorial_submissions/proc/begin(ckey)
	if(busy_ckey)
		return FALSE
	busy_ckey = ckey
	return TRUE

/// The supervisor's cooldown for ckey: list("ok", "wait_seconds") or list("ok" = FALSE, "error").
/datum/babylon_tutorial_submissions/proc/check(ckey)
	var/list/answer = request(list("action" = "tutorial_submit_check", "actor" = ckey), check_timeout)
	if(!answer?["ok"])
		return list("ok" = FALSE, "error" = answer?["error"] || "The server could not be reached")
	if(isnum(answer["cooldown_hours"]))
		cooldown_hours = max(0, answer["cooldown_hours"])
	return list("ok" = TRUE, "wait_seconds" = max(0, round(text2num("[answer["wait_seconds"]]") || 0)))

/// Submits the world as a tutorial (after begin()). list("ok", "text") for the panel.
/datum/babylon_tutorial_submissions/proc/submit(ckey, title, description)
	var/list/result
	try
		result = submit_steps(ckey, title, description)
	catch(var/exception/error)
		result = list("ok" = FALSE, "text" = "Submitting failed: [error]")
		log_world("BABYLON TUTORIAL: submitting failed: [error]")
	busy_ckey = null
	return result

/datum/babylon_tutorial_submissions/proc/submit_steps(ckey, title, description)
	var/refusal = babylon_tutorial_submit_refusal(ckey, TRUE)
	if(refusal)
		return list("ok" = FALSE, "text" = babylon_tutorial_refusal_text(refusal))
	var/list/cooldown = check(ckey)
	if(!cooldown["ok"])
		return list("ok" = FALSE, "text" = "Not submitted: [cooldown["error"]].")
	if(cooldown["wait_seconds"])
		return list("ok" = FALSE, "text" = "Not submitted: you can submit another tutorial in [babylon_tutorial_wait_text(cooldown["wait_seconds"])].", "wait_seconds" = cooldown["wait_seconds"])
	// Again right before the save: the check above takes a moment (the marker may be gone, the
	// world stopping).
	refusal = babylon_tutorial_submit_refusal(ckey, TRUE)
	if(refusal)
		return list("ok" = FALSE, "text" = babylon_tutorial_refusal_text(refusal))
	var/list/snapshot = take_snapshot()
	if(!snapshot["ok"])
		return list("ok" = FALSE, "text" = "Not submitted: the world could not be saved ([snapshot["error"]]).")
	var/generation = snapshot["generation"]
	var/list/answer = request(list("action" = "tutorial_submit", "actor" = ckey, "title" = title, "description" = description, "generation" = generation), copy_timeout, CALLBACK(src, PROC_REF(submission_answered), generation, ckey))
	if(answer?["ok"])
		log_game("BABYLON TUTORIAL: [ckey] submitted \"[title]\" as tutorial [answer["tutorial"]] (snapshot [generation]).")
		return list("ok" = TRUE, "text" = "Submitted \"[title]\". The moderators review it before it is published.", "tutorial" = answer["tutorial"], "generation" = generation)
	if(answer?["timeout"])
		return list("ok" = FALSE, "text" = "The server did not confirm the submission in time. It may still go through. If it did, your cooldown has started: the Cooldown line here shows it in a moment.")
	return list("ok" = FALSE, "text" = "Not submitted: [answer?["error"] || "the server could not be reached"].")

/// Saves the edit world back to its pending tutorial (after begin()). list("ok", "text").
/datum/babylon_tutorial_submissions/proc/save_back(ckey, is_admin)
	var/list/result
	try
		result = save_back_steps(ckey, is_admin)
	catch(var/exception/error)
		result = list("ok" = FALSE, "text" = "Saving back failed: [error]")
		log_world("BABYLON TUTORIAL: saving back failed: [error]")
	busy_ckey = null
	return result

/datum/babylon_tutorial_submissions/proc/save_back_steps(ckey, is_admin)
	var/refusal = babylon_tutorial_save_back_refusal(is_admin, TRUE)
	if(refusal)
		return list("ok" = FALSE, "text" = babylon_tutorial_refusal_text(refusal))
	var/list/snapshot = take_snapshot()
	if(!snapshot["ok"])
		return list("ok" = FALSE, "text" = "Not saved back: the world could not be saved ([snapshot["error"]]).")
	var/generation = snapshot["generation"]
	var/list/answer = request(list("action" = "tutorial_save_back", "actor" = ckey, "generation" = generation), copy_timeout, CALLBACK(src, PROC_REF(discard_snapshot), generation))
	if(answer?["ok"])
		log_game("BABYLON TUTORIAL: [ckey] saved tutorial [GLOB.babylon_world.tutorial_id] back (snapshot [generation]).")
		return list("ok" = TRUE, "text" = "Saved back: the pending tutorial now starts from this state.")
	if(answer?["timeout"])
		return list("ok" = FALSE, "text" = "The server did not confirm the save back in time. It may still complete: play the pending tutorial from the lobby to check before you save back again.")
	return list("ok" = FALSE, "text" = "Not saved back: [answer?["error"] || "the server could not be reached"].")

/// Writes the tutorial snapshot: list("ok", "generation") or list("error").
/datum/babylon_tutorial_submissions/proc/take_snapshot()
	var/list/result = GLOB.babylon_save.save_world(force = TRUE, for_tutorial = TRUE)
	if(!result?["ok"])
		return list("ok" = FALSE, "error" = result?["error"] || "unknown error")
	return result

/// The supervisor answered a submission (in time or late): the snapshot goes, and the owner's
/// panel asks for the cooldown again (it started if the submission went through).
/datum/babylon_tutorial_submissions/proc/submission_answered(generation, ckey)
	discard_snapshot(generation)
	var/datum/babylon_creative_panel/panel = GLOB.babylon_creative_panels[ckey]
	panel?.refresh_tutorial_cooldown(TRUE)

/// Deletes a tutorial snapshot once the supervisor answered (it has its own copy, or none). The
/// supervisor deletes it too; one left behind is marked and never a checkpoint (persistence.dm).
/datum/babylon_tutorial_submissions/proc/discard_snapshot(generation)
	var/static/regex/valid = regex(@"^save-\d{8}-\d{6}-\d+$")
	if(!istext(generation) || !valid.Find(generation))
		return
	fdel("data/babylon/saves/[generation]/")

/// Why ckey may not submit now (a code for babylon_tutorial_refusal_text()), or null. The cooldown
/// is the supervisor's. running: the caller holds the snapshot slot itself.
/proc/babylon_tutorial_submit_refusal(ckey, running = FALSE)
	if(!GLOB.babylon_world?.can_submit_tutorial())
		return "not_capable"
	if(!ckey || ckey != GLOB.babylon_world.owner_ckey)
		return "not_owner"
	. = babylon_tutorial_snapshot_refusal()
	if(.)
		return
	if(!running && GLOB.babylon_tutorial_submissions.busy_ckey)
		return "busy"
	return null

/// Why this player may not save back now (a code), or null.
/proc/babylon_tutorial_save_back_refusal(is_admin, running = FALSE)
	if(!GLOB.babylon_world?.can_save_back_tutorial())
		return "not_edit_world"
	if(!is_admin)
		return "not_admin"
	. = babylon_tutorial_snapshot_refusal()
	if(.)
		return
	if(!running && GLOB.babylon_tutorial_submissions.busy_ckey)
		return "busy"
	return null

/// Why no tutorial snapshot can be taken now, whoever asks: the world is stopping, or the start
/// marker is missing or on a level that is not saved (CentCom, reserved levels).
/proc/babylon_tutorial_snapshot_refusal()
	var/datum/babylon_save/session = GLOB.babylon_save
	if(session?.draining || session?.round_ending)
		return "stopping"
	var/turf/start = babylon_tutorial_marker_turf("start")
	if(!start)
		return "no_start"
	if(!(start.z in session?.persisted_levels()))
		return "start_unsaved"
	return null

/proc/babylon_tutorial_refusal_text(code, wait_seconds)
	switch(code)
		if("not_capable")
			return "Tutorials can only be submitted from a Creative world on a station map (a Creative Plane or a station). Babylon worlds can build, but not submit."
		if("not_owner")
			return "Only the world's owner can submit it as a tutorial."
		if("no_start")
			return "Needs a start marker: place a marker with the id \"start\" (tutorial wand) where players begin."
		if("stopping")
			return "This world is stopping; try again once it has started again."
		if("start_unsaved")
			return "The start marker is on a level that is not saved: move it onto the station or the map's own levels."
		if("busy")
			return "A tutorial save is already running in this world. Wait for it to finish."
		if("cooldown")
			return "Cooldown: you can submit another tutorial in [babylon_tutorial_wait_text(wait_seconds)]."
		if("not_edit_world")
			return "Saving back only works in a world that edits a pending tutorial."
		if("not_admin")
			return "Only server administrators can save back to a pending tutorial."
	return "That is not possible right now."

/// "4 min", "1 h 5 min", "30 s".
/proc/babylon_tutorial_wait_text(seconds)
	seconds = max(0, round(seconds))
	if(seconds < 60)
		return "[seconds] s"
	var/minutes = CEILING(seconds / 60, 1)
	if(minutes < 60)
		return "[minutes] min"
	return "[round(minutes / 60)] h[minutes % 60 ? " [minutes % 60] min" : ""]"

/// Player text for a tutorial: one line unless multiline, no tabs, trimmed. (The supervisor drops
/// any other control character; its limits are the ones that count.)
/proc/babylon_tutorial_clean_text(value, multiline = FALSE)
	var/static/regex/line_breaks = regex(@"\r\n?", "g")
	var/static/regex/all_breaks = regex(@"[\n\t]", "g")
	var/text = line_breaks.Replace("[value]", "\n")
	if(multiline)
		text = replacetext(text, "\t", " ")
	else
		text = all_breaks.Replace(text, " ")
	return trim(text)

// The Creative panel's Tutorial tab.

/datum/babylon_creative_panel
	/// "submitting" or "saving_back" while this player's request runs, else null.
	var/tutorial_running
	/// The last submission's or save back's outcome: list("ok", "text"), else null.
	var/list/tutorial_outcome
	/// world.time the supervisor's cooldown for the owner ends (from tutorial_submit_check), or null.
	var/tutorial_wait_until
	/// world.time of the last cooldown check (-INFINITY: never), and whether one runs now.
	var/tutorial_checked_at = -INFINITY
	var/tutorial_checking = FALSE
	/// Why the last cooldown check failed, else null.
	var/tutorial_check_error

/datum/babylon_creative_panel/tabs(mob/user)
	. = ..()
	. += list(list("id" = "tutorial", "name" = "Tutorial", "icon" = "graduation-cap"))

/datum/babylon_creative_panel/extension_data(mob/user)
	. = ..()
	.["tutorial"] = tutorial_data(user)

/// The Tutorial tab's data: which form it shows, why its button is disabled, the cooldown and the
/// last outcome.
/datum/babylon_creative_panel/proc/tutorial_data(mob/user)
	var/save_back = !!GLOB.babylon_world?.can_save_back_tutorial()
	var/wait = tutorial_wait_seconds()
	var/blocked
	if(save_back)
		blocked = babylon_tutorial_save_back_refusal(babylon_tutorial_is_admin(user))
	else
		blocked = babylon_tutorial_submit_refusal(user?.ckey)
		if(!blocked && wait)
			blocked = "cooldown"
	if(GLOB.babylon_tutorial_submissions.busy_ckey == ckey && tutorial_running)
		blocked = null
	return list(
		"mode" = save_back ? "save_back" : "submit",
		"blocked" = blocked,
		"blocked_text" = blocked ? babylon_tutorial_refusal_text(blocked, wait) : null,
		"wait_seconds" = wait,
		"checking" = tutorial_checking,
		"check_error" = tutorial_check_error,
		"state" = tutorial_running || (tutorial_outcome ? (tutorial_outcome["ok"] ? "done" : "error") : "idle"),
		"message" = tutorial_outcome?["text"],
		"title" = GLOB.babylon_world?.tutorial_title,
		"cooldown_hours" = GLOB.babylon_tutorial_submissions.cooldown_hours,
		"pause_seconds" = GLOB.babylon_save?.estimated_pause_seconds() || 0,
		"title_max" = BABYLON_TUTORIAL_TITLE_MAX,
		"description_max" = BABYLON_TUTORIAL_DESCRIPTION_MAX,
	)

/// Seconds left of the owner's cooldown as last checked (0: none or unknown).
/datum/babylon_creative_panel/proc/tutorial_wait_seconds()
	if(isnull(tutorial_wait_until) || tutorial_wait_until <= world.time)
		return 0
	return CEILING((tutorial_wait_until - world.time) / (1 SECONDS), 1)

/proc/babylon_tutorial_is_admin(mob/user)
	return user?.client?.babylon_world_role == "admin"

/datum/babylon_creative_panel/extension_action(mob/living/user, action, list/params)
	switch(action)
		if("tutorial_refresh")
			return refresh_tutorial_cooldown()
		if("tutorial_submit")
			if(tutorial_running)
				return FALSE
			var/title = babylon_tutorial_clean_text(params["title"])
			var/description = babylon_tutorial_clean_text(params["description"], TRUE)
			var/refusal = babylon_tutorial_submit_refusal(user.ckey)
			if(!refusal && tutorial_wait_seconds())
				refusal = "cooldown"
			if(refusal)
				return report(babylon_tutorial_refusal_text(refusal, tutorial_wait_seconds()), FALSE)
			if(!length_char(title) || length_char(title) > BABYLON_TUTORIAL_TITLE_MAX || length_char(description) > BABYLON_TUTORIAL_DESCRIPTION_MAX)
				return report("Use a title of 1-[BABYLON_TUTORIAL_TITLE_MAX] characters and a description up to [BABYLON_TUTORIAL_DESCRIPTION_MAX] characters.", FALSE)
			if(!GLOB.babylon_tutorial_submissions.begin(user.ckey))
				return report(babylon_tutorial_refusal_text("busy"), FALSE)
			tutorial_running = "submitting"
			tutorial_outcome = null
			babylon_creative_log(user, "submits this world as the tutorial \"[babylon_creative_clean(title)]\".")
			INVOKE_ASYNC(src, PROC_REF(run_tutorial_submit), user.ckey, title, description)
			return TRUE
		if("tutorial_save_back")
			if(tutorial_running)
				return FALSE
			var/is_admin = babylon_tutorial_is_admin(user)
			var/refusal = babylon_tutorial_save_back_refusal(is_admin)
			if(refusal)
				return report(babylon_tutorial_refusal_text(refusal), FALSE)
			if(!GLOB.babylon_tutorial_submissions.begin(user.ckey))
				return report(babylon_tutorial_refusal_text("busy"), FALSE)
			tutorial_running = "saving_back"
			tutorial_outcome = null
			babylon_creative_log(user, "saves this world back to the pending tutorial [GLOB.babylon_world.tutorial_id].")
			INVOKE_ASYNC(src, PROC_REF(run_tutorial_save_back), user.ckey, is_admin)
			return TRUE
		if("tutorial_dismiss")
			tutorial_outcome = null
			return TRUE
	return ..()

/// Asks the supervisor for the owner's cooldown in the background (at most once a minute).
/datum/babylon_creative_panel/proc/refresh_tutorial_cooldown(force = FALSE)
	if(tutorial_checking || (babylon_tutorial_submit_refusal(ckey) in list("not_capable", "not_owner")))
		return FALSE
	if(!force && world.time < tutorial_checked_at + BABYLON_TUTORIAL_CHECK_INTERVAL)
		return FALSE
	tutorial_checking = TRUE
	tutorial_checked_at = world.time
	INVOKE_ASYNC(src, PROC_REF(run_tutorial_check))
	return TRUE

/datum/babylon_creative_panel/proc/run_tutorial_check()
	var/list/answer = GLOB.babylon_tutorial_submissions.check(ckey)
	if(QDELETED(src))
		return
	tutorial_checking = FALSE
	tutorial_check_error = answer["ok"] ? null : answer["error"]
	if(answer["ok"])
		tutorial_wait_until = answer["wait_seconds"] ? world.time + answer["wait_seconds"] * (1 SECONDS) : null
	SStgui.update_uis(src)

/datum/babylon_creative_panel/proc/run_tutorial_submit(submitter, title, description)
	var/list/result = GLOB.babylon_tutorial_submissions.submit(submitter, title, description)
	if(QDELETED(src))
		return
	tutorial_running = null
	tutorial_outcome = result
	if(result["wait_seconds"])
		tutorial_wait_until = world.time + result["wait_seconds"] * (1 SECONDS)
	if(result["ok"])
		// The cooldown starts now: ask for it at once.
		refresh_tutorial_cooldown(TRUE)
	babylon_tutorial_tell(submitter, result)
	SStgui.update_uis(src)

/datum/babylon_creative_panel/proc/run_tutorial_save_back(submitter, is_admin)
	var/list/result = GLOB.babylon_tutorial_submissions.save_back(submitter, is_admin)
	if(QDELETED(src))
		return
	tutorial_running = null
	tutorial_outcome = result
	babylon_tutorial_tell(submitter, result)
	SStgui.update_uis(src)

/// The outcome in the player's chat too (the panel may be closed by now).
/proc/babylon_tutorial_tell(ckey, list/result)
	var/client/player = GLOB.directory[ckey]
	if(player)
		to_chat(player, result["ok"] ? span_notice(html_encode(result["text"])) : span_warning(html_encode(result["text"])))

#undef BABYLON_TUTORIAL_CHECK_INTERVAL
