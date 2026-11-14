// Tutorial NPCs (spec 7.2): an NPC spawner (a hidden tutorial object) creates a human with a
// name, an outfit and a species, standing still (no AI, no client), and applies its effects —
// damage, wounds, a disease, reagents in the blood, unconsciousness, bleeding — each with its own
// chance. The spawner is what is saved; its NPC is not (babylon_tutorial_npc), and it is created
// again when the world comes up, when a run starts (spawn at start) or by a Spawn NPC action.

#define BABYLON_TUTORIAL_NPC_TRAIT "babylon_tutorial_npc"

/mob/living
	/// Created by a tutorial NPC spawner: never saved, removed and re-created by its spawner.
	var/babylon_tutorial_npc = FALSE

/// Atoms a checkpoint must not save: tutorial NPCs and everything they carry. The station
/// build's checkpoint (D1) skips mobs for which this is TRUE.
/proc/babylon_tutorial_skip_save(atom/thing)
	for(var/atom/holder = thing; holder && !isturf(holder); holder = holder.loc)
		if(isliving(holder))
			var/mob/living/body = holder
			if(body.babylon_tutorial_npc)
				return TRUE
	return FALSE

/// Awake: alive, not in crit, not unconscious or asleep.
/proc/babylon_tutorial_awake(mob/living/body)
	return body.stat != DEAD && body.stat < HARD_CRIT && !body.IsUnconscious() && !body.IsSleeping()

/obj/babylon_tutorial/npc_spawner
	tutorial_kind = "npc_spawner"
	tutorial_category = "npc"
	kind_name = "NPC spawner"
	kind_desc = "Creates a standing NPC: a guide, a patient with injuries or an illness, a bystander."
	ui_icon = "user-nurse"
	view_icon = 'icons/effects/mapping_helpers.dmi'
	view_state = "corpsehuman"
	/// The NPC this spawner created.
	var/datum/weakref/npc_ref

/obj/babylon_tutorial/npc_spawner/settings_schema()
	return list(
		babylon_tutorial_field("npc_name", "Name", "text", "Guide", "The NPC's name."),
		babylon_tutorial_field("outfit", "Outfit", "typepath", "[/datum/outfit/job/assistant]", "A job outfit (ids and gear are left out).", options = babylon_tutorial_outfit_options(), base = /datum/outfit/job, placeholder = "Search outfits, e.g. doctor"),
		babylon_tutorial_field("species", "Species", "choice", "[/datum/species/human]", null, options = babylon_tutorial_species_options()),
		babylon_tutorial_field("facing", "Facing", "choice", "[SOUTH]", null, options = babylon_tutorial_options(list("[SOUTH]" = "South (down)", "[NORTH]" = "North (up)", "[EAST]" = "East (right)", "[WEST]" = "West (left)"))),
		babylon_tutorial_field("spawn_at_start", "Spawn at the start", "bool", 1, "On: the NPC is there from the start. Off: it appears when a Spawn NPC action runs."),
		babylon_tutorial_field("effects", "Effects", "effects", list(), "What is wrong with the NPC. Each effect happens with its chance (100% = always) every time the NPC is created."),
	)

/obj/babylon_tutorial/npc_spawner/Destroy()
	remove_npc()
	return ..()

/obj/babylon_tutorial/npc_spawner/target_atom()
	return current_npc() || get_turf(src)

/obj/babylon_tutorial/npc_spawner/summary()
	var/list/effects = setting("effects")
	return "[setting("npc_name")][length(effects) ? ", [length(effects)] effect\s" : ""][current_npc() ? "" : " (not spawned)"]"

/obj/babylon_tutorial/npc_spawner/proc/current_npc()
	RETURN_TYPE(/mob/living/carbon/human)
	var/mob/living/carbon/human/npc = npc_ref?.resolve()
	return QDELETED(npc) ? null : npc

/obj/babylon_tutorial/npc_spawner/proc/remove_npc()
	var/mob/living/carbon/human/npc = current_npc()
	npc_ref = null
	if(npc)
		qdel(npc)

