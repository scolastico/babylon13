// Tutorial runtime (spec 7.2): one /datum/babylon_tutorial_run per participating player, stepped
// once a second by SSbabylon_tutorial. A run starts automatically when a player spawns in a
// tutorial world (station_round.dm) and from the wand's Test run in creative worlds.
//
// Everything a run tracks (enabled triggers, what fired, pending button presses, the player's
// private images) is per run, so two builders test-running at once never fire each other's
// steps. Stopping a run resets its state only; the world (spawned NPCs, given items) stays.

SUBSYSTEM_DEF(babylon_tutorial)
	name = "Babylon Tutorials"
	wait = 1 SECONDS
	runlevels = RUNLEVEL_LOBBY | RUNLEVELS_DEFAULT
	ss_flags = SS_NO_INIT | SS_KEEP_TIMING
	/// player mob => /datum/babylon_tutorial_run
	var/list/runs = list()
	/// Spawners already handled after the world came up (spawn_at_start NPCs appear once).
	var/started_spawners = FALSE

/datum/controller/subsystem/babylon_tutorial/fire(resumed)
	if(!started_spawners && babylon_world_ready())
		started_spawners = TRUE
		babylon_tutorial_spawn_start_npcs()
	refresh_hooks()
	for(var/mob/player as anything in runs.Copy())
		var/datum/babylon_tutorial_run/run = runs[player]
		try
			run.check_triggers()
		catch(var/exception/error)
			babylon_loop_failed("tutorial run of [player]", error)
	for(var/obj/item/babylon_tutorial_wand/wand as anything in GLOB.babylon_tutorial_wands)
		try
			wand.sync_view()
		catch(var/exception/error)
			babylon_loop_failed("tutorial wand view", error)

/// Hooks every used-on trigger to its current target (an NPC can be respawned).
/datum/controller/subsystem/babylon_tutorial/proc/refresh_hooks()
	for(var/obj/babylon_tutorial/trigger/used_on/trigger in GLOB.babylon_tutorial_objects)
		trigger.refresh_hook()

/// The tutorial run a mob takes part in, if any.
/proc/babylon_tutorial_run_of(mob/player)
	RETURN_TYPE(/datum/babylon_tutorial_run)
	return player ? SSbabylon_tutorial.runs[player] : null

/// Starts (or restarts) a tutorial run for a player. from_start: move them to the "start" marker
/// first. test_run: a builder's test (the completion screen offers no lobby button).
/proc/babylon_tutorial_begin(mob/living/player, from_start = FALSE, test_run = FALSE)
	RETURN_TYPE(/datum/babylon_tutorial_run)
	if(!istype(player) || QDELETED(player))
		return null
	babylon_tutorial_end(player)
	if(from_start)
		var/turf/start = babylon_tutorial_marker_turf("start")
		if(start)
			player.buckled?.unbuckle_mob(player, TRUE)
			player.forceMove(start)
	babylon_tutorial_spawn_start_npcs()
	var/datum/babylon_tutorial_run/run = new(player, test_run)
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

/// NPC spawners set to spawn at the start, which have no living NPC yet, create it.
/proc/babylon_tutorial_spawn_start_npcs()
	for(var/obj/babylon_tutorial/npc_spawner/spawner in GLOB.babylon_tutorial_objects)
		if(spawner.setting("spawn_at_start") && !spawner.current_npc())
			spawner.spawn_npc()

/datum/babylon_tutorial_run
	var/mob/living/player
	var/test_run = FALSE
	/// trigger => world.time it was enabled (only enabled triggers are keys).
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
	/// Private images shown to the player: image => world.time it disappears.
	var/list/images = list()
	/// Speakers pointing again and again: list(speaker weakref, target weakref, until).
	var/list/pointing = list()
	/// Timers of actions still waiting.
	var/list/timers = list()
	var/completed = FALSE
	var/datum/babylon_tutorial_complete/complete_screen

/datum/babylon_tutorial_run/New(mob/living/player, test_run)
	src.player = player
	src.test_run = test_run
	RegisterSignal(player, COMSIG_QDELETING, PROC_REF(player_deleted))
	RegisterSignal(player, COMSIG_MOB_SAY, PROC_REF(player_said))
	for(var/obj/babylon_tutorial/trigger/trigger as anything in babylon_tutorial_objects_of("trigger"))
		if(trigger.setting("enabled_at_start"))
			enabled[trigger] = world.time

