// Tutorial tests (both test builds; services/supervisor/smoke_native.py and smoke_station.py).
// Each test builds its tutorial next to the world's respawn point and removes it again.

/// Places a tutorial object for a test with validated settings; it is added to `made`.
/proc/babylon_tutorial_test_place(path, turf/tile, id, list/settings, list/made)
	var/obj/babylon_tutorial/object = new path(tile)
	made += object
	if(id)
		object.set_tutorial_id(id)
	for(var/key in settings)
		var/error = object.set_setting(key, settings[key])
		if(error)
			CRASH("tutorial test setting [key] of [id] refused: [error]")
	return object

/// A free spot to build test tutorials: next to the respawn point, away from other tests.
/datum/babylon_save/proc/tutorial_test_base(offset = 0)
	var/turf/origin = respawn_turf || locate(round(world.maxx / 2), round(world.maxy / 2), station_z || 1)
	return locate(clamp(origin.x - 6 + offset, 2, world.maxx - 12), clamp(origin.y - 6, 2, world.maxy - 12), origin.z)

/proc/babylon_tutorial_test_cleanup(list/made)
	for(var/datum/thing as anything in made)
		if(!QDELETED(thing))
			qdel(thing)

/// The trigger -> action chain the spec describes: entering a zone shows a message, holding a
/// health analyzer points at the patient, using it on the patient completes the tutorial.
/// Also: the world has one run, a second player joins it and any player can fire a step.
/datum/babylon_save/proc/test_tutorial_flow()
	var/list/result = list()
	var/list/made = list()
	var/turf/base = tutorial_test_base()
	try
		var/turf/zone_tile = locate(base.x + 2, base.y, base.z)
		babylon_tutorial_test_place(/obj/babylon_tutorial/marker, base, "start", list(), made)
		var/obj/babylon_tutorial/npc_spawner/spawner = babylon_tutorial_test_place(/obj/babylon_tutorial/npc_spawner, locate(base.x + 4, base.y + 2, base.z), "flow_patient", list("npc_name" = "Patient", "spawn_at_start" = 1), made)
		babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/zone, zone_tile, "flow_enter", list("zone" = list(zone_tile.x, zone_tile.y, zone_tile.x + 1, zone_tile.y, zone_tile.z), "actions" = list("flow_hello")), made)
		babylon_tutorial_test_place(/obj/babylon_tutorial/action/message, base, "flow_hello", list("text" = "Hi \[player], grab the analyzer."), made)
		babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/holding, base, "flow_hold", list("item_type" = "[/obj/item/healthanalyzer]", "actions" = list("flow_point")), made)
		babylon_tutorial_test_place(/obj/babylon_tutorial/action/point, base, "flow_point", list("target" = "flow_patient", "duration" = 5), made)
		babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/used_on, base, "flow_scan", list("item_type" = "[/obj/item/healthanalyzer]", "target" = "flow_patient", "actions" = list("flow_done")), made)
		babylon_tutorial_test_place(/obj/babylon_tutorial/action/complete, base, "flow_done", list(), made)

		var/mob/living/carbon/human/player = new(locate(base.x, base.y + 1, base.z))
		made += player
		player.real_name = "Tutorial Tester"
		var/datum/babylon_tutorial_run/run = babylon_tutorial_begin(TRUE, TRUE, FALSE, list(player))
		result["run_started"] = run && babylon_tutorial_current_run() == run && (player in run.players())
		result["moved_to_start"] = get_turf(player) == base
		var/mob/living/carbon/human/npc = spawner.current_npc()
		result["npc_spawned_at_start"] = istype(npc) && npc.real_name == "Patient"
		made += npc
		run.check_triggers()
		result["nothing_before_zone"] = !length(run.history)

		player.forceMove(zone_tile)
		run.check_triggers()
		result["zone_fires_message"] = run.history ~= list("flow_enter>flow_hello")
		run.check_triggers()
		result["zone_fires_once"] = length(run.history) == 1

		var/obj/item/healthanalyzer/analyzer = new(get_turf(player))
		made += analyzer
		player.put_in_hands(analyzer)
		run.check_triggers()
		result["holding_points"] = run.history ~= list("flow_enter>flow_hello", "flow_hold>flow_point")
		result["point_arrow_shared"] = length(run.images) == 1

		// A second player joins the world's run: the steps already done stay done for both.
		var/mob/living/carbon/human/other = new(locate(base.x, base.y + 1, base.z))
		made += other
		run.add_player(other)
		other.forceMove(zone_tile)
		run.check_triggers()
		result["one_run_for_both"] = babylon_tutorial_current_run() == run && (other in run.players()) && length(run.history) == 2

		// The second player, not the first, scans the patient: any player fires a step.
		var/obj/item/healthanalyzer/other_analyzer = new(get_turf(other))
		made += other_analyzer
		other.put_in_hands(other_analyzer)
		other.forceMove(get_step(npc, WEST))
		SSbabylon_tutorial.refresh_hooks()
		other_analyzer.melee_attack_chain(other, npc)
		run.check_triggers()
		result["used_on_by_any_player_completes"] = run.completed && (run.history ~= list("flow_enter>flow_hello", "flow_hold>flow_point", "flow_scan>flow_done"))
		result["completion_screen"] = !!run.complete_screen && run.complete_screen.test_run
		run.check_triggers()
		result["nothing_after_complete"] = length(run.history) == 3

		babylon_tutorial_end()
		result["end_stops_run"] = !babylon_tutorial_current_run() && QDELETED(run)
	catch(var/exception/error)
		result["no_error"] = FALSE
		log_world("test_tutorial_flow failed: [error] ([error.file]:[error.line])")
	babylon_tutorial_test_cleanup(made)
	return result

/// The other trigger kinds and the run's common settings: say, button, timer, condition,
/// enable/disable, cooldown, repeat and delays.
/datum/babylon_save/proc/test_tutorial_triggers()
	var/list/result = list()
	var/list/made = list()
	var/turf/base = tutorial_test_base(14)
	try
		var/turf/marker_tile = locate(base.x + 1, base.y + 1, base.z)
		babylon_tutorial_test_place(/obj/babylon_tutorial/action/sound, base, "trig_sound", list("sound" = "ding"), made)
		babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/say, base, "trig_say", list("phrase" = "ready", "actions" = list("trig_sound", "trig_enable")), made)
		babylon_tutorial_test_place(/obj/babylon_tutorial/action/toggle, base, "trig_enable", list("mode" = "enable", "triggers" = list("trig_button")), made)
		var/obj/babylon_tutorial/trigger/button/button = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/button, locate(base.x + 1, base.y, base.z), "trig_button", list("label" = "big red button", "starts" = "manual", "once" = 0, "cooldown" = 30, "actions" = list("trig_sound")), made)
		babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/timer, base, "trig_timer", list("seconds" = 1, "actions" = list("trig_delayed")), made)
		babylon_tutorial_test_place(/obj/babylon_tutorial/action/message, base, "trig_delayed", list("text" = "later", "delay" = 600), made)
		babylon_tutorial_test_place(/obj/babylon_tutorial/marker, marker_tile, "trig_table_spot", list("target" = "tile"), made)
		babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/condition, base, "trig_table", list("condition" = "structure", "target" = "trig_table_spot", "structure_type" = "[/obj/structure/table]", "actions" = list("trig_sound")), made)

		result["button_visible"] = button.invisibility == 0 && button.name == "big red button"
		var/mob/living/carbon/human/player = new(base)
		made += player
		var/datum/babylon_tutorial_run/run = babylon_tutorial_begin(FALSE, TRUE, FALSE, list(player))
		result["disabled_at_start"] = !run.is_enabled(button)
		button.attack_hand(player)
		run.check_triggers()
		result["disabled_button_ignored"] = !run.fired[button]

		player.say("I am READY now")
		run.check_triggers()
		result["say_fires_and_enables"] = !!run.fired[babylon_tutorial_find("trig_say")] && run.is_enabled(button)

		button.attack_hand(player)
		run.check_triggers()
		result["button_fires"] = run.fired[button] == 1
		result["repeating_stays_enabled"] = run.is_enabled(button)
		button.attack_hand(player)
		run.check_triggers()
		result["cooldown_holds"] = run.fired[button] == 1

		var/obj/babylon_tutorial/trigger/timer/timer = babylon_tutorial_find("trig_timer")
		run.enabled[timer] = world.time - 2 SECONDS
		run.check_triggers()
		result["timer_fires"] = run.fired[timer] == 1
		result["delayed_action_waits"] = !("trig_timer>trig_delayed" in run.history) && length(run.timers) >= 1

		var/obj/babylon_tutorial/trigger/condition/condition = babylon_tutorial_find("trig_table")
		run.check_triggers()
		result["condition_false_without_table"] = !run.fired[condition]
		var/obj/structure/table/table = new(marker_tile)
		made += table
		run.check_triggers()
		result["condition_fires_with_table"] = run.fired[condition] == 1
		babylon_tutorial_end()
		result["stop_cancels_delays"] = QDELETED(run) && !length(run.timers)
	catch(var/exception/error)
		result["no_error"] = FALSE
		log_world("test_tutorial_triggers failed: [error] ([error.file]:[error.line])")
	babylon_tutorial_test_cleanup(made)
	return result

