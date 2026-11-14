// The tutorial wand (spec 7.1): the builder's tool for tutorial objects, usable in creative
// worlds only. Use it in hand to open its window (tgui BabylonTutorialWand); click tiles with it
// to act in the chosen mode:
// - Place: puts the chosen tutorial object (palette: triggers, actions, markers) on the tile.
// - Configure: opens the settings window (tgui BabylonTutorialObject) of an object on the tile.
// - NPC: places an NPC spawner from a preset; its NPC appears at once.
// - Delete: removes a tutorial object from the tile.
// Its window also lists every tutorial object (Overview, with warnings) and starts or stops a
// test run for the holder. While the wand is in a hand, its holder's client sees every tutorial
// object as an image with its id; nobody else does, and tutorial players never do.

/// Every tutorial wand that exists (SSbabylon_tutorial keeps their views in sync).
GLOBAL_LIST_EMPTY(babylon_tutorial_wands)

/// The tutorial wand's type (the Creative panel hands it out).
/proc/babylon_tutorial_wand_type()
	return /obj/item/babylon_tutorial_wand

/// Category => label colour of the wand's images and windows.
/proc/babylon_tutorial_category_colors()
	return list("trigger" = "#ffc857", "action" = "#5ad1c6", "marker" = "#8be07c", "npc" = "#c49bff")

/obj/item/babylon_tutorial_wand
	name = "tutorial wand"
	desc = "Builds tutorials: places, configures and test-runs hidden tutorial objects. Use it in your hand to open its window."
	icon = 'icons/obj/weapons/guns/magic.dmi'
	icon_state = "telewand"
	inhand_icon_state = "wand"
	lefthand_file = 'icons/mob/inhands/items_lefthand.dmi'
	righthand_file = 'icons/mob/inhands/items_righthand.dmi'
	icon_angle = -45
	w_class = WEIGHT_CLASS_SMALL
	item_flags = NOBLUDGEON
	/// "place", "configure", "npc" or "delete".
	var/mode = "place"
	/// The tutorial object kind Place puts down.
	var/selected_kind = "message"
	/// The NPC preset NPC mode puts down.
	var/selected_preset = "guide"
	/// While picking a zone: list(object weakref, setting key, first corner or null).
	var/list/picking
	/// The object whose settings window is open (its references are highlighted).
	var/datum/weakref/focus
	/// The mob whose client sees the images, and the client they were given to.
	var/mob/living/viewer
	var/client/viewer_client
	var/list/images = list()
	var/shown_version = -1
	/// Last result line for the window: list(text, ok, id).
	var/list/notice

/obj/item/babylon_tutorial_wand/Initialize(mapload)
	. = ..()
	GLOB.babylon_tutorial_wands += src

/obj/item/babylon_tutorial_wand/Destroy()
	GLOB.babylon_tutorial_wands -= src
	hide_view()
	return ..()

/obj/item/babylon_tutorial_wand/examine(mob/user)
	. = ..()
	if(!babylon_creative_enabled())
		. += span_warning("It only works in creative worlds.")
		return
	. += span_notice("Mode: <b>[babylon_tutorial_mode_name(mode)]</b>. Use it in your hand to choose a mode, then click tiles with it.")

/proc/babylon_tutorial_mode_name(mode)
	switch(mode)
		if("place")
			return "Place"
		if("configure")
			return "Configure"
		if("npc")
			return "NPC"
		if("delete")
			return "Delete"
	return mode

/// The wand works for this mob: creative world, its own living body, holding the wand.
/obj/item/babylon_tutorial_wand/proc/usable_by(mob/living/user)
	if(!babylon_creative_enabled() || !istype(user) || QDELETED(user) || !user.is_holding(src))
		return FALSE
	var/client/player = user.client
	if(player && (player.babylon_showcase_visitor || player.babylon_admin_spectator))
		return FALSE
	return TRUE

/obj/item/babylon_tutorial_wand/attack_self(mob/user)
	. = ..()
	if(.)
		return
	if(!babylon_creative_enabled())
		to_chat(user, span_warning("The tutorial wand only works in creative worlds."))
		return TRUE
	ui_interact(user)
	return TRUE

/obj/item/babylon_tutorial_wand/equipped(mob/user, slot, initial)
	. = ..()
	sync_view()

