// Tutorial objects: the hidden building blocks of a tutorial (spec 7.2). Builders place and
// configure them with the tutorial wand (wand.dm); the runtime (runtime.dm) plays them.
//
// Every object is an /obj (not an /obj/effect: persistence skips effects), anchored,
// indestructible, never dense and invisible to everyone (INVISIBILITY_ABSTRACT, no mouse). Only a
// player holding the tutorial wand sees them, as client images (wand.dm). The tutorial button is
// the one exception: players press it, so it is a visible, clickable object.
//
// An object's settings live in `settings_json` (a JSON object) and its id in `tutorial_id`; both
// are persisted (extra_fields) and exported with the map (get_save_vars). Each subtype describes
// its settings with settings_schema(): the configure window (BabylonTutorialObject.tsx) is built
// from that schema and every value is validated on the server by babylon_tutorial_clean_value().

/// Every tutorial object in the world.
GLOBAL_LIST_EMPTY(babylon_tutorial_objects)
/// Bumped whenever a tutorial object appears, disappears or changes: wand views rebuild on it.
GLOBAL_VAR_INIT(babylon_tutorial_version, 0)

#define BABYLON_TUTORIAL_ID_MAX 32
#define BABYLON_TUTORIAL_TEXT_MAX 200
#define BABYLON_TUTORIAL_LONGTEXT_MAX 1000
#define BABYLON_TUTORIAL_IDLIST_MAX 20
#define BABYLON_TUTORIAL_EFFECTS_MAX 12

/datum/babylon_save/New()
	. = ..()
	extra_fields |= list("tutorial_id", "settings_json")

/obj/babylon_tutorial
	name = "tutorial object"
	desc = "A hidden part of a tutorial."
	icon = 'icons/effects/landmarks_static.dmi'
	icon_state = "x"
	invisibility = INVISIBILITY_ABSTRACT
	mouse_opacity = MOUSE_OPACITY_TRANSPARENT
	anchored = TRUE
	density = FALSE
	move_resist = INFINITY
	resistance_flags = INDESTRUCTIBLE | LAVA_PROOF | FIRE_PROOF | UNACIDABLE | ACID_PROOF | FREEZE_PROOF
	/// The object's id: triggers, actions and other objects refer to it by this.
	var/tutorial_id
	/// The object's settings as a JSON object (see settings_schema()).
	var/settings_json
	/// Short key of this kind ("zone", "message" ...), unique per subtype; null on abstract types.
	var/tutorial_kind
	/// "trigger", "action", "marker" or "npc".
	var/tutorial_category
	/// Shown in the wand's palette and the configure window.
	var/kind_name = "Tutorial object"
	/// One line telling builders what this object does.
	var/kind_desc = ""
	/// An example use, for the wand's palette ("e.g. ...").
	var/kind_example = ""
	/// What the id is for, under the id field.
	var/id_help = "Other parts refer to this object by its id."
	/// Font Awesome icon for the tgui windows.
	var/ui_icon = "circle"
	/// The image a wand holder sees.
	var/view_icon = 'icons/effects/landmarks_static.dmi'
	var/view_state = "x"
	/// Decoded settings_json, and the JSON it was decoded from.
	var/list/settings_cache
	var/settings_cache_json
	/// issues() cached: the result, and the tutorial version and time it was computed at.
	var/list/issues_cache
	var/issues_version = -1
	var/issues_time = -1

/obj/babylon_tutorial/Initialize(mapload)
	. = ..()
	// Nowhere: a sample made to read the schema (babylon_tutorial_schema), not a placed object.
	if(isnull(loc))
		return
	GLOB.babylon_tutorial_objects += src
	if(!babylon_tutorial_valid_id(tutorial_id))
		tutorial_id = babylon_tutorial_unique_id(tutorial_kind || "object")
	babylon_tutorial_changed()

/obj/babylon_tutorial/Destroy()
	GLOB.babylon_tutorial_objects -= src
	// No run may keep a reference to a removed object (runtime.dm).
	for(var/datum/babylon_tutorial_run/run as anything in GLOB.babylon_tutorial_runs)
		run.forget(src)
	// Nor a builder's hidden list (wand.dm).
	babylon_tutorial_forget_hidden(src)
	babylon_tutorial_changed()
	return ..()

/obj/babylon_tutorial/get_save_vars()
	. = ..()
	. += NAMEOF(src, tutorial_id)
	. += NAMEOF(src, settings_json)
	return .

/obj/babylon_tutorial/ex_act(severity, target)
	return FALSE

/obj/babylon_tutorial/singularity_pull(atom/singularity, current_size)
	return

/obj/babylon_tutorial/singularity_act()
	return 0

/obj/babylon_tutorial/zap_act(power, zap_flags)
	return 0

/// The settings, decoded (cached until settings_json changes, also when persistence restores it).
/obj/babylon_tutorial/proc/settings()
	if(isnull(settings_cache) || settings_cache_json != settings_json)
		settings_cache_json = settings_json
		var/list/decoded = length(settings_json) ? safe_json_decode(settings_json) : null
		settings_cache = islist(decoded) ? decoded : list()
	return settings_cache

/// One setting, or its schema default when it was never set.
/obj/babylon_tutorial/proc/setting(key)
	var/list/values = settings()
	if(!isnull(values[key]))
		return values[key]
	var/list/field = babylon_tutorial_schema_field(type, key)
	return field?["default"]

