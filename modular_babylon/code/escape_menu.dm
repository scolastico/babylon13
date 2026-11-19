// Babylon game worlds return through the same lobby handoff as the verb/HUD.
// The separate lobby build retains its native Quit command.
/datum/escape_menu/send_init()
	. = ..()
	send_update(list("babylon" = TRUE, "canReturnToLobby" = !!client?.babylon_lobby_link()))

/datum/escape_menu/on_message(type, payload, href_list)
	if(type == "action" && payload?["action"] == "quit" && client?.babylon_lobby_link())
		client?.babylon_return_lobby()
		return TRUE
	return ..()
