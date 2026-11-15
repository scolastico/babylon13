// Creative panel, Self and Tools tabs: godmode, noclip, heal, the tool kit and the tutorial
// wand. Powers only ever act on the player's own body (panel.dm checks that).

/// Trait source of every creative power, so turning a power off never removes another source's.
#define BABYLON_CREATIVE_TRAIT "babylon_creative"
/// How far (tiles) noclip-off and teleports look for a free spot.
#define BABYLON_CREATIVE_UNSTUCK_RANGE 15

/// Bodies holding a creative power (weakrefs), so the powers can be taken back when Creative is
/// switched off while the world runs.
GLOBAL_LIST_EMPTY(babylon_creative_powered)

/mob/living
	/// Noclip (creative) is on; the body's incorporeal_move from before it is kept here.
	var/babylon_creative_noclip = FALSE
	var/babylon_creative_prior_incorporeal = FALSE
	/// Fullbright (creative) is on: this body sees every tile lit, whatever the lighting.
	var/babylon_creative_fullbright = FALSE

/proc/babylon_creative_godmode(mob/living/user)
	return HAS_TRAIT_FROM(user, TRAIT_GODMODE, BABYLON_CREATIVE_TRAIT)

/proc/babylon_creative_set_godmode(mob/living/user, enabled)
	if(enabled)
		ADD_TRAIT(user, TRAIT_GODMODE, BABYLON_CREATIVE_TRAIT)
		GLOB.babylon_creative_powered |= WEAKREF(user)
	else
		REMOVE_TRAIT(user, TRAIT_GODMODE, BABYLON_CREATIVE_TRAIT)
	return babylon_creative_godmode(user)

/proc/babylon_creative_xray(mob/living/user)
	return HAS_TRAIT_FROM(user, TRAIT_XRAY_VISION, BABYLON_CREATIVE_TRAIT)

/// X-ray: see turfs, objects and mobs through walls (tg's TRAIT_XRAY_VISION, our own trait source).
/proc/babylon_creative_set_xray(mob/living/user, enabled)
	if(enabled)
		ADD_TRAIT(user, TRAIT_XRAY_VISION, BABYLON_CREATIVE_TRAIT)
		GLOB.babylon_creative_powered |= WEAKREF(user)
	else
		REMOVE_TRAIT(user, TRAIT_XRAY_VISION, BABYLON_CREATIVE_TRAIT)
	return babylon_creative_xray(user)

/// Fullbright: the lighting plane's cutoff is raised to fully bright. Carbon bodies get it from
/// their sight update (every update recomputes the cutoff, so a signal hook keeps it); any other
/// living body has its cutoff set directly.
/proc/babylon_creative_set_fullbright(mob/living/user, enabled)
	if(enabled == user.babylon_creative_fullbright)
		return enabled
	user.babylon_creative_fullbright = enabled
	if(enabled)
		GLOB.babylon_creative_powered |= WEAKREF(user)
		if(iscarbon(user))
			user.RegisterSignal(user, COMSIG_CARBON_UPDATE_SIGHT_CUTOFFS, TYPE_PROC_REF(/mob/living, babylon_creative_fullbright_cutoff))
		else
			user.lighting_cutoff = LIGHTING_CUTOFF_FULLBRIGHT
	else
		if(iscarbon(user))
			user.UnregisterSignal(user, COMSIG_CARBON_UPDATE_SIGHT_CUTOFFS)
		else
			user.lighting_cutoff = initial(user.lighting_cutoff)
	user.update_sight()
	return enabled

/// Runs inside the carbon sight update, before the cutoff is applied to the screen.
/mob/living/proc/babylon_creative_fullbright_cutoff(datum/source, list/return_list)
	SIGNAL_HANDLER
	lighting_cutoff = LIGHTING_CUTOFF_FULLBRIGHT

/proc/babylon_creative_set_noclip(mob/living/user, enabled)
	if(enabled == user.babylon_creative_noclip)
		return enabled
	if(enabled)
		user.babylon_creative_prior_incorporeal = user.incorporeal_move
		user.incorporeal_move = INCORPOREAL_MOVE_BASIC
		user.babylon_creative_noclip = TRUE
		GLOB.babylon_creative_powered |= WEAKREF(user)
		return TRUE
	user.incorporeal_move = user.babylon_creative_prior_incorporeal
	user.babylon_creative_prior_incorporeal = FALSE
	user.babylon_creative_noclip = FALSE
	babylon_creative_unstuck(user)
	return FALSE

