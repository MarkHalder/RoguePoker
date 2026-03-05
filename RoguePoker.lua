-- ==========================================
-- RoguePoker - Rogue Rotation Advisor
-- Turtle WoW (1.12 Client)
-- ==========================================
-- .toc requires: ## SavedVariables: RoguePokerDB

-- ==========================================
-- Global State
-- ==========================================
RoguePoker = {}
RoguePoker.TickTime = 2
RoguePoker.Global = 1
RoguePoker.FirstTick = 0
RoguePoker.Energy = 110

-- Energy tick tracking
RoguePoker.f = CreateFrame("Frame", "RoguePokerEnergyFrame", UIParent)
RoguePoker.f:RegisterEvent("UNIT_ENERGY")
RoguePoker.f:SetScript("OnEvent", function()
	if (UnitMana("player") == (RoguePoker.Energy + 20)) then
		RoguePoker.FirstTick = GetTime()
	end
	RoguePoker.Energy = UnitMana("player")
end)

-- ==========================================
-- Ability Name Registry
-- ==========================================
RoguePoker.name = {
	[1]  = "Slice and Dice",
	[2]  = "Envenom",
	[3]  = "Taste for Blood",
	[4]  = "Rupture",
	[5]  = "Noxious Assault",
	[6]  = "Eviscerate",
	[7]  = "Feint",
	[8]  = "Ghostly Strike",
	[9]  = "Evasion",
	[10] = "Vanish",
	[11] = "Flourish",
	[12] = "Kick",
	[13] = "Gouge",
	[14] = "Blind",
	[15] = "Deadly Throw",
	[16] = "Throw",
	[17] = "Sinister Strike",
	[18] = "Backstab",
	[19] = "Hemorrhage",
}

-- ==========================================
-- Default Settings
-- ==========================================
local defaults = {
	position      = { x = 400, y = 300 },
	configOpen    = false,
	-- Combo builder: "Noxious Assault", "Sinister Strike", "Backstab", "Hemorrhage"
	comboBuilder  = "Noxious Assault",
	-- Finisher threshold
	comboThreshold = 5,
	-- Buffs to keep active
	keepActive = {
		sliceAndDice = true,
		envenom      = true,
		rupture      = true,
	},
	-- PvP trinket
	useInsignia = true,
	-- Tanking mode: always use tank/evade rotation, never use Feint
	tankingMode = false,
	-- Always feint regardless of who is targeting
	alwaysFeint = false,
	-- Tank/evade abilities (used when mob is targeting player)
	tankAbilities = {
		ghostlyStrike = true,
		flourish      = true,
		evasion       = true,
		feint         = true,
		vanish        = false,
	},
}

-- ==========================================
-- DB Init
-- ==========================================
local function InitDB()
	RoguePokerDB = RoguePokerDB or {}

	if not RoguePokerDB.position      then RoguePokerDB.position      = defaults.position      end
	if not RoguePokerDB.comboBuilder  then RoguePokerDB.comboBuilder  = defaults.comboBuilder  end
	if RoguePokerDB.comboThreshold == nil then RoguePokerDB.comboThreshold = defaults.comboThreshold end
	if RoguePokerDB.useInsignia == nil then RoguePokerDB.useInsignia = defaults.useInsignia end
	if RoguePokerDB.tankingMode == nil then RoguePokerDB.tankingMode = defaults.tankingMode end
	if RoguePokerDB.alwaysFeint == nil then RoguePokerDB.alwaysFeint = defaults.alwaysFeint end

	if not RoguePokerDB.keepActive then
		RoguePokerDB.keepActive = {}
		for k, v in pairs(defaults.keepActive) do RoguePokerDB.keepActive[k] = v end
	else
		for k, v in pairs(defaults.keepActive) do
			if RoguePokerDB.keepActive[k] == nil then RoguePokerDB.keepActive[k] = v end
		end
	end

	if not RoguePokerDB.tankAbilities then
		RoguePokerDB.tankAbilities = {}
		for k, v in pairs(defaults.tankAbilities) do RoguePokerDB.tankAbilities[k] = v end
	else
		for k, v in pairs(defaults.tankAbilities) do
			if RoguePokerDB.tankAbilities[k] == nil then RoguePokerDB.tankAbilities[k] = v end
		end
	end

	RoguePokerDB.discoveredTextures = RoguePokerDB.discoveredTextures or {}
end


-- ==========================================
-- Core Utility Functions
-- ==========================================

function RoguePoker:GetNextTick()
	local i, now = RoguePoker.FirstTick, GetTime()
	while true do
		if (i > now) then return (i - now) end
		i = i + RoguePoker.TickTime
	end
end

local tooltipFrame = nil

function RoguePoker:IsActive(name)
	if not tooltipFrame then
		tooltipFrame = CreateFrame("GameTooltip", "RoguePokerTooltip", UIParent, "GameTooltipTemplate")
	end
	for i = 0, 31 do
		local buffIndex = GetPlayerBuff(i, "HELPFUL")
		if buffIndex < 0 then break end
		tooltipFrame:SetOwner(UIParent, "ANCHOR_NONE")
		tooltipFrame:ClearLines()
		tooltipFrame:SetPlayerBuff(buffIndex)
		local buff = RoguePokerTooltipTextLeft1:GetText()
		if not buff then break end
		if buff == name then
			return true, GetPlayerBuffTimeLeft(buffIndex)
		end
		tooltipFrame:Hide()
	end
	return false, 0
