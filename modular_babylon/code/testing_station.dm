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
	var/real_creative = flags.creative
	flags.creative = TRUE
	var/creative_capable = babylon_tutorial_capable()
	flags.creative = FALSE
	result["tutorial_capable_with_creative"] = creative_capable && !babylon_tutorial_capable()
	flags.creative = real_creative
	result["unsafe_ids_rejected"] = !babylon_safe_id("../x") && !babylon_safe_id("") && babylon_safe_id("creative_plane_m")
	result["ready"] = babylon_world_ready() && ready
	result["map_loaded"] = SSmapping.current_map?.map_name == "MetaStation" || flags.map_id != "metastation"
	// The Babylon rules (rules.dm) are not compiled in: normal tg rounds.
	result["events_fire"] = !(SSevents.ss_flags & SS_NO_FIRE) && !(SSgamemode.ss_flags & SS_NO_FIRE)
	result["several_levels"] = world.maxz > 1
	result["saving_available"] = babylon_station_saving_available()
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
/// every record and turf carries its level's z.
/datum/babylon_save/proc/test_station_save_level()
	var/list/result = list()
	var/list/levels = persisted_levels()
	result["station_levels_persisted"] = length(levels) && (station_z in levels)
	result["station_format"] = save_format_version() == BABYLON_STATION_STATE_VERSION && level_file(station_z) == "z[station_z].dmm"
	// The test must not change the live world: ids handed out here are taken back afterwards
	// (cleared again; the counter keeps going).
	var/first_new_id = next_id
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
	var/list/handed_out = list()
	for(var/list/record as anything in records)
		if(text2num(copytext(record["id"], 3)) >= first_new_id)
			handed_out[record["id"]] = TRUE
	var/cleared = 0
	for(var/turf/tile as anything in block(1, 1, station_z, world.maxx, world.maxy, station_z))
		for(var/atom/movable/thing as anything in tile.get_all_contents() - tile)
			var/id = thing.babylon_save_id
			if(id && text2num(copytext(id, 3)) >= first_new_id)
				thing.babylon_save_id = null
				cleared++
		CHECK_TICK
	// next_id is not wound back: an atom outside the level's contents (a part kept in nullspace)
	// may hold one of the ids, and handing that id out again gave two atoms the same one, so a
	// restored machine's reference pointed at the wrong object.
	result["ids_taken_back"] = length(handed_out) && cleared >= length(handed_out)
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
	result["persisted_levels"] = persisted_levels()
	result["last_save"] = last_save_report
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
	var/resumes = babylon_world_saves() && !!last_save
	result["next_start_text_follows_saving"] = babylon_next_start_text() == babylon_next_start_message(resumes, FALSE) && babylon_next_start_text(TRUE) == babylon_next_start_message(resumes, TRUE)
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
	var/datum/babylon_world/flags = GLOB.babylon_world
	var/real_kind = flags.kind
	var/list/modes = list()
	for(var/kind in list("world", "tutorial", "tutorial_edit"))
		flags.kind = kind
		modes[kind] = babylon_choose_round_mode(flags.is_tutorial(), FALSE)
	flags.kind = real_kind
	result["tutorial_starts_at_once"] = modes["tutorial"] == "auto" && modes["tutorial_edit"] == "auto"
	result["world_kind_holds"] = modes["world"] == "hold"
	result["saved_round_resumes"] = babylon_choose_round_mode(FALSE, TRUE) == "resume" && babylon_choose_round_mode(TRUE, TRUE) == "resume"
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

/// An open, free tile near the middle of level z for a test marker, or null.
/datum/babylon_save/proc/test_marker_turf(z, list/skipped_tiles)
	var/best
	var/best_distance = INFINITY
	var/center_x = round(world.maxx / 2)
	var/center_y = round(world.maxy / 2)
	for(var/turf/open/tile in block(1, 1, z, world.maxx, world.maxy, z))
		if(isspaceturf(tile) || isopenspaceturf(tile) || tile.is_blocked_turf(TRUE) || skipped_tiles[tile] || istype(tile.loc, /area/shuttle))
			continue
		if(islava(tile) || ischasm(tile) || iswaterturf(tile))
			continue
		var/distance = abs(tile.x - center_x) + abs(tile.y - center_y)
		if(distance < best_distance)
			best = tile
			best_distance = distance
	return best

