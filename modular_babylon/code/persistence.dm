// Apply saved physical configuration BEFORE Initialize creates cable/pipe nodes.
// Version 1 maps omitted these assignments due to an unparenthesized `in`.
/datum/babylon_save/proc/preload_atom(atom/thing)
	if(!resume_data)
		load_resume_data()
	var/list/record = resume_records[thing.babylon_save_id]
	if(!record)
		return
	var/list/fields = record["fields"]
	for(var/field in structural_fields)
		if((field in fields) && (field in thing.vars))
			thing.vars[field] = decode_value(fields[field])
	if((resume_data["version"] || 1) < 2)
		if(istype(thing, /obj/machinery/atmospherics/components/trinary))
			thing.vars["flipped"] = findtext(fields["icon_state"], "_f") > 0
		if(istype(thing, /obj/machinery/atmospherics/pipe/smart))
			// Smart-pipe dir describes existing neighbours, not allowed ports.
			// Version 1 omitted the port mask; use the RPD/dispenser default.
			// Inferring it from dir prevents adding branches after recovery.
			thing.vars["initialize_directions"] = ALL_CARDINALS

/// Reads data/babylon/resume-state.json (staged by the supervisor) once: resume_data, and
/// resume_records by save id. Returns the state, or null for a fresh world.
/datum/babylon_save/proc/load_resume_data()
	if(resume_data || !fexists("data/babylon/resume-state.json"))
		return resume_data
	resume_data = json_decode(file2text("data/babylon/resume-state.json"))
	for(var/list/record as anything in resume_data["records"])
		resume_records[record["id"]] = record
	return resume_data

/datum/babylon_save/proc/encode_gas(datum/gas_mixture/gas)
	if(!gas)
		return null
	var/list/moles = list()
	for(var/gas_type, amount in gas.moles)
		moles["[gas_type]"] = amount
	return list("temperature" = gas.temperature, "volume" = gas.volume, "moles" = moles)

/datum/babylon_save/proc/restore_gas(datum/gas_mixture/gas, data)
	if(!gas || !data)
		return
	if(istext(data))
		gas.copy_from(SSair.parse_gas_string(data))
	else
		var/list/saved = data
		gas.moles.Cut()
		var/list/moles = saved["moles"]
		for(var/gas_type in moles)
			gas.moles[text2path(gas_type)] = moles[gas_type]
		gas.temperature = saved["temperature"]
		gas.volume = saved["volume"]
	gas.archive()

/datum/babylon_save/proc/material_container(atom/thing)
	if(!("materials" in thing.vars))
		return null
	var/datum/value = thing.vars["materials"]
	if(istype(value, /datum/remote_materials))
		var/datum/remote_materials/remote = value
		return remote.mat_container
	if(istype(value, /datum/material_container))
		return value
	return null

// A rebuilt lathe normally waits for roundstart to create local storage.
// Restore it now, before the simulation resumes, and keep its silo link.
/datum/remote_materials/proc/babylon_restore_container(obj/machinery/ore_silo/saved_silo)
	if(connection)
		LAZYREMOVE(SSticker.round_start_events, connection)
		connection = null
	if(saved_silo)
		saved_silo.connect_receptacle(src, parent)
	else if(!mat_container && allow_standalone)
		_MakeLocal()
	return mat_container

// An invalid material key must not abort UI generation or stock accounting.
// Valid material identities and amounts are left untouched.
/datum/material_container/proc/babylon_prune_invalid_materials()
	if(!islist(materials))
		return
	for(var/material in materials.Copy())
		if(!istype(material, /datum/material))
			materials.Remove(material)

/datum/babylon_save/proc/assign_id(atom/thing)
	if(!thing.babylon_save_id)
		thing.babylon_save_id = "bb[next_id++]"
	return thing.babylon_save_id

/// Text as a save writes it: without BYOND's \proper/\improper markers. They are stored as
/// bytes that are not UTF-8, and the file writer dropped them, so a save whose text held one
/// came out shorter on disk than written (names of objects made during play carry them).
/proc/babylon_save_text(text)
	if(!istext(text))
		return text
	return replacetext(replacetext(replacetext(replacetext(text, "\proper ", ""), "\improper ", ""), "\proper", ""), "\improper", "")

/// TRUE if a save leaves this text field out because it holds the type's own value: the type
/// default comes back on load, with its \proper/\improper marker. Written stripped, such a text
/// would make name != initial(name) for every saved object of the type (atmos naming, fire
/// alarms, cameras and article handling check that), and lose the marker's grammar.
/// `name` is always left out when unchanged; other text fields when their default carries a marker.
/proc/babylon_save_keeps_default_text(atom/thing, field, value)
	if(!istext(value))
		return FALSE
	var/default = initial(thing.vars[field])
	if(value != default)
		return FALSE
	return field == "name" || babylon_save_text(default) != default

/// A plane without its multi-z offset (PLANE_TO_TRUE). Saves and copies store this: a level loads
/// at a z whose offset Initialize applies again (turfs, SET_PLANE_IMPLICIT), so an offset plane
/// would be offset twice, and a level restored at another z needs that z's offset anyway.
/proc/babylon_true_plane(plane)
	if(!isnum(plane))
		return plane
	var/true_plane = PLANE_TO_TRUE(plane)
	return isnum(true_plane) ? true_plane : plane

/datum/babylon_save/proc/encode_value(value)
	if(istext(value))
		return babylon_save_text(value)
	if(isnull(value) || isnum(value))
		return value
	if(ispath(value))
		return list("path" = "[value]")
	if(isatom(value))
		var/atom/thing = value
		return list("atom" = assign_id(thing))
	if(islist(value))
		var/list/result = list()
		var/list/values = value
		for(var/index in 1 to length(values))
			var/key = values[index]
			result += list(list("key" = encode_value(key), "value" = (!isnum(key) && !isnull(key)) ? encode_value(values[key]) : null))
		return list("entries" = result)
	return null

/datum/babylon_save/proc/decode_value(value)
	if(!islist(value))
		return value
	var/list/encoded = value
	if("path" in encoded)
		return text2path(encoded["path"])
	if("atom" in encoded)
		return restored_atoms[encoded["atom"]]
	if("sequence" in encoded)
		var/list/result = list()
		for(var/entry in encoded["sequence"])
			result += list(decode_value(entry))
		return result
	if("entries" in encoded)
		var/list/result = list()
		for(var/list/entry as anything in encoded["entries"])
			var/key = decode_value(entry["key"])
			result += list(key)
			if(!isnull(entry["value"]) && !isnum(key) && !isnull(key))
				result[key] = decode_value(entry["value"])
		return result
	return null

/datum/babylon_save/proc/capture(atom/thing, list/records, parent_id)
	var/save_id = assign_id(thing)
	var/list/record = list("id" = save_id, "type" = "[thing.type]", "parent" = parent_id, "x" = thing.x, "y" = thing.y, "fields" = list(), "references" = list())
	var/list/fields = record["fields"]
	var/list/capture_fields = capture_fields_by_type[thing.type]
	if(isnull(capture_fields))
		capture_fields = list()
		for(var/field in state_fields | extra_fields | structural_fields | type_fields(thing))
			if(field in thing.vars)
				capture_fields += field
		capture_fields_by_type[thing.type] = capture_fields
	for(var/field in capture_fields)
		var/value = thing.vars[field]
		if(field == "plane")
			value = babylon_true_plane(value)
		if(babylon_save_keeps_default_text(thing, field, value))
			continue
		if(isdatum(value) && (field in object_type_fields_of(thing)))
			var/datum/held = value
			value = held.type
		if(isnull(value) || isnum(value) || istext(value) || ispath(value) || (field in list_fields))
			fields[field] = encode_value(value)
	if(istype(thing, /obj/machinery/portable_atmospherics))
		var/obj/machinery/portable_atmospherics/portable = thing
		// An explicit null distinguishes an intentionally detached device from
		// older checkpoints which never recorded this relationship.
		record["portable_port"] = encode_value(portable.connected_port)
	if(istype(thing, /obj/machinery/airalarm))
		var/obj/machinery/airalarm/alarm = thing
		var/list/thresholds = list()
		for(var/key in alarm.tlv_collection)
			var/datum/tlv/threshold = alarm.tlv_collection[key]
			thresholds += list(list("key" = encode_value(key), "type" = "[threshold.type]", "warning_min" = threshold.warning_min, "warning_max" = threshold.warning_max, "hazard_min" = threshold.hazard_min, "hazard_max" = threshold.hazard_max))
		record["alarm_thresholds"] = thresholds
		record["alarm_mode"] = alarm.selected_mode ? "[alarm.selected_mode.type]" : null
	if(istype(thing, /obj/machinery/atmospherics/components/unary/airlock_pump))
		var/obj/machinery/atmospherics/components/unary/airlock_pump/pump = thing
		var/list/settings = list()
		for(var/field in list("can_unwrench", "internal_pressure_target", "external_pressure_target", "cycle_pressure_target", "allowed_pressure_error", "min_distro_pressure", "docked_side_pressure", "volume_rate", "cycle_timeout", "airlock_pump_distance_limit", "airlock_group_distance_limit", "valid_airlock_typepath", "cycling_set_up", "open_airlock_on_cycle", "is_cycling_audible"))
			settings[field] = encode_value(pump.vars[field])
		record["cycle_settings"] = settings
		record["cycle_internal"] = encode_value(pump.internal_airlocks)
		record["cycle_external"] = encode_value(pump.external_airlocks)
		record["cycle_remaining"] = pump.on ? max(1, timeleft(pump.emergency_stop_timer)) : 0
	if(thing.wires)
		record["wires"] = list("colors" = thing.wires.colors.Copy(), "cut_wires" = thing.wires.cut_wires?.Copy())
	if(istype(thing, /obj/machinery/atmospherics/components/unary/vent_pump))
		var/obj/machinery/atmospherics/components/unary/vent_pump/vent = thing
		record["assigned_area"] = vent.assigned_area ? "[vent.assigned_area.type]" : null
	if(istype(thing, /obj/machinery/atmospherics/components/unary/vent_scrubber))
		var/obj/machinery/atmospherics/components/unary/vent_scrubber/scrubber = thing
		record["assigned_area"] = scrubber.assigned_area ? "[scrubber.assigned_area.type]" : null
	if(istype(thing, /obj/machinery/power/solar_control))
		var/obj/machinery/power/solar_control/control = thing
		record["solar_panels"] = encode_value(control.connected_panels)
		record["solar_tracker"] = encode_value(control.connected_tracker)
	if(istype(thing, /obj/machinery/power/apc))
		var/obj/machinery/power/apc/apc = thing
		record["has_terminal"] = !isnull(apc.terminal)
	thing.babylon_capture_settings(fields)
	var/list/references = record["references"]
	// Looking a name up in vars scans every var: the present fields are cached per type.
	var/list/present_references = reference_fields_by_type[thing.type]
	if(isnull(present_references))
		present_references = list()
		for(var/field in reference_fields)
			if(field in thing.vars)
				present_references += field
		reference_fields_by_type[thing.type] = present_references
	for(var/field in present_references)
		references[field] = encode_value(thing.vars[field])
	if(istype(thing, /obj/structure/frame/machine))
		capture_machine_frame(thing, record)
	if(istype(thing, /obj/machinery/power/smes))
		var/obj/machinery/power/smes/smes = thing
		references["terminal"] = encode_value(smes.terminal)
	if(istype(thing, /obj/machinery/power/terminal))
		var/obj/machinery/power/terminal/terminal = thing
		references["master"] = encode_value(terminal.master)
	if(thing.reagents)
		var/list/chems = list()
		for(var/datum/reagent/chem as anything in thing.reagents.reagent_list)
			chems += list(list("type" = "[chem.type]", "volume" = chem.volume, "purity" = chem.purity))
		record["reagents"] = chems
	var/list/present_gases = gas_fields_by_type[thing.type]
	if(isnull(present_gases))
		present_gases = list()
		for(var/field in list("air_contents", "air1", "air2", "air3", "absorbed_gasmix"))
			if(field in thing.vars)
				present_gases += field
		gas_fields_by_type[thing.type] = present_gases
	for(var/field in present_gases)
		var/datum/gas_mixture/mix = thing.vars[field]
		if(istype(mix))
			record[field] = encode_gas(mix)
	if(istype(thing, /obj/machinery/atmospherics/pipe))
		var/obj/machinery/atmospherics/pipe/pipe = thing
		if(pipe.parent?.air)
			record["pipeline_gas"] = encode_gas(pipe.parent.air)
	if(istype(thing, /obj/machinery/atmospherics/components))
		var/obj/machinery/atmospherics/components/device = thing
		var/list/airs = list()
		for(var/datum/gas_mixture/gas as anything in device.airs)
			airs += list(encode_gas(gas))
		record["device_airs"] = airs
	if(istype(thing, /obj/machinery))
		var/obj/machinery/machine = thing
		var/list/parts = list()
		for(var/datum/part as anything in machine.component_parts)
			if(istype(part, /datum/stock_part))
				parts += list(list("path" = "[part.type]"))
			else if(isatom(part))
				parts += list(encode_value(part))
		record["parts"] = parts
		if("materials" in machine.vars)
			var/datum/material_container/mats = material_container(machine)
			if(istype(machine.vars["materials"], /datum/remote_materials))
				var/datum/remote_materials/remote = machine.vars["materials"]
				record["material_silo"] = remote.silo ? assign_id(remote.silo) : null
			if(istype(mats))
				var/list/materials = list()
				for(var/datum/material/mat as anything in mats.materials)
					if(!mat)
						continue
					materials["[mat.type]"] = mats.materials[mat]
				record["materials"] = materials
	if(istype(thing, /obj/item/modular_computer))
		var/obj/item/modular_computer/computer = thing
		var/list/programs = list()
		for(var/datum/computer_file/file as anything in computer.stored_files)
			programs += "[file.type]"
		record["programs"] = programs
		record["active_program"] = computer.active_program?.filename
		var/list/background_programs = list()
		for(var/datum/computer_file/program/program as anything in computer.idle_threads)
			background_programs += program.filename
		record["background_programs"] = background_programs
	records += list(record)
	// A mob's contents are its organs and body parts: only Babylon's drones keep their items here
	// (their hands and storage); other mobs are saved by type and core fields only.
	if(ismob(thing) && !istype(thing, /mob/living/basic/drone))
		return record
	for(var/obj/child in thing.contents)
		if(QDELETED(child))
			continue
		// Containers hold more than items: the engine's secure crate holds the supermatter
		// shard, a machine. Saving only items dropped it from every world after its first save.
		if(child.babylon_skip_save())
			continue
		if(isitem(child) || (istype(thing, /obj/structure/closet) && !istype(child, /obj/effect)))
			capture(child, records, save_id)
	return record

