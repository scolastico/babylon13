/*
 * Rough player position updates for external map tools such as the SPLURT atlas.
 *
 * tgui-panel forwards every message the server sends it to the player's optional
 * websocket relay (chat settings -> Websocket), so a periodic "player/position"
 * message is all a local map tool needs. The panel reports when that relay
 * connects and disconnects, and the updates only run while it is connected:
 * players without a relay never get a timer.
 */

/**
 * The atlas's z for a world z: the 1-based index among the station's levels
 * (SSmapping.levels_by_trait(ZTRAIT_STATION)), or null off the station (CentCom, lavaland,
 * space ruins, reserved levels). Shared by the position updates and the stat panel's map link
 * (client_procs.dm "openWebMap"), so both use the same frame on every map, multi-z or not.
 */
/proc/atlas_station_z(z)
	var/list/station_levels = SSmapping.levels_by_trait(ZTRAIT_STATION)
	return station_levels.Find(z) || null

/**
 * The atlas's key of the current map: the "m" parameter of its webmap_url fragment
 * (maps.txt, e.g. ".../splurt-atlas/#m=metastation" gives "metastation"), the same key the
 * stat panel's map link opens. Null when the map has no such URL.
 */
/proc/atlas_map_key()
	var/url = SSmapping.current_map?.mapping_url
	var/hash = url ? findtext(url, "#") : 0
	if(!hash)
		return null
	for(var/param in splittext(copytext(url, hash + 1), "&"))
		if(findtext(param, "m=") == 1)
			return url_decode(copytext(param, 3))
	return null

/datum/tgui_panel
	/// Looping timer behind the position updates, TIMER_ID_NULL while they are not running.
	var/position_timer_id = TIMER_ID_NULL

/datum/tgui_panel/on_message(type, payload)
	. = ..()
	switch(type)
		if("websocket/open")
			start_position_updates()
			return TRUE
		if("websocket/closed")
			stop_position_updates()
			return TRUE

// A reloaded panel ("Fix chat") starts without a relay and reports it again once it reconnects.
/datum/tgui_panel/initialize(force = FALSE)
	stop_position_updates()
	return ..()

/datum/tgui_panel/Del()
	stop_position_updates()
	return ..()

/datum/tgui_panel/proc/start_position_updates()
	stop_position_updates()
	var/interval = CONFIG_GET(number/atlas_position_interval)
	if(interval <= 0)
		return
	position_timer_id = addtimer(CALLBACK(src, PROC_REF(send_position)), interval SECONDS, TIMER_LOOP | TIMER_STOPPABLE)

/datum/tgui_panel/proc/stop_position_updates()
	if(position_timer_id == TIMER_ID_NULL)
		return
	deltimer(position_timer_id)
	position_timer_id = TIMER_ID_NULL

/**
 * private
 *
 * Sends the client's own mob position to the panel, offset by a random amount.
 */
/datum/tgui_panel/proc/send_position()
	if(!client)
		stop_position_updates()
		return
	if(!is_ready())
		return
	var/turf/location = get_turf(client.mob)
	if(!location)
		return
	// The reported tile is deliberately offset by a random amount inside the configured radius.
	// Whatever listens on the websocket (map tools, but also any automation or bot) only ever gets
	// a rough estimate of where the player is, never exact coordinates.
	// "z" and "map" are in the atlas's frame, the same as the stat panel's map link: z within
	// the station (null off the station) and the map's atlas key. "world_z" and "map_name" are
	// the raw values, for debugging.
	var/radius = CONFIG_GET(number/atlas_position_fuzz_radius)
	window.send_message("player/position", list(
		"x" = clamp(location.x + rand(-radius, radius), 1, world.maxx),
		"y" = clamp(location.y + rand(-radius, radius), 1, world.maxy),
		"z" = atlas_station_z(location.z),
		"world_z" = location.z,
		"radius" = radius,
		"map" = atlas_map_key(),
		"map_name" = SSmapping.current_map?.map_name,
		"round_id" = GLOB.round_id,
	))
