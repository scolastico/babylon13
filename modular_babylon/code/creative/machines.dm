// Creative machines (spec 5.1): infinite sources and voids for power, gas, plumbing fluids and
// disposals. Shared by both game builds. They are spawned through the Creative panel
// (babylon_creative_machine_types()) and placed by the generated Creative Plane maps
// (creative/plane.dm), never by research or cargo.
//
// Behaviour: the infinite effects run while babylon_creative_machines_active(): in Creative
// worlds, in tutorial instances (an authored scenario keeps its creative power and air even
// though the players there have no Creative panel) and on Creative Plane maps (the map's own
// power and air infrastructure, whatever the Creative flag). Anywhere else they are ordinary, inert
// machines that say so on examine.
//
// Settings: Ctrl + Shift + click (free on all four machines; Alt-clicks are taken by plumbing
// rotation and canister ports) opens a short series of tgui prompts, in Creative worlds only.
// The SMES and canister keep their normal UIs for output level and valve/release pressure.
// The settings vars are saved with the world (BABYLON_CREATIVE_MACHINE_FIELDS).

#define BABYLON_CREATIVE_OFF_TEXT "Creative mode is off in this world."
#define BABYLON_CREATIVE_TINT "#c8a2ff"
#define BABYLON_CREATIVE_GESTURE "Ctrl + Shift + click"
/// Persisted settings of the creative machines, added to the save's extra_fields.
#define BABYLON_CREATIVE_MACHINE_FIELDS list("creative_mode", "creative_gas", "creative_pressure", "creative_reagent", "creative_item", "creative_interval")

/// Integration tests answer the settings prompts from this list instead of asking a player.
GLOBAL_VAR(babylon_creative_test_answers)

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

/// The machines' infinite behaviour runs: Creative worlds, tutorial instances and Creative
/// Plane maps. Changing their settings stays Creative-only (babylon_creative_can_configure).
/proc/babylon_creative_machines_active()
	return babylon_creative_enabled() || !!GLOB.babylon_world?.is_tutorial() || !!GLOB.babylon_world?.is_creative_plane()

/// Shared examine lines: what the machine does, how to change it, or that it is inert here.
/proc/babylon_creative_examine(list/examine_list, summary)
	if(!babylon_creative_machines_active())
		examine_list += span_warning(BABYLON_CREATIVE_OFF_TEXT)
		return
	examine_list += span_notice(summary)
	if(babylon_creative_enabled())
		examine_list += span_notice("[EXAMINE_HINT(BABYLON_CREATIVE_GESTURE)] it to change its creative settings.")

/// Screentip for the settings gesture, shown where settings may change.
/proc/babylon_creative_context(list/context)
	if(!babylon_creative_enabled())
		return NONE
	context[SCREENTIP_CONTEXT_CTRL_SHIFT_LMB] = "Creative settings (Ctrl + Shift + click)"
	return CONTEXTUAL_SCREENTIP_SET

/// Settings may only change in a Creative world, by someone who can still reach the machine.
/proc/babylon_creative_can_configure(atom/machine, mob/user)
	if(QDELETED(machine) || QDELETED(user))
		return FALSE
	if(!babylon_creative_enabled())
		to_chat(user, span_warning(BABYLON_CREATIVE_OFF_TEXT))
		return FALSE
	return user.can_perform_action(machine)

/// One settings prompt: kind "list", "number" or "text". Tests answer from
/// GLOB.babylon_creative_test_answers.
/proc/babylon_creative_prompt(mob/user, kind, message, title, list/items, default, max_value, min_value)
	if(islist(GLOB.babylon_creative_test_answers))
		var/list/answers = GLOB.babylon_creative_test_answers
		if(!length(answers))
			return null
		var/answer = answers[1]
		answers.Cut(1, 2)
		return answer
	switch(kind)
		if("list")
			return tgui_input_list(user, message, title, items, default)
		if("number")
			return tgui_input_number(user, message, title, default, max_value, min_value)
		if("text")
			return tgui_input_text(user, message, title, default, 128)

