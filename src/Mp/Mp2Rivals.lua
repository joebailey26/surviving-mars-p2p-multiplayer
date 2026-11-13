-- P2P multiplayer: remote colonies as Space Race rival colonies.
-- Every remote player is a DumbAIPlayer in RivalAIs whose AI never thinks; its
-- `resources` / `researched_techs` are overwritten from that player's snapshots.
-- Whatever the local game then does to that rival (trade, aid, stealing...)
-- shows up as a difference against the last snapshot and is sent to the peer
-- as a delta, which the peer applies to their real colony.

Mp = rawget(_G, "Mp") or {}
Mp.base = Mp.base or {}            -- peer id -> last known resource values
Mp.tech_base = Mp.tech_base or {}  -- peer id -> set of tech ids from last snapshot

-- rival resource key -> real resource id
Mp.RES = {
	metals = "Metals", concrete = "Concrete", food = "Food", raremetals = "PreciousMetals",
	polymers = "Polymers", electronics = "Electronics", machineparts = "MachineParts", fuel = "Fuel",
}

-- keys a peer may set through a snapshot
Mp.SNAP_KEYS = { funding = true, colonists = true, buildings = true, research_production = true, researched_techs = true }
-- keys whose local changes are sent back as deltas
Mp.DELTA_KEYS = { funding = true, colonists = true }
for key in pairs(Mp.RES) do
	Mp.SNAP_KEYS[key] = true
	Mp.SNAP_KEYS[key .. "_production"] = true
	Mp.DELTA_KEYS[key] = true
end

