// Authenticated integration-test helpers shared by both test builds (babylon-test.dme,
// babylon-station-test.dme); excluded from production builds.
GLOBAL_DATUM_INIT(babylon_debug, /datum/babylon_debug, new)

// Exercises the same native HTTP export as the admission gate, without a client.
/datum/babylon_save/proc/test_supervisor_export(encoded_query)
	return babylon_supervisor_request(json_decode(encoded_query))

/datum/babylon_save/proc/test_afk_policy()
	var/datum/babylon_afk/policy = new
	var/list/result = list()
	result["active"] = isnull(policy.update(839 SECONDS, 15 MINUTES))
	result["warning_boundary"] = policy.update(840 SECONDS, 15 MINUTES) == "warn"
	result["warning_once"] = isnull(policy.update(850 SECONDS, 15 MINUTES))
	result["activity_cancels_warning"] = isnull(policy.update(1 SECONDS, 15 MINUTES)) && !policy.warned
	result["warning_rearmed"] = policy.update(840 SECONDS, 15 MINUTES) == "warn"
	result["kick_boundary"] = policy.update(15 MINUTES, 15 MINUTES) == "kick"
	result["kick_once"] = isnull(policy.update(901 SECONDS, 15 MINUTES))
	result["activity_cancels_kick"] = isnull(policy.update(0, 15 MINUTES)) && !policy.kick_pending
	result["kick_rearmed"] = policy.update(15 MINUTES, 15 MINUTES) == "kick"
	result["disabled"] = isnull(policy.update(100 MINUTES, 0)) && !policy.kick_pending && !policy.warned
	result["short_timeout_warning"] = policy.update(1 SECONDS, 10 SECONDS) == "warn"
	result["short_timeout_kick"] = policy.update(10 SECONDS, 10 SECONDS) == "kick"
	qdel(policy)
	return result

/datum/babylon_debug/proc/resolve_target(reference)
	switch(reference)
#ifdef BABYLON_DRONE
		if("builder")
			return GLOB.babylon_save.owner_player()?.builder
#endif
		if("session")
			return GLOB.babylon_save
		if("master")
			return Master
		if("air")
			return SSair
		if("machines")
			return SSmachines
	if(!istext(reference))
		return null
	return locate(reference)

/datum/babylon_debug/proc/pack_value(value, depth = 0)
	if(isnull(value) || isnum(value) || istext(value))
		return value
	if(ispath(value))
		return list("typepath" = "[value]")
	if(islist(value))
		var/list/values = value
		var/list/entries = list()
		if(depth < 2)
			for(var/index in 1 to min(length(values), 50))
				var/key = values[index]
				entries += list(list("entry" = pack_value(key, depth + 1), "value" = istext(key) ? pack_value(values[key], depth + 1) : null))
		return list("length" = length(values), "entries" = entries)
	if(istype(value, /datum))
		var/datum/object = value
		var/list/description = list("ref" = REF(object), "type" = "[object.type]")
		if(isatom(object))
			var/atom/thing = object
			description["name"] = thing.name
			description["x"] = thing.x
			description["y"] = thing.y
			description["z"] = thing.z
		return description
	return "[value]"

/datum/babylon_debug/proc/unpack_value(value)
	if(!islist(value))
		return value
	var/list/encoded = value
	if("ref" in encoded)
		return resolve_target(encoded["ref"])
	if("typepath" in encoded)
		return text2path(encoded["typepath"])
	if("turf" in encoded)
		var/list/coordinates = encoded["turf"]
		if(length(coordinates) == 3)
			return locate(coordinates[1], coordinates[2], coordinates[3])
		return null
	var/list/decoded = list()
	for(var/index in 1 to length(encoded))
		decoded += list(unpack_value(encoded[index]))
	return decoded

/datum/babylon_debug/proc/admin_request(action, list/request)
#ifdef BABYLON_STATION
	var/datum/target = resolve_target(request["target"] || "session")
#else
	var/datum/target = resolve_target(request["target"] || "builder")
#endif
	if(action == "find")
		var/type_filter = text2path(request["type"])
		if(!ispath(type_filter, /atom))
			return list("error" = "find requires an atom type path")
		var/list/matches = list()
		var/limit = clamp(text2num("[request["limit"]]") || 30, 1, 100)
		for(var/atom/thing in world)
			if(istype(thing, type_filter))
				matches += list(pack_value(thing))
				if(length(matches) >= limit)
					break
		return list("matches" = matches, "limit" = limit)
	if(action == "spawn")
		var/spawn_type = text2path(request["type"])
		var/atom/location = unpack_value(request["location"])
		if(!location && isatom(target))
			location = get_turf(target)
		if(!ispath(spawn_type, /atom/movable) || !isatom(location))
			return list("error" = "spawn requires a movable atom type and an atom location")
		var/atom/movable/created = new spawn_type(location)
		return list("ok" = TRUE, "object" = pack_value(created))
	if(!istype(target) || QDELETED(target))
		return list("error" = "Target missing, deleted, or not a datum")
	if(action == "inspect")
		var/list/result = list("object" = pack_value(target))
		var/list/fields = request["vars"]
		if(islist(fields))
			var/list/values = list()
			for(var/field in fields)
				if(field in target.vars)
					values[field] = pack_value(target.vars[field])
			result["vars"] = values
		else
			var/list/names = list()
			for(var/field in target.vars)
				names += field
			result["var_names"] = names
		return result
	if(action == "set_var")
		var/field = request["var"]
		if(!(field in target.vars))
			return list("error" = "Unknown variable")
		target.vars[field] = unpack_value(request["value"])
		return list("ok" = TRUE, "value" = pack_value(target.vars[field]))
	if(action == "call")
		var/procedure = request["proc"]
		if(!istext(procedure) || !hascall(target, procedure))
			return list("error" = "Unknown procedure")
		var/list/arguments = unpack_value(request["args"] || list())
		if(!islist(arguments))
			return list("error" = "args must be an array")
		return list("ok" = TRUE, "result" = pack_value(call(target, procedure)(arglist(arguments))))
	if(action == "delete")
		qdel(target)
		return list("ok" = TRUE)
	return list("error" = "Unknown admin action")

