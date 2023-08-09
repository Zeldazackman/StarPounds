require "/scripts/messageutil.lua"
require "/scripts/util.lua"
require "/scripts/vec2.lua"
require "/scripts/status.lua"

local function nullFunction()
end

starPounds = {
	settings = root.assetJson("/scripts/starpounds/starpounds.config:settings"),
	sizes = root.assetJson("/scripts/starpounds/starpounds_sizes.config"),
	stats = root.assetJson("/scripts/starpounds/starpounds_stats.config"),
	skills = root.assetJson("/scripts/starpounds/starpounds_skills.config:skills"),
	species = root.assetJson("/scripts/starpounds/starpounds_species.config"),
	baseData = root.assetJson("/scripts/starpounds/starpounds.config:baseData")
}
-- Mod functions
----------------------------------------------------------------------------------
starPounds.isEnabled = function()
	return storage.starPounds.enabled
end

starPounds.getData = function(key)
	if key then return storage.starPounds[key] end
	return storage.starPounds
end

starPounds.digest = function(dt, isGurgle, bloatMultiplier)
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return end
	-- Argument sanitisation.
	dt = math.max(tonumber(dt) or 0, 0)
	if dt == 0 then return end
	bloatMultiplier = tonumber(bloatMultiplier) or 1
	-- Don't do anything if stomach is empty.
	if starPounds.stomach.contents == 0 then
		starPounds.gurgleTimer, starPounds.rumbleTimer = nil
		starPounds.voreDigestTimer = 0
		return
	end

	if not isGurgle then
		-- Vore stuff
		if not starPounds.hasOption("disablePredDigestion") then
			-- Timer overrun incase function is called directly with multiple seconds.
			local diff = math.abs(math.min((starPounds.voreDigestTimer or 0) - dt, 0))
			starPounds.voreDigestTimer = math.max((starPounds.voreDigestTimer or 0) - dt, 0)
			if starPounds.voreDigestTimer == 0 then
				starPounds.voreDigestTimer = starPounds.settings.voreDigestTimer
				starPounds.voreDigest(starPounds.settings.voreDigestTimer + diff)
			end
		end
		-- Gurgle stuff.
		if not starPounds.hasOption("disableGurgles") then
			if starPounds.gurgleTimer and starPounds.gurgleTimer > 0 then
				starPounds.gurgleTimer = math.max(starPounds.gurgleTimer - (dt * starPounds.getStat("gurgleRate")), 0)
			else
				-- gurgleTime (default 30) is the average, minimumGurgleTime (default 5) is the minimum, so (5 + (60 - 5))/2 = 30
				if starPounds.gurgleTimer then starPounds.gurgle() end
				starPounds.gurgleTimer = math.round(util.randomInRange({starPounds.settings.minimumGurgleTime, (starPounds.settings.gurgleTime * 2) - starPounds.settings.minimumGurgleTime}))
			end
		end
		-- Ditto but for rumbles.
		if not starPounds.hasOption("disableRumbles") then
			if starPounds.rumbleTimer and starPounds.rumbleTimer > 0 then
				starPounds.rumbleTimer = math.max(starPounds.rumbleTimer - (dt * starPounds.getStat("gurgleRate")), 0)
			else
				if starPounds.rumbleTimer then starPounds.rumble() end
				starPounds.rumbleTimer = math.round(util.randomInRange({starPounds.settings.minimumRumbleTime, (starPounds.settings.rumbleTime * 2) - starPounds.settings.minimumRumbleTime}))
			end
		end
	elseif not starPounds.hasOption("disablePredDigestion") then
		-- 25% strength for vore digestion on gurgles.
		starPounds.voreDigest(dt * 0.25)
	end

	local food = storage.starPounds.stomach
	local bloat = storage.starPounds.bloat
	-- Skip the rest if there's nothing to digest.
	if food == 0 and bloat == 0 then return end
	-- Split between food and bloat.
	local foodRatio = math.min(math.max(math.round(food/(food + bloat), 2), (food > 0) and 0.05 or 0), (bloat > 0) and 0.95 or 1)
	-- Amount is 1 + 1% of food value, or the remaining food value.
	local amount = math.min(math.round((food/100 + 1) * starPounds.getStat("digestion") * foodRatio * dt, 4), food)
	storage.starPounds.stomach = math.round(math.max(food - amount, 0), 3)
	-- Ditto for bloat.
	local bloatAmount = math.min(math.round((bloat/100 + 1) * starPounds.getStat("digestion") * (1 - foodRatio) * starPounds.getStat("bloatDigestion") * bloatMultiplier * dt, 4), bloat)
	storage.starPounds.bloat = math.round(math.max(bloat - bloatAmount, 0), 3)
	-- Don't need to run the rest if there's no actual food.
	if amount == 0 then return end
	-- Subtract food used to fill up hunger from weight gain.
	if status.isResource("food") then
		-- Food for weight gain reduced by up to half when filling hunger, with hunger restored increased by absorption.
		local foodAmount = math.min(status.resourceMax("food") - status.resource("food"), amount)
		amount = math.round(amount - (foodAmount/2), 4)
		status.giveResource("food", foodAmount * math.max(starPounds.getStat("absorption")/starPounds.stats.absorption.base, 1) + (not isGurgle and math.abs(math.min(status.stat("foodDelta") * dt, 0)) or 0))
	end
	-- Don't need to run the rest if there's no actual food after we divert some to hunger.
	if amount == 0 then return end
	-- Costs double the food value to produce.
	local milkRatio = starPounds.settings.drinkables[starPounds.breasts.type] * 2
	local milkProduced = 0
	local milkCost = 0
	local milkCurrent = storage.starPounds.breasts
	local milkCapacity = starPounds.breasts.capacity
	if (starPounds.getStat("breastProduction") > 0) and not starPounds.hasOption("disableMilkGain") then
		local maxCapacity = milkCapacity * (starPounds.hasOption("disableLeaking") and 1 or 1.1)
		if starPounds.breasts.contents < maxCapacity then
			milkCost = amount * starPounds.getStat("absorption") * starPounds.getStat("breastProduction")
			milkProduced = math.round((milkCost/milkRatio) * starPounds.getStat("breastEfficiency"), 4)
			if (milkCapacity - milkCurrent) < milkProduced then
				-- Free after you've maxed out capacity, but you only gain a third as much.
				milkProduced = math.min(math.max((milkCapacity - milkCurrent), milkProduced/3), maxCapacity - milkCurrent)
				milkCost = math.max(0, milkCapacity - milkCurrent) * milkRatio/starPounds.getStat("breastEfficiency")
			end
			starPounds.gainMilk(milkProduced)
		end
	end
	-- Gain weight based on amount digested, milk production, and digestion efficiency.
	starPounds.gainWeight((amount * starPounds.getStat("absorption")) - milkCost)
	-- Don't heal if eaten.
	if not storage.starPounds.pred then
		-- Base amount 1 health (100 food would restore 100 health, modified by healing and absorption)
		if status.resourcePositive("health") then
			status.modifyResource("health", amount * starPounds.getStat("absorption") * starPounds.getStat("healing"))
		end
		-- Energy regenerates faster than health, and energy lock time gets reduced.
		if not isGurgle and status.isResource("energy") and status.resourcePercentage("energy") < 1 and starPounds.getStat("digestionEnergy") > 0 then
			if not status.resourcePositive("energyRegenBlock") and status.resourcePercentage("energy") < 1 then
				status.modifyResource("energy", amount * starPounds.getStat("absorption") * starPounds.getStat("digestionEnergy") * 10)
			end
			-- Energy regen block is capped at 2x the speed (decreases by the delta)
			status.modifyResource("energyRegenBlock", math.max(-amount * starPounds.getStat("absorption") * starPounds.getStat("digestionEnergy"), -dt))
		end
	end
end

starPounds.gurgle = function(noDigest)
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return end
	-- Don't do anything if gurgles are disabled.
	if starPounds.hasOption("disableGurgles") and not noDigest then return end
	-- Instantly digest 1 - 3 seconds worth of food.
	local seconds = starPounds.getStat("gurgleAmount") * math.random(100, 300)/100
	if not noDigest then
		-- Chance to belch if they have bloat.
		local bloat = storage.starPounds.bloat
		local bloatMultiplier = 0
		if starPounds.getStat("belchChance") > math.random() and bloat > 0 and starPounds.getStat("bloatDigestion") > 0 then
			-- Every 100 bloat pitches the sound down and volume up by 10%, max 25%
			local belchMultiplier = math.min(bloat/1000, 0.25)
			bloatMultiplier = starPounds.getStat("belchAmount")
			starPounds.belch(0.5 + belchMultiplier, (math.random(110,130)/100) * (1 - belchMultiplier))
		end
		starPounds.digest(seconds, true, bloatMultiplier)
	end
	if not starPounds.hasOption("disableGurgleSounds") then
		world.sendEntityMessage(entity.id(), "starPounds.playSound", "digest", 0.75, (2 - seconds/5) - storage.starPounds.weight/(starPounds.settings.maxWeight * 2))
	end
end

starPounds.rumble = function()
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return end
	-- Don't do anything if rumbles are disabled.
	if starPounds.hasOption("disableRumbles") then return end
	-- Rumble sound every 10 seconds.
	world.sendEntityMessage(entity.id(), "starPounds.playSound", "rumble", 0.75, (math.random(90,110)/100))
end

starPounds.belch = function(volume, pitch, loops, skipParticles)
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return end
	-- Argument sanitisation.
	volume = tonumber(volume) or 1
	pitch = tonumber(pitch) or 1
	loops = tonumber(loops)
	-- Skip if belches are disabled.
	if starPounds.hasOption("disableBelches") then return end
	world.sendEntityMessage(entity.id(), "starPounds.playSound", "belch", volume, pitch, loops)
	-- Skip if we're not doing particles.
	if skipParticles or starPounds.hasOption("disableBelchParticles") then return end
	-- More accurately calculate where the enities's mouth is.
	local facingDirection = mcontroller.facingDirection()
	local mouthOffset = {0.375 * facingDirection * (mcontroller.crouching() and 1.5 or 1), (mcontroller.crouching() and 0 or 1) - 1}
	local mouthPosition = vec2.add(world.entityMouthPosition(entity.id()), mouthOffset)
	local gravity = world.gravity(mouthPosition)
	local friction = world.breathable(mouthPosition) or world.liquidAt(mouthPosition)
	local particle = {
		type = "ember",
		size = 1.25,
		color = {60, 150, 224, 200},
		position = {0, 0},
		approach = {5, 10},
	  destructionAction = "shrink",
	  destructionTime = 0.2,
		layer = "middle",
		timeToLive = 0.5,
		initialVelocity = vec2.add({7 * facingDirection, 0}, vec2.add(mcontroller.velocity(), {0, gravity/62.5})), -- Gravity still alters velocity standing still. Why 62.5 you ask? Who knows! :D
		finalVelocity = {0, -gravity},
		approach = {friction and 5 or 0, gravity},
		variance = {
			initialVelocity = {5.0, 3.0},
			size = 0.25,
			timeToLive = 0.25,
		}
	}
	-- 7.5 (Rounded to 8) to 10 particles, decreased or increased by up to 2x, -5
	-- Ends up yielding around 10 - 15 particles if the belch is very loud and deep, 3 - 5 at normal volume and pitch, and none if it's half volume or twice as high pitch.
	local volumeMultiplier = math.max(math.min(volume, 1.5), 0)
	local pitchMultiplier = 1/math.max(pitch, 2/3)
	local particleCount = math.round(math.max(math.random(75, 100) * 0.1 * pitchMultiplier * volumeMultiplier - 5, 0))
	-- Belches give momentum in zero g based on the particle count, because why not.
	if mcontroller.zeroG() then
		mcontroller.addMomentum({-0.5 * facingDirection * (0.5 + starPounds.weightMultiplier * 0.5) * particleCount, 0})
	end
	world.spawnProjectile("invisibleprojectile", vec2.add(mouthPosition,  mcontroller.isNullColliding() and 0 or vec2.div(mcontroller.velocity(), 60)), entity.id(), {0,0}, true, {
		damageKind = "hidden",
		universalDamage = false,
		onlyHitTerrain = true,
		timeToLive = 5/60,
		periodicActions = {{action = "loop", time = 0, ["repeat"] = false, count = particleCount, body = {{action = "particle", specification = particle}}}}
	})
end

