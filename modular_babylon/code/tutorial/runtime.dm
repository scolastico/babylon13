// Tutorial runtime (spec 7.2): one /datum/babylon_tutorial_run per participating player, stepped
// once a second by SSbabylon_tutorial. A run starts automatically when a player spawns in a
// tutorial world (station_round.dm) and from the wand's Test run in creative worlds.
//
// Everything a run tracks (listening triggers, what fired, pending button presses, the player's
// private images, objective and speech) is per run, so two builders test-running at once never
// fire each other's steps. Stopping a run resets its state only; the world (spawned NPCs, given
// items) stays.

/// Every run that exists, registered or not (preview runs): deleted tutorial objects are purged
/// from all of them.
GLOBAL_LIST_EMPTY(babylon_tutorial_runs)

SUBSYSTEM_DEF(babylon_tutorial)
	name = "Babylon Tutorials"
	wait = 1 SECONDS
	runlevels = RUNLEVEL_LOBBY | RUNLEVELS_DEFAULT
	ss_flags = SS_NO_INIT | SS_KEEP_TIMING
	/// player mob => /datum/babylon_tutorial_run
	var/list/runs = list()
	/// Spawners already handled after the world came up (spawn_at_start NPCs appear once).
	var/started_spawners = FALSE
	/// Runs still to step in this fire (the fire resumes after MC_TICK_CHECK).
	var/list/currentrun = list()
	/// Counts fires: world-state conditions are evaluated once per fire for every run.
	var/fire_count = 0
	/// TRUE while fire() steps the runs.
	var/firing_now = FALSE

/datum/controller/subsystem/babylon_tutorial/fire(resumed)
	if(!resumed)
		fire_count++
		if(!started_spawners && babylon_world_ready())
			started_spawners = TRUE
			babylon_tutorial_spawn_start_npcs()
		refresh_hooks()
		for(var/obj/item/babylon_tutorial_wand/wand as anything in GLOB.babylon_tutorial_wands)
			try
				wand.sync_view()
			catch(var/exception/error)
				babylon_loop_failed("tutorial wand view", error)
		currentrun = runs.Copy()
	firing_now = TRUE
	while(length(currentrun))
		var/mob/player = currentrun[length(currentrun)]
		var/datum/babylon_tutorial_run/run = currentrun[player]
		currentrun.len--
		if(!QDELETED(run))
			try
				run.check_triggers()
			catch(var/exception/error)
				babylon_loop_failed("tutorial run of [player]", error)
		if(MC_TICK_CHECK)
			firing_now = FALSE
			return
	firing_now = FALSE

/// Hooks every used-on trigger to its current target (an NPC can be respawned).
/datum/controller/subsystem/babylon_tutorial/proc/refresh_hooks()
	for(var/obj/babylon_tutorial/trigger/used_on/trigger in GLOB.babylon_tutorial_objects)
		trigger.refresh_hook()

/// The tutorial run a mob takes part in, if any.
/proc/babylon_tutorial_run_of(mob/player)
	RETURN_TYPE(/datum/babylon_tutorial_run)
	return player ? SSbabylon_tutorial.runs[player] : null

/// Starts (or restarts) a tutorial run for a player. from_start: move them to the "start" marker
/// first. test_run: a builder's test (the completion screen offers no lobby button). reset_npcs:
/// spawn-at-start NPCs are created again, fresh (a test restart).
/proc/babylon_tutorial_begin(mob/living/player, from_start = FALSE, test_run = FALSE, reset_npcs = FALSE)
	RETURN_TYPE(/datum/babylon_tutorial_run)
	if(!istype(player) || QDELETED(player))
		return null
	babylon_tutorial_end(player)
	if(from_start)
		var/turf/start = babylon_tutorial_marker_turf("start")
		if(start)
			player.buckled?.unbuckle_mob(player, TRUE)
			player.forceMove(start)
	babylon_tutorial_spawn_start_npcs(reset_npcs)
	var/datum/babylon_tutorial_run/run = new(player, test_run)
	run.reset_npcs = reset_npcs
	SSbabylon_tutorial.runs[player] = run
	SSbabylon_tutorial.refresh_hooks()
	log_game("BABYLON TUTORIAL: [key_name(player)] started a tutorial run[test_run ? " (test)" : ""].")
	return run

