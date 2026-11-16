// Tutorial runtime (spec 7.2, 12 #21): ONE /datum/babylon_tutorial_run per world, stepped once a
// second by SSbabylon_tutorial. The tutorial is running or not. In a tutorial world the run starts
// when the first player spawns (station_round.dm); in a creative world the wand's Test run starts,
// restarts and stops it for the whole world.
//
// Everything a run tracks (listening triggers, what fired, pending button presses, gate states
// and numbers, images, objective, speech) is global: every player in the world sees the same arrows and objective,
// including players who join mid-run. Triggers that react to a player fire when ANY player
// satisfies them; actions that target "the player" hit EVERY living player (players.dm keeps who
// the players are, by ckey, also while they are dead or a ghost). Stopping a run resets its state
// only; the world (spawned NPCs, given items) stays.
//
// A preview run (the configure window's Preview button) is a throwaway run of one action for the
// builder only: its only player is that builder and no trigger listens.

/// Every run that exists, the world's run and previews: deleted tutorial objects are purged from
/// all of them.
GLOBAL_LIST_EMPTY(babylon_tutorial_runs)

SUBSYSTEM_DEF(babylon_tutorial)
	name = "Babylon Tutorials"
	wait = 1 SECONDS
	runlevels = RUNLEVEL_LOBBY | RUNLEVELS_DEFAULT
	ss_flags = SS_NO_INIT | SS_KEEP_TIMING
	/// The world's tutorial run, while the tutorial is running.
	var/datum/babylon_tutorial_run/run
	/// Spawners already handled after the world came up (spawn_at_start NPCs appear once).
	var/started_spawners = FALSE

/datum/controller/subsystem/babylon_tutorial/fire(resumed)
	if(!started_spawners && babylon_world_ready())
		started_spawners = TRUE
		babylon_tutorial_spawn_start_npcs()
	refresh_hooks()
	// No try: a wand whose view fails ends only its own sync_view(); the others still sync.
	for(var/obj/item/babylon_tutorial_wand/wand as anything in GLOB.babylon_tutorial_wands)
		wand.sync_view()
	for(var/obj/item/babylon_world_edit_wand/edit_wand as anything in GLOB.babylon_world_edit_wands)
		edit_wand.sync_view()
	// No try here: a deep stack_trace (an outfit, a revive) would unwind the whole step. A runtime
	// ends only the proc it happens in; the next fire steps the run again.
	if(run && !QDELETED(run))
		run.check_triggers()
	// Events Start event actions started, where nothing else steps them (world_actions.dm).
	babylon_tutorial_step_events()

/// Hooks every used-on trigger to its current target (an NPC can be respawned).
/datum/controller/subsystem/babylon_tutorial/proc/refresh_hooks()
	for(var/obj/babylon_tutorial/trigger/used_on/trigger in GLOB.babylon_tutorial_objects)
		trigger.refresh_hook()

/// The world's tutorial run, if the tutorial is running.
/proc/babylon_tutorial_current_run()
	RETURN_TYPE(/datum/babylon_tutorial_run)
	var/datum/babylon_tutorial_run/run = SSbabylon_tutorial.run
	return QDELETED(run) ? null : run

/// Starts (or restarts) the world's tutorial run. from_start: every living player moves to the
/// "start" marker first. test_run: a builder's test (the completion screen offers no lobby
/// button). reset_npcs: spawn-at-start NPCs are created again, fresh (a test restart). players:
/// mobs that take part from the first step even without a client (the spawning player, tests).
/proc/babylon_tutorial_begin(from_start = FALSE, test_run = FALSE, reset_npcs = FALSE, list/players)
	RETURN_TYPE(/datum/babylon_tutorial_run)
	babylon_tutorial_end()
	babylon_tutorial_spawn_start_npcs(reset_npcs)
	var/datum/babylon_tutorial_run/run = new(test_run)
	run.reset_npcs = reset_npcs
	for(var/mob/living/player in players)
		run.add_player(player)
	run.refresh_players()
	if(from_start)
		var/turf/start = babylon_tutorial_marker_turf("start")
		if(start)
			for(var/mob/living/player as anything in run.players())
				player.buckled?.unbuckle_mob(player, TRUE)
				player.forceMove(start)
	SSbabylon_tutorial.run = run
	SSbabylon_tutorial.refresh_hooks()
	log_game("BABYLON TUTORIAL: the tutorial run started[test_run ? " (test)" : ""] with [length(run.players())] player\s.")
	return run

/// A player spawned in a tutorial world: the run starts with them, or they join the running one.
/proc/babylon_tutorial_player_spawned(mob/living/player)
	var/datum/babylon_tutorial_run/run = babylon_tutorial_current_run()
	if(run)
		run.add_player(player)
		return run
	return babylon_tutorial_begin(players = list(player))