end

function RoguePoker:FindSpellid(SpellName)
	for i = 1, 100 do
		local name, rank = GetSpellName(i, BOOKTYPE_SPELL)
		if name == SpellName then return i end
	end
	return 0
end

function RoguePoker:PrintSpellid()
	for i = 1, 100 do
		local name, rank = GetSpellName(i, BOOKTYPE_SPELL)
		if name then print(i, name, rank) end
	end
end

function RoguePoker:AutoAttack()
	if not IsCurrentAction(72) then AttackTarget() end
end

function RoguePoker:AtRange()
	return IsActionInRange(71) == 1
end

function RoguePoker:IsMyTargetTargetingMe()
	return UnitExists("targettarget") and UnitIsUnit("targettarget", "player")
end

function RoguePoker:AssistPlayer()
	if UnitIsPlayer("target") then AssistUnit("target") end
end

-- ==========================================
-- Bad Status / Insignia
-- ==========================================
RoguePoker.badTextures = {
    ["Interface\\Icons\\Ability_Ensnare"] = true,
    ["Interface\\Icons\\Spell_Nature_NullifyDisease"] = false,
    ["Interface\\Icons\\Spell_Shadow_ShadowWordPain"] = false,
    ["Interface\\Icons\\Spell_Nature_FaerieFire"] = false,
    ["Interface\\Icons\\Spell_Shadow_CurseOfTounges"] = false,
    ["Interface\\Icons\\Spell_Shadow_GatherShadows"] = false,
    ["Interface\\Icons\\Spell_Fire_Immolation"] = false,
    ["Interface\\Icons\\Spell_Nature_CorrosiveBreath"] = false,
    ["Interface\\Icons\\Ability_Creature_Poison_02"] = false,
    ["Interface\\Icons\\Spell_Fire_FlameBolt"] = false,
    ["Interface\\Icons\\Spell_Holy_Excorcism_02"] = false,
    ["Interface\\Icons\\Spell_Nature_NatureTouchDecay"] = false,
    ["Interface\\Icons\\Spell_Holy_AshesToAshes"] = false,
    ["Interface\\Icons\\Spell_Magic_PolymorphPig"] = true,
    ["Interface\\Icons\\INV_Misc_MonsterClaw_03"] = false,
    ["Interface\\Icons\\Spell_Nature_StrengthOfEarthTotem02"] = false,
    ["Interface\\Icons\\Spell_Fire_Flare"] = false,
    ["Interface\\Icons\\Spell_Frost_FrostArmor02"] = false,
    ["Interface\\Icons\\Spell_ChargePositive"] = false,
    ["Interface\\Icons\\Spell_Fire_SealOfFire"] = false,
    ["Interface\\Icons\\Spell_Shadow_NightOfTheDead"] = false,
    ["Interface\\Icons\\Ability_Hunter_Pet_Bear"] = false,
    ["Interface\\Icons\\Spell_Nature_Acid_01"] = false,
    ["Interface\\Icons\\Spell_Holy_SealOfMight"] = false,
    ["Interface\\Icons\\Ability_Sap"] = true,
    ["Interface\\Icons\\Spell_Frost_FrostBolt02"] = false,
    ["Interface\\Icons\\Ability_Warrior_Charge"] = true,
    ["Interface\\Icons\\Spell_Nature_Slow"] = true,
    ["Interface\\Icons\\Ability_Hunter_Quickshot"] = false,
    ["Interface\\Icons\\Ability_ShockWave"] = true,
    ["Interface\\Icons\\Spell_Nature_StrangleVines"] = true,
    ["Interface\\Icons\\Spell_Shadow_DeathScream"] = true,
    ["Interface\\Icons\\Ability_CheapShot"] = true,
    ["Interface\\Icons\\Spell_Fire_LavaSpawn"] = false,
    ["Interface\\Icons\\Ability_Warrior_Disarm"] = false,
    ["Interface\\Icons\\Spell_ChargeNegative"] = false,
    ["Interface\\Icons\\Spell_Fire_Incinerate"] = false,
    ["Interface\\Icons\\Spell_Shadow_PsychicScream"] = true,
    ["Interface\\Icons\\Spell_Fire_SoulBurn"] = false,
    ["Interface\\Icons\\Spell_Shadow_BlackPlague"] = false,
    ["Interface\\Icons\\Spell_Shadow_Teleport"] = false,
    ["Interface\\Icons\\Spell_Nature_AstralRecal"] = false,
    ["Interface\\Icons\\Spell_Shadow_AntiShadow"] = false,
    ["Interface\\Icons\\Ability_Vanish"] = false,
    ["Interface\\Icons\\Ability_Hunter_Pet_Bat"] = false,
    ["Interface\\Icons\\Spell_Nature_StarFall"] = false,
    ["Interface\\Icons\\Ability_Warrior_DecisiveStrike"] = false,
    ["Interface\\Icons\\Spell_Fire_Fireball02"] = false,
    ["Interface\\Icons\\Spell_Fire_SelfDestruct"] = false,
    ["Interface\\Icons\\INV_Misc_Bandage_08"] = false,
    ["Interface\\Icons\\Spell_Frost_FrostArmor"] = false,
    ["Interface\\Icons\\Ability_WarStomp"] = true,
    ["Interface\\Icons\\Ability_Hunter_SniperShot"] = false,
    ["Interface\\Icons\\Spell_Nature_Drowsy"] = true,
    ["Interface\\Icons\\Ability_Warrior_WarCry"] = false,
    ["Interface\\Icons\\spell_lacerate_1C"] = false,
    ["Interface\\Icons\\Spell_Nature_ThunderClap"] = false,
    ["Interface\\Icons\\Ability_Warrior_SavageBlow"] = false,
    ["Interface\\Icons\\inv_misc_food_66"] = false,
    ["Interface\\Icons\\INV_Misc_Head_Dragon_Green"] = false,
    ["Interface\\Icons\\Spell_Shadow_MindSteal"] = false,
    ["Interface\\Icons\\Ability_Creature_Disease_03"] = false,
    ["Interface\\Icons\\Spell_Shadow_CurseOfMannoroth"] = false,
    ["Interface\\Icons\\Spell_Frost_FrostShock"] = false,
    ["Interface\\Icons\\Spell_Nature_Brilliance"] = false,
    ["Interface\\Icons\\Spell_Nature_Polymorph"] = true,
    ["Interface\\Icons\\Spell_Shadow_SoulLeech_3"] = false,
    ["Interface\\Icons\\Ability_CriticalStrike"] = false,
    ["Interface\\Icons\\Spell_Nature_Web"] = true,
    ["Interface\\Icons\\Spell_Holy_SearingLight"] = false,
    ["Interface\\Icons\\Ability_Gouge"] = true,
    ["Interface\\Icons\\Spell_Fire_FlameShock"] = false,
    ["Interface\\Icons\\Ability_Rogue_KidneyShot"] = true,
    ["Interface\\Icons\\Spell_Nature_WispSplode"] = false,
    ["Interface\\Icons\\Ability_Warrior_Sunder"] = false,
    ["Interface\\Icons\\INV_Mace_02"] = true,
    ["Interface\\Icons\\INV_Misc_Head_Dragon_Black"] = false,
    ["Interface\\Icons\\Spell_Shadow_DeadofNight"] = false,
    ["Interface\\Icons\\Spell_Frost_Glacier"] = true,
    ["Interface\\Icons\\Ability_Rogue_Disguise"] = false,
    ["Interface\\Icons\\Spell_Nature_EarthBind"] = true,
    ["Interface\\Icons\\Spell_Holy_PrayerOfHealing"] = false,
    ["Interface\\Icons\\Spell_Shadow_RainOfFire"] = false,
    ["Interface\\Icons\\Ability_Rogue_Trip"] = true,
    ["Interface\\Icons\\Spell_Shadow_VampiricAura"] = false,
    ["Interface\\Icons\\Spell_Shadow_MindRot"] = false,
    ["Interface\\Icons\\Spell_Nature_NaturesWrath"] = false,
    ["Interface\\Icons\\Spell_Shadow_Haunting"] = false,
    ["Interface\\Icons\\Spell_Holy_ElunesGrace"] = false,
    ["Interface\\Icons\\Spell_Fire_FireBolt02"] = false,
    ["Interface\\Icons\\Spell_Shadow_Charm"] = true,
    ["Interface\\Icons\\Spell_Arcane_ArcaneResilience"] = false,
    ["Interface\\Icons\\Ability_BackStab"] = false,
    ["Interface\\Icons\\Spell_Nature_Sleep"] = true,
    ["Interface\\Icons\\Ability_ThunderBolt"] = true,
    ["Interface\\Icons\\Spell_Shadow_AuraOfDarkness"] = false,
    ["Interface\\Icons\\Spell_Shadow_SiphonMana"] = false,
    ["Interface\\Icons\\Ability_Devour"] = false,
    ["Interface\\Icons\\Spell_Frost_FrostNova"] = true,
    ["Interface\\Icons\\Spell_Holy_Silence"] = false,
    ["Interface\\Icons\\Spell_Nature_BloodLust"] = false,
    ["Interface\\Icons\\Spell_Shadow_DarkSummoning"] = false,
    ["Interface\\Icons\\Ability_GolemThunderClap"] = true,
    ["Interface\\Icons\\Ability_Racial_Cannibalize"] = false,
    ["Interface\\Icons\\Spell_Frost_Stun"] = true,
    ["Interface\\Icons\\Ability_Creature_Poison_05"] = false,
    ["Interface\\Icons\\Spell_Fire_Fireball"] = false,
    ["Interface\\Icons\\Spell_Holy_Vindication"] = false,
    ["Interface\\Icons\\Spell_Shadow_AnimateDead"] = false,
    ["Interface\\Icons\\Spell_Shadow_Cripple"] = true,
    ["Interface\\Icons\\Spell_Shadow_CurseOfSargeras"] = false,
    ["Interface\\Icons\\Spell_Nature_InsectSwarm"] = false,
    ["Interface\\Icons\\Spell_Nature_Earthquake"] = true,
    ["Interface\\Icons\\Spell_Shadow_UnholyFrenzy"] = false,
    ["Interface\\Icons\\Spell_Fire_MeteorStorm"] = false,
    ["Interface\\Icons\\Ability_BullRush"] = true,
    ["Interface\\Icons\\Spell_Frost_ChainsOfIce"] = true,
    ["Interface\\Icons\\Spell_Fire_WindsofWoe"] = false,
    ["Interface\\Icons\\Ability_PoisonSting"] = false,
    ["Interface\\Icons\\Ability_Rogue_DeviousPoisons"] = false,
    ["Interface\\Icons\\INV_Misc_Head_Dragon_Bronze"] = false,
    ["Interface\\Icons\\Ability_Druid_ChallangingRoar"] = false,
    ["Interface\\Icons\\Spell_Fire_Fire"] = false,
    ["Interface\\Icons\\Ability_Druid_Disembowel"] = false,
    ["Interface\\Icons\\INV_Misc_Fork&Knife"] = false,
    ["Interface\\Icons\\Spell_Nature_UnyeildingStamina"] = false,
    ["Interface\\Icons\\Spell_Shadow_Possession"] = true,
    ["Interface\\Icons\\Spell_Nature_SlowPoison"] = false,
}

