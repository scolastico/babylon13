// Creative machines (spec 5.1): infinite sources and voids for power, gas, plumbing fluids and
// disposals. Shared by both game builds. They are spawned only through the Creative panel
// (babylon_creative_machine_types()), never by maps, research or cargo. Every infinite effect
// runs only while babylon_creative_enabled(); in any other world they are ordinary, inert
// machines that say so on examine.
//
// Settings: Alt + right-click opens a short series of tgui prompts (mode and the machine's
// setting). The SMES and canister keep their normal UIs for output level and valve/release
// pressure. The settings vars are saved with the world (BABYLON_CREATIVE_MACHINE_FIELDS).

#define BABYLON_CREATIVE_OFF_TEXT "Creative mode is off in this world."
#define BABYLON_CREATIVE_TINT "#c8a2ff"
/// Persisted settings of the creative machines, added to the save's extra_fields.
#define BABYLON_CREATIVE_MACHINE_FIELDS list("creative_mode", "creative_gas", "creative_pressure", "creative_reagent", "creative_item", "creative_interval")

/datum/babylon_save/New()
	. = ..()
	extra_fields |= BABYLON_CREATIVE_MACHINE_FIELDS

/// The spawnable creative machine types (the Creative panel offers these). Each base type is a
/// source; the named subtypes are presets of the same machine.
/proc/babylon_creative_machine_types()
	return list(
		/obj/machinery/power/smes/babylon_creative,
		/obj/machinery/power/smes/babylon_creative/sink,
		/obj/machinery/portable_atmospherics/canister/babylon_creative,
		/obj/machinery/portable_atmospherics/canister/babylon_creative/nitrogen,
		/obj/machinery/portable_atmospherics/canister/babylon_creative/void,
		/obj/machinery/plumbing/babylon_creative_tank,
		/obj/machinery/plumbing/babylon_creative_tank/void,
		/obj/machinery/disposal/bin/babylon_creative,
		/obj/machinery/disposal/bin/babylon_creative/void,
	)

/// Shared examine lines: what the machine does, or that Creative is off here.
/proc/babylon_creative_examine(list/examine_list, summary)
	if(!babylon_creative_enabled())
		examine_list += span_warning(BABYLON_CREATIVE_OFF_TEXT)
		return
	examine_list += span_notice(summary)
	examine_list += span_notice("[EXAMINE_HINT("Alt + right-click")] to change its creative settings.")

/// Settings may only change in a creative world, by someone who can still reach the machine.
/proc/babylon_creative_can_configure(atom/machine, mob/user)
	if(QDELETED(machine) || QDELETED(user))
		return FALSE
	if(!babylon_creative_enabled())
		to_chat(user, span_warning(BABYLON_CREATIVE_OFF_TEXT))
		return FALSE
	return user.can_perform_action(machine)

/// Asks for one of the modes; null when cancelled.
/proc/babylon_creative_ask_mode(atom/machine, mob/user, list/modes, current)
	var/choice = tgui_input_list(user, "Mode for [machine]", "Creative machine", modes, current)
	if(!(choice in modes) || !babylon_creative_can_configure(machine, user))
		return null
	return choice

/// Gases a creative canister can produce: every gas in the standard gas list.
/proc/babylon_creative_gas_choices()
	var/list/choices = list()
	var/list/names = GLOB.meta_gas_info[META_GAS_NAME]
	for(var/gas_type in names)
		choices["[names[gas_type]]"] = gas_type
	return choices

/proc/babylon_creative_gas_allowed(gas_type)
	return ispath(gas_type, /datum/gas) && !isnull(GLOB.meta_gas_info[META_GAS_NAME][gas_type])