/// Stops the world's run, if any.
/proc/babylon_tutorial_end()
	var/datum/babylon_tutorial_run/run = babylon_tutorial_current_run()
	SSbabylon_tutorial.run = null
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
	var/test_run = FALSE
	/// trigger => world.time it started listening (only listening triggers are keys).
	var/list/enabled = list()
	/// trigger => times it fired.
	var/list/fired = list()
	/// trigger => world.time it last fired.
	var/list/last_fired = list()
	/// trigger => whether its condition held at the last check (edge-triggered kinds).
	var/list/last_state = list()
	/// trigger => TRUE: a player's event (a press, a use, a phrase) waits for the next check.
	var/list/hits = list()
	/// "trigger>action" for every action performed, in order (tests and the log).
	var/list/history = list()
	/// Images every player sees: image => list(until, anchor weakref, clear_on triggers).
	var/list/images = list()
	/// Speakers pointing again and again: list(speaker weakref, target weakref, until, next, clear_on).
	var/list/pointing = list()
	/// Timers of actions still waiting.
	var/list/timers = list()
	/// The trigger whose actions are being performed (actions use it for "until the next step").
	var/obj/babylon_tutorial/trigger/current_trigger
	var/completed = FALSE
	var/datum/babylon_tutorial_complete/complete_screen
	/// The objective on every player's screen, if any ("[player]" is filled in per player).
	var/objective
	var/objective_title = "Guide"
	/// Weakrefs to the mobs the objective alert was put on (to take it off again).
	var/list/objective_shown = list()
	/// A throwaway run previewing one action for one builder: never touches the objective alert.
	var/preview = FALSE
	/// The run was started with "Reset NPCs" (Run again does the same).
	var/reset_npcs = FALSE
	/// Player key (ckey, or a ref for a mob without one) => weakref to their body: the living mob
	/// they play, or the one they left when they died or ghosted (players.dm).
	var/list/bodies = list()
	/// Player key => what their body looked like and wore just before it died (players.dm).
	var/list/snapshots = list()
	/// The builder a preview runs for: the run's only player.
	var/mob/living/preview_mob
	/// Gate => its state: a logic gate's output, a number gate's condition (gates.dm).
	var/list/gate_states = list()
	/// Number gate => its number in this run (missing: still its start value).
	var/list/gate_values = list()
	/// The gates being updated right now, outermost first: the current evaluation wave's path.
	var/list/gate_wave = list()
	/// Gate => why the run stopped a loop or an over-long chain at it (the wand shows it).
	var/list/gate_stops = list()
	/// Every stop, in order, for the Test run log.
	var/list/gate_log = list()
	/// Gates that started listening since the last check (gates.dm settle_pending_gates()).
	var/list/gate_pending = list()
	/// Gate updates made in the current wave, and whether the wave ran out of them.
	var/gate_wave_updates = 0
	var/gate_wave_stopped = FALSE
	/// Level trigger (zone, holding, condition) feeding a listening gate => its sampled state.
	var/list/level_states = list()
	/// Action => what went wrong the last time it ran in this run (an NPC that gave up walking, a
	/// door that would not open ...): its issues show it as "Test run: ..." (wand checks).
	var/list/action_notes = list()
	/// Every note, in order, for the Test run tab (the last 20).
	var/list/action_log = list()
	/// NPC => its walk (/datum/babylon_tutorial_npc_move, npc.dm) started by a Move NPC action.
	var/list/movers = list()
	/// Objects the run's Spawn object actions created so far (BABYLON_TUTORIAL_SPAWN_RUN_CAP).
	var/spawned_count = 0

/datum/babylon_tutorial_run/New(test_run, mob/living/preview_for)
	src.test_run = test_run
	GLOB.babylon_tutorial_runs += src
	if(preview_for)
		preview = TRUE
		preview_mob = preview_for
		add_player(preview_for)
		return
	for(var/obj/babylon_tutorial/trigger/trigger as anything in babylon_tutorial_objects_of("trigger"))
		if(trigger.listens_at_start())
			enabled[trigger] = world.time
			if(istype(trigger, /obj/babylon_tutorial/trigger/gate))
				gate_started(trigger)

