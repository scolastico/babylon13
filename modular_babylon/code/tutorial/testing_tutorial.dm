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
		var/list/types = list("text", "longtext", "number", "bool", "choice", "typepath", "id", "idlist", "zone", "effects", "target")
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
		result["npc_target_validated"] = !burn_npc.issues()["target"] && !!hurt.set_setting("effect", "gib")

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

		// #19 a destroyed body: a new one with the same looks and clothes, where it died.
		var/obj/item/clothing/under/rank/medical/doctor/scrubs = new(second)
		second.equip_to_slot_or_del(scrubs, ITEM_SLOT_ICLOTHING)
		result["test_body_dressed"] = second.w_uniform == scrubs
		var/turf/death_tile = locate(base.x + 2, base.y + 3, base.z)
		second.forceMove(death_tile)
		second.death()
		var/mob/dead/observer/second_ghost = second.ghostize(TRUE)
		made += second_ghost
		qdel(second)
		result["destroyed_body_counts_dead"] = !!dead_check.evaluate(run) && !run.body_of(second_key)
		var/list/second_shot = run.snapshots[second_key]
		var/datum/outfit/second_outfit = second_shot?["outfit"]
		result["snapshot_has_clothes"] = second_outfit?.uniform == /obj/item/clothing/under/rank/medical/doctor
		run.perform(null, revive)
		var/mob/living/carbon/human/rebuilt = run.body_of(second_key)
		made += rebuilt
		result["revive_rebuilds_body"] = istype(rebuilt) && rebuilt != second && rebuilt.stat != DEAD && get_turf(rebuilt) == death_tile
		result["rebuilt_looks_the_same"] = rebuilt?.real_name == "Second Tester"
		result["rebuilt_wears_the_same"] = istype(rebuilt?.w_uniform, /obj/item/clothing/under/rank/medical/doctor)
		result["rebuilt_gets_player"] = rebuilt?.ckey == second_key && (QDELETED(second_ghost) || second_ghost.ckey != second_key)
		result["nobody_dead_after_revive"] = !dead_check.evaluate(run)
		result["revive_leaves_living_alone"] = isnull(run.revive_player(first_key))
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
