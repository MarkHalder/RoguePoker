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
RoguePoker.shadowOfDeathPending = false
RoguePoker.inCombat = false
RoguePoker.defensivePending = nil
RoguePoker.defensivePendingTime = nil
RoguePoker.notBehindTarget = false     -- true when we got a "must be behind" error
RoguePoker.notBehindTime = nil

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
-- Nampower Queue Wrapper
-- ==========================================
-- Uses QueueSpellByName if nampower is loaded, otherwise falls back to
-- CastSpellByName. Since nampower only allows 1 GCD spell in the queue
-- at a time, calling this will automatically replace any previously
-- queued spell with the new one -- no manual queue management needed.
function RoguePoker:QueueOrCast(spellName)
	if QueueSpellByName then
		QueueSpellByName(spellName)
	else
		CastSpellByName(spellName)
	end
end

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
	comboBuilder    = "Sinister Strike",
	useInsignia     = true,
	useInsigniaStuns    = true,
	useInsigniaMovement = true,
	useSprintMovement   = true,
	alwaysFeint     = false,
	tankMode        = false,
	pvpMode         = false,
	autoAssist      = false,
	autoAssistName  = "",
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
	if RoguePokerDB.useInsignia        == nil then RoguePokerDB.useInsignia        = defaults.useInsignia        end
	if RoguePokerDB.useInsigniaStuns   == nil then RoguePokerDB.useInsigniaStuns   = defaults.useInsigniaStuns   end
	if RoguePokerDB.useInsigniaMovement == nil then RoguePokerDB.useInsigniaMovement = defaults.useInsigniaMovement end
	if RoguePokerDB.useSprintMovement  == nil then RoguePokerDB.useSprintMovement  = defaults.useSprintMovement  end
	if RoguePokerDB.alwaysFeint   == nil then RoguePokerDB.alwaysFeint   = defaults.alwaysFeint   end
	if RoguePokerDB.tankMode      == nil then RoguePokerDB.tankMode      = defaults.tankMode      end
	if RoguePokerDB.pvpMode       == nil then RoguePokerDB.pvpMode       = defaults.pvpMode       end
	if RoguePokerDB.autoAssist    == nil then RoguePokerDB.autoAssist    = defaults.autoAssist    end
	if RoguePokerDB.autoAssistName == nil then RoguePokerDB.autoAssistName = defaults.autoAssistName end
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
	-- Only enable auto-attack if it isn't already running
	if UnitExists("target") and not UnitIsDead("target") and UnitCanAttack("player", "target") then
		local isAutoAttacking = false
		if GetCurrentCastingInfo then
			local castId, visId, autoId, casting, channeling, onswing, autoattack = GetCurrentCastingInfo()
			isAutoAttacking = (autoattack ~= nil and autoattack == 1)
		else
			isAutoAttacking = IsCurrentAction(72)
		end
		if not isAutoAttacking then
			AttackTarget()
		end
	end
end

function RoguePoker:AtRange()
	if IsSpellInRange then
		local wtype = RoguePoker:GetRangedWeaponType()
		local spellName = nil
		if     wtype == "Thrown"   then spellName = "Throw"
		elseif wtype == "Bow"      then spellName = "Shoot Bow"
		elseif wtype == "Crossbow" then spellName = "Shoot Crossbow"
		elseif wtype == "Gun"      then spellName = "Shoot Gun"
		elseif wtype == "Wand"     then spellName = "Shoot"
		end
		if spellName then
			return IsSpellInRange(spellName, "target") == 1
		end
		return false
	end
	-- Fallback for non-nampower: must be within ranged range but NOT in melee range
	if UnitInRange then
		local inRange = UnitInRange("target") == 1
		if not inRange then return false end
	end
	if CheckInteractDistance then
		local tooClose = CheckInteractDistance("target", 3)
		if tooClose then return false end
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

function RoguePoker:AssistNamedPlayer()
	local db = RoguePokerDB
	local name = db and db.autoAssistName
	if not name or name == "" then
		print("|cFFFFD700RoguePoker|r: No assist target set. Use /rp to configure.")
		return
	end
	TargetByName(name)
	if UnitExists("target") then
		AssistUnit("target")
	else
		print("|cFFFFD700RoguePoker|r: Could not find player: " .. name)
	end
end

function RoguePoker:AutoAssistTarget()
	local db = RoguePokerDB
	if not db.autoAssist then return end
	local name = db.autoAssistName
	if not name or name == "" then return end
	-- Only act when we have no target at all
	if UnitExists("target") then return end
	-- AssistUnit only accepts unit tokens, so we target by name first,
	-- then assist that target.
	TargetByName(name)
	if UnitExists("target") then
		AssistUnit("target")
	end
