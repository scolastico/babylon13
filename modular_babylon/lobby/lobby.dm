var/global/list/lobby_config

/world
	name = "Babylon 13 Lobby"
	mob = /mob/lobby
	maxx = 1
	maxy = 1
	maxz = 1
	view = 0
	fps = 5
	// A sleeping world stops refreshing its hub entry, so an empty lobby would
	// drop off the hub list until someone joined. Keep it awake.
	sleep_offline = 0
	// BYOND only registers with the hub set at compile time, so hub is fixed here.
	// The world announces itself while it starts, before New() can read the lobby
	// config. Announced with a wrong password, the hub treats it as unregistered and
	// lists it only while someone is connected; a later password change is not
	// re-announced until a player joins. So the lobby starts invisible with
	// upstream's (public) password, and New() sets the configured password before
	// making it visible (BABYLON_HUB_LISTED). Unlisted lobbies stay invisible.
	hub = "Exadv1.spacestation13"
	hub_password = "kMZy3U5jJHSiBQjr"
	visibility = 0

/world/New()
	..()
	var/config_file = world.params["lobby-config"] || "babylon-lobby-config.json"
	if(!fexists(config_file))
		world.log << "Missing lobby-config JSON file."
		del(world)
		return
	lobby_config = json_decode(file2text(config_file))
	if(!lobby_config["secret"] || !findtext(lobby_config["api"], "http://127.0.0.1:"))
		world.log << "Lobby requires a loopback API and private lobby credential."
		del(world)
		return
	if(lobby_config["name"])
		name = lobby_config["name"]
	world.log << "Lobby started as [name] (hub listing [lobby_config["hub_listed"] ? "on" : "off"])"
	// Only the lobby is listed; child worlds run with -invisible and need a lobby ticket anyway.
	if(lobby_config["hub_listed"])
		if(lobby_config["hub"] && lobby_config["hub"] != hub)
			hub = lobby_config["hub"]
		hub_password = lobby_config["hub_password"]
		visibility = 1
	else
		hub_password = "SORRYNOPASSWORD"
		visibility = 0
	spawn(0)
		while(1)
			// A runtime error must not stop the hub status for the rest of the run.
			try
				update_hub_status()
			catch(var/exception/error)
				world.log << "Updating the hub status failed: [error] ([error.file]:[error.line])"
			sleep(300)

// The hub only counts clients connected to the lobby itself, so the status text
// carries the cluster-wide total including everyone playing in a child world.
/world/proc/update_hub_status()
	var/in_lobby = 0
	for(var/mob/lobby/M)
		if(M.client)
			in_lobby++
	var/in_worlds = 0
	var/running = 0
	var/admin_worlds = 0
	var/list/query = list("secret" = lobby_config["secret"], "action" = "summary")
	var/list/response = Export("[lobby_config["api"]]/api?[list2params(query)]")
	if(response && response["CONTENT"])
		try
			var/list/summary = json_decode(file2text(response["CONTENT"]))
			if(summary && summary["ok"])
				in_worlds = text2num("[summary["players"]]") || 0
				running = text2num("[summary["running_worlds"]]") || 0
				admin_worlds = text2num("[summary["admin_worlds"]]") || 0
		catch
			in_worlds = 0
	status = render_hub_status(in_lobby, in_worlds, running, admin_worlds)
	game_state = 0

/// Fills the BABYLON_HUB_STATUS template (see CLUSTER.md for the placeholders).
/// Admin worlds run outside the limit but are listed as ordinary running worlds here.
/world/proc/render_hub_status(in_lobby, in_worlds, running, admin_worlds = 0)
	var/all_running = running + admin_worlds
	var/text = lobby_config["hub_status"] || "<b>{name}</b>"
	var/list/values = list(
		"{name}" = html_encode(name),
		"{players}" = "[in_lobby + in_worlds]",
		"{lobby_players}" = "[in_lobby]",
		"{world_players}" = "[in_worlds]",
		"{running_worlds}" = "[all_running]",
		"{running_worlds_label}" = "[all_running] running world[all_running == 1 ? "" : "s"]",
		"{admin_worlds}" = "[admin_worlds]",
		"{max_running_worlds}" = "[lobby_config["max_running_worlds"]]",
		"{address}" = html_encode("[lobby_config["address"]]"),
	)
	for(var/key in values)
		text = replacetext(text, key, values[key])
	return text

/world/Topic()
	return null

/client
	/// Each connection (including a return to an existing lobby mob) activates only once.
	var/lobby_window_started = FALSE

/// The document loaded, but DreamSeeker may still be showing its start splash. Read visibility
/// until the main window appears; only then write startup settings, once for this client.
/client/proc/lobby_window_ready()
	set waitfor = FALSE
	if(lobby_window_started)
		return
	lobby_window_started = TRUE
	for(var/attempt in 1 to 60)
		if(!src)
			return
		if(winget(src, "mainwindow", "is-visible") == "true")
			winset(src, "mainwindow", "is-maximized=true")
			// Native top-level activation request; the OS may decline to foreground it.
			winset(src, "mainwindow", "focus=true")
			return
		sleep(10)

/client/New(TopicData)
	// A world sends a player back with babylon_rejoin when its game window stayed hidden
	// (DreamSeeker's start splash bug, see the world's interface.dm): join it again at once.
	var/list/query = istext(TopicData) ? params2list(TopicData) : list()
	TopicData = null
	if(!ckey || findtext(ckey, "guest") == 1 || connection != "seeker")
		return null
	. = ..()
	var/rejoin = query["babylon_rejoin"]
	var/static/regex/world_id = regex(@"^[0-9a-f]{32}$")
	// A world sent the player back with a reason (only known codes: the text is the lobby's own,
	// worded for the button that sent them there, which their returning mob remembers).
	var/static/list/world_notices = list("admission_timeout" = "admission")
	var/world_notice = world_notices[query["babylon_notice"]]
	spawn(1)
		if(src)
			if(world_notice)
				mob:set_notice(lobby_retry_notice(world_notice, mob:last_retry), TRUE)
			mob:show_browser()
			if(istext(rejoin) && world_id.Find(rejoin))
				world.log << "[ckey] returned to rejoin world [rejoin]"
				mob:run_action("join", list("world" = rejoin, "spectate" = query["spectate"] == "1" ? 1 : 0))


