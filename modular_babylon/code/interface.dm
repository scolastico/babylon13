// Babylon's game window: a smaller top bar, the world's name as the station's, no round ID,
// and no verbs for systems Babylon does not have (antags, OPFOR, round end, votes, jobs ...).

/client
	/// Startup window writes belong to this connection, never a later resize or mob Login.
	var/babylon_window_started = FALSE
	/// Resources load on demand instead of preloading the whole .rsc (over 300 MB) at login.
	/// DreamSeeker keeps its "Your game will begin shortly" splash up until a preload finishes,
	/// so the first join after every new build sat behind it for minutes (and the window
	/// watchdog below showed the game with the splash still open). Upstream sets PRELOAD_RSC 1
	/// in _compile_options.dm; its external-URL alternative needs a download server per build.
	preload_rsc = 0

/client/New(TopicData)
	. = ..()
	if(!src)
		return
	babylon_setup_top_bar()
	remove_verb(src, list(
		/client/verb/check_antag_tickets,
		/client/verb/antag_tickets_info,
		/client/verb/show_character_directory,
		/client/verb/map_vote_tally_count,
		/client/verb/linkforumaccount,
		/client/verb/verify_in_discord,
		/client/verb/notify_restart,
		/client/verb/go2relay,
		/client/verb/policy,
		/client/verb/checkachievements,
		/client/proc/show_previous_roundend_report,
		/client/proc/show_servers_last_roundend_report,
	))
	// Antag and security OOC channels; admins keep them.
	if(!holder)
		remove_verb(src, list(/client/verb/aooc, /client/verb/sooc))
	// The outermost /client/New override: everything above has returned. A stuck join without
	// this line means New() never returned, which keeps DreamSeeker on its start splash.
	log_world("Babylon: [key] finished connecting ([mob?.type]).")
	babylon_watch_game_window()

/// Some joins stay on DreamSeeker's "Your game will begin shortly" splash although the world
/// is done: after BYOND's Members-ad countdown, DreamSeeker's handover from the lobby leaves
/// the game window hidden and the splash open. A second join right after works, so the first
/// time it happens the player is sent back to the lobby, which joins this world again at once
/// (babylon_rejoin). If the window is hidden again, it is shown after 10 seconds instead.
/client/proc/babylon_watch_game_window()
	set waitfor = FALSE
	var/started = world.time
	for(var/attempt in 1 to 60)
		sleep(1 SECONDS)
		if(!src)
			return
		if(winget(src, "mainwindow", "is-visible") == "true")
			if(attempt > 2)
				log_world("Babylon: [key]'s game window appeared after [DisplayTimeText(world.time - started)].")
			babylon_game_window_shown()
			return
		if(attempt == 5 && babylon_rejoin_once())
			return
		if(attempt == 10)
			log_world("Babylon: [key]'s game window is still hidden after 10 seconds; showing it.")
			winset(src, "mainwindow", "is-visible=true")
	log_world("Babylon: [key]'s game window never appeared within a minute (mob [mob?.type]).")

/// Sends the client through the lobby back into this world, once per player and 10 minutes.
/// Returns FALSE when it was tried already (or there is no lobby): then the window is forced.
/client/proc/babylon_rejoin_once()
	var/static/list/tried = list()
	var/lobby = babylon_lobby_link()
	var/world_id = world.params["babylon-world"]
	if(!lobby || !world_id || (tried[ckey] && world.time < tried[ckey] + 10 MINUTES))
		return FALSE
	tried[ckey] = world.time
	log_world("Babylon: [key]'s game window is still hidden after 5 seconds; rejoining through the lobby.")
	var/list/query = list("babylon_rejoin" = world_id)
	if(babylon_admin_spectator)
		query["spectate"] = "1"
	src << link("[lobby][findtext(lobby, "?") ? "&" : "?"][list2params(query)]")
	return TRUE