end

-- ==========================================
-- Bad Status / Insignia
-- ==========================================

-- Stuns, incapacitates, and mind control effects (hard CC - cannot act)
RoguePoker.stunTextures = {
    ["Interface\\Icons\\Ability_Ensnare"]              = true, -- Net/Ensnare stun
    ["Interface\\Icons\\Spell_Magic_PolymorphPig"]     = true, -- Polymorph (pig)
    ["Interface\\Icons\\Ability_Sap"]                  = true, -- Sap
    ["Interface\\Icons\\Ability_Warrior_Charge"]       = true, -- Charge stun
    ["Interface\\Icons\\Ability_ShockWave"]            = true, -- Shockwave stun
    ["Interface\\Icons\\Spell_Shadow_DeathScream"]     = true, -- Death Scream fear
    ["Interface\\Icons\\Ability_CheapShot"]            = true, -- Cheap Shot stun
    ["Interface\\Icons\\Ability_WarStomp"]             = true, -- War Stomp stun
    ["Interface\\Icons\\Spell_Nature_Drowsy"]          = true, -- Drowsy (sleep)
    ["Interface\\Icons\\Spell_Nature_Polymorph"]       = true, -- Polymorph (sheep)
    ["Interface\\Icons\\Ability_Gouge"]                = true, -- Gouge incapacitate
    ["Interface\\Icons\\Ability_Rogue_KidneyShot"]     = true, -- Kidney Shot stun
    ["Interface\\Icons\\INV_Mace_02"]                  = true, -- Blackjack stun
    ["Interface\\Icons\\Spell_Shadow_Charm"]           = true, -- Charm/MC
    ["Interface\\Icons\\Spell_Nature_Sleep"]           = true, -- Sleep
    ["Interface\\Icons\\Ability_ThunderBolt"]          = true, -- Thunderbolt stun
    ["Interface\\Icons\\Spell_Frost_Stun"]             = true, -- Frost stun
    ["Interface\\Icons\\Ability_GolemThunderClap"]     = true, -- Golem Thunderclap stun
    ["Interface\\Icons\\Spell_Shadow_Possession"]      = true, -- Possession (mind control)
    ["Interface\\Icons\\Spell_Shadow_PsychicScream"]   = true, -- Psychic Scream fear
    ["Interface\\Icons\\Spell_Frost_Glacier"]          = true, -- Glacier stun
    ["Interface\\Icons\\Spell_Holy_RighteousnessAura"] = true, -- Hammer of Justice (paladin stun)
    ["Interface\\Icons\\Spell_Shadow_ShadowWordDominate"] = true, -- Shadow Word: Dominate (mind control)
}

-- Severe movement impairing effects (roots and heavy slows)
RoguePoker.movementTextures = {
    ["Interface\\Icons\\Spell_Nature_Slow"]            = true, -- Slow
    ["Interface\\Icons\\Spell_Nature_StrangleVines"]   = true, -- Entangling Roots
    ["Interface\\Icons\\Spell_Nature_Web"]             = true, -- Web root
    ["Interface\\Icons\\Spell_Nature_EarthBind"]       = true, -- Earthbind root
    ["Interface\\Icons\\Ability_Rogue_Trip"]           = true, -- Trip root
    ["Interface\\Icons\\Spell_Shadow_Cripple"]         = true, -- Cripple slow
    ["Interface\\Icons\\Spell_Nature_Earthquake"]      = true, -- Earthquake root
    ["Interface\\Icons\\Ability_BullRush"]             = true, -- Bull Rush root
    ["Interface\\Icons\\Spell_Frost_ChainsOfIce"]      = true, -- Chains of Ice root
    ["Interface\\Icons\\Spell_Frost_FrostNova"]        = true, -- Frost Nova root
    ["Interface\\Icons\\Spell_Frost_ChillingBlast"]    = true, -- Chilling Blast slow/root
    ["Interface\\Icons\\Ability_Hunter_Quickshot"]     = true, -- Concussive Shot / Wing Clip slow
}

function RoguePoker:IsBadStatusForInsignia()
	local db = RoguePokerDB
	local i = 1
	while true do
		local texture = UnitDebuff("player", i)
		if not texture then break end
		if db.useInsigniaStuns    and RoguePoker.stunTextures[texture]     then return true end
		if db.useInsigniaMovement and RoguePoker.movementTextures[texture] then return true end
		i = i + 1
	end
	return false
end