starPounds.slosh = function(dt)
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return end
	-- Argument sanitisation.
	dt = math.max(tonumber(dt) or 0, 0)
	if dt == 0 then return end
	-- Check for relevant skill.
	if not starPounds.hasSkill("sloshing") then return end
	-- Skip if nothing in stomach.
	if starPounds.stomach.contents == 0 then return end
	local crouching = mcontroller.crouching()
	starPounds.sloshTimer = math.max((starPounds.sloshTimer or 0) - dt, 0)
	starPounds.sloshDeactivateTimer = math.max((starPounds.sloshDeactivateTimer or 0) - dt, 0)
	local sloshActivationCount = starPounds.settings.sloshActivationCount
	if crouching and not starPounds.wasCrouching and starPounds.sloshTimer < (starPounds.settings.sloshTimer - starPounds.settings.minimumSloshTimer) then
		starPounds.sloshActivations = math.min(starPounds.sloshActivations or 0, sloshActivationCount)
		local activationMultiplier = starPounds.sloshActivations/sloshActivationCount
		local sloshEffectiveness = (1 - (starPounds.sloshTimer/starPounds.settings.sloshTimer)) * activationMultiplier
		-- Sloshy sound, with volume increasing until activated.
		local soundMultiplier =  0.45 * (0.5 + 0.5 * math.min(starPounds.stomach.contents/starPounds.settings.stomachCapacity, 1)) * activationMultiplier
		local pitchMultiplier = 1.25 - storage.starPounds.weight/(starPounds.settings.maxWeight * 2)
		world.sendEntityMessage(entity.id(), "starPounds.playSound", "slosh", soundMultiplier, pitchMultiplier)
		if activationMultiplier > 0 then
			starPounds.digest(starPounds.settings.sloshDigestion * sloshEffectiveness, true)
			starPounds.gurgleTimer = math.max((starPounds.gurgleTimer or 0) - (starPounds.settings.sloshPercent * starPounds.settings.gurgleTime), 0)
			starPounds.rumbleTimer = math.max((starPounds.rumbleTimer or 0) - (starPounds.settings.sloshPercent * starPounds.settings.rumbleTime), 0)
		end
		starPounds.sloshActivations = math.min(starPounds.sloshActivations + 1, sloshActivationCount)
		starPounds.sloshTimer = starPounds.settings.sloshTimer
		starPounds.sloshDeactivateTimer = starPounds.settings.sloshDeactivateTimer
	end
	if starPounds.sloshDeactivateTimer == 0 or (mcontroller.walking() or mcontroller.running()) then
		starPounds.sloshActivations = 0
	end
	starPounds.wasCrouching = crouching
end

starPounds.exercise = function(dt)
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return end
	-- Argument sanitisation.
	dt = math.max(tonumber(dt) or 0, 0)
	if dt == 0 then return end
	-- Skip this if we're in a sphere.
	if status.stat("activeMovementAbilities") > 1 then return end
	-- Jumping > Running > Walking
	local effort = 0
	local consumeEnergy = false
	if mcontroller.groundMovement() then
		if mcontroller.walking() then effort = 0.125 end
		if mcontroller.running() then effort = 0.5 consumeEnergy = true end
		-- Reset jump checker while on ground.
		didJump = false
		-- Moving through liquid takes up to 50% more effort.
		effort = effort * (1 + math.min(math.round(mcontroller.liquidPercentage(), 1), 0.5))
	elseif not mcontroller.liquidMovement() and mcontroller.jumping() and not didJump then
		effort = 1
		consumeEnergy = true
	else
		didJump = true
	end

	-- Skip the rest if we're not moving.
	if effort == 0 then return end
	local strainedThreshhold = starPounds.getStat("strainedThreshhold")
	local strainedPenalty = starPounds.getStat("strainedPenalty")
	local threshholds = starPounds.settings.threshholds.strain
	local speedModifier = math.max(0.5, (1 - math.max(0, math.min(starPounds.stomach.fullness - (strainedThreshhold * threshholds.starpoundsstomach), 2)/4) * strainedPenalty))
	local runningSuppressed = status.isResource("energy") and (not status.resourcePositive("energy") or status.resourceLocked("energy")) and (starPounds.stomach.fullness > (strainedThreshhold * threshholds.starpoundsstomach))
	-- Consume energy based on how far over capacity they are.
	if starPounds.stomach.fullness > (strainedThreshhold * threshholds.starpoundsstomach) then
		-- consume and lock energy when running.
		if status.isResource("energy") and not status.resourceLocked("energy") and consumeEnergy then
			local energyCost = status.resourceMax("energy") * strainedPenalty * effort * 0.25 * dt
			-- Double energy cost from super tummy-too-big-itus
			if starPounds.stomach.fullness >= (strainedThreshhold * threshholds.starpoundsstomach2) then
				energyCost = energyCost * 2
			end
			status.modifyResource("energy", -energyCost)
			status.setResourcePercentage("energyRegenBlock", math.max(strainedPenalty, status.resourcePercentage("energyRegenBlock")))
		end
	end
	-- Sweat if we can't run and moving.
	if runningSuppressed and effort > 0 then
		status.addEphemeralEffect("sweat")
	end
	-- Move speed stuffs.
	mcontroller.controlModifiers({
		runningSuppressed = runningSuppressed,
		airJumpModifier = runningSuppressed and 0.5 or nil,
		speedModifier = speedModifier
	})
	-- Lose weight based on weight, effort, and the multiplier.
	local amount = effort * starPounds.weightMultiplier * starPounds.getStat("metabolism") * dt * 0.125
	-- Weight loss reduced by half if you're full.
	if status.isResource("food") and status.resource("food") >= (status.resourceMax("food") + status.stat("foodDelta")) and starPounds.stomach.food > 0 then
		amount = amount * 0.5
	end
	starPounds.loseWeight(amount)
end

starPounds.drink = function(dt)
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return end
	-- Argument sanitisation.
	dt = math.max(tonumber(dt) or 0, 0)
	if dt == 0 then return end
	-- Don't do anything if drinking is disabled.
	if starPounds.hasOption("disableDrinking") then return end
	-- Don't drink inside distortion spheres.
	if status.stat("activeMovementAbilities") > 1 then return end
	-- Can only drink if you're below capacity.
	if starPounds.stomach.fullness >= 1 and not starPounds.hasSkill("wellfedProtection") then
		return
	elseif starPounds.stomach.fullness >= (starPounds.getStat("strainedThreshhold") * starPounds.settings.threshholds.strain.starpoundsstomach3) then
		return
	end
	-- More accurately calculate where the entities's mouth is.
	local mouthOffset = {0.375 * mcontroller.facingDirection() * (mcontroller.crouching() and 1.5 or 1), (mcontroller.crouching() and 0 or 1) - 1}
	local mouthPosition = vec2.add(world.entityMouthPosition(entity.id()), mouthOffset)
	local mouthLiquid = world.liquidAt(mouthPosition) or world.liquidAt(vec2.add(mouthPosition, {0, 0.25}))
	-- Space out 'drinks', otherwise they'll happen every script update.
	drinkTimer = math.max((drinkTimer or 0) - dt, 0)
	drinkCounter = drinkCounter or 0
	-- Check if drinking isn't on cooldown.
	if not (drinkTimer == 0) then return end
	-- Check if there is liquid in front of the entities's mouth, and if it is milk/jelly/lard/chocolate.
	if mouthLiquid and (starPounds.settings.drinkables[root.liquidName(mouthLiquid[1])] or starPounds.hasOption("universalDrinking")) then
		-- Remove liquid at the entities's mouth, and store how much liquid was removed.
		local consumedLiquid = world.destroyLiquid(mouthPosition) or world.destroyLiquid(vec2.add(mouthPosition, {0, 0.25}))
		if consumedLiquid and consumedLiquid[1] and consumedLiquid[2] then
			-- Increment counter up to 2 (20 times).
			drinkCounter = math.min(drinkCounter + 0.1, 2)
			-- Reset the drink cooldown, shorter based on how high drinkCounter is.
			drinkTimer = 1/(1 + drinkCounter)
			-- Add to entities's stomach based on liquid consumed.
			local foodAmount = starPounds.settings.drinkableVolume * (starPounds.settings.drinkables[root.liquidName(consumedLiquid[1])] or 0)
			local bloatAmount = math.max(0, starPounds.settings.drinkableVolume - foodAmount)
			starPounds.feed(foodAmount * consumedLiquid[2])
			starPounds.gainBloat(bloatAmount * consumedLiquid[2], true)
			-- Play drinking sound. Volume increased by amount of liquid consumed.
			world.sendEntityMessage(entity.id(), "starPounds.playSound", "drink", 0.5 + 0.5 * consumedLiquid[2], math.random(8, 12)/10)
		end
	else
		-- Reset the drink counter if there is nothing to drink.
		if drinkCounter >= 1 then
			-- Gets up to 25% deeper depending on how many 'sips' over 10 were taken.
			local belchMultiplier = 1 - (drinkCounter - 1) * 0.25
			starPounds.belch(0.75, (math.random(110,130)/100) * belchMultiplier)
		end
		drinkCounter = 0
	end
end

starPounds.updateFoodItem = function(item)
	if configParameter(item, "foodValue") and not configParameter(item, "starpounds_effectApplied", false) then
		local experienceRatio = starPounds.settings.foodExperienceMultipliers
		local effects = configParameter(item, "effects", jarray())

		if not effects[1] then
			table.insert(effects, jarray())
		end

		table.insert(effects[1], {effect = "starpoundsfood", duration = configParameter(item, "foodValue", 0)})
		if not configParameter(item, "starpounds_disableExperience", false) then
			table.insert(effects[1], {effect = "starpoundsexperience", duration = configParameter(item, "foodValue", 0) * experienceRatio[string.lower(configParameter(item, "rarity", "common"))]})
		end

		item.parameters.starpounds_effectApplied = true
		item.parameters.effects = effects
		item.parameters.starpounds_foodValue = configParameter(item, "foodValue", 0)
		item.parameters.foodValue = 0

		return item
	end
	return false
end

starPounds.updateStatuses = function()
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return end
	-- Check if statuses don't exist. (using the sound handler first since it doesn't change)
	if not status.uniqueStatusEffectActive("starpoundssoundhandler") then
		starPounds.createStatuses()
		return
	end

	if not (starPounds.type == "player") then return end

	if not starPounds.hasOption("disableStomachMeter") then
		local stomachTracker = "starpoundsstomach"
		if starPounds.stomach.interpolatedFullness >= (starPounds.getStat("strainedThreshhold") * starPounds.settings.threshholds.strain.starpoundsstomach2) then
			stomachTracker = "starpoundsstomach3"
		elseif starPounds.stomach.interpolatedFullness >= (starPounds.getStat("strainedThreshhold") * starPounds.settings.threshholds.strain.starpoundsstomach) then
			stomachTracker = "starpoundsstomach2"
		end
		if not status.uniqueStatusEffectActive(stomachTracker) then
			starPounds.createStatuses()
			return
		end
	end

	if not starPounds.hasOption("disableSizeMeter") then
		if not status.uniqueStatusEffectActive("starpounds"..starPounds.currentSize.size) then
			starPounds.createStatuses()
			return
		end
	end
end

starPounds.updateStats = function(force)
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return end
	-- Give the entity hitbox, bonus stats, and effects based on fatness.
	local size = starPounds.currentSize
	local sizeIndex = starPounds.currentSizeIndex
	if oldWeightMultiplier ~= starPounds.weightMultiplier or force then
		status.setPersistentEffects("starpounds", {
			{stat = "maxHealth", baseMultiplier = math.round(1 + size.healthBonus * starPounds.getStat("health"), 2)},
			{stat = "foodDelta", effectiveMultiplier = math.round(starPounds.getStat("hunger"), 2)},
			{stat = "grit", amount = status.stat("activeMovementAbilities") <= 1 and -((starPounds.weightMultiplier - 1) * math.max(0, 1 - starPounds.getStat("knockbackResistance"))) or 0},
			{stat = "fallDamageMultiplier", effectiveMultiplier = 1 + size.healthBonus * (1 - starPounds.getStat("fallDamageReduction"))},
			{stat = "iceStatusImmunity", amount = sizeIndex >= 3 and starPounds.getSkillLevel("iceImmunity") or 0},
			{stat = "poisonStatusImmunity", amount = sizeIndex >= 3 and starPounds.getSkillLevel("poisonImmunity") or 0},
			{stat = "iceResistance", amount = math.min(starPounds.getStat("iceResistance") * (sizeIndex - 1)/3, starPounds.getStat("iceResistance"))},
			{stat = "poisonResistance", amount = math.min(starPounds.getStat("poisonResistance") * (sizeIndex - 1)/3, starPounds.getStat("poisonResistance"))}
		})
	end
	-- Check if the entity is using a morphball (Tech patch bumps this number for the morphball).
	if status.stat("activeMovementAbilities") > 1 then return end
	-- Disable movement penalty on the tech missions so you can actually complete them.
	if starPounds.type == "player" and world.type():find("techchallenge") then
		starPounds.movementModifier = 1
		starPounds.blobDisabled = true
		return
	end

	if not baseParameters then baseParameters = mcontroller.baseParameters() end
	local parameters = baseParameters

	if not controlParameters or oldWeightMultiplier ~= starPounds.weightMultiplier or force then
		starPounds.movementModifier = math.max(0, 1 - (size.movementPenalty - (size.movementPenalty * (starPounds.getStat("movement") - 1))))
		if size.movementPenalty >= 1 then
			starPounds.movementModifier = 0
		end
		local movementModifier = starPounds.movementModifier
		local weightMultiplier = starPounds.weightMultiplier
		controlParameters = sb.jsonMerge(
			{
				mass = parameters.mass * weightMultiplier,
				walkSpeed = parameters.walkSpeed * movementModifier,
				runSpeed = parameters.runSpeed * movementModifier,
				flySpeed = parameters.flySpeed * movementModifier,
				groundForce = parameters.groundForce * weightMultiplier,
				airForce = parameters.airForce * weightMultiplier,
				airFriction = parameters.airFriction * weightMultiplier,
			  liquidBuoyancy = parameters.liquidBuoyancy + math.min(weightMultiplier * 0.01, 0.95),
				liquidForce = parameters.liquidForce * starPounds.weightMultiplier,
				liquidFriction = parameters.liquidFriction * weightMultiplier,
				normalGroundFriction = parameters.normalGroundFriction * weightMultiplier,
				ambulatingGroundFriction = parameters.ambulatingGroundFriction * weightMultiplier,
				airJumpProfile = {
					jumpSpeed = parameters.airJumpProfile.jumpSpeed * movementModifier,
					jumpControlForce = parameters.airJumpProfile.jumpControlForce * weightMultiplier,
				},
				liquidJumpProfile = {
					jumpSpeed = parameters.liquidJumpProfile.jumpSpeed * movementModifier,
					jumpControlForce = parameters.liquidJumpProfile.jumpControlForce * weightMultiplier,
				}
			},
			((not size.isBlob and starPounds.hasOption("disableHitbox")) and {} or (size.controlParameters[starPounds.getVisualSpecies()] or size.controlParameters.default))
		)
	end
	mcontroller.controlParameters(controlParameters)
