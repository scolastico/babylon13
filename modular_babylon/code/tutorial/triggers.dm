// Tutorial triggers (spec 7.2): each checks one condition for one run (one player) and, when it
// becomes true, the run fires the trigger's actions (runtime.dm). Zone, holding and condition
// triggers fire when their condition becomes true; used on, button and say triggers fire on the
// player's event; a timer fires a set time after it was enabled.

/// Checks the trigger for a run. TRUE: the condition holds (or the event happened) now.
/obj/babylon_tutorial/trigger/proc/check(datum/babylon_tutorial_run/run)
	return FALSE

// ---------------------------------------------------------------------------------------------
// Tutorial starts

/obj/babylon_tutorial/trigger/start
	tutorial_kind = "start"
	kind_name = "Tutorial starts"
	kind_desc = "Fires once, right when the tutorial starts for the player."
	kind_example = "e.g. a welcome message and a point at the guide."
	ui_icon = "flag"
	view_icon = 'icons/effects/landmarks_static.dmi'
	view_state = "observer_start"
	edge_triggered = FALSE

/obj/babylon_tutorial/trigger/start/check(datum/babylon_tutorial_run/run)
	return !run.fired[src]

// ---------------------------------------------------------------------------------------------
// Zone

/obj/babylon_tutorial/trigger/zone
	tutorial_kind = "zone"
	kind_name = "Zone"
	kind_desc = "Fires when the player walks into a rectangle of tiles."
	kind_example = "e.g. the player enters medbay."
	ui_icon = "vector-square"
	view_icon = 'icons/effects/landmarks_static.dmi'
	view_state = "navigate"

/obj/babylon_tutorial/trigger/zone/own_schema()
	return list(
		babylon_tutorial_field("zone", "Zone", "zone", null, "Click \"Pick corners\", then two opposite corner tiles with the wand. Without a zone it is just this trigger's tile."),
	)

/// The zone as list(x1, y1, x2, y2, z): the configured one, else this trigger's own tile.
/obj/babylon_tutorial/trigger/zone/proc/zone()
	var/list/zone = setting("zone")
	if(islist(zone) && length(zone) == 5)
		return zone
	var/turf/tile = get_turf(src)
	return tile ? list(tile.x, tile.y, tile.x, tile.y, tile.z) : null

/obj/babylon_tutorial/trigger/zone/check(datum/babylon_tutorial_run/run)
	return babylon_tutorial_in_zone(get_turf(run.player), zone())

/obj/babylon_tutorial/trigger/zone/summary()
	var/list/zone = zone()
	return "[zone ? "[zone[3] - zone[1] + 1]x[zone[4] - zone[2] + 1] tiles" : "no zone"], " + ..()

/proc/babylon_tutorial_in_zone(turf/tile, list/zone)
	if(!tile || length(zone) != 5)
		return FALSE
	return tile.z == zone[5] && tile.x >= zone[1] && tile.x <= zone[3] && tile.y >= zone[2] && tile.y <= zone[4]

/// The turfs of a zone (at most 10 000).
/proc/babylon_tutorial_zone_turfs(list/zone)
	if(length(zone) != 5)
		return list()
	var/x2 = min(zone[3], zone[1] + 99)
	var/y2 = min(zone[4], zone[2] + 99)
	return block(locate(zone[1], zone[2], zone[5]), locate(x2, y2, zone[5]))

// ---------------------------------------------------------------------------------------------
// Holding

/obj/babylon_tutorial/trigger/holding
	tutorial_kind = "holding"
	kind_name = "Holding"
	kind_desc = "Fires when the player holds an item of a type in a hand."
	kind_example = "e.g. the player picks up the health analyzer."
	ui_icon = "hand-holding"
	view_icon = 'icons/hud/screen_gen.dmi'
	view_state = "grab"

/obj/babylon_tutorial/trigger/holding/own_schema()
	return list(
		babylon_tutorial_field("item_type", "Item", "typepath", "", "The item the player must hold, e.g. a health analyzer.", base = /obj/item, required = TRUE, placeholder = "Search items, e.g. analyzer"),
		babylon_tutorial_field("exact", "Exactly this type", "bool", 0, "Off: variants of the item count too (an advanced health analyzer is a health analyzer)."),
	)

/obj/babylon_tutorial/trigger/holding/check(datum/babylon_tutorial_run/run)
	var/path = text2path(setting("item_type"))
	if(!path)
		return FALSE
	for(var/obj/item/held in run.player.held_items)
		if(babylon_tutorial_type_matches(held, path, setting("exact")))
			return TRUE
	return FALSE