function RoguePoker:IsBadStatusForSprint()
	local db = RoguePokerDB
	local i = 1
	while true do
		local texture = UnitDebuff("player", i)
		if not texture then break end
		if RoguePoker.movementTextures[texture] then return true end
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

	-- If current target is dead, clear it and find a new one
	if UnitExists("target") and UnitIsDead("target") then
		ClearTarget()
		if db.autoAssist and db.autoAssistName and db.autoAssistName ~= "" then
			-- Auto assist: target the assist player then assist their target
			TargetByName(db.autoAssistName)
			if UnitExists("target") then
				AssistUnit("target")
			end
		else
			-- Fall back to nearest enemy
			TargetNearestEnemy()
		end
	end

	local mobTargetsMe = (not UnitIsPlayer("target")) and RoguePoker:IsMyTargetTargetingMe()
	local inMeleeCombat = mobTargetsMe or db.tankMode

	RoguePoker:AutoAttack()
	if not db.pvpMode then
		RoguePoker:AssistPlayer()
	end
	RoguePoker:AutoAssistTarget()

	-- Insignia CC break on bad status
	if db.useInsignia and RoguePoker:IsBadStatusForInsignia() then
		RoguePoker:UseInsignia()
		return
	end

	-- Sprint movement impair break (Improved Sprint rank 2 required)
	if db.useSprintMovement and RoguePoker:IsBadStatusForSprint() then
		local _, _, _, _, improvedSprintRank = GetTalentInfo(2, 7)
		if improvedSprintRank and improvedSprintRank == 2 then
			local sprintSid = RoguePoker:FindSpellid("Sprint")
			if sprintSid > 0 then
				local start, duration = GetSpellCooldown(sprintSid, BOOKTYPE_SPELL)
				local onCooldown = duration and duration > 0 and (start + duration) > GetTime()
				if not onCooldown then
					CastSpellByName("Sprint")
					return
				end
			end
		end
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
					RoguePoker:QueueOrCast("Feint")
					return
				end
			end
		end
	end


	-- ---- Evasion / Tank abilities ----
	if inMeleeCombat then
		-- Clear pending tracker if the buff has appeared or it's been > 2s
		if RoguePoker.defensivePending then
			local elapsed = RoguePoker.defensivePendingTime and (GetTime() - RoguePoker.defensivePendingTime) or 0
			local buffApplied = RoguePoker:IsActive(RoguePoker.defensivePending)
			if buffApplied or elapsed > 2 then
				RoguePoker.defensivePending = nil
				RoguePoker.defensivePendingTime = nil
			else
				-- A defensive ability was just queued, skip this block entirely
				return
			end
		end

		for _, ev in ipairs(db.evasion) do
			if ev.enabled then
				local name = ev.name
				local sid = RoguePoker:FindSpellid(name)
				if sid > 0 then
					local _, dur = GetSpellCooldown(sid, BOOKTYPE_SPELL)

					-- Feint: cast whenever off cooldown
					if name == "Feint" then
						if dur == 0 and not RoguePoker:ShouldWait(name) then
							RoguePoker:QueueOrCast(name)
							return
						end

					-- Vanish: emergency only below configured health threshold
					elseif name == "Vanish" then
						local ph = UnitHealth("player")
						local phMax = UnitHealthMax("player")
						local phPct = (phMax > 0) and (100 * ph / phMax) or 100
						local threshold = ev.healthPct or 20
						if dur == 0 and phPct < threshold then
							RoguePoker:QueueOrCast(name)
							return
						end

					-- Evasion: only below configured health threshold, not if GS/Flourish active or pending
					-- Also only fires if all enabled higher-priority defensives (GS/Flourish) are on cooldown
					elseif name == "Evasion" then
						local ph = UnitHealth("player")
						local phMax = UnitHealthMax("player")
						local phPct = (phMax > 0) and (100 * ph / phMax) or 100
						local threshold = ev.healthPct or 50
						local active, timeLeft = RoguePoker:IsActive(name)
						-- Don't fire if another defensive was recently queued
						local otherPending = RoguePoker.defensivePending and RoguePoker.defensivePending ~= name
						-- Don't override Ghostly Strike or Flourish if still active > 0.5s
						local otherActive = false
						for _, ev2 in ipairs(db.evasion) do
							if ev2.name ~= "Feint" and ev2.name ~= "Vanish" and ev2.name ~= "Evasion" then
								local a, t = RoguePoker:IsActive(ev2.name)
								if a and t > 0.5 then otherActive = true break end
							end
						end
						-- Only fire if all enabled GS/Flourish are on cooldown
						local higherPriorityAvailable = false
						for _, ev2 in ipairs(db.evasion) do
							if ev2.enabled and ev2.name ~= "Feint" and ev2.name ~= "Vanish" and ev2.name ~= "Evasion" then
								local sid2 = RoguePoker:FindSpellid(ev2.name)
								if sid2 > 0 then
									local s2, d2 = GetSpellCooldown(sid2, BOOKTYPE_SPELL)
									local notOnCooldown = not (d2 and d2 > 0 and (s2 + d2) > GetTime())
									if notOnCooldown then
										higherPriorityAvailable = true
										break
									end
								end
							end
						end
						if dur == 0 and phPct <= threshold and not otherActive and not otherPending and not higherPriorityAvailable and (not active or timeLeft <= 0.5) then
							RoguePoker.defensivePending = name
							RoguePoker.defensivePendingTime = GetTime()
							RoguePoker:QueueOrCast(name)
							return
						end

					-- Ghostly Strike / Flourish: only one of GS/Flourish/Evasion active at a time
					-- Allow casting when the current active buff drops to <= 0.5s remaining
					else
						local active, timeLeft = RoguePoker:IsActive(name)
						local otherBuffActive = false
						local otherPending = RoguePoker.defensivePending and RoguePoker.defensivePending ~= name
						for _, ev2 in ipairs(db.evasion) do
							if ev2.name ~= "Feint" and ev2.name ~= "Vanish" and ev2.name ~= name then
								local a, t = RoguePoker:IsActive(ev2.name)
								if a and t > 0.5 then otherBuffActive = true break end
							end
						end
						local needsCP = (name == "Flourish")
						local start, duration = GetSpellCooldown(sid, BOOKTYPE_SPELL)
						local onCooldown = duration and duration > 0 and (start + duration) > GetTime()
						if not onCooldown and not otherBuffActive and not otherPending and (not active or timeLeft <= 0.5) then
							if not needsCP or cP > 0 then
								RoguePoker.defensivePending = name
								RoguePoker.defensivePendingTime = GetTime()
								RoguePoker:QueueOrCast(name)
								return
							end
						end
					end
				end
			end
		end
	end

	-- ---- Mark for Death + Shadow of Death combo ----
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
						RoguePoker:QueueOrCast("Mark for Death")
						return
					elseif not sodEnabled or not sodKnown then
						RoguePoker:QueueOrCast("Mark for Death")
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
					RoguePoker:QueueOrCast("Shadow of Death")
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
					local canFire = false
					if name == "Surprise Attack" or name == "Riposte" then
						-- Use nampower's IsSpellUsable to detect proc availability
						-- Returns 1 only when the proc is active (dodge for SA, parry for Riposte)
						if IsSpellUsable then
							local procReady = IsSpellUsable(name) == 1
							local start, duration = GetSpellCooldown(sid, BOOKTYPE_SPELL)
							local onCooldown = duration and duration > 0 and (start + duration) > GetTime()
							canFire = procReady and not onCooldown
						end
					else
						local start, duration = GetSpellCooldown(sid, BOOKTYPE_SPELL)
						canFire = not (duration and duration > 0 and (start + duration) > GetTime())
					end
					if canFire then
						if not RoguePoker:ShouldWait(name) then
							RoguePoker:QueueOrCast(name)
							return
						end
					end
				end
				end

			-- All other finishers require minimum CP
			elseif cP >= minCP then
				local active, timeLeft
				if name == "Rupture" then
					active, timeLeft = RoguePoker:IsActive("Taste for Blood")
				elseif name == "Expose Armor" then
					active, timeLeft = RoguePoker:IsActiveOnTarget("Expose Armor")
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
						RoguePoker:QueueOrCast(name)
						return
					end

				elseif kind == "dot" then
					local refreshWindow = (name == "Rupture") and 10 or 5
					if (not active or timeLeft < refreshWindow) and not RoguePoker:ShouldWait(name) then
						if name == "Expose Armor" then
							RoguePoker:TrackDebuff("Expose Armor", 30)
						end
						RoguePoker:QueueOrCast(name)
						return
					end

				else -- damage
					if not RoguePoker:ShouldWait(name) then
						RoguePoker:QueueOrCast(name)
						return
					end
				end
			else
			end
		end
	end

	-- ---- Combo Builder ----
	local builder = db.comboBuilder or "Sinister Strike"

	-- Backstab requires being behind the target
	-- Fall back to Sinister Strike if mob is targeting us, or if we recently
	-- got a "must be behind your target" error from a failed Backstab attempt
	if builder == "Backstab" then
		-- Expire the not-behind flag after 3 seconds
		if RoguePoker.notBehindTime and (GetTime() - RoguePoker.notBehindTime) > 3 then
			RoguePoker.notBehindTarget = false
			RoguePoker.notBehindTime = nil
		end
		if mobTargetsMe or RoguePoker.notBehindTarget then
			builder = "Sinister Strike"
		end
	end

	RoguePoker:QueueOrCast(builder)
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
				local wtype = RoguePoker:GetRangedWeaponType()
				if wtype ~= "Thrown" then
					castName = nil
				end

			elseif name == "Throw/Shoot" then
				local wtype = RoguePoker:GetRangedWeaponType()
				if     wtype == "Thrown"   then castName = "Throw"
				elseif wtype == "Bow"      then castName = "Shoot Bow"
				elseif wtype == "Crossbow" then castName = "Shoot Crossbow"
				elseif wtype == "Gun"      then castName = "Shoot Gun"
				elseif wtype == "Wand"     then castName = "Shoot"
				else castName = nil
				end
			end

			-- Kidney Shot requires minimum combo points
			if castName == "Kidney Shot" then
				local cP = GetComboPoints("player")
				if cP < (ab.minCP or 1) then castName = nil end
			end

			if castName then
				if isRanged then
					if RoguePoker:AtRange() then
						local sid = RoguePoker:FindSpellid(castName)
						if sid > 0 then
							local _, dur = GetSpellCooldown(sid, BOOKTYPE_SPELL)
							if dur == 0 then
								if not RoguePoker:ShouldWait(castName) then
									RoguePoker:QueueOrCast(castName)
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
								RoguePoker:QueueOrCast(castName)
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