/mob/lobby
	var/busy = 0
	var/view_filter = "active"
	var/notice = ""
	/// The notice is a problem (role alert, like the other errors on the page), not a confirmation.
	var/notice_alert = FALSE
	/// How the player was last sent to a world ("join", "play" or "edit"): a notice that sends them
	/// back says which button to press (lobby_retry_notice). Empty on a fresh mob (neutral wording).
	var/last_retry = ""
	/// The text each live message (by key) was last drawn with its role: see announce().
	var/list/announced = list()
	var/list/cards = list()
	/// Map catalog ids from the last list, with their names.
	var/list/map_names = list()
	/// Map catalog ids from the last list, with their build ("babylon" or "station").
	var/list/map_builds = list()
	var/player_limit = 4
	var/browser_initialized = 0
	var/request_revision = 0
	var/last_browser_content = ""
	var/poll_generation = 0
	var/discord_invite = ""
	/// The page request the current action answered (see respond()).
	var/responded = 0
	/// Map preview images already sent to this client with browse_rsc.
	var/list/sent_previews = list()
	/// Tutorials from the last list of the Tutorials tab, by id.
	var/list/tutorial_cards = list()

// BYOND hands a returning player their old mob, so everything tied to the
// previous client connection (its browser page, a pending action, the poll
// loop) must be reset here, or the new client gets an empty grey window.
/mob/lobby/Login()
	..()
	// The lobby's main window has the game skin's id, "mainwindow": on a link() between the
	// lobby and a world, DreamSeeker swaps skins, and after BYOND's Members-ad countdown its
	// handover left the new main window hidden behind the start splash (testing whether the
	// same id avoids it).
	// The skin's static icon is not shown: the window exists before the client has the
	// resource. Set it at login, as the game worlds do.
	var/static/window_icon = 'modular_babylon/icons/babylon13_64.png'
	winset(src, "mainwindow", "icon=\ref[window_icon]")
	loc = locate(1, 1, 1)
	browser_initialized = 0
	last_browser_content = ""
	sent_previews = list()
	// A new connection has heard nothing yet.
	announced = list()
	busy = 0
	request_revision++
	var/generation = ++poll_generation
	world.log << "[ckey] connected to the lobby"
	spawn(50)
		while(client && generation == poll_generation)
			// The page shows the restart screen when these stop: the server went away.
			src << output(null, "mainwindow.browser:lobbyAlive")
			if(!busy)
				// A runtime error must not stop this player's lobby from refreshing.
				try
					show_browser()
				catch(var/exception/error)
					world.log << "Refreshing the lobby of [ckey] failed: [error] ([error.file]:[error.line])"
			sleep(50)

/mob/lobby/Logout()
	world.log << "[ckey] left the lobby"
	browser_initialized = 0
	last_browser_content = ""
	poll_generation++
	..()

/// Longest the lobby waits for one supervisor answer (deciseconds); a tutorial copy can hold the
/// supervisor for a while.
#define LOBBY_API_TIMEOUT 600

/// One supervisor request in the background: world.Export has no timeout of its own.
/// After this long (deciseconds) a request that never answered no longer blocks new ones.
#define LOBBY_STALLED_CAP 3000
/// Deciseconds the lobby keeps asking for a starting world's ticket: longer than the supervisor's
/// station_startup_timeout_seconds (constants.py, 600 s), so the supervisor's own outcome (ready or
/// a startup error) reaches the player instead of "taking longer than expected" (test_contracts).
#define LOBBY_JOIN_WAIT 6600

/datum/lobby_request
	var/url
	var/started
	var/done = FALSE
	var/list/response

/datum/lobby_request/proc/perform()
	response = world.Export(url)
	done = TRUE

/// world.Export(url) in the background: the request, to wait for with lobby_await().
/proc/lobby_export_start(url)
	var/datum/lobby_request/request = new
	request.url = url
	request.started = world.time
	spawn(0)
		request.perform()
	return request

/// Waits at most `timeout` deciseconds for a request: its response, or null (also when it is still
/// running; it then finishes in the background and its answer is dropped).
/proc/lobby_await(datum/lobby_request/request, timeout = LOBBY_API_TIMEOUT)
	var/deadline = world.time + timeout
	while(!request.done && world.time < deadline)
		sleep(1)
	return request.done ? request.response : null

/mob/lobby
	/// This player's request that timed out and still runs: until it finishes, no new one is started
	/// (the 5 s refresh would pile them up while the supervisor is stalled).
	var/datum/lobby_request/stalled_request

/mob/lobby/proc/api(action, list/payload)
	var/list/query = list("secret" = lobby_config["secret"], "actor" = ckey, "action" = action, "payload" = json_encode(payload || list()))
	var/list/response
	// A request that never comes back is given up after LOBBY_STALLED_CAP: the lobby asks anew.
	if(stalled_request && world.time - stalled_request.started > LOBBY_STALLED_CAP)
		stalled_request = null
	if(!stalled_request || stalled_request.done)
		var/datum/lobby_request/request = lobby_export_start("[lobby_config["api"]]/api?[list2params(query)]")
		response = lobby_await(request)
		stalled_request = request.done ? null : request
	if(!response || !response["CONTENT"])
		world.log << "Supervisor unavailable for [ckey] ([action])"
		return list("error" = "The world manager isn't responding. Try again in a moment.", "unavailable" = TRUE)
	var/list/result
	try
		result = json_decode(file2text(response["CONTENT"]))
	catch
		return list("error" = "The world manager sent an unexpected answer. Try again.")
	return result

/mob/lobby/proc/page_start()
	return "<!doctype html><html><head><meta charset='utf-8'><meta http-equiv='X-UA-Compatible' content='IE=edge'><style>[file2text('modular_babylon/lobby/style.css')]</style><script>[file2text('modular_babylon/lobby/loading.js')]</script><script>[file2text('modular_babylon/lobby/lobby.js')]</script></head><body onload='lobbyWindowReady(\"\ref[src]\", [poll_generation])'>"

/// A number for the page; anything else from the supervisor becomes 0.
/proc/lobby_number(value)
	return isnum(value) ? value : 0

/// "1 running world", "3 running worlds".
/proc/lobby_plural(value, noun)
	value = lobby_number(value)
	return "[value] [noun][value == 1 ? "" : "s"]"