/// Runs once the game window is visible. Coming from the lobby, the window opens at the skin's
/// small default size and the viewport was fitted to that: maximized, the chat panel took half
/// the screen and the map sat between black bars. Maximizes the window (not fullscreen) and
/// fits the viewport again whenever the window's size changes. Window writes wait until the
/// window is shown, so they cannot interfere with DreamSeeker's start splash.
/client/proc/babylon_game_window_shown()
	if(babylon_window_started)
		return
	babylon_window_started = TRUE
	var/list/settings = list("on-size=babylon-window-resized")
	if(!prefs?.read_preference(/datum/preference/toggle/fullscreen_mode))
		settings += "is-maximized=true"
	winset(src, "mainwindow", jointext(settings, ";"))
	babylon_window_resized()
	// Target the top-level window, not the map/chat control. Windows may refuse activation;
	// consuming the guard first ensures we never retry and steal focus from a later action.
	winset(src, "mainwindow", "focus=true")

/// The game window's on-size command. Resizing sends it many times; the viewport is fitted
/// once the size has settled (and only for players with auto-fit enabled, upstream's default).
/client/verb/babylon_window_resized()
	set name = "babylon-window-resized"
	set hidden = TRUE
	babylon_layout_top_bar()
	addtimer(CALLBACK(src, PROC_REF(attempt_auto_fit_viewport)), 0.5 SECONDS, TIMER_UNIQUE | TIMER_OVERRIDE | TIMER_CLIENT_TIME)

/// Four controls share the current pane width. Reusing upstream's seven slots leaves
/// hidden gaps and compresses the remaining buttons when the pane narrows.
/client/proc/babylon_setup_top_bar()
	set waitfor = FALSE
	winset(src, null, "infobuttons.hotkeys.is-visible=false;infobuttons.relays.is-visible=false;infobuttons.wiki.is-visible=false")
	winset(src, "infobuttons", list("on-size" = "babylon-top-bar-resized"))
	babylon_layout_top_bar()
	// A separate write keeps an unsupported icon from undoing the layout.
	var/static/window_icon = 'modular_babylon/icons/babylon13_64.png'
	winset(src, "mainwindow", "icon=\ref[window_icon]")

/// Use real client pixels, including display scaling. Re-measure after native resizing;
/// fixed anchors avoid applying the old seven-column offsets a second time.
/client/verb/babylon_layout_top_bar()
	set name = "babylon-top-bar-resized"
	set hidden = TRUE
	set waitfor = FALSE
	var/list/dimensions = splittext(winget(src, "infobuttons", "size"), "x")
	if(!src || length(dimensions) != 2)
		return
	var/pane_width = text2num(dimensions[1])
	var/pane_height = text2num(dimensions[2])
	if(pane_width <= 13 || pane_height <= 4)
		return
	var/list/buttons = list("options", "settings", "fullscreen-toggle", "reconnect")
	var/available_width = pane_width - 13 // two 2px margins and three 3px gaps
	for(var/index in 1 to length(buttons))
		var/left = 2 + round((index - 1) * available_width / 4) + (index - 1) * 3
		var/button_width = round(index * available_width / 4) - round((index - 1) * available_width / 4)
		winset(src, "infobuttons.[buttons[index]]", list(
			"anchor1" = "0,0",
			"anchor2" = "0,0",
			"pos" = "[left],2",
			"size" = "[button_width]x[pane_height - 4]",
			"font-size" = min(10, max(6, round(button_width / 8))),
		))

/mob
	/// Babylon: the mob's name without its player's key, so the key is only ever added once.
	var/babylon_base_name

/// Drones, ghosts and showcase visitors show who controls them: "derelict drone (611) (Key)".
/// Names that already contain the key (ghosts named after their player) stay as they are.
/mob/proc/babylon_show_player_key()
	if(!world.params["babylon-world"] || !key)
		return
	if(!istype(src, /mob/living/basic/drone) && !isobserver(src))
		return
	var/suffix = " ([key])"
	if(!babylon_base_name)
		babylon_base_name = name
		// A name restored from a save may already end with this player's key.
		var/cut = length(name) - length(suffix)
		if(cut > 0 && copytext(name, cut + 1) == suffix)
			babylon_base_name = copytext(name, 1, cut + 1)
	var/shown = findtext(babylon_base_name, key) ? babylon_base_name : "[babylon_base_name][suffix]"
	if(name == shown)
		return
	fully_replace_character_name(real_name, shown)
	name = shown

