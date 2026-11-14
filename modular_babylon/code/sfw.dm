// Babylon is a safe-for-work build. SPLURT inherits explicit (ERP) content from
// Skyrat/Bubberstation; this file switches it off for Babylon only. Ordinary
// SPLURT builds never include it, so their behavior is unchanged.
//
// The upstream config flags already hide ERP preferences, genitals, arousal,
// climax, ERP quirks, lewd NIFsofts, lewd item spawns and flagged ERP chemistry.
// They are forced on here, because a flag alone does not cover the interaction
// menu (it offers lewd interactions against clientless non-human mobs regardless
// of preferences), lewd emotes, the Plug13 toy bridge, lewd research designs,
// unflagged ERP drink/chemistry recipes or "plappable" plushie text.

/// Research design IDs that print ERP items, boards or lewd NIFsofts.
/proc/babylon_erp_design_ids()
	return list("sex_research", "hypnoticmodule", "borg_upgrade_bellyriding_harness", "nifsoft_hypno_brainwash", "nifsoft_rapid_disrobe", "nifsoft_gfluid")

/**
 * TRUE for ERP item, structure and machine types: the lewd item roots (sex toys, the types
 * modular_skyrat/.../_erp_disabled_item_enforcement.dm deletes when lewd items are off) and any
 * type path naming lewd content. Spawning and type listings (the Creative panel) skip them.
 */
/proc/babylon_type_is_erp(path)
	if(!ispath(path))
		return FALSE
	var/static/list/erp_roots = list(
		/obj/item/clothing/sextoy, /obj/item/storage/box/milking_kit, /obj/item/storage/box/xstand_kit,
		/obj/item/storage/box/bdsmbed_kit, /obj/item/storage/box/strippole_kit, /obj/item/storage/box/shibari_stand,
		/obj/item/paper/shibari_kit_instructions, /obj/item/clothing/mask/ballgag, /obj/item/reagent_containers/cup/lewd_filter,
		/obj/item/clothing/mask/gas/bdsm_mask, /obj/item/clothing/suit/corset, /obj/item/clothing/head/domina_cap,
		/obj/item/storage/belt/erpbelt, /obj/item/clothing/glasses/hypno, /obj/item/clothing/shoes/latex_heels/domina_heels,
		/obj/item/clothing/gloves/ball_mittens, /obj/item/clothing/suit/straight_jacket/kinky_sleepbag,
		/obj/item/clothing/ears/kinky_headphones, /obj/item/clothing/glasses/blindfold/kinky, /obj/item/clothing/neck/kink_collar,
		/obj/item/lustwish_discount, /obj/item/tickle_feather, /obj/item/clothing/mask/leatherwhip, /obj/item/kinky_shocker,
		/obj/item/condom_pack, /obj/item/clothing/under/stripper_outfit, /obj/structure/stripper_pole, /obj/item/polepack,
		/obj/item/bdsm_bed_kit, /obj/structure/chair/x_stand, /obj/item/x_stand_kit, /obj/structure/chair/milking_machine,
		/obj/item/milking_machine/constructionkit, /obj/item/bdsm_candle, /obj/item/spanking_pad, /obj/item/restraints/handcuffs/lewd,
		/obj/item/strapon_dildo, /obj/item/key/kink_collar, /obj/item/mind_controller, /obj/item/clothing/neck/mind_collar,
		/obj/item/restraints/handcuffs/milker, /obj/item/vending_refill/lustwish, /obj/machinery/vending/dorms,
		/obj/structure/bed/bdsm_bed, /obj/item/clothing/strapon, /obj/item/clothing/erp_leash, /obj/item/clicker, /obj/item/breastpump,
	)
	for(var/root in erp_roots)
		if(ispath(path, root))
			return TRUE
	var/static/regex/erp_words = regex(@"lewd|sextoy|dildo|strapon|kink|bdsm|lustwish|fleshlight|vibrator|condom|genital|aphro|(^|[/_])erp")
	return erp_words.Find(lowertext("[path]")) != 0