/// Reagents a creative tank can produce: those chemistry may synthesize
/// (REAGENT_CAN_BE_SYNTHESIZED, the chem dispenser/synthesizer rule, which keeps out admin-only
/// and special reagents) and none of the ERP reagents (sfw.dm).
/proc/babylon_creative_reagent_allowed(reagent_type)
	if(!ispath(reagent_type, /datum/reagent))
		return FALSE
	var/datum/reagent/reagent = GLOB.chemical_reagents_list[reagent_type]
	if(!reagent || !(reagent.chemical_flags & REAGENT_CAN_BE_SYNTHESIZED))
		return FALSE
	return !is_type_in_typecache(reagent_type, babylon_erp_reagents())

/proc/babylon_creative_reagent_choices()
	var/list/choices = list()
	for(var/reagent_type in GLOB.chemical_reagents_list)
		if(babylon_creative_reagent_allowed(reagent_type))
			var/datum/reagent/reagent = GLOB.chemical_reagents_list[reagent_type]
			choices["[reagent.name]"] = reagent_type
	return sortTim(choices, GLOBAL_PROC_REF(cmp_text_asc))

/// Items a creative disposal source may produce: concrete /obj/item types only. Abstract
/// types, abstract (non-physical) items and a few that would harm the server or bypass the
/// SFW and spawning rules when produced every few seconds stay out.
/proc/babylon_creative_item_allowed(item_type)
	if(!ispath(item_type, /obj/item))
		return FALSE
	var/obj/item/item_path = item_type
	if(initial(item_path.abstract_type) == item_type || (initial(item_path.item_flags) & ABSTRACT))
		return FALSE
	var/static/list/blocked = typecacheof(list(
		/obj/item/antag_spawner, // summons ghost roles
		/obj/item/bombcore,
		/obj/item/disk/nuclear, // round-critical, tracked globally
		/obj/item/grenade,
		/obj/item/hand_item, // abstract hand gestures
		/obj/item/hilbertshotel, // creates map levels
		/obj/item/mmi, // brain holders
		/obj/item/mob_holder, // holds a mob
		/obj/item/transfer_valve,
	))
	return !is_type_in_typecache(item_type, blocked)

// ---------------------------------------------------------------------------------------------
// Creative SMES: source keeps its charge at the maximum and outputs its output level forever;
// sink absorbs every bit of surplus power on its own cable and its terminal's network.

/obj/item/circuitboard/machine/smes/babylon_creative
	name = "creative SMES"
	build_path = /obj/machinery/power/smes/babylon_creative

/obj/machinery/power/smes/babylon_creative
	name = "creative SMES (source)"
	desc = "A creative-mode power storage unit. As a source it never runs dry; as a sink it swallows any power it is offered."
	color = BABYLON_CREATIVE_TINT
	circuit = /obj/item/circuitboard/machine/smes/babylon_creative
	output_level = 200 KILO WATTS
	/// "source" or "sink".
	var/creative_mode = "source"

/obj/machinery/power/smes/babylon_creative/sink
	name = "creative SMES (sink)"
	creative_mode = "sink"
	output_attempt = FALSE

/obj/machinery/power/smes/babylon_creative/Initialize(mapload)
	. = ..()
	// A creative SMES needs no terminal: it feeds (or drains) the cable it stands on.
	if(!terminal)
		set_machine_stat(machine_stat & ~BROKEN)
		update_appearance()

/obj/machinery/power/smes/babylon_creative/disconnect_terminal()
	if(terminal)
		terminal.master = null
		terminal = null

/obj/machinery/power/smes/babylon_creative/RefreshParts()
	. = ..()
	input_level_max = max(input_level_max, 10 MEGA WATTS)
	output_level_max = max(output_level_max, 10 MEGA WATTS)

/obj/machinery/power/smes/babylon_creative/examine(mob/user)
	. = ..()
	babylon_creative_examine(., creative_mode == "sink" ? "Sink: absorbs all surplus power on its cable and terminal." : "Source: never runs out of charge and outputs its output level.")

/obj/machinery/power/smes/babylon_creative/process(seconds_per_tick)
	if(!babylon_creative_enabled())
		return ..()
	if(creative_mode == "sink")
		creative_sink()
		return
	adjust_charge(total_capacity)
	. = ..()
	adjust_charge(total_capacity)

