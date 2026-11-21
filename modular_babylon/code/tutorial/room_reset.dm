// Paste area (spec 12 #9, "room reset"): a tutorial action that pastes a copy of an area over a
// room, through the area tools' own capture and paste (area_tools.dm), so a room can be put back
// the way it was for the next try. Two modes:
// - Snapshot (the default): the builder selects the room with the world-edit wand and presses
//   "Store selection in this action". The copy is kept in the action's settings (a versioned clip,
//   babylon_area_clip.to_data()), so it is saved with the world and travels with a submitted,
//   played or copied tutorial. It pastes back where it was stored, or at a picked corner.
// - Live: the action keeps a source rectangle and a target corner, and copies the source when it
//   fires. Players can change the source in the meantime; "Protect the source" keeps them from
//   building or taking it apart (with any item, near or at range) while the tutorial runs.
// Both clear the target first (players are moved aside, as the area tools do), paste with map
// loading that yields between ticks, then re-smooth walls and set up pipes and cables as a paste
// does. Tutorial objects, tutorial NPCs and builder tools in the target stay where they are, and
// the copy carries no tutorial objects. One area operation runs in the world at a time: a paste
// waits up to BABYLON_TUTORIAL_PASTE_WAIT for another builder's operation to end.

/// How long a Paste area waits for another area operation to finish.
#define BABYLON_TUTORIAL_PASTE_WAIT (30 SECONDS)

/obj/babylon_tutorial/action/paste_area
	tutorial_kind = "paste_area"
	preview_changes_world = TRUE
	kind_name = "Paste area"
	kind_desc = "Pastes a stored copy of an area (or a live copy of another area) over a room: puts a room back the way it was."
	kind_example = "e.g. reset the medbay after the lesson, so the next player finds it as you built it."
	ui_icon = "paste"
	view_icon = 'modular_babylon/icons/babylon_world_edit.dmi'
	view_state = "wooden_axe"

/obj/babylon_tutorial/action/paste_area/own_schema()
	return list(
		babylon_tutorial_field("mode", "Copy from", "choice", "snapshot", "A stored snapshot: the area as it was when you stored it, saved with the tutorial. A live area: another area (a template room) copied when the action runs. Switching keeps a stored snapshot (it stays saved with the action).", options = babylon_tutorial_options(list("snapshot" = "A stored snapshot (recommended)", "live" = "A live area, copied when it runs"))),
		babylon_tutorial_field("snapshot", "Stored area", "area_clip", null, "Select the room with the world-edit wand, then store it here (at most [BABYLON_AREA_SNAPSHOT_BYTES / 1024] KB, and all of a world's stored areas together at most [GLOB.babylon_area_snapshots_total_bytes / 1024] KB; identical tiles are stored once). Tutorial objects are not stored: the room's own tutorial objects stay where they are.", when = list("mode" = list("snapshot")), required = TRUE),
		babylon_tutorial_field("source", "Source area", "zone", null, "The area copied each time the action runs. Players can change or damage it while the tutorial runs: protect it below, or keep it where players can't go.", when = list("mode" = list("live")), max_tiles = BABYLON_AREA_MAX_TILES),
		babylon_tutorial_field("protect", "Protect the source", "bool", 1, "While the tutorial runs (a test run or a preview too), nobody can use tools or items on anything in the source area (no RCD, no deconstruction), builders included: stop the run before editing it. Only the builder wands still work there. Bare hands, explosions, fire and gas still change it. Prefer a stored snapshot unless you need the source to change.", when = list("mode" = list("live"))),
		babylon_tutorial_field("target", "Paste at", "tile", null, "The tile that becomes the copy's bottom-left (south-west) corner. A snapshot without one pastes back where it was stored."),
	)

/obj/babylon_tutorial/action/paste_area
	/// The stored snapshot's measured JSON size, and the settings_json it was measured for.
	var/snapshot_size = 0
	var/snapshot_size_json