/// Objects, schema, validation, persistence fields and the wand.
/datum/babylon_save/proc/test_tutorial_objects()
	var/list/result = list()
	var/list/made = list()
	var/turf/base = tutorial_test_base(28)
	try
		result["persisted_fields"] = ("tutorial_id" in extra_fields) && ("settings_json" in extra_fields)
		var/obj/babylon_tutorial/action/message/message = babylon_tutorial_test_place(/obj/babylon_tutorial/action/message, base, "obj_message", list("text" = "Hello"), made)
		var/list/save_vars = message.get_save_vars()
		result["map_export_fields"] = ("tutorial_id" in save_vars) && ("settings_json" in save_vars)
		result["hidden"] = message.invisibility == INVISIBILITY_ABSTRACT && message.mouse_opacity == MOUSE_OPACITY_TRANSPARENT && !message.density && message.anchored
		result["not_an_effect"] = !istype(message, /obj/effect)

		// Every kind has a schema with known types and unique keys.
		var/schemas_ok = length(babylon_tutorial_kinds()) >= 19
		var/list/types = list("text", "longtext", "number", "bool", "choice", "typepath", "id", "idlist", "gateinputs", "zone", "effects", "target", "loadout", "event")
		for(var/kind in babylon_tutorial_kinds())
			var/list/keys = list()
			for(var/list/field as anything in babylon_tutorial_schema(babylon_tutorial_kinds()[kind]))
				if(!(field["type"] in types) || (field["key"] in keys))
					schemas_ok = FALSE
				keys += field["key"]
		result["schemas_valid"] = schemas_ok

		// Validation.
		result["number_rejects_text"] = !!message.set_setting("delay", "soon")
		message.set_setting("delay", 9999)
		result["number_clamped"] = message.setting("delay") == 600
		result["choice_rejects_unknown"] = !!message.set_setting("style", "shout")
		result["id_rejects_bad"] = !!message.set_tutorial_id("bad id!") && message.tutorial_id == "obj_message"
		var/obj/babylon_tutorial/trigger/holding/holding = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/holding, base, "obj_hold", list(), made)
		result["typepath_rejects_blocked"] = !!holding.set_setting("item_type", "[/obj/item/grenade/flashbang]")
		result["typepath_rejects_wrong_base"] = !!holding.set_setting("item_type", "[/obj/structure/table]")
		result["typepath_accepts_item"] = isnull(holding.set_setting("item_type", "[/obj/item/healthanalyzer]"))
		result["idlist_from_text"] = isnull(holding.set_setting("actions", "obj_message, obj_message ,missing_action")) && (holding.setting("actions") ~= list("obj_message", "missing_action"))
		var/list/issues = holding.issues()
		result["dangling_reference_reported"] = findtext(issues["actions"], "missing_action") != 0
		holding.set_setting("actions", list("obj_hold"))
		result["wrong_category_reported"] = findtext(holding.issues()["actions"], "not a") != 0
		holding.set_setting("actions", list("obj_message"))
		result["valid_reference_clean"] = !holding.issues()["actions"]
		// Ids can still clash after a map paste: the clash is reported.
		var/obj/babylon_tutorial/marker/duplicate = babylon_tutorial_test_place(/obj/babylon_tutorial/marker, base, null, list(), made)
		result["taken_id_refused"] = !!duplicate.set_tutorial_id("obj_message")
		duplicate.tutorial_id = "obj_message"
		babylon_tutorial_changed()
		var/list/duplicate_issues = duplicate.issues()
		result["duplicate_id_reported"] = !!duplicate_issues["id"]
		var/found_duplicate = FALSE
		for(var/text in babylon_tutorial_overview_texts())
			if(findtext(text, "already uses the id \"obj_message\""))
				found_duplicate = TRUE
		result["overview_warns_duplicate"] = found_duplicate
		qdel(duplicate)
		result["unique_ids"] = babylon_tutorial_unique_id("obj_hold") != "obj_hold"
		result["search_finds_analyzer"] = FALSE
		for(var/list/found as anything in babylon_tutorial_search_types(babylon_tutorial_schema_field(holding.type, "item_type"), "health analyzer"))
			if(found["path"] == "[/obj/item/healthanalyzer]")
				result["search_finds_analyzer"] = TRUE

		// Persistence: the checkpoint record carries id and settings, and they come back.
		var/list/records = list()
		var/list/record = capture(message, records)
		var/list/fields = record["fields"]
		result["record_has_fields"] = fields["tutorial_id"] == "obj_message" && length(fields["settings_json"])
		var/obj/babylon_tutorial/action/message/restored = new(base)
		made += restored
		var/list/decoded = json_decode(json_encode(fields))
		for(var/field in decoded)
			if(field in restored.vars)
				restored.vars[field] = decode_value(decoded[field])
		result["settings_round_trip"] = restored.tutorial_id == "obj_message" && restored.setting("text") == "Hello" && restored.setting("delay") == 600

		// Markers and the Creative panel's lists.
		// A tile with nothing on it (station maps have furniture near the arrivals).
		var/turf/empty = locate(base.x + 1, base.y, base.z)
		for(var/turf/candidate as anything in block(locate(base.x, base.y + 4, base.z), locate(base.x + 10, base.y + 10, base.z)))
			if(!babylon_tutorial_object_on(candidate))
				empty = candidate
				break
		var/obj/babylon_tutorial/marker/spot = babylon_tutorial_test_place(/obj/babylon_tutorial/marker, empty, "obj_spot", list(), made)
		result["marker_targets"] = babylon_tutorial_marker_targets()["obj_spot"] == spot
		result["marker_stands_for_tile_when_empty"] = spot.target_atom() == get_turf(spot)
		var/obj/structure/closet/closet = new(get_turf(spot))
		made += closet
		result["marker_stands_for_object"] = spot.target_atom() == closet
		result["wand_type"] = ispath(babylon_tutorial_wand_type(), /obj/item)

		// The wand's view: one image per object (plus the focused zone), none without a holder.
		var/obj/item/babylon_tutorial_wand/wand = new(base)
		made += wand
		wand.build_images()
		result["wand_image_per_object"] = length(wand.images) == length(GLOB.babylon_tutorial_objects)
		wand.sync_view()
		result["wand_hidden_on_floor"] = !length(wand.images) && !wand.viewer
		var/mob/living/carbon/human/builder = new(base)
		made += builder
		builder.put_in_hands(wand)
		var/was_creative = GLOB.babylon_world.creative
		GLOB.babylon_world.creative = FALSE
		result["wand_refused_outside_creative"] = wand.use_on(base, builder) == ITEM_INTERACT_BLOCKING
		GLOB.babylon_world.creative = TRUE
		var/before = length(GLOB.babylon_tutorial_objects)
		wand.mode = "place"
		wand.selected_kind = "marker"
		wand.use_on(locate(base.x + 2, base.y, base.z), builder)
		result["wand_places"] = length(GLOB.babylon_tutorial_objects) == before + 1
		for(var/obj/babylon_tutorial/placed in locate(base.x + 2, base.y, base.z))
			made += placed
		wand.mode = "delete"
		wand.use_on(locate(base.x + 2, base.y, base.z), builder)
		result["wand_deletes"] = length(GLOB.babylon_tutorial_objects) == before
		wand.mode = "npc"
		wand.selected_preset = "guide"
		wand.use_on(locate(base.x + 3, base.y, base.z), builder)
		var/obj/babylon_tutorial/npc_spawner/guide = locate() in locate(base.x + 3, base.y, base.z)
		made += guide
		result["wand_places_guide"] = guide?.current_npc()?.real_name == "Guide"
		var/obj/babylon_tutorial/trigger/zone/zone = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/zone, base, "obj_zone", list(), made)
		wand.start_picking(builder, zone, "zone")
		wand.use_on(base, builder)
		wand.use_on(locate(base.x + 3, base.y + 2, base.z), builder)
		result["wand_picks_zone"] = (zone.zone() ~= list(base.x, base.y, base.x + 3, base.y + 2, base.z)) && !wand.picking
		GLOB.babylon_world.creative = was_creative
	catch(var/exception/error)
		result["no_error"] = FALSE
		log_world("test_tutorial_objects failed: [error] ([error.file]:[error.line])")
	babylon_tutorial_test_cleanup(made)
	return result

/// NPC presets: every effect applies at chance 100 and none at chance 0; NPCs are never saved.
/datum/babylon_save/proc/test_npc_effects()
	var/list/result = list()
	var/list/made = list()
	var/turf/base = tutorial_test_base(42)
	try
		var/list/effects = list(
			list("kind" = "brute", "amount" = 30, "zone" = BODY_ZONE_CHEST, "chance" = 100),
			list("kind" = "burn", "amount" = 20, "zone" = BODY_ZONE_L_ARM, "chance" = 100),
			list("kind" = "tox", "amount" = 15, "chance" = 100),
			list("kind" = "oxy", "amount" = 10, "chance" = 100),
			list("kind" = "wound", "type" = "[/datum/wound/blunt/bone/severe]", "zone" = BODY_ZONE_R_LEG, "chance" = 100),
			list("kind" = "disease", "type" = "[/datum/disease/cold]", "chance" = 100),
			list("kind" = "reagent", "type" = "[/datum/reagent/water]", "amount" = 5, "chance" = 100),
			list("kind" = "unconscious", "amount" = 60, "chance" = 100),
			list("kind" = "bleed", "amount" = 40, "zone" = BODY_ZONE_L_ARM, "chance" = 100),
		)
		var/obj/babylon_tutorial/npc_spawner/sure = babylon_tutorial_test_place(/obj/babylon_tutorial/npc_spawner, base, "npc_sure", list("npc_name" = "Sure", "outfit" = "[/datum/outfit/job/doctor]", "effects" = effects), made)
		var/mob/living/carbon/human/npc = sure.spawn_npc()
		result["named"] = npc.real_name == "Sure"
		result["dressed"] = !!npc.w_uniform
		result["no_client_no_ai"] = !npc.client && !npc.ai_controller
		result["flagged"] = npc.babylon_tutorial_npc
		result["brute"] = npc.get_brute_loss() >= 29
		result["burn"] = npc.get_fire_loss() >= 19
		result["tox"] = npc.get_tox_loss() >= 14
		result["oxy"] = npc.get_oxy_loss() >= 9
		result["wound"] = length(npc.all_wounds) >= 2
		result["disease"] = length(npc.diseases) >= 1
		result["reagent"] = !!npc.reagents.has_reagent(/datum/reagent/water)
		result["unconscious"] = !!npc.IsUnconscious()
		result["bleeding"] = npc.blood_volume < BLOOD_VOLUME_NORMAL
		result["not_saved"] = babylon_tutorial_skip_save(npc) && babylon_tutorial_skip_save(npc.w_uniform)
		result["spawner_saved"] = !babylon_tutorial_skip_save(sure)

		var/list/never = list()
		for(var/list/effect as anything in effects)
			var/list/copy = effect.Copy()
			copy["chance"] = 0
			never += list(copy)
		var/obj/babylon_tutorial/npc_spawner/never_spawner = babylon_tutorial_test_place(/obj/babylon_tutorial/npc_spawner, locate(base.x + 1, base.y, base.z), "npc_never", list("effects" = never), made)
		var/mob/living/carbon/human/healthy = never_spawner.spawn_npc()
		result["chance_zero_applies_nothing"] = !healthy.get_brute_loss() && !healthy.get_fire_loss() && !healthy.get_tox_loss() && !healthy.get_oxy_loss() && !length(healthy.all_wounds) && !length(healthy.diseases) && !healthy.IsUnconscious() && healthy.blood_volume >= BLOOD_VOLUME_NORMAL && !healthy.reagents.has_reagent(/datum/reagent/water)
		result["effects_validated"] = !!sure.set_setting("effects", list(list("kind" = "explode", "chance" = 100))) && length(sure.setting("effects")) == length(effects)

		var/mob/living/carbon/human/old = npc
		npc = sure.spawn_npc()
		result["respawn_replaces"] = QDELETED(old) && npc != old && sure.current_npc() == npc
		result["spawner_resolves_to_npc"] = babylon_tutorial_resolve("npc_sure") == npc
		qdel(sure)
		result["deleting_spawner_removes_npc"] = QDELETED(npc)

		var/obj/babylon_tutorial/npc_spawner/guide = babylon_tutorial_place_npc(locate(base.x + 2, base.y, base.z), "guide")
		made += guide
		var/mob/living/carbon/human/guide_npc = guide.current_npc()
		result["guide_preset"] = guide_npc?.real_name == "Guide" && !guide_npc.get_brute_loss() && !length(guide.setting("effects"))
		var/presets_ok = TRUE
		for(var/id in babylon_tutorial_npc_presets())
			var/obj/babylon_tutorial/npc_spawner/preset = babylon_tutorial_place_npc(locate(base.x + 3, base.y, base.z), id)
			made += preset
			if(!preset?.current_npc() || length(preset.setting("effects")) != length(babylon_tutorial_npc_presets()[id]["settings"]["effects"]))
				presets_ok = FALSE
			qdel(preset)
		result["all_presets_spawn"] = presets_ok
	catch(var/exception/error)
		result["no_error"] = FALSE
		log_world("test_npc_effects failed: [error] ([error.file]:[error.line])")
	babylon_tutorial_test_cleanup(made)
	return result