/// Multi-z save, first half (smoke_station.py runs it on icebox): markers on the station's first
/// level and on a level without the station trait, a locker emptied by hand and an animal; then a
/// real save, checked on disk. Returns the markers for test_multiz_restored() after a restart.
/datum/babylon_save/proc/test_multiz_save_roundtrip()
	var/list/result = list()
	var/list/levels = persisted_levels()
	result["several_levels"] = length(levels) > 1
	var/clean = TRUE
	var/station_level
	var/other_level
	for(var/z in levels)
		var/datum/space_level/space = SSmapping.z_list[z]
		var/list/traits = space.traits
		if(traits[ZTRAIT_CENTCOM] || traits[ZTRAIT_RESERVED])
			clean = FALSE
		if(traits[ZTRAIT_STATION])
			station_level = station_level || z
		else
			other_level = other_level || z
	result["no_centcom_or_reserved"] = clean
	result["station_level_saved"] = station_level == station_z
	result["non_station_level_saved"] = !!other_level
	var/list/skipped = checkpoint_skipped_tiles()
	var/list/markers = list()
	for(var/z in list(station_level, other_level))
		var/turf/spot = test_marker_turf(z, skipped)
		if(!spot)
			continue
		var/obj/item/paper/marker = new(spot)
		marker.name = "babylon marker z[z]"
		markers += list(list("name" = marker.name, "x" = spot.x, "y" = spot.y, "z" = spot.z))
	result["markers_placed"] = length(markers) == 2
	// Saved on the level without the station trait, moved later (below).
	var/obj/item/paper/traveller
	if(length(markers) == 2)
		var/list/other_marker = markers[2]
		traveller = new(locate(other_marker["x"], other_marker["y"], other_marker["z"]))
		traveller.name = "babylon traveller"
	var/turf/station_spot = test_marker_turf(station_level, skipped)
	// A locker fills itself the first time it opens: emptied by hand, it must stay empty after a
	// restart (contents_initialized is saved).
	var/obj/structure/closet/emcloset/locker = new(station_spot)
	locker.name = "babylon marker locker"
	var/list/lying = station_spot.contents.Copy()
	locker.dump_contents()
	var/dumped = 0
	for(var/obj/item/content in station_spot)
		if(!(content in lying))
			qdel(content)
			dumped++
	result["locker_emptied"] = dumped > 0 && locker.contents_initialized
	var/mob/living/basic/cow/cow = new(station_spot)
	cow.name = "babylon marker cow"
	cow.real_name = cow.name
	// It stays put and alive until the save (the ice moon's caves are cold and full of plasma).
	QDEL_NULL(cow.ai_controller)
	ADD_TRAIT(cow, TRAIT_GODMODE, "babylon_test")
	// A planetary tile with plasma blown onto it: the save keeps the planet's own air for it.
	var/turf/open/planet
	for(var/turf/open/tile in block(1, 1, other_level, world.maxx, world.maxy, other_level))
		if(tile.planetary_atmos && !isopenspaceturf(tile) && !tile.is_blocked_turf(TRUE) && !islava(tile) && !ischasm(tile))
			planet = tile
			break
	result["planet_tile_found"] = !!planet
	planet?.atmos_spawn_air("plasma=200;TEMP=293")
	result["planet_coords"] = planet ? json_encode(list(planet.x, planet.y, planet.z)) : "[ascii2text(91)][ascii2text(93)]"
	var/list/saved = save_world()
	result["saved"] = !!saved["ok"]
	result["first_save_captures_everything"] = saved["reused_levels"] == 0
	result["several_levels_written"] = saved["levels"] == length(levels)
	var/base = "data/babylon/saves/[saved["generation"]]"
	var/state_text = file2text("[base]/state.json")
	var/list/state = json_decode(state_text)
	result["format_version"] = state["version"] == BABYLON_STATION_STATE_VERSION
	var/list/files = list()
	var/files_exist = TRUE
	for(var/list/level as anything in state["levels"])
		files += level["file"]
		if(!fexists("[base]/[level["file"]]") || !islist(level["traits"]))
			files_exist = FALSE
	var/list/expected_files = list()
	for(var/z in levels)
		expected_files += "z[z].dmm"
	result["level_files"] = files_exist && !length(files - expected_files) && !length(expected_files - files)
	var/list/map_config = state["map_config"]
	result["map_config"] = islist(map_config) && !!map_config["map_name"]
	var/list/round_state = state["round"]
	result["round_recorded"] = islist(round_state) && round_state["started"] == (SSticker.HasRoundStarted() ? 1 : 0)
	result["characters_is_an_object"] = !!findtext(state_text, "\"characters\":{}")
	var/found = 0
	for(var/list/record as anything in state["records"])
		var/list/fields = record["fields"]
		// An empty fields object comes back from JSON as a plain list.
		if(!islist(fields) || !("name" in fields))
			continue
		for(var/list/marker as anything in markers)
			if(fields["name"] == marker["name"] && record["z"] == marker["z"] && record["x"] == marker["x"] && record["y"] == marker["y"])
				found++
	result["markers_saved_with_z"] = found == length(markers) && found
	var/animal_saved = FALSE
	for(var/list/record as anything in state["records"])
		var/list/fields = record["fields"]
		if(record["type"] == "[cow.type]" && islist(fields) && ("name" in fields) && fields["name"] == cow.name)
			animal_saved = TRUE
	result["animal_saved"] = animal_saved
	result["markers"] = json_encode(markers)
	result["station_time"] = max(1, round(SSticker.HasRoundStarted() ? STATION_TIME_PASSED() : 1))
	// Nobody connected and nothing moved: a second save reuses every level and still contains
	// the markers (checked after the restart, which loads the stop's save).
	var/list/again = save_world()
	// Something leaving a level nobody stands on (drift, a fall, a teleport) changes both levels:
	// the next save captures them, so the object is neither lost nor kept twice.
	var/turf/landing = test_marker_turf(station_level, checkpoint_skipped_tiles())
	traveller.forceMove(landing)
	var/list/moved = save_world()
	var/list/moved_state = json_decode(file2text("data/babylon/saves/[moved["generation"]]/state.json"))
	var/copies = 0
	var/copy_z
	for(var/list/record as anything in moved_state["records"])
		var/list/fields = record["fields"]
		if(islist(fields) && ("name" in fields) && fields["name"] == "babylon traveller")
			copies++
			copy_z = record["z"]
	result["moved_object_once"] = moved["ok"] && copies == 1 && copy_z == station_level
	result["both_levels_recaptured"] = moved["ok"] && moved["reused_levels"] <= length(levels) - 2
	result["traveller"] = json_encode(list(landing.x, landing.y, landing.z))
	result["unchanged_levels_reused"] = again["ok"] && again["reused_levels"] == length(levels)
	if(!result["unchanged_levels_reused"])
		var/list/causes = list()
		for(var/z_text in last_dirty_causes)
			causes += "z[z_text]: [last_dirty_causes[z_text]]"
		result["changed_by"] = "changed: [causes.Join("; ")]"
	result["reused_save_is_fast"] = again["ok"] && again["capture_ms"] < saved["capture_ms"]
	result["reuse_report"] = "full [saved["capture_ms"]] ms, reused [again["capture_ms"]] ms"
	return result

