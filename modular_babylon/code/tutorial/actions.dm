// Tutorial actions (spec 7.2): what happens when a trigger fires. A trigger runs its actions in
// order; each action may wait (its delay) after the ones before it. Everything an action shows
// goes to the run's player only (chat, private images, local sounds), except what happens in the
// world on purpose: an NPC speaking or pointing, a spawned NPC, a given item.

/// Runs the action for a run's player.
/obj/babylon_tutorial/action/proc/perform(datum/babylon_tutorial_run/run)
	return

/// "[player]" in builder text becomes the player's name.
/proc/babylon_tutorial_fill_text(text, mob/player)
	return replacetext("[text]", "\[player]", player ? player.real_name : "you")

/// The friendly "Guide" chat box.
/proc/babylon_tutorial_guide_message(speaker, text)
	return custom_boxed_message("green_box", "<span class='nicegreen'><b>[html_encode(speaker)]</b></span><br>[replacetext(html_encode(text), "\n", "<br>")]")

// ---------------------------------------------------------------------------------------------
// Message

/obj/babylon_tutorial/action/message
	tutorial_kind = "message"
	kind_name = "Message"
	kind_desc = "Tells the player something: a Guide box in chat, or a speaker (NPC or marked object) says it aloud."
	ui_icon = "message"
	view_icon = 'icons/hud/screen_gen.dmi'
	view_state = "talk_help"

/obj/babylon_tutorial/action/message/own_schema()
	return list(
		babylon_tutorial_field("text", "Text", "longtext", "", "What to say. \[player] is replaced by the player's name.", required = TRUE, placeholder = "Hi \[player]! See the scanner on the table?"),
		babylon_tutorial_field("style", "Style", "choice", "chat", "Guide box: a highlighted message only the player sees. Speaker: someone in the world says it aloud.", options = babylon_tutorial_options(list("chat" = "Guide box in chat", "speaker" = "Spoken by a speaker"))),
		babylon_tutorial_field("guide_name", "Guide name", "text", "Guide", "The name above the Guide box.", when = list("style" = list("chat"))),
		babylon_tutorial_field("speaker", "Speaker", "id", "", "An NPC spawner (its NPC speaks) or a marker (the object on it speaks).", filter = list("npc", "marker"), when = list("style" = list("speaker")), required = TRUE),
		babylon_tutorial_field("hint", "Screen hint", "text", "", "Optional: a short hint that pops up over the player for important steps."),
	)

/obj/babylon_tutorial/action/message/perform(datum/babylon_tutorial_run/run)
	var/text = babylon_tutorial_fill_text(setting("text"), run.player)
	if(setting("style") == "speaker")
		var/atom/movable/speaker = babylon_tutorial_speaker(setting("speaker"))
		if(speaker)
			speaker.say(text, forced = "tutorial")
		else
			to_chat(run.player, babylon_tutorial_guide_message("Guide", text))
	else
		to_chat(run.player, babylon_tutorial_guide_message(setting("guide_name") || "Guide", text))
	var/hint = setting("hint")
	if(length(hint))
		run.player.balloon_alert(run.player, babylon_tutorial_fill_text(hint, run.player))
	run.player.playsound_local(get_turf(run.player), 'sound/misc/bloop.ogg', 30, FALSE)

/obj/babylon_tutorial/action/message/summary()
	var/text = setting("text")
	return length(text) ? "\"[copytext_char(text, 1, 40)][length_char(text) > 40 ? "…" : ""]\"" : "no text yet"

/// The atom that speaks for an id: a spawner's NPC, a marker's object, or the marker itself
/// (named after its speaker name) when its tile is empty.
/proc/babylon_tutorial_speaker(id)
	var/obj/babylon_tutorial/found = babylon_tutorial_find(id)
	if(!found)
		return null
	var/atom/target = found.target_atom()
	if(ismovable(target))
		return target
	if(istype(found, /obj/babylon_tutorial/marker))
		found.name = found.setting("speaker_name") || "Guide"
		return found
	return null

// ---------------------------------------------------------------------------------------------
// Point

/obj/babylon_tutorial/action/point
	tutorial_kind = "point"
	kind_name = "Point"
	kind_desc = "Points at a target: a speaker points at it and an arrow over it shows the player where to look."
	ui_icon = "arrow-pointer"
	view_icon = 'icons/hud/screen_gen.dmi'
	view_state = "arrow"