/obj/item/babylon_tutorial_wand/dropped(mob/user, silent)
	. = ..()
	// The item leaves the hand before it lands in a bag: check after this move.
	addtimer(CALLBACK(src, PROC_REF(sync_view)), 0)

/obj/item/babylon_tutorial_wand/interact_with_atom(atom/interacting_with, mob/living/user, list/modifiers)
	return use_on(interacting_with, user)

/obj/item/babylon_tutorial_wand/ranged_interact_with_atom(atom/interacting_with, mob/living/user, list/modifiers)
	return use_on(interacting_with, user)

/// A click on something with the wand, in the current mode.
/obj/item/babylon_tutorial_wand/proc/use_on(atom/target, mob/living/user)
	if(!usable_by(user))
		to_chat(user, span_warning("The tutorial wand only works in creative worlds."))
		return ITEM_INTERACT_BLOCKING
	var/turf/tile = get_turf(target)
	if(!tile)
		return ITEM_INTERACT_BLOCKING
	if(picking)
		pick_corner(user, tile)
		return ITEM_INTERACT_SUCCESS
	switch(mode)
		if("place")
			var/path = babylon_tutorial_kinds()[selected_kind]
			if(!path)
				report(user, "Choose what to place in the wand's window first.", FALSE)
				return ITEM_INTERACT_BLOCKING
			var/obj/babylon_tutorial/object = babylon_tutorial_place(path, tile)
			log_game("BABYLON TUTORIAL: [key_name(user)] placed [object.kind_name] [object.tutorial_id] at [AREACOORD(tile)].")
			report(user, "Placed [object.kind_name] \"[object.tutorial_id]\". Its settings are open.", TRUE)
			open_editor(user, object)
		if("npc")
			var/obj/babylon_tutorial/npc_spawner/spawner = babylon_tutorial_place_npc(tile, selected_preset)
			if(!spawner)
				report(user, "Choose an NPC preset in the wand's window first.", FALSE)
				return ITEM_INTERACT_BLOCKING
			log_game("BABYLON TUTORIAL: [key_name(user)] placed NPC spawner [spawner.tutorial_id] ([selected_preset]) at [AREACOORD(tile)].")
			report(user, "Placed NPC \"[spawner.tutorial_id]\". Its settings are open.", TRUE)
			open_editor(user, spawner)
		if("configure")
			var/obj/babylon_tutorial/object = choose_object(user, target, "Configure which?")
			if(object)
				open_editor(user, object)
		if("delete")
			var/obj/babylon_tutorial/object = choose_object(user, target, "Delete which?")
			if(object)
				delete_object(user, object)
	return ITEM_INTERACT_SUCCESS

/// The tutorial object a click means: the spawner of a clicked NPC, else one on the tile (a
/// list to choose from when there are several).
/obj/item/babylon_tutorial_wand/proc/choose_object(mob/living/user, atom/target, question)
	var/list/candidates = list()
	if(isliving(target))
		for(var/obj/babylon_tutorial/npc_spawner/spawner in GLOB.babylon_tutorial_objects)
			if(spawner.current_npc() == target)
				candidates += spawner
	for(var/obj/babylon_tutorial/object in get_turf(target))
		candidates |= object
	if(!length(candidates))
		report(user, "There is no tutorial object here.", FALSE)
		return null
	if(length(candidates) == 1)
		return candidates[1]
	var/list/choices = list()
	for(var/obj/babylon_tutorial/object as anything in candidates)
		choices["[object.tutorial_id] ([object.kind_name])"] = object
	var/choice = tgui_input_list(user, question, "Tutorial wand", choices)
	var/obj/babylon_tutorial/chosen = choices[choice]
	if(!chosen || QDELETED(chosen) || !usable_by(user))
		return null
	return chosen

/obj/item/babylon_tutorial_wand/proc/delete_object(mob/living/user, obj/babylon_tutorial/object)
	log_game("BABYLON TUTORIAL: [key_name(user)] deleted [object.kind_name] [object.tutorial_id] at [AREACOORD(object)].")
	var/id = object.tutorial_id
	qdel(object)
	var/list/still = list()
	if(!babylon_tutorial_find(id))
		for(var/obj/babylon_tutorial/other as anything in GLOB.babylon_tutorial_objects)
			if(other.references()[id])
				still += other.tutorial_id
	report(user, length(still) ? "Deleted \"[id]\". [english_list(still)] still refer[length(still) == 1 ? "s" : ""] to it." : "Deleted \"[id]\".", TRUE)