/// JSON for a script: an inline <script> block or a value handed to a page function with
/// output(). json_encode leaves "<", ">" and "&" as they are, so a world name such as
/// "</script>" or "<!--<script>" would end (or comment out) the page's script and leave the
/// lobby blank for everyone. Here they, and the JavaScript line separators U+2028/U+2029,
/// become \uXXXX escapes, which JSON.parse and JavaScript read back unchanged.
/// Every JSON that reaches a script goes through this (guarded by test_lobby_script_json.py).
/proc/lobby_script_json(value)
	var/static/list/escapes
	if(!escapes)
		escapes = list("<" = "\\u003c", ">" = "\\u003e", "&" = "\\u0026")
		escapes[ascii2text(8232)] = "\\u2028"
		escapes[ascii2text(8233)] = "\\u2029"
	var/text = json_encode(value)
	for(var/character in escapes)
		text = replacetext(text, character, escapes[character])
	return text

/// Text with leading and trailing whitespace removed, as lobby.js trims it.
/proc/lobby_trim(text)
	var/static/regex/edges = regex(@"^\s+|\s+$", "g")
	return istext(text) ? edges.Replace(text, "") : text

/// A link parameter carrying a JSON payload, as lobby.js sends them.
/proc/lobby_payload(list/payload)
	return url_encode(json_encode(payload))

/mob/lobby/proc/loading_panel(world_name, stage)
	return "<div class='loading-shell'><section class='loading' role='status' aria-live='polite' aria-busy='true'><div class='spinner'></div><div class='brand'>BABYLON // WORLD MANAGEMENT</div><h1 id='loading-world'>[html_encode(world_name)]</h1><p id='loading-stage'>[html_encode(stage)]</p><small>Keep this client open while your request completes.</small><a id='handoff-return' class='button' style='display:none'>Return to lobby</a></section></div>"

/// Shown instead of the world list while the server restarts (or its supervisor is
/// unreachable). loading.js shows the same screen when the lobby connection itself is gone.
/proc/lobby_restart_panel(title, message)
	return "<div class='loading-shell'><section class='loading' role='status' aria-live='polite'><div class='spinner'></div><div class='brand'>BABYLON 13</div><h1>[html_encode(title)]</h1><p>[html_encode(message)]</p><p class='muted'>Saved worlds keep their progress; worlds marked Not saved start fresh. A restart usually takes a minute or two. Once the server is back, press Reconnect.</p><a class='button primary' href='byond://winset?command=.reconnect'>Reconnect</a></section></div>"

/mob/lobby/proc/show_loading(world_name, stage)
	if(client)
		src << output(list2params(list(world_name, stage)), "mainwindow.browser:showLobbyLoading")

/// The preview image of a catalog map, sent to the client once; null without one.
/mob/lobby/proc/map_preview(list/map)
	var/static/regex/safe_path = regex(@"^[A-Za-z0-9_][A-Za-z0-9_./-]*\.png$")
	var/static/regex/safe_id = regex(@"^[a-z][a-z0-9_]{0,63}$")
	var/path = map["preview"]
	var/id = map["id"]
	if(!istext(path) || !istext(id) || !safe_path.Find(path) || !safe_id.Find(id) || findtext(path, ".."))
		return null
	var/resource = "babylon_map_[id].png"
	if(!(resource in sent_previews))
		if(!fexists(path))
			return null
		src << browse_rsc(file(path), resource)
		sent_previews += resource
	return resource