/obj/babylon_tutorial/action/point/own_schema()
	return list(
		babylon_tutorial_field("target", "Target", "id", "", "What to point at: a marker (its object or tile) or an NPC spawner (its NPC).", filter = list("marker", "npc"), required = TRUE),
		babylon_tutorial_field("from", "Pointed at by", "choice", "arrow", "Arrow only: a bouncing arrow over the target. A speaker: an NPC or marked object also points at it, again and again.", options = babylon_tutorial_options(list("arrow" = "Arrow only", "speaker" = "A speaker and the arrow"))),
		babylon_tutorial_field("speaker", "Speaker", "id", "", "Who points.", filter = list("npc", "marker"), when = list("from" = list("speaker")), required = TRUE),
		babylon_tutorial_field("duration", "Show for (seconds)", "number", 15, "How long the arrow stays (the speaker points again every 4 seconds meanwhile).", min = 1, max = 600),
	)

/obj/babylon_tutorial/action/point/perform(datum/babylon_tutorial_run/run)
	var/atom/target = babylon_tutorial_resolve(setting("target"))
	if(!target)
		return
	var/duration = setting("duration") SECONDS
	var/image/arrow = image('icons/hud/screen_gen.dmi', target, "arrow_large", ABOVE_ALL_MOB_LAYER)
	SET_PLANE_EXPLICIT(arrow, POINT_PLANE, target)
	arrow.pixel_y = 20
	arrow.appearance_flags = RESET_COLOR | RESET_ALPHA | KEEP_APART
	animate(arrow, pixel_y = 28, time = 5, loop = -1, easing = SINE_EASING)
	animate(pixel_y = 20, time = 5, easing = SINE_EASING)
	run.show_image(arrow, duration)
	if(setting("from") == "speaker")
		var/atom/movable/speaker = babylon_tutorial_speaker(setting("speaker"))
		if(speaker)
			run.repeat_point(speaker, target, world.time + duration)

/obj/babylon_tutorial/action/point/summary()
	return "at [setting("target") || "?"]"

/// Lets a speaker point: a mob uses its own point, an object (a marked machine, a hidden
/// marker) gets a visible arrow flying from its tile.
/proc/babylon_tutorial_point(atom/movable/speaker, atom/target)
	if(ismob(speaker))
		var/mob/pointer = speaker
		if(babylon_tutorial_awake(pointer))
			pointer.point_at(target, TRUE)
		return
	var/turf/origin = get_turf(speaker)
	var/turf/destination = get_turf(target)
	if(!origin || !destination || origin.z != destination.z)
		return
	var/obj/effect/temp_visual/point/visual = new(origin, 0)
	animate(visual, pixel_x = (destination.x - origin.x) * ICON_SIZE_X + target.pixel_x, pixel_y = (destination.y - origin.y) * ICON_SIZE_Y + target.pixel_y, time = 1.7, easing = EASE_OUT)

// ---------------------------------------------------------------------------------------------
// Highlight

/obj/babylon_tutorial/action/highlight
	tutorial_kind = "highlight"
	kind_name = "Highlight"
	kind_desc = "Outlines a target for a while, so the player spots it."
	ui_icon = "highlighter"
	view_icon = 'icons/hud/screen_gen.dmi'
	view_state = "selector"

/obj/babylon_tutorial/action/highlight/own_schema()
	return list(
		babylon_tutorial_field("target", "Target", "id", "", "A marker (its object) or an NPC spawner (its NPC).", filter = list("marker", "npc"), required = TRUE),
		babylon_tutorial_field("duration", "Seconds", "number", 10, null, min = 1, max = 600),
		babylon_tutorial_field("color", "Colour", "choice", "#ffd34d", null, options = babylon_tutorial_options(list("#ffd34d" = "Yellow", "#4dffb8" = "Green", "#4db8ff" = "Blue", "#ff6b6b" = "Red"))),
	)

/obj/babylon_tutorial/action/highlight/perform(datum/babylon_tutorial_run/run)
	var/atom/target = babylon_tutorial_resolve(setting("target"))
	if(!target)
		return
	var/image/glow = image(loc = target)
	glow.appearance = target.appearance
	glow.loc = target
	glow.pixel_x = 0
	glow.pixel_y = 0
	glow.pixel_w = 0
	glow.pixel_z = 0
	glow.dir = target.dir
	glow.alpha = 255
	glow.layer = target.layer + 0.01
	glow.mouse_opacity = MOUSE_OPACITY_TRANSPARENT
	glow.appearance_flags |= KEEP_APART | RESET_TRANSFORM
	glow.filters = filter(type = "outline", size = 2, color = setting("color") || "#ffd34d")
	animate(glow.filters[1], size = 1, time = 6, loop = -1)
	animate(size = 2, time = 6)
	run.show_image(glow, setting("duration") SECONDS)