function RoguePoker:IsBadStatus()
	local i = 1
	while true do
		local texture = UnitDebuff("player", i)
		if not texture then break end
		if RoguePoker.badTextures[texture] then return true end
		i = i + 1
	end
	return false
end

function RoguePoker:UseInsignia()
	local trinketName = "Insignia of the Horde"
	local slot13 = GetInventoryItemLink("player", 13)
	local slot14 = GetInventoryItemLink("player", 14)
	local slot = nil
	if slot13 and string.find(slot13, trinketName) then
		slot = 13
	elseif slot14 and string.find(slot14, trinketName) then
		slot = 14
	end
	if slot then
		local start, duration, enabled = GetInventoryItemCooldown("player", slot)
		if duration == 0 then
			UseInventoryItem(slot)
			return true
		end
	end
	return false
end

-- ==========================================
-- Debuff Recording (debug)
-- ==========================================
function RoguePoker:RecordDebuffs()
	local i = 1
	while true do
		local texture = UnitDebuff("player", i)
		if not texture then break end
		if not RoguePokerDB.discoveredTextures[texture] then
			RoguePokerDB.discoveredTextures[texture] = true
		end
		i = i + 1
	end
end

function RoguePoker:DebugDebuffs()
	local i = 1
	while true do
		local a, b, c, d, e = UnitDebuff("player", i)
		if not a then break end
		if not RoguePoker.badTextures[a] then
			print("Debuff " .. i .. ": " .. tostring(a) .. " | " .. tostring(b) .. " | " .. tostring(c) .. " | " .. tostring(d) .. " | " .. tostring(e))
		end
		i = i + 1
	end