/// Validates and stores one setting. Null on success, else why it was refused.
/obj/babylon_tutorial/proc/set_setting(key, value)
	if(key == "id")
		return set_tutorial_id(value)
	var/list/field = babylon_tutorial_schema_field(type, key)
	if(!field)
		return "Unknown setting."
	var/list/cleaned = babylon_tutorial_clean_value(field, value)
	if(cleaned["error"])
		return cleaned["error"]
	var/list/values = settings().Copy()
	values[key] = cleaned["value"]
	store_settings(values)
	return null

/// Writes settings back to settings_json (only keys the schema knows).
/obj/babylon_tutorial/proc/store_settings(list/values)
	var/list/kept = list()
	for(var/list/field as anything in babylon_tutorial_schema(type))
		var/key = field["key"]
		if(!isnull(values[key]))
			kept[key] = values[key]
	settings_json = json_encode(kept)
	settings_cache = kept
	settings_cache_json = settings_json
	settings_changed()
	babylon_tutorial_changed()

/// Called on an object an area paste (or undo) just made from a copy: a note for the builder about
/// what it could not keep, or null.
/obj/babylon_tutorial/proc/after_area_paste()
	return null

/// Called after the settings changed (subtypes refresh themselves).
/obj/babylon_tutorial/proc/settings_changed()
	return

/// Gives the object a new id. Ids in other objects' settings that referred to the old one are
/// rewritten (unless another object still has the old id). Null on success, else why not;
/// last_rename_links lists the objects whose links were updated.
/obj/babylon_tutorial/proc/set_tutorial_id(value)
	value = trim("[value]")
	if(value == tutorial_id)
		last_rename_links = list()
		return null
	if(!babylon_tutorial_valid_id(value))
		return "Ids use letters, digits, _ and - only (at most [BABYLON_TUTORIAL_ID_MAX] characters)."
	var/obj/babylon_tutorial/taken = babylon_tutorial_find(value)
	if(taken && taken != src)
		return "\"[value]\" is already used by a [taken.kind_name]. Pick another id."
	var/old_id = tutorial_id
	tutorial_id = value
	last_rename_links = list()
	var/obj/babylon_tutorial/twin = babylon_tutorial_find(old_id)
	if(old_id && !twin)
		var/list/changed = babylon_tutorial_rewrite_links(old_id, value)
		if(isnull(changed))
			// A link could not be rewritten: keep the old id, nothing changed.
			tutorial_id = old_id
			return "The links to [old_id] could not be updated; the id was not changed."
		last_rename_links = changed
	babylon_tutorial_changed()
	return null

/obj/babylon_tutorial
	/// Ids of the objects whose links the last set_tutorial_id() rewrote.
	var/list/last_rename_links = list()

/// Replaces an id in every setting that links to other objects. Returns the ids of the objects
/// changed.
/proc/babylon_tutorial_rewrite_links(old_id, new_id)
	var/list/changed = list()
	var/list/pending = list()
	var/list/rename = list()
	rename[old_id] = new_id
	for(var/obj/babylon_tutorial/object as anything in GLOB.babylon_tutorial_objects)
		var/list/values = object.settings().Copy()
		var/touched = FALSE
		for(var/list/field as anything in babylon_tutorial_schema(object.type))
			var/key = field["key"]
			if(!babylon_tutorial_links_field(field) || !(old_id in babylon_tutorial_value_ids(field, values[key])))
				continue
			values[key] = babylon_tutorial_value_renamed(field, values[key], rename)
			touched = TRUE
		if(touched)
			pending[object] = values
	// Every new value is a plain id swap, checked before anything is written: all or nothing.
	for(var/obj/babylon_tutorial/object as anything in pending)
		var/list/values = pending[object]
		for(var/list/field as anything in babylon_tutorial_schema(object.type))
			if(babylon_tutorial_links_field(field))
				var/list/cleaned = babylon_tutorial_clean_value(field, values[field["key"]])
				if(cleaned["error"])
					return null
	for(var/obj/babylon_tutorial/object as anything in pending)
		object.store_settings(pending[object])
		changed += object.tutorial_id
	return changed

/// Whether a field links to other tutorial objects by id. Every place that follows, checks or
/// rewrites links (references, issues, renames, pasted copies) goes through this and the two
/// procs below, so a new kind of link field only has to be taught here.
/proc/babylon_tutorial_links_field(list/field)
	return field["type"] in list("id", "idlist", "gateinputs")

/// The ids a setting value links to, in order, each once.
/proc/babylon_tutorial_value_ids(list/field, value)
	var/list/ids = list()
	switch(field["type"])
		if("id")
			if(istext(value) && length(value))
				ids += value
		if("idlist")
			if(islist(value))
				for(var/id in value)
					if(istext(id) && length(id))
						ids |= id
		if("gateinputs")
			if(islist(value))
				for(var/list/entry in value)
					for(var/key in list("id", "source"))
						var/id = entry[key]
						if(istext(id) && length(id))
							ids |= id
	return ids

