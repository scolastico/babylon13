// Tutorial NPCs (spec 7.2): an NPC spawner (a hidden tutorial object) creates a human with a
// name, an outfit and a species, standing still (no AI, no client), and applies its effects —
// damage, wounds, a disease, reagents in the blood, unconsciousness, bleeding — each with its own
// chance. The spawner is what is saved; its NPC is not (babylon_tutorial_npc), and it is created
// again when the world comes up, when a run starts (spawn at start) or by a Spawn NPC action.

#define BABYLON_TUTORIAL_NPC_TRAIT "babylon_tutorial_npc"

/mob/living
	/// Created by a tutorial NPC spawner: never saved, removed and re-created by its spawner.
	var/babylon_tutorial_npc = FALSE
	/// A tutorial NPC stuck in place ("Anchored", spec 12 #4): see babylon_tutorial_anchor_npc().
	var/babylon_tutorial_anchored = FALSE

/obj/item
	/// Part of a tutorial NPC's outfit: never saved, even when it was taken off the NPC.
	var/babylon_tutorial_npc_item = FALSE

/// Atoms a checkpoint must not save: tutorial NPCs, everything they carry and their outfit's
/// items wherever they are. The checkpoint asks every atom through babylon_skip_save()
/// (persistence.dm), which is wired to this below.
/proc/babylon_tutorial_skip_save(atom/thing)
	if(isitem(thing))
		var/obj/item/item = thing
		if(item.babylon_tutorial_npc_item)
			return TRUE
	for(var/atom/holder = thing; holder && !isturf(holder); holder = holder.loc)
		if(isliving(holder))
			var/mob/living/body = holder
			if(body.babylon_tutorial_npc)
				return TRUE
	return FALSE

/atom/babylon_skip_save()
	return ..() || babylon_tutorial_skip_save(src)

/// Awake: alive, not in crit, not unconscious or asleep.
/proc/babylon_tutorial_awake(mob/living/body)
	return body.stat != DEAD && body.stat < HARD_CRIT && !body.IsUnconscious() && !body.IsSleeping()

/obj/babylon_tutorial/npc_spawner
	tutorial_kind = "npc_spawner"
	tutorial_category = "npc"
	kind_name = "NPC spawner"
	kind_desc = "Creates a standing NPC: a guide, a patient with injuries or an illness, a bystander."
	kind_example = "e.g. a patient with a broken leg in front of the medbay bed."
	id_help = "Actions and triggers refer to this NPC by its id (point at it, use an item on it, check its health)."
	ui_icon = "user-nurse"
	view_icon = 'icons/effects/mapping_helpers.dmi'
	view_state = "corpsehuman"
	/// The NPC this spawner created.
	var/datum/weakref/npc_ref
	/// Weakrefs to the items its outfit put on the NPC (removed with the NPC).
	var/list/outfit_items = list()
	/// settings_json when the NPC was created: the window says when a respawn would change it.
	var/spawned_settings

