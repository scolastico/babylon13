// Tutorial gates (spec 12 #10, #20): triggers that never fire from players, only from other
// triggers, their "inputs". A gate is true or false; when it becomes true it fires like any
// trigger (its "On true" actions run, triggers "After" it start listening, gates fed by it see it
// fire), when it becomes false its "On false" actions run, and its "On change" actions run on
// every change.
//
// - Logic gate: AND, OR, XOR (exactly one), NOT (one input). A level input (zone, holding,
//   condition: is_level()) is LIVE: true while its condition holds, sampled every check whether or
//   not that trigger listens itself. An event input (start, button, say, used on, timer) is
//   LATCHED: true once it fired in this run. A gate input counts with its own current state.
// - Number gate: a number per run, starting at its start value. Each input has an operation that
//   runs every time that input fires (count up, set, add ... by a constant or by another number
//   gate's number); a level input "fires" each time its condition becomes true. The gate is true
//   while its condition holds (equals, at least ...). Its On change actions run whenever the
//   number changes.
//
// Gates update at once, in one evaluation wave: a trigger fires, the gates it feeds update, the
// gates THEY feed update, and so on. Every wave keeps the path of gates it is updating; a gate
// that is already on the path (a loop: A -> B -> A), a path longer than
// BABYLON_TUTORIAL_GATE_DEPTH gates or more than BABYLON_TUTORIAL_GATE_WAVE_UPDATES gate updates
// in one wave stops the wave there, and the run records which gate it was (the wand's Test run
// log and that gate's issues show it). find_issues() also warns about loops while building.
//
// A gate only updates while it listens ("Starts listening"): firings before that, also the one
// that makes it start listening, are not counted. A gate that starts listening is false until
// the next check, which evaluates it once: if it holds, it becomes true, runs On true and fires
// (like a zone that starts listening with a player already inside); if not, it runs On false.
// On change does not run for this first evaluation. A gate switched off by a Disable action
// turns false without running its own actions; the gates it feeds see it become false.

/// Most gates one evaluation wave goes through in a row.
#define BABYLON_TUTORIAL_GATE_DEPTH 16
/// Most gate updates one evaluation wave makes in all (fan-out, not depth).
#define BABYLON_TUTORIAL_GATE_WAVE_UPDATES 256
/// A number gate's number stays within +- this.
#define BABYLON_TUTORIAL_GATE_NUMBER_MAX 1000000

/obj/babylon_tutorial/trigger/gate
	ui_icon = "microchip"
	view_icon = 'icons/effects/mapping_helpers.dmi'
	view_state = "circuit"
	edge_triggered = FALSE

/obj/babylon_tutorial/trigger/gate/settings_schema()
	return own_schema() + list(
		babylon_tutorial_field("actions", "On true", "idlist", list(), "Run, in this order, when the gate becomes true (also when it starts listening while true). That counts as the gate firing: triggers \"After\" it start listening and gates fed by it see it fire.", filter = list("action")),
		babylon_tutorial_field("actions_false", "On false", "idlist", list(), "Run when the gate becomes false, and once when it starts listening while false.", filter = list("action")),
		babylon_tutorial_field("actions_change", "On change", "idlist", list(), change_help(), filter = list("action")),
		babylon_tutorial_field("once", "Fire only once", "bool", 0, "On: once the gate became true it stops listening (nothing about it changes any more)."),
	) + babylon_tutorial_listen_fields() + list(
		babylon_tutorial_field("delay", "Delay (seconds)", "number", 0, "Wait this long before the first action of a list runs.", min = 0, max = 600),
	)

/obj/babylon_tutorial/trigger/gate/action_keys()
	return list("actions", "actions_false", "actions_change")

/obj/babylon_tutorial/trigger/gate/proc/change_help()
	return "Run whenever the gate turns true or false (not when it starts listening)."