/// Multi-z save, second half: after a stop (saved) and a start from that save, the same levels
/// are back with their traits, the markers lie where they were, the emptied locker is still
/// empty, the animal is back and a started round resumed with its clock.
/datum/babylon_save/proc/test_multiz_restored(encoded_markers, saved_station_time, round_was_started, encoded_planet, encoded_traveller)
	var/list/result = list()
	var/list/state = load_resume_data()
	result["restored_from_save"] = islist(state) && babylon_restoring_saved_levels() && last_save == state["generation"]
	var/list/levels = persisted_levels()
	var/list/saved_levels = state["levels"]
	result["same_level_count"] = length(levels) == length(saved_levels)
	var/same_traits = length(levels) == length(saved_levels)
	var/same_z = TRUE
	for(var/index in 1 to min(length(levels), length(saved_levels)))
		var/list/saved_level = saved_levels[index]
		var/datum/space_level/space = SSmapping.z_list[levels[index]]
		var/list/traits = space.traits
		var/list/saved_traits = saved_level["traits"]
		for(var/trait in saved_traits | traits)
			if(!(trait in traits) || !(trait in saved_traits) || "[traits[trait]]" != "[saved_traits[trait]]")
				same_traits = FALSE
		if(saved_level["file"] != "z[levels[index]].dmm")
			same_z = FALSE
	result["same_traits"] = same_traits
	result["same_z_numbers"] = same_z
	var/list/markers = json_decode(encoded_markers)
	var/found = 0
	for(var/list/marker as anything in markers)
		var/turf/spot = locate(marker["x"], marker["y"], marker["z"])
		for(var/obj/item/paper/paper in spot)
			if(paper.name == marker["name"])
				found++
				break
	result["markers_restored"] = length(markers) == 2 && found == length(markers)
	var/travellers = 0
	var/traveller_in_place = FALSE
	var/list/landing = json_decode("[encoded_traveller]")
	for(var/obj/item/paper/paper in world)
		if(paper.name == "babylon traveller")
			travellers++
			traveller_in_place = length(landing) == 3 && paper.x == landing[1] && paper.y == landing[2] && paper.z == landing[3]
	result["moved_object_restored_once"] = travellers == 1 && traveller_in_place
	var/obj/structure/closet/emcloset/locker
	for(var/obj/structure/closet/emcloset/candidate in world)
		if(candidate.name == "babylon marker locker")
			locker = candidate
			break
	result["locker_restored"] = !!locker
	result["locker_still_empty"] = locker && locker.contents_initialized && !(locate(/obj/item) in locker.contents)
	var/cow_back = FALSE
	for(var/mob/living/basic/cow/cow in GLOB.mob_living_list)
		if(cow.name == "babylon marker cow" && (cow.z in levels))
			cow_back = TRUE
	result["animal_restored"] = cow_back
	if(!cow_back)
		var/list/names = list()
		for(var/mob/living/basic/cow/cow in GLOB.mob_living_list)
			names += "[cow.name]@[cow.x],[cow.y],[cow.z]"
		result["cows_found"] = "cows: [names.Join("; ")]"
	var/list/planet_coords = json_decode("[encoded_planet]")
	var/turf/open/planet = length(planet_coords) == 3 ? locate(planet_coords[1], planet_coords[2], planet_coords[3]) : null
	var/datum/gas_mixture/planet_air = planet?.return_air()
	result["planet_keeps_its_air"] = istype(planet) && planet.planetary_atmos && planet.initial_gas_mix == initial(planet.initial_gas_mix) && (planet_air.moles[/datum/gas/plasma] || 0) < 1
	if(text2num("[round_was_started]"))
		result["round_resumed"] = round_mode == "resume" && SSticker.HasRoundStarted()
		result["station_time_continues"] = STATION_TIME_PASSED() >= text2num("[saved_station_time]")
	else
		result["round_held"] = round_mode == "hold"
	return result