/obj/babylon_tutorial/npc_spawner/settings_schema()
	return list(
		babylon_tutorial_field("npc_name", "Name", "text", "Guide", "The NPC's name.", is_name = TRUE),
		babylon_tutorial_field("outfit", "Outfit", "typepath", "[/datum/outfit/job/assistant]", "A job outfit (ids and gear are left out).", options = babylon_tutorial_outfit_options(), base = /datum/outfit/job, placeholder = "Search outfits, e.g. doctor"),
		babylon_tutorial_field("species", "Species", "choice", "[/datum/species/human]", null, options = babylon_tutorial_species_options()),
		babylon_tutorial_field("facing", "Facing", "choice", "[SOUTH]", null, options = babylon_tutorial_options(list("[SOUTH]" = "South (down)", "[NORTH]" = "North (up)", "[EAST]" = "East (right)", "[WEST]" = "West (left)"))),
		babylon_tutorial_field("spawn_at_start", "Spawn at the start", "bool", 1, "On: the NPC is there from the start. Off: it appears when a Spawn NPC action runs."),
		babylon_tutorial_field("invulnerable", "Unhurtable until made vulnerable", "bool", 0, "On: nothing can hurt the NPC until a \"Make NPC vulnerable\" action runs (its effects still apply when it is created)."),
		babylon_tutorial_field("spawn_dead", "Spawn dead", "bool", 0, "On: the NPC is a corpse from the moment it appears (after its effects). It stays dead until a Heal / revive action revives it; an NPC State \"Dead\" check holds. Tutorial NPCs never rot."),
		babylon_tutorial_field("anchored", "Anchored (stuck in place)", "bool", 0, "On: players can't pull, push, buckle, carry or swap places with the NPC and can't walk over it, even when it lies down or is dead. It only moves when a Move NPC action walks it somewhere."),
		babylon_tutorial_field("effects", "Effects", "effects", list(), "What is wrong with the NPC. Each effect happens with its chance (100% = always) every time the NPC is created."),
	)

/obj/babylon_tutorial/npc_spawner/Destroy()
	remove_npc()
	return ..()

/obj/babylon_tutorial/npc_spawner/target_atom()
	return current_npc() || get_turf(src)

/obj/babylon_tutorial/npc_spawner/proc/base_summary()
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
	// Outfit items someone took off the NPC go with it, unless a player is carrying them.
	for(var/datum/weakref/item_ref as anything in outfit_items)
		var/obj/item/item = item_ref.resolve()
		if(!item)
			continue
		var/mob/living/holder = get(item, /mob/living)
		if(holder && !holder.babylon_tutorial_npc)
			continue
		qdel(item)
	outfit_items.Cut()

/// The NPC's settings changed since it was created (a respawn would apply them).
/obj/babylon_tutorial/npc_spawner/proc/npc_outdated()
	return current_npc() && spawned_settings != settings_json

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
	for(var/obj/item/item in npc.get_all_contents())
		item.babylon_tutorial_npc_item = TRUE
		outfit_items += WEAKREF(item)
	npc.setDir(text2num(setting("facing")) || SOUTH)
	// Tutorial NPCs never starve or die of thirst while they wait for the player.
	ADD_TRAIT(npc, TRAIT_NOHUNGER, BABYLON_TUTORIAL_NPC_TRAIT)
	ADD_TRAIT(npc, TRAIT_NOTHIRST, BABYLON_TUTORIAL_NPC_TRAIT)
	npc_ref = WEAKREF(npc)
	spawned_settings = settings_json
	babylon_tutorial_apply_effects(npc, setting("effects"))
	if(setting("anchored"))
		babylon_tutorial_anchor_npc(npc)
	if(setting("spawn_dead"))
		babylon_tutorial_kill_quietly(npc)
	if(setting("invulnerable"))
		ADD_TRAIT(npc, TRAIT_GODMODE, BABYLON_TUTORIAL_NPC_TRAIT)
	babylon_tutorial_changed()
	return npc

/obj/babylon_tutorial/npc_spawner/summary()
	. = base_summary()
	var/list/extras = list()
	if(setting("spawn_dead"))
		extras += "dead"
	if(setting("anchored"))
		extras += "anchored"
	if(length(extras))
		. += " \[[jointext(extras, ", ")]\]"

/// A corpse from the start: dead without a death gasp in chat (it was never seen alive); no rot
/// (attach_rot below).
/proc/babylon_tutorial_kill_quietly(mob/living/npc)
	var/old_message = npc.death_message
	var/old_sound = npc.death_sound
	var/old_flags = npc.living_flags
	npc.death_message = null
	npc.death_sound = null
	npc.living_flags &= ~ALWAYS_DEATHGASP
	npc.death(FALSE)
	npc.death_message = old_message
	npc.death_sound = old_sound
	npc.living_flags = old_flags

