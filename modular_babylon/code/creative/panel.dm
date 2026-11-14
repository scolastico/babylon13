// The Creative panel (tgui BabylonCreative): every player in a creative world gets a Creative
// action button and a "Creative panel" verb that open it. Tabs: Self (powers.dm), Spawn
// (spawning.dm), Teleport (teleport.dm), Events (events.dm) and Tools (powers.dm); other modules
// add tabs through /datum/babylon_creative_panel/proc/tabs (the Tutorial tab mounts there).
//
// Every action is checked on the server: Creative is on, the acting mob is the panel owner's own
// body, spawns and events are rate-limited, paths are validated, amounts and coordinates
// clamped. Nothing here reaches outside this world: no VV, proc calls, SDQL, bans or
// announcements. Every action is written to the game log with the player's key.

/// Searches per panel at most one per this many deciseconds (the panel debounces typing).
#define BABYLON_CREATIVE_SEARCH_COOLDOWN 2

/// ckey => /datum/babylon_creative_panel
GLOBAL_LIST_EMPTY(babylon_creative_panels)
/// Every Creative button handed out, so all can be taken back when Creative is switched off.
GLOBAL_LIST_EMPTY(babylon_creative_buttons)

/// A mob that may use the Creative panel: Creative is on and it is a living body of a player who
/// is not a showcase visitor or spectating admin.
/proc/babylon_creative_eligible(mob/user)
	if(!babylon_creative_enabled() || !isliving(user) || QDELETED(user))
		return FALSE
	var/client/player = user.client
	if(player && (player.babylon_showcase_visitor || player.babylon_admin_spectator))
		return FALSE
	return TRUE

/// The player's panel, created on first use.
/proc/babylon_creative_panel_for(ckey)
	RETURN_TYPE(/datum/babylon_creative_panel)
	if(!ckey)
		return null
	var/datum/babylon_creative_panel/panel = GLOB.babylon_creative_panels[ckey]
	if(!panel)
		panel = new(ckey)
		GLOB.babylon_creative_panels[ckey] = panel
	return panel

/// Opens the panel for a player's body. FALSE (with a message) when they may not use it.
/proc/babylon_creative_open(mob/user)
	if(!babylon_creative_eligible(user) || !user.ckey)
		if(user)
			to_chat(user, span_warning("The Creative panel is only available in creative worlds, in your own body."))
		return FALSE
	var/datum/babylon_creative_panel/panel = babylon_creative_panel_for(user.ckey)
	panel.ui_interact(user)
	return panel

/// Grants or removes the Creative button and verb to match whether this mob may use the panel.
/// Runs on every login (new body, body swap, ghosting) and on every world tick as a backstop.
/proc/babylon_creative_sync(mob/user)
	if(QDELETED(user))
		return
	var/datum/action/babylon_creative/button
	for(var/datum/action/babylon_creative/held in user.actions)
		button = held
	var/client/player = user.client
	if(babylon_creative_eligible(user))
		if(!button)
			button = new(user)
			button.Grant(user)
			GLOB.babylon_creative_buttons += button
		if(player && !(/client/proc/babylon_creative_panel in player.verbs))
			add_verb(player, /client/proc/babylon_creative_panel)
		return
	if(button)
		qdel(button)
	if(player && (/client/proc/babylon_creative_panel in player.verbs))
		remove_verb(player, /client/proc/babylon_creative_panel)

/mob/Login()
	. = ..()
	babylon_creative_sync(src)

/// Creative was switched off while the world runs: close every panel, take back the buttons,
/// verbs and powers.
/proc/babylon_creative_shutdown()
	for(var/ckey in GLOB.babylon_creative_panels)
		SStgui.close_uis(GLOB.babylon_creative_panels[ckey])
	for(var/datum/action/babylon_creative/button as anything in GLOB.babylon_creative_buttons.Copy())
		if(!QDELETED(button))
			qdel(button)
	GLOB.babylon_creative_buttons.Cut()
	for(var/client/player as anything in GLOB.clients)
		if(player?.mob)
			babylon_creative_sync(player.mob)
	babylon_creative_revoke_powers()
	babylon_creative_end_events()
	log_game("BABYLON CREATIVE: Creative was switched off; panels closed, powers removed, panel events ended.")

