// Tutorial actions (spec 7.2, 12 #21): what happens when a trigger fires. A trigger runs its
// actions in order; each action may wait (its delay) after the ones before it. There is one run
// per world: everything an action shows goes to every player in the world (chat, images, local
// sounds), and actions that target "the player" (teleport, give item, damage, heal ...) hit EVERY
// living player. A preview runs an action for the builder who pressed Preview only.

/// Runs the action for the run's players.
/obj/babylon_tutorial/action/proc/perform(datum/babylon_tutorial_run/run)
	return

/// "[player]" in builder text becomes the player's name.
/proc/babylon_tutorial_fill_text(text, mob/player)
	return replacetext("[text]", "\[player]", player ? player.real_name : "you")

/// The friendly "Guide" chat box, headed with the speaker's name. Lines are kept.
/proc/babylon_tutorial_guide_message(speaker, text)
	return custom_boxed_message("green_box", "<span class='nicegreen' style='font-size: 110%'><b>[html_encode(speaker)]</b></span><br><span class='notice'>[replacetext(html_encode(text), "\n", "<br>")]</span>")

/// "Show until" for actions that show something: the next step, some seconds, or a trigger.
/proc/babylon_tutorial_until_fields(default_seconds)
	return list(
		babylon_tutorial_field("until", "Show until", "choice", "next", "The next step: until a trigger listening after this step fires (at most 10 minutes).", options = babylon_tutorial_options(list("next" = "The next step's trigger fires", "seconds" = "Some seconds have passed", "trigger" = "A chosen trigger fires"))),
		babylon_tutorial_field("duration", "Seconds", "number", default_seconds, null, min = 1, max = 600, when = list("until" = list("seconds"))),
		babylon_tutorial_field("until_trigger", "Until trigger", "id", "", null, filter = list("trigger"), when = list("until" = list("trigger")), required = TRUE),
	)

/// "Until the next step" on an action whose trigger has no next step lasts the full 10 minutes.
/obj/babylon_tutorial/action/proc/until_issue()
	if(setting("until") != "next")
		return null
	for(var/obj/babylon_tutorial/trigger/trigger in GLOB.babylon_tutorial_objects)
		if((tutorial_id in trigger.action_ids()) && !length(babylon_tutorial_triggers_after(trigger)))
			return "No step comes after [trigger.tutorial_id], so this never ends before 10 minutes. Choose some seconds or a trigger."
	return null

/obj/babylon_tutorial/action/point/find_issues()
	. = ..()
	var/issue = until_issue()
	if(issue)
		.["until"] = issue

/obj/babylon_tutorial/action/highlight/find_issues()
	. = ..()
	var/issue = until_issue()
	if(issue)
		.["until"] = issue

/// How long something shown by an action lasts at most.
/obj/babylon_tutorial/action/proc/show_duration()
	return setting("until") == "seconds" ? setting("duration") SECONDS : 10 MINUTES

/// A speaker says something to every player of the run. TRUE when at least one heard it spoken.
/proc/babylon_tutorial_speak(datum/babylon_tutorial_run/run, atom/movable/speaker, text)
	. = FALSE
	for(var/mob/player as anything in run.audience())
		if(babylon_tutorial_speak_to(player, speaker, text))
			. = TRUE

/// A speaker says something to one player only, in say style with a chat bubble over the
/// speaker. When the player could not hear it (too far, another level, the speaker is out cold or
/// dead), it arrives as a Guide box headed with the speaker's name instead.
/proc/babylon_tutorial_speak_to(mob/player, atom/movable/speaker, text)
	var/name = speaker ? speaker.name : "Guide"
	var/audible = speaker && get_dist(speaker, player) <= 7 && speaker.z == player.z
	if(isliving(speaker) && !babylon_tutorial_awake(speaker))
		audible = FALSE
	if(!audible)
		to_chat(player, babylon_tutorial_guide_message(name, text))
		return FALSE
	for(var/line in splittext(text, "\n"))
		line = trim(line)
		if(!length(line))
			continue
		to_chat(player, "<span class='game say'><span class='name'>[html_encode(name)]</span> <span class='message'>says, \"[html_encode(line)]\"</span></span>")
		// Runechat over the speaker, for this player only (it needs their client).
		if(player.client)
			player.create_chat_message(speaker, null, line)
	return TRUE

