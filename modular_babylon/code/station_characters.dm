// Players' characters in station worlds (babylon-station.dmb only).
//
// A player's body persists in its world, by ckey: state["characters"][ckey] holds the human (name,
// species, DNA, job, limb damage, where it stood) and its inventory as save records whose parent is
// the character. Characters are captured apart from the levels on every save, so a reused
// (unchanged) level never carries a player's body or items (persistence_levels.dm).
// - Which body is a player's is kept on their /datum/babylon_player (character_ref), updated every
//   world tick while they play; the per-player records (state["players"]) and the characters use
//   that one registry, player_sessions.
// - Bodies come back only when the save's round had started (round_mode "resume"); a world
//   restored before its round started spawns none. restore_containers() rebuilds them before the
//   records pass, so their items find their parent; the human's babylon_after_restore() equips
//   the items and puts the damage back. At the resumed round's start they take their jobs again
//   (job slot, crew manifest).
// - A returning player is put back into their body (reattach_saved_character); a player whose
//   body was dead, or who watched it as a ghost, comes back as its ghost. Players without a saved
//   body join late as usual.
// - Tutorial snapshots never hold characters: babylon_world_saves_characters() (world_flags.dm).
// Preferences (the character editor) are shared between worlds by the supervisor; bodies are not.

/datum/babylon_player
	/// The player's human in this world: the body they play, or the one they watch as a ghost.
	var/datum/weakref/character_ref
	/// The player watched their body as a ghost (or it is dead): they come back as its ghost.
	var/character_ghosted = FALSE
	/// The job title of a restored character, until the resumed round registers it.
	var/character_job

/// The player's human, or null.
/datum/babylon_player/proc/character()
	RETURN_TYPE(/mob/living/carbon/human)
	var/mob/living/carbon/human/body = character_ref?.resolve()
	return (ishuman(body) && !QDELETED(body)) ? body : null

/datum/babylon_player/proc/set_character(mob/living/carbon/human/body, ghosted = FALSE)
	character_ref = body ? WEAKREF(body) : null
	character_ghosted = body ? !!ghosted : FALSE

/// Follows the player's mob: their human, the human their ghost can return to, or none once they
/// play something else (a cyborg, an animal) or gave their body up. The menu changes nothing (a
/// restored body waits there for its player).
/datum/babylon_player/proc/track_character(mob/current)
	if(ishuman(current))
		set_character(current)
		return
	if(isobserver(current))
		var/mob/dead/observer/ghost = current
		var/mob/living/carbon/human/body = ghost.mind?.current
		set_character((ishuman(body) && ghost.can_reenter_corpse) ? body : null, TRUE)
		return
	if(isnewplayer(current) || !current)
		return
	set_character(null)

/datum/babylon_save
	/// Players whose characters this restore rebuilt; the resumed round's start registers their jobs.
	var/list/restored_characters = list()

/datum/babylon_save/New()
	. = ..()
	tick_listeners += new /datum/babylon_tick_listener(src, CALLBACK(src, PROC_REF(track_characters)))

/datum/babylon_save/proc/track_characters()
	if(busy || draining)
		return
	for(var/client/student in GLOB.clients)
		if(!babylon_ready_client(student) || student.babylon_showcase_visitor || student.babylon_admin_spectator)
			continue
		var/datum/babylon_player/player = ensure_station_player(student.ckey)
		player?.track_character(student.mob)

// --- Saving ---------------------------------------------------------------------------------

/// state["characters"]: every player's human on a saved level, by ckey. None in a tutorial snapshot
/// (babylon_world_saves_characters()) or before the round started.
/datum/babylon_save/proc/capture_characters(for_tutorial = FALSE)
	var/list/characters = list()
	if(!babylon_world_saves_characters(for_tutorial) || !SSticker.HasRoundStarted())
		return characters
	var/list/levels = persisted_levels()
	for(var/player_key in player_sessions)
		var/datum/babylon_player/player = player_sessions[player_key]
		var/mob/living/carbon/human/body = player.character()
		if(!body || body.babylon_skip_save())
			continue
		var/turf/tile = get_turf(body)
		if(!tile || !(tile.z in levels))
			continue
		characters[player_key] = capture_character(body, player)
	return characters

