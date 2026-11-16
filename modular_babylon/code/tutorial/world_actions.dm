// Tutorial actions that change the world (spec 12 #5, #6, #11, #12): spawn objects, remove
// objects, start a round event, and open, close, lock or unlock doors and containers. They act on
// a place: a marker's tile or a zone (doors also by a shutter button's id). Whatever an action
// could not do in a test run is noted for the builder (runtime.dm note_action(): the Test run tab
// and the action's checks), never silently dropped.

/// Objects one run's Spawn object actions may create at most (all actions together): a repeating
/// trigger can't fill the world.
#define BABYLON_TUTORIAL_SPAWN_RUN_CAP 500
/// Things one Remove objects action deletes at most per run of it.
#define BABYLON_TUTORIAL_REMOVE_MAX 500
/// Tiles a Spawn / Remove / Door zone may cover.
#define BABYLON_TUTORIAL_PLACE_MAX_TILES 400

/// "Where": a marker's tile or a zone (the place an action works on).
/proc/babylon_tutorial_place_fields(what)
	return list(
		babylon_tutorial_field("place", "Where", "choice", "marker", "A marker: its tile. A zone: every tile of a rectangle (at most [BABYLON_TUTORIAL_PLACE_MAX_TILES]).", options = babylon_tutorial_options(list("marker" = "On a marker's tile", "zone" = "In a zone"))),
		babylon_tutorial_field("marker", "Marker", "id", "", what, filter = list("marker"), when = list("place" = list("marker")), required = TRUE),
		babylon_tutorial_field("zone", "Zone", "zone", null, what, when = list("place" = list("zone")), max_tiles = BABYLON_TUTORIAL_PLACE_MAX_TILES),
	)

/// The tiles an action with babylon_tutorial_place_fields() works on.
/obj/babylon_tutorial/action/proc/place_turfs()
	if(setting("place") == "zone")
		var/list/zone = setting("zone")
		return length(zone) == 5 ? babylon_tutorial_zone_turfs(zone) : list()
	var/turf/tile = babylon_tutorial_marker_turf(setting("marker"))
	return tile ? list(tile) : list()

/// The place's issue: a zone that was never picked.
/obj/babylon_tutorial/action/proc/place_issue()
	if(setting("place") == "zone" && length(setting("zone")) != 5)
		return "Pick the zone's corners."
	return null

/obj/babylon_tutorial/action/proc/place_summary()
	if(setting("place") == "zone")
		var/list/zone = setting("zone")
		return length(zone) == 5 ? "in a [zone[3] - zone[1] + 1]x[zone[4] - zone[2] + 1] zone" : "in a zone (not picked)"
	return "at [setting("marker") || "?"]"

// ---------------------------------------------------------------------------------------------
// Spawn object (#5)

/obj/babylon_tutorial/action/spawn_object
	tutorial_kind = "spawn_object"
	preview_changes_world = TRUE
	kind_name = "Spawn object"
	kind_desc = "Creates items, structures or machines on a marker's tile or in a zone, like the Creative panel's Spawn tab."
	kind_example = "e.g. three bruise packs appear on the medbay table."
	ui_icon = "cube"
	view_icon = 'icons/effects/landmarks_static.dmi'
	view_state = "random_loot"

/obj/babylon_tutorial/action/spawn_object/own_schema()
	return list(
		babylon_tutorial_field("object_type", "Object", "typepath", "", "Anything the Creative panel can spawn (items, structures, machines; no mobs: NPCs come from NPC spawners).", base = /obj, required = TRUE, placeholder = "Search like the Creative panel, e.g. medkit", search = "creative"),
		babylon_tutorial_field("count", "How many", "number", 1, "Copies (at most [BABYLON_CREATIVE_MAX_COPIES]); for a stack (sheets, cable ...) the size of the one stack.", min = 1, max = 50),
	) + babylon_tutorial_place_fields("Where the objects appear (in a zone: each one on a random free tile).")

/obj/babylon_tutorial/action/spawn_object/find_issues()
	. = ..()
	var/issue = place_issue()
	if(issue)
		.["zone"] = issue
	var/path = text2path(setting("object_type"))
	if(path && !ispath(path, /obj/item/stack) && setting("count") > BABYLON_CREATIVE_MAX_COPIES)
		.["count"] = "At most [BABYLON_CREATIVE_MAX_COPIES] copies of one object are made (only a stack can be bigger)."