/datum/babylon_save
	/// Creative was on at the last world tick (to notice it being switched off).
	var/creative_was_on = FALSE
	/// Alternates every world tick: events are stepped every two seconds, as SSevents would.
	var/creative_event_phase = FALSE

/datum/babylon_save/New()
	. = ..()
	tick_listeners += new /datum/babylon_tick_listener(src, CALLBACK(src, PROC_REF(tick_creative)))

/datum/babylon_save/proc/tick_creative()
	if(!babylon_creative_enabled())
		if(creative_was_on)
			creative_was_on = FALSE
			babylon_creative_shutdown()
		return
	creative_was_on = TRUE
	for(var/client/player as anything in GLOB.clients)
		if(babylon_ready_client(player) && player.mob)
			babylon_creative_sync(player.mob)
	babylon_creative_prune_panels()
	creative_event_phase = !creative_event_phase
	if(creative_event_phase)
		babylon_creative_step_events()

/// Steps the running round events where SSevents does not (the Babylon build), at its pace.
/proc/babylon_creative_step_events()
	if(!babylon_creative_events_need_stepping())
		return FALSE
	for(var/datum/round_event/event as anything in SSevents.running.Copy())
		if(QDELETED(event))
			SSevents.running -= event
			continue
		event.process(2)
	return TRUE

/// Drops the panels of players who left this world (their rate limits go with them after a
/// minute away, so leaving and rejoining does not reset a limit right away).
/proc/babylon_creative_prune_panels()
	for(var/ckey in GLOB.babylon_creative_panels.Copy())
		var/datum/babylon_creative_panel/panel = GLOB.babylon_creative_panels[ckey]
		if(GLOB.directory[ckey])
			panel.left_at = null
			continue
		panel.left_at ||= world.time
		if(world.time - panel.left_at >= 1 MINUTES)
			GLOB.babylon_creative_panels -= ckey
			qdel(panel)

/datum/action/babylon_creative
	name = "Creative"
	desc = "Open the Creative panel: godmode, noclip, spawning, teleporting, events and tools."
	button_icon = 'modular_babylon/icons/babylon_creative.dmi'
	button_icon_state = "creative"
	show_to_observers = FALSE

/datum/action/babylon_creative/Destroy()
	GLOB.babylon_creative_buttons -= src
	return ..()

/datum/action/babylon_creative/Trigger(mob/clicker, trigger_flags)
	if(!..())
		return FALSE
	return !!babylon_creative_open(owner)

/client/proc/babylon_creative_panel()
	set name = "Creative panel"
	set category = "Babylon"
	set desc = "Godmode, noclip, spawning, teleporting, events and tools for this creative world."
	babylon_creative_open(mob)

/datum/babylon_creative_panel
	/// The player this panel belongs to; only their own body may use it.
	var/ckey
	/// world.time of recent spawns (one entry per created object) and events, for the rate limits.
	var/list/spawn_times = list()
	var/list/event_times = list()
	var/search_query = ""
	var/search_category = "all"
	var/list/search_results = list()
	var/search_capped = FALSE
	/// The last action's outcome, shown in the panel.
	var/notice
	var/notice_ok = TRUE
	var/notice_id = 0
	/// world.time of the last search (searches are at most one per BABYLON_CREATIVE_SEARCH_COOLDOWN).
	var/last_search = -INFINITY
	/// list(query, category) of a search that came in during the cooldown; run when it ends.
	var/list/pending_search
	/// world.time the owner was last seen gone from the world, for pruning.
	var/left_at
	/// Where the owner was before their last teleport, for "Back".
	var/datum/weakref/teleport_back