// Config: the server operator cannot turn ERP back on (config.txt or VV).

/datum/config_entry/flag/disable_erp_preferences
	default = TRUE
	protection = CONFIG_ENTRY_LOCKED

/datum/config_entry/flag/disable_erp_preferences/ValidateAndSet(str_val)
	. = ..()
	config_entry_value = TRUE

/datum/config_entry/flag/disable_lewd_items
	default = TRUE
	protection = CONFIG_ENTRY_LOCKED

/datum/config_entry/flag/disable_lewd_items/ValidateAndSet(str_val)
	. = ..()
	config_entry_value = TRUE

// Interaction menu (ctrl+shift click, "Interact With" verb).

/// TRUE for interactions that Babylon must never list or perform.
/proc/babylon_interaction_is_erp(datum/interaction/interaction)
	if(interaction.lewd || istype(interaction, /datum/interaction/lewd))
		return TRUE
	return LOWER_TEXT("[interaction.category]") in list(INTERACTION_CAT_LEWD, INTERACTION_CAT_EXTREME, INTERACTION_CAT_HARMFUL, INTERACTION_CAT_UNHOLY)

/datum/component/interactable/build_interactions_list()
	..()
	for(var/datum/interaction/interaction as anything in interactions.Copy())
		if(babylon_interaction_is_erp(interaction))
			interactions -= interaction

/datum/component/interactable/can_interact(datum/interaction/interaction, mob/living/target)
	if(babylon_interaction_is_erp(interaction))
		return FALSE
	return ..()

/datum/interaction/act(mob/living/user, mob/living/target, obj/body_relay = null)
	if(babylon_interaction_is_erp(src))
		return FALSE
	return ..()

// The SPLURT "MobInteraction" window also carries genital, arousal, ERP
// preference and lewd item tabs. Babylon opens a plain interaction list instead
// and sends only the data that list needs.
/datum/component/interactable/ui_interact(mob/user, datum/tgui/ui)
	ui = SStgui.try_update_ui(user, src, ui)
	if(!ui)
		ui = new(user, src, "BabylonInteraction")
		ui.open()

/datum/component/interactable/ui_static_data(mob/user)
	return list()

/datum/component/interactable/ui_data(mob/user)
	var/list/data = list()
	var/list/categories = list()
	var/list/descriptions = list()
	var/list/colors = list()
	for(var/datum/interaction/interaction as anything in interactions)
		if(!can_interact(interaction, user))
			continue
		LAZYADDASSOCLIST(categories, interaction.category, interaction.name)
		descriptions[interaction.name] = interaction.description
		colors[interaction.name] = interaction.color
	for(var/category in categories)
		categories[category] = sort_list(categories[category])
	var/datum/component/interactable/user_component = user.GetComponent(/datum/component/interactable)
	data["categories"] = sort_list(assoc_to_keys(categories))
	data["interactions"] = categories
	data["descriptions"] = descriptions
	data["colors"] = colors
	data["ref_user"] = REF(user)
	data["ref_self"] = REF(self)
	data["self"] = (body_relay && !can_see(user, self)) ? body_relay.name : self.name
	data["block_interact"] = user_component?.interact_next >= world.time
	return data

// Only plain interactions remain; favorites, auto interactions, genital toggles,
// ERP preference writes and lewd item slots are refused even if sent by hand.
/datum/component/interactable/ui_act(action, list/params)
	if(action != "interact")
		return FALSE
	return ..()

// Emotes, verbs and quirks.

/datum/emote/living/lewd/can_run_emote(mob/user, status_check = TRUE, intentional = FALSE, params)
	return FALSE

/datum/quirk/aphrodisiacal_bite
	erp_quirk = TRUE

