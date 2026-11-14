// Tutorial submission and save-back tests (tutorial/submit.dm; services/supervisor/smoke_station.py).

/// Answers the supervisor requests itself and records them. It reads each snapshot before it is
/// deleted, as the supervisor would copy it.
/datum/babylon_tutorial_submissions/test_fake
	/// action -> the answer to give
	var/list/answers = list()
	/// Every request, in order (copies of the queries).
	var/list/queries = list()
	/// generation -> its state.json, decoded, as it was when the supervisor was asked
	var/list/snapshots = list()

/datum/babylon_tutorial_submissions/test_fake/request(list/query, timeout, datum/callback/on_answer)
	queries += list(query.Copy())
	var/generation = query["generation"]
	if(generation)
		var/path = "data/babylon/saves/[generation]/state.json"
		snapshots[generation] = fexists(path) ? json_decode(file2text(path)) : null
	var/list/answer = answers[query["action"]]
	on_answer?.Invoke(answer)
	return answer || list("ok" = FALSE, "error" = "The server could not be reached")

/// Swaps the fake in; returns the real one to put back.
/proc/babylon_tutorial_test_fake_submissions(datum/babylon_tutorial_submissions/test_fake/fake)
	var/datum/babylon_tutorial_submissions/real = GLOB.babylon_tutorial_submissions
	GLOB.babylon_tutorial_submissions = fake
	return real

/// Who may submit or save back, and why not (no snapshot is taken for a refused submission).
/datum/babylon_save/proc/test_tutorial_submit_refusals()
	var/list/result = list()
	var/datum/babylon_world/flags = GLOB.babylon_world
	var/list/was = list(flags.build, flags.creative, flags.kind, flags.owner_ckey)
	var/datum/babylon_tutorial_submissions/test_fake/fake = new
	var/datum/babylon_tutorial_submissions/real = babylon_tutorial_test_fake_submissions(fake)
	var/list/made = list()
	// The world may hold a start marker from another test: hidden for these checks.
	var/obj/babylon_tutorial/existing = babylon_tutorial_find("start")
	if(existing)
		GLOB.babylon_tutorial_objects -= existing
	try
		flags.build = "station"
		flags.creative = TRUE
		flags.kind = "world"
		flags.owner_ckey = "tutorialowner"
		result["no_start_refused"] = babylon_tutorial_submit_refusal("tutorialowner") == "no_start"
		var/saves_before = save_count
		fake.answers["tutorial_submit_check"] = list("ok" = TRUE, "wait_seconds" = 0)
		fake.begin("tutorialowner")
		var/list/refused = fake.submit("tutorialowner", "Title", "")
		result["no_start_submit_refused"] = !refused["ok"] && findtext(refused["text"], "start marker")
		result["no_start_no_save"] = save_count == saves_before && !length(fake.queries) && !fake.busy_ckey
		babylon_tutorial_test_place(/obj/babylon_tutorial/marker, tutorial_test_base(9), "start", list(), made)
		result["owner_may_submit"] = isnull(babylon_tutorial_submit_refusal("tutorialowner"))
		result["others_refused"] = babylon_tutorial_submit_refusal("someoneelse") == "not_owner" && babylon_tutorial_submit_refusal(null) == "not_owner"
		flags.creative = FALSE
		result["not_creative_refused"] = babylon_tutorial_submit_refusal("tutorialowner") == "not_capable"
		flags.creative = TRUE
		flags.build = "babylon"
		result["babylon_build_refused"] = babylon_tutorial_submit_refusal("tutorialowner") == "not_capable"
		flags.build = "station"
		flags.kind = "tutorial"
		result["tutorial_run_refused"] = babylon_tutorial_submit_refusal("tutorialowner") == "not_capable"
		flags.kind = "tutorial_edit"
		result["edit_world_cannot_submit"] = babylon_tutorial_submit_refusal("tutorialowner") == "not_capable"
		result["edit_world_admin_may_save_back"] = isnull(babylon_tutorial_save_back_refusal(TRUE))
		result["edit_world_player_refused"] = babylon_tutorial_save_back_refusal(FALSE) == "not_admin"
		flags.kind = "world"
		result["save_back_only_in_edit_world"] = babylon_tutorial_save_back_refusal(TRUE) == "not_edit_world"
		// One snapshot at a time: a second request meanwhile is refused (the panel ignores it).
		result["first_begins"] = fake.begin("tutorialowner")
		result["second_refused"] = !fake.begin("other") && babylon_tutorial_submit_refusal("tutorialowner") == "busy"
		fake.busy_ckey = null
		var/datum/babylon_creative_panel/panel = new("tutorialowner")
		panel.tutorial_running = "submitting"
		var/mob/living/carbon/human/clicker = new(tutorial_test_base(9))
		made += clicker
		result["double_click_ignored"] = !panel.extension_action(clicker, "tutorial_submit", list("title" = "Again")) && !fake.busy_ckey && !length(fake.queries)
		qdel(panel)
		var/crlf = "[ascii2text(13)]\n"
		result["clean_title"] = babylon_tutorial_clean_text("  A\tB[crlf]C  ") == "A B C" && babylon_tutorial_clean_text("A[crlf]B", TRUE) == "A\nB"
		result["wait_text"] = babylon_tutorial_wait_text(240) == "4 min" && babylon_tutorial_wait_text(30) == "30 s" && babylon_tutorial_wait_text(3900) == "1 h 5 min"
	catch(var/exception/error)
		result["error_[error]"] = FALSE
	flags.build = was[1]
	flags.creative = was[2]
	flags.kind = was[3]
	flags.owner_ckey = was[4]
	GLOB.babylon_tutorial_submissions = real
	babylon_tutorial_test_cleanup(made)
	if(existing)
		GLOB.babylon_tutorial_objects += existing
	return result