/// Diagnostics, not asserted: BYOND's profiler around one level's save step. Returns the procs
/// with the most self time as JSON text. Hands out save ids in the live world.
/datum/babylon_save/proc/test_profile_save_level(z)
	world.Profile(PROFILE_RESTART)
	var/started = REALTIMEOFDAY
	var/list/level = save_level(text2num("[z]"))
	var/elapsed = (REALTIMEOFDAY - started) * 100
	var/list/profile = json_decode(world.Profile(PROFILE_REFRESH, format = "json"))
	world.Profile(PROFILE_STOP)
	var/list/top = list()
	for(var/list/entry as anything in profile)
		if(entry["self"] > 0.2)
			top += list(list("name" = entry["name"], "self" = entry["self"], "total" = entry["total"], "calls" = entry["calls"]))
	return json_encode(list("ms" = elapsed, "records" = length(level["records"]), "procs" = top))

/// The owner's Save world is refused for 5 minutes after a save, telling how long a save pauses.
/datum/babylon_save/proc/test_manual_save_cooldown()
	var/list/result = list()
	var/real_next = next_manual_save_at
	next_manual_save_at = world.time + 3 MINUTES
	var/list/refused = request_manual_save(null)
	result["refused_while_cooling_down"] = !!findtext(refused["error"], "You can save again in about") && !!findtext(refused["error"], "pauses the world")
	next_manual_save_at = real_next
	return result