/// The review round: safe names and texts, NPC safety (reagents, diseases, unhurtable), no
/// references to deleted objects, zone limits, renaming, step chains, private speech, "until the
/// next step", the start trigger and preset ids.
/datum/babylon_save/proc/test_tutorial_review()
	var/list/result = list()
	var/list/made = list()
	var/turf/base = tutorial_test_base(56)
	try
		// Names: markup is refused or stripped, never stored.
		var/obj/babylon_tutorial/npc_spawner/spawner = babylon_tutorial_test_place(/obj/babylon_tutorial/npc_spawner, base, "rev_npc", list("npc_name" = "Patient"), made)
		var/bad = "<span class='danger'>x</span>"
		var/list/name_fields = list(list(spawner, "npc_name"))
		var/obj/babylon_tutorial/marker/speaker_marker = babylon_tutorial_test_place(/obj/babylon_tutorial/marker, locate(base.x + 2, base.y, base.z), "rev_marker", list("target" = "tile"), made)
		name_fields += list(list(speaker_marker, "speaker_name"))
		var/obj/babylon_tutorial/trigger/button/button = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/button, locate(base.x + 3, base.y, base.z), "rev_button", list(), made)
		name_fields += list(list(button, "label"))
		var/names_safe = TRUE
		for(var/list/entry as anything in name_fields)
			var/obj/babylon_tutorial/object = entry[1]
			var/error = object.set_setting(entry[2], bad)
			var/value = object.setting(entry[2])
			if(!error && (findtext(value, "<") || findtext(value, ">")))
				names_safe = FALSE
		result["names_never_hold_markup"] = names_safe && !findtext(button.name, "<")

		// Blood reagents: only the curated list.
		var/blocked_ok = TRUE
		for(var/path in list("/datum/reagent/magillitis", "/datum/reagent/mutationtoxin", "/datum/reagent/gluttonytoxin", "/datum/reagent/xenomicrobes", "/datum/reagent/romerol", "/datum/reagent/aslimetoxin", "/datum/reagent/cyborg_mutation_nanomachines"))
			var/list/cleaned = babylon_tutorial_clean_effects(list(list("kind" = "reagent", "type" = path, "amount" = 5, "chance" = 100)))
			if(!cleaned["error"])
				blocked_ok = FALSE
		result["dangerous_reagents_refused"] = blocked_ok
		var/list/allowed_reagent = babylon_tutorial_clean_effects(list(list("kind" = "reagent", "type" = "[/datum/reagent/medicine/epinephrine]", "amount" = 5, "chance" = 100)))
		result["medicine_allowed"] = !allowed_reagent["error"]

		// Diseases never spread; unhurtable until made vulnerable.
		spawner.set_setting("effects", list(list("kind" = "disease", "type" = "[/datum/disease/cold]", "chance" = 100)))
		spawner.set_setting("invulnerable", 1)
		var/mob/living/carbon/human/npc = spawner.spawn_npc()
		var/datum/disease/illness = length(npc.diseases) ? npc.diseases[1] : null
		result["disease_not_contagious"] = illness && illness.spread_flags == DISEASE_SPREAD_NON_CONTAGIOUS
		result["npc_unhurtable"] = HAS_TRAIT(npc, TRAIT_GODMODE)
		var/obj/babylon_tutorial/action/npc_vulnerable/vulnerable = babylon_tutorial_test_place(/obj/babylon_tutorial/action/npc_vulnerable, base, "rev_vulnerable", list("target" = "rev_npc"), made)
		var/mob/living/carbon/human/player = new(locate(base.x, base.y + 1, base.z))
		made += player
		var/datum/babylon_tutorial_run/run = babylon_tutorial_begin(FALSE, TRUE, FALSE, list(player))
		run.perform(null, vulnerable)
		result["npc_made_vulnerable"] = !HAS_TRAIT(npc, TRAIT_GODMODE)
		var/obj/item/uniform = npc.w_uniform
		result["outfit_items_never_saved"] = !uniform || (uniform.babylon_tutorial_npc_item && babylon_tutorial_skip_save(uniform))
		if(uniform)
			npc.dropItemToGround(uniform, TRUE)
			spawner.spawn_npc()
			result["dropped_outfit_cleaned_on_respawn"] = QDELETED(uniform)

		// Give item refuses Hilbert's hotel; gas zones are capped.
		result["hilbert_refused"] = !babylon_tutorial_type_allowed(/obj/item/hilbertshotel, null)
		var/obj/babylon_tutorial/trigger/condition/gas = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/condition, base, "rev_gas", list("condition" = "gas"), made)
		result["gas_zone_capped"] = !!gas.set_setting("zone", list(1, 1, 100, 100, base.z)) && isnull(gas.set_setting("zone", list(base.x, base.y, base.x + 9, base.y + 9, base.z)))

		// Renaming rewrites the links; taken ids are refused.
		var/obj/babylon_tutorial/action/message/hello = babylon_tutorial_test_place(/obj/babylon_tutorial/action/message, base, "rev_hello", list("text" = "Hello"), made)
		var/obj/babylon_tutorial/trigger/start/start = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/start, base, "rev_start", list("actions" = list("rev_hello")), made)
		var/obj/babylon_tutorial/action/point/point = babylon_tutorial_test_place(/obj/babylon_tutorial/action/point, base, "rev_point", list("target" = "rev_npc"), made)
		var/obj/babylon_tutorial/trigger/say/say = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/say, base, "rev_say", list("phrase" = "it's done", "starts" = "after", "after" = "rev_start", "actions" = list("rev_point")), made)
		var/obj/babylon_tutorial/trigger/timer/after_say = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/timer, base, "rev_next", list("seconds" = 600, "starts" = "after", "after" = "rev_say"), made)
		result["rename_refuses_taken"] = !!hello.set_tutorial_id("rev_start")
		result["rename_rewrites_links"] = isnull(hello.set_tutorial_id("rev_welcome")) && (start.setting("actions") ~= list("rev_welcome")) && (hello.last_rename_links ~= list("rev_start"))

		// Steps: the start trigger fires once; the say trigger listens only after it.
		babylon_tutorial_end()
		run = babylon_tutorial_begin(FALSE, TRUE, FALSE, list(player))
		result["chained_trigger_waits"] = run.is_enabled(start) && !run.is_enabled(say)
		run.check_triggers()
		run.check_triggers()
		result["start_trigger_fires_once"] = run.fired[start] == 1 && ("rev_start>rev_welcome" in run.history)
		result["chain_starts_listening"] = run.is_enabled(say)
		// Said text arrives encoded ("it&#39;s"): the phrase still matches.
		player.say("ok it's done")
		run.check_triggers()
		result["say_matches_encoded_text"] = run.fired[say] == 1
		result["point_until_next_step"] = length(run.images) == 1
		var/image/arrow = run.images[1]
		var/list/info = run.images[arrow]
		result["point_waits_for_next_trigger"] = (after_say in info["clear_on"])
		run.fire(after_say)
		result["point_cleared_by_next_step"] = !length(run.images)

		// Deleted objects leave no references in runs; deleted targets take their images along.
		run.perform(null, point)
		var/mob/living/carbon/human/old_npc = spawner.current_npc()
		spawner.spawn_npc()
		result["images_follow_their_target"] = QDELETED(old_npc) && !length(run.images)
		run.set_enabled(after_say, TRUE)
		run.hits[after_say] = TRUE
		run.last_state[after_say] = TRUE
		qdel(after_say)
		result["deleted_trigger_forgotten"] = !(after_say in run.enabled) && !(after_say in run.hits) && !(after_say in run.last_state) && !(after_say in run.fired)

		// Speech: private, and a Guide box when the player cannot hear the speaker.
		result["speech_heard_nearby"] = babylon_tutorial_speak(run, spawner.current_npc(), "Hello there")
		player.forceMove(locate(base.x + 11, base.y + 9, base.z))
		result["speech_falls_back_when_far"] = !babylon_tutorial_speak(run, spawner.current_npc(), "Hello there")

		// Objective: encoded on screen, removed at the end.
		run.set_objective("<b>Scan</b> the patient", "Guide")
		var/atom/movable/screen/alert/objective = player.alerts["babylon_tutorial_objective"]
		result["objective_shown_encoded"] = objective && findtext(objective.maptext, "&lt;b&gt;") && !findtext(objective.maptext, "<b>")
		babylon_tutorial_end()
		result["objective_cleared"] = !player.alerts["babylon_tutorial_objective"]

		// Preset ids name what they are.
		var/obj/babylon_tutorial/npc_spawner/guide = babylon_tutorial_place_npc(locate(base.x + 4, base.y, base.z), "guide")
		made += guide
		var/obj/babylon_tutorial/npc_spawner/patient = babylon_tutorial_place_npc(locate(base.x + 5, base.y, base.z), "bruised")
		made += patient
		result["preset_ids"] = findtext(guide.tutorial_id, "guide") == 1 && findtext(patient.tutorial_id, "patient") == 1

		// Placed triggers chain after the last placed one.
		var/obj/babylon_tutorial/trigger/zone/placed = babylon_tutorial_place(/obj/babylon_tutorial/trigger/zone, base)
		made += placed
		result["placed_trigger_chains"] = placed.setting("starts") == "after" && length(placed.setting("after"))
	catch(var/exception/error)
		result["no_error"] = FALSE
		log_world("test_tutorial_review failed: [error] ([error.file]:[error.line])")
	babylon_tutorial_test_cleanup(made)
	return result

/// Review round 2: loops and unreachable steps are named, a trigger can't wait for itself, a
/// fired once-trigger is never revived, previews leave the run's objective alone and an image on
/// a player's body shares the run's deletion handler with the body tracking.
/datum/babylon_save/proc/test_tutorial_chains()
	var/list/result = list()
	var/list/made = list()
	var/turf/base = tutorial_test_base(70)
	try
		var/obj/babylon_tutorial/trigger/timer/first = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/timer, base, "chain_a", list("seconds" = 1), made)
		var/obj/babylon_tutorial/trigger/timer/second = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/timer, base, "chain_b", list("seconds" = 1, "starts" = "after", "after" = "chain_a"), made)
		result["self_wait_refused"] = !!first.set_setting("after", "chain_a")
		// chain_a waits for chain_b and chain_b for chain_a: a loop nobody can enter.
		first.set_setting("starts", "after")
		first.set_setting("after", "chain_b")
		var/found_cycle = FALSE
		for(var/text in babylon_tutorial_overview_texts())
			if(findtext(text, "wait for each other") && findtext(text, "chain_a") && findtext(text, "chain_b"))
				found_cycle = TRUE
		result["cycle_named"] = found_cycle
		var/obj/babylon_tutorial/trigger/timer/orphan = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/timer, base, "chain_c", list("seconds" = 1, "starts" = "after", "after" = "chain_b"), made)
		var/found_unreachable = FALSE
		for(var/text in babylon_tutorial_overview_texts())
			if(findtext(text, "Trigger chain_c waits for chain_b, which can never fire"))
				found_unreachable = TRUE
		result["unreachable_named"] = found_unreachable
		// Entered through an Enable action, the loop runs each once-trigger once, then stops.
		var/mob/living/carbon/human/player = new(base)
		made += player
		var/datum/babylon_tutorial_run/run = babylon_tutorial_begin(FALSE, TRUE, FALSE, list(player))
		run.set_enabled(first, TRUE)
		run.fire(first)
		run.fire(second)
		result["once_trigger_not_revived"] = !run.is_enabled(first) && run.fired[first] == 1
		run.set_enabled(first, TRUE)
		result["fired_once_stays_off"] = !run.is_enabled(first)
		result["orphan_listens_after_loop_step"] = run.is_enabled(orphan)
		// Previews show their objective in chat only; the real run's alert stays.
		run.set_objective("Real goal", "Guide")
		var/datum/babylon_tutorial_run/preview = new(TRUE, player)
		preview.set_objective("Preview goal", "Guide")
		qdel(preview)
		var/atom/movable/screen/alert/babylon_tutorial_objective/alert = player.alerts["babylon_tutorial_objective"]
		result["preview_leaves_objective"] = alert && findtext(alert.maptext, "Real goal") && run.objective == "Real goal"
		// An image anchored to the player's body: deleting the (living) body removes the image,
		// keeps the world's run and forgets the player, who left.
		var/image/mark = image('icons/hud/screen_gen.dmi', player, "arrow")
		run.show_image(mark, 5 SECONDS, player)
		var/key = babylon_tutorial_player_key(player)
		qdel(player)
		result["player_deletion_keeps_run"] = !QDELETED(run) && babylon_tutorial_current_run() == run && !length(run.images) && !(key in run.bodies) && !(key in run.snapshots)
		babylon_tutorial_end()
	catch(var/exception/error)
		result["no_error"] = FALSE
		log_world("test_tutorial_chains failed: [error] ([error.file]:[error.line])")
	babylon_tutorial_test_cleanup(made)
	return result