/obj/babylon_tutorial/action/highlight/summary()
	return "[setting("target") || "?"] for [setting("duration")] s"

// ---------------------------------------------------------------------------------------------
// Teleport

/obj/babylon_tutorial/action/teleport
	tutorial_kind = "teleport"
	kind_name = "Teleport"
	kind_desc = "Moves the player to a marker."
	ui_icon = "person-walking-arrow-right"
	view_icon = 'icons/effects/landmarks_static.dmi'
	view_state = "portal_exit"

/obj/babylon_tutorial/action/teleport/own_schema()
	return list(
		babylon_tutorial_field("target", "Marker", "id", "", "Where the player goes.", filter = list("marker"), required = TRUE),
	)

/obj/babylon_tutorial/action/teleport/perform(datum/babylon_tutorial_run/run)
	var/obj/babylon_tutorial/marker = babylon_tutorial_find(setting("target"))
	var/turf/destination = get_turf(marker)
	if(!destination)
		return
	run.player.buckled?.unbuckle_mob(run.player, TRUE)
	run.player.forceMove(destination)

/obj/babylon_tutorial/action/teleport/summary()
	return "to [setting("target") || "?"]"

// ---------------------------------------------------------------------------------------------
// Spawn NPC

/obj/babylon_tutorial/action/spawn_npc
	tutorial_kind = "spawn_npc"
	kind_name = "Spawn NPC"
	kind_desc = "Makes an NPC spawner create its NPC (again: an existing one is replaced)."
	ui_icon = "person-circle-plus"
	view_icon = 'icons/effects/mapping_helpers.dmi'
	view_state = "mobspawner"

/obj/babylon_tutorial/action/spawn_npc/own_schema()
	return list(
		babylon_tutorial_field("target", "NPC spawner", "id", "", null, filter = list("npc"), required = TRUE),
	)

/obj/babylon_tutorial/action/spawn_npc/perform(datum/babylon_tutorial_run/run)
	var/obj/babylon_tutorial/npc_spawner/spawner = babylon_tutorial_find(setting("target"))
	if(istype(spawner))
		spawner.spawn_npc()
		SSbabylon_tutorial.refresh_hooks()

/obj/babylon_tutorial/action/spawn_npc/summary()
	return "[setting("target") || "?"]"

// ---------------------------------------------------------------------------------------------
// Give item

/obj/babylon_tutorial/action/give_item
	tutorial_kind = "give_item"
	kind_name = "Give item"
	kind_desc = "Puts an item into the player's hand (or at their feet when both hands are full)."
	ui_icon = "gift"
	view_icon = 'icons/effects/landmarks_static.dmi'
	view_state = "random_loot"

/obj/babylon_tutorial/action/give_item/own_schema()
	return list(
		babylon_tutorial_field("item_type", "Item", "typepath", "", null, base = /obj/item, required = TRUE, placeholder = "Search items, e.g. analyzer"),
	)

/obj/babylon_tutorial/action/give_item/perform(datum/babylon_tutorial_run/run)
	var/path = text2path(setting("item_type"))
	if(!ispath(path, /obj/item) || !babylon_tutorial_type_allowed(path, null))
		return
	var/obj/item/gift = new path(get_turf(run.player))
	run.player.put_in_hands(gift)

/obj/babylon_tutorial/action/give_item/summary()
	return babylon_tutorial_type_label(setting("item_type"))

// ---------------------------------------------------------------------------------------------
// Enable / disable triggers

/obj/babylon_tutorial/action/toggle
	tutorial_kind = "toggle"
	kind_name = "Enable/disable triggers"
	kind_desc = "Switches triggers on or off, to chain steps (only the next step's triggers listen)."
	ui_icon = "toggle-on"
	view_icon = 'icons/effects/mapping_helpers.dmi'
	view_state = "component"

/obj/babylon_tutorial/action/toggle/own_schema()
	return list(
		babylon_tutorial_field("mode", "Do", "choice", "enable", null, options = babylon_tutorial_options(list("enable" = "Enable", "disable" = "Disable"))),
		babylon_tutorial_field("triggers", "Triggers", "idlist", list(), null, filter = list("trigger"), required = TRUE),
	)

