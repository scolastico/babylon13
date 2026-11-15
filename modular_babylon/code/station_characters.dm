// Players' characters in station worlds (babylon-station.dmb only).
//
// A player's body persists in its world, by ckey: state["characters"][ckey] holds the human (name,
// species, DNA, job, limb damage, where it stood) and its inventory as save records whose parent is
// the character. Characters are captured apart from the levels on every save, so a reused
// (unchanged) level never carries a player's body or items (persistence_levels.dm).
// - Which body is a player's is kept on their /datum/babylon_player (character_ref), updated every
//   world tick while they play; the per-player records (state["players"]) and the characters use
//   that one registry, player_sessions. A body is saved for a player only while it is theirs (its
//   ckey or its mind's key), and only once.
// - Bodies players left behind (a corpse whose player now plays someone else, a body given up for a
//   cyborg) are saved too, without a player: state["characters"]["#<save id>"]. They come back as
//   they were, belong to nobody and take no job.
// - Bodies come back only when the save's round had started (round_mode "resume"); a world
//   restored before its round started spawns none. restore_containers() rebuilds them before the
//   records pass, so their items find their parent; the human's babylon_after_restore() puts the
//   damage back and equips the items. A body saved on a shuttle (which loads again at its
//   roundstart dock) or over space comes back at a late-join point. Living bodies come back asleep
//   (SSD), so the usual cryo rules free their job. At the resumed round's start they take their
//   jobs again (job slot, crew manifest, bank account, the job's implants).
// - A returning player is put back into their body (reattach_saved_character); a player whose
//   body was dead, or who watched it as a ghost, comes back as its ghost. Players without a saved
//   body join late as usual.
// - Tutorial snapshots never hold characters: babylon_world_saves_characters() (world_flags.dm).
// Preferences (the character editor) are shared between worlds by the supervisor; bodies are not.

/// state["characters"] keys of bodies without a player start with this.
#define BABYLON_OWNERLESS_PREFIX "#"

/datum/babylon_player
	/// The player's human in this world: the body they play, or the one they watch as a ghost.
	var/datum/weakref/character_ref
	/// The player watched their body as a ghost (or it is dead): they come back as its ghost.
	var/character_ghosted = FALSE
	/// The job title of a restored character, until the resumed round registers it.
	var/character_job
	/// The bank balance of a restored character, until the resumed round opens its account.
	var/character_balance

/mob/living/carbon/human
	/// A body a player left behind, restored without a player: saved again as one.
	var/babylon_kept_body = FALSE

/// The player's human, or null.
/datum/babylon_player/proc/character()
	RETURN_TYPE(/mob/living/carbon/human)
	var/mob/living/carbon/human/body = character_ref?.resolve()
	return (ishuman(body) && !QDELETED(body)) ? body : null

/// Makes body this player's character. A body is one player's at most (character_owners): anyone
/// else's link to it goes. While it is theirs, its deletion (gibbed, dusted) marks its level as
/// changed, so whatever it dropped there is saved with the level. Called every world tick for every
/// player: an unchanged body costs nothing more.
/datum/babylon_player/proc/set_character(mob/living/carbon/human/body, ghosted = FALSE)
	var/mob/living/carbon/human/previous = character()
	character_ghosted = body ? !!ghosted : FALSE
	if(previous == body && body)
		return
	var/list/owners = GLOB.babylon_save.character_owners
	if(previous)
		UnregisterSignal(previous, COMSIG_QDELETING)
		if(owners[previous] == src)
			owners -= previous
	character_ref = body ? WEAKREF(body) : null
	if(!body)
		return
	var/datum/babylon_player/other = owners[body]
	if(other && other != src)
		other.set_character(null)
	owners[body] = src
	RegisterSignal(body, COMSIG_QDELETING, PROC_REF(character_deleted))

