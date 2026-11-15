"""Restore stability, shared by smoke_native.py (Babylon) and smoke_station.py (station maps).

A world is created, started and stopped (saved), then started and stopped again `cycles` times.
Every save after a restore must hold the same objects, type by type, as the one before it: a
restore that makes anything anew on top of what was saved (decoration, objects another object
makes in its Initialize, CentCom's template) adds copies on every restart.
"""
from collections import Counter
import json
from pathlib import Path


def record_types(data, world):
    saves = Path(data) / "worlds" / world / "data/babylon/saves"
    generation = json.loads((saves / "latest.json").read_text())["generation"]
    state = json.loads((saves / generation / "state.json").read_text())
    counts = Counter()
    for record in state.get("records") or []:
        kind = record["type"]
        if kind.startswith("/obj/item/stack/"):
            # Stacks on one tile merge when they load: what must stay is their amount.
            counts[kind + " (amount)"] += (record.get("fields") or {}).get("amount") or 1
        else:
            counts[kind] += 1
    return generation, counts


def changes(before, after):
    """Types whose count differs, largest change first."""
    diff = {kind: after[kind] - before[kind] for kind in set(before) | set(after) if after[kind] != before[kind]}
    return dict(sorted(diff.items(), key=lambda item: (-abs(item[1]), item[0]))[:25])


def restore_cycles(world, start, stop, data, cycles=3, census=None):
    """start(world) waits until it runs (and returns the run), stop(world) until it exited after
    its save. census(run), if given, lists what the save leaves out (reported, not asserted).
    Returns the report; raises AssertionError if any restore changed the saved objects."""
    run = start(world)
    left_out = census(run) if census else None
    stop(world)
    generation, counts = record_types(data, world)
    report = dict(world=world, saves=[dict(generation=generation, records=sum(counts.values()))], changes=[],
                  left_out=left_out)
    for _ in range(cycles):
        start(world)
        stop(world)
        generation, after = record_types(data, world)
        report["saves"].append(dict(generation=generation, records=sum(after.values())))
        report["changes"].append(changes(counts, after))
        counts = after
    assert len({save["generation"] for save in report["saves"]}) == cycles + 1, report["saves"]
    # The first save is of a fresh world seconds after its start (monsters still digging out,
    # stacks not yet merged): its differences to the first restore are reported, not asserted.
    # From then on every restore must keep exactly what was saved; a copy made on load would
    # show up on each of them.
    assert not any(report["changes"][1:]), ("restores changed the saved objects", report)
    return report
