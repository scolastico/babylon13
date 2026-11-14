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
		last_rename_links = babylon_tutorial_rewrite_links(old_id, value)
	babylon_tutorial_changed()
	return null

/obj/babylon_tutorial
	/// Ids of the objects whose links the last set_tutorial_id() rewrote.
	var/list/last_rename_links = list()

/// Replaces an id in every id and idlist setting. Returns the ids of the objects changed.
/proc/babylon_tutorial_rewrite_links(old_id, new_id)
	var/list/changed = list()
	for(var/obj/babylon_tutorial/object as anything in GLOB.babylon_tutorial_objects)
		var/list/values = object.settings().Copy()
		var/touched = FALSE
		for(var/list/field as anything in babylon_tutorial_schema(object.type))
			var/key = field["key"]
			switch(field["type"])
				if("id")
					if(values[key] == old_id)
						values[key] = new_id
						touched = TRUE
				if("idlist")
					var/list/ids = values[key]
					if(islist(ids) && (old_id in ids))
						var/list/renamed = list()
						for(var/id in ids)
							renamed += id == old_id ? new_id : id
						values[key] = renamed
						touched = TRUE
		if(touched)
			object.store_settings(values)
			changed += object.tutorial_id
	return changed

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
		var/key = field["key"]
		switch(field["type"])
			if("id")
				var/id = setting(key)
				if(length(id))
					refs[id] = key
			if("idlist")
				for(var/id in setting(key))
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
		var/key = field["key"]
		var/list/ids
		switch(field["type"])
			if("id")
				var/id = setting(key)
				if(length(id))
					ids = list(id)
				else if(field["required"])
					found[key] = "Choose an id."
			if("idlist")
				ids = setting(key)
				if(!length(ids) && field["required"])
					found[key] = "Add at least one id."
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

/// One settings field. type: text, longtext, number, bool, choice, typepath, id, idlist, zone or
/// effects. options: list(list("value", "label")). filter: categories an id may refer to. when:
/// list(other key = list(values)) — the field applies only while that setting has one of them.
/proc/babylon_tutorial_field(key, label, type, default_value = null, help = "", list/options = null, min = null, max = null, list/filter = null, list/when = null, base = null, required = FALSE, placeholder = null, is_name = FALSE, max_tiles = null)
	var/list/field = list("key" = key, "label" = label, "type" = type, "default" = default_value, "help" = help)
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
		if("effects")
			return babylon_tutorial_clean_effects(value)
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
	if(ispath(path, /obj/item))
		var/obj/item/item_path = path
		if(initial(item_path.item_flags) & ABSTRACT)
			return FALSE
		if(initial(item_path.abstract_type) == path)
			return FALSE
		// Kept in step with the Creative panel's spawn blocklist (merged into one check later).
		var/static/list/blocked = typecacheof(list(/obj/item/hand_item, /obj/item/antag_spawner, /obj/item/bombcore, /obj/item/disk/nuclear, /obj/item/grenade, /obj/item/transfer_valve, /obj/item/mmi, /obj/item/mob_holder, /obj/item/hilbertshotel))
		if(blocked[path])
			return FALSE
		if(findtext("[path]", "lewd") || findtext("[path]", "/erp"))
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
			for(var/id in object.setting("actions"))
				used_actions[id] = TRUE
	for(var/obj/babylon_tutorial/object as anything in GLOB.babylon_tutorial_objects)
		if(object.tutorial_category == "trigger")
			var/starts = object.setting("starts")
			if(starts == "manual" && !enabled_later[object.tutorial_id])
				warnings += list(list("text" = "Trigger [object.tutorial_id] waits for an Enable action, but none enables it: it can never fire.", "ref" = REF(object)))
			else if(starts == "start" && enabled_later[object.tutorial_id] && !istype(object, /obj/babylon_tutorial/trigger/start))
				warnings += list(list("text" = "Trigger [object.tutorial_id] listens from the beginning, but [enabled_later[object.tutorial_id]] also enables it later. Did you mean \"After [enabled_later[object.tutorial_id]] fired\"?", "ref" = REF(object)))
		if(object.tutorial_category == "action" && !used_actions[object.tutorial_id])
			warnings += list(list("text" = "Action [object.tutorial_id] is not used by any trigger.", "ref" = REF(object)))
	var/has_complete = FALSE
	for(var/obj/babylon_tutorial/action/complete/complete in GLOB.babylon_tutorial_objects)
		has_complete = TRUE
	if(length(GLOB.babylon_tutorial_objects) && !has_complete)
		warnings += list(list("text" = "No Complete action: players never see the tutorial's end screen.", "ref" = null))
	cached = warnings
	cached_version = GLOB.babylon_tutorial_version
	cached_time = world.time
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
		babylon_tutorial_field("starts", "Starts listening", "choice", "start", "When this trigger begins to watch for the player. \"After a trigger fired\" chains steps: one step's trigger starts listening once the step before it fired.", options = babylon_tutorial_options(list("start" = "At the beginning", "after" = "After a trigger fired", "manual" = "When an Enable action switches it on"))),
		babylon_tutorial_field("after", "After", "id", "", "The trigger whose firing makes this one start listening.", filter = list("trigger"), when = list("starts" = list("after")), required = TRUE),
		babylon_tutorial_field("cooldown", "Cooldown (seconds)", "number", 0, "Shortest time between two firings.", min = 0, max = 600),
		babylon_tutorial_field("delay", "Delay (seconds)", "number", 0, "Wait this long after firing before the first action runs.", min = 0, max = 600),
	)

/// The fields of this trigger kind (the common trigger fields are added after them).
/obj/babylon_tutorial/trigger/proc/own_schema()
	return list()

/obj/babylon_tutorial/trigger/store_settings(list/values)
	if(isnull(values["starts"]) && values["enabled_at_start"] == 0)
		values["starts"] = "manual"
	return ..()

/obj/babylon_tutorial/trigger/setting(key)
	// Saves from before "Starts listening": enabled_at_start = 0 meant waiting for an Enable action.
	if(key == "starts" && isnull(settings()["starts"]) && settings()["enabled_at_start"] == 0)
		return "manual"
	return ..()

/// Whether the trigger listens as soon as a run starts.
/obj/babylon_tutorial/trigger/proc/listens_at_start()
	return setting("starts") == "start"

/obj/babylon_tutorial/trigger/summary()
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