/// Never fires from the check loop: only its inputs update it (the run's notify_gates()).
/obj/babylon_tutorial/trigger/gate/check(datum/babylon_tutorial_run/run)
	return FALSE

/obj/babylon_tutorial/trigger/gate/is_level()
	return FALSE

/// The ids of the triggers that feed this gate.
/obj/babylon_tutorial/trigger/gate/proc/input_ids()
	return list()

/// The state the gate has in a run now, worked out from its inputs (logic) or number.
/obj/babylon_tutorial/trigger/gate/proc/compute(datum/babylon_tutorial_run/run)
	return FALSE

/// An input fired (fired = TRUE) or a gate input became false (fired = FALSE): update.
/obj/babylon_tutorial/trigger/gate/proc/input_changed(datum/babylon_tutorial_run/run, obj/babylon_tutorial/trigger/input, fired)
	return

/obj/babylon_tutorial/trigger/gate/find_issues()
	var/list/found = ..()
	for(var/id in input_ids())
		if(id == tutorial_id)
			found["inputs"] = "A gate can't be its own input."
			break
	if(!found["inputs"])
		var/list/loop = babylon_tutorial_gate_loop(src)
		if(loop)
			found["inputs"] = "Gates feed each other in a loop: [jointext(loop, " -> ")]. A test run stops the loop at [tutorial_id]."
	var/datum/babylon_tutorial_run/run = babylon_tutorial_current_run()
	var/stopped = run?.gate_stops[src]
	if(stopped)
		found["live"] = "Test run: [stopped]"
	return found

/obj/babylon_tutorial/trigger/gate/summary()
	return "from [length(input_ids()) ? jointext(input_ids(), ", ") : "no inputs"], " + ..()

/obj/babylon_tutorial/trigger/gate/actions_summary()
	var/list/labels = list("actions" = "on true", "actions_false" = "on false", "actions_change" = "on change")
	var/list/parts = list()
	for(var/key in labels)
		var/list/listed = setting(key)
		if(length(listed))
			parts += "[labels[key]] [jointext(listed, ", ")]"
	return length(parts) ? "runs [jointext(parts, "; ")]" : "runs nothing yet"

/// Every gate's state in a run, for the wand's Test run tab.
/proc/babylon_tutorial_gates_live(datum/babylon_tutorial_run/run)
	var/list/gates = list()
	for(var/obj/babylon_tutorial/trigger/gate/gate in GLOB.babylon_tutorial_objects)
		gates += list(list(
			"id" = gate.tutorial_id,
			"kind" = gate.tutorial_kind,
			"state" = !!run.gate_states[gate],
			"value" = istype(gate, /obj/babylon_tutorial/trigger/gate/number) ? run.gate_number(gate) : null,
			"listening" = run.is_enabled(gate),
			"stopped" = !!run.gate_stops[gate],
		))
	return gates

/// How a trigger counts as a gate input, for the configure window: "gate", "live" or "latched".
/proc/babylon_tutorial_input_mode(obj/babylon_tutorial/trigger/trigger)
	if(istype(trigger, /obj/babylon_tutorial/trigger/gate))
		return "gate"
	return trigger.is_level() ? "live" : "latched"

/// Input id => the gates that list it as an input, in placing order. Built once per tutorial
/// version. The lists are never changed after they are built: callers may iterate them while a
/// wave changes the tutorial.
/proc/babylon_tutorial_gate_index()
	var/static/list/index
	var/static/index_version = -1
	if(index && index_version == GLOB.babylon_tutorial_version)
		return index
	index = list()
	for(var/obj/babylon_tutorial/trigger/gate/gate in GLOB.babylon_tutorial_objects)
		for(var/id in gate.input_ids())
			var/list/gates = index[id]
			if(!gates)
				gates = list()
				index[id] = gates
			gates += gate
	index_version = GLOB.babylon_tutorial_version
	return index