/// One run per world (spec 12 #21), the player-state condition (#18), Damage / effect (#8) and
/// Heal / revive (#19): two players share the run, one fires a step and both get its effect;
/// dead and ghosted players still count; a revive brings back a body that survived and rebuilds
/// one that was destroyed, and puts the player back in.
/datum/babylon_save/proc/test_tutorial_players()
	var/list/result = list()
	var/list/made = list()
	var/turf/base = tutorial_test_base(84)
	try
		var/turf/zone_tile = locate(base.x + 3, base.y, base.z)
		var/obj/babylon_tutorial/trigger/zone/zone = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/zone, zone_tile, "pl_enter", list("actions" = list("pl_give", "pl_goal")), made)
		babylon_tutorial_test_place(/obj/babylon_tutorial/action/give_item, base, "pl_give", list("item_type" = "[/obj/item/healthanalyzer]"), made)
		babylon_tutorial_test_place(/obj/babylon_tutorial/action/message, base, "pl_goal", list("text" = "Scan yourself.", "hint" = "Heal up, \[player]"), made)
		var/obj/babylon_tutorial/trigger/condition/dead_check = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/condition, base, "pl_dead", list("condition" = "player", "npc_check" = "dead", "starts" = "manual"), made)
		var/obj/babylon_tutorial/trigger/condition/healed_check = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/condition, base, "pl_healed", list("condition" = "player", "npc_check" = "healed", "damage_type" = "brute", "amount" = 5, "starts" = "manual"), made)
		var/obj/babylon_tutorial/action/harm/hurt = babylon_tutorial_test_place(/obj/babylon_tutorial/action/harm, base, "pl_hurt", list("effect" = "brute", "amount" = 30), made)
		var/obj/babylon_tutorial/action/heal/heal_brute = babylon_tutorial_test_place(/obj/babylon_tutorial/action/heal, base, "pl_heal", list("heal" = "type", "damage_type" = "brute", "amount" = 30), made)
		var/obj/babylon_tutorial/action/heal/revive = babylon_tutorial_test_place(/obj/babylon_tutorial/action/heal, base, "pl_revive", list("heal" = "revive"), made)
		var/obj/babylon_tutorial/npc_spawner/spawner = babylon_tutorial_test_place(/obj/babylon_tutorial/npc_spawner, locate(base.x + 5, base.y + 2, base.z), "pl_npc", list("npc_name" = "Dummy", "spawn_at_start" = 0), made)
		var/mob/living/carbon/human/npc = spawner.spawn_npc()
		made += npc
		var/obj/babylon_tutorial/action/harm/burn_npc = babylon_tutorial_test_place(/obj/babylon_tutorial/action/harm, base, "pl_burn_npc", list("apply_to" = "npc", "target" = "pl_npc", "effect" = "burn", "amount" = 25), made)
		var/obj/babylon_tutorial/action/heal/heal_npc = babylon_tutorial_test_place(/obj/babylon_tutorial/action/heal, base, "pl_heal_npc", list("apply_to" = "npc", "target" = "pl_npc", "heal" = "full"), made)
		result["npc_target_no_issue_when_spawned"] = !burn_npc.issues()["target"] && !heal_npc.issues()["target"]
		result["unknown_effect_refused"] = !!hurt.set_setting("effect", "gib")
		// Without its NPC, both actions warn the builder.
		var/obj/babylon_tutorial/npc_spawner/missing = babylon_tutorial_test_place(/obj/babylon_tutorial/npc_spawner, locate(base.x + 7, base.y + 2, base.z), "pl_missing", list("spawn_at_start" = 0), made)
		var/obj/babylon_tutorial/action/harm/harm_missing = babylon_tutorial_test_place(/obj/babylon_tutorial/action/harm, base, "pl_harm_missing", list("apply_to" = "npc", "target" = "pl_missing"), made)
		var/obj/babylon_tutorial/action/heal/heal_missing = babylon_tutorial_test_place(/obj/babylon_tutorial/action/heal, base, "pl_heal_missing", list("apply_to" = "npc", "target" = "pl_missing"), made)
		result["npc_not_spawned_warned"] = !missing.current_npc() && findtext(harm_missing.issues()["target"], "no NPC") && findtext(heal_missing.issues()["target"], "no NPC")
		var/obj/babylon_tutorial/trigger/used_on/scan = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/used_on, base, "pl_scan", list("item_type" = "[/obj/item/healthanalyzer]", "target" = "pl_npc"), made)

		// Two players without clients, keyed like real ones (the run follows the key).
		var/mob/living/carbon/human/first = new(locate(base.x, base.y + 1, base.z))
		var/mob/living/carbon/human/second = new(locate(base.x + 1, base.y + 1, base.z))
		made += first
		made += second
		first.real_name = "First Tester"
		first.name = first.real_name
		second.real_name = "Second Tester"
		second.name = second.real_name
		first.mind_initialize()
		second.mind_initialize()
		first.key = "babylontutorialtester1"
		second.key = "babylontutorialtester2"
		var/first_key = first.ckey
		var/second_key = second.ckey
		var/datum/babylon_tutorial_run/run = babylon_tutorial_begin(FALSE, TRUE, FALSE, list(first, second))
		result["both_players"] = (first in run.players()) && (second in run.players()) && run.body_of(first_key) == first

		// #21: the first player walks in; both get the item and the objective.
		first.forceMove(zone_tile)
		run.check_triggers()
		result["one_fires_for_all"] = run.fired[zone] == 1
		var/obj/item/healthanalyzer/first_item = locate() in first.held_items
		var/obj/item/healthanalyzer/second_item = locate() in second.held_items
		made += first_item
		made += second_item
		result["both_given_item"] = !!first_item && !!second_item
		var/atom/movable/screen/alert/first_alert = first.alerts["babylon_tutorial_objective"]
		var/atom/movable/screen/alert/second_alert = second.alerts["babylon_tutorial_objective"]
		result["both_see_objective"] = first_alert && second_alert && findtext(first_alert.maptext, "First Tester") && findtext(second_alert.maptext, "Second Tester")
		second.forceMove(zone_tile)
		run.check_triggers()
		result["fired_step_shared"] = run.fired[zone] == 1

		// A late joiner gets the objective that is already on screen.
		var/mob/living/carbon/human/late = new(locate(base.x + 2, base.y + 1, base.z))
		made += late
		late.real_name = "Late Tester"
		run.add_player(late)
		run.check_triggers()
		var/atom/movable/screen/alert/late_alert = late.alerts["babylon_tutorial_objective"]
		result["late_joiner_sees_objective"] = late_alert && findtext(late_alert.maptext, "Late Tester")
		qdel(late)
		result["left_player_forgotten"] = !(late in run.players())

		// A client-less mob nobody plays (a monkey, an AI mob) using the item is no player.
		var/mob/living/carbon/human/stray = new(get_step(npc, EAST))
		made += stray
		var/obj/item/healthanalyzer/stray_item = new(get_turf(stray))
		made += stray_item
		stray.put_in_hands(stray_item)
		SSbabylon_tutorial.refresh_hooks()
		stray_item.melee_attack_chain(stray, npc)
		run.check_triggers()
		result["stray_mob_no_player"] = !run.fired[scan] && !(stray in run.players()) && !run.hits[scan]

		// #8 on every player and on an NPC.
		run.perform(null, hurt)
		result["damage_hits_every_player"] = first.get_brute_loss() >= 29 && second.get_brute_loss() >= 29
		run.perform(null, burn_npc)
		result["damage_hits_npc_only"] = npc.get_fire_loss() >= 24 && first.get_fire_loss() < 1 && second.get_fire_loss() < 1
		var/mob/living/carbon/human/dummy = new(locate(base.x + 6, base.y, base.z))
		made += dummy
		babylon_tutorial_harm(dummy, list("effect" = "fire", "stacks" = 2))
		result["effect_fire"] = !!dummy.has_status_effect(/datum/status_effect/fire_handler/fire_stacks)
		dummy.extinguish_mob()
		babylon_tutorial_harm(dummy, list("effect" = "knockdown", "seconds" = 3))
		result["effect_knockdown"] = !!dummy.IsKnockdown()
		babylon_tutorial_harm(dummy, list("effect" = "blur", "seconds" = 5))
		result["effect_blur"] = !!dummy.has_status_effect(/datum/status_effect/eye_blur)
		babylon_tutorial_harm(dummy, list("effect" = "blind", "seconds" = 5))
		result["effect_blind"] = !!dummy.has_status_effect(/datum/status_effect/temporary_blindness)
		babylon_tutorial_harm(dummy, list("effect" = "bleed", "zone" = BODY_ZONE_L_ARM))
		result["effect_bleed"] = length(dummy.all_wounds) >= 1
		babylon_tutorial_harm(dummy, list("effect" = "disease", "disease" = "[/datum/disease/cold]"))
		var/datum/disease/illness = length(dummy.diseases) ? dummy.diseases[1] : null
		result["effect_disease_not_contagious"] = illness?.spread_flags == DISEASE_SPREAD_NON_CONTAGIOUS
		babylon_tutorial_harm(dummy, list("effect" = "tox", "amount" = 12))
		result["effect_tox"] = dummy.get_tox_loss() >= 11
		babylon_tutorial_harm(dummy, list("effect" = "oxy", "amount" = 13))
		result["effect_oxy"] = dummy.get_oxy_loss() >= 12
		var/wounds_before = length(dummy.all_wounds)
		babylon_tutorial_harm(dummy, list("effect" = "wound", "wound" = "[/datum/wound/blunt/bone/severe]", "zone" = BODY_ZONE_R_LEG))
		result["effect_wound"] = length(dummy.all_wounds) > wounds_before
		result["effect_wound_refuses_unlisted"] = !babylon_tutorial_harm(dummy, list("effect" = "wound", "wound" = "[/datum/wound]"))
		ADD_TRAIT(dummy, TRAIT_GODMODE, "babylon_test")
		result["god_mode_spared"] = !babylon_tutorial_harm(dummy, list("effect" = "brute", "amount" = 50)) && dummy.get_brute_loss() < 1

		// #18 healed check and #19 heal one type, on every player.
		result["healed_false_when_hurt"] = !healed_check.evaluate(run)
		run.perform(null, heal_brute)
		result["heal_type_every_player"] = first.get_brute_loss() <= 1 && second.get_brute_loss() <= 1
		result["healed_true_after_heal"] = !!healed_check.evaluate(run)
		run.perform(null, heal_npc)
		result["full_heal_npc"] = npc.get_fire_loss() < 1
		// A preview runs for its builder only.
		var/datum/babylon_tutorial_run/preview = new(TRUE, first)
		preview.perform(null, hurt)
		result["preview_hits_builder_only"] = first.get_brute_loss() >= 29 && second.get_brute_loss() < 1
		qdel(preview)
		first.fully_heal(HEAL_ALL)

		// #18 a dead player counts, also as a ghost; #19 revive puts them back into that body.
		result["dead_false_while_alive"] = !dead_check.evaluate(run)
		first.death()
		result["dead_player_counts"] = !!dead_check.evaluate(run)
		var/mob/dead/observer/ghost = first.ghostize(TRUE)
		made += ghost
		result["ghosted_player_counts"] = !!dead_check.evaluate(run) && run.body_of(first_key) == first && ghost?.ckey == first_key
		result["snapshot_at_death"] = islist(run.snapshots[first_key])
		run.perform(null, revive)
		result["revive_surviving_body"] = first.stat != DEAD && first.ckey == first_key && (QDELETED(ghost) || ghost.ckey != first_key)
		result["dead_false_after_revive"] = !dead_check.evaluate(run)

		// #19 a destroyed body: a new one with the same looks and clothes, where it died. The
		// scrubs fell off when it was destroyed (as in a gib): the new body wears those, no copy.
		// The shoes are destroyed: they are made again.
		var/obj/item/clothing/under/rank/medical/doctor/scrubs = new(second)
		second.equip_to_slot_or_del(scrubs, ITEM_SLOT_ICLOTHING)
		var/obj/item/clothing/shoes/sneakers/white/shoes = new(second)
		second.equip_to_slot_or_del(shoes, ITEM_SLOT_FEET)
		result["test_body_dressed"] = second.w_uniform == scrubs && second.shoes == shoes
		var/turf/death_tile = locate(base.x + 2, base.y + 3, base.z)
		second.forceMove(death_tile)
		second.death()
		var/mob/dead/observer/second_ghost = second.ghostize(TRUE)
		made += second_ghost
		second.dropItemToGround(scrubs, TRUE)
		made += scrubs
		qdel(shoes)
		qdel(second)
		result["destroyed_body_counts_dead"] = !!dead_check.evaluate(run) && !run.body_of(second_key)
		run.perform(null, revive)
		var/mob/living/carbon/human/rebuilt = run.body_of(second_key)
		made += rebuilt
		result["revive_rebuilds_body"] = istype(rebuilt) && rebuilt != second && rebuilt.stat != DEAD && get_turf(rebuilt) == death_tile
		result["rebuilt_looks_the_same"] = rebuilt?.real_name == "Second Tester"
		var/scrubs_on_floor = 0
		for(var/obj/item/clothing/under/rank/medical/doctor/loose in death_tile)
			scrubs_on_floor++
		result["rebuilt_wears_the_originals"] = rebuilt?.w_uniform == scrubs && !scrubs_on_floor
		result["rebuilt_gets_gone_items_again"] = istype(rebuilt?.shoes, /obj/item/clothing/shoes/sneakers/white) && rebuilt?.shoes != shoes
		result["rebuilt_gets_player"] = rebuilt?.ckey == second_key && (QDELETED(second_ghost) || second_ghost.ckey != second_key)
		result["nobody_dead_after_revive"] = !dead_check.evaluate(run)
		result["revive_leaves_living_alone"] = isnull(run.revive_player(first_key))

		// Nobody around to come back (an SSD corpse; a player in the lobby has no ghost either):
		// a revive leaves the body dead and pulls no one in.
		var/mob/living/carbon/human/absent = new(locate(base.x + 4, base.y + 3, base.z))
		made += absent
		run.add_player(absent)
		var/absent_key = babylon_tutorial_player_key(absent)
		absent.death()
		result["absent_player_not_revived"] = isnull(run.revive_player(absent_key)) && absent.stat == DEAD
		babylon_tutorial_end()
		result["end_clears_objective"] = !first.alerts["babylon_tutorial_objective"]
	catch(var/exception/error)
		result["no_error"] = FALSE
		log_world("test_tutorial_players failed: [error] ([error.file]:[error.line])")
	babylon_tutorial_end()
	// The test keys belong to no client: a keyed mob deleted without one is reported as a leak.
	for(var/mob/keyed in made)
		if(findtext(keyed.ckey, "babylontutorialtester") == 1)
			keyed.key = null
	babylon_tutorial_test_cleanup(made)
	return result

/// How often a step is in a run's history.
/proc/babylon_tutorial_test_count(list/history, step)
	var/count = 0
	for(var/entry in history)
		if(entry == step)
			count++
	return count

/// A logic gate's test settings with the three test action lists.
/proc/babylon_tutorial_test_gate_settings(list/settings)
	var/list/merged = settings.Copy()
	merged["actions"] = list("g_true")
	merged["actions_false"] = list("g_false")
	merged["actions_change"] = list("g_change")
	return merged