// ---------------------------------------------------------------------------------------------
// Message

/obj/babylon_tutorial/action/message
	tutorial_kind = "message"
	kind_name = "Message"
	kind_desc = "Tells every player something: a Guide box in chat, or an NPC or marked object says it to them."
	kind_example = "e.g. \"Grab the health analyzer from the table.\""
	ui_icon = "message"
	view_icon = 'icons/hud/screen_gen.dmi'
	view_state = "talk_help"

/obj/babylon_tutorial/action/message/own_schema()
	return list(
		babylon_tutorial_field("text", "Text", "longtext", "", "What to say. \[player] is replaced by each player's own name.", required = TRUE, placeholder = "Hi \[player]! See the scanner on the table?"),
		babylon_tutorial_field("style", "Style", "choice", "chat", "Guide box: a highlighted message in every player's chat. Speaker: an NPC or marked object says it (only the tutorial's players hear it).", options = babylon_tutorial_options(list("chat" = "Guide box in chat", "speaker" = "Spoken by a speaker"))),
		babylon_tutorial_field("guide_name", "Guide name", "text", "Guide", "The name above the Guide box.", when = list("style" = list("chat")), is_name = TRUE),
		babylon_tutorial_field("speaker", "Speaker", "id", "", "An NPC spawner (its NPC speaks) or a marker (the object on it speaks). A player too far away to hear gets the text as a Guide box instead.", filter = list("npc", "marker"), when = list("style" = list("speaker")), required = TRUE),
		babylon_tutorial_field("hint", "Objective (stays on screen)", "text", "", "Optional: a short goal shown on every player's screen until the next objective or the end, e.g. \"Scan the patient\"."),
	)

/obj/babylon_tutorial/action/message/perform(datum/babylon_tutorial_run/run)
	var/title = setting("guide_name") || "Guide"
	var/atom/movable/speaker
	if(setting("style") == "speaker")
		speaker = babylon_tutorial_speaker(setting("speaker"))
		title = speaker ? speaker.name : title
	for(var/mob/player as anything in run.audience())
		var/text = babylon_tutorial_fill_text(setting("text"), player)
		if(setting("style") == "speaker")
			babylon_tutorial_speak_to(player, speaker, text)
		else
			to_chat(player, babylon_tutorial_guide_message(title, text))
		player.playsound_local(get_turf(player), 'sound/misc/bloop.ogg', 30, FALSE)
	var/hint = setting("hint")
	if(length(hint))
		// "[player]" is filled in on each player's own screen.
		run.set_objective(hint, title)

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
	kind_desc = "Shows every player where to look: an arrow over the target, and a speaker can point at it."
	kind_example = "e.g. point at the health analyzer until a player picks it up."
	ui_icon = "arrow-pointer"
	view_icon = 'icons/hud/screen_gen.dmi'
	view_state = "arrow"

/obj/babylon_tutorial/action/point/own_schema()
	return list(
		babylon_tutorial_field("target", "Target", "id", "", "What to point at: a marker (its object or tile) or an NPC spawner (its NPC).", filter = list("marker", "npc"), required = TRUE),
		babylon_tutorial_field("from", "Pointed at by", "choice", "arrow", "Arrow only: a bouncing arrow over the target. A speaker: an NPC or marked object also points at it, every 4 seconds.", options = babylon_tutorial_options(list("arrow" = "Arrow only", "speaker" = "A speaker and the arrow"))),
		babylon_tutorial_field("speaker", "Speaker", "id", "", "Who points.", filter = list("npc", "marker"), when = list("from" = list("speaker")), required = TRUE),
	) + babylon_tutorial_until_fields(15)