/// The gates fed by a trigger (gates that list it as an input), in placing order. Do not change
/// the returned list.
/proc/babylon_tutorial_gates_fed_by(obj/babylon_tutorial/trigger/trigger)
	var/list/gates = babylon_tutorial_gate_index()[trigger.tutorial_id]
	return gates || list()

/// A loop of gates through this one, in the order signals flow (["a", "b", "a"]), else null.
/proc/babylon_tutorial_gate_loop(obj/babylon_tutorial/trigger/gate/start)
	var/list/path = list(start)
	var/list/seen = list()
	return babylon_tutorial_gate_loop_from(start, start, path, seen)

/proc/babylon_tutorial_gate_loop_from(obj/babylon_tutorial/trigger/gate/start, obj/babylon_tutorial/trigger/current, list/path, list/seen)
	for(var/obj/babylon_tutorial/trigger/gate/next as anything in babylon_tutorial_gates_fed_by(current))
		if(next == start)
			var/list/ids = babylon_tutorial_ids_of(path)
			ids += start.tutorial_id
			return ids
		if(seen[next])
			continue
		seen[next] = TRUE
		path += next
		var/list/found = babylon_tutorial_gate_loop_from(start, next, path, seen)
		if(found)
			return found
		path.len--
	return null

// ---------------------------------------------------------------------------------------------
// The run's side: state per gate and the evaluation wave

/// Whether a trigger counts as true for a logic gate: a gate by its state, a level trigger by its
/// live condition, an event trigger once it fired in this run.
/datum/babylon_tutorial_run/proc/input_state(obj/babylon_tutorial/trigger/input)
	if(istype(input, /obj/babylon_tutorial/trigger/gate))
		return !!gate_states[input]
	if(input.is_level())
		if(isnull(level_states[input]))
			level_states[input] = !!input.check(src)
		return level_states[input]
	return fired[input] > 0

/// A number gate's number in this run.
/datum/babylon_tutorial_run/proc/gate_number(obj/babylon_tutorial/trigger/gate/number/gate)
	if(!istype(gate))
		return 0
	return isnull(gate_values[gate]) ? gate.setting("start") : gate_values[gate]

/// Samples every level trigger that feeds a listening gate; a change is passed to its gates
/// (becoming true counts as a firing for number gates). Level triggers no listening gate uses
/// are forgotten, so they are measured afresh when one starts listening.
/datum/babylon_tutorial_run/proc/sample_levels()
	if(preview)
		return
	var/list/index = babylon_tutorial_gate_index()
	for(var/id in index)
		if(completed)
			return
		var/obj/babylon_tutorial/trigger/input = babylon_tutorial_find(id)
		if(!istype(input) || !input.is_level())
			continue
		var/used = FALSE
		for(var/obj/babylon_tutorial/trigger/gate/gate as anything in index[id])
			if(is_enabled(gate))
				used = TRUE
				break
		if(!used)
			level_states -= input
			continue
		var/state = !!input.check(src)
		var/was = level_states[input]
		level_states[input] = state
		if(!isnull(was) && was != state)
			notify_gates(input, state)

/// Gates that started listening since the last check are evaluated once, each as its own wave:
/// one that holds becomes true (On true, it fires, the gates it feeds see it), one that does not
/// runs On false. On change does not run for this first evaluation. They settle in dependency
/// order (a pending gate's pending input gates first), so a gate never reads an input gate that
/// is about to settle; gates in a loop fall back to placing order.
/datum/babylon_tutorial_run/proc/settle_pending_gates()
	if(preview || !length(gate_pending))
		return
	var/list/pending = gate_pending
	gate_pending = list()
	for(var/obj/babylon_tutorial/trigger/gate/gate as anything in babylon_tutorial_gate_settle_order(pending))
		if(completed)
			return
		if(QDELETED(gate) || !is_enabled(gate))
			continue
		start_gate_wave()
		gate_wave += gate
		gate_wave_updates++
		var/state = !!gate.compute(src)
		gate_states[gate] = state
		if(state)
			mark_fired(gate)
			run_actions(gate, gate.setting("actions"))
			notify_gates(gate, TRUE)
		else
			run_actions(gate, gate.setting("actions_false"))
		gate_wave.Cut()