/datum/babylon_player/proc/character_deleted(mob/living/carbon/human/body)
	SIGNAL_HANDLER
	var/turf/tile = get_turf(body)
	if(tile)
		GLOB.babylon_save.mark_level_changed(tile.z, body)
	if(GLOB.babylon_save.character_owners[body] == src)
		GLOB.babylon_save.character_owners -= body
	character_ref = null
	character_ghosted = FALSE

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
		if(!ishuman(body) || !ghost.can_reenter_corpse)
			set_character(null)
			return
		// An admin's ghost (aghost) leaves a living body with a "@key": the admin comes back in it.
		var/admin_ghost = body.stat != DEAD && copytext(body.key, 1, 2) == "@"
		set_character(body, !admin_ghost)
		return
	if(isnewplayer(current) || !current)
		return
	set_character(null)

/// The ckey whose body this is: its own key, or its mind's (a body whose player is away or
/// watches it as a ghost keeps the mind's key).
/proc/babylon_body_owner(mob/living/carbon/human/body)
	if(body.ckey)
		return body.ckey
	return body.mind?.key ? ckey(body.mind.key) : null

/datum/babylon_save
	/// Players whose characters this restore rebuilt; the resumed round's start registers their jobs.
	var/list/restored_characters = list()
	/// Body -> the /datum/babylon_player whose character it is (one player per body).
	var/list/character_owners = list()
	/// ckey -> saved character entry this restore could not rebuild: saved again unchanged while
	/// the player has no character, so one failure does not lose the character for good.
	var/list/unrestored_characters = list()

/datum/babylon_save/New()
	. = ..()
	tick_listeners += new /datum/babylon_tick_listener(src, CALLBACK(src, PROC_REF(track_characters)))

/datum/babylon_save/proc/track_characters()
	if(busy || draining)
		return
	track_connected_characters()

/// Each connected player's record follows their mob (track_character()).
/datum/babylon_save/proc/track_connected_characters()
	for(var/client/student in GLOB.clients)
		if(!babylon_ready_client(student) || student.babylon_showcase_visitor || student.babylon_admin_spectator)
			continue
		var/datum/babylon_player/player = ensure_station_player(student.ckey)
		player?.track_character(student.mob)

/// Where a returning body goes when its own place cannot hold it: a late-join point, else the
/// observer start.
/datum/babylon_save/proc/character_arrival_turf()
	if(length(SSjob.latejoin_trackers))
		return get_turf(pick(SSjob.latejoin_trackers))
	return respawn_turf

// --- Saving ---------------------------------------------------------------------------------

/// state["characters"]: every player's human on a saved level, by ckey, and the player bodies left
/// behind ("#<save id>"). None in a tutorial snapshot (babylon_world_saves_characters()) or before
/// the round started. One character that cannot be captured is skipped and logged; the save goes on.
/datum/babylon_save/proc/capture_characters(for_tutorial = FALSE)
	var/list/characters = list()
	if(!babylon_world_saves_characters(for_tutorial) || !SSticker.HasRoundStarted())
		return characters
	// Bodies taken since the last world tick (a late-join a moment ago) are their players'.
	track_connected_characters()
	var/list/levels = persisted_levels()
	var/list/skipped_tiles = checkpoint_skipped_tiles()
	var/list/captured_bodies = list()
	for(var/player_key in player_sessions)
		var/datum/babylon_player/player = player_sessions[player_key]
		var/mob/living/carbon/human/body = player.character()
		if(!body)
			if(unrestored_characters[player_key])
				characters[player_key] = unrestored_characters[player_key]
			continue
		// A body someone else now plays (a mind swap, an admin taking it over) is no longer theirs.
		if(babylon_body_owner(body) != player_key)
			player.set_character(null)
			continue
		if(captured_bodies[body] || !saves_character_body(body, levels))
			continue
		captured_bodies[body] = TRUE
		try
			characters[player_key] = capture_character(body, player, skipped_tiles)
		catch(var/exception/error)
			log_world("Babylon save: the character of [player_key] could not be saved: [error] ([error?.file]:[error?.line])")
	for(var/mob/living/carbon/human/body as anything in GLOB.human_list)
		if(captured_bodies[body] || QDELETED(body) || !saves_character_body(body, levels))
			continue
		var/owner_key = babylon_body_owner(body)
		if(!body.babylon_kept_body && !owner_key && !body.last_mind?.key)
			continue // an NPC human (ruin corpses): not kept (checkpoint_mobs()).
		captured_bodies[body] = TRUE
		// A body its player is in (a ckey on it), while their record holds no other character:
		// theirs, not left behind. A player who joined a moment ago may have no record yet.
		var/datum/babylon_player/owner = owner_key && body.ckey == owner_key ? ensure_station_player(owner_key) : null
		if(owner && !characters[owner_key] && !owner.character())
			owner.set_character(body)
			try
				characters[owner_key] = capture_character(body, owner, skipped_tiles)
			catch(var/exception/owner_error)
				log_world("Babylon save: the character of [owner_key] could not be saved: [owner_error] ([owner_error?.file]:[owner_error?.line])")
			continue
		try
			var/list/entry = capture_character(body, null, skipped_tiles)
			characters["[BABYLON_OWNERLESS_PREFIX][entry["id"]]"] = entry
		catch(var/exception/error)
			log_world("Babylon save: the body of [body.real_name] could not be saved: [error] ([error?.file]:[error?.line])")
	return characters

