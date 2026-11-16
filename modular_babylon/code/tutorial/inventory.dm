// Set inventory (spec 12 #7): every player's (or an NPC's) inventory is cleared, its hands only,
// or replaced by a stored loadout. A builder stores a loadout from what they wear and carry
// ("Store my current loadout" in the action's settings window) and can edit it there (remove
// entries, add items by type to a slot). A loadout keeps every item's slot, name, settings (the
// save engine's setting fields, as the area tools copy them: babylon_area_capture_settings),
// reagents and contents.
//
// A loadout is a list of entries, one per item:
//   list("type", "slot" (an ITEM_SLOT_* flag) | "hand" (1 left, 2 right) | "packed" (into the
//        backpack), optional "name", "amount" (stacks), "fields", "reagents" (list(list(type,
//        volume))), "contents" (babylon_area_capture_contents entries)).

/// Entries one loadout holds at most, and items inside them (all levels together).
#define BABYLON_TUTORIAL_LOADOUT_MAX 40
#define BABYLON_TUTORIAL_LOADOUT_NESTED_MAX 150

/// Slot flag => label, in the order a loadout dresses a body (uniform first: pockets, belt and
/// ID hang on it).
/proc/babylon_tutorial_loadout_slots()
	var/static/list/slots
	if(!slots)
		slots = list()
		var/list/labels = list(
			"[ITEM_SLOT_ICLOTHING]" = "Uniform",
			"[ITEM_SLOT_UNDERWEAR]" = "Underwear",
			"[ITEM_SLOT_SHIRT]" = "Undershirt",
			"[ITEM_SLOT_BRA]" = "Bra",
			"[ITEM_SLOT_SOCKS]" = "Socks",
			"[ITEM_SLOT_OCLOTHING]" = "Suit",
			"[ITEM_SLOT_BACK]" = "Back",
			"[ITEM_SLOT_BELT]" = "Belt",
			"[ITEM_SLOT_GLOVES]" = "Gloves",
			"[ITEM_SLOT_WRISTS]" = "Wrists",
			"[ITEM_SLOT_FEET]" = "Shoes",
			"[ITEM_SLOT_HEAD]" = "Head",
			"[ITEM_SLOT_MASK]" = "Mask",
			"[ITEM_SLOT_NECK]" = "Neck",
			"[ITEM_SLOT_EARS_LEFT]" = "Left ear",
			"[ITEM_SLOT_EARS_RIGHT]" = "Right ear",
			"[ITEM_SLOT_EYES]" = "Eyes",
			"[ITEM_SLOT_ID]" = "ID",
			"[ITEM_SLOT_SUITSTORE]" = "Suit storage",
			"[ITEM_SLOT_LPOCKET]" = "Left pocket",
			"[ITEM_SLOT_RPOCKET]" = "Right pocket",
		)
		for(var/slot in babylon_tutorial_revive_slots())
			slots["[slot]"] = labels["[slot]"] || "Slot [slot]"
	return slots

/// Where an entry goes, as the window names it: "slot:<flag>", "hand:1", "hand:2" or "packed".
/proc/babylon_tutorial_loadout_place(list/entry)
	if(entry["hand"])
		return "hand:[entry["hand"]]"
	if(entry["packed"])
		return "packed"
	return "slot:[entry["slot"]]"

/proc/babylon_tutorial_loadout_place_label(place)
	switch(place)
		if("hand:1")
			return "Left hand"
		if("hand:2")
			return "Right hand"
		if("packed")
			return "In the backpack"
	return babylon_tutorial_loadout_slots()[copytext(place, 6)] || place

/// Every place an item can be added to, for the window: list(list(value, label)).
/proc/babylon_tutorial_loadout_place_options()
	var/list/options = list()
	for(var/slot in babylon_tutorial_loadout_slots())
		options += list(list("value" = "slot:[slot]", "label" = babylon_tutorial_loadout_slots()[slot]))
	options += list(list("value" = "hand:1", "label" = "Left hand"), list("value" = "hand:2", "label" = "Right hand"), list("value" = "packed", "label" = "In the backpack"))
	return options

