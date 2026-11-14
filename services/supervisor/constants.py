"""Values shared by the supervisor, its driver and the container configuration."""

# A world's kind: a normal player world, a tutorial run by a player, or a tutorial being edited.
WORLD_KINDS = ("world", "tutorial", "tutorial_edit")
# The kind of an ordinary player world.
WORLD_KIND = WORLD_KINDS[0]
# Kinds whose world starts from a tutorial snapshot instead of a player save.
TUTORIAL_KINDS = ("tutorial", "tutorial_edit")

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
    # Hours a player waits between two tutorial submissions (0 turns the cooldown off).
    "tutorial_submit_cooldown_hours": 6,
}