end


function RoguePoker:DebugBuffs()
	for i = 0, 31 do
		local buffIndex = GetPlayerBuff(i, "HELPFUL")
		if buffIndex < 0 then break end
		local timeLeft = GetPlayerBuffTimeLeft(buffIndex)
		print("Buff " .. i .. " index:" .. buffIndex .. " timeLeft:" .. tostring(timeLeft))
	end
	local sdActive, sdTime = RoguePoker:IsActive(RoguePoker.name[1])
	local eActive, eTime = RoguePoker:IsActive(RoguePoker.name[2])
	print("SD active:" .. tostring(sdActive) .. " time:" .. tostring(sdTime))
	print("Envenom active:" .. tostring(eActive) .. " time:" .. tostring(eTime))
end
-- ==========================================
-- Rotation Engine
-- ==========================================

-- Returns the energy cost of a spell so we can check if we should wait for tick
local energyCost = {
	["Slice and Dice"]  = 25,
	["Envenom"]         = 35,
	["Rupture"]         = 25,
	["Eviscerate"]      = 35,
	["Noxious Assault"] = 45,
	["Sinister Strike"] = 45,
	["Backstab"]        = 60,
	["Hemorrhage"]      = 35,
	["Ghostly Strike"]  = 40,
	["Flourish"]        = 20,
	["Evasion"]         = 0,
	["Feint"]           = 20,
	["Vanish"]          = 0,
	["Kick"]            = 25,
	["Gouge"]           = 45,
	["Blind"]           = 30,
	["Deadly Throw"]    = 40,
	["Throw"]           = 0,
}

function RoguePoker:ShouldWait(spellName)
	local cost = energyCost[spellName] or 35
	local energy = UnitMana("player")
	return (energy <= cost and RoguePoker:GetNextTick() > 1)
end