/// Asks for one of the modes (display text = mode); returns the mode or null when cancelled.
/proc/babylon_creative_ask_mode(atom/machine, mob/user, list/modes, current)
	var/current_text
	for(var/text in modes)
		if(modes[text] == current)
			current_text = text
	var/choice = babylon_creative_prompt(user, "list", "Mode for [machine]", "Creative machine", modes, current_text)
	if(choice in modes)
		choice = modes[choice]
	var/list/values = list()
	for(var/text in modes)
		values += modes[text]
	if(!(choice in values) || !babylon_creative_can_configure(machine, user))
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
			// Several reagents share a name; a taken name gets the type appended.
			var/key = "[reagent.name]"
			if(key in choices)
				key = "[reagent.name] ([reagent_type])"
			choices[key] = reagent_type
	return sortTim(choices, GLOBAL_PROC_REF(cmp_text_asc))

/// What would harm the round when a creative disposal source made it every few seconds, on top of
/// the panel's blocklist: grenades, bomb cores, tank transfer valves and brain holders.
/proc/babylon_creative_automated_extra(item_type)
	var/static/list/automated_extra = typecacheof(list(
		/obj/item/bombcore,
		/obj/item/grenade,
		/obj/item/mmi,
		/obj/item/transfer_valve,
	))
	return is_type_in_typecache(item_type, automated_extra)

/// Item types a creative disposal source never produces: everything the Creative panel may not
/// spawn (babylon_creative_spawn_blocked, spawning.dm: the one spawn blocklist, ERP items
/// included), plus babylon_creative_automated_extra().
/proc/babylon_creative_item_blocked(item_type)
	return babylon_creative_spawn_blocked(item_type) || babylon_creative_automated_extra(item_type)

/// Things a produced item may not carry inside it: only the harmful half of the blocklist
/// (babylon_creative_type_harmful) plus babylon_creative_automated_extra(). The entry rules
/// (abstract, ABSTRACT, no icon) do not apply to contents: a revolver's internal cylinder and an
/// implanter's implant are ABSTRACT, and the item breaks without them.
/proc/babylon_creative_inner_item_blocked(item_type)
	return babylon_creative_type_harmful(item_type) || babylon_creative_automated_extra(item_type)

/// Items a creative disposal source may produce: /obj/item types only (the panel's blocklist
/// already refuses abstract types and ABSTRACT items), nothing babylon_creative_item_blocked().
/proc/babylon_creative_item_allowed(item_type)
	return ispath(item_type, /obj/item) && !babylon_creative_item_blocked(item_type)

/// "[name] ([path])" entries of the allowed items whose name or path contains the search, sorted,
/// at most limit of them.
/proc/babylon_creative_item_matches(search, limit = 200)
	var/list/matches = list()
	search = LOWER_TEXT(trim(search))
	if(!length(search))
		return matches
	for(var/obj/item/candidate as anything in subtypesof(/obj/item))
		var/item_name = initial(candidate.name)
		if(!findtext(LOWER_TEXT(item_name), search) && !findtext("[candidate]", search))
			continue
		if(!babylon_creative_item_allowed(candidate))
			continue
		matches["[item_name] ([candidate])"] = candidate
	sortTim(matches, GLOBAL_PROC_REF(cmp_text_asc))
	if(length(matches) > limit)
		matches.Cut(limit + 1)
	return matches

// ---------------------------------------------------------------------------------------------
// Creative SMES: source keeps its charge at the maximum and outputs its output level forever;
// sink takes in the power left over on its cable and terminal networks after every other
// machine has drawn (powernet netexcess), so it never starves APCs, and stores none of it.

/obj/item/circuitboard/machine/smes/babylon_creative
	name = "creative SMES"
	build_path = /obj/machinery/power/smes/babylon_creative