/datum/babylon_creative_panel/New(ckey)
	src.ckey = ckey

/datum/babylon_creative_panel/Destroy()
	SStgui.close_uis(src)
	return ..()

/datum/babylon_creative_panel/ui_interact(mob/user, datum/tgui/ui)
	ui = SStgui.try_update_ui(user, src, ui)
	if(!ui)
		ui = new(user, src, "BabylonCreative")
		ui.open()

/datum/babylon_creative_panel/ui_state(mob/user)
	return GLOB.always_state

/datum/babylon_creative_panel/ui_status(mob/user, datum/ui_state/state)
	if(user?.ckey != ckey || !babylon_creative_eligible(user))
		return UI_CLOSE
	return UI_INTERACTIVE

/// The panel's tabs, in order: list(id, name, icon). Modules add theirs by overriding this
/// (calling ..()) together with extension_data() and extension_action().
/datum/babylon_creative_panel/proc/tabs(mob/user)
	return list(
		list("id" = "self", "name" = "Self", "icon" = "user-shield"),
		list("id" = "spawn", "name" = "Spawn", "icon" = "cube"),
		list("id" = "teleport", "name" = "Teleport", "icon" = "location-arrow"),
		list("id" = "events", "name" = "Events", "icon" = "bolt"),
		list("id" = "tools", "name" = "Kits", "icon" = "toolbox"),
	)

/// Data for tabs other modules add, merged into ui_data under "extensions".
/datum/babylon_creative_panel/proc/extension_data(mob/user)
	return list()

/// Actions of tabs other modules add. TRUE when handled (the panel then refreshes).
/datum/babylon_creative_panel/proc/extension_action(mob/living/user, action, list/params)
	return FALSE

/datum/babylon_creative_panel/ui_static_data(mob/user)
	var/list/data = list()
	data["tabs"] = tabs(user)
	data["categories"] = babylon_creative_categories()
	data["levels"] = babylon_creative_levels()
	data["areas"] = babylon_creative_areas()
	data["events"] = babylon_creative_events()
	data["wand_available"] = ispath(babylon_tutorial_wand_type(), /obj/item)
	data["kit"] = babylon_creative_curated(babylon_creative_kit_types())
	data["show_markers"] = babylon_tutorial_capable()
	data["map_size"] = list("x" = world.maxx, "y" = world.maxy)
	data["limits"] = list(
		"spawns" = BABYLON_CREATIVE_SPAWN_LIMIT,
		"spawn_window" = BABYLON_CREATIVE_SPAWN_WINDOW / (1 SECONDS),
		"copies" = BABYLON_CREATIVE_MAX_COPIES,
		"events" = BABYLON_CREATIVE_EVENT_LIMIT,
		"event_window" = BABYLON_CREATIVE_EVENT_WINDOW / (1 SECONDS),
	)
	return data

/datum/babylon_creative_panel/ui_data(mob/user)
	var/list/data = list()
	var/mob/living/body = isliving(user) ? user : null
	data["godmode"] = !!(body && babylon_creative_godmode(body))
	data["godmode_elsewhere"] = !!(body && HAS_TRAIT(body, TRAIT_GODMODE) && !babylon_creative_godmode(body))
	data["noclip"] = !!body?.babylon_creative_noclip
	data["dead"] = body?.stat == DEAD
	data["health"] = body ? clamp(round(100 * body.health / max(1, body.maxHealth)), -100, 100) : 0
	data["body"] = body ? body.name : ""
	var/turf/here = get_turf(user)
	data["position"] = here ? list("x" = here.x, "y" = here.y, "z" = here.z, "area" = get_area_name(here, TRUE)) : null
	data["players"] = babylon_creative_players(user)
	data["markers"] = babylon_tutorial_capable() ? babylon_creative_markers() : list()
	data["search"] = list("query" = search_query, "category" = search_category, "results" = search_results, "capped" = search_capped)
	data["spawns_left"] = budget_left(spawn_times, BABYLON_CREATIVE_SPAWN_LIMIT, BABYLON_CREATIVE_SPAWN_WINDOW)
	data["spawns_refill_in"] = refill_in(spawn_times, BABYLON_CREATIVE_SPAWN_WINDOW)
	data["events_left"] = budget_left(event_times, BABYLON_CREATIVE_EVENT_LIMIT, BABYLON_CREATIVE_EVENT_WINDOW)
	data["events_refill_in"] = refill_in(event_times, BABYLON_CREATIVE_EVENT_WINDOW)
	data["can_go_back"] = !!teleport_back?.resolve()
	data["respawn_pending"] = babylon_creative_respawn_pending(user)
	data["notice"] = notice ? list("text" = notice, "ok" = notice_ok, "id" = notice_id) : null
	data["extensions"] = extension_data(user)
	return data