/mob/lobby/proc/show_browser(complete = 0)
	var/revision = request_revision
	var/list/result = api("list")
	// An old poll must not overwrite a click, even if its action has finished.
	if(!client || busy || revision != request_revision)
		return
	var/content
	if(result["restarting"])
		content = lobby_restart_panel("The server is restarting", result["server_notice"] || "The server is restarting.")
	else if(result["unavailable"])
		content = lobby_restart_panel("The server is unavailable", "The lobby cannot reach its world manager right now, usually because the server is restarting.")
	if(content)
		render_page(content, revision, complete)
		return
	content = "<div class='brand'>BABYLON 13</div><div class='top'><h1>Your station, your next chapter.</h1><button type='button' class='button primary' onclick='return lobbyOpenCreate()'>+ New world</button></div><nav class='tabs' aria-label='World categories'>"
	var/list/tabs = list("active" = "Active worlds", "mine" = "My worlds", "shared" = "Shared with me", "all" = "Browse worlds", "tutorials" = "Tutorials")
	// Admins see how many tutorials wait for their review.
	var/pending_tutorials = lobby_number(result["pending_tutorials"])
	for(var/tab in tabs)
		var/selected = view_filter == tab
		var/tab_count = tab == "tutorials" && pending_tutorials ? " <span class='tab-count' title='Tutorials waiting for your review' aria-label='[pending_tutorials] tutorial[pending_tutorials == 1 ? "" : "s"] waiting for review'>[pending_tutorials]</span>" : ""
		content += "<a class='[selected ? "active" : ""]' aria-current='[selected ? "page" : "false"]' data-stage='[tab == "tutorials" ? "Loading tutorials..." : "Loading worlds..."]' onclick='return beginAction(this)' href='?src=\ref[src];action=filter;payload=[lobby_payload(list("filter" = tab))]'>[tabs[tab]][tab_count]</a>"
	content += "</nav><h2 class='page-heading'>[tabs[view_filter]]</h2>"
	var/list/descriptions = list("active" = "Worlds currently running, starting or stopping. Join an online world to continue building.", "mine" = "Worlds you own. Start an offline world, change its settings, or restore a saved checkpoint.", "shared" = "Worlds where you have membership. You can start these worlds even when the owner is away. On station maps the round itself waits for the owner.", "all" = "Worlds available to your account. Guests can join online worlds; owners, members and admins can start offline worlds.", "tutorials" = "Guided tutorials built by players. <b>Play</b> opens a private copy that disappears when you leave. <b>Copy to my worlds</b> makes a Creative world of your own to build on.")
	content += "<p class='muted'>[descriptions[view_filter]]</p>"
	if(result["admin"])
		content += "<p><span class='badge'>Server administrator</span> <small>Your account can see private worlds, bypass their admission restrictions and the per-owner world limits, and spectate worlds as an invisible ghost without a drone.</small></p>"
	if(result["server_notice"])
		content += "<p class='notice'[announce("server_notice", result["server_notice"], "alert")]><b>[html_encode(result["server_notice"])]</b></p>"
	content += discord_bar(result["discord"])
	if(notice)
		content += "<p class='notice'[announce("notice", notice, notice_alert ? "alert" : "status")]>[html_encode(notice)]</p>"
	var/list/state
	if(result["error"])
		content += "<p class='notice'[announce("list_error", result["error"], "alert")]>[html_encode(result["error"])]</p>"
	else
		cards = list()
		map_names = list()
		map_builds = list()
		var/list/maps = list()
		for(var/list/map in result["maps"])
			if(!istext(map["id"]))
				continue
			map_names[map["id"]] = "[map["name"]]"
			map_builds[map["id"]] = map["build"] == "station" ? "station" : "babylon"
			map["preview_url"] = map_preview(map)
			maps += list(map)
		var/rendered = ""
		var/visible = 0
		var/list/tutorial_state
		var/list/states = list("running" = "Online", "stopped" = "Offline", "starting" = "Starting", "stopping" = "Stopping", "error" = "Needs attention")
		for(var/list/card in result["worlds"])
			if(!istext(card["id"]))
				continue
			cards[card["id"]] = card
			if(view_filter == "tutorials")
				continue
			if(view_filter == "active" && card["state"] == "stopped")
				continue
			if(view_filter == "mine" && card["owner"] != ckey)
				continue
			if(view_filter == "shared" && card["role"] != "member")
				continue
			visible++
			rendered += world_card(card, states)
		if(view_filter == "tutorials")
			tutorial_state = tutorial_list()
			// lobby.js draws the tutorial cards from the page state into this placeholder.
			content += "<div id='lobby-tutorials'></div>"
		else if(!visible)
			content += "<div class='count'>Showing 0 worlds</div>"
			var/list/empty = list("active" = "No worlds are active. Open My worlds or Browse worlds to find a station to start.", "mine" = "You have no worlds yet.", "shared" = "No worlds have been shared with your account yet. Ask an owner to add you as a member.", "all" = "No worlds are available. Create one, or ask an owner for membership.")
			var/create_button = view_filter == "shared" ? "" : "<p><button type='button' class='button primary' onclick='return lobbyOpenCreate()'>+ Create your first world</button></p>"
			content += "<div class='empty'>[empty[view_filter]][create_button]</div>"
		else
			content += "<div class='count'>Showing [visible] world[visible == 1 ? "" : "s"]</div>[rendered]"
		var/list/limits = result["limits"]
		if(!islist(limits))
			limits = list()
		player_limit = lobby_number(limits["max_players_per_world"])
		var/expiry = result["delete_unused_worlds_after_days"]
		var/expiry_text = expiry ? "Unused stopped worlds are deleted after [lobby_number(expiry)] days." : "Automatic world expiry is disabled."
		content += "<footer class='footer'>Server limits: [lobby_plural(limits["max_running_worlds"], "running world")]; [lobby_plural(limits["max_players_per_world"], "player")] per world; per owner [lobby_plural(limits["max_worlds_per_player"], "saved world")], [lobby_plural(limits["max_total_worlds_per_player"], "world")] in total and [lobby_plural(limits["max_running_worlds_per_player"], "running world")].<br>Private worlds require membership. Your station continues from its last successful checkpoint; worlds marked Not saved start fresh every time.<br>[expiry_text]</footer>"
		// The dialogs (lobby.js) work from this; everything in it is escaped there.
		var/list/discord = islist(result["discord"]) ? result["discord"] : list()
		var/list/discord_state = list("link" = discord["link"] ? 1 : 0, "linked" = discord["linked"] ? 1 : 0, "name" = discord["name"], "require_create" = discord["require_create"] ? 1 : 0, "require_join" = discord["require_join"] ? 1 : 0)
		state = list("ref" = "\ref[src]", "ckey" = ckey, "admin" = result["admin"] ? 1 : 0, "worlds" = result["worlds"], "maps" = maps, "limits" = limits, "player_limit" = player_limit, "discord" = discord_state)
		if(tutorial_state)
			state["tutorials"] = tutorial_state["tutorials"]
			state["tutorials_error"] = tutorial_state["error"]
	render_page(content, revision, complete, state)