/// A setting value with its links renamed: rename is old id => new id; other ids stay.
/proc/babylon_tutorial_value_renamed(list/field, value, list/rename)
	switch(field["type"])
		if("id")
			return istext(value) && rename[value] ? rename[value] : value
		if("idlist")
			if(!islist(value))
				return value
			var/list/renamed = list()
			for(var/id in value)
				renamed += (istext(id) && rename[id]) || id
			return renamed
		if("gateinputs")
			if(!islist(value))
				return value
			var/list/renamed = list()
			for(var/list/entry in value)
				var/list/copy = entry.Copy()
				for(var/key in list("id", "source"))
					var/id = copy[key]
					if(istext(id) && rename[id])
						copy[key] = rename[id]
				renamed += list(copy)
			return renamed
	return value

/// The fields of this kind's settings: a list of babylon_tutorial_field() lists.
/obj/babylon_tutorial/proc/settings_schema()
	return list()

/// The atom this object stands for when others refer to its id (a target, a speaker ...).
/obj/babylon_tutorial/proc/target_atom()
	return get_turf(src)

/// Short summary for the wand's overview.
/obj/babylon_tutorial/proc/summary()
	return kind_desc

/// Ids this object refers to: list(id = setting key).
/obj/babylon_tutorial/proc/references()
	var/list/refs = list()
	for(var/list/field as anything in babylon_tutorial_schema(type))
		if(!babylon_tutorial_field_active(src, field))
			continue
		if(!babylon_tutorial_links_field(field))
			continue
		var/key = field["key"]
		for(var/id in babylon_tutorial_value_ids(field, setting(key)))
			refs[id] = key
	return refs

/// Problems with this object's settings, for the configure window: list(field key = message).
/// Cached until the tutorial changes, and for at most a second (targets on tiles can change).
/obj/babylon_tutorial/proc/issues()
	if(issues_version == GLOB.babylon_tutorial_version && world.time < issues_time + 1 SECONDS && issues_cache)
		return issues_cache
	issues_cache = find_issues()
	issues_version = GLOB.babylon_tutorial_version
	issues_time = world.time
	return issues_cache

/obj/babylon_tutorial/proc/find_issues()
	var/list/found = list()
	var/count = 0
	for(var/obj/babylon_tutorial/other as anything in GLOB.babylon_tutorial_objects)
		if(other.tutorial_id == tutorial_id)
			count++
	if(count > 1)
		found["id"] = "Another tutorial object already uses the id \"[tutorial_id]\"."
	for(var/list/field as anything in babylon_tutorial_schema(type))
		if(!babylon_tutorial_field_active(src, field))
			continue
		if(!babylon_tutorial_links_field(field))
			continue
		var/key = field["key"]
		var/list/ids = babylon_tutorial_value_ids(field, setting(key))
		if(!length(ids) && field["required"])
			found[key] = field["type"] == "id" ? "Choose an id." : "Add at least one id."
		for(var/id in ids)
			var/obj/babylon_tutorial/other = babylon_tutorial_find(id)
			if(!other)
				found[key] = "Nothing has the id \"[id]\"."
				break
			var/list/allowed = field["filter"]
			if(length(allowed) && !(other.tutorial_category in allowed))
				found[key] = "\"[id]\" is a [lowertext(other.kind_name)], not a [english_list(allowed, and_text = " or ")]."
				break
	return found

// ---------------------------------------------------------------------------------------------
// Lookups

/// Ids: letters, digits, _ and -, 1 to BABYLON_TUTORIAL_ID_MAX characters.
/proc/babylon_tutorial_valid_id(value)
	if(!istext(value) || !length(value) || length(value) > BABYLON_TUTORIAL_ID_MAX)
		return FALSE
	var/static/regex/allowed = regex(@"^[A-Za-z0-9_-]+$")
	return allowed.Find(value) != 0

/// A fresh id: prefix plus the lowest free number ("zone1", "zone2" ...).
/proc/babylon_tutorial_unique_id(prefix)
	var/list/taken = list()
	for(var/obj/babylon_tutorial/other as anything in GLOB.babylon_tutorial_objects)
		taken[other.tutorial_id] = TRUE
	var/number = 1
	while(taken["[prefix][number]"])
		number++
	return "[prefix][number]"

/// The tutorial object with this id (the first one placed, if ids are duplicated).
/proc/babylon_tutorial_find(id)
	RETURN_TYPE(/obj/babylon_tutorial)
	if(!length(id))
		return null
	for(var/obj/babylon_tutorial/candidate as anything in GLOB.babylon_tutorial_objects)
		if(candidate.tutorial_id == id)
			return candidate
	return null

/// The atom an id stands for: a marker's object (or tile), a spawner's NPC, a button ...
/proc/babylon_tutorial_resolve(id)
	var/obj/babylon_tutorial/found = babylon_tutorial_find(id)
	return found?.target_atom()

/// Every tutorial object of a category ("trigger" ...), in placing order.
/proc/babylon_tutorial_objects_of(category)
	var/list/found = list()
	for(var/obj/babylon_tutorial/candidate as anything in GLOB.babylon_tutorial_objects)
		if(candidate.tutorial_category == category)
			found += candidate
	return found

/// Markers and NPC spawners by id, for the Creative panel's teleport list: id => object.
/proc/babylon_tutorial_marker_targets()
	var/list/targets = list()
	for(var/obj/babylon_tutorial/candidate as anything in GLOB.babylon_tutorial_objects)
		if(candidate.tutorial_category in list("marker", "npc"))
			if(!targets[candidate.tutorial_id])
				targets[candidate.tutorial_id] = candidate
	return targets