/// The air a saved open turf loads with. Planetary turfs keep their planet's mix (their own
/// initial_gas_mix, e.g. the ice moon's): writing their current air there would make every
/// visited tile a new planet with that air for good. Other turfs load with their current air.
/datum/babylon_save/proc/saved_gas_mix(turf/open/tile)
	if(tile.planetary_atmos && istext(tile.initial_gas_mix))
		return tile.initial_gas_mix
	var/datum/gas_mixture/gas = tile.return_air()
	return gas.to_string()

/// The fields of this atom's type that go into a saved map (structural_fields, map_link_fields and
/// type_metadata_fields), cached per type. The area tools' copies use the same list.
/datum/babylon_save/proc/map_fields(atom/thing)
	var/list/fields = metadata_fields_by_type[thing.type]
	if(isnull(fields))
		fields = list()
		for(var/field in structural_fields | map_link_fields | type_metadata_fields(thing) | object_type_fields_of(thing))
			if(field in thing.vars)
				fields += field
		metadata_fields_by_type[thing.type] = fields
	return fields

/// The object_type_fields (state.dm) that apply to this atom's type.
/datum/babylon_save/proc/object_type_fields_of(atom/thing)
	var/list/fields = list()
	for(var/path in object_type_fields)
		if(istype(thing, path))
			fields |= object_type_fields[path]
	return fields

/// The typed_fields that apply to this atom's type.
/datum/babylon_save/proc/type_fields(atom/thing)
	var/list/fields = list()
	for(var/path in typed_fields)
		if(istype(thing, path))
			fields |= typed_fields[path]
	return fields

/// The extra_fields of this atom's type (settings applied after the object exists: creative
/// machine settings, pump and filter modes ...), cached per type. The area tools' copies use them.
/datum/babylon_save/proc/setting_fields(atom/thing)
	var/list/fields = setting_fields_by_type[thing.type]
	if(isnull(fields))
		fields = list()
		for(var/field in extra_fields | type_fields(thing))
			if(field in thing.vars)
				fields += field
		setting_fields_by_type[thing.type] = fields
	return fields

/datum/babylon_save/proc/metadata(atom/thing, is_turf = FALSE, with_id = TRUE)
	var/list/entries = list()
	var/list/fields = map_fields(thing)
	if(!is_turf && with_id)
		entries += "babylon_save_id = \"[assign_id(thing)]\""
	// Most turfs keep their type's values: their entry depends only on the type and the air,
	// and is built once per save (whole levels of rock and snow were most of a save's time).
	var/turf_key
	if(is_turf)
		turf_key = "[thing.type]"
		for(var/field in fields)
			var/current = field == "plane" ? babylon_true_plane(thing.plane) : thing.vars[field]
			if(current != initial(thing.vars[field]))
				turf_key = null
				break
		if(turf_key)
			if(isopenturf(thing) && !isspaceturf(thing))
				turf_key += "|[saved_gas_mix(thing)]"
			if(turf_metadata_cache[turf_key])
				return turf_metadata_cache[turf_key]
	for(var/field in fields)
		var/value = thing.vars[field]
		if(field == "plane")
			value = babylon_true_plane(value)
		if(babylon_save_keeps_default_text(thing, field, value))
			continue
		if(isdatum(value) && (field in object_type_fields_of(thing)))
			var/datum/held = value
			value = held.type
		if(isnull(value) || isnum(value) || istext(value) || ispath(value) || (islist(value) && (field in list_map_fields)))
			entries += "[field] = [tgm_encode(istext(value) ? babylon_save_text(value) : value)]"
	if(is_turf && isopenturf(thing) && !isspaceturf(thing))
		entries += "initial_gas_mix = [tgm_encode(saved_gas_mix(thing))]"
	. = length(entries) ? "{\n\t[entries.Join(";\n\t")]\n\t}" : ""
	if(turf_key)
		turf_metadata_cache[turf_key] = .

/datum/babylon_save
	/// Time between autosaves. Station worlds read babylon-autosave-minutes (station_session.dm).
	var/autosave_interval = 15 MINUTES
	/// Saved level z (as text) -> list(records JSON, turfs JSON, record count) of the last save in
	/// this run; a level nobody touched since reuses them (reusable_level()).
	var/list/saved_level_json = list()
	/// Saved level z (as text) -> milliseconds its last capture took (the pause estimate).
	var/list/level_capture_ms = list()
	/// Saved level z (as text) -> the generation directory holding its z<N>.dmm.
	var/list/saved_level_source = list()
	/// Type -> the reference_fields / gas mixture fields its instances have (capture()).
	var/list/reference_fields_by_type = list()
	var/list/gas_fields_by_type = list()
	/// "type|air" -> the saved map entry of a turf that keeps its type's values (one save only).
	var/list/turf_metadata_cache = list()
	/// The last successful save's result (generation, objects, levels, bytes, timings).
	var/list/last_save_report

/// Saves a checkpoint. Worlds that are not saved (babylon_world_saves()) refuse unless forced.
/// for_tutorial: a tutorial snapshot (a submission or save back, tutorial/submit.dm), forced, that
/// never becomes the world's checkpoint (no latest.json, no level reuse) and keeps no characters or
/// per-player records (babylon_world_saves_characters()). The caller deletes it once it was copied.
/datum/babylon_save/proc/save_world(force = FALSE, for_tutorial = FALSE)
	// After a round's end nothing is saved: the next start resumes the last save from before it.
	if(round_ending)
		return list("error" = "The round is over; this world is not saved again")
	if(!force && !for_tutorial && !babylon_world_saves())
		return list("error" = "This world is not saved")
	if(!ready || busy)
		return list("error" = "Babylon is not ready or a save is in progress")
	busy = TRUE
	checkpoint_processing = Master.processing
	var/list/result
	// Everything between busy = TRUE and busy = FALSE runs inside the try: a runtime must never
	// leave the world flagged busy (no save ever again) or the master paused.
	try
		before_checkpoint()
		// The chat subsystem stops with the master: these messages go out at once.
		to_chat_immediate(world, span_notice("Saving... the world is paused for about [estimated_pause_seconds()] seconds."))
		checkpoint_started = REALTIMEOFDAY
		Master.processing = FALSE
		checkpoint_hold(TRUE)
		sleep(1 TICKS)
		result = save_world_impl(for_tutorial)
	catch(var/exception/error)
		result = list("error" = "Checkpoint failed: [error]")
		log_world("BABYLON SAVE ERROR: [error]")
	if(!result["ok"] && draining)
		draining = FALSE
	release_checkpoint()
	busy = FALSE
	if(result["ok"])
		if(!for_tutorial)
			last_save_report = result
		if(!draining)
			to_chat_immediate(world, span_notice("Saved. Play resumes."))
	else
		level_save_failed()
		to_chat_immediate(world, span_warning("The save failed: [result["error"]]. Play resumes."))
	return result

/// Just before a save pauses the world (the station build lets a moving tram arrive first).
/datum/babylon_save/proc/before_checkpoint()
	return

/// A save failed: levels it took as changed stay changed for the next one.
/datum/babylon_save/proc/level_save_failed()
	return