/// Takes all surplus on the SMES's own network and its terminal's, storing none of it.
/obj/machinery/power/smes/babylon_creative/proc/creative_sink()
	var/last_inputting = inputting
	var/last_outputting = outputting
	adjust_charge(-total_charge())
	outputting = FALSE
	output_used = 0
	input_available = 0
	if(machine_stat & BROKEN)
		inputting = FALSE
	else
		for(var/datum/powernet/net in list(powernet, terminal?.powernet))
			var/surplus = clamp(net.avail - net.load, 0, net.avail)
			if(surplus > 0)
				net.load += surplus
				input_available += surplus
		inputting = input_available > 0
	if(last_inputting != inputting || last_outputting != outputting)
		update_appearance(UPDATE_OVERLAYS)

/obj/machinery/power/smes/babylon_creative/click_alt_secondary(mob/user)
	if(!babylon_creative_can_configure(src, user))
		return CLICK_ACTION_BLOCKING
	INVOKE_ASYNC(src, PROC_REF(creative_configure), user)
	return CLICK_ACTION_SUCCESS

/obj/machinery/power/smes/babylon_creative/proc/creative_configure(mob/user)
	var/mode = babylon_creative_ask_mode(src, user, list("source", "sink"), creative_mode)
	if(mode)
		set_creative_mode(mode)
		balloon_alert(user, mode)

/obj/machinery/power/smes/babylon_creative/proc/set_creative_mode(mode)
	creative_mode = mode == "sink" ? "sink" : "source"
	name = "creative SMES ([creative_mode])"
	if(creative_mode == "sink")
		output_attempt = FALSE
	update_appearance(UPDATE_OVERLAYS)

// ---------------------------------------------------------------------------------------------
// Creative canister: source refills itself with its gas to the fill pressure, so its valve or a
// connector port never runs dry; void deletes all gas inside it every atmos tick (connected to a
// port it drains the whole pipe network, a scrubber sink).

/obj/machinery/portable_atmospherics/canister/babylon_creative
	name = "creative canister (oxygen source)"
	desc = "A creative-mode canister. As a source it refills itself with its gas; as a void it destroys any gas that enters it."
	greyscale_config = /datum/greyscale_config/canister/double_stripe
	greyscale_colors = "#7b3fbf#e9d8ff"
	/// "source" or "void".
	var/creative_mode = "source"
	/// The gas a source produces (a /datum/gas path).
	var/creative_gas = /datum/gas/oxygen
	/// The pressure (kPa) a source refills itself to.
	var/creative_pressure = 4500

/obj/machinery/portable_atmospherics/canister/babylon_creative/nitrogen
	name = "creative canister (nitrogen source)"
	creative_gas = /datum/gas/nitrogen

/obj/machinery/portable_atmospherics/canister/babylon_creative/void
	name = "creative canister (void)"
	creative_mode = "void"
	greyscale_colors = "#2b1840#7b3fbf"

/obj/machinery/portable_atmospherics/canister/babylon_creative/examine(mob/user)
	. = ..()
	if(creative_mode == "void")
		babylon_creative_examine(., "Void: destroys all gas inside it.")
	else
		babylon_creative_examine(., "Source: refills itself with [creative_gas_name()] to [creative_pressure] kPa.")

/obj/machinery/portable_atmospherics/canister/babylon_creative/proc/creative_gas_name()
	return babylon_creative_gas_allowed(creative_gas) ? LOWER_TEXT(GLOB.meta_gas_info[META_GAS_NAME][creative_gas]) : "nothing"

/obj/machinery/portable_atmospherics/canister/babylon_creative/process_atmos()
	if(babylon_creative_enabled() && !(machine_stat & BROKEN))
		creative_tick()
	. = ..()
	// Stay in the atmos machinery loop (a quiet canister normally drops out of it), so the
	// source keeps refilling and the void keeps draining whatever the port pushes in.
	if(!(machine_stat & BROKEN))
		return null