/// Logic and number gates (spec 12 #10, #20): every logic mode, every number operation, chained
/// gates, live (zone) and latched (say) inputs, gates that start listening already true, the loop
/// guard naming the gate it stopped at, the depth limit, the per-wave update budget, disabling a
/// gate, ids in pasted copies and the reset by a new run.
/datum/babylon_save/proc/test_tutorial_gates()
	var/list/result = list()
	var/list/made = list()
	var/turf/base = tutorial_test_base(98)
	try
		// Inputs: say triggers that wait for an Enable action, fired by hand.
		var/list/inputs = list()
		for(var/id in list("g_in_a", "g_in_b", "g_in_c", "g_in_up", "g_in_down", "g_in_set", "g_in_add", "g_in_sub", "g_in_mul", "g_in_reset", "g_in_by", "g_in_deep", "g_in_m", "g_in_w"))
			inputs[id] = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/say, base, id, list("phrase" = id, "starts" = "manual", "once" = 0), made)
		babylon_tutorial_test_place(/obj/babylon_tutorial/action/sound, base, "g_true", list("sound" = "ding"), made)
		babylon_tutorial_test_place(/obj/babylon_tutorial/action/sound, base, "g_false", list("sound" = "ding"), made)
		babylon_tutorial_test_place(/obj/babylon_tutorial/action/sound, base, "g_change", list("sound" = "ding"), made)
		var/obj/babylon_tutorial/trigger/gate/logic/gate_and = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/gate/logic, base, "g_and", babylon_tutorial_test_gate_settings(list("mode" = "and", "inputs" = list("g_in_a", "g_in_b"))), made)
		var/obj/babylon_tutorial/trigger/gate/logic/gate_or = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/gate/logic, base, "g_or", babylon_tutorial_test_gate_settings(list("mode" = "or", "inputs" = list("g_in_a", "g_in_b"))), made)
		var/obj/babylon_tutorial/trigger/gate/logic/gate_xor = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/gate/logic, base, "g_xor", babylon_tutorial_test_gate_settings(list("mode" = "xor", "inputs" = list("g_in_a", "g_in_b"))), made)
		var/obj/babylon_tutorial/trigger/gate/logic/gate_not = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/gate/logic, base, "g_not", babylon_tutorial_test_gate_settings(list("mode" = "not", "inputs" = list("g_in_a"))), made)
		result["gate_schema_three_lists"] = !!babylon_tutorial_schema_field(/obj/babylon_tutorial/trigger/gate/logic, "actions_false") && !!babylon_tutorial_schema_field(/obj/babylon_tutorial/trigger/gate/number, "actions_change")
		result["gate_actions_counted_used"] = !("Action g_false is not used by any trigger." in babylon_tutorial_overview_texts())
		var/list/not_issues = gate_not.find_issues()
		result["not_needs_one_input"] = !not_issues["inputs"]
		gate_not.set_setting("inputs", list("g_in_a", "g_in_b"))
		not_issues = gate_not.find_issues()
		result["not_two_inputs_warned"] = !!findtext(not_issues["inputs"], "exactly one input")
		gate_not.set_setting("inputs", list("g_in_a"))
		result["bad_operation_refused"] = !!babylon_tutorial_clean_gate_inputs(null, list(list("id" = "g_in_a", "op" = "divide")))["error"]

		// Number gate with every operation; g_by (start 4) is the "by another gate" operand.
		var/obj/babylon_tutorial/trigger/gate/number/by_gate = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/gate/number, base, "g_by", list("start" = 4, "inputs" = list(list("id" = "g_in_by", "op" = "up"))), made)
		var/obj/babylon_tutorial/trigger/gate/number/ops = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/gate/number, base, "g_ops", list("start" = 1, "condition" = "between", "amount" = 5, "amount_max" = 10, "inputs" = list(
			list("id" = "g_in_up", "op" = "up"),
			list("id" = "g_in_down", "op" = "down"),
			list("id" = "g_in_set", "op" = "set", "amount" = 5),
			list("id" = "g_in_add", "op" = "add", "amount" = 2.5),
			list("id" = "g_in_sub", "op" = "sub", "amount" = 1),
			list("id" = "g_in_mul", "op" = "mul", "amount" = 3),
			list("id" = "g_in_reset", "op" = "reset"),
			list("id" = "g_in_by", "op" = "add", "source" = "g_by"),
		)), made)
		ops.set_setting("actions", list("g_true"))
		ops.set_setting("actions_false", list("g_false"))
		ops.set_setting("actions_change", list("g_change"))

		// Chain: g_count counts g_in_c up and is true at 2; g_chain = g_count AND g_in_b; g_after
		// counts g_chain's firings; a trigger waits "After" g_chain.
		babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/gate/number, base, "g_count", list("inputs" = list(list("id" = "g_in_c", "op" = "up")), "condition" = "at_least", "amount" = 2), made)
		var/obj/babylon_tutorial/trigger/gate/logic/chain = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/gate/logic, base, "g_chain", list("mode" = "and", "inputs" = list("g_count", "g_in_b")), made)
		var/obj/babylon_tutorial/trigger/gate/number/after_chain = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/gate/number, base, "g_after", list("inputs" = list(list("id" = "g_chain", "op" = "up"))), made)
		var/obj/babylon_tutorial/trigger/timer/waits = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/timer, base, "g_waits", list("seconds" = 600, "starts" = "after", "after" = "g_chain"), made)

		// A gate that does not listen yet ignores its inputs.
		var/obj/babylon_tutorial/trigger/gate/number/sleeper = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/gate/number, base, "g_sleeper", list("starts" = "manual", "inputs" = list(list("id" = "g_in_a", "op" = "up"))), made)

		// Loop: g_loop_a counts g_in_c and g_loop_b; g_loop_b counts g_loop_a.
		var/obj/babylon_tutorial/trigger/gate/number/loop_a = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/gate/number, base, "g_loop_a", list("inputs" = list(list("id" = "g_in_c", "op" = "up"), list("id" = "g_loop_b", "op" = "up"))), made)
		var/obj/babylon_tutorial/trigger/gate/number/loop_b = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/gate/number, base, "g_loop_b", list("inputs" = list(list("id" = "g_loop_a", "op" = "up"))), made)
		var/list/issues = loop_a.find_issues()
		result["loop_warned_while_building"] = !!findtext(issues["inputs"], "g_loop_a -> g_loop_b -> g_loop_a")
		issues = loop_b.find_issues()
		result["loop_warned_on_both"] = !!findtext(issues["inputs"], "loop")
		issues = chain.find_issues()
		result["chain_not_a_loop"] = !issues["inputs"]

		// Depth: 17 OR gates in a row from g_in_deep.
		var/previous = "g_in_deep"
		for(var/number in 1 to 17)
			babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/gate/logic, base, "g_deep[number]", list("mode" = "or", "inputs" = list(previous)), made)
			previous = "g_deep[number]"

		// Budget: a ladder of XOR gates, two per layer, each fed by both gates of the layer before:
		// every layer doubles the updates of one firing.
		babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/gate/logic, base, "g_w1a", list("mode" = "or", "inputs" = list("g_in_w")), made)
		babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/gate/logic, base, "g_w1b", list("mode" = "or", "inputs" = list("g_in_w")), made)
		for(var/layer in 2 to 10)
			for(var/side in list("a", "b"))
				babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/gate/logic, base, "g_w[layer][side]", list("mode" = "xor", "inputs" = list("g_w[layer - 1]a", "g_w[layer - 1]b")), made)

		// Live inputs: two one-tile zones (once: they stop listening after their first firing).
		var/turf/zone_a = locate(base.x + 2, base.y + 3, base.z)
		var/turf/zone_b = locate(base.x + 4, base.y + 3, base.z)
		var/obj/babylon_tutorial/trigger/zone/live_a = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/zone, zone_a, "g_zone_a", list(), made)
		babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/zone, zone_b, "g_zone_b", list(), made)
		var/obj/babylon_tutorial/trigger/gate/logic/live_and = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/gate/logic, base, "g_l_and", babylon_tutorial_test_gate_settings(list("mode" = "and", "inputs" = list("g_zone_a", "g_zone_b"))), made)
		var/obj/babylon_tutorial/trigger/gate/logic/live_not = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/gate/logic, base, "g_l_not", babylon_tutorial_test_gate_settings(list("mode" = "not", "inputs" = list("g_zone_a"))), made)
		var/obj/babylon_tutorial/trigger/gate/logic/live_xor = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/gate/logic, base, "g_l_xor", babylon_tutorial_test_gate_settings(list("mode" = "xor", "inputs" = list("g_zone_a", "g_zone_b"))), made)
		var/obj/babylon_tutorial/trigger/gate/number/entries = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/gate/number, base, "g_l_entries", list("inputs" = list(list("id" = "g_zone_a", "op" = "up"))), made)
		result["input_modes"] = babylon_tutorial_input_mode(live_a) == "live" && babylon_tutorial_input_mode(inputs["g_in_a"]) == "latched" && babylon_tutorial_input_mode(live_and) == "gate"

		// Starting to listen: a number gate after its own input does not count that firing; an
		// AND gate enabled when both inputs already fired becomes true and fires.
		var/obj/babylon_tutorial/trigger/gate/number/after_own = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/gate/number, base, "g_m1", list("starts" = "after", "after" = "g_in_m", "inputs" = list(list("id" = "g_in_m", "op" = "up"))), made)
		var/obj/babylon_tutorial/trigger/gate/logic/late = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/gate/logic, base, "g_late", list("mode" = "and", "starts" = "manual", "inputs" = list("g_in_a", "g_in_b")), made)
		var/obj/babylon_tutorial/trigger/timer/after_late = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/timer, base, "g_after_late", list("seconds" = 600, "starts" = "after", "after" = "g_late"), made)
		// Disabling: g_down = NOT g_or.
		var/obj/babylon_tutorial/trigger/gate/logic/down = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/gate/logic, base, "g_down", list("mode" = "not", "inputs" = list("g_or")), made)

		var/mob/living/carbon/human/player = new(base)
		made += player
		var/mob/living/carbon/human/second = new(base)
		made += second
		var/datum/babylon_tutorial_run/run = babylon_tutorial_begin(FALSE, TRUE, FALSE, list(player, second))
		result["false_until_first_check"] = !run.gate_states[gate_not] && !length(run.history) && run.gate_pending[gate_not]
		run.check_triggers()
		result["baseline_states"] = !run.gate_states[gate_and] && !run.gate_states[gate_or] && !run.gate_states[gate_xor] && run.gate_states[gate_not]
		result["not_runs_on_true_first_check"] = babylon_tutorial_test_count(run.history, "g_not>g_true") == 1 && run.fired[gate_not] == 1
		// The start is symmetric: a gate that does not hold runs On false once; On change does
		// not run at the start; only gates that hold fire.
		result["start_runs_on_false"] = babylon_tutorial_test_count(run.history, "g_and>g_false") == 1 && babylon_tutorial_test_count(run.history, "g_ops>g_false") == 1 && !run.fired[gate_and]
		result["number_start_true_fires"] = run.gate_states[by_gate] && run.fired[by_gate] == 1
		result["start_no_on_change"] = !babylon_tutorial_test_count(run.history, "g_not>g_change") && !babylon_tutorial_test_count(run.history, "g_and>g_change") && !babylon_tutorial_test_count(run.history, "g_ops>g_change")
		var/history_size = length(run.history)
		run.check_triggers()
		result["gates_never_poll"] = !run.fired[gate_and] && !run.fired[gate_or] && !run.fired[gate_xor] && length(run.history) == history_size

		// in_a fires: OR and XOR become true, NOT becomes false, AND stays false.
		var/before_a = length(run.history)
		run.fire(inputs["g_in_a"])
		result["and_one_of_two_false"] = !run.gate_states[gate_and]
		result["or_true"] = run.gate_states[gate_or] && ("g_or>g_true" in run.history) && ("g_or>g_change" in run.history)
		result["xor_one_true"] = run.gate_states[gate_xor] && run.fired[gate_xor] == 1
		var/not_true = 0
		for(var/step in run.history)
			if(step == "g_not>g_true")
				not_true++
		result["not_false"] = !run.gate_states[gate_not] && ("g_not>g_false" in run.history) && ("g_not>g_change" in run.history) && not_true == 1
		var/and_ran = FALSE
		for(var/step in run.history.Copy(before_a + 1))
			if(findtext(step, "g_and>") == 1)
				and_ran = TRUE
		result["and_untouched_runs_nothing"] = !and_ran
		// in_b fires: AND true, XOR false again (both true), OR stays true without new actions.
		var/or_actions = 0
		for(var/step in run.history)
			if(findtext(step, "g_or>") == 1)
				or_actions++
		run.fire(inputs["g_in_b"])
		result["and_true"] = run.gate_states[gate_and] && ("g_and>g_true" in run.history)
		result["xor_two_false"] = !run.gate_states[gate_xor] && babylon_tutorial_test_count(run.history, "g_xor>g_false") == 2
		var/or_after = 0
		for(var/step in run.history)
			if(findtext(step, "g_or>") == 1)
				or_after++
		result["or_stays_quiet"] = or_after == or_actions

		// Number operations, from 1.
		var/list/expected = list("g_in_up" = 2, "g_in_down" = 1, "g_in_set" = 5, "g_in_add" = 7.5, "g_in_sub" = 6.5, "g_in_mul" = 19.5, "g_in_reset" = 1, "g_in_by" = 6)
		for(var/id in expected)
			run.fire(inputs[id])
			result["op_[copytext(id, 6)]"] = abs(run.gate_number(ops) - expected[id]) < 0.001
		// g_in_by also counted g_by up first (4 -> 5), so "add g_by" added 5.
		result["by_gate_counted"] = run.gate_number(by_gate) == 5
		result["number_condition_true_false"] = ("g_ops>g_true" in run.history) && babylon_tutorial_test_count(run.history, "g_ops>g_false") == 2 && run.gate_states[ops]
		var/changes = 0
		for(var/step in run.history)
			if(step == "g_ops>g_change")
				changes++
		result["number_change_per_change"] = changes == 8
		ops.set_setting("condition", "equals")
		ops.set_setting("amount", 6)
		result["cond_equals"] = ops.holds(6) && !ops.holds(6.5)
		ops.set_setting("condition", "at_most")
		result["cond_at_most"] = ops.holds(6) && ops.holds(-3) && !ops.holds(6.1)
		ops.set_setting("condition", "at_least")
		result["cond_at_least"] = ops.holds(6) && !ops.holds(5.9)

		// Chain: g_in_c twice makes g_count true; g_in_b already fired, so g_chain fires.
		result["sleeper_ignores_inputs"] = run.gate_number(sleeper) == 0
		run.fire(inputs["g_in_c"])
		result["chain_waits"] = !run.gate_states[chain] && !run.is_enabled(waits)
		run.fire(inputs["g_in_c"])
		result["chain_fires"] = run.gate_states[chain] && run.fired[chain] == 1
		result["chain_counts_on"] = run.gate_number(after_chain) == 1
		result["after_gate_listens"] = run.is_enabled(waits)

		// The loop (fed by g_in_c too) stopped at once, at g_loop_a, and the run says so.
		result["loop_stopped_at_gate"] = !!findtext(run.gate_stops[loop_a], "loop stopped at g_loop_a")
		result["loop_logged"] = length(run.gate_log) && findtext(run.gate_log[1], "g_loop_a -> g_loop_b -> g_loop_a")
		result["loop_counts_bounded"] = run.gate_number(loop_a) <= 3 && run.gate_number(loop_b) <= 2
		issues = loop_a.find_issues()
		result["loop_in_wand_issues"] = !!findtext(issues["live"], "g_loop_a")
		var/list/live = babylon_tutorial_gates_live(run)
		var/live_ok = FALSE
		for(var/list/entry as anything in live)
			if(entry["id"] == "g_loop_a" && entry["stopped"])
				live_ok = TRUE
		result["wand_lists_gates"] = live_ok

		// Depth limit: 16 gates update, the 17th is stopped and named.
		run.fire(inputs["g_in_deep"])
		result["depth_16_pass"] = run.gate_states[babylon_tutorial_find("g_deep16")]
		var/obj/babylon_tutorial/trigger/gate/deep17 = babylon_tutorial_find("g_deep17")
		result["depth_17_stopped"] = !run.gate_states[deep17] && !!findtext(run.gate_stops[deep17], "chain stopped at g_deep17")

		// Live inputs: zones follow the players both ways; a number gate counts each entry once.
		player.forceMove(zone_a)
		run.check_triggers()
		result["live_not_false_on_entry"] = !run.gate_states[live_not] && babylon_tutorial_test_count(run.history, "g_l_not>g_false") == 1
		result["live_xor_one"] = run.gate_states[live_xor] && !run.gate_states[live_and]
		second.forceMove(zone_b)
		run.check_triggers()
		result["live_and_true"] = run.gate_states[live_and] && !run.gate_states[live_xor]
		second.forceMove(base)
		run.check_triggers()
		result["live_and_false_on_leave"] = !run.gate_states[live_and] && babylon_tutorial_test_count(run.history, "g_l_and>g_false") == 2 && run.gate_states[live_xor]
		player.forceMove(base)
		run.check_triggers()
		result["live_not_back_true"] = run.gate_states[live_not] && babylon_tutorial_test_count(run.history, "g_l_not>g_true") == 2 && !run.gate_states[live_xor]
		result["once_zone_still_live"] = !run.is_enabled(live_a) && run.fired[live_a] == 1
		player.forceMove(zone_a)
		run.check_triggers()
		result["entries_counted_once_each"] = run.gate_number(entries) == 2
		player.forceMove(base)
		run.check_triggers()
		result["latched_event_stays_true"] = run.input_state(inputs["g_in_a"])

		// Starting to listen.
		run.fire(inputs["g_in_m"])
		result["enabling_firing_not_counted"] = run.is_enabled(after_own) && run.gate_number(after_own) == 0
		run.check_triggers()
		run.fire(inputs["g_in_m"])
		result["counts_after_listening"] = run.gate_number(after_own) == 1
		run.set_enabled(late, TRUE)
		result["late_waits_for_check"] = !run.gate_states[late]
		run.check_triggers()
		result["late_true_fires"] = run.gate_states[late] && run.fired[late] == 1 && run.is_enabled(after_late)

		// Disabling a true gate: it turns false without its own actions, g_down sees it.
		var/or_false_before = babylon_tutorial_test_count(run.history, "g_or>g_false")
		result["down_false_while_or"] = !run.gate_states[down]
		run.set_enabled(gate_or, FALSE)
		result["disabled_gate_false"] = !run.gate_states[gate_or] && babylon_tutorial_test_count(run.history, "g_or>g_false") == or_false_before
		result["downstream_sees_disable"] = run.gate_states[down]
		// Enabled again while it holds (g_in_a fired, a latched input): it runs On true once at
		// the next check, without On change.
		var/or_change_before = babylon_tutorial_test_count(run.history, "g_or>g_change")
		var/or_true_before = babylon_tutorial_test_count(run.history, "g_or>g_true")
		run.set_enabled(gate_or, TRUE)
		run.check_triggers()
		result["reenabled_runs_on_true_once"] = run.gate_states[gate_or] && babylon_tutorial_test_count(run.history, "g_or>g_true") == or_true_before + 1 && babylon_tutorial_test_count(run.history, "g_or>g_change") == or_change_before

		// Budget: the XOR ladder stops after the per-wave budget and names the gate.
		var/log_before = length(run.gate_log)
		run.fire(inputs["g_in_w"])
		var/budget_text = length(run.gate_log) > log_before ? run.gate_log[length(run.gate_log)] : ""
		result["budget_stops_wave"] = !!findtext(budget_text, "wave stopped at g_w") && !!findtext(budget_text, "256")
		result["budget_bounded"] = run.gate_wave_updates <= 256
		var/budget_named = FALSE
		for(var/obj/babylon_tutorial/trigger/gate/stopped as anything in run.gate_stops)
			if(findtext(stopped.tutorial_id, "g_w") == 1 && findtext(run.gate_stops[stopped], "wave stopped at [stopped.tutorial_id]"))
				budget_named = TRUE
		result["budget_names_gate"] = budget_named
		run.fire(inputs["g_in_a"])
		result["next_wave_has_budget"] = !run.gate_wave_stopped

		// A pasted copy: ids and "by" sources inside the copy get the suffix, outside ones stay.
		var/datum/babylon_area_clip/clip = new
		clip.origin = list(base.x, base.y, base.z)
		clip.width = 1
		clip.height = 1
		var/list/pasted = babylon_area_rewrite_settings(/obj/babylon_tutorial/trigger/gate/number, json_encode(list("inputs" = list(list("id" = "g_in_up", "op" = "add", "amount" = 1, "source" = "g_by"), list("id" = "g_outside", "op" = "add", "amount" = 1, "source" = "g_far")))), list("g_in_up" = "g_in_up_2", "g_by" = "g_by_2"), clip, base)
		var/list/pasted_inputs = pasted["inputs"]
		var/list/pasted_first = pasted_inputs[1]
		var/list/pasted_second = pasted_inputs[2]
		result["paste_rewrites_inputs"] = pasted_first["id"] == "g_in_up_2" && pasted_first["source"] == "g_by_2" && pasted_second["id"] == "g_outside" && pasted_second["source"] == "g_far"
		qdel(clip)

		// Renaming an input or a "by" gate rewrites the number gate's inputs.
		var/obj/babylon_tutorial/trigger/up_input = inputs["g_in_up"]
		up_input.set_tutorial_id("g_in_up2")
		by_gate.set_tutorial_id("g_by2")
		var/list/renamed = ops.setting("inputs")
		var/list/first_input = renamed[1]
		var/list/last_input = renamed[8]
		result["rename_rewrites_inputs"] = first_input["id"] == "g_in_up2" && last_input["source"] == "g_by2" && ("g_by2" in ops.references())

		// Restarting the test run resets every gate's state and number.
		var/datum/babylon_tutorial_run/again = babylon_tutorial_begin(FALSE, TRUE, FALSE, list(player))
		again.check_triggers()
		result["reset_numbers"] = again.gate_number(ops) == 1 && again.gate_number(after_chain) == 0 && !length(again.gate_stops)
		result["reset_states"] = !again.gate_states[gate_or] && again.gate_states[gate_not] && !again.gate_states[chain]
		result["old_run_gone"] = QDELETED(run)
		babylon_tutorial_end()
	catch(var/exception/error)
		result["no_error"] = FALSE
		log_world("test_tutorial_gates failed: [error] ([error.file]:[error.line])")
	babylon_tutorial_end()
	babylon_tutorial_test_cleanup(made)
	return result