/// Creates the NPC (replacing the old one) and applies its effects. Returns the NPC.
/obj/babylon_tutorial/npc_spawner/proc/spawn_npc()
	remove_npc()
	var/turf/tile = get_turf(src)
	if(!tile)
		return null
	var/mob/living/carbon/human/npc = new(tile)
	npc.babylon_tutorial_npc = TRUE
	var/species = text2path(setting("species"))
	if(ispath(species, /datum/species) && species != /datum/species/human)
		npc.set_species(species)
	var/name = setting("npc_name") || "Guide"
	npc.real_name = name
	npc.name = name
	var/outfit = text2path(setting("outfit"))
	if(ispath(outfit, /datum/outfit/job) && babylon_tutorial_type_allowed(outfit, null))
		npc.equipOutfit(outfit, TRUE)
	npc.setDir(text2num(setting("facing")) || SOUTH)
	// Tutorial NPCs never starve or die of thirst while they wait for the player.
	ADD_TRAIT(npc, TRAIT_NOHUNGER, BABYLON_TUTORIAL_NPC_TRAIT)
	ADD_TRAIT(npc, TRAIT_NOTHIRST, BABYLON_TUTORIAL_NPC_TRAIT)
	npc_ref = WEAKREF(npc)
	babylon_tutorial_apply_effects(npc, setting("effects"))
	babylon_tutorial_changed()
	return npc

// ---------------------------------------------------------------------------------------------
// Effects

/// Effect kind => label, for the configure window.
/proc/babylon_tutorial_effect_kinds()
	return list(
		"brute" = "Brute damage",
		"burn" = "Burn damage",
		"tox" = "Toxin damage",
		"oxy" = "Suffocation damage",
		"wound" = "Wound",
		"disease" = "Disease",
		"reagent" = "Reagent in blood",
		"unconscious" = "Unconscious",
		"bleed" = "Bleeding",
	)

/// Wound path => label: the wounds a tutorial NPC can have.
/proc/babylon_tutorial_wounds()
	return list(
		"[/datum/wound/blunt/bone/moderate]" = "Dislocated joint (moderate)",
		"[/datum/wound/blunt/bone/severe]" = "Hairline fracture (severe)",
		"[/datum/wound/blunt/bone/critical]" = "Compound fracture (critical)",
		"[/datum/wound/slash/flesh/moderate]" = "Rough abrasion (moderate)",
		"[/datum/wound/slash/flesh/severe]" = "Open laceration (severe)",
		"[/datum/wound/slash/flesh/critical]" = "Weeping avulsion (critical)",
		"[/datum/wound/pierce/bleed/moderate]" = "Minor skin breakage (moderate)",
		"[/datum/wound/pierce/bleed/severe]" = "Open puncture (severe)",
		"[/datum/wound/pierce/bleed/critical]" = "Ruptured cavity (critical)",
		"[/datum/wound/burn/flesh/moderate]" = "Second degree burns (moderate)",
		"[/datum/wound/burn/flesh/severe]" = "Third degree burns (severe)",
		"[/datum/wound/burn/flesh/critical]" = "Catastrophic burns (critical)",
	)

/// Disease path => label: illnesses a tutorial NPC can have (not contagious to the world's
/// machinery; ordinary curable diseases).
/proc/babylon_tutorial_diseases()
	return list(
		"[/datum/disease/cold]" = "The Cold (spaceacillin)",
		"[/datum/disease/flu]" = "The Flu (spaceacillin)",
		"[/datum/disease/tuberculosis]" = "Fungal Tuberculosis (spaceacillin + convermol)",
		"[/datum/disease/asthma_attack]" = "Asthma attack (albuterol)",
		"[/datum/disease/adrenal_crisis]" = "Adrenal Crisis",
		"[/datum/disease/anxiety]" = "Severe Anxiety",
	)

/proc/babylon_tutorial_body_zones()
	return list(
		BODY_ZONE_CHEST = "Chest",
		BODY_ZONE_HEAD = "Head",
		BODY_ZONE_L_ARM = "Left arm",
		BODY_ZONE_R_ARM = "Right arm",
		BODY_ZONE_L_LEG = "Left leg",
		BODY_ZONE_R_LEG = "Right leg",
	)

/proc/babylon_tutorial_species_options()
	return babylon_tutorial_options(list(
		"[/datum/species/human]" = "Human",
		"[/datum/species/lizard]" = "Lizardperson",
		"[/datum/species/moth]" = "Mothperson",
		"[/datum/species/human/felinid]" = "Felinid",
		"[/datum/species/ethereal]" = "Ethereal",
		"[/datum/species/skrell]" = "Skrell",
		"[/datum/species/vulpkanin]" = "Vulpkanin",
		"[/datum/species/tajaran]" = "Tajaran",
	))

