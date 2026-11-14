// TEMPORARY stubs so the Creative panel (panel.dm) compiles on its own. Each proc is removed when
// the task that owns it merges: the creative machines (E2), the tutorial wand (F1) and the
// tutorial markers (F tasks). Delete this whole file once all three exist.

/// removed when E2 merges: the creative machine type paths for the Spawn tab.
/proc/babylon_creative_machine_types()
	return list()

/// removed when F1 merges: the tutorial wand's type path, or null while there is none.
/proc/babylon_tutorial_wand_type()
	return null

/// removed when the tutorial markers merge: marker id => the marker atom (or its turf) a
/// creative player can teleport to. Only markers in this world.
/proc/babylon_tutorial_marker_targets()
	return list()