/obj/babylon_tutorial/trigger/holding/summary()
	return "holding [babylon_tutorial_type_label(setting("item_type"))], " + ..()

/proc/babylon_tutorial_type_matches(datum/thing, path, exact)
	return exact ? thing.type == path : istype(thing, path)

/proc/babylon_tutorial_type_label(path_text)
	var/path = text2path(path_text)
	return path ? babylon_tutorial_type_name(path) : "(nothing chosen)"

// ---------------------------------------------------------------------------------------------
// Used on

/obj/babylon_tutorial/trigger/used_on
	tutorial_kind = "used_on"
	kind_name = "Used on"
	kind_desc = "Fires when the player uses an item of a type on a target."
	kind_example = "e.g. a health analyzer used on the patient NPC."
	ui_icon = "hand-pointer"
	view_icon = 'icons/hud/screen_gen.dmi'
	view_state = "help"
	edge_triggered = FALSE
	/// The atom whose item interactions this trigger listens to.
	var/datum/weakref/hooked_target

/obj/babylon_tutorial/trigger/used_on/own_schema()
	return list(
		babylon_tutorial_field("item_type", "Item", "typepath", "", "The item the player must use.", base = /obj/item, required = TRUE, placeholder = "Search items, e.g. analyzer"),
		babylon_tutorial_field("exact", "Exactly this type", "bool", 0, "Off: variants of the item count too."),
		babylon_tutorial_field("target", "Target", "id", "", "A marker (its object) or an NPC spawner (its NPC) the item must be used on.", filter = list("marker", "npc"), required = TRUE),
	)

/obj/babylon_tutorial/trigger/used_on/Destroy()
	unhook()
	return ..()

/// Listens to the current target's item interactions (the target can change: a respawned NPC).
/obj/babylon_tutorial/trigger/used_on/proc/refresh_hook()
	var/atom/target = babylon_tutorial_resolve(setting("target"))
	if(isturf(target))
		target = null
	var/atom/hooked = hooked_target?.resolve()
	if(hooked == target)
		return
	unhook()
	if(target)
		RegisterSignal(target, COMSIG_ATOM_ITEM_INTERACTION, PROC_REF(on_item_interaction))
		hooked_target = WEAKREF(target)

/obj/babylon_tutorial/trigger/used_on/proc/unhook()
	var/atom/hooked = hooked_target?.resolve()
	if(hooked)
		UnregisterSignal(hooked, COMSIG_ATOM_ITEM_INTERACTION)
	hooked_target = null

/obj/babylon_tutorial/trigger/used_on/proc/on_item_interaction(atom/source, mob/living/user, obj/item/tool, list/modifiers)
	SIGNAL_HANDLER
	var/path = text2path(setting("item_type"))
	if(!path || !tool || !babylon_tutorial_type_matches(tool, path, setting("exact")))
		return NONE
	var/datum/babylon_tutorial_run/run = babylon_tutorial_run_of(user)
	run?.hit(src)
	// Never handles the interaction: the item still does what it does (the analyzer scans).
	return NONE

/obj/babylon_tutorial/trigger/used_on/check(datum/babylon_tutorial_run/run)
	return run.take_hit(src)

/obj/babylon_tutorial/trigger/used_on/find_issues()
	. = ..()
	var/obj/babylon_tutorial/target = babylon_tutorial_find(setting("target"))
	if(target && isturf(target.target_atom()))
		.["target"] = istype(target, /obj/babylon_tutorial/npc_spawner) ? "[target.tutorial_id] has no NPC right now: spawn it first." : "There is nothing on [target.tutorial_id]'s tile to use the item on."

/obj/babylon_tutorial/trigger/used_on/summary()
	return "[babylon_tutorial_type_label(setting("item_type"))] on [setting("target") || "?"], " + ..()

// ---------------------------------------------------------------------------------------------
// Condition

/obj/babylon_tutorial/trigger/condition
	tutorial_kind = "condition"
	kind_name = "Condition"
	kind_desc = "Fires when something in the world becomes true: gas, power, a fluid, a structure or an NPC's state."
	kind_example = "e.g. the patient's brute damage is healed to 10 or less."
	ui_icon = "list-check"
	view_icon = 'icons/effects/mapping_helpers.dmi'
	view_state = "trait"

