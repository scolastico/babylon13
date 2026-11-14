"""Explicit integration test of the station build with real DreamDaemon children.

Runs the real supervisor with babylon-station-test.dmb (compile babylon-station-test.dme first)
copied over babylon-station.dmb, creates a world on a catalog station map, joins it, checks the
station build's tests and stops it again. No player world is touched.

    python3 services/supervisor/smoke_station.py --dreamdaemon /opt/byond/bin/DreamDaemon \
        --config-directory config --data-directory /tmp/smoke-station [--maps metastation boxstation] \
        [--multiz-map icebox | --no-multiz]

The first map gets the full checks, including a real save (timings and sizes are reported) and
round control: the round waits for its owner, starts on the owner's Start round and, once it ends,
the world returns everyone to the lobby and exits without a new save (the supervisor records an
ordinary stop). Further maps (used to vet the map catalog) are only booted to the ready state,
checked for the right map and late-join points, and stopped, which saves them. Then every Creative
Plane map (--creative-planes, default S, M and L) boots as a Creative world (S without Creative mode,
M and L with it): its floor, landmarks, inert storyteller, refused shuttles and, a few seconds into
its round, power and the atmos loop are checked; the owner's Start round must start its round. A
tutorial-kind world on the first map checks that its round starts by itself and stops without a
save. Finally the multi-z map (icebox) starts its round, places markers on the station level and on
a level without the station trait, saves, stops, starts again from the save and checks that the
markers, an emptied locker, an animal, the levels' traits and the running round came back.
"""
import argparse
import json
from pathlib import Path
import secrets
import shutil
import socket
import threading
import time
import urllib.error
import urllib.request