/obj/babylon_tutorial/action/spawn_object/perform(datum/babylon_tutorial_run/run)
	var/path = text2path(setting("object_type"))
	if(!ispath(path, /obj) || babylon_creative_spawn_blocked(path))
		run.note_action(src, "nothing to spawn: choose an object the Creative panel can spawn.")
		return
	var/list/tiles = place_turfs()
	if(!length(tiles))
		run.note_action(src, "there is no place to spawn at ([place_summary()]).")
		return
	// Never inside a wall: free tiles first, else any open one (a table's tile).
	var/list/open = list()
	var/list/free = list()
	for(var/turf/tile as anything in tiles)
		if(isclosedturf(tile))
			continue
		open += tile
		if(!tile.is_blocked_turf(TRUE))
			free += tile
	if(!length(open))
		run.note_action(src, "nothing spawned: [place_summary()] there is only wall.")
		return
	if(!length(free))
		free = open
	var/amount = round(setting("count") || 1)
	var/copies = ispath(path, /obj/item/stack) ? 1 : clamp(amount, 1, BABYLON_CREATIVE_MAX_COPIES)
	if(!ispath(path, /obj/item/stack) && amount > copies)
		run.note_action(src, "made [copies] copies, not [amount]: at most [BABYLON_CREATIVE_MAX_COPIES] copies of one object per run of the action (only a stack can be bigger).")
	if(!run.claim_spawns(copies, src))
		return
	for(var/copy in 1 to copies)
		var/turf/spot = pick(free)
		if(ispath(path, /obj/item/stack))
			var/obj/item/stack/stack_type = path
			new path(spot, clamp(amount, 1, max(1, initial(stack_type.max_amount))), FALSE)
		else
			new path(spot)

/// Counts count new objects of action against the run's cap (BABYLON_TUTORIAL_SPAWN_RUN_CAP): every
/// action that makes objects (Spawn object, Give item, a Set inventory loadout) shares it, so a
/// repeating trigger can't fill the world. FALSE, with a note for the builder, when they would go
/// over it: the action then makes nothing.
/datum/babylon_tutorial_run/proc/claim_spawns(count, obj/babylon_tutorial/action/action)
	if(spawned_count + count > BABYLON_TUTORIAL_SPAWN_RUN_CAP)
		note_action(action, "this run already made [spawned_count] objects (at most [BABYLON_TUTORIAL_SPAWN_RUN_CAP] per run): nothing more was made.")
		return FALSE
	spawned_count += count
	return TRUE

/obj/babylon_tutorial/action/spawn_object/summary()
	var/count = setting("count") || 1
	return "[count > 1 ? "[count] x " : ""][babylon_tutorial_type_label(setting("object_type"))] [place_summary()]"

// ---------------------------------------------------------------------------------------------
// Remove objects (#6)

/obj/babylon_tutorial/action/remove_objects
	tutorial_kind = "remove_objects"
	preview_changes_world = TRUE
	kind_name = "Remove objects"
	kind_desc = "Deletes objects of a type, or every loose item, on a marker's tile or in a zone. Never players, mobs, tutorial objects or protected objects."
	kind_example = "e.g. clear the used gauze off the floor before the next lesson."
	ui_icon = "broom"
	view_icon = 'icons/effects/mapping_helpers.dmi'
	view_state = "no_atoms_ontop"

/obj/babylon_tutorial/action/remove_objects/own_schema()
	return list(
		babylon_tutorial_field("what", "Remove", "choice", "loose", "Loose items: every item lying on the floor. A type: objects of that type and its subtypes (items, structures, machines).", options = babylon_tutorial_options(list("loose" = "All loose items", "type" = "Objects of a type"))),
		babylon_tutorial_field("object_type", "Type", "typepath", "", "Its subtypes go too (\"medkit\" also removes the burn and brute medkits).", base = /obj, when = list("what" = list("type")), required = TRUE, placeholder = "Search, e.g. gauze", search = "any"),
	) + babylon_tutorial_place_fields("Where to remove them.")

/obj/babylon_tutorial/action/remove_objects/find_issues()
	. = ..()
	var/issue = place_issue()
	if(issue)
		.["zone"] = issue
	if(setting("what") == "type" && !length(setting("object_type")))
		.["object_type"] = "Choose the type to remove."