// Reproduce an invalid material identity without changing real stock.
/datum/material_container/proc/babylon_test_invalid_material()
	materials[null] = 0
	return TRUE

/// Joining must not preload the whole .rsc: DreamSeeker keeps its start splash up until it is done.
/datum/babylon_save/proc/test_join_loading()
	var/list/result = list()
	result["resources_load_on_demand"] = /client::preload_rsc == 0
	return result

/datum/babylon_save/proc/test_showcase_visitor()
	var/roster_before = length(player_sessions)
	var/turf/start = respawn_turf
	var/turf/destination = get_step(start, EAST)
	var/mob/dead/observer/babylon_visitor/visitor = new(start)
	var/obj/structure/closet/crate/crate = new(destination)
	var/obj/item/screwdriver/tool = new(start)
	var/list/result = list()
	result["visible_to_living"] = !visitor.invisibility && visitor.alpha > 0
	result["observer_without_body"] = isobserver(visitor) && !visitor.can_reenter_corpse && !visitor.mind
	result["no_inventory"] = !length(visitor.contents) && !visitor.put_in_hands(tool) && tool.loc == start
	result["no_physical_actions"] = !visitor.can_perform_action(crate, NONE) && !visitor.can_interact_with(crate) && !visitor.start_pulling(crate)
	visitor.ClickOn(crate, "left=1")
	visitor.UnarmedAttack(crate, TRUE)
	result["cannot_open_crate"] = !crate.opened
	result["no_possession"] = isnull(visitor.ghostize(can_reenter_corpse = TRUE))
	result["no_emote_actions"] = !visitor.emote("boo")
	visitor.Move(destination, EAST)
	result["passes_through_solids"] = visitor.loc == destination && crate.density
	result["faces_movement"] = visitor.dir == EAST
	var/turf/outside = locate(1, 1, station_z == 1 ? 2 : 1)
	visitor.Move(outside, NORTH)
	visitor.forceMove(outside)
	result["station_only"] = outside && visitor.loc == destination
	result["observer_tools_allowed"] = babylon_showcase_allowed_verb(/mob/dead/observer/verb/follow) && babylon_showcase_allowed_verb(/client/verb/fix_tgui_panel)
	result["ghost_powers_blocked"] = !babylon_showcase_allowed_verb(/mob/dead/observer/verb/reenter_corpse) && !babylon_showcase_allowed_verb(/mob/dead/observer/verb/observe)
	result["unknown_window_blocked"] = !babylon_showcase_window_allowed(visitor, "tgui-window-1")
	result["no_player_roster"] = length(player_sessions) == roster_before
	result["raw_machine_link_blocked"] = !babylon_showcase_topic_allowed(list("src" = REF(crate), "open" = 1))
	result["machine_ui_blocked"] = !babylon_showcase_topic_allowed(list("tgui" = TRUE, "window_id" = "tgui1", "type" = "act", "payload" = "{}"))
	result["chunk_bypass_blocked"] = !babylon_showcase_topic_allowed(list("tgui" = TRUE, "window_id" = "browseroutput", "type" = "oversizedPayloadRequest", "payload" = "{}"))
	result["forged_verb_blocked"] = !babylon_showcase_topic_allowed(list("tgui" = TRUE, "window_id" = "browseroutput", "type" = "verbs/invoke", "payload" = json_encode(list("verb_type" = "/mob/dead/observer/proc/reenter_corpse"))))
	result["chat_ready_allowed"] = babylon_showcase_topic_allowed(list("tgui" = TRUE, "window_id" = "browseroutput", "type" = "ready"))
	result["chat_metadata_without_payload"] = babylon_showcase_topic_allowed(list("tgui" = TRUE, "window_id" = "browseroutput", "type" = "requestMetadata"))
	result["chat_verbs_without_payload"] = babylon_showcase_topic_allowed(list("tgui" = TRUE, "window_id" = "browseroutput", "type" = "verbs/request_verbs"))
	result["chat_entry_allowed"] = babylon_showcase_topic_allowed(list("tgui" = TRUE, "window_id" = "tgui_say", "type" = "entry", "payload" = json_encode(list("channel" = SAY_CHANNEL, "entry" = "Hello"))))
	result["say_verb_allowed"] = babylon_showcase_topic_allowed(list("tgui" = TRUE, "window_id" = "browseroutput", "type" = "verbs/invoke", "payload" = json_encode(list("verb_type" = "/mob/verb/say_verb"))))
	result["invalid_chat_payload_blocked"] = !babylon_showcase_topic_allowed(list("tgui" = TRUE, "window_id" = "tgui_say", "type" = "entry", "payload" = "not json"))
	result["unsafe_channel_blocked"] = !babylon_showcase_topic_allowed(list("tgui" = TRUE, "window_id" = "tgui_say", "type" = "entry", "payload" = json_encode(list("channel" = ME_CHANNEL, "entry" = "boo"))))
	result["asset_link_cannot_smuggle_action"] = !babylon_showcase_topic_allowed(list("asset_cache_confirm_arrival" = 1, "src" = REF(crate), "open" = 1))
	qdel(visitor)
	qdel(crate)
	qdel(tool)
	return result

