// Area tools of the world-edit wand (spec 7.1 item 3, 12 #1; the wand is world_edit.dm): a small
// WorldEdit for creative worlds. A builder clicks two corners with the wand; its window then works
// on that rectangle (a tutorial's Paste area action, room_reset.dm, uses the same capture and
// paste):
// - Copy: the tiles, objects (with container contents and reagents) and tutorial objects go to
//   the builder's clipboard (kept in memory, also written to data/babylon/clipboard/<ckey>.dmm).
// - Paste: click the tile that becomes the copy's bottom-left (south-west) corner, then confirm.
//   The copy is loaded there as a map template (pipes, cables and air are set up as on a map
//   load); tutorial objects get an id suffix ("_2"), applied to their links among each other.
// - Fill / Border: a turf or a structure on every tile, or along the edge.
// - Clear: objects and mobs go, floors become plating (or a chosen turf).
// - Undo: the builder's last operation, one step.
// Limits: at most BABYLON_AREA_MAX_TILES tiles, one level, inside the map and the world's
// building levels; indestructible turfs and objects are never changed, copied or removed (tutorial
// objects excepted). Players (a client, a ckey or a mind) are never deleted: they are moved to the
// nearest free tile outside the area. After an operation a builder waits 2 seconds plus 1 second
// per 1000 tiles; one operation runs at a time in the world (map loading can pause), and that lock
// expires after BABYLON_AREA_LOCK_TIMEOUT so nobody can hold it for good.

#define BABYLON_AREA_MAX_TILES 10000
#define BABYLON_AREA_COOLDOWN (2 SECONDS)
/// At most this many items inside containers are copied per operation.
#define BABYLON_AREA_MAX_NESTED 4000
/// At most this many objects (and mobs) in an area per operation.
#define BABYLON_AREA_MAX_OBJECTS 20000
/// The world-wide operation lock is ignored after this long.
#define BABYLON_AREA_LOCK_TIMEOUT (60 SECONDS)
/// Sessions unused this long lose their clipboard and undo (memory).
#define BABYLON_AREA_SESSION_IDLE (30 MINUTES)

/// ckey => /datum/babylon_area_session
GLOBAL_LIST_EMPTY(babylon_area_sessions)
/// While an area operation runs (map loading may pause it): the world.time its lock expires.
/// The running operation pushes it on while it makes progress (BABYLON_AREA_TICK).
GLOBAL_VAR_INIT(babylon_area_busy, 0)
/// The session whose operation holds the lock: only it releases the lock.
GLOBAL_DATUM(babylon_area_lock_owner, /datum/babylon_area_session)
/// Pipe links on paste edges that threw (tests check it stays unchanged).
GLOBAL_VAR_INIT(babylon_area_link_failures, 0)

/// Keeps the running operation's lock and yields when the tick is used up.
#define BABYLON_AREA_TICK babylon_area_tick()

/// An area operation holds the world-wide lock right now.
/proc/babylon_area_locked_by_other()
	return GLOB.babylon_area_busy > world.time

/// The running operation made progress: its lock lasts another BABYLON_AREA_LOCK_TIMEOUT.
/proc/babylon_area_keepalive()
	if(GLOB.babylon_area_lock_owner && GLOB.babylon_area_busy)
		GLOB.babylon_area_busy = world.time + BABYLON_AREA_LOCK_TIMEOUT

/// Keeps the lock and yields when the tick is used up (a pause here pauses the operation).
/proc/babylon_area_tick()
	babylon_area_keepalive()
	CHECK_TICK
/// Last tag given to an object written into a clipboard map.
GLOBAL_VAR_INIT(babylon_area_next_tag, 0)

/obj
	/// Set on objects loaded from a clipboard map, so the paste finds them again (area_tools.dm).
	var/babylon_clip_tag

/// The area tool session of a builder (by ckey), created on first use.
/proc/babylon_area_session(key)
	RETURN_TYPE(/datum/babylon_area_session)
	key = "[key]"
	babylon_area_prune_sessions()
	var/datum/babylon_area_session/session = GLOB.babylon_area_sessions[key]
	if(!session)
		session = new(key)
		GLOB.babylon_area_sessions[key] = session
	session.last_used = world.time
	return session

/// Frees sessions nobody used for a while (their clipboards and undo snapshots can be large).
/proc/babylon_area_prune_sessions()
	var/static/next_prune = 0
	if(world.time < next_prune)
		return
	next_prune = world.time + 1 MINUTES
	for(var/key in GLOB.babylon_area_sessions)
		var/datum/babylon_area_session/session = GLOB.babylon_area_sessions[key]
		if(world.time > session.last_used + BABYLON_AREA_SESSION_IDLE)
			GLOB.babylon_area_sessions -= key
			fdel("data/babylon/clipboard/[world.port]-[ckey(key)].dmm")

/// The levels area tools may change: the world's saved building levels.
/proc/babylon_area_levels()
	var/list/levels = GLOB.babylon_save?.persisted_levels()
	return length(levels) ? levels : SSmapping.levels_by_trait(ZTRAIT_STATION)

/// "2 tiles with a player on them (no free tile to move them to)"
/proc/babylon_area_occupied_text(count)
	return "[count] tile[count == 1 ? "" : "s"] with a player on [count == 1 ? "it" : "them"] (no free tile to move them to)"

/// "12×8 (96 tiles)"
/proc/babylon_area_size_text(width, height)
	var/tiles = width * height
	return "[width]×[height] ([tiles] tile[tiles == 1 ? "" : "s"])"

/// Why a rectangle can't be worked on (corners in any order), or null.
/proc/babylon_area_check(x1, y1, z1, x2, y2, z2)
	if(z1 != z2)
		return "Both corners must be on the same deck."
	if(!(z1 in babylon_area_levels()))
		return "You can only build on this world's own decks, not there."
	if(min(x1, x2) < 1 || min(y1, y2) < 1 || max(x1, x2) > world.maxx || max(y1, y2) > world.maxy)
		return "That reaches past the edge of the map (it is [world.maxx]×[world.maxy] tiles)."
	var/width = abs(x2 - x1) + 1
	var/height = abs(y2 - y1) + 1
	if(width * height > BABYLON_AREA_MAX_TILES)
		return "That is [babylon_area_size_text(width, height)]: the area tools work on at most 10,000 tiles at once. Select a smaller area."
	return null

/// Turfs nobody may change with the area tools (the Creative Plane's edge, centcom floors ...).
/proc/babylon_area_locked(turf/tile)
	return istype(tile, /turf/closed/indestructible) || istype(tile, /turf/open/indestructible) || (tile.resistance_flags & INDESTRUCTIBLE)

/// A mob that belongs to a player: connected, disconnected (a ckey) or a ghosted player's body
/// (a mind). Never deleted by the area tools.
/proc/babylon_area_is_player(mob/thing)
	return !!(thing.client || thing.ckey || thing.mind)

/// "1 protected tile (a wall or floor the game won't let you change)"
/proc/babylon_area_protected_text(count)
	return "[count] protected tile[count == 1 ? "" : "s"] (walls or floors the game won't let you change)"

/// The tiles of a rectangle, column by column from its south-west corner.
/proc/babylon_area_tiles(x1, y1, x2, y2, z)
	var/list/tiles = list()
	for(var/x in x1 to x2)
		for(var/y in y1 to y2)
			tiles += locate(x, y, z)
	return tiles

/// The tiles on a rectangle's edge (only those inside the map).
/proc/babylon_area_edge(x1, y1, x2, y2, z)
	var/list/tiles = list()
	for(var/x in x1 to x2)
		for(var/y in y1 to y2)
			if(x != x1 && x != x2 && y != y1 && y != y2)
				continue
			var/turf/tile = locate(x, y, z)
			if(tile)
				tiles += tile
	return tiles

/// A tile a player can be put on.
/proc/babylon_area_free(turf/tile)
	return tile && !isclosedturf(tile) && !babylon_area_locked(tile) && !tile.is_blocked_turf(TRUE)

/// What a moved player is told. The running operation may set another text (a tutorial's Paste
/// area says the room was reset); one area operation runs at a time, and it puts null back.
GLOBAL_VAR(babylon_area_move_message)

/// Moves a player (or another mob) to the nearest free tile outside a rectangle. Returns the
/// tile, or null.
/proc/babylon_area_move_out(mob/living/body, list/rect)
	var/turf/from = get_turf(body)
	if(!from)
		return null
	for(var/distance in 1 to 20)
		var/turf/best
		var/best_score = INFINITY
		for(var/turf/tile as anything in babylon_area_edge(rect[1] - distance, rect[2] - distance, rect[3] + distance, rect[4] + distance, rect[5]))
			if(!babylon_area_free(tile))
				continue
			// Floors before open space.
			var/score = get_dist(from, tile) + (isspaceturf(tile) ? 100 : 0)
			if(score < best_score)
				best = tile
				best_score = score
		if(best)
			body.buckled?.unbuckle_mob(body, TRUE)
			// Out of a mech or other sealed vehicle properly, so it does not drop them back in later.
			if(istype(body.loc, /obj/vehicle/sealed))
				var/obj/vehicle/sealed/vehicle = body.loc
				vehicle.mob_exit(body, TRUE)
			body.forceMove(best)
			to_chat(body, span_notice(GLOB.babylon_area_move_message || "A builder changed the area you were in: you were moved aside."))
			return best
	return null

/// Moves every player on these tiles (or inside something on them) out of the rectangle.
/// may_pause: FALSE when the caller needs the tiles to stay as they are (it clears them next).
/// all_mobs: every living mob, not only players (the tile is about to become solid).
/proc/babylon_area_evict(list/tiles, list/rect, may_pause = TRUE, all_mobs = FALSE)
	. = 0
	for(var/turf/tile as anything in tiles)
		for(var/mob/living/body in tile.get_all_contents())
			if(all_mobs ? !QDELETED(body) : babylon_area_is_player(body))
				if(babylon_area_move_out(body, rect))
					.++
		if(may_pause)
			BABYLON_AREA_TICK

/// Objects the game protects (INDESTRUCTIBLE: vault parts, unique machines ...). The area tools
/// never remove or copy them. Tutorial objects are flagged too, but only against damage.
/proc/babylon_area_protected_object(obj/thing)
	return (thing.resistance_flags & INDESTRUCTIBLE) && !istype(thing, /obj/babylon_tutorial)

/// Objects Clear and Paste remove (effects such as landmarks and lighting stay, and protected
/// objects).
/proc/babylon_area_removable(obj/thing)
	if(QDELETED(thing))
		return FALSE
	if(istype(thing, /obj/babylon_tutorial))
		return TRUE
	if(istype(thing, /obj/effect) && !istype(thing, /obj/effect/decal))
		return FALSE
	if(istype(thing, /obj/docking_port))
		return FALSE
	if(babylon_area_protected_object(thing))
		return FALSE
	return TRUE

/// How many objects and mobs a rectangle holds (the per-operation cap).
/proc/babylon_area_object_count(list/rect)
	. = 0
	for(var/turf/tile as anything in babylon_area_tiles(rect[1], rect[2], rect[3], rect[4], rect[5]))
		. += length(tile.contents)

/// Why a rectangle holds too much for one operation, or null.
/proc/babylon_area_too_full(list/rect)
	var/count = babylon_area_object_count(rect)
	if(count > BABYLON_AREA_MAX_OBJECTS)
		return "That area holds [count] objects; the tools handle at most [BABYLON_AREA_MAX_OBJECTS] at once. Select a smaller area."
	return null