/// One atmos tick of the infinite behaviour.
/obj/machinery/portable_atmospherics/canister/babylon_creative/proc/creative_tick()
	if(creative_mode == "void")
		if(air_contents.total_moles() > 0)
			air_contents.remove(air_contents.total_moles())
		return
	if(!babylon_creative_gas_allowed(creative_gas))
		return
	if(air_contents.total_moles() <= 0 || air_contents.temperature < TCMB)
		air_contents.temperature = T20C
	var/missing = creative_pressure - air_contents.return_pressure()
	if(missing > 0)
		air_contents.adjust_gas(creative_gas, missing * air_contents.volume / (R_IDEAL_GAS_EQUATION * air_contents.temperature))

/obj/machinery/portable_atmospherics/canister/babylon_creative/ui_act(action, list/params, datum/tgui/ui, datum/ui_state/state)
	// Relabelling would disguise it as an ordinary canister.
	if(action == "relabel")
		return FALSE
	return ..()

/obj/machinery/portable_atmospherics/canister/babylon_creative/click_alt_secondary(mob/user)
	if(!babylon_creative_can_configure(src, user))
		return CLICK_ACTION_BLOCKING
	INVOKE_ASYNC(src, PROC_REF(creative_configure), user)
	return CLICK_ACTION_SUCCESS

/obj/machinery/portable_atmospherics/canister/babylon_creative/proc/creative_configure(mob/user)
	var/mode = babylon_creative_ask_mode(src, user, list("source", "void"), creative_mode)
	if(!mode)
		return
	if(mode == "void")
		set_creative_settings(mode, creative_gas, creative_pressure)
		balloon_alert(user, "void")
		return
	var/list/gases = babylon_creative_gas_choices()
	var/gas_name = tgui_input_list(user, "Gas to produce", "Creative canister", gases, GLOB.meta_gas_info[META_GAS_NAME][creative_gas])
	if(!gas_name || !babylon_creative_can_configure(src, user))
		return
	var/pressure = tgui_input_number(user, "Pressure to keep inside (kPa)", "Creative canister", creative_pressure, 9000, 100)
	if(isnull(pressure) || !babylon_creative_can_configure(src, user))
		return
	set_creative_settings(mode, gases[gas_name], pressure)
	balloon_alert(user, "[creative_gas_name()] source")

/obj/machinery/portable_atmospherics/canister/babylon_creative/proc/set_creative_settings(mode, gas_type, pressure)
	creative_mode = mode == "void" ? "void" : "source"
	if(babylon_creative_gas_allowed(gas_type))
		creative_gas = gas_type
	creative_pressure = clamp(round(pressure), 100, 9000)
	if(creative_mode == "source" && babylon_creative_enabled())
		// A new gas replaces the old one instead of mixing with it.
		air_contents.remove(air_contents.total_moles())
	name = creative_mode == "void" ? "creative canister (void)" : "creative canister ([creative_gas_name()] source)"
	SSair.start_processing_machine(src)
	update_appearance()

// ---------------------------------------------------------------------------------------------
// Creative fluid tank (plumbing): source keeps itself full of its reagent, supplying the ducts
// on its output side; void empties itself every tick, so it takes everything its input side
// is offered. Ducts connect like the ordinary chemical tank (input west, output east).

/obj/machinery/plumbing/babylon_creative_tank
	name = "creative fluid tank (water source)"
	desc = "A creative-mode chemical tank. As a source it never runs dry; as a void it destroys every reagent piped into it."
	icon_state = "tank"
	color = BABYLON_CREATIVE_TINT
	use_power = NO_POWER_USE
	buffer = 400
	/// "source" or "void".
	var/creative_mode = "source"
	/// The reagent a source produces (a /datum/reagent path).
	var/creative_reagent = /datum/reagent/water

/obj/machinery/plumbing/babylon_creative_tank/void
	name = "creative fluid tank (void)"
	creative_mode = "void"

/obj/machinery/plumbing/babylon_creative_tank/Initialize(mapload, layer)
	. = ..()
	AddComponent(/datum/component/plumbing/tank, layer)