// Guards the safe-for-work build (sfw.dm): every check must be TRUE.
/datum/babylon_save/proc/test_moderation()
	var/list/result = list()
	SSplayer_ranks.mentor_controller?.add_player("babylonsmokementor")
	result["no_mentors_loaded"] = !GLOB.mentor_datums["babylonsmokementor"]
	babylon_grant_admin("babylonsmokeadmin")
	var/datum/admins/granted = GLOB.admin_datums["babylonsmokeadmin"]
	result["lobby_admin_granted"] = !!granted?.check_for_rights(R_EVERYTHING)
	GLOB.admin_datums -= "babylonsmokeadmin"
	result["reply_needs_the_player"] = babylon_discord_ahelp_reply("babylonsmokeabsent", "Mod", "Hello")["result"] == "The player is no longer in this world"
	result["ticket_commands_refused"] = !babylon_discord_ahelp_reply("babylonsmokeabsent", "Mod", "ticket close")["ok"]
	// Players' keys show on drones and ghosts; Babylon's own drone in Babylon, tg's elsewhere.
	var/named_type = babylon_is_station_build() ? /mob/living/basic/drone : text2path("/mob/living/basic/drone/babylon")
	var/mob/living/named = new named_type(respawn_turf)
	var/base = named.name
	named.key = "Smoke Namer"
	named.babylon_show_player_key()
	named.babylon_show_player_key()
	result["drone_shows_player_key"] = named.name == "[base] (Smoke Namer)"
	named.key = null
	qdel(named)
	result["station_named_after_world"] = station_name() == world.params["babylon-name"]
	var/build_commit = world.GetConfig("env", "BABYLON_COMMIT")
	result["revision_from_build"] = build_commit ? GLOB.revdata.commit == build_commit : isnull(GLOB.revdata.commit)
	result["closing_needs_a_ticket"] = babylon_discord_ahelp_close(987654, "Mod")["result"] == "That ticket does not exist in this world"
	if(babylon_is_station_build())
		// Station worlds wait in the pre-round lobby; OOC must stay on once the round starts.
		result["ooc_allowed_during_round"] = GLOB.ooc_allowed && !!CONFIG_GET(flag/ooc_during_round)
	else
		result["ooc_allowed_during_round"] = GLOB.ooc_allowed && SSticker.current_state >= GAME_STATE_PLAYING
	result["ooc_logged"] = !!CONFIG_GET(flag/log_ooc)
	return result

/datum/babylon_save/proc/test_music_loops()
	var/list/result = list()
	var/datum/babylon_music/music = new
	music.root = "data/babylon_music_loops_test/"
	fdel(music.root)
	for(var/track in list("a.ogg", "b.ogg", "c.ogg", "d.ogg", "e.ogg", "intro.ogg", "notes.txt"))
		text2file("", "[music.root]space/drift/[track]")
	text2file(json_encode(list(
		"title" = "Drift", "weight" = 3, "layers" = list("min" = 2, "max" = 3),
		"duration" = 60, "change_every" = 10, "overlap" = 0, "intro" = "intro.ogg",
		"always" = list("a.ogg"), "never_together" = list(list("b.ogg", "c.ogg")),
		"loops" = list("d.ogg" = list("volume" = 50, "weight" = 0)),
	)), "[music.root]space/drift/index.json")
	text2file("{", "[music.root]space/broken/index.json")
	text2file("", "[music.root]space/broken/x.ogg")
	text2file("", "[music.root]space/plain.ogg")
	music.scan_folder("", 0)
	var/datum/babylon_loop_set/drift
	for(var/entry in music.tracks["space"])
		if(istype(entry, /datum/babylon_loop_set))
			drift = entry
	result["plain_track_and_one_set"] = length(music.tracks["space"]) == 2 && !!drift
	result["broken_set_skipped"] = !("[music.root]space/broken/x.ogg" in music.tracks["space"])
	result["channels_reserved"] = length(music.loop_channels) >= 6
	if(!drift)
		return result
	var/path = "[music.root]space/drift/"
	result["settings_read"] = drift.title == "Drift" && drift.weight == 3 && drift.layers_min == 2 && drift.layers_max == 3 \
		&& drift.duration_min == 60 SECONDS && drift.change_min == 10 SECONDS && !drift.overlap && drift.intro == "[path]intro.ogg"
	result["loops_found"] = length(drift.loops) == 5 && drift.loops["[path]d.ogg"] == 50 && !drift.loop_weights["[path]d.ogg"]
	result["no_errors"] = !length(drift.errors)
	var/rules_kept = TRUE
	var/changed = 0
	var/list/current = drift.choose(3)
	for(var/i in 1 to 200)
		var/list/next = i % 2 ? drift.choose(rand(2, 3)) : drift.next_layers(current)
		if(!length(next ^ current))
			changed--
		changed++
		current = next
		if(!("[path]a.ogg" in current) || ("[path]d.ogg" in current) || (("[path]b.ogg" in current) && ("[path]c.ogg" in current)) \
			|| length(current) < 2 || length(current) > 3)
			rules_kept = FALSE
	result["always_never_together_and_layers_kept"] = rules_kept
	result["layers_change"] = changed > 120
	var/datum/babylon_loop_player/run = new(null, drift, 0)
	result["run_starts"] = run.advance(0) && length(run.active) >= 2 && length(run.active) <= 3
	var/list/first = run.active.Copy()
	run.advance(5 SECONDS)
	result["no_change_early"] = !length(first ^ run.active)
	for(var/second in 10 to 50 step 10)
		run.advance(second SECONDS)
	result["run_keeps_rules"] = ("[path]a.ogg" in run.active) && length(run.active) >= 2
	result["run_ends"] = run.advance(60 SECONDS) && !length(run.active) && !run.advance(70 SECONDS)
	var/datum/babylon_loop_set/errors = new
	text2file(json_encode(list("layers" = "many", "always" = list("missing.ogg"))), "[music.root]space/errors/index.json")
	text2file("", "[music.root]space/errors/z.ogg")
	result["mistakes_logged"] = errors.load("[music.root]space/errors/") && length(errors.errors) == 2
	fdel(music.root)
	qdel(run)
	return result

