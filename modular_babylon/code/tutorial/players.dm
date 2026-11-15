// Who the players of the world's tutorial run are (spec 12 #18, #19, #21).
//
// The run follows players by key (their ckey; a mob without one, e.g. in tests, by its ref), not
// by mob: bodies[key] is a weakref to the living mob they play, and it stays on the body they leave
// when they die or ghost. So "Player state" still sees a dead player, and "Revive" finds their body
// again. When a body dies the run captures its looks and equipment; when that dead body is later
// destroyed (gibbed, dusted, deleted), a revive builds a new one from the snapshot. A body deleted
// while alive means the player left (back to the lobby): the run forgets them.
//
// Every living mob with a client (or a player's key) that is not a tutorial NPC is a player; the
// run picks them up on every check. add_player() adds one at once, also without a client: the
// spawning player and tests join that way. A client-less mob that was never a player (a monkey
// using an item on a target) never becomes one.

/// The key the run knows a mob's player by.
/proc/babylon_tutorial_player_key(mob/player)
	return player.ckey || "mob_[REF(player)]"

/// A mob that can take part in the run: living, not a tutorial NPC.
/proc/babylon_tutorial_can_play(mob/living/player)
	return isliving(player) && !QDELETED(player) && !player.babylon_tutorial_npc

/// Adds a player (or moves their key to this new living body). key: the player's key when the
/// body does not carry it yet (a rebuilt body before the player is put in).
/datum/babylon_tutorial_run/proc/add_player(mob/living/player, key)
	if(!babylon_tutorial_can_play(player))
		return
	key = key || babylon_tutorial_player_key(player)
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
	// The ghosts of disconnected players, looked up once per call (not once per key).
	var/list/ghosts
	for(var/key in bodies)
		var/client/player = GLOB.directory[key]
		var/mob/current = player?.mob
		if(!current)
			if(isnull(ghosts))
				ghosts = babylon_tutorial_ghosts_by_key()
			current = ghosts[key] || body_of(key)
		if(current && !QDELETED(current))
			found |= current
	return found

/// ckey => ghost, for ghosts that carry a key.
/proc/babylon_tutorial_ghosts_by_key()
	var/list/ghosts = list()
	for(var/mob/dead/observer/ghost in GLOB.dead_mob_list)
		if(ghost.ckey)
			ghosts[ghost.ckey] = ghost
	return ghosts

/// The mob that holds a player key now (their client's mob, else a ghost carrying the key).
/proc/babylon_tutorial_mob_of_key(key)
	var/client/player = GLOB.directory[key]
	if(player?.mob)
		return player.mob
	for(var/mob/dead/observer/ghost in GLOB.dead_mob_list)
		if(ghost.ckey == key)
			return ghost
	return null

/// Whether a mob (an item's user, a button's presser) counts as a player of this run: a known
/// player, or a living mob a player controls (a client or a player's key). Never a client-less
/// mob nobody plays.
/datum/babylon_tutorial_run/proc/is_player(mob/living/user)
	if(!babylon_tutorial_can_play(user))
		return FALSE
	if(preview)
		return user == preview_mob
	if(body_of(babylon_tutorial_player_key(user)) == user)
		return TRUE
	if(!user.client && !user.ckey)
		return FALSE
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
		shot["identity"] = babylon_capture_identity(human)
		shot["items"] = babylon_tutorial_capture_items(human)
	snapshots[key] = shot