/obj/item
	/// A builder's tool (the tutorial wand, the world-edit wand): tutorial actions never take it
	/// away or delete it (Set inventory, Remove objects) and it is never part of a loadout.
	var/babylon_builder_tool = FALSE

/// Items an inventory change never takes away: the builder's tools (babylon_builder_tool). They
/// stay where they are; one inside something that goes is taken out first (to a free hand, else
/// the floor). A loadout item meant for their hand goes to the other hand or the floor.
/proc/babylon_tutorial_inventory_kept(obj/item/item)
	return istype(item) && item.babylon_builder_tool

/// Builder tools inside something (a wand in a backpack), at any depth.
/proc/babylon_tutorial_kept_inside(atom/movable/thing)
	var/list/found = list()
	for(var/obj/item/inner in thing.get_all_contents())
		if(inner != thing && babylon_tutorial_inventory_kept(inner))
			found += inner
	return found

/// A value JSON keeps as it is (null, a number, a text, or a list of those): settings that hold
/// anything else (a path, a reference) are left out of a loadout.
/proc/babylon_tutorial_json_safe(value, depth = 0)
	if(isnull(value) || isnum(value) || istext(value))
		return TRUE
	if(!islist(value) || depth >= 2)
		return FALSE
	var/list/values = value
	if(length(values) > 50)
		return FALSE
	for(var/key in values)
		if(!(istext(key) || isnum(key)) || !babylon_tutorial_json_safe(key, depth + 1))
			return FALSE
		if(istext(key) && !isnull(values[key]) && !babylon_tutorial_json_safe(values[key], depth + 1))
			return FALSE
	return TRUE

// ---------------------------------------------------------------------------------------------
// Capture

/// A body's loadout: what it wears and holds, with settings and contents. Returns
/// list("loadout" = entries, "left_out" = names of items that can't be in a tutorial).
/proc/babylon_tutorial_capture_loadout(mob/living/body)
	var/list/entries = list()
	var/list/left_out = list()
	var/datum/babylon_area_clip/clip = new
	if(ishuman(body))
		var/mob/living/carbon/human/human = body
		for(var/slot in babylon_tutorial_revive_slots())
			var/obj/item/item = human.get_item_by_slot(slot)
			if(!istype(item) || babylon_tutorial_inventory_kept(item))
				continue
			if(!babylon_tutorial_type_allowed(item.type, null))
				left_out += "[item.name] (not allowed in tutorials)"
				continue
			var/list/entry = babylon_tutorial_loadout_entry(item, clip)
			entry["slot"] = slot
			entries += list(entry)
	for(var/hand in 1 to length(body.held_items))
		var/obj/item/held = body.held_items[hand]
		if(!istype(held) || babylon_tutorial_inventory_kept(held))
			continue
		if(!babylon_tutorial_type_allowed(held.type, null))
			left_out += "[held.name] (not allowed in tutorials)"
			continue
		var/list/entry = babylon_tutorial_loadout_entry(held, clip)
		entry["hand"] = hand
		entries += list(entry)
	qdel(clip)
	// Over the limit for items inside bags: the last ones are left out (and named as a count).
	var/list/budget = list(BABYLON_TUTORIAL_LOADOUT_NESTED_MAX)
	var/dropped = 0
	for(var/list/entry in entries)
		dropped += babylon_tutorial_trim_contents(entry, budget)
	if(dropped)
		left_out += "[dropped] item\s inside bags (a loadout holds at most [BABYLON_TUTORIAL_LOADOUT_NESTED_MAX])"
	return list("loadout" = entries, "left_out" = left_out)