/// A body that goes into a save: on a saved level, not a hologram or a tutorial prop.
/datum/babylon_save/proc/saves_character_body(mob/living/carbon/human/body, list/levels)
	var/turf/tile = get_turf(body)
	return tile && (tile.z in levels) && !body.babylon_skip_save() && !(body.flags_1 & HOLOGRAM_1)

/// One character: the human's identity, job, damage and place, and its items as save records
/// (the worn and held ones with the character as parent, their contents below them). player is
/// null for a body left behind. skipped_tiles: checkpoint_skipped_tiles(), the shuttles' tiles.
/datum/babylon_save/proc/capture_character(mob/living/carbon/human/body, datum/babylon_player/player, list/skipped_tiles = checkpoint_skipped_tiles())
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
	var/datum/bank_account/account = SSeconomy.bank_accounts_by_id["[body.account_id]"]
	// A body on a shuttle's tile, which the level saves as what lies beneath the shuttle (it loads
	// again at its roundstart dock; players' own shuttles are saved where they are), would come back
	// over that. The same tiles as the level writer's (checkpoint_skipped_tiles()).
	var/list/entry = list(
		"id" = body_id,
		"type" = "[body.type]",
		"x" = tile.x,
		"y" = tile.y,
		"z" = tile.z,
		"on_shuttle" = !!skipped_tiles[tile],
		"job" = body.mind?.assigned_role?.title,
		"balance" = account?.account_balance,
		"stat" = body.stat,
		"ghost" = player ? (player.character_ghosted || body.stat == DEAD) : FALSE,
		"bodyparts" = bodyparts,
		"tox" = body.get_tox_loss(),
		"oxy" = body.get_oxy_loss(),
		"records" = records,
	)
	// Name, gender, physique, age, species and DNA: the shared identity format (tutorial/players.dm).
	var/list/identity = babylon_capture_identity(body)
	for(var/key in identity)
		entry[key] = identity[key]
	return entry

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
	for(var/key in characters)
		var/list/entry = characters[key]
		var/ownerless = copytext(key, 1, 2) == BABYLON_OWNERLESS_PREFIX
		if((!ownerless && ckey(key) != key) || !islist(entry) || !istext(entry["id"]))
			continue
		var/mob/living/carbon/human/body
		try
			body = restore_character(ownerless ? null : key, entry)
			// Where it stands now (a late-join point if its own place could not hold it), as a saved
			// z: restore_world() maps a record's z through restored_level_z().
			. += list(list("id" = entry["id"], "type" = "[body.type]", "parent" = null, "x" = body.x, "y" = body.y, "z" = saved_level_of(body.z), "fields" = list("babylon_character" = entry), "references" = list()))
			for(var/list/record in entry["records"])
				. += list(record)
		catch(var/exception/error)
			log_world("Babylon restore: the character [key] could not be rebuilt: [error] ([error?.file]:[error?.line])")
			if(body)
				restored_atoms -= entry["id"]
				qdel(body)
			if(!ownerless)
				unrestored_characters[key] = entry

