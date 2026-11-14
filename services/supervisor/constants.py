"""Values shared by the supervisor, its driver and the container configuration."""

# A world's kind: a normal player world, a tutorial run by a player, or a tutorial being edited.
WORLD_KINDS = ("world", "tutorial", "tutorial_edit")
# The kind of an ordinary player world.
WORLD_KIND = WORLD_KINDS[0]
# Kinds whose world starts from a tutorial snapshot instead of a player save.
TUTORIAL_KINDS = ("tutorial", "tutorial_edit")
# Longest tutorial title and description (characters after cleaning); the DM side has the same limits
# (modular_babylon/code/tutorial/submit.dm, checked by test_contracts.py).
TUTORIAL_TITLE_MAX = 60
TUTORIAL_DESCRIPTION_MAX = 500
# A file in a save generation that a world wrote only as a tutorial snapshot (a submission or save
# back; modular_babylon/code/persistence.dm writes it). Such a generation is never a checkpoint:
# Checkpoints neither lists nor restores it and deletes it once it is old, and tutorial copies leave
# the file out.
TUTORIAL_SNAPSHOT_MARKER = "tutorial-snapshot"
# Seconds after which a tutorial snapshot left in a world's saves (its world stopped, or the
# supervisor's answer never arrived) is deleted.
TUTORIAL_SNAPSHOT_MAX_AGE = 15 * 60


def world_policy(build, persistent, creative, kind, map_id):
    """What a world of this type may do: the supervisor's copy of the DM policy table in
    modular_babylon/code/world_flags.dm (/datum/babylon_world). test_contracts.py checks that both
    give the same answers for every world type."""
    tutorial = kind in TUTORIAL_KINDS
    plane = str(map_id or "").startswith("creative_plane")
    creative = bool(creative)
    tutorial_capable = build == "station" and creative
    saves = bool(persistent) and not tutorial
    return {
        "creative_enabled": creative,
        "tutorial_capable": tutorial_capable,
        "can_submit_tutorial": tutorial_capable and kind == WORLD_KIND,
        "can_save_back_tutorial": kind == "tutorial_edit",
        "creative_machines_active": creative or tutorial or plane,
        "delam_contained": creative or tutorial or plane,
        "storyteller_inert": build == "babylon" or tutorial or plane,
        "saves": saves,
        "stop_saves": saves,
        "round_starts_at_once": tutorial,
        "plays_tutorial_on_join": kind == "tutorial",
        "unsaved_as_tutorial": tutorial,
        "saves_characters": not tutorial,
    }


# Whether a checkpoint of a world of each kind keeps the players' characters and per-player records
# (world_policy()["saves_characters"]; world_flags.dm saves_characters()). A forced tutorial snapshot
# (a submission or save-back) never keeps them, whatever the kind; tutorials.py blanks them in every
# snapshot it copies.
SAVES_CHARACTERS = {kind: world_policy("station", 1, 1, kind, None)["saves_characters"] for kind in WORLD_KINDS}


# Configuration defaults used wherever the configuration does not name a value.
DEFAULTS = {
    "kept_save_points_per_world": 4,
    "delete_unused_worlds_after_days": 60,
    "afk_timeout_seconds": 900,
    "max_total_worlds_per_player": 20,
    "empty_grace_seconds": 120,
    "startup_timeout_seconds": 300,
    # Station-build worlds boot a full tg round (several z-levels); measured 77-167 s.
    "station_startup_timeout_seconds": 600,
    "ticket_lifetime_seconds": 60,
    # Minutes between autosaves of station-build worlds (a save pauses the world for about a minute).
    "station_autosave_minutes": 30,
    # Hours a player waits between two tutorial submissions (0 turns the cooldown off).
    "tutorial_submit_cooldown_hours": 6,
}
