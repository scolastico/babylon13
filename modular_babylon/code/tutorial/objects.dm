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
	/// Font Awesome icon for the tgui windows.
	var/ui_icon = "circle"
	/// The image a wand holder sees.
	var/view_icon = 'icons/effects/landmarks_static.dmi'
	var/view_state = "x"
	/// Decoded settings_json, and the JSON it was decoded from.
	var/list/settings_cache
	var/settings_cache_json

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

/obj/babylon_tutorial/proc/set_tutorial_id(value)
	value = trim("[value]")
	if(!babylon_tutorial_valid_id(value))
		return "Ids use letters, digits, _ and - only (at most [BABYLON_TUTORIAL_ID_MAX] characters)."
	tutorial_id = value
	babylon_tutorial_changed()
	return null

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
/obj/babylon_tutorial/proc/issues()
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
/proc/babylon_tutorial_field(key, label, type, default_value = null, help = "", list/options = null, min = null, max = null, list/filter = null, list/when = null, base = null, required = FALSE, placeholder = null)
	var/list/field = list("key" = key, "label" = label, "type" = type, "default" = default_value, "help" = help)
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
			return list("value" = list(x1, y1, x2, y2, z))
		if("effects")
			return babylon_tutorial_clean_effects(value)
	return list("error" = "Unknown setting type.")

/// Type paths a builder may pick for a typepath field.
/proc/babylon_tutorial_type_allowed(path, list/field)
	if(ispath(path, /obj/item))
		var/obj/item/item_path = path
		if(initial(item_path.item_flags) & ABSTRACT)
			return FALSE
		if(path in typesof(/obj/item/hand_item, /obj/item/antag_spawner, /obj/item/bombcore, /obj/item/disk/nuclear, /obj/item/grenade, /obj/item/transfer_valve, /obj/item/mmi, /obj/item/mob_holder))
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

/// Problems with the tutorial as a whole, for the wand's overview.
/proc/babylon_tutorial_overview_warnings()
	var/list/warnings = list()
	var/obj/babylon_tutorial/start = babylon_tutorial_find("start")
	if(!istype(start, /obj/babylon_tutorial/marker))
		warnings += "There is no marker with the id \"start\": players start at the arrivals instead."
	var/list/seen = list()
	var/list/enabled_later = list()
	var/list/used_actions = list()
	for(var/obj/babylon_tutorial/object as anything in GLOB.babylon_tutorial_objects)
		if(seen[object.tutorial_id])
			warnings += "The id \"[object.tutorial_id]\" is used more than once."
		seen[object.tutorial_id] = TRUE
		for(var/id in object.references())
			if(!babylon_tutorial_find(id))
				warnings += "[object.tutorial_id] refers to \"[id]\", which does not exist."
		if(istype(object, /obj/babylon_tutorial/action/toggle) && object.setting("mode") == "enable")
			for(var/id in object.setting("triggers"))
				enabled_later[id] = TRUE
		if(object.tutorial_category == "trigger")
			for(var/id in object.setting("actions"))
				used_actions[id] = TRUE
	for(var/obj/babylon_tutorial/object as anything in GLOB.babylon_tutorial_objects)
		if(object.tutorial_category == "trigger" && !object.setting("enabled_at_start") && !enabled_later[object.tutorial_id])
			warnings += "Trigger [object.tutorial_id] starts disabled and no action enables it: it can never fire."
		if(object.tutorial_category == "action" && !used_actions[object.tutorial_id])
			warnings += "Action [object.tutorial_id] is not used by any trigger."
	var/has_complete = FALSE
	for(var/obj/babylon_tutorial/action/complete/complete in GLOB.babylon_tutorial_objects)
		has_complete = TRUE
	if(length(GLOB.babylon_tutorial_objects) && !has_complete)
		warnings += "No Complete action: players never see the tutorial's end screen."
	return warnings

// ---------------------------------------------------------------------------------------------
// Categories

/obj/babylon_tutorial/trigger
	tutorial_category = "trigger"
	/// Fires when its condition becomes true (not on every check while it stays true).
	var/edge_triggered = TRUE

/obj/babylon_tutorial/trigger/settings_schema()
	return own_schema() + list(
		babylon_tutorial_field("actions", "Actions", "idlist", list(), "The actions to run, in this order, when the trigger fires.", filter = list("action")),
		babylon_tutorial_field("once", "Fire only once", "bool", 1, "Off: the trigger can fire again (every time its condition becomes true)."),
		babylon_tutorial_field("enabled_at_start", "Enabled at the start", "bool", 1, "Off: the trigger waits until an Enable/disable action switches it on."),
		babylon_tutorial_field("cooldown", "Cooldown (seconds)", "number", 0, "Shortest time between two firings.", min = 0, max = 600),
		babylon_tutorial_field("delay", "Delay (seconds)", "number", 0, "Wait this long after firing before the first action runs.", min = 0, max = 600),
	)

/// The fields of this trigger kind (the common trigger fields are added after them).
/obj/babylon_tutorial/trigger/proc/own_schema()
	return list()

/obj/babylon_tutorial/trigger/summary()
	var/list/actions = setting("actions")
	return length(actions) ? "runs [jointext(actions, ", ")]" : "runs nothing yet"

/obj/babylon_tutorial/action
	tutorial_category = "action"

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
	ui_icon = "location-dot"
	view_icon = 'icons/effects/landmarks_static.dmi'
	view_state = "x2"

/obj/babylon_tutorial/marker/settings_schema()
	return list(
		babylon_tutorial_field("target", "Stands for", "choice", "object", "What actions mean when they use this marker: the object on this tile (a machine, a closet ...) or the tile itself.", options = babylon_tutorial_options(list("object" = "The object on this tile", "tile" = "This tile"))),
		babylon_tutorial_field("speaker_name", "Speaker name", "text", "Guide", "Name used when this marker speaks and there is no object on its tile."),
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
	if(!tile || setting("target") == "tile")
		return tile
	return babylon_tutorial_object_on(tile) || tile

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
