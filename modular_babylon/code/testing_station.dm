// Authenticated integration tests for babylon-station.dmb only (babylon-station-test.dme),
// asserted from services/supervisor/smoke_station.py. Every check must be TRUE.

/// The world flags come from the supervisor's start parameters (world_flags.dm).
/datum/babylon_save/proc/test_station_world_flags()
	var/list/result = list()
	var/datum/babylon_world/flags = GLOB.babylon_world
	result["station_build"] = babylon_is_station_build() && flags.build == "station"
	result["map_from_params"] = !!flags.map_id && flags.map_id == world.params["babylon-map"]
	result["persistent_from_params"] = flags.persistent == (world.params["babylon-persistent"] != "0")
	result["creative_from_params"] = flags.creative == (world.params["babylon-creative"] == "1") && babylon_creative_enabled() == flags.creative
	result["kind_from_params"] = flags.kind == (world.params["babylon-kind"] || "world")
	result["owner_from_params"] = flags.owner_ckey == ckey(world.params["babylon-owner"]) && owner_ckey == flags.owner_ckey
	result["unsafe_ids_rejected"] = !babylon_safe_id("../x") && !babylon_safe_id("") && babylon_safe_id("creative_plane_m")
	result["ready"] = babylon_world_ready() && ready
	result["map_loaded"] = SSmapping.current_map?.map_name == "MetaStation" || flags.map_id != "metastation"
	// The Babylon rules (rules.dm) are not compiled in: normal tg rounds.
	result["events_fire"] = !(SSevents.ss_flags & SS_NO_FIRE) && !(SSgamemode.ss_flags & SS_NO_FIRE)
	result["several_levels"] = world.maxz > 1
	result["saving_unavailable"] = !!save_world()["error"]
	return result

/// Station worlds run SPLURT's storytellers without a vote; Creative Plane and tutorials do not.
/datum/babylon_save/proc/test_station_storyteller()
	var/list/result = list()
	var/datum/babylon_world/flags = GLOB.babylon_world
	result["not_inert_on_a_station_map"] = !babylon_storyteller_inert()
	var/chosen = babylon_world_storyteller()
	result["storyteller_not_babylon"] = chosen != /datum/storyteller/babylon && SSgamemode.voted_storyteller == chosen
	result["running_storyteller_not_babylon"] = SSgamemode.storyteller?.type != /datum/storyteller/babylon
	if(!CONFIG_GET(string/default_storyteller))
		result["fallback_without_config"] = chosen == /datum/storyteller/default
	result["vote_refused"] = !SSvote.initiate_vote(/datum/vote/storyteller, "Babylon test", forced = TRUE)
	result["no_vote_running"] = !istype(SSvote.current_vote, /datum/vote/storyteller)
	var/old_map = flags.map_id
	flags.map_id = "creative_plane_m"
	result["creative_plane_inert"] = babylon_storyteller_inert() && babylon_world_storyteller() == /datum/storyteller/babylon
	flags.map_id = old_map
	var/old_kind = flags.kind
	flags.kind = "tutorial"
	result["tutorial_inert"] = babylon_storyteller_inert()
	flags.kind = "tutorial_edit"
	result["tutorial_edit_inert"] = babylon_storyteller_inert()
	flags.kind = old_kind
	result["flags_restored"] = !babylon_storyteller_inert()
	return result

/// The save engine's per-level step in the station format (persistence.dm save_level()):
/// every record and turf carries its level's z. Station saves stay refused (Task D1).
/datum/babylon_save/proc/test_station_save_level()
	var/list/result = list()
	var/list/levels = persisted_levels()
	result["station_levels_persisted"] = length(levels) && (station_z in levels)
	result["station_format"] = save_format_version() == BABYLON_STATION_STATE_VERSION && level_file(station_z) == "z[station_z].dmm"
	var/list/level = save_level(station_z)
	result["map_text"] = findtext(level["map_text"], "//[DMM2TGM_MESSAGE]") == 1
	var/list/records = level["records"]
	var/list/turfs = level["turfs"]
	result["records"] = length(records) > 0
	result["turfs"] = length(turfs) > 0
	var/all_z = TRUE
	for(var/list/record as anything in records + turfs)
		if(record["z"] != station_z)
			all_z = FALSE
			break
	result["records_and_turfs_carry_z"] = all_z
	return result

/// Facts about the running station world for the smoke report (not asserted).
/datum/babylon_save/proc/test_station_info()
	var/list/result = list()
	result["map_name"] = SSmapping.current_map?.map_name
	result["levels"] = world.maxz
	result["ticker_state"] = SSticker.current_state
	result["storyteller"] = "[SSgamemode.storyteller?.type || SSgamemode.voted_storyteller]"
	result["emergency_shuttle"] = !!SSshuttle.emergency
	result["arrivals_shuttle"] = !!SSshuttle.arrivals
	result["latejoin_spawns"] = length(SSjob.latejoin_trackers)
	result["respawn_turf"] = !!respawn_turf
	result["latejoin_source"] = latejoin_source
	result["round_mode"] = round_mode
	result["round_started_by"] = round_started_by
	return result

