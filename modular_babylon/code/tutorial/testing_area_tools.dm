// Area tool tests (both test builds; services/supervisor/smoke_native.py and smoke_station.py).
// Each test works in a 24×8 rectangle next to the world's respawn point: a setup session clears
// it first and its Undo puts the rectangle back at the end.

/// The test rectangle: list(x1, y1, x2, y2, z).
/datum/babylon_save/proc/area_test_rect()
	var/turf/origin = respawn_turf || locate(round(world.maxx / 2), round(world.maxy / 2), station_z || 1)
	var/x1 = clamp(origin.x - 12, 2, world.maxx - 25)
	var/y1 = clamp(origin.y - 10, 2, world.maxy - 9)
	return list(x1, y1, x1 + 23, y1 + 7, origin.z)

/// A test session without the 2 second limit (a fresh one for every name).
/proc/babylon_area_test_session(name)
	var/key = "areatest_[name]"
	GLOB.babylon_area_sessions -= key
	var/datum/babylon_area_session/session = babylon_area_session(key)
	session.rate_limited = FALSE
	return session

/// Clears the test rectangle to plating; returns the session whose Undo restores it.
/datum/babylon_save/proc/area_test_setup(list/rect)
	var/datum/babylon_area_session/setup = babylon_area_test_session("setup")
	setup.select(rect[1], rect[2], rect[5], rect[3], rect[4], rect[5])
	setup.clear(null)
	return setup

/proc/babylon_area_test_cleanup(datum/babylon_area_session/setup, list/made)
	for(var/datum/thing as anything in made)
		if(ismob(thing) && !QDELETED(thing))
			var/mob/body = thing
			body.key = null
		if(!QDELETED(thing))
			qdel(thing)
	GLOB.babylon_area_busy = FALSE
	setup?.undo(null)
	for(var/key in GLOB.babylon_area_sessions)
		if(findtext(key, "areatest_") == 1)
			GLOB.babylon_area_sessions -= key

/// Every tile of a rectangle is of a turf type.
/proc/babylon_area_test_all(list/tiles, path)
	for(var/turf/tile as anything in tiles)
		if(tile.type != path)
			return FALSE
	return TRUE