/datum/babylon_creative_panel/ui_act(action, list/params, datum/tgui/ui, datum/ui_state/state)
	. = ..()
	if(.)
		return
	return handle_action(ui.user, action, params)

/// Drops entries older than `window` from `times`; how many more fit under `limit`.
/datum/babylon_creative_panel/proc/budget_left(list/times, limit, window)
	while(length(times) && times[1] <= world.time - window)
		times.Cut(1, 2)
	return max(0, limit - length(times))

/// Seconds until the oldest entry of `times` leaves the window (one more fits), or 0.
/datum/babylon_creative_panel/proc/refill_in(list/times, window)
	if(!length(times))
		return 0
	return max(0, round((times[1] + window - world.time) / (1 SECONDS), 1))

/// The "slow down" text for a spawn that does not fit the rate limit.
/datum/babylon_creative_panel/proc/spawn_limit_text()
	var/left = budget_left(spawn_times, BABYLON_CREATIVE_SPAWN_LIMIT, BABYLON_CREATIVE_SPAWN_WINDOW)
	if(!left)
		return "No spawns left right now: wait [refill_in(spawn_times, BABYLON_CREATIVE_SPAWN_WINDOW)] seconds."
	return "Only [left] spawn[left == 1 ? "" : "s"] left right now: lower the amount or wait a few seconds."

/datum/babylon_creative_panel/proc/report(text, ok = TRUE)
	notice = text
	notice_ok = ok
	notice_id++
	return TRUE

/proc/babylon_creative_log(mob/user, text)
	log_game("BABYLON CREATIVE: [key_name(user)] [text]")

/// Player-sent text for the log: one line, at most 120 characters.
/proc/babylon_creative_clean(value)
	var/static/regex/breaks = regex(@"[\r\n\t]", "g")
	return breaks.Replace(copytext("[value]", 1, 121), " ")

/proc/babylon_creative_where(atom/place)
	var/turf/spot = get_turf(place)
	return spot ? "([spot.x],[spot.y],[spot.z])" : "(nowhere)"

/**
 * One panel action for `user`. Refused unless Creative is on and `user` is the owner's own
 * body. Returns TRUE when the panel should refresh. Callable without tgui (tests).
 */