/// Seconds a save pauses this world: the last capture's time, else a guess for the build.
/// The levels' last capture times add up for the levels the next save captures (a level that
/// was never captured in this run counts as a whole first save divided by the levels).
/datum/babylon_save/proc/estimated_pause_seconds()
	var/list/levels = persisted_levels()
	var/fallback_ms = (babylon_is_station_build() ? 45 SECONDS : 3 SECONDS) * 100 / max(1, length(levels))
	var/total_ms = 0
	for(var/z in levels)
		if(reusable_level(z))
			continue
		var/known = level_capture_ms["[z]"]
		total_ms += isnum(known) ? known : fallback_ms
	return max(1, round(total_ms / 1000 + 0.5))

/// Waits up to timeout (deciseconds) for a save in progress to finish. TRUE when none runs.
/datum/babylon_save/proc/await_save_idle(timeout)
	var/waited = 0
	while(busy && waited < timeout)
		sleep(1 SECONDS)
		waited += 1 SECONDS
	return !busy

/// Starts the autosave countdown every autosave_interval (Babylon 15 minutes, station worlds the
/// supervisor's babylon-autosave-minutes, default 30) while players are connected (both
/// builds' tick_players()). Worlds that are not saved never count down.
/datum/babylon_save/proc/schedule_autosave()
	if(!autosave_due(length(GLOB.clients)))
		return
	next_autosave_at = world.time + autosave_interval + 30 SECONDS
	INVOKE_ASYNC(src, PROC_REF(countdown_autosave))

/// The autosave countdown should start now, with this many players connected.
/datum/babylon_save/proc/autosave_due(connected)
	return babylon_world_saves() && connected && world.time >= next_autosave_at - 30 SECONDS && !autosave_countdown_active && !draining

// Keep the possession/reconnect loop responsive during the warning period.
// The authenticated control API may allow an unoccupied drone for isolated tests.
/datum/babylon_save/proc/countdown_autosave(allow_unoccupied = FALSE)
	if(autosave_countdown_active)
		return
	autosave_countdown_active = TRUE
	// A runtime must not leave the countdown flagged active: no autosave would ever run again.
	try
		autosave_countdown_steps(allow_unoccupied)
	catch(var/exception/error)
		log_world("Babylon autosave countdown failed: [error] ([error?.file]:[error?.line])")
	autosave_countdown_active = FALSE

/datum/babylon_save/proc/autosave_countdown_steps(allow_unoccupied)
	autosave_notices = list()
	var/remaining = 30
	for(var/seconds_left in list(30, 10, 5, 1))
		if(remaining > seconds_left)
			sleep((remaining - seconds_left) SECONDS)
		if(!allow_unoccupied && !length(GLOB.clients))
			return
		var/message = seconds_left == 1 ? "Babylon autosave now: the world pauses for about [estimated_pause_seconds()] seconds." : "Babylon autosave in [seconds_left] seconds; the world pauses for about [estimated_pause_seconds()] seconds."
		autosave_notices += list(list("remaining" = seconds_left, "at" = world.time, "message" = message))
		to_chat(world, span_notice(message))
		remaining = seconds_left
	// Give the client a full second to receive/render "now" before freezing.
	sleep(1 SECONDS)
	if((allow_unoccupied || length(GLOB.clients)) && !busy)
		save_world()

// Only snapshot capture is frozen. Serialization and disk writes use detached data.
/datum/babylon_save/proc/release_checkpoint()
	if(draining)
		return
	checkpoint_hold(FALSE)
	Master.processing = checkpoint_processing

/// Freezes (or releases) the players' bodies for a checkpoint. The build's session supplies it.
/datum/babylon_save/proc/checkpoint_hold(frozen)
	return

/// Mobs saved with the map, as list(turf = list(mob, ...)). The build's session supplies them.
/datum/babylon_save/proc/checkpoint_mobs()
	return list()

/// Adds the build's own session data (players, research ...) to a checkpoint's state.json.
/// for_tutorial: a tutorial snapshot, which keeps no characters or per-player records.
/datum/babylon_save/proc/capture_session_state(list/state, for_tutorial = FALSE)
	return

/// Creates the saved objects that hold other saved objects but are not in the saved map (the
/// station's player characters), before restore_world()'s records pass: they get their save ids
/// in restored_atoms, so records whose parent they are find it. Returns the records to restore
/// with the others (their own records and those of their contents). Babylon has none.
/datum/babylon_save/proc/restore_containers(list/state)
	return list()

/// Restores what capture_session_state saved, once every saved object exists again.
/datum/babylon_save/proc/restore_session_state(list/state)
	return

/// state.json "version" this build's checkpoints are written in, for migrations only (the layout
/// is writes_level_files()). Babylon: BABYLON_STATE_VERSION. The station build overrides it
/// (BABYLON_STATION_STATE_VERSION).
/datum/babylon_save/proc/save_format_version()
	return BABYLON_STATE_VERSION

/// Extra map variables written for this atom's type in the saved map (structural_fields are
/// written for every type). Babylon has none; the station build adds the docking ports' setup.
/datum/babylon_save/proc/type_metadata_fields(atom/thing)
	return list()

/// Effects are not saved (spawners, helpers, overlays), apart from decals. The station build
/// also keeps landmarks that its rounds need.
/datum/babylon_save/proc/saves_effect(obj/effect/effect)
	return istype(effect, /obj/effect/decal) || istype(effect, /obj/effect/turf_decal)

/// The tile's floor decals (warning lines, trim) as map entries. A turf decal turns into an
/// element on its turf when it loads and deletes itself, so without these every save lost them.
/datum/babylon_save/proc/turf_decal_entries(turf/tile)
	var/list/decals = list()
	SEND_SIGNAL(tile, COMSIG_ATOM_DECALS_ROTATING, decals)
	if(!length(decals))
		return list()
	var/list/entries = list()
	for(var/datum/element/decal/decal as anything in decals)
		var/list/decal_data = decal.get_rotated_parameters(tile.dir, tile.dir)
		// Only plain floor decals: cleanable, described or smoothing ones come from elsewhere.
		if(decal_data["cleanable"] || decal_data["desc"] || !isnull(decal_data["smoothing"]) || !decal_data["icon"])
			continue
		var/list/vars_text = list("icon = [tgm_encode(decal_data["icon"])]", "icon_state = [tgm_encode(decal_data["icon_state"])]", "dir = [decal_data["dir"]]", "layer = [decal_data["layer"]]", "alpha = [decal_data["alpha"]]")
		if(istext(decal_data["color"]))
			vars_text += "color = [tgm_encode(decal_data["color"])]"
		entries += "/obj/effect/turf_decal{\n\t[vars_text.Join(";\n\t")]\n\t}"
	return entries

/// Whether an object on a tile gets a state.json record (and a save id), or only its entry in
/// the saved map. Babylon records everything; the station build leaves out scenery (plants,
/// rocks, decals), which was most of a planet level's objects.
/datum/babylon_save/proc/saves_record(obj/object)
	return TRUE

/// Tiles saved as what lies beneath them, without their contents: list(turf = list(turf type,
/// area type)). The station build leaves its shuttles out this way (they load again at their
/// docks). Babylon has none.
/datum/babylon_save/proc/checkpoint_skipped_tiles()
	return list()

/// Extra map entries per tile, as list(turf = list(entry, ...)): things that only existed while
/// the map loaded and must load with it again. Babylon has none; the station build writes the
/// transport id landmarks its lifts and trams consumed.
/datum/babylon_save/proc/checkpoint_tile_extras()
	return list()

/// Whether a non-space turf's temperature and air go into state.json "turfs" (the map's
/// initial_gas_mix already holds its air). Babylon keeps every one.
/datum/babylon_save/proc/saves_turf_air(turf/tile)
	return TRUE

/// The z a saved turf record's z is loaded at in this world. Babylon: the same.
/datum/babylon_save/proc/restored_level_z(saved_z)
	return saved_z

/// The z-levels a checkpoint saves, in load order. Babylon: its one station level.
/datum/babylon_save/proc/persisted_levels()
	return list(station_z)

/// The checkpoint layout, separate from save_format_version() (which only drives migrations):
/// FALSE (Babylon) writes one map.dmm and records and turfs without z; TRUE (the station build)
/// writes a z<N>.dmm per saved level and a z on every record and turf. Driver.prepare reads the
/// layout by the world's build (services/supervisor/fixtures/README.md).
/datum/babylon_save/proc/writes_level_files()
	return FALSE

/// The map file a saved level is written to inside its generation directory.
/datum/babylon_save/proc/level_file(z)
	return writes_level_files() ? "z[z].dmm" : "map.dmm"