/// The stored snapshot data, or null.
/obj/babylon_tutorial/action/paste_area/proc/snapshot_data()
	var/list/data = setting("snapshot")
	return islist(data) && length(data) ? data : null

/// The stored snapshot's real size (its JSON), measured once per settings change (also after a
/// restore or copy, which only set settings_json). 0 without one.
/obj/babylon_tutorial/action/paste_area/proc/snapshot_bytes()
	if(snapshot_size_json != settings_json)
		snapshot_size_json = settings_json
		var/list/data = snapshot_data()
		snapshot_size = data ? length(json_encode(data)) : 0
	return snapshot_size

/// Every way a snapshot is stored goes through set_setting (the store button, tests): the size
/// caps are checked on the measured value, never on a size the data names.
/obj/babylon_tutorial/action/paste_area/set_setting(key, value)
	if(key == "snapshot" && islist(value) && length(value))
		var/problem = babylon_tutorial_snapshot_size_problem(length(json_encode(value)), src)
		if(problem)
			return problem
	return ..()

/// A copy made by the area tools (paste or undo) keeps its stored area only within the caps;
/// otherwise the copy drops it and the builder is told (the original keeps it).
/obj/babylon_tutorial/action/paste_area/after_area_paste()
	var/list/data = snapshot_data()
	if(!data)
		return null
	var/problem = babylon_area_clip_data_problem(data, snapshot_bytes()) || babylon_tutorial_snapshot_size_problem(snapshot_bytes(), src)
	if(!problem || findtext(problem, "older format") || findtext(problem, "newer format"))
		// Format problems stay visible on the copy as its issue; nothing is dropped for them.
		return null
	var/list/values = settings().Copy()
	values -= "snapshot"
	store_settings(values)
	return "The copy of [tutorial_id] left its stored area out: [problem]"

/// Why this action's stored area can't be pasted now: its own problem, or the world's total.
/obj/babylon_tutorial/action/paste_area/proc/snapshot_problem()
	var/list/data = snapshot_data()
	return babylon_area_clip_data_problem(data, data ? snapshot_bytes() : null) || (data && babylon_tutorial_snapshot_total_problem())

/// Where the copy goes (its south-west tile), or null.
/obj/babylon_tutorial/action/paste_area/proc/target_turf()
	var/list/target = setting("target")
	if(length(target) == 3)
		return locate(target[1], target[2], target[3])
	if(setting("mode") == "live")
		return null
	var/list/data = snapshot_data()
	var/list/origin = data?["origin"]
	return length(origin) == 3 ? locate(origin[1], origin[2], origin[3]) : null

/// The copy's size: list(width, height), or null when it is not known yet.
/obj/babylon_tutorial/action/paste_area/proc/copy_size()
	if(setting("mode") == "live")
		var/list/zone = setting("source")
		return length(zone) == 5 ? list(zone[3] - zone[1] + 1, zone[4] - zone[2] + 1) : null
	var/list/data = snapshot_data()
	return data ? list(data["width"], data["height"]) : null

/// The rectangle the paste covers: list(x1, y1, x2, y2, z), or null.
/obj/babylon_tutorial/action/paste_area/proc/footprint()
	var/turf/origin = target_turf()
	var/list/size = copy_size()
	if(!origin || !size || !isnum(size[1]) || !isnum(size[2]))
		return null
	return list(origin.x, origin.y, origin.x + size[1] - 1, origin.y + size[2] - 1, origin.z)