/// Sticks a tutorial NPC in place (spec 12 #4), with the game's own flags and traits:
/// - anchored and move_resist INFINITY: nobody can pull it (can_be_pulled) or push it (PushAM),
///   no throw, conveyor or air pressure moves it, nothing can put it in a closet or body bag;
/// - TRAIT_NOMOBSWAP: nobody swaps places with it;
/// - can_buckle_to FALSE: nobody buckles it to a chair or roller bed (a fireman carry needs a
///   pull first);
/// - babylon_tutorial_anchored: nobody walks over it while it lies or is dead
///   (/mob/living/CanAllowThrough below; a lying mob is otherwise passable).
/// Its own Move() still works: a Move NPC action walks it (npc.dm, /datum/babylon_tutorial_npc_move).
/proc/babylon_tutorial_anchor_npc(mob/living/npc)
	npc.babylon_tutorial_anchored = TRUE
	npc.set_anchored(TRUE)
	npc.move_resist = INFINITY
	npc.can_buckle_to = FALSE
	ADD_TRAIT(npc, TRAIT_NOMOBSWAP, BABYLON_TUTORIAL_NPC_TRAIT)

/mob/living/CanAllowThrough(atom/movable/mover, border_dir)
	. = ..()
	// An anchored tutorial NPC blocks other mobs also while it lies (a patient on the floor, a
	// corpse): projectiles and thrown things pass as usual.
	if(. && babylon_tutorial_anchored && ismob(mover) && !mover.throwing && body_position == LYING_DOWN)
		return FALSE

/// Tutorial NPCs wait for the players as long as it takes: a dead one never rots (no miasma).
/mob/living/carbon/attach_rot()
	if(babylon_tutorial_npc)
		return
	return ..()

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

