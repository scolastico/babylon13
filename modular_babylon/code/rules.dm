// Babylon's own world rules. Compiled only into babylon.dmb: the station build runs normal
// tg rounds with events, the storyteller, weather and minor mapping, on multi-z maps.

/world
	maxx = 255
	maxy = 255
	maxz = 1

// This standalone building session has no random encounters or event tracks.
/datum/controller/subsystem/events
	ss_flags = SS_NO_FIRE

/datum/controller/subsystem/gamemode
	ss_flags = SS_NO_FIRE

/datum/controller/subsystem/weather
	ss_flags = SS_NO_FIRE

/datum/controller/subsystem/minor_mapping/Initialize()
	// Reopening a builder world must not seed new critters, loot or weakpoints.
	return SS_INIT_NO_NEED
