// Shared by the standalone lobby and both game builds; no simulation dependencies.

/// Route default loopback links through the server the player actually reached. winget's
/// "url" is the SERVER's IP:port; client.address is the PLAYER's IP and must never be used.
/// A configured non-loopback destination stays authoritative. Keep the destination's port
/// and query verbatim: in particular, never rebuild, log or expose an admission ticket.
/proc/babylon_connection_address(destination, endpoint)
	if(!istext(destination))
		return null
	var/static/regex/target = regex(@"^byond://([a-z0-9][a-z0-9.-]{0,252}):([0-9]{1,5})(\?[^\x00-\x20#]*)?$", "i")
	if(!target.Find(destination))
		return null
	var/host = lowertext(target.group[1])
	if(copytext(host, -1) == ".")
		host = copytext(host, 1, -1)
	var/destination_port = target.group[2]
	var/port = text2num(destination_port)
	var/suffix = target.group[3]
	if(host == "0.0.0.0" || port < 1 || port > 65535)
		return null
	var/static/regex/loopback = regex(@"^127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$")
	if(host != "localhost" && !loopback.Find(host))
		return destination
	if(!istext(endpoint))
		return null
	var/static/regex/connected = regex(@"^([a-z0-9][a-z0-9.-]{0,252}):([0-9]{1,5})$", "i")
	if(!connected.Find(endpoint))
		return null
	host = connected.group[1]
	port = text2num(connected.group[2])
	if(host == "0.0.0.0" || port < 1 || port > 65535)
		return null
	return "byond://[host]:[destination_port][suffix]"

/// Read the connected server only when the default address needs routing. Public addresses
/// work even if the client cannot answer winget. Invalid/unavailable endpoints fail closed.
/client/proc/babylon_server_link(destination)
	var/address = babylon_connection_address(destination, null)
	if(address)
		return address
	return babylon_connection_address(destination, winget(src, null, "url"))

/// One record format for the standalone lobby and both world builds. JSON escapes player text,
/// so names and refusal reasons cannot create forged log lines. Never pass tickets or URLs here.
/proc/babylon_session_log_line(event, player_ckey, ip, world_name = null, world_id = null, reason = null)
	return "BABYLON_SESSION [json_encode(list("time" = time2text(world.realtime, "YYYY-MM-DD hh:mm:ss"), "event" = event, "ckey" = ckey(player_ckey), "ip" = ip || "127.0.0.1", "world_name" = world_name, "world_id" = world_id, "reason" = reason))]"

/client
	var/babylon_session_connected = 0
	var/babylon_session_joined = 0
	var/babylon_session_left = 0
	var/babylon_session_leave_reason
	var/babylon_session_target_name
	var/babylon_session_target_world

/client/proc/babylon_log_session(event, reason = null, world_name = null, world_id = null)
	if(!world_id)
		world_id = world.params["babylon-world"]
#ifdef BABYLON_BUILDER
	if(!world_name)
#else
	if(world_id && world_id == world.params["babylon-world"] && !world_name)
#endif
		world_name = world.params["babylon-name"] || world.name
	world.log << babylon_session_log_line(event, ckey, address, world_name, world_id, reason)

/// A redirect may be declined or fail; only deletion confirms departure. A later kick/ban
/// replaces an earlier return intent, retaining the actual final cause.
/client/proc/babylon_set_leave_reason(reason)
	if(!babylon_session_left)
		babylon_session_leave_reason = reason

/client/proc/babylon_log_leave(reason)
	if(babylon_session_left)
		return
	babylon_session_leave_reason = reason || babylon_session_leave_reason || "unknown"
	if(babylon_session_joined && !babylon_session_left)
		babylon_session_left = 1
		babylon_log_session("leave_world", babylon_session_leave_reason)

/client/proc/babylon_log_disconnect(reason)
	if(!babylon_session_connected)
		return
	babylon_log_leave(reason)
	babylon_log_session("disconnect", babylon_session_leave_reason || "unknown", babylon_session_target_name, babylon_session_target_world)
	babylon_session_connected = 0

/client/Del()
	babylon_log_disconnect(babylon_session_leave_reason)
	return ..()

/// Flush before the engine destroys clients; their Del hooks need not run during shutdown.
/world/Del()
	for(var/client/player)
		player.babylon_log_disconnect("world_stopped")
	return ..()