end

starPounds.createStatuses = function()
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return end
	-- Remove all old statuses.
	world.sendEntityMessage(entity.id(), "starPounds.expire")
	status.addEphemeralEffect("starpoundssoundhandler")

	status[((storage.starPounds.pred or not status.resourcePositive("health")) and "set" or "clear").."PersistentEffects"]("starpoundseaten", {
		{stat = "statusImmunity", effectiveMultiplier = 0}
	})
	status[((storage.starPounds.pred or not status.resourcePositive("health")) and "add" or "remove").."EphemeralEffect"]("starpoundseaten")

	if not (starPounds.type == "player") then return end

	local stomachTracker = "starpoundsstomach"
	if starPounds.stomach.interpolatedFullness >= (starPounds.getStat("strainedThreshhold") * starPounds.settings.threshholds.strain.starpoundsstomach2) then
		stomachTracker = "starpoundsstomach3"
	elseif starPounds.stomach.interpolatedFullness >= (starPounds.getStat("strainedThreshhold") * starPounds.settings.threshholds.strain.starpoundsstomach) then
		stomachTracker = "starpoundsstomach2"
	end
	-- Removing them just puts them back in order (Size tracker before stomach tracker)
	local sizeTracker = "starpounds"..starPounds.currentSize.size
	status.removeEphemeralEffect(sizeTracker)
	if not starPounds.hasOption("disableSizeMeter") then
		status.addEphemeralEffect(sizeTracker)
	end
	status.removeEphemeralEffect(stomachTracker)
	if not starPounds.hasOption("disableStomachMeter") then
		status.addEphemeralEffect(stomachTracker)
	end
end

starPounds.gainExperience = function(amount, multiplier, isLevel)
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return end
	-- Argument sanitisation.
	amount = tonumber(amount) or 0
	multiplier = tonumber(multiplier) or 1
	-- Skip everything else if we're just adding straight levels.
	if isLevel then
		storage.starPounds.level = storage.starPounds.level + math.max(math.round(amount))
		return
	end

	-- Main stuff.
	local multiplier = multiplier or starPounds.getStat("experienceMultiplier")
	local levelModifier = 1 + storage.starPounds.level * starPounds.settings.experienceIncrement
	local amount = math.round((amount or 0) * multiplier)
	local amountRequired = math.round(starPounds.settings.experienceAmount * levelModifier - storage.starPounds.experience)
	if amount < amountRequired then
		storage.starPounds.experience = math.round(storage.starPounds.experience + amount)
	else
		amount = amount - amountRequired
		storage.starPounds.level = storage.starPounds.level + 1
		storage.starPounds.experience = 0
		starPounds.gainExperience(amount, 1)
	end
end

starPounds.toggleOption = function(option)
	storage.starPounds.options[option] = not storage.starPounds.options[option] and true or nil
	starPounds.optionChanged = true
	starPounds.backup()
	return storage.starPounds.options[option]
end

starPounds.setOptionsMultipliers = function(options)
  storage.starPounds.optionMultipliers = {}
  for _, option in ipairs(options) do
    if option.statModifiers and starPounds.hasOption(option.name) then
			for _, statModifier in ipairs(option.statModifiers) do
	      storage.starPounds.optionMultipliers[statModifier[1]] = (storage.starPounds.optionMultipliers[statModifier[1]] or 1) + statModifier[2]
			end
    end
  end
end

starPounds.getOptionsMultiplier = function(stat)
	-- Argument sanitisation.
	stat = tostring(stat)
	return storage.starPounds.optionMultipliers[stat] or 1
end

starPounds.hasOption = function(option)
	-- Argument sanitisation.
	stat = tostring(option)
	return storage.starPounds.options[option]
end

starPounds.getStat = function(stat)
	-- Argument sanitisation.
	stat = tostring(stat)
	-- Only recalculate per tick, otherwise use the cached value. (starPounds.statCache gets reset every tick)
	if not starPounds.statCache[stat] then
		-- Default amount (or 1), modified by accessory values.
		local statAmount = (starPounds.stats[stat].base ~= 0 and starPounds.stats[stat].base or 1) * starPounds.getAccessoryModfiers(stat)
		-- Add flat bonuses from skills and status effects.
		statAmount = statAmount + starPounds.getStatBonus(stat) + starPounds.getEffectBonus(stat)
		-- Multiply the total bonuses by status effect and option multipliers.
		starPounds.statCache[stat] = math.max(math.min(statAmount * starPounds.getEffectMultiplier(stat) * starPounds.getOptionsMultiplier(stat), starPounds.stats[stat].maxValue or math.huge), 0)
	end
	return starPounds.statCache[stat]
end

starPounds.getSkillUnlockedLevel = function(skill)
	-- Argument sanitisation.
	skill = tostring(skill)
	return math.min(storage.starPounds.skills[skill] and storage.starPounds.skills[skill][2] or 0, starPounds.skills[skill] and (starPounds.skills[skill].levels or 1) or 0)
end

starPounds.hasUnlockedSkill = function(skill, level)
	-- Argument sanitisation.
	skill = tostring(skill)
	level = tonumber(level) or 1
	return (starPounds.getSkillUnlockedLevel(skill) >= level)
end

starPounds.getSkillLevel = function(skill)
	-- Argument sanitisation.
	skill = tostring(skill)
	return math.min(storage.starPounds.skills[skill] and storage.starPounds.skills[skill][1] or 0, starPounds.skills[skill] and (starPounds.skills[skill].levels or 1) or 0)
end

starPounds.hasSkill = function(skill, level)
	-- Argument sanitisation.
	skill = tostring(skill)
	level = tonumber(level) or 1
	return (starPounds.getSkillLevel(skill) >= level)
end

starPounds.upgradeSkill = function(skill, cost)
	-- Argument sanitisation.
	skill = tostring(skill)
	cost = tonumber(cost) or 0
	storage.starPounds.skills[skill] = storage.starPounds.skills[skill] or jarray()
	if starPounds.getSkillUnlockedLevel(skill) == starPounds.getSkillLevel(skill) then
		storage.starPounds.skills[skill][1] = math.min(starPounds.getSkillUnlockedLevel(skill) + 1, starPounds.skills[skill].levels or 1)
	end
	storage.starPounds.skills[skill][2] = math.min(starPounds.getSkillUnlockedLevel(skill) + 1, starPounds.skills[skill].levels or 1)

	local experienceProgress = storage.starPounds.experience/(starPounds.settings.experienceAmount * (1 + storage.starPounds.level * starPounds.settings.experienceIncrement))
	storage.starPounds.level = math.max(storage.starPounds.level - math.round(cost), 0)
	storage.starPounds.experience = math.round(experienceProgress * starPounds.settings.experienceAmount * (1 + storage.starPounds.level * starPounds.settings.experienceIncrement))
	starPounds.gainExperience()
	starPounds.parseSkillStats()
  starPounds.updateStats(true)
  starPounds.optionChanged = true
end

starPounds.setSkill = function(skill, level)
	-- Argument sanitisation.
	skill = tostring(skill)
	level = tonumber(level)
	-- Need a level to do anything here.
	if not level then return end
	-- Skip if there's no such skill.
	if not storage.starPounds.skills[skill] then return end
	if starPounds.getSkillUnlockedLevel(skill) > 0 then
		storage.starPounds.skills[skill] = storage.starPounds.skills[skill] or jarray()
		storage.starPounds.skills[skill][1] = math.max(math.min(level, starPounds.getSkillUnlockedLevel(skill)), 0)
	end
	starPounds.parseSkillStats()
  starPounds.updateStats(true)
  starPounds.optionChanged = true
end

starPounds.parseSkillStats = function()
  storage.starPounds.stats = {}
  for skillName in pairs(storage.starPounds.skills) do
    local skill = starPounds.skills[skillName]
    if skill.type == "addStat" then
      storage.starPounds.stats[skill.stat] = (storage.starPounds.stats[skill.stat] or 0) + (skill.amount * starPounds.getSkillLevel(skillName))
    elseif skill.type == "subtractStat" then
      storage.starPounds.stats[skill.stat] = (storage.starPounds.stats[skill.stat] or 0) - (skill.amount * starPounds.getSkillLevel(skillName))
    end
    if storage.starPounds.stats[skill.stat] == 0 then
      storage.starPounds.stats[skill.stat] = nil
    end
  end
  starPounds.backup()
end

starPounds.parseSkills = function()
	for skill in pairs(storage.starPounds.skills) do
		-- Remove the skill if it doesn't exist.
		if not starPounds.skills[skill] then
			storage.starPounds.skills[skill] = nil
		else
			-- Cap skills at their maximum possible level.
			storage.starPounds.skills[skill][2] = math.min(starPounds.skills[skill].levels or 1, storage.starPounds.skills[skill][2])
			storage.starPounds.skills[skill][1] = math.min(storage.starPounds.skills[skill][1], storage.starPounds.skills[skill][2])
		end
	end
	starPounds.parseSkillStats()
end

starPounds.getStatBonus = function(stat)
	-- Argument sanitisation.
	stat = tostring(stat)
	if not starPounds.stats[stat] then return 0 end
	return starPounds.stats[stat].base + (storage.starPounds.stats[stat] or 0)
end

starPounds.parseEffectStats = function(dt)
	starPounds.statusEffectModifierTimer = math.max((starPounds.statusEffectModifierTimer or 0) - dt, 0)
	if starPounds.statusEffectModifierTimer == 0 then
		starPounds.statusEffectModifiers = {
			bonuses = {},
			multipliers = {}
		}
		-- Don't do anything if the mod is disabled.
		if not storage.starPounds.enabled then return end
		for effectName, stats in pairs(starPounds.settings.statusEffectModifiers.bonuses) do
			if status.uniqueStatusEffectActive(effectName) then
				for stat, bonus in pairs(stats) do
					local currentBonus = starPounds.statusEffectModifiers.bonuses[stat] or 0
					starPounds.statusEffectModifiers.bonuses[stat] = currentBonus + bonus
				end
			end
		end
		for effectName, stats in pairs(starPounds.settings.statusEffectModifiers.multipliers) do
			if status.uniqueStatusEffectActive(effectName) then
				for stat, multiplier in pairs(stats) do
					local currentMultiplier = starPounds.statusEffectModifiers.multipliers[stat] or 1
					starPounds.statusEffectModifiers.multipliers[stat] = currentMultiplier * multiplier
				end
			end
		end
		starPounds.statusEffectModifierTimer = starPounds.settings.effectRefreshTimer
	end
end

starPounds.getEffectMultiplier = function(stat)
	-- Argument sanitisation.
	stat = tostring(stat)
	return starPounds.statusEffectModifiers.multipliers[stat] or 1
end

starPounds.getEffectBonus = function(stat)
	-- Argument sanitisation.
	stat = tostring(stat)
	return starPounds.statusEffectModifiers.bonuses[stat] or 0
end

starPounds.getAccessory = function(slot)
	-- Argument sanitisation.
	slot = tostring(slot)
	return storage.starPounds.accessories[slot]
end

starPounds.getAccessoryModfiers = function(stat)
	-- Argument sanitisation.
	stat = stat and tostring(stat) or nil
	if not stat then
		local accessoryModifiers = {}
		for _, accessory in pairs(storage.starPounds.accessories) do
			for _, stat in pairs(configParameter(accessory, "stats", {})) do
				if starPounds.stats[stat.name] then
					accessoryModifiers[stat.name] = math.round((accessoryModifiers[stat.name] or 0) + stat.modifier, 3)
				end
			end
		end
		return accessoryModifiers
	else
		return math.max(-1, starPounds.accessoryModifiers[stat] or 0)
	end
end