/// kind key => type path, for every placeable tutorial object.
/proc/babylon_tutorial_kinds()
	var/static/list/kinds
	if(!kinds)
		kinds = list()
		for(var/obj/babylon_tutorial/path as anything in subtypesof(/obj/babylon_tutorial))
			var/kind = initial(path.tutorial_kind)
			if(kind)
				kinds[kind] = path
	return kinds

/proc/babylon_tutorial_changed()
	GLOB.babylon_tutorial_version++

// ---------------------------------------------------------------------------------------------
// Settings schema

/// One settings field. type: text, longtext, number, bool, choice, typepath, id, idlist,
/// gateinputs (a number gate's inputs, gates.dm), zone, tile (one picked tile: list(x, y, z)),
/// effects, loadout (a stored inventory, inventory.dm), event (a round event the Creative panel
/// offers, world_actions.dm) or area_clip (a stored area, room_reset.dm: only the server stores
/// it, from the builder's world-edit selection; the window sees a summary). options:
/// list(list("value", "label")). filter: categories an id may refer to. when:
/// list(other key = list(values)) — the field applies only while that setting has one of them.
/// search (typepath and loadout fields): "creative" searches and allows what the Creative panel's
/// Spawn tab does (babylon_creative_search, babylon_creative_spawn_blocked); "any" allows every
/// type under base (removing things); null: the default tutorial rules (babylon_tutorial_type_allowed).
/proc/babylon_tutorial_field(key, label, type, default_value = null, help = "", list/options = null, min = null, max = null, list/filter = null, list/when = null, base = null, required = FALSE, placeholder = null, is_name = FALSE, max_tiles = null, input_modes = FALSE, search = null)
	var/list/field = list("key" = key, "label" = label, "type" = type, "default" = default_value, "help" = help)
	if(search)
		field["search"] = search
	if(input_modes)
		// Gate inputs: the window marks each trigger live, latched or gate.
		field["input_modes"] = TRUE
	if(is_name)
		field["name"] = TRUE
	if(max_tiles)
		field["max_tiles"] = max_tiles
	if(options)
		field["options"] = options
	if(!isnull(min))
		field["min"] = min
	if(!isnull(max))
		field["max"] = max
	if(filter)
		field["filter"] = filter
	if(when)
		field["when"] = when
	if(base)
		field["base"] = "[base]"
	if(required)
		field["required"] = TRUE
	if(placeholder)
		field["placeholder"] = placeholder
	return field

/// Choice options from value = label pairs.
/proc/babylon_tutorial_options(list/pairs)
	var/list/options = list()
	for(var/value in pairs)
		options += list(list("value" = "[value]", "label" = pairs[value]))
	return options

/// The schema of a tutorial object type (cached per type).
/proc/babylon_tutorial_schema(path)
	var/static/list/schemas = list()
	if(!schemas[path])
		// Placeholder first: the sample's own Initialize may read a setting.
		schemas[path] = list()
		var/obj/babylon_tutorial/sample = new path(null)
		schemas[path] = sample.settings_schema()
		qdel(sample)
	return schemas[path]

/proc/babylon_tutorial_schema_field(path, key)
	for(var/list/field as anything in babylon_tutorial_schema(path))
		if(field["key"] == key)
			return field
	return null

/// Whether a field applies with the object's current settings (its "when" condition).
/proc/babylon_tutorial_field_active(obj/babylon_tutorial/object, list/field)
	var/list/when = field["when"]
	for(var/key in when)
		if(!("[object.setting(key)]" in when[key]))
			return FALSE
	return TRUE

