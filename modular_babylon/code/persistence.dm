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
		for(var/field in state_fields | extra_fields | structural_fields)
			if(field in thing.vars)
				capture_fields += field
		capture_fields_by_type[thing.type] = capture_fields
	for(var/field in capture_fields)
		var/value = thing.vars[field]
		if(babylon_save_keeps_default_text(thing, field, value))
			continue
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

/datum/babylon_save/proc/metadata(atom/thing, is_turf = FALSE, with_id = TRUE)
	var/list/entries = list()
	var/list/fields = metadata_fields_by_type[thing.type]
	if(isnull(fields))
		fields = list()
		for(var/field in structural_fields | map_link_fields | type_metadata_fields(thing))
			if(field in thing.vars)
				fields += field
		metadata_fields_by_type[thing.type] = fields
	if(!is_turf && with_id)
		entries += "babylon_save_id = \"[assign_id(thing)]\""
	// Most turfs keep their type's values: their entry depends only on the type and the air,
	// and is built once per save (whole levels of rock and snow were most of a save's time).
	var/turf_key
	if(is_turf)
		turf_key = "[thing.type]"
		for(var/field in fields)
			if(thing.vars[field] != initial(thing.vars[field]))
				turf_key = null
				break
		if(turf_key)
			if(isopenturf(thing) && !isspaceturf(thing))
				turf_key += "|[saved_gas_mix(thing)]"
			if(turf_metadata_cache[turf_key])
				return turf_metadata_cache[turf_key]
	for(var/field in fields)
		var/value = thing.vars[field]
		if(babylon_save_keeps_default_text(thing, field, value))
			continue
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

/// Saves a checkpoint. Worlds that are not saved (babylon_world_saves()) refuse unless forced
/// (a tutorial's save back to its pending copy).
/datum/babylon_save/proc/save_world(force = FALSE)
	// After a round's end nothing is saved: the next start resumes the last save from before it.
	if(round_ending)
		return list("error" = "The round is over; this world is not saved again")
	if(!force && !babylon_world_saves())
		return list("error" = "This world is not saved")
	if(!ready || busy)
		return list("error" = "Babylon is not ready or a save is in progress")
	busy = TRUE
	before_checkpoint()
	// The chat subsystem stops with the master: these messages go out at once.
	to_chat_immediate(world, span_notice("Saving... the world is paused for about [estimated_pause_seconds()] seconds."))
	checkpoint_processing = Master.processing
	checkpoint_started = REALTIMEOFDAY
	Master.processing = FALSE
	checkpoint_hold(TRUE)
	sleep(1 TICKS)
	var/list/result
	try
		result = save_world_impl()
	catch(var/exception/error)
		result = list("error" = "Checkpoint failed: [error]")
		log_world("BABYLON SAVE ERROR: [error]")
	if(!result["ok"] && draining)
		draining = FALSE
	release_checkpoint()
	busy = FALSE
	if(result["ok"])
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

/// This world saves checkpoints: it is persistent (the world's setting) and not a tutorial
/// instance, which only lives while it runs. Other worlds never autosave, hide their save verbs
/// and stop without a save.
/proc/babylon_world_saves()
	return babylon_persistence_enabled() && !GLOB.babylon_world?.is_tutorial()

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
	autosave_notices = list()
	var/remaining = 30
	for(var/seconds_left in list(30, 10, 5, 1))
		if(remaining > seconds_left)
			sleep((remaining - seconds_left) SECONDS)
		if(!allow_unoccupied && !length(GLOB.clients))
			autosave_countdown_active = FALSE
			return
		var/message = seconds_left == 1 ? "Babylon autosave now: the world pauses for about [estimated_pause_seconds()] seconds." : "Babylon autosave in [seconds_left] seconds; the world pauses for about [estimated_pause_seconds()] seconds."
		autosave_notices += list(list("remaining" = seconds_left, "at" = world.time, "message" = message))
		to_chat(world, span_notice(message))
		remaining = seconds_left
	// Give the client a full second to receive/render "now" before freezing.
	sleep(1 SECONDS)
	if((allow_unoccupied || length(GLOB.clients)) && !busy)
		save_world()
	autosave_countdown_active = FALSE

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
/datum/babylon_save/proc/capture_session_state(list/state)
	return

/// Restores what capture_session_state saved, once every saved object exists again.
/datum/babylon_save/proc/restore_session_state(list/state)
	return

/// state.json "version" this build's checkpoints are written in. Babylon: BABYLON_STATE_VERSION
/// (one map.dmm, records without z). The station build overrides it (BABYLON_STATION_STATE_VERSION).
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