/obj/babylon_tutorial/action/remove_objects/perform(datum/babylon_tutorial_run/run)
	var/path
	if(setting("what") == "type")
		path = text2path(setting("object_type"))
		if(!ispath(path, /obj))
			run.note_action(src, "no type chosen: nothing was removed.")
			return
	var/list/tiles = place_turfs()
	if(!length(tiles))
		run.note_action(src, "there is no place to remove from ([place_summary()]).")
		return
	var/removed = 0
	var/kept = 0
	for(var/turf/tile as anything in tiles)
		for(var/obj/thing in tile)
			if(path ? !istype(thing, path) : !isitem(thing))
				continue
			if(removed >= BABYLON_TUTORIAL_REMOVE_MAX)
				run.note_action(src, "stopped after [BABYLON_TUTORIAL_REMOVE_MAX] objects (the most one run of it removes).")
				return
			if(!babylon_tutorial_removable(thing))
				kept++
				continue
			// Protected things inside (a unique item in a crate) stay on the tile.
			for(var/obj/inner in thing.get_all_contents())
				if(inner != thing && babylon_area_protected_object(inner))
					inner.forceMove(tile)
			// No try around it (a deep stack_trace in a Destroy would unwind it half done).
			qdel(thing)
			removed++
	log_game("BABYLON TUTORIAL: [tutorial_id] removed [removed] object\s [place_summary()][kept ? ", kept [kept]" : ""].")

/obj/babylon_tutorial/action/remove_objects/summary()
	var/what = setting("what") == "type" ? babylon_tutorial_type_label(setting("object_type")) : "loose items"
	return "[what] [place_summary()]"

/**
 * Whether a Remove objects action may delete this object. Never:
 * - tutorial objects (they are the tutorial itself);
 * - what the area tools would not remove (babylon_area_removable): protected (indestructible)
 *   objects, effects other than decals, docking ports;
 * - anything with a mob inside (a player in a locker, an NPC's body in a body bag) or a mob
 *   buckled to it (a player in a chair): mobs are never removed, neither directly nor with what
 *   holds them;
 * - a builder's tool (the tutorial or world-edit wand) or anything holding one.
 */
/proc/babylon_tutorial_removable(obj/thing)
	if(QDELETED(thing) || istype(thing, /obj/babylon_tutorial))
		return FALSE
	if(!babylon_area_removable(thing))
		return FALSE
	if(thing.has_buckled_mobs())
		return FALSE
	for(var/mob/living/body in thing.get_all_contents())
		return FALSE
	// A builder's tool on the floor, or in a bag on the floor, stays (inventory.dm).
	if(babylon_tutorial_inventory_kept(thing) || length(babylon_tutorial_kept_inside(thing)))
		return FALSE
	return TRUE

// ---------------------------------------------------------------------------------------------
// Start event (#11)

/// Events tutorial actions started (weakrefs): the tutorial subsystem steps them where neither
/// SSevents nor the Creative panel's tick does (a tutorial world, creative off).
GLOBAL_LIST_EMPTY(babylon_tutorial_events)
/// world.time of every event a tutorial action started (the shared rate limit).
GLOBAL_LIST_EMPTY(babylon_tutorial_event_times)

/obj/babylon_tutorial/action/start_event
	tutorial_kind = "start_event"
	preview_changes_world = TRUE
	kind_name = "Start event"
	kind_desc = "Starts a round event, like the Creative panel's Events tab (the same list and the same rules)."
	kind_example = "e.g. a meteor shower once the shields lesson starts."
	ui_icon = "bolt"
	view_icon = 'icons/effects/mapping_helpers.dmi'
	view_state = "ztrait"

/obj/babylon_tutorial/action/start_event/own_schema()
	return list(
		babylon_tutorial_field("event", "Event", "event", "", "Only events the Creative panel's Events tab offers: no antagonists, nothing that picks on other players or wrecks the world. Tutorial actions start at most [BABYLON_CREATIVE_EVENT_LIMIT] events per [BABYLON_CREATIVE_EVENT_WINDOW / 10] seconds.", required = TRUE),
	)

/obj/babylon_tutorial/action/start_event/find_issues()
	. = ..()
	var/event = setting("event")
	if(!length(event))
		.["event"] = "Choose an event."
	else if(!babylon_creative_event_allowed(event))
		.["event"] = "This event can't be started here any more."