/obj/babylon_tutorial/action/toggle/perform(datum/babylon_tutorial_run/run)
	var/enable = setting("mode") != "disable"
	for(var/id in setting("triggers"))
		var/obj/babylon_tutorial/trigger/trigger = babylon_tutorial_find(id)
		if(istype(trigger))
			run.set_enabled(trigger, enable)

/obj/babylon_tutorial/action/toggle/summary()
	return "[setting("mode")] [jointext(setting("triggers"), ", ")]"

// ---------------------------------------------------------------------------------------------
// Sound

/obj/babylon_tutorial/action/sound
	tutorial_kind = "sound"
	kind_name = "Sound"
	kind_desc = "Plays a sound for the player."
	ui_icon = "volume-high"
	view_icon = 'icons/effects/mapping_helpers.dmi'
	view_state = "sound"

/// Sound name => file: the sounds a tutorial may play.
/proc/babylon_tutorial_sounds()
	return list(
		"ding" = 'sound/machines/ding.ogg',
		"chime" = 'sound/machines/chime.ogg',
		"ping" = 'sound/machines/ping.ogg',
		"confirm" = 'sound/machines/high_tech_confirm.ogg',
		"radar" = 'sound/machines/radar-ping.ogg',
		"click" = 'sound/machines/click.ogg',
		"buzzer" = 'sound/machines/warning-buzzer.ogg',
		"bloop" = 'sound/misc/bloop.ogg',
		"ready" = 'sound/misc/server-ready.ogg',
		"pop" = 'sound/effects/pop.ogg',
		"clap" = 'sound/machines/slowclap.ogg',
		"trombone" = 'sound/misc/sadtrombone.ogg',
	)

/obj/babylon_tutorial/action/sound/own_schema()
	var/list/names = list()
	for(var/name in babylon_tutorial_sounds())
		names[name] = capitalize(name)
	return list(
		babylon_tutorial_field("sound", "Sound", "choice", "ding", null, options = babylon_tutorial_options(names)),
		babylon_tutorial_field("volume", "Volume (%)", "number", 60, null, min = 5, max = 100),
	)

/obj/babylon_tutorial/action/sound/perform(datum/babylon_tutorial_run/run)
	var/sound_file = babylon_tutorial_sounds()[setting("sound")]
	if(sound_file)
		run.player.playsound_local(get_turf(run.player), sound_file, setting("volume"), FALSE)

/obj/babylon_tutorial/action/sound/summary()
	return "[setting("sound")]"

// ---------------------------------------------------------------------------------------------
// Complete

/obj/babylon_tutorial/action/complete
	tutorial_kind = "complete"
	kind_name = "Complete"
	kind_desc = "Ends the tutorial: the player sees the \"Tutorial complete!\" screen with a way back to the lobby."
	ui_icon = "flag-checkered"
	view_icon = 'icons/effects/landmarks_static.dmi'
	view_state = "tdome_admin"

/obj/babylon_tutorial/action/complete/own_schema()
	return list(
		babylon_tutorial_field("text", "Closing words", "longtext", "Well done, \[player]! You finished this tutorial.", "Shown on the completion screen. \[player] is replaced by the player's name."),
	)

/obj/babylon_tutorial/action/complete/perform(datum/babylon_tutorial_run/run)
	run.complete(babylon_tutorial_fill_text(setting("text"), run.player))

/// The "Tutorial complete!" screen (tgui BabylonTutorialComplete).
/datum/babylon_tutorial_complete
	var/datum/babylon_tutorial_run/run
	var/text
	var/test_run

/datum/babylon_tutorial_complete/New(datum/babylon_tutorial_run/run, text)
	src.run = run
	src.text = text
	test_run = run.test_run

/datum/babylon_tutorial_complete/ui_state(mob/user)
	return GLOB.always_state

/datum/babylon_tutorial_complete/ui_interact(mob/user, datum/tgui/ui)
	ui = SStgui.try_update_ui(user, src, ui)
	if(!ui)
		ui = new(user, src, "BabylonTutorialComplete")
		ui.open()

/datum/babylon_tutorial_complete/ui_static_data(mob/user)
	return list(
		"text" = text,
		"test_run" = !!test_run,
		"title" = GLOB.babylon_world?.tutorial_id,
	)

/datum/babylon_tutorial_complete/ui_act(action, list/params, datum/tgui/ui, datum/ui_state/state)
	. = ..()
	if(.)
		return
	switch(action)
		if("lobby")
			if(test_run)
				return FALSE
			ui.close()
			usr.client?.babylon_return_lobby()
			return TRUE
		if("close")
			ui.close()
			return TRUE
