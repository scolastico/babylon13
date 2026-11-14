// Integration test of the creative machines (machines.dm), shared by both test builds.
// Every machine in each mode in three worlds: Creative (active, configurable), a tutorial
// instance without Creative (active, not configurable) and an ordinary world (inert). Settings
// go through the real Ctrl+Shift click path of a player body, with the prompts answered from
// GLOB.babylon_creative_test_answers. The world's flags are restored afterwards.

/datum/babylon_save/proc/test_creative_machines()
	var/list/result = list()
	var/was_creative = GLOB.babylon_world.creative
	var/was_kind = GLOB.babylon_world.kind
	var/turf/place = respawn_turf
	var/list/made = list()
	// The acting player body: a drone in Babylon, a human in station worlds.
	var/body_type = babylon_is_station_build() ? /mob/living/carbon/human/dummy : text2path("/mob/living/basic/drone/babylon/replacement")
	var/mob/living/tester = new body_type(place)

	var/list/types = babylon_creative_machine_types()
	var/all_machines = length(types) > 0
	for(var/path in types)
		all_machines = all_machines && ispath(path, /obj/machinery)
	result["machine_types"] = all_machines
	var/fields_saved = TRUE
	for(var/field in list("creative_mode", "creative_gas", "creative_pressure", "creative_reagent", "creative_item", "creative_interval"))
		fields_saved = fields_saved && (field in extra_fields)
	result["settings_saved"] = fields_saved
	result["item_rules"] = babylon_creative_item_allowed(/obj/item/stack/sheet/iron) && !babylon_creative_item_allowed(/obj/item) && !babylon_creative_item_allowed(/obj/item/grenade/flashbang) && !babylon_creative_item_allowed(/obj/machinery/vending) && !babylon_creative_item_allowed(/obj/item/clothing/sextoy)
	var/obj/item/crowbar_path = /obj/item/crowbar
	var/crowbar_entry = "[initial(crowbar_path.name)] ([crowbar_path])"
	var/list/by_name = babylon_creative_item_matches("CROWBAR", 5000)
	var/found_iron = FALSE
	var/list/iron = babylon_creative_item_matches("iron", 5000)
	for(var/entry in iron)
		found_iron = found_iron || ispath(iron[entry], /obj/item/stack/sheet/iron)
	var/lewd_listed = FALSE
	var/list/collars = babylon_creative_item_matches("collar", 2000)
	for(var/entry in collars)
		lewd_listed = lewd_listed || babylon_creative_item_blocked(collars[entry])
	result["item_search_by_name"] = by_name[crowbar_entry] == /obj/item/crowbar && found_iron && !lewd_listed
	result["gas_rules"] = babylon_creative_gas_allowed(/datum/gas/nitrogen) && !babylon_creative_gas_allowed(/datum/gas) && babylon_creative_gas_choices()["Nitrogen"] == /datum/gas/nitrogen
	result["reagent_rules"] = babylon_creative_reagent_allowed(/datum/reagent/water) && !babylon_creative_reagent_allowed(/datum/reagent) && !babylon_creative_reagent_allowed(/datum/reagent/drug/aphrodisiac)

	for(var/world_state in list("creative", "tutorial", "off"))
		GLOB.babylon_world.creative = world_state == "creative"
		GLOB.babylon_world.kind = world_state == "tutorial" ? "tutorial" : "world"
		var/active = world_state != "off"
		result["machines_active_[world_state]"] = babylon_creative_machines_active() == active

		// SMES source: own powernet, no terminal.
		var/obj/machinery/power/smes/babylon_creative/source = new(place)
		made += source
		source.disconnect_from_network()
		var/datum/powernet/source_net = new()
		source_net.add_machine(source)
		source.adjust_charge(-source.total_charge())
		source.output_attempt = TRUE
		source.output_level = 100 KILO WATTS
		source.process(1)
		source.process(1)
		var/full = source.total_charge() >= source.total_capacity
		if(active)
			result["smes_source_[world_state]"] = !(source.machine_stat & BROKEN) && full && source.outputting && source.output_used > 0 && source_net.newavail > 0
		else
			result["smes_source_[world_state]"] = !full && source_net.newavail == 0
		source_net.remove_machine(source)

		// SMES sink: processes before a consumer (the worst order for the consumer), which must
		// still get all the power; the sink only counts what is left over afterwards.
		var/obj/machinery/power/smes/babylon_creative/sink/sink = new(place)
		made += sink
		sink.disconnect_from_network()
		var/obj/machinery/power/terminal/consumer = new(place)
		made += consumer
		consumer.disconnect_from_network()
		var/datum/powernet/sink_net = new()
		sink_net.add_machine(sink)
		sink_net.add_machine(consumer)
		sink_net.avail = 500 KILO WATTS
		sink.process(1)
		var/consumer_sees = consumer.surplus()
		consumer.add_load(200 KILO WATTS)
		var/consumer_powered = consumer_sees == 500 KILO WATTS && sink_net.load == 200 KILO WATTS
		sink_net.reset()
		sink.process(1)
		if(active)
			result["smes_sink_[world_state]"] = consumer_powered && sink.input_available == 300 KILO WATTS && sink.inputting && !sink.outputting && sink.total_charge() == 0
		else
			result["smes_sink_[world_state]"] = consumer_powered && sink.input_available == 0
		sink_net.remove_machine(sink)
		sink_net.remove_machine(consumer)

		// Canisters.
		var/obj/machinery/portable_atmospherics/canister/babylon_creative/canister = new(place)
		made += canister
		canister.air_contents.remove(canister.air_contents.total_moles())
		canister.process_atmos()
		var/pressure = canister.air_contents.return_pressure()
		if(active)
			result["canister_source_[world_state]"] = abs(pressure - canister.creative_pressure) < 1 && canister.air_contents.moles[/datum/gas/oxygen] > 0
			canister.set_creative_settings("source", /datum/gas/nitrogen, 2000)
			canister.process_atmos()
			var/switched = abs(canister.air_contents.return_pressure() - 2000) < 1 && !canister.air_contents.moles[/datum/gas/oxygen] && canister.name == "creative canister (nitrogen source)"
			// Cold gas: refilled at room temperature, not with ever more moles.
			canister.air_contents.remove(canister.air_contents.total_moles())
			canister.air_contents.adjust_gas(/datum/gas/nitrogen, 1)
			canister.air_contents.temperature = 50
			canister.process_atmos()
			result["canister_switch_and_cold_[world_state]"] = switched && canister.air_contents.temperature >= T20C && abs(canister.air_contents.return_pressure() - 2000) < 1
		else
			result["canister_source_[world_state]"] = pressure == 0
		var/obj/machinery/portable_atmospherics/canister/babylon_creative/void/void_canister = new(place)
		made += void_canister
		void_canister.air_contents.adjust_gas(/datum/gas/nitrogen, 50)
		void_canister.process_atmos()
		result["canister_void_[world_state]"] = active ? void_canister.air_contents.total_moles() == 0 : void_canister.air_contents.total_moles() >= 50

		// Plumbing tanks.
		var/obj/machinery/plumbing/babylon_creative_tank/tank = new(place)
		made += tank
		tank.reagents.add_reagent(/datum/reagent/consumable/sugar, 20)
		tank.process(1)
		if(active)
			result["tank_source_[world_state]"] = tank.reagents.total_volume == tank.reagents.maximum_volume && tank.reagents.has_reagent(/datum/reagent/water, tank.reagents.maximum_volume) && !tank.reagents.has_reagent(/datum/reagent/consumable/sugar)
		else
			result["tank_source_[world_state]"] = tank.reagents.total_volume == 20
		var/obj/machinery/plumbing/babylon_creative_tank/void/void_tank = new(place)
		made += void_tank
		void_tank.reagents.add_reagent(/datum/reagent/water, 50)
		void_tank.process(1)
		result["tank_void_[world_state]"] = active ? void_tank.reagents.total_volume == 0 : void_tank.reagents.total_volume == 50

		// Disposal source: needs a trunk below to flush into; pauses at its output cap.
		var/obj/structure/disposalpipe/trunk/trunk = new(place)
		made += trunk
		var/obj/machinery/disposal/bin/babylon_creative/bin = new(place)
		made += bin
		bin.trunk_check()
		bin.creative_max_out = 1
		bin.process(1)
		var/obj/item/stack/sheet/iron/sent = locate() in bin
		if(sent)
			made += sent
		if(active)
			var/first_sent = !!sent && bin.flushing && bin.creative_next > world.time
			bin.flushing = FALSE
			bin.creative_next = 0
			bin.process(1)
			var/sheets = 0
			for(var/obj/item/stack/sheet/iron/sheet in bin)
				sheets++
			var/paused_shown = FALSE
			for(var/line in bin.examine(tester))
				paused_shown = paused_shown || findtext(line, "Paused: 1 of its items")
			result["disposal_source_[world_state]"] = first_sent && sheets == 1 && bin.creative_items_out() == 1 && paused_shown
			// What a source makes may not carry blocked things inside it.
			bin.creative_item = /obj/item/storage/box/flashbangs
			var/obj/item/box = bin.creative_spawn()
			made += box
			result["disposal_inner_blocked_[world_state]"] = !!box && !length(box.get_all_contents_type(/obj/item/grenade))
		else
			result["disposal_source_[world_state]"] = !sent

		// Disposal void: things put inside and things arriving by pipe; mobs are put out.
		var/obj/machinery/disposal/bin/babylon_creative/void/void_bin = new(place)
		made += void_bin
		var/obj/item/stack/rods/dropped = new(void_bin)
		made += dropped
		void_bin.process(1)
		var/obj/structure/disposalholder/holder = new(void_bin)
		var/obj/item/stack/rods/arrived = new(holder)
		var/mob/living/basic/mouse/passenger = new(holder)
		made += list(holder, arrived, passenger)
		void_bin.expel(holder)
		if(active)
			result["disposal_void_[world_state]"] = QDELETED(dropped) && QDELETED(arrived) && QDELETED(holder) && !QDELETED(passenger) && passenger.loc == get_turf(void_bin)
		else
			result["disposal_void_[world_state]"] = !QDELETED(dropped) && !QDELETED(arrived) && !QDELETED(passenger)

		// Settings through the player's Ctrl+Shift click; only Creative worlds accept them.
		var/obj/machinery/power/smes/babylon_creative/clicked_smes = new(place)
		var/obj/machinery/portable_atmospherics/canister/babylon_creative/clicked_canister = new(place)
		var/obj/machinery/plumbing/babylon_creative_tank/clicked_tank = new(place)
		var/obj/machinery/disposal/bin/babylon_creative/clicked_bin = new(place)
		made += list(clicked_smes, clicked_canister, clicked_tank, clicked_bin)
		var/datum/reagent/sugar = GLOB.chemical_reagents_list[/datum/reagent/consumable/sugar]
		if(world_state == "creative")
			var/list/reached = list()
			GLOB.babylon_creative_test_answers = list("sink")
			tester.base_click_ctrl_shift(clicked_smes)
			reached["smes_sink"] = clicked_smes.creative_mode == "sink" && !clicked_smes.output_attempt
			GLOB.babylon_creative_test_answers = list("Source - never runs dry, outputs its output level")
			tester.base_click_ctrl_shift(clicked_smes)
			reached["smes_source"] = clicked_smes.creative_mode == "source" && clicked_smes.output_attempt && clicked_smes.name == "creative SMES (source)"
			GLOB.babylon_creative_test_answers = list("source", "Nitrogen", 3000)
			tester.base_click_ctrl_shift(clicked_canister)
			clicked_canister.process_atmos()
			reached["canister"] = clicked_canister.creative_gas == /datum/gas/nitrogen && clicked_canister.creative_pressure == 3000
			GLOB.babylon_creative_test_answers = list("source", "Nitrogen", 3500)
			tester.base_click_ctrl_shift(clicked_canister)
			reached["canister_pressure_keeps_gas"] = clicked_canister.creative_pressure == 3500 && clicked_canister.air_contents.return_pressure() > 2900
			GLOB.babylon_creative_test_answers = list("source", sugar.name)
			tester.base_click_ctrl_shift(clicked_tank)
			reached["tank"] = clicked_tank.creative_reagent == /datum/reagent/consumable/sugar
			GLOB.babylon_creative_test_answers = list("source", "crowbar", crowbar_entry, 5)
			tester.base_click_ctrl_shift(clicked_bin)
			reached["disposal"] = clicked_bin.creative_item == /obj/item/crowbar && clicked_bin.creative_interval == 5 && findtext(clicked_bin.name, "every 5 s")
			reached["all_answers_used"] = !length(GLOB.babylon_creative_test_answers)
			var/all_reached = TRUE
			for(var/key in reached)
				all_reached = all_reached && reached[key]
			result["configure_by_click_creative"] = all_reached
		else
			var/refused = TRUE
			for(var/obj/machinery/machine as anything in list(clicked_smes, clicked_canister, clicked_tank, clicked_bin))
				GLOB.babylon_creative_test_answers = list("void", "sink")
				tester.base_click_ctrl_shift(machine)
				refused = refused && length(GLOB.babylon_creative_test_answers) == 2 && machine.vars["creative_mode"] == "source"
			result["configure_refused_[world_state]"] = refused
		GLOB.babylon_creative_test_answers = null

		for(var/datum/thing as anything in made)
			if(QDELETED(thing))
				continue
			if(istype(thing, /obj/machinery/portable_atmospherics))
				var/obj/machinery/portable_atmospherics/portable = thing
				// Do not dump the test gas onto the floor.
				portable.air_contents.remove(portable.air_contents.total_moles())
			qdel(thing)
		made.Cut()

	// Settings survive a save: capture, JSON round trip, apply as restore_world does.
	var/obj/machinery/disposal/bin/babylon_creative/saved_bin = new(place)
	saved_bin.set_creative_settings("source", /obj/item/crowbar, 7)
	var/obj/machinery/portable_atmospherics/canister/babylon_creative/saved_canister = new(place)
	saved_canister.set_creative_settings("void", /datum/gas/plasma, 1234)
	var/roundtrip = TRUE
	for(var/obj/machinery/original as anything in list(saved_bin, saved_canister))
		var/list/record = json_decode(json_encode(capture(original, list(), null)))
		var/obj/machinery/copy = new original.type(place)
		var/list/fields = record["fields"]
		for(var/field in fields)
			if(field in copy.vars)
				copy.vars[field] = decode_value(fields[field])
		for(var/field in list("name", "creative_mode", "creative_gas", "creative_pressure", "creative_item", "creative_interval"))
			if(field in original.vars)
				roundtrip = roundtrip && copy.vars[field] == original.vars[field]
		if(istype(copy, /obj/machinery/portable_atmospherics))
			var/obj/machinery/portable_atmospherics/portable = copy
			portable.air_contents.remove(portable.air_contents.total_moles())
		qdel(copy)
	result["settings_roundtrip"] = roundtrip && saved_bin.creative_item == /obj/item/crowbar && saved_canister.creative_gas == /datum/gas/plasma
	saved_canister.air_contents.remove(saved_canister.air_contents.total_moles())
	qdel(saved_bin)
	qdel(saved_canister)
	qdel(tester)

	GLOB.babylon_world.kind = "world"
	GLOB.babylon_world.creative = FALSE
	var/list/shown = list()
	babylon_creative_examine(shown, "summary")
	result["examine_off"] = length(shown) == 1 && findtext(shown[1], "Creative mode is off in this world.")
	GLOB.babylon_world.creative = TRUE
	shown.Cut()
	babylon_creative_examine(shown, "summary")
	result["examine_on"] = length(shown) == 1 && findtext(shown[1], "summary") && findtext(shown[1], "Ctrl + Shift + click")
	GLOB.babylon_world.creative = was_creative
	GLOB.babylon_world.kind = was_kind
	return result
