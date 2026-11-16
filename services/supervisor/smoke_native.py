"""Explicit integration test with real DreamDaemon children; no player world is touched."""
import argparse
import json
from pathlib import Path
import secrets
import shutil
import socket
import threading
import time
import urllib.request

from protocol import topic
from smoke_stability import restore_cycles
from supervisor import Driver, Supervisor, serve


def dm_entries(packed):
    """A DM test's packed result as a dict. The debug bridge packs at most a limited number of
    entries (testing_common.dm pack_value); a cut-off result must fail, never pass silently."""
    assert packed["length"] == len(packed["entries"]), ("result cut off", packed["length"], len(packed["entries"]))
    return {entry["entry"]: entry["value"] for entry in packed["entries"]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dreamdaemon", required=True)
    parser.add_argument("--config-directory", required=True)
    parser.add_argument("--data-directory", required=True)
    parser.add_argument("--api-port", type=int, default=1368)
    parser.add_argument("--child-port", type=int, default=1458)
    parser.add_argument("--only-stability", action="store_true",
                        help="only the restore stability check (a world restored 3 times keeps its objects)")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    # Closet/crate contents are generated on first opening; count the papers
    # available immediately after initialization, including satchel contents.
    lore = json.loads((root / "_maps/babylon/lore.json").read_text())
    expected_lore = sum(not item["paper"].startswith("/obj/structure/closet/") for item in lore)
    data = Path(args.data_directory).resolve()
    if data.exists():
        raise RuntimeError("Use a new empty test data directory")
    for port in (args.api_port, args.child_port):
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", port))
    config = dict(data_directory=str(data), template_directory=str(root),
                  config_directory=str(Path(args.config_directory).resolve()),
                  dreamdaemon=str(Path(args.dreamdaemon).resolve()),
                  max_worlds_per_player=3, max_running_worlds_per_player=1,
                  max_running_worlds=1, max_players_per_world=2,
                  port_first=args.child_port, port_last=args.child_port,
                  ticket_lifetime_seconds=60, empty_grace_seconds=600,
                  startup_timeout_seconds=300, public_host="127.0.0.1", admins=["testadmin"],
                  listen_host="127.0.0.1", listen_port=args.api_port,
                  lobby_secret=secrets.token_urlsafe(32), lobby_address="byond://127.0.0.1:1369")

    class TestDriver(Driver):
        def prepare(self, world, run):
            prepared = super().prepare(world, run)
            for ext in ("dmb", "rsc"):
                shutil.copy2(root / f"babylon-test.{ext}", prepared / f"babylon.{ext}")
            return prepared

    driver = TestDriver(config)
    service = Supervisor(config, driver)
    threading.Thread(target=serve, args=(config, service), daemon=True).start()

    def api(action, payload=None, actor="smokeowner"):
        body = json.dumps(dict(secret=config["lobby_secret"], actor=actor, action=action, payload=payload or {})).encode()
        request = urllib.request.Request(f"http://127.0.0.1:{args.api_port}/api", data=body,
                                         headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=180) as response:
            result = json.load(response)
        assert result.get("ok"), result
        return result

    def current():
        with service.lock:
            return service.row("SELECT * FROM runs")

    def wait_ready(world):
        api("join", {"world": world})
        deadline = time.time() + 300
        while time.time() < deadline:
            run = current()
            if run and run["state"] == "running":
                return run
            if run and run["state"] == "error":
                raise RuntimeError(run["error"])
            if world in service.launch_failures:
                # The start failed in the background (the join answered "pending" at once).
                raise RuntimeError(service.launch_failures[world]["message"])
            time.sleep(2)
        raise TimeoutError("Child did not become ready")

    def debug(run, action, payload):
        result = topic(run["port"], run["secret"], action, payload, timeout=180)
        assert not result.get("error"), result
        return result

    def call(run, target, proc, values=None):
        return debug(run, "call", dict(target=target, proc=proc, args=values or []))["result"]

    def stop(world):
        api("stop", {"world": world})
        deadline = time.time() + 60
        while time.time() < deadline and current():
            time.sleep(1)
        assert not current(), "Child did not exit after checkpoint"

    def stability():
        """A Babylon world restored three times keeps exactly its saved objects (smoke_stability.py)."""
        stable = api("create", dict(name="Stability smoke", visibility="private"), actor="stabilityowner")["id"]

        def start(world):
            api("join", {"world": world}, actor="stabilityowner")
            deadline = time.time() + 300
            while time.time() < deadline:
                run = current()
                if run and run["state"] == "running":
                    return run
                assert not (run and run["state"] == "error"), run
                time.sleep(2)
            raise TimeoutError("Stability child did not become ready")

        def stop_world(world):
            api("stop", {"world": world}, actor="stabilityowner")
            deadline = time.time() + 120
            while time.time() < deadline and current():
                time.sleep(1)
            assert not current(), "Stability child did not exit"
        def census(run):
            packed = call(run, "session", "test_companion_census")
            return dm_entries(packed)
        return restore_cycles(stable, start, stop_world, data, census=census)

    try:
        time.sleep(.5)
        if args.only_stability:
            report = dict(passed=True, restore_stability=stability())
            (data / "result.json").write_text(json.dumps(report, indent=2))
            print(json.dumps(report, indent=2))
            return
        world = api("create", dict(name="Native smoke", visibility="private"))["id"]
        run = wait_ready(world)
        assert topic(run["port"], run["secret"], "status")["players"] == []
        assert topic(run["port"], run["secret"], "announce", {"message": "Smoke restart notice"}).get("ok"), "announce failed"
        afk = call(run, "session", "test_afk_policy")
        afk = dm_entries(afk)
        assert afk and all(afk.values()), afk
        showcase = call(run, "session", "test_showcase_visitor")
        showcase = dm_entries(showcase)
        assert showcase and all(showcase.values()), showcase
        experience = call(run, "session", "test_builder_experience")
        experience = dm_entries(experience)
        for key in ("replacement_items", "replacement_storage", "replacement_head", "station_confinement", "physical_cafe_turfs"):
            assert experience[key] == 0, experience
        for key in ("spawners_hidden", "minigames_hidden", "dnr_present", "reenter_present", "return_before_destruct"):
            assert experience[key], experience
        assert experience["lore_papers"] == expected_lore, experience
        sfw = call(run, "session", "test_sfw_content")
        sfw = dm_entries(sfw)
        assert sfw and all(sfw.values()), sfw
        moderation = call(run, "session", "test_moderation")
        moderation = dm_entries(moderation)
        assert moderation and all(moderation.values()), moderation
        research = call(run, "session", "test_research")
        research = dm_entries(research)
        assert research and all(research.values()), research
        closets = call(run, "session", "test_closet_contents")
        closets = dm_entries(closets)
        assert closets and all(closets.values()), closets
        controls = call(run, "session", "test_save_controls")
        controls = dm_entries(controls)
        assert controls and all(controls.values()), controls
        unsaved = call(run, "session", "test_non_persistent_never_saves")
        unsaved = dm_entries(unsaved)
        assert unsaved and all(unsaved.values()), unsaved
        frames = call(run, "session", "test_machine_frames")
        frames = dm_entries(frames)
        assert frames and all(frames.values()), frames
        reflectors = call(run, "session", "test_reflectors")
        reflectors = dm_entries(reflectors)
        assert reflectors and all(reflectors.values()), reflectors
        music = call(run, "session", "test_music_folders")
        music = dm_entries(music)
        assert music and all(music.values()), music
        loops = call(run, "session", "test_music_loops")
        loops = dm_entries(loops)
        assert loops and all(loops.values()), loops
        joining = call(run, "session", "test_join_loading")
        joining = dm_entries(joining)
        assert joining and all(joining.values()), joining
        silicons = call(run, "session", "test_no_unplayable_silicons")
        silicons = dm_entries(silicons)
        assert silicons and all(silicons.values()), silicons
        played = call(run, "session", "test_play_time")
        played = dm_entries(played)
        assert played and all(played.values()), played
        machines = call(run, "session", "test_creative_machines")
        machines = dm_entries(machines)
        assert machines and all(machines.values()), machines
        creative = call(run, "session", "test_creative_panel_actions")
        creative = dm_entries(creative)
        assert creative and all(creative.values()), creative
        atlas = call(run, "session", "test_atlas_frames")
        atlas = dm_entries(atlas)
        assert atlas and all(atlas.values()), atlas
        wrap = call(run, "session", "test_space_wrap")
        wrap = dm_entries(wrap)
        assert wrap and all(wrap.values()), wrap
        storyteller = call(run, "session", "test_no_storyteller")
        storyteller = dm_entries(storyteller)
        assert storyteller and all(storyteller.values()), storyteller
        for proc in ("test_tutorial_objects", "test_tutorial_flow", "test_tutorial_triggers", "test_npc_effects", "test_tutorial_review", "test_tutorial_chains", "test_tutorial_players", "test_tutorial_gates", "test_tutorial_world_actions",
                     "test_area_tools_limits", "test_paste_suffix_rewrites_refs", "test_area_tools_roundtrip",
                     "test_area_tools_copy_settings", "test_tutorial_room_reset"):
            values = call(run, "session", proc)
            values = dm_entries(values)
            assert values and all(values.values()), (proc, values)
        player = call(run, "session", "ensure_player", ["smokefriend"])
        friend_ref = player["ref"]
        fields = debug(run, "inspect", dict(target=friend_ref, vars=["builder"]))["vars"]
        friend_drone = fields["builder"]["ref"]
        debug(run, "set_var", dict(target=friend_drone, var="name", value="Second persistent drone"))
        debug(run, "set_var", dict(target=friend_drone, var="picked", value=1))
        bag = debug(run, "spawn", dict(type="/obj/item/storage/backpack", target=friend_drone))["object"]["ref"]
        call(run, friend_drone, "put_in_hand", [{"ref": bag}, 2, 1])
        closet = debug(run, "spawn", dict(type="/obj/structure/closet", target=friend_drone))["object"]["ref"]
        call(run, friend_drone, "forceMove", [{"ref": closet}])
        call(run, friend_drone, "death")
        # Exercise real DM world.Export -> HTTP redemption, with an admin bypass.
        address = api("join", {"world": world}, actor="testadmin")["address"]
        ticket = address.split("babylon_ticket=")[1]
        query = dict(action="redeem", actor="testadmin", ticket=ticket)
        # Test-only helper runs the same HTTP request procedure as client.New.
        exported = call(run, "session", "test_supervisor_export", [json.dumps(query)])
        assert any(e["entry"] == "ok" and e["value"] for e in exported["entries"]), exported
        exported = call(run, "session", "test_supervisor_export", [json.dumps(query)])
        assert not any(e["entry"] == "ok" and e["value"] for e in exported["entries"]), "Ticket replay accepted"
        # Lights, cameras and alarms whose state the restored map's Initialize would decide anew.
        saved_state = call(run, "session", "test_saved_state_setup")
        saved_state = dm_entries(saved_state)
        assert saved_state and all(saved_state.values()), saved_state
        stop(world)
        saved = data / "worlds" / world / "data/babylon/saves"
        generation = json.loads((saved / "latest.json").read_text())["generation"]
        before = json.loads((saved / generation / "state.json").read_text())
        assert set(before["players"]) == {"smokeowner", "smokefriend"}
        friend_id = before["players"]["smokefriend"]["builder"]
        assert before["players"]["smokefriend"]["respawn_pending"]
        run = wait_ready(world)
        restored_state = call(run, "session", "test_saved_state_restored", [saved_state["state"]])
        restored_state = dm_entries(restored_state)
        assert restored_state and all(restored_state.values()), restored_state
        roster = debug(run, "inspect", dict(target="session", vars=["player_sessions"]))["vars"]["player_sessions"]
        assert roster["length"] == 2, roster
        restored_friend = next(e["value"]["ref"] for e in roster["entries"] if e["entry"] == "smokefriend")
        fields = debug(run, "inspect", dict(target=restored_friend, vars=["builder", "respawn_pending", "respawn_ready_at"]))["vars"]
        assert fields["builder"]["name"] == "Second persistent drone", fields
        assert fields["respawn_pending"], fields
        # Restoring refreshes every object's appearance; holobarriers must keep their overlay.
        barriers = debug(run, "find", dict(type="/obj/structure/holosign/barrier", limit=5))["matches"]
        assert barriers, "the map's holobarriers were not restored"
        for barrier in barriers:
            shown = debug(run, "inspect", dict(target=barrier["ref"], vars=["vis_contents"]))["vars"]["vis_contents"]
            assert shown["length"] >= 1, "restored holobarrier lost its overlay (invisible)"
        papers = debug(run, "find", dict(type="/obj/item/paper/babylon", limit=100))["matches"]
        assert len(papers) == expected_lore, papers
        # Exercise the actual respawn path, not only the replacement initializer.
        debug(run, "set_var", dict(target=restored_friend, var="respawn_ready_at", value=0))
        assert call(run, restored_friend, "respawn_builder"), "Respawn failed"
        replacement = debug(run, "inspect", dict(target=restored_friend, vars=["builder"]))["vars"]["builder"]["ref"]
        equipment = debug(run, "inspect", dict(target=replacement, vars=["internal_storage", "head", "contents"]))["vars"]
        assert not equipment["internal_storage"] and not equipment["head"], equipment
        assert not any(isinstance(e["entry"], dict) and e["entry"].get("type", "").startswith("/obj/item") for e in equipment["contents"]["entries"]), equipment
        stop(world)
        generation2 = json.loads((saved / "latest.json").read_text())["generation"]
        after = json.loads((saved / generation2 / "state.json").read_text())
        assert after["players"]["smokefriend"]["builder"] != friend_id
        objects = {r["id"]: r for r in after["records"]}
        inventory = [r for r in before["records"] if r.get("parent") == friend_id]
        for item in inventory:
            assert objects[item["id"]].get("parent") == friend_id
        # A real showcase child must classify admission through native HTTP,
        # including attempts to request player access from an untrusted guest.
        showcase_world = api("create", dict(name="Native showcase", visibility="showcase"))["id"]
        showcase_run = wait_ready(showcase_world)
        for actor, mode in (("smokevisitor", "showcase"), ("smokeowner", "player"), ("testadmin", "player")):
            address = api("join", dict(world=showcase_world, mode="player"), actor=actor)["address"]
            query = dict(action="redeem", actor=actor, ticket=address.split("babylon_ticket=")[1], mode="player")
            exported = call(showcase_run, "session", "test_supervisor_export", [json.dumps(query)])
            fields = dm_entries(exported)
            assert fields.get("ok") and fields.get("mode") == mode, fields
        stop(showcase_world)
        # Checkpoints written by the build before the station rework (a9c41016abe) still load:
        # the golden version 7 generation and its version 5 shape (fixtures/README.md).
        legacy = {}
        fixtures = Path(__file__).resolve().parent / "fixtures"
        for version, state_dir in ((7, "babylon_v7"), (5, "babylon_v5")):
            legacy_world = api("create", dict(name="Legacy v%d" % version, visibility="private"), actor="fixtureowner")["id"]
            state = json.loads((fixtures / state_dir / "state.json").read_text())
            assert state["version"] == version, state["version"]
            generation_dir = data / "worlds" / legacy_world / "data/babylon/saves" / state["generation"]
            generation_dir.mkdir(parents=True)
            shutil.copy2(fixtures / "babylon_v7/map.dmm", generation_dir / "map.dmm")
            shutil.copy2(fixtures / state_dir / "state.json", generation_dir / "state.json")
            (generation_dir.parent / "latest.json").write_text(json.dumps({"generation": state["generation"]}))
            api("join", {"world": legacy_world}, actor="fixtureowner")
            deadline = time.time() + 300
            while time.time() < deadline:
                legacy_run = current()
                if legacy_run and legacy_run["state"] == "running":
                    break
                assert not (legacy_run and legacy_run["state"] == "error"), legacy_run
                assert legacy_world not in service.launch_failures, service.launch_failures[legacy_world]["message"]
                time.sleep(2)
            restored = call(legacy_run, "session", "test_legacy_babylon_restore",
                            [version, "gas_compression", state["research"]["target"]])
            restored = dm_entries(restored)
            assert restored and all(restored.values()), ("legacy v%d" % version, restored)
            legacy["v%d" % version] = restored
            api("stop", {"world": legacy_world}, actor="fixtureowner")
            deadline = time.time() + 60
            while time.time() < deadline and current():
                time.sleep(1)
            assert not current(), "Legacy child did not exit"
        restore_stability = stability()
        report = dict(passed=True, real_child_start_stop=True, http_ticket_redemption=True,
                      afk_policy=True, showcase_read_only_visitor=True,
                      showcase_ticket_redemption=True,
                      replay_rejected=True, admin_private_bypass=True, multiplayer_roster=True,
                      second_inventory=True, second_respawn=True, enclosed_drone=True,
                      empty_respawn=True, ghost_hud_trimmed=True, physical_cafe_turfs=0,
                      lore_papers=expected_lore, return_button_order=True,
                      generations=[generation, generation2], legacy_saves=legacy,
                      restore_stability=restore_stability)
        (data / "result.json").write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2))
    finally:
        run = current()
        if run:
            try:
                api("stop", {"world": run["world"]})
                deadline = time.time() + 30
                while time.time() < deadline and current():
                    time.sleep(1)
            except Exception:
                pass
            if current():
                print("Test child retained for diagnosis; see test data directory.")


if __name__ == "__main__":
    main()