/// One world in the list. Everything from the supervisor is encoded for where it lands:
/// text and attributes with html_encode, link parameters with url_encode, numbers as numbers.
/mob/lobby/proc/world_card(list/card, list/states)
	var/static/list/access_labels = list("private" = "Private", "showcase" = "Showcase", "password" = "Password-protected", "public" = "Public")
	var/static/list/role_labels = list("owner" = "Owner", "admin" = "Administrator", "member" = "Member", "guest" = "Guest")
	var/id = html_encode(card["id"])
	var/world_name = html_encode(card["name"])
	var/manager = card["role"] == "owner" || card["role"] == "admin"
	var/state = card["state"]
	var/stopped = state == "stopped"
	var/changing = state == "starting" || state == "stopping"
	var/saved = !(isnum(card["persistent"]) && !card["persistent"])
	var/round_over = state == "stopping" && card["stop_reason"] == "round_ended"
	var/station = istext(card["map"]) && map_builds[card["map"]] == "station"
	var/map_name = istext(card["map"]) ? (map_names[card["map"]] || card["map"]) : "Babylon"
	var/badges = round_over ? "<span class='badge ended'>Round over</span>" : "<span class='badge [html_encode(state)]'>[states[state] || "Unknown"]</span>"
	var/list/flags = list()
	if(card["creative"])
		flags += "<span class='badge creative' title='Everyone in this world has the Creative panel.'>Creative</span>"
	if(!saved)
		flags += "<span class='badge unsaved' title='This world is not saved and starts fresh every time.'>Not saved</span>"
	if(card["kind"] && card["kind"] != "world")
		flags += "<span class='badge'>Tutorial run</span>"
	var/text = "<section class='card'><div class='card-head'><h2>[world_name]</h2><span class='badges'>[badges]</span></div>"
	text += "<div class='flags'><span class='badge map'>[html_encode(map_name)]</span>[jointext(flags, "")]</div>"
	if(card["description"])
		text += "<p>[html_encode(card["description"])]</p>"
	text += "<div class='meta'>Owner: [html_encode(card["owner"])] &nbsp; | &nbsp; Access: [html_encode(access_labels[card["visibility"]] || card["visibility"])] &nbsp; | &nbsp; [lobby_number(card["players"])]/[lobby_number(card["max_players"])] players online<br>Your role: <b>[html_encode(role_labels[card["role"]] || card["role"])]</b> &nbsp; | &nbsp; Last active: [html_encode(card["last_active"] || "Unknown")]"
	text += saved ? "<br>Last save: [html_encode(card["last_save"] || "None yet")]" : "<br>Not saved: starts fresh every time"
	text += "</div><div class='actions'>"
	if(round_over)
		text += "<span class='card-hint'>Round over: the world is shutting down. Start it again to play on.</span>"
	else if(state == "stopping")
		text += "<span class='card-hint'>Stopping... you can rejoin in a moment.</span>"
	else if(state == "starting")
		text += "<span class='card-hint'>Starting... you can join in a moment.</span>"
	else if(card["role"] != "guest" || !stopped)
		var/join_label = stopped ? "Start and join" : (card["visibility"] == "showcase" && card["role"] == "guest" ? "Visit showcase" : "Join world")
		var/needs_password = card["visibility"] == "password" && card["role"] == "guest"
		text += "<a class='button primary' data-id='[id]' data-password='[needs_password ? 1 : 0]' data-world='[world_name]' data-stage='Preparing your connection...' onclick='return lobbyJoin(this)' href='?src=\ref[src];action=join;payload=[lobby_payload(list("world" = card["id"]))]'>[join_label]</a>"
		// Admins can look around as an invisible ghost instead of leaving a drone behind.
		if(card["role"] == "admin")
			var/spectate_label = stopped ? "Start and spectate" : "Spectate"
			text += "<a class='button' data-id='[id]' data-password='0' data-spectate='1' data-world='[world_name]' data-stage='Preparing your connection...' onclick='return lobbyJoin(this)' href='?src=\ref[src];action=join;payload=[lobby_payload(list("world" = card["id"], "spectate" = 1))]'>[spectate_label]</a>"
		if(card["visibility"] == "showcase" && card["role"] == "guest")
			text += station ? "<small>Visible ghost visit: look around and chat only. Membership is required to play.</small>" : "<small>Visible ghost visit: explore and chat only. Membership is required to build.</small>"
	else
		text += "<small>An owner, member or admin must start this world.</small>"
	if(manager && (!card["kind"] || card["kind"] == "world"))
		text += "<button type='button' class='button' data-id='[id]' onclick='return lobbyOpenWorld(\"edit\", this)'>Settings</button>"
		text += "<button type='button' class='button' data-id='[id]' onclick='return lobbyOpenWorld(\"members\", this)'>Members</button>"
		if(stopped)
			if(saved)
				text += "<button type='button' class='button' data-id='[id]' onclick='return lobbyOpenWorld(\"checkpoints\", this)'>Checkpoints</button>"
			text += "<button type='button' class='button danger push' data-id='[id]' onclick='return lobbyOpenWorld(\"reset\", this)'>Reset</button>"
			text += "<button type='button' class='button danger' data-id='[id]' onclick='return lobbyOpenWorld(\"delete\", this)'>Delete world</button>"
		else if(!changing)
			text += "<button type='button' class='button danger push' data-id='[id]' onclick='return lobbyOpenWorld(\"stop\", this)'>[saved ? "Save and stop..." : "Stop world..."]</button>"
	// A tutorial run (or an edit world) can only be stopped; it is deleted once it has.
	else if(manager && !stopped && !changing)
		text += "<button type='button' class='button danger push' data-id='[id]' onclick='return lobbyOpenWorld(\"stop\", this)'>Stop tutorial...</button>"
	if(card["error"])
		text += "<p class='card-error'[announce("card:[id]", card["error"], "alert")]>[html_encode(card["error"])]</p>"
	return text + "</div></section>"

/mob/lobby/proc/render_page(content, revision, complete, list/state)
	// The dialog data changes the page even when the list looks the same.
	var/signature = "[content]\n[state ? json_encode(state) : ""]"
	var/list/data = list("html" = content, "view" = view_filter, "revision" = revision, "complete" = complete)
	if(state)
		data["state"] = state
	if(!browser_initialized)
		data["complete"] = 1
		var/shell = "[page_start()]<main id='browser-content'></main><div id='action-loading' style='display:none'>[loading_panel("Your world", "Working...")]</div><div id='connection-lost' style='display:none'>[lobby_restart_panel("Connection lost", "The connection to the server was lost, most likely because it is restarting.")]</div><div id='modal-root'></div><div id='toast-root' class='toasts' aria-live='polite'></div><script>renderLobby([lobby_script_json(json_encode(data))]);</script></body></html>"
		src << browse(shell, "window=mainwindow.browser")
		browser_initialized = 1
	else if(complete || signature != last_browser_content)
		src << output(list2params(list(lobby_script_json(data))), "mainwindow.browser:renderLobby")
	last_browser_content = signature

// --- Page requests ---------------------------------------------------------------------
// The page sends byond://?src=<ref>;action=<name>;payload=<urlencoded JSON>[;request=<n>].
// Nothing from it is trusted: every field is checked here, then again by the supervisor.

/// A request id from the page: a small positive number, or 0 for a plain link.
/proc/lobby_request_id(value)
	var/static/regex/digits = regex(@"^[1-9][0-9]{0,8}$")
	if(!istext(value) || !digits.Find(value))
		return 0
	return text2num(value)

/// The page's JSON payload as an object (assoc list); null when it is anything else.
/proc/lobby_decode_payload(value)
	if(isnull(value))
		return list()
	if(!istext(value) || length(value) > 8192)
		return null
	var/list/payload
	try
		payload = json_decode(value)
	catch
		return null
	if(!islist(payload))
		return null
	for(var/key in payload)
		if(!istext(key))
			return null
	return payload

/// Text from the page of at most max_length characters; null for anything else.
/proc/lobby_text(value, max_length)
	if(!istext(value) || length_char(value) > max_length)
		return null
	return value

/// A 0/1 flag from the page; null for anything else.
/proc/lobby_flag(value)
	if(isnum(value) && (value == 0 || value == 1))
		return value
	return null

/// "save-YYYYMMDD-HHMMSS-N", the checkpoint generation format; null for anything else.
/proc/lobby_generation(value)
	var/static/regex/generation = regex(@"^save-[0-9]{8}-[0-9]{6}-[0-9]{1,9}$")
	if(!istext(value) || !generation.Find(value))
		return null
	return value

/mob/lobby/Topic(href, list/params)
	if(usr != src)
		return
	// A load notification is independent of the page's busy actions and never refreshes it.
	// Ignore callbacks from the document of an earlier connection to this returning mob.
	if(params["action"] == "window_ready")
		if(client && browser_initialized && params["generation"] == "[poll_generation]")
			client.lobby_window_ready()
		return
	var/action = params["action"]
	if(!istext(action) || length(action) > 32)
		return
	var/request = lobby_request_id(params["request"])
	var/list/payload = lobby_decode_payload(params["payload"])
	if(isnull(payload))
		if(request)
			respond(request, list("error" = "The request could not be read. Please try again."))
		return
	run_action(action, payload, request)