/// Saves one z-level: list("map_pieces" = its .dmm (a single-level TGM map) in pieces, "records" = saved
/// objects (state.json "records"), "turfs" = room air and temperature (state.json "turfs")).
/// Records and turfs carry their z when writes_level_files(); Babylon's do not.
/datum/babylon_save/proc/save_level(z, list/mobs_by_turf = checkpoint_mobs(), list/skipped_tiles = checkpoint_skipped_tiles(), list/tile_extras = checkpoint_tile_extras())
	var/list/records = list()
	var/list/turfs = list()
	var/list/headers = list()
	var/list/dictionary = list()
	var/list/grid = list()
	var/key_index = 1
	var/list/empty_space_keys = list()
	// All map changes and room air are exported; nested items and live settings go in state.json.
	for(var/x in 1 to world.maxx)
		grid += "\n([x],1,1) = {\"\n"
		for(var/y in world.maxy to 1 step -1)
			var/turf/tile = locate(x, y, z)
			var/list/beneath = skipped_tiles[tile]
			if(beneath)
				// Only the docks under it stay, so the skipped thing (a shuttle) can load there again.
				var/list/kept = list()
				for(var/obj/docking_port/stationary/dock in tile)
					if(istype(dock, /obj/docking_port/stationary/transit) || QDELETED(dock))
						continue
					kept += "[dock.type][metadata(dock)]"
					capture(dock, records, null)
				kept += "[beneath[1]]"
				kept += "[beneath[2]]"
				var/beneath_header = "(\n[kept.Join(",\n")])\n"
				var/beneath_key = dictionary[beneath_header]
				if(!beneath_key)
					beneath_key = calculate_tgm_header_index(key_index++, 3)
					dictionary[beneath_header] = beneath_key
					headers += "\"[beneath_key]\" = [beneath_header]"
				grid += "[beneath_key]\n"
				continue
			// Most of the 255x255 map is empty space. Reuse identical headers
			// instead of inspecting and encoding its vars 60,000 times.
			var/area/room = get_area(tile)
			var/space_signature
			if(isspaceturf(tile) && !(locate(/obj) in tile) && !mobs_by_turf[tile])
				space_signature = "[tile.type]|[room.type]|[tile.dir]|[tile.name]|[tile.pixel_x]|[tile.pixel_y]|[tile.pixel_z]|[tile.layer]|[tile.plane]|[tile.alpha]|[tile.density]|[tile.opacity]|[tile.icon_state]"
				if(empty_space_keys[space_signature])
					grid += "[empty_space_keys[space_signature]]\n"
					continue
			if(!isspaceturf(tile) && saves_turf_air(tile))
				var/list/turf_data = list("x" = x, "y" = y, "temperature" = tile.temperature)
				if(isopenturf(tile))
					var/turf/open/open = tile
					turf_data["gas"] = encode_gas(open.return_air())
				turfs += list(turf_data)
			var/list/objects = list()
			// CentCom loads its own template on every start (Babylon saves its tiles with the
			// level): only the floor and area are kept there, never its objects.
			var/centcom = istype(room, /area/centcom)
			for(var/obj/object in tile)
				if(centcom)
					break
				// A multi-tile object (lift and tram platforms, wide airlocks) is in the contents of
				// every tile it covers: it is saved once, on the tile it stands on.
				if(QDELETED(object) || object.loc != tile)
					continue
				if(istype(object, /obj/projectile))
					continue
				if(istype(object, /obj/machinery/power/terminal))
					var/obj/machinery/power/terminal/terminal = object
					if(istype(terminal.master, /obj/machinery/power/apc))
						continue
				if(istype(object, /obj/effect) && !saves_effect(object))
					continue
				if(object.flags_1 & HOLOGRAM_1)
					continue
				if(object.babylon_skip_save())
					continue
				if(!saves_record(object))
					// Scenery: the saved map's entry is all there is to it.
					objects += "[object.type][metadata(object, FALSE, FALSE)]"
					continue
				objects += "[object.type][metadata(object)]"
				capture(object, records, null)
			for(var/mob/living/saved_mob as anything in (centcom ? list() : mobs_by_turf[tile]))
				if(!QDELETED(saved_mob))
					objects += "[saved_mob.type][metadata(saved_mob)]"
					capture(saved_mob, records, null)
			objects += turf_decal_entries(tile)
			if(tile_extras[tile])
				objects += tile_extras[tile]
			objects += "[tile.type][metadata(tile, TRUE)]"
			objects += "[room.type]"
			var/header = "(\n[objects.Join(",\n")])\n"
			var/key = dictionary[header]
			if(!key)
				key = calculate_tgm_header_index(key_index++, 3)
				dictionary[header] = key
				headers += "\"[key]\" = [header]"
			if(space_signature)
				empty_space_keys[space_signature] = key
			grid += "[key]\n"
		grid += "\"}\n"
		CHECK_TICK
	if(writes_level_files())
		for(var/list/record as anything in records)
			record["z"] = z
		for(var/list/turf_data as anything in turfs)
			turf_data["z"] = z
	// The map text of a station level is tens of MB: it is kept and written in pieces of at most
	// BABYLON_SAVE_PIECE_BYTES (babylon_write_pieces()), never spliced into one string.
	var/list/map_pieces = list("//[DMM2TGM_MESSAGE]\n")
	map_pieces += babylon_join_in_pieces(headers)
	map_pieces += babylon_join_in_pieces(grid)
	return list("map_pieces" = map_pieces, "records" = records, "turfs" = turfs)

/datum/babylon_save/proc/save_world_impl(for_tutorial = FALSE)
	var/list/levels = persisted_levels()
	// Which levels changed is taken now, while the world is paused (changes from here on count
	// for the next save).
	begin_level_capture()
	// z (as text) -> the level's map text (in pieces), records and turf records (levels captured now)
	var/list/level_maps = list()
	var/list/level_records = list()
	var/list/level_turfs = list()
	// z (as text) -> the generation whose z<N>.dmm and records a clean level reuses
	var/list/reused_levels = list()
	turf_metadata_cache = list()
	var/list/mobs_by_turf = checkpoint_mobs()
	var/list/skipped_tiles = checkpoint_skipped_tiles()
	var/list/tile_extras = checkpoint_tile_extras()
	// z (as text) -> list(milliseconds, records) of its capture, for the save's report.
	var/list/level_costs = list()
	for(var/z in levels)
		var/source = reusable_level(z)
		if(source)
			reused_levels["[z]"] = source
			level_costs["[z]"] = list(0, "reused")
			continue
		var/level_started = REALTIMEOFDAY
		var/list/level = save_level(z, mobs_by_turf, skipped_tiles, tile_extras)
		level_costs["[z]"] = list((REALTIMEOFDAY - level_started) * 100, length(level["records"]))
		level_capture_ms["[z]"] = (REALTIMEOFDAY - level_started) * 100
		level_records["[z]"] = level["records"]
		level_turfs["[z]"] = level["turfs"]
		level_maps["[z]"] = level["map_pieces"]
	turf_metadata_cache = list()
	var/generation = "save-[time2text(world.realtime, "YYYYMMDD-hhmmss")]-[++save_count]"
	var/base = "data/babylon/saves/[generation]"
	// 7: non-item contents of closets and crates are saved (restore_lost_supermatter()).
	// "records" and "turfs" are spliced in as JSON below, level by level.
	var/list/state = list("version" = save_format_version(), "generation" = generation, "next_id" = next_id, "save_count" = save_count, "records" = "@babylon-records@", "turfs" = "@babylon-turfs@")
	capture_session_state(state, for_tutorial)
	// The session's capture may give objects their first save id (the characters' items).
	state["next_id"] = next_id
	state["sun"] = list("azimuth" = SSsun.azimuth, "azimuth_mod" = SSsun.azimuth_mod, "base_rotation" = SSsun.base_rotation)
	state["play_time"] = play_time
	checkpoint_capture_ms = (REALTIMEOFDAY - checkpoint_started) * 100
	release_checkpoint()
	CHECK_TICK
	// Every level's records and turfs as JSON: kept, so a level nobody touched can reuse them.
	var/list/level_json = list()
	for(var/z in levels)
		var/list/encoded = reused_levels["[z]"] ? saved_level_json["[z]"] : list(json_encode(level_records["[z]"]), json_encode(level_turfs["[z]"]), length(level_records["[z]"]))
		level_json["[z]"] = encoded
		CHECK_TICK
	var/list/record_parts = list()
	var/list/turf_parts = list()
	var/objects = 0
	for(var/z_text in level_json)
		var/list/encoded = level_json[z_text]
		objects += encoded[3]
		// Each is a JSON array; its inside joins the others into one array.
		if(length(encoded[1]) > 2)
			record_parts += copytext(encoded[1], 2, -1)
		if(length(encoded[2]) > 2)
			turf_parts += copytext(encoded[2], 2, -1)
	var/bytes = 0
	if(for_tutorial)
		// First, so even a half-written snapshot is never taken for a checkpoint (the supervisor's
		// constants.TUTORIAL_SNAPSHOT_MARKER: never listed or restored, deleted once old).
		rustg_file_write("1", "[base]/tutorial-snapshot")
	// Every file is checked: a level map written short loads as a broken level ("Undefined model
	// key"), and the next save would write that loss over the world.
	var/list/write_errors = list()
	for(var/z_text in level_maps)
		var/list/written = babylon_write_pieces(level_maps[z_text], "[base]/[level_file(text2num(z_text))]")
		bytes += written["bytes"]
		if(written["error"])
			write_errors += "[level_file(text2num(z_text))]: [written["error"]]"
	for(var/z_text in reused_levels)
		var/file_name = level_file(text2num(z_text))
		if(!fcopy("data/babylon/saves/[reused_levels[z_text]]/[file_name]", "[base]/[file_name]"))
			write_errors += "[file_name]: copying it from [reused_levels[z_text]] failed"
		bytes += length(file("[base]/[file_name]"))
	var/state_text = json_encode(state)
	// json_encode writes an empty list as []; the save contract's "characters" is an object
	// (services/supervisor/fixtures/README.md). Babylon's state has no such key.
	// (Brackets and braces spelled as characters: DM string literals treat them specially.)
	var/open_list = ascii2text(91)
	var/close_list = ascii2text(93)
	state_text = replacetext(state_text, "\"characters\":[open_list][close_list]", "\"characters\":[ascii2text(123)][ascii2text(125)]")
	// state.json is written piece by piece: the records of a large station are tens of MB, and
	// splicing them into one string broke (the file came out truncated).
	var/records_at = findtext(state_text, "\"@babylon-records@\"")
	var/turfs_at = findtext(state_text, "\"@babylon-turfs@\"")
	var/list/pieces = list(copytext(state_text, 1, records_at), open_list)
	for(var/index in 1 to length(record_parts))
		pieces += index > 1 ? ",[record_parts[index]]" : record_parts[index]
	pieces += list(close_list, copytext(state_text, records_at + length("\"@babylon-records@\""), turfs_at), open_list)
	for(var/index in 1 to length(turf_parts))
		pieces += index > 1 ? ",[turf_parts[index]]" : turf_parts[index]
	pieces += list(close_list, copytext(state_text, turfs_at + length("\"@babylon-turfs@\"")))
	var/list/state_written = babylon_write_pieces(pieces, "[base]/state.json")
	bytes += state_written["bytes"]
	if(state_written["error"])
		write_errors += "state.json: [state_written["error"]]"
		if(state_written["size_mismatch"])
			log_non_ascii_text(pieces, generation)
	// latest.json is committed only after every generation file is present and was written whole.
	var/complete = !length(write_errors)
	for(var/error in write_errors)
		log_world("Babylon save [generation]: [error]")
	for(var/z in levels)
		if(!fexists("[base]/[level_file(z)]"))
			complete = FALSE
	if(!complete)
		busy = FALSE
		return list("error" = "Save files could not be written")
	if(for_tutorial)
		// Only the supervisor's copy of it is kept: the world neither resumes nor reuses levels
		// from it, and the levels it captured count as changed for the next real save.
		level_save_failed()
		log_world("Babylon wrote tutorial snapshot [generation]: [objects] objects, [bytes] bytes; capture [checkpoint_capture_ms] ms.")
		return list("ok" = TRUE, "generation" = generation, "objects" = objects, "bytes" = bytes, "tutorial_snapshot" = TRUE)
	last_save = generation
	saved_level_json = level_json
	saved_level_source = list()
	for(var/z in levels)
		saved_level_source["[z]"] = generation
	level_saved()
	rustg_file_write(json_encode(list("generation" = generation, "saved_at" = time2text(world.realtime, "YYYY-MM-DD hh:mm:ss"), "objects" = objects)), "data/babylon/saves/latest.json")
	var/total_ms = (REALTIMEOFDAY - checkpoint_started) * 100
	// The simulation is paused for capture_ms: keep an eye on it for large (multi-level) maps.
	log_world("Babylon saved [generation]: [length(levels)] level(s) ([length(reused_levels)] unchanged, reused), [objects] objects, [bytes] bytes; capture [checkpoint_capture_ms] ms, total [total_ms] ms.")
	return list("ok" = TRUE, "generation" = generation, "objects" = objects, "capture_ms" = checkpoint_capture_ms, "total_ms" = total_ms, "levels" = length(levels), "reused_levels" = length(reused_levels), "bytes" = bytes, "level_costs" = level_costs)