/obj/babylon_tutorial/action/start_event/perform(datum/babylon_tutorial_run/run)
	for(var/time in GLOB.babylon_tutorial_event_times.Copy())
		if(world.time - time >= BABYLON_CREATIVE_EVENT_WINDOW)
			GLOB.babylon_tutorial_event_times -= time
	if(length(GLOB.babylon_tutorial_event_times) >= BABYLON_CREATIVE_EVENT_LIMIT)
		run.note_action(src, "not started: tutorial actions already started [BABYLON_CREATIVE_EVENT_LIMIT] events in the last [BABYLON_CREATIVE_EVENT_WINDOW / 10] seconds.")
		return
	var/result = babylon_creative_start_event(setting("event"), "tutorial action [tutorial_id]")
	if(istext(result))
		run.note_action(src, "the event did not start: [result]")
		return
	var/datum/round_event/started = result
	GLOB.babylon_tutorial_event_times += world.time
	GLOB.babylon_tutorial_events += WEAKREF(started)
	log_game("BABYLON TUTORIAL: [tutorial_id] started the event [started.control.name] ([started.control.type]).")

/obj/babylon_tutorial/action/start_event/summary()
	var/datum/round_event_control/control = babylon_creative_event_control(setting("event"))
	return control ? control.name : "no event chosen"

/// Steps running events every two seconds where nothing else does: no SSevents (Babylon builds)
/// and no Creative tick (Creative off, e.g. a published tutorial). Only while a tutorial action
/// started one. Called by SSbabylon_tutorial every second.
/proc/babylon_tutorial_step_events()
	var/static/phase = FALSE
	if(!length(GLOB.babylon_tutorial_events))
		return FALSE
	for(var/datum/weakref/reference as anything in GLOB.babylon_tutorial_events.Copy())
		var/datum/round_event/event = reference.resolve()
		if(!event || QDELETED(event) || !(event in SSevents.running))
			GLOB.babylon_tutorial_events -= reference
	if(!length(GLOB.babylon_tutorial_events) || babylon_creative_enabled())
		// The Creative tick steps them (twice as fast if both did).
		return FALSE
	phase = !phase
	if(!phase)
		return FALSE
	return babylon_creative_step_events()

// ---------------------------------------------------------------------------------------------
// Door / container (#12)

/obj/babylon_tutorial/action/door
	tutorial_kind = "door"
	preview_changes_world = TRUE
	kind_name = "Door / container"
	kind_desc = "Opens, closes, locks or unlocks airlocks, windoors, shutters and blast doors, lockers, closets and crates."
	kind_example = "e.g. unbolt the medbay door once the players have their gear."
	ui_icon = "door-open"
	view_icon = 'icons/effects/mapping_helpers.dmi'
	view_state = "airlock_unres_helper"

/obj/babylon_tutorial/action/door/own_schema()
	return list(
		babylon_tutorial_field("door_action", "Do", "choice", "open", "Open and close follow each thing's own rules: a bolted, welded or unpowered airlock stays as it is, a locked or welded locker stays shut (Unlock first). Lock and unlock always work: they bolt and unbolt airlocks (also without power) and lock secure lockers and crates (an open one is closed first). Windoors, shutters and blast doors only open and close. Closing or locking a locker or crate shuts in whoever stands on its tile, as it would for a player (they can climb out).", options = babylon_tutorial_options(list("open" = "Open", "close" = "Close", "lock" = "Lock (bolt)", "unlock" = "Unlock (unbolt)"))),
		babylon_tutorial_field("place", "Where", "choice", "marker", "A marker: the doors and containers on its tile. A zone: those on every tile of it. Shutter button: every shutter and blast door with that id in this world (as its button would).", options = babylon_tutorial_options(list("marker" = "On a marker's tile", "zone" = "In a zone", "button" = "Shutters with a button id"))),
		babylon_tutorial_field("marker", "Marker", "id", "", "The marker on the door or container.", filter = list("marker"), when = list("place" = list("marker")), required = TRUE),
		babylon_tutorial_field("zone", "Zone", "zone", null, "Every door and container in it.", when = list("place" = list("zone")), max_tiles = BABYLON_TUTORIAL_PLACE_MAX_TILES),
		babylon_tutorial_field("button_id", "Button id", "text", "", "The id the shutters and their button share (a multitool shows it).", when = list("place" = list("button"))),
	)

/obj/babylon_tutorial/action/door/find_issues()
	. = ..()
	var/issue = place_issue()
	if(issue)
		.["zone"] = issue
	if(setting("place") == "button" && !length(setting("button_id")))
		.["button_id"] = "Enter the shutters' id."

/obj/babylon_tutorial/action/door/place_summary()
	if(setting("place") == "button")
		return "with id [setting("button_id") || "?"]"
	return ..()