/// Cleans a value for a field: list("value" = clean value) or list("error" = why it was refused).
/proc/babylon_tutorial_clean_value(list/field, value)
	switch(field["type"])
		if("text", "longtext")
			var/limit = field["type"] == "text" ? BABYLON_TUTORIAL_TEXT_MAX : BABYLON_TUTORIAL_LONGTEXT_MAX
			value = isnull(value) ? "" : "[value]"
			if(field["type"] == "text")
				value = replacetext(replacetext(value, "\n", " "), ascii2text(13), "")
			value = trim(value)
			if(length_char(value) > limit)
				return list("error" = "At most [limit] characters.")
			if(field["name"])
				// Names end up in chat and on mobs: letters, digits, spaces and simple punctuation.
				var/clean_name = reject_bad_name(value, TRUE, 42, FALSE, FALSE, FALSE, FALSE)
				if(!clean_name)
					return list("error" = "Use a name of letters, digits, spaces and simple punctuation (at most 42 characters).")
				value = clean_name
			return list("value" = value)
		if("number")
			var/number = isnum(value) ? value : text2num("[value]")
			if(isnull(number))
				return list("error" = "Enter a number.")
			if(!isnull(field["min"]))
				number = max(number, field["min"])
			if(!isnull(field["max"]))
				number = min(number, field["max"])
			return list("value" = round(number, 0.1))
		if("bool")
			return list("value" = (value == TRUE || value == "1" || value == "true") ? 1 : 0)
		if("choice")
			for(var/list/option as anything in field["options"])
				if(option["value"] == "[value]")
					return list("value" = option["value"])
			return list("error" = "Choose one of the offered options.")
		if("typepath")
			if(!length("[value]"))
				return list("value" = "")
			var/path = text2path("[value]")
			var/base = text2path(field["base"])
			if(!path || (base && !ispath(path, base)))
				return list("error" = "Not a known type of this kind.")
			if(!babylon_tutorial_type_allowed(path, field))
				return list("error" = "That type can't be used in tutorials.")
			return list("value" = "[path]")
		if("id")
			value = trim("[isnull(value) ? "" : value]")
			if(length(value) && !babylon_tutorial_valid_id(value))
				return list("error" = "Ids use letters, digits, _ and - only.")
			return list("value" = value)
		if("idlist")
			var/list/raw = islist(value) ? value : splittext("[value]", ",")
			var/list/ids = list()
			for(var/entry in raw)
				entry = trim("[entry]")
				if(!length(entry))
					continue
				if(!babylon_tutorial_valid_id(entry))
					return list("error" = "\"[entry]\" is not a valid id.")
				ids |= entry
			if(length(ids) > BABYLON_TUTORIAL_IDLIST_MAX)
				return list("error" = "At most [BABYLON_TUTORIAL_IDLIST_MAX] ids.")
			return list("value" = ids)
		if("gateinputs")
			return babylon_tutorial_clean_gate_inputs(field, value)
		if("zone")
			if(!islist(value) || length(value) != 5)
				return list("error" = "A zone needs two corners.")
			var/list/numbers = list()
			for(var/entry in value)
				var/number = isnum(entry) ? entry : text2num("[entry]")
				if(isnull(number))
					return list("error" = "A zone needs two corners.")
				numbers += round(number)
			var/z = numbers[5]
			if(z < 1 || z > world.maxz)
				return list("error" = "That level is not part of this world.")
			var/x1 = clamp(min(numbers[1], numbers[3]), 1, world.maxx)
			var/x2 = clamp(max(numbers[1], numbers[3]), 1, world.maxx)
			var/y1 = clamp(min(numbers[2], numbers[4]), 1, world.maxy)
			var/y2 = clamp(max(numbers[2], numbers[4]), 1, world.maxy)
			var/tiles = (x2 - x1 + 1) * (y2 - y1 + 1)
			if(field["max_tiles"] && tiles > field["max_tiles"])
				return list("error" = "This zone can cover at most [field["max_tiles"]] tiles (that one has [tiles]). Pick smaller corners.")
			return list("value" = list(x1, y1, x2, y2, z))
		if("tile")
			if(!islist(value) || length(value) != 3)
				return list("error" = "Pick a tile.")
			var/list/numbers = list()
			for(var/entry in value)
				var/number = isnum(entry) ? entry : text2num("[entry]")
				if(isnull(number))
					return list("error" = "Pick a tile.")
				numbers += round(number)
			if(numbers[3] < 1 || numbers[3] > world.maxz)
				return list("error" = "That level is not part of this world.")
			return list("value" = list(clamp(numbers[1], 1, world.maxx), clamp(numbers[2], 1, world.maxy), numbers[3]))
		if("area_clip")
			if(!islist(value) || !length(value))
				return list("value" = null)
			var/problem = babylon_area_clip_data_problem(value)
			if(problem)
				return list("error" = problem)
			return list("value" = value)
		if("effects")
			return babylon_tutorial_clean_effects(value)
		if("loadout")
			return babylon_tutorial_clean_loadout(value)
		if("event")
			value = "[value]"
			if(!length(value))
				return list("value" = "")
			if(!babylon_creative_event_allowed(value))
				return list("error" = "That event can't be started from a tutorial (the Creative panel's Events tab lists the ones that can).")
			return list("value" = value)
		if("target")
			// A marker's target: "object" (the best thing on its tile), "tile" or a type on the tile.
			if(value == "object" || value == "tile")
				return list("value" = value)
			var/path = text2path("[value]")
			if(!ispath(path, /obj) && !ispath(path, /mob))
				return list("error" = "Choose something on the marker's tile.")
			return list("value" = "[path]")
	return list("error" = "Unknown setting type.")

/// Type paths a builder may pick for a typepath field.
/proc/babylon_tutorial_type_allowed(path, list/field)
	switch(field?["search"])
		if("creative")
			// Exactly what the Creative panel may spawn.
			return !babylon_creative_spawn_blocked(path)
		if("any")
			return TRUE
	if(ispath(path, /obj/item))
		// The Creative panel's spawn blocklist plus the creative disposal unit's extras
		// (grenades, bomb cores, transfer valves, brain holders): babylon_creative_item_allowed.
		if(!babylon_creative_item_allowed(path))
			return FALSE
	if(ispath(path, /datum/reagent))
		if(babylon_erp_reagents()[path])
			return FALSE
	if(ispath(path, /datum/outfit))
		return ispath(path, /datum/outfit/job)
	return TRUE

/// Up to 30 type paths under a field's base matching a search (name or path), for the window.
/proc/babylon_tutorial_search_types(list/field, query)
	var/list/results = list()
	var/base = text2path(field["base"])
	query = lowertext(trim("[query]"))
	if(!base || length(query) < 2)
		return results
	if(field["search"] == "creative")
		// The Creative panel's own search (aliases, ranking, "full"/"standard" hints), limited to base.
		var/list/answer = babylon_creative_search(query, "all")
		for(var/list/entry as anything in answer["results"])
			if(length(results) >= 30)
				break
			if(ispath(text2path(entry["path"]), base))
				results += list(list("path" = entry["path"], "name" = entry["name"], "hint" = entry["hint"]))
		return results
	for(var/path in subtypesof(base))
		if(length(results) >= 30)
			break
		var/name = babylon_tutorial_type_name(path)
		if(!findtext(lowertext(name), query) && !findtext("[path]", query))
			continue
		if(!babylon_tutorial_type_allowed(path, field))
			continue
		results += list(list("path" = "[path]", "name" = name))
	return results