/// TRUE if a file of file_size holds text_bytes of ASCII text appended in piece_count pieces,
/// within what DM's 32-bit float lengths and sums can tell apart (see save_world_impl()).
/proc/babylon_written_size_matches(file_size, text_bytes, piece_count)
	// Below 2^24 every length and sum is an exact integer.
	var/tolerance = max(file_size, text_bytes) < 2 ** 24 ? 0 : (piece_count + 1) * max(file_size, text_bytes) / (2 ** 23)
	return abs(file_size - text_bytes) <= tolerance

/// The strings joined into pieces of at most BABYLON_SAVE_PIECE_BYTES (a single string is never
/// split): large save files are written piece by piece (babylon_write_pieces()).
/proc/babylon_join_in_pieces(list/strings)
	var/list/pieces = list()
	var/list/current = list()
	var/current_bytes = 0
	for(var/text in strings)
		var/size = length(text)
		if(current_bytes && current_bytes + size > BABYLON_SAVE_PIECE_BYTES)
			pieces += current.Join()
			current = list()
			current_bytes = 0
		current += text
		current_bytes += size
	if(length(current))
		pieces += current.Join()
	return pieces

/// Writes the pieces as the file at path (replacing it) and checks the result. Large DM strings
/// spliced into one and written at once came out truncated or damaged, so every save file goes
/// through here: list("bytes" = text bytes, "error" = text or null, "size_mismatch" = TRUE when
/// the file on disk is not as long as its text). rust-g answers an error text when a write fails.
/proc/babylon_write_pieces(list/pieces, path)
	fdel(path)
	var/text_bytes = 0
	var/error
	for(var/piece in pieces)
		text_bytes += length(piece)
		var/result = rustg_file_append(piece, path)
		if(result && !error)
			error = "writing failed: [result]"
		CHECK_TICK
	var/file_size = fexists(path) ? length(file(path)) : 0
	// The pieces' text is ASCII or UTF-8; length() counts bytes either way, as the file size does.
	var/mismatch = !babylon_written_size_matches(file_size, text_bytes, length(pieces))
	if(mismatch && !error)
		error = "[num2text(file_size, 12)] bytes on disk for [num2text(text_bytes, 12)] bytes of text in [length(pieces)] pieces"
	return list("bytes" = text_bytes, "error" = error, "size_mismatch" = mismatch)

/// Diagnostics for a state.json whose size is off: where its text holds characters outside
/// ASCII (json_encode should leave none), with some context, for the first few hits.
/datum/babylon_save/proc/log_non_ascii_text(list/pieces, generation)
	var/regex/non_ascii = regex(@"[^\x00-\x7F]", "g")
	var/hits = 0
	for(var/index in 1 to length(pieces))
		var/piece = pieces[index]
		non_ascii.next = 1
		while(hits < 5 && non_ascii.Find(piece))
			hits++
			var/at = non_ascii.index
			var/context = copytext(piece, max(1, at - 40), min(length(piece) + 1, at + 40))
			log_world("Babylon save [generation]: state.json piece [index] has character [text2ascii(piece, at)] at [num2text(at, 12)]: [json_encode(context)]")
		if(hits >= 5)
			break
	if(!hits)
		log_world("Babylon save [generation]: state.json text is all ASCII.")

/// The generation whose files and records a level can reuse because nothing changed it since,
/// or null to capture it. Babylon always captures its one level.
/datum/babylon_save/proc/reusable_level(z)
	return null

/// After a successful save: the build's bookkeeping of changed levels.
/datum/babylon_save/proc/level_saved()
	return

/// At the start of a capture, while the world is paused: the build takes the set of changed
/// levels for this save and starts a new one.
/datum/babylon_save/proc/begin_level_capture()
	return

/// Atoms that never go into a save (the tutorial engine marks its own props and NPCs).
/atom/proc/babylon_skip_save()
	return FALSE