/mob/lobby/proc/run_action(action, list/payload, request = 0)
	if(!client)
		return
	if(busy)
		if(request)
			respond(request, list("error" = "Another request is still running. Try again in a moment."))
		return
	busy = 1
	responded = 0
	request_revision++
	if(action == "join" && !request)
		var/list/card = istext(payload["world"]) ? cards[payload["world"]] : null
		show_loading(card ? card["name"] : "Your world", "Preparing your connection...")
		sleep(1)
	try
		handle_action(action, payload, request)
	catch(var/exception/error)
		world.log << "Lobby action [action] by [ckey] failed: [error] ([error.file]:[error.line])"
		respond(request, list("error" = "Request failed. Please try again."))
	// Every page request gets exactly one answer, so its dialog never stays busy.
	if(request && responded != request)
		respond(request, list("error" = "The request could not be completed. Please try again."))
	busy = 0
	if(client)
		show_browser(1)

/// Answers a page request (lobbyResult in lobby.js: errors stay in the open dialog).
/// Without a request (a plain link) the answer becomes the page notice.
/mob/lobby/proc/respond(request, list/data)
	if(!request)
		set_notice(data["error"] || data["notice"], !!data["error"])
		return
	if(responded == request)
		return
	responded = request
	data["request"] = request
	if(client)
		src << output(list2params(list(lobby_script_json(data))), "mainwindow.browser:lobbyResult")

/// Discord link state, requirements and the link/unlink/invite buttons.
/mob/lobby/proc/discord_bar(list/discord)
	if(!islist(discord) || !discord["link"])
		discord_invite = islist(discord) ? (discord["invite"] || "") : ""
		return discord_invite ? "<p class='muted'><a class='button' href='?src=\ref[src];action=discord_invite'>Join our Discord</a></p>" : ""
	discord_invite = discord["invite"] || ""
	var/list/required = list()
	if(discord["require_create"])
		required += "create"
	if(discord["require_join"])
		required += "join"
	var/requirement = length(required) ? "Required to [jointext(required, " and ")] worlds." : "Optional."
	var/invite = discord_invite ? "<a class='button' href='?src=\ref[src];action=discord_invite'>Open our Discord</a>" : ""
	if(discord["linked"])
		return "<div class='discord linked'><span><b>Discord:</b> linked as <b>[html_encode(discord["name"])]</b>.</span><span class='buttons'><button type='button' class='button' onclick='return lobbyOpenDiscordUnlink()'>Unlink</button>[invite]</span></div>"
	return "<div class='discord[length(required) ? " required" : ""]'><span><b>Discord:</b> not linked. [requirement]</span><span class='buttons'><button type='button' class='button primary' onclick='return lobbyOpenDiscordLink()'>Link Discord</button>[invite]</span></div>"

/// The create/edit fields of a payload, checked as the supervisor checks them.
/// Returns the clean payload for the supervisor, or an error text.
/mob/lobby/proc/world_settings(list/payload, creating)
	var/static/regex/visible = regex(@"\S")
	var/list/clean = list()
	var/name = lobby_text(payload["name"], 60)
	if(!name || !visible.Find(name))
		return "Give the world a name of 1 to 60 characters."
	var/description = isnull(payload["description"]) ? "" : lobby_text(payload["description"], 500)
	if(isnull(description))
		return "Keep the description under 500 characters."
	var/visibility = payload["visibility"]
	if(!istext(visibility) || !(visibility in list("private", "showcase", "password", "public")))
		return "Choose who can join."
	var/maximum = payload["max_players"]
	if(!isnum(maximum) || round(maximum) != maximum || maximum < 1 || (player_limit && maximum > player_limit))
		return "Choose between 1 and [player_limit] players."
	var/creative = lobby_flag(payload["creative"])
	var/persistent = lobby_flag(payload["persistent"])
	if(isnull(creative) || isnull(persistent))
		return "Choose whether the world is creative and persistent."
	clean["name"] = name
	clean["description"] = description
	clean["visibility"] = visibility
	clean["max_players"] = maximum
	clean["creative"] = creative
	clean["persistent"] = persistent
	if(visibility == "password")
		var/password = isnull(payload["password"]) ? "" : lobby_text(payload["password"], 128)
		if(isnull(password))
			return "Use a password of at most 128 characters."
		if(password)
			clean["password"] = password
		else if(creating)
			return "Choose a password for your guests."
	if(creating)
		var/map = payload["map"]
		if(!istext(map) || !(map in map_names))
			return "Choose a map from the list."
		clean["map"] = map
	return clean

/// The page notice; alert for a problem, so it is announced like the page's other errors.
/mob/lobby/proc/set_notice(text, alert = FALSE)
	notice = text || ""
	notice_alert = alert
	// A new notice is announced even when its text repeats the last one.
	announced -= "notice"

/// The role attribute of a live message the first time it is drawn with this text. The poll
/// replaces the whole page whenever anything on it changes, and a redrawn role='alert' can be
/// announced again; later redraws leave the role out, so a message is announced once.
/mob/lobby/proc/announce(key, text, role)
	if(announced[key] == text)
		return ""
	announced[key] = text
	return " role='[role]'"