/datum/babylon_creative_panel/proc/handle_action(mob/user, action, list/params)
	if(!istext(action))
		return FALSE
	if(!babylon_creative_eligible(user) || user.ckey != ckey)
		return FALSE
	var/mob/living/body = user
	params = islist(params) ? params : list()
	switch(action)
		if("godmode")
			var/enabled = babylon_creative_set_godmode(body, !babylon_creative_godmode(body))
			babylon_creative_log(body, "turned godmode [enabled ? "on" : "off"].")
			return report(enabled ? "Godmode on: nothing can hurt you." : "Godmode off.")
		if("noclip")
			var/turf/before = get_turf(body)
			var/enabled = babylon_creative_set_noclip(body, !body.babylon_creative_noclip)
			babylon_creative_log(body, "turned noclip [enabled ? "on" : "off"] at [babylon_creative_where(before)].")
			if(enabled)
				return report("Noclip on: you move through walls.")
			if(get_turf(body) != before)
				return report("Noclip off. You were moved out of the wall to the nearest free spot.")
			return report("Noclip off.")
		if("heal")
			if(babylon_creative_respawn_pending(body))
				return report("Your body is being replaced; heal the new one once it arrives.", FALSE)
			var/was_dead = body.stat == DEAD
			babylon_creative_heal(body)
			babylon_creative_log(body, "healed themselves[was_dead ? " (revived)" : ""].")
			return report(was_dead ? "Revived and fully healed." : "Fully healed.")
		if("search")
			var/query = copytext_char(trim("[params["query"]]"), 1, 65)
			var/category = "[params["category"]]"
			category = (category in babylon_creative_category_ids()) ? category : "all"
			if(world.time < last_search + BABYLON_CREATIVE_SEARCH_COOLDOWN)
				// Too soon: answer the latest request once the cooldown is over, so the panel never
				// waits on a search that was dropped.
				pending_search = list(query, category)
				addtimer(CALLBACK(src, PROC_REF(run_pending_search)), last_search + BABYLON_CREATIVE_SEARCH_COOLDOWN - world.time, TIMER_UNIQUE | TIMER_OVERRIDE)
				return FALSE
			run_search(query, category)
			return TRUE
		if("spawn")
			return act_spawn(body, params)
		if("teleport_coords")
			var/turf/destination = babylon_creative_coordinates_turf(params["x"], params["y"], params["z"])
			if(!destination)
				return report("Those coordinates are not on one of this world's levels.", FALSE)
			return finish_teleport(body, destination, "coordinates [destination.x], [destination.y], [destination.z]")
		if("teleport_area")
			var/turf/destination = babylon_creative_area_turf(params["path"], body, text2num("[params["z"]]"))
			if(!destination)
				return report("That area is not part of this world.", FALSE)
			return finish_teleport(body, destination, get_area_name(destination, TRUE))
		if("teleport_player")
			var/client/player = GLOB.directory[ckey(params["ckey"])]
			var/mob/target = player?.mob
			if(!target || target == body || player.babylon_showcase_visitor || player.babylon_admin_spectator || isnewplayer(target))
				return report("That player is not in this world.", FALSE)
			return finish_teleport(body, get_turf(target), "[player.key]")
		if("teleport_back")
			var/turf/back = teleport_back?.resolve()
			if(!back)
				return report("There is no earlier spot to go back to.", FALSE)
			return finish_teleport(body, back, "your earlier spot")
		if("teleport_marker")
			var/list/targets = babylon_tutorial_capable() ? babylon_tutorial_marker_targets() : list()
			var/id = "[params["id"]]"
			if(!(id in targets))
				return report("There is no marker with that id.", FALSE)
			return finish_teleport(body, get_turf(targets[id]), "marker [id]")
		if("run_event")
			if(!budget_left(event_times, BABYLON_CREATIVE_EVENT_LIMIT, BABYLON_CREATIVE_EVENT_WINDOW))
				return report("No events left right now: the next one is possible in [refill_in(event_times, BABYLON_CREATIVE_EVENT_WINDOW)] seconds.", FALSE)
			var/result = babylon_creative_run_event(body, params["path"])
			if(istext(result))
				babylon_creative_log(body, "was refused event [babylon_creative_clean(params["path"])]: [result]")
				return report(result, FALSE)
			var/datum/round_event/started = result
			event_times += world.time
			babylon_creative_log(body, "started the event [started.control.name] ([started.control.type]).")
			return report("Started: [started.control.name].")
		if("give_tools")
			if(!budget_left(spawn_times, BABYLON_CREATIVE_SPAWN_LIMIT, BABYLON_CREATIVE_SPAWN_WINDOW))
				return report(spawn_limit_text(), FALSE)
			babylon_creative_give_tools(body)
			spawn_times += world.time
			babylon_creative_log(body, "took the creative tool kit at [babylon_creative_where(body)].")
			return report("Tool kit ready: toolbelt, insulated gloves, RCD and RPD.")
		if("give_wand")
			if(!ispath(babylon_tutorial_wand_type(), /obj/item))
				return report("The tutorial wand is coming soon.", FALSE)
			if(!budget_left(spawn_times, BABYLON_CREATIVE_SPAWN_LIMIT, BABYLON_CREATIVE_SPAWN_WINDOW))
				return report(spawn_limit_text(), FALSE)
			var/obj/item/wand = babylon_creative_give_wand(body)
			spawn_times += world.time
			babylon_creative_log(body, "took a tutorial wand at [babylon_creative_where(body)].")
			return report("[capitalize(wand?.name || "tutorial wand")] is in your hand.")
	return extension_action(body, action, params)