/// The human of one saved character, with its identity and, for a player's character, a mind
/// for its player. player_key is null for a body left behind.
/datum/babylon_save/proc/restore_character(player_key, list/entry)
	RETURN_TYPE(/mob/living/carbon/human)
	var/turf/tile = locate(entry["x"], entry["y"], restored_level_z(entry["z"]))
	if(entry["on_shuttle"] || !tile || isspaceturf(tile) || isclosedturf(tile))
		tile = character_arrival_turf()
	var/path = text2path(entry["type"])
	if(!ispath(path, /mob/living/carbon/human))
		path = /mob/living/carbon/human
	var/mob/living/carbon/human/body = new path(tile)
	body.babylon_save_id = entry["id"]
	restored_atoms[entry["id"]] = body
	apply_character_identity(body, entry)
	if(!player_key)
		body.babylon_kept_body = TRUE
		return body
	var/datum/mind/mind = new /datum/mind(player_key)
	mind.name = body.real_name
	mind.active = FALSE
	mind.transfer_to(body)
	var/datum/babylon_player/player = ensure_station_player(player_key)
	player.set_character(body, !!entry["ghost"])
	player.character_job = istext(entry["job"]) ? entry["job"] : null
	player.character_balance = isnum(entry["balance"]) ? entry["balance"] : null
	restored_characters |= player
	// Asleep until their player returns, as after a Logout(): the usual cryo rules apply.
	if(entry["stat"] != DEAD && !entry["ghost"])
		body.lastclienttime = world.time
		body.set_ssd_indicator(TRUE)
	return body

/// Species, DNA, name, blood type and look of a saved character (the shared identity helper).
/datum/babylon_save/proc/apply_character_identity(mob/living/carbon/human/body, list/entry)
	babylon_apply_identity(body, entry)

/mob/living/carbon/human/babylon_after_restore(list/fields)
	var/list/entry = fields["babylon_character"]
	if(islist(entry))
		GLOB.babylon_save.finish_character(src, entry)

/// After every saved object exists: the character's damage, lost limbs and death come back
/// (without dying a second time), then it wears and holds its items again. The damage comes first:
/// an item that cannot be put back must never bring a dead body back alive.
/datum/babylon_save/proc/finish_character(mob/living/carbon/human/body, list/entry)
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
	if(entry["stat"] == DEAD)
		// Dead already, as the save's other mobs (persistence_levels.dm): no death() again.
		var/obj/item/organ/heart/heart = body.get_organ_slot(ORGAN_SLOT_HEART)
		heart?.Stop()
		body.timeofdeath = world.time
		body.set_stat(DEAD)
	else
		body.updatehealth()
	body.update_damage_overlays()
	try
		equip_character(body, entry)
	catch(var/exception/error)
		log_world("Babylon restore: [body.real_name]'s items could not all be put back on: [error] ([error?.file]:[error?.line])")
	body.regenerate_icons()

/// Puts a restored character's worn and held items back on.
/datum/babylon_save/proc/equip_character(mob/living/carbon/human/body, list/entry)
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

/// The resumed round started (persistence_levels.dm): restored characters take their jobs again,
/// counted in their job's slots (living ones: a dead body holds no slot), appear on the crew
/// manifest, get their bank account back on their ID card and their job's implants (mindshields).
/datum/babylon_save/proc/register_restored_characters()
	for(var/datum/babylon_player/player as anything in restored_characters)
		var/mob/living/carbon/human/body = player.character()
		if(!body?.mind)
			continue
		try
			register_restored_character(player, body)
		catch(var/exception/error)
			log_world("Babylon: the restored character [body.real_name] could not take their job again: [error] ([error?.file]:[error?.line])")
	restored_characters = list()