/// Removes objects and non-player mobs from tiles; players are moved out of the rectangle first.
/// Returns counts: list("objects", "tutorial", "mobs", "moved", "kept", "occupied").
/// occupied: tiles kept as they were because a player could not be moved off them.
/// Each tile is handled within one tick: its players (also inside lockers, body bags, mechs) are
/// moved out, then its contents go, so nobody can step or be put in between.
/// turf_path: then the tile becomes this turf, in the same tick (Clear).
/// keep_tutorial (a tutorial's Paste area action, room_reset.dm): tutorial objects, tutorial NPCs
/// and builder tools (and whatever holds one) stay where they are.
/proc/babylon_area_clear_tiles(list/tiles, list/rect, turf_path, keep_tutorial = FALSE)
	var/list/counts = list("objects" = 0, "tutorial" = 0, "mobs" = 0, "moved" = 0, "kept" = 0, "occupied" = 0)
	for(var/turf/tile as anything in tiles)
		counts["moved"] += babylon_area_evict(list(tile), rect, FALSE)
		for(var/mob/living/body in tile)
			if(babylon_area_is_player(body) || (keep_tutorial && body.babylon_tutorial_npc))
				continue
			counts["mobs"]++
			babylon_area_delete(body)
		for(var/obj/thing in tile)
			if(!QDELETED(thing) && babylon_area_protected_object(thing))
				counts["kept"]++
				continue
			if(!babylon_area_removable(thing))
				continue
			if(keep_tutorial && babylon_area_kept_by_tutorial(thing))
				continue
			// Deleting a container deletes what it holds: players (checked again, just before) and
			// protected items come out first.
			for(var/mob/living/body in thing.get_all_contents())
				if(babylon_area_is_player(body) && babylon_area_move_out(body, rect))
					counts["moved"]++
			// No free tile for someone inside: the container (locker, body bag, mech) stays.
			var/still_inside = FALSE
			for(var/mob/living/body in thing.get_all_contents())
				if(babylon_area_is_player(body))
					still_inside = TRUE
			if(still_inside)
				counts["kept"]++
				continue
			for(var/obj/inner in thing.get_all_contents())
				if(inner != thing && babylon_area_protected_object(inner))
					inner.forceMove(tile)
					counts["kept"]++
			// A tutorial NPC goes with its spawner.
			counts[istype(thing, /obj/babylon_tutorial) ? "tutorial" : "objects"]++
			babylon_area_delete(thing)
		if(turf_path && tile.type != turf_path)
			// No free tile for a player still here (also inside something): no wall around them.
			if(ispath(turf_path, /turf/closed) && babylon_area_player_on(tile))
				counts["occupied"]++
			else
				babylon_area_change_turf(tile, turf_path, babylon_area_air_flags(tile))
		BABYLON_AREA_TICK
	return counts

/// What a tutorial's Paste area leaves where it is: tutorial objects, builder tools and anything
/// holding a builder tool.
/proc/babylon_area_kept_by_tutorial(obj/thing)
	if(istype(thing, /obj/babylon_tutorial))
		return TRUE
	if(isitem(thing))
		var/obj/item/item = thing
		if(item.babylon_builder_tool)
			return TRUE
	for(var/obj/item/inner in thing.get_all_contents())
		if(inner.babylon_builder_tool)
			return TRUE
	return FALSE

/// A player is on a tile or inside something on it.
/proc/babylon_area_player_on(turf/tile)
	for(var/mob/living/body in tile.get_all_contents())
		if(babylon_area_is_player(body))
			return TRUE
	return FALSE

/// After a map load: players who walked into the footprint while it loaded, or could not be moved
/// out before it, and now stand in a wall or a dense object are moved out. Where no free tile is
/// found, a wall with a player in it becomes plating. Other mobs (a tutorial NPC a Paste area
/// kept, an animal that walked in) are moved out of walls only: an NPC lying on a table or bed
/// stays there; without a free tile it stays, logged (no wall is opened for it).
/// away: the rectangle they are moved out of (the footprint; tests pass one with no free tile).
/proc/babylon_area_rescue(list/rect, list/away = rect)
	. = 0
	for(var/turf/tile as anything in babylon_area_tiles(rect[1], rect[2], rect[3], rect[4], rect[5]))
		if(!isclosedturf(tile) && !tile.is_blocked_turf(TRUE))
			continue
		for(var/mob/living/body in tile.get_all_contents())
			if(QDELETED(body))
				continue
			var/player = babylon_area_is_player(body)
			if(!player && !isclosedturf(tile))
				continue
			if(babylon_area_move_out(body, away))
				.++
			else if(!player)
				log_world("BABYLON AREA: no free tile for [body] in a pasted wall at [tile.x],[tile.y],[tile.z]; it stays.")
		if(isclosedturf(tile) && !babylon_area_locked(tile) && babylon_area_player_on(tile))
			log_world("BABYLON AREA: no free tile for a player in a pasted wall at [tile.x],[tile.y],[tile.z]; it becomes plating.")
			babylon_area_change_turf(tile, /turf/open/floor/plating, babylon_area_air_flags(tile))

// No try in the area tools (and nothing that calls them): an uncaught runtime or stack_trace()
// ends only the proc it happens in, and its caller goes on. A try would instead unwind every
// proc between the error and the try: one stack_trace() deep in a Destroy() or a reconcile step
// would abort the rest of that delete, turf change or paste and leave it half done. Each step
// that may fail is a proc of its own that returns TRUE at its end; a falsy return means it was
// cut short, and the caller logs it and goes on. Guarded by tools/babylon/test_no_try.py.

/// Deletes one thing.
/proc/babylon_area_delete(datum/thing)
	qdel(thing)

/// Changes one turf. Returns the turf at that spot (also when the change was cut short).
/proc/babylon_area_change_turf(turf/tile, path, flags)
	var/x = tile.x
	var/y = tile.y
	var/z = tile.z
	var/turf/changed = tile.ChangeTurf(path, null, flags)
	if(!changed)
		log_world("BABYLON AREA: changing the turf at [x],[y],[z] to [path] was cut short.")
	return changed || locate(x, y, z)

/// A tile counts as empty for "Only empty tiles": not a wall, no mobs, nothing on it but things
/// under the floor (pipes, cables, lattices) and hidden objects.
/proc/babylon_area_empty(turf/tile)
	if(isclosedturf(tile))
		return FALSE
	for(var/mob/living/body in tile)
		return FALSE
	var/static/list/ignored = typecacheof(list(/obj/effect, /obj/babylon_tutorial, /obj/structure/cable, /obj/machinery/atmospherics/pipe, /obj/structure/disposalpipe, /obj/structure/lattice))
	for(var/obj/thing in tile)
		if(!ignored[thing.type])
			return FALSE
	return TRUE

/// Re-smooths walls, windows and tables in and around a rectangle (after a map load).
/proc/babylon_area_resmooth(list/rect)
	for(var/turf/tile as anything in babylon_area_tiles(max(1, rect[1] - 1), max(1, rect[2] - 1), min(world.maxx, rect[3] + 1), min(world.maxy, rect[4] + 1), rect[5]))
		if(tile.smoothing_flags)
			QUEUE_SMOOTH(tile)
		for(var/atom/movable/thing as anything in tile)
			if(thing.smoothing_flags)
				QUEUE_SMOOTH(thing)
		BABYLON_AREA_TICK

/// Smooths at once whatever waits for icon smoothing in and around a rectangle. Before a map
/// load: the loader pauses between batches, and the smoothing subsystem would then smooth these
/// against loaded but not yet initialized atoms ("bad index" runtimes).
/proc/babylon_area_smooth_now(list/rect)
	for(var/turf/tile as anything in babylon_area_tiles(max(1, rect[1] - 1), max(1, rect[2] - 1), min(world.maxx, rect[3] + 1), min(world.maxy, rect[4] + 1), rect[5]))
		if((tile.smoothing_flags & SMOOTH_QUEUED) && (tile.flags_1 & INITIALIZED_1))
			tile.smooth_icon()
		for(var/atom/movable/thing as anything in tile)
			if((thing.smoothing_flags & SMOOTH_QUEUED) && (thing.flags_1 & INITIALIZED_1))
				thing.smooth_icon()

/// The pipes and devices of a loaded copy, instead of tg's template setup (which builds the
/// copy's pipenets at once and then crashes or leaves split nets where they meet existing ones,
/// especially devices such as a pump next to a vent):
/// 1. every loaded machine finds its nodes (atmos_init); a multi-deck pipe also links to the
///    multi-deck pipes above and below it now (tg does that only when it builds the pipenet);
/// 2. a node that is not one of the loaded machines (around the paste, on another deck, or a
///    machine that stayed in the footprint) finds the loaded one too, so links go both ways (a
///    one-way link is dropped: it would break both pipes' deletion later);
/// 3. those outside machines' pipenets are dropped (a pipeline keeps its gas in its pipes when it
///    is deleted; a net of devices only is let go by its devices, tg deletes it then);
/// 4. everything is queued: the air subsystem builds one network across the edge, as when pipes
///    are built by hand.
/// machines: only the machines this paste loaded.
/proc/babylon_area_setup_pipes(list/machines)
	var/list/nets = list()
	var/list/rebuild = list()
	var/list/loaded = list()
	for(var/obj/machinery/atmospherics/machine as anything in machines)
		loaded[machine] = TRUE
	for(var/obj/machinery/atmospherics/machine as anything in machines)
		if(QDELETED(machine))
			continue
		if(!babylon_area_pipe_init(machine))
			GLOB.babylon_area_link_failures++
			log_world("BABYLON AREA: setting up [machine.type] was cut short.")
		rebuild |= machine
	for(var/obj/machinery/atmospherics/machine as anything in machines)
		if(QDELETED(machine))
			continue
		for(var/obj/machinery/atmospherics/node in machine.nodes.Copy())
			if(loaded[node])
				continue
			if(!QDELETED(node) && get_turf(node) && !babylon_area_pipe_init(node, FALSE))
				GLOB.babylon_area_link_failures++
				log_world("BABYLON AREA: connecting [machine.type] to [node.type] was cut short.")
			if(!QDELETED(node) && (machine in node.nodes))
				nets |= node.return_pipenets()
				rebuild |= node
			else
				var/index = machine.nodes.Find(node)
				if(index)
					machine.nodes[index] = null
					machine.update_appearance()
	for(var/datum/pipeline/net as anything in nets)
		if(net && !QDELETED(net) && !babylon_area_drop_pipenet(net, rebuild))
			GLOB.babylon_area_link_failures++
			log_world("BABYLON AREA: dropping a pipenet on the paste edge was cut short.")
	for(var/obj/machinery/atmospherics/machine as anything in rebuild)
		if(!QDELETED(machine))
			SSair.add_to_rebuild_queue(machine)

/// Sets up one pipe or device (multi-z pipes also expand). TRUE when it got to the end.
/proc/babylon_area_pipe_init(obj/machinery/atmospherics/machine, expand = TRUE)
	machine.atmos_init()
	if(expand && istype(machine, /obj/machinery/atmospherics/pipe/multiz))
		machine.pipeline_expansion()
	return TRUE

/// Lets go of a pipenet on the paste edge (step 3 above). TRUE when it got to the end.
/proc/babylon_area_drop_pipenet(datum/pipeline/net, list/rebuild)
	if(!length(net.members))
		for(var/obj/machinery/atmospherics/components/device as anything in net.other_atmos_machines.Copy())
			device.nullify_pipenet(net)
			rebuild |= device
	else
		qdel(net)
	return TRUE

/// Pipes in a rectangle that list a pipe which does not list them back (tests).
/proc/babylon_area_one_way_nodes(list/rect)
	. = 0
	for(var/turf/tile as anything in babylon_area_tiles(rect[1], rect[2], rect[3], rect[4], rect[5]))
		for(var/obj/machinery/atmospherics/machine in tile)
			for(var/obj/machinery/atmospherics/node in machine.nodes)
				if(!(machine in node.nodes))
					.++

// ---------------------------------------------------------------------------------------------
// Materials: what Fill, Border and Clear may put down

