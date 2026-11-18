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
