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
	GLOB.babylon_area_busy = 0
	GLOB.babylon_area_lock_owner = null
	setup?.undo(null)
	for(var/key in GLOB.babylon_area_sessions)
		if(findtext(key, "areatest_") == 1)
			GLOB.babylon_area_sessions -= key

/// Links a deck to the one above it for a test (the test maps have no multi-deck station).
/// Returns what babylon_area_test_unlink_decks() needs to undo it, or null.
/proc/babylon_area_test_link_decks(lower, upper)
	if(lower < 1 || upper != lower + 1 || length(SSmapping.multiz_levels) < upper || !islist(SSmapping.multiz_levels[lower]) || !islist(SSmapping.multiz_levels[upper]))
		return null
	var/list/saved = list(lower, upper, SSmapping.multiz_levels[lower][Z_LEVEL_UP], SSmapping.multiz_levels[upper][Z_LEVEL_DOWN])
	SSmapping.multiz_levels[lower][Z_LEVEL_UP] = TRUE
	SSmapping.multiz_levels[upper][Z_LEVEL_DOWN] = TRUE
	return saved

/proc/babylon_area_test_unlink_decks(list/saved)
	if(!saved)
		return
	SSmapping.multiz_levels[saved[1]][Z_LEVEL_UP] = saved[3]
	SSmapping.multiz_levels[saved[2]][Z_LEVEL_DOWN] = saved[4]

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
		result["over_limit_refused"] = !!findtext(session.select(1, 1, z, 101, 100, z) || "", "at most 10,000 tiles")
		result["over_limit_not_selected"] = isnull(session.selection)
		result["at_limit_accepted"] = isnull(session.select(1, 1, z, 100, 100, z)) && session.selection_width() * session.selection_height() == 10000
		result["out_of_bounds_refused"] = !!findtext(session.select(world.maxx - 2, 1, z, world.maxx + 3, 4, z) || "", "edge of the map")
		result["cross_z_refused"] = !!findtext(session.select(rect[1], rect[2], z, rect[1] + 2, rect[2] + 2, z + 1) || "", "same deck")
		var/foreign = 0
		for(var/level in 1 to world.maxz)
			if(!(level in babylon_area_levels()))
				foreign = level
				break
		result["foreign_level_refused"] = !foreign || !!findtext(session.select(1, 1, foreign, 3, 3, foreign) || "", "own decks")
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
		result["paste_over_indestructible_refused"] = !!findtext(session.paste(null)["text"], "protected tile")
		session.cancel_paste()
		session.select(rect[1] + 10, rect[2], z, rect[1] + 12, rect[2] + 2, z)
		session.fill(null, "[/turf/open/floor/iron]")
		result["fill_leaves_indestructible"] = istype(blocker, /turf/closed/indestructible) && istype(locate(rect[1] + 10, rect[2], z), /turf/open/floor/iron)
		session.clear(null)
		result["clear_leaves_indestructible"] = istype(blocker, /turf/closed/indestructible)
		// A copy never carries protected tiles or objects, nor turfs the tools can't build.
		var/turf/lava = locate(rect[1] + 12, rect[2] + 1, z)
		lava.ChangeTurf(/turf/open/lava/smooth)
		var/obj/structure/chair/guarded = new(locate(rect[1] + 10, rect[2] + 2, z))
		made += guarded
		guarded.resistance_flags |= INDESTRUCTIBLE
		session.copy(null)
		result["copy_reports_left_out"] = session.clipboard.skipped_locked == 1 && session.clipboard.skipped_protected == 1 && session.clipboard.replaced_turfs == 1
		session.arm_paste()
		session.click(locate(rect[1] + 15, rect[2], z))
		result["paste_beside_protected_ok"] = session.paste(null)["ok"]
		result["protected_tile_not_carried"] = !babylon_area_locked(locate(rect[1] + 16, rect[2] + 1, z))
		result["unbuildable_turf_becomes_plating"] = istype(locate(rect[1] + 17, rect[2] + 1, z), /turf/open/floor/plating)
		result["protected_object_not_copied"] = !(locate(/obj/structure/chair) in locate(rect[1] + 15, rect[2] + 2, z))
		session.cancel_paste()
		session.clear(null)
		result["clear_keeps_protected_object"] = !QDELETED(guarded) && get_turf(guarded) == locate(rect[1] + 10, rect[2] + 2, z)
		qdel(guarded)
		blocker.ChangeTurf(/turf/open/floor/plating)
		// A paste leaves a copied APC out where the area keeps its own APC.
		var/datum/babylon_area_clip/apc_clip = new
		apc_clip.width = 1
		apc_clip.height = 1
		apc_clip.tiles = list(list("turf" = "[/turf/open/floor/plating]", "objects" = list("[/obj/machinery/power/apc]{\n\tdir = 1\n\t}", "[/obj/structure/table]"), "space" = FALSE))
		var/apc_text = babylon_area_map_text(apc_clip, FALSE, list("0,0" = TRUE))
		result["second_apc_left_out"] = !findtext(apc_text, "/obj/machinery/power/apc") && findtext(apc_text, "/obj/structure/table")
		result["unknown_material_refused"] = !session.fill(null, "[/obj/item/toy/plush]")["ok"] && !babylon_area_material("[/turf/closed/indestructible]")
		session.rate_limited = TRUE
		session.next_op = 0
		var/first = session.copy(null)["ok"]
		var/list/second = session.copy(null)
		result["rate_limited"] = first && !second["ok"] && !!findtext(second["text"], "longer pause")
		session.rate_limited = FALSE
		GLOB.babylon_area_busy = world.time + 100
		result["one_at_a_time"] = !!findtext(session.copy(null)["text"], "still running")
		// A lock that outlived its timeout blocks nobody.
		GLOB.babylon_area_busy = world.time - 1
		result["stale_lock_ignored"] = session.copy(null)["ok"]
		// An operation that lost its (expired) lock does not release the next one's lock.
		var/datum/babylon_area_session/other = babylon_area_test_session("other")
		GLOB.babylon_area_busy = world.time + 100
		GLOB.babylon_area_lock_owner = other
		session.finish()
		result["finish_keeps_others_lock"] = babylon_area_locked_by_other() && GLOB.babylon_area_lock_owner == other
		// A running operation keeps its lock while it makes progress.
		GLOB.babylon_area_busy = world.time + 1
		babylon_area_keepalive()
		result["progress_extends_lock"] = GLOB.babylon_area_busy >= world.time + BABYLON_AREA_LOCK_TIMEOUT
		other.finish()
		result["owner_releases_lock"] = !babylon_area_locked_by_other() && !GLOB.babylon_area_lock_owner
		GLOB.babylon_area_busy = 0
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
		// An id taken in the meantime: the restored objects get a suffix instead of a duplicate.
		session.set_option("custom_suffix", "_d")
		session.click(locate(x1 + 6, y1, z))
		session.paste(null)
		babylon_tutorial_test_place(/obj/babylon_tutorial/marker, locate(x1, y1 + 7, z), "room_msg_2", list(), made)
		var/list/undone = session.undo(null)
		var/collisions = 0
		var/list/seen = list()
		for(var/obj/babylon_tutorial/object as anything in GLOB.babylon_tutorial_objects)
			if(seen[object.tutorial_id])
				collisions++
			seen[object.tutorial_id] = TRUE
		// A freed id taken inside the area, on a tile the undo leaves alone (a protected one):
		// the restored object must not duplicate it.
		var/turf/kept_tile = locate(x1 + 21, y1 + 5, z)
		kept_tile.ChangeTurf(/turf/closed/indestructible)
		babylon_tutorial_test_place(/obj/babylon_tutorial/marker, locate(x1 + 20, y1 + 5, z), "clear_mark", list(), made)
		session.select(x1 + 19, y1 + 4, z, x1 + 22, y1 + 6, z)
		session.clear(null)
		var/cleared_mark = !babylon_tutorial_find("clear_mark")
		babylon_tutorial_test_place(/obj/babylon_tutorial/marker, kept_tile, "clear_mark", list(), made)
		session.undo(null)
		var/marks = 0
		for(var/obj/babylon_tutorial/object as anything in GLOB.babylon_tutorial_objects)
			if(object.tutorial_id == "clear_mark")
				marks++
		result["undo_keeps_ids_taken_in_area"] = cleared_mark && marks == 1 && !!babylon_tutorial_find("clear_mark_2")
		kept_tile.ChangeTurf(/turf/open/floor/plating)
		result["undo_resuffixes_taken_ids"] = undone["ok"] && !collisions && !!findtext(undone["text"], "suffix") && babylon_tutorial_find("room_enter_2_2")?.setting("actions") ~= list("room_msg_2_2", "room_point_2_2")
	catch(var/exception/error)
		result["no_error"] = FALSE
		log_world("test_paste_suffix_rewrites_refs failed: [error] ([error.file]:[error.line])")
	for(var/obj/babylon_tutorial/object as anything in GLOB.babylon_tutorial_objects.Copy())
		if(findtext(object.tutorial_id, "room_") == 1 || findtext(object.tutorial_id, "clear_mark") == 1)
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
	var/list/linked_decks
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
		// The test area can border space: air rushing out would blow loose things off the area
		// while the tools pause. Anchored, test objects stay put.
		toolbox.anchored = TRUE
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
		closet.anchored = TRUE
		beaker.anchored = TRUE
		var/mob/living/carbon/human/npc = new(locate(x1 + 3, y1 + 1, z))
		made += npc
		var/mob/living/carbon/human/player = new(locate(x1 + 2, y1 + 2, z))
		made += player
		player.key = "AreaTestPlayer"
		// A ghosted player's body (a mind, no ckey), once on the floor and once in a closet.
		var/mob/living/carbon/human/ghosted = new(locate(x1 + 4, y1 + 3, z))
		made += ghosted
		ghosted.mind_initialize()
		var/obj/structure/closet/locker = new(locate(x1 + 5, y1 + 3, z))
		var/mob/living/carbon/human/stored = new(locker)
		made += stored
		stored.mind_initialize()
		// A protected item inside the closet survives the closet.
		var/obj/item/screwdriver/guarded = new(closet)
		made += guarded
		guarded.resistance_flags |= INDESTRUCTIBLE
		result["clear_ok"] = session.clear(null)["ok"]
		result["clear_removed_objects"] = !!(QDELETED(toolbox) && QDELETED(closet) && QDELETED(beaker))
		for(var/obj/survivor as anything in list(toolbox, closet, beaker))
			if(!QDELETED(survivor))
				var/turf/survivor_tile = get_turf(survivor)
				result["survivor [survivor.type] at [survivor_tile?.x],[survivor_tile?.y] in [survivor.loc?.type] (room [x1],[y1])"] = FALSE
		result["clear_removed_npc"] = QDELETED(npc)
		result["clear_player_not_deleted"] = !QDELETED(player)
		var/turf/player_tile = get_turf(player)
		result["clear_player_moved_out"] = player_tile && !(player_tile in room) && player_tile.z == z
		result["clear_keeps_ghosted_body"] = !QDELETED(ghosted) && !(get_turf(ghosted) in room)
		result["clear_keeps_body_in_closet"] = !QDELETED(stored) && !(get_turf(stored) in room)
		result["clear_to_plating"] = babylon_area_test_all(room, /turf/open/floor/plating)
		result["clear_keeps_protected_item_in_container"] = !QDELETED(guarded) && isturf(guarded.loc)
		session.undo(null)
		var/obj/structure/closet/restored_closet = locate() in locate(x1 + 1, y1, z)
		var/obj/item/stack/sheet/iron/restored_stack = restored_closet && (locate() in restored_closet)
		var/item_count = 0
		// (The protected screwdriver lay on the closet's tile, so the reloaded closet takes it in.)
		for(var/obj/item/item in restored_closet)
			if(item != guarded)
				item_count++
		result["undo_restores_objects"] = !!(locate(/obj/item/storage/toolbox) in locate(x1, y1, z))
		result["undo_restores_closet_contents"] = restored_stack?.amount == 7 && item_count == 1
		var/obj/item/reagent_containers/cup/beaker/restored_beaker = locate() in locate(x1 + 2, y1, z)
		result["undo_restores_reagents"] = restored_beaker?.reagents.get_reagent_amount(/datum/reagent/water) == 15
		if(!result["undo_restores_reagents"] || !result["undo_restores_closet_contents"])
			var/list/seen_here = list()
			for(var/turf/tile as anything in babylon_area_tiles(x1, y1, x1 + 2, y1, z))
				for(var/obj/thing in tile)
					seen_here += "[thing.type]@[tile.x - x1]"
			result["after undo: [jointext(seen_here, " ")]; closet items [item_count]; stack [restored_stack?.amount]; water [restored_beaker?.reagents?.get_reagent_amount(/datum/reagent/water)]"] = FALSE
		session.clear(null)

		// Paste: a cable, a pipe and air; a player stands where the copy goes.
		var/obj/structure/cable/cable = new(locate(x1 + 1, y1 + 1, z))
		made += cable
		// The pipe sits on the copy's west edge; at the target a pipe already waits next to it.
		var/obj/machinery/atmospherics/pipe/smart/simple/general/visible/pipe = new(locate(x1, y1 + 1, z))
		made += pipe
		var/obj/machinery/atmospherics/pipe/smart/simple/general/visible/outside = new(locate(x1 + 7, y1 + 1, z))
		made += outside
		outside.on_construction(null, outside.pipe_color, outside.piping_layer)
		// A pump on the copy's west edge, and a vent right next to where it lands: two devices
		// that share a pipenet without any pipe.
		var/obj/machinery/atmospherics/components/binary/pump/pump = new(locate(x1, y1 + 2, z), TRUE, EAST)
		made += pump
		var/obj/machinery/atmospherics/components/unary/vent_pump/vent = new(locate(x1 + 7, y1 + 2, z), TRUE, EAST)
		made += vent
		vent.on_construction(null, vent.pipe_color, vent.piping_layer)
		// A multi-deck pipe in the copy, and a built one on the next deck where it lands: the
		// pasted pipe links to it across decks, so its pipenet must be rebuilt as one.
		var/obj/machinery/atmospherics/pipe/multiz/scrubbers/visible/riser = new(locate(x1 + 1, y1 + 3, z))
		made += riser
		var/obj/machinery/atmospherics/pipe/multiz/scrubbers/visible/deck_pipe
		var/datum/pipeline/deck_net_before
		for(var/other_z in list(z + 1, z - 1))
			var/turf/deck_tile = locate(x1 + 9, y1 + 3, other_z)
			if(!deck_tile || (deck_tile.turf_flags & RESERVATION_TURF))
				continue
			linked_decks = babylon_area_test_link_decks(min(z, other_z), max(z, other_z))
			if(!linked_decks)
				continue
			deck_pipe = new(deck_tile)
			made += deck_pipe
			deck_pipe.on_construction(null, deck_pipe.pipe_color, deck_pipe.piping_layer)
			break
		result["multiz_case_built"] = !!deck_pipe
		for(var/wait in 1 to 100)
			if(!deck_pipe || deck_pipe.parent)
				break
			sleep(1)
		deck_net_before = deck_pipe?.parent
		result["multiz_deck_pipe_has_pipenet"] = !!deck_net_before
		var/failures_before = GLOB.babylon_area_link_failures
		session.copy(null)
		player.forceMove(locate(x1 + 10, y1 + 1, z))
		session.arm_paste()
		session.click(locate(x1 + 8, y1, z))
		result["paste_ok"] = session.paste(null)["ok"]
		var/obj/structure/cable/pasted_cable = locate() in locate(x1 + 9, y1 + 1, z)
		var/obj/machinery/atmospherics/pipe/pasted_pipe = locate(/obj/machinery/atmospherics/pipe/smart) in locate(x1 + 8, y1 + 1, z)
		var/obj/machinery/atmospherics/pipe/multiz/pasted_riser = locate() in locate(x1 + 9, y1 + 3, z)
		result["paste_cable_in_powernet"] = !!pasted_cable?.powernet
		// One live pipenet across the paste edge once the air subsystem rebuilt it.
		for(var/wait in 1 to 100)
			if(!length(SSair.rebuild_queue) && !length(SSair.expansion_queue) && pasted_pipe?.parent && vent.parents[1] && (!deck_pipe || (pasted_riser?.parent && deck_pipe.parent)))
				break
			sleep(1)
		var/datum/pipeline/net = pasted_pipe?.parent
		result["paste_pipe_in_pipenet"] = !!net && !QDELETED(net) && (net in SSair.networks)
		result["paste_edge_one_pipenet"] = !!net && outside.parent == net
		var/consistent = !!net
		for(var/obj/machinery/atmospherics/pipe/member as anything in net?.members)
			if(member.parent != net)
				consistent = FALSE
		result["paste_pipenet_consistent"] = consistent
		var/leaked = 0
		for(var/datum/pipeline/other_net as anything in SSair.networks)
			if(other_net != net && ((pasted_pipe in other_net.members) || (outside in other_net.members)))
				leaked++
		result["paste_no_leaked_pipenet"] = !leaked
		result["paste_edge_no_link_errors"] = GLOB.babylon_area_link_failures == failures_before
		var/obj/machinery/atmospherics/components/binary/pump/pasted_pump = locate() in locate(x1 + 8, y1 + 2, z)
		var/datum/pipeline/device_net = vent.parents[1]
		result["paste_pump_joins_vent"] = !!pasted_pump && !!device_net && !QDELETED(device_net) && (device_net in pasted_pump.parents)
		// The pasted multi-deck pipe and the one on the next deck: linked both ways, one live
		// pipeline, each in exactly one, and the deck pipe's old pipeline is gone.
		if(deck_pipe)
			result["multiz_pasted"] = !!pasted_riser
			result["multiz_link_two_way"] = !!pasted_riser && (deck_pipe in pasted_riser.nodes) && (pasted_riser in deck_pipe.nodes)
			var/datum/pipeline/deck_net = deck_pipe.parent
			result["multiz_one_live_pipeline"] = !!deck_net && !QDELETED(deck_net) && (deck_net in SSair.networks) && pasted_riser?.parent == deck_net
			var/riser_nets = 0
			var/deck_nets = 0
			for(var/datum/pipeline/any_net as anything in SSair.networks)
				if(pasted_riser && (pasted_riser in any_net.members))
					riser_nets++
				if(deck_pipe in any_net.members)
					deck_nets++
			result["multiz_each_in_one_pipeline"] = riser_nets == 1 && deck_nets == 1
			result["multiz_no_stale_pipeline"] = !!deck_net_before && deck_net != deck_net_before && !!(QDELETED(deck_net_before) || !(deck_net_before in SSair.networks))
			if(!result["multiz_each_in_one_pipeline"] || !result["multiz_no_stale_pipeline"] || !result["multiz_link_two_way"])
				result["multiz details: riser nets [riser_nets], deck nets [deck_nets], old net deleted [QDELETED(deck_net_before)], riser nodes [jointext(pasted_riser?.nodes || list(), " ")], deck nodes [jointext(deck_pipe.nodes, " ")]"] = FALSE
		var/turf/open/pasted_floor = locate(x1 + 11, y1 + 2, z)
		result["paste_air_sane"] = istype(pasted_floor) && pasted_floor.return_air().return_pressure() > 50
		player_tile = get_turf(player)
		result["paste_player_kept"] = !QDELETED(player) && player_tile && !(player_tile in babylon_area_tiles(x1 + 8, y1, x1 + 13, y1 + 4, z))
		session.undo(null)
		result["paste_undone"] = !(locate(/obj/structure/cable) in locate(x1 + 9, y1 + 1, z))
		result["no_one_way_pipes"] = !babylon_area_one_way_nodes(list(x1 + 8, y1, x1 + 13, y1 + 4, z))
		if(deck_pipe)
			result["multiz_undo_unlinks"] = !QDELETED(deck_pipe) && !(pasted_riser in deck_pipe.nodes) && GLOB.babylon_area_link_failures == failures_before
		babylon_area_test_unlink_decks(linked_decks)
		linked_decks = null
		// Clear to a wall material: a player in the area ends up beside it, not inside a wall.
		session.set_option("material", "[/turf/closed/wall]")
		session.set_option("clear_to", "material")
		player.forceMove(locate(x1 + 3, y1 + 2, z))
		session.clear(null)
		player_tile = get_turf(player)
		result["clear_to_wall_moves_player"] = !QDELETED(player) && !isclosedturf(player_tile) && !(player_tile in room)
		session.undo(null)
		session.set_option("clear_to", "plating")
		// A player with no free tile to go to (the rectangle they are moved out of lies on a deck
		// that does not exist): Clear and Fill to a wall leave their tile open, and a pasted wall
		// they stand in becomes plating.
		var/turf/stuck_tile = locate(x1 + 3, y1 + 2, z)
		player.forceMove(stuck_tile)
		var/list/nowhere = list(x1 + 3, y1 + 2, x1 + 3, y1 + 2, world.maxz + 1)
		var/list/stuck_clear = babylon_area_clear_tiles(list(stuck_tile), nowhere, /turf/closed/wall)
		stuck_tile = locate(x1 + 3, y1 + 2, z)
		result["clear_keeps_occupied_tile_open"] = stuck_clear["occupied"] == 1 && !isclosedturf(stuck_tile) && get_turf(player) == stuck_tile && !QDELETED(player)
		var/list/stuck_journal = list("turfs" = list(), "made" = list())
		var/list/stuck_fill = babylon_area_put(list(stuck_tile), /turf/closed/wall, FALSE, nowhere, stuck_journal)
		stuck_tile = locate(x1 + 3, y1 + 2, z)
		result["fill_keeps_occupied_tile_open"] = stuck_fill["occupied"] == 1 && !isclosedturf(stuck_tile) && get_turf(player) == stuck_tile
		babylon_area_change_turf(stuck_tile, /turf/closed/wall, NONE)
		babylon_area_rescue(list(x1 + 3, y1 + 2, x1 + 3, y1 + 2, z), nowhere)
		stuck_tile = locate(x1 + 3, y1 + 2, z)
		result["rescue_opens_wall_on_stuck_player"] = !isclosedturf(stuck_tile) && get_turf(player) == stuck_tile && !QDELETED(player)
		babylon_area_change_turf(stuck_tile, /turf/open/floor/plating, NONE)

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
	babylon_area_test_unlink_decks(linked_decks)
	babylon_area_test_cleanup(setup, made)
	return result