/// Stops a player's run, if any.
/proc/babylon_tutorial_end(mob/player)
	var/datum/babylon_tutorial_run/run = babylon_tutorial_run_of(player)
	if(run)
		qdel(run)
		return TRUE
	return FALSE

/// The turf of the marker with this id (players start at "start").
/proc/babylon_tutorial_marker_turf(id)
	var/obj/babylon_tutorial/marker/marker = babylon_tutorial_find(id)
	return istype(marker) ? get_turf(marker) : null

/// NPC spawners set to spawn at the start create their NPC: those without one, or all of them
/// again when reset.
/proc/babylon_tutorial_spawn_start_npcs(reset = FALSE)
	for(var/obj/babylon_tutorial/npc_spawner/spawner in GLOB.babylon_tutorial_objects)
		if(spawner.setting("spawn_at_start") && (reset || !spawner.current_npc()))
			spawner.spawn_npc()

/// The triggers that start listening when this trigger fires ("After <trigger> fired").
/proc/babylon_tutorial_triggers_after(obj/babylon_tutorial/trigger/trigger)
	var/list/found = list()
	for(var/obj/babylon_tutorial/trigger/candidate in GLOB.babylon_tutorial_objects)
		if(candidate.setting("starts") == "after" && candidate.setting("after") == trigger.tutorial_id)
			found += candidate
	return found

/datum/babylon_tutorial_run
	var/mob/living/player
	var/test_run = FALSE
	/// trigger => world.time it started listening (only listening triggers are keys).
	var/list/enabled = list()
	/// trigger => times it fired.
	var/list/fired = list()
	/// trigger => world.time it last fired.
	var/list/last_fired = list()
	/// trigger => whether its condition held at the last check (edge-triggered kinds).
	var/list/last_state = list()
	/// trigger => TRUE: the player's event (a press, a use, a phrase) waits for the next check.
	var/list/hits = list()
	/// "trigger>action" for every action performed, in order (tests and the log).
	var/list/history = list()
	/// Private images shown to the player: image => list(until, anchor weakref, clear_on triggers).
	var/list/images = list()
	/// Speakers pointing again and again: list(speaker weakref, target weakref, until, next, clear_on).
	var/list/pointing = list()
	/// Timers of actions still waiting.
	var/list/timers = list()
	/// The trigger whose actions are being performed (actions use it for "until the next step").
	var/obj/babylon_tutorial/trigger/current_trigger
	var/completed = FALSE
	var/datum/babylon_tutorial_complete/complete_screen
	/// The objective shown on the player's screen, if any.
	var/objective
	/// A throwaway run previewing one action: it never touches the player's objective alert.
	var/preview = FALSE
	/// The run was started with "Reset NPCs" (Run again does the same).
	var/reset_npcs = FALSE

/datum/babylon_tutorial_run/New(mob/living/player, test_run)
	src.player = player
	src.test_run = test_run
	GLOB.babylon_tutorial_runs += src
	RegisterSignal(player, COMSIG_QDELETING, PROC_REF(player_deleted))
	RegisterSignal(player, COMSIG_MOB_SAY, PROC_REF(player_said))
	for(var/obj/babylon_tutorial/trigger/trigger as anything in babylon_tutorial_objects_of("trigger"))
		if(trigger.listens_at_start())
			enabled[trigger] = world.time