/obj/machinery/power/smes/babylon_creative
	name = "creative SMES (source)"
	desc = "A creative-mode power storage unit. As a source it never runs dry; as a sink it soaks up whatever power is left over."
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
	babylon_creative_examine(., creative_mode == "sink" ? "Sink: soaks up the power left over on its cable and terminal networks." : "Source: never runs out of charge and outputs its output level.")

/obj/machinery/power/smes/babylon_creative/add_context(atom/source, list/context, obj/item/held_item, mob/user)
	. = ..()
	if(babylon_creative_context(context))
		return CONTEXTUAL_SCREENTIP_SET

/obj/machinery/power/smes/babylon_creative/process(seconds_per_tick)
	if(!babylon_creative_machines_active())
		return ..()
	if(creative_mode == "sink")
		creative_sink()
		return
	adjust_charge(total_capacity)
	. = ..()
	adjust_charge(total_capacity)

/// Counts the power nobody else used on its networks last cycle (netexcess, after the other
/// SMESes recharged from it) as taken in. It adds no load, so other consumers keep priority.
/obj/machinery/power/smes/babylon_creative/proc/creative_sink()
	var/last_inputting = inputting
	var/last_outputting = outputting
	adjust_charge(-total_charge())
	outputting = FALSE
	output_used = 0
	input_available = 0
	if(!(machine_stat & BROKEN))
		for(var/datum/powernet/net in list(powernet, terminal?.powernet))
			input_available += max(0, net.netexcess)
	inputting = input_available > 0
	if(last_inputting != inputting || last_outputting != outputting)
		update_appearance(UPDATE_OVERLAYS)

/obj/machinery/power/smes/babylon_creative/click_ctrl_shift(mob/user)
	if(!babylon_creative_can_configure(src, user))
		return CLICK_ACTION_BLOCKING
	INVOKE_ASYNC(src, PROC_REF(creative_configure), user)
	return CLICK_ACTION_SUCCESS

/obj/machinery/power/smes/babylon_creative/proc/creative_configure(mob/user)
	var/mode = babylon_creative_ask_mode(src, user, list(
		"Source - never runs dry, outputs its output level" = "source",
		"Sink - soaks up leftover power" = "sink",
	), creative_mode)
	if(!mode)
		return
	set_creative_mode(mode)
	balloon_alert(user, mode == "source" ? "source, output on" : "sink")

/obj/machinery/power/smes/babylon_creative/proc/set_creative_mode(mode)
	creative_mode = mode == "sink" ? "sink" : "source"
	name = "creative SMES ([creative_mode])"
	output_attempt = creative_mode == "source"
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
	/// It belongs on the connector port on its tile: it reconnects to that port whenever it can
	/// (mapped canisters, restored saves). Set when it starts on a port or connects; cleared when
	/// it is disconnected (a wrench), so a player's choice sticks.
	var/babylon_port_wanted = FALSE

/obj/machinery/portable_atmospherics/canister/babylon_creative/nitrogen
	name = "creative canister (nitrogen source)"
	creative_gas = /datum/gas/nitrogen

/obj/machinery/portable_atmospherics/canister/babylon_creative/void
	name = "creative canister (void)"
	creative_mode = "void"
	greyscale_colors = "#2b1840#7b3fbf"

/obj/machinery/portable_atmospherics/canister/babylon_creative/Initialize(mapload)
	. = ..()
	if(!(locate(/obj/machinery/atmospherics/components/unary/portables_connector) in loc))
		return
	babylon_port_wanted = TRUE
	// Pipe networks exist once SSair has initialized (or a moment after a runtime load); until
	// then a connection is impossible. process_atmos retries too.
	if(SSair.initialized)
		babylon_reconnect_port()
	else
		RegisterSignal(SSair, COMSIG_SUBSYSTEM_POST_INITIALIZE, PROC_REF(on_air_initialized))

/obj/machinery/portable_atmospherics/canister/babylon_creative/Destroy()
	UnregisterSignal(SSair, COMSIG_SUBSYSTEM_POST_INITIALIZE)
	return ..()