/// The doors and containers the action works on.
/obj/babylon_tutorial/action/door/proc/targets()
	var/list/found = list()
	if(setting("place") == "button")
		var/id = setting("button_id")
		if(!length(id))
			return found
		for(var/obj/machinery/door/poddoor/shutter as anything in SSmachines.get_machines_by_type_and_subtypes(/obj/machinery/door/poddoor))
			// The same rules as on a marker or in a zone (nothing protected).
			if("[shutter.id]" == id && (shutter.z in babylon_area_levels()) && babylon_tutorial_door_target(shutter))
				found += shutter
		return found
	for(var/turf/tile as anything in place_turfs())
		for(var/obj/thing in tile)
			if(babylon_tutorial_door_target(thing))
				found += thing
	return found

/// What a Door / container action can work on: airlocks, windoors, shutters and blast doors,
/// closets, lockers and crates. Not firelocks (they keep the air in), nothing protected.
/proc/babylon_tutorial_door_target(obj/thing)
	if(QDELETED(thing) || babylon_area_protected_object(thing))
		return FALSE
	if(istype(thing, /obj/machinery/door/firedoor))
		return FALSE
	return istype(thing, /obj/machinery/door/airlock) || istype(thing, /obj/machinery/door/window) || istype(thing, /obj/machinery/door/poddoor) || istype(thing, /obj/structure/closet)

/obj/babylon_tutorial/action/door/perform(datum/babylon_tutorial_run/run)
	var/list/targets = targets()
	if(!length(targets))
		run.note_action(src, "no door or container [place_summary()].")
		return
	var/act = setting("door_action")
	var/list/refused = list()
	for(var/obj/thing as anything in targets)
		var/why = babylon_tutorial_door_act(thing, act)
		if(why)
			refused += "[thing.name] [why]"
	if(length(refused))
		run.note_action(src, "[english_list(refused.Copy(1, min(length(refused), 3) + 1))][length(refused) > 3 ? " and [length(refused) - 3] more" : ""].")

/// Opens, closes, locks or unlocks one door or container with its own procs. Returns null when it
/// did (or it already was so), else why not ("is bolted" ...). Doors move on their own (their
/// animation sleeps): they are started asynchronously.
/proc/babylon_tutorial_door_act(obj/thing, act)
	if(istype(thing, /obj/machinery/door/airlock))
		var/obj/machinery/door/airlock/airlock = thing
		switch(act)
			if("lock")
				// Forced: bolts drop also without power (like the AI's bolt button, minus the power check).
				airlock.bolt()
				return null
			if("unlock")
				airlock.unbolt()
				return null
		if((act == "open") != !!airlock.density)
			return null
		if(airlock.locked)
			return "is bolted"
		if(airlock.welded)
			return "is welded"
		if(airlock.seal)
			return "is sealed"
		if(!airlock.hasPower())
			return "has no power"
		INVOKE_ASYNC(airlock, act == "open" ? TYPE_PROC_REF(/obj/machinery/door, open) : TYPE_PROC_REF(/obj/machinery/door, close))
		return null
	if(istype(thing, /obj/machinery/door))
		// Windoors, shutters and blast doors: open and close only (they have no bolts).
		var/obj/machinery/door/door = thing
		if(!(act in list("open", "close")))
			return "can't be locked"
		if((act == "open") != !!door.density)
			return null
		INVOKE_ASYNC(door, act == "open" ? TYPE_PROC_REF(/obj/machinery/door, open) : TYPE_PROC_REF(/obj/machinery/door, close))
		return null
	if(istype(thing, /obj/structure/closet))
		var/obj/structure/closet/closet = thing
		switch(act)
			if("open")
				if(closet.opened)
					return null
				if(closet.locked)
					return "is locked"
				if(closet.welded)
					return "is welded shut"
				return closet.open(null) ? null : "would not open"
			if("close")
				if(!closet.opened)
					return null
				return closet.close(null) ? null : "would not close (something is in the way)"
			if("lock")
				if(!closet.secure || closet.broken)
					return "has no lock"
				if(closet.opened && !closet.close(null))
					return "would not close to be locked"
				closet.lock()
				return null
			if("unlock")
				if(!closet.secure || closet.broken)
					return null
				closet.unlock()
				return null
	return "can't be opened"

/obj/babylon_tutorial/action/door/summary()
	var/static/list/verbs = list("open" = "open", "close" = "close", "lock" = "lock", "unlock" = "unlock")
	return "[verbs[setting("door_action")] || "?"] [place_summary()]"

#undef BABYLON_TUTORIAL_SPAWN_RUN_CAP
#undef BABYLON_TUTORIAL_REMOVE_MAX
#undef BABYLON_TUTORIAL_PLACE_MAX_TILES
