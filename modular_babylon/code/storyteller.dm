/*
 * Storytellers. Shared by both game builds.
 *
 * Babylon worlds have no storyteller yet: no round-start vote, no event rolls and no
 * antagonists. SPLURT starts a storyteller vote when DEFAULT_STORYTELLER is unset (Babylon's
 * own config does not set it), and other code expects a storyteller to exist. So every
 * Babylon world runs the inert storyteller below instead of none at all. A Babylon-specific
 * storyteller replaces it later; the overrides here keep any other one from being picked.
 *
 * Station worlds (babylon-station.dmb) run SPLURT's normal storytellers, but never vote: a
 * private world rarely has voters. They use DEFAULT_STORYTELLER from the config, else the one
 * SSgamemode falls back to without a vote (/datum/storyteller/default). Creative Plane and
 * tutorial worlds are station worlds that use the inert Babylon storyteller too: events there
 * come only from the Creative panel.
 */

/datum/storyteller/babylon
	name = "Babylon"
	desc = "Babylon's storyteller. It does not run events or antagonists yet."
	welcome_text = "The station is quiet."
	disable_distribution = TRUE
	guarantees_roundstart_crewset = FALSE
	antag_divisor = 0
	votable = FALSE

// Which worlds run only the inert Babylon storyteller: babylon_storyteller_inert() (world_flags.dm).

/// The storyteller this world runs: the inert one, or the station world's fixed one.
/proc/babylon_world_storyteller()
	if(babylon_storyteller_inert())
		return /datum/storyteller/babylon
	var/configured = text2path(CONFIG_GET(string/default_storyteller))
	if(ispath(configured, /datum/storyteller) && configured != /datum/storyteller/babylon && SSgamemode.storytellers[configured])
		return configured
	// SSgamemode's own choice when nobody voted (its initial voted_storyteller).
	return /datum/storyteller/default

/datum/vote/storyteller/can_be_initiated(mob/by_who, forced = FALSE)
	..()
	return "This world has no storyteller vote."

/// No vote in any world, even when SPLURT's vote schedule would override the config.
/datum/controller/subsystem/gamemode/storyteller_vote_can_override()
	return FALSE

/// Inert worlds only run the Babylon storyteller, whatever is requested (config, vote, admin).
/// Other station worlds take requests as usual.
/datum/controller/subsystem/gamemode/set_storyteller(passed_type, forced, force_ckey)
	if(!babylon_storyteller_inert())
		return ..()
	if(passed_type != /datum/storyteller/babylon)
		log_dynamic("Babylon ignored a request for storyteller [passed_type].")
	return ..(/datum/storyteller/babylon, forced, force_ckey)

/// Inert worlds select the Babylon storyteller silently, without the vote results or a chat and
/// Discord announcement. Station worlds get their fixed storyteller instead of a vote result.
/datum/controller/subsystem/gamemode/init_storyteller()
	if(babylon_storyteller_inert())
		if(storyteller?.type != /datum/storyteller/babylon)
			set_storyteller(/datum/storyteller/babylon)
		return
	if(!storyteller)
		voted_storyteller = babylon_world_storyteller()
	return ..()

/// tgstation's own random events stay off in inert worlds, even with ALLOW_RANDOM_EVENTS set or
/// toggled by an admin.
/datum/controller/subsystem/events/spawnEvent(datum/round_event_control/excluded_event)
	if(babylon_storyteller_inert())
		return
	return ..()