local tab3Panel = CreateFrame("Frame", nil, cfgFrame)
tab3Panel:SetWidth(360)
tab3Panel:SetHeight(550)
tab3Panel:SetPoint("TOPLEFT", cfgFrame, "TOPLEFT", 0, -50)
tab3Panel:Hide()

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

local tab3Btn = CreateFrame("Button", nil, cfgFrame, "UIPanelButtonTemplate")
tab3Btn:SetWidth(80)
tab3Btn:SetHeight(22)
tab3Btn:SetPoint("LEFT", tab2Btn, "RIGHT", 4, 0)
tab3Btn:SetText("Options")

local function ShowTab(tabNum)
	if tabNum == 1 then
		tab1Panel:Show()
		tab2Panel:Hide()
		tab3Panel:Hide()
		tab1Btn:SetAlpha(1.0)
		tab2Btn:SetAlpha(0.6)
		tab3Btn:SetAlpha(0.6)
	elseif tabNum == 2 then
		tab1Panel:Hide()
		tab2Panel:Show()
		tab3Panel:Hide()
		tab1Btn:SetAlpha(0.6)
		tab2Btn:SetAlpha(1.0)
		tab3Btn:SetAlpha(0.6)
	else
		tab1Panel:Hide()
		tab2Panel:Hide()
		tab3Panel:Show()
		tab1Btn:SetAlpha(0.6)
		tab2Btn:SetAlpha(0.6)
		tab3Btn:SetAlpha(1.0)
	end