/// Size limit, map bounds, one level, building levels, the paste footprint, indestructible
/// turfs, the rate limit and one operation at a time.
/datum/babylon_save/proc/test_area_tools_limits()
	var/list/result = list()
	var/list/rect = area_test_rect()
	var/z = rect[5]
	var/datum/babylon_area_session/setup
	var/list/made = list()
	try
		setup = area_test_setup(rect)
		var/datum/babylon_area_session/session = babylon_area_test_session("limits")
		result["over_limit_refused"] = !!findtext(session.select(1, 1, z, 101, 100, z) || "", "at most 10 000 tiles")
		result["over_limit_not_selected"] = isnull(session.selection)
		result["at_limit_accepted"] = isnull(session.select(1, 1, z, 100, 100, z)) && session.selection_width() * session.selection_height() == 10000
		result["out_of_bounds_refused"] = !!findtext(session.select(world.maxx - 2, 1, z, world.maxx + 3, 4, z) || "", "edge of the map")
		result["cross_z_refused"] = !!findtext(session.select(rect[1], rect[2], z, rect[1] + 2, rect[2] + 2, z + 1) || "", "same level")
		var/foreign = 0
		for(var/level in 1 to world.maxz)
			if(!(level in babylon_area_levels()))
				foreign = level
				break
		result["foreign_level_refused"] = !foreign || !!findtext(session.select(1, 1, foreign, 3, 3, foreign) || "", "not part of this world")
		// A click picks corner 1, the second click selects; a refused corner 2 keeps corner 1.
		session.reselect()
		session.click(locate(rect[1], rect[2], z))
		var/list/refused = session.click(locate(world.maxx, world.maxy, z))
		result["refused_corner_keeps_first"] = !refused["ok"] && session.corner && session.corner[1] == rect[1]
		session.click(locate(rect[1] + 2, rect[2] + 2, z))
		result["two_clicks_select"] = session.selection ~= list(rect[1], rect[2], rect[1] + 2, rect[2] + 2, z)
		result["copied"] = session.copy(null)["ok"]
		session.arm_paste()
		session.click(locate(world.maxx - 1, rect[2], z))
		result["paste_past_edge_refused"] = !!findtext(session.paste(null)["text"], "does not fit")
		var/turf/blocker = locate(rect[1] + 11, rect[2] + 1, z)
		blocker.ChangeTurf(/turf/closed/indestructible)
		session.click(locate(rect[1] + 10, rect[2], z))
		result["paste_over_indestructible_refused"] = !!findtext(session.paste(null)["text"], "indestructible")
		session.cancel_paste()
		session.select(rect[1] + 10, rect[2], z, rect[1] + 12, rect[2] + 2, z)
		session.fill(null, "[/turf/open/floor/iron]")
		result["fill_leaves_indestructible"] = istype(blocker, /turf/closed/indestructible) && istype(locate(rect[1] + 10, rect[2], z), /turf/open/floor/iron)
		session.clear(null)
		result["clear_leaves_indestructible"] = istype(blocker, /turf/closed/indestructible)
		blocker.ChangeTurf(/turf/open/floor/plating)
		result["unknown_material_refused"] = !session.fill(null, "[/obj/item/toy/plush]")["ok"] && !babylon_area_material("[/turf/closed/indestructible]")
		session.rate_limited = TRUE
		session.next_op = 0
		var/first = session.copy(null)["ok"]
		var/list/second = session.copy(null)
		result["rate_limited"] = first && !second["ok"] && !!findtext(second["text"], "every 2 seconds")
		session.rate_limited = FALSE
		GLOB.babylon_area_busy = TRUE
		result["one_at_a_time"] = !!findtext(session.copy(null)["text"], "still running")
		GLOB.babylon_area_busy = FALSE
	catch(var/exception/error)
		result["no_error"] = FALSE
		log_world("test_area_tools_limits failed: [error] ([error.file]:[error.line])")
	babylon_area_test_cleanup(setup, made)
	return result