/proc/babylon_tutorial_type_name(path)
	if(ispath(path, /atom))
		var/atom/atom_path = path
		return "[initial(atom_path.name)]"
	if(ispath(path, /datum/reagent))
		var/datum/reagent/reagent_path = path
		return "[initial(reagent_path.name)]"
	if(ispath(path, /datum/outfit))
		var/datum/outfit/outfit_path = path
		return "[initial(outfit_path.name)]"
	return "[path]"

/// Problems with the tutorial as a whole, for the wand's overview: list(list(text, ref)), ref
/// naming the object to open (or null). Every object's own issues are included. Cached until the
/// tutorial changes, for at most a second.
/proc/babylon_tutorial_overview_warnings()
	var/static/list/cached
	var/static/cached_version = -1
	var/static/cached_time = -1
	if(cached && cached_version == GLOB.babylon_tutorial_version && world.time < cached_time + 1 SECONDS)
		return cached
	var/list/warnings = list()
	var/obj/babylon_tutorial/start = babylon_tutorial_find("start")
	if(!istype(start, /obj/babylon_tutorial/marker))
		warnings += list(list("text" = "There is no marker with the id \"start\": players start at the arrivals instead.", "ref" = null))
	var/list/enabled_later = list()
	var/list/used_actions = list()
	for(var/obj/babylon_tutorial/object as anything in GLOB.babylon_tutorial_objects)
		var/list/issues = object.issues()
		for(var/key in issues)
			warnings += list(list("text" = "[object.tutorial_id]: [issues[key]]", "ref" = REF(object)))
		if(istype(object, /obj/babylon_tutorial/action/toggle) && object.setting("mode") == "enable")
			for(var/id in object.setting("triggers"))
				enabled_later[id] = object.tutorial_id
		if(object.tutorial_category == "trigger")
			if(object.setting("starts") == "after" && length(object.setting("after")))
				enabled_later[object.tutorial_id] = enabled_later[object.tutorial_id] || object.setting("after")
			var/obj/babylon_tutorial/trigger/trigger = object
			for(var/id in trigger.action_ids())
				used_actions[id] = TRUE
		if(object.tutorial_category == "action")
			var/obj/babylon_tutorial/action/action = object
			for(var/id in action.follow_up_ids())
				used_actions[id] = TRUE
	for(var/obj/babylon_tutorial/object as anything in GLOB.babylon_tutorial_objects)
		if(object.tutorial_category == "trigger")
			var/starts = object.setting("starts")
			if(starts == "start" && enabled_later[object.tutorial_id] && !istype(object, /obj/babylon_tutorial/trigger/start))
				warnings += list(list("text" = "Trigger [object.tutorial_id] listens from the beginning, but [enabled_later[object.tutorial_id]] also enables it later. Did you mean \"After [enabled_later[object.tutorial_id]] fired\"?", "ref" = REF(object)))
		if(object.tutorial_category == "action" && !used_actions[object.tutorial_id])
			warnings += list(list("text" = "Action [object.tutorial_id] is not used by any trigger.", "ref" = REF(object)))
	warnings += babylon_tutorial_reachability_warnings()
	var/has_complete = FALSE
	for(var/obj/babylon_tutorial/action/complete/complete in GLOB.babylon_tutorial_objects)
		has_complete = TRUE
	if(length(GLOB.babylon_tutorial_objects) && !has_complete)
		warnings += list(list("text" = "No Complete action: players never see the tutorial's end screen.", "ref" = null))
	cached = warnings
	cached_version = GLOB.babylon_tutorial_version
	cached_time = world.time
	return warnings

/// The triggers that can start listening once this trigger fired: those waiting "After" it and
/// those its Enable actions switch on.
/proc/babylon_tutorial_trigger_successors(obj/babylon_tutorial/trigger/trigger)
	var/list/next = list()
	for(var/obj/babylon_tutorial/trigger/candidate in GLOB.babylon_tutorial_objects)
		if(candidate.setting("starts") == "after" && candidate.setting("after") == trigger.tutorial_id)
			next |= candidate
	for(var/id in babylon_tutorial_expand_actions(trigger.action_ids()))
		var/obj/babylon_tutorial/action/toggle/toggle = babylon_tutorial_find(id)
		if(istype(toggle) && toggle.setting("mode") == "enable")
			for(var/enabled_id in toggle.setting("triggers"))
				var/obj/babylon_tutorial/trigger/enabled = babylon_tutorial_find(enabled_id)
				if(istype(enabled))
					next |= enabled
	return next

/// Triggers that can ever start listening: from those listening at the beginning, following
/// "After" links and Enable actions. Returns trigger => TRUE.
/proc/babylon_tutorial_reachable_triggers()
	var/list/reachable = list()
	var/list/queue = list()
	for(var/obj/babylon_tutorial/trigger/trigger in GLOB.babylon_tutorial_objects)
		if(trigger.listens_at_start())
			reachable[trigger] = TRUE
			queue += trigger
	while(length(queue))
		var/obj/babylon_tutorial/trigger/current = queue[1]
		queue.Cut(1, 2)
		for(var/obj/babylon_tutorial/trigger/next as anything in babylon_tutorial_trigger_successors(current))
			if(!reachable[next])
				reachable[next] = TRUE
				queue += next
	return reachable

