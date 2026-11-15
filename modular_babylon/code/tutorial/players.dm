// Who the players of the world's tutorial run are (spec 12 #18, #19, #21).
//
// The run follows players by key (their ckey; a mob without one, e.g. in tests, by its ref), not
// by mob: bodies[key] is a weakref to the living mob they play, and it stays on the body they leave
// when they die or ghost. So "Player state" still sees a dead player, and "Revive" finds their body
// again. When a body dies the run captures its looks and equipment; when that dead body is later
// destroyed (gibbed, dusted, deleted), a revive builds a new one from the snapshot. A body deleted
// while alive means the player left (back to the lobby): the run forgets them.
//
// Every living mob with a client that is not a tutorial NPC is a player; the run picks them up on
// every check (add_player() adds one at once, also without a client).

/// The key the run knows a mob's player by.
/proc/babylon_tutorial_player_key(mob/player)
	return player.ckey || "mob_[REF(player)]"

/// A mob that can take part in the run: living, not a tutorial NPC.
/proc/babylon_tutorial_can_play(mob/living/player)
	return isliving(player) && !QDELETED(player) && !player.babylon_tutorial_npc

/// Adds a player (or moves their key to this new living body).
/datum/babylon_tutorial_run/proc/add_player(mob/living/player)
	if(!babylon_tutorial_can_play(player))
		return
	var/key = babylon_tutorial_player_key(player)
	var/datum/weakref/known_ref = bodies[key]
	var/mob/living/known = known_ref?.resolve()
	if(known == player)
		return
	if(known)
		UnregisterSignal(known, list(COMSIG_LIVING_DEATH, COMSIG_MOB_SAY))
	bodies[key] = WEAKREF(player)
	RegisterSignal(player, COMSIG_QDELETING, PROC_REF(on_qdeleting), override = TRUE)
	RegisterSignal(player, COMSIG_LIVING_DEATH, PROC_REF(player_died), override = TRUE)
	RegisterSignal(player, COMSIG_MOB_SAY, PROC_REF(player_said), override = TRUE)

/// Picks up every living player in the world (previews keep their one builder).
/datum/babylon_tutorial_run/proc/refresh_players()
	if(preview)
		return
	for(var/mob/living/player in GLOB.player_list)
		if(babylon_tutorial_can_play(player))
			add_player(player)

/// The body a player key plays or left behind; null when it is gone.
/datum/babylon_tutorial_run/proc/body_of(key)
	RETURN_TYPE(/mob/living)
	var/datum/weakref/body_ref = bodies[key]
	var/mob/living/body = body_ref?.resolve()
	return QDELETED(body) ? null : body

/// Every living player: actions that target "the player" hit all of them.
/datum/babylon_tutorial_run/proc/players()
	var/list/found = list()
	for(var/key in bodies)
		var/mob/living/body = body_of(key)
		if(body && body.stat != DEAD)
			found += body
	return found

/// The mob each player is now (their body, or their ghost): who reads messages and sees images.
/datum/babylon_tutorial_run/proc/audience()
	var/list/found = list()
	for(var/key in bodies)
		var/mob/current = babylon_tutorial_mob_of_key(key) || body_of(key)
		if(current && !QDELETED(current))
			found |= current
	return found

/// The mob that holds a player key now (their client's mob, else a mob carrying the key).
/proc/babylon_tutorial_mob_of_key(key)
	var/client/player = GLOB.directory[key]
	if(player?.mob)
		return player.mob
	for(var/mob/dead/observer/ghost in GLOB.dead_mob_list)
		if(ghost.ckey == key)
			return ghost
	return null

/// Whether a mob (an item's user, a button's presser) counts as a player of this run.
/datum/babylon_tutorial_run/proc/is_player(mob/living/user)
	if(!babylon_tutorial_can_play(user))
		return FALSE
	if(preview)
		return user == preview_mob
	add_player(user)
	return TRUE

/datum/babylon_tutorial_run/proc/player_died(mob/living/source, gibbed)
	SIGNAL_HANDLER
	snapshot(source)