/datum/babylon_save/proc/test_sfw_content()
	var/list/result = list()
	// Locked on: even an explicit "off" from the config or VV leaves them on.
	var/datum/config_entry/flag/preferences = config.entries_by_type[/datum/config_entry/flag/disable_erp_preferences]
	var/datum/config_entry/flag/items = config.entries_by_type[/datum/config_entry/flag/disable_lewd_items]
	preferences.ValidateAndSet("0")
	items.ValidateAndSet("0")
	result["erp_preferences_disabled"] = !!CONFIG_GET(flag/disable_erp_preferences)
	result["lewd_items_disabled"] = !!CONFIG_GET(flag/disable_lewd_items)
	// The acting player body: a drone in Babylon, a human in station worlds.
	var/body_type = babylon_is_station_build() ? /mob/living/carbon/human/dummy : text2path("/mob/living/basic/drone/babylon/replacement")
	var/mob/living/first = new body_type(respawn_turf)
	var/mob/living/basic/mouse/second = new(respawn_turf)
	var/datum/component/interactable/menu = second.GetComponent(/datum/component/interactable)
	menu.build_interactions_list()
	var/listed_erp = FALSE
	for(var/datum/interaction/interaction as anything in menu.interactions)
		if(babylon_interaction_is_erp(interaction))
			listed_erp = TRUE
	result["no_erp_interactions_listed"] = !listed_erp
	var/allowed_erp = FALSE
	for(var/name in SSinteractions.interactions)
		var/datum/interaction/interaction = SSinteractions.interactions[name]
		if(babylon_interaction_is_erp(interaction) && menu.can_interact(interaction, first))
			allowed_erp = TRUE
	result["no_erp_interactions_allowed"] = !allowed_erp
	result["no_erp_ui_data"] = !("genitals" in menu.ui_data(first)) && !length(menu.ui_static_data(first))
	var/datum/emote/living/lewd/lewdmoan/emote = new
	result["no_lewd_emotes"] = !emote.can_run_emote(first, intentional = TRUE)
	qdel(emote)
	qdel(second)
	qdel(first)
	var/erp_designs = FALSE
	for(var/node_id in SSresearch.techweb_nodes)
		var/datum/techweb_node/node = SSresearch.techweb_nodes[node_id]
		for(var/design_id in node.design_ids)
			if(design_id in babylon_erp_design_ids())
				erp_designs = TRUE
	result["no_erp_designs"] = !erp_designs
	var/erp_reactions = FALSE
	for(var/reaction_path in GLOB.chemical_reactions_list)
		if(babylon_reaction_is_erp(GLOB.chemical_reactions_list[reaction_path]))
			erp_reactions = TRUE
	result["no_erp_reactions"] = !erp_reactions
	var/obj/item/toy/plush/bubbleplush/plush = new(respawn_turf)
	result["no_plush_toy_slot"] = !plush.plappable && !plush.atom_storage
	qdel(plush)
	return result

/datum/babylon_save
	/// Steps counted by test_tick_listener_counts().
	var/test_tick_count = 0

/datum/babylon_save/proc/test_tick_listener_fails()
	CRASH("Babylon test: a failing world tick listener (expected)")

/datum/babylon_save/proc/test_tick_listener_counts()
	test_tick_count++

/// Play time is kept per player in the checkpoint and restored with it (play_time.dm).
/datum/babylon_save/proc/test_play_time()
	var/list/result = list()
	result["text_format"] = babylon_play_time_text(3 HOURS + 7 MINUTES) == "3h 07m" && babylon_play_time_text(30 SECONDS) == "under a minute"
#ifdef BABYLON_DRONE
	var/datum/babylon_player/player = new("babylonsmokeplayer")
	player.play_time = 42 MINUTES
	var/list/snapshot = player_snapshot(player)
	var/datum/babylon_player/restored = new("babylonsmokeplayer")
	restore_player(restored, snapshot)
	result["player_time_survives_a_checkpoint"] = restored.play_time == 42 MINUTES
	var/datum/babylon_player/older = new("babylonsmokeplayer")
	restore_player(older, list())
	result["older_checkpoints_start_at_zero"] = older.play_time == 0
#endif
	// Nobody connected: time passes, play time does not.
	var/before = play_time
	play_time_counted_at = REALTIMEOFDAY - 5 SECONDS
	var/list/sessions = player_sessions
	player_sessions = list()
	count_play_time()
	player_sessions = sessions
	result["empty_world_does_not_count"] = play_time == before
	// Every module stepping with the world tick still receives it (one listener each).
	var/listening = 0
	for(var/datum/babylon_tick_listener/listener as anything in tick_listeners)
		if(listener.step && (COMSIG_BABYLON_WORLD_TICK in listener._signal_procs?[src]))
			listening++
	result["tick_listeners"] = listening == length(tick_listeners) && listening == (babylon_is_station_build() ? 4 : 2)
	// A failing listener does not keep the listeners after it from their step.
	var/datum/tick_source = new
	var/datum/babylon_tick_listener/failing = new(tick_source, CALLBACK(src, PROC_REF(test_tick_listener_fails)))
	var/datum/babylon_tick_listener/counting = new(tick_source, CALLBACK(src, PROC_REF(test_tick_listener_counts)))
	test_tick_count = 0
	SEND_SIGNAL(tick_source, COMSIG_BABYLON_WORLD_TICK)
	result["failing_listener_does_not_stop_the_next"] = test_tick_count == 1
	qdel(failing)
	qdel(counting)
	qdel(tick_source)
	// The owner's record is their own: one step with the owner playing adds it once to the
	// world and once to the owner (the owner's record used to be the session itself).
	var/datum/babylon_player/owner = owner_player() || new /datum/babylon_player(owner_ckey)
	result["owner_record_is_not_the_session"] = owner != src
	var/world_before = play_time
	var/owner_before = owner.play_time
	add_play_time(7 SECONDS, list(owner))
	result["one_step_each"] = play_time == world_before + 7 SECONDS && owner.play_time == owner_before + 7 SECONDS
	play_time = world_before
	owner.play_time = owner_before