/// The pending gates (gate => TRUE) in settle order: placing order, but every pending gate a
/// gate takes as an input comes before it (depth first). A gate already being visited (a loop)
/// is not waited for.
/proc/babylon_tutorial_gate_settle_order(list/pending)
	var/list/order = list()
	var/list/visiting = list()
	for(var/obj/babylon_tutorial/trigger/gate/gate in GLOB.babylon_tutorial_objects)
		if(pending[gate])
			babylon_tutorial_gate_settle_visit(gate, pending, order, visiting)
	return order

/proc/babylon_tutorial_gate_settle_visit(obj/babylon_tutorial/trigger/gate/gate, list/pending, list/order, list/visiting)
	if((gate in order) || visiting[gate])
		return
	visiting[gate] = TRUE
	for(var/id in gate.input_ids())
		var/obj/babylon_tutorial/trigger/gate/input = babylon_tutorial_find(id)
		if(istype(input) && pending[input])
			babylon_tutorial_gate_settle_visit(input, pending, order, visiting)
	visiting -= gate
	order += gate

/// A gate started listening: it is false until the next check evaluates it.
/datum/babylon_tutorial_run/proc/gate_started(obj/babylon_tutorial/trigger/gate/gate)
	gate_states -= gate
	gate_pending[gate] = TRUE

/// A gate was switched off: it turns false without its own actions; the gates it feeds see it.
/datum/babylon_tutorial_run/proc/gate_stopped(obj/babylon_tutorial/trigger/gate/gate)
	gate_pending -= gate
	if(!gate_states[gate])
		return
	gate_states[gate] = FALSE
	notify_gates(gate, FALSE)

/// A new wave starts: its update budget is full again.
/datum/babylon_tutorial_run/proc/start_gate_wave()
	gate_wave_updates = 0
	gate_wave_stopped = FALSE

/// A trigger fired (fired = TRUE) or a gate or level input became false (fired = FALSE): every
/// listening gate it feeds updates, as one step of the evaluation wave.
/datum/babylon_tutorial_run/proc/notify_gates(obj/babylon_tutorial/trigger/source, fired)
	if(preview)
		return
	if(!length(gate_wave))
		start_gate_wave()
	for(var/obj/babylon_tutorial/trigger/gate/gate as anything in babylon_tutorial_gates_fed_by(source))
		if(completed || gate_wave_stopped)
			return
		// Not listening, or just started (it is evaluated at the next check, so the firing that
		// made it listen is not counted).
		if(!is_enabled(gate) || gate_pending[gate])
			continue
		if(gate in gate_wave)
			stop_gate_wave(gate, "loop stopped at [gate.tutorial_id]: [jointext(babylon_tutorial_ids_of(gate_wave), " -> ")] -> [gate.tutorial_id] (it was already updating in this wave).")
			continue
		if(length(gate_wave) >= BABYLON_TUTORIAL_GATE_DEPTH)
			stop_gate_wave(gate, "chain stopped at [gate.tutorial_id]: more than [BABYLON_TUTORIAL_GATE_DEPTH] gates in a row ([jointext(babylon_tutorial_ids_of(gate_wave), " -> ")] -> [gate.tutorial_id]).")
			continue
		if(gate_wave_updates >= BABYLON_TUTORIAL_GATE_WAVE_UPDATES)
			stop_gate_wave(gate, "wave stopped at [gate.tutorial_id]: more than [BABYLON_TUTORIAL_GATE_WAVE_UPDATES] gate updates from one firing (gates fan out into each other too much; reached through [jointext(babylon_tutorial_ids_of(gate_wave), " -> ")] -> [gate.tutorial_id]).")
			gate_wave_stopped = TRUE
			return
		gate_wave_updates++
		gate_wave += gate
		gate.input_changed(src, source, fired)
		gate_wave.len--