/datum/babylon_tutorial_run/Destroy()
	GLOB.babylon_tutorial_runs -= src
	for(var/timer in timers)
		deltimer(timer)
	timers.Cut()
	clear_images()
	pointing.Cut()
	set_objective(null)
	current_trigger = null
	enabled.Cut()
	fired.Cut()
	last_fired.Cut()
	last_state.Cut()
	hits.Cut()
	if(player)
		UnregisterSignal(player, list(COMSIG_QDELETING, COMSIG_MOB_SAY))
		if(SSbabylon_tutorial.runs[player] == src)
			SSbabylon_tutorial.runs -= player
	if(complete_screen)
		SStgui.close_uis(complete_screen)
		QDEL_NULL(complete_screen)
	player = null
	return ..()

/// A tutorial object was deleted: drop every reference to it.
/datum/babylon_tutorial_run/proc/forget(obj/babylon_tutorial/object)
	enabled -= object
	fired -= object
	last_fired -= object
	last_state -= object
	hits -= object
	if(current_trigger == object)
		current_trigger = null
	for(var/image/picture as anything in images)
		var/list/info = images[picture]
		var/list/clear_on = info["clear_on"]
		clear_on -= object
	for(var/list/entry as anything in pointing)
		var/list/clear_on = entry[5]
		clear_on -= object

/datum/babylon_tutorial_run/proc/player_deleted(datum/source)
	SIGNAL_HANDLER
	qdel(src)

/datum/babylon_tutorial_run/proc/player_said(datum/source, list/speech_args)
	SIGNAL_HANDLER
	var/message = speech_args[SPEECH_MESSAGE]
	for(var/obj/babylon_tutorial/trigger/say/trigger in enabled)
		trigger.heard(src, message)

/datum/babylon_tutorial_run/proc/is_enabled(obj/babylon_tutorial/trigger/trigger)
	return !isnull(enabled[trigger])

/// world.time the trigger started listening.
/datum/babylon_tutorial_run/proc/enabled_since(obj/babylon_tutorial/trigger/trigger)
	return enabled[trigger] || world.time

/datum/babylon_tutorial_run/proc/set_enabled(obj/babylon_tutorial/trigger/trigger, enable)
	if(QDELETED(trigger))
		return
	// A trigger that fires only once stays done: loops of steps cannot revive it.
	if(enable && fired[trigger] && trigger.setting("once"))
		return
	if(enable)
		enabled[trigger] = world.time
		// Its condition counts from now: a zone the player already stands in fires.
		last_state -= trigger
	else
		enabled -= trigger
	hits -= trigger

/// The player's event for a listening trigger (a press, a use, a phrase).
/datum/babylon_tutorial_run/proc/hit(obj/babylon_tutorial/trigger/trigger)
	if(is_enabled(trigger) && !completed)
		hits[trigger] = TRUE

/datum/babylon_tutorial_run/proc/take_hit(obj/babylon_tutorial/trigger/trigger)
	if(!hits[trigger])
		return FALSE
	hits -= trigger
	return TRUE

/// One check of every listening trigger.
/datum/babylon_tutorial_run/proc/check_triggers()
	if(QDELETED(player))
		qdel(src)
		return
	expire_images()
	continue_pointing()
	prune_timers()
	if(completed)
		return
	for(var/obj/babylon_tutorial/trigger/trigger as anything in enabled.Copy())
		if(QDELETED(trigger))
			forget(trigger)
			continue
		if(!is_enabled(trigger))
			continue
		var/state = !!trigger.check(src)
		var/was = last_state[trigger]
		last_state[trigger] = state
		if(!state || (trigger.edge_triggered && was))
			continue
		var/cooldown = trigger.setting("cooldown") SECONDS
		if(cooldown && last_fired[trigger] && world.time < last_fired[trigger] + cooldown)
			// Not yet: check again next time, as if the condition had just become true.
			last_state[trigger] = FALSE
			continue
		fire(trigger)
		if(completed)
			return