/datum/babylon_tutorial_run/Destroy()
	GLOB.babylon_tutorial_runs -= src
	if(SSbabylon_tutorial.run == src)
		SSbabylon_tutorial.run = null
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
	bodies.Cut()
	snapshots.Cut()
	gate_states.Cut()
	gate_values.Cut()
	gate_wave.Cut()
	if(length(gate_stops))
		// The stopped gates' issues ("Test run: loop stopped ...") go away.
		babylon_tutorial_changed()
	gate_stops.Cut()
	gate_log.Cut()
	gate_pending.Cut()
	level_states.Cut()
	for(var/mob/living/npc as anything in movers.Copy())
		var/datum/babylon_tutorial_npc_move/walk = movers[npc]
		qdel(walk)
	movers.Cut()
	if(length(action_notes))
		// The actions' issues ("Test run: ...") go away.
		babylon_tutorial_changed()
	action_notes.Cut()
	action_log.Cut()
	preview_mob = null
	if(complete_screen)
		SStgui.close_uis(complete_screen)
		QDEL_NULL(complete_screen)
	return ..()

/// A tutorial object was deleted: drop every reference to it.
/datum/babylon_tutorial_run/proc/forget(obj/babylon_tutorial/object)
	enabled -= object
	fired -= object
	last_fired -= object
	last_state -= object
	hits -= object
	gate_states -= object
	gate_values -= object
	gate_stops -= object
	gate_pending -= object
	level_states -= object
	action_notes -= object
	for(var/mob/living/npc as anything in movers.Copy())
		var/datum/babylon_tutorial_npc_move/walk = movers[npc]
		if(walk.action_ref?.resolve() == object || !walk.action_ref?.resolve())
			qdel(walk)
	if(current_trigger == object)
		current_trigger = null
	for(var/image/picture as anything in images)
		var/list/info = images[picture]
		var/list/clear_on = info["clear_on"]
		clear_on -= object
	for(var/list/entry as anything in pointing)
		var/list/clear_on = entry[5]
		clear_on -= object

/// Something the run listens to is being deleted: a player's body (players.dm) or the anchor of
/// an image. One handler for both, so neither replaces the other's registration.
/datum/babylon_tutorial_run/proc/on_qdeleting(atom/source)
	SIGNAL_HANDLER
	body_deleted(source)
	for(var/image/picture as anything in images.Copy())
		var/list/info = images[picture]
		var/datum/weakref/anchor_ref = info["anchor"]
		// A weakref no longer resolves while its atom is being deleted.
		if(anchor_ref && (anchor_ref.resolve() == source || !anchor_ref.resolve()))
			remove_image(picture)
	UnregisterSignal(source, COMSIG_QDELETING)

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
	var/is_gate = istype(trigger, /obj/babylon_tutorial/trigger/gate)
	if(enable)
		// A gate that starts listening is evaluated at the next check (gates.dm).
		if(is_gate && !is_enabled(trigger))
			gate_started(trigger)
		enabled[trigger] = world.time
		// Its condition counts from now: a zone a player already stands in fires.
		last_state -= trigger
	else
		enabled -= trigger
		if(is_gate)
			gate_stopped(trigger)
	hits -= trigger

/// A player's event for a listening trigger (a press, a use, a phrase).
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
	refresh_players()
	expire_images()
	continue_pointing()
	prune_timers()
	sync_objective()
	if(completed)
		return
	// Gates first: live inputs are sampled, gates that started listening are evaluated.
	sample_levels()
	settle_pending_gates()
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

/// Fires a trigger: what waited for it stops, the next step's triggers start listening, its
/// actions run in order, each after its own delay, and the gates it feeds see it fire.
/datum/babylon_tutorial_run/proc/fire(obj/babylon_tutorial/trigger/trigger)
	mark_fired(trigger)
	run_actions(trigger, trigger.setting("actions"))
	// A level trigger (zone ...) reaches its gates through sample_levels(), live, whether or not
	// it listens itself: notifying here too would count its firing twice.
	if(!trigger.is_level())
		notify_gates(trigger, TRUE)

/// Counts a firing: a once-trigger stops listening, what waited for it ends and the triggers
/// "After" it start listening.
/datum/babylon_tutorial_run/proc/mark_fired(obj/babylon_tutorial/trigger/trigger)
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

/// Runs a list of action ids for a trigger in order, each after its own delay (the trigger's
/// delay first). wait: start from this delay instead of the trigger's (follow-up actions of an
/// action, e.g. a Move NPC action's "On arrival", which already waited for their action).
/datum/babylon_tutorial_run/proc/run_actions(obj/babylon_tutorial/trigger/trigger, list/ids, wait = null)
	if(isnull(wait))
		wait = trigger ? trigger.setting("delay") SECONDS : 0
	for(var/id in ids)
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
	if(action && !QDELETED(src))
		perform(trigger_ref?.resolve(), action)

/// Performs an action for this run. trigger: the trigger that fired it (null for a preview).
/// No try: a deep stack_trace (an outfit, a revive) must end only the proc it happens in.
/datum/babylon_tutorial_run/proc/perform(obj/babylon_tutorial/trigger/trigger, obj/babylon_tutorial/action/action)
	if(completed)
		return
	history += "[trigger ? trigger.tutorial_id : "preview"]>[action.tutorial_id]"
	current_trigger = trigger
	action.perform(src)
	current_trigger = null