/// Turfs and structures Fill and Border offer: list(list("path", "name", "group")), and the
/// same as a lookup by path text.
/proc/babylon_area_materials()
	var/static/list/materials
	if(materials)
		return materials
	materials = list()
	var/list/blocked_roots = list(/turf/open/floor/holofloor, /turf/open/floor/fakespace, /turf/open/floor/fakepit, /turf/closed/wall/material, /turf/open/floor/material, /turf/closed/indestructible, /turf/open/indestructible, /turf/open/space/transit, /turf/open/floor/engine/hull)
	var/list/blocked = list()
	for(var/root in blocked_roots)
		if(ispath(root))
			blocked |= typesof(root)
	var/list/groups = list(
		list("Floors", /turf/open/floor),
		list("Walls", /turf/closed/wall),
		list("Outdoors", /turf/open/misc),
	)
	materials += list(list("path" = "[/turf/open/space]", "name" = "space", "group" = "Space"))
	for(var/list/group as anything in groups)
		var/root = group[2]
		for(var/turf/path as anything in typesof(root))
			if(blocked.Find(path) || initial(path.abstract_type) == path)
				continue
			if(initial(path.resistance_flags) & INDESTRUCTIBLE)
				continue
			if(ispath(path, /turf/open))
				var/turf/open/open_path = path
				// Only breathable, normal air: no airless, planetary or special-gas floors.
				if(initial(open_path.initial_gas_mix) != OPENTURF_DEFAULT_ATMOS || initial(open_path.planetary_atmos))
					continue
			var/group_name = group[1]
			if(ispath(path, /turf/open/floor/plating))
				group_name = "Plating"
			materials += list(list("path" = "[path]", "name" = "[initial(path.name)]", "group" = group_name))
	var/list/structures = list(/obj/structure/grille, /obj/structure/girder, /obj/structure/lattice, /obj/structure/lattice/catwalk, /obj/structure/table, /obj/structure/table/reinforced, /obj/structure/table/glass, /obj/structure/table/wood, /obj/structure/barricade/wooden)
	for(var/obj/structure/window/window as anything in subtypesof(/obj/structure/window))
		if(findtext("[window]", "/fulltile") && !findtext("[window]", "/unanchored") && !findtext("[window]", "/spawner") && initial(window.abstract_type) != window)
			structures += window
	for(var/obj/path as anything in structures)
		if(ispath(path))
			materials += list(list("path" = "[path]", "name" = "[initial(path.name)]", "group" = "Structures"))
	return materials

/// The material for a path text, or null when it is not offered.
/proc/babylon_area_material(path_text)
	var/static/list/by_path
	if(!by_path)
		by_path = list()
		for(var/list/material as anything in babylon_area_materials())
			by_path[material["path"]] = material
	return by_path["[path_text]"]

// ---------------------------------------------------------------------------------------------
// Clipboard: capturing an area and building it somewhere

/datum/babylon_area_clip
	var/width = 0
	var/height = 0
	/// One entry per tile, column by column from the south-west corner:
	/// list("turf" = "path{vars}", "objects" = list("path{vars}", ...), "space" = TRUE/FALSE).
	var/list/tiles = list()
	/// Clip tag => list("fields" = settings (babylon_area_capture_settings),
	/// "reagents" = list(list(type, volume)), "contents" = nested entries).
	var/list/extras = list()
	/// Tutorial objects: list("dx", "dy", "type", "id", "settings", "dir", "pixel_x", "pixel_y", "npc").
	var/list/tutorial = list()
	/// The south-west corner it was copied from: list(x, y, z).
	var/list/origin
	var/object_count = 0
	var/nested_count = 0
	/// What the copy left out: mobs, protected objects, protected tiles, turfs it can't build.
	var/skipped_mobs = 0
	var/skipped_protected = 0
	var/skipped_locked = 0
	var/replaced_turfs = 0
	/// Made from stored data (babylon_area_clip_from_data): settings are applied only for the
	/// fields the save engine keeps for the object's type.
	var/from_storage = FALSE

/// The tile entry at an offset from the south-west corner.
/datum/babylon_area_clip/proc/entry(dx, dy)
	return tiles[dx * height + dy + 1]

// ---------------------------------------------------------------------------------------------
// Stored clips: a tutorial's Paste area action (room_reset.dm) keeps a clip in its settings, so it
// is saved with the world and travels with a submitted, played or copied tutorial.

/// The stored clip format. Bump it when the clip's fields change: a clip stored in another version
/// is refused with a clear message (babylon_area_clip_from_data), never pasted half understood.
/// 1: the first format (a list of every tile, then a palette); 2: palette + grid, sizes measured.
#define BABYLON_AREA_CLIP_VERSION 2
/// The most one stored area (a Paste area's snapshot) may take, measured as its JSON. Checked
/// wherever a snapshot is made, copied or loaded (babylon_area_clip_data_problem).
#define BABYLON_AREA_SNAPSHOT_BYTES (512 * 1024)
/// The most all stored areas of a world may take together (room_reset.dm). A variable so tests can
/// lower it.
GLOBAL_VAR_INIT(babylon_area_snapshots_total_bytes, 4 * 1024 * 1024)

/// The clip as JSON-safe data. Tutorial objects are left out: a stored room never carries them
/// (the room's own tutorial objects stay where they are when it is pasted). Tiles are stored as a
/// palette of distinct tile entries plus one palette index per tile (like a map's keys), so a
/// room of plain floors costs one entry.
/datum/babylon_area_clip/proc/to_data()
	var/list/palette = list()
	var/list/grid = list()
	var/list/index_of = list()
	for(var/list/entry as anything in tiles)
		var/key = json_encode(entry)
		var/index = index_of[key]
		if(!index)
			palette += list(entry)
			index = length(palette)
			index_of[key] = index
		grid += index
	var/list/stored_extras = list()
	for(var/tag in extras)
		var/list/extra = extras[tag]
		var/list/stored = list()
		if(extra["fields"])
			var/list/fields = list()
			var/list/given = extra["fields"]
			for(var/field in given)
				if(babylon_area_storable(given[field]))
					fields[field] = babylon_area_store_value(given[field])
			if(length(fields))
				stored["fields"] = fields
		if(extra["reagents"])
			stored["reagents"] = extra["reagents"]
		if(!isnull(extra["contents"]))
			stored["contents"] = extra["contents"]
		stored_extras["[tag]"] = stored
	return list(
		"version" = BABYLON_AREA_CLIP_VERSION,
		"width" = width,
		"height" = height,
		"origin" = origin.Copy(),
		"palette" = palette,
		"grid" = grid,
		"extras" = stored_extras,
		"objects" = object_count,
		"nested" = nested_count,
		"skipped_mobs" = skipped_mobs,
		"skipped_protected" = skipped_protected,
		"skipped_locked" = skipped_locked,
		"replaced_turfs" = replaced_turfs,
		"skipped_tutorial" = length(tutorial),
	)

/// A setting value JSON can carry (with babylon_area_store_value): null, a number, a text, a
/// type path, or a list of those (two levels deep). References to atoms are not.
/proc/babylon_area_storable(value, depth = 0)
	if(isnull(value) || isnum(value) || istext(value) || ispath(value))
		return TRUE
	if(!islist(value) || depth >= 2)
		return FALSE
	var/list/values = value
	for(var/key in values)
		if(!(istext(key) || isnum(key) || ispath(key)))
			return FALSE
		if(!babylon_area_storable(key, depth + 1))
			return FALSE
		if(!isnum(key) && !isnull(values[key]) && !babylon_area_storable(values[key], depth + 1))
			return FALSE
	return TRUE

/// A storable value as JSON data: paths and lists are wrapped so they come back as they were.
/proc/babylon_area_store_value(value)
	if(ispath(value))
		return list("path" = "[value]")
	if(islist(value))
		var/list/values = value
		var/list/entries = list()
		for(var/key in values)
			entries += list(list(babylon_area_store_value(key), (!isnum(key) && !isnull(values[key])) ? babylon_area_store_value(values[key]) : null))
		return list("list" = entries)
	return value

/proc/babylon_area_load_value(value)
	if(!islist(value))
		return value
	var/list/wrapped = value
	if(!isnull(wrapped["path"]))
		return text2path("[wrapped["path"]]")
	var/list/result = list()
	for(var/list/entry in wrapped["list"])
		if(length(entry) < 2)
			continue
		var/key = babylon_area_load_value(entry[1])
		result += list(key)
		if(!isnull(entry[2]) && !isnum(key) && !isnull(key))
			result[key] = babylon_area_load_value(entry[2])
	return result

/// Why stored clip data can't be pasted (missing, another version, damaged, or over the size cap),
/// or null. size: its JSON's length when the caller knows it (a Paste area caches it); otherwise
/// it is measured here. Never a size the data says about itself.
/proc/babylon_area_clip_data_problem(list/data, size = null)
	if(!islist(data) || !length(data))
		return "No area is stored yet."
	var/version = data["version"]
	if(version != BABYLON_AREA_CLIP_VERSION)
		var/age = isnum(version) && version > BABYLON_AREA_CLIP_VERSION ? "a newer" : "an older"
		return "This area was stored in [age] format (version [isnum(version) ? version : "unknown"]; this server reads version [BABYLON_AREA_CLIP_VERSION]), so it can't be pasted. Select the area with the world-edit wand and store it again."
	var/width = data["width"]
	var/height = data["height"]
	var/list/origin = data["origin"]
	var/list/palette = data["palette"]
	var/list/grid = data["grid"]
	if(!isnum(width) || !isnum(height) || width < 1 || height < 1 || width * height > BABYLON_AREA_MAX_TILES || !islist(origin) || length(origin) != 3 || !islist(palette) || !length(palette) || length(palette) > width * height || !islist(grid) || length(grid) != width * height)
		return "The stored area is damaged, so it can't be pasted. Select the area with the world-edit wand and store it again."
	if(isnull(size))
		size = length(json_encode(data))
	if(size > BABYLON_AREA_SNAPSHOT_BYTES)
		return "This stored area takes [babylon_area_kb(size)]; a stored area may take at most [babylon_area_kb(BABYLON_AREA_SNAPSHOT_BYTES)], so it can't be pasted. Select a smaller area with the world-edit wand and store it again."
	return null

/// "38 KB"
/proc/babylon_area_kb(bytes)
	return "[max(1, round(bytes / 1024))] KB"

/// A clip from stored data: list("clip" = clip, "missing" = types that no longer exist) or
/// list("error" = why not). A type this server no longer has is left out (a turf becomes plating),
/// so a stored room never breaks the map load.
/proc/babylon_area_clip_from_data(list/data, size = null)
	var/problem = babylon_area_clip_data_problem(data, size)
	if(problem)
		return list("error" = problem)
	var/datum/babylon_area_clip/clip = new
	clip.width = round(data["width"])
	clip.height = round(data["height"])
	var/list/origin = data["origin"]
	clip.origin = list(round(text2num("[origin[1]]") || 1), round(text2num("[origin[2]]") || 1), round(text2num("[origin[3]]") || 1))
	clip.from_storage = TRUE
	var/list/missing = list()
	// Each palette entry is checked once: its texts must be plain map entries of known, harmless
	// types (a stored room is data, never a way past the spawn blocklist).
	var/list/entries = list()
	for(var/list/stored in data["palette"])
		if(!islist(stored) || !istext(stored["turf"]))
			return list("error" = "The stored area is damaged, so it can't be pasted. Select the area with the world-edit wand and store it again.")
		var/list/entry = list("turf" = stored["turf"], "objects" = list(), "space" = !!stored["space"])
		if(stored["keep"])
			entry["keep"] = TRUE
			entry["turf"] = "/turf/template_noop"
		else if(!babylon_area_entry_valid(stored["turf"], /turf))
			missing |= babylon_area_entry_path_text(stored["turf"])
			entry["turf"] = "[/turf/open/floor/plating]"
		for(var/object_text in stored["objects"])
			if(!istext(object_text))
				continue
			if(!babylon_area_entry_valid(object_text, /obj))
				missing |= babylon_area_entry_path_text(object_text)
				continue
			entry["objects"] += object_text
		entries += list(entry)
		BABYLON_AREA_TICK
	for(var/index in data["grid"])
		if(!isnum(index) || index < 1 || index > length(entries))
			return list("error" = "The stored area is damaged, so it can't be pasted. Select the area with the world-edit wand and store it again.")
		clip.tiles += list(entries[index])
	var/list/stored_extras = data["extras"]
	if(islist(stored_extras))
		for(var/tag in stored_extras)
			var/list/stored = stored_extras[tag]
			if(!islist(stored))
				continue
			var/list/extra = list()
			if(islist(stored["fields"]))
				var/list/fields = list()
				var/list/given = stored["fields"]
				for(var/field in given)
					fields[field] = babylon_area_load_value(given[field])
				extra["fields"] = fields
			if(islist(stored["reagents"]))
				extra["reagents"] = stored["reagents"]
			if(islist(stored["contents"]))
				extra["contents"] = babylon_area_clean_stored_contents(stored["contents"], 1)
			clip.extras["[tag]"] = extra
	clip.object_count = round(text2num("[data["objects"]]") || 0)
	clip.nested_count = round(text2num("[data["nested"]]") || 0)
	return list("clip" = clip, "missing" = missing)

/// "/obj/structure/table" from a map entry ("/obj/structure/table{\n\tdir = 4\n\t}").
/proc/babylon_area_entry_path_text(text)
	var/brace = findtext(text, "{")
	return brace ? copytext(text, 1, brace) : text

