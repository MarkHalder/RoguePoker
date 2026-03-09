-- ==========================================
-- RoguePoker - Rogue Rotation Advisor
-- Turtle WoW (1.18 Client)
-- ==========================================
-- .toc requires: ## SavedVariables: RoguePokerDB

-- ==========================================
-- Global State
-- ==========================================
RoguePoker = {}
RoguePoker.TickTime = 2
RoguePoker.FirstTick = nil
RoguePoker.Energy = 110
RoguePoker.isAttacking = false
RoguePoker.surpriseAttackReady = false
RoguePoker.riposteReady = false
RoguePoker.shadowOfDeathPending = false

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
-- Master Ability Definitions
-- ==========================================

-- Combo builders to choose from
RoguePoker.BUILDERS = {
	"Sinister Strike",
	"Noxious Assault",
	"Backstab",
	"Hemorrhage",
}

-- Finishers with default CP threshold and type
-- type: "buff" (keep active), "dot" (don't reapply while active),
--       "damage" (always cast at CP), "conditional" (no CP req, cast when available)
RoguePoker.FINISHER_DEFAULTS = {
	{ name = "Slice and Dice",  minCP = 1, kind = "buff" },
	{ name = "Envenom",         minCP = 1, kind = "buff" },
	{ name = "Rupture",         minCP = 5, kind = "dot" },
	{ name = "Expose Armor",    minCP = 5, kind = "dot" },
	{ name = "Shadow of Death", minCP = 5, kind = "dot" },
	{ name = "Eviscerate",      minCP = 5, kind = "damage" },
	{ name = "Riposte",         minCP = 0, kind = "conditional" },
	{ name = "Surprise Attack", minCP = 0, kind = "conditional" },
	{ name = "Mark for Death",  minCP = 0, kind = "conditional" },
}

-- Evasion abilities
RoguePoker.EVASION_DEFAULTS = {
	{ name = "Feint" },
	{ name = "Ghostly Strike" },
	{ name = "Flourish" },
	{ name = "Evasion" },
	{ name = "Vanish" },
}

-- Interrupt abilities master list
RoguePoker.INTERRUPT_DEFAULTS = {
	{ name = "Deadly Throw" },
	{ name = "Throw/Shoot" },
	{ name = "Kick" },
	{ name = "Kidney Shot", minCP = 1 },
	{ name = "Gouge" },
	{ name = "Blind" },
}

-- Energy costs for ShouldWait check
RoguePoker.energyCost = {
	["Sinister Strike"]  = 45,
	["Noxious Assault"]  = 45,
	["Backstab"]         = 60,
	["Hemorrhage"]       = 35,
	["Slice and Dice"]   = 25,
	["Envenom"]          = 35,
	["Rupture"]          = 25,
	["Eviscerate"]       = 35,
	["Expose Armor"]     = 25,
	["Shadow of Death"]  = 30,
	["Mark for Death"]   = 40,
	["Riposte"]          = 10,
	["Surprise Attack"]  = 0,
	["Deadly Throw"]     = 35,
	["Kidney Shot"]    = 25,
	["Throw/Shoot"]      = 0,
	["Feint"]            = 20,
	["Ghostly Strike"]   = 40,
	["Flourish"]         = 20,
	["Evasion"]          = 0,
	["Vanish"]           = 0,
}

-- ==========================================
-- Spellbook Scanner
-- ==========================================
function RoguePoker:HasSpell(spellName)
	for i = 1, 200 do
		local name = GetSpellName(i, BOOKTYPE_SPELL)
		if name and name == spellName then return true end
	end
	return false
end

function RoguePoker:FindSpellid(spellName)
	for i = 1, 200 do
		local name = GetSpellName(i, BOOKTYPE_SPELL)
		if name and name == spellName then return i end
	end
	return 0
end

-- Scans spellbook and returns filtered list, keeping only known spells
-- Core rogue builders are always included regardless of scan result
local ALWAYS_KNOWN_BUILDERS = { ["Sinister Strike"] = true, ["Backstab"] = true }
function RoguePoker:FilterKnown(list)
	local result = {}
	for _, entry in ipairs(list) do
		local n = type(entry) == "table" and entry.name or entry
		if ALWAYS_KNOWN_BUILDERS[n] or RoguePoker:HasSpell(n) then
			result[table.getn(result) + 1] = entry
		end
	end
	return result
end

-- ==========================================
-- Default Settings
-- ==========================================
local defaults = {
	comboBuilder  = "Sinister Strike",
	useInsignia   = true,
	alwaysFeint   = false,
	-- finishers: ordered list of { name, minCP, enabled }
	finishers = {
		{ name = "Slice and Dice",  minCP = 1, enabled = true,  kind = "buff" },
		{ name = "Envenom",         minCP = 1, enabled = true,  kind = "buff" },
		{ name = "Rupture",         minCP = 5, enabled = true,  kind = "dot" },
		{ name = "Expose Armor",    minCP = 5, enabled = false, kind = "dot" },
		{ name = "Shadow of Death", minCP = 5, enabled = true,  kind = "dot" },
		{ name = "Eviscerate",      minCP = 5, enabled = true,  kind = "damage" },
		{ name = "Riposte",         minCP = 0, enabled = true,  kind = "conditional" },
		{ name = "Surprise Attack", minCP = 0, enabled = false, kind = "conditional" },
		{ name = "Mark for Death",  minCP = 0, enabled = true,  kind = "conditional" },
	},
	-- evasion: ordered list of { name, enabled, healthPct (optional) }
	evasion = {
		{ name = "Feint",          enabled = true },
		{ name = "Ghostly Strike", enabled = true },
		{ name = "Flourish",       enabled = true },
		{ name = "Evasion",        enabled = true,  healthPct = 50 },
		{ name = "Vanish",         enabled = true,  healthPct = 20 },
	},
	-- interrupt: ordered list of { name, enabled }
	interrupt = {
		{ name = "Deadly Throw",  enabled = true,  minCP = nil },
		{ name = "Throw/Shoot",   enabled = true,  minCP = nil },
		{ name = "Kick",          enabled = true,  minCP = nil },
		{ name = "Kidney Shot",   enabled = true,  minCP = 1   },
		{ name = "Gouge",         enabled = true,  minCP = nil },
		{ name = "Blind",         enabled = false, minCP = nil },
	},
}

-- ==========================================
-- DB Init
-- ==========================================
local function deepCopy(orig)
	if orig == nil then return {} end
	local copy = {}
	for k, v in pairs(orig) do
		if type(v) == "table" then
			copy[k] = deepCopy(v)
		else
			copy[k] = v
		end
	end
	return copy
end

local function isEmpty(t)
	return t == nil or table.getn(t) == 0
end

local function InitDB()
	RoguePokerDB = RoguePokerDB or {}
	if RoguePokerDB.comboBuilder  == nil then RoguePokerDB.comboBuilder  = defaults.comboBuilder  end
	if RoguePokerDB.useInsignia   == nil then RoguePokerDB.useInsignia   = defaults.useInsignia   end
	if RoguePokerDB.alwaysFeint   == nil then RoguePokerDB.alwaysFeint   = defaults.alwaysFeint   end
	if isEmpty(RoguePokerDB.finishers) then RoguePokerDB.finishers = deepCopy(defaults.finishers)  end
	if isEmpty(RoguePokerDB.evasion)   then RoguePokerDB.evasion   = deepCopy(defaults.evasion)    end
	if isEmpty(RoguePokerDB.interrupt) then RoguePokerDB.interrupt = deepCopy(defaults.interrupt)  end
	-- Migrate old "Throw" entry to "Throw/Shoot"
	if RoguePokerDB.interrupt then
		for _, ab in ipairs(RoguePokerDB.interrupt) do
			if ab.name == "Throw" then ab.name = "Throw/Shoot" end

		end
	end
	RoguePokerDB.discoveredTextures = RoguePokerDB.discoveredTextures or {}
end

-- ==========================================
-- Core Utility Functions
-- ==========================================

function RoguePoker:GetNextTick()
	if not RoguePoker.FirstTick then return 0 end
	local i, now = RoguePoker.FirstTick, GetTime()
	while true do
		if i > now then return i - now end
		i = i + RoguePoker.TickTime
	end
end

function RoguePoker:ShouldWait(spellName)
	local cost = RoguePoker.energyCost[spellName] or 35
	local energy = UnitMana("player")
	-- Never block if we already have enough energy
	if energy >= cost then return false end
	-- Block only if the next tick is more than 1 second away
	return RoguePoker:GetNextTick() > 1
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

-- Textures for debuffs we apply to the target
RoguePoker.targetDebuffTextures = {
	["Expose Armor"]    = "ability_warrior_riposte",
	["Shadow of Death"] = "spell_shadow_deathanddecay",
}

RoguePoker.targetDebuffDuration = {
	["Expose Armor"]    = 30,
	["Shadow of Death"] = 24,
}

local debuffTooltipFrame = nil
function RoguePoker:IsActiveOnTarget(name)
	local expiry = RoguePoker.debuffExpiry and RoguePoker.debuffExpiry[name]

	if expiry then
		local timeLeft = expiry - GetTime()
		if timeLeft > 0 then
			return true, timeLeft
		end
		RoguePoker.debuffExpiry[name] = nil
	end

	return false, 0
end

-- Record expiry when we cast a debuff on the target
function RoguePoker:TrackDebuff(name, duration)
	if not RoguePoker.debuffExpiry then RoguePoker.debuffExpiry = {} end
	RoguePoker.debuffExpiry[name] = GetTime() + duration
end

function RoguePoker:AutoAttack()
	-- Only start auto-attack if not already in combat to avoid toggling it off
	if not RoguePoker.isAttacking then
		RoguePoker.isAttacking = true
		AttackTarget()
	end
end

function RoguePoker:AtRange()
	-- UnitInRange returns true within ~30 yards, covering all ranged weapons
	-- Falls back to true if the function is unavailable so we don't silently block
	if UnitInRange then
		return UnitInRange("target") == 1
	end
	return true
end

function RoguePoker:GetRangedWeaponType()
	local rangedLink = GetInventoryItemLink("player", 18)
	if not rangedLink then return nil end
	if not RoguePoker.rangedTip then
		RoguePoker.rangedTip = CreateFrame("GameTooltip", "RoguePokerRangedTip", UIParent, "GameTooltipTemplate")
		RoguePoker.rangedTip:SetOwner(UIParent, "ANCHOR_NONE")
	end
	local tip = RoguePoker.rangedTip
	tip:ClearLines()
	tip:SetInventoryItem("player", 18)
	for i = 1, tip:NumLines() do
		local line = getglobal("RoguePokerRangedTipTextLeft" .. i)
		if line then
			local t = line:GetText()
			if t then
				if string.find(t, "Thrown")   then return "Thrown"
				elseif string.find(t, "Crossbow") then return "Crossbow"
				elseif string.find(t, "Bow")      then return "Bow"
				elseif string.find(t, "Gun")      then return "Gun"
				elseif string.find(t, "Wand")     then return "Wand"
				end
			end
		end
	end
	return nil
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
	local slot13 = GetInventoryItemLink("player", 13)
	local slot14 = GetInventoryItemLink("player", 14)
	local slot = nil
	local function isInsignia(link)
		return link and (string.find(link, "Insignia of the Horde") or string.find(link, "Insignia of the Alliance"))
	end
	if isInsignia(slot13) then slot = 13
	elseif isInsignia(slot14) then slot = 14 end
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
-- Rotation Engine
-- ==========================================

function RoguePoker:Rota()
	local db          = RoguePokerDB
	local cP          = GetComboPoints("player")
	local energy      = UnitMana("player")
	local mobTargetsMe = (not UnitIsPlayer("target")) and RoguePoker:IsMyTargetTargetingMe()


	RoguePoker:AutoAttack()
	RoguePoker:AssistPlayer()

	-- Insignia on bad status
	if db.useInsignia and RoguePoker:IsBadStatus() then
		RoguePoker:UseInsignia()
		return
	end

	-- ---- Always Feint (threat reduction, not in tank mode) ----
	if db.alwaysFeint then
		local feintEnabled = false
		for _, ev in ipairs(db.evasion) do
			if ev.name == "Feint" and ev.enabled then feintEnabled = true break end
		end
		if feintEnabled then
			local sid = RoguePoker:FindSpellid("Feint")
			if sid > 0 then
				local _, dur = GetSpellCooldown(sid, BOOKTYPE_SPELL)
				if dur == 0 and not RoguePoker:ShouldWait("Feint") then
					CastSpellByName("Feint")
					return
				end
			end
		end
	end


	-- ---- Evasion / Tank abilities ----
	if mobTargetsMe then
		for _, ev in ipairs(db.evasion) do
			if ev.enabled then
				local name = ev.name
				local sid = RoguePoker:FindSpellid(name)
				if sid > 0 then
					local _, dur = GetSpellCooldown(sid, BOOKTYPE_SPELL)

					-- Feint: cast whenever off cooldown
					if name == "Feint" then
						if dur == 0 and not RoguePoker:ShouldWait(name) then
							CastSpellByName(name)
							return
						end

					-- Vanish: emergency only below configured health threshold
					elseif name == "Vanish" then
						local ph = UnitHealth("player")
						local phMax = UnitHealthMax("player")
						local phPct = (phMax > 0) and (100 * ph / phMax) or 100
						local threshold = ev.healthPct or 20
						if dur == 0 and phPct < threshold then
							CastSpellByName(name)
							return
						end

					-- Evasion: only below configured health threshold, not if GS/Flourish active
					elseif name == "Evasion" then
						local ph = UnitHealth("player")
						local phMax = UnitHealthMax("player")
						local phPct = (phMax > 0) and (100 * ph / phMax) or 100
						local threshold = ev.healthPct or 50
						local active, timeLeft = RoguePoker:IsActive(name)
						-- Don't override Ghostly Strike or Flourish if still active > 2s
						local otherActive = false
						for _, ev2 in ipairs(db.evasion) do
							if ev2.name ~= "Feint" and ev2.name ~= "Vanish" and ev2.name ~= "Evasion" then
								local a, t = RoguePoker:IsActive(ev2.name)
								if a and t > 2 then otherActive = true break end
							end
						end
						if dur == 0 and phPct < threshold and not otherActive and (not active or timeLeft <= 2) then
							CastSpellByName(name)
							return
						end

					-- Ghostly Strike / Flourish: one-buff-at-a-time rule with Evasion
					else
						-- Check if any evasion buff (including Evasion itself) is already active > 2s
						local buffActive = false
						for _, ev2 in ipairs(db.evasion) do
							if ev2.name ~= "Feint" and ev2.name ~= "Vanish" then
								local a, t = RoguePoker:IsActive(ev2.name)
								if a and t > 2 then buffActive = true break end
							end
						end
						if not buffActive then
							local active, timeLeft = RoguePoker:IsActive(name)
							local needsCP = (name == "Flourish")
							if dur == 0 and (not active or timeLeft <= 2) then
								if not needsCP or cP > 0 then
									if not RoguePoker:ShouldWait(name) then
										CastSpellByName(name)
										return
									end
								end
							end
						end
					end
				end
			end
		end
	end

	-- ---- Mark for Death + Shadow of Death combo ----
	-- If both are enabled and ready, and we have (sodMinCP - 2) or more CP,
	-- cast Mark for Death first to generate 2 CP and buff AP, then lock Shadow of Death next.
	-- Exception: if Shadow of Death is disabled or not known, Mark for Death fires on its own.
	if not RoguePoker.shadowOfDeathPending then
		local mfdEntry, sodEntry = nil, nil
		for _, fin in ipairs(db.finishers) do
			if fin.name == "Mark for Death"  and fin.enabled then mfdEntry = fin end
			if fin.name == "Shadow of Death" and fin.enabled then sodEntry = fin end
		end
		if mfdEntry then
			local mfdSid = RoguePoker:FindSpellid("Mark for Death")
			if mfdSid > 0 then
				local _, mfdDur = GetSpellCooldown(mfdSid, BOOKTYPE_SPELL)
				if mfdDur == 0 and not RoguePoker:ShouldWait("Mark for Death") then
					local sodAvailable = false
					if sodEntry then
						local sodSid = RoguePoker:FindSpellid("Shadow of Death")
						if sodSid > 0 then
							local sodMinCP = sodEntry.minCP or 5
							local _, sodDur = GetSpellCooldown(sodSid, BOOKTYPE_SPELL)
							local sodActive = RoguePoker:IsActiveOnTarget("Shadow of Death")
							if sodDur == 0 and not sodActive and cP >= (sodMinCP - 2) then
								sodAvailable = true
							end
						end
					end
					local sodKnown = RoguePoker:HasSpell("Shadow of Death")
					local sodEnabled = sodEntry ~= nil
					if sodAvailable then
						RoguePoker.shadowOfDeathPending = true
						RoguePoker.shadowOfDeathPendingTime = GetTime()
						CastSpellByName("Mark for Death")
						return
					elseif not sodEnabled or not sodKnown then
						CastSpellByName("Mark for Death")
						return
					end
				end
			end
		end
	end

	-- If Shadow of Death is pending (Mark for Death just fired), cast it immediately
	if RoguePoker.shadowOfDeathPending then
		local elapsed = RoguePoker.shadowOfDeathPendingTime and (GetTime() - RoguePoker.shadowOfDeathPendingTime) or 0
		if elapsed > 6 then
			RoguePoker.shadowOfDeathPending = false
			RoguePoker.shadowOfDeathPendingTime = nil
		else
			local sodSid = RoguePoker:FindSpellid("Shadow of Death")
			if sodSid > 0 then
				local _, sodDur = GetSpellCooldown(sodSid, BOOKTYPE_SPELL)
				if sodDur == 0 and not RoguePoker:ShouldWait("Shadow of Death") then
					RoguePoker.shadowOfDeathPending = false
					RoguePoker.shadowOfDeathPendingTime = nil
					CastSpellByName("Shadow of Death")
					return
				end
			else
				RoguePoker.shadowOfDeathPending = false
				RoguePoker.shadowOfDeathPendingTime = nil
			end
			return
		end
	end

	-- ---- Finishers (work down priority list) ----
	for _, fin in ipairs(db.finishers) do
		if fin.enabled then
			local name = fin.name
			local kind = fin.kind or "damage"
			local minCP = fin.minCP or 1

			-- Conditional abilities: no CP requirement, fire when available
			if kind == "conditional" then
				-- Mark for Death is handled exclusively by the combo block above
				if name == "Mark for Death" then
					-- skip, handled by MfD+SoD combo logic
				else
				local sid = RoguePoker:FindSpellid(name)
				if sid > 0 then
					local _, dur = GetSpellCooldown(sid, BOOKTYPE_SPELL)
					local canFire = dur == 0
					-- Surprise Attack only fires when dodge proc is active
					if name == "Surprise Attack" then
						-- Expire the proc if more than 3s have passed since the dodge
						if RoguePoker.surpriseAttackTime and (GetTime() - RoguePoker.surpriseAttackTime) > 3 then
							RoguePoker.surpriseAttackReady = false
							RoguePoker.surpriseAttackTime = nil
						end
						canFire = canFire and RoguePoker.surpriseAttackReady
					end
					-- Riposte only fires when parry proc is active
					if name == "Riposte" then
						canFire = canFire and RoguePoker.riposteReady
					end
					if canFire then
						if not RoguePoker:ShouldWait(name) then
							if name == "Surprise Attack" then
								RoguePoker.surpriseAttackReady = false
								RoguePoker.surpriseAttackTime = nil
							elseif name == "Riposte" then
								RoguePoker.riposteReady = false
							end
							CastSpellByName(name)
							return
						end
					end
				end
				end

			-- All other finishers require minimum CP
			elseif cP >= minCP then
				-- For Rupture, activity is indicated by "Taste for Blood" buff on player
				-- For Expose Armor, check the debuff on the target
				local active, timeLeft
				if name == "Rupture" then
					active, timeLeft = RoguePoker:IsActive("Taste for Blood")
				elseif name == "Expose Armor" then
					active, timeLeft = RoguePoker:IsActiveOnTarget("Expose Armor")
					-- Failsafe: if CP threshold is met, do a live texture scan to confirm debuff is actually on target
					-- If it's missing despite our timer saying active, reset and recast
					if active and cP >= minCP then
						local matchTexture = RoguePoker.targetDebuffTextures["Expose Armor"]
						local found = false
						if matchTexture then
							for i = 1, 40 do
								local texture = UnitDebuff("target", i)
								if not texture then break end
								local iconName = string.lower(string.gsub(texture, ".*\\", ""))
								if iconName == matchTexture then
									found = true
									break
								end
							end
						end
						if not found then
							-- Timer says active but debuff is gone - force recast
							RoguePoker.debuffExpiry["Expose Armor"] = nil
							active, timeLeft = false, 0
						end
					end
				else
					active, timeLeft = RoguePoker:IsActive(name)
				end

				if kind == "buff" then
					local needsRefresh = (not active) or (active and timeLeft > 0.5 and timeLeft < 2)
					if needsRefresh and not RoguePoker:ShouldWait(name) then
						CastSpellByName(name)
						return
					end

				elseif kind == "dot" then
					local refreshWindow = 5
					if (not active or timeLeft < refreshWindow) and not RoguePoker:ShouldWait(name) then
						if name == "Expose Armor" then
							RoguePoker:TrackDebuff("Expose Armor", 30)
						end
						CastSpellByName(name)
						return
					end

				else -- damage
					if not RoguePoker:ShouldWait(name) then
						CastSpellByName(name)
						return
					end
				end
			else
			end
		end
	end

	-- ---- Combo Builder ----
	local builder = db.comboBuilder or "Sinister Strike"

	-- Backstab requires being behind the target - fall back to Sinister Strike
	if builder == "Backstab" and mobTargetsMe then
		builder = "Sinister Strike"
	end

	if not RoguePoker:ShouldWait(builder) then
		CastSpellByName(builder)
	end
end

-- ==========================================
-- Interrupt Engine
-- ==========================================
function RoguePoker:Interrupt()
	local db = RoguePokerDB
	for _, ab in ipairs(db.interrupt) do
		if ab.enabled then
			local name = ab.name
			local isRanged = (name == "Deadly Throw" or name == "Throw/Shoot")

			-- Resolve castable spell name
			local castName = name

			if name == "Deadly Throw" then
				-- Requires a thrown weapon equipped
				local wtype = RoguePoker:GetRangedWeaponType()
				if wtype ~= "Thrown" then
					-- No thrown weapon, skip and fall through
					castName = nil
				end

			elseif name == "Throw/Shoot" then
				-- Resolve to the correct spell for the equipped ranged weapon
				local wtype = RoguePoker:GetRangedWeaponType()
				if     wtype == "Thrown"   then castName = "Throw"
				elseif wtype == "Bow"      then castName = "Shoot Bow"
				elseif wtype == "Crossbow" then castName = "Shoot Crossbow"
				elseif wtype == "Gun"      then castName = "Shoot Gun"
				elseif wtype == "Wand"     then castName = "Shoot"
				else castName = nil  -- no ranged weapon equipped, skip
				end
			end

			-- Kidney Shot requires minimum combo points
			if castName == "Kidney Shot" then
				local cP = GetComboPoints("player")
				if cP < (ab.minCP or 1) then castName = nil end
			end

			if castName then
				-- Ranged abilities: check range first
				if isRanged then
					if RoguePoker:AtRange() then
						local sid = RoguePoker:FindSpellid(castName)
						if sid > 0 then
							local _, dur = GetSpellCooldown(sid, BOOKTYPE_SPELL)
							if dur == 0 then
								if not RoguePoker:ShouldWait(castName) then
									CastSpellByName(castName)
									return
								end
							end
						end
					end
				else
					local sid = RoguePoker:FindSpellid(castName)
					if sid > 0 then
						local _, dur = GetSpellCooldown(sid, BOOKTYPE_SPELL)
						if dur == 0 then
							if not RoguePoker:ShouldWait(castName) then
								CastSpellByName(castName)
								return
							end
						end
					end
				end
			end
		end
	end
end

-- ==========================================
-- Debug Helpers
-- ==========================================
function RoguePoker:DebugBuffs()
	for i = 0, 31 do
		local buffIndex = GetPlayerBuff(i, "HELPFUL")
		if buffIndex < 0 then break end
		local timeLeft = GetPlayerBuffTimeLeft(buffIndex)
		print("Buff " .. i .. " index:" .. buffIndex .. " timeLeft:" .. tostring(timeLeft))
	end
	local sdActive, sdTime = RoguePoker:IsActive("Slice and Dice")
	local eActive, eTime   = RoguePoker:IsActive("Envenom")
	print("SD active:" .. tostring(sdActive) .. " time:" .. tostring(sdTime))
	print("Envenom active:" .. tostring(eActive) .. " time:" .. tostring(eTime))
end

function RoguePoker:DebugDebuffs()
	local i = 1
	while true do
		local a, b, c, d, e = UnitDebuff("player", i)
		if not a then break end
		if not RoguePoker.badTextures[a] then
			print("Debuff " .. i .. ": " .. tostring(a))
		end
		i = i + 1
	end
end

function RoguePoker:PrintSpellid()
	for i = 1, 200 do
		local name, rank = GetSpellName(i, BOOKTYPE_SPELL)
		if not name then break end
		print(i, name, rank)
	end
end

-- ==========================================
-- UI Helpers
-- ==========================================
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

-- ==========================================
-- Config Frame (tabbed)
-- ==========================================
local cfgFrame = CreateFrame("Frame", "RoguePokerConfigFrame", UIParent)
cfgFrame:SetWidth(380)
cfgFrame:SetHeight(620)
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

local closeBtn = CreateFrame("Button", nil, cfgFrame, "UIPanelButtonTemplate")
closeBtn:SetWidth(60)
closeBtn:SetHeight(20)
closeBtn:SetPoint("TOPRIGHT", cfgFrame, "TOPRIGHT", -8, -8)
closeBtn:SetText("Close")
closeBtn:SetScript("OnClick", function() cfgFrame:Hide() end)

-- ==========================================
-- Tab Panels
-- ==========================================
local tab1Panel = CreateFrame("Frame", nil, cfgFrame)
tab1Panel:SetWidth(360)
tab1Panel:SetHeight(550)
tab1Panel:SetPoint("TOPLEFT", cfgFrame, "TOPLEFT", 0, -50)
tab1Panel:Show()

local tab2Panel = CreateFrame("Frame", nil, cfgFrame)
tab2Panel:SetWidth(360)
tab2Panel:SetHeight(550)
tab2Panel:SetPoint("TOPLEFT", cfgFrame, "TOPLEFT", 0, -50)
tab2Panel:Hide()

-- Tab buttons
local tab1Btn = CreateFrame("Button", nil, cfgFrame, "UIPanelButtonTemplate")
tab1Btn:SetWidth(130)
tab1Btn:SetHeight(22)
tab1Btn:SetPoint("TOPLEFT", cfgFrame, "TOPLEFT", 8, -30)
tab1Btn:SetText("Rogue Rotation")

local tab2Btn = CreateFrame("Button", nil, cfgFrame, "UIPanelButtonTemplate")
tab2Btn:SetWidth(100)
tab2Btn:SetHeight(22)
tab2Btn:SetPoint("LEFT", tab1Btn, "RIGHT", 4, 0)
tab2Btn:SetText("Interrupt")

local function ShowTab(tabNum)
	if tabNum == 1 then
		tab1Panel:Show()
		tab2Panel:Hide()
		tab1Btn:SetAlpha(1.0)
		tab2Btn:SetAlpha(0.6)
	else
		tab1Panel:Hide()
		tab2Panel:Show()
		tab1Btn:SetAlpha(0.6)
		tab2Btn:SetAlpha(1.0)
	end
end

tab1Btn:SetScript("OnClick", function() ShowTab(1) end)
tab2Btn:SetScript("OnClick", function() ShowTab(2) end)

-- ==========================================
-- TAB 1: Rogue Rotation
-- ==========================================

-- ---- Section: Combo Builder ----
local builderTitle = tab1Panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
builderTitle:SetPoint("TOPLEFT", tab1Panel, "TOPLEFT", 10, -8)
builderTitle:SetText("Combo Builder:")
builderTitle:SetTextColor(0.6, 0.8, 1)

local knownBuilders = {}
local builderBtns   = {}

local function RebuildBuilderButtons()
	for _, btn in ipairs(builderBtns) do btn:Hide() end
	builderBtns = {}
	local bX = 10
	for _, name in ipairs(knownBuilders) do
		local bName = name
		local shortLabel = name
		if name == "Noxious Assault" then shortLabel = "Noxious" end
		if name == "Sinister Strike" then shortLabel = "Sinister" end
		if name == "Hemorrhage"      then shortLabel = "Hemmorh" end
		local btn = CreateFrame("Button", nil, tab1Panel, "UIPanelButtonTemplate")
		btn:SetWidth(82)
		btn:SetHeight(18)
		btn:SetPoint("TOPLEFT", tab1Panel, "TOPLEFT", bX, -24)
		btn:SetText(shortLabel)
		btn.key = bName
		btn:SetScript("OnClick", function()
			RoguePokerDB.comboBuilder = bName
			for _, bb in ipairs(builderBtns) do
				bb:SetAlpha(bb.key == bName and 1.0 or 0.55)
			end
		end)
		table.insert(builderBtns, btn)
		bX = bX + 86
	end
end

local function UpdateBuilderHighlight()
	if not RoguePokerDB then return end
	for _, bb in ipairs(builderBtns) do
		bb:SetAlpha(bb.key == RoguePokerDB.comboBuilder and 1.0 or 0.55)
	end
end

-- ---- Section: Finishers ----
local finisherTitle = tab1Panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
finisherTitle:SetPoint("TOPLEFT", tab1Panel, "TOPLEFT", 10, -50)
finisherTitle:SetText("Finishers (priority order, top = first):")
finisherTitle:SetTextColor(0.6, 0.8, 1)

local finisherRows = {}

local function RefreshFinisherRows()
	for _, row in ipairs(finisherRows) do
		for _, widget in pairs(row) do widget:Hide() end
	end
	finisherRows = {}
	local db = RoguePokerDB
	if not db or not db.finishers then return end
	for idx, fin in ipairs(db.finishers) do
		local y = -66 - (idx - 1) * 26
		local row = {}
		local finIdx = idx
		local isConditional = (fin.kind == "conditional")

		local cb = CreateFrame("CheckButton", nil, tab1Panel, "UICheckButtonTemplate")
		cb:SetWidth(20)
		cb:SetHeight(20)
		cb:SetPoint("TOPLEFT", tab1Panel, "TOPLEFT", 10, y)
		cb:SetChecked(fin.enabled)
		cb:SetScript("OnClick", function()
			RoguePokerDB.finishers[finIdx].enabled = (cb:GetChecked() == 1)
		end)
		row.cb = cb

		local nameLabel = tab1Panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		nameLabel:SetPoint("TOPLEFT", tab1Panel, "TOPLEFT", 34, y - 2)
		nameLabel:SetText(fin.name)
		nameLabel:SetTextColor(0.9, 0.9, 0.9)
		nameLabel:SetWidth(110)
		row.nameLabel = nameLabel

		if isConditional then
			local procLabel = tab1Panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
			procLabel:SetPoint("TOPLEFT", tab1Panel, "TOPLEFT", 150, y - 2)
			procLabel:SetText("(on proc)")
			procLabel:SetTextColor(0.6, 1, 0.6)
			procLabel:SetWidth(60)
			row.procLabel = procLabel
		else
			local minusBtn = CreateFrame("Button", nil, tab1Panel, "UIPanelButtonTemplate")
			minusBtn:SetWidth(18)
			minusBtn:SetHeight(18)
			minusBtn:SetPoint("TOPLEFT", tab1Panel, "TOPLEFT", 150, y)
			minusBtn:SetText("-")
			row.minusBtn = minusBtn

			local cpLabel = tab1Panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
			cpLabel:SetPoint("TOPLEFT", tab1Panel, "TOPLEFT", 172, y - 2)
			cpLabel:SetText(fin.minCP .. "CP")
			cpLabel:SetTextColor(1, 0.8, 0.2)
			cpLabel:SetWidth(28)
			row.cpLabel = cpLabel

			local plusBtn = CreateFrame("Button", nil, tab1Panel, "UIPanelButtonTemplate")
			plusBtn:SetWidth(18)
			plusBtn:SetHeight(18)
			plusBtn:SetPoint("TOPLEFT", tab1Panel, "TOPLEFT", 202, y)
			plusBtn:SetText("+")
			row.plusBtn = plusBtn

			local function updateCP(delta)
				local newCP = RoguePokerDB.finishers[finIdx].minCP + delta
				if newCP < 1 then newCP = 1 end
				if newCP > 5 then newCP = 5 end
				RoguePokerDB.finishers[finIdx].minCP = newCP
				cpLabel:SetText(newCP .. "CP")
			end
			minusBtn:SetScript("OnClick", function() updateCP(-1) end)
			plusBtn:SetScript("OnClick",  function() updateCP(1)  end)
		end

		local upBtn = CreateFrame("Button", nil, tab1Panel, "UIPanelButtonTemplate")
		upBtn:SetWidth(22)
		upBtn:SetHeight(18)
		upBtn:SetPoint("TOPLEFT", tab1Panel, "TOPLEFT", 232, y)
		upBtn:SetText("^")
		upBtn:SetScript("OnClick", function()
			if finIdx > 1 then
				local t = RoguePokerDB.finishers
				t[finIdx], t[finIdx - 1] = t[finIdx - 1], t[finIdx]
				RefreshFinisherRows()
			end
		end)
		row.upBtn = upBtn

		local downBtn = CreateFrame("Button", nil, tab1Panel, "UIPanelButtonTemplate")
		downBtn:SetWidth(22)
		downBtn:SetHeight(18)
		downBtn:SetPoint("TOPLEFT", tab1Panel, "TOPLEFT", 256, y)
		downBtn:SetText("v")
		downBtn:SetScript("OnClick", function()
			local t = RoguePokerDB.finishers
			if finIdx < table.getn(t) then
				t[finIdx], t[finIdx + 1] = t[finIdx + 1], t[finIdx]
				RefreshFinisherRows()
			end
		end)
		row.downBtn = downBtn

		table.insert(finisherRows, row)
	end
end

-- ---- Section: Evasion ----
local evasionTitle = tab1Panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
evasionTitle:SetPoint("TOPLEFT", tab1Panel, "TOPLEFT", 10, -290)
evasionTitle:SetText("Evasion (priority order, top = first):")
evasionTitle:SetTextColor(1, 0.5, 0.3)

local evasionRows = {}

local function RefreshEvasionRows()
	for _, row in ipairs(evasionRows) do
		for _, widget in pairs(row) do widget:Hide() end
	end
	evasionRows = {}
	local db = RoguePokerDB
	if not db or not db.evasion then return end
	for idx, ev in ipairs(db.evasion) do
		local y = -306 - (idx - 1) * 26
		local row = {}
		local evIdx = idx

		local cb = CreateFrame("CheckButton", nil, tab1Panel, "UICheckButtonTemplate")
		cb:SetWidth(20)
		cb:SetHeight(20)
		cb:SetPoint("TOPLEFT", tab1Panel, "TOPLEFT", 10, y)
		cb:SetChecked(ev.enabled)
		cb:SetScript("OnClick", function()
			RoguePokerDB.evasion[evIdx].enabled = (cb:GetChecked() == 1)
		end)
		row.cb = cb

		local nameLabel = tab1Panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		nameLabel:SetPoint("TOPLEFT", tab1Panel, "TOPLEFT", 34, y - 2)
		nameLabel:SetText(ev.name)
		nameLabel:SetTextColor(0.9, 0.9, 0.9)
		nameLabel:SetWidth(110)
		row.nameLabel = nameLabel

		-- Up/Down buttons (always present, same position for all rows)
		local upBtn = CreateFrame("Button", nil, tab1Panel, "UIPanelButtonTemplate")
		upBtn:SetWidth(22)
		upBtn:SetHeight(18)
		upBtn:SetPoint("TOPLEFT", tab1Panel, "TOPLEFT", 148, y)
		upBtn:SetText("^")
		upBtn:SetScript("OnClick", function()
			if evIdx > 1 then
				local t = RoguePokerDB.evasion
				t[evIdx], t[evIdx - 1] = t[evIdx - 1], t[evIdx]
				RefreshEvasionRows()
			end
		end)
		row.upBtn = upBtn

		local downBtn = CreateFrame("Button", nil, tab1Panel, "UIPanelButtonTemplate")
		downBtn:SetWidth(22)
		downBtn:SetHeight(18)
		downBtn:SetPoint("TOPLEFT", tab1Panel, "TOPLEFT", 172, y)
		downBtn:SetText("v")
		downBtn:SetScript("OnClick", function()
			local t = RoguePokerDB.evasion
			if evIdx < table.getn(t) then
				t[evIdx], t[evIdx + 1] = t[evIdx + 1], t[evIdx]
				RefreshEvasionRows()
			end
		end)
		row.downBtn = downBtn

		-- Health threshold controls for Evasion and Vanish (after reorder buttons)
		if ev.name == "Evasion" or ev.name == "Vanish" then
			local minusBtn = CreateFrame("Button", nil, tab1Panel, "UIPanelButtonTemplate")
			minusBtn:SetWidth(18)
			minusBtn:SetHeight(18)
			minusBtn:SetPoint("TOPLEFT", tab1Panel, "TOPLEFT", 200, y)
			minusBtn:SetText("-")
			row.minusBtn = minusBtn

			local hpLabel = tab1Panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
			hpLabel:SetPoint("TOPLEFT", tab1Panel, "TOPLEFT", 221, y - 2)
			hpLabel:SetText((ev.healthPct or 50) .. "%")
			hpLabel:SetTextColor(1, 0.4, 0.4)
			hpLabel:SetWidth(32)
			row.hpLabel = hpLabel

			local plusBtn = CreateFrame("Button", nil, tab1Panel, "UIPanelButtonTemplate")
			plusBtn:SetWidth(18)
			plusBtn:SetHeight(18)
			plusBtn:SetPoint("TOPLEFT", tab1Panel, "TOPLEFT", 255, y)
			plusBtn:SetText("+")
			row.plusBtn = plusBtn

			local function updateHP(delta)
				local cur = RoguePokerDB.evasion[evIdx].healthPct or 50
				local newHP = cur + delta
				if newHP < 5   then newHP = 5   end
				if newHP > 100 then newHP = 100 end
				RoguePokerDB.evasion[evIdx].healthPct = newHP
				hpLabel:SetText(newHP .. "%")
			end
			minusBtn:SetScript("OnClick", function() updateHP(-5) end)
			plusBtn:SetScript("OnClick",  function() updateHP(5)  end)
		end

		table.insert(evasionRows, row)
	end
end

-- ---- Section: Options (Tab 1) ----
local optionsY = -470

local optTitle = tab1Panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
optTitle:SetPoint("TOPLEFT", tab1Panel, "TOPLEFT", 10, optionsY)
optTitle:SetText("Options:")
optTitle:SetTextColor(0.6, 0.8, 1)

local alwaysFeintCB, _ = MakeCheckbox(tab1Panel, "Always Feint (reduces threat)", 10, optionsY - 18,
	function() return RoguePokerDB and RoguePokerDB.alwaysFeint end,
	function(v) if RoguePokerDB then RoguePokerDB.alwaysFeint = v end end)

local insigniaCB, _ = MakeCheckbox(tab1Panel, "Use Insignia when stunned", 10, optionsY - 40,
	function() return RoguePokerDB and RoguePokerDB.useInsignia end,
	function(v) if RoguePokerDB then RoguePokerDB.useInsignia = v end end)

-- ==========================================
-- TAB 2: Interrupt
-- ==========================================

local intTitle = tab2Panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
intTitle:SetPoint("TOPLEFT", tab2Panel, "TOPLEFT", 10, -8)
intTitle:SetText("Interrupt Abilities (priority order, top = first):")
intTitle:SetTextColor(0.6, 0.8, 1)

local intNote = tab2Panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
intNote:SetPoint("TOPLEFT", tab2Panel, "TOPLEFT", 10, -24)
intNote:SetText("Falls through to next if ability is on cooldown or out of range.")
intNote:SetTextColor(0.6, 0.6, 0.6)

local interruptRows = {}

local function RefreshInterruptRows()
	for _, row in ipairs(interruptRows) do
		for _, widget in pairs(row) do widget:Hide() end
	end
	interruptRows = {}
	local db = RoguePokerDB
	if not db or not db.interrupt then return end
	for idx, ab in ipairs(db.interrupt) do
		local y = -44 - (idx - 1) * 26
		local row = {}
		local abIdx = idx
		local isRanged = (ab.name == "Deadly Throw" or ab.name == "Throw/Shoot")

		local cb = CreateFrame("CheckButton", nil, tab2Panel, "UICheckButtonTemplate")
		cb:SetWidth(20)
		cb:SetHeight(20)
		cb:SetPoint("TOPLEFT", tab2Panel, "TOPLEFT", 10, y)
		cb:SetChecked(ab.enabled)
		cb:SetScript("OnClick", function()
			RoguePokerDB.interrupt[abIdx].enabled = (cb:GetChecked() == 1)
		end)
		row.cb = cb

		local nameLabel = tab2Panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		nameLabel:SetPoint("TOPLEFT", tab2Panel, "TOPLEFT", 34, y - 2)
		nameLabel:SetText(ab.name)
		nameLabel:SetTextColor(0.9, 0.9, 0.9)
		nameLabel:SetWidth(130)
		row.nameLabel = nameLabel

		if isRanged then
			local rangeLabel = tab2Panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
			rangeLabel:SetPoint("TOPLEFT", tab2Panel, "TOPLEFT", 170, y - 2)
			rangeLabel:SetText("(range check)")
			rangeLabel:SetTextColor(0.6, 0.8, 1)
			row.rangeLabel = rangeLabel
		end

		if ab.name == "Kidney Shot" then
			local minusBtn = CreateFrame("Button", nil, tab2Panel, "UIPanelButtonTemplate")
			minusBtn:SetWidth(18)
			minusBtn:SetHeight(18)
			minusBtn:SetPoint("TOPLEFT", tab2Panel, "TOPLEFT", 170, y)
			minusBtn:SetText("-")
			row.minusBtn = minusBtn

			local cpLabel = tab2Panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
			cpLabel:SetPoint("TOPLEFT", tab2Panel, "TOPLEFT", 192, y - 2)
			cpLabel:SetText((ab.minCP or 1) .. "CP")
			cpLabel:SetTextColor(1, 0.8, 0.2)
			cpLabel:SetWidth(28)
			row.cpLabel = cpLabel

			local plusBtn = CreateFrame("Button", nil, tab2Panel, "UIPanelButtonTemplate")
			plusBtn:SetWidth(18)
			plusBtn:SetHeight(18)
			plusBtn:SetPoint("TOPLEFT", tab2Panel, "TOPLEFT", 222, y)
			plusBtn:SetText("+")
			row.plusBtn = plusBtn

			local function updateCP(delta)
				local newCP = (RoguePokerDB.interrupt[abIdx].minCP or 1) + delta
				if newCP < 1 then newCP = 1 end
				if newCP > 5 then newCP = 5 end
				RoguePokerDB.interrupt[abIdx].minCP = newCP
				cpLabel:SetText(newCP .. "CP")
			end
			minusBtn:SetScript("OnClick", function() updateCP(-1) end)
			plusBtn:SetScript("OnClick",  function() updateCP(1)  end)
		end

		local upBtn = CreateFrame("Button", nil, tab2Panel, "UIPanelButtonTemplate")
		upBtn:SetWidth(22)
		upBtn:SetHeight(18)
		upBtn:SetPoint("TOPLEFT", tab2Panel, "TOPLEFT", 270, y)
		upBtn:SetText("^")
		upBtn:SetScript("OnClick", function()
			if abIdx > 1 then
				local t = RoguePokerDB.interrupt
				t[abIdx], t[abIdx - 1] = t[abIdx - 1], t[abIdx]
				RefreshInterruptRows()
			end
		end)
		row.upBtn = upBtn

		local downBtn = CreateFrame("Button", nil, tab2Panel, "UIPanelButtonTemplate")
		downBtn:SetWidth(22)
		downBtn:SetHeight(18)
		downBtn:SetPoint("TOPLEFT", tab2Panel, "TOPLEFT", 294, y)
		downBtn:SetText("v")
		downBtn:SetScript("OnClick", function()
			local t = RoguePokerDB.interrupt
			if abIdx < table.getn(t) then
				t[abIdx], t[abIdx + 1] = t[abIdx + 1], t[abIdx]
				RefreshInterruptRows()
			end
		end)
		row.downBtn = downBtn

		table.insert(interruptRows, row)
	end
end

-- ==========================================
-- Scan & Rebuild (after all local UI functions are defined)
-- ==========================================
function RoguePoker:ScanAndRebuild()
	local db = RoguePokerDB
	if not db then return end

	-- Reset all three lists to defaults, then filter to known spells
	db.finishers = deepCopy(defaults.finishers)
	db.evasion   = deepCopy(defaults.evasion)
	db.interrupt = deepCopy(defaults.interrupt)

	-- Filter builders
	knownBuilders = RoguePoker:FilterKnown(RoguePoker.BUILDERS)

	-- Filter finishers
	local knownFinishers = {}
	for _, fin in ipairs(db.finishers) do
		if RoguePoker:HasSpell(fin.name) then
			knownFinishers[table.getn(knownFinishers) + 1] = fin
		end
	end
	db.finishers = knownFinishers

	-- Filter evasion
	local knownEvasion = {}
	for _, ev in ipairs(db.evasion) do
		if RoguePoker:HasSpell(ev.name) then
			knownEvasion[table.getn(knownEvasion) + 1] = ev
		end
	end
	db.evasion = knownEvasion

	-- Filter interrupt
	local knownInterrupt = {}
	for _, ab in ipairs(db.interrupt) do
		local abKnown = RoguePoker:HasSpell(ab.name)
		if ab.name == "Throw/Shoot" then
			abKnown = RoguePoker:HasSpell("Throw") or RoguePoker:HasSpell("Shoot Bow") or RoguePoker:HasSpell("Shoot Crossbow") or RoguePoker:HasSpell("Shoot Gun") or RoguePoker:HasSpell("Shoot")
		end
		if abKnown then
			knownInterrupt[table.getn(knownInterrupt) + 1] = ab
		end
	end
	db.interrupt = knownInterrupt

	-- Rebuild UI
	RebuildBuilderButtons()
	UpdateBuilderHighlight()
	RefreshFinisherRows()
	RefreshEvasionRows()
	RefreshInterruptRows()

	-- Restore option checkboxes
	alwaysFeintCB:SetChecked(db.alwaysFeint)
	insigniaCB:SetChecked(db.useInsignia)
end

-- ==========================================
-- Version label
-- ==========================================
local versionLabel = cfgFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
versionLabel:SetPoint("BOTTOMRIGHT", cfgFrame, "BOTTOMRIGHT", -8, 8)
versionLabel:SetText("v1.1.3")
versionLabel:SetTextColor(0.5, 0.5, 0.5)

-- ==========================================
-- Save Button (shared)
-- ==========================================
local saveBtn = CreateFrame("Button", nil, cfgFrame, "UIPanelButtonTemplate")
saveBtn:SetWidth(90)
saveBtn:SetHeight(24)
saveBtn:SetPoint("BOTTOMRIGHT", cfgFrame, "BOTTOM", -4, 12)
saveBtn:SetText("Save & Close")
saveBtn:SetScript("OnClick", function()
	cfgFrame:Hide()
	print("RoguePoker: Settings saved.")
end)

local refreshBtn = CreateFrame("Button", nil, cfgFrame, "UIPanelButtonTemplate")
refreshBtn:SetWidth(110)
refreshBtn:SetHeight(24)
refreshBtn:SetPoint("BOTTOMLEFT", cfgFrame, "BOTTOM", 4, 12)
refreshBtn:SetText("Refresh Talents")
refreshBtn:SetScript("OnClick", function()
	RoguePoker:ScanAndRebuild()
	print("|cFFFFD700RoguePoker|r: Talents refreshed.")
end)

-- ==========================================
-- Update Loop
-- ==========================================
local updateFrame = CreateFrame("Frame")
local elapsed = 0
updateFrame:SetScript("OnUpdate", function()
	elapsed = elapsed + arg1
	if elapsed < 0.3 then return end
	elapsed = 0
	if not RoguePokerDB or not cfgFrame:IsShown() then return end
	UpdateBuilderHighlight()
end)

-- ==========================================
-- Load Event
-- ==========================================
-- VARIABLES_LOADED: init DB only (spellbook not ready yet)
local loadFrame = CreateFrame("Frame")
loadFrame:RegisterEvent("VARIABLES_LOADED")
loadFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
loadFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
loadFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
loadFrame:RegisterEvent("CHAT_MSG_COMBAT_SELF_MISSES")
loadFrame:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")
loadFrame:SetScript("OnEvent", function()
	if event == "PLAYER_REGEN_DISABLED" then
		RoguePoker.isAttacking = true
		RoguePoker.surpriseAttackReady = false
		RoguePoker.surpriseAttackTime = nil
		RoguePoker.riposteReady = false
		RoguePoker.shadowOfDeathPending = false
		RoguePoker.shadowOfDeathPendingTime = nil
	elseif event == "PLAYER_REGEN_ENABLED" then
		RoguePoker.isAttacking = false
		RoguePoker.surpriseAttackReady = false
		RoguePoker.surpriseAttackTime = nil
		RoguePoker.riposteReady = false
		RoguePoker.shadowOfDeathPending = false
		RoguePoker.shadowOfDeathPendingTime = nil
		RoguePoker.debuffExpiry = {}
	elseif event == "CHAT_MSG_COMBAT_SELF_MISSES" then
		if arg1 and string.find(arg1, "dodge") then
			RoguePoker.surpriseAttackReady = true
			RoguePoker.surpriseAttackTime = GetTime()
		end
		if arg1 and string.find(arg1, "parr") then
			RoguePoker.riposteReady = true
		end
	elseif event == "CHAT_MSG_SPELL_SELF_DAMAGE" then
		if arg1 and string.find(arg1, "dodge") then
			RoguePoker.surpriseAttackReady = true
			RoguePoker.surpriseAttackTime = GetTime()
		end
		if arg1 and string.find(arg1, "parr") then
			RoguePoker.riposteReady = true
		end
	elseif event == "VARIABLES_LOADED" then
		InitDB()

	elseif event == "PLAYER_ENTERING_WORLD" then
		if not RoguePokerDB then return end
		knownBuilders = RoguePoker:FilterKnown(RoguePoker.BUILDERS)
		-- If saved builder is no longer known (respec), reset to first known builder
		if table.getn(knownBuilders) > 0 then
			local builderKnown = false
			for _, b in ipairs(knownBuilders) do
				if b == RoguePokerDB.comboBuilder then builderKnown = true break end
			end
			if not builderKnown then
				RoguePokerDB.comboBuilder = knownBuilders[1]
			end
		end
		RebuildBuilderButtons()
		UpdateBuilderHighlight()
		RefreshFinisherRows()
		RefreshEvasionRows()
		RefreshInterruptRows()
		alwaysFeintCB:SetChecked(RoguePokerDB.alwaysFeint)
		insigniaCB:SetChecked(RoguePokerDB.useInsignia)
		print("|cFFFFD700RoguePoker|r loaded. Type |cFFFFD700/rp|r to configure.")
	end
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

SLASH_RPCHECK1 = "/rpcheck"
SlashCmdList["RPCHECK"] = function(msg)
	print("RP CHECK: target debuffs:")
	for i = 1, 40 do
		local texture = UnitDebuff("target", i)
		if not texture then break end
		print("RP CHECK: slot "..tostring(i).." texture="..tostring(texture))
	end
end