/// Something an action could not do in this run (a builder-visible note): the action's issues say
/// "Test run: ..." until the run ends, the Test run tab lists it and the game log has it. A
/// preview tells its builder instead.
/datum/babylon_tutorial_run/proc/note_action(obj/babylon_tutorial/action/action, text)
	var/line = "[action ? action.tutorial_id : "?"]: [text]"
	log_game("BABYLON TUTORIAL: [line]")
	if(preview)
		if(preview_mob)
			to_chat(preview_mob, span_warning("Preview: [html_encode(line)]"))
		return
	action_log += line
	if(length(action_log) > 20)
		action_log.Cut(1, 2)
	if(action && action_notes[action] != text)
		action_notes[action] = text
		babylon_tutorial_changed()

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

/// The clients that see the run's images: every player's (also as a ghost).
/datum/babylon_tutorial_run/proc/image_viewers()
	var/list/found = list()
	for(var/mob/viewer as anything in audience())
		if(viewer.client)
			found |= viewer.client
	return found

/// Shows an image to every player, for a while. anchor: the atom it is attached to; when that is
/// deleted, the image goes. clear_on: triggers whose firing removes it early.
/datum/babylon_tutorial_run/proc/show_image(image/picture, duration, atom/anchor, list/clear_on)
	images[picture] = list("until" = world.time + duration, "anchor" = anchor ? WEAKREF(anchor) : null, "clear_on" = clear_on ? clear_on.Copy() : list())
	if(anchor)
		RegisterSignal(anchor, COMSIG_QDELETING, PROC_REF(on_qdeleting), override = TRUE)
	for(var/client/viewer as anything in image_viewers())
		viewer.images += picture
	timers += addtimer(CALLBACK(src, PROC_REF(expire_images)), duration + 1, TIMER_STOPPABLE)

/datum/babylon_tutorial_run/proc/remove_image(image/picture)
	images -= picture
	// Every client: a player who left the run (or the world's players changed) loses it too.
	for(var/client/viewer as anything in GLOB.clients)
		viewer.images -= picture
	picture.loc = null

/// Expired images go; players who joined or reconnected since see the ones still running.
/datum/babylon_tutorial_run/proc/expire_images()
	var/list/clients = image_viewers()
	for(var/image/picture as anything in images.Copy())
		var/list/info = images[picture]
		if(world.time >= info["until"])
			remove_image(picture)
			continue
		for(var/client/viewer as anything in clients)
			if(!(picture in viewer.images))
				viewer.images += picture

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

/// Shows (or with null removes) the objective that stays on every player's screen.
/datum/babylon_tutorial_run/proc/set_objective(text, title = "Guide")
	if(preview)
		// The on-screen objective belongs to the world's run (if any): only tell.
		if(length(text))
			for(var/mob/viewer as anything in audience())
				to_chat(viewer, span_notice("<b>Objective (preview):</b> [html_encode(babylon_tutorial_fill_text(text, viewer))]"))
		return
	objective = length(text) ? text : null
	objective_title = title || "Guide"
	for(var/datum/weakref/shown_ref as anything in objective_shown)
		var/mob/shown = shown_ref.resolve()
		shown?.clear_alert("babylon_tutorial_objective", TRUE)
	objective_shown.Cut()
	sync_objective()

/// Every living player wears the objective alert while there is one (players who joined later too).
/datum/babylon_tutorial_run/proc/sync_objective()
	if(preview || !objective)
		return
	for(var/mob/living/player as anything in players())
		if(player.alerts["babylon_tutorial_objective"])
			continue
		var/atom/movable/screen/alert/babylon_tutorial_objective/alert = player.throw_alert("babylon_tutorial_objective", /atom/movable/screen/alert/babylon_tutorial_objective)
		alert?.show(objective_title, babylon_tutorial_fill_text(objective, player))
		objective_shown += WEAKREF(player)

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

/// The tutorial is done: every player sees the completion screen and no trigger fires any more.
/datum/babylon_tutorial_run/proc/complete(text)
	if(completed)
		return
	completed = TRUE
	pointing.Cut()
	clear_images()
	set_objective(null)
	log_game("BABYLON TUTORIAL: the tutorial was completed[test_run ? " (test run)" : ""].")
	complete_screen = new(src, text)
	for(var/mob/viewer as anything in audience())
		viewer.playsound_local(get_turf(viewer), 'sound/misc/server-ready.ogg', 50, FALSE)
		if(viewer.client)
			complete_screen.ui_interact(viewer)