/// Warnings for triggers that can never start listening; "After" loops are named as such.
/proc/babylon_tutorial_reachability_warnings()
	var/list/warnings = list()
	var/list/reachable = babylon_tutorial_reachable_triggers()
	var/list/reported = list()
	for(var/obj/babylon_tutorial/trigger/trigger in GLOB.babylon_tutorial_objects)
		if(reachable[trigger] || reported[trigger])
			continue
		// Follow the "After" links: a loop back to an earlier trigger is a cycle.
		var/list/path = list()
		var/obj/babylon_tutorial/trigger/current = trigger
		while(istype(current) && current.setting("starts") == "after" && !(current in path))
			path += current
			current = babylon_tutorial_find(current.setting("after"))
		if(istype(current) && (current in path))
			var/list/cycle = path.Copy(path.Find(current))
			if(!reported[current])
				var/list/names = list()
				for(var/obj/babylon_tutorial/trigger/member as anything in cycle)
					names += member.tutorial_id
					reported[member] = TRUE
				var/text = length(names) == 1 ? "[names[1]] waits for itself: it will never start." : "[english_list(names)] wait for each other: none of them will ever start."
				warnings += list(list("text" = text, "ref" = REF(current)))
			if(trigger in cycle)
				continue
		reported[trigger] = TRUE
		var/starts = trigger.setting("starts")
		var/text
		if(starts == "manual")
			text = "Trigger [trigger.tutorial_id] waits for an Enable action, but no reachable step enables it: it can never fire."
		else
			text = "Trigger [trigger.tutorial_id] waits for [trigger.setting("after") || "?"], which can never fire: it will never start."
		warnings += list(list("text" = text, "ref" = REF(trigger)))
	return warnings

/// The overview warnings as plain text (tests, logs).
/proc/babylon_tutorial_overview_texts()
	var/list/texts = list()
	for(var/list/warning as anything in babylon_tutorial_overview_warnings())
		texts += warning["text"]
	return texts

// ---------------------------------------------------------------------------------------------
// Categories

/obj/babylon_tutorial/trigger
	tutorial_category = "trigger"
	id_help = "Other triggers can start listening after this one fires (their \"After\" setting)."
	/// Fires when its condition becomes true (not on every check while it stays true).
	var/edge_triggered = TRUE

/obj/babylon_tutorial/trigger/settings_schema()
	return own_schema() + list(
		babylon_tutorial_field("actions", "Actions", "idlist", list(), "The actions to run, in this order, when the trigger fires.", filter = list("action")),
		babylon_tutorial_field("once", "Fire only once", "bool", 1, "Off: the trigger can fire again (every time its condition becomes true)."),
	) + babylon_tutorial_listen_fields() + list(
		babylon_tutorial_field("cooldown", "Cooldown (seconds)", "number", 0, "Shortest time between two firings.", min = 0, max = 600),
		babylon_tutorial_field("delay", "Delay (seconds)", "number", 0, "Wait this long after firing before the first action runs.", min = 0, max = 600),
	)

/// "Starts listening" and "After": when a trigger (or gate) begins to watch.
/proc/babylon_tutorial_listen_fields()
	return list(
		babylon_tutorial_field("starts", "Starts listening", "choice", "start", "When this trigger begins to watch for the players. \"After a trigger fired\" chains steps: one step's trigger starts listening once the step before it fired.", options = babylon_tutorial_options(list("start" = "At the beginning", "after" = "After a trigger fired", "manual" = "When an Enable action switches it on"))),
		babylon_tutorial_field("after", "After", "id", "", "The trigger whose firing makes this one start listening.", filter = list("trigger"), when = list("starts" = list("after")), required = TRUE),
	)

/// Every action this trigger can run (a gate has three lists), each once.
/obj/babylon_tutorial/trigger/proc/action_ids()
	var/list/ids = list()
	for(var/key in action_keys())
		var/list/listed = setting(key)
		if(islist(listed))
			ids |= listed
	return ids

/// The settings that hold this trigger's action lists.
/obj/babylon_tutorial/trigger/proc/action_keys()
	return list("actions")

/// The fields of this trigger kind (the common trigger fields are added after them).
/obj/babylon_tutorial/trigger/proc/own_schema()
	return list()

/obj/babylon_tutorial/trigger/set_setting(key, value)
	if(key == "after" && trim("[value]") == tutorial_id)
		return "A trigger can't wait for itself. Choose the trigger of the step before."
	return ..()

/obj/babylon_tutorial/trigger/store_settings(list/values)
	if(isnull(values["starts"]) && values["enabled_at_start"] == 0)
		values["starts"] = "manual"
	return ..()

/obj/babylon_tutorial/trigger/setting(key)
	// Saves from before "Starts listening": enabled_at_start = 0 meant waiting for an Enable action.
	if(key == "starts" && isnull(settings()["starts"]) && settings()["enabled_at_start"] == 0)
		return "manual"
	return ..()

/// A level trigger (zone, holding, condition) has a condition that holds or not at any moment:
/// as a gate input it is live. Event triggers (start, button, say, used on, timer) are latched.
/// The same split as edge_triggered: level kinds fire when their condition becomes true.
/obj/babylon_tutorial/trigger/proc/is_level()
	return edge_triggered