-- Core rotation driven by DB config
function RoguePoker:Rota()
	local db         = RoguePokerDB
	local ka         = db.keepActive
	local ta         = db.tankAbilities
	local builder    = db.comboBuilder or "Noxious Assault"
	local threshold  = db.comboThreshold or 5

	local cP         = GetComboPoints("player")
	local energy     = UnitMana("player")
	local health     = UnitHealth("target")
	local healthMax  = UnitHealthMax("target")
	local healthPct  = (healthMax > 0) and (100 * health / healthMax) or 100
	local mobTargetsMe = RoguePokerDB.tankingMode or ((not UnitIsPlayer("target")) and RoguePoker:IsMyTargetTargetingMe())

	RoguePoker:AutoAttack()

	-- Bad status: try insignia if enabled
	if RoguePokerDB.useInsignia and RoguePoker:IsBadStatus() then
		RoguePoker:UseInsignia()
		return
	end

	-- Assist if targeting a player
	RoguePoker:AssistPlayer()

	-- Always Feint if enabled (fires regardless of who is targeting, disabled in Tanking Mode)
	if RoguePokerDB.alwaysFeint and not RoguePokerDB.tankingMode then
		if ta.feint then
			local _, Fduration = GetSpellCooldown(RoguePoker:FindSpellid(RoguePoker.name[7]), BOOKTYPE_SPELL)
			if Fduration == 0 then
				if not RoguePoker:ShouldWait(RoguePoker.name[7]) then
					CastSpellByName(RoguePoker.name[7])
					return
				end
			end
		end
	end

	-- ---- Tank/Evade abilities (only when mob is targeting me) ----
	if mobTargetsMe then

		-- Feint is highest priority when mob targets me (disabled in Tanking Mode)
		if ta.feint and not RoguePokerDB.tankingMode then
			local _, Fduration = GetSpellCooldown(RoguePoker:FindSpellid(RoguePoker.name[7]), BOOKTYPE_SPELL)
			if Fduration == 0 then
				if not RoguePoker:ShouldWait(RoguePoker.name[7]) then
					CastSpellByName(RoguePoker.name[7])
					return
				end
			end
		end

		-- Vanish is an emergency and bypasses the one-buff rule
		if ta.vanish then
			local playerHealth = UnitHealth("player")
			local playerHealthMax = UnitHealthMax("player")
			local playerHealthPct = (playerHealthMax > 0) and (100 * playerHealth / playerHealthMax) or 100
			local _, Vduration = GetSpellCooldown(RoguePoker:FindSpellid(RoguePoker.name[10]), BOOKTYPE_SPELL)
			if Vduration == 0 and playerHealthPct < 20 then
				CastSpellByName(RoguePoker.name[10])
				return
			end
		end

		-- Check if any tank buff is currently active with more than 2 seconds left
		local tankBuffActive = false
		if ta.ghostlyStrike then
			local GSactive, GStimeLeft = RoguePoker:IsActive(RoguePoker.name[8])
			if GSactive and GStimeLeft > 2 then tankBuffActive = true end
		end
		if ta.flourish then
			local FLactive, FLtimeLeft = RoguePoker:IsActive(RoguePoker.name[11])
			if FLactive and FLtimeLeft > 2 then tankBuffActive = true end
		end
		if ta.evasion then
			local EVactive, EVtimeLeft = RoguePoker:IsActive(RoguePoker.name[9])
			if EVactive and EVtimeLeft > 2 then tankBuffActive = true end
		end

		-- Only try to apply a new tank buff if none are active with > 2s left
		if not tankBuffActive then

			-- Ghostly Strike (highest priority)
			if ta.ghostlyStrike then
				local GSactive, GStimeLeft = RoguePoker:IsActive(RoguePoker.name[8])
				local _, GSduration = GetSpellCooldown(RoguePoker:FindSpellid(RoguePoker.name[8]), BOOKTYPE_SPELL)
				if GSduration == 0 and (not GSactive or GStimeLeft <= 2) then
					if not RoguePoker:ShouldWait(RoguePoker.name[8]) then
						CastSpellByName(RoguePoker.name[8])
						return
					end
				end
			end

			-- Flourish (needs at least 1 CP)
			if ta.flourish and cP > 0 then
				local FLactive, FLtimeLeft = RoguePoker:IsActive(RoguePoker.name[11])
				local _, FLduration = GetSpellCooldown(RoguePoker:FindSpellid(RoguePoker.name[11]), BOOKTYPE_SPELL)
				if FLduration == 0 and (not FLactive or FLtimeLeft <= 2) then
					if not RoguePoker:ShouldWait(RoguePoker.name[11]) then
						CastSpellByName(RoguePoker.name[11])
						return
					end
				end
			end

			-- Evasion - 50% health threshold normally, 60% in tanking mode
			if ta.evasion then
				local playerHealth = UnitHealth("player")
				local playerHealthMax = UnitHealthMax("player")
				local playerHealthPct = (playerHealthMax > 0) and (100 * playerHealth / playerHealthMax) or 100
				local evasionThreshold = RoguePokerDB.tankingMode and 60 or 50
				local EVactive, EVtimeLeft = RoguePoker:IsActive(RoguePoker.name[9])
				local _, EVduration = GetSpellCooldown(RoguePoker:FindSpellid(RoguePoker.name[9]), BOOKTYPE_SPELL)
				if EVduration == 0 and (not EVactive or EVtimeLeft <= 2) and playerHealthPct < evasionThreshold then
					CastSpellByName(RoguePoker.name[9])
					return
				end
			end

		end

	end

	-- ---- Finishers at threshold ----
	if cP >= threshold then

		-- Rupture: only fires at exactly threshold CP and only if not already active
		if ka.rupture then
			local Ractive, RtimeLeft = RoguePoker:IsActive(RoguePoker.name[4])
			if not Ractive or RtimeLeft < 5 then
				if not RoguePoker:ShouldWait(RoguePoker.name[4]) then
					CastSpellByName(RoguePoker.name[4])
					return
				end
			end
		end

		-- Eviscerate on low health
		if not (healthPct > 40 or (health > 5000 and healthPct > 50)) then
			if not RoguePoker:ShouldWait(RoguePoker.name[6]) then
				CastSpellByName(RoguePoker.name[6])
				return
			end
		end

		-- Default finisher: Eviscerate
		if not RoguePoker:ShouldWait(RoguePoker.name[6]) then
			CastSpellByName(RoguePoker.name[6])
			return
		end
	end

	-- ---- Buff upkeep (needs at least 1 CP) ----
	-- Apply if not active OR if active but expiring within 2 seconds

	-- Slice and Dice
	if ka.sliceAndDice and cP >= 1 then
		local SDactive, SDtimeLeft = RoguePoker:IsActive(RoguePoker.name[1])
		local SDneedsRefresh = (not SDactive) or (SDactive and SDtimeLeft > 0.5 and SDtimeLeft < 2)
		if SDneedsRefresh then
			if not RoguePoker:ShouldWait(RoguePoker.name[1]) then
				CastSpellByName(RoguePoker.name[1])
				return
			end
		end
	end

	-- Envenom
	if ka.envenom and cP >= 1 then
		local Eactive, EtimeLeft = RoguePoker:IsActive(RoguePoker.name[2])
		local EneedsRefresh = (not Eactive) or (Eactive and EtimeLeft > 0.5 and EtimeLeft < 2)
		if EneedsRefresh then
			if not RoguePoker:ShouldWait(RoguePoker.name[2]) then
				CastSpellByName(RoguePoker.name[2])
				return
			end
		end
	end

	-- ---- Combo Builder ----
	if not RoguePoker:ShouldWait(builder) then
		CastSpellByName(builder)
	end