/obj/babylon_tutorial/trigger/condition/own_schema()
	var/list/compare = babylon_tutorial_options(list("above" = "At least", "below" = "At most"))
	return list(
		babylon_tutorial_field("condition", "Check", "choice", "gas", "What to watch.", options = babylon_tutorial_options(list(
			"gas" = "Gas in a zone",
			"power" = "Power",
			"fluid" = "Fluid in a container",
			"structure" = "Structure at a marker",
			"npc" = "NPC state",
		))),
		// Gas
		babylon_tutorial_field("zone", "Zone", "zone", null, "The tiles whose air is measured (at most 1000). Without a zone it is this trigger's tile.", when = list("condition" = list("gas")), max_tiles = 1000),
		babylon_tutorial_field("gas", "Gas", "choice", "total", "Which gas to measure.", options = babylon_tutorial_gas_options(), when = list("condition" = list("gas"))),
		babylon_tutorial_field("measure", "Measure", "choice", "pressure", "Pressure: the average over the zone (kPa). Moles: the amount in the whole zone.", options = babylon_tutorial_options(list("pressure" = "Pressure (kPa)", "moles" = "Moles")), when = list("condition" = list("gas"))),
		// Power
		babylon_tutorial_field("power", "Power check", "choice", "area", "Area has power: the marker's room has equipment power. APC/SMES charge: the charge in % of the APC or SMES at the marker.", options = babylon_tutorial_options(list("area" = "Area has power", "apc" = "APC charge (%)", "smes" = "SMES charge (%)")), when = list("condition" = list("power"))),
		// Fluid
		babylon_tutorial_field("reagent", "Reagent", "typepath", "", "Empty: the container's total volume.", base = /datum/reagent, when = list("condition" = list("fluid")), placeholder = "Search reagents, e.g. water"),
		// Structure
		babylon_tutorial_field("structure_type", "Structure", "typepath", "", "The object that must be on the marker's tile.", base = /obj, when = list("condition" = list("structure")), placeholder = "Search, e.g. table"),
		babylon_tutorial_field("anchored", "Must be anchored", "bool", 1, "Only counts when it is wrenched/bolted down.", when = list("condition" = list("structure"))),
		// NPC
		babylon_tutorial_field("npc_check", "NPC check", "choice", "health_above", "Health: 100 is unhurt, 0 is in crit.", options = babylon_tutorial_options(list(
			"health_above" = "Health at least",
			"health_below" = "Health at most",
			"healed" = "Damage type healed to at most",
			"alive" = "Alive",
			"dead" = "Dead",
			"cured" = "Has no disease",
			"conscious" = "Awake",
		)), when = list("condition" = list("npc"))),
		babylon_tutorial_field("damage_type", "Damage type", "choice", "brute", null, options = babylon_tutorial_damage_options(), when = list("condition" = list("npc"), "npc_check" = list("healed"))),
		// Shared
		babylon_tutorial_field("target", "Marker / NPC", "id", "", "The marker (power, fluid, structure) or NPC spawner (NPC state) to watch.", filter = list("marker", "npc"), when = list("condition" = list("power", "fluid", "structure", "npc")), required = TRUE),
		babylon_tutorial_field("compare", "Compare", "choice", "above", null, options = compare, when = list("condition" = list("gas", "fluid", "power"))),
		babylon_tutorial_field("amount", "Amount", "number", 0, "Pressure in kPa, moles, units of fluid, charge in % or health.", min = -200, max = 100000, when = list("condition" = list("gas", "fluid", "power", "npc"))),
	)

/obj/babylon_tutorial/trigger/condition
	/// The last evaluation, shared by every run during one subsystem fire.
	var/cached_result
	var/cached_fire = -1

/obj/babylon_tutorial/trigger/condition/check(datum/babylon_tutorial_run/run)
	// The world is the same for every run: evaluate once per fire (tests call evaluate directly).
	if(SSbabylon_tutorial.firing_now)
		if(cached_fire != SSbabylon_tutorial.fire_count)
			cached_fire = SSbabylon_tutorial.fire_count
			cached_result = evaluate()
		return cached_result
	return evaluate()

/obj/babylon_tutorial/trigger/condition/find_issues()
	. = ..()
	var/condition = setting("condition")
	if(condition in list("fluid", "npc"))
		var/obj/babylon_tutorial/target = babylon_tutorial_find(setting("target"))
		if(target && isturf(target.target_atom()))
			.["target"] = condition == "npc" ? "[target.tutorial_id] has no NPC right now." : "There is nothing on [target.tutorial_id]'s tile to measure."