/// The map entry's type when it exists under base, else null.
/proc/babylon_area_entry_type(text, base)
	var/path = text2path(babylon_area_entry_path_text(text))
	return ispath(path, base) ? path : null

/// A stored map entry is one plain entry as babylon_area_metadata() writes it ("/path", or
/// "/path{" plus lines that each start with a tab, then "}"): nothing can start a second entry.
/// Its type must exist under base, and an object's must not be harmful (the spawn blocklist).
/proc/babylon_area_entry_valid(text, base)
	var/static/regex/path_shape = regex(@"^/[A-Za-z0-9_/]+$")
	var/brace = findtext(text, "{")
	if(!path_shape.Find(brace ? copytext(text, 1, brace) : text))
		return FALSE
	if(brace)
		// "{", then lines that each start with a tab, then "}" as the very last character; no
		// other brace (tgm_encode strips them from texts).
		if(copytext(text, -1) != "}")
			return FALSE
		var/body = copytext(text, brace + 1, -1)
		if(findtext(body, "{") || findtext(body, "}"))
			return FALSE
		var/list/lines = splittext(body, "\n")
		if(length(lines) < 2 || length(lines[1]))
			return FALSE
		for(var/index in 2 to length(lines))
			if(copytext(lines[index], 1, 2) != "\t")
				return FALSE
	var/path = babylon_area_entry_type(text, base)
	if(!path)
		return FALSE
	return ispath(path, /turf) || !babylon_creative_type_harmful(path)

/// Stored container contents with only existing, harmless item types (depth as in a capture).
/proc/babylon_area_clean_stored_contents(list/entries, depth)
	var/list/kept = list()
	for(var/list/entry in entries)
		var/path = text2path("[entry["type"]]")
		if(!ispath(path, /obj/item) || babylon_creative_type_harmful(path))
			continue
		var/list/clean = list("type" = "[path]")
		if(istext(entry["name"]))
			clean["name"] = strip_html("[entry["name"]]", 64)
		if(isnum(entry["amount"]))
			clean["amount"] = entry["amount"]
		if(islist(entry["reagents"]))
			clean["reagents"] = entry["reagents"]
		if(islist(entry["contents"]) && depth < 4)
			clean["contents"] = babylon_area_clean_stored_contents(entry["contents"], depth + 1)
		kept += list(clean)
	return kept

/// Copies a rectangle (south-west and north-east corners). Protected (indestructible) tiles are
/// left out: a paste leaves the target there as it is, so the Creative Plane's edge can't be
/// carried elsewhere. faithful: an undo snapshot, which keeps every other turf as it is; a copy
/// turns turfs the materials list does not offer (lava, hull, airless floors ...) into plating.
/proc/babylon_area_capture(x1, y1, x2, y2, z, faithful = FALSE)
	var/datum/babylon_area_clip/clip = new
	clip.width = x2 - x1 + 1
	clip.height = y2 - y1 + 1
	clip.origin = list(x1, y1, z)
	for(var/dx in 0 to clip.width - 1)
		for(var/dy in 0 to clip.height - 1)
			var/turf/tile = locate(x1 + dx, y1 + dy, z)
			if(babylon_area_locked(tile))
				clip.skipped_locked++
				clip.tiles += list(list("turf" = "/turf/template_noop", "objects" = list(), "space" = FALSE, "keep" = TRUE))
				continue
			var/list/objects = list()
			for(var/obj/thing in tile)
				if(istype(thing, /obj/babylon_tutorial))
					clip.tutorial += list(babylon_area_capture_tutorial(thing, dx, dy))
					continue
				if(!QDELETED(thing) && thing.loc == tile && babylon_area_protected_object(thing))
					clip.skipped_protected++
					continue
				if(!babylon_area_copyable(thing, tile))
					continue
				// Only objects with settings, reagents or contents get a tag (the paste finds them
				// by it): untagged entries of the same kind are alike, so stored rooms deduplicate.
				var/list/extra = babylon_area_capture_extra(thing, clip)
				var/tag = extra ? "[++GLOB.babylon_area_next_tag]" : null
				objects += "[thing.type][babylon_area_metadata(thing, tag, faithful)]"
				if(extra)
					clip.extras[tag] = extra
				clip.object_count++
			for(var/mob/living/body in tile)
				clip.skipped_mobs++
			var/turf_text
			if(faithful || isspaceturf(tile) || babylon_area_material("[tile.type]"))
				turf_text = "[isspaceturf(tile) ? /turf/open/space : tile.type][babylon_area_metadata(tile)]"
			else
				clip.replaced_turfs++
				turf_text = "[/turf/open/floor/plating][isopenturf(tile) ? babylon_area_metadata(tile) : ""]"
			clip.tiles += list(list("turf" = turf_text, "objects" = objects, "space" = isspaceturf(tile)))
		BABYLON_AREA_TICK
	return clip

/// Objects a copy takes along: not hidden effects, projectiles or holograms, nor anything a save
/// leaves out (babylon_skip_save(), persistence.dm: tutorial NPC gear and whatever else opts out).
/proc/babylon_area_copyable(obj/thing, turf/tile)
	if(QDELETED(thing) || thing.loc != tile)
		return FALSE
	if(istype(thing, /obj/effect) && !istype(thing, /obj/effect/decal))
		return FALSE
	if(istype(thing, /obj/projectile) || istype(thing, /obj/docking_port))
		return FALSE
	// Builder tools (both wands) are never copied: one per builder, from the Creative panel.
	if(isitem(thing))
		var/obj/item/item = thing
		if(item.babylon_builder_tool)
			return FALSE
	if(thing.flags_1 & HOLOGRAM_1)
		return FALSE
	if(thing.babylon_skip_save())
		return FALSE
	if(babylon_area_protected_object(thing))
		return FALSE
	// An APC makes its own terminal when it is loaded.
	if(istype(thing, /obj/machinery/power/terminal))
		var/obj/machinery/power/terminal/terminal = thing
		if(istype(terminal.master, /obj/machinery/power/apc))
			return FALSE
	return TRUE

/// Fields a copy writes into its map on top of the save engine's map fields: state that a save
/// keeps in its records, but that a pasted object must have while it initializes.
#define BABYLON_AREA_CLIP_FIELDS list("desc", "color", "opened", "locked")

/// The map vars of an object or turf ("{\n\tdir = 4;\n\t...}"), from the save engine's own field
/// list (babylon_save.map_fields(): build state, pipe layers, cable links, access, and the map link
/// fields that link buttons, doors, cameras, radios ...) plus BABYLON_AREA_CLIP_FIELDS, and for
/// floors their air. Only values that differ from the type's are written. faithful (an undo
/// snapshot): an APC keeps its areastring; a copy builds its APC for the area it lands in.
/proc/babylon_area_metadata(atom/thing, tag, faithful = FALSE)
	var/datum/babylon_save/engine = GLOB.babylon_save
	var/list/entries = list()
	if(tag)
		entries += "babylon_clip_tag = \"[tag]\""
	for(var/field in engine.map_fields(thing) | BABYLON_AREA_CLIP_FIELDS)
		if(!(field in thing.vars))
			continue
		if(field == "areastring" && !faithful)
			continue
		if(field == "icon_state" && thing.smoothing_flags)
			continue
		if(!issaved(thing.vars[field]))
			continue
		var/value = thing.vars[field]
		// Without the source deck's multi-z offset: Initialize adds the target deck's
		// (babylon_true_plane, persistence.dm).
		if(field == "plane")
			value = babylon_true_plane(value)
		if(babylon_save_keeps_default_text(thing, field, value))
			continue
		if(islist(value))
			var/list/values = value
			if(!length(values) || !(field in engine.list_map_fields))
				continue
		else
			if(!(isnull(value) || isnum(value) || istext(value) || ispath(value)))
				continue
			if(value == initial(thing.vars[field]))
				continue
		entries += "[field] = [tgm_encode(istext(value) ? babylon_save_text(value) : value)]"
	if(isopenturf(thing) && !isspaceturf(thing))
		var/turf/open/open = thing
		var/datum/gas_mixture/gas = open.return_air()
		if(gas)
			entries += "initial_gas_mix = [tgm_encode(gas.to_string())]"
	return length(entries) ? "{\n\t[entries.Join(";\n\t")]\n\t}" : ""

/// An object's settings that are applied once it exists, as a restore applies them: the save
/// engine's extra_fields (babylon_save.setting_fields(): creative machine settings, pump, filter and
/// scrubber modes ...) that differ from the type's. Null if there are none.
/proc/babylon_area_capture_settings(obj/thing)
	var/datum/babylon_save/engine = GLOB.babylon_save
	var/list/settings = list()
	for(var/field in engine.setting_fields(thing))
		// The plane is in the copy's map (babylon_area_metadata), where Initialize offsets it for
		// the target deck; set again afterwards, it would carry the source deck's offset.
		if(field == "plane")
			continue
		var/value = thing.vars[field]
		if(islist(value))
			if(!(field in engine.list_fields))
				continue
			var/list/values = value
			settings[field] = values.Copy()
			continue
		if(!(isnull(value) || isnum(value) || istext(value) || ispath(value)))
			continue
		if(value == initial(thing.vars[field]))
			continue
		settings[field] = value
	// What a variable cannot carry (an ID card's trim), as the save engine captures it.
	thing.babylon_capture_settings(settings)
	return length(settings) ? settings : null

/// Puts captured settings (babylon_area_capture_settings) on a pasted object.
/proc/babylon_area_restore_settings(obj/thing, list/settings)
	for(var/field in settings)
		if(!(field in thing.vars))
			continue
		var/value = settings[field]
		if(islist(value))
			var/list/values = value
			value = values.Copy()
		thing.vars[field] = value
	thing.update_appearance()
	// As after a restore: lights, cameras, canister ports ... reconcile (persistence.dm). A step
	// that fails ends only itself (no try: see babylon_area_delete).
	if(!babylon_area_reconcile(thing, settings))
		log_world("Babylon paste: reconciling [thing.type] was cut short.")

/// babylon_after_restore() on a pasted object. TRUE when it got to the end.
/proc/babylon_area_reconcile(obj/thing, list/settings)
	thing.babylon_after_restore(settings)
	return TRUE

/// A stored extra limited to the setting fields the save engine keeps for this object's type
/// (plus keys that are no variable, for babylon_after_restore), like a loadout's settings.
/proc/babylon_area_stored_extra_for(obj/thing, list/extra)
	var/list/allowed = GLOB.babylon_save.setting_fields(thing)
	var/list/fields = list()
	var/list/given = extra["fields"]
	for(var/field in given)
		if((field in allowed) || !(field in thing.vars))
			fields[field] = given[field]
	var/list/limited = extra.Copy()
	limited["fields"] = fields
	return limited

/// A pasted object's settings, reagents and contents. TRUE when it got to the end.
/proc/babylon_area_restore_extra(obj/thing, list/extra)
	if(extra["fields"])
		babylon_area_restore_settings(thing, extra["fields"])
	if(extra["reagents"])
		babylon_area_restore_reagents(thing, extra["reagents"])
	if(!isnull(extra["contents"]) && babylon_area_is_container(thing))
		babylon_area_restore_contents(thing, extra["contents"])
	return TRUE

/// Closets and storage items: their contents are copied too.
/proc/babylon_area_is_container(atom/thing)
	return istype(thing, /obj/structure/closet) || (isitem(thing) && thing.atom_storage)

/proc/babylon_area_capture_extra(obj/thing, datum/babylon_area_clip/clip)
	var/list/extra = list()
	var/list/settings = babylon_area_capture_settings(thing)
	if(settings)
		extra["fields"] = settings
	var/list/chems = babylon_area_capture_reagents(thing)
	if(chems)
		extra["reagents"] = chems
	if(babylon_area_is_container(thing))
		extra["contents"] = babylon_area_capture_contents(thing, clip, 1)
	return length(extra) ? extra : null

/// The reagents in a holder (an empty list for an empty holder), or null without one.
/proc/babylon_area_capture_reagents(atom/thing)
	if(!thing.reagents)
		return null
	var/list/chems = list()
	for(var/datum/reagent/chem as anything in thing.reagents.reagent_list)
		chems += list(list("[chem.type]", chem.volume))
	return chems