/// The forced tutorial snapshot (fake supervisor): in a non-persistent world it leaves latest.json
/// and the world's checkpoint alone, it has no characters, the requests have the supervisor's shape
/// and the snapshot is deleted once answered. Then the same for a save back.
/datum/babylon_save/proc/test_tutorial_snapshot()
	var/list/result = list()
	var/datum/babylon_world/flags = GLOB.babylon_world
	var/list/was = list(flags.build, flags.creative, flags.kind, flags.owner_ckey, flags.persistent)
	var/datum/babylon_tutorial_submissions/test_fake/fake = new
	var/datum/babylon_tutorial_submissions/real = babylon_tutorial_test_fake_submissions(fake)
	var/list/made = list()
	try
		flags.build = "station"
		flags.creative = TRUE
		flags.kind = "world"
		flags.owner_ckey = "tutorialowner"
		flags.persistent = FALSE
		result["characters_saved_normally"] = babylon_world_saves_characters()
		taking_tutorial_snapshot = TRUE
		result["no_characters_while_snapshotting"] = !babylon_world_saves_characters()
		taking_tutorial_snapshot = FALSE
		if(!babylon_tutorial_marker_turf("start"))
			babylon_tutorial_test_place(/obj/babylon_tutorial/marker, tutorial_test_base(9), "start", list(), made)
		var/latest_before = fexists("data/babylon/saves/latest.json") ? file2text("data/babylon/saves/latest.json") : null
		var/last_save_before = last_save
		fake.answers["tutorial_submit_check"] = list("ok" = TRUE, "wait_seconds" = 0)
		fake.answers["tutorial_submit"] = list("ok" = TRUE, "tutorial" = "0123456789abcdef0123456789abcdef")
		fake.begin("tutorialowner")
		var/list/submitted = fake.submit("tutorialowner", "First aid", "Line one\nLine two")
		result["submitted"] = submitted["ok"] && !fake.busy_ckey
		result["two_requests"] = length(fake.queries) == 2
		var/list/check = length(fake.queries) >= 1 ? fake.queries[1] : list()
		var/list/submit = length(fake.queries) >= 2 ? fake.queries[2] : list()
		result["check_shape"] = check["action"] == "tutorial_submit_check" && check["actor"] == "tutorialowner" && length(check) == 2
		var/generation = submit["generation"]
		result["submit_shape"] = submit["action"] == "tutorial_submit" && submit["actor"] == "tutorialowner" && submit["title"] == "First aid" && submit["description"] == "Line one\nLine two" && istext(generation) && length(submit) == 5
		var/list/state = fake.snapshots[generation]
		result["snapshot_written"] = islist(state) && state["generation"] == generation
		result["snapshot_has_no_characters"] = islist(state) && islist(state["characters"]) && !length(state["characters"])
		result["snapshot_deleted"] = istext(generation) && !fexists("data/babylon/saves/[generation]/state.json")
		var/latest_after = fexists("data/babylon/saves/latest.json") ? file2text("data/babylon/saves/latest.json") : null
		result["latest_unchanged"] = latest_after == latest_before && last_save == last_save_before
		result["flag_cleared"] = !taking_tutorial_snapshot && !busy

		// A refused copy also drops the snapshot.
		fake.queries.Cut()
		fake.answers["tutorial_submit"] = list("ok" = FALSE, "error" = "Use a title of 1-60 characters")
		fake.begin("tutorialowner")
		var/list/denied = fake.submit("tutorialowner", "First aid", "")
		var/denied_generation = length(fake.queries) >= 2 ? fake.queries[2]["generation"] : null
		result["denied_reported"] = !denied["ok"] && findtext(denied["text"], "Use a title")
		result["denied_snapshot_deleted"] = istext(denied_generation) && !fexists("data/babylon/saves/[denied_generation]/state.json")

		// A cooldown stops before any save.
		fake.queries.Cut()
		var/saves_before = save_count
		fake.answers["tutorial_submit_check"] = list("ok" = TRUE, "wait_seconds" = 240)
		fake.begin("tutorialowner")
		var/list/cooling = fake.submit("tutorialowner", "First aid", "")
		result["cooldown_refused"] = !cooling["ok"] && cooling["wait_seconds"] == 240 && findtext(cooling["text"], "4 min") && save_count == saves_before && length(fake.queries) == 1

		// Save back from an edit world.
		fake.queries.Cut()
		flags.kind = "tutorial_edit"
		fake.answers["tutorial_save_back"] = list("ok" = TRUE, "tutorial" = "0123456789abcdef0123456789abcdef")
		fake.begin("tutorialadmin")
		var/list/saved_back = fake.save_back("tutorialadmin", TRUE)
		var/list/back = length(fake.queries) ? fake.queries[1] : list()
		var/back_generation = back["generation"]
		result["saved_back"] = saved_back["ok"] && !fake.busy_ckey
		result["save_back_shape"] = length(fake.queries) == 1 && back["action"] == "tutorial_save_back" && back["actor"] == "tutorialadmin" && istext(back_generation) && length(back) == 3
		var/list/back_state = fake.snapshots[back_generation]
		result["save_back_has_no_characters"] = islist(back_state) && islist(back_state["characters"]) && !length(back_state["characters"])
		result["save_back_snapshot_deleted"] = istext(back_generation) && !fexists("data/babylon/saves/[back_generation]/state.json")
		latest_after = fexists("data/babylon/saves/latest.json") ? file2text("data/babylon/saves/latest.json") : null
		result["save_back_latest_unchanged"] = latest_after == latest_before && last_save == last_save_before
	catch(var/exception/error)
		result["error_[error]"] = FALSE
	taking_tutorial_snapshot = FALSE
	flags.build = was[1]
	flags.creative = was[2]
	flags.kind = was[3]
	flags.owner_ckey = was[4]
	flags.persistent = was[5]
	GLOB.babylon_tutorial_submissions = real
	babylon_tutorial_test_cleanup(made)
	return result