/// Places a tutorial object of a type. A new trigger after the first starts listening after the
/// most recently placed trigger, so steps chain in placing order (builders can change it).
/proc/babylon_tutorial_place(path, turf/tile)
	var/obj/babylon_tutorial/trigger/previous
	if(ispath(path, /obj/babylon_tutorial/trigger) && !ispath(path, /obj/babylon_tutorial/trigger/start))
		for(var/obj/babylon_tutorial/trigger/trigger in GLOB.babylon_tutorial_objects)
			previous = trigger
	var/obj/babylon_tutorial/object = new path(tile)
	if(previous)
		object.store_settings(list("starts" = "after", "after" = previous.tutorial_id))
	return object

/obj/item/babylon_tutorial_wand/proc/open_editor(mob/living/user, obj/babylon_tutorial/object)
	focus = WEAKREF(object)
	sync_view(TRUE)
	if(!user.client)
		return
	var/datum/babylon_tutorial_editor/editor = new(object, src)
	editor.ui_interact(user)

/// Starts picking a zone for an object's setting: the next two clicks are its corners.
/obj/item/babylon_tutorial_wand/proc/start_picking(mob/living/user, obj/babylon_tutorial/object, key)
	picking = list(WEAKREF(object), key, null)
	to_chat(user, span_notice("Click the first corner of the zone with the wand."))
	user.balloon_alert(user, "click corner 1")

/// The object whose zone is being picked, if any.
/obj/item/babylon_tutorial_wand/proc/picking_object()
	if(!picking)
		return null
	var/datum/weakref/object_ref = picking[1]
	return object_ref?.resolve()

/obj/item/babylon_tutorial_wand/proc/pick_corner(mob/living/user, turf/tile)
	var/obj/babylon_tutorial/object = picking_object()
	if(!object)
		picking = null
		return
	var/turf/first = picking[3]
	if(!first)
		picking[3] = tile
		user.balloon_alert(user, "click corner 2")
		to_chat(user, span_notice("Corner 1 is at [tile.x], [tile.y]. Now click the opposite corner."))
		return
	var/key = picking[2]
	picking = null
	if(first.z != tile.z)
		report(user, "Both corners must be on the same level.", FALSE)
		return
	var/error = object.set_setting(key, list(first.x, first.y, tile.x, tile.y, tile.z))
	if(error)
		report(user, error, FALSE)
		return
	report(user, "Zone of [object.tutorial_id] set: [abs(tile.x - first.x) + 1]x[abs(tile.y - first.y) + 1] tiles.", TRUE)
	user.balloon_alert(user, "zone set")
	open_editor(user, object)

/obj/item/babylon_tutorial_wand/proc/report(mob/user, text, ok)
	notice = list("text" = text, "ok" = ok, "id" = world.time)
	if(user)
		to_chat(user, ok ? span_notice(text) : span_warning(text))
	SStgui.update_uis(src)

/proc/babylon_tutorial_ids_of(list/objects)
	var/list/ids = list()
	for(var/obj/babylon_tutorial/object as anything in objects)
		ids += object.tutorial_id
	return ids

// ---------------------------------------------------------------------------------------------
// The holder's view

/// Shows the images to the holder while the wand is in a hand in a creative world, else hides
/// them. Rebuilds them when tutorial objects changed. force: rebuild anyway (new focus).
/obj/item/babylon_tutorial_wand/proc/sync_view(force = FALSE)
	var/mob/living/holder = isliving(loc) ? loc : null
	if(!holder || !usable_by(holder) || !holder.client)
		hide_view()
		return
	if(holder != viewer || holder.client != viewer_client)
		hide_view()
		viewer = holder
		viewer_client = holder.client
		RegisterSignal(viewer, COMSIG_QDELETING, PROC_REF(viewer_deleted))
	if(force || shown_version != GLOB.babylon_tutorial_version || !length(images) && length(GLOB.babylon_tutorial_objects))
		build_images()

/obj/item/babylon_tutorial_wand/proc/viewer_deleted(datum/source)
	SIGNAL_HANDLER
	hide_view()

/obj/item/babylon_tutorial_wand/proc/hide_view()
	if(viewer_client)
		viewer_client.images -= images
	images.Cut()
	if(viewer)
		UnregisterSignal(viewer, COMSIG_QDELETING)
	viewer = null
	viewer_client = null
	shown_version = -1