/// Fires a trigger: what waited for it stops, the next step's triggers start listening and its
/// actions run in order, each after its own delay.
/datum/babylon_tutorial_run/proc/fire(obj/babylon_tutorial/trigger/trigger)
	fired[trigger] = fired[trigger] + 1
	last_fired[trigger] = world.time
	if(trigger.setting("once"))
		enabled -= trigger
	else
		// A repeating timer counts again from now.
		enabled[trigger] = world.time
	clear_waiting_for(trigger)
	for(var/obj/babylon_tutorial/trigger/next as anything in babylon_tutorial_triggers_after(trigger))
		set_enabled(next, TRUE)
	var/wait = trigger.setting("delay") SECONDS
	for(var/id in trigger.setting("actions"))
		var/obj/babylon_tutorial/action/action = babylon_tutorial_find(id)
		if(!istype(action))
			continue
		wait += action.setting("delay") SECONDS
		if(wait <= 0)
			perform(trigger, action)
		else
			timers += addtimer(CALLBACK(src, PROC_REF(perform_later), WEAKREF(trigger), WEAKREF(action)), wait, TIMER_STOPPABLE)

/datum/babylon_tutorial_run/proc/perform_later(datum/weakref/trigger_ref, datum/weakref/action_ref)
	var/obj/babylon_tutorial/action/action = action_ref?.resolve()
	if(action && !QDELETED(player))
		perform(trigger_ref?.resolve(), action)

/// Performs an action for this run. trigger: the trigger that fired it (null for a preview).
/datum/babylon_tutorial_run/proc/perform(obj/babylon_tutorial/trigger/trigger, obj/babylon_tutorial/action/action)
	if(completed)
		return
	history += "[trigger ? trigger.tutorial_id : "preview"]>[action.tutorial_id]"
	current_trigger = trigger
	try
		action.perform(src)
	catch(var/exception/error)
		babylon_loop_failed("tutorial action [action.tutorial_id]", error)
	current_trigger = null

/datum/babylon_tutorial_run/proc/prune_timers()
	for(var/timer in timers.Copy())
		if(isnull(timeleft(timer)))
			timers -= timer

/// The triggers whose firing ends something an action shows now ("until the next step"): the
/// triggers that start listening after the trigger being performed, or the chosen one.
/datum/babylon_tutorial_run/proc/clear_triggers_for(obj/babylon_tutorial/action/action)
	switch(action.setting("until"))
		if("seconds")
			return list()
		if("trigger")
			var/obj/babylon_tutorial/trigger/chosen = babylon_tutorial_find(action.setting("until_trigger"))
			return istype(chosen) ? list(chosen) : list()
	return current_trigger ? babylon_tutorial_triggers_after(current_trigger) : list()

/// Shows an image to the player only, for a while. anchor: the atom it is attached to; when that
/// is deleted, the image goes. clear_on: triggers whose firing removes it early.
/datum/babylon_tutorial_run/proc/show_image(image/picture, duration, atom/anchor, list/clear_on)
	images[picture] = list("until" = world.time + duration, "anchor" = anchor ? WEAKREF(anchor) : null, "clear_on" = clear_on ? clear_on.Copy() : list())
	// The player's own deletion ends the whole run (player_deleted): never replace that handler.
	if(anchor && anchor != player)
		RegisterSignal(anchor, COMSIG_QDELETING, PROC_REF(anchor_deleted), override = TRUE)
	player.client?.images += picture
	timers += addtimer(CALLBACK(src, PROC_REF(expire_images)), duration + 1, TIMER_STOPPABLE)

/datum/babylon_tutorial_run/proc/anchor_deleted(atom/source)
	SIGNAL_HANDLER
	for(var/image/picture as anything in images.Copy())
		var/list/info = images[picture]
		var/datum/weakref/anchor_ref = info["anchor"]
		// A weakref no longer resolves while its atom is being deleted.
		if(anchor_ref && (anchor_ref.resolve() == source || !anchor_ref.resolve()))
			remove_image(picture)
	UnregisterSignal(source, COMSIG_QDELETING)

/datum/babylon_tutorial_run/proc/remove_image(image/picture)
	images -= picture
	player?.client?.images -= picture
	picture.loc = null