end

-- Throw / Deadly Throw
function RoguePoker:Throw()
	local DTStart, DTduration = GetSpellCooldown(RoguePoker:FindSpellid(RoguePoker.name[15]), BOOKTYPE_SPELL)
	if RoguePoker:AtRange() then
		if DTduration == 0 then
			if not RoguePoker:ShouldWait(RoguePoker.name[15]) then
				CastSpellByName(RoguePoker.name[15])
			end
		else
			CastSpellByName(RoguePoker.name[16])
		end
		return true
	end
	return false
end

-- Interrupt rotation
function RoguePoker:Interrupt()
	local _, Kduration = GetSpellCooldown(RoguePoker:FindSpellid(RoguePoker.name[12]), BOOKTYPE_SPELL)
	local _, Gduration = GetSpellCooldown(RoguePoker:FindSpellid(RoguePoker.name[13]), BOOKTYPE_SPELL)
	local _, Bduration = GetSpellCooldown(RoguePoker:FindSpellid(RoguePoker.name[14]), BOOKTYPE_SPELL)
	if RoguePoker:Throw() then return end
	if Kduration == 0 then
		if not RoguePoker:ShouldWait(RoguePoker.name[12]) then
			CastSpellByName(RoguePoker.name[12])
			return
		end
	end
	if Gduration == 0 then
		if not RoguePoker:ShouldWait(RoguePoker.name[13]) then
			CastSpellByName(RoguePoker.name[13])
			AttackTarget()
			return
		end
	end
	if Bduration == 0 then
		if not RoguePoker:ShouldWait(RoguePoker.name[14]) then
			CastSpellByName(RoguePoker.name[14])
			AttackTarget()
			return
		end
	end
end

-- RotaEvade wrapper
function RoguePoker:RotaEvade()
	RoguePoker:AssistPlayer()
	RoguePoker:Rota()
end

-- ==========================================
-- UI
-- ==========================================

local UI = {}
RoguePoker.UI = UI

local function MakeLabel(parent, text, size, r, g, b)
	local fs = parent:CreateFontString(nil, "OVERLAY", size or "GameFontNormal")
	fs:SetText(text or "")
	if r then fs:SetTextColor(r, g, b) end
	return fs
end

local function MakeCheckbox(parent, label, x, y, getVal, setVal)
	local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	cb:SetWidth(20)
	cb:SetHeight(20)
	cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
	cb:SetChecked(false)
	cb:SetScript("OnClick", function()
		setVal(cb:GetChecked() == 1)
	end)
	local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	lbl:SetPoint("LEFT", cb, "RIGHT", 2, 0)
	lbl:SetText(label)
	lbl:SetTextColor(0.9, 0.9, 0.9)
	return cb, lbl
end

-- ---- Main Frame ----
-- ---- Config Frame ----
local cfgFrame = CreateFrame("Frame", "RoguePokerConfigFrame", UIParent)
cfgFrame:SetWidth(300)
cfgFrame:SetHeight(450)
cfgFrame:SetBackdrop({
	bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
	edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
	tile = true, tileSize = 16, edgeSize = 16,
	insets = { left = 4, right = 4, top = 4, bottom = 4 }
})
cfgFrame:SetMovable(true)
cfgFrame:EnableMouse(true)
cfgFrame:RegisterForDrag("LeftButton")
cfgFrame:SetScript("OnDragStart", function() cfgFrame:StartMoving() end)
cfgFrame:SetScript("OnDragStop", function() cfgFrame:StopMovingOrSizing() end)
cfgFrame:Hide()