/// A tracked body is being deleted. A dead one (captured at its death) keeps its player in the run
/// and the snapshot remembers where it was last; a living one means the player left the world.
/datum/babylon_tutorial_run/proc/body_deleted(atom/source)
	for(var/key in bodies)
		var/datum/weakref/body_ref = bodies[key]
		// A weakref no longer resolves (and WEAKREF() gives null) while its atom is being
		// deleted: compare the atom's own weakref.
		if(!body_ref || body_ref != source.weak_reference)
			continue
		var/mob/living/body = source
		if(body.stat != DEAD)
			bodies -= key
			snapshots -= key
			return
		if(!snapshots[key])
			snapshot(body, key)
		var/list/shot = snapshots[key]
		var/turf/tile = get_turf(body)
		if(tile)
			shot["turf"] = list(tile.x, tile.y, tile.z)
		return

/// Captures a body's looks and equipment for a later revive in a new body.
/datum/babylon_tutorial_run/proc/snapshot(mob/living/body, key)
	key = key || babylon_tutorial_player_key(body)
	var/turf/tile = get_turf(body)
	var/list/shot = list("type" = body.type, "name" = body.real_name, "turf" = tile ? list(tile.x, tile.y, tile.z) : null)
	if(ishuman(body))
		var/mob/living/carbon/human/human = body
		shot["identity"] = babylon_tutorial_capture_identity(human)
		shot["outfit"] = babylon_tutorial_capture_outfit(human)
	snapshots[key] = shot

/// Revives one player: their body if it still exists, else a new body made from the snapshot;
/// then the player is put back into it. Returns the body (null when there was nothing to do).
/datum/babylon_tutorial_run/proc/revive_player(key)
	var/mob/living/body = body_of(key)
	var/mob/current = babylon_tutorial_mob_of_key(key)
	if(body)
		// Alive and played (or a client-less player): nothing to revive.
		if(body.stat != DEAD && (!current || current == body))
			return null
		if(body.stat == DEAD)
			body.revive(HEAL_ALL | HEAL_ADMIN)
	else
		// Nobody to put into a new body (the player left): nothing to rebuild.
		if(!current)
			return null
		body = rebuild_body(key)
		if(!body)
			return null
		add_player(body)
		// add_player keys the body by its own (empty) key: it belongs to this player.
		var/own_key = babylon_tutorial_player_key(body)
		if(own_key != key)
			bodies -= own_key
			bodies[key] = WEAKREF(body)
	babylon_tutorial_put_player_in(body, key, current)
	if(body.ckey && body.ckey != key)
		// The key changed hands (a new body took the player's ckey): follow it.
		bodies -= key
		bodies[body.ckey] = WEAKREF(body)
	log_game("BABYLON TUTORIAL: revived [key] in [body] at [AREACOORD(body)].")
	return body

/// A new body from a player's snapshot, at the old body's last tile (else the start marker).
/datum/babylon_tutorial_run/proc/rebuild_body(key)
	var/list/shot = snapshots[key]
	var/turf/spot
	var/list/coords = shot?["turf"]
	if(length(coords) == 3)
		spot = locate(coords[1], coords[2], coords[3])
	spot = spot || babylon_tutorial_marker_turf("start")
	if(!spot)
		return null
	var/path = shot?["type"]
	if(!ispath(path, /mob/living))
		path = /mob/living/carbon/human
	var/mob/living/body = new path(spot)
	if(ishuman(body) && shot)
		var/mob/living/carbon/human/human = body
		if(islist(shot["identity"]))
			babylon_tutorial_apply_identity(human, shot["identity"])
		var/datum/outfit/outfit = shot["outfit"]
		if(istype(outfit))
			human.equipOutfit(outfit)
	else if(shot?["name"])
		body.real_name = shot["name"]
		body.name = shot["name"]
	return body

/// Puts a player (by key) back into a body: their ghost's key (and mind) move into it. A player
/// who already plays another living body is left alone.
/proc/babylon_tutorial_put_player_in(mob/living/body, key, mob/current)
	if(body.ckey == key)
		return TRUE
	if(!current || current == body)
		return FALSE
	if(isliving(current) && current.stat != DEAD)
		return FALSE
	var/datum/mind/mind = current.mind
	if(mind && mind.current != body && !body.mind)
		mind.transfer_to(body)
	if(current.key)
		body.PossessByPlayer(current.key)
	body.client?.init_verbs()
	// The ghost the player left is empty now.
	if(isobserver(current) && !current.key)
		qdel(current)
	return body.ckey == key

// ---------------------------------------------------------------------------------------------
// Identity (the station build's characters keep theirs the same way: station_characters.dm)

