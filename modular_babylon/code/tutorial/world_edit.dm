// The world-edit wand (spec 12 #1): the builder's area tools (area_tools.dm), split off the tutorial
// wand, which keeps tutorial objects only. Same rules as the tutorial wand: it works in creative
// worlds only, for its holder's own living body, and the Creative panel hands it out next to the
// tutorial wand. Click two corners with it to select an area; its window (tgui
// BabylonWorldEditWand) then copies, pastes, fills, borders, clears or undoes. Right-click it in
// hand to drop the selection (or stop pasting). While it is in a hand its holder sees the
// selection and the paste footprint outlined; nobody else does.
// It looks like a blocky wooden axe: a small nod to a certain block game.

/// Every world-edit wand that exists (SSbabylon_tutorial keeps their outlines in sync).
GLOBAL_LIST_EMPTY(babylon_world_edit_wands)

/// The world-edit wand's type (the Creative panel hands it out).
/proc/babylon_world_edit_wand_type()
	return /obj/item/babylon_world_edit_wand

/obj/item/babylon_world_edit_wand
	name = "world-edit wand"
	desc = "Selects, copies, pastes, fills and clears whole areas of a creative world. Use it in your hand to open its window. It looks suspiciously like a blocky wooden axe."
	icon = 'modular_babylon/icons/babylon_world_edit.dmi'
	icon_state = "wooden_axe"
	inhand_icon_state = "hatchet"
	lefthand_file = 'icons/mob/inhands/equipment/hydroponics_lefthand.dmi'
	righthand_file = 'icons/mob/inhands/equipment/hydroponics_righthand.dmi'
	w_class = WEIGHT_CLASS_SMALL
	item_flags = NOBLUDGEON
	force = 0
	throwforce = 0
	babylon_builder_tool = TRUE
	/// The mob whose client sees the outlines, and the client they were given to.
	var/mob/living/viewer
	var/client/viewer_client
	var/list/images = list()
	/// The area session version the outlines show.
	var/shown_area_version = -1
	/// Last result line for the window: list(text, ok, id).
	var/list/notice

/obj/item/babylon_world_edit_wand/Initialize(mapload)
	. = ..()
	GLOB.babylon_world_edit_wands += src

/obj/item/babylon_world_edit_wand/Destroy()
	GLOB.babylon_world_edit_wands -= src
	hide_view()
	return ..()

/obj/item/babylon_world_edit_wand/examine(mob/user)
	. = ..()
	if(!babylon_creative_enabled())
		. += span_warning("It only works in creative worlds.")
		return
	. += span_notice("Click two opposite corners with it to select an area, then use it in your hand to copy, paste, fill or clear. Right-click it while holding it to drop the selection.")

/// The wand works for this mob: creative world, its own living body, holding the wand (as the
/// tutorial wand).
/obj/item/babylon_world_edit_wand/proc/usable_by(mob/living/user)
	if(!babylon_creative_enabled() || !istype(user) || QDELETED(user) || !user.is_holding(src))
		return FALSE
	var/client/player = user.client
	if(player && (player.babylon_showcase_visitor || player.babylon_admin_spectator))
		return FALSE
	return TRUE

/obj/item/babylon_world_edit_wand/attack_self(mob/user)
	. = ..()
	if(.)
		return
	if(!babylon_creative_enabled())
		to_chat(user, span_warning("The world-edit wand only works in creative worlds."))
		return TRUE
	ui_interact(user)
	return TRUE

/// Right-click in hand: stop pasting, else drop the selection.
/obj/item/babylon_world_edit_wand/attack_self_secondary(mob/user, modifiers)
	. = ..()
	if(.)
		return
	if(!usable_by(user))
		to_chat(user, span_warning("The world-edit wand only works in creative worlds."))
		return TRUE
	var/datum/babylon_area_session/session = area_session(user)
	if(session.paste_armed)
		var/list/result = session.cancel_paste()
		report(user, result["text"], result["ok"])
	else
		session.reselect()
		report(user, "Selection dropped: click the first corner of an area.", TRUE)
	sync_view(TRUE)
	return TRUE

/// The area tool session of the wand's user (shared with the tutorial wand's "Store selection").
/obj/item/babylon_world_edit_wand/proc/area_session(mob/user)
	RETURN_TYPE(/datum/babylon_area_session)
	return babylon_area_session(user?.ckey || REF(user))

/// What the next click does.
/obj/item/babylon_world_edit_wand/proc/area_hint(mob/user)
	var/datum/babylon_area_session/session = area_session(user)
	if(session.paste_armed)
		return "click the tile that becomes the copy's bottom-left (south-west) corner."
	if(session.corner)
		return "click the opposite corner."
	return session.selection ? "your selection is [session.selection_text()]; a click starts a new one." : "click the first corner of an area."

/obj/item/babylon_world_edit_wand/equipped(mob/user, slot, initial)
	. = ..()
	sync_view()