/// The items in a container, recursively for storage items (a medkit in a locker).
/proc/babylon_area_capture_contents(atom/container, datum/babylon_area_clip/clip, depth)
	var/list/entries = list()
	for(var/obj/item/item in container)
		if(QDELETED(item) || item.babylon_skip_save() || (item.flags_1 & HOLOGRAM_1) || item.babylon_builder_tool)
			continue
		if(babylon_area_protected_object(item))
			clip.skipped_protected++
			continue
		if(clip.nested_count >= BABYLON_AREA_MAX_NESTED)
			break
		clip.nested_count++
		var/list/entry = list("type" = "[item.type]")
		if(item.name != initial(item.name))
			entry["name"] = item.name
		if(isstack(item))
			var/obj/item/stack/stack = item
			entry["amount"] = stack.amount
		var/list/chems = babylon_area_capture_reagents(item)
		if(chems)
			entry["reagents"] = chems
		if(item.atom_storage && depth < 4)
			entry["contents"] = babylon_area_capture_contents(item, clip, depth + 1)
		entries += list(entry)
	return entries

/proc/babylon_area_restore_reagents(atom/thing, list/chems)
	if(!thing.reagents)
		return
	thing.reagents.clear_reagents()
	for(var/list/chem as anything in chems)
		var/path = text2path(chem[1])
		if(ispath(path, /datum/reagent))
			thing.reagents.add_reagent(path, chem[2])

/// Replaces a container's items with copied ones.
/proc/babylon_area_restore_contents(atom/container, list/entries)
	for(var/obj/item/item in container)
		if(!babylon_area_protected_object(item))
			qdel(item)
	for(var/list/entry as anything in entries)
		var/path = text2path(entry["type"])
		if(!ispath(path, /obj/item))
			continue
		var/obj/item/item = ispath(path, /obj/item/stack) ? new path(container, entry["amount"] || 1) : new path(container)
		if(QDELETED(item))
			continue
		if(entry["name"])
			item.name = entry["name"]
		if(entry["reagents"])
			babylon_area_restore_reagents(item, entry["reagents"])
		if(!isnull(entry["contents"]) && item.atom_storage)
			babylon_area_restore_contents(item, entry["contents"])

/proc/babylon_area_capture_tutorial(obj/babylon_tutorial/object, dx, dy)
	var/has_npc = FALSE
	if(istype(object, /obj/babylon_tutorial/npc_spawner))
		var/obj/babylon_tutorial/npc_spawner/spawner = object
		has_npc = !!spawner.current_npc()
	return list("dx" = dx, "dy" = dy, "type" = "[object.type]", "id" = object.tutorial_id, "settings" = object.settings_json, "dir" = object.dir, "pixel_x" = object.pixel_x, "pixel_y" = object.pixel_y, "npc" = has_npc)

/// The clip as a map (TGM). skip_space: tiles that were space are left as they are. no_apc: tile
/// indexes ("dx,dy") whose APCs are left out (the target area already has its own).
/// The clip as map text (a single-level TGM map), for tests; files are written from the pieces.
/proc/babylon_area_map_text(datum/babylon_area_clip/clip, skip_space, list/no_apc)
	return jointext(babylon_area_map_pieces(clip, skip_space, no_apc), "")

/// The clip as a TGM map in pieces of at most BABYLON_SAVE_PIECE_BYTES, written with
/// babylon_write_pieces() (persistence.dm) like a save's level maps.
/proc/babylon_area_map_pieces(datum/babylon_area_clip/clip, skip_space, list/no_apc)
	var/list/headers = list()
	var/list/dictionary = list()
	var/list/grid = list()
	var/key_index = 1
	for(var/dx in 0 to clip.width - 1)
		grid += "\n([dx + 1],1,1) = {\"\n"
		for(var/dy in clip.height - 1 to 0 step -1)
			var/list/entry = clip.entry(dx, dy)
			var/header
			if(entry["keep"] || (skip_space && entry["space"]))
				header = "(\n/turf/template_noop,\n/area/template_noop)\n"
			else
				var/list/objects = entry["objects"]
				var/list/parts = objects.Copy()
				if(no_apc?["[dx],[dy]"])
					for(var/object_text in objects)
						if(findtext(object_text, "/obj/machinery/power/apc") == 1)
							parts -= object_text
				parts += entry["turf"]
				// The area stays: the paste never moves rooms between areas (or their APCs).
				parts += "/area/template_noop"
				header = "(\n[parts.Join(",\n")])\n"
			var/key = dictionary[header]
			if(!key)
				key = calculate_tgm_header_index(key_index++, 3)
				dictionary[header] = key
				headers += "\"[key]\" = [header]"
			grid += "[key]\n"
		grid += "\"}\n"
	var/list/pieces = list("//[DMM2TGM_MESSAGE]\n")
	pieces += babylon_join_in_pieces(headers)
	pieces += babylon_join_in_pieces(grid)
	return pieces

/datum/map_template/babylon_clipboard
	name = "Babylon clipboard"
	// The copy replaces the turfs it covers.
	should_place_on_top = FALSE

/// A copy of tg's /datum/map_template/proc/initTemplateBounds (code/modules/mapping/map_template.dm;
/// merge upstream changes here), except that the pipes and devices this paste loaded are set up by
/// babylon_area_setup_pipes(), which joins them to the pipes around the paste properly.
/datum/map_template/babylon_clipboard/initTemplateBounds(list/bounds)
	if(!bounds)
		stack_trace("[name] template failed to initialize correctly!")
		return
	var/list/obj/machinery/atmospherics/loaded_machines = list()
	var/list/obj/structure/cable/cables = list()
	var/list/atom/movable/movables = list()
	var/list/area/areas = list()
	var/list/turfs = block(bounds[MAP_MINX], bounds[MAP_MINY], bounds[MAP_MINZ], bounds[MAP_MAXX], bounds[MAP_MAXY], bounds[MAP_MAXZ])
	for(var/turf/current_turf as anything in turfs)
		areas |= current_turf.loc
		if(!SSatoms.initialized)
			continue
		for(var/movable_in_turf in current_turf)
			if(istype(movable_in_turf, /obj/docking_port/mobile))
				continue
			movables += movable_in_turf
			if(istype(movable_in_turf, /obj/structure/cable))
				cables += movable_in_turf
				continue
			if(istype(movable_in_turf, /obj/machinery/atmospherics))
				// Not initialized yet: loaded by this paste (not a machine that stayed in the footprint).
				var/obj/machinery/atmospherics/machine = movable_in_turf
				if(!(machine.flags_1 & INITIALIZED_1))
					loaded_machines += machine
	SSmapping.reg_in_areas_in_z(areas)
	if(!SSatoms.initialized)
		return
	SSatoms.InitializeAtoms(areas + turfs + movables, returns_created_atoms ? created_atoms : null)
	SSlighting.setup_static_lighting_if_needed(turfs)
	SSmachines.setup_template_powernets(cables)
	babylon_area_setup_pipes(loaded_machines)
	for(var/turf/affected_turf as anything in block(bounds[MAP_MINX] - 1, bounds[MAP_MINY] - 1, bounds[MAP_MINZ], bounds[MAP_MAXX] + 1, bounds[MAP_MAXY] + 1, bounds[MAP_MAXZ]))
		affected_turf.air_update_turf(TRUE, TRUE)
		affected_turf.levelupdate()

/// Old tutorial id => new id for pasting a clip. mode: "auto" (the first free "_2", "_3" ...),
/// "custom" (suffix) or "keep". ignore: objects about to be removed (their ids are free).
/// Returns list("map" = ids, "suffix" = text) or list("error" = why).
/proc/babylon_area_id_map(datum/babylon_area_clip/clip, mode, suffix, list/ignore)
	var/list/ids = list()
	for(var/list/entry as anything in clip.tutorial)
		ids |= entry["id"]
	if(!length(ids))
		return list("map" = list(), "suffix" = "")
	var/list/taken = list()
	for(var/obj/babylon_tutorial/object as anything in GLOB.babylon_tutorial_objects)
		if(!(object in ignore))
			taken[object.tutorial_id] = object
	switch(mode)
		if("keep")
			var/list/map = list()
			for(var/id in ids)
				var/obj/babylon_tutorial/owner = taken[id]
				if(owner)
					var/turf/tile = get_turf(owner)
					return list("error" = "\"Keep ids\" needs free ids, but [id] is already used (a [lowertext(owner.kind_name)] at [tile?.x], [tile?.y]). Choose a suffix, or delete the original first.")
				map[id] = id
			return list("map" = map, "suffix" = "")
		if("custom")
			suffix = trim("[suffix]")
			if(!length(suffix) || length(suffix) > 10 || !babylon_tutorial_valid_id(suffix))
				return list("error" = "A suffix has 1 to 10 letters, digits, _ or -, such as _b.")
			var/list/map = list()
			for(var/id in ids)
				var/new_id = "[id][suffix]"
				if(length(new_id) > BABYLON_TUTORIAL_ID_MAX)
					return list("error" = "[id][suffix] would be longer than [BABYLON_TUTORIAL_ID_MAX] characters. Use a shorter suffix or rename [id].")
				if(taken[new_id])
					return list("error" = "[new_id] is already used. Choose another suffix.")
				map[id] = new_id
			return list("map" = map, "suffix" = suffix)
	for(var/number in 2 to 999)
		var/candidate = "_[number]"
		var/list/map = list()
		for(var/id in ids)
			var/new_id = "[id][candidate]"
			if(length(new_id) > BABYLON_TUTORIAL_ID_MAX)
				return list("error" = "[id] is too long to get a suffix (ids have at most [BABYLON_TUTORIAL_ID_MAX] characters). Rename it, or paste with \"Keep ids\".")
			if(taken[new_id])
				map = null
				break
			map[id] = new_id
		if(map)
			return list("map" = map, "suffix" = candidate)
	return list("error" = "No free suffix was found. Choose a custom suffix.")

/// A tutorial object's settings for its copy: links to copied objects use the new ids, zones,
/// picked tiles and stored areas (their origin) inside the copied area move with it. Links and
/// places outside the copy stay as they were.
/proc/babylon_area_rewrite_settings(path, json, list/ids, datum/babylon_area_clip/clip, turf/origin)
	var/list/decoded = length(json) ? safe_json_decode(json) : null
	var/list/values = islist(decoded) ? decoded : list()
	var/dx = origin.x - clip.origin[1]
	var/dy = origin.y - clip.origin[2]
	for(var/list/field as anything in babylon_tutorial_schema(path))
		var/key = field["key"]
		var/value = values[key]
		if(babylon_tutorial_links_field(field))
			if(length(ids) && !isnull(value))
				values[key] = babylon_tutorial_value_renamed(field, value, ids)
			continue
		switch(field["type"])
			if("zone")
				var/list/zone = value
				if(islist(zone) && length(zone) == 5 && zone[5] == clip.origin[3] \
					&& min(zone[1], zone[3]) >= clip.origin[1] && max(zone[1], zone[3]) < clip.origin[1] + clip.width \
					&& min(zone[2], zone[4]) >= clip.origin[2] && max(zone[2], zone[4]) < clip.origin[2] + clip.height)
					values[key] = list(zone[1] + dx, zone[2] + dy, zone[3] + dx, zone[4] + dy, origin.z)
			if("tile")
				var/list/spot = value
				if(islist(spot) && length(spot) == 3 && spot[3] == clip.origin[3] \
					&& spot[1] >= clip.origin[1] && spot[1] < clip.origin[1] + clip.width \
					&& spot[2] >= clip.origin[2] && spot[2] < clip.origin[2] + clip.height)
					values[key] = list(spot[1] + dx, spot[2] + dy, origin.z)
			if("area_clip")
				// A stored room inside the copy resets the copied room, not the original.
				var/list/stored = value
				var/list/stored_origin = islist(stored) ? stored["origin"] : null
				if(length(stored_origin) == 3 && stored_origin[3] == clip.origin[3] \
					&& stored_origin[1] >= clip.origin[1] && stored_origin[1] < clip.origin[1] + clip.width \
					&& stored_origin[2] >= clip.origin[2] && stored_origin[2] < clip.origin[2] + clip.height)
					var/list/moved = stored.Copy()
					moved["origin"] = list(stored_origin[1] + dx, stored_origin[2] + dy, origin.z)
					values[key] = moved
	return values