/obj/item/babylon_tutorial_wand/proc/build_images()
	if(viewer_client)
		viewer_client.images -= images
	images.Cut()
	shown_version = GLOB.babylon_tutorial_version
	var/obj/babylon_tutorial/focused = focus?.resolve()
	var/list/related = focused ? focused.references() : list()
	var/list/colors = babylon_tutorial_category_colors()
	var/list/per_tile = list()
	for(var/obj/babylon_tutorial/object as anything in GLOB.babylon_tutorial_objects)
		var/turf/tile = get_turf(object)
		if(!tile)
			continue
		var/index = per_tile[tile] || 0
		per_tile[tile] = index + 1
		var/image/picture = image(object.view_icon, tile, object.view_state, ABOVE_ALL_MOB_LAYER)
		SET_PLANE_EXPLICIT(picture, ABOVE_LIGHTING_PLANE, tile)
		picture.appearance_flags = RESET_COLOR | RESET_ALPHA | KEEP_APART | PIXEL_SCALE
		picture.mouse_opacity = MOUSE_OPACITY_TRANSPARENT
		picture.alpha = 230
		picture.pixel_x = index * 8
		picture.pixel_y = index * 6
		picture.maptext_width = 96
		picture.maptext_x = -32
		picture.maptext_y = -10
		picture.maptext = "<span style='font-family: \"Grand9K Pixel\"; font-size: 6pt; text-align: center; color: [colors[object.tutorial_category]]; -dm-text-outline: 1px black'>[html_encode(object.tutorial_id)]</span>"
		if(object == focused)
			picture.filters = filter(type = "outline", size = 1, color = "#ffffff")
		else if(related[object.tutorial_id])
			picture.filters = filter(type = "outline", size = 1, color = "#ffd34d")
		images += picture
	// The focused zone, tile by tile (at most 400 tiles; larger zones show their corners).
	var/list/zone = focused?.setting("zone")
	if(istype(focused, /obj/babylon_tutorial/trigger/zone))
		var/obj/babylon_tutorial/trigger/zone/zone_trigger = focused
		zone = zone_trigger.zone()
	if(length(zone) == 5)
		var/list/tiles = babylon_tutorial_zone_turfs(zone)
		if(length(tiles) > 400)
			tiles = list(locate(zone[1], zone[2], zone[5]), locate(zone[3], zone[4], zone[5]), locate(zone[1], zone[4], zone[5]), locate(zone[3], zone[2], zone[5]))
		for(var/turf/tile as anything in tiles)
			var/image/shade = image('icons/effects/alphacolors.dmi', tile, "white", ABOVE_ALL_MOB_LAYER)
			SET_PLANE_EXPLICIT(shade, ABOVE_LIGHTING_PLANE, tile)
			shade.appearance_flags = RESET_COLOR | RESET_ALPHA | KEEP_APART
			shade.color = colors["trigger"]
			shade.alpha = 60
			shade.mouse_opacity = MOUSE_OPACITY_TRANSPARENT
			images += shade
	viewer_client?.images += images

// ---------------------------------------------------------------------------------------------
// Wand window

/obj/item/babylon_tutorial_wand/ui_state(mob/user)
	return GLOB.hands_state

/obj/item/babylon_tutorial_wand/ui_interact(mob/user, datum/tgui/ui)
	ui = SStgui.try_update_ui(user, src, ui)
	if(!ui)
		ui = new(user, src, "BabylonTutorialWand")
		ui.open()

/obj/item/babylon_tutorial_wand/ui_static_data(mob/user)
	var/list/groups = list(
		list("id" = "trigger", "name" = "Triggers", "desc" = "Wait for something the player does, then run actions."),
		list("id" = "action", "name" = "Actions", "desc" = "What happens when a trigger fires."),
		list("id" = "marker", "name" = "Markers", "desc" = "Name a spot or an object so others can refer to it."),
	)
	for(var/list/group as anything in groups)
		var/list/entries = list()
		for(var/kind in babylon_tutorial_kinds())
			var/obj/babylon_tutorial/path = babylon_tutorial_kinds()[kind]
			if(initial(path.tutorial_category) != group["id"])
				continue
			entries += list(list("kind" = kind, "name" = initial(path.kind_name), "desc" = initial(path.kind_desc), "example" = initial(path.kind_example), "icon" = initial(path.ui_icon)))
		group["entries"] = entries
	var/list/presets = list()
	var/list/all_presets = babylon_tutorial_npc_presets()
	for(var/id in all_presets)
		var/list/preset = all_presets[id]
		presets += list(list("id" = id, "name" = preset["name"], "desc" = preset["desc"], "icon" = preset["icon"]))
	return list("palette" = groups, "presets" = presets, "colors" = babylon_tutorial_category_colors())