/// The map file a saved level is written to inside its generation directory.
/datum/babylon_save/proc/level_file(z)
	return save_format_version() < BABYLON_STATION_STATE_VERSION ? "map.dmm" : "z[z].dmm"

/// Saves one z-level: list("map_text" = its .dmm (a single-level TGM map), "records" = saved
/// objects (state.json "records"), "turfs" = room air and temperature (state.json "turfs")).
/// Records and turfs carry their z from BABYLON_STATION_STATE_VERSION on; Babylon's do not.
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
			for(var/obj/object in tile)
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
			for(var/mob/living/saved_mob as anything in mobs_by_turf[tile])
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
	if(save_format_version() >= BABYLON_STATION_STATE_VERSION)
		for(var/list/record as anything in records)
			record["z"] = z
		for(var/list/turf_data as anything in turfs)
			turf_data["z"] = z
	return list("map_text" = "//[DMM2TGM_MESSAGE]\n[headers.Join()][grid.Join()]", "records" = records, "turfs" = turfs)

/datum/babylon_save/proc/save_world_impl()
	var/list/levels = persisted_levels()
	// Which levels changed is taken now, while the world is paused (changes from here on count
	// for the next save).
	begin_level_capture()
	// z (as text) -> the level's map text, records and turf records (levels captured now)
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
		level_maps["[z]"] = level["map_text"]
	turf_metadata_cache = list()
	var/generation = "save-[time2text(world.realtime, "YYYYMMDD-hhmmss")]-[++save_count]"
	var/base = "data/babylon/saves/[generation]"
	// 7: non-item contents of closets and crates are saved (restore_lost_supermatter()).
	// "records" and "turfs" are spliced in as JSON below, level by level.
	var/list/state = list("version" = save_format_version(), "generation" = generation, "next_id" = next_id, "save_count" = save_count, "records" = "@babylon-records@", "turfs" = "@babylon-turfs@")
	capture_session_state(state)
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
	for(var/z_text in level_maps)
		bytes += length(level_maps[z_text])
		rustg_file_write(level_maps[z_text], "[base]/[level_file(text2num(z_text))]")
	for(var/z_text in reused_levels)
		var/file_name = level_file(text2num(z_text))
		fcopy("data/babylon/saves/[reused_levels[z_text]]/[file_name]", "[base]/[file_name]")
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
	fdel("[base]/state.json")
	var/state_bytes = 0
	var/append_error
	for(var/piece in pieces)
		state_bytes += length(piece)
		// rust-g answers an error text when a write fails; one failed piece fails the save.
		var/append_result = rustg_file_append(piece, "[base]/state.json")
		if(append_result && !append_error)
			append_error = "[append_result]"
		CHECK_TICK
	bytes += state_bytes
	var/state_file_size = fexists("[base]/state.json") ? length(file("[base]/state.json")) : 0
	// latest.json is committed only after every generation file is present and state.json was
	// written whole: every append succeeded and the file is as long as its text. The text is
	// pure ASCII (json_encode escapes everything else), so the two are equal, but DM numbers
	// are 32-bit floats: past 16 MB (2^24) every length, sum and file size is rounded to a few
	// bytes. That rounding was the "+8 to 12 bytes" of a 40 to 50 MB state.json. The tolerance
	// is twice its worst case: half a float step per piece added and for the file size.
	var/size_matches = babylon_written_size_matches(state_file_size, state_bytes, length(pieces))
	if(!size_matches)
		log_world("Babylon save [generation]: state.json is [num2text(state_file_size, 12)] bytes on disk for [num2text(state_bytes, 12)] bytes of text in [length(pieces)] pieces.")
		log_non_ascii_text(pieces, generation)
	var/complete = !append_error && size_matches
	if(append_error)
		log_world("Babylon save [generation]: writing state.json failed: [append_error]")
	for(var/z in levels)
		if(!fexists("[base]/[level_file(z)]"))
			complete = FALSE
	if(!complete)
		busy = FALSE
		return list("error" = "Save files could not be written")
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
		// world's lockers refilled on every restart.
		if(istype(thing, /obj/item) || istype(thing, /obj/machinery) || istype(thing, /obj/structure) || istype(thing, /mob/living/basic/drone))
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
		for(var/field in list("layer", "plane", "pixel_x", "pixel_y", "pixel_z", "alpha"))
			if((field in record["fields"]) && (field in thing.vars))
				thing.vars[field] = decode_value(record["fields"][field])
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
	play_time = isnum(state["play_time"]) ? state["play_time"] : 0
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
