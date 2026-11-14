// The supermatter stays spawnable in creative worlds (engine tutorials need it), but in creative
// and tutorial worlds a delamination never makes a singularity, a tesla ball or a resonance
// cascade (crystal mass, evacuation rift, round end): those would eat or end the whole world.
// The explosion, radiation, hallucinations and anomalies stay.

/// Delaminations here only explode: the world is creative or a tutorial.
/proc/babylon_delam_contained()
	return babylon_creative_enabled() || !!GLOB.babylon_world?.is_tutorial()

/datum/sm_delam/effect_singulo(obj/machinery/power/supermatter_crystal/sm)
	if(babylon_delam_contained())
		return FALSE // The singularity delamination falls back to its explosion.
	return ..()

/datum/sm_delam/effect_tesla(obj/machinery/power/supermatter_crystal/sm)
	if(babylon_delam_contained())
		return FALSE
	return ..()

/datum/sm_delam/effect_crystal_mass(obj/machinery/power/supermatter_crystal/sm, avoid)
	if(babylon_delam_contained())
		return
	return ..()

/datum/sm_delam/cascade/can_select(obj/machinery/power/supermatter_crystal/sm)
	if(babylon_delam_contained())
		return FALSE
	return ..()

// A cascade forced anyway (an admin's manual delamination) explodes like an ordinary one.
/datum/sm_delam/cascade/delaminate(obj/machinery/power/supermatter_crystal/sm)
	if(!babylon_delam_contained())
		return ..()
	log_delamination(sm)
	effect_irradiate(sm)
	effect_demoralize(sm)
	effect_explosion(sm)
	qdel(sm)

// Two immovable rods meeting collapse into a singularity. Here they just shatter. (The panel does
// not offer the rod event either; wizards and admins can still throw rods.)
/obj/effect/immovablerod/Bump(atom/clong)
	if(babylon_delam_contained() && istype(clong, /obj/effect/immovablerod))
		visible_message(span_danger("[src] collides with [clong] and both shatter!"))
		do_smoke(2, src, get_turf(src))
		qdel(clong)
		qdel(src)
		return
	return ..()