local cfgTitle = cfgFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
cfgTitle:SetPoint("TOP", cfgFrame, "TOP", 0, -10)
cfgTitle:SetText("RoguePoker Config")
cfgTitle:SetTextColor(1, 0.82, 0)

-- Close button
local closeBtn = CreateFrame("Button", nil, cfgFrame, "UIPanelButtonTemplate")
closeBtn:SetWidth(60)
closeBtn:SetHeight(20)
closeBtn:SetPoint("TOPRIGHT", cfgFrame, "TOPRIGHT", -8, -8)
closeBtn:SetText("Close")
closeBtn:SetScript("OnClick", function() cfgFrame:Hide() end)

-- ---- Section: Combo Builder ----
local builderTitle = cfgFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
builderTitle:SetPoint("TOPLEFT", cfgFrame, "TOPLEFT", 10, -38)
builderTitle:SetText("Combo Builder:")
builderTitle:SetTextColor(0.6, 0.8, 1)

local builders = {
	{ label = "Noxious Assault", key = "Noxious Assault" },
	{ label = "Sinister Strike",  key = "Sinister Strike" },
	{ label = "Backstab",         key = "Backstab" },
	{ label = "Hemorrhage",       key = "Hemorrhage" },
}

local builderBtns = {}
local bX = 10
for _, b in ipairs(builders) do
	local btn = CreateFrame("Button", nil, cfgFrame, "UIPanelButtonTemplate")
	btn:SetWidth(66)
	btn:SetHeight(18)
	btn:SetPoint("TOPLEFT", cfgFrame, "TOPLEFT", bX, -55)
	btn:SetText(b.label == "Noxious Assault" and "Noxious" or b.label)
	local bKey = b.key
	btn:SetScript("OnClick", function()
		RoguePokerDB.comboBuilder = bKey
		-- highlight selected
		for _, bb in ipairs(builderBtns) do
			bb:SetAlpha(bb.key == bKey and 1.0 or 0.55)
		end
	end)
	btn.key = b.key
	table.insert(builderBtns, btn)
	bX = bX + 70
end

-- ---- Section: Combo Threshold ----
local thresholdLabel = cfgFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
thresholdLabel:SetPoint("TOPLEFT", cfgFrame, "TOPLEFT", 10, -82)
thresholdLabel:SetText("Finisher at CP: 5")
thresholdLabel:SetTextColor(0.6, 0.8, 1)

local threshSlider = CreateFrame("Slider", "RoguePokerThreshSlider", cfgFrame, "OptionsSliderTemplate")
threshSlider:SetPoint("TOPLEFT", cfgFrame, "TOPLEFT", 10, -100)
threshSlider:SetWidth(200)
threshSlider:SetHeight(16)
threshSlider:SetMinMaxValues(1, 5)
threshSlider:SetValueStep(1)
getglobal(threshSlider:GetName() .. "Low"):SetText("1")
getglobal(threshSlider:GetName() .. "High"):SetText("5")
getglobal(threshSlider:GetName() .. "Text"):SetText("")
threshSlider:SetScript("OnValueChanged", function()
	local v = math.floor(threshSlider:GetValue())
	RoguePokerDB.comboThreshold = v
	thresholdLabel:SetText("Finisher at CP: " .. v)
end)

-- ---- Section: Keep Active Buffs ----
local kaTitle = cfgFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
kaTitle:SetPoint("TOPLEFT", cfgFrame, "TOPLEFT", 10, -124)
kaTitle:SetText("Keep Active:")
kaTitle:SetTextColor(0.6, 0.8, 1)

local keepActiveData = {
	{ key = "sliceAndDice", label = "Slice and Dice" },
	{ key = "envenom",      label = "Envenom" },
	{ key = "rupture",      label = "Rupture" },
}

local kaCBs = {}
for idx, d in ipairs(keepActiveData) do
	local cx = 10 + (idx - 1) * 90
	local cy = -142
	local dKey = d.key
	local cb, lbl = MakeCheckbox(cfgFrame, d.label, cx, cy,
		function() return RoguePokerDB.keepActive and RoguePokerDB.keepActive[dKey] end,
		function(v) if RoguePokerDB.keepActive then RoguePokerDB.keepActive[dKey] = v end end
	)
	kaCBs[dKey] = cb
end

-- ---- Section: Tank Abilities ----
local tankTitle = cfgFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
tankTitle:SetPoint("TOPLEFT", cfgFrame, "TOPLEFT", 10, -174)
tankTitle:SetText("When Mob Targets Me:")
tankTitle:SetTextColor(1, 0.5, 0.3)

local tankData = {
	{ key = "ghostlyStrike", label = "Ghostly Strike" },
	{ key = "flourish",      label = "Flourish" },
	{ key = "evasion",       label = "Evasion" },
	{ key = "feint",         label = "Feint" },
	{ key = "vanish",        label = "Vanish" },
}

