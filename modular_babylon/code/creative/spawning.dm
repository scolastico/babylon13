// Creative panel, Spawn tab: what a creative player may spawn, the curated categories and the
// server-side search. panel.dm calls babylon_creative_spawn() after its own checks.

/// Spawns per player and window (BABYLON_CREATIVE_SPAWN_WINDOW); every created object counts.
#define BABYLON_CREATIVE_SPAWN_LIMIT 20
#define BABYLON_CREATIVE_SPAWN_WINDOW (10 SECONDS)
/// Copies of one non-stack type per spawn request.
#define BABYLON_CREATIVE_MAX_COPIES 10
/// Search results sent to the panel at most.
#define BABYLON_CREATIVE_SEARCH_LIMIT 60

/// Everything a creative player can spawn is one of these (or a subtype).
/proc/babylon_creative_spawn_roots()
	var/static/list/roots = list(
		/obj/item,
		/obj/structure,
		/obj/machinery,
		/mob/living/basic,
		/mob/living/carbon/human,
	)
	return roots

/**
 * TRUE when a creative player may not spawn this path. The blacklist:
 * - anything outside babylon_creative_spawn_roots(), and non-paths;
 * - abstract types (abstract_type == the type) and types without a name or icon;
 * - debug and admin tools: any path containing "debug" or "admin" (omnitools, debug ID cards,
 *   admin RCD/RTD, adminordrazine, badmin bomb cores, the admin suit ...);
 * - server- or round-wrecking things: the nuclear bomb and nuke disk (round end, lone operative
 *   events), the doomsday device, the station charter (renames the world), antagonist summoners
 *   (they recruit other players or ghosts), clusterbusters and spawner grenades (hundreds of
 *   objects or mobs at once), mob nests that spawn without end. Singularities and tesla balls
 *   are /obj/singularity and /obj/energy_ball, outside the roots, and this code base has no
 *   generator machine for them;
 * - Babylon's own builder drones (the drone builder session owns them);
 * - humans other than the plain NPC human and its species variants (no test dummies).
 */
/proc/babylon_creative_spawn_blocked(path)
	if(!ispath(path))
		return TRUE
	var/inside_roots = FALSE
	for(var/root in babylon_creative_spawn_roots())
		if(ispath(path, root))
			inside_roots = TRUE
			break
	if(!inside_roots)
		return TRUE
	var/atom/movable/thing = path
	if(initial(thing.abstract_type) == path || !initial(thing.name) || !initial(thing.icon))
		return TRUE
	var/text = lowertext("[path]")
	if(findtext(text, "debug") || findtext(text, "admin"))
		return TRUE
	var/static/list/blocked_roots = list(
		/obj/machinery/nuclearbomb,
		/obj/machinery/doomsday_device,
		/obj/item/disk/nuclear,
		/obj/item/station_charter,
		/obj/item/antag_spawner,
		/obj/item/grenade/clusterbuster,
		/obj/item/grenade/spawnergrenade,
		/obj/structure/spawner,
	)
	for(var/blocked in blocked_roots)
		if(ispath(path, blocked))
			return TRUE
	if(findtext(text, "/mob/living/basic/drone/babylon") == 1)
		return TRUE
	if(ispath(path, /mob/living/carbon/human) && path != /mob/living/carbon/human && !ispath(path, /mob/living/carbon/human/species))
		return TRUE
	return FALSE

/// One spawnable type as the panel shows it.
/proc/babylon_creative_entry(path, display_name)
	var/atom/movable/thing = path
	var/list/entry = list(
		"path" = "[path]",
		"name" = display_name || capitalize(initial(thing.name)),
		"icon" = "[initial(thing.icon)]",
		"icon_state" = initial(thing.icon_state),
		"stack" = ispath(path, /obj/item/stack),
		"max" = 1,
		"item" = ispath(path, /obj/item),
	)
	if(entry["stack"])
		var/obj/item/stack/stack = path
		entry["max"] = max(1, initial(stack.max_amount))
	return entry