end

tab1Btn:SetScript("OnClick", function() ShowTab(1) end)
tab2Btn:SetScript("OnClick", function() ShowTab(2) end)
tab3Btn:SetScript("OnClick", function() ShowTab(3) end)

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

		-- Up/Down buttons
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

		-- Health threshold controls for Evasion and Vanish
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
-- TAB 3: Options
-- ==========================================

local optTitle3 = tab3Panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
optTitle3:SetPoint("TOPLEFT", tab3Panel, "TOPLEFT", 10, -8)
optTitle3:SetText("Options:")
optTitle3:SetTextColor(0.6, 0.8, 1)

local alwaysFeintCB, _ = MakeCheckbox(tab3Panel, "Always Feint (reduces threat)", 10, -28,
	function() return RoguePokerDB and RoguePokerDB.alwaysFeint end,
	function(v) if RoguePokerDB then RoguePokerDB.alwaysFeint = v end end)

local insigniaCB, _ = MakeCheckbox(tab3Panel, "Use Insignia on CC", 10, -50,
	function() return RoguePokerDB and RoguePokerDB.useInsignia end,
	function(v) if RoguePokerDB then RoguePokerDB.useInsignia = v end end)

-- Sub-option: Stuns & Mind Control (indented, greyed when parent disabled)
local insigniaStunsCB = CreateFrame("CheckButton", nil, tab3Panel, "UICheckButtonTemplate")
insigniaStunsCB:SetWidth(20)
insigniaStunsCB:SetHeight(20)
insigniaStunsCB:SetPoint("TOPLEFT", tab3Panel, "TOPLEFT", 30, -68)
local insigniaStunsCBLabel = tab3Panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
insigniaStunsCBLabel:SetPoint("LEFT", insigniaStunsCB, "RIGHT", 2, 0)
insigniaStunsCBLabel:SetText("Stuns & Mind Control")
insigniaStunsCB:SetScript("OnClick", function()
	if RoguePokerDB and RoguePokerDB.useInsignia then
		RoguePokerDB.useInsigniaStuns = (insigniaStunsCB:GetChecked() == 1)
	else
		insigniaStunsCB:SetChecked(RoguePokerDB and RoguePokerDB.useInsigniaStuns)
	end
end)