/obj/machinery/plumbing/babylon_creative_tank/examine(mob/user)
	. = ..()
	if(creative_mode == "void")
		babylon_creative_examine(., "Void: destroys every reagent that enters it.")
	else
		babylon_creative_examine(., "Source: keeps itself full of [creative_reagent_name()].")

/obj/machinery/plumbing/babylon_creative_tank/proc/creative_reagent_name()
	var/datum/reagent/reagent = babylon_creative_reagent_allowed(creative_reagent) ? GLOB.chemical_reagents_list[creative_reagent] : null
	return reagent ? LOWER_TEXT(reagent.name) : "nothing"

/obj/machinery/plumbing/babylon_creative_tank/process(seconds_per_tick)
	if(!babylon_creative_enabled() || (machine_stat & BROKEN))
		return
	if(creative_mode == "void")
		if(reagents.total_volume)
			reagents.clear_reagents()
		return
	if(!babylon_creative_reagent_allowed(creative_reagent))
		return
	for(var/datum/reagent/other as anything in reagents.reagent_list.Copy())
		if(other.type != creative_reagent)
			reagents.del_reagent(other.type)
	var/missing = reagents.maximum_volume - reagents.total_volume
	if(missing > 0)
		reagents.add_reagent(creative_reagent, missing)

/obj/machinery/plumbing/babylon_creative_tank/click_alt_secondary(mob/user)
	if(!babylon_creative_can_configure(src, user))
		return CLICK_ACTION_BLOCKING
	INVOKE_ASYNC(src, PROC_REF(creative_configure), user)
	return CLICK_ACTION_SUCCESS

/obj/machinery/plumbing/babylon_creative_tank/proc/creative_configure(mob/user)
	var/mode = babylon_creative_ask_mode(src, user, list("source", "void"), creative_mode)
	if(!mode)
		return
	var/reagent_type = creative_reagent
	if(mode == "source")
		var/list/choices = babylon_creative_reagent_choices()
		var/reagent_name = tgui_input_list(user, "Reagent to produce", "Creative fluid tank", choices)
		if(!reagent_name || !babylon_creative_can_configure(src, user))
			return
		reagent_type = choices[reagent_name]
	set_creative_settings(mode, reagent_type)
	balloon_alert(user, mode == "void" ? "void" : "[creative_reagent_name()] source")

/obj/machinery/plumbing/babylon_creative_tank/proc/set_creative_settings(mode, reagent_type)
	creative_mode = mode == "void" ? "void" : "source"
	if(babylon_creative_reagent_allowed(reagent_type))
		creative_reagent = reagent_type
	if(babylon_creative_enabled())
		reagents.clear_reagents()
	name = creative_mode == "void" ? "creative fluid tank (void)" : "creative fluid tank ([creative_reagent_name()] source)"

// ---------------------------------------------------------------------------------------------
// Creative disposal unit: source drops its item into itself every creative_interval seconds and
// flushes it down the trunk below it (no pressure needed); void deletes whatever arrives through
// the pipes or is put inside. Mobs are never deleted: they are put out on the floor instead.

/obj/machinery/disposal/bin/babylon_creative
	name = "creative disposal unit (source)"
	desc = "A creative-mode disposal unit. As a source it sends an item down its pipe every few seconds; as a void it destroys everything that reaches it."
	color = BABYLON_CREATIVE_TINT
	/// "source" or "void".
	var/creative_mode = "source"
	/// The item a source produces (an /obj/item path).
	var/creative_item = /obj/item/stack/sheet/iron
	/// Seconds between two items of a source (at least 2).
	var/creative_interval = 10
	/// world.time at which a source sends its next item.
	var/creative_next = 0

/obj/machinery/disposal/bin/babylon_creative/void
	name = "creative disposal unit (void)"
	creative_mode = "void"

