/datum/ship_select

/datum/ship_select/ui_state(mob/user)
	return GLOB.always_state

/datum/ship_select/ui_status(mob/user, datum/ui_state/state)
	return isnewplayer(user) ? UI_INTERACTIVE : UI_CLOSE

/datum/ship_select/ui_interact(mob/user, datum/tgui/ui)
	ui = SStgui.try_update_ui(user, src, ui)
	if (!ui)
		ui = new(user, src, "ShipSelect")
		ui.open()

/datum/ship_select/ui_act(action, list/params, datum/tgui/ui, datum/ui_state/state)
	. = ..()
	if(.)
		return
	if(!isnewplayer(usr))
		return
	var/mob/dead/new_player/spawnee = usr
	switch(action)
		if("join")
			var/datum/overmap/ship/controlled/target = locate(params["ship"]) in SSovermap.controlled_ships
			var/datum/job/selected_job = locate(params["job"]) in target.job_slots
			if(join_ship(spawnee, target, selected_job))
				ui.close()

		if("buy")
			var/datum/map_template/shuttle/template = SSmapping.ship_purchase_list[params["name"]]
			buy_ship(template, spawnee, ui)

/datum/ship_select/ui_static_data(mob/user)
	// tracks the number of existing ships of each template type so that their unavailability for purchase can be communicated to the user
	var/list/template_num_lookup = list()

	. = list()
	.["ships"] = list()
	.["shipSpawnAllowed"] = SSovermap.player_ship_spawn_allowed()
	.["purchaseBanned"] = is_banned_from(user.ckey, "Ship Purchasing")
	.["playMin"] = user.client ? user.client.get_exp_living(TRUE) : 0

	for(var/datum/overmap/ship/controlled/S as anything in SSovermap.controlled_ships)
		if(S.source_template)
			if(!template_num_lookup[S.source_template])
				template_num_lookup[S.source_template] = 1
			else
				template_num_lookup[S.source_template] += 1
		if(!S.is_join_option())
			continue

		var/list/ship_jobs = list()
		for(var/datum/job/job as anything in S.job_slots)
			var/slots = S.job_slots[job]
			if(slots <= 0)
				continue
			ship_jobs += list(list(
				"name" = job,
				"slots" = slots,
				"minTime" = job.officer ? S.source_template.get_req_officer_minutes() : 0,
				"ref" = REF(job),
			))

		var/list/ship_data = list(
			"name" = S.name,
			"faction" = ship_prefix_to_faction(S.source_template.prefix),
			"class" = S.source_template.short_name,
			"desc" = S.source_template.description,
			"tags" = S.source_template.tags,
			"memo" = S.memo,
			"jobs" = ship_jobs,
			"manifest" = S.manifest,
			"joinMode" = S.join_mode,
			"ref" = REF(S)
		)

		.["ships"] += list(ship_data)

	.["templates"] = list()
	for(var/template_name as anything in SSmapping.ship_purchase_list)
		var/datum/map_template/shuttle/T = SSmapping.ship_purchase_list[template_name]
		if(!T.enabled)
			continue
		var/list/ship_data = list(
			"name" = T.name,
			"faction" = ship_prefix_to_faction(T.prefix),
			"desc" = T.description,
			"tags" = T.tags,
			"crewCount" = length(T.job_slots),
			"limit" = T.limit,
			"curNum" = template_num_lookup[T] || 0,
			"minTime" = T.get_req_spawn_minutes(),
		)
		.["templates"] += list(ship_data)