from protocol import topic
from supervisor import Driver, Supervisor, serve


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dreamdaemon", required=True)
    parser.add_argument("--config-directory", required=True)
    parser.add_argument("--data-directory", required=True)
    parser.add_argument("--api-port", type=int, default=1378)
    parser.add_argument("--child-port", type=int, default=1468)
    parser.add_argument("--maps", nargs="+", default=["metastation"])
    parser.add_argument("--creative-planes", nargs="*", default=["creative_plane_s", "creative_plane_m", "creative_plane_l"])
    parser.add_argument("--startup-timeout", type=int, default=900)
    parser.add_argument("--multiz-map", default="icebox")
    parser.add_argument("--no-multiz", action="store_true")
    parser.add_argument("--restore-maps", nargs="*", default=["tramstation"],
                        help="maps saved, restarted and checked for their transports and links")
    parser.add_argument("--only-multiz", action="store_true", help="skip the --maps checks and the tutorial world")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    for ext in ("dmb", "rsc"):
        if not (root / f"babylon-station-test.{ext}").is_file():
            raise RuntimeError("Compile babylon-station-test.dme first")
    data = Path(args.data_directory).resolve()
    if data.exists():
        raise RuntimeError("Use a new empty test data directory")
    for port in (args.api_port, args.child_port):
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", port))
    config = dict(data_directory=str(data), template_directory=str(root),
                  config_directory=str(Path(args.config_directory).resolve()),
                  dreamdaemon=str(Path(args.dreamdaemon).resolve()),
                  max_worlds_per_player=20, max_total_worlds_per_player=20, max_running_worlds_per_player=1,
                  max_running_worlds=1, max_players_per_world=2,
                  port_first=args.child_port, port_last=args.child_port,
                  ticket_lifetime_seconds=60, empty_grace_seconds=600,
                  startup_timeout_seconds=args.startup_timeout, public_host="127.0.0.1", admins=["testadmin"],
                  listen_host="127.0.0.1", listen_port=args.api_port,
                  lobby_secret=secrets.token_urlsafe(32), lobby_address="byond://127.0.0.1:1379")

    class TestDriver(Driver):
        def prepare(self, world, run):
            # The test build stands in for babylon-station.dmb, which need not be compiled.
            target = self.data_root() / "worlds" / world["id"]
            target.mkdir(parents=True, exist_ok=True)
            for ext in ("dmb", "rsc"):
                shutil.copy2(root / f"babylon-station-test.{ext}", target / f"babylon-station.{ext}")
            prepared = super().prepare(world, run)
            for ext in ("dmb", "rsc"):
                shutil.copy2(root / f"babylon-station-test.{ext}", prepared / f"babylon-station.{ext}")
            return prepared

        def restore_source(self, world):
            # Tutorial snapshots come with the tutorial pipeline; the round test needs none.
            if self.field(world, "kind", "world") != "world":
                return None
            return super().restore_source(world)

    driver = TestDriver(config)
    service = Supervisor(config, driver)
    threading.Thread(target=serve, args=(config, service), daemon=True).start()

    def api(action, payload=None, actor="smokeowner"):
        body = json.dumps(dict(secret=config["lobby_secret"], actor=actor, action=action, payload=payload or {})).encode()
        request = urllib.request.Request(f"http://127.0.0.1:{args.api_port}/api", data=body,
                                         headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=180) as response:
                result = json.load(response)
        except urllib.error.HTTPError as error:
            raise RuntimeError("%s %s: %s" % (action, payload, error.read().decode(errors="replace"))) from None
        assert result.get("ok"), result
        return result

    def current():
        with service.lock:
            return service.row("SELECT * FROM runs")

    def wait_ready(world):
        api("join", {"world": world})
        deadline = time.time() + args.startup_timeout
        while time.time() < deadline:
            run = current()
            if run and run["state"] == "running":
                return run
            if run and run["state"] == "error":
                raise RuntimeError(run["error"])
            time.sleep(5)
        raise TimeoutError("Child did not become ready")

    def debug(run, action, payload):
        result = topic(run["port"], run["secret"], action, payload, timeout=180)
        assert not result.get("error"), result
        return result

    def values(run, proc, args=None):
        """A DM test's entries without asserting them (facts to compare across a restart)."""
        result = debug(run, "call", dict(target="session", proc=proc, args=args or []))["result"]
        return {entry["entry"]: entry["value"] for entry in result["entries"]}

    def compare_links(before, after):
        """After a restart from a save: links are at least as complete as before it."""
        for key in ("one_apc_per_area", "lift_buttons_linked", "trams_have_ids", "trams_positioned"):
            assert after[key] or not before[key], (key, before, after)
        assert after["transports"] == before["transports"], (before["transports"], after["transports"])
        assert after["lift_buttons"] == before["lift_buttons"], (before, after)

    def checks(run, proc, values=None):
        result = debug(run, "call", dict(target="session", proc=proc, args=values or []))["result"]
        values = {entry["entry"]: entry["value"] for entry in result["entries"]}
        assert values and all(values.values()), (proc, values)
        return values

    def stop(world):
        process = driver.processes.get(current()["id"])
        api("stop", {"world": world})
        deadline = time.time() + 600
        while time.time() < deadline and current():
            time.sleep(1)
        assert not current(), "Child did not exit after a managed stop"
        if process:
            process.wait(timeout=30)
            assert process.poll() is not None, "DreamDaemon is still running"

    def ticker_state(run):
        info = debug(run, "call", dict(target="session", proc="test_station_info", args=[]))["result"]
        return {e["entry"]: e["value"] for e in info["entries"]}["ticker_state"]

    def wait_round_running(run, timeout=180):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if ticker_state(run) == 3:  # GAME_STATE_PLAYING
                return
            time.sleep(2)
        raise TimeoutError("The round did not start")

    def wait_round_end_stop(world):
        """The world stops itself after its round ends: never an error state, no save."""
        process = driver.processes.get(current()["id"])
        states = set()
        deadline = time.time() + 180
        while time.time() < deadline:
            run = current()
            if not run:
                break
            states.add(run["state"])
            time.sleep(.5)
        assert not current(), "The world did not exit after its round ended"
        assert "error" not in states, states
        assert "stopping" in states, states
        if process:
            process.wait(timeout=30)
        with service.lock:
            ended = service.row("SELECT * FROM audit WHERE action='round_ended' AND world=?", (world,))
        assert ended, "The supervisor was not told about the round's end"
        return sorted(states)

    def latest(world):
        path = data / "worlds" / world / "data/babylon/saves/latest.json"
        return json.loads(path.read_text())["generation"] if path.exists() else None

    def save_size(world, generation):
        directory = data / "worlds" / world / "data/babylon/saves" / generation
        files = {path.name: path.stat().st_size for path in sorted(directory.iterdir())}
        return dict(files=files, total_bytes=sum(files.values()))

    def info(run):
        result = debug(run, "call", dict(target="session", proc="test_station_info", args=[]))["result"]
        return {e["entry"]: e["value"] for e in result["entries"]}

    catalog = {entry["id"]: entry for entry in json.loads((root / "_maps/babylon/catalog.json").read_text())["maps"]}

    def run_map(index, map_id):
        started = time.time()
        world = api("create", dict(name="Station smoke %s" % map_id, visibility="private", map=map_id))["id"]
        run = wait_ready(world)
        status = topic(run["port"], run["secret"], "status")
        assert status["ready"] and status["players"] == [] and status.get("build") == "station", status
        assert status.get("map") == map_id, status
        entry = dict(ready_seconds=round(time.time() - started))
        info = debug(run, "call", dict(target="session", proc="test_station_info", args=[]))["result"]
        entry["info"] = {e["entry"]: e["value"] for e in info["entries"]}
        expected = json.loads((root / "_maps" / catalog[map_id]["map_json"]).read_text())["map_name"]
        assert entry["info"]["map_name"] == expected, (entry["info"], expected)
        entry["world_flags"] = checks(run, "test_station_world_flags")
        entry["test_station_latejoin"] = checks(run, "test_station_latejoin")
        if index == 0:
            assert topic(run["port"], run["secret"], "announce", {"message": "Smoke notice"}).get("ok"), "announce failed"
            entry["storyteller"] = checks(run, "test_station_storyteller")
            entry["test_station_save_level"] = checks(run, "test_station_save_level")
            entry["test_station_emergency_dock"] = checks(run, "test_station_emergency_dock")
            # The shared modules' tests (testing_common.dm), as the Babylon smoke runs them.
            for proc in ("test_sfw_content", "test_showcase_visitor", "test_moderation", "test_play_time",
                         "test_music_loops", "test_creative_machines",
                         "test_creative_panel_actions"):
                entry[proc] = checks(run, proc)
            entry["test_non_persistent_never_saves"] = checks(run, "test_non_persistent_never_saves")
            entry["test_save_controls"] = checks(run, "test_save_controls")
            entry["test_manual_save_cooldown"] = checks(run, "test_manual_save_cooldown")
            links_before = values(run, "test_station_links")
            entry["links_fresh"] = links_before
            # A real station save (all persisted levels) through the control API, as the lobby asks.
            saved = topic(run["port"], run["secret"], "save", timeout=600)
            assert saved.get("ok"), saved
            assert saved.get("reused_levels") == 0, saved
            entry["save"] = dict(saved, size=save_size(world, saved["generation"]))
            # Nothing changed since: the next save reuses every level (this one is restored below).
            saved = topic(run["port"], run["secret"], "save", timeout=600)
            assert saved.get("ok") and saved.get("reused_levels") == saved.get("levels"), saved
            entry["save_unchanged"] = dict(saved, size=save_size(world, saved["generation"]))
            entry["afk"] = bool(checks(run, "test_afk_policy"))
            entry["join_loading"] = bool(checks(run, "test_join_loading"))
            # Real DM world.Export -> HTTP ticket redemption, as client.New runs it.
            address = api("join", {"world": world}, actor="testadmin")["address"]
            query = dict(action="redeem", actor="testadmin", ticket=address.split("babylon_ticket=")[1])
            exported = debug(run, "call", dict(target="session", proc="test_supervisor_export", args=[json.dumps(query)]))["result"]
            assert any(e["entry"] == "ok" and e["value"] for e in exported["entries"]), exported
            exported = debug(run, "call", dict(target="session", proc="test_supervisor_export", args=[json.dumps(query)]))["result"]
            assert not any(e["entry"] == "ok" and e["value"] for e in exported["entries"]), "Ticket replay accepted"
            entry["ticket_redemption"] = True
            # Round control: hold, the owner's start, the round's end back to the lobby.
            entry["test_round_hold_and_owner_start"] = checks(run, "test_round_hold_and_owner_start")
            wait_round_running(run)
            status = topic(run["port"], run["secret"], "status")
            assert status["ready"] and not status["draining"], status
            entry["test_round_end_no_save"] = checks(run, "test_round_end_no_save")
            entry["round_end_states"] = wait_round_end_stop(world)
            # The round's end saved nothing new: the next start resumes the save from before it.
            assert latest(world) == saved["generation"], "the round's end saved the world"
            entry["round_end_without_save"] = True
            # The next start picks up from that save (before the round): the map comes back whole.
            restarted = time.time()
            run = wait_ready(world)
            entry["restored_ready_seconds"] = round(time.time() - restarted)
            links_after = values(run, "test_station_links")
            entry["links_restored"] = links_after
            compare_links(links_before, links_after)
            assert links_after["one_apc_per_area"], links_after
            stop(world)
        else:
            stop(world)
            # An ordinary stop of a persistent world saves it (all its levels).
            generation = latest(world)
            assert generation, "the stopped station world was not saved"
            entry["stop_saved"] = save_size(world, generation)
        return entry

    def run_multiz(map_id):
        """Saves a running round on a multi-z map, restarts the world from that save and checks it."""
        started = time.time()
        world = api("create", dict(name="Station smoke multi-z", visibility="private", map=map_id))["id"]
        run = wait_ready(world)
        entry = dict(ready_seconds=round(time.time() - started))
        assert debug(run, "call", dict(target="session", proc="begin_round", args=["Babylon smoke"]))["result"]
        wait_round_running(run)
        links_before = values(run, "test_station_links")
        first = checks(run, "test_multiz_save_roundtrip")
        entry["test_multiz_save_roundtrip"] = first
        entry["save"] = info(run)["last_save"]
        stopped = time.time()
        stop(world)
        entry["stop_seconds"] = round(time.time() - stopped)
        generation = latest(world)
        assert generation and generation != first.get("generation"), generation
        entry["stop_save"] = save_size(world, generation)
        restarted = time.time()
        run = wait_ready(world)
        entry["restored_ready_seconds"] = round(time.time() - restarted)
        entry["restored_info"] = info(run)
        entry["test_multiz_restored"] = checks(run, "test_multiz_restored",
                                               [first["markers"], first["station_time"], 1, first["planet_coords"],
                                                first["traveller"]])
        links_after = values(run, "test_station_links")
        entry["links"] = dict(before=links_before, after=links_after)
        compare_links(links_before, links_after)
        assert links_after["lift_buttons_linked"], links_after
        stop(world)
        return entry

    def run_restore(map_id):
        """Saves a world on a map with transports (tram, lifts), restarts it and compares the links."""
        world = api("create", dict(name="Station smoke restore %s" % map_id, visibility="private", map=map_id))["id"]
        run = wait_ready(world)
        before = values(run, "test_station_links")
        stop(world)
        assert latest(world), "the stopped world was not saved"
        run = wait_ready(world)
        after = values(run, "test_station_links")
        compare_links(before, after)
        assert after["trams_have_ids"] and after["trams_positioned"] and after["lift_buttons_linked"], after
        # The tram found its platform and nav beacon when it loaded (no CRASH in the world's logs).
        for log_file in (data / "worlds" / world).rglob("*.log"):
            text = log_file.read_text(errors="replace")
            assert "initialized without the required landmarks" not in text, log_file
        entry = dict(before=before, after=after)
        if after["transports"].count("icts_tram:"):
            # A tram saved between stations drives back to a platform after the restore. Trams
            # only run during a round (SStransport does not fire in the pre-round lobby).
            assert debug(run, "call", dict(target="session", proc="begin_round", args=["Babylon smoke"]))["result"]
            wait_round_running(run)
            entry["mid_trip"] = checks(run, "test_tram_mid_trip")
            time.sleep(10)
            stop(world)
            run = wait_ready(world)
            deadline = time.time() + 180
            while True:
                recovered = values(run, "test_station_links")
                if recovered["trams_positioned"] or time.time() > deadline:
                    break
                time.sleep(5)
            assert recovered["trams_positioned"], recovered
            # It really was between stations: the restore drove it back (reset_stray_trams()).
            reset_logged = any("saved between stations" in f.read_text(errors="replace")
                               for f in (data / "worlds" / world).rglob("*.log"))
            assert reset_logged, "the tram was not reset after the restore"
            assert recovered["transports"] == after["transports"], (after["transports"], recovered["transports"])
            entry["mid_trip_recovered"] = recovered
        stop(world)
        return entry

    def eventually(run, proc, timeout=120):
        """Checks that need the simulation to run a while (air, power): retried until all pass;
        on a timeout the assertion carries <proc>_info's numbers."""
        deadline = time.time() + timeout
        while True:
            result = debug(run, "call", dict(target="session", proc=proc, args=[]))["result"]
            values = {entry["entry"]: entry["value"] for entry in result["entries"]}
            if values and all(values.values()):
                return values
            if time.time() > deadline:
                info = debug(run, "call", dict(target="session", proc=proc + "_info", args=[]))["result"]
                raise AssertionError((proc, values, {e["entry"]: e["value"] for e in info["entries"]}))
            time.sleep(3)

    def run_creative_plane(map_id):
        """A Creative world on a Creative Plane map: the map works and its round starts."""
        started = time.time()
        # S runs without Creative mode: the plane's creative machines must work anyway.
        creative = 0 if map_id == "creative_plane_s" else 1
        world = api("create", dict(name="Station smoke %s" % map_id, visibility="private", map=map_id, creative=creative))["id"]
        run = wait_ready(world)
        status = topic(run["port"], run["secret"], "status")
        assert status["ready"] and status.get("build") == "station" and status.get("map") == map_id, status
        entry = dict(ready_seconds=round(time.time() - started))
        info = debug(run, "call", dict(target="session", proc="test_station_info", args=[]))["result"]
        entry["info"] = {e["entry"]: e["value"] for e in info["entries"]}
        expected = json.loads((root / "_maps" / catalog[map_id]["map_json"]).read_text())["map_name"]
        assert entry["info"]["map_name"] == expected, (entry["info"], expected)
        entry["world_flags"] = checks(run, "test_station_world_flags")
        entry["test_station_latejoin"] = checks(run, "test_station_latejoin")
        entry["test_creative_plane"] = checks(run, "test_creative_plane")
        entry["test_round_hold_and_owner_start"] = checks(run, "test_round_hold_and_owner_start")
        wait_round_running(run)
        entry["test_creative_plane_round"] = eventually(run, "test_creative_plane_round")
        stop(world)
        saves = data / "worlds" / world / "data/babylon/saves"
        assert not (saves / "latest.json").exists(), "a station world saved"
        return entry

    def discard_child():
        """Kills a failed child so the next map can start (max_running_worlds is 1)."""
        run = current()
        if not run:
            return
        process = driver.processes.get(run["id"])
        if process and process.poll() is None:
            process.kill()
            process.wait(timeout=30)
        with service.lock, service.db:
            service.db.execute("DELETE FROM runs WHERE id=?", (run["id"],))

    report = dict(passed=False, maps={})
    try:
        time.sleep(.5)
        for index, map_id in enumerate([] if args.only_multiz else args.maps):
            try:
                entry = run_map(index, map_id)
            except Exception as error:
                # The first map is the test; further maps only vet the catalog and are reported.
                if index == 0:
                    raise
                entry = dict(failed=repr(error))
                discard_child()
            report["maps"][map_id] = entry
            print(json.dumps({map_id: entry}), flush=True)
        for map_id in ([] if args.only_multiz else args.creative_planes):
            try:
                entry = run_creative_plane(map_id)
            except Exception as error:
                entry = dict(failed=repr(error))
                discard_child()
            report["maps"][map_id] = entry
            print(json.dumps({map_id: entry}), flush=True)
        if not args.only_multiz:
            # A tutorial-kind world starts its round by itself (no owner hold).
            world = api("create", dict(name="Station smoke tutorial", visibility="private", map=args.maps[0]))["id"]
            with service.lock, service.db:
                service.db.execute("UPDATE worlds SET kind='tutorial', tutorial='smoke_tutorial' WHERE id=?", (world,))
            run = wait_ready(world)
            tutorial = dict(test_tutorial_round=checks(run, "test_tutorial_round"),
                            world_flags=checks(run, "test_station_world_flags"))
            stop(world)
            # A tutorial instance is not saved and is deleted once it stops.
            assert not (data / "worlds" / world / "data/babylon/saves/latest.json").exists(), "a tutorial world saved"
            tutorial["stopped_without_save"] = True
            report["tutorial"] = tutorial
            print(json.dumps({"tutorial": tutorial}), flush=True)
        for map_id in args.restore_maps:
            report.setdefault("restore", {})[map_id] = run_restore(map_id)
            print(json.dumps({"restore": {map_id: report["restore"][map_id]}}), flush=True)
        if not args.no_multiz:
            report["multiz"] = {args.multiz_map: run_multiz(args.multiz_map)}
            print(json.dumps({"multiz": report["multiz"]}), flush=True)
        report["passed"] = not any("failed" in entry for entry in report["maps"].values())
        (data / "result.json").write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2))
        if not report["passed"]:
            raise SystemExit(1)
    finally:
        run = current()
        if run:
            try:
                api("stop", {"world": run["world"]})
                deadline = time.time() + 60
                while time.time() < deadline and current():
                    time.sleep(1)
            except Exception:
                pass
            if current():
                print("Test child retained for diagnosis; see test data directory.")


if __name__ == "__main__":
    main()