/// The outfits offered first (any job outfit can also be searched).
/proc/babylon_tutorial_outfit_options()
	return babylon_tutorial_options(list(
		"[/datum/outfit/job/assistant]" = "Assistant",
		"[/datum/outfit/job/doctor]" = "Medical Doctor",
		"[/datum/outfit/job/paramedic]" = "Paramedic",
		"[/datum/outfit/job/chemist]" = "Chemist",
		"[/datum/outfit/job/engineer]" = "Station Engineer",
		"[/datum/outfit/job/atmos]" = "Atmospheric Technician",
		"[/datum/outfit/job/scientist]" = "Scientist",
		"[/datum/outfit/job/cargo_tech]" = "Cargo Technician",
		"[/datum/outfit/job/miner]" = "Shaft Miner",
		"[/datum/outfit/job/botanist]" = "Botanist",
		"[/datum/outfit/job/cook]" = "Cook",
		"[/datum/outfit/job/bartender]" = "Bartender",
		"[/datum/outfit/job/janitor]" = "Janitor",
		"[/datum/outfit/job/security]" = "Security Officer",
		"[/datum/outfit/job/curator]" = "Curator",
		"[/datum/outfit/job/hop]" = "Head of Personnel",
	))

/// Validates an effects list: list(list(kind, amount, zone, type, chance), ...).
/proc/babylon_tutorial_clean_effects(value)
	if(!islist(value))
		return list("error" = "Effects must be a list.")
	var/list/raw = value
	if(length(raw) > BABYLON_TUTORIAL_EFFECTS_MAX)
		return list("error" = "At most [BABYLON_TUTORIAL_EFFECTS_MAX] effects.")
	var/list/kinds = babylon_tutorial_effect_kinds()
	var/list/zones = babylon_tutorial_body_zones()
	var/list/cleaned = list()
	for(var/list/entry in raw)
		var/kind = "[entry["kind"]]"
		if(!kinds[kind])
			return list("error" = "Unknown effect.")
		var/list/effect = list("kind" = kind)
		var/chance = text2num("[entry["chance"]]")
		effect["chance"] = clamp(round(isnull(chance) ? 100 : chance), 0, 100)
		var/amount = text2num("[entry["amount"]]")
		switch(kind)
			if("brute", "burn", "tox", "oxy")
				effect["amount"] = clamp(round(isnull(amount) ? 20 : amount), 1, 200)
			if("unconscious")
				effect["amount"] = clamp(round(isnull(amount) ? 300 : amount), 1, 3600)
			if("bleed")
				effect["amount"] = clamp(round(isnull(amount) ? 50 : amount), 0, 300)
			if("reagent")
				effect["amount"] = clamp(round(isnull(amount) ? 10 : amount, 0.1), 0.1, 100)
		if(kind in list("brute", "burn", "wound", "bleed"))
			var/zone = "[entry["zone"]]"
			effect["zone"] = zones[zone] ? zone : BODY_ZONE_CHEST
		switch(kind)
			if("wound")
				var/wound = "[entry["type"]]"
				if(!babylon_tutorial_wounds()[wound])
					return list("error" = "Choose a wound.")
				effect["type"] = wound
			if("disease")
				var/disease = "[entry["type"]]"
				if(!babylon_tutorial_diseases()[disease])
					return list("error" = "Choose a disease.")
				effect["type"] = disease
			if("reagent")
				var/reagent = text2path("[entry["type"]]")
				if(!ispath(reagent, /datum/reagent) || !babylon_tutorial_type_allowed(reagent, null))
					return list("error" = "Choose a reagent.")
				effect["type"] = "[reagent]"
		cleaned += list(effect)
	return list("value" = cleaned)

/// Applies effects to an NPC, each with its chance. Returns the kinds that were applied.
/proc/babylon_tutorial_apply_effects(mob/living/carbon/human/npc, list/effects)
	var/list/applied = list()
	for(var/list/effect in effects)
		if(!prob(effect["chance"]))
			continue
		var/amount = effect["amount"]
		var/obj/item/bodypart/limb = npc.get_bodypart(effect["zone"]) || npc.get_bodypart(BODY_ZONE_CHEST)
		switch(effect["kind"])
			if("brute")
				npc.apply_damage(amount, BRUTE, limb, forced = TRUE, wound_bonus = CANT_WOUND)
			if("burn")
				npc.apply_damage(amount, BURN, limb, forced = TRUE, wound_bonus = CANT_WOUND)
			if("tox")
				npc.adjust_tox_loss(amount, forced = TRUE)
			if("oxy")
				npc.adjust_oxy_loss(amount, forced = TRUE)
			if("wound")
				var/wound_path = text2path(effect["type"])
				if(limb && ispath(wound_path, /datum/wound))
					var/datum/wound/wound = new wound_path()
					wound.apply_wound(limb, silent = TRUE, wound_source = "tutorial")
			if("disease")
				var/disease_path = text2path(effect["type"])
				if(ispath(disease_path, /datum/disease))
					npc.ForceContractDisease(new disease_path(), FALSE, TRUE)
			if("reagent")
				var/reagent_path = text2path(effect["type"])
				if(ispath(reagent_path, /datum/reagent))
					npc.reagents.add_reagent(reagent_path, amount)
			if("unconscious")
				npc.Unconscious(amount SECONDS, ignore_canstun = TRUE)
			if("bleed")
				if(limb)
					var/datum/wound/slash/flesh/moderate/cut = new()
					cut.apply_wound(limb, silent = TRUE, wound_source = "tutorial")
				if(amount)
					npc.adjust_blood_volume(-amount)
		applied += effect["kind"]
	return applied

