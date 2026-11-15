// Round control in station-build worlds (babylon-station.dmb only).
//
// - Ordinary worlds (kind "world", standard maps and Creative Plane) hold the round forever in
//   the pre-round lobby: there is no countdown. The world's owner and server administrators get
//   a "Start round" button in the title screen menu (and a Babylon verb as fallback).
// - Tutorial worlds (kinds "tutorial" and "tutorial_edit") start at once; a joining player is
//   spawned as an Assistant at the tutorial's start (babylon_tutorial_start_turf()).
// - A restored world whose save says the round had started resumes it at once, without roundstart
//   job assignment or antagonist rolls; returning players get their saved body back
//   (reattach_saved_character, station_characters.dm) or the normal late-join menu.
// - When the round ends, players read the round-end report (the normal restart delay, at most a
//   minute), are sent back to the Babylon lobby and the world stops WITHOUT a save. Whether the next
//   start resumes an autosave or begins fresh is told truthfully (babylon_next_start_text()).
//   Every world reboot ends this way.

/// Longest wait between the round's end and the return to the lobby.
#define BABYLON_ROUND_END_DELAY_MAX (60 SECONDS)
/// Fewer arrival seats than this: the hallway's free floor is added as arrival points.
#define BABYLON_MIN_ARRIVAL_SEATS 4
/// Tutorial spawn attempts per player before giving up.
#define BABYLON_TUTORIAL_SPAWN_TRIES 3

/datum/babylon_save
	/// "hold" (waits for the owner's Start round), "auto" (tutorial kinds: starts at once) or
	/// "resume" (the save had a started round: starts at once without roundstart assignment).
	var/round_mode = "hold"
	/// Who pressed Start round (a key), for the log and the tests.
	var/round_started_by
	/// world.time at which the players return to the lobby after the round's end.
	var/round_end_at
	/// Test hook: replaces the round-end delay (deciseconds) when set.
	var/round_end_delay_override
	/// Where late-joiners arrive ("map", "arrivals chairs", "arrivals floor", "observer start").
	var/latejoin_source
	/// ckeys whose tutorial character is being spawned.
	var/list/tutorial_spawning = list()
	/// ckey -> failed tutorial spawn attempts; at BABYLON_TUTORIAL_SPAWN_TRIES the player is told.
	var/list/tutorial_spawn_failures = list()

/client
	/// The Start round verb is currently given to this client.
	var/babylon_start_verb_shown = FALSE

/// The round's mode for a (tutorial) world whose save does (not) contain a started round.
/proc/babylon_choose_round_mode(tutorial, saved_round_started)
	if(saved_round_started)
		return "resume"
	if(tutorial)
		return "auto"
	return "hold"

/// TRUE only when a save's state says its round had started (state["round"]["started"], written
/// by the station persistence). Anything else, a missing key included, means not started.
/proc/babylon_state_round_started(list/state)
	if(!islist(state))
		return FALSE
	var/list/round_state = state["round"]
	if(!islist(round_state))
		return FALSE
	var/started = round_state["started"]
	return started == TRUE || started == 1 || started == "1"

/// The state.json this world restores from, or null.
/datum/babylon_save/proc/saved_state()
	if(resume_data)
		return resume_data
	if(!fexists("data/babylon/resume-state.json"))
		return null
	try
		return json_decode(file2text("data/babylon/resume-state.json"))
	catch(var/exception/error)
		log_world("Babylon: could not read the saved round state: [error]")
		return null

/// Called from SSbabylon_station.Initialize, before the world reports ready.
/datum/babylon_save/proc/setup_round_control()
	round_mode = babylon_choose_round_mode(GLOB.babylon_world.round_starts_at_once(), babylon_state_round_started(saved_state()))
	if(round_mode == "hold")
		// The master sets timeLeft from start_at once initialization ends: no countdown at all.
		SSticker.SetTimeLeft(-1)
	else
		SSticker.start_immediately = TRUE
	RegisterSignal(SSticker, COMSIG_TICKER_ERROR_SETTING_UP, PROC_REF(round_setup_failed))
	ensure_latejoin_points()
	log_world("Babylon: round mode [round_mode]; late-joiners arrive at: [latejoin_source].")

