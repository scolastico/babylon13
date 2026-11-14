"""Explicit integration test of the station build with real DreamDaemon children.

Runs the real supervisor with babylon-station-test.dmb (compile babylon-station-test.dme first)
copied over babylon-station.dmb, creates a world on a catalog station map, joins it, checks the
station build's tests and stops it again. No player world is touched.

    python3 services/supervisor/smoke_station.py --dreamdaemon /opt/byond/bin/DreamDaemon \
        --config-directory config --data-directory /tmp/smoke-station [--maps metastation boxstation]

The first map gets the full checks, including round control: the round waits for its owner,
starts on the owner's Start round and, once it ends, the world returns everyone to the lobby and
exits without a save (the supervisor records an ordinary stop). Further maps (used to vet the map
catalog) are only booted to the ready state, checked for the right map and late-join points, and
stopped. Finally a tutorial-kind world on the first map checks that its round starts by itself.
"""
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
from supervisor import Driver, Supervisor, serve


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dreamdaemon", required=True)
    parser.add_argument("--config-directory", required=True)
    parser.add_argument("--data-directory", required=True)
    parser.add_argument("--api-port", type=int, default=1378)
    parser.add_argument("--child-port", type=int, default=1468)
    parser.add_argument("--maps", nargs="+", default=["metastation"])
    parser.add_argument("--startup-timeout", type=int, default=900)
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
        with urllib.request.urlopen(request, timeout=180) as response:
            result = json.load(response)
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

    def checks(run, proc):
        result = debug(run, "call", dict(target="session", proc=proc, args=[]))["result"]
        values = {entry["entry"]: entry["value"] for entry in result["entries"]}
        assert values and all(values.values()), (proc, values)
        return values

    def stop(world):
        process = driver.processes.get(current()["id"])
        api("stop", {"world": world})
        deadline = time.time() + 120
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
            # The shared modules' tests (testing_common.dm), as the Babylon smoke runs them.
            for proc in ("test_sfw_content", "test_showcase_visitor", "test_moderation", "test_play_time",
                         "test_music_loops"):
                entry[proc] = checks(run, proc)
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
        else:
            stop(world)
        saves = data / "worlds" / world / "data/babylon/saves"
        assert not (saves / "latest.json").exists(), "a station world saved"
        entry["stopped_without_save"] = True
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
        for index, map_id in enumerate(args.maps):
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
        # A tutorial-kind world starts its round by itself (no owner hold).
        world = api("create", dict(name="Station smoke tutorial", visibility="private", map=args.maps[0]))["id"]
        with service.lock, service.db:
            service.db.execute("UPDATE worlds SET kind='tutorial', tutorial='smoke_tutorial' WHERE id=?", (world,))
        run = wait_ready(world)
        tutorial = dict(test_tutorial_round=checks(run, "test_tutorial_round"),
                        world_flags=checks(run, "test_station_world_flags"))
        stop(world)
        report["tutorial"] = tutorial
        print(json.dumps({"tutorial": tutorial}), flush=True)
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