/mob/lobby/proc/handle_action(action, list/payload, request)
	set_notice("")
	if(action == "filter")
		if(payload["filter"] in list("active", "mine", "shared", "all", "tutorials"))
			view_filter = payload["filter"]
		return
	if(action == "discord_invite")
		if(discord_invite)
			src << link(discord_invite)
		return
	if(action == "discord_link")
		var/list/code_result = api("discord_code")
		if(code_result["error"])
			respond(request, list("error" = code_result["error"]))
			return
		var/command = "/link code:[code_result["code"]]"
		world.log << "[ckey] requested a Discord link code"
		respond(request, list("ok" = 1, "command" = command, "invite" = discord_invite ? 1 : 0, "notice" = "Type [command] in our Discord within 10 minutes."))
		return
	if(action == "discord_unlink")
		if(payload["confirm"] != 1)
			respond(request, list("error" = "Confirm unlinking first."))
			return
		var/list/unlink_result = api("discord_unlink")
		respond(request, unlink_result["error"] ? list("error" = unlink_result["error"]) : list("ok" = 1, "notice" = "Your Discord account was unlinked."))
		return
	if(action == "create")
		var/settings = world_settings(payload, TRUE)
		if(!islist(settings))
			respond(request, list("error" = settings))
			return
		var/list/created = api("create", settings)
		if(created["error"] || !istext(created["id"]))
			respond(request, list("error" = created["error"] || "The world could not be created."))
			return
		view_filter = "mine"
		var/list/clean = settings
		if(payload["join"] != 1)
			respond(request, list("ok" = 1, "notice" = "[clean["name"]] was created."))
			return
		respond(request, list("ok" = 1))
		show_loading(clean["name"], "Starting your new world...")
		join_world(created["id"], clean["name"], list("world" = created["id"]))
		return
	if(action in list("tutorial_play", "tutorial_copy", "tutorial_edit", "tutorial_accept", "tutorial_reject", "tutorial_delete"))
		tutorial_action(action, payload, request)
		return
	var/static/regex/world_id = regex(@"^[0-9a-f]{32}$")
	var/id = payload["world"]
	var/list/card = istext(id) && world_id.Find(id) ? cards[id] : null
	if(!card)
		respond(request, list("error" = "This world is no longer available. The list has been refreshed."))
		return
	if(action == "join")
		var/list/join = list("world" = id)
		if(payload["spectate"] == 1)
			join["spectate"] = 1
		if(!isnull(payload["password"]))
			var/password = lobby_text(payload["password"], 128)
			if(isnull(password))
				respond(request, list("error" = "Use a password of at most 128 characters."))
				return
			join["password"] = password
		// A tutorial run joined from its card (or rejoined after a hidden-window bounce) keeps the
		// tutorial wording in the notices that send the player back.
		var/static/list/retry_by_kind = list("tutorial" = "play", "tutorial_edit" = "edit")
		var/tutorial_retry = istext(card["kind"]) ? retry_by_kind[card["kind"]] : null
		join_world(id, card["name"], join, request, retry = tutorial_retry || "join")
		return
	if(card["role"] != "owner" && card["role"] != "admin")
		respond(request, list("error" = "Only the owner or a server administrator can do that."))
		return
	if(action == "edit")
		var/settings = world_settings(payload, FALSE)
		if(!islist(settings))
			respond(request, list("error" = settings))
			return
		var/list/clean = settings
		clean["world"] = id
		var/list/result = api("edit", clean)
		respond(request, result["error"] ? list("error" = result["error"]) : list("ok" = 1, "notice" = "Settings of [clean["name"]] saved."))
	else if(action == "member")
		var/static/regex/account = regex(@"^[A-Za-z0-9 ._@-]{1,64}$")
		var/who = payload["member"]
		var/role = payload["role"]
		if(!istext(who) || !account.Find(who))
			respond(request, list("error" = "Enter a BYOND account name."))
			return
		if(!(role in list("member", "remove")))
			respond(request, list("error" = "Choose whether to add or remove the account."))
			return
		var/list/result = api("member", list("world" = id, "member" = who, "role" = role))
		respond(request, result["error"] ? list("error" = result["error"]) : list("ok" = 1, "notice" = role == "member" ? "[who] is now a member of [card["name"]]." : "[who] no longer has access to [card["name"]]."))
	else if(action == "checkpoints")
		var/list/history = api("checkpoints", list("world" = id))
		if(history["error"])
			respond(request, list("error" = history["error"]))
			return
		var/list/points = list()
		for(var/list/point in history["checkpoints"])
			if(lobby_generation(point["generation"]))
				points += list(list("generation" = point["generation"], "current" = point["current"] ? 1 : 0, "objects" = lobby_number(point["objects"])))
		respond(request, list("ok" = 1, "checkpoints" = points, "latest" = lobby_generation(history["latest"])))
	else if(action == "rollback")
		var/generation = lobby_generation(payload["generation"])
		var/latest = lobby_generation(payload["expected_latest"])
		if(!generation || !latest)
			respond(request, list("error" = "Choose a checkpoint from the list."))
			return
		if(payload["confirm"] != 1)
			respond(request, list("error" = "Confirm that newer checkpoints will be deleted."))
			return
		var/list/result = api("rollback", list("world" = id, "generation" = generation, "expected_latest" = latest, "confirm_delete_newer" = 1))
		respond(request, result["error"] ? list("error" = result["error"]) : list("ok" = 1, "notice" = "Checkpoint restored. Newer checkpoints deleted: [lobby_number(result["deleted"])]. Join to continue from this point."))
	else if(action == "delete" || action == "reset")
		// The page asks for the world's name before it sends these; checked here as well.
		if(payload["confirm"] != 1 || !istext(payload["confirm_name"]) || lobby_trim(payload["confirm_name"]) != lobby_trim(card["name"]))
			respond(request, list("error" = "Type the world's name to confirm."))
			return
		if(action == "delete")
			var/list/result = api("delete", list("world" = id, "confirm_delete" = 1))
			respond(request, result["error"] ? list("error" = result["error"]) : list("ok" = 1, "notice" = "[card["name"]] was permanently deleted."))
		else
			var/list/result = api("reset", list("world" = id, "confirm" = 1))
			respond(request, result["error"] ? list("error" = result["error"]) : list("ok" = 1, "notice" = "[card["name"]] was reset. Its next start begins fresh."))
	else if(action == "stop")
		if(payload["confirm"] != 1)
			respond(request, list("error" = "Confirm the stop first."))
			return
		var/saved = !(isnum(card["persistent"]) && !card["persistent"])
		var/list/result = api("stop", list("world" = id))
		if(result["error"])
			respond(request, list("error" = result["error"]))
			return
		respond(request, list("ok" = 1))
		show_loading(card["name"], saved ? "Saving the final checkpoint and stopping the world..." : "Stopping the world...")
		var/deadline = world.time + 1800
		while(client && world.time < deadline)
			var/list/status = api("list")
			if(status["error"])
				set_notice(status["error"], TRUE)
				return
			var/list/current
			for(var/list/item in status["worlds"])
				if(item["id"] == id)
					current = item
					break
			if(!current || current["state"] == "stopped")
				set_notice(saved ? "World saved and stopped." : "World stopped.")
				return
			if(current["error"] || current["state"] == "error")
				set_notice(current["error"] || "The world could not stop. Check its status before trying again.", TRUE)
				return
			sleep(10)
		set_notice("Shutdown is still in progress. Check the world status before joining again.", TRUE)

// --- Tutorials ------------------------------------------------------------------------
// The Tutorials tab: lobby.js draws the cards and dialogs from state["tutorials"]; the actions
// come back here and go to the supervisor, which checks every permission again.