/datum/babylon_save/proc/register_restored_character(datum/babylon_player/player, mob/living/carbon/human/body)
	var/datum/job/job = player.character_job ? SSjob.get_job(player.character_job) : null
	if(job)
		body.mind.set_assigned_role(job)
		if(body.stat != DEAD)
			job.current_positions++
	SSticker.minds |= body.mind
	GLOB.manifest.inject(body)
	if(job?.paycheck_department)
		var/datum/bank_account/account = new(body.real_name, job, body.dna.species.payday_modifier)
		account.account_balance = isnum(player.character_balance) ? player.character_balance : 0
		account.replaceable = FALSE
		body.account_id = account.account_id
		// Their own card (one that names them) holds their account.
		var/obj/item/card/id/card = body.get_idcard(hand_first = FALSE)
		if(card && card.registered_name == body.real_name)
			card.set_account(account)
		else if(card)
			log_world("Babylon: [body.real_name]'s ID card names [card.registered_name]; their bank account is not put on it.")
	if(job?.outfit && body.stat != DEAD)
		var/datum/outfit/outfit = new job.outfit
		for(var/implant_type in outfit.implants)
			if(locate(implant_type) in body.implants)
				continue
			var/obj/item/implant/implant = new implant_type
			implant.implant(body, null, TRUE)
		qdel(outfit)

// --- Rejoining ------------------------------------------------------------------------------

/// What a returning player of a resumed round gets: list("plan" = "body" (back into it), "ghost"
/// (back as its ghost: it is dead, or they watched it as one) or "latejoin" (no saved body, or it
/// is someone else's now), "body" = the body).
/datum/babylon_save/proc/saved_character_plan(player_key)
	var/datum/babylon_player/record = player_sessions[player_key]
	var/mob/living/carbon/human/body = record?.character()
	if(!body || body.client || (body.ckey && body.ckey != player_key) || babylon_body_owner(body) != player_key)
		return list("plan" = "latejoin")
	return list("plan" = (record.character_ghosted || body.stat == DEAD) ? "ghost" : "body", "body" = body)

/// Puts a returning player (on the menu of a resumed round) into the body this world saved for
/// them, or back as its ghost (saved_character_plan()). TRUE when they have it; FALSE leaves the
/// normal late-join menu, also after an error on the way. Never makes a second body.
/datum/babylon_save/proc/reattach_saved_character(client/player)
	if(!player)
		return FALSE
	var/mob/dead/new_player/menu = player.mob
	if(!istype(menu))
		return FALSE
	var/list/plan = saved_character_plan(player.ckey)
	if(plan["plan"] == "latejoin")
		return FALSE
	var/mob/living/carbon/human/body = plan["body"]
	try
		menu.spawning = TRUE
		menu.hide_title_screen()
		if(body.mind)
			body.mind.key = player.key
		body.PossessByPlayer(player.ckey)
	catch(var/exception/error)
		log_world("Babylon: [player.ckey] could not be put back into [body.real_name]: [error] ([error?.file]:[error?.line])")
		if(!QDELETED(menu) && player.mob == menu)
			menu.spawning = FALSE
			menu.show_title_screen()
			to_chat(player, span_warning("Your saved character could not be given back. Press <b>JOIN GAME</b> to join the round."))
			return FALSE
	// The client is in the body now: the rest must not send it anywhere else.
	try
		body.stop_sound_channel(CHANNEL_LOBBYMUSIC)
		player.init_verbs()
		GLOB.joined_player_list |= player.ckey
		if(!QDELETED(menu))
			qdel(menu)
		log_game("[key_name(player)] returned to their saved character [body.real_name].")
		if(plan["plan"] == "ghost")
			body.ghostize(TRUE)
			to_chat(player, span_notice("You are back as the ghost of [html_encode(body.real_name)], where this world was saved."))
		else
			to_chat(player, span_notice("You are back in your character, [html_encode(body.real_name)], where this world was saved."))
	catch(var/exception/finish_error)
		log_world("Babylon: finishing [player.ckey]'s return to [body.real_name] failed: [finish_error] ([finish_error?.file]:[finish_error?.line])")
	return TRUE

#undef BABYLON_OWNERLESS_PREFIX