/obj/babylon_tutorial/action/paste_area/find_issues()
	. = ..()
	if(setting("mode") == "live")
		var/list/zone = setting("source")
		if(length(zone) != 5)
			.["source"] = "Pick the source area's corners, or use your world-edit selection."
		else
			var/error = babylon_area_check(zone[1], zone[2], zone[5], zone[3], zone[4], zone[5])
			if(error)
				.["source"] = error
		if(length(setting("target")) != 3)
			.["target"] = "Pick the tile the copy goes to."
	else
		var/problem = snapshot_problem()
		if(problem)
			.["snapshot"] = problem
	var/list/rect = footprint()
	if(rect && !.["target"])
		var/error = babylon_area_check(rect[1], rect[2], rect[5], rect[3], rect[4], rect[5])
		if(error)
			.["target"] = "The copy does not fit there. [error]"
		else if(setting("mode") == "live")
			var/list/zone = setting("source")
			if(babylon_area_rects_overlap(zone, rect))
				.["target"] = "The copy would cover its own source area. Pick a target away from it."

/obj/babylon_tutorial/action/paste_area/summary()
	var/turf/origin = target_turf()
	var/where = origin ? "at [origin.x], [origin.y]" : "(no target)"
	if(setting("mode") == "live")
		var/list/zone = setting("source")
		return length(zone) == 5 ? "copy of [zone[3] - zone[1] + 1]x[zone[4] - zone[2] + 1] tiles at [zone[1]], [zone[2]] [where][setting("protect") ? ", source protected" : ""]" : "live copy (no source yet)"
	var/list/data = snapshot_data()
	return data ? "stored [data["width"]]x[data["height"]] area [where]" : "nothing stored yet"

/obj/babylon_tutorial/action/paste_area/perform(datum/babylon_tutorial_run/run)
	// Capturing and map loading pause between ticks: the paste runs on its own.
	INVOKE_ASYNC(GLOBAL_PROC, GLOBAL_PROC_REF(babylon_tutorial_paste_area), src, run)

/// Two rectangles (x1, y1, x2, y2, z) share a tile.
/proc/babylon_area_rects_overlap(list/one, list/other)
	if(length(one) != 5 || length(other) != 5 || one[5] != other[5])
		return FALSE
	return one[1] <= other[3] && other[1] <= one[3] && one[2] <= other[4] && other[2] <= one[4]

/// Runs a Paste area for a run (a preview tells only its builder). Whatever it could not do is
/// noted for the builder (run.note_action).
/proc/babylon_tutorial_paste_area(obj/babylon_tutorial/action/paste_area/action, datum/babylon_tutorial_run/run)
	// One area operation at a time in the world: wait for another builder's to end.
	var/deadline = world.time + BABYLON_TUTORIAL_PASTE_WAIT
	// A save in progress counts the same: the paste waits for it (area session begin() refuses).
	while(babylon_area_locked_by_other() || GLOB.babylon_save?.busy)
		if(world.time > deadline)
			if(!QDELETED(run) && !QDELETED(action))
				run.note_action(action, "another area operation or a save ran for more than [BABYLON_TUTORIAL_PASTE_WAIT / (1 SECONDS)] seconds, so nothing was pasted.")
			return
		sleep(1 SECONDS)
	if(QDELETED(run) || QDELETED(action))
		return
	var/datum/babylon_area_session/session = new("tutorial:[action.tutorial_id]")
	session.rate_limited = FALSE
	var/refusal = session.begin()
	if(refusal)
		// Taken in the same tick by someone else (or a save began): nothing happens this time.
		run.note_action(action, "it could not start ([refusal]), so nothing was pasted.")
		return
	var/list/outcome = list()
	babylon_tutorial_paste_area_steps(action, outcome)
	session.finish()
	if(QDELETED(run) || QDELETED(action))
		return
	if(outcome["error"])
		run.note_action(action, outcome["error"])
		return
	if(!outcome["done"])
		// Cut short by a runtime in the steps themselves (no try: see babylon_area_delete).
		run.note_action(action, "the paste was cut short; part of the area may be pasted.")
		return
	if(length(outcome["missing"]))
		run.note_action(action, "pasted, without [length(outcome["missing"])] type\s this server no longer has: [english_list(outcome["missing"])].")
	log_game("BABYLON TUTORIAL: [action.tutorial_id] pasted [outcome["size"]] at [outcome["where"]].")
	if(run.preview && run.preview_mob)
		to_chat(run.preview_mob, span_notice("Preview: pasted [outcome["size"]] at [outcome["where"]][outcome["moved"] ? " (moved [outcome["moved"]] player\s aside)" : ""]."))