/obj/machinery/portable_atmospherics/canister/babylon_creative/proc/on_air_initialized(datum/source)
	SIGNAL_HANDLER
	UnregisterSignal(SSair, COMSIG_SUBSYSTEM_POST_INITIALIZE)
	babylon_reconnect_port()

/// Connects to a free connector port on its tile once that port's pipe network exists. TRUE if
/// it is connected afterwards. Also called after a save is restored.
/obj/machinery/portable_atmospherics/canister/babylon_creative/proc/babylon_reconnect_port()
	if(connected_port)
		return TRUE
	var/obj/machinery/atmospherics/components/unary/portables_connector/port = locate() in loc
	if(!port || port.connected_device || !port.parents[1])
		return FALSE
	return connect(port)

/// After a restore (persistence.dm restore_world, once the saved pipe networks and portable
/// connections are back): every restored creative canister that belongs on a port goes back onto
/// it. One that cannot yet (no pipe network) retries lazily in process_atmos.
/datum/babylon_save/proc/reconnect_creative_canisters()
	for(var/save_id in restored_atoms)
		var/obj/machinery/portable_atmospherics/canister/babylon_creative/canister = restored_atoms[save_id]
		if(istype(canister) && !QDELETED(canister) && canister.babylon_port_wanted)
			canister.babylon_reconnect_port()

/obj/machinery/portable_atmospherics/canister/babylon_creative/connect(obj/machinery/atmospherics/components/unary/portables_connector/new_port)
	. = ..()
	if(.)
		babylon_port_wanted = TRUE

/obj/machinery/portable_atmospherics/canister/babylon_creative/disconnect(destroyed = FALSE)
	. = ..()
	if(. && !destroyed)
		babylon_port_wanted = FALSE

/obj/machinery/portable_atmospherics/canister/babylon_creative/examine(mob/user)
	. = ..()
	if(creative_mode == "void")
		babylon_creative_examine(., "Void: destroys all gas inside it.")
	else
		babylon_creative_examine(., "Source: refills itself with [creative_gas_name()] to [creative_pressure] kPa.")

/obj/machinery/portable_atmospherics/canister/babylon_creative/add_context(atom/source, list/context, obj/item/held_item, mob/user)
	. = ..()
	if(babylon_creative_context(context))
		return CONTEXTUAL_SCREENTIP_SET

/obj/machinery/portable_atmospherics/canister/babylon_creative/proc/creative_gas_name()
	return babylon_creative_gas_allowed(creative_gas) ? LOWER_TEXT(GLOB.meta_gas_info[META_GAS_NAME][creative_gas]) : "nothing"

/obj/machinery/portable_atmospherics/canister/babylon_creative/process_atmos()
	if(babylon_port_wanted && !connected_port)
		babylon_reconnect_port()
	if(babylon_creative_machines_active() && !(machine_stat & BROKEN))
		creative_tick()
	. = ..()
	// While active, stay in the atmos machinery loop (a quiet canister normally drops out of
	// it), so the source keeps refilling and the void keeps draining what the port pushes in.
	// Inert, it leaves the loop like an ordinary canister.
	if(babylon_creative_machines_active() && !(machine_stat & BROKEN))
		return null

/// One atmos tick of the infinite behaviour.
/obj/machinery/portable_atmospherics/canister/babylon_creative/proc/creative_tick()
	if(creative_mode == "void")
		if(air_contents.total_moles() > 0)
			air_contents.remove(air_contents.total_moles())
		return
	if(!babylon_creative_gas_allowed(creative_gas))
		return
	var/missing = creative_pressure - air_contents.return_pressure()
	if(missing <= 0)
		return
	// Refill at room temperature at least: cold gas would need ever more moles (and an empty
	// mixture may have no meaningful temperature).
	if(air_contents.total_moles() <= 0 || air_contents.temperature < T20C)
		air_contents.temperature = T20C
		missing = creative_pressure - air_contents.return_pressure()
		if(missing <= 0)
			return
	air_contents.adjust_gas(creative_gas, missing * air_contents.volume / (R_IDEAL_GAS_EQUATION * air_contents.temperature))