/// Cuts an entry's contents down to the budget left (budget[1], items inside bags). Returns how
/// many items it cut.
/proc/babylon_tutorial_trim_contents(list/entry, list/budget)
	. = 0
	var/list/inside = entry["contents"]
	if(!islist(inside))
		return
	var/list/kept = list()
	for(var/list/inner in inside)
		if(budget[1] <= 0)
			. += 1 + babylon_tutorial_loadout_inside(inner)
			continue
		budget[1]--
		. += babylon_tutorial_trim_contents(inner, budget)
		kept += list(inner)
	entry["contents"] = kept

/// One item as a loadout entry (its place is added by the caller).
/proc/babylon_tutorial_loadout_entry(obj/item/item, datum/babylon_area_clip/clip)
	var/list/entry = list("type" = "[item.type]")
	if(item.name != initial(item.name))
		entry["name"] = item.name
	if(isstack(item))
		var/obj/item/stack/stack = item
		entry["amount"] = stack.amount
	var/list/settings = babylon_area_capture_settings(item)
	if(settings)
		var/list/fields = list()
		for(var/field in settings)
			if(babylon_tutorial_json_safe(settings[field]))
				fields[field] = settings[field]
		if(length(fields))
			entry["fields"] = fields
	var/list/chems = babylon_area_capture_reagents(item)
	if(length(chems))
		entry["reagents"] = chems
	if(babylon_area_is_container(item))
		entry["contents"] = babylon_area_capture_contents(item, clip, 1)
	return entry

// ---------------------------------------------------------------------------------------------
// Validation (every loadout, stored from the builder or edited in the window)

/// list("value" = cleaned loadout) or list("error" = why it was refused).
/proc/babylon_tutorial_clean_loadout(value)
	if(isnull(value))
		return list("value" = list())
	if(!islist(value))
		return list("error" = "A loadout must be a list of items.")
	var/list/raw = value
	if(length(raw) > BABYLON_TUTORIAL_LOADOUT_MAX)
		return list("error" = "A loadout holds at most [BABYLON_TUTORIAL_LOADOUT_MAX] items.")
	var/list/budget = list(0)
	var/list/cleaned = list()
	var/list/taken = list()
	for(var/list/entry in raw)
		var/list/item = babylon_tutorial_clean_loadout_item(entry, 0, budget)
		if(item["error"])
			return item
		var/list/out = item["value"]
		if(!isnull(entry["hand"]))
			var/hand = round(text2num("[entry["hand"]]") || 0)
			if(hand != 1 && hand != 2)
				return list("error" = "Items are held in the left or the right hand.")
			out["hand"] = hand
		else if(entry["packed"])
			out["packed"] = 1
		else
			var/slot = round(text2num("[entry["slot"]]") || 0)
			if(!babylon_tutorial_loadout_slots()["[slot]"])
				return list("error" = "Unknown slot for [babylon_tutorial_type_label(out["type"])].")
			out["slot"] = slot
		var/place = babylon_tutorial_loadout_place(out)
		if(place != "packed")
			if(taken[place])
				return list("error" = "Two items in the same place ([babylon_tutorial_loadout_place_label(place)]).")
			taken[place] = TRUE
		cleaned += list(out)
	return list("value" = cleaned)