/obj/babylon_tutorial/action/point/perform(datum/babylon_tutorial_run/run)
	var/atom/target = babylon_tutorial_resolve(setting("target"))
	if(!target)
		return
	var/duration = show_duration()
	var/list/clear_on = run.clear_triggers_for(src)
	var/image/arrow = image('icons/hud/screen_gen.dmi', target, "arrow_large", ABOVE_ALL_MOB_LAYER)
	SET_PLANE_EXPLICIT(arrow, POINT_PLANE, target)
	arrow.pixel_y = 20
	arrow.appearance_flags = RESET_COLOR | RESET_ALPHA | KEEP_APART
	animate(arrow, pixel_y = 28, time = 5, loop = -1, easing = SINE_EASING)
	animate(pixel_y = 20, time = 5, easing = SINE_EASING)
	// One arrow per target: performed again (a repeating trigger, another Point action at the
	// same target), the new arrow replaces the old one.
	run.show_image(arrow, duration, target, clear_on, babylon_tutorial_image_key("arrow", target))
	if(setting("from") == "speaker")
		var/atom/movable/speaker = babylon_tutorial_speaker(setting("speaker"))
		if(speaker)
			run.repeat_point(speaker, target, world.time + duration, clear_on)

/obj/babylon_tutorial/action/point/summary()
	return "at [setting("target") || "?"]"

/// A speaker points at a target for the run's players: an arrow flies from the speaker to the
/// target (an image only they see) and players nearby read "<speaker> points at <target>.".
/// The flying arrow fades out as it arrives: the Point action's own arrow already bounces over
/// the target, and a second one resting next to it was the two-arrows bug (spec 12 #14).
/// How long a speaker's arrow flies to its target (deciseconds, as upstream pointing), and how
/// long it then takes to fade out over the target's own arrow.
#define BABYLON_TUTORIAL_POINT_FLIGHT 1.7
#define BABYLON_TUTORIAL_POINT_FADE (0.5 SECONDS)

/// The key of a run image (show_image()): what it shows, and on which atom.
/proc/babylon_tutorial_image_key(what, atom/on)
	return "[what]:[REF(on)]"

/proc/babylon_tutorial_point(datum/babylon_tutorial_run/run, atom/movable/speaker, atom/target)
	if(isliving(speaker) && !babylon_tutorial_awake(speaker))
		return
	var/turf/origin = get_turf(speaker)
	var/turf/destination = get_turf(target)
	if(!origin || !destination || origin.z != destination.z)
		return
	var/image/flying = image('icons/hud/screen_gen.dmi', origin, "arrow", ABOVE_ALL_MOB_LAYER)
	SET_PLANE_EXPLICIT(flying, POINT_PLANE, origin)
	flying.appearance_flags = RESET_COLOR | RESET_ALPHA | KEEP_APART
	animate(flying, pixel_x = (destination.x - origin.x) * ICON_SIZE_X + target.pixel_x, pixel_y = (destination.y - origin.y) * ICON_SIZE_Y + target.pixel_y, time = BABYLON_TUTORIAL_POINT_FLIGHT, easing = EASE_OUT)
	animate(alpha = 0, time = BABYLON_TUTORIAL_POINT_FADE)
	run.show_image(flying, BABYLON_TUTORIAL_POINT_FLIGHT + BABYLON_TUTORIAL_POINT_FADE, null, null, babylon_tutorial_image_key("pointing", speaker))
	for(var/mob/player as anything in run.audience())
		if(get_dist(origin, player) <= 7)
			to_chat(player, span_emote("<b>[html_encode(speaker.name)]</b> points at [html_encode(target.name)]."))

// ---------------------------------------------------------------------------------------------
// Highlight