local tankCBs = {}
for idx, d in ipairs(tankData) do
	local col = (idx <= 3) and 0 or 1
	local row = (idx <= 3) and (idx - 1) or (idx - 4)
	local cx = 10 + col * 140
	local cy = -192 - row * 22
	local dKey = d.key
	local cb, lbl = MakeCheckbox(cfgFrame, d.label, cx, cy,
		function() return RoguePokerDB.tankAbilities and RoguePokerDB.tankAbilities[dKey] end,
		function(v) if RoguePokerDB.tankAbilities then RoguePokerDB.tankAbilities[dKey] = v end end
	)
	tankCBs[dKey] = cb
end

-- ---- Section: Tanking Mode ----
local tankingModeTitle = cfgFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
tankingModeTitle:SetPoint("TOPLEFT", cfgFrame, "TOPLEFT", 10, -258)
tankingModeTitle:SetText("Tanking Mode:")
tankingModeTitle:SetTextColor(1, 0.5, 0.3)

local tankingModeCB, tankingModeLbl = MakeCheckbox(cfgFrame, "Always use tank rotation (no Feint)", 10, -276,
	function() return RoguePokerDB.tankingMode end,
	function(v) RoguePokerDB.tankingMode = v end
)

-- ---- Section: Always Feint ----
local alwaysFeintTitle = cfgFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
alwaysFeintTitle:SetPoint("TOPLEFT", cfgFrame, "TOPLEFT", 10, -306)
alwaysFeintTitle:SetText("Threat Management:")
alwaysFeintTitle:SetTextColor(0.6, 0.8, 1)

local alwaysFeintCB, alwaysFeintLbl = MakeCheckbox(cfgFrame, "Always Feint (reduces threat)", 10, -324,
	function() return RoguePokerDB.alwaysFeint end,
	function(v) RoguePokerDB.alwaysFeint = v end
)

-- ---- Section: PvP Trinket ----
local insigniaTitle = cfgFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
insigniaTitle:SetPoint("TOPLEFT", cfgFrame, "TOPLEFT", 10, -350)
insigniaTitle:SetText("PvP Trinket:")
insigniaTitle:SetTextColor(0.6, 0.8, 1)

local insigniaCB, insigniaLbl = MakeCheckbox(cfgFrame, "Use Insignia of the Horde when stunned", 10, -368,
	function() return RoguePokerDB.useInsignia end,
	function(v) RoguePokerDB.useInsignia = v end
)

-- Save button
local saveBtn = CreateFrame("Button", nil, cfgFrame, "UIPanelButtonTemplate")
saveBtn:SetWidth(80)
saveBtn:SetHeight(24)
saveBtn:SetPoint("BOTTOM", cfgFrame, "BOTTOM", 0, 12)
saveBtn:SetText("Save & Close")
saveBtn:SetScript("OnClick", function()
	cfgFrame:Hide()
	print("RoguePoker: Settings saved.")
end)

-- Keep builder buttons highlighted correctly when config is open
local updateFrame = CreateFrame("Frame")
local elapsed = 0
updateFrame:SetScript("OnUpdate", function()
	elapsed = elapsed + arg1
	if elapsed < 0.3 then return end
	elapsed = 0
	if not RoguePokerDB or not cfgFrame:IsShown() then return end
	if RoguePokerDB.comboBuilder then
		for _, bb in ipairs(builderBtns) do
			bb:SetAlpha(bb.key == RoguePokerDB.comboBuilder and 1.0 or 0.55)
		end
	end
end)

-- ==========================================
-- Load Event
-- ==========================================
local loadFrame = CreateFrame("Frame")
loadFrame:RegisterEvent("VARIABLES_LOADED")
loadFrame:SetScript("OnEvent", function()
	InitDB()


	-- Restore threshold slider
	threshSlider:SetValue(RoguePokerDB.comboThreshold or 5)
	thresholdLabel:SetText("Finisher at CP: " .. (RoguePokerDB.comboThreshold or 5))

	-- Restore checkboxes
	for k, cb in pairs(kaCBs) do
		cb:SetChecked(RoguePokerDB.keepActive[k])
	end
	for k, cb in pairs(tankCBs) do
		cb:SetChecked(RoguePokerDB.tankAbilities[k])
	end
	insigniaCB:SetChecked(RoguePokerDB.useInsignia)
	tankingModeCB:SetChecked(RoguePokerDB.tankingMode)
	alwaysFeintCB:SetChecked(RoguePokerDB.alwaysFeint)

	-- Highlight active builder
	for _, bb in ipairs(builderBtns) do
		bb:SetAlpha(bb.key == RoguePokerDB.comboBuilder and 1.0 or 0.55)
	end

	print("|cFFFFD700RoguePoker|r loaded successfully!")
	print("Type |cFFFFD700/rp|r to open the configuration panel.")
	print("Use |cFFFFD700/script RoguePoker:Rota()|r in a macro to run the rotation.")
end)

-- ==========================================
-- Slash Command
-- ==========================================
SLASH_ROGUEPOKR1 = "/rp"
SlashCmdList["ROGUEPOKR"] = function(msg)
	if cfgFrame:IsShown() then
		cfgFrame:Hide()
	else
		cfgFrame:ClearAllPoints()
		cfgFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
		cfgFrame:Show()
	end
end