#ifdef BABYLON_DRONE
	result["watchdog_log_shows_it"] = !!findtext(GLOB.babylon_lore.render_core_log(), "time awake, this world")
#else
	// Someone playing counts for the world and for themselves.
	var/datum/babylon_player/record = ensure_station_player("babylonsmokeplayer")
	result["station_player_record"] = record?.ckey == "babylonsmokeplayer" && player_sessions["babylonsmokeplayer"] == record
	player_sessions -= "babylonsmokeplayer"
#endif
	return result

/// Worlds that are not saved (persistent=0, tutorial kinds) never save: no save, no autosave
/// countdown, and a managed stop that reports success without one (persistence.dm, admission.dm).
/datum/babylon_save/proc/test_non_persistent_never_saves()
	var/list/result = list()
	var/datum/babylon_world/flags = GLOB.babylon_world
	var/real_persistent = flags.persistent
	var/real_kind = flags.kind
	var/real_last_save = last_save
	var/real_next_autosave = next_autosave_at
	result["persistent_world_saves"] = babylon_world_saves() == (real_persistent && !flags.is_tutorial())
	next_autosave_at = 0
	result["persistent_autosave_due"] = !babylon_world_saves() || autosave_due(1)
	flags.persistent = FALSE
	result["not_saved"] = !babylon_world_saves()
	result["save_refused"] = save_world()["error"] == "This world is not saved"
	result["no_new_save"] = last_save == real_last_save
	result["no_autosave"] = !autosave_due(1)
	result["stop_without_save"] = !babylon_stop_saves()
	result["stop_message_says_so"] = !!findtext(babylon_stop_message(FALSE), "without a save") || !!findtext(babylon_stop_message(FALSE), "not saved")
	flags.persistent = TRUE
	flags.kind = "tutorial"
	result["tutorial_not_saved"] = !babylon_world_saves() && !babylon_stop_saves() && save_world()["error"] == "This world is not saved" && !autosave_due(1)
	flags.kind = "tutorial_edit"
	result["tutorial_edit_not_saved"] = !babylon_world_saves() && !babylon_stop_saves()
	flags.kind = real_kind
	flags.persistent = real_persistent
	next_autosave_at = real_next_autosave
	result["flags_restored"] = flags.persistent == real_persistent && flags.kind == real_kind && last_save == real_last_save
	result["persistent_stop_saves"] = babylon_stop_saves() == babylon_world_saves()
#ifdef BABYLON_DRONE
	// Babylon hides the drone's save verbs in worlds that are not saved.
	var/mob/living/basic/drone/babylon/drone = owner_player()?.builder
	if(drone)
		var/list/save_verbs = list(/mob/living/basic/drone/babylon/verb/save_babylon, /mob/living/basic/drone/babylon/verb/save_stop_babylon)
		flags.persistent = FALSE
		hide_save_verbs(drone)
		result["drone_save_verbs_hidden"] = !(save_verbs[1] in drone.verbs) && !(save_verbs[2] in drone.verbs)
		flags.persistent = real_persistent
		add_verb(drone, save_verbs)
		result["drone_save_verbs_back"] = (save_verbs[1] in drone.verbs)
#endif
	return result

/obj/item/babylon_test_unsaved
	name = "unsaved test prop"

/obj/item/babylon_test_unsaved/babylon_skip_save()
	return TRUE

/// Save controls shared by both builds: a stop waits for a save in progress, the pause is
/// announced with an estimate, the autosave interval, and atoms marked babylon_skip_save().
/datum/babylon_save/proc/test_save_controls()
	var/list/result = list()
	var/real_busy = busy
	busy = TRUE
	spawn(2 SECONDS)
		busy = FALSE
	var/started = world.time
	result["stop_waits_for_a_running_save"] = await_save_idle(30 SECONDS) && world.time - started >= 2 SECONDS
	busy = TRUE
	result["wait_is_bounded"] = !await_save_idle(1 SECONDS)
	busy = real_busy
	// A second stop while one is under way answers with that stop's outcome, not a bare
	// "pending" (the supervisor would keep the run stopping for good if the first failed).
	var/real_last_stop = last_stop_result
	stop_pending = TRUE
	last_stop_result = list("error" = "first stop failed (test)")
	spawn(2 SECONDS)
		stop_pending = FALSE
	var/list/second = managed_stop()
	result["second_stop_gets_first_outcome"] = second["error"] == "first stop failed (test)" && !draining
	stop_pending = FALSE
	last_stop_result = real_last_stop
	result["pause_estimate"] = estimated_pause_seconds() >= 1
#ifdef BABYLON_STATION
	var/minutes = text2num(world.params["babylon-autosave-minutes"])
	result["station_autosave_interval"] = autosave_interval == ((isnum(minutes) && minutes >= 1) ? round(minutes) MINUTES : 30 MINUTES)