/// A failed setup goes back to the pre-round lobby; without this it would retry at once forever.
/datum/babylon_save/proc/round_setup_failed()
	SIGNAL_HANDLER
	if(round_mode != "hold")
		// Tutorials and resumed rounds are only ready once their round runs: report the failure
		// (the supervisor shows it) instead of a silent startup timeout.
		if(!boot_error)
			boot_error = "This world's round could not start. Try starting it again; if it keeps failing, tell an admin."
			log_world("Babylon: round setup failed in a [round_mode] world.")
		return
	SSticker.start_immediately = FALSE
	SSticker.SetTimeLeft(-1)
	round_started_by = null
	to_chat(world, span_warning("The round could not start. [html_encode(babylon_world_owner_name())] can press Start round to try again; if it keeps failing, tell an admin."))
	SStitle.show_title_screen()

/// The round waits for its owner: pre-round, no start requested.
/proc/babylon_round_on_hold()
	var/datum/babylon_save/session = GLOB.babylon_save
	return session?.round_mode == "hold" && SSticker.current_state <= GAME_STATE_PREGAME && !SSticker.start_immediately && SSticker.GetTimeLeft() < 0

/// The world owner's key: remembered from the last time they were connected, else their ckey.
/proc/babylon_world_owner_name()
	var/static/last_seen_key
	var/owner = GLOB.babylon_world.owner_ckey
	var/client/owner_client = GLOB.directory[owner]
	if(owner_client?.key)
		last_seen_key = owner_client.key
	return last_seen_key || owner || "the world's owner"

/// The owner is connected right now.
/proc/babylon_world_owner_online()
	return !!GLOB.directory[GLOB.babylon_world.owner_ckey]

/// What the waiting round says to this viewer: the owner and admins start it themselves, everyone
/// else is told whom they wait for (or that the owner is away).
/proc/babylon_round_status_text(client/viewer)
	return babylon_round_status_for(viewer && babylon_may_start_round(viewer), babylon_world_owner_online(), babylon_world_owner_name())

/proc/babylon_round_status_for(may_start, owner_online, owner_name)
	if(may_start)
		return "You start this round. Press START ROUND when everyone is ready."
	if(owner_online)
		return "Waiting for [owner_name] to start the round. Tick READY to get a job when it starts."
	return "[owner_name] is offline. Only they or an admin can start this round; you can OBSERVE or return to the lobby."

/// Players ready for the roundstart, and all players in the menu.
/proc/babylon_ready_counts()
	var/ready_players = 0
	var/total = 0
	for(var/mob/dead/new_player/player as anything in GLOB.new_player_list)
		if(!player.client)
			continue
		total++
		if(player.ready == PLAYER_READY_TO_PLAY)
			ready_players++
	return list(ready_players, total)

/// What the end of the round says about the world's next start. Players who are not the owner
/// only hear what is true for everyone.
/proc/babylon_next_start_text(for_owner = FALSE)
	// Only a world with a save to go back to picks up from it.
	return babylon_next_start_message(babylon_world_saves() && !!GLOB.babylon_save?.last_save, for_owner)

/proc/babylon_next_start_message(saves, for_owner)
	if(!saves)
		return for_owner ? null : "Next time this world starts, it begins a fresh round."
	return for_owner ? "Next time you start this world, it picks up from its last autosave before the round ended. To begin fresh, reset or roll back the world in the lobby." : null

/// Who may start the round: the world's owner and server administrators, never visitors.
/proc/babylon_round_starter_allowed(player_ckey, role, server_rights, visitor)
	if(!player_ckey || visitor)
		return FALSE
	return player_ckey == GLOB.babylon_world.owner_ckey || role == "admin" || !!server_rights

/proc/babylon_may_start_round(client/player)
	if(!player)
		return FALSE
	return babylon_round_starter_allowed(player.ckey, player.babylon_world_role, check_rights_for(player, R_SERVER), player.babylon_showcase_visitor || player.babylon_admin_spectator)