/// TRUE when a body cannot stand on this turf: walls, dense machines, anything blocking.
/proc/babylon_creative_turf_blocked(turf/spot, atom/movable/mover)
	return !spot || spot.is_blocked_turf(exclude_mobs = TRUE, source_atom = mover)

/// The nearest free turf to `center` (itself included) on its z-level, preferring floors over
/// space, or null when there is none within BABYLON_CREATIVE_UNSTUCK_RANGE.
/proc/babylon_creative_free_turf(turf/center, atom/movable/mover)
	if(!center)
		return null
	if(!babylon_creative_turf_blocked(center, mover))
		return center
	var/turf/space_fallback
	for(var/distance in 1 to BABYLON_CREATIVE_UNSTUCK_RANGE)
		for(var/turf/candidate as anything in RANGE_TURFS(distance, center))
			if(get_dist(candidate, center) != distance || babylon_creative_turf_blocked(candidate, mover))
				continue
			if(!isspaceturf(candidate))
				return candidate
			space_fallback ||= candidate
		if(space_fallback)
			return space_fallback
	return null

/// Moves a body standing inside a wall (noclip just turned off) to the nearest free spot.
/proc/babylon_creative_unstuck(mob/living/user)
	var/turf/here = get_turf(user)
	if(!here || !babylon_creative_turf_blocked(here, user))
		return FALSE
	var/turf/free = babylon_creative_free_turf(here, user)
	if(!free)
		return FALSE
	user.forceMove(free)
	return TRUE

/// Full heal; revives a dead body.
/proc/babylon_creative_heal(mob/living/user)
	return user.revive(HEAL_ALL)

/// Takes back every creative power from every body (Creative switched off at runtime).
/proc/babylon_creative_revoke_powers()
	for(var/datum/weakref/reference as anything in GLOB.babylon_creative_powered)
		var/mob/living/body = reference.resolve()
		if(!istype(body) || QDELETED(body))
			continue
		babylon_creative_set_godmode(body, FALSE)
		babylon_creative_set_noclip(body, FALSE)
		babylon_creative_set_xray(body, FALSE)
		babylon_creative_set_fullbright(body, FALSE)
	GLOB.babylon_creative_powered.Cut()

/// The tools the kit's toolbelt holds.
/proc/babylon_creative_belt_tools()
	var/static/list/tools = list(
		/obj/item/screwdriver/power,
		/obj/item/crowbar/power,
		/obj/item/weldingtool/experimental,
		/obj/item/multitool,
		/obj/item/stack/cable_coil,
		/obj/item/analyzer,
		/obj/item/t_scanner,
	)
	return tools

/// Everything in the kit, as the Kits tab lists it.
/proc/babylon_creative_kit_types()
	return list(/obj/item/storage/belt/utility) + babylon_creative_belt_tools() + list(
		/obj/item/clothing/gloves/color/yellow,
		/obj/item/construction/rcd/loaded/upgraded,
		/obj/item/pipe_dispenser,
	)

/// The basic tool kit: a toolbelt with the everyday tools, plus an RCD (with matter), an RPD and
/// insulated gloves. Human bodies wear the belt and gloves when those slots are free; the rest
/// goes to the hands, else to the floor. Returns the created items.
/proc/babylon_creative_give_tools(mob/living/user)
	var/turf/location = get_turf(user)
	var/obj/item/storage/belt/utility/belt = new(location)
	for(var/tool in babylon_creative_belt_tools())
		var/obj/item/created = new tool(location)
		if(!belt.atom_storage.attempt_insert(created, override = TRUE, messages = FALSE))
			qdel(created)
	var/obj/item/clothing/gloves/color/yellow/gloves = new(location)
	var/obj/item/construction/rcd/loaded/upgraded/rcd = new(location)
	var/obj/item/pipe_dispenser/rpd = new(location)
	if(!user.equip_to_slot_if_possible(belt, ITEM_SLOT_BELT, disable_warning = TRUE))
		user.put_in_hands(belt)
	if(!user.equip_to_slot_if_possible(gloves, ITEM_SLOT_GLOVES, disable_warning = TRUE))
		user.put_in_hands(gloves)
	user.put_in_hands(rcd)
	user.put_in_hands(rpd)
	return list(belt, gloves, rcd, rpd)

/// The tutorial wand (tutorial-capable worlds), in hand. Null while it does not exist.
/proc/babylon_creative_give_wand(mob/living/user)
	var/wand_type = babylon_tutorial_wand_type()
	if(!ispath(wand_type, /obj/item))
		return null
	var/obj/item/wand = new wand_type(get_turf(user))
	user.put_in_hands(wand)
	return wand