/// Revives one player: their body if it still exists, else a new body made from the snapshot;
/// then the player is put back into it. Only a player who is around to come back counts: one in
/// their dead body or watching as a ghost. Nobody is pulled out of the lobby, an SSD corpse stays
/// as it is and a player who plays another living body is left alone. Returns the body, or null
/// when there was nothing to do.
/datum/babylon_tutorial_run/proc/revive_player(key)
	var/mob/living/body = body_of(key)
	var/mob/current = babylon_tutorial_mob_of_key(key)
	var/present = isobserver(current) || (body && current == body)
	if(!present)
		return null
	if(body)
		// Alive and played: nothing to revive.
		if(body.stat != DEAD && current == body)
			return null
		if(body.stat == DEAD)
			body.revive(HEAL_ALL | HEAL_ADMIN)
		babylon_tutorial_put_player_in(body, key, current)
	else
		body = rebuild_body(key)
		if(!body)
			return null
		add_player(body, key)
		if(!babylon_tutorial_put_player_in(body, key, current))
			// Nobody could be put in: no empty body stays behind.
			bodies -= key
			qdel(body)
			return null
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
			babylon_apply_identity(human, shot["identity"])
		babylon_tutorial_restore_items(human, shot["items"])
	else if(shot?["name"])
		body.real_name = shot["name"]
		body.name = shot["name"]
	return body

/// Puts a player (by key) back into a body: their ghost's key (and mind) move into it. Only from
/// a ghost or a dead body: a player in the lobby or in another living body is left alone.
/proc/babylon_tutorial_put_player_in(mob/living/body, key, mob/current)
	if(body.ckey == key)
		return TRUE
	if(!current || current == body)
		return FALSE
	if(!isobserver(current) && !(isliving(current) && current.stat == DEAD))
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
// Items of a body that died: the originals come back where they still exist; only the ones that
// are gone are made again, so a revive never duplicates an item.

/// The slots a revive dresses, uniform first (pockets, belt and ID hang on it).
/proc/babylon_tutorial_revive_slots()
	return list(ITEM_SLOT_ICLOTHING, ITEM_SLOT_UNDERWEAR, ITEM_SLOT_SHIRT, ITEM_SLOT_BRA, ITEM_SLOT_SOCKS, ITEM_SLOT_OCLOTHING, ITEM_SLOT_BACK, ITEM_SLOT_BELT, ITEM_SLOT_GLOVES, ITEM_SLOT_WRISTS, ITEM_SLOT_FEET, ITEM_SLOT_HEAD, ITEM_SLOT_MASK, ITEM_SLOT_NECK, ITEM_SLOT_EARS_LEFT, ITEM_SLOT_EARS_RIGHT, ITEM_SLOT_EYES, ITEM_SLOT_ID, ITEM_SLOT_SUITSTORE, ITEM_SLOT_LPOCKET, ITEM_SLOT_RPOCKET)

/// What a human wears, holds and carries in its backpack: list(list(type, slot, hand, packed,
/// item weakref)). Not copy_outfit(): that admin helper asks for a name and registers globally.
/proc/babylon_tutorial_capture_items(mob/living/carbon/human/body)
	var/list/items = list()
	for(var/slot in babylon_tutorial_revive_slots())
		var/obj/item/item = body.get_item_by_slot(slot)
		if(istype(item))
			items += list(list("type" = item.type, "slot" = slot, "ref" = WEAKREF(item)))
	for(var/hand in 1 to length(body.held_items))
		var/obj/item/held = body.held_items[hand]
		if(istype(held))
			items += list(list("type" = held.type, "hand" = hand, "ref" = WEAKREF(held)))
	var/obj/item/backpack = body.get_item_by_slot(ITEM_SLOT_BACK)
	if(istype(backpack) && backpack.atom_storage)
		for(var/obj/item/packed in backpack.atom_storage.return_inv(recursive = FALSE))
			items += list(list("type" = packed.type, "packed" = TRUE, "ref" = WEAKREF(packed)))
	return items