/obj/machinery/disposal/bin/babylon_creative/examine(mob/user)
	. = ..()
	if(creative_mode == "void")
		babylon_creative_examine(., "Void: destroys everything that reaches it, except living beings.")
	else
		var/obj/item/item_path = creative_item
		babylon_creative_examine(., "Source: sends [babylon_creative_item_allowed(creative_item) ? initial(item_path.name) : "nothing"] down its pipe every [creative_interval] seconds[trunk ? "" : " once it stands on a disposal pipe trunk"].")

/obj/machinery/disposal/bin/babylon_creative/process(seconds_per_tick)
	if(!babylon_creative_enabled() || (machine_stat & BROKEN))
		return ..()
	if(creative_mode == "void")
		creative_destroy(contents)
		return
	if(world.time < creative_next || flushing || !trunk || !babylon_creative_item_allowed(creative_item))
		return
	creative_next = world.time + max(2, creative_interval) SECONDS
	new creative_item(src)
	do_flush()

/// Arrivals through the pipe network.
/obj/machinery/disposal/bin/babylon_creative/expel(obj/structure/disposalholder/holder)
	if(!babylon_creative_enabled() || creative_mode != "void")
		return ..()
	holder.active = FALSE
	creative_destroy(holder.contents)
	holder.vent_gas(loc)
	qdel(holder)

/// Deletes the given things; mobs, and anything carrying one, are put out on the floor.
/obj/machinery/disposal/bin/babylon_creative/proc/creative_destroy(list/things)
	var/turf/floor = get_turf(src)
	for(var/atom/movable/thing as anything in things.Copy())
		if(QDELETED(thing) || thing == stored || thing == mounted_tagger)
			continue
		if(ismob(thing) || length(thing.get_all_contents_type(/mob)))
			thing.forceMove(floor)
			continue
		qdel(thing)
	update_appearance()

/obj/machinery/disposal/bin/babylon_creative/click_alt_secondary(mob/user)
	if(!babylon_creative_can_configure(src, user))
		return CLICK_ACTION_BLOCKING
	INVOKE_ASYNC(src, PROC_REF(creative_configure), user)
	return CLICK_ACTION_SUCCESS

/obj/machinery/disposal/bin/babylon_creative/proc/creative_configure(mob/user)
	var/mode = babylon_creative_ask_mode(src, user, list("source", "void"), creative_mode)
	if(!mode)
		return
	var/item_type = creative_item
	var/interval = creative_interval
	if(mode == "source")
		var/search = tgui_input_text(user, "Item type path or part of it (e.g. sheet/iron)", "Creative disposal unit", "[creative_item]", 128)
		if(!search || !babylon_creative_can_configure(src, user))
			return
		var/list/matches = list()
		for(var/candidate in subtypesof(/obj/item))
			if(findtext("[candidate]", search) && babylon_creative_item_allowed(candidate))
				matches += candidate
				if(length(matches) >= 200)
					break
		if(!length(matches))
			to_chat(user, span_warning("No spawnable item matches \"[search]\"."))
			return
		item_type = length(matches) == 1 ? matches[1] : tgui_input_list(user, "Item to send", "Creative disposal unit", matches)
		if(!item_type || !babylon_creative_can_configure(src, user))
			return
		interval = tgui_input_number(user, "Seconds between items", "Creative disposal unit", creative_interval, 600, 2)
		if(isnull(interval) || !babylon_creative_can_configure(src, user))
			return
	set_creative_settings(mode, item_type, interval)
	balloon_alert(user, creative_mode)

/obj/machinery/disposal/bin/babylon_creative/proc/set_creative_settings(mode, item_type, interval)
	creative_mode = mode == "void" ? "void" : "source"
	if(babylon_creative_item_allowed(item_type))
		creative_item = item_type
	creative_interval = clamp(round(interval), 2, 600)
	creative_next = 0
	name = "creative disposal unit ([creative_mode])"

#undef BABYLON_CREATIVE_OFF_TEXT
#undef BABYLON_CREATIVE_TINT
#undef BABYLON_CREATIVE_MACHINE_FIELDS
