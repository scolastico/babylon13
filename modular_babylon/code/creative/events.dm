// Creative panel, Events tab: tg round events a creative player can start in this world.
// The Babylon build never fires SSevents (rules.dm), so events started here are stepped by the
// creative module's world tick instead (babylon_creative_step_events, panel.dm).

/// Events per player and window.
#define BABYLON_CREATIVE_EVENT_LIMIT 3
#define BABYLON_CREATIVE_EVENT_WINDOW (30 SECONDS)

/**
 * TRUE when the panel must not offer or start this event. Refused:
 * - roundstart events, wizard events, events without a round event datum;
 * - everything that makes antagonists or hands bodies to ghosts: the crewset/ghostset tracks,
 *   antagonist tags, ghost-role events (they recruit other players);
 * - events that single out other players: heart attack, brain trauma, disease, fake virus,
 *   obsession, borers, sentience;
 * - events that wreck the server or the round: space vines and fleshmind (unbounded spreading),
 *   mold, the emergency shuttle events (insurance, loan, catastrophe), dynamic tweaks.
 */
/proc/babylon_creative_event_blocked(datum/round_event_control/control)
	if(!istype(control) || !ispath(control.typepath, /datum/round_event))
		return TRUE
	if(control.roundstart || control.wizardevent || control.holidayID)
		return TRUE
	if(control.track == EVENT_TRACK_CREWSET || control.track == EVENT_TRACK_GHOSTSET)
		return TRUE
	if(ispath(control.typepath, /datum/round_event/ghost_role))
		return TRUE
	var/list/tags = control.tags
	if(islist(tags) && length(tags & list(TAG_CREW_ANTAG, TAG_TEAM_ANTAG, TAG_OUTSIDER_ANTAG)))
		return TRUE
	var/static/list/blocked = list(
		/datum/round_event_control/antagonist,
		/datum/round_event_control/heart_attack,
		/datum/round_event_control/brain_trauma,
		/datum/round_event_control/disease_outbreak,
		/datum/round_event_control/fake_virus,
		/datum/round_event_control/obsessed,
		/datum/round_event_control/cortical_borer,
		/datum/round_event_control/sentience,
		/datum/round_event_control/bitrunning_glitch,
		/datum/round_event_control/spacevine,
		/datum/round_event_control/fleshmind,
		/datum/round_event_control/mold,
		/datum/round_event_control/shuttle_insurance,
		/datum/round_event_control/shuttle_loan,
		/datum/round_event_control/shuttle_catastrophe,
		/datum/round_event_control/dynamic_tweak,
		/datum/round_event_control/stray_cargo/changeling_zombie,
		/datum/round_event_control/operative,
		/datum/round_event_control/fugitives,
		/datum/round_event_control/slaughter,
		/datum/round_event_control/blob,
		/datum/round_event_control/mutant_infestation,
		/datum/round_event_control/santa,
		/datum/round_event_control/wizard_dice,
	)
	return is_type_in_list(control, blocked)

/// The events the panel offers: list of list(path, name, description, category), by name.
/proc/babylon_creative_events()
	var/list/events = list()
	for(var/datum/round_event_control/control as anything in SSevents.control)
		if(babylon_creative_event_blocked(control))
			continue
		events += list(list(
			"path" = "[control.type]",
			"name" = control.name,
			"description" = control.description || "",
			"category" = control.category || "Other",
		))
	sortTim(events, GLOBAL_PROC_REF(cmp_babylon_creative_name))
	return events

/// Starts an event from the panel. Returns the round event, or an error text.
/proc/babylon_creative_run_event(mob/user, event_path)
	var/path = text2path("[event_path]")
	if(!ispath(path, /datum/round_event_control))
		return "Unknown event."
	var/datum/round_event_control/control = locate(path) in SSevents.control
	if(!control || control.type != path || babylon_creative_event_blocked(control))
		return "That event cannot run here."
	var/datum/round_event/started = control.run_event(event_cause = "[user.key] (creative panel)")
	if(!istype(started))
		return "The event did not start."
	return started

/// Events need SSevents to step them; the Babylon build switches it off (rules.dm).
/proc/babylon_creative_events_need_stepping()
	return !!(SSevents.ss_flags & SS_NO_FIRE) || !SSevents.can_fire