/// One character: the human's identity, job, damage and place, and its items as save records
/// (the worn and held ones with the character as parent, their contents below them).
/datum/babylon_save/proc/capture_character(mob/living/carbon/human/body, datum/babylon_player/player)
	var/body_id = assign_id(body)
	var/turf/tile = get_turf(body)
	var/list/records = list()
	for(var/obj/item/item as anything in body.get_equipped_items(INCLUDE_POCKETS | INCLUDE_HELD))
		if(QDELETED(item) || item.loc != body || item.babylon_skip_save())
			continue
		var/list/record = capture(item, records, body_id)
		var/hand = body.get_held_index_of_item(item)
		if(hand)
			record["hand"] = hand
		else
			record["slot"] = body.get_slot_by_item(item)
	var/list/bodyparts = list()
	for(var/obj/item/bodypart/part as anything in body.bodyparts)
		bodyparts += list(list("zone" = part.body_zone, "brute" = part.brute_dam, "burn" = part.burn_dam))
	var/datum/dna/dna = body.dna
	var/list/dna_data = list(
		"unique_enzymes" = dna.unique_enzymes,
		"unique_identity" = dna.unique_identity,
		"unique_features" = dna.unique_features,
		"features" = dna.features.Copy(),
		"mutant_bodyparts" = LAZYCOPY(dna.mutant_bodyparts),
		"body_markings" = dna.body_markings.Copy(),
		"blood_type" = dna.blood_type?.id,
	)
	return list(
		"id" = body_id,
		"type" = "[body.type]",
		"x" = tile.x,
		"y" = tile.y,
		"z" = tile.z,
		"real_name" = babylon_save_text(body.real_name),
		"gender" = body.gender,
		"physique" = body.physique,
		"age" = body.age,
		"species" = "[dna.species.type]",
		"dna" = dna_data,
		"job" = body.mind?.assigned_role?.title,
		"stat" = body.stat,
		"ghost" = player.character_ghosted || body.stat == DEAD,
		"bodyparts" = bodyparts,
		"tox" = body.get_tox_loss(),
		"oxy" = body.get_oxy_loss(),
		"records" = records,
	)

// --- Restoring ------------------------------------------------------------------------------

/// Rebuilds the saved characters before the records pass (persistence.dm): only when the save's
/// round had started, and never where characters are not kept. Returns each human's record (its
/// babylon_after_restore() finishes it) and its items' records.
/datum/babylon_save/restore_containers(list/state)
	. = list()
	var/list/characters = state["characters"]
	if(!islist(characters) || !length(characters))
		return
	if(!babylon_state_round_started(state) || !babylon_world_saves_characters())
		log_world("Babylon restore: [length(characters)] saved character(s) not rebuilt (the round had not started, or this world keeps none).")
		return
	for(var/player_key in characters)
		var/list/entry = characters[player_key]
		if(ckey(player_key) != player_key || !islist(entry) || !istext(entry["id"]))
			continue
		try
			var/mob/living/carbon/human/body = restore_character(player_key, entry)
			. += list(list("id" = entry["id"], "type" = "[body.type]", "parent" = null, "x" = entry["x"], "y" = entry["y"], "z" = entry["z"], "fields" = list("babylon_character" = entry), "references" = list()))
			for(var/list/record in entry["records"])
				. += list(record)
		catch(var/exception/error)
			log_world("Babylon restore: the character of [player_key] could not be rebuilt: [error] ([error?.file]:[error?.line])")

/// The human of one saved character, with its identity and a mind for its player.
/datum/babylon_save/proc/restore_character(player_key, list/entry)
	RETURN_TYPE(/mob/living/carbon/human)
	var/turf/tile = locate(entry["x"], entry["y"], restored_level_z(entry["z"]))
	if(!tile)
		tile = respawn_turf
	var/path = text2path(entry["type"])
	if(!ispath(path, /mob/living/carbon/human))
		path = /mob/living/carbon/human
	var/mob/living/carbon/human/body = new path(tile)
	apply_character_identity(body, entry)
	body.babylon_save_id = entry["id"]
	restored_atoms[entry["id"]] = body
	var/datum/mind/mind = new /datum/mind(player_key)
	mind.name = body.real_name
	mind.active = FALSE
	mind.transfer_to(body)
	var/datum/babylon_player/player = ensure_station_player(player_key)
	player.set_character(body, !!entry["ghost"])
	player.character_job = istext(entry["job"]) ? entry["job"] : null
	restored_characters |= player
	return body

/// Species, DNA, name, blood type and look of a saved character.
/datum/babylon_save/proc/apply_character_identity(mob/living/carbon/human/body, list/entry)
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

/mob/living/carbon/human/babylon_after_restore(list/fields)
	var/list/entry = fields["babylon_character"]
	if(islist(entry))
		GLOB.babylon_save.finish_character(src, entry)