/// After a restart from a save: one APC per area, every lift call button finds its lift, and
/// (for comparison with the run before) the transports and their ids as JSON.
/datum/babylon_save/proc/test_station_links()
	var/list/result = list()
	var/list/levels = persisted_levels()
	var/list/apc_areas = list()
	var/duplicates = 0
	var/list/duplicate_names = list()
	for(var/obj/machinery/power/apc/apc as anything in SSmachines.get_machines_by_type_and_subtypes(/obj/machinery/power/apc))
		if(!(apc.z in levels) || !apc.area)
			continue
		var/key = REF(apc.area)
		if(apc_areas[key])
			duplicates++
			duplicate_names += "[apc.area.type] ([apc.x],[apc.y],[apc.z])"
		apc_areas[key] = TRUE
	result["one_apc_per_area"] = duplicates == 0
	if(duplicates)
		result["duplicate_apcs"] = "[duplicate_names.Join("; ")]"
	var/buttons = 0
	var/linked = 0
	for(var/obj/item/assembly/control/elevator/button in world)
		var/turf/button_turf = get_turf(button)
		if(!button_turf || !(button_turf.z in levels))
			continue
		buttons++
		if(button.lift_weakref?.resolve())
			linked++
	result["lift_buttons_linked"] = buttons == linked
	if(buttons != linked)
		result["unlinked_lift_buttons"] = "[buttons - linked] of [buttons]"
	var/list/transports = list()
	var/trams_have_ids = TRUE
	var/trams_positioned = TRUE
	for(var/transport_type in SStransport.transports_by_type)
		for(var/datum/transport_controller/linear/controller as anything in SStransport.transports_by_type[transport_type])
			var/list/shape = list()
			// A tram is one merged module per level: its size and the tiles it covers.
			for(var/obj/structure/transport/linear/module as anything in controller.transport_modules)
				shape += "[module.bound_width / ICON_SIZE_X]x[module.bound_height / ICON_SIZE_Y]/[length(module.locs)]"
			transports += "[transport_type]:[controller.specific_transport_id]:[length(controller.transport_modules)]:[jointext(sort_list(shape), ",")]"
			if(transport_type == TRANSPORT_TYPE_TRAM)
				var/datum/transport_controller/linear/tram/tram = controller
				if(!tram.specific_transport_id)
					trams_have_ids = FALSE
				// It starts from a platform and knows where it is (check_starting_landmark()).
				if(!tram.idle_platform || !tram.nav_beacon)
					trams_positioned = FALSE
	result["trams_have_ids"] = trams_have_ids
	result["trams_positioned"] = trams_positioned
	result["transports"] = json_encode(sort_list(transports))
	result["lift_buttons"] = "[buttons]"
	return result