local function clamp(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end
Mp.Clamp = clamp

local function untranslated(s)
	local f = Mp.G("Untranslated")
	return f and f(s) or s
end
Mp.Text = untranslated

function Mp.InGame()
	return Mp.G("UIColony") and Mp.G("MainCity") and Mp.G("GameTime") and true or false
end

function Mp.SpaceRace()
	return Mp.G("SpawnRivalAI") and Mp.G("DumbAIPlayer") and true or false
end

function Mp.FindRival(peer_id)
	local rivals = Mp.G("RivalAIs")
	if type(rivals) ~= "table" then return end
	for key, ai in pairs(rivals) do
		if ai.mp_peer == peer_id then return ai, key end
	end
end

function Mp.PeerName(peer_id)
	local peer = Mp.peers[peer_id]
	return peer and peer.name or "Unknown colony"
end

local function pick_preset(peer)
	local presets = Mp.G("Presets")
	local group = presets and presets.DumbAIDef and presets.DumbAIDef.MissionSponsors
	if not group then return end
	local rivals = Mp.G("RivalAIs") or {}
	local params = Mp.G("g_CurrentMissionParams")
	local mine = params and params.idMissionSponsor or Mp.hello_sponsor
	local function free(preset)
		local id = preset and preset.id
		return id and id ~= "random" and id ~= "none" and id ~= mine and not rivals[id]
	end
	if peer.sponsor and peer.sponsor ~= "" and free(group[peer.sponsor]) then
		return group[peer.sponsor]
	end
	for _, preset in ipairs(group) do
		if free(preset) then return preset end
	end
end

local function apply_names(ai, key, peer)
	ai.display_name = untranslated(peer.name)
	local spots = Mp.G("MarsScreenLandingSpots")
	local spot = spots and spots[key]
	if spot then spot.display_name = untranslated("Colony of " .. peer.name) end
end

local function mute(ai)
	-- no AI behaviour at all for a human-driven rival
	ai.actions = {}
	ai.production_rules = {}
	ai.running_actions = {}
end

-- Make sure the peer has a rival object in the current game. Returns it.
function Mp.EnsureRival(peer)
	if not Mp.InGame() or not Mp.SpaceRace() then return end
	local ai, key = Mp.FindRival(peer.id)
	if ai then
		if ai.mp_name ~= peer.name then
			ai.mp_name = peer.name
			apply_names(ai, key, peer)
		end
		return ai
	end
	if type(Mp.G("RivalAIs")) ~= "table" then
		RivalAIs = {}
	end
	local preset = pick_preset(peer)
	if not preset then
		if not peer.warned then
			peer.warned = true
			Mp.Log("no free rival slot for", peer.name)
			Mp.Notify("Multiplayer", "No free rival colony slot for " .. peer.name .. ".")
		end
		return
	end
	local ok, obj = pcall(SpawnRivalAI, preset)
	if not ok or not obj then
		Mp.Log("SpawnRivalAI failed:", tostring(obj))
		return
	end
	obj.mp_peer = peer.id
	obj.mp_name = peer.name
	mute(obj)
	for res in pairs(obj.resources) do obj.resources[res] = 0 end
	obj.researched_techs = {}
	apply_names(obj, preset.id, peer)
	Mp.base[peer.id] = nil
	Mp.Log("spawned rival", preset.id, "for", peer.name)
	Mp.Notify("Multiplayer", peer.name .. " joined as a rival colony.")
	return obj
end

----- snapshots ---------------------------------------------------------------

function Mp.BuildSnapshot()
	local res = {}
	local mil = const.Scale and const.Scale.mil or 1000000
	local scale = const.ResourceScale or 1000
	pcall(function() res.funding = UIColony.funds:GetFunding() // mil end)
	local ro
	pcall(function() ro = GetCityResourceOverview(MainCity) end)
	if ro then
		for key, id in pairs(Mp.RES) do
			pcall(function() res[key] = (ro:GetAvailable(id) or 0) // scale end)
			pcall(function() res[key .. "_production"] = (ro:GetProducedYesterday(id) or 0) // scale end)
		end
		pcall(function() res.colonists = ro:GetColonistCount() or 0 end)
		pcall(function() res.buildings = ro:GetBuildingsCount() or 0 end)
	end
	local techs = {}
	pcall(function()
		for id, status in pairs(UIColony.tech_status) do
			if status.researched and #techs < 600 then techs[#techs + 1] = id end
		end
	end)
	res.researched_techs = #techs
	for key, v in pairs(res) do
		res[key] = Mp.Floor(v)
	end
	return { t = "snap", res = res, techs = techs, sol = Mp.G("UIColony") and UIColony.day or 0 }
end

-- Send what the local game changed on this rival since the last snapshot.
function Mp.FlushDeltas(ai, peer_id)
	local base = Mp.base[peer_id]
	local res = ai.resources
	if not base then
		base = {}
		for key in pairs(Mp.DELTA_KEYS) do base[key] = res[key] or 0 end
		base.standing = res.standing or 0
		Mp.base[peer_id] = base
		return
	end
	local d
	for key in pairs(Mp.DELTA_KEYS) do
		local cur = res[key] or 0
		local was = base[key] or cur
		if cur ~= was then
			d = d or {}
			d[key] = cur - was
			base[key] = cur
		end
	end
	if d then Mp.Send({ t = "delta", d = d }, peer_id) end

	local standing = clamp(res.standing or 0, -100, 100)
	res.standing = standing
	if standing ~= base.standing then
		base.standing = standing
		Mp.Send({ t = "standing", v = standing }, peer_id)
	end

	-- techs handed to the rival locally (tech exchange) are granted to the peer
	local known = Mp.tech_base[peer_id]
	if known then
		for _, id in ipairs(ai.researched_techs or {}) do
			if type(id) == "string" and not known[id] then
				known[id] = true
				Mp.Send({ t = "tech", id = id }, peer_id)
			end
		end
	end
end

function Mp.ApplySnapshot(msg)
	local peer = Mp.peers[msg.from]
	if not peer then return end
	local ai = Mp.EnsureRival(peer)
	if not ai then return end
	Mp.FlushDeltas(ai, peer.id)   -- do not lose local changes made since last time
	local base = Mp.base[peer.id]
	if type(msg.res) == "table" then
		for key, v in pairs(msg.res) do
			if Mp.SNAP_KEYS[key] and type(v) == "number" then
				v = Mp.Floor(clamp(v, key == "funding" and -1000000 or 0, 100000000))
				ai.resources[key] = v
				if base and Mp.DELTA_KEYS[key] then base[key] = v end
			end
		end
	end
	if type(msg.techs) == "table" then
		local defs = Mp.G("TechDef") or {}
		local list, set = {}, {}
		for _, id in ipairs(msg.techs) do
			if type(id) == "string" and defs[id] and not set[id] then
				set[id] = true
				list[#list + 1] = id
			end
		end
		ai.researched_techs = list
		Mp.tech_base[peer.id] = set
	end
	mute(ai)
	pcall(ObjModified, ai)
end

function Mp.ApplyStanding(msg)
	local ai = Mp.FindRival(msg.from)
	if not ai or type(msg.v) ~= "number" then return end
	local v = Mp.Floor(clamp(msg.v, -100, 100))
	ai.resources.standing = v
	local base = Mp.base[msg.from]
	if base then base.standing = v end
	pcall(ObjModified, ai)
end

----- keep the stock AI away from human rivals --------------------------------

function OnMsg.ClassesPreprocess(classdefs)
	local def = type(classdefs) == "table" and rawget(classdefs, "DumbAIPlayer") or Mp.G("DumbAIPlayer")
	if type(def) == "table" and def.AIThink and not rawget(def, "mp_wrapped") then
		def.mp_wrapped = true
		local think = def.AIThink
		def.AIThink = function(self, ...)
			if self.mp_peer then return end
			return think(self, ...)
		end
		local add = def.AddAIDef
		if add then
			def.AddAIDef = function(self, ...)
				if self.mp_peer then return end
				return add(self, ...)
			end
		end
	end
end
