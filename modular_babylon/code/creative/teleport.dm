// Creative panel, Teleport tab: coordinates, areas, players and tutorial markers, always within
// this world's own levels (never CentCom, transit/reserved space or secret levels).

/// TRUE when z is one of this world's real levels.
/proc/babylon_creative_level_allowed(z)
	if(!isnum(z) || z < 1 || z > world.maxz || z > length(SSmapping.z_list))
		return FALSE
	return !SSmapping.level_has_any_trait(z, list(ZTRAIT_CENTCOM, ZTRAIT_RESERVED, ZTRAIT_SECRET))

/// The levels a creative player can teleport to: list of list(z, name).
/proc/babylon_creative_levels()
	var/list/levels = list()
	for(var/z in 1 to min(world.maxz, length(SSmapping.z_list)))
		if(!babylon_creative_level_allowed(z))
			continue
		var/datum/space_level/level = SSmapping.z_list[z]
		levels += list(list("z" = z, "name" = level.name || "Level [z]"))
	return levels

/// The areas on this world's levels (space left out): list of list(path, name, z), by name.
/proc/babylon_creative_areas()
	var/list/areas = list()
	var/list/names = list()
	for(var/area/place as anything in GLOB.areas)
		if(istype(place, /area/space) || !place.has_contained_turfs())
			continue
		for(var/z in 1 to length(place.turfs_by_zlevel))
			if(!babylon_creative_level_allowed(z) || !length(place.get_turfs_by_zlevel(z)))
				continue
			var/key = "[place.name] [z] [place.type]"
			if(names[key])
				continue
			names[key] = TRUE
			areas += list(list("path" = "[place.type]", "name" = place.name, "z" = z))
	sortTim(areas, GLOBAL_PROC_REF(cmp_babylon_creative_name))
	return areas

/proc/cmp_babylon_creative_name(list/first, list/second)
	return sorttext(second["name"], first["name"])

/// The other players in this world a creative player can teleport to: list of list(ckey, name).
/proc/babylon_creative_players(mob/user)
	var/list/players = list()
	for(var/mob/other as anything in GLOB.player_list)
		var/client/player = other.client
		if(other == user || !player || player.babylon_showcase_visitor || player.babylon_admin_spectator)
			continue
		var/turf/spot = get_turf(other)
		if(!spot || !babylon_creative_level_allowed(spot.z) || isnewplayer(other))
			continue
		players += list(list("ckey" = player.ckey, "name" = "[other.name] ([player.key])", "z" = spot.z))
	return players

/// The tutorial markers a creative player can teleport to: list of list(id, x, y, z).
/proc/babylon_creative_markers()
	var/list/markers = list()
	var/list/targets = babylon_tutorial_marker_targets()
	for(var/id in targets)
		var/turf/spot = get_turf(targets[id])
		if(spot && babylon_creative_level_allowed(spot.z))
			markers += list(list("id" = "[id]", "x" = spot.x, "y" = spot.y, "z" = spot.z))
	return markers

/**
 * Moves `user` to `destination`, or the nearest free spot if it is blocked and the user has no
 * noclip. Returns null on success, else the reason.
 */
/proc/babylon_creative_teleport(mob/living/user, turf/destination)
	if(!destination || !babylon_creative_level_allowed(destination.z))
		return "That place is not part of this world."
	if(!user.babylon_creative_noclip)
		destination = babylon_creative_free_turf(destination, user)
		if(!destination)
			return "There is no free spot there. Turn on noclip to go into walls."
	// Leave whatever holds the body first: a chair or ridden vehicle, a mech or sealed vehicle,
	// a closet (forceMove alone would leave the closet or mech behind with a stale occupant).
	user.stop_pulling()
	user.buckled?.unbuckle_mob(user, force = TRUE)
	if(istype(user.loc, /obj/vehicle/sealed))
		var/obj/vehicle/sealed/vehicle = user.loc
		vehicle.mob_exit(user, silent = TRUE)
	user.forceMove(destination)
	return null

/// Coordinates from the panel, clamped to the map; the level must be one of this world's.
/proc/babylon_creative_coordinates_turf(x, y, z)
	x = text2num("[x]")
	y = text2num("[y]")
	z = text2num("[z]")
	if(isnull(x) || isnull(y) || isnull(z) || !babylon_creative_level_allowed(round(z)))
		return null
	return locate(clamp(round(x), 1, world.maxx), clamp(round(y), 1, world.maxy), round(z))

/// A free turf in an area, on this world's levels (on level `only_z` when it is given), or null.
/proc/babylon_creative_area_turf(area_path, mob/user, only_z)
	var/path = text2path("[area_path]")
	if(!ispath(path, /area) || ispath(path, /area/space))
		return null
	var/area/place = GLOB.areas_by_type[path]
	if(!place)
		return null
	var/list/candidates = list()
	for(var/z in 1 to length(place.turfs_by_zlevel))
		if(babylon_creative_level_allowed(z) && (!only_z || z == only_z))
			candidates += place.get_turfs_by_zlevel(z)
	if(!length(candidates))
		return null
	for(var/attempt in 1 to 30)
		var/turf/candidate = pick(candidates)
		if(!babylon_creative_turf_blocked(candidate, user))
			return candidate
	for(var/turf/candidate as anything in candidates)
		if(!babylon_creative_turf_blocked(candidate, user))
			return candidate
	return candidates[1]