// ---------------------------------------------------------------------------------------------
// Presets (the wand's NPC mode)

/// Preset id => list(name, desc, icon, settings): ready-made NPC spawners.
/proc/babylon_tutorial_npc_presets()
	return list(
		"guide" = list("name" = "Guide", "desc" = "A friendly guide who can talk and point. No injuries.", "icon" = "person-chalkboard", "settings" = list(
			"npc_name" = "Guide", "outfit" = "[/datum/outfit/job/curator]", "effects" = list())),
		"bystander" = list("name" = "Bystander", "desc" = "An ordinary crew member standing around.", "icon" = "person", "settings" = list(
			"npc_name" = "Crew member", "outfit" = "[/datum/outfit/job/assistant]", "effects" = list())),
		"bruised" = list("name" = "Bruised patient", "desc" = "40 brute damage on the chest: treat with sutures or bruise packs.", "icon" = "user-injured", "settings" = list(
			"npc_name" = "Patient", "effects" = list(list("kind" = "brute", "amount" = 40, "zone" = BODY_ZONE_CHEST, "chance" = 100)))),
		"burned" = list("name" = "Burned patient", "desc" = "35 burn damage on the left arm: treat with ointment or mesh.", "icon" = "fire", "settings" = list(
			"npc_name" = "Patient", "effects" = list(list("kind" = "burn", "amount" = 35, "zone" = BODY_ZONE_L_ARM, "chance" = 100)))),
		"poisoned" = list("name" = "Poisoned patient", "desc" = "30 toxin damage: treat with a toxin medicine.", "icon" = "skull-crossbones", "settings" = list(
			"npc_name" = "Patient", "effects" = list(list("kind" = "tox", "amount" = 30, "chance" = 100)))),
		"fracture" = list("name" = "Broken leg", "desc" = "A hairline fracture on the right leg: needs a splint or bone gel.", "icon" = "bone", "settings" = list(
			"npc_name" = "Patient", "effects" = list(list("kind" = "wound", "type" = "[/datum/wound/blunt/bone/severe]", "zone" = BODY_ZONE_R_LEG, "chance" = 100)))),
		"bleeding" = list("name" = "Bleeding patient", "desc" = "A cut on the left arm that bleeds and some blood lost: gauze and blood.", "icon" = "droplet", "settings" = list(
			"npc_name" = "Patient", "effects" = list(list("kind" = "bleed", "amount" = 80, "zone" = BODY_ZONE_L_ARM, "chance" = 100)))),
		"sick" = list("name" = "Sick patient", "desc" = "Has the cold: cure it with spaceacillin.", "icon" = "virus", "settings" = list(
			"npc_name" = "Patient", "effects" = list(list("kind" = "disease", "type" = "[/datum/disease/cold]", "chance" = 100)))),
		"unconscious" = list("name" = "Unconscious patient", "desc" = "Out cold for 10 minutes, with some suffocation damage.", "icon" = "bed", "settings" = list(
			"npc_name" = "Patient", "effects" = list(list("kind" = "unconscious", "amount" = 600, "chance" = 100), list("kind" = "oxy", "amount" = 30, "chance" = 100)))),
	)

/// Places an NPC spawner from a preset on a tile and creates its NPC. Returns the spawner.
/proc/babylon_tutorial_place_npc(turf/tile, preset_id)
	var/list/preset = babylon_tutorial_npc_presets()[preset_id]
	if(!tile || !preset)
		return null
	var/obj/babylon_tutorial/npc_spawner/spawner = new(tile)
	var/list/settings = preset["settings"]
	var/list/values = list()
	for(var/key in settings)
		var/list/field = babylon_tutorial_schema_field(spawner.type, key)
		var/list/cleaned = babylon_tutorial_clean_value(field, settings[key])
		if(!cleaned["error"])
			values[key] = cleaned["value"]
	spawner.store_settings(values)
	spawner.tutorial_id = babylon_tutorial_unique_id(preset_id == "guide" ? "guide" : "npc")
	spawner.spawn_npc()
	return spawner

#undef BABYLON_TUTORIAL_NPC_TRAIT
