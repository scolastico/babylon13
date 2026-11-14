// Creative panel smoke test, in both test builds (babylon-test.dme, babylon-station-test.dme).
// Every check must be TRUE. It switches Creative on and off itself and restores the flag.

/datum/babylon_save/proc/test_creative_panel_actions()
	var/list/result = list()
	var/datum/babylon_world/flags = GLOB.babylon_world
	var/was_creative = flags.creative
	var/was_on = creative_was_on
	var/turf/start = babylon_creative_free_turf(respawn_turf)
	var/body_type = babylon_is_station_build() ? /mob/living/carbon/human : text2path("/mob/living/basic/drone/babylon/replacement")
	var/mob/living/body = new body_type(start)
	body.ckey = "babylonsmokecreative"
	var/mob/living/stranger = new body_type(start)
	stranger.ckey = "babylonsmokestranger"
	var/list/cleanup = list(body, stranger)
	var/datum/babylon_creative_panel/panel = babylon_creative_panel_for(body.ckey)

	// Creative off: no panel, no button, every action refused.
	flags.creative = FALSE
	babylon_creative_sync(body)
	result["disabled_no_panel"] = !babylon_creative_open(body)
	result["disabled_no_button"] = !babylon_creative_test_button(body)
	result["disabled_actions_refused"] = !panel.handle_action(body, "godmode") && !HAS_TRAIT(body, TRAIT_GODMODE) \
		&& !panel.handle_action(body, "spawn", list("path" = "/obj/item/wrench"))

	flags.creative = TRUE
	babylon_creative_sync(body)
	result["enabled_button"] = !!babylon_creative_test_button(body)
	result["stranger_refused"] = !panel.handle_action(stranger, "godmode") && !HAS_TRAIT(stranger, TRAIT_GODMODE)

	// Self: godmode toggles TRAIT_GODMODE from the creative source only.
	panel.handle_action(body, "godmode")
	var/godmode_on = HAS_TRAIT_FROM(body, TRAIT_GODMODE, BABYLON_CREATIVE_TRAIT)
	panel.handle_action(body, "godmode")
	result["godmode_toggles"] = godmode_on && !HAS_TRAIT(body, TRAIT_GODMODE)
	body.adjust_brute_loss(20)
	var/hurt = body.health < body.maxHealth
	panel.handle_action(body, "heal")
	result["heal"] = hurt && body.health >= body.maxHealth

	// Spawn: at the feet, stacks clamped, blocked paths refused, rate limit.
	var/wrenches = babylon_creative_test_count(start, /obj/item/wrench)
	panel.handle_action(body, "spawn", list("path" = "/obj/item/wrench", "amount" = 2))
	result["spawn_creates"] = babylon_creative_test_count(start, /obj/item/wrench) == wrenches + 2
	panel.handle_action(body, "spawn", list("path" = "/obj/item/stack/sheet/iron", "amount" = 5000))
	var/obj/item/stack/sheet/iron/sheets = locate() in start
	result["stack_amount_clamped"] = sheets?.amount == sheets?.max_amount
	panel.handle_action(body, "spawn", list("path" = "/obj/item/stack/rods", "amount" = 7, "in_hand" = TRUE))
	var/obj/item/stack/rods/rods = locate() in body.held_items
	result["spawn_in_hand"] = rods?.amount == 7
	panel.handle_action(body, "spawn", list("path" = "/obj/item/debug/omnitool"))
	result["blocked_path_refused"] = !panel.notice_ok && !(locate(/obj/item/debug/omnitool) in start)
	var/dirt = babylon_creative_test_count(start, /obj/effect/decal/cleanable/dirt)
	panel.handle_action(body, "spawn", list("path" = "/obj/effect/decal/cleanable/dirt"))
	result["outside_roots_refused"] = !panel.notice_ok && babylon_creative_test_count(start, /obj/effect/decal/cleanable/dirt) == dirt
	result["blacklist"] = babylon_creative_spawn_blocked(/obj/item/disk/nuclear) && babylon_creative_spawn_blocked(/obj/machinery/nuclearbomb) \
		&& babylon_creative_spawn_blocked(/obj/item/construction/rcd/combat/admin) && babylon_creative_spawn_blocked(/mob/living/carbon/human/dummy) \
		&& babylon_creative_spawn_blocked(/obj/item) && babylon_creative_spawn_blocked(/datum) && babylon_creative_spawn_blocked("/obj/item/wrench") \
		&& !babylon_creative_spawn_blocked(/obj/item/wrench) && !babylon_creative_spawn_blocked(/mob/living/carbon/human) \
		&& !babylon_creative_spawn_blocked(/mob/living/basic/pet/dog/corgi) && !babylon_creative_spawn_blocked(/obj/machinery/power/smes)
	panel.spawn_times.Cut()
	wrenches = babylon_creative_test_count(start, /obj/item/wrench)
	panel.handle_action(body, "spawn", list("path" = "/obj/item/wrench", "amount" = BABYLON_CREATIVE_MAX_COPIES))
	panel.handle_action(body, "spawn", list("path" = "/obj/item/wrench", "amount" = BABYLON_CREATIVE_SPAWN_LIMIT - BABYLON_CREATIVE_MAX_COPIES))
	var/at_limit = babylon_creative_test_count(start, /obj/item/wrench) == wrenches + BABYLON_CREATIVE_SPAWN_LIMIT
	panel.handle_action(body, "spawn", list("path" = "/obj/item/wrench"))
	result["spawn_rate_limited"] = at_limit && !panel.notice_ok && babylon_creative_test_count(start, /obj/item/wrench) == wrenches + BABYLON_CREATIVE_SPAWN_LIMIT
	panel.spawn_times.Cut()
	panel.handle_action(body, "search", list("query" = "wrench", "category" = "tools"))
	var/search_clean = length(panel.search_results) > 0
	for(var/list/entry as anything in panel.search_results)
		if(babylon_creative_spawn_blocked(text2path(entry["path"])) || !ispath(text2path(entry["path"]), /obj/item))
			search_clean = FALSE
	panel.handle_action(body, "search", list("query" = "omnitool", "category" = "all"))
	for(var/list/entry as anything in panel.search_results)
		if(findtext(entry["path"], "debug"))
			search_clean = FALSE
	result["search"] = search_clean
	result["categories"] = length(babylon_creative_categories()) == length(babylon_creative_category_ids()) - 1
	panel.last_search = -INFINITY
	panel.handle_action(body, "search", list("query" = "metal", "category" = "materials"))
	var/alias_found = FALSE
	for(var/list/entry as anything in panel.search_results)
		if(entry["path"] == "[/obj/item/stack/sheet/iron]")
			alias_found = TRUE
	result["search_alias"] = alias_found
	panel.handle_action(body, "search", list("query" = "dildo", "category" = "all"))
	result["search_cooldown"] = panel.search_query == "metal"
	panel.last_search = -INFINITY
	panel.handle_action(body, "search", list("query" = "dildo", "category" = "all"))
	result["search_no_erp"] = panel.search_query == "dildo" && !length(panel.search_results)
	result["erp_blocked"] = babylon_type_is_erp(/obj/item/clothing/sextoy/dildo) && babylon_creative_spawn_blocked(/obj/item/clothing/sextoy/dildo) \
		&& babylon_creative_spawn_blocked(/obj/structure/stripper_pole) && !babylon_type_is_erp(/obj/item/wrench) && !babylon_type_is_erp(/obj/item/clothing/suit/hazardvest)
	panel.last_search = -INFINITY
	panel.handle_action(body, "search", list("query" = "tank", "category" = "all"))
	var/hints = TRUE
	var/list/names_seen = list()
	for(var/list/entry as anything in panel.search_results)
		names_seen[entry["name"]] = (names_seen[entry["name"]] || 0) + 1
	for(var/list/entry as anything in panel.search_results)
		if(names_seen[entry["name"]] > 1 && !entry["hint"])
			hints = FALSE
	result["same_names_get_hints"] = hints && panel.search_capped

	// Blacklist rules from the review: singularity makers, spreading cores, shuttle control,
	// CentCom IDs, mob makers, and the board of every blocked machine.
	result["blocked_singularity"] = babylon_creative_spawn_blocked(/obj/singularity) && babylon_creative_spawn_blocked(/obj/energy_ball) \
		&& babylon_creative_spawn_blocked(/obj/machinery/power/singularity_beacon) && !babylon_creative_spawn_blocked(/obj/machinery/power/supermatter_crystal)
	result["blocked_spreading"] = babylon_creative_spawn_blocked(/obj/structure/mold) && babylon_creative_spawn_blocked(/obj/structure/fleshmind) \
		&& babylon_creative_spawn_blocked(/obj/structure/spacevine) && babylon_creative_spawn_blocked(/obj/structure/alien/weeds/node)
	result["blocked_shuttle_and_ids"] = babylon_creative_spawn_blocked(/obj/machinery/computer/shuttle) \
		&& babylon_creative_spawn_blocked(/obj/machinery/computer/camera_advanced/shuttle_docker) \
		&& babylon_creative_spawn_blocked(/obj/item/card/id/advanced/centcom/ert) && babylon_creative_spawn_blocked(/obj/item/card/id/advanced/black/deathsquad)
	result["blocked_mob_makers"] = babylon_creative_spawn_blocked(/mob/living/basic/mining/legion) && babylon_creative_spawn_blocked(/mob/living/basic/regal_rat) \
		&& babylon_creative_spawn_blocked(/obj/item/mmi/posibrain)
	var/boards_follow = TRUE
	var/shuttle_boards = 0
	for(var/obj/item/circuitboard/board as anything in typesof(/obj/item/circuitboard))
		var/builds = initial(board.build_path)
		if(ispath(builds, /obj/machinery/computer/shuttle))
			shuttle_boards++
		if(ispath(builds) && babylon_creative_spawn_blocked(builds) && !babylon_creative_spawn_blocked(board))
			boards_follow = FALSE
	result["blocked_machine_boards"] = boards_follow && shuttle_boards > 0

	// Supermatter: spawnable, but no singularity, tesla or cascade here.
	var/datum/sm_delam/delam = GLOB.sm_delam_list[/datum/sm_delam/singularity]
	var/datum/sm_delam/cascade = GLOB.sm_delam_list[/datum/sm_delam/cascade]
	var/singularities = length(GLOB.singularities)
	var/turf/far = babylon_creative_free_turf(locate(clamp(start.x + 8, 1, world.maxx), start.y, start.z)) || start
	var/obj/machinery/power/supermatter_crystal/shard/shard = new(far)
	cleanup += shard
	var/made_singulo = delam.effect_singulo(shard)
	var/datum/sm_delam/tesla = GLOB.sm_delam_list[/datum/sm_delam/tesla]
	var/made_tesla = tesla.effect_tesla(shard)
	result["supermatter_contained"] = babylon_delam_contained() && !made_singulo && !made_tesla && !QDELETED(shard) \
		&& !cascade.can_select(shard) && length(GLOB.singularities) == singularities
	// Outside creative and tutorial worlds the delaminations are untouched.
	flags.creative = FALSE
	var/kind = flags.kind
	flags.kind = "world"
	result["supermatter_normal_elsewhere"] = !babylon_delam_contained()
	flags.kind = "tutorial"
	result["supermatter_contained_in_tutorials"] = babylon_delam_contained()
	flags.kind = kind
	flags.creative = TRUE
	result["rod_event_refused"] = istext(babylon_creative_run_event(body, "/datum/round_event_control/immovable_rod"))
	result["blocked_ghost_pollers"] = babylon_creative_spawn_blocked(/obj/item/guardian_creator) && babylon_creative_spawn_blocked(/obj/item/slimepotion/sentience) \
		&& babylon_creative_spawn_blocked(/obj/item/clothing/head/helmet/monkey_sentience) && babylon_creative_spawn_blocked(/obj/item/soulscythe) \
		&& babylon_creative_spawn_blocked(/obj/item/aicard/syndie/loaded) && babylon_creative_spawn_blocked(/obj/machinery/experimental_cloner) \
		&& babylon_creative_spawn_blocked(/obj/item/clothing/neck/tie/disco) && babylon_creative_spawn_blocked(/mob/living/basic/bot/cleanbot) \
		&& babylon_creative_spawn_blocked(/obj/item/organ/zombie_infection) && babylon_creative_spawn_blocked(/obj/machinery/computer/communications)

	// Mob cap: a world full of creative mobs refuses more.
	var/list/mobs_before = GLOB.babylon_creative_mobs.Copy()
	for(var/i in 1 to BABYLON_CREATIVE_MOB_CAP)
		GLOB.babylon_creative_mobs += WEAKREF(body)
	var/corgis = babylon_creative_test_count(start, /mob/living/basic/pet/dog/corgi)
	panel.handle_action(body, "spawn", list("path" = "/mob/living/basic/pet/dog/corgi"))
	result["mob_cap"] = !panel.notice_ok && babylon_creative_test_count(start, /mob/living/basic/pet/dog/corgi) == corgis
	GLOB.babylon_creative_mobs = mobs_before
	panel.spawn_times.Cut()

	// Teleport: coordinates clamped to the map, only this world's levels, areas, unstuck.
	panel.handle_action(body, "noclip")
	result["noclip_on"] = body.incorporeal_move == INCORPOREAL_MOVE_BASIC
	// (Map edges are space transitions: check the clamping itself, not a move onto the edge.)
	var/turf/clamped = babylon_creative_coordinates_turf("99999", -40, start.z)
	result["teleport_clamped"] = clamped?.x == world.maxx && clamped?.y == 1 && clamped?.z == start.z \
		&& isnull(babylon_creative_coordinates_turf(10, 10, "abc"))
	var/turf/before = get_turf(body)
	var/foreign_z = 0
	for(var/z in 1 to world.maxz)
		if(!babylon_creative_level_allowed(z))
			foreign_z = z
	panel.handle_action(body, "teleport_coords", list("x" = 10, "y" = 10, "z" = foreign_z || world.maxz + 1))
	result["teleport_other_levels_refused"] = !panel.notice_ok && get_turf(body) == before
	panel.handle_action(body, "teleport_coords", list("x" = start.x, "y" = start.y, "z" = start.z))
	result["teleport_moves"] = get_turf(body) == start
	var/area/start_area = get_area(start)
	panel.handle_action(body, "teleport_area", list("path" = "[start_area.type]"))
	result["teleport_area"] = panel.notice_ok && get_area(body) == start_area
	panel.handle_action(body, "teleport_area", list("path" = "/area/centcom"))
	result["teleport_area_centcom_refused"] = !panel.notice_ok && get_area(body) == start_area
	var/obj/structure/girder/wall = new(start)
	cleanup += wall
	body.forceMove(start)
	panel.handle_action(body, "noclip")
	result["noclip_off_unstuck"] = !body.babylon_creative_noclip && !body.incorporeal_move && get_turf(body) != start \
		&& !babylon_creative_turf_blocked(get_turf(body), body) && get_dist(body, start) <= BABYLON_CREATIVE_UNSTUCK_RANGE
	qdel(wall)
	// Teleporting out of a closet leaves the closet behind, empty of the body.
	var/obj/structure/closet/locker = new(start)
	cleanup += locker
	body.forceMove(locker)
	panel.handle_action(body, "teleport_coords", list("x" = start.x, "y" = start.y, "z" = start.z))
	result["teleport_leaves_closet"] = isturf(body.loc) && !(body in locker.contents)
	panel.handle_action(body, "teleport_back")
	result["teleport_back"] = panel.notice_ok
	qdel(locker)
	body.forceMove(start)
	panel.handle_action(body, "teleport_coords", list("x" = start.x, "y" = start.y, "z" = start.z))

	// Events: offered list is filtered; one can be started and is stepped where SSevents is off.
	var/list/events = babylon_creative_events()
	var/events_clean = length(events) > 0
	for(var/list/entry as anything in events)
		var/path = text2path(entry["path"])
		if(ispath(path, /datum/round_event_control/antagonist) || ispath(path, /datum/round_event_control/spacevine) || ispath(path, /datum/round_event_control/wizard))
			events_clean = FALSE
	result["events_listed"] = events_clean
	var/running = length(SSevents.running)
	panel.handle_action(body, "run_event", list("path" = "/datum/round_event_control/communications_blackout"))
	var/datum/round_event/started = length(SSevents.running) > running ? SSevents.running[length(SSevents.running)] : null
	result["event_started"] = panel.notice_ok && istype(started, /datum/round_event/communications_blackout)
	if(started && babylon_creative_events_need_stepping())
		var/active = started.activeFor
		babylon_creative_step_events()
		result["event_stepped_without_ssevents"] = started.activeFor == active + 1
	started?.kill()
	panel.handle_action(body, "run_event", list("path" = "/datum/round_event_control/antagonist/solo/traitor"))
	result["blocked_event_refused"] = !panel.notice_ok
	result["dangerous_events_refused"] = istext(babylon_creative_run_event(body, "/datum/round_event_control/dark_matteor")) \
		&& istext(babylon_creative_run_event(body, "/datum/round_event_control/sandstorm")) \
		&& istext(babylon_creative_run_event(body, "/datum/round_event_control/icarus_sunbeam"))
	var/datum/round_event_control/communications_blackout/never_random = new
	never_random.weight = 0
	var/weightless = babylon_creative_event_blocked(never_random)
	never_random.weight = 10
	never_random.max_occurrences = 0
	result["admin_only_events_refused"] = weightless && babylon_creative_event_blocked(never_random)
	qdel(never_random)
	panel.event_times.Cut()

	// Tools: the kit, and the wand (refused while it does not exist).
	panel.handle_action(body, "give_tools")
	var/obj/item/storage/belt/utility/belt = locate() in body.get_all_contents()
	belt ||= locate() in start
	result["tool_kit"] = panel.notice_ok && length(belt?.contents) >= 7 \
		&& !!((locate(/obj/item/construction/rcd) in body.get_all_contents()) || (locate(/obj/item/construction/rcd) in start))
	panel.handle_action(body, "give_wand")
	result["wand"] = ispath(babylon_tutorial_wand_type(), /obj/item) ? panel.notice_ok : !panel.notice_ok

	// Creative switched off at runtime: the world tick takes everything back.
	panel.handle_action(body, "godmode")
	panel.handle_action(body, "noclip")
	panel.event_times.Cut()
	panel.handle_action(body, "run_event", list("path" = "/datum/round_event_control/wormholes"))
	var/datum/round_event/wormholes/lingering = length(SSevents.running) ? SSevents.running[length(SSevents.running)] : null
	var/list/holes = list()
	if(istype(lingering))
		lingering.start_when = lingering.activeFor
		lingering.process() // starts it: the wormholes open
		holes = lingering.wormholes?.Copy()
	flags.creative = FALSE
	creative_was_on = TRUE
	tick_creative()
	result["runtime_off_revokes"] = !HAS_TRAIT(body, TRAIT_GODMODE) && !body.babylon_creative_noclip && !body.incorporeal_move \
		&& !babylon_creative_test_button(body)
	var/holes_closed = length(holes) > 0
	for(var/obj/effect/portal/wormhole/hole as anything in holes)
		if(!QDELETED(hole))
			holes_closed = FALSE
	result["runtime_off_ends_events"] = istype(lingering) && !(lingering in SSevents.running) && holes_closed

	flags.creative = was_creative
	creative_was_on = was_on
	GLOB.babylon_creative_panels -= body.ckey
	// Test bodies were never played: drop their keys so deleting them is not a lost player.
	body.ckey = null
	stranger.ckey = null
	for(var/atom/movable/thing in start)
		if(thing.type in list(/obj/item/wrench, /obj/item/stack/sheet/iron, /obj/item/stack/rods))
			cleanup += thing
	for(var/obj/item/thing in body.get_all_contents())
		cleanup += thing
	cleanup += belt
	for(var/datum/thing as anything in cleanup)
		if(thing && !QDELETED(thing))
			qdel(thing)
	return result

/proc/babylon_creative_test_button(mob/user)
	for(var/datum/action/babylon_creative/button in user.actions)
		return button
	return null

/proc/babylon_creative_test_count(turf/spot, path)
	. = 0
	for(var/atom/movable/thing in spot)
		if(thing.type == path)
			.++