/// Dresses a rebuilt body. Per item: the original when it still exists and no one carries it
/// (dropped by a gib, lying on the floor or in a crate); nothing when someone else carries it now;
/// a fresh copy only when it is gone.
/proc/babylon_tutorial_restore_items(mob/living/carbon/human/body, list/items)
	var/turf/tile = get_turf(body)
	var/obj/item/backpack
	for(var/list/entry in items)
		var/datum/weakref/item_ref = entry["ref"]
		var/obj/item/item = item_ref?.resolve()
		if(item && get(item, /mob))
			continue
		if(!item)
			var/path = entry["type"]
			if(!ispath(path, /obj/item))
				continue
			item = new path(tile)
		if(entry["packed"])
			backpack = backpack || body.get_item_by_slot(ITEM_SLOT_BACK)
			if(!backpack?.atom_storage?.attempt_insert(item, body, override = TRUE, force = STORAGE_FULLY_LOCKED, messages = FALSE))
				item.forceMove(tile)
		else if(entry["hand"])
			if(!body.put_in_hand(item, entry["hand"]))
				item.forceMove(tile)
		else if(!body.equip_to_slot_if_possible(item, entry["slot"], disable_warning = TRUE, bypass_equip_delay_self = TRUE, initial = TRUE, indirect_action = TRUE))
			item.forceMove(tile)

// ---------------------------------------------------------------------------------------------
// Identity: one capture and one apply for every body the Babylon code saves or rebuilds (tutorial
// revives here, the station build's characters in station_characters.dm). The list is the saved
// character entry's own format: top-level name, gender, physique, age and species, the DNA in "dna".

/proc/babylon_capture_identity(mob/living/carbon/human/body)
	var/datum/dna/dna = body.dna
	var/list/dna_data = list()
	if(dna)
		dna_data = list(
			"unique_enzymes" = dna.unique_enzymes,
			"unique_identity" = dna.unique_identity,
			"unique_features" = dna.unique_features,
			"features" = islist(dna.features) ? dna.features.Copy() : list(),
			"mutant_bodyparts" = islist(dna.mutant_bodyparts) ? dna.mutant_bodyparts.Copy() : list(),
			"body_markings" = islist(dna.body_markings) ? dna.body_markings.Copy() : list(),
			"blood_type" = dna.blood_type?.id,
		)
	return list(
		"real_name" = babylon_save_text(body.real_name),
		"gender" = body.gender,
		"physique" = body.physique,
		"age" = body.age,
		"species" = dna?.species ? "[dna.species.type]" : "[/datum/species/human]",
		"dna" = dna_data,
	)

/// Species, DNA, name, blood type and look from a babylon_capture_identity() list (or a saved
/// character entry, which holds the same keys).
/proc/babylon_apply_identity(mob/living/carbon/human/body, list/entry)
	var/list/saved = islist(entry["dna"]) ? entry["dna"] : list()
	var/species_type = text2path(entry["species"])
	if(!ispath(species_type, /datum/species))
		species_type = /datum/species/human
	var/list/features = islist(saved["features"]) ? saved["features"] : body.dna.features.Copy()
	var/list/mutant_parts = islist(saved["mutant_bodyparts"]) ? saved["mutant_bodyparts"] : list()
	var/list/markings = islist(saved["body_markings"]) ? saved["body_markings"] : list()
	// set_species() keeps the DNA's current features over the ones it is given: the saved ones go
	// into the DNA first, so the species' organs (tails, ears ...) are made from them.
	body.dna.features = features.Copy()
	body.dna.mutant_bodyparts = mutant_parts.Copy()
	body.dna.body_markings = markings.Copy()
	body.set_species(species_type, icon_update = FALSE, pref_load = FALSE, override_features = features.Copy(), override_mutantparts = mutant_parts.Copy(), override_markings = markings.Copy())
	for(var/field in list("unique_enzymes", "unique_identity", "unique_features"))
		if(istext(saved[field]))
			body.dna.vars[field] = saved[field]
	if(istext(saved["blood_type"]))
		body.set_blood_type(saved["blood_type"])
	if(istext(entry["gender"]))
		body.gender = entry["gender"]
	if(istext(entry["physique"]))
		body.physique = entry["physique"]
	if(isnum(entry["age"]))
		body.age = entry["age"]
	if(istext(entry["real_name"]) && length(entry["real_name"]))
		body.real_name = entry["real_name"]
		body.name = entry["real_name"]
		body.dna.real_name = entry["real_name"]
	body.updateappearance(icon_update = TRUE, mutcolor_update = TRUE, mutations_overlay_update = TRUE)