/datum/babylon_save/proc/restore_world()
	if(!fexists("data/babylon/resume-state.json"))
		return
	// A saved level that did not load (a damaged map file) must fail the start: the world would
	// run without it and its next save would write the loss over the checkpoint.
	if(length(SSmapping.babylon_failed_maps))
		CRASH("Saved map files failed to load: [jointext(SSmapping.babylon_failed_maps, ", ")]")
	var/list/state = resume_data || json_decode(file2text("data/babylon/resume-state.json"))
	var/list/sun = state["sun"]
	if(sun)
		SSsun.azimuth = sun["azimuth"]
		SSsun.azimuth_mod = sun["azimuth_mod"]
		SSsun.base_rotation = sun["base_rotation"]
	next_id = state["next_id"]
	save_count = state["save_count"] || 0
	last_save = state["generation"]
	var/list/records = state["records"]
	var/duplicate_ids = 0
	for(var/atom/thing in world)
		if(thing.babylon_save_id)
			var/atom/first = restored_atoms[thing.babylon_save_id]
			if(first)
				duplicate_ids++
				if(duplicate_ids <= 5)
					log_world("Babylon restore: save id [thing.babylon_save_id] on [first.type] ([first.x],[first.y],[first.z]) and [thing.type] ([thing.x],[thing.y],[thing.z]).")
			restored_atoms[thing.babylon_save_id] = thing
		CHECK_TICK
	if(duplicate_ids)
		log_world("Babylon restore: [duplicate_ids] save id(s) are carried by more than one object; references to them may point at the wrong one.")
	var/list/container_records = restore_containers(state)
	if(length(container_records))
		records = records + container_records
		for(var/list/record as anything in container_records)
			resume_records[record["id"]] = record
	var/list/used_children = list()
	for(var/list/record as anything in records)
		var/save_id = record["id"]
		var/atom/thing = restored_atoms[save_id]
		if(record["parent"])
			var/atom/parent = restored_atoms[record["parent"]]
			if(!parent)
				continue
			var/path = text2path(record["type"])
			for(var/obj/candidate in parent.contents)
				// A body's own organs and limbs are never one of its saved items.
				if(ismob(parent) && (isorgan(candidate) || isbodypart(candidate)))
					continue
				// A candidate that carries another saved object's id is that object, not this one.
				if(candidate.type == path && !(candidate in used_children) && (!candidate.babylon_save_id || candidate.babylon_save_id == save_id))
					thing = candidate
					break
			if(!thing)
				thing = new path(parent)
			else if(thing.loc != parent)
				var/atom/movable/child = thing
				child.forceMove(parent)
			used_children += thing
			thing.babylon_save_id = save_id
			restored_atoms[save_id] = thing
		if(!thing)
			continue
		var/list/fields = record["fields"]
		for(var/field in fields)
			if(field in thing.vars)
				thing.vars[field] = decode_value(fields[field])
		if(record["wires"] && thing.wires)
			var/list/wire_data = record["wires"]
			thing.wires.colors = wire_data["colors"]
			thing.wires.cut_wires = wire_data["cut_wires"]
		if(istype(thing, /obj/machinery/power/apc) && !record["has_terminal"])
			var/obj/machinery/power/apc/apc = thing
			QDEL_NULL(apc.terminal)
		if(thing.reagents && ("reagents" in record))
			thing.reagents.clear_reagents()
			for(var/list/chem as anything in record["reagents"])
				thing.reagents.add_reagent(text2path(chem["type"]), chem["volume"], added_purity = chem["purity"], no_react = TRUE)
		CHECK_TICK
	// A closed locker takes in whatever lies or stands on its tile when the map loads (animals
	// too). Saved objects and mobs beside it go back onto their tile, before the regenerated
	// contents are removed below.
	for(var/list/record as anything in records)
		if(record["parent"])
			continue
		var/atom/movable/thing = restored_atoms[record["id"]]
		if(!istype(thing) || isturf(thing.loc))
			continue
		var/turf/tile = locate(record["x"], record["y"], isnull(record["z"]) ? station_z : restored_level_z(record["z"]))
		if(tile)
			thing.forceMove(tile)
		CHECK_TICK
	// Remove regenerated default inventory which was not in the saved inventory.
	for(var/list/record as anything in records)
		var/atom/thing = restored_atoms[record["id"]]
		if(!thing)
			continue
		// Lockers, cabinets and bookcases fill themselves on load as well: without them a
		// world's lockers refilled on every restart. Every object counts, vehicles too: a mining
		// Ripley rolls a new random drill in its Initialize, and the one it rolled stayed beside
		// the saved one (the saved equipment is attached again in babylon_after_restore()).
		if(isobj(thing) || istype(thing, /mob/living/basic/drone))
			for(var/obj/item/extra in thing.contents.Copy())
				if(!(extra in used_children))
					qdel(extra)
		var/list/references = record["references"]
		for(var/field in references)
			if(field in thing.vars)
				if(field != "connected_sensor")
					thing.vars[field] = decode_value(references[field])
		if((istype(thing, /obj/structure/frame/computer) || istype(thing, /obj/machinery)) && ("circuit" in thing.vars))
			var/obj/item/circuitboard/board = thing.vars["circuit"]
			if(QDELETED(board) || board.loc != thing)
				// Legacy saves retained the board as a child but omitted the
				// frame/machine's circuit reference. Preserve the construction
				// stage: circuit_added() would reset an already wired frame.
				thing.vars["circuit"] = null
				for(var/obj/item/circuitboard/candidate in thing.contents)
					if(!QDELETED(candidate) && (candidate in used_children))
						thing.vars["circuit"] = candidate
						break
		if(istype(thing, /obj/structure/frame/machine))
			restore_machine_frame(thing, record, used_children)
		if(istype(thing, /obj/machinery/airalarm) && references["connected_sensor"])
			var/obj/machinery/airalarm/alarm = thing
			var/obj/machinery/air_sensor/sensor = decode_value(references["connected_sensor"])
			if(sensor && alarm.connected_sensor != sensor)
				if(alarm.connected_sensor)
					alarm.disconnect_sensor()
				alarm.connect_sensor(sensor)
		if(istype(thing, /obj/machinery))
			var/obj/machinery/machine = thing
			if(length(record["parts"]))
				var/list/parts = list()
				for(var/list/part as anything in record["parts"])
					if(part["path"])
						// Stock parts are singletons; the frame and part exchange compare them.
						var/datum/stock_part/stock_part = GLOB.stock_part_datums[text2path(part["path"])]
						if(stock_part)
							parts += stock_part
					else
						var/atom/part_atom = decode_value(part)
						if(part_atom)
							parts += part_atom
				machine.component_parts = parts
				machine.RefreshParts()
			// RefreshParts may reset operating settings. Reapply the snapshot
			// afterwards; connectivity was already restored by the map preloader.
			var/list/fields = record["fields"]
			for(var/field in fields)
				if(field in thing.vars)
					thing.vars[field] = decode_value(fields[field])
			if(record["materials"] && ("materials" in machine.vars))
				var/datum/material_container/mats = material_container(machine)
				if(istype(machine.vars["materials"], /datum/remote_materials))
					var/datum/remote_materials/remote = machine.vars["materials"]
					mats = remote.babylon_restore_container(restored_atoms[record["material_silo"]])
				if(istype(mats))
					for(var/matpath in record["materials"])
						var/datum/material/material = SSmaterials.get_material(text2path(matpath))
						if(istype(material))
							mats.materials[material] = record["materials"][matpath]
			machine.power_change()
		if(istype(thing, /obj/item/modular_computer) && record["programs"])
			var/obj/item/modular_computer/computer = thing
			for(var/program_type in record["programs"])
				var/path = text2path(program_type)
				var/datum/computer_file/program = new path()
				if(!computer.find_file_by_name(program.filename))
					computer.store_file(program)
				else
					qdel(program)
		if(istype(thing, /obj/machinery/atmospherics/components/unary/vent_pump))
			var/obj/machinery/atmospherics/components/unary/vent_pump/vent = thing
			vent.disconnect_from_area(vent.assigned_area)
			var/area/assigned = ("assigned_area" in record) ? locate(text2path(record["assigned_area"])) : get_area(vent)
			if(assigned)
				vent.assign_to_area(assigned)
		if(istype(thing, /obj/machinery/atmospherics/components/unary/vent_scrubber))
			var/obj/machinery/atmospherics/components/unary/vent_scrubber/scrubber = thing
			scrubber.disconnect_from_area(scrubber.assigned_area)
			var/area/assigned = ("assigned_area" in record) ? locate(text2path(record["assigned_area"])) : get_area(scrubber)
			if(assigned)
				scrubber.assign_to_area(assigned)
		if((state["version"] || 1) < 2)
			recover_legacy(thing, record)
		// update_icon() drops an atom's managed vis overlays and expects update_overlays() to add
		// them again. Objects that make theirs only in Initialize (holobarriers, plastic flaps)
		// kept alpha 0 without their overlay: invisible, though named and attackable.
		var/list/vis_overlays = thing.managed_vis_overlays?.Copy()
		thing.update_appearance()
		if(length(vis_overlays) && !length(thing.managed_vis_overlays) && ismovable(thing))
			var/atom/movable/shown = thing
			for(var/obj/effect/overlay/vis/overlay as anything in vis_overlays)
				if(QDELETED(overlay))
					continue
				shown.vis_contents += overlay
				LAZYADD(shown.managed_vis_overlays, overlay)
		// Rendering order is runtime-editable and update_appearance may reset it.
		for(var/field in list("layer", "pixel_x", "pixel_y", "pixel_z", "alpha"))
			if((field in record["fields"]) && (field in thing.vars))
				thing.vars[field] = decode_value(record["fields"][field])
		// The plane is saved without its multi-z offset (older saves with it); this z's offset
		// goes back on.
		if(("plane" in record["fields"]) && ("plane" in thing.vars))
			SET_PLANE_IMPLICIT(thing, babylon_true_plane(decode_value(record["fields"]["plane"])))
		CHECK_TICK
	// Restore gases only after parts and network topology are complete.
	// copy_from preserves volume; version 2 also stores the actual volume.
	for(var/list/record as anything in records)
		var/atom/thing = restored_atoms[record["id"]]
		if(!thing)
			continue
		for(var/field in list("air_contents", "air1", "air2", "air3", "absorbed_gasmix"))
			if(record[field] && (field in thing.vars))
				var/datum/gas_mixture/mix = thing.vars[field]
				if(istype(mix))
					restore_gas(mix, record[field])
		if(record["pipeline_gas"] && istype(thing, /obj/machinery/atmospherics/pipe))
			var/obj/machinery/atmospherics/pipe/pipe = thing
			restore_gas(pipe.parent?.air, record["pipeline_gas"])
		if(record["device_airs"] && istype(thing, /obj/machinery/atmospherics/components))
			var/obj/machinery/atmospherics/components/device = thing
			var/list/airs = record["device_airs"]
			for(var/index in 1 to min(length(airs), length(device.airs)))
				var/datum/gas_mixture/mix = device.airs[index]
				restore_gas(mix, airs[index])
		CHECK_TICK
	for(var/list/record as anything in state["turfs"])
		// Babylon's turfs carry no z: they are on the station level.
		var/turf/tile = locate(record["x"], record["y"], isnull(record["z"]) ? station_z : restored_level_z(record["z"]))
		if(!tile)
			continue
		tile.temperature = record["temperature"]
		if(record["gas"] && isopenturf(tile))
			var/turf/open/open = tile
			restore_gas(open.return_air(), record["gas"])
		CHECK_TICK
	restore_portable_connections(records)
	for(var/list/record as anything in records)
		var/atom/thing = restored_atoms[record["id"]]
		if(thing && !QDELETED(thing))
			// One object's reconcile step must never fail the whole world's restore.
			try
				thing.babylon_after_restore(record["fields"] || list())
			catch(var/exception/error)
				log_world("Babylon restore: [thing.type] [record["id"]] could not be reconciled: [error] ([error?.file]:[error?.line])")
		CHECK_TICK
	record_creative_canister_ports()
	SSmachines.makepowernets()
	restore_airlock_configuration(state)
	// Door animations and their sleeping procs cannot survive a process restart.
	// Settle at the saved physical position, then rebuild pump links without
	// running set_links' fresh-install open/close animations over the snapshot.
	for(var/list/record as anything in records)
		var/atom/thing = restored_atoms[record["id"]]
		if(istype(thing, /obj/machinery/door/airlock))
			var/obj/machinery/door/airlock/door = thing
			door.operating = FALSE
			door.delayed_close_requested = FALSE
			door.set_airlock_state(door.density ? AIRLOCK_CLOSED : AIRLOCK_OPEN)
			door.set_opacity(door.density && !door.glass)
			if(door.filler)
				door.filler.set_density(door.density)
				door.filler.set_opacity(door.opacity)
			if(door.density)
				door.flags_1 |= PREVENT_CLICK_UNDER_1
			else
				door.flags_1 &= ~PREVENT_CLICK_UNDER_1
			door.air_update_turf(TRUE, FALSE)
			if(!door.density && door.autoclose)
				door.autoclose_in(8 SECONDS)
		if(istype(thing, /obj/machinery/airalarm) && record["alarm_thresholds"])
			var/obj/machinery/airalarm/alarm = thing
			for(var/list/saved as anything in record["alarm_thresholds"])
				var/key = decode_value(saved["key"])
				var/threshold_type = text2path(saved["type"])
				var/datum/tlv/threshold = new threshold_type()
				for(var/field in list("warning_min", "warning_max", "hazard_min", "hazard_max"))
					threshold.vars[field] = saved[field]
				qdel(alarm.tlv_collection[key])
				alarm.tlv_collection[key] = threshold
			if(record["alarm_mode"])
				alarm.select_mode(alarm, text2path(record["alarm_mode"]), should_apply = FALSE)
		if(istype(thing, /obj/machinery/atmospherics/components/unary/airlock_pump))
			restore_cycle_pump(thing, record)
		CHECK_TICK

	for(var/list/record as anything in records)
		var/atom/thing = restored_atoms[record["id"]]
		if(istype(thing, /obj/machinery/power/solar_control))
			var/obj/machinery/power/solar_control/control = thing
			if("solar_panels" in record)
				var/list/panels = decode_value(record["solar_panels"])
				for(var/obj/machinery/power/solar/panel as anything in panels)
					panel.set_control(control)
				var/obj/machinery/power/tracker/tracker = decode_value(record["solar_tracker"])
				if(tracker)
					tracker.set_control(control)
			else
				control.search_for_connected()
			if("track" in record["fields"])
				control.track = record["fields"]["track"]
		if(istype(thing, /obj/item/modular_computer) && record["active_program"])
			programs_to_resume[thing] = record
		CHECK_TICK
	restore_session_state(state)
	remove_saved_companion_copies(records)
	play_time = isnum(state["play_time"]) ? state["play_time"] : 0
	loading_saved_map = FALSE
	to_chat(world, span_notice("Babylon resumed from [last_save]."))

/// Saves before version 7 dropped the supermatter shard from the engine's secure crate, which
/// makes progression impossible. Such a world without any crystal gets the shard back there.
/// Only older saves are repaired: a crystal lost in play afterwards stays lost.
/datum/babylon_save/proc/restore_lost_supermatter()
	if(length(SSmachines.get_machines_by_type_and_subtypes(/obj/machinery/power/supermatter_crystal)))
		return
	var/atom/destination
	var/list/engine = get_area_turfs(/area/ruin/space/bb13/engineering/engine, station_z)
	for(var/turf/tile as anything in engine)
		destination = locate(/obj/structure/closet/crate/secure/engineering) in tile
		if(destination)
			break
	if(!destination)
		for(var/turf/open/tile in engine)
			if(!tile.is_blocked_turf(TRUE))
				destination = tile
				break
	if(!destination)
		migration_notes |= "The supermatter shard was missing and no place in the engine room was free to return it."
		return
	var/obj/machinery/power/supermatter_crystal/shard/shard = new(destination)
	shard.warning_channel = null
	migration_notes |= "Returned the supermatter shard that older saves dropped from the engine's secure crate."
	log_world("Babylon: returned the lost supermatter shard to [destination] ([destination.x],[destination.y],[destination.z]).")

// Group membership is derived from the saved IDs after every door exists.
// Do not rely solely on the cached close_others list from a previous world.
/datum/babylon_save/proc/restore_portable_connections(list/records)
	// Both sides and their pipe networks/gases must exist before connect().
	// The native path also restores anchoring, offsets and atmos processing.
	for(var/list/record as anything in records)
		var/obj/machinery/portable_atmospherics/portable = restored_atoms[record["id"]]
		if(!istype(portable))
			continue
		var/obj/machinery/atmospherics/components/unary/portables_connector/port
		if("portable_port" in record)
			port = decode_value(record["portable_port"])
		else if(portable.anchored)
			// Before this field was saved, wrenching left only the anchored
			// flag. Recover a matching free connector on that same tile.
			for(var/obj/machinery/atmospherics/components/unary/portables_connector/candidate in get_turf(portable))
				if(!candidate.connected_device)
					port = candidate
					break
		if(!istype(port) || port.loc != get_turf(portable) || port.connected_device)
			continue
		if(portable.connect(port) && !("portable_port" in record))
			migration_notes |= "Recovered anchored portable-atmos connector attachment from legacy save."

// ---------------------------------------------------------------------------------------------
// Saved state over fresh-map defaults. A saved level (and an area-tool copy) loads as a map, so its
// atoms initialize with mapload, where upstream code decides things that only fit a fresh map.
// One mechanism covers the class:
// - babylon_loading_saved_map() is TRUE while such a map loads; the mapload defaults below stand back;
// - the state itself is saved (typed_fields, state.dm), restored like any field, and
//   babylon_after_restore() reconciles what a plain variable write cannot (powernets, camera nets,
//   components, connections). restore_world() calls it for every restored object; the area tools'
//   paste calls it with the copied settings.

/datum/babylon_save/New()
	. = ..()
	loading_saved_map = fexists("data/babylon/resume-state.json")

/proc/babylon_loading_saved_map()
	return !!GLOB.babylon_save?.loading_saved_map

/// This start resumes a saved world (the supervisor staged its state). Round-start rolls that only
/// fit a fresh map (decay, area spawns, station traits) stand back for the whole start; atoms ask
/// babylon_loading_saved_map(), which ends when the restore finished.
/proc/babylon_world_resumes_save()
	return fexists("data/babylon/resume-state.json")