/// The paste's work: fills outcome ("error", or "done", "size", "where", "moved", "missing").
/proc/babylon_tutorial_paste_area_steps(obj/babylon_tutorial/action/paste_area/action, list/outcome)
	var/datum/babylon_area_clip/clip
	if(action.setting("mode") == "live")
		var/list/zone = action.setting("source")
		if(length(zone) != 5)
			outcome["error"] = "no source area is picked."
			return
		var/error = babylon_area_check(zone[1], zone[2], zone[5], zone[3], zone[4], zone[5]) || babylon_area_too_full(zone)
		if(error)
			outcome["error"] = "the source area can't be copied: [error]"
			return
		clip = babylon_area_capture(zone[1], zone[2], zone[3], zone[4], zone[5])
		if(!clip)
			outcome["error"] = "the source area could not be copied."
			return
		// The source's own tutorial objects stay out of the copy.
		clip.tutorial = list()
	else
		// Loaded data is checked again (size measured, world total): a restored or imported save may
		// hold anything.
		var/problem = action.snapshot_problem()
		if(problem)
			outcome["error"] = problem
			return
		var/list/loaded = babylon_area_clip_from_data(action.snapshot_data(), action.snapshot_bytes())
		if(loaded["error"])
			outcome["error"] = loaded["error"]
			return
		clip = loaded["clip"]
		outcome["missing"] = loaded["missing"]
	var/turf/origin = action.target_turf()
	if(!origin)
		outcome["error"] = "no tile to paste at is picked."
		return
	var/list/rect = list(origin.x, origin.y, origin.x + clip.width - 1, origin.y + clip.height - 1, origin.z)
	var/error = babylon_area_check(rect[1], rect[2], rect[5], rect[3], rect[4], rect[5]) || babylon_area_too_full(rect)
	if(error)
		outcome["error"] = "the copy does not fit at [origin.x], [origin.y]: [error]"
		return
	if(action.setting("mode") == "live" && babylon_area_rects_overlap(action.setting("source"), rect))
		outcome["error"] = "the copy would cover its own source area."
		return
	// Protected tiles (the Creative Plane's edge ...) are never changed: where the copy has
	// something for one, nothing is pasted.
	for(var/dx in 0 to clip.width - 1)
		for(var/dy in 0 to clip.height - 1)
			var/turf/tile = locate(rect[1] + dx, rect[2] + dy, rect[5])
			var/list/entry = clip.entry(dx, dy)
			if(babylon_area_locked(tile) && !entry["keep"])
				outcome["error"] = "the copy would cover a protected tile at [tile.x], [tile.y]."
				return
	var/list/counts = list()
	// Players (and kept NPCs) moved aside are told it was the tutorial (one area operation at a time).
	GLOB.babylon_area_move_message = "The room was reset: you were moved aside."
	error = babylon_area_place(clip, origin, "keep", null, FALSE, "[world.port]-tutorial-[ckey(action.tutorial_id)]", counts, TRUE)
	GLOB.babylon_area_move_message = null
	if(error)
		outcome["error"] = error
		return
	outcome["size"] = babylon_area_size_text(clip.width, clip.height)
	outcome["where"] = "[rect[1]],[rect[2]],[rect[5]]"
	outcome["moved"] = counts["moved"]
	outcome["done"] = TRUE

// ---------------------------------------------------------------------------------------------
// Storing a snapshot, and the window's views