// Plug13 bridges game events to a player's networked sex toy.
/client/New(TopicData)
	. = ..()
	if(src)
		remove_verb(src, /client/verb/plug13_menu)

/client/__gvb_plug13_menu(list/structured_args)
	return

// Plushies: no sex toy slot and no matching examine text.
/obj/item/toy/plush/Initialize(mapload)
	plappable = FALSE
	return ..()

// Research: lewd designs are never unlockable.

/// Designs no world offers: ERP ones, and in Babylon pAI / AI core ones (silicons.dm, which
/// the station build does not include).
/proc/babylon_removed_design(datum/design/design)
	if(!istype(design))
		return FALSE
	if(design.id in babylon_erp_design_ids())
		return TRUE
#ifndef BABYLON_STATION
	if(babylon_unplayable_design(design))
		return TRUE
#endif
	return FALSE

// Pruned from every node right before SSresearch links nodes and designs. Not in
// /datum/techweb_node/Initialize(): initialize_all_techweb_nodes() calls it on the previous,
// still empty node list, so at startup it never runs. Modular nodes also add IDs in New().
/datum/controller/subsystem/research/calculate_techweb_nodes()
	for(var/node_id in techweb_nodes)
		var/datum/techweb_node/node = techweb_nodes[node_id]
		for(var/design_id in LAZYCOPY(node.design_ids))
			if(babylon_removed_design(techweb_design_by_id(design_id)))
				node.design_ids -= design_id
	return ..()

// Saved research (or anything else) cannot add a removed design either.
/datum/techweb/add_design(datum/design/design, custom = FALSE, list/add_to)
	if(babylon_removed_design(design))
		return FALSE
	return ..()

// Chemistry: the forced config removes reactions flagged erp_reaction. Remove
// unflagged ones that make or consume ERP reagents too (e.g. drinks whose
// recipe yields aphrodisiacs), since drink and chem dispensers are buildable.
/datum/controller/subsystem/processing/reagents/Initialize()
	. = ..()
	babylon_remove_erp_reactions()

/proc/babylon_erp_reagents()
	var/static/list/erp_reagents = typecacheof(list(
		/datum/reagent/drug/aphrodisiac,
		/datum/reagent/consumable/cum,
		/datum/reagent/consumable/femcum,
		/datum/reagent/lewd_mutation_toxin,
		/datum/reagent/mkultra,
		/datum/reagent/consumable/ethanol/panty_dropper,
		/datum/reagent/consumable/ethanol/cum_in_a_hot_tub,
	))
	return erp_reagents

/proc/babylon_reaction_is_erp(datum/chemical_reaction/reaction)
	if(reaction.erp_reaction)
		return TRUE
	var/list/erp_reagents = babylon_erp_reagents()
	for(var/reagent in reaction.results)
		if(is_type_in_typecache(reagent, erp_reagents))
			return TRUE
	for(var/reagent in reaction.required_reagents)
		if(is_type_in_typecache(reagent, erp_reagents))
			return TRUE
	return FALSE

/proc/babylon_remove_erp_reactions()
	for(var/reaction_path in GLOB.chemical_reactions_list.Copy())
		var/datum/chemical_reaction/reaction = GLOB.chemical_reactions_list[reaction_path]
		if(!babylon_reaction_is_erp(reaction))
			continue
		GLOB.chemical_reactions_list -= reaction_path
		for(var/reagent in GLOB.chemical_reactions_list_reactant_index)
			GLOB.chemical_reactions_list_reactant_index[reagent] -= reaction
		for(var/reagent in GLOB.chemical_reactions_list_product_index)
			GLOB.chemical_reactions_list_product_index[reagent] -= reaction
	// The reagent lookup UI lists every recipe; drop removed and ERP ones.
	for(var/list/entry as anything in GLOB.chemical_reactions_results_lookup_list.Copy())
		if(!GLOB.chemical_reactions_list[entry["id"]])
			GLOB.chemical_reactions_results_lookup_list -= list(entry)