/// Late-joiners arrive on the station (station_round.dm), not in tg's last-resort spawn.
/datum/babylon_save/proc/test_station_latejoin()
	var/list/result = list()
	result["latejoin_points"] = length(SSjob.latejoin_trackers) || length(SSjob.latejoin_override_trackers)
	result["source_known"] = latejoin_source in list("map", "arrivals chairs", "arrivals chairs and floor", "arrivals floor", "observer start")
	// A few seats are padded with the hallway's free floor, so a group does not share one bench.
	result["enough_arrival_points"] = length(SSjob.latejoin_trackers) >= 4 || latejoin_source == "observer start"
	var/datum/job/assistant = SSjob.get_job_type(/datum/job/assistant)
	var/atom/arrival = assistant.get_latejoin_spawn_point()
	var/turf/arrival_turf = get_turf(arrival)
	result["assistant_arrives_on_station"] = !!arrival_turf && is_station_level(arrival_turf.z)
	result["not_the_error_room"] = !!arrival_turf && !istype(get_area(arrival_turf), /area/misc/testroom)
	var/turf/tutorial_start = babylon_tutorial_start_turf()
	result["tutorial_start_fallback"] = isturf(tutorial_start) && is_station_level(tutorial_start.z)
	return result

/// Ordinary worlds hold the round for their owner: no countdown, Start round only for the owner
/// and administrators. Ends by starting the round as the owner would (the smoke waits for it).
/datum/babylon_save/proc/test_round_hold_and_owner_start()
	var/list/result = list()
	var/owner = GLOB.babylon_world.owner_ckey
	result["mode_hold"] = round_mode == "hold"
	result["pre_round"] = SSticker.current_state == GAME_STATE_PREGAME
	result["no_countdown"] = SSticker.GetTimeLeft() < 0 && SSticker.start_at < 0 && !SSticker.start_immediately
	result["on_hold"] = babylon_round_on_hold()
	// Nobody is connected: others are told that the owner is away, never "waiting for" a ghost.
	result["status_owner_offline"] = findtext(babylon_round_status_text(), "[owner] is offline. Only they or an admin can start this round; you can OBSERVE or return to the lobby.") == 1
	var/menu = babylon_title_additions(null, "menuref")
	result["menu_shows_status"] = !!findtext(menu, "is offline") && !!findtext(menu, "BABYLON13")
	result["menu_hides_button_from_others"] = !findtext(menu, "babylon_start_round")
	result["menu_moves_up_while_held"] = !!findtext(menu, "calc(50% + 15vmin)")
	result["style_hides_logo_and_emoji"] = !!findtext(babylon_title_style(), ".container_logo{display:none") && !!findtext(babylon_title_style(), "::before")
	result["ready_counts_are_a_pair"] = length(babylon_ready_counts()) == 2
	var/mob/dead/new_player/fake_player = new
	var/list/before = babylon_ready_counts()
	result["ready_starter_marked"] = mark_starter_ready(fake_player) && fake_player.ready == PLAYER_READY_TO_PLAY
	var/list/after = babylon_ready_counts()
	result["ready_counter_ignores_clientless"] = after[1] == before[1] && after[2] == before[2]
	result["observer_not_marked"] = !mark_starter_ready(null) && !mark_starter_ready(new /obj/item)
	qdel(fake_player)
	result["owner_status_text"] = babylon_round_status_for(TRUE, TRUE, "Owner Key") == "You start this round. Press START ROUND when everyone is ready."
	result["member_status_owner_online"] = babylon_round_status_for(FALSE, TRUE, "Owner Key") == "Waiting for Owner Key to start the round. Tick READY to get a job when it starts."
	result["member_status_owner_offline"] = babylon_round_status_for(FALSE, FALSE, "Owner Key") == "Owner Key is offline. Only they or an admin can start this round; you can OBSERVE or return to the lobby."
	result["owner_key_not_empty"] = !!babylon_world_owner_name()
	result["next_start_fresh_without_saving"] = !babylon_station_saving_available() && babylon_next_start_text() == "Next time this world starts, it begins a fresh round." && !babylon_next_start_text(TRUE)
	result["next_start_fresh_when_not_persistent"] = babylon_next_start_message(FALSE, FALSE) == "Next time this world starts, it begins a fresh round."
	result["next_start_resume_for_owner_only"] = !babylon_next_start_message(TRUE, FALSE) && !!findtext(babylon_next_start_message(TRUE, TRUE), "picks up from its last autosave before the round ended. To begin fresh, reset or roll back the world in the lobby.")
	result["owner_may_start"] = babylon_round_starter_allowed(owner, "owner", FALSE, FALSE)
	result["admin_may_start"] = babylon_round_starter_allowed("someadmin", "admin", FALSE, FALSE) && babylon_round_starter_allowed("serveradmin", "guest", TRUE, FALSE)
	result["member_may_not"] = !babylon_round_starter_allowed("somemember", "member", FALSE, FALSE)
	result["guest_may_not"] = !babylon_round_starter_allowed("someguest", "guest", FALSE, FALSE)
	result["visitor_may_not"] = !babylon_round_starter_allowed(owner, "owner", FALSE, TRUE)
	result["nobody_may_not"] = !babylon_round_starter_allowed(null, "admin", TRUE, FALSE)
	result["clientless_start_refused"] = !babylon_start_round(null) && babylon_round_on_hold()
	// Tutorials start at once, resumed rounds too; Creative Plane worlds keep the owner's hold.
	result["tutorial_starts_at_once"] = babylon_choose_round_mode("tutorial", FALSE) == "auto" && babylon_choose_round_mode("tutorial_edit", FALSE) == "auto"
	result["world_kind_holds"] = babylon_choose_round_mode("world", FALSE) == "hold"
	result["saved_round_resumes"] = babylon_choose_round_mode("world", TRUE) == "resume" && babylon_choose_round_mode("tutorial", TRUE) == "resume"
	result["saved_round_flag_read_defensively"] = babylon_state_round_started(list("round" = list("started" = TRUE))) \
		&& !babylon_state_round_started(null) && !babylon_state_round_started(list()) \
		&& !babylon_state_round_started(list("round" = "yes")) && !babylon_state_round_started(list("round" = list("started" = FALSE))) \
		&& !babylon_state_round_started(list("round" = list()))
	result["fresh_world_not_resumed"] = !babylon_state_round_started(saved_state())
	result["assignment_kept_when_held"] = !babylon_skip_roundstart_assignment()
	round_mode = "resume"
	result["resume_skips_assignment"] = babylon_skip_roundstart_assignment()
	round_mode = "auto"
	result["tutorial_skips_assignment"] = babylon_skip_roundstart_assignment()
	round_mode = "hold"
	result["no_saved_character_yet"] = reattach_saved_character(null) == FALSE
	result["owner_start"] = begin_round("Babylon smoke") && SSticker.start_immediately && round_started_by == "Babylon smoke"
	result["no_second_start"] = !begin_round("Babylon smoke again") && !babylon_round_on_hold()
	return result