/datum/babylon_tutorial_run/Destroy()
	for(var/timer in timers)
		deltimer(timer)
	timers.Cut()
	clear_images()
	if(player)
		UnregisterSignal(player, list(COMSIG_QDELETING, COMSIG_MOB_SAY))
		if(SSbabylon_tutorial.runs[player] == src)
			SSbabylon_tutorial.runs -= player
	if(complete_screen)
		SStgui.close_uis(complete_screen)
		QDEL_NULL(complete_screen)
	player = null
	return ..()

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

/// world.time the trigger was (last) enabled.
/datum/babylon_tutorial_run/proc/enabled_since(obj/babylon_tutorial/trigger/trigger)
	return enabled[trigger] || world.time

/datum/babylon_tutorial_run/proc/set_enabled(obj/babylon_tutorial/trigger/trigger, enable)
	if(enable)
		enabled[trigger] = world.time
		// Its condition counts from now: a zone the player already stands in fires.
		last_state -= trigger
	else
		enabled -= trigger
	hits -= trigger

/// The player's event for an enabled trigger (a press, a use, a phrase).
/datum/babylon_tutorial_run/proc/hit(obj/babylon_tutorial/trigger/trigger)
	if(is_enabled(trigger) && !completed)
		hits[trigger] = TRUE

/datum/babylon_tutorial_run/proc/take_hit(obj/babylon_tutorial/trigger/trigger)
	if(!hits[trigger])
		return FALSE
	hits -= trigger
	return TRUE

/// One check of every enabled trigger.
/datum/babylon_tutorial_run/proc/check_triggers()
	if(QDELETED(player))
		qdel(src)
		return
	expire_images()
	continue_pointing()
	if(completed)
		return
	for(var/obj/babylon_tutorial/trigger/trigger as anything in enabled.Copy())
		if(QDELETED(trigger))
			enabled -= trigger
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

/// Fires a trigger: its actions run in order, each after its own delay.
/datum/babylon_tutorial_run/proc/fire(obj/babylon_tutorial/trigger/trigger)
	fired[trigger] = fired[trigger] + 1
	last_fired[trigger] = world.time
	if(trigger.setting("once"))
		enabled -= trigger
	else
		// A repeating timer counts again from now.
		enabled[trigger] = world.time
	var/wait = trigger.setting("delay") SECONDS
	for(var/id in trigger.setting("actions"))
		var/obj/babylon_tutorial/action/action = babylon_tutorial_find(id)
		if(!istype(action))
			continue
		wait += action.setting("delay") SECONDS
		if(wait <= 0)
			perform(trigger.tutorial_id, action)
		else
			timers += addtimer(CALLBACK(src, PROC_REF(perform_later), trigger.tutorial_id, WEAKREF(action)), wait, TIMER_STOPPABLE)

/datum/babylon_tutorial_run/proc/perform_later(trigger_id, datum/weakref/action_ref)
	var/obj/babylon_tutorial/action/action = action_ref?.resolve()
	if(action && !QDELETED(player))
		perform(trigger_id, action)

/datum/babylon_tutorial_run/proc/perform(trigger_id, obj/babylon_tutorial/action/action)
	if(completed)
		return
	history += "[trigger_id]>[action.tutorial_id]"
	try
		action.perform(src)
	catch(var/exception/error)
		babylon_loop_failed("tutorial action [action.tutorial_id]", error)

/// Shows an image to the player only, for a while.
/datum/babylon_tutorial_run/proc/show_image(image/picture, duration)
	images[picture] = world.time + duration
	player.client?.images += picture
	timers += addtimer(CALLBACK(src, PROC_REF(expire_images)), duration + 1, TIMER_STOPPABLE)

/datum/babylon_tutorial_run/proc/expire_images()
	for(var/image/picture as anything in images.Copy())
		if(world.time >= images[picture])
			images -= picture
			player?.client?.images -= picture
		else if(player?.client && !(picture in player.client.images))
			// The player reconnected: show what is still running again.
			player.client.images += picture

/datum/babylon_tutorial_run/proc/clear_images()
	for(var/image/picture as anything in images)
		player?.client?.images -= picture
	images.Cut()

/datum/babylon_tutorial_run/proc/repeat_point(atom/movable/speaker, atom/target, until)
	pointing += list(list(WEAKREF(speaker), WEAKREF(target), until, 0))
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
			babylon_tutorial_point(speaker, target)

/// The tutorial is done: the completion screen opens and no trigger fires any more.
/datum/babylon_tutorial_run/proc/complete(text)
	if(completed)
		return
	completed = TRUE
	pointing.Cut()
	log_game("BABYLON TUTORIAL: [key_name(player)] completed the tutorial[test_run ? " (test run)" : ""].")
	player.playsound_local(get_turf(player), 'sound/misc/server-ready.ogg', 50, FALSE)
	complete_screen = new(src, text)
	if(player.client)
		complete_screen.ui_interact(player)