/// One item of a loadout (depth 0) or of its contents. budget[1] counts the items inside.
/proc/babylon_tutorial_clean_loadout_item(list/entry, depth, list/budget)
	if(!islist(entry))
		return list("error" = "A loadout item must be a list.")
	var/path = text2path("[entry["type"]]")
	if(!ispath(path, /obj/item))
		return list("error" = "\"[entry["type"]]\" is not an item.")
	// Worn and held items follow the tutorial rules (what Give item may hand out); what comes
	// inside them only has to be harmless (what the item may carry in a world at all).
	if(depth == 0 ? !babylon_tutorial_type_allowed(path, null) : babylon_creative_type_harmful(path))
		return list("error" = "[babylon_tutorial_type_label("[path]")] can't be used in tutorials.")
	var/obj/item/item_path = path
	if(initial(item_path.babylon_builder_tool))
		// Never in a loadout: inside a bag it is left out, as an item of its own it is refused.
		return depth ? list("skip" = TRUE) : list("error" = "Builder tools (the tutorial and world-edit wands) can't be part of a loadout.")
	var/list/out = list("type" = "[path]")
	if(istext(entry["name"]) && length(entry["name"]))
		var/name = trim(strip_html("[entry["name"]]", 64))
		if(length(name))
			out["name"] = name
	if(ispath(path, /obj/item/stack) && !isnull(entry["amount"]))
		var/obj/item/stack/stack_type = path
		out["amount"] = clamp(round(text2num("[entry["amount"]]") || 1), 1, max(1, initial(stack_type.max_amount)))
	if(islist(entry["fields"]) && depth == 0)
		var/list/fields = list()
		var/static/regex/var_name = regex(@"^[A-Za-z_][A-Za-z0-9_]*$")
		var/list/given = entry["fields"]
		for(var/field in given)
			if(length(fields) >= 30)
				break
			if(!istext(field) || !var_name.Find(field) || !babylon_tutorial_json_safe(given[field]))
				continue
			fields[field] = given[field]
		if(length(fields))
			out["fields"] = fields
	if(islist(entry["reagents"]))
		var/list/chems = list()
		for(var/list/chem in entry["reagents"])
			if(length(chems) >= 20 || length(chem) < 2)
				continue
			var/reagent = text2path("[chem[1]]")
			if(!ispath(reagent, /datum/reagent) || !babylon_tutorial_type_allowed(reagent, null))
				continue
			chems += list(list("[reagent]", clamp(text2num("[chem[2]]") || 0, 0, 1000)))
		if(length(chems))
			out["reagents"] = chems
	if(islist(entry["contents"]) && depth < 4)
		var/list/inside = list()
		for(var/list/inner in entry["contents"])
			budget[1]++
			if(budget[1] > BABYLON_TUTORIAL_LOADOUT_NESTED_MAX)
				return list("error" = "A loadout holds at most [BABYLON_TUTORIAL_LOADOUT_NESTED_MAX] items inside bags and boxes.")
			var/list/cleaned_inner = babylon_tutorial_clean_loadout_item(inner, depth + 1, budget)
			if(cleaned_inner["error"])
				return cleaned_inner
			if(cleaned_inner["skip"])
				continue
			inside += list(cleaned_inner["value"])
		out["contents"] = inside
	return list("value" = out)

/// Items inside an entry's containers, all levels.
/proc/babylon_tutorial_loadout_inside(list/entry)
	. = 0
	for(var/list/inner in entry["contents"])
		. += 1 + babylon_tutorial_loadout_inside(inner)

/// A loadout as the window shows it: list(list(place, where, name, path, inside)).
/proc/babylon_tutorial_loadout_view(list/loadout)
	var/list/view = list()
	for(var/list/entry in loadout)
		var/place = babylon_tutorial_loadout_place(entry)
		view += list(list(
			"place" = place,
			"where" = babylon_tutorial_loadout_place_label(place),
			"name" = entry["name"] || babylon_tutorial_type_label(entry["type"]),
			"path" = entry["type"],
			"inside" = babylon_tutorial_loadout_inside(entry),
		))
	return view

// ---------------------------------------------------------------------------------------------
// Apply

/**
 * Changes a body's inventory. mode: "clear_all" (everything worn and held), "clear_hands" (held
 * items) or "loadout" (everything, then the loadout). drop_old: the removed items fall to the
 * floor instead of being deleted. Kept items (babylon_tutorial_inventory_kept) stay. Returns the
 * items the loadout created.
 */