/// Copy and paste keep what a save keeps: a creative canister's settings (extra_fields), a door
/// button's link to its blast door (map link fields), and they leave out what a save leaves out
/// (babylon_skip_save()).
/datum/babylon_save/proc/test_area_tools_copy_settings()
	var/list/result = list()
	var/list/rect = area_test_rect()
	var/z = rect[5]
	var/x1 = rect[1]
	var/y1 = rect[2]
	var/datum/babylon_area_session/setup
	var/list/made = list()
	var/link_id = "babylon_clip_test"
	try
		setup = area_test_setup(rect)
		var/obj/machinery/portable_atmospherics/canister/babylon_creative/canister = new(locate(x1, y1, z))
		made += canister
		canister.set_creative_settings("source", /datum/gas/nitrogen, 2345)
		canister.anchored = TRUE
		var/obj/machinery/button/door/button = new(locate(x1 + 1, y1, z))
		made += button
		button.id = link_id
		var/obj/machinery/door/poddoor/blast_door = new(locate(x1 + 2, y1, z))
		made += blast_door
		blast_door.id = link_id
		var/obj/item/babylon_test_unsaved/unsaved = new(locate(x1 + 3, y1, z))
		made += unsaved
		unsaved.anchored = TRUE
		result["unsaved_prop_opts_out"] = unsaved.babylon_skip_save()

		var/datum/babylon_area_session/session = babylon_area_test_session("copy_settings")
		session.select(x1, y1, z, x1 + 3, y1, z)
		session.copy(null)
		session.arm_paste()
		session.click(locate(x1 + 8, y1 + 2, z))
		result["paste_ok"] = session.paste(null)["ok"]
		var/obj/machinery/portable_atmospherics/canister/babylon_creative/pasted_canister = locate() in locate(x1 + 8, y1 + 2, z)
		result["canister_settings_kept"] = !!pasted_canister && pasted_canister.creative_mode == "source" \
			&& pasted_canister.creative_gas == /datum/gas/nitrogen && pasted_canister.creative_pressure == 2345
		var/obj/machinery/button/door/pasted_button = locate() in locate(x1 + 9, y1 + 2, z)
		var/obj/item/assembly/control/control = pasted_button?.device
		result["button_link_kept"] = pasted_button?.id == link_id && istype(control) && control.id == link_id
		var/obj/machinery/door/poddoor/pasted_door = locate() in locate(x1 + 10, y1 + 2, z)
		result["door_link_kept"] = pasted_door?.id == link_id
		result["skipped_atom_not_copied"] = !(locate(/obj/item/babylon_test_unsaved) in locate(x1 + 11, y1 + 2, z)) && !QDELETED(unsaved)
		if(pasted_canister)
			pasted_canister.air_contents.remove(pasted_canister.air_contents.total_moles())
		session.undo(null)
	catch(var/exception/error)
		result["no_error"] = FALSE
		log_world("test_area_tools_copy_settings failed: [error] ([error.file]:[error.line])")
	for(var/obj/machinery/portable_atmospherics/portable in made)
		if(!QDELETED(portable))
			portable.air_contents.remove(portable.air_contents.total_moles())
	babylon_area_test_cleanup(setup, made)
	return result