starPounds.setAccessory = function(item, slot)
	-- Argument sanitisation.
	slot = tostring(slot)
	if not slot then return end
	storage.starPounds.accessories[slot] = item
	starPounds.accessoryModifiers = starPounds.getAccessoryModfiers()
	starPounds.optionChanged = true
	starPounds.backup()
end

starPounds.getSize = function(weight)
	-- Default to base size if the mod is off.
	if not storage.starPounds.enabled then
		return starPounds.sizes[1], 1
	end
	-- Argument sanitisation.
	weight = math.max(tonumber(weight) or 0, 0)

	local sizeIndex = 0
	-- Go through all starPounds.sizes (smallest to largest) to find which size.
	for i in ipairs(starPounds.sizes) do
		local isBlob = starPounds.sizes[i].isBlob
		local blobDisabled = starPounds.hasOption("disableBlob") or starPounds.blobDisabled
		local skipSize = isBlob and blobDisabled
		if weight >= starPounds.sizes[i].weight and not skipSize then
			sizeIndex = i
		end
	end

	-- If we have the anti-immobile skill, use the regular blob clothing and an increased movement penalty.
	local isImmobile = starPounds.sizes[sizeIndex].movementPenalty == 1
	local immobileDisabled = blobDisabled or starPounds.hasSkill("preventImmobile")
	if isImmobile and immobileDisabled then
		local oldMovementPenalty = starPounds.sizes[sizeIndex - 1].movementPenalty
		local newMovementPenalty = oldMovementPenalty + 0.5 * (1 - oldMovementPenalty)
		local newSize = sb.jsonMerge(starPounds.sizes[sizeIndex], {
			movementPenalty = newMovementPenalty
		})
		return newSize, sizeIndex
	end

	return starPounds.sizes[sizeIndex], sizeIndex
end

starPounds.hunger = function(dt)
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return end
	-- Argument sanitisation.
	dt = math.max(tonumber(dt) or 0, 0)
	if dt == 0 then return end
	-- Check upgrade for preventing starving and they have weight loss enabled.
	if starPounds.hasSkill("preventStarving") and not starPounds.hasOption("disableLoss") then
		-- 1% more than the food delta.
		local threshhold = math.max(status.stat("foodDelta") * -1, 0) * 1.01 * dt
		-- Check if the player is about to starve.
		local isStarving = status.resource("food") < (math.max(status.stat("foodDelta") * -1, 0) * 1.01 * dt)
	  -- Rumble sound every 5 seconds when hungry.
	  if (isStarving or status.uniqueStatusEffectActive("hungry")) and not starPounds.hasOption("disableRumbles") and math.random(1, math.round(5/dt)) == 1 then
	  	world.sendEntityMessage(entity.id(), "starPounds.playSound", "rumble", 0.75, (math.random(90,110)/100))
	  end
		if isStarving then
			local minimumOffset = starPounds.getSkillLevel("minimumSize")
			local foodAmount = math.min((minimumOffset > 0 and (storage.starPounds.weight - starPounds.sizes[minimumOffset + 1].weight) or storage.starPounds.weight) * 0.1, threshhold - status.resource("food"))
			status.giveResource("food", foodAmount)
			starPounds.loseWeight(2 * foodAmount/math.max(0.01, starPounds.getStat("absorption")))
		end
	end
	-- Set the statuses.
	if not (starPounds.type == "player") then return end
	if starPounds.stomach.interpolatedFullness >= (starPounds.getStat("strainedThreshhold") * starPounds.settings.threshholds.strain.starpoundsstomach) and not starPounds.hasSkill("wellfedProtection") then
		status.addEphemeralEffect("wellfed")
	elseif starPounds.stomach.interpolatedFullness >= (starPounds.getStat("strainedThreshhold") * starPounds.settings.threshholds.strain.starpoundsstomach3) then
		status.addEphemeralEffect("wellfed")
	else
		if status.resource("food") >= (status.resourceMax("food") + status.stat("foodDelta")) and starPounds.stomach.food > 0 then
			status.addEphemeralEffect("starpoundswellfed")
		end
	end
end

starPounds.getStomach = function()
		local stomachContents = storage.starPounds.stomach + storage.starPounds.bloat
		local stomachCapacity = starPounds.settings.stomachCapacity * starPounds.getStat("capacity")
		-- Add how heavy every entity in the stomach is to the counter.
		for _, v in pairs(storage.starPounds.entityStomach) do
			stomachContents = stomachContents + v.weight + v.bloat
		end

		return {
			capacity = stomachCapacity,
			food = math.round(storage.starPounds.stomach, 3),
			contents = math.round(stomachContents, 3),
			fullness = math.round(stomachContents/stomachCapacity, 2),
			interpolatedContents = math.round(storage.starPounds.stomachLerp, 3),
			interpolatedFullness = math.round(storage.starPounds.stomachLerp/stomachCapacity, 2),
			bloat = math.round(storage.starPounds.bloat, 3)
		}
end

starPounds.getBreasts = function()
		local breastCapacity = 10 * starPounds.getStat("breastCapacity")
		if starPounds.hasOption("disableLeaking") then
			storage.starPounds.breasts = math.min(storage.starPounds.breasts, breastCapacity)
		end
		local breastContents = storage.starPounds.breasts

		return {
			capacity = breastCapacity,
			type = storage.starPounds.breastType or "milk",
			contents = math.round(breastContents, 4),
			fullness = math.round(breastContents/breastCapacity, 4)
		}
end

starPounds.getChestVariant = function(size)
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return end
	-- Argument sanitisation.
	size = sb.jsonMerge({variants = jarray()}, type(size) == "table" and size or {})

	local variant = nil

	local breastSize = (starPounds.hasOption("disableBreastGrowth") and 0 or starPounds.breasts.contents) + (
		starPounds.hasOption("busty") and starPounds.settings.threshholds.breasts[1].amount or (
		starPounds.hasOption("milky") and starPounds.settings.threshholds.breasts[2].amount or 0)
	)

	local stomachSize = (starPounds.hasOption("disableStomachGrowth") and 0 or storage.starPounds.stomachLerp) + (
		starPounds.hasOption("stuffed") and starPounds.settings.threshholds.stomach[2].amount * starPounds.currentSize.threshholdMultiplier or (
		starPounds.hasOption("filled") and starPounds.settings.threshholds.stomach[4].amount * starPounds.currentSize.threshholdMultiplier or (
		starPounds.hasOption("gorged") and starPounds.settings.threshholds.stomach[6].amount * starPounds.currentSize.threshholdMultiplier or 0))
	)

	for _, v in ipairs(starPounds.settings.threshholds.breasts) do
		if contains(size.variants, v.name) then
			if breastSize >= v.amount then
				variant = v.name
			end
		end
	end

	for _, v in ipairs(starPounds.settings.threshholds.stomach) do
		if contains(size.variants, v.name) then
			if stomachSize >= (v.amount * starPounds.currentSize.threshholdMultiplier) then
				variant = v.name
			end
		end
	end

	if starPounds.hasOption("hyper") then
		variant = "hyper"
	end

	return variant
end

starPounds.getVisualSpecies = function(species)
	-- Get entity species.
	local species = species and tostring(species) or world.entitySpecies(entity.id())
	return starPounds.species[species] and (starPounds.species[species].override or species) or species
end

starPounds.getSpeciesData = function(species)
	-- Get merged species data.
	local species = species and tostring(species) or world.entitySpecies(entity.id())
	return sb.jsonMerge(starPounds.species.default, starPounds.species[species] or {})
end