/obj/machinery/portable_atmospherics/canister/babylon_creative/ui_act(action, list/params, datum/tgui/ui, datum/ui_state/state)
	// Relabelling would disguise it as an ordinary canister.
	if(action == "relabel")
		return FALSE
	return ..()

/obj/machinery/portable_atmospherics/canister/babylon_creative/click_ctrl_shift(mob/user)
	if(!babylon_creative_can_configure(src, user))
		return CLICK_ACTION_BLOCKING
	INVOKE_ASYNC(src, PROC_REF(creative_configure), user)
	return CLICK_ACTION_SUCCESS

/obj/machinery/portable_atmospherics/canister/babylon_creative/proc/creative_configure(mob/user)
	var/mode = babylon_creative_ask_mode(src, user, list(
		"Source - refills itself with a gas" = "source",
		"Void - destroys all gas that enters it" = "void",
	), creative_mode)
	if(!mode)
		return
	if(mode == "void")
		set_creative_settings(mode, creative_gas, creative_pressure)
		balloon_alert(user, "void")
		return
	var/list/gases = babylon_creative_gas_choices()
	var/gas_name = babylon_creative_prompt(user, "list", "Gas to produce", "Creative canister", gases, GLOB.meta_gas_info[META_GAS_NAME][creative_gas])
	if(!(gas_name in gases) || !babylon_creative_can_configure(src, user))
		return
	var/pressure = babylon_creative_prompt(user, "number", "Pressure to keep inside (kPa)", "Creative canister", null, creative_pressure, 9000, 100)
	if(!isnum(pressure) || !babylon_creative_can_configure(src, user))
		return
	set_creative_settings(mode, gases[gas_name], pressure)
	balloon_alert(user, "[creative_gas_name()] at [creative_pressure] kPa")

/obj/machinery/portable_atmospherics/canister/babylon_creative/proc/set_creative_settings(mode, gas_type, pressure)
	var/old_gas = creative_gas
	var/old_mode = creative_mode
	creative_mode = mode == "void" ? "void" : "source"
	if(babylon_creative_gas_allowed(gas_type))
		creative_gas = gas_type
	creative_pressure = clamp(round(pressure), 100, 9000)
	if(creative_mode == "source" && (creative_gas != old_gas || old_mode != "source") && babylon_creative_machines_active())
		// A new gas replaces the old one instead of mixing with it; a pressure change keeps it.
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

/obj/machinery/plumbing/babylon_creative_tank/add_context(atom/source, list/context, obj/item/held_item, mob/user)
	. = ..()
	if(babylon_creative_context(context))
		return CONTEXTUAL_SCREENTIP_SET

/obj/machinery/plumbing/babylon_creative_tank/proc/creative_reagent_name()
	var/datum/reagent/reagent = babylon_creative_reagent_allowed(creative_reagent) ? GLOB.chemical_reagents_list[creative_reagent] : null
	return reagent ? LOWER_TEXT(reagent.name) : "nothing"

/obj/machinery/plumbing/babylon_creative_tank/process(seconds_per_tick)
	if(!babylon_creative_machines_active() || (machine_stat & BROKEN))
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

/obj/machinery/plumbing/babylon_creative_tank/click_ctrl_shift(mob/user)
	if(!babylon_creative_can_configure(src, user))
		return CLICK_ACTION_BLOCKING
	INVOKE_ASYNC(src, PROC_REF(creative_configure), user)
	return CLICK_ACTION_SUCCESS