/proc/babylon_tutorial_capture_identity(mob/living/carbon/human/body)
	var/datum/dna/dna = body.dna
	if(!dna)
		return list("real_name" = body.real_name)
	return list(
		"species" = dna.species ? "[dna.species.type]" : null,
		"unique_enzymes" = dna.unique_enzymes,
		"unique_identity" = dna.unique_identity,
		"unique_features" = dna.unique_features,
		"features" = islist(dna.features) ? dna.features.Copy() : list(),
		"mutant_bodyparts" = islist(dna.mutant_bodyparts) ? dna.mutant_bodyparts.Copy() : list(),
		"body_markings" = islist(dna.body_markings) ? dna.body_markings.Copy() : list(),
		"blood_type" = dna.blood_type?.id,
		"gender" = body.gender,
		"physique" = body.physique,
		"age" = body.age,
		"real_name" = body.real_name,
	)

/proc/babylon_tutorial_apply_identity(mob/living/carbon/human/body, list/saved)
	var/species_type = text2path(saved["species"])
	if(ispath(species_type, /datum/species))
		var/list/features = islist(saved["features"]) ? saved["features"] : body.dna.features.Copy()
		var/list/mutant_parts = islist(saved["mutant_bodyparts"]) ? saved["mutant_bodyparts"] : list()
		var/list/markings = islist(saved["body_markings"]) ? saved["body_markings"] : list()
		// set_species() keeps the DNA's features over the ones it is given: set them first.
		body.dna.features = features.Copy()
		body.dna.mutant_bodyparts = mutant_parts.Copy()
		body.dna.body_markings = markings.Copy()
		body.set_species(species_type, icon_update = FALSE, pref_load = FALSE, override_features = features.Copy(), override_mutantparts = mutant_parts.Copy(), override_markings = markings.Copy())
		for(var/field in list("unique_enzymes", "unique_identity", "unique_features"))
			if(istext(saved[field]))
				body.dna.vars[field] = saved[field]
	if(istext(saved["blood_type"]))
		body.set_blood_type(saved["blood_type"])
	if(istext(saved["gender"]))
		body.gender = saved["gender"]
	if(istext(saved["physique"]))
		body.physique = saved["physique"]
	if(isnum(saved["age"]))
		body.age = saved["age"]
	if(istext(saved["real_name"]) && length(saved["real_name"]))
		body.real_name = saved["real_name"]
		body.name = saved["real_name"]
		body.dna.real_name = saved["real_name"]
	body.updateappearance(icon_update = TRUE, mutcolor_update = TRUE, mutations_overlay_update = TRUE)

/// What a human wears and holds, as an outfit of item types (a fresh copy of each item). Not
/// copy_outfit(): that admin helper asks for a name and registers the outfit globally.
/proc/babylon_tutorial_capture_outfit(mob/living/carbon/human/body)
	var/datum/outfit/varedit/outfit = new
	outfit.name = "Tutorial revive"
	var/static/list/slots = list(ITEM_SLOT_ICLOTHING, ITEM_SLOT_UNDERWEAR, ITEM_SLOT_SHIRT, ITEM_SLOT_BRA, ITEM_SLOT_SOCKS, ITEM_SLOT_BACK, ITEM_SLOT_OCLOTHING, ITEM_SLOT_BELT, ITEM_SLOT_GLOVES, ITEM_SLOT_WRISTS, ITEM_SLOT_FEET, ITEM_SLOT_HEAD, ITEM_SLOT_MASK, ITEM_SLOT_NECK, ITEM_SLOT_EARS_LEFT, ITEM_SLOT_EARS_RIGHT, ITEM_SLOT_EYES, ITEM_SLOT_ID, ITEM_SLOT_SUITSTORE, ITEM_SLOT_LPOCKET, ITEM_SLOT_RPOCKET)
	for(var/slot in slots)
		var/obj/item/item = body.get_item_by_slot(slot)
		if(istype(item))
			outfit.set_equipment_by_slot(slot, item.type)
	if(length(body.held_items) >= 2)
		var/obj/item/left = body.held_items[1]
		var/obj/item/right = body.held_items[2]
		if(istype(left))
			outfit.l_hand = left.type
		if(istype(right))
			outfit.r_hand = right.type
	var/obj/item/backpack = body.get_item_by_slot(ITEM_SLOT_BACK)
	if(istype(backpack) && backpack.atom_storage)
		var/list/counts = list()
		for(var/obj/item/packed in backpack.atom_storage.return_inv(recursive = FALSE))
			counts[packed.type] += 1
		outfit.backpack_contents = counts
	return outfit