/obj/item/babylon_tutorial_wand/ui_data(mob/user)
	var/list/objects = list()
	for(var/obj/babylon_tutorial/object as anything in GLOB.babylon_tutorial_objects)
		var/turf/tile = get_turf(object)
		var/list/issues = object.issues()
		var/list/messages = list()
		for(var/key in issues)
			messages += issues[key]
		var/list/refs = list()
		for(var/id in object.references())
			refs += id
		objects += list(list(
			"ref" = REF(object),
			"id" = object.tutorial_id,
			"kind" = object.tutorial_kind,
			"kind_name" = object.kind_name,
			"category" = object.tutorial_category,
			"icon" = object.ui_icon,
			"summary" = object.summary(),
			"x" = tile?.x, "y" = tile?.y, "z" = tile?.z,
			"refs" = refs,
			"issues" = messages,
			"actions" = object.tutorial_category == "trigger" ? object.setting("actions") : null,
			"starts" = object.tutorial_category == "trigger" ? object.setting("starts") : null,
			"after" = object.tutorial_category == "trigger" && object.setting("starts") == "after" ? object.setting("after") : null,
		))
	var/datum/babylon_tutorial_run/run = babylon_tutorial_run_of(user)
	var/list/zone_pick
	if(picking)
		var/obj/babylon_tutorial/object = picking_object()
		zone_pick = list("id" = object?.tutorial_id, "corner" = picking[3] ? 2 : 1)
	return list(
		"creative" = babylon_creative_enabled(),
		"mode" = mode,
		"selected_kind" = selected_kind,
		"selected_preset" = selected_preset,
		"objects" = objects,
		"warnings" = babylon_tutorial_overview_warnings(),
		"picking" = zone_pick,
		"has_start" = !!babylon_tutorial_marker_turf("start"),
		"test" = run ? list("running" = TRUE, "completed" = run.completed, "fired" = length(run.history), "listening" = babylon_tutorial_ids_of(run.enabled), "steps" = run.history.Copy(max(1, length(run.history) - 7)), "objective" = run.objective) : list("running" = FALSE),
		"notice" = notice,
	)

/obj/item/babylon_tutorial_wand/ui_act(action, list/params, datum/tgui/ui, datum/ui_state/state)
	. = ..()
	if(.)
		return
	var/mob/living/user = usr
	if(!usable_by(user))
		return FALSE
	switch(action)
		if("mode")
			if(params["mode"] in list("place", "configure", "npc", "delete"))
				mode = params["mode"]
				picking = null
				user.balloon_alert(user, "[lowertext(babylon_tutorial_mode_name(mode))] mode")
			return TRUE
		if("kind")
			if(babylon_tutorial_kinds()[params["kind"]])
				selected_kind = params["kind"]
				mode = "place"
			return TRUE
		if("preset")
			if(babylon_tutorial_npc_presets()[params["preset"]])
				selected_preset = params["preset"]
				mode = "npc"
			return TRUE
		if("configure")
			var/obj/babylon_tutorial/object = locate(params["ref"]) in GLOB.babylon_tutorial_objects
			if(object)
				open_editor(user, object)
			return TRUE
		if("delete")
			var/obj/babylon_tutorial/object = locate(params["ref"]) in GLOB.babylon_tutorial_objects
			if(object)
				delete_object(user, object)
			return TRUE
		if("jump")
			var/obj/babylon_tutorial/object = locate(params["ref"]) in GLOB.babylon_tutorial_objects
			var/turf/tile = get_turf(object)
			if(!tile)
				return TRUE
			user.buckled?.unbuckle_mob(user, TRUE)
			user.forceMove(tile)
			log_game("BABYLON TUTORIAL: [key_name(user)] jumped to [object.tutorial_id] at [AREACOORD(tile)].")
			report(user, "You are at [object.tutorial_id].", TRUE)
			return TRUE
		if("cancel_pick")
			picking = null
			report(user, "Zone picking cancelled.", TRUE)
			return TRUE
		if("test_start")
			var/from_start = params["from"] == "start"
			if(from_start && !babylon_tutorial_marker_turf("start"))
				report(user, "There is no \"start\" marker yet: place a marker and give it the id start.", FALSE)
				return TRUE
			var/reset = !!params["reset_npcs"]
			babylon_tutorial_begin(user, from_start, TRUE, reset)
			report(user, "Test run started[from_start ? " at the start marker" : " where you stand"][reset ? ", NPCs reset" : ""]. Your triggers are live now.", TRUE)
			return TRUE
		if("test_stop")
			if(babylon_tutorial_end(user))
				report(user, "Test run stopped. The world stays as it is.", TRUE)
			return TRUE
	return FALSE