-- Sub-option: Movement Impairing Effects (indented, greyed when parent disabled)
local insigniaMovementCB = CreateFrame("CheckButton", nil, tab3Panel, "UICheckButtonTemplate")
insigniaMovementCB:SetWidth(20)
insigniaMovementCB:SetHeight(20)
insigniaMovementCB:SetPoint("TOPLEFT", tab3Panel, "TOPLEFT", 30, -86)
local insigniaMovementCBLabel = tab3Panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
insigniaMovementCBLabel:SetPoint("LEFT", insigniaMovementCB, "RIGHT", 2, 0)
insigniaMovementCBLabel:SetText("Movement Impairing Effects")
insigniaMovementCB:SetScript("OnClick", function()
	if RoguePokerDB and RoguePokerDB.useInsignia then
		RoguePokerDB.useInsigniaMovement = (insigniaMovementCB:GetChecked() == 1)
	else
		insigniaMovementCB:SetChecked(RoguePokerDB and RoguePokerDB.useInsigniaMovement)
	end
end)

-- Helper to update sub-option visual state based on parent
local function UpdateInsigniaSubOptions()
	local enabled = RoguePokerDB and RoguePokerDB.useInsignia
	local alpha = enabled and 1.0 or 0.4
	insigniaStunsCB:SetAlpha(alpha)
	insigniaStunsCBLabel:SetAlpha(alpha)
	insigniaMovementCB:SetAlpha(alpha)
	insigniaMovementCBLabel:SetAlpha(alpha)
end

-- Override insigniaCB click to also update sub-option states
insigniaCB:SetScript("OnClick", function()
	if RoguePokerDB then
		RoguePokerDB.useInsignia = (insigniaCB:GetChecked() == 1)
		UpdateInsigniaSubOptions()
	end
end)

local sprintMovementCB, _ = MakeCheckbox(tab3Panel, "Use Sprint on Movement Impairing Effects", 10, -108,
	function() return RoguePokerDB and RoguePokerDB.useSprintMovement end,
	function(v) if RoguePokerDB then RoguePokerDB.useSprintMovement = v end end)

local pvpModeCB, _ = MakeCheckbox(tab3Panel, "PvP Mode (disables Assist)", 10, -130,
	function() return RoguePokerDB and RoguePokerDB.pvpMode end,
	function(v) if RoguePokerDB then RoguePokerDB.pvpMode = v end end)

local tankModeCB, _ = MakeCheckbox(tab3Panel, "Tank Mode", 10, -152,
	function() return RoguePokerDB and RoguePokerDB.tankMode end,
	function(v) if RoguePokerDB then RoguePokerDB.tankMode = v end end)

-- ---- Auto Assist ----
local assistSep = tab3Panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
assistSep:SetPoint("TOPLEFT", tab3Panel, "TOPLEFT", 10, -178)
assistSep:SetText("------------------------------")
assistSep:SetTextColor(0.4, 0.4, 0.4)

local autoAssistCB, _ = MakeCheckbox(tab3Panel, "Auto Assist", 10, -194,
	function() return RoguePokerDB and RoguePokerDB.autoAssist end,
	function(v) if RoguePokerDB then RoguePokerDB.autoAssist = v end end)

local assistNote = tab3Panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
assistNote:SetPoint("TOPLEFT", tab3Panel, "TOPLEFT", 10, -216)
assistNote:SetText("When enabled and you have no target, assist this player:")
assistNote:SetTextColor(0.7, 0.7, 0.7)

local assistEditBox = CreateFrame("EditBox", "RoguePokerAssistEditBox", tab3Panel, "InputBoxTemplate")
assistEditBox:SetWidth(200)
assistEditBox:SetHeight(20)
assistEditBox:SetPoint("TOPLEFT", tab3Panel, "TOPLEFT", 14, -234)
assistEditBox:SetAutoFocus(false)
assistEditBox:SetMaxLetters(64)
assistEditBox:SetText("")
assistEditBox:SetScript("OnEnterPressed", function()
	assistEditBox:ClearFocus()
	if RoguePokerDB then
		RoguePokerDB.autoAssistName = assistEditBox:GetText()
	end
end)
assistEditBox:SetScript("OnEscapePressed", function()
	assistEditBox:ClearFocus()
	-- Restore saved value on escape
	if RoguePokerDB then
		assistEditBox:SetText(RoguePokerDB.autoAssistName or "")
	end
end)
assistEditBox:SetScript("OnEditFocusLost", function()
	if RoguePokerDB then
		RoguePokerDB.autoAssistName = assistEditBox:GetText()
	end
end)