/// Whether the condition holds in the world right now.
/obj/babylon_tutorial/trigger/condition/proc/evaluate()
	var/amount = setting("amount")
	switch(setting("condition"))
		if("gas")
			var/list/zone = setting("zone")
			if(length(zone) != 5)
				var/turf/tile = get_turf(src)
				zone = list(tile.x, tile.y, tile.x, tile.y, tile.z)
			return babylon_tutorial_compare(babylon_tutorial_measure_gas(zone, setting("gas"), setting("measure")), setting("compare"), amount)
		if("power")
			var/atom/target = babylon_tutorial_resolve(setting("target"))
			if(!target)
				return FALSE
			switch(setting("power"))
				if("area")
					var/area/room = get_area(target)
					return !!room?.powered(AREA_USAGE_EQUIP)
				if("apc")
					var/obj/machinery/power/apc/apc = istype(target, /obj/machinery/power/apc) ? target : locate(/obj/machinery/power/apc) in get_turf(target)
					return apc?.cell && babylon_tutorial_compare(apc.cell.percent(), setting("compare"), amount)
				if("smes")
					var/obj/machinery/power/smes/smes = istype(target, /obj/machinery/power/smes) ? target : locate(/obj/machinery/power/smes) in get_turf(target)
					return smes && babylon_tutorial_compare(babylon_tutorial_smes_percent(smes), setting("compare"), amount)
			return FALSE
		if("fluid")
			var/atom/target = babylon_tutorial_resolve(setting("target"))
			if(!target?.reagents)
				return FALSE
			var/reagent = text2path(setting("reagent"))
			var/volume = reagent ? target.reagents.get_reagent_amount(reagent) : target.reagents.total_volume
			return babylon_tutorial_compare(volume, setting("compare"), amount)
		if("structure")
			var/obj/babylon_tutorial/marker = babylon_tutorial_find(setting("target"))
			var/path = text2path(setting("structure_type"))
			var/turf/tile = get_turf(marker)
			if(!tile || !path)
				return FALSE
			for(var/obj/thing in tile)
				if(istype(thing, path) && (!setting("anchored") || thing.anchored))
					return TRUE
			return FALSE
		if("npc")
			var/mob/living/carbon/human/npc = babylon_tutorial_resolve(setting("target"))
			if(!istype(npc))
				return FALSE
			switch(setting("npc_check"))
				if("health_above")
					return npc.stat != DEAD && npc.health >= amount
				if("health_below")
					return npc.health <= amount
				if("healed")
					return npc.stat != DEAD && babylon_tutorial_damage_of(npc, setting("damage_type")) <= amount
				if("alive")
					return npc.stat != DEAD
				if("dead")
					return npc.stat == DEAD
				if("cured")
					return npc.stat != DEAD && !length(npc.diseases)
				if("conscious")
					return babylon_tutorial_awake(npc)
	return FALSE

/obj/babylon_tutorial/trigger/condition/summary()
	return "[setting("condition")], " + ..()

/proc/babylon_tutorial_compare(value, compare, amount)
	if(isnull(value))
		return FALSE
	return compare == "below" ? value <= amount : value >= amount

/proc/babylon_tutorial_gas_options()
	return babylon_tutorial_options(list(
		"total" = "All gases",
		"[/datum/gas/oxygen]" = "Oxygen",
		"[/datum/gas/nitrogen]" = "Nitrogen",
		"[/datum/gas/carbon_dioxide]" = "Carbon dioxide",
		"[/datum/gas/plasma]" = "Plasma",
		"[/datum/gas/nitrous_oxide]" = "Nitrous oxide",
		"[/datum/gas/water_vapor]" = "Water vapour",
	))

/proc/babylon_tutorial_damage_options()
	return babylon_tutorial_options(list("brute" = "Brute", "burn" = "Burn", "tox" = "Toxin", "oxy" = "Suffocation"))

/proc/babylon_tutorial_damage_of(mob/living/target, damage_type)
	switch(damage_type)
		if("brute")
			return target.get_brute_loss()
		if("burn")
			return target.get_fire_loss()
		if("tox")
			return target.get_tox_loss()
		if("oxy")
			return target.get_oxy_loss()
	return 0

/// Gas in a zone: the average pressure (kPa) or the total moles, of one gas or all.
/proc/babylon_tutorial_measure_gas(list/zone, gas, measure)
	var/gas_path = gas == "total" ? null : text2path(gas)
	var/total = 0
	var/tiles = 0
	for(var/turf/open/tile in babylon_tutorial_zone_turfs(zone))
		var/datum/gas_mixture/air = tile.return_air()
		if(!air)
			continue
		tiles++
		var/moles = air.total_moles()
		var/gas_moles = gas_path ? (air.moles[gas_path] || 0) : moles
		if(measure == "moles")
			total += gas_moles
		else
			var/pressure = air.return_pressure()
			total += moles > 0 ? pressure * gas_moles / moles : 0
	if(measure == "moles")
		return total
	return tiles ? total / tiles : 0