/// The round has started; ending it returns everyone to the lobby and stops the world without
/// a save. Triggers the end (a short report delay); the smoke asserts the exit and the stop.
/datum/babylon_save/proc/test_round_end_no_save()
	var/list/result = list()
	result["round_running"] = SSticker.current_state == GAME_STATE_PLAYING && SSticker.HasRoundStarted()
	result["started_by_owner_button"] = round_started_by == "Babylon smoke"
	result["no_roundstart_job_without_players"] = !length(GLOB.joined_player_list)
	result["report_delay_capped"] = round_end_delay() > 0 && round_end_delay() <= 60 SECONDS
	result["not_ending_yet"] = !round_ending && !draining
	round_ending = TRUE
	result["no_save_after_the_end"] = !!findtext(save_world()["error"], "round is over")
	round_ending = FALSE
	round_end_delay_override = 5 SECONDS
	SSticker.force_ending = ADMIN_FORCE_END_ROUND
	result["end_requested"] = TRUE
	return result

/// Tutorial worlds start their round without the owner and without roundstart assignment.
/datum/babylon_save/proc/test_tutorial_round()
	var/list/result = list()
	result["tutorial_kind"] = GLOB.babylon_world.is_tutorial()
	result["mode_auto"] = round_mode == "auto"
	result["started_without_owner"] = SSticker.current_state == GAME_STATE_PLAYING && !round_started_by
	result["not_on_hold"] = !babylon_round_on_hold()
	result["no_start_button"] = !findtext(babylon_title_additions(null, "menuref"), "babylon_start_round")
	result["skips_roundstart_assignment"] = babylon_skip_roundstart_assignment()
	result["inert_storyteller"] = babylon_storyteller_inert() && SSgamemode.storyteller?.type == /datum/storyteller/babylon
	var/turf/start = babylon_tutorial_start_turf()
	result["start_turf"] = isturf(start)
	// A failed setup here is reported (status error) instead of a silent startup timeout.
	round_setup_failed()
	result["setup_failure_reported"] = !!boot_error
	result["setup_failure_text"] = boot_error == "This world's round could not start. Try starting it again; if it keeps failing, tell an admin."
	boot_error = null
	result["menu_says_starting"] = !!findtext(babylon_title_additions(null, "menuref"), "Starting your tutorial")
	result["refresh_all_is_safe_in_a_running_round"] = isnull(babylon_refresh_starter_titles(TRUE))
	return result