/// A wave stopped at a gate: the run notes it for the wand and the log.
/datum/babylon_tutorial_run/proc/stop_gate_wave(obj/babylon_tutorial/trigger/gate/gate, text)
	var/known = gate_stops[gate] == text
	gate_stops[gate] = text
	gate_log += text
	if(length(gate_log) > 20)
		gate_log.Cut(1, 2)
	log_game("BABYLON TUTORIAL: gate [text]")
	if(!known)
		// The gate's issues and the overview checks show it.
		babylon_tutorial_changed()

/// A gate's new state (and for a number gate whether its number changed): On true / On false,
/// then On change, then the gates it feeds update.
/datum/babylon_tutorial_run/proc/set_gate_state(obj/babylon_tutorial/trigger/gate/gate, state, number_changed = FALSE)
	state = !!state
	var/was = !!gate_states[gate]
	gate_states[gate] = state
	var/became = state != was
	if(became && state)
		mark_fired(gate)
		run_actions(gate, gate.setting("actions"))
	else if(became)
		run_actions(gate, gate.setting("actions_false"))
	if(became || number_changed)
		run_actions(gate, gate.setting("actions_change"))
	if(became)
		notify_gates(gate, state)

// ---------------------------------------------------------------------------------------------
// Logic gate

/obj/babylon_tutorial/trigger/gate/logic
	tutorial_kind = "logic_gate"
	kind_name = "Logic gate"
	kind_desc = "Fires from other triggers, never from players: true when its inputs are (AND, OR, XOR, NOT). Runs actions when it becomes true, false, or either."
	kind_example = "e.g. both valves opened (AND), or the alarm was NOT pressed."

/obj/babylon_tutorial/trigger/gate/logic/own_schema()
	return list(
		babylon_tutorial_field("mode", "Logic", "choice", "and", "Zone, holding and condition inputs are live: true while their condition holds. Button, say, used on, timer and start inputs are latched: true once they fired in this run. A gate input is true while that gate is. XOR: exactly one input is true. NOT: true while its one input is not.", options = babylon_tutorial_options(list("and" = "AND: all inputs", "or" = "OR: any input", "xor" = "XOR: exactly one input", "not" = "NOT: its input is not true"))),
		babylon_tutorial_field("inputs", "Inputs", "idlist", list(), "The triggers and gates this gate listens to (each marked live or latched).", filter = list("trigger"), required = TRUE, input_modes = TRUE),
	)

/obj/babylon_tutorial/trigger/gate/logic/input_ids()
	var/list/ids = setting("inputs")
	return islist(ids) ? ids : list()

/obj/babylon_tutorial/trigger/gate/logic/compute(datum/babylon_tutorial_run/run)
	var/list/inputs = list()
	for(var/id in input_ids())
		var/obj/babylon_tutorial/trigger/input = babylon_tutorial_find(id)
		if(istype(input) && input != src)
			inputs += input
	if(!length(inputs))
		return FALSE
	var/count = 0
	for(var/obj/babylon_tutorial/trigger/input as anything in inputs)
		if(run.input_state(input))
			count++
	switch(setting("mode"))
		if("and")
			return count == length(inputs)
		if("or")
			return count > 0
		if("xor")
			return count == 1
		if("not")
			return length(inputs) == 1 && !count
	return FALSE

/obj/babylon_tutorial/trigger/gate/logic/input_changed(datum/babylon_tutorial_run/run, obj/babylon_tutorial/trigger/input, fired)
	run.set_gate_state(src, compute(run))

/obj/babylon_tutorial/trigger/gate/logic/find_issues()
	var/list/found = ..()
	if(!found["inputs"] && setting("mode") == "not" && length(input_ids()) != 1)
		found["inputs"] = "NOT needs exactly one input (it has [length(input_ids())])."
	return found