/datum/babylon_creative_panel/proc/run_search(query, category)
	last_search = world.time
	pending_search = null
	search_query = query
	search_category = category
	var/list/answer = babylon_creative_search(search_query, search_category)
	search_results = answer["results"]
	search_capped = answer["capped"]

/datum/babylon_creative_panel/proc/run_pending_search()
	if(!pending_search || QDELETED(src))
		return
	run_search(pending_search[1], pending_search[2])
	SStgui.update_uis(src)

/datum/babylon_creative_panel/proc/act_spawn(mob/living/body, list/params)
	var/path = text2path("[params["path"]]")
	if(babylon_creative_spawn_blocked(path))
		babylon_creative_log(body, "was refused spawning [babylon_creative_clean(params["path"])].")
		return report("That cannot be spawned.", FALSE)
	var/amount = round(text2num("[params["amount"]]") || 1)
	var/count = ispath(path, /obj/item/stack) ? 1 : clamp(amount, 1, BABYLON_CREATIVE_MAX_COPIES)
	if(budget_left(spawn_times, BABYLON_CREATIVE_SPAWN_LIMIT, BABYLON_CREATIVE_SPAWN_WINDOW) < count)
		return report(spawn_limit_text(), FALSE)
	var/in_hand = !!params["in_hand"] && params["in_hand"] != "0" && ispath(path, /obj/item)
	var/result = babylon_creative_spawn(body, path, amount, in_hand)
	if(istext(result))
		return report(result, FALSE)
	var/list/created = result
	for(var/i in 1 to count)
		spawn_times += world.time
	var/atom/movable/first = length(created) ? created[1] : null
	var/label = first ? first.name : "[path]"
	if(istype(first, /obj/item/stack))
		var/obj/item/stack/stack = first
		label = "[stack.amount] x [stack.singular_name || stack.name]"
	else if(length(created) > 1)
		label = "[length(created)] x [label]"
	var/held = in_hand && first?.loc == body
	babylon_creative_log(body, "spawned [label] ([path]) at [babylon_creative_where(body)][held ? " in hand" : ""].")
	if(in_hand && !held)
		return report("Spawned [label] at your feet: your hands are full.")
	return report("Spawned [label][held ? " in your hands" : " at your feet"].")

/datum/babylon_creative_panel/proc/finish_teleport(mob/living/body, turf/destination, label)
	var/turf/from = get_turf(body)
	var/error = babylon_creative_teleport(body, destination)
	if(error)
		babylon_creative_log(body, "was refused a teleport to [label]: [error]")
		return report(error, FALSE)
	if(from)
		teleport_back = WEAKREF(from)
	babylon_creative_log(body, "teleported from [babylon_creative_where(from)] to [label] [babylon_creative_where(body)].")
	return report("Teleported to [label].")

/// Babylon: the player's drone is dead and a replacement is on its way (drone_recovery.dm).
/proc/babylon_creative_respawn_pending(mob/user)
#ifdef BABYLON_DRONE
	var/datum/babylon_player/player = GLOB.babylon_save?.player_sessions[user?.ckey]
	return !!player?.respawn_pending
#else
	return FALSE
#endif