/// After every saved object exists: the character wears and holds its items again, its lost limbs
/// stay lost and its damage and death come back (without dying a second time on screen).
/datum/babylon_save/proc/finish_character(mob/living/carbon/human/body, list/entry)
	var/list/pending = list()
	for(var/list/record in entry["records"])
		if(record["parent"] != entry["id"])
			continue
		var/obj/item/item = restored_atoms[record["id"]]
		if(!istype(item) || QDELETED(item))
			continue
		// Made inside the body, but not worn: it is equipped from the body's tile.
		item.forceMove(body.drop_location())
		pending[item] = record
	// Some slots need another item first (a belt or pockets need the jumpsuit).
	for(var/attempt in 1 to 3)
		var/placed_any = FALSE
		for(var/obj/item/item as anything in pending.Copy())
			var/list/record = pending[item]
			var/placed = FALSE
			if(isnum(record["hand"]))
				placed = body.put_in_hand(item, record["hand"], forced = TRUE)
			else if(isnum(record["slot"]))
				placed = body.equip_to_slot_if_possible(item, record["slot"], disable_warning = TRUE, redraw_mob = FALSE, bypass_equip_delay_self = TRUE, initial = TRUE)
			if(placed)
				pending -= item
				placed_any = TRUE
		if(!placed_any || !length(pending))
			break
	for(var/obj/item/item as anything in pending)
		log_world("Babylon restore: [body.real_name]'s [item.type] could not be put back on; it lies at their feet.")
	var/list/parts = list()
	for(var/list/part in entry["bodyparts"])
		parts[part["zone"]] = part
	if(length(parts))
		for(var/obj/item/bodypart/part as anything in body.bodyparts.Copy())
			var/list/saved = parts[part.body_zone]
			if(!saved)
				// Only limbs can have been lost and lived without.
				if(part.body_zone in list(BODY_ZONE_L_ARM, BODY_ZONE_R_ARM, BODY_ZONE_L_LEG, BODY_ZONE_R_LEG))
					part.drop_limb(special = TRUE)
					qdel(part)
				continue
			// Set as saved: receive_damage() would apply the species' modifiers a second time.
			part.brute_dam = clamp(isnum(saved["brute"]) ? saved["brute"] : 0, 0, part.max_damage)
			part.burn_dam = clamp(isnum(saved["burn"]) ? saved["burn"] : 0, 0, part.max_damage)
			if(part.can_be_disabled)
				part.update_disabled()
	if(isnum(entry["tox"]))
		body.set_tox_loss(entry["tox"], updating_health = FALSE, forced = TRUE)
	if(isnum(entry["oxy"]))
		body.set_oxy_loss(entry["oxy"], updating_health = FALSE, forced = TRUE)
	body.updatehealth()
	if(entry["stat"] == DEAD && body.stat != DEAD)
		body.death()
	body.update_damage_overlays()
	body.regenerate_icons()

/// The resumed round started (persistence_levels.dm): restored characters take their jobs again,
/// counted in their job's slots, and appear on the crew manifest.
/datum/babylon_save/proc/register_restored_characters()
	for(var/datum/babylon_player/player as anything in restored_characters)
		var/mob/living/carbon/human/body = player.character()
		if(!body?.mind)
			continue
		var/datum/job/job = player.character_job ? SSjob.get_job(player.character_job) : null
		if(job)
			body.mind.set_assigned_role(job)
			job.current_positions++
		SSticker.minds |= body.mind
		GLOB.manifest.inject(body)
	restored_characters = list()

// --- Rejoining ------------------------------------------------------------------------------

/// Puts a returning player (on the menu of a resumed round) into the body this world saved for
/// them, or back as its ghost when it is dead or they watched it as one. TRUE when they have it;
/// FALSE leaves the normal late-join menu. Never makes a second body.
/datum/babylon_save/proc/reattach_saved_character(client/player)
	if(!player)
		return FALSE
	var/datum/babylon_player/record = player_sessions[player.ckey]
	var/mob/living/carbon/human/body = record?.character()
	var/mob/dead/new_player/menu = player.mob
	if(!body || !istype(menu) || body.client || (body.ckey && body.ckey != player.ckey))
		return FALSE
	menu.spawning = TRUE
	menu.hide_title_screen()
	if(body.mind)
		body.mind.key = player.key
	body.PossessByPlayer(player.ckey)
	body.stop_sound_channel(CHANNEL_LOBBYMUSIC)
	player.init_verbs()
	if(!QDELETED(menu))
		qdel(menu)
	log_game("[key_name(player)] returned to their saved character [body.real_name].")
	if(record.character_ghosted || body.stat == DEAD)
		body.ghostize(TRUE)
		to_chat(player, span_notice("You are back as the ghost of [html_encode(body.real_name)], where this world was saved."))
	else
		to_chat(player, span_notice("You are back in your character, [html_encode(body.real_name)], where this world was saved."))
	return TRUE