/datum/ship_select/proc/buy_ship(datum/map_template/shuttle/target_ship, mob/dead/new_player/shipowner, datum/tgui/ui)
	if(is_banned_from(shipowner.ckey, "Ship Purchasing"))
		to_chat(shipowner, span_danger("You are banned from purchasing ships!"))
		shipowner.new_player_panel()
		ui.close()
		return
	if(!SSovermap.player_ship_spawn_allowed())
		to_chat(shipowner, span_danger("No more ships may be spawned at this time!"))
		return
	if(!target_ship.enabled)
		to_chat(shipowner, span_danger("This ship is not currently available for purchase!"))
		return
	if(!target_ship.has_ship_spawn_playtime(shipowner.client))
		to_chat(shipowner, span_danger("You do not have enough playtime to spawn this ship!</span>"))
		return

	var/num_ships_with_template = 0
	for(var/datum/overmap/ship/controlled/Ship as anything in SSovermap.controlled_ships)
		if(target_ship == Ship.source_template)
			num_ships_with_template += 1
	if(num_ships_with_template >= target_ship.limit)
		to_chat(shipowner, span_danger("There are already [num_ships_with_template] ships of this type; you cannot spawn more!"))
		return
	ui.close()
	to_chat(shipowner, span_danger("Your [target_ship.name] is being prepared. Please be patient!"))
	var/datum/overmap/ship/controlled/target = SSovermap.spawn_ship_at_start(target_ship)
	if(!target?.shuttle_port)
		to_chat(shipowner, span_danger("There was an error loading the ship. Please contact admins!"))
		shipowner.new_player_panel()
		return
	SSblackbox.record_feedback("tally", "ship_purchased", 1, target_ship.name) //If you are copy-pasting this, ensure the 2nd parameter is unique to the new proc!
	// Try to spawn as the first listed job in the job slots (usually captain)
	// Playtime checks are overridden, to ensure the player gets to join the ship they spawned.
	if(!shipowner.AttemptLateSpawn(target.job_slots[1], target, FALSE))
		to_chat(shipowner, span_danger("Ship spawned, but you were unable to be spawned. You can likely try to spawn in the ship through joining normally, but if not, please contact an admin."))
		shipowner.new_player_panel()

/datum/ship_select/proc/join_ship(mob/dead/new_player/spawnee, datum/overmap/ship/controlled/target, datum/job/selected_job)
	if(!target)
		to_chat(spawnee, "<span class='danger'>Unable to locate ship. Please contact admins!</span>")
		spawnee.new_player_panel()
		return FALSE
	if(!target.is_join_option())
		to_chat(spawnee, "<span class='danger'>This ship is not currently accepting new players!</span>")
		spawnee.new_player_panel()
		return FALSE

	var/did_application = FALSE
	if(target.join_mode == SHIP_JOIN_MODE_APPLY)
		var/datum/ship_application/current_application = target.get_application(spawnee)
		if(isnull(current_application))
			var/datum/ship_application/app = new(spawnee, target)
			if(app.get_user_response())
				to_chat(spawnee, "<span class='notice'>Ship application sent. You will be notified if the application is accepted.</span>")
			else
				to_chat(spawnee, "<span class='notice'>Application cancelled, or there was an error sending the application.</span>")
			return FALSE
		switch(current_application.status)
			if(SHIP_APPLICATION_ACCEPTED)
				to_chat(spawnee, "<span class='notice'>Your ship application was accepted, continuing...</span>")
			if(SHIP_APPLICATION_PENDING)
				alert(spawnee, "You already have a pending application for this ship!")
				return FALSE
			if(SHIP_APPLICATION_DENIED)
				alert(spawnee, "You can't join this ship, as a previous application was denied!")
				return FALSE
		did_application = TRUE

	if(target.join_mode == SHIP_JOIN_MODE_CLOSED || (target.join_mode == SHIP_JOIN_MODE_APPLY && !did_application))
		to_chat(spawnee, "<span class='warning'>You cannot join this ship anymore, as its join mode has changed!</span>")
		return FALSE
	// Attempts the spawn itself. This checks for playtime requirements.
	if(!spawnee.AttemptLateSpawn(selected_job, target))
		to_chat(spawnee, "<span class='danger'>Unable to spawn on ship!</span>")
		spawnee.new_player_panel()
		return FALSE
	return TRUE