/obj/machinery/plumbing/babylon_creative_tank/proc/creative_configure(mob/user)
	var/mode = babylon_creative_ask_mode(src, user, list(
		"Source - keeps itself full of a reagent" = "source",
		"Void - destroys every reagent that enters it" = "void",
	), creative_mode)
	if(!mode)
		return
	var/reagent_type = creative_reagent
	if(mode == "source")
		var/list/choices = babylon_creative_reagent_choices()
		var/datum/reagent/current = GLOB.chemical_reagents_list[creative_reagent]
		var/reagent_name = babylon_creative_prompt(user, "list", "Reagent to produce", "Creative fluid tank", choices, current?.name)
		if(!(reagent_name in choices) || !babylon_creative_can_configure(src, user))
			return
		reagent_type = choices[reagent_name]
	set_creative_settings(mode, reagent_type)
	balloon_alert(user, creative_mode == "void" ? "void" : "[creative_reagent_name()] source")

/obj/machinery/plumbing/babylon_creative_tank/proc/set_creative_settings(mode, reagent_type)
	creative_mode = mode == "void" ? "void" : "source"
	if(babylon_creative_reagent_allowed(reagent_type))
		creative_reagent = reagent_type
	if(babylon_creative_machines_active())
		reagents.clear_reagents()
	name = creative_mode == "void" ? "creative fluid tank (void)" : "creative fluid tank ([creative_reagent_name()] source)"

// ---------------------------------------------------------------------------------------------
// Creative disposal unit: source drops its item into itself every creative_interval seconds and
// flushes it down the trunk below it (no pressure needed), pausing while creative_max_out of its
// items still exist so a forgotten source cannot fill the world (and its save); void deletes
// whatever arrives through the pipes or is put inside. Mobs are never deleted: they are put out
// on the floor instead.

/obj/machinery/disposal/bin/babylon_creative
	name = "creative disposal unit (source)"
	desc = "A creative-mode disposal unit. As a source it sends an item down its pipe every few seconds; as a void it destroys everything that reaches it."
	color = BABYLON_CREATIVE_TINT
	/// "source" or "void".
	var/creative_mode = "source"
	/// The item a source produces (an /obj/item path).
	var/creative_item = /obj/item/stack/sheet/iron
	/// Seconds between two items of a source (2-600).
	var/creative_interval = 10
	/// world.time at which a source sends its next item.
	var/creative_next = 0
	/// Weak references to the items this source made (pruned as they are deleted).
	var/list/datum/weakref/creative_outputs = list()
	/// A source pauses while this many of its items still exist.
	var/creative_max_out = 100

/obj/machinery/disposal/bin/babylon_creative/void
	name = "creative disposal unit (void)"
	creative_mode = "void"

/obj/machinery/disposal/bin/babylon_creative/Initialize(mapload, obj/structure/disposalconstruct/make_from)
	. = ..()
	update_creative_name()
	register_context()

/obj/machinery/disposal/bin/babylon_creative/examine(mob/user)
	. = ..()
	if(creative_mode == "void")
		babylon_creative_examine(., "Void: destroys everything that reaches it, except living beings.")
		return
	babylon_creative_examine(., "Source: sends [creative_item_name()] down its pipe every [creative_interval] seconds[trunk ? "" : " once it stands on a disposal pipe trunk"].")
	var/out = creative_items_out()
	if(babylon_creative_machines_active() && out >= creative_max_out)
		. += span_warning("Paused: [out] of its items still exist. It continues once fewer than [creative_max_out] are left.")

/obj/machinery/disposal/bin/babylon_creative/add_context(atom/source, list/context, obj/item/held_item, mob/user)
	. = ..()
	if(babylon_creative_context(context))
		return CONTEXTUAL_SCREENTIP_SET

/obj/machinery/disposal/bin/babylon_creative/proc/creative_item_name()
	var/obj/item/item_path = creative_item
	return babylon_creative_item_allowed(creative_item) ? initial(item_path.name) : "nothing"

/obj/machinery/disposal/bin/babylon_creative/proc/update_creative_name()
	name = creative_mode == "void" ? "creative disposal unit (void)" : "creative disposal unit ([creative_item_name()] every [creative_interval] s)"