// ---------------------------------------------------------------------------------------------
// Settings window of one object

/// Open while the user holds a tutorial wand in a creative world and the object exists.
/datum/ui_state/babylon_tutorial_editor/can_use_topic(src_object, mob/user)
	var/datum/babylon_tutorial_editor/editor = src_object
	var/obj/item/babylon_tutorial_wand/wand = editor.wand_ref?.resolve()
	var/obj/babylon_tutorial/object = editor.object_ref?.resolve()
	if(!wand || !object || !wand.usable_by(user))
		return UI_CLOSE
	return UI_INTERACTIVE

GLOBAL_DATUM_INIT(babylon_tutorial_editor_state, /datum/ui_state/babylon_tutorial_editor, new)

/datum/babylon_tutorial_editor
	var/datum/weakref/object_ref
	var/datum/weakref/wand_ref
	/// The last type search: list(key, query, results).
	var/list/search
	var/list/notice

/datum/babylon_tutorial_editor/New(obj/babylon_tutorial/object, obj/item/babylon_tutorial_wand/wand)
	object_ref = WEAKREF(object)
	wand_ref = WEAKREF(wand)

/datum/babylon_tutorial_editor/ui_state(mob/user)
	return GLOB.babylon_tutorial_editor_state

/datum/babylon_tutorial_editor/ui_interact(mob/user, datum/tgui/ui)
	ui = SStgui.try_update_ui(user, src, ui)
	if(!ui)
		ui = new(user, src, "BabylonTutorialObject")
		ui.open()

/datum/babylon_tutorial_editor/ui_close(mob/user)
	. = ..()
	var/obj/item/babylon_tutorial_wand/wand = wand_ref?.resolve()
	if(wand && wand.focus?.resolve() == object_ref?.resolve() && !wand.picking)
		wand.focus = null
		wand.sync_view(TRUE)
	qdel(src)

/datum/babylon_tutorial_editor/ui_static_data(mob/user)
	var/obj/babylon_tutorial/object = object_ref?.resolve()
	if(!object)
		return list()
	var/list/zones = list()
	var/list/body_zones = babylon_tutorial_body_zones()
	for(var/zone in body_zones)
		zones += list(list("value" = zone, "label" = body_zones[zone]))
	var/list/kinds = list()
	var/list/effect_kinds = babylon_tutorial_effect_kinds()
	for(var/kind in effect_kinds)
		kinds += list(list("value" = kind, "label" = effect_kinds[kind]))
	// "+ New Message" and friends in a trigger's action list.
	var/list/new_actions = list()
	for(var/kind in babylon_tutorial_kinds())
		var/obj/babylon_tutorial/path = babylon_tutorial_kinds()[kind]
		if(initial(path.tutorial_category) == "action")
			new_actions += list(list("value" = kind, "label" = initial(path.kind_name)))
	return list(
		"kind" = object.tutorial_kind,
		"kind_name" = object.kind_name,
		"kind_desc" = object.kind_desc,
		"category" = object.tutorial_category,
		"icon" = object.ui_icon,
		"id_help" = object.id_help,
		"color" = babylon_tutorial_category_colors()[object.tutorial_category],
		"schema" = babylon_tutorial_schema(object.type),
		"effect_kinds" = kinds,
		"body_zones" = zones,
		"wounds" = babylon_tutorial_options(babylon_tutorial_wounds()),
		"diseases" = babylon_tutorial_options(babylon_tutorial_diseases()),
		"reagents" = babylon_tutorial_options(babylon_tutorial_blood_reagents()),
		"new_actions" = new_actions,
	)