/mob/Login()
	. = ..()
	babylon_show_player_key()
	remove_verb(src, list(
		/mob/verb/opposing_force,
		/mob/verb/request_internet_sound,
		/mob/verb/abandon_mob,
		/mob/verb/vote,
		/mob/verb/adjust_degradation,
		/mob/verb/refresh_death_consequences,
		/mob/proc/view_exploitables_verb,
		/mob/living/verb/reflexes_verb,
		/mob/dead/observer/verb/join_soulcatcher,
	))

/// The world's name (from the lobby) is the station's name. It is player-written and
/// station_name() lands in chat HTML across the code base, so markup characters are dropped.
/proc/babylon_apply_world_name()
	var/raw = world.params["babylon-name"]
	if(!istext(raw))
		return
	var/static/regex/markup = regex("\[<>&\"\]", "g")
	var/clean = trim(markup.Replace(raw, ""))
	if(length(clean))
		set_station_name(copytext_char(clean, 1, 61))

/// The status tab without the round ID; Babylon worlds have no rounds.
/datum/controller/subsystem/statpanels/set_status_tab(client/target)
	if(!global_data)
		return
	var/list/shown = list()
	for(var/entry in global_data)
		if(istext(entry) && findtext(entry, "Round ID:") == 1)
			continue
		shown += list(entry)
	target.stat_panel.send_message("update_stat", list(
		"global_data" = shown,
		"other_str" = target.mob?.get_status_tab_items(),
	))

/// The image has no .git, so rust-g returns "failed to open repository" text for every git
/// lookup. The revision comes from the image instead (BABYLON_COMMIT and friends, set by CI),
/// and anything that is not a commit hash is dropped rather than shown as one.
/datum/getrev/New()
	..()
	// Not static: this datum is created during global init, before static vars are set up.
	var/regex/hash = regex(@"^[0-9a-f]{7,40}$")
	var/build_commit = world.GetConfig("env", "BABYLON_COMMIT")
	if(istext(build_commit) && hash.Find(build_commit))
		commit = build_commit
		originmastercommit = build_commit
		date = world.GetConfig("env", "BABYLON_COMMIT_DATE")
	if(!istext(commit) || !hash.Find(commit))
		commit = null
	if(!istext(originmastercommit) || !hash.Find(originmastercommit))
		originmastercommit = null
	if(!commit && !originmastercommit)
		date = null

/// The repository players can read the code at: the build's, or the configured GitHub URL.
/proc/babylon_repository_url()
	var/repository = world.GetConfig("env", "BABYLON_REPOSITORY")
	if(istext(repository) && findtext(repository, "https://") == 1)
		return repository
	return CONFIG_GET(string/githuburl)

/// Babylon's revision info: BYOND version, repository, commit and build date. No round ID or
/// antagonist settings, which Babylon does not have.
/client/__gvb_showrevinfo(list/structured_args)
	var/list/msg = list()
	msg += "<b>BYOND Version:</b> [world.byond_version].[world.byond_build]"
	if(DM_VERSION != world.byond_version || DM_BUILD != world.byond_build)
		msg += "<b>Compiled with BYOND Version:</b> [DM_VERSION].[DM_BUILD]"
	var/repository = babylon_repository_url()
	if(repository)
		msg += "<b>Repository:</b> <a href=\"[html_encode(repository)]\">[html_encode(repository)]</a>"
	var/datum/getrev/revdata = GLOB.revdata
	if(revdata?.commit)
		var/short = copytext(revdata.commit, 1, 12)
		msg += "<b>Commit:</b> [repository ? "<a href=\"[html_encode(repository)]/commit/[revdata.commit]\">[short]</a>" : short]"
		if(revdata.date)
			msg += "<b>Built from a commit of:</b> [html_encode(revdata.date)]"
	else
		msg += "No commit information (a local build)."
	to_chat(src, fieldset_block("Server Revision Info", span_infoplain(jointext(msg, "<br>")), "boxed_message"), type = MESSAGE_TYPE_INFO)

/// Babylon has no database. Without one every query fails, and warn_execute() told the player
/// "A SQL error occurred" for queries like the last-seen lookup run at every login.
/datum/db_query/warn_execute(async = TRUE)
	if(CONFIG_GET(flag/sql_enabled))
		return ..()
	return Execute(async, log_error = FALSE)