/// Starts the held round for its owner or an administrator. Checked here, on the server, so a
/// forged menu link from anyone else does nothing.
/proc/babylon_start_round(mob/user)
	var/client/player = user?.client
	if(!babylon_may_start_round(player))
		if(player)
			to_chat(player, span_warning("Only the world's owner or a server administrator can start the round."))
		return FALSE
	if(!babylon_round_on_hold())
		to_chat(player, span_warning(SSticker.HasRoundStarted() ? "The round has already started." : "The round is already starting."))
		return FALSE
	log_game("[key_name(player)] started the round.")
	return GLOB.babylon_save.begin_round(player.key, player)

/// Starts the held round. The starter is marked READY (unless observing), so that pressing Start
/// round does not leave them without a job.
/datum/babylon_save/proc/begin_round(starter, client/starter_client)
	if(round_mode != "hold" || !babylon_round_on_hold() || SSticker.current_state != GAME_STATE_PREGAME)
		return FALSE
	round_started_by = starter
	mark_starter_ready(starter_client?.mob)
	SSticker.start_immediately = TRUE
	to_chat(world, span_boldannounce("[html_encode(starter)] started the round."))
	return TRUE

/// The starter gets a job too, unless they already observe (an observer's mob is no new_player).
/datum/babylon_save/proc/mark_starter_ready(mob/starter_mob)
	if(!istype(starter_mob, /mob/dead/new_player))
		return FALSE
	var/mob/dead/new_player/menu = starter_mob
	menu.ready = PLAYER_READY_TO_PLAY
	return TRUE

/// Resumed rounds and tutorials: no roundstart jobs and no roundstart antagonists.
/proc/babylon_skip_roundstart_assignment()
	var/datum/babylon_save/session = GLOB.babylon_save
	return session?.round_mode == "resume" || session?.round_mode == "auto"

/datum/controller/subsystem/ticker/setup()
	if(babylon_skip_roundstart_assignment())
		// Nobody gets a roundstart job: every player joins late (or gets their saved body back).
		for(var/mob/dead/new_player/player as anything in GLOB.new_player_list)
			player.ready = PLAYER_NOT_READY
	return ..()

/datum/controller/subsystem/gamemode/handle_pre_setup_roundstart_events()
	if(babylon_skip_roundstart_assignment())
		return
	return ..()

/datum/controller/subsystem/gamemode/handle_post_setup_roundstart_events()
	if(babylon_skip_roundstart_assignment())
		return
	return ..()

/// No latejoin antagonists in worlds without a storyteller (tutorials, Creative Plane).
/datum/controller/subsystem/dynamic/on_latejoin(mob/living/carbon/human/latejoiner)
	if(babylon_storyteller_inert())
		return
	return ..()

// --- Title screen menu ---------------------------------------------------------------------