/proc/babylon_tutorial_set_inventory(mob/living/body, mode, list/loadout, drop_old = FALSE)
	var/list/created = list()
	if(QDELETED(body))
		return created
	var/list/old = list()
	for(var/obj/item/held in body.held_items)
		old += held
	if(mode != "clear_hands")
		var/list/slots = babylon_tutorial_revive_slots()
		if(ishuman(body))
			var/mob/living/carbon/human/human = body
			// Pockets, belt and ID before the uniform they hang on.
			for(var/index in length(slots) to 1 step -1)
				var/obj/item/worn = human.get_item_by_slot(slots[index])
				if(istype(worn))
					old |= worn
		for(var/obj/item/other in body.get_equipped_items(INCLUDE_POCKETS | INCLUDE_ACCESSORIES))
			old |= other
	for(var/obj/item/item as anything in old)
		if(QDELETED(item) || babylon_tutorial_inventory_kept(item))
			continue
		// Something worn on another item (an accessory on the uniform) goes with that item.
		if(item.loc != body)
			continue
		// Builder tools inside it (a wand in the backpack) come out first: a free hand, else the floor.
		for(var/obj/item/tool as anything in babylon_tutorial_kept_inside(item))
			tool.forceMove(get_turf(body))
			body.put_in_hands(tool)
		if(drop_old)
			body.dropItemToGround(item, TRUE)
		else
			body.temporarilyRemoveItemFromInventory(item, TRUE)
			qdel(item)
	if(mode != "loadout")
		return created
	var/turf/tile = get_turf(body)
	var/list/order = babylon_tutorial_revive_slots()
	var/list/worn = list()
	var/list/held = list()
	var/list/packed = list()
	for(var/list/entry in loadout)
		if(entry["hand"])
			held += list(entry)
		else if(entry["packed"])
			packed += list(entry)
		else
			worn += list(entry)
	// Dressed in slot order (the uniform before what hangs on it).
	for(var/slot in order)
		for(var/list/entry in worn)
			if(entry["slot"] != slot)
				continue
			var/obj/item/item = babylon_tutorial_make_loadout_item(entry, tile)
			if(!item)
				continue
			created += item
			if(!ishuman(body) || !body.equip_to_slot_if_possible(item, slot, disable_warning = TRUE, bypass_equip_delay_self = TRUE, initial = TRUE, indirect_action = TRUE))
				item.forceMove(tile)
	for(var/list/entry in held)
		var/obj/item/item = babylon_tutorial_make_loadout_item(entry, tile)
		if(!item)
			continue
		created += item
		if(!body.put_in_hand(item, entry["hand"]) && !body.put_in_hands(item))
			item.forceMove(tile)
	for(var/list/entry in packed)
		var/obj/item/item = babylon_tutorial_make_loadout_item(entry, tile)
		if(!item)
			continue
		created += item
		var/obj/item/backpack = ishuman(body) ? body.get_item_by_slot(ITEM_SLOT_BACK) : null
		if(!backpack?.atom_storage?.attempt_insert(item, body, override = TRUE, force = STORAGE_FULLY_LOCKED, messages = FALSE))
			item.forceMove(tile)
	// A stack put into a hand or a bag may have merged into another one and be gone.
	for(var/obj/item/item as anything in created.Copy())
		if(QDELETED(item))
			created -= item
	return created

/// Makes one loadout item on a tile, with its name, settings, reagents and contents.
/proc/babylon_tutorial_make_loadout_item(list/entry, turf/tile)
	var/path = text2path("[entry["type"]]")
	if(!ispath(path, /obj/item) || !babylon_tutorial_type_allowed(path, null))
		return null
	var/obj/item/item = ispath(path, /obj/item/stack) ? new path(tile, entry["amount"] || 1, FALSE) : new path(tile)
	if(QDELETED(item))
		return null
	if(entry["name"])
		item.name = entry["name"]
	var/list/fields = entry["fields"]
	if(length(fields))
		// Only the save engine's setting fields of this type (and the extra keys its
		// babylon_after_restore() reads, which are no variables): never any other variable.
		var/list/allowed = GLOB.babylon_save.setting_fields(item)
		var/list/kept = list()
		for(var/field in fields)
			if(field == "plane")
				continue
			if((field in allowed) || !(field in item.vars))
				kept[field] = fields[field]
		if(length(kept))
			babylon_area_restore_settings(item, kept)
	if(entry["reagents"])
		babylon_area_restore_reagents(item, entry["reagents"])
	if(!isnull(entry["contents"]) && (item.atom_storage || istype(item, /obj/structure/closet)))
		babylon_area_restore_contents(item, entry["contents"])
	return item