/// Stores a builder's world-edit selection in a Paste area's snapshot setting. Returns
/// list("text", "ok"). Uses the builder's area session (its lock and cooldown, as Copy).
/proc/babylon_tutorial_store_area(mob/living/user, obj/babylon_tutorial/object, key)
	var/datum/babylon_area_session/session = babylon_area_session(user?.ckey || REF(user))
	var/error = session.selection_problem() || session.begin()
	if(error)
		return list("text" = error, "ok" = FALSE)
	var/list/rect = session.selection.Copy()
	var/width = rect[3] - rect[1] + 1
	var/height = rect[4] - rect[2] + 1
	error = babylon_area_too_full(rect)
	var/datum/babylon_area_clip/clip
	if(!error)
		clip = babylon_area_capture(rect[1], rect[2], rect[3], rect[4], rect[5])
		if(!clip)
			error = "The area could not be copied."
	session.finish(width * height)
	if(error)
		return list("text" = error, "ok" = FALSE)
	if(QDELETED(object))
		return list("text" = "The action is gone.", "ok" = FALSE)
	var/list/data = clip.to_data()
	var/bytes = length(json_encode(data))
	// set_setting checks the caps too (on the same measured size).
	error = object.set_setting(key, data)
	if(error)
		return list("text" = error, "ok" = FALSE)
	log_game("BABYLON TUTORIAL: [key_name(user)] stored [babylon_area_size_text(width, height)] at [rect[1]],[rect[2]],[rect[5]] in [object.tutorial_id].")
	var/list/notes = list()
	if(length(clip.tutorial))
		notes += "[length(clip.tutorial)] tutorial object\s (they stay where they are)"
	var/not_copied = babylon_area_not_copied(clip)
	return list("text" = "Stored [babylon_area_size_text(width, height)] from [rect[1]], [rect[2]]: [clip.object_count] object\s, [babylon_area_kb(bytes)] of the [babylon_area_kb(BABYLON_AREA_SNAPSHOT_BYTES)] limit.[length(notes) ? " Not stored: [english_list(notes)]." : ""] [not_copied]", "ok" = TRUE)

/// Why a snapshot of this many bytes (measured) can't be in this action, or null: the
/// per-snapshot cap and the world's total over every Paste area (this action's old one excepted).
/proc/babylon_tutorial_snapshot_size_problem(bytes, obj/babylon_tutorial/object)
	if(bytes > BABYLON_AREA_SNAPSHOT_BYTES)
		return "That area takes [babylon_area_kb(bytes)] stored; a snapshot may take at most [babylon_area_kb(BABYLON_AREA_SNAPSHOT_BYTES)]. Select a smaller area (or one with fewer different tiles and objects)."
	var/total = bytes + babylon_tutorial_snapshots_bytes(object)
	if(total > GLOB.babylon_area_snapshots_total_bytes)
		return "Together with the other Paste area snapshots this world would store [babylon_area_kb(total)]; all snapshots together may take at most [babylon_area_kb(GLOB.babylon_area_snapshots_total_bytes)]. Select a smaller area, or clear another snapshot."
	return null

/// The measured size of every Paste area's stored area in the world (but one).
/proc/babylon_tutorial_snapshots_bytes(obj/babylon_tutorial/except)
	. = 0
	for(var/obj/babylon_tutorial/action/paste_area/other in GLOB.babylon_tutorial_objects)
		if(other != except)
			. += other.snapshot_bytes()

/// Why no stored area can be pasted in this world now: all of them together over the total (a
/// restored or imported save), or null.
/proc/babylon_tutorial_snapshot_total_problem()
	var/total = babylon_tutorial_snapshots_bytes()
	if(total > GLOB.babylon_area_snapshots_total_bytes)
		return "This world's stored areas take [babylon_area_kb(total)] together; at most [babylon_area_kb(GLOB.babylon_area_snapshots_total_bytes)] are allowed, so none is pasted. Clear some Paste area snapshots or store smaller areas."
	return null