/obj/babylon_tutorial/trigger/gate/logic/summary()
	return "[uppertext(setting("mode"))] " + ..()

// ---------------------------------------------------------------------------------------------
// Number gate

/obj/babylon_tutorial/trigger/gate/number
	tutorial_kind = "number_gate"
	kind_name = "Number gate"
	kind_desc = "A number for the tutorial: its inputs count it up, down or change it; it is true while a condition on the number holds. Runs actions when it becomes true, false, or the number changes."
	kind_example = "e.g. 3 of 5 valves opened: each valve counts up, true at 3 or more."
	ui_icon = "calculator"
	view_state = "element"

/obj/babylon_tutorial/trigger/gate/number/own_schema()
	return list(
		babylon_tutorial_field("start", "Start value", "number", 0, "The number when the tutorial starts (and after a reset).", min = -100000, max = 100000),
		babylon_tutorial_field("inputs", "Inputs", "gateinputs", list(), "Each time an input fires, its operation changes the number: a zone, holding or condition input each time its condition becomes true, a gate input when it becomes true. Firings before this gate starts listening (also the one that starts it) are not counted. \"By\" another number gate uses that gate's number at that moment.", options = babylon_tutorial_options(babylon_tutorial_gate_operations()), filter = list("trigger"), required = TRUE, input_modes = TRUE),
		babylon_tutorial_field("condition", "True while", "choice", "at_least", null, options = babylon_tutorial_options(list("equals" = "The number equals", "at_least" = "The number is at least", "at_most" = "The number is at most", "between" = "The number is between"))),
		babylon_tutorial_field("amount", "Value", "number", 1, "The number to compare with (between: the lowest).", min = -100000, max = 100000),
		babylon_tutorial_field("amount_max", "And", "number", 10, "The highest number (between).", min = -100000, max = 100000, when = list("condition" = list("between"))),
	)

/obj/babylon_tutorial/trigger/gate/number/change_help()
	return "Run whenever the number changes (also while the condition stays as it is; not when the gate starts listening)."

/// Operation key => label, for a number gate input.
/proc/babylon_tutorial_gate_operations()
	return list(
		"up" = "Count up (+1)",
		"down" = "Count down (-1)",
		"set" = "Set to",
		"add" = "Add",
		"sub" = "Subtract",
		"mul" = "Multiply by",
		"reset" = "Reset to the start value",
	)

/// Operations that use a value (a constant, or another number gate's number).
/proc/babylon_tutorial_gate_operation_takes_value(op)
	return op in list("set", "add", "sub", "mul")

/// Cleans a number gate's inputs: list(list("id", "op", "amount", "source")), at most
/// BABYLON_TUTORIAL_IDLIST_MAX entries. Missing parts get defaults (count up, 1, a constant).
/proc/babylon_tutorial_clean_gate_inputs(list/field, value)
	if(isnull(value))
		return list("value" = list())
	if(!islist(value))
		return list("error" = "Inputs are a list.")
	var/list/value_list = value
	if(length(value_list) > BABYLON_TUTORIAL_IDLIST_MAX)
		return list("error" = "At most [BABYLON_TUTORIAL_IDLIST_MAX] inputs.")
	var/list/operations = babylon_tutorial_gate_operations()
	var/list/cleaned = list()
	for(var/list/entry in value_list)
		var/id = trim("[entry["id"] || ""]")
		if(length(id) && !babylon_tutorial_valid_id(id))
			return list("error" = "\"[id]\" is not a valid id.")
		var/op = "[entry["op"] || "up"]"
		if(!operations[op])
			return list("error" = "Choose one of the offered operations.")
		var/amount = isnum(entry["amount"]) ? entry["amount"] : text2num("[entry["amount"]]")
		amount = round(clamp(isnull(amount) ? 1 : amount, -100000, 100000), 0.1)
		var/source = trim("[entry["source"] || ""]")
		if(length(source) && !babylon_tutorial_valid_id(source))
			return list("error" = "\"[source]\" is not a valid id.")
		if(!babylon_tutorial_gate_operation_takes_value(op))
			source = ""
		cleaned += list(list("id" = id, "op" = op, "amount" = amount, "source" = source))
	return list("value" = cleaned)