/datum/babylon_tutorial_editor/ui_data(mob/user)
	var/obj/babylon_tutorial/object = object_ref?.resolve()
	if(!object)
		return list("missing" = TRUE)
	var/list/values = list()
	for(var/list/field as anything in babylon_tutorial_schema(object.type))
		var/key = field["key"]
		var/value = object.setting(key)
		if(field["type"] == "typepath")
			values[key] = list("path" = value, "name" = length(value) ? babylon_tutorial_type_label(value) : "")
		else
			values[key] = value
	var/list/ids = list()
	for(var/obj/babylon_tutorial/other as anything in GLOB.babylon_tutorial_objects)
		if(other != object)
			ids += list(list("id" = other.tutorial_id, "kind_name" = other.kind_name, "category" = other.tutorial_category, "summary" = other.summary()))
	var/turf/tile = get_turf(object)
	var/obj/item/babylon_tutorial_wand/wand = wand_ref?.resolve()
	var/list/data = list(
		"id" = object.tutorial_id,
		"values" = values,
		"issues" = object.issues(),
		"ids" = ids,
		"position" = tile ? list("x" = tile.x, "y" = tile.y, "z" = tile.z) : null,
		"summary" = object.summary(),
		"search" = search,
		"notice" = notice,
		"picking" = !!wand && wand.picking_object() == object,
	)
	if(istype(object, /obj/babylon_tutorial/marker))
		var/obj/babylon_tutorial/marker/marker = object
		var/atom/target = marker.target_atom()
		data["target_choices"] = marker.target_choices()
		data["target_now"] = isturf(target) ? "this tile" : "[target]"
	if(istype(object, /obj/babylon_tutorial/npc_spawner))
		var/obj/babylon_tutorial/npc_spawner/spawner = object
		var/mob/living/carbon/human/npc = spawner.current_npc()
		data["npc"] = npc ? list("name" = npc.real_name, "health" = npc.health, "stat" = npc.stat == DEAD ? "dead" : (babylon_tutorial_awake(npc) ? "awake" : "unconscious"), "outdated" = spawner.npc_outdated()) : null
	return data

/datum/babylon_tutorial_editor/proc/set_notice(text, ok, key = null)
	notice = list("text" = text, "ok" = ok, "id" = world.time + rand(), "key" = key)