#else
	result["babylon_autosave_every_15_minutes"] = autosave_interval == 15 MINUTES
#endif
	var/obj/structure/closet/crate/crate = new(respawn_turf)
	var/obj/item/babylon_test_unsaved/prop = new(crate)
	var/obj/item/screwdriver/kept = new(crate)
	var/list/records = list()
	capture(crate, records, null)
	var/prop_saved = FALSE
	var/kept_saved = FALSE
	for(var/list/record as anything in records)
		if(record["type"] == "[prop.type]")
			prop_saved = TRUE
		if(record["type"] == "[kept.type]")
			kept_saved = TRUE
	result["skip_hook_respected"] = !prop_saved && kept_saved
	// BYOND's \improper marker never goes into a save (the file writer dropped its bytes).
	var/obj/item/screwdriver/marked = new(respawn_turf)
	marked.name = "\improper Babylon test screwdriver"
	var/list/marked_records = list()
	capture(marked, marked_records, null)
	var/list/marked_fields = marked_records[1]["fields"]
	result["text_markers_stripped"] = marked_fields["name"] == "Babylon test screwdriver" && !!findtext(metadata(marked), "name = \"Babylon test screwdriver\"")
	// A name the object still has from its type is not written at all, so the type's marker
	// comes back on load and name == initial(name) holds (records and map entries alike).
	var/obj/item/wallframe/apc/default_marked = new(respawn_turf)
	var/obj/item/screwdriver/default_plain = new(respawn_turf)
	var/list/default_records = list()
	capture(default_marked, default_records, null)
	capture(default_plain, default_records, null)
	var/defaults_left_out = length(default_records) == 2
	for(var/list/record as anything in default_records)
		var/list/fields = record["fields"]
		if(islist(fields) && ("name" in fields))
			defaults_left_out = FALSE
	result["default_name_not_saved"] = defaults_left_out && !findtext(metadata(default_marked), "name =") && !findtext(metadata(default_plain), "name =") && initial(default_marked.name) != babylon_save_text(initial(default_marked.name))
	qdel(default_marked)
	qdel(default_plain)
	// state.json's size check: exact for small files, and past 16 MB within DM's float rounding
	// (a 41 234 754-byte text measured 41 234 756 summed and 41 234 768 on disk, 12 pieces),
	// while a missing kilobyte still fails it.
	// The checkpoint layout is the build's, whatever the format version (fixtures/README.md).
	result["layout_is_the_builds"] = writes_level_files() == babylon_is_station_build() \
		&& level_file(station_z) == (babylon_is_station_build() ? "z[station_z].dmm" : "map.dmm")
	result["state_size_check"] = babylon_written_size_matches(1000, 1000, 3) && !babylon_written_size_matches(999, 1000, 3) && !babylon_written_size_matches(1001, 1000, 3) && babylon_written_size_matches(41234768, 41234756, 12) && !babylon_written_size_matches(41234756 - 1024, 41234756, 12) && !babylon_written_size_matches(41234756 + 1024, 41234756, 12)
	qdel(marked)
	qdel(crate)
	return result

/// The atlas helpers (SPLURT PRs #1395/#1396, modular_zzplurt/.../atlas_position.dm): positions and
/// the stat panel's map link share one z frame and map key, and nothing is sent or linked for a
/// map without an atlas URL (every Babylon world).
/datum/babylon_save/proc/test_atlas_frames()
	var/list/result = list()
	var/list/station_levels = SSmapping.levels_by_trait(ZTRAIT_STATION)
	var/list/centcom_levels = SSmapping.levels_by_trait(ZTRAIT_CENTCOM)
	result["station_z_counted_within_the_station"] = length(station_levels) && atlas_station_z(station_levels[1]) == 1 \
		&& atlas_station_z(station_levels[length(station_levels)]) == length(station_levels)
	result["off_station_is_null"] = !length(centcom_levels) || isnull(atlas_station_z(centcom_levels[1]))
	if(!length(station_levels))
		return result
	var/datum/map_config/current = SSmapping.current_map
	var/real_url = current.mapping_url
	var/turf/tile = locate(10, 20, station_levels[1])
	current.mapping_url = null
	result["no_url_no_link_no_key"] = isnull(atlas_map_link(tile)) && isnull(atlas_map_key()) && !atlas_map_url()
	current.mapping_url = "https://atlas.example/#m=metastation&layer=pipes"
	result["link_and_key_share_the_map"] = atlas_map_link(tile) == "https://atlas.example/#m=metastation&layer=pipes&t=10,20,1" && atlas_map_key() == "metastation"
	current.mapping_url = "https://webmap.example/metastation/"
	result["url_without_fragment"] = atlas_map_link(tile) == "https://webmap.example/metastation/#t=10,20,1" && isnull(atlas_map_key())
	if(length(centcom_levels))
		result["off_station_link_is_the_plain_url"] = atlas_map_link(locate(10, 20, centcom_levels[1])) == "https://webmap.example/metastation/"
	current.mapping_url = real_url
	// Positions run only for maps the atlas has.
	current.mapping_url = null
	var/without_url = atlas_positions_enabled()
	current.mapping_url = "https://atlas.example/#m=metastation"
	var/with_url = atlas_positions_enabled() == (CONFIG_GET(number/atlas_position_interval) > 0)
	current.mapping_url = real_url
	result["positions_only_with_url"] = !without_url && with_url
	return result