/datum/babylon_tutorial_run/proc/expire_images()
	for(var/image/picture as anything in images.Copy())
		var/list/info = images[picture]
		if(world.time >= info["until"])
			remove_image(picture)
		else if(player?.client && !(picture in player.client.images))
			// The player reconnected: show what is still running again.
			player.client.images += picture

/datum/babylon_tutorial_run/proc/clear_images()
	for(var/image/picture as anything in images.Copy())
		remove_image(picture)

/// A trigger fired: arrows, highlights and repeating points waiting for it end.
/datum/babylon_tutorial_run/proc/clear_waiting_for(obj/babylon_tutorial/trigger/trigger)
	for(var/image/picture as anything in images.Copy())
		var/list/info = images[picture]
		if(trigger in info["clear_on"])
			remove_image(picture)
	for(var/list/entry as anything in pointing.Copy())
		var/list/clear_on = entry[5]
		if(trigger in clear_on)
			pointing -= list(entry)

/datum/babylon_tutorial_run/proc/repeat_point(atom/movable/speaker, atom/target, until, list/clear_on)
	pointing += list(list(WEAKREF(speaker), WEAKREF(target), until, 0, clear_on ? clear_on.Copy() : list()))
	continue_pointing()

/// Speakers point again every 4 seconds while their point action lasts.
/datum/babylon_tutorial_run/proc/continue_pointing()
	for(var/list/entry as anything in pointing.Copy())
		var/datum/weakref/speaker_ref = entry[1]
		var/datum/weakref/target_ref = entry[2]
		var/atom/movable/speaker = speaker_ref.resolve()
		var/atom/target = target_ref.resolve()
		if(!speaker || !target || world.time >= entry[3])
			pointing -= list(entry)
			continue
		if(world.time >= entry[4])
			entry[4] = world.time + 4 SECONDS
			babylon_tutorial_point(src, speaker, target)

/// Shows (or with null removes) the objective that stays on the player's screen.
/datum/babylon_tutorial_run/proc/set_objective(text, title = "Guide")
	objective = text
	if(!player)
		return
	if(preview)
		// The on-screen objective belongs to the player's real run (if any): only tell.
		if(length(text))
			to_chat(player, span_notice("<b>Objective (preview):</b> [html_encode(text)]"))
		return
	if(!length(text))
		player.clear_alert("babylon_tutorial_objective", TRUE)
		return
	var/atom/movable/screen/alert/babylon_tutorial_objective/alert = player.throw_alert("babylon_tutorial_objective", /atom/movable/screen/alert/babylon_tutorial_objective)
	alert?.show(title, text)

/// The objective alert: an icon with the objective written next to it.
/atom/movable/screen/alert/babylon_tutorial_objective
	name = "Objective"
	desc = ""
	icon = 'icons/hud/screen_gen.dmi'
	icon_state = "talk_help"

/atom/movable/screen/alert/babylon_tutorial_objective/proc/show(title, text)
	name = title
	desc = html_encode(text)
	maptext_width = 288
	maptext_height = 32
	maptext_x = -292
	maptext_y = 2
	maptext = "<span style='font-family: \"Grand9K Pixel\"; font-size: 6pt; text-align: right; color: #c8f7d8; -dm-text-outline: 1px black'>[html_encode(text)]</span>"

/// The tutorial is done: the completion screen opens and no trigger fires any more.
/datum/babylon_tutorial_run/proc/complete(text)
	if(completed)
		return
	completed = TRUE
	pointing.Cut()
	clear_images()
	set_objective(null)
	log_game("BABYLON TUTORIAL: [key_name(player)] completed the tutorial[test_run ? " (test run)" : ""].")
	player.playsound_local(get_turf(player), 'sound/misc/server-ready.ogg', 50, FALSE)
	complete_screen = new(src, text)
	if(player.client)
		complete_screen.ui_interact(player)