/// The Spawn tab's curated categories: list of list(id, name, icon, entries).
/proc/babylon_creative_categories()
	var/list/machines = list()
	for(var/path in babylon_creative_machine_types())
		if(!babylon_creative_spawn_blocked(path))
			machines += list(babylon_creative_entry(path))
	var/list/categories = list()
	categories += list(list("id" = "creative", "name" = "Creative machines", "icon" = "wand-magic-sparkles", "entries" = machines))
	categories += list(list("id" = "tools", "name" = "Tools", "icon" = "screwdriver-wrench", "entries" = babylon_creative_curated(list(
		/obj/item/construction/rcd/loaded/upgraded,
		/obj/item/pipe_dispenser,
		/obj/item/construction/rld,
		/obj/item/construction/plumbing,
		/obj/item/multitool,
		/obj/item/weldingtool/experimental,
		/obj/item/crowbar/power,
		/obj/item/screwdriver/power,
		/obj/item/wrench,
		/obj/item/wirecutters,
		/obj/item/clothing/gloves/color/yellow,
		/obj/item/t_scanner,
		/obj/item/analyzer,
		/obj/item/airlock_painter,
		/obj/item/pipe_painter,
		/obj/item/inducer,
		/obj/item/holosign_creator/atmos,
		/obj/item/extinguisher,
		/obj/item/clothing/glasses/meson/engine,
		/obj/item/storage/toolbox/mechanical,
		/obj/item/storage/toolbox/electrical,
	))))
	categories += list(list("id" = "materials", "name" = "Construction materials", "icon" = "cubes", "entries" = babylon_creative_curated(list(
		/obj/item/stack/sheet/iron,
		/obj/item/stack/sheet/glass,
		/obj/item/stack/sheet/rglass,
		/obj/item/stack/sheet/plasteel,
		/obj/item/stack/rods,
		/obj/item/stack/tile/iron,
		/obj/item/stack/cable_coil,
		/obj/item/stack/sheet/mineral/wood,
		/obj/item/stack/sheet/plastic,
		/obj/item/stack/sheet/cardboard,
		/obj/item/stack/sheet/cloth,
		/obj/item/stack/tile/glass,
		/obj/item/stack/tile/carpet,
		/obj/item/stack/sheet/mineral/titanium,
		/obj/item/stack/sheet/titaniumglass,
		/obj/item/stack/sheet/plasmaglass,
		/obj/item/stack/sheet/plasmarglass,
		/obj/item/stack/sheet/plastitaniumglass,
		/obj/item/stack/sheet/mineral/plasma,
		/obj/item/stack/sheet/mineral/gold,
		/obj/item/stack/sheet/mineral/silver,
		/obj/item/stack/sheet/mineral/uranium,
		/obj/item/stack/sheet/mineral/diamond,
		/obj/item/stack/sheet/bluespace_crystal,
	))))
	categories += list(list("id" = "machines", "name" = "Machines", "icon" = "gears", "entries" = babylon_creative_curated(list(
		/obj/machinery/autolathe,
		/obj/machinery/rnd/production/protolathe,
		/obj/machinery/rnd/production/circuit_imprinter,
		/obj/machinery/rnd/destructive_analyzer,
		/obj/machinery/rnd/server,
		/obj/machinery/computer/rdconsole,
		/obj/machinery/power/smes,
		/obj/machinery/power/port_gen/pacman,
		/obj/machinery/power/port_gen/pacman/super,
		/obj/machinery/power/rtg,
		/obj/machinery/power/solar,
		/obj/machinery/power/tracker,
		/obj/machinery/power/emitter,
		/obj/machinery/field/generator,
		/obj/machinery/power/supermatter_crystal,
		/obj/machinery/portable_atmospherics/canister/air,
		/obj/machinery/portable_atmospherics/canister/oxygen,
		/obj/machinery/portable_atmospherics/canister/nitrogen,
		/obj/machinery/portable_atmospherics/pump,
		/obj/machinery/portable_atmospherics/scrubber,
		/obj/machinery/space_heater,
		/obj/machinery/door/airlock,
		/obj/machinery/door/airlock/public/glass,
		/obj/machinery/vending/tool,
		/obj/machinery/vending/engivend,
		/obj/machinery/cell_charger,
		/obj/machinery/recharge_station,
		/obj/machinery/hydroponics/constructable,
		/obj/machinery/chem_dispenser,
		/obj/machinery/microwave,
	))))
	categories += list(list("id" = "structures", "name" = "Structures", "icon" = "chair", "entries" = babylon_creative_curated(list(
		/obj/structure/table,
		/obj/structure/table/reinforced,
		/obj/structure/table/wood,
		/obj/structure/chair,
		/obj/structure/chair/office,
		/obj/structure/bed,
		/obj/structure/rack,
		/obj/structure/closet,
		/obj/structure/closet/crate,
		/obj/structure/closet/emcloset,
		/obj/structure/closet/firecloset,
		/obj/structure/girder,
		/obj/structure/grille,
		/obj/structure/window/fulltile,
		/obj/structure/window/reinforced/fulltile,
		/obj/structure/railing,
		/obj/structure/door_assembly,
		/obj/structure/plasticflaps,
		/obj/structure/frame/machine,
		/obj/structure/frame/computer,
		/obj/structure/sink,
		/obj/structure/toilet,
		/obj/structure/reagent_dispensers/watertank,
		/obj/structure/reagent_dispensers/fueltank,
		/obj/structure/ladder,
	))))
	categories += list(list("id" = "items", "name" = "Items", "icon" = "box-open", "entries" = babylon_creative_curated(list(
		/obj/item/stock_parts/power_store/cell/hyper,
		/obj/item/stock_parts/power_store/cell/bluespace,
		/obj/item/electronics/airlock,
		/obj/item/electronics/apc,
		/obj/item/electronics/airalarm,
		/obj/item/electronics/firealarm,
		/obj/item/wallframe/apc,
		/obj/item/wallframe/airalarm,
		/obj/item/wallframe/light_fixture,
		/obj/item/light/tube,
		/obj/item/storage/box/lights/mixed,
		/obj/item/flashlight,
		/obj/item/radio,
		/obj/item/gps,
		/obj/item/card/id/advanced/gold,
		/obj/item/tank/internals/oxygen,
		/obj/item/clothing/mask/gas,
		/obj/item/clothing/head/utility/hardhat,
		/obj/item/clothing/suit/hazardvest,
		/obj/item/storage/backpack,
		/obj/item/storage/box,
		/obj/item/storage/medkit/regular,
		/obj/item/food/burger/plain,
		/obj/item/reagent_containers/cup/glass/waterbottle,
		/obj/item/paper,
		/obj/item/pen,
	))))
	var/list/mobs = babylon_creative_curated(list(
		/mob/living/basic/pet/dog/corgi,
		/mob/living/basic/pet/cat,
		/mob/living/basic/pet/fox,
		/mob/living/basic/pet/penguin/emperor,
		/mob/living/basic/cow,
		/mob/living/basic/pig,
		/mob/living/basic/sheep,
		/mob/living/basic/goat,
		/mob/living/basic/chicken,
		/mob/living/basic/rabbit,
		/mob/living/basic/mouse,
		/mob/living/basic/frog,
		/mob/living/basic/lizard,
		/mob/living/basic/axolotl,
		/mob/living/basic/crab,
		/mob/living/basic/butterfly,
		/mob/living/basic/bot/cleanbot,
		/mob/living/basic/bot/medbot,
		/mob/living/basic/carp,
		/mob/living/basic/bear,
		/mob/living/basic/spider/giant,
	))
	mobs.Insert(1, list(babylon_creative_entry(/mob/living/carbon/human, "NPC human")))
	categories += list(list("id" = "mobs", "name" = "Mobs", "icon" = "paw", "entries" = mobs))
	return categories