/obj/babylon_tutorial/trigger/gate/number/proc/inputs()
	var/list/entries = setting("inputs")
	return islist(entries) ? entries : list()

/obj/babylon_tutorial/trigger/gate/number/input_ids()
	var/list/ids = list()
	for(var/list/entry in inputs())
		if(length(entry["id"]))
			ids |= entry["id"]
	return ids

/obj/babylon_tutorial/trigger/gate/number/compute(datum/babylon_tutorial_run/run)
	return holds(run.gate_number(src))

/// Whether the condition holds for a number.
/obj/babylon_tutorial/trigger/gate/number/proc/holds(number)
	var/amount = setting("amount")
	// Numbers are floats: equal within a small margin (0.1 steps, multiplications).
	switch(setting("condition"))
		if("equals")
			return abs(number - amount) < 0.0005
		if("at_least")
			return number >= amount - 0.0005
		if("at_most")
			return number <= amount + 0.0005
		if("between")
			var/high = setting("amount_max")
			return number >= min(amount, high) - 0.0005 && number <= max(amount, high) + 0.0005
	return FALSE

/// The number after one input's operation.
/obj/babylon_tutorial/trigger/gate/number/proc/apply(datum/babylon_tutorial_run/run, list/entry, number)
	var/operand = entry["amount"]
	if(length(entry["source"]))
		operand = run.gate_number(babylon_tutorial_find(entry["source"]))
	switch(entry["op"])
		if("up")
			number += 1
		if("down")
			number -= 1
		if("set")
			number = operand
		if("add")
			number += operand
		if("sub")
			number -= operand
		if("mul")
			number *= operand
		if("reset")
			number = setting("start")
	return clamp(round(number, 0.001), -BABYLON_TUTORIAL_GATE_NUMBER_MAX, BABYLON_TUTORIAL_GATE_NUMBER_MAX)

/// Only firings count: a gate input becoming false does not change the number.
/obj/babylon_tutorial/trigger/gate/number/input_changed(datum/babylon_tutorial_run/run, obj/babylon_tutorial/trigger/input, fired)
	if(!fired)
		return
	var/old_number = run.gate_number(src)
	var/number = old_number
	for(var/list/entry in inputs())
		if(entry["id"] == input.tutorial_id)
			number = apply(run, entry, number)
	run.gate_values[src] = number
	run.set_gate_state(src, holds(number), number != old_number)

/obj/babylon_tutorial/trigger/gate/number/find_issues()
	var/list/found = ..()
	for(var/list/entry in inputs())
		if(found["inputs"])
			break
		if(!length(entry["id"]))
			found["inputs"] = "Every input needs a trigger or gate."
			continue
		var/source = entry["source"]
		if(length(source) && !istype(babylon_tutorial_find(source), /obj/babylon_tutorial/trigger/gate/number))
			found["inputs"] = "\"By\" [source] must be a number gate."
	return found

/obj/babylon_tutorial/trigger/gate/number/summary()
	var/list/labels = list("equals" = "=", "at_least" = ">=", "at_most" = "<=")
	var/condition = setting("condition")
	var/test = condition == "between" ? "[setting("amount")]..[setting("amount_max")]" : "[labels[condition]] [setting("amount")]"
	return "starts at [setting("start")], true at [test], " + ..()

#undef BABYLON_TUTORIAL_GATE_NUMBER_MAX
#undef BABYLON_TUTORIAL_GATE_WAVE_UPDATES