/// Walks a Move NPC action's NPC step by step (no waiting for timers). Returns the walk when it
/// is still going after max_steps, else null (arrived or gave up).
/proc/babylon_tutorial_test_walk(datum/babylon_tutorial_run/run, mob/living/npc, max_steps = 40)
	for(var/step_number in 1 to max_steps)
		var/datum/babylon_tutorial_npc_move/walk = run.movers[npc]
		if(!walk)
			return null
		walk.walk_step()
	return run.movers[npc]

/// The world actions of spec 12: dead (#2) and anchored (#4) NPCs, Move NPC (#3), Spawn object
/// (#5), Remove objects (#6), Set inventory with a stored loadout (#7), Start event (#11) and
/// Door / container (#12).
/datum/babylon_save/proc/test_tutorial_world_actions()
	var/list/result = list()
	var/list/made = list()
	var/turf/base = tutorial_test_base(112)
	var/list/old_event_times = GLOB.babylon_tutorial_event_times.Copy()
	var/list/rect = list(base.x, base.y, base.x + 7, base.y + 3, base.z)
	try
		// A clear 8x4 floor to walk and build on.
		babylon_area_clear_tiles(babylon_area_tiles(rect[1], rect[2], rect[3], rect[4], rect[5]), rect, /turf/open/floor/iron)
		var/turf/row_start = locate(base.x, base.y, base.z)
		var/datum/babylon_tutorial_run/run = babylon_tutorial_begin(FALSE, TRUE, FALSE, list())

		// #2 Spawn dead: a corpse at once, it stays dead (no rot) and counts as dead.
		var/obj/babylon_tutorial/npc_spawner/corpse_spawner = babylon_tutorial_test_place(/obj/babylon_tutorial/npc_spawner, locate(base.x + 7, base.y + 3, base.z), "wa_corpse", list("npc_name" = "Corpse", "spawn_at_start" = 0, "spawn_dead" = 1), made)
		var/mob/living/carbon/human/corpse = corpse_spawner.spawn_npc()
		made += corpse
		var/obj/babylon_tutorial/trigger/condition/dead_check = babylon_tutorial_test_place(/obj/babylon_tutorial/trigger/condition, base, "wa_dead", list("condition" = "npc", "npc_check" = "dead", "target" = "wa_corpse", "starts" = "manual"), made)
		result["spawn_dead_is_dead"] = corpse?.stat == DEAD && !!dead_check.evaluate(run)
		result["spawn_dead_no_rot"] = !corpse?.GetComponent(/datum/component/rot)
		result["spawn_dead_summary"] = findtext(corpse_spawner.summary(), "dead") != 0

		// #4 Anchored: no pull, push, swap, buckle, walking over it.
		var/obj/babylon_tutorial/npc_spawner/stuck_spawner = babylon_tutorial_test_place(/obj/babylon_tutorial/npc_spawner, locate(base.x + 1, base.y + 2, base.z), "wa_stuck", list("npc_name" = "Stuck", "spawn_at_start" = 0, "anchored" = 1), made)
		var/mob/living/carbon/human/stuck = stuck_spawner.spawn_npc()
		made += stuck
		var/turf/stuck_tile = get_turf(stuck)
		var/mob/living/carbon/human/pusher = new(locate(base.x, base.y + 2, base.z))
		made += pusher
		pusher.start_pulling(stuck)
		result["anchored_not_pulled"] = pusher.pulling != stuck && !stuck.can_be_pulled(pusher, MOVE_FORCE_EXTREMELY_STRONG)
		pusher.Move(stuck_tile, EAST)
		result["anchored_not_pushed_or_swapped"] = get_turf(stuck) == stuck_tile && get_turf(pusher) != stuck_tile
		var/obj/structure/chair/chair = new(stuck_tile)
		made += chair
		result["anchored_not_buckled"] = !chair.buckle_mob(stuck, check_loc = FALSE) && !stuck.buckled
		stuck.Knockdown(30 SECONDS, ignore_canstun = TRUE)
		result["anchored_blocks_while_lying"] = stuck.body_position == LYING_DOWN && !stuck.CanPass(pusher, EAST)
		// The same checks on an NPC that is not anchored (the control).
		var/obj/babylon_tutorial/npc_spawner/free_spawner = babylon_tutorial_test_place(/obj/babylon_tutorial/npc_spawner, locate(base.x + 1, base.y + 3, base.z), "wa_free", list("npc_name" = "Free", "spawn_at_start" = 0), made)
		var/mob/living/carbon/human/free = free_spawner.spawn_npc()
		made += free
		free.Knockdown(30 SECONDS, ignore_canstun = TRUE)
		result["control_free_npc_passable_and_pullable"] = free.CanPass(pusher, EAST) && free.can_be_pulled(pusher, MOVE_FORCE_EXTREMELY_STRONG)
		result["anchored_summary"] = findtext(stuck_spawner.summary(), "anchored") != 0

		// #3 Move NPC: an anchored NPC walks along the row, then its On arrival action runs.
		var/obj/babylon_tutorial/npc_spawner/walker_spawner = babylon_tutorial_test_place(/obj/babylon_tutorial/npc_spawner, row_start, "wa_walker", list("npc_name" = "Walker", "spawn_at_start" = 0, "anchored" = 1), made)
		var/mob/living/carbon/human/walker = walker_spawner.spawn_npc()
		made += walker
		babylon_tutorial_test_place(/obj/babylon_tutorial/marker, locate(base.x + 5, base.y, base.z), "wa_far", list("target" = "tile"), made)
		babylon_tutorial_test_place(/obj/babylon_tutorial/marker, locate(base.x + 2, base.y, base.z), "wa_near", list("target" = "tile"), made)
		babylon_tutorial_test_place(/obj/babylon_tutorial/action/message, base, "wa_arrived", list("text" = "Here."), made)
		var/obj/babylon_tutorial/action/move_npc/walk_far = babylon_tutorial_test_place(/obj/babylon_tutorial/action/move_npc, base, "wa_walk", list("target" = "wa_walker", "destination" = "wa_far", "on_arrival" = list("wa_arrived")), made)
		var/obj/babylon_tutorial/action/move_npc/walk_back = babylon_tutorial_test_place(/obj/babylon_tutorial/action/move_npc, base, "wa_back", list("target" = "wa_walker", "destination" = "wa_near", "timeout" = 5), made)
		result["follow_up_counts_as_used"] = !("Action wa_arrived is not used by any trigger." in babylon_tutorial_overview_texts()) && ("Action wa_back is not used by any trigger." in babylon_tutorial_overview_texts())
		run.perform(null, walk_far)
		result["walk_started"] = !!run.movers[walker]
		babylon_tutorial_test_walk(run, walker)
		result["walked_to_marker"] = get_turf(walker) == locate(base.x + 5, base.y, base.z) && !run.movers[walker]
		result["on_arrival_ran"] = babylon_tutorial_test_count(run.history, "preview>wa_arrived") == 1
		// It can't stand: it crawls back.
		walker.Knockdown(60 SECONDS, ignore_canstun = TRUE)
		run.perform(null, walk_back)
		babylon_tutorial_test_walk(run, walker)
		result["crawled_to_marker"] = walker.body_position == LYING_DOWN && get_turf(walker) == locate(base.x + 2, base.y, base.z)
		// It gives up at its deadline, with a note for the builder.
		run.perform(null, walk_far)
		var/datum/babylon_tutorial_npc_move/late = run.movers[walker]
		late.deadline = world.time - 1
		late.walk_step()
		var/note = run.action_notes[walk_far]
		result["gave_up_noted"] = !run.movers[walker] && findtext(note, "gave up") && findtext(walk_far.issues()["live"], "Test run:") && length(run.action_log)
		walker.death()
		run.perform(null, walk_far)
		babylon_tutorial_test_walk(run, walker, 2)
		result["dead_npc_does_not_walk"] = findtext(run.action_notes[walk_far], "dead") && get_turf(walker) == locate(base.x + 2, base.y, base.z)
		walker.revive(HEAL_ALL | HEAL_ADMIN)
		var/obj/babylon_tutorial/action/move_npc/loop = babylon_tutorial_test_place(/obj/babylon_tutorial/action/move_npc, base, "wa_loop", list("target" = "wa_walker", "destination" = "wa_far", "on_arrival" = list("wa_loop")), made)
		result["self_loop_warned"] = !!loop.issues()["on_arrival"]

		// #5 Spawn object: like the Creative panel, on a marker or spread over a zone.
		var/turf/spawn_tile = locate(base.x + 6, base.y + 1, base.z)
		babylon_tutorial_test_place(/obj/babylon_tutorial/marker, spawn_tile, "wa_spawn_at", list("target" = "tile"), made)
		var/obj/babylon_tutorial/action/spawn_object/spawn_gauze = babylon_tutorial_test_place(/obj/babylon_tutorial/action/spawn_object, base, "wa_gauze", list("object_type" = "[/obj/item/stack/medical/suture]", "count" = 3, "marker" = "wa_spawn_at"), made)
		var/obj/babylon_tutorial/action/spawn_object/spawn_scanners = babylon_tutorial_test_place(/obj/babylon_tutorial/action/spawn_object, base, "wa_scanners", list("object_type" = "[/obj/item/healthanalyzer]", "count" = 2, "marker" = "wa_spawn_at"), made)
		result["spawn_refuses_blocked"] = !!spawn_scanners.set_setting("object_type", "[/obj/item/grenade/clusterbuster]") && !!spawn_scanners.set_setting("object_type", "[/mob/living/basic/pet/cat]")
		result["spawn_search_like_creative"] = length(babylon_tutorial_search_types(babylon_tutorial_schema_field(spawn_gauze.type, "object_type"), "gauze")) > 0
		run.perform(null, spawn_gauze)
		run.perform(null, spawn_scanners)
		var/obj/item/stack/medical/suture/gauze = locate() in spawn_tile
		var/scanners = 0
		for(var/obj/item/healthanalyzer/scanner in spawn_tile)
			scanners++
		result["spawned_stack_and_copies"] = gauze?.amount == 3 && scanners == 2
		var/obj/babylon_tutorial/action/spawn_object/spawn_zone = babylon_tutorial_test_place(/obj/babylon_tutorial/action/spawn_object, base, "wa_wrenches", list("object_type" = "[/obj/item/wrench]", "count" = 4, "place" = "zone", "zone" = list(base.x + 4, base.y + 3, base.x + 6, base.y + 3, base.z)), made)
		run.perform(null, spawn_zone)
		var/wrenches = 0
		for(var/turf/tile as anything in babylon_tutorial_zone_turfs(spawn_zone.setting("zone")))
			for(var/obj/item/wrench/wrench in tile)
				wrenches++
		result["spawned_in_zone"] = wrenches == 4
		run.spawned_count = 499
		run.perform(null, spawn_scanners)
		var/scanners_after = 0
		for(var/obj/item/healthanalyzer/scanner in spawn_tile)
			scanners_after++
		result["spawn_run_cap"] = scanners_after == 2 && findtext(run.action_notes[spawn_scanners], "at most")
		run.spawned_count = 0

		// #6 Remove objects: never players, mobs, tutorial objects or protected things.
		var/turf/clean_tile = locate(base.x + 4, base.y + 2, base.z)
		var/obj/babylon_tutorial/marker/clean_marker = babylon_tutorial_test_place(/obj/babylon_tutorial/marker, clean_tile, "wa_clean", list("target" = "tile"), made)
		var/obj/item/wrench/loose = new(clean_tile)
		made += loose
		var/obj/item/screwdriver/protected = new(clean_tile)
		made += protected
		protected.resistance_flags |= INDESTRUCTIBLE
		var/obj/structure/table/table = new(clean_tile)
		made += table
		var/obj/structure/closet/occupied = new(clean_tile)
		made += occupied
		var/mob/living/carbon/human/hider = new(occupied)
		made += hider
		var/obj/structure/closet/crate/crate = new(clean_tile)
		made += crate
		var/obj/item/crowbar/inside_protected = new(crate)
		made += inside_protected
		inside_protected.resistance_flags |= INDESTRUCTIBLE
		var/mob/living/carbon/human/bystander = new(clean_tile)
		made += bystander
		var/obj/babylon_tutorial/action/remove_objects/remove_loose = babylon_tutorial_test_place(/obj/babylon_tutorial/action/remove_objects, base, "wa_rm_loose", list("marker" = "wa_clean"), made)
		run.perform(null, remove_loose)
		result["remove_loose_items"] = QDELETED(loose) && !QDELETED(protected) && !QDELETED(table) && !QDELETED(clean_marker)
		var/obj/babylon_tutorial/action/remove_objects/remove_closets = babylon_tutorial_test_place(/obj/babylon_tutorial/action/remove_objects, base, "wa_rm_closets", list("marker" = "wa_clean", "what" = "type", "object_type" = "[/obj/structure/closet]"), made)
		run.perform(null, remove_closets)
		result["remove_type_with_subtypes"] = QDELETED(crate) && !QDELETED(inside_protected) && get_turf(inside_protected) == clean_tile
		result["remove_never_mobs"] = !QDELETED(occupied) && !QDELETED(hider) && hider.loc == occupied && !QDELETED(bystander)
		var/obj/babylon_tutorial/action/remove_objects/remove_all = babylon_tutorial_test_place(/obj/babylon_tutorial/action/remove_objects, base, "wa_rm_all", list("marker" = "wa_clean", "what" = "type", "object_type" = "[/obj]"), made)
		result["remove_any_type_allowed"] = remove_all.setting("object_type") == "[/obj]"
		run.perform(null, remove_all)
		result["remove_all_keeps_protected"] = QDELETED(table) && !QDELETED(protected) && !QDELETED(clean_marker) && !QDELETED(occupied)
		result["protected_rules"] = !babylon_tutorial_removable(clean_marker) && !babylon_tutorial_removable(protected) && !babylon_tutorial_removable(occupied)

		// #7 Set inventory: store a builder's loadout, apply it to every player, round trip.
		var/mob/living/carbon/human/builder = new(locate(base.x + 6, base.y + 2, base.z))
		made += builder
		var/obj/item/clothing/under/rank/medical/scrubs/purple/scrubs = new(builder)
		builder.equip_to_slot_or_del(scrubs, ITEM_SLOT_ICLOTHING)
		var/obj/item/storage/backpack/pack = new(builder)
		builder.equip_to_slot_or_del(pack, ITEM_SLOT_BACK)
		var/obj/item/stack/medical/suture/packed = new(pack, 5)
		packed.forceMove(pack)
		var/obj/item/reagent_containers/cup/beaker/beaker = new(builder)
		beaker.reagents.add_reagent(/datum/reagent/water, 12)
		builder.put_in_hand(beaker, 1)
		var/obj/item/wrench/lucky = new(builder)
		lucky.name = "lucky wrench"
		builder.equip_to_slot_or_del(lucky, ITEM_SLOT_LPOCKET)
		var/obj/item/wand = new /obj/item/babylon_tutorial_wand(builder)
		made += wand
		builder.put_in_hand(wand, 2)
		var/list/captured = babylon_tutorial_capture_loadout(builder)
		var/list/loadout = captured["loadout"]
		var/list/types = list()
		for(var/list/entry in loadout)
			types += entry["type"]
		result["capture_items"] = ("[/obj/item/clothing/under/rank/medical/scrubs/purple]" in types) && ("[/obj/item/storage/backpack]" in types) && ("[/obj/item/reagent_containers/cup/beaker]" in types) && ("[/obj/item/wrench]" in types)
		result["capture_leaves_wand"] = !("[/obj/item/babylon_tutorial_wand]" in types)
		var/obj/babylon_tutorial/action/inventory/dress = babylon_tutorial_test_place(/obj/babylon_tutorial/action/inventory, base, "wa_dress", list(), made)
		result["loadout_stored"] = isnull(dress.set_setting("loadout", loadout)) && length(dress.setting("loadout")) == length(loadout)
		// The stored loadout survives the JSON of the save.
		var/list/decoded_settings = json_decode(dress.settings_json)
		var/list/decoded = decoded_settings["loadout"]
		result["loadout_in_json"] = length(decoded) == length(loadout)
		var/mob/living/carbon/human/student = new(locate(base.x + 7, base.y + 2, base.z))
		made += student
		var/obj/item/clothing/shoes/sneakers/black/old_shoes = new(student)
		student.equip_to_slot_or_del(old_shoes, ITEM_SLOT_FEET)
		var/obj/item/stock_parts/power_store/cell/old_cell = new(student)
		student.put_in_hand(old_cell, 1)
		run.add_player(student)
		run.perform(null, dress)
		var/obj/item/storage/backpack/student_pack = student.get_item_by_slot(ITEM_SLOT_BACK)
		var/obj/item/stack/medical/suture/student_gauze = student_pack ? locate(/obj/item/stack/medical/suture) in student_pack : null
		var/obj/item/reagent_containers/cup/beaker/student_beaker = student.held_items[1]
		var/obj/item/student_pocket = student.get_item_by_slot(ITEM_SLOT_LPOCKET)
		result["loadout_applied"] = istype(student.w_uniform, /obj/item/clothing/under/rank/medical/scrubs/purple) && istype(student_pack)
		result["loadout_round_trip_contents"] = student_gauze?.amount == 5
		result["loadout_round_trip_reagents"] = istype(student_beaker) && round(student_beaker.reagents.get_reagent_amount(/datum/reagent/water)) == 12
		result["loadout_round_trip_name"] = student_pocket?.name == "lucky wrench"
		result["loadout_replaces_old"] = QDELETED(old_shoes) && QDELETED(old_cell)
		// Clear hands, dropping: the beaker lands on the floor; the wand never goes.
		var/obj/babylon_tutorial/action/inventory/drop_hands = babylon_tutorial_test_place(/obj/babylon_tutorial/action/inventory, base, "wa_drop", list("inventory" = "clear_hands", "old_items" = "drop"), made)
		var/obj/item/wand_two = new /obj/item/babylon_tutorial_wand(student)
		made += wand_two
		student.put_in_hand(wand_two, 2)
		run.perform(null, drop_hands)
		result["clear_hands_drops"] = !QDELETED(student_beaker) && student_beaker.loc == get_turf(student) && !QDELETED(student_pocket) && student.w_uniform
		result["wand_never_removed"] = student.is_holding(wand_two)
		made += student_beaker
		var/obj/babylon_tutorial/action/inventory/strip = babylon_tutorial_test_place(/obj/babylon_tutorial/action/inventory, base, "wa_strip", list("inventory" = "clear_all"), made)
		run.perform(null, strip)
		result["clear_all_deletes"] = !student.w_uniform && !student.get_item_by_slot(ITEM_SLOT_BACK) && QDELETED(student_pocket) && student.is_holding(wand_two)
		// Refusals: a blocked item, an unknown slot, two items in one place; foreign settings stay out.
		result["loadout_refuses_blocked"] = !!dress.set_setting("loadout", list(list("type" = "[/obj/item/grenade/clusterbuster]", "slot" = ITEM_SLOT_BELT)))
		result["loadout_refuses_bad_slot"] = !!dress.set_setting("loadout", list(list("type" = "[/obj/item/wrench]", "slot" = 3)))
		result["loadout_refuses_doubles"] = !!dress.set_setting("loadout", list(list("type" = "[/obj/item/wrench]", "hand" = 1), list("type" = "[/obj/item/crowbar]", "hand" = 1)))
		var/list/cleaned = babylon_tutorial_clean_loadout(list(list("type" = "[/obj/item/wrench]", "hand" = 1, "fields" = list("bad name!" = 1, "force" = list(1, list(2, list(3)))))))
		var/list/cleaned_entry = length(cleaned["value"]) ? cleaned["value"][1] : null
		result["loadout_drops_odd_fields"] = cleaned_entry && !cleaned_entry["fields"]
		// The window's edits: add by type to a place (replacing what is there), remove.
		var/datum/babylon_tutorial_editor/editor = new(dress, null)
		dress.set_setting("loadout", list())
		editor.loadout_act(builder, dress, "loadout", "loadout_add", list("place" = "hand:2", "path" = "[/obj/item/healthanalyzer]"))
		editor.loadout_act(builder, dress, "loadout", "loadout_add", list("place" = "hand:2", "path" = "[/obj/item/crowbar]"))
		editor.loadout_act(builder, dress, "loadout", "loadout_add", list("place" = "packed", "path" = "[/obj/item/stack/medical/suture]"))
		var/list/edited = dress.setting("loadout")
		result["editor_add_replaces"] = length(edited) == 2 && edited[1]["type"] == "[/obj/item/crowbar]" && edited[1]["hand"] == 2
		editor.loadout_act(builder, dress, "loadout", "loadout_add", list("place" = "slot:[ITEM_SLOT_BELT]", "path" = "[/obj/item/grenade/clusterbuster]"))
		result["editor_add_refuses_blocked"] = length(dress.setting("loadout")) == 2 && editor.notice && !editor.notice["ok"]
		editor.loadout_act(builder, dress, "loadout", "loadout_remove", list("index" = 0))
		result["editor_remove"] = length(dress.setting("loadout")) == 1
		editor.loadout_act(builder, dress, "loadout", "store_loadout", list())
		result["editor_store"] = length(dress.setting("loadout")) == length(loadout)
		qdel(editor)
		// On an NPC: its new items are never saved (like its outfit).
		var/obj/babylon_tutorial/action/inventory/dress_npc = babylon_tutorial_test_place(/obj/babylon_tutorial/action/inventory, base, "wa_dress_npc", list("apply_to" = "npc", "target" = "wa_free", "loadout" = list(list("type" = "[/obj/item/healthanalyzer]", "hand" = 1))), made)
		free.SetKnockdown(0)
		run.perform(null, dress_npc)
		var/obj/item/npc_scanner = free.held_items[1]
		result["npc_loadout_not_saved"] = istype(npc_scanner, /obj/item/healthanalyzer) && npc_scanner.babylon_tutorial_npc_item

		// #11 Start event: the Creative panel's list and rules, stepped where nothing else does.
		var/obj/babylon_tutorial/action/start_event/event_action = babylon_tutorial_test_place(/obj/babylon_tutorial/action/start_event, base, "wa_event", list(), made)
		result["event_refuses_blocked"] = !!event_action.set_setting("event", "/datum/round_event_control/immovable_rod") && !!event_action.set_setting("event", "/datum/round_event_control/antagonist/solo/traitor")
		result["event_accepts_offered"] = isnull(event_action.set_setting("event", "/datum/round_event_control/communications_blackout"))
		GLOB.babylon_tutorial_event_times.Cut()
		var/events_before = length(GLOB.babylon_tutorial_events)
		run.perform(null, event_action)
		var/datum/weakref/started_ref = length(GLOB.babylon_tutorial_events) > events_before ? GLOB.babylon_tutorial_events[length(GLOB.babylon_tutorial_events)] : null
		var/datum/round_event/started = started_ref?.resolve()
		result["event_started"] = istype(started) && (started in SSevents.running)
		if(started)
			var/before = started.activeFor
			for(var/i in 1 to 4)
				babylon_tutorial_step_events()
			result["event_stepped"] = babylon_creative_enabled() || !babylon_creative_events_need_stepping() || started.activeFor > before
		for(var/i in 1 to 3)
			GLOB.babylon_tutorial_event_times += world.time
		run.perform(null, event_action)
		result["event_rate_limited"] = findtext(run.action_notes[event_action], "not started") != 0
		babylon_creative_end_events()

		// #12 Door / container: each thing's own procs; lock and unlock are forced.
		var/turf/door_tile = locate(base.x + 3, base.y + 1, base.z)
		var/obj/machinery/door/airlock/airlock = new(door_tile)
		made += airlock
		babylon_tutorial_test_place(/obj/babylon_tutorial/marker, door_tile, "wa_door", list("target" = "tile"), made)
		var/obj/babylon_tutorial/action/door/bolt = babylon_tutorial_test_place(/obj/babylon_tutorial/action/door, base, "wa_bolt", list("door_action" = "lock", "marker" = "wa_door"), made)
		var/obj/babylon_tutorial/action/door/unbolt = babylon_tutorial_test_place(/obj/babylon_tutorial/action/door, base, "wa_unbolt", list("door_action" = "unlock", "marker" = "wa_door"), made)
		var/obj/babylon_tutorial/action/door/open_door = babylon_tutorial_test_place(/obj/babylon_tutorial/action/door, base, "wa_open", list("door_action" = "open", "marker" = "wa_door"), made)
		var/obj/babylon_tutorial/action/door/close_door = babylon_tutorial_test_place(/obj/babylon_tutorial/action/door, base, "wa_close", list("door_action" = "close", "marker" = "wa_door"), made)
		run.perform(null, bolt)
		result["airlock_bolted"] = airlock.locked
		run.perform(null, open_door)
		result["bolted_airlock_stays_shut"] = airlock.density && findtext(run.action_notes[open_door], "bolted")
		run.perform(null, unbolt)
		result["airlock_unbolted"] = !airlock.locked
		run.perform(null, open_door)
		if(airlock.hasPower())
			sleep(2 SECONDS)
			result["airlock_opens"] = !airlock.density
			run.perform(null, close_door)
			sleep(2 SECONDS)
			result["airlock_closes"] = airlock.density
		else
			result["unpowered_airlock_noted"] = airlock.density && findtext(run.action_notes[open_door], "no power")
		// A secure locker: locked ones stay shut until unlocked; lock closes an open one first.
		var/turf/locker_tile = locate(base.x + 3, base.y + 3, base.z)
		var/obj/structure/closet/secure_closet/locker = new(locker_tile)
		made += locker
		babylon_tutorial_test_place(/obj/babylon_tutorial/marker, locker_tile, "wa_locker", list("target" = "tile"), made)
		var/obj/babylon_tutorial/action/door/lock_locker = babylon_tutorial_test_place(/obj/babylon_tutorial/action/door, base, "wa_lock_l", list("door_action" = "lock", "marker" = "wa_locker"), made)
		var/obj/babylon_tutorial/action/door/unlock_locker = babylon_tutorial_test_place(/obj/babylon_tutorial/action/door, base, "wa_unlock_l", list("door_action" = "unlock", "marker" = "wa_locker"), made)
		var/obj/babylon_tutorial/action/door/open_locker = babylon_tutorial_test_place(/obj/babylon_tutorial/action/door, base, "wa_open_l", list("door_action" = "open", "marker" = "wa_locker"), made)
		var/obj/babylon_tutorial/action/door/close_locker = babylon_tutorial_test_place(/obj/babylon_tutorial/action/door, base, "wa_close_l", list("door_action" = "close", "marker" = "wa_locker"), made)
		run.perform(null, lock_locker)
		run.perform(null, open_locker)
		result["locked_locker_stays_shut"] = locker.locked && !locker.opened && findtext(run.action_notes[open_locker], "locked")
		run.perform(null, unlock_locker)
		run.perform(null, open_locker)
		result["locker_unlocked_and_opened"] = !locker.locked && locker.opened
		run.perform(null, lock_locker)
		result["lock_closes_first"] = locker.locked && !locker.opened
		run.perform(null, unlock_locker)
		run.perform(null, open_locker)
		run.perform(null, close_locker)
		result["locker_closed"] = !locker.opened
		// Shutters by their button id; they have no bolts.
		var/obj/machinery/door/poddoor/shutters/shutter = new(locate(base.x + 5, base.y + 2, base.z))
		made += shutter
		shutter.id = "wa_test_shutters"
		var/obj/babylon_tutorial/action/door/open_shutters = babylon_tutorial_test_place(/obj/babylon_tutorial/action/door, base, "wa_shutters", list("door_action" = "open", "place" = "button", "button_id" = "wa_test_shutters"), made)
		var/obj/babylon_tutorial/action/door/lock_shutters = babylon_tutorial_test_place(/obj/babylon_tutorial/action/door, base, "wa_lock_shut", list("door_action" = "lock", "place" = "button", "button_id" = "wa_test_shutters"), made)
		result["shutters_found_by_id"] = (shutter in open_shutters.targets())
		var/was_closed = shutter.density
		run.perform(null, open_shutters)
		sleep(2 SECONDS)
		result["shutters_open"] = was_closed && !shutter.density
		run.perform(null, lock_shutters)
		result["shutters_no_bolts_noted"] = findtext(run.action_notes[lock_shutters], "can't be locked") != 0
		var/obj/machinery/door/firedoor/firelock = new(locate(base.x + 6, base.y + 3, base.z))
		made += firelock
		result["firelocks_left_alone"] = !babylon_tutorial_door_target(firelock)
		var/obj/babylon_tutorial/action/door/nothing = babylon_tutorial_test_place(/obj/babylon_tutorial/action/door, base, "wa_nothing", list("door_action" = "open", "place" = "zone"), made)
		result["unpicked_zone_warned"] = !!nothing.issues()["zone"]

		// Ending the run drops its notes and its walks.
		babylon_tutorial_end()
		result["end_clears_notes"] = !walk_far.issues()["live"]
	catch(var/exception/error)
		result["no_error"] = FALSE
		log_world("test_tutorial_world_actions failed: [error] ([error.file]:[error.line])")
	babylon_tutorial_end()
	GLOB.babylon_tutorial_event_times = old_event_times
	babylon_tutorial_test_cleanup(made)
	// What the actions spawned and dropped goes too.
	babylon_area_clear_tiles(babylon_area_tiles(rect[1], rect[2], rect[3], rect[4], rect[5]), rect, /turf/open/floor/iron)
	return result