/obj/babylon_tutorial/action/highlight
	tutorial_kind = "highlight"
	kind_name = "Highlight"
	kind_desc = "Outlines a target so the players spot it (only the tutorial's players see it)."
	kind_example = "e.g. outline the medkit on the shelf."
	ui_icon = "highlighter"
	view_icon = 'icons/hud/screen_gen.dmi'
	view_state = "selector"

/obj/babylon_tutorial/action/highlight/own_schema()
	return list(
		babylon_tutorial_field("target", "Target", "id", "", "A marker (its object) or an NPC spawner (its NPC).", filter = list("marker", "npc"), required = TRUE),
		babylon_tutorial_field("color", "Colour", "choice", "#ffd34d", null, options = babylon_tutorial_options(list("#ffd34d" = "Yellow", "#4dffb8" = "Green", "#4db8ff" = "Blue", "#ff6b6b" = "Red"))),
	) + babylon_tutorial_until_fields(10)

/obj/babylon_tutorial/action/highlight/perform(datum/babylon_tutorial_run/run)
	var/atom/target = babylon_tutorial_resolve(setting("target"))
	if(!target)
		return
	var/color = setting("color") || "#ffd34d"
	var/image/glow = image(loc = target)
	babylon_tutorial_dress_outline(glow, target, color)
	// One outline per target, and it follows the target's look (an NPC that turns or lies down).
	run.show_image(glow, show_duration(), target, run.clear_triggers_for(src), babylon_tutorial_image_key("outline", target), color)

/// Makes an image an outlined copy of an atom's current look, attached to it.
/proc/babylon_tutorial_dress_outline(image/glow, atom/target, color)
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
	glow.filters = filter(type = "outline", size = 2, color = color)
	animate(glow.filters[1], size = 1, time = 6, loop = -1)
	animate(size = 2, time = 6)

/obj/babylon_tutorial/action/highlight/summary()
	return "[setting("target") || "?"][setting("until") == "seconds" ? " for [setting("duration")] s" : ""]"

// ---------------------------------------------------------------------------------------------
// Teleport

/obj/babylon_tutorial/action/teleport
	tutorial_kind = "teleport"
	kind_name = "Teleport"
	kind_desc = "Moves every living player to a marker."
	ui_icon = "person-walking-arrow-right"
	view_icon = 'icons/effects/landmarks_static.dmi'
	view_state = "portal_exit"

/obj/babylon_tutorial/action/teleport/own_schema()
	return list(
		babylon_tutorial_field("target", "Marker", "id", "", "Where the players go.", filter = list("marker"), required = TRUE),
	)

/obj/babylon_tutorial/action/teleport/perform(datum/babylon_tutorial_run/run)
	var/obj/babylon_tutorial/marker = babylon_tutorial_find(setting("target"))
	var/turf/destination = get_turf(marker)
	if(!destination)
		return
	for(var/mob/living/player as anything in run.players())
		player.buckled?.unbuckle_mob(player, TRUE)
		player.forceMove(destination)

/obj/babylon_tutorial/action/teleport/summary()
	return "to [setting("target") || "?"]"

// ---------------------------------------------------------------------------------------------
// Spawn NPC

/obj/babylon_tutorial/action/spawn_npc
	tutorial_kind = "spawn_npc"
	preview_changes_world = TRUE
	kind_name = "Spawn NPC"
	kind_desc = "Makes an NPC spawner create its NPC again. The new NPC replaces the old one for everyone in the world."
	kind_example = "e.g. a second patient appears after the first one is treated."
	ui_icon = "person-circle-plus"
	view_icon = 'icons/effects/mapping_helpers.dmi'
	view_state = "mobspawner"