/datum/controller/subsystem/mapping
	/// Map files LoadGroup() could not load in this run (upstream only announces them): a restore
	/// refuses to run over them (restore_world()).
	var/list/babylon_failed_maps = list()

/datum/controller/subsystem/mapping/LoadGroup(list/errorList, name, path, files, list/traits, list/default_traits, silent = FALSE, height_autosetup = TRUE)
	var/list/before = islist(errorList) ? errorList.Copy() : list()
	. = ..()
	for(var/failed in errorList)
		if(!(failed in before))
			babylon_failed_maps |= failed

// ---------------------------------------------------------------------------------------------
// Companions: objects another atom makes in its Initialize and puts on the map beside it (a gravity
// generator's parts, a turret's cover, a wide airlock's fillers, a cult floor's effect, a shield
// generator's field). Their maker makes them again whenever it initializes, also when a save
// loads, so a save that kept them got one more copy on every restart. They are marked when they
// are made and never saved (babylon_skip_save()); a restore removes the copies older saves hold
// (remove_saved_companion_copies()). Atoms a map template places are never companions, even when
// the template loads during another atom's Initialize.

/datum/controller/subsystem/atoms
	/// The atoms whose Initialize runs right now, innermost last.
	var/list/babylon_initializing = list()
	/// Above 0 while an Initialize makes something only a fresh map gets (a random default that
	/// stands back for a saved map): what it makes is saved, it is no companion.
	var/babylon_fresh_map_only = 0

/datum/controller/subsystem/atoms/InitAtom(atom/A, from_template = FALSE, list/arguments)
	var/depth = length(babylon_initializing)
	if(depth && !from_template && !babylon_fresh_map_only && ismovable(A) && isturf(A.loc))
		var/atom/movable/companion = A
		companion.babylon_companion_of = WEAKREF(babylon_initializing[depth])
		companion.babylon_companion_turf = A.loc
	babylon_initializing += A
	// No try here: in DM a try anywhere up the stack makes a runtime deep inside an Initialize
	// (a stack_trace) unwind everything up to it, where it would otherwise only end the proc that
	// failed (a tram then no longer merged its modules). Without one, a runtime in A's Initialize
	// returns here and the stack shrinks back. Code that loads atoms inside its own try restores
	// the depth in its catch (babylon_init_depth_restore()).
	. = ..()
	babylon_initializing.Cut(depth + 1)

/// For a catch around code that creates atoms: drops the initializing atoms a runtime left on the
/// stack (depth: length(SSatoms.babylon_initializing) before the try).
/proc/babylon_init_depth_restore(depth)
	if(length(SSatoms.babylon_initializing) > depth)
		SSatoms.babylon_initializing.Cut(depth + 1)

/atom/movable
	/// The atom whose Initialize made this one (a weakref), see Companions above.
	var/datum/weakref/babylon_companion_of
	/// The tile it was made on: one that was moved away (picked up, carried off) is a player's now.
	var/turf/babylon_companion_turf

/// A companion its maker still owns: still where it was made, its maker alive and not inside it
/// (a paper that put itself into a bottle it made keeps the bottle).
/atom/movable/proc/babylon_is_companion()
	if(!babylon_companion_of || loc != babylon_companion_turf)
		return FALSE
	var/atom/maker = babylon_companion_of.resolve()
	if(!maker || QDELETED(maker))
		return FALSE
	for(var/atom/holder = maker.loc; holder && !isturf(holder); holder = holder.loc)
		if(holder == src)
			return FALSE
	return TRUE

/atom/movable/babylon_skip_save()
	return ..() || babylon_is_companion()

/// After a restore: a saved object of the same type on the same tile as a companion made during this
/// load is a copy an older save kept; the companion stays (its maker holds it). The same holds for
/// CentCom, whose template loads again on every start (Babylon saves its tiles with the level).
/datum/babylon_save/proc/remove_saved_companion_copies(list/records)
	var/list/removed = list()
	for(var/list/record as anything in records)
		if(record["parent"])
			continue
		var/atom/movable/saved = restored_atoms[record["id"]]
		if(!istype(saved) || QDELETED(saved) || !isturf(saved.loc))
			continue
		var/in_centcom = istype(get_area(saved), /area/centcom)
		for(var/atom/movable/other in saved.loc)
			if(other == saved || other.type != saved.type || other.babylon_save_id)
				continue
			if(other.babylon_is_companion() || in_centcom)
				removed["[saved.type]"] = (removed["[saved.type]"] || 0) + 1
				qdel(saved)
				break
		CHECK_TICK
	if(length(removed))
		var/list/parts = list()
		for(var/kind in removed)
			parts += "[kind] x[removed[kind]]"
		log_world("Babylon restore: removed saved copies of objects the world makes itself: [parts.Join(", ")].")
	return removed

/// Once the world finished initializing after a restore (both builds' boot, before ready): what
/// the load made anew on top of the save that the companion rule cannot see (made outside an
/// Initialize: a LateInitialize, a subsystem, a timer): an unsaved object of the same type on the
/// same tile as a saved one is a regenerated copy, and the saved one, with its state, stays.
/// Restricted to objects without a save id that are no companions, on saved levels.
/datum/babylon_save/proc/remove_regenerated_copies()
	if(!length(restored_atoms))
		return 0
	var/list/saved_here = list()
	for(var/id in restored_atoms)
		var/atom/movable/saved = restored_atoms[id]
		if(istype(saved) && !QDELETED(saved) && isturf(saved.loc))
			saved_here["[saved.type]|[saved.x]|[saved.y]|[saved.z]"] = TRUE
	var/list/levels = persisted_levels()
	var/list/removed = list()
	for(var/atom/movable/thing in world)
		if(thing.babylon_save_id || !isturf(thing.loc) || !(thing.z in levels))
			continue
		if(!saved_here["[thing.type]|[thing.x]|[thing.y]|[thing.z]"] || thing.babylon_is_companion())
			continue
		if(ismob(thing))
			var/mob/creature = thing
			if(creature.client || creature.mind)
				continue
		removed["[thing.type]"] = (removed["[thing.type]"] || 0) + 1
		qdel(thing)
		CHECK_TICK
	if(length(removed))
		var/list/parts = list()
		for(var/kind in removed)
			parts += "[kind] x[removed[kind]]"
		log_world("Babylon restore: removed objects the load made again over saved ones: [parts.Join(", ")].")
	return removed

/// Applies what a restore or paste wrote into this atom's variables. fields: the saved fields.
/atom/proc/babylon_after_restore(list/fields)
	return

// Dirt: upstream dirties a third of all mapped floors (more in ruins); a saved level already has
// its dirt as saved objects, and each restart added a new layer (about 400 decals on Babylon).
/turf/open/floor/MakeDirty()
	if(babylon_loading_saved_map())
		return
	// Made once, on a fresh map, never again on a load: saved like anything else, not a companion.
	// No try (see InitAtom above): a runtime inside ends only the failing proc and returns here.
	SSatoms.babylon_fresh_map_only++
	. = ..()
	SSatoms.babylon_fresh_map_only--

// Station traits: every start rolled new ones, also in a resumed world, and the ones that change the
// map (a wallet in a locker, the nebula's closet swap) changed the saved world on each restart.
// Their effects on the map are in the save; they are rolled on a fresh map only.
/datum/controller/subsystem/processing/station/SetupTraits()
	if(babylon_world_resumes_save())
		log_world("Station traits skipped: this world resumes a save.")
		return
	return ..()

/// A mech's saved equipment comes back as plain contents (the equipment its Initialize made is
/// removed above when it was not saved): it is attached again, to a free arm for arm equipment.
/obj/vehicle/sealed/mecha/babylon_after_restore(list/fields)
	. = ..()
	for(var/obj/item/mecha_parts/mecha_equipment/equipment in contents)
		if(equipment in flat_equipment)
			continue
		if(equipment.can_attach(src, FALSE))
			equipment.attach(src, FALSE)
		else if(equipment.can_attach(src, TRUE))
			equipment.attach(src, TRUE)

// Skyrat's decay: at round start it dirties floors, breaks tiles, rusts walls and puts webs and
// rat or spider nests into maintenance. A saved world keeps its own decay; decaying it again on
// every restart piled up dirt, webs and nests.
/datum/controller/subsystem/decay/Initialize()
	if(babylon_world_resumes_save())
		log_world("SSDecay skipped: this world resumes a save.")
		return SS_INIT_NO_NEED
	return ..()

// Skyrat's area spawns: at round start they place extra machines, pets, job start points and the
// like on random free tiles. A saved world has them saved where they were; placing them again
// put a new set elsewhere on every restart.
/datum/controller/subsystem/area_spawn/Initialize()
	if(babylon_world_resumes_save())
		log_world("Area spawns skipped: this world resumes a save.")
		return SS_INIT_NO_NEED
	return ..()

// Emergency closets: upstream deletes 1% of them as they initialize; a saved one stays. (The
// radiation-nebula swap happens before the closet initializes and is left alone.)
/obj/structure/closet/emcloset/Initialize(mapload)
	. = ..()
	if(. == INITIALIZE_HINT_QDEL && (flags_1 & INITIALIZED_1) && mapload && babylon_loading_saved_map())
		return INITIALIZE_HINT_NORMAL

// Disposal bins: upstream hides an animal in some mapped bins; a saved bin keeps what it held.
/obj/machinery/disposal/bin/spawn_contained_animal()
	if(babylon_loading_saved_map())
		return
	return ..()

// MULEbots: upstream swaps 0.7% of mapped MULEbots for a paranormal one; a saved bot stays itself.
/mob/living/basic/bot/mulebot/Initialize(mapload)
	if(mapload && babylon_loading_saved_map())
		replacement_chance = 0
	return ..()

// Lights: upstream breaks 2% of tubes and 5% of bulbs of every mapped light; a saved light keeps
// its saved status (working, empty, broken, burned out) instead.
/obj/machinery/light/Initialize(mapload)
	if(mapload && babylon_loading_saved_map())
		allow_break_on_init = FALSE
	return ..()

/obj/machinery/light/babylon_after_restore(list/fields)
	// Its backup cell came back as a saved child (and its saved cell reference), but the light
	// still holds the mock flag of a fresh light, so update() (get_cell()) would replace it with a
	// second cell on every restart.
	if(!cell)
		cell = locate(/obj/item/stock_parts/power_store) in contents
	if(cell)
		has_mock_cell = FALSE
	update(trigger = FALSE)

// Cameras: upstream switches 3% of mapped station cameras off; a saved camera keeps its saved
// on/off state.
/obj/machinery/camera/Initialize(mapload)
	var/was_start_active = start_active
	if(mapload && babylon_loading_saved_map())
		start_active = TRUE
	. = ..()
	start_active = was_start_active

/obj/machinery/camera/babylon_after_restore(list/fields)
	// It initialized switched on; the saved value was written over the variable only.
	if(!camera_enabled)
		camera_enabled = TRUE
		toggle_cam(null, FALSE)