/// Whether the trigger listens as soon as a run starts.
/obj/babylon_tutorial/trigger/proc/listens_at_start()
	return setting("starts") == "start"

/obj/babylon_tutorial/trigger/summary()
	return actions_summary()

/// "runs a, b" for the overview.
/obj/babylon_tutorial/trigger/proc/actions_summary()
	var/list/actions = setting("actions")
	return length(actions) ? "runs [jointext(actions, ", ")]" : "runs nothing yet"

/obj/babylon_tutorial/action
	tutorial_category = "action"
	id_help = "Triggers list this id to run it."

/obj/babylon_tutorial/action/settings_schema()
	return own_schema() + list(
		babylon_tutorial_field("delay", "Delay (seconds)", "number", 0, "Wait this long before this action runs (after the actions before it).", min = 0, max = 600),
	)

/obj/babylon_tutorial/action/proc/own_schema()
	return list()

/// Actions this action runs itself later (a Move NPC action's "On arrival"): they count as used,
/// and steps they enable are reachable.
/obj/babylon_tutorial/action/proc/follow_up_ids()
	return list()

/// Action ids plus every follow-up action they run, recursively, each once (in order).
/proc/babylon_tutorial_expand_actions(list/ids)
	var/list/found = list()
	var/list/queue = islist(ids) ? ids.Copy() : list()
	while(length(queue))
		var/id = queue[1]
		queue.Cut(1, 2)
		if(found.Find(id))
			continue
		found += id
		var/obj/babylon_tutorial/action/action = babylon_tutorial_find(id)
		if(istype(action))
			queue += action.follow_up_ids()
	return found

/// Something an action could not do in the running test run: "Test run: ..." (runtime.dm note_action()).
/obj/babylon_tutorial/action/find_issues()
	. = ..()
	var/datum/babylon_tutorial_run/run = babylon_tutorial_current_run()
	var/note = run?.action_notes[src]
	if(note)
		.["live"] = "Test run: [note]"

// ---------------------------------------------------------------------------------------------
// Markers

/obj/babylon_tutorial/marker
	tutorial_kind = "marker"
	tutorial_category = "marker"
	kind_name = "Marker"
	kind_desc = "Names a spot or the object on it, so other parts can refer to it. Id \"start\" is where players begin."
	kind_example = "e.g. \"scanner\" on the table with the health analyzer, so a Point action can point at it."
	id_help = "A marker named start is where players begin. Actions and triggers refer to this marker by its id."
	ui_icon = "location-dot"
	view_icon = 'icons/effects/landmarks_static.dmi'
	view_state = "x2"

/obj/babylon_tutorial/marker/settings_schema()
	return list(
		babylon_tutorial_field("target", "Stands for", "target", "object", "What actions mean when they use this marker: one of the things on its tile, or the tile itself."),
		babylon_tutorial_field("speaker_name", "Speaker name", "text", "Guide", "Name used when this marker speaks and there is no object on its tile.", is_name = TRUE),
	)

/obj/babylon_tutorial/marker/Initialize(mapload)
	. = ..()
	update_view_state()

/obj/babylon_tutorial/marker/settings_changed()
	update_view_state()

/obj/babylon_tutorial/marker/set_tutorial_id(value)
	. = ..()
	update_view_state()

/obj/babylon_tutorial/marker/proc/update_view_state()
	view_state = tutorial_id == "start" ? "observer_start" : "x2"

/obj/babylon_tutorial/marker/target_atom()
	var/turf/tile = get_turf(src)
	var/target = setting("target")
	if(!tile || target == "tile")
		return tile
	var/path = text2path(target)
	if(path)
		for(var/atom/movable/thing as anything in tile)
			if(thing.type == path && !istype(thing, /obj/babylon_tutorial))
				return thing
	return babylon_tutorial_object_on(tile) || tile

/// The things a marker on this tile can stand for, for its settings window.
/obj/babylon_tutorial/marker/proc/target_choices()
	var/list/choices = list(list("value" = "object", "label" = "Whatever is on this tile (best match)"), list("value" = "tile", "label" = "This tile"))
	var/list/seen = list()
	for(var/atom/movable/thing as anything in get_turf(src))
		if(istype(thing, /obj/babylon_tutorial) || istype(thing, /obj/effect) || thing.invisibility >= INVISIBILITY_ABSTRACT || seen[thing.type])
			continue
		seen[thing.type] = TRUE
		choices += list(list("value" = "[thing.type]", "label" = "[thing.name]"))
	return choices

/obj/babylon_tutorial/marker/summary()
	var/atom/target = target_atom()
	if(tutorial_id == "start")
		return "players start here"
	return isturf(target) ? "this tile" : "[target]"

/// The object a marker on this tile stands for: a living mob first, then machines and structures,
/// then items. Tutorial objects and effects never count.
/proc/babylon_tutorial_object_on(turf/tile)
	var/atom/best
	var/best_rank = 0
	for(var/atom/movable/thing as anything in tile)
		if(istype(thing, /obj/babylon_tutorial) || istype(thing, /obj/effect) || thing.invisibility >= INVISIBILITY_ABSTRACT)
			continue
		var/rank = 0
		if(isliving(thing))
			rank = 4
		else if(ismachinery(thing))
			rank = 3
		else if(isstructure(thing))
			rank = 2
		else if(isitem(thing))
			rank = 1
		if(rank > best_rank)
			best = thing
			best_rank = rank
	return best