/obj/babylon_tutorial/action/spawn_npc/own_schema()
	return list(
		babylon_tutorial_field("target", "NPC spawner", "id", "", "Its NPC is created again for everyone in this world (an existing one is removed).", filter = list("npc"), required = TRUE),
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
	kind_desc = "Puts an item into every living player's hand (or at their feet when both hands are full)."
	kind_example = "e.g. hand each player a health analyzer."
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
	var/list/players = run.players()
	if(!run.claim_spawns(length(players), src))
		return
	for(var/mob/living/player as anything in players)
		var/obj/item/gift = new path(get_turf(player))
		player.put_in_hands(gift)

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
		babylon_tutorial_field("triggers", "Triggers", "idlist", list(), "A gate that is disabled turns false without running its own actions; gates it feeds see it become false. Enabled again, it is evaluated at the next check and runs its On true or On false once.", filter = list("trigger"), required = TRUE),
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
	kind_desc = "Plays a sound for every player."
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
	if(!sound_file)
		return
	for(var/mob/player as anything in run.audience())
		player.playsound_local(get_turf(player), sound_file, setting("volume"), FALSE)

/obj/babylon_tutorial/action/sound/summary()
	return "[setting("sound")]"

// ---------------------------------------------------------------------------------------------
// Complete

/obj/babylon_tutorial/action/complete
	tutorial_kind = "complete"
	kind_name = "Complete"
	kind_desc = "Ends the tutorial for the whole world: every player sees the \"Tutorial complete!\" screen with a way back to the lobby."
	ui_icon = "flag-checkered"
	view_icon = 'icons/effects/landmarks_static.dmi'
	view_state = "tdome_admin"

/obj/babylon_tutorial/action/complete/own_schema()
	return list(
		babylon_tutorial_field("text", "Closing words", "longtext", "Well done, \[player]! You finished this tutorial.", "Shown on the completion screen. \[player] is replaced by each player's own name."),
	)

/obj/babylon_tutorial/action/complete/perform(datum/babylon_tutorial_run/run)
	// "[player]" is filled in on each player's own screen.
	run.complete(setting("text"))

/// The "Tutorial complete!" screen (tgui BabylonTutorialComplete).
/datum/babylon_tutorial_complete
	var/datum/babylon_tutorial_run/run
	var/text
	var/test_run
	/// A Preview's Complete: the screen only closes. "Run again" would start the world's run for
	/// everyone, while the builder only pressed Preview (review B-I-1).
	var/preview

/datum/babylon_tutorial_complete/New(datum/babylon_tutorial_run/run, text)
	src.run = run
	src.text = text
	test_run = run.test_run
	preview = run.preview

/datum/babylon_tutorial_complete/ui_state(mob/user)
	return GLOB.always_state

/datum/babylon_tutorial_complete/ui_interact(mob/user, datum/tgui/ui)
	ui = SStgui.try_update_ui(user, src, ui)
	if(!ui)
		ui = new(user, src, "BabylonTutorialComplete")
		ui.open()

/datum/babylon_tutorial_complete/ui_static_data(mob/user)
	return list(
		"text" = babylon_tutorial_fill_text(text, user),
		"test_run" = !!test_run,
		"preview" = !!preview,
		"title" = GLOB.babylon_world?.tutorial_title,
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
			if(!test_run)
				to_chat(usr, span_notice("Look around as long as you like. To leave, use <b>Return to Babylon lobby</b> in the Babylon tab."))
			return TRUE
		if("again")
			if(!test_run || preview || !isliving(usr))
				return FALSE
			ui.close()
			babylon_tutorial_begin(TRUE, TRUE, run?.reset_npcs, list(usr))
			return TRUE

// ---------------------------------------------------------------------------------------------
// Damage / effect and Heal / revive (spec 12 #8, #19): on every player, or on one NPC.

/// "Apply to": every player or an NPC spawner's NPC.
/proc/babylon_tutorial_body_target_fields(verb_text)
	return list(
		babylon_tutorial_field("apply_to", "Apply to", "choice", "players", "Every player: each living player in the world (a revive brings back the dead ones). An NPC: the NPC of an NPC spawner.", options = babylon_tutorial_options(list("players" = "Every player", "npc" = "An NPC"))),
		babylon_tutorial_field("target", "NPC spawner", "id", "", "Its NPC is [verb_text].", filter = list("npc"), when = list("apply_to" = list("npc")), required = TRUE),
	)

/// "Apply to: an NPC" changes the shared NPC for everyone: no Preview (players stay the builder's).
/obj/babylon_tutorial/action/harm/preview_refusal()
	return setting("apply_to") == "npc" ? BABYLON_TUTORIAL_PREVIEW_WORLD_TEXT : ..()

/obj/babylon_tutorial/action/heal/preview_refusal()
	return setting("apply_to") == "npc" ? BABYLON_TUTORIAL_PREVIEW_WORLD_TEXT : ..()

/// The NPC an action with "Apply to" targets, if it exists.
/obj/babylon_tutorial/action/proc/target_npc()
	var/mob/living/npc = babylon_tutorial_resolve(setting("target"))
	return isliving(npc) && npc.babylon_tutorial_npc ? npc : null

/obj/babylon_tutorial/action/proc/npc_target_issue()
	if(setting("apply_to") != "npc")
		return null
	var/obj/babylon_tutorial/target = babylon_tutorial_find(setting("target"))
	if(istype(target, /obj/babylon_tutorial/npc_spawner) && isturf(target.target_atom()))
		return "[target.tutorial_id] has no NPC right now: spawn it first."
	return null

/// Effect key => label: what a Damage / effect action can do. Curated for teaching: the four
/// damage types (medicine), wounds and a bleeding cut (gauze, splints), fire (stop, drop and
/// roll), a knockdown, blurred or lost sight (eye care) and a few curable illnesses. Nothing that
/// takes the player's control away for long (sleep, unconsciousness) or destroys a body.
/proc/babylon_tutorial_harm_effects()
	return list(
		"brute" = "Brute damage",
		"burn" = "Burn damage",
		"tox" = "Toxin damage",
		"oxy" = "Suffocation damage",
		"bleed" = "Bleeding cut",
		"wound" = "Wound",
		"fire" = "Set on fire",
		"knockdown" = "Knocked down",
		"blur" = "Blurred vision",
		"blind" = "Blinded",
		"disease" = "Disease",
	)

/obj/babylon_tutorial/action/harm
	tutorial_kind = "harm"
	kind_name = "Damage / effect"
	kind_desc = "Hurts every living player (or an NPC) or gives them an effect: damage, a wound, fire, a knockdown, bad sight or an illness."
	kind_example = "e.g. 30 brute damage, so the players learn to treat themselves."
	ui_icon = "heart-crack"
	view_icon = 'icons/effects/mapping_helpers.dmi'
	view_state = "basic_mob_flammable"

/obj/babylon_tutorial/action/harm/own_schema()
	var/list/zones = babylon_tutorial_options(babylon_tutorial_body_zones())
	return babylon_tutorial_body_target_fields("hurt (an unhurtable NPC, or a player in god mode, is not)") + list(
		babylon_tutorial_field("effect", "Effect", "choice", "brute", "What happens to them.", options = babylon_tutorial_options(babylon_tutorial_harm_effects())),
		babylon_tutorial_field("amount", "Damage", "number", 20, "How much damage (100 is a lot: crit starts at 100 total).", min = 1, max = 200, when = list("effect" = list("brute", "burn", "tox", "oxy"))),
		babylon_tutorial_field("zone", "Body part", "choice", BODY_ZONE_CHEST, null, options = zones, when = list("effect" = list("brute", "burn", "bleed", "wound"))),
		babylon_tutorial_field("wound", "Wound", "choice", "[/datum/wound/blunt/bone/severe]", null, options = babylon_tutorial_options(babylon_tutorial_wounds()), when = list("effect" = list("wound"))),
		babylon_tutorial_field("stacks", "Fire strength", "number", 3, "Fire stacks: how long they burn (1 to 10).", min = 1, max = 10, when = list("effect" = list("fire"))),
		babylon_tutorial_field("seconds", "Seconds", "number", 5, "How long it lasts.", min = 1, max = 120, when = list("effect" = list("knockdown", "blur", "blind"))),
		babylon_tutorial_field("disease", "Disease", "choice", "[/datum/disease/cold]", "It never spreads to anyone else.", options = babylon_tutorial_options(babylon_tutorial_diseases()), when = list("effect" = list("disease"))),
	)

/obj/babylon_tutorial/action/harm/find_issues()
	. = ..()
	var/issue = npc_target_issue()
	if(issue)
		.["target"] = issue

/obj/babylon_tutorial/action/harm/perform(datum/babylon_tutorial_run/run)
	// Every effect setting with its default filled in.
	var/list/values = list()
	for(var/key in list("effect", "amount", "zone", "wound", "stacks", "seconds", "disease"))
		values[key] = setting(key)
	if(setting("apply_to") == "npc")
		var/mob/living/npc = target_npc()
		if(npc)
			babylon_tutorial_harm(npc, values)
		return
	for(var/mob/living/player as anything in run.players())
		babylon_tutorial_harm(player, values)

/obj/babylon_tutorial/action/harm/summary()
	var/effect = babylon_tutorial_harm_effects()[setting("effect")] || "?"
	var/amount = (setting("effect") in list("brute", "burn", "tox", "oxy")) ? " [setting("amount")]" : ""
	return "[effect][amount] on [setting("apply_to") == "npc" ? (setting("target") || "?") : "every player"]"

/// Applies one Damage / effect action's effect to a body. God mode (an unhurtable NPC, a builder
/// in god mode) protects. Returns TRUE when it applied.
/proc/babylon_tutorial_harm(mob/living/target, list/values)
	if(QDELETED(target) || HAS_TRAIT(target, TRAIT_GODMODE))
		return FALSE
	var/effect = values["effect"] || "brute"
	var/amount = clamp(text2num("[values["amount"]]") || 20, 1, 200)
	var/zone = values["zone"] || BODY_ZONE_CHEST
	var/obj/item/bodypart/limb
	if(iscarbon(target))
		var/mob/living/carbon/body = target
		limb = body.get_bodypart(zone) || body.get_bodypart(BODY_ZONE_CHEST)
	switch(effect)
		if("brute")
			target.apply_damage(amount, BRUTE, limb, forced = TRUE, wound_bonus = CANT_WOUND)
		if("burn")
			target.apply_damage(amount, BURN, limb, forced = TRUE, wound_bonus = CANT_WOUND)
		if("tox")
			target.adjust_tox_loss(amount, forced = TRUE)
		if("oxy")
			target.adjust_oxy_loss(amount, forced = TRUE)
		if("bleed")
			if(!limb)
				return FALSE
			var/datum/wound/slash/flesh/moderate/cut = new()
			cut.apply_wound(limb, silent = TRUE, wound_source = "tutorial")
		if("wound")
			var/wound_path = text2path(values["wound"])
			if(!limb || !babylon_tutorial_wounds()["[wound_path]"])
				return FALSE
			var/datum/wound/wound = new wound_path()
			wound.apply_wound(limb, silent = TRUE, wound_source = "tutorial")
		if("fire")
			target.adjust_fire_stacks(clamp(text2num("[values["stacks"]]") || 3, 1, 10))
			target.ignite_mob()
		if("knockdown")
			target.Knockdown(clamp(text2num("[values["seconds"]]") || 5, 1, 120) SECONDS, ignore_canstun = TRUE)
		if("blur")
			target.set_eye_blur_if_lower(clamp(text2num("[values["seconds"]]") || 5, 1, 120) SECONDS)
		if("blind")
			target.set_temp_blindness_if_lower(clamp(text2num("[values["seconds"]]") || 5, 1, 120) SECONDS)
		if("disease")
			var/disease_path = text2path(values["disease"])
			if(!babylon_tutorial_diseases()["[disease_path]"])
				return FALSE
			// Like an NPC's illness: it stays with the one who has it, never spreads.
			var/datum/disease/illness = new disease_path()
			illness.spread_flags = DISEASE_SPREAD_NON_CONTAGIOUS
			illness.spread_text = "Non-contagious"
			target.ForceContractDisease(illness, FALSE, TRUE)
		else
			return FALSE
	return TRUE

/obj/babylon_tutorial/action/heal
	tutorial_kind = "heal"
	kind_name = "Heal / revive"
	kind_desc = "Heals every living player (or an NPC) fully or one damage type, or brings dead players back into their body."
	kind_example = "e.g. revive a player who died, or heal everyone after a lesson."
	ui_icon = "kit-medical"
	view_icon = 'icons/effects/mapping_helpers.dmi'
	view_state = "injector"

/obj/babylon_tutorial/action/heal/own_schema()
	return babylon_tutorial_body_target_fields("healed or revived") + list(
		babylon_tutorial_field("heal", "Do", "choice", "full", "Full heal: all damage, wounds and illnesses. Revive: dead players (or the dead NPC) come back fully healed; a player is put back into their body, or, where the old body was destroyed, into a new one that looks the same and wears the same clothes (the ones it dropped; only lost ones are made again). Only players in their body or watching as a ghost come back. Living players are left as they are.", options = babylon_tutorial_options(list("full" = "Full heal", "type" = "Heal one damage type", "revive" = "Revive the dead"))),
		babylon_tutorial_field("damage_type", "Damage type", "choice", "brute", null, options = babylon_tutorial_damage_options(), when = list("heal" = list("type"))),
		babylon_tutorial_field("amount", "Amount", "number", 50, "How much of that damage is healed.", min = 1, max = 500, when = list("heal" = list("type"))),
	)

/obj/babylon_tutorial/action/heal/find_issues()
	. = ..()
	var/issue = npc_target_issue()
	if(issue)
		.["target"] = issue

/obj/babylon_tutorial/action/heal/perform(datum/babylon_tutorial_run/run)
	var/mode = setting("heal")
	if(setting("apply_to") == "npc")
		var/mob/living/npc = target_npc()
		if(!npc)
			return
		if(mode == "revive")
			if(npc.stat == DEAD)
				npc.revive(HEAL_ALL | HEAL_ADMIN)
			return
		babylon_tutorial_heal(npc, mode, setting("damage_type"), setting("amount"))
		return
	if(mode == "revive")
		for(var/key in run.bodies.Copy())
			run.revive_player(key)
		return
	for(var/mob/living/player as anything in run.players())
		babylon_tutorial_heal(player, mode, setting("damage_type"), setting("amount"))

/obj/babylon_tutorial/action/heal/summary()
	var/what
	switch(setting("heal"))
		if("type")
			what = "heal [setting("amount")] [setting("damage_type")]"
		if("revive")
			what = "revive"
		else
			what = "full heal"
	return "[what], [setting("apply_to") == "npc" ? (setting("target") || "?") : "every player"]"

/// Heals a living body: fully, or one damage type by an amount.
/proc/babylon_tutorial_heal(mob/living/target, mode, damage_type, amount)
	if(QDELETED(target) || target.stat == DEAD)
		return FALSE
	if(mode == "type")
		var/static/list/types = list("brute" = BRUTE, "burn" = BURN, "tox" = TOX, "oxy" = OXY)
		if(!types[damage_type])
			return FALSE
		target.heal_damage_type(clamp(text2num("[amount]") || 0, 0, 500), types[damage_type])
		return TRUE
	target.fully_heal(HEAL_ALL)
	return TRUE