// Fire and air alarms: a mapped alarm starts fully built; the saved buildstage (with panel_open, a
// state field) takes over, and the generic update_appearance shows it.

// Bots: upstream enables ghost possession on every mapped station bot (_bots.dm). A restored bot
// takes the saved can_be_possessed instead: on only if a player had switched its personality on
// (or it was a mapped bot that still had it on). Saves from before the field was kept leave it off.
/mob/living/basic/bot/babylon_after_restore(list/fields)
	var/wanted = ("can_be_possessed" in fields) ? !!GLOB.babylon_save.decode_value(fields["can_be_possessed"]) : FALSE
	var/datum/component/ghost_direct_control/control = GetComponent(/datum/component/ghost_direct_control)
	if(wanted && !control && (bot_mode_flags & BOT_MODE_CAN_BE_SAPIENT))
		enable_possession(mapload = TRUE)
	else if(!wanted)
		can_be_possessed = FALSE
		// No longer offered in the ghosts' joinable mob list either.
		qdel(control)

/// Adds what a plain variable cannot carry to an atom's saved fields (a save's record fields and an
/// area-tool copy's settings: the one path for both), for its babylon_after_restore() to apply.
/atom/proc/babylon_capture_settings(list/fields)
	return

// ID cards: a card made from its type has its type's trim and access (often none: a captain's gold
// card gets its trim from the outfit). The trim is a singleton datum, kept by type; access, holder
// and assignment are typed_fields; its bank account is the holder's (characters).
/obj/item/card/id/babylon_capture_settings(list/fields)
	if(trim)
		fields["babylon_trim"] = "[trim.type]"

/// The saved access, holder and assignment were written over the variables already (a restore
/// and a paste both do that first). The saved trim goes back on, and the access is split again into
/// the trim's own accesses and wildcards, so the card's wildcard slots count them.
/obj/item/card/id/babylon_after_restore(list/fields)
	var/trim_path = fields["babylon_trim"]
	if(istext(trim_path))
		trim_path = text2path(trim_path)
	var/list/saved_access = islist(access) ? access.Copy() : list()
	var/saved_assignment = assignment
	if(ispath(trim_path, /datum/id_trim) && SSid_access.trim_singletons_by_path[trim_path] && SSid_access.apply_trim_to_card(src, trim_path, copy_access = FALSE))
		var/datum/id_trim/applied = trim
		access = saved_access & applied.access
		add_wildcards(saved_access - applied.access, mode = FORCE_ADD_ALL)
	else
		access = saved_access
	if("assignment" in fields)
		assignment = saved_assignment
	update_label()
	update_icon()

/datum/babylon_save/proc/restore_cycle_pump(obj/machinery/atmospherics/components/unary/airlock_pump/pump, list/record)
	var/list/settings = record["cycle_settings"]
	if(settings)
		for(var/field in settings)
			pump.vars[field] = decode_value(settings[field])
		pump.internal_airlocks = decode_value(record["cycle_internal"]) || list()
		pump.external_airlocks = decode_value(record["cycle_external"]) || list()
	else
		// Older checkpoints lack pump settings. Find the existing pair without
		// closing the outer/opening the inner door as if installing a new pump.
		var/perpendicular_dirs = NSCOMPONENT(pump.dir) ? WEST|EAST : NORTH|SOUTH
		pump.internal_airlocks = pump.get_adjacent_airlocks(pump.find_density(get_turf(pump), pump.dir), perpendicular_dirs)
		pump.external_airlocks = pump.get_adjacent_airlocks(pump.find_density(get_turf(pump), REVERSE_DIR(pump.dir)), perpendicular_dirs)
		if(!length(pump.internal_airlocks))
			for(var/obj/machinery/door/airlock/door as anything in pump.external_airlocks)
				pump.internal_airlocks |= door.close_others
			pump.internal_airlocks -= pump.external_airlocks
		if(!length(pump.external_airlocks))
			for(var/obj/machinery/door/airlock/door as anything in pump.internal_airlocks)
				pump.external_airlocks |= door.close_others
			pump.external_airlocks -= pump.internal_airlocks
		pump.cycling_set_up = length(pump.internal_airlocks) && length(pump.external_airlocks)
		// The original Babylon wreck has no airlock pumps. Legacy pumps were
		// player-built; map loading incorrectly made them permanently secured.
		pump.can_unwrench = TRUE
		migration_notes |= "Recovered removable player-built airlock pump from legacy save."
	for(var/obj/machinery/door/airlock/door as anything in (pump.internal_airlocks + pump.external_airlocks))
		door.set_cycle_pump(pump)
		pump.RegisterSignal(door, COMSIG_QDELETING, TYPE_PROC_REF(/obj/machinery/atmospherics/components/unary/airlock_pump, unlink_airlock))
	pump.airlocks_animating = FALSE
	pump.check_turfs()
	if(pump.on && pump.cycling_set_up)
		if(isnull(pump.cycle_pressure_target))
			pump.cycle_pressure_target = pump.pump_direction == ATMOS_DIRECTION_RELEASING ? pump.internal_pressure_target : pump.external_pressure_target
		pump.emergency_stop_timer = addtimer(CALLBACK(pump, TYPE_PROC_REF(/obj/machinery/atmospherics/components/unary/airlock_pump, emergency_stop)), record["cycle_remaining"] || pump.cycle_timeout, TIMER_STOPPABLE|TIMER_UNIQUE|TIMER_OVERRIDE|TIMER_DELETE_ME)
	pump.update_appearance()

/datum/babylon_save/proc/restore_airlock_configuration(list/state)
	var/list/doors = list()
	for(var/list/record as anything in state["records"])
		var/obj/machinery/door/airlock/door = restored_atoms[record["id"]]
		if(istype(door))
			doors += door
	for(var/obj/machinery/door/airlock/door as anything in doors)
		if(door.closeOtherId)
			door.close_others = list()
		var/obj/item/electronics/airlock/electronics = door.electronics
		if(!electronics)
			continue
		var/list/fields = resume_records[electronics.babylon_save_id]?["fields"]
		// Old running builds already save the effective door name, access,
		// and group; infer missing board settings from that completed door.
		if(!fields || !("passed_name" in fields))
			electronics.passed_name = door.name
		if(!fields || !("passed_cycle_id" in fields))
			electronics.passed_cycle_id = door.closeOtherId
		if(!fields || !("one_access" in fields))
			electronics.one_access = !!length(door.req_one_access)
			electronics.accesses = electronics.one_access ? door.req_one_access.Copy() : (door.req_access?.Copy() || list())
		if(!fields || !("unres_sides" in fields))
			electronics.unres_sides = door.unres_sides
	for(var/obj/machinery/door/airlock/door as anything in doors)
		if(door.closeOtherId)
			door.update_other_id()
		if(door.cyclelinkeddir && !door.cyclelinkedairlock)
			door.cyclelinkairlock()

/datum/babylon_save/proc/recover_legacy(atom/thing, list/record)
	if(istype(thing, /obj/machinery/power/emitter))
		var/obj/machinery/power/emitter/emitter = thing
		emitter.active = FALSE
	if(istype(thing, /obj/machinery/power/supermatter_crystal))
		var/obj/machinery/power/supermatter_crystal/crystal = thing
		crystal.internal_energy = 0
		migration_notes |= "Legacy save did not contain crystal energy or emitter on/off state. Reactor recovered shut down."
	if(istype(thing, /obj/machinery/atmospherics/components/trinary/filter))
		var/obj/machinery/atmospherics/components/trinary/filter/filter = thing
		var/list/airs = record["device_airs"]
		if(length(airs) >= 2 && istext(airs[2]))
			var/datum/gas_mixture/output = SSair.parse_gas_string(airs[2])
			var/dominant
			var/highest = 0
			for(var/gas_type, amount in output.moles)
				if(amount > highest)
					highest = amount
					dominant = gas_type
			if(dominant)
				filter.filter_type = list(dominant)
				migration_notes |= "Legacy filter selections recovered from their saved output gases; verify before reactor startup."

/// A machine frame's construction progress: the parts put in (objects, which are also saved
/// as its contents, and stock parts, which are kept only as their type) and what it still needs.
/datum/babylon_save/proc/capture_machine_frame(obj/structure/frame/machine/frame, list/record)
	if(isnull(frame.components) && isnull(frame.req_components))
		return
	var/list/parts = list()
	for(var/part in frame.components)
		if(istype(part, /datum/stock_part))
			var/datum/stock_part/stock_part = part
			parts += list(list("stock_part" = "[stock_part.type]"))
		else if(isatom(part))
			parts += list(encode_value(part))
	record["frame_parts"] = parts
	var/list/required = list()
	for(var/path in frame.req_components)
		required["[path]"] = frame.req_components[path]
	record["frame_required"] = required

/// Rebuilds the frame's part lists from its board and the saved progress. Without them a
/// frame with a board installed could neither be finished nor emptied.
/datum/babylon_save/proc/restore_machine_frame(obj/structure/frame/machine/frame, list/record, list/used_children)
	var/obj/item/circuitboard/machine/board = frame.circuit
	if(!istype(board) || board.loc != frame)
		frame.components = null
		frame.req_components = null
		frame.req_component_names = null
		if(frame.state == FRAME_STATE_BOARD_INSTALLED)
			frame.state = FRAME_STATE_WIRED
			frame.update_appearance(UPDATE_ICON_STATE)
		return
	frame.circuit_added(board) // The board as the first part and all the parts it needs.
	var/list/required = record["frame_required"]
	if(islist(required))
		for(var/path_text in required)
			var/path = text2path(path_text)
			if(path && !isnull(frame.req_components[path]) && isnum(required[path_text]))
				frame.req_components[path] = max(0, required[path_text])
		for(var/list/part as anything in record["frame_parts"])
			if(part["stock_part"])
				var/datum/stock_part/stock_part = GLOB.stock_part_datums[text2path(part["stock_part"])]
				if(stock_part)
					frame.components += stock_part
				continue
			var/atom/movable/inserted = decode_value(part)
			if(inserted && inserted != board && inserted.loc == frame)
				frame.components |= inserted
		return
	// Older saves kept only the board and the parts that stay objects; stock parts and stacks
	// already put in are lost and have to be added again.
	for(var/obj/item/inserted in frame.contents)
		if(inserted == board || !(inserted in used_children))
			continue
		for(var/path in frame.req_components)
			if(frame.req_components[path] > 0 && ispath(path, /obj/item) && istype(inserted, path))
				frame.components += inserted
				frame.req_components[path]--
				break
	migration_notes |= "Machine frames from older saves keep their circuit board; stock parts already put into them have to be added again."

/// Reflectors: the saved angle and rotation lock are set before Initialize (structural fields).
/// Initialize turns the mirror to rotation_angle only while it can rotate, so a reflector
/// locked with a screwdriver would keep its angle but show the mirror unturned.
/obj/structure/reflector/Initialize(mapload)
	var/locked = !can_rotate
	can_rotate = TRUE
	. = ..()
	if(locked)
		can_rotate = FALSE