/proc/babylon_creative_curated(list/paths)
	var/list/entries = list()
	for(var/path in paths)
		if(!babylon_creative_spawn_blocked(path))
			entries += list(babylon_creative_entry(path))
	return entries

/// Which root a search category limits the search to; "all" (or anything unknown) searches every root.
/proc/babylon_creative_category_root(category)
	switch(category)
		if("creative")
			return /obj/machinery
		if("tools", "items")
			return /obj/item
		if("materials")
			return /obj/item/stack
		if("machines")
			return /obj/machinery
		if("structures")
			return /obj/structure
		if("mobs")
			return /mob/living
	return null

/// Every spawnable type, built once: list of list(path, lowercase name, lowercase path text).
/proc/babylon_creative_index()
	var/static/list/index
	if(index)
		return index
	index = list()
	for(var/root in babylon_creative_spawn_roots())
		for(var/path in typesof(root))
			if(babylon_creative_spawn_blocked(path))
				continue
			var/atom/movable/thing = path
			index += list(list(path, lowertext(initial(thing.name)), lowertext("[path]")))
	return index

/**
 * The search: names first (names starting with the query before names containing it), then
 * type paths containing it. At most BABYLON_CREATIVE_SEARCH_LIMIT entries.
 */
/proc/babylon_creative_search(query, category)
	var/list/results = list()
	query = lowertext(trim("[query]"))
	if(length(query) < 2 || length(query) > 64)
		return results
	var/root = babylon_creative_category_root(category)
	var/list/allowed
	if(category == "creative")
		allowed = babylon_creative_machine_types()
	var/list/starts = list()
	var/list/contains = list()
	var/list/by_path = list()
	for(var/list/row as anything in babylon_creative_index())
		var/path = row[1]
		if(root && !ispath(path, root))
			continue
		if(allowed && !(path in allowed))
			continue
		var/position = findtext(row[2], query)
		if(position == 1)
			starts += path
		else if(position)
			contains += path
		else if(findtext(row[3], query))
			by_path += path
		if(length(starts) >= BABYLON_CREATIVE_SEARCH_LIMIT)
			break
	for(var/path in starts + contains + by_path)
		results += list(babylon_creative_entry(path))
		if(length(results) >= BABYLON_CREATIVE_SEARCH_LIMIT)
			break
	return results

/**
 * Creates `path` for `user`: one stack of `amount` (clamped to the stack's maximum), or `amount`
 * copies (1 to BABYLON_CREATIVE_MAX_COPIES) of anything else, at the user's feet or, for items
 * with in_hand, in their hands. Returns the created atoms, or an error text.
 */
/proc/babylon_creative_spawn(mob/living/user, path, amount, in_hand)
	if(babylon_creative_spawn_blocked(path))
		return "That cannot be spawned."
	var/turf/location = get_turf(user)
	if(!location)
		return "You are nowhere."
	amount = round(text2num("[amount]") || 1)
	var/list/created = list()
	if(ispath(path, /obj/item/stack))
		var/obj/item/stack/stack_type = path
		var/obj/item/stack/stack = new path(location, clamp(amount, 1, max(1, initial(stack_type.max_amount))), FALSE)
		created += stack
	else
		for(var/copy in 1 to clamp(amount, 1, BABYLON_CREATIVE_MAX_COPIES))
			created += new path(location)
	if(in_hand)
		for(var/obj/item/item in created)
			if(!QDELETED(item))
				user.put_in_hands(item)
	return created
