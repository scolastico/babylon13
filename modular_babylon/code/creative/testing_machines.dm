// Integration test of the creative machines (machines.dm), shared by both test builds.
// Every machine in each mode with Creative on, and inert with Creative off. The world's
// creative flag is restored afterwards.

/datum/babylon_save/proc/test_creative_machines()
	var/list/result = list()
	var/was_creative = GLOB.babylon_world.creative
	var/turf/place = respawn_turf
	var/list/made = list()

	var/list/types = babylon_creative_machine_types()
	var/all_machines = length(types) > 0
	for(var/path in types)
		all_machines = all_machines && ispath(path, /obj/machinery)
	result["machine_types"] = all_machines
	var/fields_saved = TRUE
	for(var/field in list("creative_mode", "creative_gas", "creative_pressure", "creative_reagent", "creative_item", "creative_interval"))
		fields_saved = fields_saved && (field in extra_fields)
	result["settings_saved"] = fields_saved
	result["item_rules"] = babylon_creative_item_allowed(/obj/item/stack/sheet/iron) && !babylon_creative_item_allowed(/obj/item) && !babylon_creative_item_allowed(/obj/item/grenade/flashbang) && !babylon_creative_item_allowed(/obj/machinery/vending)
	result["gas_rules"] = babylon_creative_gas_allowed(/datum/gas/nitrogen) && !babylon_creative_gas_allowed(/datum/gas) && babylon_creative_gas_choices()["Nitrogen"] == /datum/gas/nitrogen
	result["reagent_rules"] = babylon_creative_reagent_allowed(/datum/reagent/water) && !babylon_creative_reagent_allowed(/datum/reagent) && !babylon_creative_reagent_allowed(/datum/reagent/drug/aphrodisiac)

	for(var/creative in list(TRUE, FALSE))
		GLOB.babylon_world.creative = creative
		var/suffix = creative ? "on" : "off"

		// SMES: own powernet, no terminal.
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
		if(creative)
			result["smes_source_on"] = !(source.machine_stat & BROKEN) && full && source.outputting && source.output_used > 0 && source_net.newavail > 0
		else
			result["smes_source_off"] = !full && source_net.newavail == 0
		source_net.remove_machine(source)

		var/obj/machinery/power/smes/babylon_creative/sink/sink = new(place)
		made += sink
		sink.disconnect_from_network()
		var/datum/powernet/sink_net = new()
		sink_net.add_machine(sink)
		sink_net.avail = 500 KILO WATTS
		sink.process(1)
		if(creative)
			result["smes_sink_on"] = sink_net.load == 500 KILO WATTS && sink.total_charge() == 0 && sink.inputting && !sink.outputting
		else
			result["smes_sink_off"] = sink_net.load == 0
		sink_net.remove_machine(sink)

		// Canisters.
		var/obj/machinery/portable_atmospherics/canister/babylon_creative/canister = new(place)
		made += canister
		canister.air_contents.remove(canister.air_contents.total_moles())
		canister.process_atmos()
		var/pressure = canister.air_contents.return_pressure()
		if(creative)
			result["canister_source_on"] = abs(pressure - canister.creative_pressure) < 1 && canister.air_contents.moles[/datum/gas/oxygen] > 0
			canister.set_creative_settings("source", /datum/gas/nitrogen, 2000)
			canister.process_atmos()
			result["canister_source_gas_on"] = abs(canister.air_contents.return_pressure() - 2000) < 1 && !canister.air_contents.moles[/datum/gas/oxygen] && canister.name == "creative canister (nitrogen source)"
		else
			result["canister_source_off"] = pressure == 0
		var/obj/machinery/portable_atmospherics/canister/babylon_creative/void/void_canister = new(place)
		made += void_canister
		void_canister.air_contents.adjust_gas(/datum/gas/nitrogen, 50)
		void_canister.process_atmos()
		result["canister_void_[suffix]"] = creative ? void_canister.air_contents.total_moles() == 0 : void_canister.air_contents.total_moles() >= 50

		// Plumbing tanks.
		var/obj/machinery/plumbing/babylon_creative_tank/tank = new(place)
		made += tank
		tank.reagents.add_reagent(/datum/reagent/consumable/sugar, 20)
		tank.process(1)
		if(creative)
			result["tank_source_on"] = tank.reagents.total_volume == tank.reagents.maximum_volume && tank.reagents.has_reagent(/datum/reagent/water, tank.reagents.maximum_volume) && !tank.reagents.has_reagent(/datum/reagent/consumable/sugar)
		else
			result["tank_source_off"] = tank.reagents.total_volume == 20
		var/obj/machinery/plumbing/babylon_creative_tank/void/void_tank = new(place)
		made += void_tank
		void_tank.reagents.add_reagent(/datum/reagent/water, 50)
		void_tank.process(1)
		result["tank_void_[suffix]"] = creative ? void_tank.reagents.total_volume == 0 : void_tank.reagents.total_volume == 50

		// Disposal source: needs a trunk below to flush into.
		var/obj/structure/disposalpipe/trunk/trunk = new(place)
		made += trunk
		var/obj/machinery/disposal/bin/babylon_creative/bin = new(place)
		made += bin
		bin.trunk_check()
		bin.process(1)
		var/obj/item/stack/sheet/iron/sent = locate() in bin
		if(creative)
			result["disposal_source_on"] = !!sent && bin.flushing && bin.creative_next > world.time
		else
			result["disposal_source_off"] = !sent
		if(sent)
			made += sent

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
		if(creative)
			result["disposal_void_on"] = QDELETED(dropped) && QDELETED(arrived) && QDELETED(holder) && !QDELETED(passenger) && passenger.loc == get_turf(void_bin)
		else
			result["disposal_void_off"] = !QDELETED(dropped) && !QDELETED(arrived) && !QDELETED(passenger)

		for(var/datum/thing as anything in made)
			if(QDELETED(thing))
				continue
			if(istype(thing, /obj/machinery/portable_atmospherics))
				var/obj/machinery/portable_atmospherics/portable = thing
				// Do not dump the test gas onto the floor.
				portable.air_contents.remove(portable.air_contents.total_moles())
			qdel(thing)
		made.Cut()

	var/list/shown = list()
	babylon_creative_examine(shown, "summary")
	result["examine_off"] = length(shown) == 1 && findtext(shown[1], "Creative mode is off in this world.")
	GLOB.babylon_world.creative = TRUE
	shown.Cut()
	babylon_creative_examine(shown, "summary")
	result["examine_on"] = length(shown) == 2 && findtext(shown[1], "summary")
	GLOB.babylon_world.creative = was_creative
	return result