starPounds.getDirectives = function()
	local directives = ""
	-- Get entity species.
	local species = starPounds.getVisualSpecies()
	local speciesData = starPounds.getSpeciesData()
	-- Generate a nude portrait.
	for _,v in ipairs(world.entityPortrait(entity.id(), "fullnude")) do
		-- Find the player's body sprite.
		if string.find(v.image, "body.png") then
			-- Seperate the body sprite's image directives.
			directives = string.sub(v.image,(string.find(v.image, "?")))
			break
		end
	end
	-- Add append directives, if any. (i.e. novakids have this white patch that doesn't change with default species colours, adding ffffff=ffffff means it gets picked up by the fullbright block)
	if speciesData.appendDirectives then
		directives = string.format("%s;%s", directives, speciesData.appendDirectives):gsub(";;", ";")
	end
	-- If the species is fullbright (i.e. novakids), append 'fe' to hexcodes to make them fullbright. (99%+ opacity)
	if speciesData.fullbright then
		directives = (directives..";"):gsub("(%x)(%?)", function(a) return a..";?" end):gsub(";;", ";"):gsub("(%x+=%x%x%x%x%x%x);", function(colour)
			return string.format("%sfe;", colour)
		end)
	end
	-- Slip in override directives, if any. This is after the fullbright block since this is usually used for mimicking species palettes.
	if speciesData.prependDirectives then
		directives = string.format("%s;%s", speciesData.prependDirectives, directives):gsub(";;", ";")
	end
	return directives
end

starPounds.equipSize = function(size, modifiers)
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return end
	-- Get entity species.
	local species = starPounds.getVisualSpecies()
	-- Get entity directives
	local directives = starPounds.getDirectives()
	-- Setup base parameters for item.
	local visualSize = size.size
	if starPounds.hasSkill("preventImmobile") and visualSize == "immobile" then
		visualSize = "blob"
	end
	local items = {
		legs = {name = (modifiers.legsSize or visualSize)..species:lower().."legs", count=1},
		chest = {name = (modifiers.chestSize or visualSize)..(modifiers.chestVariant or "")..species:lower().."chest", count=1}
	}

	-- Give the items parameters to track/prevent dupes.
	items.legs.parameters = {directives = directives, price = 0, size = (modifiers.legsSize or size.size), rarity = "essential"}
	items.chest.parameters = {directives = directives, price = 0, size = (modifiers.chestSize or size.size), variant = modifiers.chestVariant, rarity = "essential"}
	-- Base size doesn't have any items.
	if (modifiers.legsSize or size.size) == "" then items.legs = nil end
	if (modifiers.chestSize or size.size) == "" and (modifiers.chestVariant or "") == "" then items.chest = nil end
	-- Grab current worn clothing.
	local currentItems = {
		legs = player.equippedItem("legsCosmetic"),
		chest = player.equippedItem("chestCosmetic")
	}
	-- Shorthand instead of 2 blocks.
	for _, itemType in ipairs({"legs", "chest"}) do
		currentItem = currentItems[itemType]
		-- If the item isn't a generated item, give it back.
		if currentItems[itemType] and not currentItems[itemType].parameters.size and not currentItems[itemType].parameters.tempSize == size.size then
			player.giveItem(currentItems[itemType])
		end
		-- Replace the item if it isn't generated.
		if not (currentItem and currentItems[itemType].parameters.tempSize) then
			player.setEquippedItem(itemType.."Cosmetic", items[itemType])
		end
	end
end

starPounds.equipCheck = function(size, modifiers)
	-- Cap size in certain vehicles to prevent clipping.
	local leftCappedVehicle = false
	if mcontroller.anchorState() then
		local anchorEntity = world.entityName(mcontroller.anchorState())
		if anchorEntity and starPounds.settings.vehicleSizeCap[anchorEntity] then
			if starPounds.currentSizeIndex > starPounds.settings.vehicleSizeCap[anchorEntity] then
				modifiers.chestVariant = "busty"
				modifiers.legsSize = nil
				modifiers.chestSize = nil
				size = starPounds.sizes[starPounds.settings.vehicleSizeCap[anchorEntity]]
				inCappedVehicle = true
			end
		end
	else
		if inCappedVehicle then
			leftCappedVehicle = true
			inCappedVehicle = false
		end
	end
	-- Skip if no changes.
	if
		size.size == (oldSize and oldSize.size or nil) and
		starPounds.currentVariant == oldVariant and
		not leftCappedVehicle and
		not (starPounds.swapSlotItem ~= nil and starPounds.swapSlotItem.parameters ~= nil and (starPounds.swapSlotItem.parameters.size ~= nil or starPounds.swapSlotItem.parameters.tempSize ~= nil)) and not
		starPounds.optionChanged
	then return end
	-- Check the item the player is holding.
	if starPounds.swapSlotItem and starPounds.swapSlotItem.parameters then
		local item = starPounds.swapSlotItem
		-- If it's a base one then bye bye item.
		if starPounds.swapSlotItem.parameters.size then
			player.setSwapSlotItem(nil)
		-- If it's a clothing one then reset it to the normal item in their cursor.
		elseif item.parameters.tempSize and item.parameters.baseName then
			-- Restore the original item
			item = {
				name = item.parameters.baseName,
				parameters = item.parameters,
				count = item.count
			}
			item.parameters.tempSize = nil
			item.parameters.baseName = nil
			player.setSwapSlotItem(item)
		end
	end

	modifierSize = nil
	-- Get the entity size, and what index it is in the config.
	sizeIndex = starPounds.currentSizeIndex
	-- Check if there's a leg size modifier, and if it exists.
	if modifiers.legsSize then
		for i = 1, modifiers.legsSize do
			if starPounds.sizes[sizeIndex + i] and not starPounds.sizes[sizeIndex + i].isBlob then
				 modifiers.legsSize = starPounds.sizes[sizeIndex + i].size
			end
		end
		if type(modifiers.legsSize) == "number" then modifiers.legsSize = nil end
	end
	-- Check if there's a chest size modifier, and if it exists.
	if modifiers.chestSize then
		for i = 1, modifiers.chestSize do
			if starPounds.sizes[sizeIndex + i] and not starPounds.sizes[sizeIndex + i].isBlob then
				 modifiers.chestSize = starPounds.sizes[sizeIndex + i].size
				 modifierSize = starPounds.sizes[sizeIndex + i]
			end
		end
		if type(modifiers.chestSize) == "number" then modifiers.chestSize = nil end
	end
	-- Check if there's a chest variant, and if it exists.
	if modifiers.chestVariant then
		 modifiers.chestVariant = contains(starPounds.sizes[sizeIndex].variants, modifiers.chestVariant) and modifiers.chestVariant or nil
	end

	-- Iterate over worn clothing.
	local doEquip = false
	for _, itemType in ipairs({"legs", "chest"}) do
		local currentItem = player.equippedItem(itemType.."Cosmetic")
		local currentSize = modifiers[itemType.."Size"] or size.size
		-- Check if the entity is wearing something, if it's not a base item, and if it's generated but the size is wrong.
		if currentItem and not currentItem.parameters.size and currentItem.parameters.tempSize ~= currentSize then
			-- Attempt to find the item for the current size.
			if pcall(root.itemType, currentSize..(currentItem.parameters.baseName or currentItem.name)) then
				-- If found, give the new item some parameters for easier checking.
				currentItem.parameters.baseName = (currentItem.parameters.baseName or currentItem.name)
				currentItem.parameters.tempSize = currentSize
				currentItem.name = currentSize..(currentItem.parameters.baseName or currentItem.name)
				player.setEquippedItem(itemType.."Cosmetic", currentItem)
			else
				-- Reset and give the item back/remove it from the slot if an updated one couldn't be found.
				currentItem.name = currentItem.parameters.baseName or currentItem.name
				currentItem.parameters.tempSize = nil
				currentItem.parameters.baseName = nil
				player.giveItem(currentItem)
				player.setEquippedItem(itemType.."Cosmetic", nil)
				currentItem = nil
			end
		end
		-- If the entity isn't wearing an item, or the item they are wearing has the wrong size/variant.
		if currentSize ~= "" or (
			not currentItem or
			currentItem.parameters.size == currentSize and currentItem.parameters.variant == modifiers[itemType.."Variant"] or
			currentItem.parameters.tempSize == currentSize or
			starPounds.currentSizeIndex == 1 and not currentItem.parameters.size
		)
		then
			player.consumeItemWithParameter("size", currentSize, 2)
			doEquip = true
		end
		for _, removedSize in ipairs(starPounds.sizes) do
			if removedSize ~= size then
				-- Delete all base items.
				player.consumeItemWithParameter("size", removedSize.size, 2)
			end
		end
	end
	if doEquip then
		starPounds.equipSize(size, modifiers)
	end
end

starPounds.feed = function(amount)
	-- Runs eat, but adapts for player food.
	-- Use this rather than eat() unless we don't care about the hunger bar for some reason.

	-- Argument sanitisation.
	amount = math.max(tonumber(amount) or 0, 0)

	if not storage.starPounds.enabled then
		if status.isResource("food") then
			status.giveResource("food", amount)
		end
	else
		starPounds.eat(amount)
	end
end

starPounds.eat = function(amount)
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return end
	-- Argument sanitisation.
	amount = math.max(tonumber(amount) or 0, 0)
	-- Insert food into stomach.
	amount = math.round(amount, 3)
	storage.starPounds.stomach = storage.starPounds.stomach + amount
end

starPounds.gainBloat = function(amount, fullAmount)
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return end
	-- Argument sanitisation.
	amount = math.max(tonumber(amount) or 0, 0)
	-- Set bloat, rounded to 4 decimals.
	amount = math.round(amount * (fullAmount and 1 or starPounds.getStat("bloatAmount")), 3)
	storage.starPounds.bloat = storage.starPounds.bloat + amount
end

starPounds.gainWeight = function(amount)
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return 0 end
	-- Argument sanitisation.
	amount = math.max(tonumber(amount) or 0, 0)
	-- Don't do anything if weight gain is disabled.
	if starPounds.hasOption("disableGain") then return end
	-- Increase weight by amount.
	amount = math.min(amount * starPounds.getStat("weightGain"), starPounds.settings.maxWeight - storage.starPounds.weight)
	starPounds.setWeight(storage.starPounds.weight + amount)
	return amount
end

starPounds.loseWeight = function(amount)
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return 0 end
	-- Argument sanitisation.
	amount = math.max(tonumber(amount) or 0, 0)
	-- Don't do anything if weight loss is disabled.
	if starPounds.hasOption("disableLoss") then return end
	-- Decrease weight by amount (min: 0)
	amount = math.min(amount * starPounds.getStat("weightLoss"), storage.starPounds.weight)
	starPounds.setWeight(storage.starPounds.weight - amount)
	return amount
end

starPounds.setWeight = function(amount)
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return end
	-- Argument sanitisation.
	amount = math.max(tonumber(amount) or 0, 0)
	-- Set weight, rounded to 4 decimals.
	amount = math.round(amount, 4)
	storage.starPounds.weight = math.max(math.min(amount, starPounds.settings.maxWeight), starPounds.sizes[(starPounds.getSkillLevel("minimumSize") + 1)].weight)
end

-- Milky functions
----------------------------------------------------------------------------------
starPounds.lactating = function(dt)
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return end
	-- Argument sanitisation.
	dt = math.max(tonumber(dt) or 0, 0)
	if dt == 0 then return end
	-- Check if breast capacity is exceeded.
	if starPounds.breasts.contents > starPounds.breasts.capacity then
		if starPounds.hasOption("disableLeaking") then
			if not starPounds.hasOption("disableMilkGain") then
				storage.starPounds.breasts = starPounds.breasts.capacity
			end
			return
		end
		if math.random(1, math.round(3/dt)) == 1 then
			local amount = math.min(math.round(starPounds.breasts.fullness * 0.5, 1), 1, starPounds.breasts.contents - starPounds.breasts.capacity)
			-- Lactate away excess
			starPounds.lactate(amount)
		end
	end
end

starPounds.lactate = function(amount, noConsume)
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return end
	-- Argument sanitisation.
	amount = math.max(tonumber(amount) or 0, 0)
	if amount == 0 then return end
	-- Don't spawn milk automatically if leaking is disabled, gain it instead.
	if starPounds.hasOption("disableLeaking") and noConsume then starPounds.gainMilk(amount) return end
	amount = math.min(math.round(amount, 4), starPounds.breasts.contents)
	-- Slightly below and in front the head.
	local spawnPosition = vec2.add(world.entityMouthPosition(entity.id()), {mcontroller.facingDirection(), -1})
	-- Only remove the milk if it actually spawns.
	if world.spawnLiquid(spawnPosition, root.liquidId(starPounds.breasts.type), amount) and not noConsume then
		starPounds.loseMilk(amount)
	end
end

starPounds.setMilkType = function(liquidType)
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return end
	-- Argument sanitisation.
	liquidType = tostring(liquidType)
	-- Skip if it's the same type of milk.
	if liquidType == storage.starPounds.breastType then return end
	-- Only allow liquids we have values for.
	if not starPounds.settings.drinkables[liquidType] then return end
	local currentMilkRatio = starPounds.settings.drinkables[starPounds.breasts.type]
	local newMilkRatio = starPounds.settings.drinkables[liquidType]
	local convertRatio = currentMilkRatio/newMilkRatio
	storage.starPounds.breastType = liquidType
	starPounds.setMilk(starPounds.breasts.contents * convertRatio, 4)
end

starPounds.setMilk = function(amount)
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return end
	-- Argument sanitisation.
	amount = math.max(tonumber(amount) or 0, 0)
	-- Set milk, rounded to 4 decimals.
	amount = math.round(amount, 4)
	storage.starPounds.breasts = amount
end

starPounds.gainMilk = function(amount)
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return 0 end
	-- Argument sanitisation.
	amount = math.max(tonumber(amount) or 0, 0)
	-- Set milk, rounded to 4 decimals.
	if starPounds.hasOption("disableMilkGain") then return end
	amount = math.max(math.round(math.min(amount, (starPounds.breasts.capacity * (starPounds.hasOption("disableLeaking") and 1 or 1.1)) - starPounds.breasts.contents), 4), 0)
	storage.starPounds.breasts = math.round(storage.starPounds.breasts + amount, 4)
end

starPounds.loseMilk = function(amount)
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return 0 end
	-- Argument sanitisation.
	amount = math.max(tonumber(amount) or 0, 0)
	-- Decrease milk by amount (min: 0)
	amount = math.min(amount, storage.starPounds.breasts)
	storage.starPounds.breasts = math.max(0, math.round(storage.starPounds.breasts - amount, 4))
	return amount
end

-- Vore functions
----------------------------------------------------------------------------------
starPounds.voreCheck = function()
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return end
	-- Don't do anything if there's no eaten entities.
	if not (#storage.starPounds.entityStomach > 0) then return end
	-- table.remove is doodoo poop water.
	local newStomach = jarray()
	for preyIndex, prey in ipairs(storage.starPounds.entityStomach) do
		if world.entityExists(prey.id) then
			table.insert(newStomach, prey)
		end
	end
	storage.starPounds.entityStomach = newStomach
end

starPounds.voreDigest = function(dt)
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return end
	-- Argument sanitisation.
	dt = math.max(tonumber(dt) or 0, 0)
	if dt == 0 then return end
	-- Don't do anything if disabled.
	if starPounds.hasOption("disablePredDigestion") then return end
	-- Don't do anything if there's no eaten entities.
	if not (#storage.starPounds.entityStomach > 0) then return end
	-- Eaten entities take less damage the more food/entities the player has eaten (While over capacity). Max of 5x slower.
	local vorePenalty = math.min(1 + math.max(starPounds.stomach.fullness - (starPounds.getStat("strainedThreshhold") * starPounds.settings.threshholds.strain.starpoundsstomach2), 0), 5)
	local damageMultiplier = math.max(1, status.stat("powerMultiplier")) * starPounds.getStat("voreDamage")
	-- Reduce health of all entities.
	for _, prey in pairs(storage.starPounds.entityStomach) do
		world.sendEntityMessage(prey.id, "starPounds.getDigested",  (damageMultiplier/vorePenalty) * dt)
	end
end

starPounds.eatNearbyEntity = function(position, range, querySize, force, check)
	-- Argument sanitisation.
	position = (type(position) == "table" and type(position[1]) == "number" and type(position[2]) == "number") and position or mcontroller.position()
	range = math.max(tonumber(range) or 0, 0)
	querySize = math.max(tonumber(querySize) or 0, 0)

	local mouthOffset = {0.375 * mcontroller.facingDirection() * (mcontroller.crouching() and 1.5 or 1), (mcontroller.crouching() and 0 or 1) - 1}
	local mouthPosition = vec2.add(world.entityMouthPosition(entity.id()), mouthOffset)
	local preferredEntities = position and world.entityQuery(position, querySize, {order = "nearest", includedTypes = {"player", "npc", "monster"}, withoutEntityId = entity.id()}) or jarray()
	local nearbyEntities = world.entityQuery(mouthPosition, range, {order = "nearest", includedTypes = {"player", "npc", "monster"}, withoutEntityId = entity.id()})
	local eatenTargets = jarray()

	for _, prey in ipairs(storage.starPounds.entityStomach) do
		eatenTargets[prey.id] = true
	end

	local function isTargetValid(target)
		return not eatenTargets[target] and not world.lineTileCollision(mouthPosition, world.entityPosition(target), {"Null", "Block", "Dynamic", "Slippery"})
	end

	for _, target in ipairs(preferredEntities) do
		if isTargetValid(target) then
			return {starPounds.eatEntity(target, force, check), true}
		end
	end

	for _, target in ipairs(nearbyEntities) do
		if isTargetValid(target) then
			return {starPounds.eatEntity(target, force, check), false}
		end
	end
end

starPounds.eatEntity = function(preyId, force, check)
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return false end
	-- Argument sanitisation.
	preyId = tonumber(preyId)
	if not preyId then return false end
	-- Counting this as 'combat', so no eating stuff on protected worlds. (e.g. the outpost)
	if world.getProperty("nonCombat") then return false end
	-- Don't do anything if pred is disabled.
	if starPounds.hasOption("disablePred") then return false end
	-- Need the upgrades for the skill to work.
	if not (
		starPounds.hasSkill("voreCritter") or
		starPounds.hasSkill("voreMonster") or
		starPounds.hasSkill("voreHumanoid") or
		force
	) then return false end
	-- Don't do anything if eaten.
	if storage.starPounds.pred then return false end
	-- Can only eat if you're below capacity.
	if starPounds.stomach.fullness >= (starPounds.getStat("strainedThreshhold") * starPounds.settings.threshholds.strain.starpoundsstomach) and not starPounds.hasSkill("wellfedProtection") and not force then
		return false
	elseif starPounds.stomach.fullness >= (starPounds.getStat("strainedThreshhold") * starPounds.settings.threshholds.strain.starpoundsstomach3) and not force then
		return false
	end
	-- Don't do anything if they're already eaten.
	if starPounds.ateEntity(preyId) then return false end
	-- Don't do anything if they're not a compatible entity.
	local compatibleEntities = jarray()
	if starPounds.hasSkill("voreMonster") or starPounds.hasSkill("voreCritter") then
		table.insert(compatibleEntities, "monster")
	end
	if starPounds.hasSkill("voreHumanoid") then
		table.insert(compatibleEntities, "npc")
		table.insert(compatibleEntities, "player")
	end

	if not force then
		if not contains(compatibleEntities, world.entityType(preyId)) then return false end
		if status.isResource("energy") and status.resourceLocked("energy") then return false end
		-- Need the upgrades for the specific entity type
		if world.entityType(preyId) == "monster" then
			local scriptCheck = contains(root.monsterParameters(world.entityTypeName(preyId)).scripts or jarray(), "/scripts/starpounds/starpounds_monster.lua")
			if scriptCheck then
				if (not starPounds.hasSkill("voreMonster")) and (not world.entityTypeName(preyId):find("critter")) then return false end
				if (not starPounds.hasSkill("voreCritter")) and world.entityTypeName(preyId):find("critter") then return false end
			else
				local behavior = root.monsterParameters(world.entityTypeName(preyId)).behavior
				if contains(starPounds.settings.critterBehaviors, behavior) and not starPounds.hasSkill("voreCritter") then return false end
				if contains(starPounds.settings.monsterBehaviors, behavior) and not starPounds.hasSkill("voreMonster") then return false end
			end
		end
	end
	-- Skip the rest if the monster/npc can't be eaten to begin with.
	if world.entityType(preyId) == "monster" then
		local scriptCheck = contains(root.monsterParameters(world.entityTypeName(preyId)).scripts or jarray(), "/scripts/starpounds/starpounds_monster.lua")
		local parameters = root.monsterParameters(world.entityTypeName(preyId))
		local behaviorCheck = parameters.behavior and (contains(starPounds.settings.critterBehaviors, parameters.behavior) or contains(starPounds.settings.monsterBehaviors, parameters.behavior)) or false
		if parameters.starPounds_options and parameters.starPounds_options.disablePrey then return false end
		if not (scriptCheck or behaviorCheck) then
			return false
		end
	end

	if world.entityType(preyId) == "npc" then
		if not contains(root.npcConfig(world.entityTypeName(preyId)).scripts or jarray(), "/scripts/starpounds/starpounds_npc.lua") then return false end
		if world.getNpcScriptParameter(preyId, "starPounds_options", jarray()).disablePrey then return false end
	end

	if world.entityDamageTeam(preyId).type == "ghostly" then return false end
	-- Skip eating if we're only checking for a valid target.
	if check then return true end
	-- Ask the entity to be eaten, add to stomach if the promise is successful.
	promises:add(world.sendEntityMessage(preyId, "starPounds.getEaten", entity.id()), function(prey)
		if not (prey and (prey.weight or prey.bloat)) then return end
		table.insert(storage.starPounds.entityStomach, {
			id = preyId,
			weight = prey.weight or 0,
			bloat = prey.bloat or 0,
			experience = prey.experience or 0,
			type = world.entityType(preyId):gsub(".+", {player = "humanoid", npc = "humanoid", monster = "creature"})
		})
		if not force then
			local preyHealth = world.entityHealth(preyId)
			local preyHealthPercent = preyHealth[1]/preyHealth[2]
			local preySizeMult = (1 + (((prey.weight or 0) + (prey.bloat or 0))/starPounds.species.default.weight)) * 0.5
			local energyCost = 5 + 30 * preyHealthPercent * preySizeMult
			status.overConsumeResource("energy", energyCost)
		end
		-- Swallow/stomach rumble
		world.sendEntityMessage(entity.id(), "starPounds.playSound", "swallow", 1 + math.random(0, 10)/100, 1)
		world.sendEntityMessage(entity.id(), "starPounds.playSound", "digest", 1, 0.75)
	end)
	return true
end

starPounds.ateEntity = function(preyId)
	-- Argument sanitisation.
	preyId = tonumber(preyId)
	if not preyId then return false end
	for _, prey in ipairs(storage.starPounds.entityStomach) do
		if prey.id == preyId then return true end
	end
	return false
end

starPounds.digestEntity = function(preyId, items, preyStomach)
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return end
	-- Argument sanitisation.
	preyId = tonumber(preyId)
	if not preyId then return end
	-- Don't do anything if disabled.
	if starPounds.hasOption("disablePredDigestion") then return end
	-- Find the entity's entry in the stomach.
	local digestedEntity = nil
	for preyIndex, prey in ipairs(storage.starPounds.entityStomach) do
		if prey.id == preyId then
			digestedEntity = table.remove(storage.starPounds.entityStomach, preyIndex)
			break
		end
	end
	-- Don't do anything if we didn't digest an entity.
	if not digestedEntity then return end
	-- Transfer eaten entities.
	storage.starPounds.entityStomach = util.mergeLists(storage.starPounds.entityStomach, preyStomach or jarray())
	for _, prey in ipairs(preyStomach or jarray()) do
		world.sendEntityMessage(prey.id, "starPounds.predEaten", entity.id())
	end
	-- More accurately calculate where the enities's mouth is.
	local mouthOffset = {0.375 * mcontroller.facingDirection() * (mcontroller.crouching() and 1.5 or 1), (mcontroller.crouching() and 0 or 1) - 1}
	local mouthPosition = vec2.add(world.entityMouthPosition(entity.id()), mouthOffset)
	-- Burp/Stomach rumble.
	local belchMultiplier = 1 - math.round((digestedEntity.weight - starPounds.species.default.weight)/(starPounds.settings.maxWeight * 4), 2)
	starPounds.belch(0.75, (math.random(110,130)/100) * belchMultiplier)
	-- Iterate over and edit the items.
	local regurgitatedItems = jarray()
	-- We get purple particles if we digest something that gives ancient essence.
	local hasEssence = false
	for _, item in pairs(items or jarray()) do
		local itemType = root.itemType(item.name)
		if string.find(root.itemType(item.name), "armor") then itemType = "clothing" end

		if itemType == "clothing" then
			if math.random() < starPounds.getStat("regurgitateClothingChance") then
				-- Make sure this exists to start with.
				item.parameters = item.parameters or {}
				-- First time digesting the item.
				if not item.parameters.baseParameters then
					local baseParameters = {}
					for k, v in pairs(item.parameters) do
						baseParameters[k] = v
					end
					item.parameters.baseParameters = baseParameters
				end
				item.parameters.digestCount = item.parameters.digestCount and math.min(item.parameters.digestCount + 1, 3) or 1
				-- Reset values before editing.
				item.parameters.category = item.parameters.baseParameters.category
				item.parameters.price = item.parameters.baseParameters.price
				item.parameters.level = item.parameters.baseParameters.level
				item.parameters.directives = item.parameters.baseParameters.directives
				item.parameters.colorIndex = item.parameters.baseParameters.colorIndex
				item.parameters.colorOptions = item.parameters.baseParameters.colorOptions
				-- Add visual flair and reduce rarity down to common.
				local label = root.assetJson("/items/categories.config:labels")[configParameter(item, "category", ""):gsub("enviroProtectionPack", "backwear")]
				item.parameters.category = string.format("^#a6ba5d;Digested %s%s", label, ((item.parameters.digestCount > 1) and string.format(" (x%s)", item.parameters.digestCount) or ""))
				item.parameters.rarity = configParameter(item, "rarity", "common"):lower():gsub(".+", {
					uncommon = "common",
					rare = "uncommon",
					legendary = "rare"
				})
				-- Reduce price to 10% (15% - 5% per digestion) of the original value.
				item.parameters.price = math.round(configParameter(item, "price", 0) * (0.15 - 0.05 * item.parameters.digestCount))
				-- Reduce armor level by 1 per digestion. (Capped at the planet threat level)
				item.parameters.level = math.max(math.min(configParameter(item, "level", 0) - item.parameters.digestCount, world.threatLevel()), configParameter(item, "level", 0) > 0 and 1 or 0)
				-- Disable status effects.
				item.parameters.statusEffects = root.itemConfig(item).statusEffects and jarray() or nil
				-- Disable effects.
				item.parameters.effectSources = root.itemConfig(item).effectSources and jarray() or nil
				-- Disable augments.
				if configParameter(item, "acceptsAugmentType") then
					item.parameters.acceptsAugmentType = ""
				end
				if configParameter(item, "tooltipKind") == "baseaugment" then
					item.parameters.tooltipKind = "back"
				end
				-- Give the armor some colour changes to make it look digested.
				item.parameters.colorOptions = configParameter(item, "colorOptions", {})
				item.parameters.colorIndex = configParameter(item, "colorIndex", 0) % (#item.parameters.colorOptions > 0 and #item.parameters.colorOptions or math.huge)
				-- Convert colorOptions and colorIndex to directives.
				if not configParameter(item, "directives") and item.parameters.colorOptions and #item.parameters.colorOptions > 0 then
					item.parameters.directives = "?replace;"
					for fromColour, toColour in pairs(item.parameters.colorOptions[item.parameters.colorIndex + 1]) do
						item.parameters.directives = string.format("%s%s=%s;", item.parameters.directives, fromColour, toColour)
					end
				end
				item.parameters.directives = configParameter(item, "directives", "")..string.rep("?brightness=-20?multiply=e9ffa6?saturation=-20", item.parameters.digestCount)
				item.parameters.colorIndex = nil
				item.parameters.colorOptions = jarray()
				-- Spawn the item.
				table.insert(regurgitatedItems, item)
			-- Second chance to regurgitate 'scrap' items instead.
			elseif math.random() < starPounds.getStat("regurgitateChance") then
				for _, item in ipairs(root.createTreasure("regurgitatedClothing", configParameter(item, "level", 0))) do
					table.insert(regurgitatedItems, item)
				end
				local armorType
				-- Check if it's a tier 5/6 armor, since the classes have different components.
				if configParameter(item, "level", 0) >= 5 then
					for _, recipe in ipairs(root.recipesForItem(item.name)) do
						if contains(recipe.groups, "craftingaccelerator") then
							armorType = "Accelerator"
						elseif contains(recipe.groups, "craftingmanipulator") then
							armorType = "Manipulator"
						elseif contains(recipe.groups, "craftingseparator") then
							armorType = "Separator"
						end
						if armorType then
							for _, item in ipairs(root.createTreasure("regurgitated"..armorType, configParameter(item, "level", 0))) do
								table.insert(regurgitatedItems, item)
							end
							break
						end
					end
				end
			end
		elseif itemType == "currency" and item.name == "essence" then
			if starPounds.type == "player" then player.giveItem(item) end
			hasEssence = true
		end
	end

	if not starPounds.hasOption("disableGurgleSounds") then
		world.sendEntityMessage(entity.id(), "starPounds.playSound", "digest", 0.75, 0.75)
	end
	-- Fancy little particles similar to the normal death animation.
	if not starPounds.hasOption("disableBelchParticles") then
		local friction = world.breathable(mouthPosition) or world.liquidAt(mouthPosition)
		local particles = {
			{
				action = "particle",
				specification = {
					type = "ember",
					size = 1,
					color = {188, 235, 96},
					position = {0, 0},
					initialVelocity = vec2.add({(friction and 2 or 3) * mcontroller.facingDirection(), 0}, vec2.add(mcontroller.velocity(), {0, world.gravity(mouthPosition)/62.5})),
					finalVelocity = {mcontroller.facingDirection(), 10},
			    approach = friction and {5, 10} or {0, 0},
					destructionAction = "fade",
					destructionTime = 0.25,
					layer = "middle",
					timeToLive = friction and 0.2 or 0.075,
					variance = {
						initialVelocity = {2.0, 2.0},
						size = 0.5,
						timeToLive = 0.05
					}
				}
			}
		}
		particles[#particles + 1] = sb.jsonMerge(particles[1], {specification = {color = {144, 217, 0}}})

		-- Humanoids get glowy death particles.
		if digestedEntity.type == "humanoid" then
			particles[#particles + 1] = sb.jsonMerge(particles[1], {specification = {color = {96, 184, 235}, fullbright = true, collidesLiquid = false, timeToLive = 0.5}})
			particles[#particles + 1] = sb.jsonMerge(particles[1], {specification = {color = {0, 140, 217}, fullbright = true, collidesLiquid = false, timeToLive = 0.5}})
		end

		-- Vault monsters get glowy purple particles.
		if hasEssence then
			particles[#particles + 1] = sb.jsonMerge(particles[1], {specification = {color = {160, 70, 235}, fullbright = true, collidesLiquid = false, timeToLive = 0.5, light = {134, 71, 179, 255}}})
			particles[#particles + 1] = sb.jsonMerge(particles[1], {specification = {color = {102, 0, 216}, fullbright = true, collidesLiquid = false, timeToLive = 0.5, light = {134, 71, 179, 255}}})
		end

		world.spawnProjectile("invisibleprojectile", vec2.add(mouthPosition,  mcontroller.isNullColliding() and 0 or vec2.div(mcontroller.velocity(), 60)), entity.id(), {0,0}, true, {
			damageKind = "hidden",
			universalDamage = false,
			onlyHitTerrain = true,
			timeToLive = 5/60,
			periodicActions = {{action = "loop", time = 0, ["repeat"] = false, count = 5, body = particles}}
		})
	end

	if #regurgitatedItems > 0 then
		world.spawnProjectile("regurgitateditems", mouthPosition, entity.id(), vec2.rotate({math.random(1,2) * mcontroller.facingDirection(), math.random(0, 2)/2}, mcontroller.rotation()), false, {
			items = regurgitatedItems
		})
	end
	starPounds.feed(digestedEntity.weight, digestedEntity.type)
	starPounds.gainBloat(digestedEntity.bloat, true)
	starPounds.gainExperience(digestedEntity.experience)
	return true
end

starPounds.preyStruggle = function(preyId, struggleStrength, escape)
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return end
	-- Argument sanitisation.
	preyId = tonumber(preyId)
	struggleStrength = math.max(tonumber(struggleStrength) or 0, 0)
	if not preyId then return end
	-- Only continue if they're actually eaten.
	for preyIndex, prey in ipairs(storage.starPounds.entityStomach) do
		if prey.id == preyId then
			local preyHealth = world.entityHealth(prey.id)
			local preyHealthPercent = preyHealth[1]/preyHealth[2]
			local struggleStrength = (1 - starPounds.getStat("struggleResistance")) * struggleStrength/math.max(1, status.stat("powerMultiplier"))
			local damageMultiplier = math.max(1, status.stat("powerMultiplier")) * starPounds.getStat("voreDamage")
			local vorePenalty = math.min(1 + math.max(starPounds.stomach.fullness - (starPounds.getStat("strainedThreshhold") * starPounds.settings.threshholds.strain.starpoundsstomach2), 0), 5)
			if math.random() < (world.entityType(preyId) == "player" and starPounds.settings.vorePlayerEscape or (0.5 * struggleStrength)) and escape then
				if world.entityType(preyId) == "player" or (status.resourceLocked("energy") and preyHealthPercent > starPounds.settings.voreUnescapableHealth) then
					starPounds.releaseEntity(preyId)
				end
			end

			if status.isResource("energy") then
				local energyAmount = 5 + 30 * struggleStrength
				if status.isResource("energyRegenBlock") and status.resourceLocked("energy") then
					status.modifyResource("energyRegenBlock", math.min(status.stat("energyRegenBlockTime") * 0.25 * struggleStrength))
				elseif status.resource("energy") > energyAmount then
					status.modifyResource("energy", -energyAmount)
				else
					status.overConsumeResource("energy", energyAmount)
				end
			end

			if not starPounds.hasOption("disablePredDigestion") then
				-- 1 second worth of digestion per struggle.
				world.sendEntityMessage(preyId, "starPounds.getDigested", damageMultiplier/vorePenalty)
			end

			if not starPounds.hasOption("disableStruggleSounds") then
				local totalPreyWeight = (prey.weight or 0) + (prey.bloat or 0)
				local soundVolume = math.min(1, 0.25 + preyHealthPercent * (totalPreyWeight/(starPounds.species.default.weight * 2)))
				world.sendEntityMessage(entity.id(), "starPounds.playSound", "struggle", soundVolume)
			end
			break
		end
	end
end

starPounds.releaseEntity = function(preyId, releaseAll)
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return end
	-- Argument sanitisation.
	preyId = tonumber(preyId)
	-- Delete the entity's entry in the stomach.
	local releasedEntity = nil
	local statusEffect = starPounds.hasSkill("regurgitateSlimeStatus") and "starpoundsslimyupgrade" or nil
	if releaseAll then
		releasedEntity = storage.starPounds.entityStomach[1]
		for preyIndex, prey in ipairs(storage.starPounds.entityStomach) do
			if world.entityExists(prey.id) then
				world.sendEntityMessage(prey.id, "starPounds.getReleased", entity.id(), statusEffect)
			end
		end
		if releasedEntity and world.entityExists(releasedEntity.id) then
			local belchMultiplier = 1 - math.round((releasedEntity.weight - starPounds.species.default.weight)/(starPounds.settings.maxWeight * 4), 2)
			starPounds.belch(0.75, (math.random(110,130)/100) * belchMultiplier)
		end
		storage.starPounds.entityStomach = jarray()
	else
		for preyIndex, prey in ipairs(storage.starPounds.entityStomach) do
			if prey.id == preyId then
				releasedEntity = table.remove(storage.starPounds.entityStomach, preyIndex)
				break
			end
			if not preyId then
				releasedEntity = table.remove(storage.starPounds.entityStomach)
				break
			end
		end
		-- Call back to release the entity incase the pred is releasing them.
		if releasedEntity and world.entityExists(releasedEntity.id) then
			local belchMultiplier = 1 - math.round((releasedEntity.weight - starPounds.species.default.weight)/(starPounds.settings.maxWeight * 4), 2)
			starPounds.belch(0.75, (math.random(110,130)/100) * belchMultiplier)
			world.sendEntityMessage(releasedEntity.id, "starPounds.getReleased", entity.id(), statusEffect)
		end
	end
end

starPounds.eaten = function(dt)
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return end
	-- Argument sanitisation.
	dt = math.max(tonumber(dt) or 0, 0)
	if dt == 0 then return end
	-- Don't do anything if we're not eaten.
	if not storage.starPounds.pred then starPounds.voreHeartbeat = nil return end
	-- Check that the entity actually exists.
	if not world.entityExists(storage.starPounds.pred) or starPounds.hasOption("disablePrey") then
		starPounds.getReleased()
		return
	end

	starPounds.voreHeartbeat = math.max((starPounds.voreHeartbeat or starPounds.settings.voreHeartbeat) - dt, 0)
	if starPounds.voreHeartbeat == 0 then
		starPounds.voreHeartbeat = starPounds.settings.voreHeartbeat
		promises:add(world.sendEntityMessage(storage.starPounds.pred, "starPounds.ateEntity", entity.id()), function(isEaten)
			if not isEaten then starPounds.getReleased() end
		end)
	end
	-- Disable knockback while eaten.
	entity.setDamageOnTouch(false)
	-- Stop entities trying to move.
	mcontroller.clearControls()
	-- Stun the entity.
	if status.isResource("stunned") then
		status.setResource("stunned", math.max(status.resource("stunned"), dt))
	end
	-- Stop lounging.
	mcontroller.resetAnchorState()
	-- Loose calculation for how "powerful" the prey is.
	local struggleStrength = math.max(1, status.stat("powerMultiplier")) * (0.5 + status.resourcePercentage("health") * 0.5)

	local entityType = world.entityType(entity.id())
	if entityType == "npc" or entityType == "monster" then
		mcontroller.setPosition(vec2.add(world.entityPosition(storage.starPounds.pred), {0, -1}))
		starPounds.cycle = starPounds.cycle and starPounds.cycle - (dt * (0.5 + status.resourcePercentage("health") / 2)) or 1
		if starPounds.cycle <= 0 then
			world.sendEntityMessage(storage.starPounds.pred, "starPounds.preyStruggle", entity.id(), struggleStrength, not starPounds.hasOption("disableEscape"))
			starPounds.cycle = math.random(5, 15) / 10
		end
		if entityType == "npc" then
			-- Stop NPCs attacking.
			npc.endPrimaryFire()
			npc.endAltFire()
		else
			-- Monsters don't have a powerMultiplier stat.
			pcall(animator.setAnimationState, "body", "idle")
			pcall(animator.setAnimationState, "damage", "none")
			pcall(animator.setGlobalTag, "hurt", "hurt")
			struggleStrength = math.max((entity.bloat + entity.weight) / starPounds.species.default.weight, 0.1) * (root.evalFunction("npcLevelPowerMultiplierModifier", monster.level()) + status.stat("powerMultiplier")) * (0.5 + status.resourcePercentage("health") * 0.5)
		end
	elseif entityType == "player" then
		-- No air time.
		status.modifyResource("breath", -status.stat("breathDepletionRate") * dt)
		-- Follow the pred's position, struggle if the player is using movement keys.
		local horizontalDirection = (mcontroller.xVelocity() > 0) and 1 or ((mcontroller.xVelocity() < 0) and -1 or 0)
		local verticalDirection = (mcontroller.yVelocity() > 0) and 1 or ((mcontroller.yVelocity() < 0) and -1 or 0)
		starPounds.cycle = 1 + math.sin((os.clock() - (starPounds.startedStruggling or os.clock())) * 2 * math.pi)
		if not (horizontalDirection == 0 and verticalDirection == 0) then
			if starPounds.cycle > 0.7 and not starPounds.struggled then
				starPounds.struggled = true
				world.sendEntityMessage(storage.starPounds.pred, "starPounds.preyStruggle", entity.id(), struggleStrength, not starPounds.hasOption("disableEscape"))
			elseif math.round(starPounds.cycle - 1, 1) == 0 then
				starPounds.struggled = false
			end
		else
			starPounds.struggled = false
			starPounds.startedStruggling = os.clock()
		end
		local predPosition = vec2.add(world.entityPosition(storage.starPounds.pred), {
			horizontalDirection * starPounds.cycle,
			verticalDirection * starPounds.cycle + math.sin(os.clock() * 0.5) - 1
		})
		local distance = world.distance(predPosition, mcontroller.position())
		mcontroller.translate(vec2.lerp(10 * dt, {0, 0}, distance))
	end
	mcontroller.setVelocity({0, 0})
	-- Stop the prey from colliding/moving normally.
	mcontroller.controlParameters({ airFriction = 0, groundFriction = 0, liquidFriction = 0, collisionEnabled = false, gravityEnabled = false })
end

starPounds.getEaten = function(predId)
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return false end
	-- Argument sanitisation.
	predId = tonumber(predId)
	if not predId then return false end
	-- Don't do anything if disabled.
	if starPounds.hasOption("disablePrey") then return false end
	-- Don't do anything if already eaten.
	if storage.starPounds.pred then return false end
	-- Check that the entity actually exists.
	if not world.entityExists(predId) then return false end
	-- Don't get eaten if already dead.
	if not status.resourcePositive("health") then return false end
	-- Eaten entities can't be interacted with. This looks very silly atm since I need to figure out a way to dynamically detect it.
	starPounds.wasInteractable = false
	if starPounds.type == "npc" then
		starPounds.wasInteractable = true
	end
	if starPounds.wasInteractable then
		if starPounds.type == "npc" then
			npc.setInteractive(false)
		end
	end
	-- Override techs
	starPounds.oldTech = {}
	for _,v in pairs({"head", "body", "legs"}) do
		local equippedTech = player.equippedTech(v)
		if equippedTech then
			starPounds.oldTech[v] = equippedTech
		end
		player.makeTechAvailable("starpoundseaten_"..v)
		player.enableTech("starpoundseaten_"..v)
		player.equipTech("starpoundseaten_"..v)
	end
	-- Save the old damage team.
	storage.starPounds.damageTeam = world.entityDamageTeam(entity.id())
	-- Save the entityId of the pred.
	storage.starPounds.pred = predId
	if npc then
		-- Are they a crewmate?
		if recruitable then
			-- Did their owner eat them?
			if recruitable.ownerUuid() and world.entityUniqueId(predId) == recruitable.ownerUuid() then
				recruitable.messageOwner("recruits.digestingRecruit")
			end
		end

		local nearbyNpcs = world.npcQuery(mcontroller.position(), 50, {withoutEntityId = entity.id(), callScript = "entity.entityInSight", callScriptArgs = {entity.id()}, callScriptResult = true})
		for _, nearbyNpc in ipairs(nearbyNpcs) do
			world.callScriptedEntity(nearbyNpc, "notify", {type = "attack", sourceId = entity.id(), targetId = storage.starPounds.pred})
		end
	end
	-- Make other entities ignore it.
	entity.setDamageTeam({type = "ghostly", team = storage.starPounds.damageTeam.team})
	-- Make the entity immune to outside damage/invisible, and disable regeneration.
	status.setPersistentEffects("starpoundseaten", {
		{stat = "statusImmunity", effectiveMultiplier = 0}
	})
	status.addEphemeralEffect("starpoundseaten")
	entity.setDamageOnTouch(false)
	entity.setDamageSources()
	return {
		weight = entity.weight + storage.starPounds.weight,
		bloat = entity.bloat,
		experience = starPounds.hasOption("disableExperience") and 0 or math.round(entity.experience)
	}
end

starPounds.predEaten = function(predId)
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return end
	-- Argument sanitisation.
	predId = tonumber(predId)
	if not predId then return false end
	-- Don't do anything if disabled.
	if starPounds.hasOption("disablePrey") then return false end
	-- Don't do anything if not already eaten.
	if not storage.starPounds.pred then return false end
	-- New pred.
	storage.starPounds.pred = predId
	return true
end

starPounds.getDigested = function(digestionRate)
	-- Don't do anything if the mod is disabled.
	if not storage.starPounds.enabled then return end
	-- Argument sanitisation.
	digestionRate = math.max(tonumber(digestionRate) or 0, 0)
	if digestionRate == 0 then return end
	-- Don't do anything if disabled.
	if starPounds.hasOption("disablePreyDigestion") then return end
	-- Don't do anything if we're not eaten.
	if not storage.starPounds.pred then return end
	-- 0.5% of current health + 0.5 or 0.5% max health, whichever is smaller. (Stops low hp entities dying instantly)
	local amount = (status.resource("health") * 0.005 + math.min(0.005 * status.resourceMax("health"), 1)) * digestionRate
	amount = root.evalFunction2("protection", amount, status.stat("protection"))
	-- Remove the health.
	status.overConsumeResource("health", amount)

	if not status.resourcePositive("health") then
		local items = {}
		for _, slot in ipairs({"head", "chest", "legs", "back"}) do
			local item = player.equippedItem(slot.."Cosmetic") or player.equippedItem(slot)
			if item then
				if (item.parameters and item.parameters.tempSize) then
					item.name = item.parameters.baseName
					item.parameters.tempSize = nil
					item.parameters.baseName = nil
				end
				if not (item.parameters and item.parameters.size) and not configParameter(item, "hideBody") then
					table.insert(items, item)
				end
			end
		end
		-- Restore techs.
		for _,v in pairs({"head", "body", "legs"}) do
			player.unequipTech("starpoundseaten_"..v)
			player.makeTechUnavailable("starpoundseaten_"..v)
		end
		for _,v in pairs(starPounds.oldTech or {}) do
			player.equipTech(v)
		end

		if starPounds.type == "monster" then
			local collectables = root.monsterParameters(monster.type()).captureCollectables or {}
			for collection, collectable in pairs(collectables) do
				world.sendEntityMessage(storage.starPounds.pred, "addCollectable", collection, collectable)
			end

			local dropPools = sb.jsonQuery(monster.uniqueParameters(), "dropPools", jarray())
			if dropPools[1] and dropPools[1].default then
				local dropItems = root.createTreasure(dropPools[1].default, monster.level())
				for _, item in ipairs(dropItems) do
					if item.name == "essence" then table.insert(items, item) end
				end
			end
		end
		world.sendEntityMessage(storage.starPounds.pred, "starPounds.digestEntity", entity.id(), items, storage.starPounds.entityStomach)

		-- Are they a crewmate?
		if recruitable then
			-- Did their owner eat them?
			local predId = storage.starPounds.pred
			storage.starPounds.pred = nil
			if recruitable.ownerUuid() and world.entityUniqueId(predId) == recruitable.ownerUuid() then
				recruitable.messageOwner("recruits.digestedRecruit", recruitable.recruitUuid())
			end
			recruitable.despawn()
			return
		end

		die()
	end
end

starPounds.getReleased = function(source, overrideStatus)
	-- Don't do anything if we're not eaten.
	if not storage.starPounds.pred then return end
	-- Argument sanitisation.
	source = tonumber(source)
	overrideStatus = overrideStatus and tostring(overrideStatus) or nil
	-- Reset damage team.
	entity.setDamageTeam(storage.starPounds.damageTeam)
	storage.starPounds.damageTeam = nil
	local predId = storage.starPounds.pred
	-- Remove the pred id from storage.
	storage.starPounds.pred = nil
	status.clearPersistentEffects("starpoundseaten")
	status.removeEphemeralEffect("starpoundseaten")
	entity.setDamageOnTouch(true)
	if starPounds.wasInteractable then
		if starPounds.type == "npc" then
			npc.setInteractive(true)
		end
	end
	-- Restore techs.
	for _,v in pairs({"head", "body", "legs"}) do
		player.unequipTech("starpoundseaten_"..v)
		player.makeTechUnavailable("starpoundseaten_"..v)
	end
	for _,v in pairs(starPounds.oldTech or {}) do
		player.equipTech(v)
	end
	-- Tell the pred we're out.
	if world.entityExists(predId) then
		-- Callback incase the entity calls this.
		world.sendEntityMessage(predId, "starPounds.releaseEntity", entity.id())
		-- Don't get stuck in the ground.
		mcontroller.setPosition(world.entityPosition(predId))
		-- Make them wet.
		status.addEphemeralEffect(overrideStatus or "starpoundsslimy")
		-- NPCs/monsters become hostile when released (as if damaged normally).
		if starPounds.type == "npc" then
			notify({type = "attack", sourceId = entity.id(), targetId = predId})
		elseif starPounds.type == "monster" then
			self.damaged = true
			if self.board then self.board:setEntity("damageSource", predId) end
		end
	end
end

starPounds.messageHandlers = function()
	-- Handler for enabling the mod.
	message.setHandler("starPounds.toggleEnable", localHandler(starPounds.toggleEnable))
	-- Handler for grabbing data.
	message.setHandler("starPounds.getData", simpleHandler(starPounds.getData))
	message.setHandler("starPounds.isEnabled", simpleHandler(starPounds.isEnabled))
	message.setHandler("starPounds.getSize", simpleHandler(starPounds.getSize))
	message.setHandler("starPounds.getStomach", simpleHandler(starPounds.getStomach))
	message.setHandler("starPounds.getBreasts", simpleHandler(starPounds.getBreasts))
	message.setHandler("starPounds.getChestVariant", simpleHandler(starPounds.getChestVariant))
	message.setHandler("starPounds.getDirectives", simpleHandler(starPounds.getDirectives))
	message.setHandler("starPounds.getVisualSpecies", simpleHandler(starPounds.getVisualSpecies))
	-- Handlers for skills/stats/options
	message.setHandler("starPounds.hasOption", simpleHandler(starPounds.hasOption))
	message.setHandler("starPounds.gainExperience", simpleHandler(starPounds.gainExperience))
	message.setHandler("starPounds.upgradeSkill", simpleHandler(starPounds.upgradeSkill))
	message.setHandler("starPounds.getStat", simpleHandler(starPounds.getStat))
	message.setHandler("starPounds.parseStats", simpleHandler(starPounds.parseStats))
	message.setHandler("starPounds.parseEffectStats", simpleHandler(starPounds.parseEffectStats))
	message.setHandler("starPounds.getSkillLevel", simpleHandler(starPounds.getSkillLevel))
	message.setHandler("starPounds.hasSkill", simpleHandler(starPounds.hasSkill))
	message.setHandler("starPounds.getAccessory", simpleHandler(starPounds.getAccessory))
	message.setHandler("starPounds.getAccessoryModfiers", simpleHandler(starPounds.getAccessoryModfiers))
	-- Handlers for affecting the entity.
	message.setHandler("starPounds.digest", simpleHandler(starPounds.digest))
	message.setHandler("starPounds.gurgle", simpleHandler(starPounds.gurgle))
	message.setHandler("starPounds.rumble", simpleHandler(starPounds.rumble))
	message.setHandler("starPounds.belch", simpleHandler(starPounds.belch))
	message.setHandler("starPounds.feed", simpleHandler(starPounds.feed))
	message.setHandler("starPounds.eat", simpleHandler(starPounds.eat))
	message.setHandler("starPounds.gainBloat", simpleHandler(starPounds.gainBloat))
	message.setHandler("starPounds.gainWeight", simpleHandler(starPounds.gainWeight))
	message.setHandler("starPounds.loseWeight", simpleHandler(starPounds.loseWeight))
	message.setHandler("starPounds.setWeight", simpleHandler(starPounds.setWeight))
	-- Ditto but lactation.
	message.setHandler("starPounds.setMilkType", simpleHandler(starPounds.setMilkType))
	message.setHandler("starPounds.setMilk", simpleHandler(starPounds.setMilk))
	message.setHandler("starPounds.gainMilk", simpleHandler(starPounds.gainMilk))
	message.setHandler("starPounds.loseMilk", simpleHandler(starPounds.loseMilk))
	message.setHandler("starPounds.lactate", simpleHandler(starPounds.lactate))
	-- Ditto but vore.
	message.setHandler("starPounds.eatNearbyEntity", simpleHandler(starPounds.eatNearbyEntity))
	message.setHandler("starPounds.eatEntity", simpleHandler(starPounds.eatEntity))
	message.setHandler("starPounds.ateEntity", simpleHandler(starPounds.ateEntity))
	message.setHandler("starPounds.digestEntity", simpleHandler(starPounds.digestEntity))
	message.setHandler("starPounds.preyStruggle", simpleHandler(starPounds.preyStruggle))
	message.setHandler("starPounds.releaseEntity", simpleHandler(starPounds.releaseEntity))
	message.setHandler("starPounds.getEaten", simpleHandler(starPounds.getEaten))
	message.setHandler("starPounds.predEaten", simpleHandler(starPounds.predEaten))
	message.setHandler("starPounds.getDigested", simpleHandler(starPounds.getDigested))
	message.setHandler("starPounds.getReleased", simpleHandler(starPounds.getReleased))
	-- Interface/debug stuff.
	message.setHandler("starPounds.reset", localHandler(starPounds.reset))
	message.setHandler("starPounds.resetConfirm", localHandler(starPounds.reset))
	message.setHandler("starPounds.resetWeight", localHandler(starPounds.resetWeight))
	message.setHandler("starPounds.resetStomach", localHandler(starPounds.resetStomach))
	message.setHandler("starPounds.resetBreasts", localHandler(starPounds.resetBreasts))
end

-- Other functions
----------------------------------------------------------------------------------
starPounds.toggleEnable = function()
	starPounds.getReleased()
	starPounds.releaseEntity(nil, true)
	-- Do a barrel roll (just flip the boolean).
	storage.starPounds.enabled = not storage.starPounds.enabled
	-- Make sure the movement penalty stuff gets reset as well.
	starPounds.currentSize, starPounds.currentSizeIndex = starPounds.getSize(storage.starPounds.weight)
	starPounds.updateStats(true)
	starPounds.optionChanged = true
	if not storage.starPounds.enabled then
		starPounds.movementModifier = 1
		starPounds.equipCheck(starPounds.getSize(0), {})
		world.sendEntityMessage(entity.id(), "starPounds.expire")
		status.clearPersistentEffects("starpounds")
		status.clearPersistentEffects("starpoundseaten")
	end
	return storage.starPounds.enabled
end

starPounds.reset = function()
	-- Save accessories.
	local accessories = storage.starPounds.accessories
	-- Reset to base data.
	storage.starPounds = root.assetJson("/scripts/starpounds/starpounds.config:baseData")
	-- Restore accessories.
	storage.starPounds.accessories = accessories
	-- If we set this to true, the enable function sets it back to false.
	-- Means we can keep all the 'get rid of stuff' code in one place.
	storage.starPounds.enabled = true
	starPounds.toggleEnable()
	-- Bye bye fat techs.
	if starPounds.type == "player" then
		for _, v in ipairs(player.availableTechs()) do
			if v:find("starpounds") then
    		player.makeTechUnavailable(v)
			end
		end
	end
	return true
end

starPounds.resetConfirm = function()
	local confirmLayout = root.assetJson("/interface/confirmation/resetstarpoundsconfirmation.config")
  confirmLayout.images.portrait = world.entityPortrait(player.id(), "full")
  promises:add(player.confirm(confirmLayout), function(response)
    if response then
      starPounds.reset()
    end
  end)
	return true
end

starPounds.resetWeight = function()
	-- Set weight.
	storage.starPounds.weight = starPounds.sizes[(starPounds.getSkillLevel("minimumSize") + 1)].weight
	storage.starPounds.bloat = 0
	starPounds.currentSize, starPounds.currentSizeIndex = starPounds.getSize(storage.starPounds.weight)
	-- Reset the fat items.
	starPounds.equipCheck(starPounds.getSize(storage.starPounds.weight), {
		chestVariant = starPounds.getChestVariant(starPounds.currentSize),
	})

	return true
end

starPounds.resetStomach = function()
	storage.starPounds.stomach = 0
	storage.starPounds.bloat = 0
	storage.starPounds.entityStomach = jarray()
	return true
end

starPounds.resetBreasts = function()
	storage.starPounds.breasts = 0
	return true
end

starPounds.backup = function()
	if starPounds.type == "player" then
		player.setProperty("starPoundsBackup", storage.starPounds)
	end
end

starPounds.debug = function(k, v)
	sb.setLogMap(string.format("%s%s", "^#ccbbff;StarPounds_", k), sb.print(v))
end

-- Other functions
----------------------------------------------------------------------------------
function math.round(num, numDecimalPlaces)
	local format = string.format("%%.%df", numDecimalPlaces or 0)
	return tonumber(string.format(format, num))
end

-- Grabs a parameter, or a config, or defaultValue
configParameter = function(item, keyName, defaultValue)
	if item.parameters[keyName] ~= nil then
		return item.parameters[keyName]
	elseif root.itemConfig(item).config[keyName] ~= nil then
		return root.itemConfig(item).config[keyName]
	else
		return defaultValue
	end
end