/obj/item/babylon_world_edit_wand/dropped(mob/user, silent)
	. = ..()
	// The item leaves the hand before it lands in a bag: check after this move.
	addtimer(CALLBACK(src, PROC_REF(sync_view)), 0)

/obj/item/babylon_world_edit_wand/interact_with_atom(atom/interacting_with, mob/living/user, list/modifiers)
	return use_on(interacting_with, user)

/obj/item/babylon_world_edit_wand/ranged_interact_with_atom(atom/interacting_with, mob/living/user, list/modifiers)
	return use_on(interacting_with, user)

/// A click on something with the wand: a corner, or the paste target.
/obj/item/babylon_world_edit_wand/proc/use_on(atom/target, mob/living/user)
	if(!usable_by(user))
		to_chat(user, span_warning("The world-edit wand only works in creative worlds."))
		return ITEM_INTERACT_BLOCKING
	var/turf/tile = get_turf(target)
	if(!tile)
		return ITEM_INTERACT_BLOCKING
	var/datum/babylon_area_session/session = area_session(user)
	var/list/result = session.click(tile)
	session.result(result["text"], result["ok"])
	report(user, result["text"], result["ok"])
	user.balloon_alert(user, session.paste_armed ? "paste here?" : (session.corner ? "corner 1" : "selected"))
	sync_view(TRUE)
	return ITEM_INTERACT_SUCCESS

/obj/item/babylon_world_edit_wand/proc/report(mob/user, text, ok)
	notice = list("text" = text, "ok" = ok, "id" = world.time)
	if(user)
		to_chat(user, ok ? span_notice(text) : span_warning(text))
	SStgui.update_uis(src)

// ---------------------------------------------------------------------------------------------
// The holder's outlines

/// Shows the outlines to the holder while the wand is in a hand in a creative world, else hides
/// them. Rebuilds them when the session changed. force: rebuild anyway.
/obj/item/babylon_world_edit_wand/proc/sync_view(force = FALSE)
	var/mob/living/holder = isliving(loc) ? loc : null
	if(!holder || !usable_by(holder) || !holder.client)
		hide_view()
		return
	if(holder != viewer || holder.client != viewer_client)
		hide_view()
		viewer = holder
		viewer_client = holder.client
		RegisterSignal(viewer, COMSIG_QDELETING, PROC_REF(viewer_deleted))
	var/datum/babylon_area_session/session = area_session(holder)
	if(force || shown_area_version != session.version)
		build_images()

/obj/item/babylon_world_edit_wand/proc/viewer_deleted(datum/source)
	SIGNAL_HANDLER
	hide_view()

/obj/item/babylon_world_edit_wand/proc/hide_view()
	if(viewer_client)
		viewer_client.images -= images
	images.Cut()
	if(viewer)
		UnregisterSignal(viewer, COMSIG_QDELETING)
	viewer = null
	viewer_client = null
	shown_area_version = -1

/obj/item/babylon_world_edit_wand/proc/build_images()
	if(viewer_client)
		viewer_client.images -= images
	images.Cut()
	if(!viewer)
		return
	var/datum/babylon_area_session/session = area_session(viewer)
	shown_area_version = session.version
	images += area_images(session)
	viewer_client?.images += images

/// Outlines for the holder: the first corner, the selection (cyan) and the paste footprint
/// (orange, red where it can't go).
/obj/item/babylon_world_edit_wand/proc/area_images(datum/babylon_area_session/session)
	var/list/made = list()
	if(session.corner)
		var/turf/corner_tile = locate(session.corner[1], session.corner[2], session.corner[3])
		if(corner_tile)
			made += babylon_area_shade(corner_tile, "#4dd0ff", 150)
			made += babylon_area_label(corner_tile, "corner 1", "#4dd0ff")
	var/list/rects = list()
	if(session.selection)
		rects += list(list(session.selection, "#4dd0ff", "[session.selection_width()]×[session.selection_height()]"))
	var/list/paste = session.paste_rect()
	if(paste)
		var/fits = !session.paste_problem()
		rects += list(list(paste, fits ? "#ffa64d" : "#ff5c5c", fits ? "paste here?" : "can't paste here"))
	for(var/list/entry as anything in rects)
		var/list/rect = entry[1]
		var/x2 = min(rect[3], world.maxx)
		var/y2 = min(rect[4], world.maxy)
		var/tiles = (x2 - rect[1] + 1) * (y2 - rect[2] + 1)
		// The edge, plus a light fill inside small areas.
		for(var/turf/tile as anything in (tiles <= 400 ? babylon_area_tiles(rect[1], rect[2], x2, y2, rect[5]) : babylon_area_edge(rect[1], rect[2], x2, y2, rect[5])))
			var/edge = tile.x == rect[1] || tile.x == x2 || tile.y == rect[2] || tile.y == y2
			if(!babylon_area_locked(tile))
				made += babylon_area_shade(tile, entry[2], edge ? 90 : 30)
		// Protected tiles (the game won't let anyone change them) in red, wherever they are.
		for(var/turf/tile as anything in babylon_area_tiles(max(1, rect[1]), max(1, rect[2]), x2, y2, rect[5]))
			if(babylon_area_locked(tile))
				made += babylon_area_shade(tile, "#ff3b3b", 140)
		var/turf/top_left = locate(rect[1], y2, rect[5])
		if(top_left)
			made += babylon_area_label(top_left, entry[3], entry[2])
	return made