/datum/babylon_tutorial_editor/ui_act(action, list/params, datum/tgui/ui, datum/ui_state/state)
	. = ..()
	if(.)
		return
	var/obj/babylon_tutorial/object = object_ref?.resolve()
	var/obj/item/babylon_tutorial_wand/wand = wand_ref?.resolve()
	var/mob/living/user = usr
	if(!object || !wand?.usable_by(user))
		return FALSE
	switch(action)
		if("set")
			var/key = "[params["key"]]"
			if(key == "id")
				var/old_id = object.tutorial_id
				var/error = object.set_tutorial_id(params["value"])
				if(error)
					set_notice(error, FALSE, "id")
				else if(old_id != object.tutorial_id)
					var/list/links = object.last_rename_links
					set_notice("Renamed [old_id] → [object.tutorial_id][length(links) ? " (updated [length(links)] link[length(links) == 1 ? "" : "s"]: [jointext(links, ", ")])" : ""].", TRUE)
					log_game("BABYLON TUTORIAL: [key_name(user)] renamed [old_id] to [object.tutorial_id].")
				wand.sync_view(TRUE)
				return TRUE
			var/error = object.set_setting(key, params["value"])
			if(error)
				set_notice(error, FALSE, key)
			else
				notice = null
				log_game("BABYLON TUTORIAL: [key_name(user)] set [key] of [object.tutorial_id].")
			wand.sync_view(TRUE)
			return TRUE
		if("search")
			// At most five searches a second per window; a query arriving sooner waits and runs
			// when the window ends (the latest one wins), so the last keystroke is never lost.
			var/key = "[params["key"]]"
			var/list/field = babylon_tutorial_schema_field(object.type, key)
			if(field?["type"] != "typepath")
				return FALSE
			var/query = copytext_char("[params["query"]]", 1, 64)
			if(world.time < next_search)
				if(!pending_search)
					addtimer(CALLBACK(src, PROC_REF(run_pending_search)), next_search - world.time)
				pending_search = list(key, query)
				return FALSE
			run_search(key, query)
			return TRUE
		if("new_linked")
			// A new action on this trigger's tile, added to its action list, its settings opened.
			var/key = "[params["key"]]"
			var/list/field = babylon_tutorial_schema_field(object.type, key)
			var/path = babylon_tutorial_kinds()["[params["kind"]]"]
			var/list/filter = field?["filter"]
			if(field?["type"] != "idlist" || !("action" in filter) || !ispath(path, /obj/babylon_tutorial/action))
				return FALSE
			var/obj/babylon_tutorial/created = new path(get_turf(object))
			var/list/ids = object.setting(key)
			ids = islist(ids) ? ids.Copy() : list()
			ids += created.tutorial_id
			var/error = object.set_setting(key, ids)
			if(error)
				qdel(created)
				set_notice(error, FALSE, key)
				return TRUE
			log_game("BABYLON TUTORIAL: [key_name(user)] placed [created.kind_name] [created.tutorial_id] for [object.tutorial_id].")
			set_notice("Added [created.kind_name] \"[created.tutorial_id]\" to [object.tutorial_id]. Its settings are open.", TRUE)
			wand.open_editor(user, created)
			return TRUE
		if("open")
			var/obj/babylon_tutorial/other = babylon_tutorial_find("[params["id"]]")
			if(other)
				wand.open_editor(user, other)
			return TRUE
		if("pick_zone")
			var/key = "[params["key"]]"
			var/list/field = babylon_tutorial_schema_field(object.type, key)
			if(field?["type"] != "zone")
				return FALSE
			wand.focus = WEAKREF(object)
			wand.start_picking(user, object, key)
			return TRUE
		if("clear_zone")
			var/key = "[params["key"]]"
			var/list/values = object.settings().Copy()
			values -= key
			object.store_settings(values)
			return TRUE
		if("spawn_npc")
			if(istype(object, /obj/babylon_tutorial/npc_spawner))
				var/obj/babylon_tutorial/npc_spawner/spawner = object
				spawner.spawn_npc()
				SSbabylon_tutorial.refresh_hooks()
				log_game("BABYLON TUTORIAL: [key_name(user)] spawned the NPC of [object.tutorial_id].")
				set_notice("NPC created.", TRUE)
			return TRUE
		if("preview")
			if(istype(object, /obj/babylon_tutorial/action))
				var/obj/babylon_tutorial/action/previewed = object
				// Always a throwaway run: it never touches a test run, and no triggers listen.
				var/datum/babylon_tutorial_run/run = new(user, TRUE)
				run.preview = TRUE
				run.enabled.Cut()
				run.perform(null, previewed)
				QDEL_IN(run, 60 SECONDS)
				set_notice("Previewed for you only.", TRUE)
			return TRUE
		if("jump")
			var/turf/tile = get_turf(object)
			if(tile)
				user.buckled?.unbuckle_mob(user, TRUE)
				user.forceMove(tile)
				log_game("BABYLON TUTORIAL: [key_name(user)] jumped to [object.tutorial_id] at [AREACOORD(tile)].")
			return TRUE
		if("delete")
			wand.delete_object(user, object)
			ui.close()
			return TRUE
	return FALSE

/datum/babylon_tutorial_editor
	/// world.time before which another type search waits.
	var/next_search = 0
	/// The latest search that arrived too soon: list(key, query).
	var/list/pending_search

/datum/babylon_tutorial_editor/proc/run_search(key, query)
	var/obj/babylon_tutorial/object = object_ref?.resolve()
	var/list/field = object && babylon_tutorial_schema_field(object.type, key)
	if(!field)
		return
	next_search = world.time + 2
	search = list("key" = key, "query" = query, "results" = babylon_tutorial_cached_search(field, query))

/datum/babylon_tutorial_editor/proc/run_pending_search()
	if(QDELETED(src) || !pending_search)
		return
	var/list/waiting = pending_search
	pending_search = null
	run_search(waiting[1], waiting[2])
	SStgui.update_uis(src)

/// Type search results, cached per base and query (the last 50 queries).
/proc/babylon_tutorial_cached_search(list/field, query)
	var/static/list/cache = list()
	var/key = "[field["base"]]|[lowertext(trim(query))]"
	if(cache[key])
		return cache[key]
	var/list/results = babylon_tutorial_search_types(field, query)
	if(length(cache) >= 50)
		cache.Cut(1, 2)
	cache[key] = results
	return results
