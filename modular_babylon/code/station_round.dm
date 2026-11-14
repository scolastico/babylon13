// Round control in station-build worlds (babylon-station.dmb only).
//
// - Ordinary worlds (kind "world", standard maps and Creative Plane) hold the round forever in
//   the pre-round lobby: there is no countdown. The world's owner and server administrators get
//   a "Start round" button in the title screen menu (and a Babylon verb as fallback).
// - Tutorial worlds (kinds "tutorial" and "tutorial_edit") start at once; a joining player is
//   spawned as an Assistant at the tutorial's start (babylon_tutorial_start_turf()).
// - A restored world whose save says the round had started resumes it at once, without roundstart
//   job assignment or antagonist rolls; returning players get their saved body back
//   (reattach_saved_character, Task D2) or the normal late-join menu.
// - When the round ends, players read the round-end report (the normal restart delay, at most a
//   minute), are sent back to the Babylon lobby and the world stops WITHOUT a save: the next start
//   resumes the latest autosave from before the round ended. Every world reboot ends this way.

/// Longest wait between the round's end and the return to the lobby.
#define BABYLON_ROUND_END_DELAY_MAX (60 SECONDS)

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

/client
	/// The Start round verb is currently given to this client.
	var/babylon_start_verb_shown = FALSE

/// The round's mode for a world of this kind whose save does (not) contain a started round.
/proc/babylon_choose_round_mode(kind, saved_round_started)
	if(saved_round_started)
		return "resume"
	if(kind == "tutorial" || kind == "tutorial_edit")
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
	round_mode = babylon_choose_round_mode(GLOB.babylon_world.kind, babylon_state_round_started(saved_state()))
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
		return
	SSticker.start_immediately = FALSE
	SSticker.SetTimeLeft(-1)
	round_started_by = null
	SStitle.show_title_screen()

/// The round waits for its owner: pre-round, no start requested.
/proc/babylon_round_on_hold()
	var/datum/babylon_save/session = GLOB.babylon_save
	return session?.round_mode == "hold" && SSticker.current_state <= GAME_STATE_PREGAME && !SSticker.start_immediately && SSticker.GetTimeLeft() < 0

/// The world owner's key when connected, else their ckey.
/proc/babylon_world_owner_name()
	var/owner = GLOB.babylon_world.owner_ckey
	var/client/owner_client = GLOB.directory[owner]
	return owner_client?.key || owner || "the world's owner"

/proc/babylon_round_status_text()
	return "Waiting for [babylon_world_owner_name()] to start the round"

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
		to_chat(player, span_warning("The round is already starting."))
		return FALSE
	log_game("[key_name(player)] started the round.")
	return GLOB.babylon_save.begin_round(player.key)