local assistSetBtn = CreateFrame("Button", nil, tab3Panel, "UIPanelButtonTemplate")
assistSetBtn:SetWidth(40)
assistSetBtn:SetHeight(20)
assistSetBtn:SetPoint("LEFT", assistEditBox, "RIGHT", 4, 0)
assistSetBtn:SetText("Set")
assistSetBtn:SetScript("OnClick", function()
	if UnitExists("target") and UnitIsPlayer("target") then
		local name = UnitName("target")
		assistEditBox:SetText(name)
		if RoguePokerDB then
			RoguePokerDB.autoAssistName = name
		end
	else
		print("|cFFFFD700RoguePoker|r: No player target to set.")
	end
end)

local assistClearBtn = CreateFrame("Button", nil, tab3Panel, "UIPanelButtonTemplate")
assistClearBtn:SetWidth(46)
assistClearBtn:SetHeight(20)
assistClearBtn:SetPoint("LEFT", assistSetBtn, "RIGHT", 4, 0)
assistClearBtn:SetText("Clear")
assistClearBtn:SetScript("OnClick", function()
	assistEditBox:SetText("")
	if RoguePokerDB then
		RoguePokerDB.autoAssistName = ""
	end
end)

-- ---- Auto Attack Setup ----
local attackSep = tab3Panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
attackSep:SetPoint("TOPLEFT", tab3Panel, "TOPLEFT", 10, -276)
attackSep:SetText("------------------------------")
attackSep:SetTextColor(0.4, 0.4, 0.4)

local attackNote = tab3Panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
attackNote:SetPoint("TOPLEFT", tab3Panel, "TOPLEFT", 10, -290)
attackNote:SetText("Required for auto-attack detection (places Attack into slot 72):")
attackNote:SetTextColor(0.7, 0.7, 0.7)

local setupAttackBtn = CreateFrame("Button", nil, tab3Panel, "UIPanelButtonTemplate")
setupAttackBtn:SetWidth(130)
setupAttackBtn:SetHeight(22)
setupAttackBtn:SetPoint("TOPLEFT", tab3Panel, "TOPLEFT", 10, -308)
setupAttackBtn:SetText("Setup Auto Attack")
setupAttackBtn:SetScript("OnClick", function()
	-- Find the Attack spell in the spellbook and place it into action slot 72
	for i = 1, 200 do
		local name = GetSpellName(i, BOOKTYPE_SPELL)
		if name == "Attack" then
			PickupSpell(i, BOOKTYPE_SPELL)
			PlaceAction(72)
			print("|cFFFFD700RoguePoker|r: Attack placed in action slot 72.")
			return
		end
	end
	print("|cFFFFD700RoguePoker|r: Could not find Attack in spellbook.")
end)

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
	insigniaStunsCB:SetChecked(db.useInsigniaStuns)
	insigniaMovementCB:SetChecked(db.useInsigniaMovement)
	UpdateInsigniaSubOptions()
	sprintMovementCB:SetChecked(db.useSprintMovement)
	tankModeCB:SetChecked(db.tankMode)
	pvpModeCB:SetChecked(db.pvpMode)
	autoAssistCB:SetChecked(db.autoAssist)
	assistEditBox:SetText(db.autoAssistName or "")
end