// ---------------------------------------------------------------------------------------------
// The action

/obj/babylon_tutorial/action/inventory
	tutorial_kind = "inventory"
	kind_name = "Set inventory"
	kind_desc = "Clears every living player's (or an NPC's) inventory or hands, or dresses them in a stored loadout."
	kind_example = "e.g. everyone starts the lesson with a medical belt and a health analyzer."
	ui_icon = "shirt"
	view_icon = 'icons/effects/mapping_helpers.dmi'
	view_state = "corpsedoctor"

/obj/babylon_tutorial/action/inventory/own_schema()
	return babylon_tutorial_body_target_fields("given the new inventory") + list(
		babylon_tutorial_field("inventory", "Do", "choice", "loadout", "Clear all: everything worn and held. Clear hands: only what is held. Loadout: everything is replaced by the stored loadout. The tutorial wand is never taken away.", options = babylon_tutorial_options(list("clear_all" = "Clear all", "clear_hands" = "Clear hands only", "loadout" = "Set a stored loadout"))),
		babylon_tutorial_field("old_items", "Old items", "choice", "delete", "What happens to the items taken away.", options = babylon_tutorial_options(list("delete" = "Deleted", "drop" = "Dropped on the floor"))),
		babylon_tutorial_field("loadout", "Loadout", "loadout", list(), "\"Store my current loadout\" copies what you wear and hold now (with names, settings, reagents and what is inside bags). Add or remove items below.", when = list("inventory" = list("loadout")), base = /obj/item, search = "creative"),
	)

/obj/babylon_tutorial/action/inventory/find_issues()
	. = ..()
	var/issue = npc_target_issue()
	if(issue)
		.["target"] = issue
	if(setting("inventory") == "loadout" && !length(setting("loadout")))
		.["loadout"] = "The loadout is empty: it only clears the inventory. Store your current loadout or add items."

/obj/babylon_tutorial/action/inventory/perform(datum/babylon_tutorial_run/run)
	var/mode = setting("inventory")
	var/list/loadout = setting("loadout")
	var/drop_old = setting("old_items") == "drop"
	if(setting("apply_to") == "npc")
		var/mob/living/npc = target_npc()
		if(!npc)
			run.note_action(src, "[setting("target") || "?"] has no NPC.")
			return
		var/obj/babylon_tutorial/npc_spawner/spawner = babylon_tutorial_find(setting("target"))
		for(var/obj/item/item as anything in babylon_tutorial_set_inventory(npc, mode, loadout, drop_old))
			// Like its outfit: never saved, gone with the NPC.
			for(var/obj/item/part in item.get_all_contents())
				part.babylon_tutorial_npc_item = TRUE
				if(istype(spawner))
					spawner.outfit_items += WEAKREF(part)
		return
	for(var/mob/living/player as anything in run.players())
		babylon_tutorial_set_inventory(player, mode, loadout, drop_old)

/obj/babylon_tutorial/action/inventory/summary()
	var/what
	switch(setting("inventory"))
		if("clear_all")
			what = "clear all"
		if("clear_hands")
			what = "clear hands"
		else
			what = "loadout of [length(setting("loadout"))] item\s"
	return "[what], [setting("apply_to") == "npc" ? (setting("target") || "?") : "every player"]"

#undef BABYLON_TUTORIAL_LOADOUT_MAX
#undef BABYLON_TUTORIAL_LOADOUT_NESTED_MAX