/datum/babylon_save/proc/begin_round(starter)
	if(round_mode != "hold" || !babylon_round_on_hold() || SSticker.current_state != GAME_STATE_PREGAME)
		return FALSE
	round_started_by = starter
	SSticker.start_immediately = TRUE
	to_chat(world, span_boldannounce("[html_encode(starter)] started the round."))
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
.container_nav hr{background-color:#34465e !important;box-shadow:none !important}
.menu_button{color:#e3eaf4 !important;font-family:'Segoe UI',Arial,sans-serif !important;font-weight:600 !important;letter-spacing:.5px !important;text-shadow:1px 1px #000 !important}
.menu_button:hover{color:#7dd3c7 !important}
.checked{color:#9be7be !important}
.unchecked{color:#ffc2c7 !important}
.menu_notice{font-family:'Segoe UI',Arial,sans-serif !important;color:#ffe1a0 !important}
.babylon_brand{font:700 1.6vmin 'Segoe UI',Arial,sans-serif;letter-spacing:3px;color:#7dd3c7;text-align:left;padding-left:5vmin;margin-bottom:.8vmin}
.babylon_round_status{font:600 2.6vmin 'Segoe UI',Arial,sans-serif;color:#ffe1a0;text-align:left;padding-left:5vmin;margin:0 0 1vmin 0}
.menu_button.babylon_start_round{background:#256d66 !important;border:1px solid #6bcdc1;border-radius:6px;color:#fff !important;height:5vmin;line-height:5vmin;margin-bottom:1vmin}
.menu_button.babylon_start_round:hover{background:#2d7f77 !important;color:#fff !important}
</style>"}

/// What Babylon adds to the top of the menu for this player: the round's status and, for the
/// owner and administrators, the Start round button.
/proc/babylon_title_additions(client/player, menu_ref)
	. = {"<div class="babylon_brand">BABYLON13</div>"}
	if(!babylon_round_on_hold())
		return
	. += {"<p class="babylon_round_status">[html_encode(babylon_round_status_text())]</p>"}
	if(babylon_may_start_round(player))
		. += {"<a class="menu_button babylon_start_round" href='byond://?src=[menu_ref];babylon_start_round=1'>START ROUND</a>"}

/mob/dead/new_player/get_title_html()
	. = ..()
	. = replacetext(., {"<div class="container_nav">"}, {"[BABYLON_TITLE_STYLE]<div class="container_nav">[babylon_title_additions(client, text_ref(src))]"})

/mob/dead/new_player/Topic(href, href_list)
	if(href_list["babylon_start_round"])
		if(src != usr || !client)
			return
		play_lobby_button_sound()
		if(babylon_start_round(src))
			SStitle.show_title_screen()
		return
	return ..()

/mob/dead/new_player/Login()
	. = ..()
	// Visitors and spectating admins leave the menu at once (showcase.dm, spectator.dm).
	if(!client || client.babylon_showcase_visitor || client.babylon_admin_spectator)
		return
	if(babylon_round_on_hold())
		if(babylon_may_start_round(client))
			to_chat(src, span_notice("This round starts when you press <b>Start round</b> in the menu. Set up your character first."))
		else
			to_chat(src, span_notice("[babylon_round_status_text()]. Set up your character in the meantime."))
	else if(GLOB.babylon_save.round_mode == "resume" && SSticker.HasRoundStarted())
		INVOKE_ASYNC(GLOB.babylon_save, TYPE_PROC_REF(/datum/babylon_save, return_to_resumed_round), client)

/datum/babylon_save/proc/return_to_resumed_round(client/player)
	if(!player || player.babylon_showcase_visitor || player.babylon_admin_spectator)
		return
	var/mob/dead/new_player/menu = player.mob
	if(!istype(menu))
		return
	if(reattach_saved_character(player))
		menu.hide_title_screen()
		return
	// No saved body: the normal late-join menu (the title screen's JOIN GAME).

/// Puts a returning player into the character they had when this world was saved (Task D2).
/// TRUE when the client now controls that character.
/datum/babylon_save/proc/reattach_saved_character(client/player)
	return FALSE

/mob/dead/get_status_tab_items()
	. = ..()
	if(!babylon_round_on_hold())
		return
	var/list/items = .
	for(var/index in 1 to length(items))
		if(istext(items[index]) && findtext(items[index], "Time To Start:") == 1)
			items[index] = babylon_round_status_text()

/atom/movable/screen/lobby/new_player_info/time_remaining_str()
	if(babylon_round_on_hold())
		return "Waiting for the owner"
	return ..()

/client/proc/babylon_start_round_verb()
	set name = "Start round"
	set category = "Babylon"
	set desc = "Start this world's round."
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
	if(length(seats))
		SSjob.latejoin_trackers += seats
		latejoin_source = "arrivals chairs"
	else if(length(floors))
		SSjob.latejoin_trackers += floors
		latejoin_source = "arrivals floor"
	else if(respawn_turf)
		SSjob.latejoin_trackers += respawn_turf
		latejoin_source = "observer start"

// --- Tutorials -----------------------------------------------------------------------------

/// Where a tutorial player starts. Task F3 replaces this with the tutorial's start marker; until
/// then (and when a tutorial has none) it is a late-join spawn point.
/proc/babylon_tutorial_start_turf()
	if(length(SSjob.latejoin_trackers))
		return get_turf(pick(SSjob.latejoin_trackers))
	return GLOB.babylon_save.respawn_turf

/datum/babylon_save/tick_world()
	. = ..()
	if(draining)
		return
	for(var/client/player in GLOB.clients)
		if(!babylon_ready_client(player))
			continue
		player.babylon_update_start_verb()
		if(round_mode == "auto" && SSticker.current_state == GAME_STATE_PLAYING && istype(player.mob, /mob/dead/new_player) && !player.babylon_showcase_visitor && !player.babylon_admin_spectator && !(player.ckey in tutorial_spawning))
			INVOKE_ASYNC(src, PROC_REF(spawn_tutorial_player), player)

/// Tutorial worlds: the player plays their preferences character as an Assistant.
/datum/babylon_save/proc/spawn_tutorial_player(client/player)
	var/player_key = player.ckey
	tutorial_spawning += player_key
	var/mob/dead/new_player/menu = player.mob
	if(istype(menu) && menu.AttemptLateSpawn(JOB_ASSISTANT))
		var/mob/living/character = player?.mob
		var/turf/start = babylon_tutorial_start_turf()
		if(isliving(character) && start)
			character.buckled?.unbuckle_mob(character, TRUE)
			character.forceMove(start)
	tutorial_spawning -= player_key

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
	if(world.params["babylon-api"] && !babylon_supervisor_request(list("action" = "round_ended"))?["ok"])
		log_world("Babylon: the supervisor did not confirm the round's end; it sees the exit as a stop.")
	to_chat(world, span_boldannounce("The round is over. Returning to the lobby…"))
	if(delay > 0)
		to_chat(world, span_notice("The round-end report stays open for [DisplayTimeText(delay)]. This world is not saved again: its next start resumes the last autosave from before the round ended."))
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
		reboot_hud.maptext = MAPTEXT_PIXELLARI("<center>Return to the lobby\n DELAYED</center>")
	else
		reboot_hud.maptext = MAPTEXT_PIXELLARI("<center>Returning to the lobby in:\n [DisplayTimeText(max(0, session.round_end_at - world.time), 1)]</center>")

#undef BABYLON_TITLE_STYLE
#undef BABYLON_ROUND_END_DELAY_MAX