/// Builds a clip with its south-west corner on origin: clears the tiles it covers (players are
/// moved aside), loads the copy as a map, restores contents and reagents, then recreates its
/// tutorial objects. id_mode/suffix: how tutorial ids are given ("auto", "custom", "keep"); the
/// map is worked out right before the objects are made, as other builders may have taken ids
/// while this paused. If the chosen way no longer works it falls back to "auto"; counts gets
/// "suffix" and "id_note". Returns an error or null; a place cut short by a runtime in its own
/// body returns the first line's text (every success path returns null explicitly).
/// keep_tutorial: a tutorial's Paste area (babylon_area_clear_tiles); the clip has no tutorial
/// objects then.
/proc/babylon_area_place(datum/babylon_area_clip/clip, turf/origin, id_mode, suffix, skip_space, file_name, list/counts, keep_tutorial = FALSE)
	. = "The paste was cut short; Undo puts back what changed."
	var/list/rect = list(origin.x, origin.y, origin.x + clip.width - 1, origin.y + clip.height - 1, origin.z)
	var/list/written = list()
	for(var/dx in 0 to clip.width - 1)
		for(var/dy in 0 to clip.height - 1)
			var/list/entry = clip.entry(dx, dy)
			if(entry["keep"] || (skip_space && entry["space"]))
				continue
			written += locate(origin.x + dx, origin.y + dy, origin.z)
	// An area keeps one APC: a copied APC is left out where the target area already has one that
	// stays (outside the tiles this paste clears).
	var/list/no_apc = list()
	for(var/dx in 0 to clip.width - 1)
		for(var/dy in 0 to clip.height - 1)
			var/turf/tile = locate(origin.x + dx, origin.y + dy, origin.z)
			var/area/room = get_area(tile)
			var/obj/machinery/power/apc/existing = room?.apc
			if(existing && !QDELETED(existing) && !(get_turf(existing) in written))
				no_apc["[dx],[dy]"] = TRUE
	var/list/cleared = babylon_area_clear_tiles(written, rect, null, keep_tutorial)
	if(!cleared)
		log_world("BABYLON AREA: clearing the paste footprint at [origin.x],[origin.y],[origin.z] was cut short.")
		return "The area could not be cleared; nothing was pasted."
	if(counts)
		for(var/key in cleared)
			counts[key] = cleared[key]
	else
		counts = list()
	// An APC cleared from the footprint frees its area: the copy's APC may take over.
	for(var/key in no_apc.Copy())
		var/list/parts = splittext(key, ",")
		var/turf/tile = locate(origin.x + text2num(parts[1]), origin.y + text2num(parts[2]), origin.z)
		var/area/room = get_area(tile)
		if(!room?.apc || QDELETED(room.apc))
			no_apc -= key
	// Map loading can pause; icon smoothing must not run then on neighbours of half-loaded tiles.
	babylon_area_smooth_now(rect)
	var/path = "data/babylon/clipboard/[file_name].dmm"
	var/list/write_result = babylon_write_pieces(babylon_area_map_pieces(clip, skip_space, no_apc), path)
	if(write_result["error"])
		log_world("BABYLON AREA: writing the copy failed: [write_result["error"]]")
		fdel(path)
		return "The copy could not be written."
	var/datum/map_template/babylon_clipboard/template = new(path, null, TRUE)
	fdel(path)
	if(!template.cached_map || template.width != clip.width || template.height != clip.height)
		return "The copy could not be read back."
	var/loaded
	// The copy is saved state, not a fresh map: mapload defaults such as random light breakage stand
	// back (babylon_loading_saved_map(), persistence.dm).
	var/was_loading = GLOB.babylon_save.loading_saved_map
	GLOB.babylon_save.loading_saved_map = TRUE
	var/init_depth = length(SSatoms.babylon_initializing)
	loaded = template.load(origin)
	if(!loaded)
		// Cut short (or refused): atoms it left half initialised must not count as initialising.
		babylon_init_depth_restore(init_depth)
		log_world("BABYLON AREA: loading the copy at [origin.x],[origin.y],[origin.z] failed or was cut short.")
	GLOB.babylon_save.loading_saved_map = was_loading
	if(!loaded)
		return "The copy could not be placed there."
	for(var/turf/tile as anything in babylon_area_tiles(rect[1], rect[2], rect[3], rect[4], rect[5]))
		BABYLON_AREA_TICK
		for(var/obj/thing in tile)
			if(!thing.babylon_clip_tag)
				continue
			var/list/extra = clip.extras[thing.babylon_clip_tag]
			thing.babylon_clip_tag = null
			if(!extra)
				continue
			if(clip.from_storage && extra["fields"])
				extra = babylon_area_stored_extra_for(thing, extra)
			if(!babylon_area_restore_extra(thing, extra))
				log_world("BABYLON AREA: restoring the settings and contents of [thing.type] was cut short.")
	babylon_area_resmooth(rect)
	// Nothing pauses from here on: the ids are checked and the objects made in one go.
	counts["moved"] += babylon_area_rescue(rect)
	// Nothing is ignored: what the clear removed is gone already, and every tutorial object still
	// here (placed during the pauses, or on tiles the paste left alone) keeps its id.
	var/list/id_result = babylon_area_id_map(clip, id_mode, suffix, list())
	if(id_result["error"])
		var/list/fallback = babylon_area_id_map(clip, "auto", null, list())
		if(fallback["error"])
			return fallback["error"]
		counts["id_note"] = "Some tutorial ids were taken meanwhile, so these got the suffix [fallback["suffix"]] instead."
		id_result = fallback
	var/list/ids = id_result["map"]
	counts["suffix"] = id_result["suffix"]
	var/list/spawners = list()
	for(var/list/entry as anything in clip.tutorial)
		var/object_path = text2path(entry["type"])
		if(!ispath(object_path, /obj/babylon_tutorial))
			continue
		var/obj/babylon_tutorial/object = new object_path(locate(origin.x + entry["dx"], origin.y + entry["dy"], origin.z))
		object.tutorial_id = ids?[entry["id"]] || entry["id"]
		object.store_settings(babylon_area_rewrite_settings(object_path, entry["settings"], ids, clip, origin))
		// A copied object may bring limited data (a Paste area's stored area: the size caps).
		var/pasted_note = object.after_area_paste()
		if(pasted_note)
			counts["id_note"] = counts["id_note"] ? "[counts["id_note"]] [pasted_note]" : pasted_note
		object.setDir(entry["dir"])
		object.pixel_x = entry["pixel_x"]
		object.pixel_y = entry["pixel_y"]
		if(entry["npc"])
			spawners += object
	for(var/obj/babylon_tutorial/npc_spawner/spawner as anything in spawners)
		spawner.spawn_npc()
	if(length(clip.tutorial))
		SSbabylon_tutorial.refresh_hooks()
		babylon_tutorial_changed()
	return null

/// ChangeTurf flags for a tool: a room's floor keeps its air; a new floor where there was space
/// or a wall gets normal air (its type's), never the vacuum of the space it replaces.
/proc/babylon_area_air_flags(turf/tile)
	return (isopenturf(tile) && !isspaceturf(tile)) ? CHANGETURF_INHERIT_AIR : NONE

/// What a turf was, to put it back on undo: list(x, y, z, type, dir, air).
/proc/babylon_area_turf_record(turf/tile)
	var/gas
	if(isopenturf(tile) && !isspaceturf(tile))
		var/turf/open/open = tile
		gas = open.return_air()?.to_string()
	return list(tile.x, tile.y, tile.z, "[tile.type]", tile.dir, gas)

/// Puts a material on tiles (Fill and Border). journal: gets the turfs' old states ("turfs") and
/// the structures made ("made"). Returns counts: list("changed", "locked", "skipped", "occupied").
/// occupied: tiles left alone because a player could not be moved off them.
/proc/babylon_area_put(list/tiles, path, only_empty, list/rect, list/journal)
	var/list/counts = list("changed" = 0, "locked" = 0, "skipped" = 0, "occupied" = 0)
	var/is_turf = ispath(path, /turf)
	var/obj/structure_path = path
	var/blocks = is_turf ? ispath(path, /turf/closed) : initial(structure_path.density)
	for(var/turf/tile as anything in tiles)
		BABYLON_AREA_TICK
		if(babylon_area_locked(tile))
			counts["locked"]++
			continue
		if(only_empty && !babylon_area_empty(tile))
			counts["skipped"]++
			continue
		if(is_turf)
			if(tile.type == path)
				continue
		else if(isclosedturf(tile) || (locate(path) in tile))
			continue
		if(blocks)
			// In the same tick as the change: nobody steps back in between.
			babylon_area_evict(list(tile), rect, FALSE, TRUE)
			// No free tile for a player still here (also inside something): nothing solid on them.
			if(babylon_area_player_on(tile))
				counts["occupied"]++
				continue
		if(is_turf)
			journal["turfs"] += list(babylon_area_turf_record(tile))
			babylon_area_change_turf(tile, path, babylon_area_air_flags(tile))
		else
			var/obj/made = new path(tile)
			journal["made"] += WEAKREF(made)
		counts["changed"]++
	return counts

// ---------------------------------------------------------------------------------------------
// A builder's session: selection, clipboard, options and undo

/datum/babylon_area_session
	var/key
	/// The first corner while selecting: list(x, y, z).
	var/list/corner
	/// The selection: list(x1, y1, x2, y2, z), south-west to north-east.
	var/list/selection
	var/datum/babylon_area_clip/clipboard
	/// Paste mode: the next click picks where the copy goes.
	var/paste_armed = FALSE
	/// Where the paste goes (its south-west corner): list(x, y, z).
	var/list/paste_target
	/// The last operation, to undo: list("label", "kind" = "turfs"/"snapshot", ...).
	var/list/last_op
	var/next_op = 0
	/// Tests switch the 2 second limit off.
	var/rate_limited = TRUE
	/// Bumped on every change (the wand redraws its outlines).
	var/version = 0
	/// Fill/Border material (path text).
	var/material
	var/only_empty = FALSE
	var/skip_space = TRUE
	/// "auto", "custom" or "keep".
	var/suffix_mode = "auto"
	var/custom_suffix = "_b"
	/// Clear makes floors of: "plating" or "material".
	var/clear_to = "plating"
	var/list/stats_cache
	var/stats_version = -1
	var/stats_time = -1
	/// paste_problem() and the footprint's contents, cached like stats.
	var/list/paste_cache
	var/paste_version = -1
	var/paste_time = -1
	/// Pastes since paste mode was switched on (the window's Cancel / Stop pasting).
	var/pasted = 0
	/// The last operation's outcome for the window: list("text", "ok", "id").
	var/list/last_result
	/// world.time of the last use (idle sessions are freed).
	var/last_used = 0
	/// The cooldown the last operation started, in deciseconds.
	var/cooldown_length = BABYLON_AREA_COOLDOWN

/datum/babylon_area_session/New(key)
	src.key = key

/datum/babylon_area_session/proc/changed()
	version++

/datum/babylon_area_session/proc/selection_width()
	return selection ? selection[3] - selection[1] + 1 : 0

/datum/babylon_area_session/proc/selection_height()
	return selection ? selection[4] - selection[2] + 1 : 0

/datum/babylon_area_session/proc/selection_text()
	return babylon_area_size_text(selection_width(), selection_height())

/// Starts an operation: why it can't run now, or null. Undo skips the cooldown (not the lock).
/datum/babylon_area_session/proc/begin(ignore_cooldown = FALSE)
	if(babylon_area_locked_by_other())
		return "Another builder's area operation is still running. Try again in a moment."
	if(rate_limited && !ignore_cooldown && world.time < next_op)
		return "Wait [round((next_op - world.time) / 10, 0.1)] more second\s: bigger areas need a longer pause between operations."
	GLOB.babylon_area_busy = world.time + BABYLON_AREA_LOCK_TIMEOUT
	GLOB.babylon_area_lock_owner = src
	return null

/// Ends an operation on tiles tiles: the lock opens, this builder's cooldown starts (2 seconds
/// plus 1 per 1000 tiles).
/datum/babylon_area_session/proc/finish(tiles = 0)
	// Only this session's own lock: if it expired and another operation took it, that one keeps it.
	if(GLOB.babylon_area_lock_owner == src)
		GLOB.babylon_area_busy = 0
		GLOB.babylon_area_lock_owner = null
	cooldown_length = BABYLON_AREA_COOLDOWN + round(tiles / 1000) * 1 SECONDS
	next_op = world.time + cooldown_length
	changed()

