// Authenticated integration tests for babylon-station.dmb only (babylon-station-test.dme),
// asserted from services/supervisor/smoke_station.py. Every check must be TRUE.

/// The world flags come from the supervisor's start parameters (world_flags.dm).
/datum/babylon_save/proc/test_station_world_flags()
	var/list/result = list()
	var/datum/babylon_world/flags = GLOB.babylon_world
	result["station_build"] = babylon_is_station_build() && flags.build == "station"
	result["map_from_params"] = !!flags.map_id && flags.map_id == world.params["babylon-map"]
	result["persistent_from_params"] = flags.persistent == (world.params["babylon-persistent"] != "0")
	result["creative_from_params"] = flags.creative == (world.params["babylon-creative"] == "1") && babylon_creative_enabled() == flags.creative
	result["kind_from_params"] = flags.kind == (world.params["babylon-kind"] || "world")
	result["owner_from_params"] = flags.owner_ckey == ckey(world.params["babylon-owner"]) && owner_ckey == flags.owner_ckey
	result["unsafe_ids_rejected"] = !babylon_safe_id("../x") && !babylon_safe_id("") && babylon_safe_id("creative_plane_m")
	result["ready"] = babylon_world_ready() && ready
	result["map_loaded"] = SSmapping.current_map?.map_name == "MetaStation" || flags.map_id != "metastation"
	// The Babylon rules (rules.dm) are not compiled in: normal tg rounds.
	result["events_fire"] = !(SSevents.ss_flags & SS_NO_FIRE) && !(SSgamemode.ss_flags & SS_NO_FIRE)
	result["several_levels"] = world.maxz > 1
	result["saving_unavailable"] = !!save_world()["error"]
	return result

/// Station worlds run SPLURT's storytellers without a vote; Creative Plane and tutorials do not.
/datum/babylon_save/proc/test_station_storyteller()
	var/list/result = list()
	var/datum/babylon_world/flags = GLOB.babylon_world
	result["not_inert_on_a_station_map"] = !babylon_storyteller_inert()
	var/chosen = babylon_world_storyteller()
	result["storyteller_not_babylon"] = chosen != /datum/storyteller/babylon && SSgamemode.voted_storyteller == chosen
	result["running_storyteller_not_babylon"] = SSgamemode.storyteller?.type != /datum/storyteller/babylon
	if(!CONFIG_GET(string/default_storyteller))
		result["fallback_without_config"] = chosen == /datum/storyteller/default
	result["vote_refused"] = !SSvote.initiate_vote(/datum/vote/storyteller, "Babylon test", forced = TRUE)
	result["no_vote_running"] = !istype(SSvote.current_vote, /datum/vote/storyteller)
	var/old_map = flags.map_id
	flags.map_id = "creative_plane_m"
	result["creative_plane_inert"] = babylon_storyteller_inert() && babylon_world_storyteller() == /datum/storyteller/babylon
	flags.map_id = old_map
	var/old_kind = flags.kind
	flags.kind = "tutorial"
	result["tutorial_inert"] = babylon_storyteller_inert()
	flags.kind = "tutorial_edit"
	result["tutorial_edit_inert"] = babylon_storyteller_inert()
	flags.kind = old_kind
	result["flags_restored"] = !babylon_storyteller_inert()
	return result

/// Every world is safe for work (sfw.dm), the station build included.
/datum/babylon_save/proc/test_station_sfw()
	var/list/result = list()
	var/datum/config_entry/flag/preferences = config.entries_by_type[/datum/config_entry/flag/disable_erp_preferences]
	var/datum/config_entry/flag/items = config.entries_by_type[/datum/config_entry/flag/disable_lewd_items]
	preferences.ValidateAndSet("0")
	items.ValidateAndSet("0")
	result["erp_preferences_locked_off"] = !!CONFIG_GET(flag/disable_erp_preferences)
	result["lewd_items_locked_off"] = !!CONFIG_GET(flag/disable_lewd_items)
	var/mob/living/carbon/human/dummy/first = new(respawn_turf)
	var/mob/living/basic/mouse/second = new(respawn_turf)
	var/datum/component/interactable/menu = second.GetComponent(/datum/component/interactable)
	menu.build_interactions_list()
	var/allowed_erp = FALSE
	for(var/datum/interaction/interaction as anything in menu.interactions)
		if(babylon_interaction_is_erp(interaction))
			allowed_erp = TRUE
	for(var/name in SSinteractions.interactions)
		var/datum/interaction/interaction = SSinteractions.interactions[name]
		if(babylon_interaction_is_erp(interaction) && menu.can_interact(interaction, first))
			allowed_erp = TRUE
	result["no_erp_interactions"] = !allowed_erp
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
	return result

/// Facts about the running station world for the smoke report (not asserted).
/datum/babylon_save/proc/test_station_info()
	var/list/result = list()
	result["map_name"] = SSmapping.current_map?.map_name
	result["levels"] = world.maxz
	result["ticker_state"] = SSticker.current_state
	result["storyteller"] = "[SSgamemode.storyteller?.type || SSgamemode.voted_storyteller]"
	result["emergency_shuttle"] = !!SSshuttle.emergency
	result["arrivals_shuttle"] = !!SSshuttle.arrivals
	result["latejoin_spawns"] = length(SSjob.latejoin_trackers)
	result["respawn_turf"] = !!respawn_turf
	return result