/// A stored area for the window: its size, origin and object count (never the clip itself).
/proc/babylon_area_clip_view(list/data, obj/babylon_tutorial/object)
	if(!islist(data) || !length(data))
		return null
	var/obj/babylon_tutorial/action/paste_area/action = istype(object, /obj/babylon_tutorial/action/paste_area) ? object : null
	var/list/origin = data["origin"]
	return list(
		"width" = data["width"],
		"height" = data["height"],
		"x" = length(origin) == 3 ? origin[1] : null,
		"y" = length(origin) == 3 ? origin[2] : null,
		"z" = length(origin) == 3 ? origin[3] : null,
		"objects" = data["objects"],
		"tiles" = length(data["grid"]),
		"distinct" = length(data["palette"]),
		"bytes" = action ? action.snapshot_bytes() : length(json_encode(data)),
		"limit" = BABYLON_AREA_SNAPSHOT_BYTES,
		"skipped_tutorial" = data["skipped_tutorial"],
		"problem" = action ? action.snapshot_problem() : babylon_area_clip_data_problem(data),
	)

/// A builder's world-edit selection for the tutorial object window, or null.
/proc/babylon_area_selection_view(datum/babylon_area_session/session)
	var/list/rect = session?.selection
	if(!rect)
		return null
	return list("x1" = rect[1], "y1" = rect[2], "x2" = rect[3], "y2" = rect[4], "z" = rect[5], "width" = session.selection_width(), "height" = session.selection_height(), "tiles" = session.selection_width() * session.selection_height(), "problem" = session.selection_problem())

/// Whether a tutorial object type has a settings field of one of these types.
/proc/babylon_tutorial_has_field_type(path, list/types)
	for(var/list/field as anything in babylon_tutorial_schema(path))
		if(field["type"] in types)
			return TRUE
	return FALSE

// ---------------------------------------------------------------------------------------------
// Protected source areas

/// The source zones of live Paste area actions that protect them (cached until the tutorial
/// changes).
/proc/babylon_tutorial_protected_zones()
	var/static/list/cached = list()
	var/static/cached_version = -1
	if(cached_version == GLOB.babylon_tutorial_version)
		return cached
	cached = list()
	cached_version = GLOB.babylon_tutorial_version
	for(var/obj/babylon_tutorial/action/paste_area/action in GLOB.babylon_tutorial_objects)
		if(action.setting("mode") != "live" || !action.setting("protect"))
			continue
		var/list/zone = action.setting("source")
		if(length(zone) == 5)
			cached += list(zone.Copy())
	return cached

/// A tile in a protected source area while the world's tutorial runs.
/proc/babylon_tutorial_build_protected(turf/tile)
	if(!tile || !length(GLOB.babylon_tutorial_objects) || !babylon_tutorial_current_run())
		return FALSE
	for(var/list/zone as anything in babylon_tutorial_protected_zones())
		if(tile.z == zone[5] && tile.x >= zone[1] && tile.x <= zone[3] && tile.y >= zone[2] && tile.y <= zone[4])
			return TRUE
	return FALSE

/// Using an item on something in a protected source area is refused (builder tools excepted).
/proc/babylon_tutorial_blocks_building(mob/user, atom/target, obj/item/tool)
	if(tool?.babylon_builder_tool || !target)
		return FALSE
	// Mobs and what they carry are no part of the room: healing someone, or putting something in
	// a bag, stays possible in the source.
	if(ismob(target) || (ismovable(target) && get(target.loc, /mob)))
		return FALSE
	if(!babylon_tutorial_build_protected(get_turf(target)))
		return FALSE
	user?.balloon_alert(user, "protected while the tutorial runs")
	return TRUE

// Every item use on an atom (tools, RCD, stacks, attacks) starts in one of these two procs.
/obj/item/melee_attack_chain(mob/user, atom/target, list/modifiers, list/attack_modifiers = list())
	if(babylon_tutorial_blocks_building(user, target, src))
		return FALSE
	return ..()

/atom/base_ranged_item_interaction(mob/living/user, obj/item/tool, list/modifiers)
	if(babylon_tutorial_blocks_building(user, src, tool))
		return ITEM_INTERACT_BLOCKING
	return ..()

#undef BABYLON_TUTORIAL_PASTE_WAIT