/// Babylon's look on tg's menu (modular_babylon/lobby/style.css palette): colours and font only.
#define BABYLON_TITLE_STYLE {"<style>
.container_nav{border:1px solid #6bcdc1 !important;border-radius:9px !important;background:rgba(16,23,34,.9) !important;box-shadow:0 6px 24px rgba(0,0,0,.6) !important;opacity:1 !important}
.container_logo{display:none !important}
.container_nav hr{background-color:#34465e !important;box-shadow:none !important}
.menu_button{color:#e3eaf4 !important;font-family:'Segoe UI',Arial,sans-serif !important;font-weight:600 !important;letter-spacing:.5px !important;text-shadow:1px 1px #000 !important}
.menu_button:hover{color:#7dd3c7 !important;transform:none !important}
.menu_button:hover::before,.menu_button:active::before{content:"›" !important;font-family:inherit !important}
.checked{color:#9be7be !important}
.unchecked{color:#ffc2c7 !important}
.menu_notice{font-family:'Segoe UI',Arial,sans-serif !important;color:#ffe1a0 !important}
.babylon_brand{font:700 2vmin 'Segoe UI',Arial,sans-serif;letter-spacing:3px;color:#7dd3c7;text-align:left;padding-left:5vmin;margin-bottom:.8vmin}
.babylon_round_status{font:600 2.2vmin/1.3 'Segoe UI',Arial,sans-serif;color:#ffe1a0;text-align:left;padding:0 2vmin 0 5vmin;margin:0 0 1vmin 0}
.menu_button.babylon_start_round{background:#256d66 !important;border:1px solid #6bcdc1;border-radius:6px;color:#fff !important;height:5vmin;line-height:5vmin;margin-bottom:1vmin}
.menu_button.babylon_start_round:hover{background:#2d7f77 !important;color:#fff !important}
</style>"}

/// While the round is held the menu holds more (status, Start round): the box sits higher, so a long,
/// wrapped status line cannot push the menu past the bottom of a short window. The default box
/// is 90vmin wide, 22.5vmin below the middle; its buttons (up to 12 x 4vmin) plus these lines
/// reach about 96vmin of a 100vmin window otherwise.
#define BABYLON_TITLE_STYLE_HELD "<style>.container_nav{top:calc(50% + 15vmin) !important}</style>"

/// What Babylon adds to the top of the menu for this player: the round's status and, for the
/// owner and administrators, the Start round button (with how many players are ready).
/proc/babylon_title_additions(client/player, menu_ref)
	. = {"<div class="babylon_brand">BABYLON13</div>"}
	var/datum/babylon_save/session = GLOB.babylon_save
	if(session?.round_mode == "auto" && !babylon_round_on_hold())
		var/failed = player && session.tutorial_spawn_failures[player.ckey] >= BABYLON_TUTORIAL_SPAWN_TRIES
		. += {"<p class="babylon_round_status">[failed ? "Your tutorial could not start." : "Starting your tutorial…"]</p>"}
		if(failed)
			. += {"<a class="menu_button babylon_start_round" href='byond://?src=[menu_ref];babylon_retry_tutorial=1'>RETRY TUTORIAL</a>"}
		return
	if(!babylon_round_on_hold())
		return
	. = BABYLON_TITLE_STYLE_HELD + .
	. += {"<p class="babylon_round_status">[html_encode(babylon_round_status_text(player))]</p>"}
	if(babylon_may_start_round(player))
		var/list/counts = babylon_ready_counts()
		. += {"<a class="menu_button babylon_start_round" href='byond://?src=[menu_ref];babylon_start_round=1'>START ROUND ([counts[1]] of [counts[2]] ready)</a>"}

/// The ready counter is on the owner's and the admins' title screens; everyone's status line
/// depends on whether the owner is here. Refreshes the starters', or everyone's with all.
/proc/babylon_refresh_starter_titles(all = FALSE)
	if(!babylon_round_on_hold())
		return
	for(var/mob/dead/new_player/menu as anything in GLOB.new_player_list)
		if(menu.client && menu.title_screen_is_ready && (all || babylon_may_start_round(menu.client)))
			menu.update_title_screen()

/// A player leaving the menu: the ready counter and the owner's presence changed for the others.
/mob/dead/new_player/Logout()
	. = ..()
	addtimer(CALLBACK(GLOBAL_PROC, GLOBAL_PROC_REF(babylon_refresh_starter_titles), TRUE), 1 SECONDS)

/proc/babylon_title_style()
	return BABYLON_TITLE_STYLE

/mob/dead/new_player/get_title_html()
	. = ..()
	. = replacetext(., {"<div class="container_nav">"}, {"[babylon_title_style()]<div class="container_nav">[babylon_title_additions(client, text_ref(src))]"})

/mob/dead/new_player/Topic(href, href_list)
	if(href_list["babylon_start_round"])
		if(src != usr || !client)
			return
		play_lobby_button_sound()
		if(babylon_start_round(src))
			SStitle.show_title_screen()
		return
	if(href_list["babylon_retry_tutorial"])
		if(src != usr || !client)
			return
		play_lobby_button_sound()
		GLOB.babylon_save.tutorial_spawn_failures -= client.ckey
		update_title_screen()
		return
	. = ..()
	if(href_list["toggle_ready"])
		babylon_refresh_starter_titles()

/mob/dead/new_player/Login()
	. = ..()
	// Visitors and spectating admins leave the menu at once (showcase.dm, spectator.dm).
	if(!client || client.babylon_showcase_visitor || client.babylon_admin_spectator)
		return
	var/datum/babylon_save/session = GLOB.babylon_save
	babylon_world_owner_name() // remembers the owner's key while they are here
	if(babylon_round_on_hold())
		if(babylon_may_start_round(client))
			to_chat(src, span_notice("You start this round. Tick <b>READY</b> so you get a job, then press <b>Start round</b> when your friends are ready."))
		else
			to_chat(src, span_notice("[html_encode(babylon_round_status_text(client))] Set up your character in the meantime."))
		babylon_refresh_starter_titles(TRUE)
	else if(session?.round_mode == "auto")
		to_chat(src, span_notice("Starting your tutorial…"))
	else if(session?.round_mode == "resume" && SSticker.HasRoundStarted())
		to_chat(src, span_notice("This round continues from the world's last autosave."))
		INVOKE_ASYNC(session, TYPE_PROC_REF(/datum/babylon_save, return_to_resumed_round), client)
	else if(SSticker.HasRoundStarted())
		to_chat(src, span_notice("The round is under way. Press <b>JOIN GAME</b> and pick a job; you arrive in the arrivals hallway."))

/datum/babylon_save/proc/return_to_resumed_round(client/player)
	if(!player || player.babylon_showcase_visitor || player.babylon_admin_spectator)
		return
	if(!istype(player.mob, /mob/dead/new_player))
		return
	// A saved body (station_characters.dm), else the normal late-join menu (JOIN GAME).
	reattach_saved_character(player)

/mob/dead/get_status_tab_items()
	. = ..()
	if(!babylon_round_on_hold())
		return
	var/list/items = .
	for(var/index in 1 to length(items))
		if(istext(items[index]) && findtext(items[index], "Time To Start:") == 1)
			items[index] = babylon_round_status_text(client)

/atom/movable/screen/lobby/new_player_info/time_remaining_str()
	if(babylon_round_on_hold())
		return "Waiting for the owner"
	return ..()

/client/proc/babylon_start_round_verb()
	set name = "Start round"
	set category = "Babylon"
	set desc = "Start the round now (players who ticked READY get their jobs)."
	babylon_start_round(mob)

/client/proc/babylon_update_start_verb()
	var/wanted = babylon_round_on_hold() && babylon_may_start_round(src)
	if(wanted == babylon_start_verb_shown)
		return
	babylon_start_verb_shown = wanted
	if(wanted)
		add_verb(src, /client/proc/babylon_start_round_verb)
	else
		remove_verb(src, /client/proc/babylon_start_round_verb)

// --- Late-join arrivals --------------------------------------------------------------------

/// SPLURT's late-joiners arrive at the Interlink (its own level, CentCom_bubber_z2.dmm, with the
/// NTV Relay arrivals shuttle and all latejoin landmarks), which ABSOLUTE_MINIMUM does not load.
/// The station maps' arrivals docks (Bubber's automapper templates) have no landmarks of their
/// own, so late-joiners would land in tg's last-resort spawn. They arrive in the station's
/// arrivals hallway instead, on its seats where it has any.
/datum/babylon_save/proc/ensure_latejoin_points()
	if(length(SSjob.latejoin_trackers) || length(SSjob.latejoin_override_trackers))
		latejoin_source = "map"
		return
	var/list/seats = list()
	var/list/floors = list()
	var/area/entry = GLOB.areas_by_type[/area/station/hallway/secondary/entry]
	if(entry)
		for(var/list/zlevel_turfs as anything in entry.get_zlevel_turf_lists())
			for(var/turf/open/floor as anything in zlevel_turfs)
				if(!istype(floor) || !is_station_level(floor.z))
					continue
				var/obj/structure/chair/seat = locate() in floor
				if(seat && seat.anchored && !istype(seat, /obj/structure/chair/stool))
					seats += seat
				else if(!floor.is_blocked_turf(TRUE))
					floors += floor
	if(length(seats) >= BABYLON_MIN_ARRIVAL_SEATS)
		SSjob.latejoin_trackers += seats
		latejoin_source = "arrivals chairs"
	else if(length(seats) && length(floors))
		// Too few seats for a group (pubbystation has one bench): the free hallway floor too.
		SSjob.latejoin_trackers += seats
		SSjob.latejoin_trackers += floors
		latejoin_source = "arrivals chairs and floor"
	else if(length(seats))
		SSjob.latejoin_trackers += seats
		latejoin_source = "arrivals chairs"
	else if(length(floors))
		SSjob.latejoin_trackers += floors
		latejoin_source = "arrivals floor"
	else if(respawn_turf)
		SSjob.latejoin_trackers += respawn_turf
		latejoin_source = "observer start"

// --- Tutorials -----------------------------------------------------------------------------

/// Where a tutorial player starts: the tutorial's "start" marker (tutorial/runtime.dm); a
/// tutorial without one starts at a late-join spawn point.
/proc/babylon_tutorial_start_turf()
	var/turf/marked = babylon_tutorial_marker_turf("start")
	if(marked)
		return marked
	if(length(SSjob.latejoin_trackers))
		return get_turf(pick(SSjob.latejoin_trackers))
	return GLOB.babylon_save.respawn_turf

/datum/babylon_save/New()
	. = ..()
	tick_listeners += new /datum/babylon_tick_listener(src, CALLBACK(src, PROC_REF(tick_round_control)))

/// Every world tick: the Start round verb and the tutorial spawns.
/datum/babylon_save/proc/tick_round_control()
	if(draining)
		return
	for(var/client/player in GLOB.clients)
		if(!babylon_ready_client(player))
			continue
		// Each player on their own, as in the session's loop.
		try
			player.babylon_update_start_verb()
			if(wants_tutorial_spawn(player))
				INVOKE_ASYNC(src, PROC_REF(spawn_tutorial_player), player)
		catch(var/exception/error)
			babylon_loop_failed("round control for [player?.ckey]", error)

/datum/babylon_save/proc/wants_tutorial_spawn(client/player)
	if(round_mode != "auto" || SSticker.current_state != GAME_STATE_PLAYING || !istype(player.mob, /mob/dead/new_player))
		return FALSE
	if(player.babylon_showcase_visitor || player.babylon_admin_spectator || (player.ckey in tutorial_spawning))
		return FALSE
	return tutorial_spawn_failures[player.ckey] < BABYLON_TUTORIAL_SPAWN_TRIES

/// Tutorial worlds: the player plays their preferences character as an Assistant.
/// A failed attempt is retried on the next ticks, at most BABYLON_TUTORIAL_SPAWN_TRIES times; then
/// the player is told and keeps the menu (JOIN GAME still works).
/datum/babylon_save/proc/spawn_tutorial_player(client/player)
	var/player_key = player.ckey
	tutorial_spawning += player_key
	var/spawned = FALSE
	try
		var/mob/dead/new_player/menu = player.mob
		if(istype(menu) && menu.AttemptLateSpawn(JOB_ASSISTANT))
			spawned = TRUE
			var/mob/living/character = player?.mob
			var/turf/start = babylon_tutorial_start_turf()
			if(isliving(character) && start)
				character.buckled?.unbuckle_mob(character, TRUE)
				character.forceMove(start)
			// Play instances run the tutorial: the first player starts the world's one run, later
			// ones join it. Admins editing one test-run it. Started from a timer, with no try
			// above it: starting a run spawns NPCs (outfits), and a harmless stack_trace in there
			// must not unwind to a catch and leave the world without its run.
			if(isliving(character) && GLOB.babylon_world.plays_tutorial_on_join())
				addtimer(CALLBACK(GLOBAL_PROC, GLOBAL_PROC_REF(babylon_tutorial_player_spawned), character), 0)
	catch(var/exception/error)
		log_world("Babylon: spawning [player_key] in the tutorial failed: [error] ([error?.file]:[error?.line])")
	tutorial_spawning -= player_key
	if(spawned)
		tutorial_spawn_failures -= player_key
		return
	tutorial_spawn_failures[player_key] = tutorial_spawn_failures[player_key] + 1
	if(tutorial_spawn_failures[player_key] >= BABYLON_TUTORIAL_SPAWN_TRIES)
		log_world("Babylon: gave up spawning [player_key] in the tutorial after [BABYLON_TUTORIAL_SPAWN_TRIES] attempts.")
		if(player)
			to_chat(player, span_warning("Your tutorial character could not be created. Use <b>Return to Babylon lobby</b> (Babylon tab) and start the tutorial again; tell an admin if it keeps happening."))
			var/mob/dead/new_player/menu = player.mob
			if(istype(menu) && menu.title_screen_is_ready)
				menu.update_title_screen() // offers RETRY TUTORIAL

// --- Round end -----------------------------------------------------------------------------

/// The time players get to read the round-end report: the normal restart delay, at most a minute.
/datum/babylon_save/proc/round_end_delay()
	if(!isnull(round_end_delay_override))
		return round_end_delay_override
	return clamp(CONFIG_GET(number/round_end_countdown) * (1 SECONDS), 5 SECONDS, BABYLON_ROUND_END_DELAY_MAX)

/// tg reboots the world once the round-end report is out; Babylon worlds go back to the lobby.
/datum/controller/subsystem/ticker/standard_reboot()
	if(!ready_for_reboot || !world.params["babylon-world"])
		return ..()
	GLOB.babylon_save.end_world_without_save()

/// Every other reboot (an administrator's Reboot World, a nuke) ends the world the same way:
/// a restarted run would bypass the supervisor.
/world/Reboot(reason = 0, fast_track = FALSE)
	if(!params["babylon-world"])
		return ..()
	log_world("Babylon: a world reboot was requested; the world stops without a save instead.")
	GLOB.babylon_save.end_world_without_save(SSticker.current_state == GAME_STATE_FINISHED ? null : 0)

/// The round is over: tell the supervisor (the run is stopping, nobody is admitted any more),
/// let the players read the report, send them to the lobby and exit. Never saves.
/datum/babylon_save/proc/end_world_without_save(delay)
	set waitfor = FALSE
	if(round_ending)
		return
	round_ending = TRUE
	draining = TRUE
	if(isnull(delay))
		delay = round_end_delay()
	round_end_at = world.time + delay
	log_world("Babylon: the round is over; returning players to the lobby in [delay / 10] s, without a save.")
	// Bounded: whatever the supervisor does, the players still go to the lobby and the world exits.
	if(world.params["babylon-api"] && !babylon_supervisor_request_within(list("action" = "round_ended"))["ok"])
		log_world("Babylon: the supervisor did not confirm the round's end; it sees the exit as a stop.")
	// tg already announces "The round has ended." on its own.
	if(delay > 0)
		to_chat(world, span_notice("Read the round-end report; everyone returns to the Babylon lobby in [DisplayTimeText(delay)]."))
	else
		to_chat(world, span_notice("Everyone returns to the Babylon lobby now."))
	var/next_start = babylon_next_start_text()
	if(next_start)
		to_chat(world, span_notice(next_start))
	var/owner_next_start = babylon_next_start_text(TRUE)
	var/client/owner_client = GLOB.directory[GLOB.babylon_world.owner_ckey]
	if(owner_next_start && owner_client)
		to_chat(owner_client, span_notice(owner_next_start))
	sleep(delay)
	while(SSticker.delay_end)
		sleep(1 SECONDS)
	for(var/client/player in GLOB.clients.Copy())
		if(world.params["babylon-lobby"])
			player << link(world.params["babylon-lobby"])
	// As managed_stop: plain BYOND sleeps, independent of the master's timers.
	sleep(3 SECONDS)
	stop_world()

/datum/controller/subsystem/ticker/fire()
	. = ..()
	var/datum/babylon_save/session = GLOB.babylon_save
	if(current_state != GAME_STATE_FINISHED || !session?.round_ending || !reboot_hud)
		return
	if(delay_end)
		reboot_hud.maptext = MAPTEXT_PIXELLARI("<center>Return to lobby\npaused by an admin</center>")
	else
		reboot_hud.maptext = MAPTEXT_PIXELLARI("<center>Returning to the lobby in:\n [DisplayTimeText(max(0, session.round_end_at - world.time), 1)]</center>")

#undef BABYLON_TITLE_STYLE
#undef BABYLON_TITLE_STYLE_HELD
#undef BABYLON_ROUND_END_DELAY_MAX
#undef BABYLON_TUTORIAL_SPAWN_TRIES
#undef BABYLON_MIN_ARRIVAL_SEATS