-- ==========================================
-- Version label
-- ==========================================
local versionLabel = cfgFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
versionLabel:SetPoint("BOTTOMRIGHT", cfgFrame, "BOTTOMRIGHT", -8, 8)
versionLabel:SetText("v1.2.0")
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
local loadFrame = CreateFrame("Frame")
loadFrame:RegisterEvent("VARIABLES_LOADED")
loadFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
loadFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
loadFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
loadFrame:RegisterEvent("UI_ERROR_MESSAGE")
loadFrame:SetScript("OnEvent", function()
	if event == "PLAYER_REGEN_DISABLED" then
		RoguePoker.inCombat = true
		RoguePoker.shadowOfDeathPending = false
		RoguePoker.shadowOfDeathPendingTime = nil
		RoguePoker.defensivePending = nil
		RoguePoker.defensivePendingTime = nil
		RoguePoker.notBehindTarget = false
		RoguePoker.notBehindTime = nil
	elseif event == "PLAYER_REGEN_ENABLED" then
		RoguePoker.inCombat = false
		RoguePoker.shadowOfDeathPending = false
		RoguePoker.shadowOfDeathPendingTime = nil
		RoguePoker.defensivePending = nil
		RoguePoker.defensivePendingTime = nil
		RoguePoker.notBehindTarget = false
		RoguePoker.notBehindTime = nil
		RoguePoker.debuffExpiry = {}
	elseif event == "UI_ERROR_MESSAGE" then
		if arg1 and string.find(arg1, "behind") then
			RoguePoker.notBehindTarget = true
			RoguePoker.notBehindTime = GetTime()
		end
	elseif event == "VARIABLES_LOADED" then
		InitDB()

	elseif event == "PLAYER_ENTERING_WORLD" then
		if not RoguePokerDB then return end
		knownBuilders = RoguePoker:FilterKnown(RoguePoker.BUILDERS)
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
		insigniaStunsCB:SetChecked(RoguePokerDB.useInsigniaStuns)
		insigniaMovementCB:SetChecked(RoguePokerDB.useInsigniaMovement)
		UpdateInsigniaSubOptions()
		sprintMovementCB:SetChecked(RoguePokerDB.useSprintMovement)
		tankModeCB:SetChecked(RoguePokerDB.tankMode)
		pvpModeCB:SetChecked(RoguePokerDB.pvpMode)
		autoAssistCB:SetChecked(RoguePokerDB.autoAssist)
		assistEditBox:SetText(RoguePokerDB.autoAssistName or "")
		print("|cFFFFD700RoguePoker|r loaded. Type |cFFFFD700/rp|r to configure.")
	end
end)

-- ==========================================
-- Slash Command
-- ==========================================
SLASH_ROGUEPOKR1 = "/rp"
SlashCmdList["ROGUEPOKR"] = function(msg)
	if msg == "help" then
		print("|cFFFFD700RoguePoker|r - Rogue rotation helper for Turtle WoW")
		print("|cFFFFD700What it does:|r")
		print("  Automates your rogue rotation when you press a single macro button.")
		print("  Manages combo builders, finishers, evasion cooldowns, and interrupts")
		print("  in priority order. Procs like Surprise Attack and Riposte are detected")
		print("  automatically via combat events and fire when available.")
		print("|cFFFFD700Required macros:|r")
		print("  |cFFAAAAAA/script RoguePoker:Rota()|r  -- Main rotation (bind to a key and spam)")
		print("  |cFFAAAAAA/script RoguePoker:Interrupt()|r  -- Interrupt rotation (bind separately)")
		print("|cFFFFD700Commands:|r")
		print("  |cFFAAAAAA/rp|r        -- Toggle configuration panel")
		print("  |cFFAAAAAA/rp help|r   -- Show this help text")
		print("  |cFFAAAAAA/rpassist|r  -- Assist the player set in the Auto Assist box")
	else
		if cfgFrame:IsShown() then
			cfgFrame:Hide()
		else
			cfgFrame:ClearAllPoints()
			cfgFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
			cfgFrame:Show()
		end
	end
end

SLASH_RPASSIST1 = "/rpassist"
SlashCmdList["RPASSIST"] = function()
	RoguePoker:AssistNamedPlayer()
end

function RoguePoker:DumpDebuffs()
	if not WriteCustomFile then
		print("|cFFFFD700RoguePoker|r: WriteCustomFile not available (nampower not loaded?)")
		return
	end
	local lines = {}
	local timestamp = date("%Y-%m-%d %H:%M:%S")
	table.insert(lines, "RoguePoker Debuff Dump - " .. timestamp)
	table.insert(lines, "----------------------------------------")
	local i = 1
	local count = 0
	while true do
		local texture = UnitDebuff("player", i)
		if not texture then break end
		local inStuns     = RoguePoker.stunTextures[texture]     and "STUN"     or ""
		local inMovement  = RoguePoker.movementTextures[texture] and "MOVEMENT" or ""
		local category = (inStuns ~= "" and inStuns) or (inMovement ~= "" and inMovement) or "UNCATEGORIZED"
		table.insert(lines, "[" .. category .. "] " .. texture)
		count = count + 1
		i = i + 1
	end
	if count == 0 then
		table.insert(lines, "(no debuffs active)")
	end
	table.insert(lines, "----------------------------------------")
	table.insert(lines, "Total: " .. count .. " debuffs")
	local content = ""
	for _, line in ipairs(lines) do
		content = content .. line .. "\n"
	end
	WriteCustomFile("RoguePokerDebuffs.txt", content, "a")
	print("|cFFFFD700RoguePoker|r: " .. count .. " debuffs written to CustomData/RoguePokerDebuffs.txt")
end

SLASH_RPDUMP1 = "/rpdump"
SlashCmdList["RPDUMP"] = function()
	RoguePoker:DumpDebuffs()
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