/// Remembers an outcome for the window and returns it.
/datum/babylon_area_session/proc/result(text, ok)
	last_result = list("text" = text, "ok" = ok, "id" = world.time + rand())
	return list("text" = text, "ok" = ok)

/// Selects a rectangle (corners in any order). Returns an error or null.
/datum/babylon_area_session/proc/select(x1, y1, z1, x2, y2, z2)
	var/error = babylon_area_check(x1, y1, z1, x2, y2, z2)
	if(error)
		return error
	selection = list(min(x1, x2), min(y1, y2), max(x1, x2), max(y1, y2), z1)
	corner = null
	changed()
	return null

/// A click with the wand in Select mode. Returns list("text", "ok").
/datum/babylon_area_session/proc/click(turf/tile)
	if(paste_armed)
		paste_target = list(tile.x, tile.y, tile.z)
		changed()
		var/list/rect = paste_rect()
		var/error = paste_problem()
		if(error)
			return list("text" = error, "ok" = FALSE)
		return list("text" = "The paste would cover [rect[1]], [rect[2]] to [rect[3]], [rect[4]]. Confirm it in the wand's window, or click another tile.", "ok" = TRUE)
	if(!corner)
		corner = list(tile.x, tile.y, tile.z)
		selection = null
		changed()
		return list("text" = "Corner 1 is at [tile.x], [tile.y]. Now click the opposite corner.", "ok" = TRUE)
	var/error = select(corner[1], corner[2], corner[3], tile.x, tile.y, tile.z)
	if(error)
		return list("text" = "[error] Corner 1 stays at [corner[1]], [corner[2]]: click another opposite corner.", "ok" = FALSE)
	return list("text" = "Selected [selection_text()]. Choose what to do with it in the wand's window.", "ok" = TRUE)

/// Forgets the selection: the next click is corner 1 again.
/datum/babylon_area_session/proc/reselect()
	corner = null
	selection = null
	paste_armed = FALSE
	paste_target = null
	changed()

/// The paste footprint for the chosen target: list(x1, y1, x2, y2, z), or null.
/datum/babylon_area_session/proc/paste_rect()
	if(!clipboard || !paste_target)
		return null
	return list(paste_target[1], paste_target[2], paste_target[1] + clipboard.width - 1, paste_target[2] + clipboard.height - 1, paste_target[3])

/// Why the paste can't go to the chosen target, or null.
/datum/babylon_area_session/proc/paste_problem()
	return paste_info()["problem"]

/// About the chosen paste target, cached until something changes (at most 2 seconds):
/// list("problem", "objects", "tutorial", "mobs") for what the paste would replace.
/datum/babylon_area_session/proc/paste_info()
	if(paste_cache && paste_version == version && world.time < paste_time + 2 SECONDS)
		return paste_cache
	var/list/info = list("problem" = null, "objects" = 0, "tutorial" = 0, "mobs" = 0)
	var/list/rect = paste_rect()
	if(!rect)
		info["problem"] = clipboard ? "Click the tile that becomes the copy's bottom-left (south-west) corner." : "Copy an area first."
	else
		var/error = babylon_area_check(rect[1], rect[2], rect[5], rect[3], rect[4], rect[5])
		if(error)
			info["problem"] = "The copy is [clipboard.width]×[clipboard.height] tiles and does not fit there. [error]"
		else
			var/locked = 0
			var/turf/first
			for(var/turf/tile as anything in babylon_area_tiles(rect[1], rect[2], rect[3], rect[4], rect[5]))
				if(babylon_area_locked(tile))
					locked++
					first = first || tile
					continue
				for(var/mob/living/body in tile)
					if(!babylon_area_is_player(body))
						info["mobs"]++
				for(var/obj/thing in tile)
					if(babylon_area_removable(thing))
						info[istype(thing, /obj/babylon_tutorial) ? "tutorial" : "objects"]++
			if(locked)
				info["problem"] = "The paste would cover [babylon_area_protected_text(locked)], outlined in red (the first at [first.x], [first.y]). Click a spot where it fits."
	paste_cache = info
	paste_version = version
	paste_time = world.time
	return info

/// Why an operation on the selection can't run, or null.
/datum/babylon_area_session/proc/selection_problem()
	if(!selection)
		return "Select an area first: click two opposite corners with the wand."
	return babylon_area_check(selection[1], selection[2], selection[5], selection[3], selection[4], selection[5])

/// What is in the selection, for the window (cached for 2 seconds or until something changes).
/datum/babylon_area_session/proc/stats()
	if(!selection)
		return null
	if(stats_cache && stats_version == version && world.time < stats_time + 2 SECONDS)
		return stats_cache
	var/list/counts = list("objects" = 0, "tutorial" = 0, "mobs" = 0, "players" = 0, "locked" = 0, "protected" = 0)
	for(var/turf/tile as anything in babylon_area_tiles(selection[1], selection[2], selection[3], selection[4], selection[5]))
		if(babylon_area_locked(tile))
			counts["locked"]++
		for(var/mob/living/body in tile)
			counts[babylon_area_is_player(body) ? "players" : "mobs"]++
		for(var/obj/thing in tile)
			if(babylon_area_removable(thing))
				counts[istype(thing, /obj/babylon_tutorial) ? "tutorial" : "objects"]++
			else if(babylon_area_protected_object(thing))
				counts["protected"]++
	stats_cache = counts
	stats_version = version
	stats_time = world.time
	return counts

/datum/babylon_area_session/proc/log_op(mob/user, text)
	log_game("BABYLON AREA: [user ? key_name(user) : key] [text]")

/// Copy. Returns list("text", "ok").
/datum/babylon_area_session/proc/copy(mob/user)
	var/error = selection_problem() || begin()
	if(error)
		return result(error, FALSE)
	var/list/rect = selection.Copy()
	var/tiles = selection_width() * selection_height()
	error = babylon_area_too_full(rect)
	if(!error && !copy_steps(rect))
		log_world("BABYLON AREA: copy was cut short.")
		error = "The copy failed."
	if(error)
		finish()
		return result(error, FALSE)
	log_op(user, "copied [babylon_area_size_text(rect[3] - rect[1] + 1, rect[4] - rect[2] + 1)] at [rect[1]],[rect[2]],[rect[5]] ([clipboard.object_count] objects, [length(clipboard.tutorial)] tutorial objects).")
	finish(tiles)
	var/tutorial = length(clipboard.tutorial)
	var/not_copied = babylon_area_not_copied(clipboard)
	return result("Copied [babylon_area_size_text(rect[3] - rect[1] + 1, rect[4] - rect[2] + 1)]: [clipboard.object_count] object\s[tutorial ? ", [tutorial] tutorial object\s" : ""]. [not_copied ? "[not_copied] " : ""]Press Paste, then click where it goes.", TRUE)

/// Copy's work (no try: see babylon_area_delete). TRUE when it got to the end.
/datum/babylon_area_session/proc/copy_steps(list/rect)
	clipboard = babylon_area_capture(rect[1], rect[2], rect[3], rect[4], rect[5])
	var/list/written = babylon_write_pieces(babylon_area_map_pieces(clipboard, FALSE), "data/babylon/clipboard/[world.port]-[ckey(key)].dmm")
	if(written["error"])
		log_world("BABYLON AREA: writing the clipboard file failed: [written["error"]]")
	return TRUE

/// "Not copied: 2 mobs (NPC spawners come along and make their NPC again), floor markings."
/proc/babylon_area_not_copied(datum/babylon_area_clip/clip)
	var/list/parts = list()
	if(clip.skipped_mobs)
		parts += "[clip.skipped_mobs] mob\s (NPC spawners come along and make their NPC again; place other NPCs with the NPC mode)"
	if(clip.skipped_protected)
		parts += "[clip.skipped_protected] protected object\s"
	if(clip.skipped_locked)
		parts += babylon_area_protected_text(clip.skipped_locked)
	if(clip.replaced_turfs)
		parts += "[clip.replaced_turfs] special floor\s or wall\s (they paste as plating)"
	parts += "floor markings"
	return "Not copied: [english_list(parts)]."

/// Paste mode on: the next click picks the target.
/datum/babylon_area_session/proc/arm_paste()
	if(!clipboard)
		return list("text" = "Copy an area first.", "ok" = FALSE)
	paste_armed = TRUE
	paste_target = null
	pasted = 0
	changed()
	return result("Click the tile that becomes the copy's bottom-left (south-west) corner.", TRUE)

/datum/babylon_area_session/proc/cancel_paste()
	var/done = pasted
	paste_armed = FALSE
	paste_target = null
	pasted = 0
	changed()
	return result(done ? "Stopped pasting ([done] paste\s made)." : "Paste cancelled.", TRUE)

/// The ids a paste would give, for the window: list("suffix", "error").
/datum/babylon_area_session/proc/paste_ids()
	if(!clipboard || !length(clipboard.tutorial))
		return null
	var/list/rect = paste_rect()
	var/list/ignore = rect ? babylon_area_tutorial_in(rect) : list()
	return babylon_area_id_map(clipboard, suffix_mode, custom_suffix, ignore)

/// Pastes the clipboard at the chosen target. Returns list("text", "ok").
/datum/babylon_area_session/proc/paste(mob/user)
	if(!clipboard)
		return result("Copy an area first.", FALSE)
	var/error = paste_problem()
	if(error)
		return result(error, FALSE)
	var/list/rect = paste_rect()
	var/list/ids = babylon_area_id_map(clipboard, suffix_mode, custom_suffix, babylon_area_tutorial_in(rect))
	if(ids["error"])
		return result(ids["error"], FALSE)
	error = begin()
	if(error)
		return result(error, FALSE)
	var/datum/babylon_area_clip/before
	var/turf/origin = locate(rect[1], rect[2], rect[5])
	var/list/counts = list()
	var/list/steps = list()
	error = babylon_area_too_full(rect)
	if(!error)
		if(paste_steps(rect, origin, suffix_mode, custom_suffix, skip_space, counts, steps))
			error = steps["error"]
		else
			error = "The paste failed."
			log_world("BABYLON AREA: paste was cut short.")
	// The snapshot taken before it, also when the paste was cut short.
	before = steps["before"]
	var/tiles = clipboard.width * clipboard.height
	if(error)
		// Whatever was placed can still be taken back.
		if(before)
			last_op = list("label" = "the failed paste at [rect[1]], [rect[2]]", "kind" = "snapshot", "clip" = before, "origin" = list(rect[1], rect[2], rect[5]))
		finish(tiles)
		return result(error, FALSE)
	var/size = babylon_area_size_text(clipboard.width, clipboard.height)
	last_op = list("label" = "Paste [size] at [rect[1]], [rect[2]]", "kind" = "snapshot", "clip" = before, "origin" = list(rect[1], rect[2], rect[5]))
	log_op(user, "pasted [size] at [rect[1]],[rect[2]],[rect[5]] (copied from [clipboard.origin[1]],[clipboard.origin[2]],[clipboard.origin[3]], id suffix \"[counts["suffix"]]\").")
	paste_target = null
	pasted++
	finish(tiles)
	var/tutorial = length(clipboard.tutorial)
	var/list/notes = list()
	if(counts["objects"] || counts["tutorial"] || counts["mobs"])
		notes += "replaced [counts["objects"]] object\s, [counts["tutorial"]] tutorial object\s and [counts["mobs"]] mob\s"
	if(counts["kept"])
		notes += "kept [counts["kept"]] protected object\s"
	if(counts["moved"])
		notes += "moved [counts["moved"]] player\s aside"
	return result("Pasted [size] at [rect[1]], [rect[2]][tutorial ? "; [tutorial] tutorial object\s[length(counts["suffix"]) ? " got the suffix [counts["suffix"]]" : " kept their ids"]" : ""][length(notes) ? "; [english_list(notes)]" : ""].[counts["id_note"] ? " [counts["id_note"]]" : ""] Click another tile to paste again, or press Stop pasting.", TRUE)

/// Paste's work (no try: see babylon_area_delete). Fills steps["before"] (the undo snapshot) as
/// soon as it exists and steps["error"]. TRUE when it got to the end.
/datum/babylon_area_session/proc/paste_steps(list/rect, turf/origin, suffix_mode, custom_suffix, skip_space, list/counts, list/steps)
	steps["before"] = babylon_area_capture(rect[1], rect[2], rect[3], rect[4], rect[5], TRUE)
	if(!steps["before"])
		// Without its Undo snapshot nothing is pasted.
		steps["error"] = "The area could not be recorded for Undo, so nothing was pasted."
		return TRUE
	steps["error"] = babylon_area_place(clipboard, origin, suffix_mode, custom_suffix, skip_space, "[world.port]-[ckey(key)]-paste", counts)
	return TRUE