/// Reagent path => label: what can be in a tutorial NPC's blood (medicine, common poisons and a
/// few drugs a medical tutorial needs). Nothing that transforms, spreads or harms the world.
/proc/babylon_tutorial_blood_reagents()
	return list(
		"[/datum/reagent/medicine/c2/libital]" = "Libital (brute medicine)",
		"[/datum/reagent/medicine/c2/aiuri]" = "Aiuri (burn medicine)",
		"[/datum/reagent/medicine/c2/multiver]" = "Multiver (toxin medicine)",
		"[/datum/reagent/medicine/c2/convermol]" = "Convermol (suffocation medicine)",
		"[/datum/reagent/medicine/c2/seiver]" = "Seiver (toxin medicine)",
		"[/datum/reagent/medicine/c2/probital]" = "Probital",
		"[/datum/reagent/medicine/epinephrine]" = "Epinephrine",
		"[/datum/reagent/medicine/morphine]" = "Morphine",
		"[/datum/reagent/medicine/salbutamol]" = "Salbutamol",
		"[/datum/reagent/medicine/albuterol]" = "Albuterol",
		"[/datum/reagent/medicine/spaceacillin]" = "Spaceacillin",
		"[/datum/reagent/medicine/salglu_solution]" = "Saline-glucose solution",
		"[/datum/reagent/medicine/coagulant]" = "Coagulant",
		"[/datum/reagent/medicine/atropine]" = "Atropine",
		"[/datum/reagent/medicine/mannitol]" = "Mannitol",
		"[/datum/reagent/medicine/potass_iodide]" = "Potassium iodide",
		"[/datum/reagent/toxin]" = "Toxin",
		"[/datum/reagent/toxin/lexorin]" = "Lexorin",
		"[/datum/reagent/toxin/cyanide]" = "Cyanide",
		"[/datum/reagent/toxin/histamine]" = "Histamine",
		"[/datum/reagent/toxin/formaldehyde]" = "Formaldehyde",
		"[/datum/reagent/toxin/venom]" = "Venom",
		"[/datum/reagent/toxin/chloralhydrate]" = "Chloral hydrate",
		"[/datum/reagent/toxin/plasma]" = "Plasma",
		"[/datum/reagent/consumable/ethanol]" = "Ethanol",
		"[/datum/reagent/drug/space_drugs]" = "Space drugs",
		"[/datum/reagent/drug/nicotine]" = "Nicotine",
		"[/datum/reagent/drug/methamphetamine]" = "Methamphetamine",
		"[/datum/reagent/water]" = "Water",
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
				var/reagent = "[entry["type"]]"
				if(!babylon_tutorial_blood_reagents()[reagent])
					return list("error" = "Choose a reagent from the list.")
				effect["type"] = reagent
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
					// The NPC's illness stays with the NPC: it never spreads to players.
					var/datum/disease/illness = new disease_path()
					illness.spread_flags = DISEASE_SPREAD_NON_CONTAGIOUS
					illness.spread_text = "Non-contagious"
					npc.ForceContractDisease(illness, FALSE, TRUE)
			if("reagent")
				var/reagent_path = text2path(effect["type"])
				if(ispath(reagent_path, /datum/reagent) && babylon_tutorial_blood_reagents()[effect["type"]])
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
// Make NPC vulnerable

/obj/babylon_tutorial/action/npc_vulnerable
	tutorial_kind = "npc_vulnerable"
	kind_name = "Make NPC vulnerable"
	kind_desc = "An NPC that was unhurtable can be hurt from now on (for everyone in this world)."
	kind_example = "e.g. the sparring partner can be hit once the lesson starts."
	ui_icon = "shield-halved"
	view_icon = 'icons/effects/mapping_helpers.dmi'
	view_state = "mobspawner"

/obj/babylon_tutorial/action/npc_vulnerable/own_schema()
	return list(
		babylon_tutorial_field("target", "NPC spawner", "id", "", "Its NPC loses the \"Unhurtable until made vulnerable\" protection.", filter = list("npc"), required = TRUE),
	)

/obj/babylon_tutorial/action/npc_vulnerable/perform(datum/babylon_tutorial_run/run)
	var/mob/living/npc = babylon_tutorial_resolve(setting("target"))
	if(isliving(npc) && npc.babylon_tutorial_npc)
		REMOVE_TRAIT(npc, TRAIT_GODMODE, BABYLON_TUTORIAL_NPC_TRAIT)

/obj/babylon_tutorial/action/npc_vulnerable/summary()
	return "[setting("target") || "?"]"

// ---------------------------------------------------------------------------------------------
// Move NPC (spec 12 #3)

/obj/babylon_tutorial/action/move_npc
	tutorial_kind = "move_npc"
	kind_name = "Move NPC"
	kind_desc = "An NPC walks to a marker (or crawls when it can't stand), finding its way around walls; actions can run when it arrives."
	kind_example = "e.g. the guide walks to the medbay door, then says \"Follow me\"."
	ui_icon = "person-walking"
	view_icon = 'icons/effects/mapping_helpers.dmi'
	view_state = "mobspawner"

/obj/babylon_tutorial/action/move_npc/own_schema()
	return list(
		babylon_tutorial_field("target", "NPC spawner", "id", "", "Its NPC walks. A new Move NPC action for the same NPC replaces the walk it is on.", filter = list("npc"), required = TRUE),
		babylon_tutorial_field("destination", "To marker", "id", "", "Where it goes: the marker's tile (or next to it, when something solid stands there). It opens only doors anyone may open, or those its ID card opens.", filter = list("marker"), required = TRUE),
		babylon_tutorial_field("timeout", "Give up after (seconds)", "number", 60, "When it has not arrived by then (blocked, no way through, knocked out), it stops where it is; the Test run tab and this action's checks say why.", min = 5, max = 600),
		babylon_tutorial_field("on_arrival", "On arrival", "idlist", list(), "Actions to run, in order, once the NPC has arrived (each after its own delay).", filter = list("action")),
	)

/obj/babylon_tutorial/action/move_npc/follow_up_ids()
	var/list/ids = setting("on_arrival")
	return islist(ids) ? ids.Copy() : list()

/obj/babylon_tutorial/action/move_npc/find_issues()
	. = ..()
	var/issue = npc_target_issue()
	if(issue)
		.["target"] = issue
	if(tutorial_id in babylon_tutorial_expand_actions(follow_up_ids()))
		.["on_arrival"] = "Its arrival runs this action again: the NPC walks again every time it arrives."

/obj/babylon_tutorial/action/move_npc/npc_target_issue()
	var/obj/babylon_tutorial/target = babylon_tutorial_find(setting("target"))
	if(istype(target, /obj/babylon_tutorial/npc_spawner) && isturf(target.target_atom()))
		return "[target.tutorial_id] has no NPC right now: spawn it first."
	return null

/obj/babylon_tutorial/action/move_npc/perform(datum/babylon_tutorial_run/run)
	var/mob/living/npc = babylon_tutorial_resolve(setting("target"))
	if(!isliving(npc) || !npc.babylon_tutorial_npc)
		run.note_action(src, "[setting("target") || "?"] has no NPC to move.")
		return
	var/turf/destination = babylon_tutorial_marker_turf(setting("destination"))
	if(!destination)
		run.note_action(src, "there is no marker [setting("destination") || "?"] to walk to.")
		return
	if(destination.z != npc.z)
		run.note_action(src, "[npc.real_name] can't walk to [setting("destination")]: it is on another level.")
		return
	var/datum/babylon_tutorial_npc_move/old = run.movers[npc]
	if(old)
		qdel(old)
	var/datum/babylon_tutorial_npc_move/walk = new(run, src, npc, destination)
	run.movers[npc] = walk
	walk.trigger_ref = run.current_trigger ? WEAKREF(run.current_trigger) : null
	walk.schedule(1)

/obj/babylon_tutorial/action/move_npc/summary()
	var/list/after = follow_up_ids()
	return "[setting("target") || "?"] to [setting("destination") || "?"][length(after) ? ", then [jointext(after, ", ")]" : ""]"

/// One NPC walking to a tile for a Move NPC action: a step every move delay along a JPS path
/// (get_path_to, the game's pathfinder, the same one AI mobs use), found again when the way is
/// blocked. Crawls when the NPC can't stand (a lying mob moves, only slower). Ends on arrival
/// (the action's On arrival actions run), or gives up at the deadline (a note for the builder).
/datum/babylon_tutorial_npc_move
	var/datum/babylon_tutorial_run/run
	var/datum/weakref/action_ref
	var/datum/weakref/npc_ref
	/// The trigger whose actions started the walk ("until the next step" of the follow-ups).
	var/datum/weakref/trigger_ref
	var/turf/destination
	var/started
	var/deadline
	/// The tiles still to walk (the next one first).
	var/list/path
	var/timer
	/// How many steps it walked; why it waits right now (for the give-up note).
	var/steps = 0
	var/waiting_for
	var/done = FALSE

/datum/babylon_tutorial_npc_move/New(datum/babylon_tutorial_run/run, obj/babylon_tutorial/action/move_npc/action, mob/living/npc, turf/destination)
	src.run = run
	action_ref = WEAKREF(action)
	npc_ref = WEAKREF(npc)
	src.destination = destination
	started = world.time
	deadline = world.time + (action.setting("timeout") || 60) SECONDS

/datum/babylon_tutorial_npc_move/Destroy()
	done = TRUE
	if(timer)
		deltimer(timer)
		timer = null
	var/mob/living/npc = npc_ref?.resolve()
	if(run && npc && run.movers[npc] == src)
		run.movers -= npc
	run = null
	destination = null
	path = null
	return ..()

/datum/babylon_tutorial_npc_move/proc/schedule(delay)
	if(done)
		return
	if(timer)
		deltimer(timer)
	timer = addtimer(CALLBACK(src, PROC_REF(walk_step)), max(1, delay), TIMER_STOPPABLE)

/// The NPC is there: on the tile, or next to it when something solid stands on it.
/datum/babylon_tutorial_npc_move/proc/arrived(mob/living/npc)
	var/turf/here = get_turf(npc)
	if(here == destination)
		return TRUE
	return get_dist(here, destination) <= 1 && destination.is_blocked_turf(TRUE, npc)

/// One step: arrive, give up, wait, or move to the next tile of the path. Tests call it directly.
/// It may sleep while the pathfinder works (get_path_to); a timer calls it.
/datum/babylon_tutorial_npc_move/proc/walk_step()
	if(timer)
		deltimer(timer)
	timer = null
	if(done || QDELETED(run))
		return
	var/mob/living/npc = npc_ref?.resolve()
	if(!npc || QDELETED(npc))
		// Respawned or removed: the walk ends with it, nothing to report.
		qdel(src)
		return
	if(arrived(npc))
		return finish(npc)
	if(npc.stat == DEAD)
		return give_up("[npc.real_name] is dead and can't walk.")
	if(world.time >= deadline)
		return give_up("[npc.real_name] gave up after [round((world.time - started) / 10)] seconds at [npc.x], [npc.y], [get_dist(npc, destination)] tiles from [destination.x], [destination.y][waiting_for ? " ([waiting_for])" : ""].")
	// Out cold, stunned, held, buckled: it waits (until the deadline).
	if(!babylon_tutorial_awake(npc) || HAS_TRAIT(npc, TRAIT_IMMOBILIZED) || npc.buckled || npc.pulledby || !isturf(npc.loc))
		waiting_for = "it could not move: out cold, held or stuck"
		return schedule(1 SECONDS)
	if(!length(path) || get_dist(npc, path[1]) > 1)
		path = get_path_to(npc, destination, 120, 0, babylon_tutorial_npc_access(npc), TRUE)
		if(done || QDELETED(npc))
			return
		if(!length(path))
			waiting_for = "no way through: walls, locked doors or someone in the way"
			return schedule(1 SECONDS)
	var/turf/next = path[1]
	if(npc.Move(next, get_dir(npc, next)) && get_turf(npc) == next)
		path.Cut(1, 2)
		steps++
		waiting_for = null
		if(arrived(npc))
			return finish(npc)
	else
		// Blocked (a closed door opening, someone in the way): find the way again next step.
		path = null
		waiting_for = "the way was blocked"
	schedule(babylon_tutorial_npc_step_delay(npc))

/datum/babylon_tutorial_npc_move/proc/finish(mob/living/npc)
	done = TRUE
	var/obj/babylon_tutorial/action/move_npc/action = action_ref?.resolve()
	var/datum/babylon_tutorial_run/current = run
	qdel(src)
	if(!action || QDELETED(current))
		return
	log_game("BABYLON TUTORIAL: [action.tutorial_id]: [npc.real_name] arrived at [AREACOORD(npc)].")
	var/list/ids = action.follow_up_ids()
	if(length(ids))
		current.run_actions(trigger_ref?.resolve(), ids, 0)

/datum/babylon_tutorial_npc_move/proc/give_up(text)
	done = TRUE
	var/obj/babylon_tutorial/action/move_npc/action = action_ref?.resolve()
	var/datum/babylon_tutorial_run/current = run
	qdel(src)
	if(action && !QDELETED(current))
		current.note_action(action, "Move NPC: [text]")

/// The access an NPC walks with: its ID card's (an NPC without one opens only public doors).
/proc/babylon_tutorial_npc_access(mob/living/npc)
	var/obj/item/card/id/card = npc.get_idcard(TRUE)
	return card ? card.GetAccess() : list()

/// Deciseconds between two steps: the NPC's own move speed (slower when it crawls or is hurt),
/// at least a brisk walk, at most two seconds.
/proc/babylon_tutorial_npc_step_delay(mob/living/npc)
	var/delay = npc.cached_multiplicative_slowdown
	if(npc.body_position == LYING_DOWN)
		delay = max(delay, 1 SECONDS)
	return clamp(round(delay), 2, 2 SECONDS)

// ---------------------------------------------------------------------------------------------
// Presets (the wand's NPC mode)

/// Preset id => list(name, desc, icon, settings): ready-made NPC spawners.
/proc/babylon_tutorial_npc_presets()
	return list(
		"guide" = list("name" = "Guide", "desc" = "A friendly guide who can talk and point. No injuries.", "id_prefix" = "guide", "icon" = "person-chalkboard", "settings" = list(
			"npc_name" = "Guide", "outfit" = "[/datum/outfit/job/curator]", "effects" = list())),
		"bystander" = list("name" = "Bystander", "desc" = "An ordinary crew member standing around.", "id_prefix" = "bystander", "icon" = "person", "settings" = list(
			"npc_name" = "Crew member", "outfit" = "[/datum/outfit/job/assistant]", "effects" = list())),
		"bruised" = list("name" = "Bruised patient", "desc" = "40 brute damage on the chest: treat with sutures or bruise packs.", "id_prefix" = "patient", "icon" = "user-injured", "settings" = list(
			"npc_name" = "Patient", "effects" = list(list("kind" = "brute", "amount" = 40, "zone" = BODY_ZONE_CHEST, "chance" = 100)))),
		"burned" = list("name" = "Burned patient", "desc" = "35 burn damage on the left arm: treat with ointment or mesh.", "id_prefix" = "patient", "icon" = "fire", "settings" = list(
			"npc_name" = "Patient", "effects" = list(list("kind" = "burn", "amount" = 35, "zone" = BODY_ZONE_L_ARM, "chance" = 100)))),
		"poisoned" = list("name" = "Poisoned patient", "desc" = "30 toxin damage: treat with a toxin medicine.", "id_prefix" = "patient", "icon" = "skull-crossbones", "settings" = list(
			"npc_name" = "Patient", "effects" = list(list("kind" = "tox", "amount" = 30, "chance" = 100)))),
		"fracture" = list("name" = "Broken leg", "desc" = "A hairline fracture on the right leg: needs a splint or bone gel.", "id_prefix" = "patient", "icon" = "bone", "settings" = list(
			"npc_name" = "Patient", "effects" = list(list("kind" = "wound", "type" = "[/datum/wound/blunt/bone/severe]", "zone" = BODY_ZONE_R_LEG, "chance" = 100)))),
		"bleeding" = list("name" = "Bleeding patient", "desc" = "A cut on the left arm that bleeds and some blood lost: gauze and blood.", "id_prefix" = "patient", "icon" = "droplet", "settings" = list(
			"npc_name" = "Patient", "effects" = list(list("kind" = "bleed", "amount" = 80, "zone" = BODY_ZONE_L_ARM, "chance" = 100)))),
		"sick" = list("name" = "Sick patient", "desc" = "Has the cold: cure it with spaceacillin.", "id_prefix" = "patient", "icon" = "virus", "settings" = list(
			"npc_name" = "Patient", "effects" = list(list("kind" = "disease", "type" = "[/datum/disease/cold]", "chance" = 100)))),
		"unconscious" = list("name" = "Unconscious patient", "desc" = "Out cold for 10 minutes, with some suffocation damage.", "id_prefix" = "patient", "icon" = "bed", "settings" = list(
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
	spawner.tutorial_id = babylon_tutorial_unique_id(preset["id_prefix"] || "npc")
	spawner.spawn_npc()
	return spawner

#undef BABYLON_TUTORIAL_NPC_TRAIT