/// A room with a trigger -> action link pasted twice: the copies' ids get "_2" and "_3", their
/// links and zones follow, links to objects outside stay, the original is untouched.
/datum/babylon_save/proc/test_paste_suffix_rewrites_refs()
	var/list/result = list()
	var/list/rect = area_test_rect()
	var/z = rect[5]
	var/x1 = rect[1]
	var/y1 = rect[2]
	var/datum/babylon_area_session/setup
	var/list/made = list()
	try
		setup = area_test_setup(rect)
		babylon_tutorial_test_place(/obj/babylon_tutorial/marker, locate(x1, y1 + 6, z), "area_outside", list(), made)
		var/obj/babylon_tutorial/enter = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/zone, locate(x1 + 1, y1 + 1, z), "room_enter", list("zone" = list(x1 + 1, y1 + 1, x1 + 2, y1 + 2, z), "actions" = list("room_msg", "room_point")), made)
		babylon_tutorial_test_place(/obj/babylon_tutorial/action/message, locate(x1 + 1, y1 + 1, z), "room_msg", list("text" = "Welcome to the lab, \[player]."), made)
		babylon_tutorial_test_place(/obj/babylon_tutorial/action/point, locate(x1 + 2, y1 + 1, z), "room_point", list("target" = "area_outside", "duration" = 5), made)
		babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/zone, locate(x1 + 3, y1 + 2, z), "room_next", list("starts" = "after", "after" = "room_enter", "actions" = list("room_msg")), made)
		var/datum/babylon_area_session/session = babylon_area_test_session("suffix")
		session.select(x1, y1, z, x1 + 4, y1 + 3, z)
		result["copied_tutorial"] = session.copy(null)["ok"] && length(session.clipboard.tutorial) == 4
		session.arm_paste()
		session.click(locate(x1 + 6, y1, z))
		var/list/preview = session.window_data()
		result["suffix_previewed"] = preview["paste"]["suffix"] == "_2"
		var/list/pasted = session.paste(null)
		result["pasted"] = pasted["ok"]
		var/obj/babylon_tutorial/new_enter = babylon_tutorial_find("room_enter_2")
		var/obj/babylon_tutorial/new_msg = babylon_tutorial_find("room_msg_2")
		var/obj/babylon_tutorial/new_point = babylon_tutorial_find("room_point_2")
		var/obj/babylon_tutorial/new_next = babylon_tutorial_find("room_next_2")
		result["ids_suffixed"] = !!(new_enter && new_msg && new_point && new_next)
		result["copy_at_offset"] = get_turf(new_enter) == locate(x1 + 7, y1 + 1, z)
		result["actions_rewritten"] = new_enter?.setting("actions") ~= list("room_msg_2", "room_point_2")
		result["after_rewritten"] = new_next?.setting("after") == "room_enter_2" && (new_next?.setting("actions") ~= list("room_msg_2"))
		result["outside_link_kept"] = new_point?.setting("target") == "area_outside"
		result["zone_moved"] = new_enter?.setting("zone") ~= list(x1 + 7, y1 + 1, x1 + 8, y1 + 2, z)
		result["settings_survive"] = new_msg?.setting("text") == "Welcome to the lab, \[player]."
		result["original_untouched"] = (enter.setting("actions") ~= list("room_msg", "room_point")) && get_turf(enter) == locate(x1 + 1, y1 + 1, z) && (enter.setting("zone") ~= list(x1 + 1, y1 + 1, x1 + 2, y1 + 2, z)) && babylon_tutorial_find("room_next").setting("after") == "room_enter"
		result["no_issues"] = !length(new_enter?.issues()) && !length(new_next?.issues()) && !length(new_point?.issues())
		session.click(locate(x1 + 12, y1, z))
		session.paste(null)
		result["next_paste_suffix_3"] = !!babylon_tutorial_find("room_enter_3") && babylon_tutorial_find("room_enter_3").setting("actions") ~= list("room_msg_3", "room_point_3")
		session.set_option("suffix_mode", "custom")
		session.set_option("custom_suffix", "_b")
		session.click(locate(x1 + 18, y1, z))
		var/list/custom = session.paste(null)
		if(!custom["ok"])
			result["custom paste refused: [custom["text"]]"] = FALSE
		result["custom_suffix"] = babylon_tutorial_find("room_next_b")?.setting("after") == "room_enter_b"
		session.set_option("suffix_mode", "keep")
		session.click(locate(x1 + 18, y1 + 4, z))
		result["keep_refused_when_taken"] = !!findtext(session.paste(null)["text"], "already used")
		var/ids = list()
		var/duplicates = FALSE
		for(var/obj/babylon_tutorial/object as anything in GLOB.babylon_tutorial_objects)
			if(ids[object.tutorial_id])
				duplicates = TRUE
			ids[object.tutorial_id] = TRUE
		result["no_duplicate_ids"] = !duplicates
		session.undo(null)
		result["undo_removes_paste"] = !babylon_tutorial_find("room_enter_b") && !!babylon_tutorial_find("room_enter_3")
		// Undoing a paste over tutorial objects brings them back with their ids.
		session.set_option("suffix_mode", "custom")
		session.set_option("custom_suffix", "_c")
		session.click(locate(x1 + 6, y1, z))
		session.paste(null)
		var/replaced = !babylon_tutorial_find("room_enter_2") && !!babylon_tutorial_find("room_enter_c")
		session.undo(null)
		result["undo_restores_ids"] = replaced && !babylon_tutorial_find("room_enter_c") && babylon_tutorial_find("room_enter_2")?.setting("actions") ~= list("room_msg_2", "room_point_2")
	catch(var/exception/error)
		result["no_error"] = FALSE
		log_world("test_paste_suffix_rewrites_refs failed: [error] ([error.file]:[error.line])")
	for(var/obj/babylon_tutorial/object as anything in GLOB.babylon_tutorial_objects.Copy())
		if(findtext(object.tutorial_id, "room_") == 1)
			made += object
	babylon_area_test_cleanup(setup, made)
	return result