/// Tutorial objects inside a rectangle.
/proc/babylon_area_tutorial_in(list/rect)
	var/list/found = list()
	for(var/obj/babylon_tutorial/object as anything in GLOB.babylon_tutorial_objects)
		var/turf/tile = get_turf(object)
		if(tile && tile.z == rect[5] && tile.x >= rect[1] && tile.x <= rect[3] && tile.y >= rect[2] && tile.y <= rect[4])
			found += object
	return found

/// Fill (edge_only: Border) with a material. Returns list("text", "ok").
/datum/babylon_area_session/proc/fill(mob/user, path_text, edge_only = FALSE)
	var/list/material = babylon_area_material(path_text)
	if(!material)
		return result("Pick a floor, wall or structure first.", FALSE)
	var/error = selection_problem() || begin()
	if(error)
		return result(error, FALSE)
	var/path = text2path(material["path"])
	var/list/rect = selection.Copy()
	var/list/tiles = edge_only ? babylon_area_edge(rect[1], rect[2], rect[3], rect[4], rect[5]) : babylon_area_tiles(rect[1], rect[2], rect[3], rect[4], rect[5])
	var/list/journal = list("turfs" = list(), "made" = list())
	// Null when it was cut short (no try: see babylon_area_delete); the journal keeps what changed.
	var/list/counts = babylon_area_put(tiles, path, only_empty, rect, journal)
	if(!counts)
		log_world("BABYLON AREA: fill was cut short.")
	var/verb_name = edge_only ? "Border" : "Fill"
	var/size = babylon_area_size_text(rect[3] - rect[1] + 1, rect[4] - rect[2] + 1)
	last_op = list("label" = "[verb_name] [size] with [material["name"]]", "kind" = "turfs", "turfs" = journal["turfs"], "made" = journal["made"], "rect" = rect)
	log_op(user, "[edge_only ? "bordered" : "filled"] [size] at [rect[1]],[rect[2]],[rect[5]] with [path] ([counts?["changed"]] tiles).")
	finish(length(tiles))
	if(!counts)
		return result("[verb_name] stopped with an error; Undo puts back what changed.", FALSE)
	var/list/notes = list()
	if(counts["skipped"])
		notes += "[counts["skipped"]] tile\s that were not empty"
	if(counts["occupied"])
		notes += babylon_area_occupied_text(counts["occupied"])
	if(counts["locked"])
		notes += babylon_area_protected_text(counts["locked"])
	return result("[verb_name]: [counts["changed"]] tile\s now [material["name"]][length(notes) ? " (left alone: [english_list(notes)])" : ""].", TRUE)

/// Clear: objects and non-player mobs go, turfs become plating (or the material). Returns
/// list("text", "ok").
/datum/babylon_area_session/proc/clear(mob/user)
	var/path = /turf/open/floor/plating
	if(clear_to == "material")
		var/list/chosen = babylon_area_material(material)
		var/material_path = chosen ? text2path(chosen["path"]) : null
		if(!ispath(material_path, /turf))
			return result("Pick a floor or wall to clear to, or clear to plating.", FALSE)
		path = material_path
	var/error = selection_problem() || begin()
	if(error)
		return result(error, FALSE)
	var/list/rect = selection.Copy()
	var/datum/babylon_area_clip/before
	var/list/tiles = list()
	var/locked = 0
	var/list/counts
	var/full = babylon_area_too_full(rect)
	if(!full)
		before = babylon_area_capture(rect[1], rect[2], rect[3], rect[4], rect[5], TRUE)
		if(!before)
			// Without its Undo snapshot nothing is cleared.
			full = "The area could not be recorded for Undo, so nothing was cleared."
	if(!full)
		for(var/turf/tile as anything in babylon_area_tiles(rect[1], rect[2], rect[3], rect[4], rect[5]))
			if(babylon_area_locked(tile))
				locked++
			else
				tiles += tile
		// Each tile is emptied (players moved out) and turned in one tick. Null when it was cut
		// short (no try: see babylon_area_delete).
		counts = babylon_area_clear_tiles(tiles, rect, path)
		if(!counts)
			log_world("BABYLON AREA: clear was cut short.")
	if(full)
		finish()
		return result(full, FALSE)
	var/size = babylon_area_size_text(rect[3] - rect[1] + 1, rect[4] - rect[2] + 1)
	if(before)
		last_op = list("label" = "Clear [size]", "kind" = "snapshot", "clip" = before, "origin" = list(rect[1], rect[2], rect[5]))
	log_op(user, "cleared [size] at [rect[1]],[rect[2]],[rect[5]] to [path] ([counts?["objects"]] objects, [counts?["mobs"]] mobs, [counts?["tutorial"]] tutorial objects).")
	finish(length(tiles) + locked)
	if(!counts)
		return result("Clear stopped with an error; Undo puts back what changed.", FALSE)
	var/list/parts = list("[counts["objects"]] object\s", "[counts["mobs"]] mob\s")
	if(counts["tutorial"])
		parts += "[counts["tutorial"]] tutorial object\s"
	var/list/notes = list()
	if(counts["moved"])
		notes += "[counts["moved"]] player\s moved aside"
	if(locked)
		notes += "[babylon_area_protected_text(locked)] left alone"
	if(counts["kept"])
		notes += "[counts["kept"]] protected object\s kept"
	if(counts["occupied"])
		notes += "[babylon_area_occupied_text(counts["occupied"])] left as they were"
	return result("Cleared [size]: removed [english_list(parts)][length(notes) ? "; [english_list(notes)]" : ""]. Undo puts the area back approximately (floor markings and machine settings are lost).", TRUE)

/// Undoes the last operation. Returns list("text", "ok").
/datum/babylon_area_session/proc/undo(mob/user)
	if(!last_op)
		return result("Nothing to undo.", FALSE)
	var/error = begin(TRUE)
	if(error)
		return result(error, FALSE)
	var/list/step = last_op
	last_op = null
	var/note = ""
	var/tiles = 0
	var/occupied = 0
	var/list/out = list("tiles" = 0, "occupied" = 0, "note" = "")
	if(undo_steps(step, out))
		error = out["error"]
	else
		error = "Undo was cut short; part of it may be undone."
		log_world("BABYLON AREA: undo was cut short.")
	tiles = out["tiles"]
	occupied = out["occupied"]
	note = out["note"]
	log_op(user, "undid: [step["label"]].")
	finish(tiles)
	if(error)
		return result(error, FALSE)
	if(occupied)
		note += " [capitalize(babylon_area_occupied_text(occupied))] stayed open."
	return result("Undone: [step["label"]].[note]", TRUE)

/// Undo's work (no try: see babylon_area_delete). Fills out (tiles, occupied, note, error) as it
/// goes. TRUE when it got to the end.
/datum/babylon_area_session/proc/undo_steps(list/step, list/out)
	if(step["kind"] == "turfs")
		for(var/datum/weakref/made_ref as anything in step["made"])
			var/obj/made = made_ref.resolve()
			if(made)
				qdel(made)
		var/list/records = step["turfs"]
		out["tiles"] = length(records)
		for(var/index in length(records) to 1 step -1)
			BABYLON_AREA_TICK
			var/list/record = records[index]
			var/turf/tile = locate(record[1], record[2], record[3])
			var/path = text2path(record[4])
			if(!tile || !ispath(path, /turf))
				continue
			// Players who walked in since must not end up inside a wall again (moved out in the
			// same tick as the change; one who can't be moved keeps the open tile).
			if(ispath(path, /turf/closed) && step["rect"])
				babylon_area_evict(list(tile), step["rect"], FALSE, TRUE)
				if(babylon_area_player_on(tile))
					out["occupied"]++
					continue
			tile = babylon_area_change_turf(tile, path, CHANGETURF_INHERIT_AIR)
			tile.setDir(record[5])
			if(record[6] && isopenturf(tile))
				var/turf/open/open = tile
				open.return_air()?.copy_from(SSair.parse_gas_string(record[6]))
				open.air_update_turf(TRUE)
	else
		var/datum/babylon_area_clip/before = step["clip"]
		var/list/origin = step["origin"]
		out["tiles"] = before.width * before.height
		var/list/rect = list(origin[1], origin[2], origin[1] + before.width - 1, origin[2] + before.height - 1, origin[3])
		// Ids taken since then (anywhere outside the area) would be duplicated: the restored
		// objects get a suffix instead, applied to their links as on a paste.
		var/list/counts = list()
		out["error"] = babylon_area_place(before, locate(rect[1], rect[2], rect[5]), "keep", null, FALSE, "[world.port]-[ckey(key)]-undo", counts)
		if(counts["id_note"])
			out["note"] = " [counts["id_note"]]"
	return TRUE

/// Sets one of the window's options. Returns an error or null.
/datum/babylon_area_session/proc/set_option(option, value)
	switch(option)
		if("only_empty")
			only_empty = (value == TRUE || value == 1)
		if("skip_space")
			skip_space = (value == TRUE || value == 1)
		if("suffix_mode")
			if(!(value in list("auto", "custom", "keep")))
				return "Unknown suffix choice."
			suffix_mode = value
		if("custom_suffix")
			value = trim("[value]")
			if(!length(value) || length(value) > 10 || !babylon_tutorial_valid_id(value))
				return "A suffix has 1 to 10 letters, digits, _ or -, such as _b."
			custom_suffix = value
		if("clear_to")
			if(!(value in list("plating", "material")))
				return "Unknown choice."
			clear_to = value
		if("material")
			if(!babylon_area_material(value))
				return "That can't be used here."
			material = "[value]"
		else
			return "Unknown option."
	changed()
	return null

/// The window's data about the area tools.
/datum/babylon_area_session/proc/window_data()
	var/step = "corner1"
	if(paste_armed)
		step = paste_target ? "paste_confirm" : "paste_target"
	else if(corner)
		step = "corner2"
	else if(selection)
		step = "selected"
	var/list/data = list(
		"step" = step,
		"corner" = corner ? list("x" = corner[1], "y" = corner[2]) : null,
		"selection" = selection ? list("x1" = selection[1], "y1" = selection[2], "x2" = selection[3], "y2" = selection[4], "z" = selection[5], "width" = selection_width(), "height" = selection_height(), "tiles" = selection_width() * selection_height(), "problem" = selection_problem(), "stats" = stats()) : null,
		"clipboard" = clipboard ? list("width" = clipboard.width, "height" = clipboard.height, "objects" = clipboard.object_count, "tutorial" = length(clipboard.tutorial), "x" = clipboard.origin[1], "y" = clipboard.origin[2], "not_copied" = babylon_area_not_copied(clipboard)) : null,
		"paste" = null,
		"undo" = last_op?["label"],
		// Paste and Clear undo rebuild the whole rectangle from a snapshot, which is approximate.
		"undo_approximate" = last_op?["kind"] == "snapshot",
		"busy" = babylon_area_locked_by_other(),
		"cooldown" = rate_limited ? max(0, round((next_op - world.time) / 10, 0.1)) : 0,
		"pasted" = pasted,
		"result" = last_result,
		"max_tiles" = BABYLON_AREA_MAX_TILES,
		"material" = material,
		"only_empty" = only_empty,
		"skip_space" = skip_space,
		"suffix_mode" = suffix_mode,
		"custom_suffix" = custom_suffix,
		"clear_to" = clear_to,
	)
	if(paste_armed)
		var/list/rect = paste_rect()
		var/list/ids = paste_ids()
		var/list/info = rect ? paste_info() : null
		data["paste"] = list(
			"target" = rect ? list("x1" = rect[1], "y1" = rect[2], "x2" = rect[3], "y2" = rect[4]) : null,
			"problem" = info?["problem"],
			"replaces" = info ? list("objects" = info["objects"], "tutorial" = info["tutorial"], "mobs" = info["mobs"]) : null,
			"suffix" = ids?["suffix"],
			"suffix_error" = ids?["error"],
		)
	else if(clipboard && length(clipboard.tutorial))
		var/list/ids = paste_ids()
		data["paste_suffix"] = ids?["suffix"]
	return data

#undef BABYLON_AREA_MAX_NESTED
#undef BABYLON_AREA_CLIP_FIELDS