/// The atom's plane is its true plane with the multi-z offset of its own z: what a fresh map gives
/// it. A plane offset twice, or with another deck's offset, fails.
/proc/babylon_plane_consistent(atom/thing)
	if(!SSmapping.max_plane_offset)
		return TRUE
	var/turf/tile = get_turf(thing)
	if(!tile)
		return TRUE
	var/true_plane = PLANE_TO_TRUE(thing.plane)
	if(isnull(true_plane))
		return FALSE
	return thing.plane == GET_NEW_PLANE(true_plane, GET_Z_PLANE_OFFSET(tile.z))

/// Turfs and objects of one level whose plane is not consistent: list(turfs, objects).
/proc/babylon_plane_mismatches(z)
	var/turfs = 0
	var/objects = 0
	for(var/turf/tile as anything in block(1, 1, z, world.maxx, world.maxy, z))
		if(!babylon_plane_consistent(tile))
			turfs++
		for(var/obj/thing in tile)
			if(!babylon_plane_consistent(thing))
				objects++
		CHECK_TICK
	return list(turfs, objects)

/// The deck the saved-state tests use: the last station level (a deck with a plane offset on
/// multi-z maps), else the station level.
/datum/babylon_save/proc/saved_state_test_z()
	var/list/station_levels = SSmapping.levels_by_trait(ZTRAIT_STATION)
	return length(station_levels) ? station_levels[length(station_levels)] : station_z

/// Counts of state that a restored map must not decide anew, on the saved levels.
/datum/babylon_save/proc/saved_state_counts()
	var/list/levels = persisted_levels()
	var/list/counts = list("lights_not_ok" = 0, "cameras_off" = 0, "alarms_unbuilt" = 0)
	for(var/obj/machinery/light/light as anything in SSmachines.get_machines_by_type_and_subtypes(/obj/machinery/light))
		if(!QDELETED(light) && (light.z in levels) && light.status != LIGHT_OK)
			counts["lights_not_ok"]++
	for(var/obj/machinery/camera/camera as anything in SSmachines.get_machines_by_type_and_subtypes(/obj/machinery/camera))
		if(!QDELETED(camera) && (camera.z in levels) && !camera.camera_enabled)
			counts["cameras_off"]++
	for(var/obj/machinery/firealarm/alarm as anything in SSmachines.get_machines_by_type_and_subtypes(/obj/machinery/firealarm))
		if(!QDELETED(alarm) && (alarm.z in levels) && alarm.buildstage != FIRE_ALARM_BUILD_SECURED)
			counts["alarms_unbuilt"]++
	for(var/obj/machinery/airalarm/alarm as anything in SSmachines.get_machines_by_type_and_subtypes(/obj/machinery/airalarm))
		if(!QDELETED(alarm) && (alarm.z in levels) && alarm.buildstage != AIR_ALARM_BUILD_COMPLETE)
			counts["alarms_unbuilt"]++
	return counts

/// Before a save and restart: changes saved state that a map's mapload Initialize would decide
/// anew (persistence.dm, babylon_after_restore): a broken and an emptied light, a light fixture
/// built by a player with a tube in it, two cameras switched off and two half-built alarms.
/// Returns facts for test_saved_state_restored ("state", JSON).
/datum/babylon_save/proc/test_saved_state_setup()
	var/list/result = list()
	var/z = saved_state_test_z()
	var/list/markers = list()
	var/list/lights = list()
	for(var/obj/machinery/light/light as anything in SSmachines.get_machines_by_type_and_subtypes(/obj/machinery/light))
		if(!QDELETED(light) && light.z == z && isturf(light.loc) && light.status == LIGHT_OK && light.type != /obj/machinery/light/empty)
			lights += light
		if(length(lights) >= 2)
			break
	result["two_lights"] = length(lights) == 2
	if(length(lights) == 2)
		var/obj/machinery/light/broken = lights[1]
		broken.break_light_tube(TRUE)
		var/obj/machinery/light/emptied = lights[2]
		emptied.status = LIGHT_EMPTY
		emptied.update(FALSE)
		markers += list(list("kind" = "light", "x" = broken.x, "y" = broken.y, "z" = broken.z, "dir" = broken.dir, "expect" = LIGHT_BROKEN))
		markers += list(list("kind" = "light", "x" = emptied.x, "y" = emptied.y, "z" = emptied.z, "dir" = emptied.dir, "expect" = LIGHT_EMPTY))
	// A fixture a player built against a wall, with a tube put in.
	var/obj/machinery/light/fixture
	for(var/turf/open/floor/tile in block(2, 2, z, world.maxx - 1, world.maxy - 1, z))
		if(tile.is_blocked_turf(TRUE) || (locate(/obj/machinery/light) in tile) || babylon_area_locked(tile))
			continue
		for(var/direction in GLOB.cardinals)
			if(isclosedturf(get_step(tile, direction)))
				fixture = new /obj/machinery/light/empty(tile)
				fixture.setDir(direction)
				break
		if(fixture)
			break
	if(fixture)
		fixture.status = LIGHT_OK
		fixture.update(FALSE)
		markers += list(list("kind" = "light", "x" = fixture.x, "y" = fixture.y, "z" = fixture.z, "dir" = fixture.dir, "expect" = LIGHT_OK, "type" = "[/obj/machinery/light/empty]"))
	result["player_fixture"] = fixture?.status == LIGHT_OK
	var/cameras = 0
	for(var/obj/machinery/camera/camera as anything in SSmachines.get_machines_by_type_and_subtypes(/obj/machinery/camera))
		if(cameras >= 2)
			break
		if(QDELETED(camera) || !(camera.z in persisted_levels()) || !camera.camera_enabled || !isturf(camera.loc))
			continue
		camera.toggle_cam(null, FALSE)
		cameras++
		markers += list(list("kind" = "camera", "x" = camera.x, "y" = camera.y, "z" = camera.z, "expect" = FALSE))
	for(var/alarm_type in list(/obj/machinery/firealarm, /obj/machinery/airalarm))
		for(var/obj/machinery/alarm as anything in SSmachines.get_machines_by_type_and_subtypes(alarm_type))
			if(QDELETED(alarm) || !(alarm.z in persisted_levels()) || !isturf(alarm.loc))
				continue
			alarm.vars["buildstage"] = 1 // FIRE_ALARM_BUILD_NO_WIRES, AIR_ALARM_BUILD_NO_WIRES
			alarm.set_panel_open(TRUE)
			alarm.update_appearance()
			markers += list(list("kind" = "alarm", "x" = alarm.x, "y" = alarm.y, "z" = alarm.z, "type" = "[alarm_type]", "expect" = 1))
			break
	var/list/planes = babylon_plane_mismatches(z)
	result["planes_turfs_fresh"] = planes[1] == 0
	result["state"] = json_encode(list("markers" = markers, "counts" = saved_state_counts(), "plane_objects" = planes[2], "z" = z))
	return result