/// Fill, Border and Clear with Undo; container contents and reagents; a player is moved, never
/// deleted; a pasted cable and pipe join their networks and pasted floors have air; the wand's
/// Select mode.
/datum/babylon_save/proc/test_area_tools_roundtrip()
	var/list/result = list()
	var/list/rect = area_test_rect()
	var/z = rect[5]
	var/x1 = rect[1]
	var/y1 = rect[2]
	var/datum/babylon_area_session/setup
	var/list/made = list()
	try
		setup = area_test_setup(rect)
		var/datum/babylon_area_session/session = babylon_area_test_session("roundtrip")
		session.select(x1, y1, z, x1 + 5, y1 + 4, z)
		var/list/room = babylon_area_tiles(x1, y1, x1 + 5, y1 + 4, z)
		var/list/edge = babylon_area_edge(x1, y1, x1 + 5, y1 + 4, z)
		result["starts_plating"] = babylon_area_test_all(room, /turf/open/floor/plating)

		session.fill(null, "[/turf/open/floor/iron]")
		result["fill_all"] = babylon_area_test_all(room, /turf/open/floor/iron)
		session.undo(null)
		result["fill_undone"] = babylon_area_test_all(room, /turf/open/floor/plating)

		var/turf/open/aired = locate(x1, y1 + 2, z)
		var/pressure_before = aired.return_air().return_pressure()
		session.fill(null, "[/turf/closed/wall]", TRUE)
		result["border_edges"] = babylon_area_test_all(edge, /turf/closed/wall) && babylon_area_test_all(room - edge, /turf/open/floor/plating)
		session.undo(null)
		result["border_undone"] = babylon_area_test_all(room, /turf/open/floor/plating)
		aired = locate(x1, y1 + 2, z)
		result["undo_restores_air"] = istype(aired) && abs(aired.return_air().return_pressure() - pressure_before) < 5
		// A floor built where there was space gets normal air, not the vacuum it replaces.
		session.fill(null, "[/turf/open/space]")
		session.fill(null, "[/turf/open/floor/iron]")
		var/turf/open/new_floor = locate(x1 + 2, y1 + 2, z)
		result["new_floor_has_air"] = istype(new_floor, /turf/open/floor/iron) && new_floor.return_air().return_pressure() > 50
		session.clear(null)

		session.fill(null, "[/obj/structure/grille]")
		var/grilles = 0
		for(var/turf/tile as anything in room)
			grilles += !!(locate(/obj/structure/grille) in tile)
		session.undo(null)
		var/left = 0
		for(var/turf/tile as anything in room)
			left += !!(locate(/obj/structure/grille) in tile)
		result["structure_fill_and_undo"] = grilles == length(room) && !left

		var/obj/item/storage/toolbox/toolbox = new(locate(x1, y1, z))
		session.set_option("only_empty", TRUE)
		session.fill(null, "[/turf/open/floor/iron]")
		result["only_empty_skips"] = istype(get_turf(toolbox), /turf/open/floor/plating) && istype(locate(x1 + 1, y1, z), /turf/open/floor/iron)
		session.undo(null)
		session.set_option("only_empty", FALSE)

		// Clear: items, a closet with a stack, a beaker of water, an NPC and a player.
		var/obj/structure/closet/closet = new(locate(x1 + 1, y1, z))
		for(var/obj/item/item in closet)
			qdel(item)
		new /obj/item/stack/sheet/iron(closet, 7)
		var/obj/item/reagent_containers/cup/beaker/beaker = new(locate(x1 + 2, y1, z))
		beaker.reagents.add_reagent(/datum/reagent/water, 15)
		var/mob/living/carbon/human/npc = new(locate(x1 + 3, y1 + 1, z))
		made += npc
		var/mob/living/carbon/human/player = new(locate(x1 + 2, y1 + 2, z))
		made += player
		player.key = "AreaTestPlayer"
		result["clear_ok"] = session.clear(null)["ok"]
		result["clear_removed_objects"] = QDELETED(toolbox) && QDELETED(closet) && QDELETED(beaker)
		result["clear_removed_npc"] = QDELETED(npc)
		result["clear_player_not_deleted"] = !QDELETED(player)
		var/turf/player_tile = get_turf(player)
		result["clear_player_moved_out"] = player_tile && !(player_tile in room) && player_tile.z == z
		result["clear_to_plating"] = babylon_area_test_all(room, /turf/open/floor/plating)
		session.undo(null)
		var/obj/structure/closet/restored_closet = locate() in locate(x1 + 1, y1, z)
		var/obj/item/stack/sheet/iron/restored_stack = restored_closet && (locate() in restored_closet)
		var/item_count = 0
		for(var/obj/item/item in restored_closet)
			item_count++
		result["undo_restores_objects"] = !!(locate(/obj/item/storage/toolbox) in locate(x1, y1, z))
		result["undo_restores_closet_contents"] = restored_stack?.amount == 7 && item_count == 1
		var/obj/item/reagent_containers/cup/beaker/restored_beaker = locate() in locate(x1 + 2, y1, z)
		result["undo_restores_reagents"] = restored_beaker?.reagents.get_reagent_amount(/datum/reagent/water) == 15
		session.clear(null)

		// Paste: a cable, a pipe and air; a player stands where the copy goes.
		var/obj/structure/cable/cable = new(locate(x1 + 1, y1 + 1, z))
		made += cable
		var/obj/machinery/atmospherics/pipe/smart/simple/general/visible/pipe = new(locate(x1 + 2, y1 + 1, z))
		made += pipe
		session.copy(null)
		player.forceMove(locate(x1 + 10, y1 + 1, z))
		session.arm_paste()
		session.click(locate(x1 + 8, y1, z))
		result["paste_ok"] = session.paste(null)["ok"]
		var/obj/structure/cable/pasted_cable = locate() in locate(x1 + 9, y1 + 1, z)
		var/obj/machinery/atmospherics/pipe/pasted_pipe = locate() in locate(x1 + 10, y1 + 1, z)
		result["paste_cable_in_powernet"] = !!pasted_cable?.powernet
		result["paste_pipe_in_pipenet"] = !!pasted_pipe?.parent
		var/turf/open/pasted_floor = locate(x1 + 11, y1 + 2, z)
		result["paste_air_sane"] = istype(pasted_floor) && pasted_floor.return_air().return_pressure() > 50
		player_tile = get_turf(player)
		result["paste_player_kept"] = !QDELETED(player) && player_tile && !(player_tile in babylon_area_tiles(x1 + 8, y1, x1 + 13, y1 + 4, z))
		session.undo(null)
		result["paste_undone"] = !(locate(/obj/structure/cable) in locate(x1 + 9, y1 + 1, z))

		// The wand: Select mode, two clicks, outlines for the holder.
		var/was_creative = GLOB.babylon_world.creative
		GLOB.babylon_world.creative = TRUE
		var/mob/living/carbon/human/builder = new(locate(x1 + 20, y1 + 6, z))
		made += builder
		var/obj/item/babylon_tutorial_wand/wand = new(get_turf(builder))
		made += wand
		builder.put_in_hands(wand)
		wand.attack_self_secondary(builder)
		var/cycled = wand.mode == "configure"
		wand.mode = "select"
		var/datum/babylon_area_session/wand_session = wand.area_session(builder)
		wand_session.reselect()
		wand.use_on(locate(x1 + 15, y1 + 1, z), builder)
		wand.use_on(locate(x1 + 18, y1 + 3, z), builder)
		result["wand_cycles_modes"] = cycled
		result["wand_selects"] = wand_session.selection ~= list(x1 + 15, y1 + 1, x1 + 18, y1 + 3, z)
		result["wand_outline"] = length(wand.area_images(wand_session)) == 4 * 3 + 1
		var/list/data = wand.ui_data(builder)
		result["wand_window_data"] = data["area"]["step"] == "selected" && data["area"]["selection"]["tiles"] == 12
		GLOB.babylon_area_sessions -= builder.ckey || REF(builder)
		GLOB.babylon_world.creative = was_creative
	catch(var/exception/error)
		result["no_error"] = FALSE
		log_world("test_area_tools_roundtrip failed: [error] ([error.file]:[error.line])")
	babylon_area_test_cleanup(setup, made)
	return result