/// How many of this source's items still exist (prunes the deleted ones).
/obj/machinery/disposal/bin/babylon_creative/proc/creative_items_out()
	for(var/datum/weakref/ref as anything in creative_outputs.Copy())
		var/obj/item/made = ref.resolve()
		if(QDELETED(made))
			creative_outputs -= ref
	return length(creative_outputs)

/obj/machinery/disposal/bin/babylon_creative/process(seconds_per_tick)
	if(!babylon_creative_machines_active() || (machine_stat & BROKEN))
		return ..()
	if(creative_mode == "void")
		creative_destroy(contents)
		return
	if(world.time < creative_next || flushing || !trunk || !babylon_creative_item_allowed(creative_item))
		return
	if(creative_items_out() >= creative_max_out)
		return
	creative_next = world.time + clamp(creative_interval, 2, 600) SECONDS
	if(creative_spawn())
		do_flush()

/// Makes one item inside the unit. Anything blocked (or a mob) that it brought inside itself,
/// such as a box of grenades, is deleted. Returns the item, or null if nothing is left.
/obj/machinery/disposal/bin/babylon_creative/proc/creative_spawn()
	var/obj/item/made = new creative_item(src)
	if(QDELETED(made))
		return null
	for(var/atom/movable/inner as anything in made.get_all_contents())
		if(inner == made || QDELETED(inner))
			continue
		if(ismob(inner) || (isitem(inner) && babylon_creative_inner_item_blocked(inner.type)))
			qdel(inner)
	creative_outputs += WEAKREF(made)
	return made

/// Arrivals through the pipe network.
/obj/machinery/disposal/bin/babylon_creative/expel(obj/structure/disposalholder/holder)
	if(!babylon_creative_machines_active() || creative_mode != "void")
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

/obj/machinery/disposal/bin/babylon_creative/click_ctrl_shift(mob/user)
	if(!babylon_creative_can_configure(src, user))
		return CLICK_ACTION_BLOCKING
	INVOKE_ASYNC(src, PROC_REF(creative_configure), user)
	return CLICK_ACTION_SUCCESS

/obj/machinery/disposal/bin/babylon_creative/proc/creative_configure(mob/user)
	var/mode = babylon_creative_ask_mode(src, user, list(
		"Source - sends an item down its pipe every few seconds" = "source",
		"Void - destroys everything that reaches it" = "void",
	), creative_mode)
	if(!mode)
		return
	var/item_type = creative_item
	var/interval = creative_interval
	if(mode == "source")
		var/search = babylon_creative_prompt(user, "text", "Item name or part of it (e.g. iron, crowbar)", "Creative disposal unit", null, creative_item_name())
		if(!istext(search) || !babylon_creative_can_configure(src, user))
			return
		var/list/matches = babylon_creative_item_matches(search)
		if(!length(matches))
			to_chat(user, span_warning("No item matches \"[search]\"."))
			return
		var/choice = length(matches) == 1 ? matches[1] : babylon_creative_prompt(user, "list", "Item to send", "Creative disposal unit", matches)
		if(!(choice in matches) || !babylon_creative_can_configure(src, user))
			return
		item_type = matches[choice]
		interval = babylon_creative_prompt(user, "number", "Seconds between items", "Creative disposal unit", null, creative_interval, 600, 2)
		if(!isnum(interval) || !babylon_creative_can_configure(src, user))
			return
	set_creative_settings(mode, item_type, interval)
	balloon_alert(user, creative_mode == "void" ? "void" : "[creative_item_name()] every [creative_interval] s")

/obj/machinery/disposal/bin/babylon_creative/proc/set_creative_settings(mode, item_type, interval)
	creative_mode = mode == "void" ? "void" : "source"
	if(babylon_creative_item_allowed(item_type))
		creative_item = item_type
	creative_interval = clamp(round(interval), 2, 600)
	creative_next = 0
	update_creative_name()

#undef BABYLON_CREATIVE_OFF_TEXT
#undef BABYLON_CREATIVE_TINT
#undef BABYLON_CREATIVE_GESTURE
#undef BABYLON_CREATIVE_MACHINE_FIELDS