/// A real submission through the supervisor (smoke_station.py checks the stored copy): the owner
/// `actor` submits this world with a start marker. Reports the tutorial id and the generation.
/datum/babylon_save/proc/test_tutorial_submit_live(actor)
	var/list/result = list()
	var/list/made = list()
	var/datum/babylon_tutorial_submissions/submissions = GLOB.babylon_tutorial_submissions
	if(!babylon_tutorial_marker_turf("start"))
		babylon_tutorial_test_place(/obj/babylon_tutorial/marker, tutorial_test_base(9), "start", list(), made)
	var/latest_before = fexists("data/babylon/saves/latest.json") ? file2text("data/babylon/saves/latest.json") : null
	result["allowed"] = isnull(babylon_tutorial_submit_refusal(actor))
	result["began"] = submissions.begin(actor)
	var/list/submitted = submissions.submit(actor, "Smoke tutorial", "Submitted by the station smoke test.")
	result["submitted"] = !!submitted["ok"]
	// Shown with the other entries when something failed.
	result["outcome"] = submitted["text"]
	result["tutorial"] = submitted["tutorial"]
	result["generation"] = submitted["generation"]
	result["snapshot_deleted"] = istext(submitted["generation"]) && !fexists("data/babylon/saves/[submitted["generation"]]/state.json")
	var/latest_after = fexists("data/babylon/saves/latest.json") ? file2text("data/babylon/saves/latest.json") : null
	result["latest_unchanged"] = latest_after == latest_before
	var/list/cooldown = submissions.check(actor)
	result["cooldown_started"] = cooldown["ok"] && cooldown["wait_seconds"] > 0
	var/list/again = submissions.submit(actor, "Again", "")
	result["second_refused_by_cooldown"] = !again["ok"] && findtext(again["text"], "another tutorial in")
	result["not_busy"] = !submissions.busy_ckey
	babylon_tutorial_test_cleanup(made)
	return result