/// One tutorial from the supervisor with only the fields the page uses; null if it is malformed.
/proc/lobby_tutorial_item(list/item)
	var/static/regex/tutorial_id = regex(@"^[A-Za-z0-9_-]{1,64}$")
	if(!islist(item) || !istext(item["id"]) || !tutorial_id.Find(item["id"]) || !(item["status"] in list("pending", "published")))
		return null
	var/list/clean = list("id" = item["id"], "status" = item["status"], "created" = lobby_number(item["created"]))
	for(var/key in list("title", "description", "author", "map", "map_name"))
		clean[key] = istext(item[key]) ? item[key] : ""
	// The state of the player's own run of it, and of an admin edit session.
	for(var/key in list("playing", "editing"))
		clean[key] = (item[key] in list("starting", "running", "stopping", "error")) ? item[key] : null
	// The tutorial a pending one was copied from (admins only): the card's "Based on" line.
	var/list/based_on = item["based_on"]
	if(islist(based_on) && istext(based_on["title"]) && istext(based_on["author"]))
		clean["based_on"] = list("title" = based_on["title"], "author" = based_on["author"])
	return clean

/// The tutorials for the page: list("tutorials" = items) or list("error" = text).
/mob/lobby/proc/tutorial_list()
	var/list/result = api("tutorials")
	tutorial_cards = list()
	if(result["error"] || !islist(result["tutorials"]))
		if(result["error"])
			world.log << "Listing tutorials for [ckey] failed: [result["error"]]"
		return list("tutorials" = list(), "error" = "The tutorials could not be loaded. Please try again in a moment.")
	var/list/items = list()
	for(var/list/item in result["tutorials"])
		var/list/clean = lobby_tutorial_item(item)
		if(clean)
			tutorial_cards[clean["id"]] = clean
			items += list(clean)
	return list("tutorials" = items)

/mob/lobby/proc/tutorial_action(action, list/payload, request)
	var/id = payload["tutorial"]
	var/list/tutorial = istext(id) ? tutorial_cards[id] : null
	if(!tutorial)
		respond(request, list("error" = "This tutorial is no longer available. The list has been refreshed."))
		return
	var/title = tutorial["title"]
	// Copying and the review steps are confirmed in a dialog first; checked here as well.
	if(action != "tutorial_play" && action != "tutorial_edit" && payload["confirm"] != 1)
		respond(request, list("error" = "Confirm this first."))
		return
	var/list/result = api(action, list("tutorial" = id, "confirm" = 1))
	if(result["error"])
		respond(request, list("error" = result["error"]))
		return
	if(action == "tutorial_play" || action == "tutorial_edit")
		var/static/regex/valid_world = regex(@"^[0-9a-f]{32}$")
		var/world_id = result["world"]
		if(!istext(world_id) || !valid_world.Find(world_id))
			respond(request, list("error" = "The tutorial could not be started. Please try again."))
			return
		respond(request, list("ok" = 1))
		var/world_name = istext(result["name"]) ? result["name"] : title
		var/stage = action == "tutorial_edit" ? "Starting the edit world from the pending copy..." : "Preparing your tutorial..."
		show_loading(world_name, stage)
		join_world(world_id, world_name, list("world" = world_id), 0, stage, action == "tutorial_edit" ? "edit" : "play")
		return
	var/list/notices = list(
		"tutorial_copy" = "[title] was copied to My worlds. Start it there to keep building.",
		"tutorial_accept" = "[title] is published. Every player can now play it.",
		"tutorial_reject" = "[title] was rejected and deleted.",
		"tutorial_delete" = "[title] was deleted.",
	)
	if(action == "tutorial_copy")
		view_filter = "mine"
	respond(request, list("ok" = 1, "notice" = notices[action]))

/// Asks the supervisor for a ticket until the world runs, then sends the player there.
/// A dialog's request is answered after the first reply; later problems become the page notice.
/// A tutorial passes its own loading stage, and how it is tried again (retry, see lobby_retry_notice).
/mob/lobby/proc/join_world(id, world_name, list/join, request = 0, stage = "Starting world and restoring its checkpoint...", retry = "join")
	var/deadline = world.time + LOBBY_JOIN_WAIT
	while(client && world.time < deadline)
		var/list/result = api("join", join)
		if(result["error"])
			respond(request, list("error" = result["error"]))
			return
		if(request)
			respond(request, list("ok" = 1))
			request = 0
		if(result["address"])
			// BYOND reports the server the client reached, even behind Docker/NAT. Never use
			// client.address here: that is the player's machine. Tickets stay server-to-client.
			var/endpoint = winget(client, null, "url")
			if(!client)
				return
			var/address = babylon_connection_address(result["address"], endpoint)
			if(!address)
				set_notice("The world's connection address is unavailable. Ask the host to set BABYLON_PUBLIC_HOST (public_host for a native cluster) to a reachable server address.", TRUE)
				return
			var/lobby = babylon_connection_address(lobby_config["address"] || "byond://[endpoint]", endpoint)
			src << output(list2params(list(world_name, lobby)), "mainwindow.browser:showLobbyHandoff")
			world.log << "[ckey] offered connection to world [world_name] ([id]) at [copytext(address, 1, findtext(address, "?"))]"
			last_retry = retry
			src << link(address)
			set_notice(lobby_retry_notice("offered", retry))
			return
		show_loading(world_name, stage)
		sleep(20)
	set_notice(lobby_retry_notice("timeout", retry), TRUE)

/// A notice that sends the player back to a world, worded for the button that does it: Join on a
/// world card, Rejoin (or Play) on a tutorial card, Edit on a pending tutorial.
/// reason: "admission" (the world took too long to let them in), "offered" or "timeout".
/// retry: "join", "play" or "edit" (anything else gets a neutral wording).
/proc/lobby_retry_notice(reason, retry)
	var/static/list/how = list(
		"join" = "press Join",
		"play" = "open Tutorials and press Rejoin (or Play, if it has ended)",
		"edit" = "open Tutorials and press Edit on the pending tutorial",
	)
	// A fresh mob (the lobby restarted meanwhile) does not know which button it was.
	var/action = istext(retry) ? how[retry] : null
	if(!action)
		action = "go back to the world or tutorial you chose"
	var/sentence = "[uppertext(copytext(action, 1, 2))][copytext(action, 2)]"
	switch(reason)
		if("admission")
			return "The world took too long to let you in. [sentence] to try again."
		if("offered")
			return "Connection offered. If you cancelled it, [action] to try again."
	if(retry == "join")
		return "Startup is taking longer than expected. Check the world status and try Join again."
	return "Startup is taking longer than expected. [sentence] to try again."

/mob/lobby/verb/open_lobby()
	set name = "Open Babylon lobby"
	show_browser(1)