/// One shaded tile of a selection outline.
/proc/babylon_area_shade(turf/tile, color, alpha)
	var/image/shade = image('icons/effects/alphacolors.dmi', tile, "white", ABOVE_ALL_MOB_LAYER)
	SET_PLANE_EXPLICIT(shade, ABOVE_LIGHTING_PLANE, tile)
	shade.appearance_flags = RESET_COLOR | RESET_ALPHA | KEEP_APART
	shade.color = color
	shade.alpha = alpha
	shade.mouse_opacity = MOUSE_OPACITY_TRANSPARENT
	return shade

/// A label over a tile ("12×8").
/proc/babylon_area_label(turf/tile, text, color)
	var/image/label = image(loc = tile, layer = ABOVE_ALL_MOB_LAYER)
	SET_PLANE_EXPLICIT(label, ABOVE_LIGHTING_PLANE, tile)
	label.appearance_flags = RESET_COLOR | RESET_ALPHA | KEEP_APART
	label.mouse_opacity = MOUSE_OPACITY_TRANSPARENT
	label.maptext_width = 160
	label.maptext_height = 16
	label.maptext_y = 34
	label.maptext = "<span style='font-family: \"Grand9K Pixel\"; font-size: 6pt; color: [color]; -dm-text-outline: 1px black'>[html_encode(text)]</span>"
	return label

// ---------------------------------------------------------------------------------------------
// Window

/obj/item/babylon_world_edit_wand/ui_state(mob/user)
	return GLOB.hands_state

/obj/item/babylon_world_edit_wand/ui_interact(mob/user, datum/tgui/ui)
	ui = SStgui.try_update_ui(user, src, ui)
	if(!ui)
		ui = new(user, src, "BabylonWorldEditWand")
		ui.open()

/obj/item/babylon_world_edit_wand/ui_static_data(mob/user)
	return list("materials" = babylon_area_materials())

/obj/item/babylon_world_edit_wand/ui_data(mob/user)
	return list(
		"creative" = babylon_creative_enabled(),
		"notice" = notice,
		"area" = area_session(user).window_data(),
	)

/obj/item/babylon_world_edit_wand/ui_act(action, list/params, datum/tgui/ui, datum/ui_state/state)
	. = ..()
	if(.)
		return
	var/mob/living/user = usr
	if(!usable_by(user))
		return FALSE
	switch(action)
		if("area_option")
			var/error = area_session(user).set_option("[params["option"]]", params["value"])
			if(error)
				report(user, error, FALSE)
			sync_view(TRUE)
			return TRUE
		if("area_reselect")
			area_session(user).reselect()
			report(user, "Click the first corner of the area with the wand.", TRUE)
			sync_view(TRUE)
			return TRUE
		if("area_paste")
			var/list/result = area_session(user).arm_paste()
			report(user, result["text"], result["ok"])
			sync_view(TRUE)
			return TRUE
		if("area_paste_cancel")
			var/list/result = area_session(user).cancel_paste()
			report(user, result["text"], result["ok"])
			sync_view(TRUE)
			return TRUE
		if("area_copy", "area_paste_confirm", "area_fill", "area_border", "area_clear", "area_undo")
			// Map loading can pause: the operation runs on its own.
			INVOKE_ASYNC(src, PROC_REF(area_operation), user, action)
			return TRUE
	return FALSE

/// Runs an area tool operation from the window and reports its outcome.
/obj/item/babylon_world_edit_wand/proc/area_operation(mob/living/user, action)
	var/datum/babylon_area_session/session = area_session(user)
	var/list/result
	switch(action)
		if("area_copy")
			result = session.copy(user)
		if("area_paste_confirm")
			result = session.paste(user)
		if("area_fill")
			result = session.fill(user, session.material, FALSE)
		if("area_border")
			result = session.fill(user, session.material, TRUE)
		if("area_clear")
			result = session.clear(user)
		if("area_undo")
			result = session.undo(user)
	if(QDELETED(src))
		return
	report(user, result["text"], result["ok"])
	sync_view(TRUE)
	// The cooldown ends: the buttons come back.
	addtimer(CALLBACK(GLOBAL_PROC, GLOBAL_PROC_REF(babylon_area_refresh_wand), WEAKREF(src)), BABYLON_AREA_COOLDOWN + 1)

/proc/babylon_area_refresh_wand(datum/weakref/wand_ref)
	var/obj/item/wand = wand_ref?.resolve()
	if(wand)
		SStgui.update_uis(wand)