/proc/babylon_tutorial_smes_percent(obj/machinery/power/smes/smes)
	var/charge = 0
	var/capacity = 0
	for(var/obj/item/stock_parts/power_store/cell in smes.component_parts)
		charge += cell.charge()
		capacity += cell.max_charge()
	return capacity ? 100 * charge / capacity : 0

// ---------------------------------------------------------------------------------------------
// Button

/obj/babylon_tutorial/trigger/button
	tutorial_kind = "button"
	kind_name = "Button"
	kind_desc = "A real button everyone can see; fires when the player presses it."
	kind_example = "e.g. \"Press when you are ready\"."
	ui_icon = "circle-dot"
	name = "button"
	desc = "Press it."
	icon = 'icons/obj/machines/wallmounts.dmi'
	icon_state = "button"
	view_icon = 'icons/obj/machines/wallmounts.dmi'
	view_state = "button"
	invisibility = 0
	mouse_opacity = MOUSE_OPACITY_ICON
	edge_triggered = FALSE

/obj/babylon_tutorial/trigger/button/own_schema()
	return list(
		babylon_tutorial_field("label", "Label", "text", "Button", "The button's name, as players see it.", is_name = TRUE),
	)

/obj/babylon_tutorial/trigger/button/Initialize(mapload)
	. = ..()
	settings_changed()

/obj/babylon_tutorial/trigger/button/settings_changed()
	name = setting("label") || "button"

/obj/babylon_tutorial/trigger/button/attack_hand(mob/living/user, list/modifiers)
	. = ..()
	if(.)
		return
	press(user)
	return TRUE

/obj/babylon_tutorial/trigger/button/attack_robot(mob/living/user)
	press(user)
	return TRUE

/obj/babylon_tutorial/trigger/button/proc/press(mob/living/user)
	playsound(src, 'sound/machines/click.ogg', 40, TRUE)
	flick("button-overlay-success", src)
	var/datum/babylon_tutorial_run/run = babylon_tutorial_run_of(user)
	run?.hit(src)

/obj/babylon_tutorial/trigger/button/check(datum/babylon_tutorial_run/run)
	return run.take_hit(src)

// ---------------------------------------------------------------------------------------------
// Say

/obj/babylon_tutorial/trigger/say
	tutorial_kind = "say"
	kind_name = "Say"
	kind_desc = "Fires when the player says a phrase (any part of what they say, upper/lower case ignored)."
	kind_example = "e.g. the player says \"ready\"."
	ui_icon = "comment"
	view_icon = 'icons/hud/screen_gen.dmi'
	view_state = "talk_hello"
	edge_triggered = FALSE

/obj/babylon_tutorial/trigger/say/own_schema()
	return list(
		babylon_tutorial_field("phrase", "Phrase", "text", "", "What the player must say, e.g. \"ready\".", required = TRUE),
	)

/obj/babylon_tutorial/trigger/say/check(datum/babylon_tutorial_run/run)
	return run.take_hit(src)

/obj/babylon_tutorial/trigger/say/summary()
	return "says \"[setting("phrase")]\", " + ..()

/obj/babylon_tutorial/trigger/say/proc/heard(datum/babylon_tutorial_run/run, message)
	var/phrase = setting("phrase")
	// Said text arrives HTML-encoded ("it&#39;s"); compare what the player typed.
	if(length(phrase) && findtext(html_decode(message), phrase))
		run.hit(src)

// ---------------------------------------------------------------------------------------------
// Timer

/obj/babylon_tutorial/trigger/timer
	tutorial_kind = "timer"
	kind_name = "Timer"
	kind_desc = "Fires a number of seconds after it started listening."
	kind_example = "e.g. a hint 30 seconds after a step began, if the player is stuck."
	ui_icon = "stopwatch"
	view_icon = 'icons/effects/landmarks_static.dmi'
	view_state = "generic_event"
	edge_triggered = FALSE

/obj/babylon_tutorial/trigger/timer/own_schema()
	return list(
		babylon_tutorial_field("seconds", "Seconds", "number", 10, "How long after being enabled it fires. A repeating timer starts counting again after each firing.", min = 1, max = 3600),
	)

/obj/babylon_tutorial/trigger/timer/check(datum/babylon_tutorial_run/run)
	return world.time >= run.enabled_since(src) + setting("seconds") SECONDS

/obj/babylon_tutorial/trigger/timer/summary()
	return "after [setting("seconds")] s, " + ..()