/// After the save above was restored: the saved light, camera and alarm states came back, none
/// was decided anew by the map's Initialize (the counts match), and every turf and object on the
/// tested deck has its deck's plane (no offset applied twice).
/datum/babylon_save/proc/test_saved_state_restored(state_json)
	var/list/result = list()
	var/list/state = json_decode(state_json)
	var/list/before = state["counts"]
	var/list/now = saved_state_counts()
	for(var/key in before)
		result["[key]_kept"] = now[key] == before[key]
		if(now[key] != before[key])
			result["[key]: [before[key]] before, [now[key]] after"] = FALSE
	var/markers_ok = TRUE
	for(var/list/marker as anything in state["markers"])
		var/turf/tile = locate(marker["x"], marker["y"], marker["z"])
		var/found = FALSE
		switch(marker["kind"])
			if("light")
				for(var/obj/machinery/light/light in tile)
					if(light.dir == marker["dir"] && (!marker["type"] || "[light.type]" == marker["type"]))
						found = light.status == marker["expect"]
			if("camera")
				for(var/obj/machinery/camera/camera in tile)
					found = camera.camera_enabled == marker["expect"] && !camera.can_use()
			if("alarm")
				var/alarm_type = text2path(marker["type"])
				var/obj/machinery/alarm = locate(alarm_type) in tile
				found = !!alarm && alarm.vars["buildstage"] == marker["expect"] && alarm.panel_open
		if(!found)
			markers_ok = FALSE
			result["marker [marker["kind"]] at [marker["x"]],[marker["y"]],[marker["z"]] not as saved"] = FALSE
	result["markers_as_saved"] = markers_ok && length(state["markers"]) >= 3
	var/list/planes = babylon_plane_mismatches(state["z"])
	result["planes_turfs_consistent"] = planes[1] == 0
	result["planes_objects_consistent"] = planes[2] <= state["plane_objects"]
	if(planes[1] || planes[2] > state["plane_objects"])
		result["planes on z[state["z"]]: [planes[1]] turfs, [planes[2]] objects (before [state["plane_objects"]])"] = FALSE
	return result

/// A copy pasted on a deck with a plane offset: its turfs and objects get that deck's plane, not
/// the source's offset again (area_tools.dm babylon_area_metadata). Station multi-z smoke only;
/// reports offset_deck = FALSE elsewhere.
/datum/babylon_save/proc/test_area_paste_planes()
	var/list/result = list()
	var/deck
	for(var/z in SSmapping.levels_by_trait(ZTRAIT_STATION))
		if(SSmapping.max_plane_offset && GET_Z_PLANE_OFFSET(z) > 0)
			deck = z
			break
	result["offset_deck"] = !!deck
	if(!deck)
		return result
	// Two free 3x1 floor runs on that deck: the copy and where it goes.
	var/list/runs = list()
	for(var/turf/open/floor/tile in block(2, 2, deck, world.maxx - 4, world.maxy - 1, deck))
		var/free = TRUE
		for(var/dx in 0 to 2)
			var/turf/step = locate(tile.x + dx, tile.y, deck)
			if(!istype(step, /turf/open/floor) || step.is_blocked_turf(TRUE) || length(step.contents) || babylon_area_locked(step))
				free = FALSE
				break
		if(!free)
			continue
		if(length(runs) && get_dist(runs[1], tile) < 6)
			continue
		runs += tile
		if(length(runs) == 2)
			break
	result["free_floor"] = length(runs) == 2
	if(length(runs) < 2)
		return result
	var/turf/source = runs[1]
	var/turf/target = runs[2]
	new /obj/item/wrench(source)
	new /obj/structure/chair(locate(source.x + 1, source.y, deck))
	var/datum/babylon_area_clip/clip = babylon_area_capture(source.x, source.y, source.x + 2, source.y, deck)
	var/list/counts = list()
	var/error = babylon_area_place(clip, target, "auto", null, FALSE, "[world.port]-planetest", counts)
	result["pasted"] = isnull(error) && !!(locate(/obj/item/wrench) in target) && !!(locate(/obj/structure/chair) in locate(target.x + 1, target.y, deck))
	var/consistent = TRUE
	for(var/dx in 0 to 2)
		var/turf/tile = locate(target.x + dx, target.y, deck)
		if(!babylon_plane_consistent(tile))
			consistent = FALSE
			result["turf [tile.x],[tile.y] plane [tile.plane]"] = FALSE
		for(var/obj/thing in tile)
			if(!babylon_plane_consistent(thing))
				consistent = FALSE
				result["[thing.type] plane [thing.plane]"] = FALSE
	result["pasted_planes_consistent"] = consistent
	return result
