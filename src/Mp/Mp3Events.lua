-- P2P multiplayer: applying what other players did to us, and reporting
-- covert operations we ran against them.

Mp = rawget(_G, "Mp") or {}
Mp.note_seq = Mp.note_seq or 0

local ICON = "UI/Icons/Notifications/New/placeholder_2.tga"

-- On-screen notification; clicking it dismisses it.
function Mp.Notify(title, text)
	if not Mp.InGame or not Mp.InGame() then
		Mp.Log(title .. ": " .. text)
		return
	end
	Mp.note_seq = Mp.note_seq + 1
	local id = "MpNote" .. Mp.note_seq
	local ok, err = pcall(AddCustomOnScreenNotification, id, Mp.Text(title), Mp.Text(text), ICON,
		function() pcall(RemoveOnScreenNotification, id) end,
		{ expiration = 180000, close_on_read = true })
	if not ok then Mp.Log("notify failed:", err, "|", title, text) end
end

local function label(name)
	local city = Mp.G("MainCity")
	local labels = city and city.labels
	return labels and labels[name] or {}
end

local function shuffled(list)
	local out = {}
	for i, v in ipairs(list) do out[i] = v end
	for i = #out, 2, -1 do
		local j = AsyncRand(i) + 1
		out[i], out[j] = out[j], out[i]
	end
	return out
end

-- Take `amount` (scaled units) of a resource out of the colony's depots.
-- Returns how much was actually removed.
function Mp.RemoveResource(res, amount)
	local left = amount
	local seen = {}
	for _, name in ipairs{ "UniversalStorageDepot", "MechanizedDepots", "StorageDepot", "Storages" } do
		for _, depot in ipairs(label(name)) do
			if left <= 0 then break end
			if not seen[depot] and depot.supply and depot.supply[res] then
				seen[depot] = true
				pcall(function()
					local stored = depot.supply[res]:GetActualAmount() or 0
					local take = Mp.Min(stored, left)
					if take <= 0 then return end
					if depot.stockpiled_amount ~= nil and depot.AddResource then
						depot:AddResource(-take, res)
					elseif depot.AddDepotResource then
						depot:AddDepotResource(-take, res)
					else
						return
					end
					left = left - take
				end)
			end
		end
	end
	return amount - left
end

function Mp.RemoveColonists(n)
	local removed = 0
	for _, colonist in ipairs(shuffled(label("Colonist"))) do
		if removed >= n then break end
		if pcall(colonist.Erase, colonist) then removed = removed + 1 end
	end
	return removed
end

function Mp.KillDrones(n)
	local removed = 0
	for _, drone in ipairs(shuffled(label("Drone"))) do
		if removed >= n then break end
		if pcall(drone.SetCommand, drone, "Dead", false, false) then removed = removed + 1 end
	end
	return removed
end

function Mp.SabotageBuildings(pct)
	local candidates = {}
	for _, bld in ipairs(label("Building")) do
		if bld.SetMalfunction and not bld.destroyed and not bld.demolishing
			and bld.maintenance_resource_type and bld.maintenance_resource_type ~= "no_maintenance" then
			candidates[#candidates + 1] = bld
		end
	end
	local n = Mp.Clamp(Mp.Floor(#candidates * pct / 100 + 0.5), 1, 15)
	local done = 0
	for _, bld in ipairs(shuffled(candidates)) do
		if done >= n then break end
		if pcall(bld.SetMalfunction, bld) then done = done + 1 end
	end
	return done
end

local function send_aid_rocket(from, cargo)
	local _, key = Mp.FindRival(from)
	local spots = Mp.G("MarsScreenLandingSpots")
	local spot = spots and key and spots[key]
	local ok, err = pcall(function()
		local rocket = PlaceBuildingIn("ForeignAidRocket", MainMapID, {
			sponsor_id = key,
			logo_id = spot and spot.logo_id,
		})
		cargo.rocket_name = "Cargo from " .. Mp.PeerName(from)
		rocket:SetCommand("FlyToMars", cargo)
	end)
	if not ok then Mp.Log("aid rocket failed:", err) end
	return ok
end

-- The peer's game changed "our" entry in its rival list; mirror it on the real colony.
function Mp.ApplyDelta(msg)
	if type(msg.d) ~= "table" then return end
	local name = Mp.PeerName(msg.from)
	local mil = const.Scale and const.Scale.mil or 1000000
	local scale = const.ResourceScale or 1000
	local cargo, got, lost = {}, {}, {}
	for key, v in pairs(msg.d) do
		if type(v) == "number" and v ~= 0 and Mp.DELTA_KEYS[key] then
			v = Mp.Floor(Mp.Clamp(v, -5000, 5000))
			if key == "funding" then
				pcall(function() UIColony.funds:ChangeFunding(v * mil, "Rival") end)
				local line = Mp.Abs(v) .. "M funding"
				if v > 0 then got[#got + 1] = line else lost[#lost + 1] = line end
			elseif key == "colonists" then
				if v < 0 then
					local n = Mp.RemoveColonists(Mp.Clamp(-v, 0, 20))
					if n > 0 then lost[#lost + 1] = n .. " colonists" end
				end
			elseif Mp.RES[key] then
				if v > 0 then
					cargo[#cargo + 1] = { class = Mp.RES[key], amount = v }
					got[#got + 1] = v .. " " .. Mp.RES[key]
				else
					local removed = Mp.RemoveResource(Mp.RES[key], -v * scale)
					if removed > 0 then lost[#lost + 1] = Mp.Floor(removed / scale) .. " " .. Mp.RES[key] end
				end
			end
		end
	end
	if #cargo > 0 then send_aid_rocket(msg.from, cargo) end
	if #got > 0 or #lost > 0 then
		local text = ""
		if #got > 0 then text = "Received: " .. table.concat(got, ", ") .. ". " end
		if #lost > 0 then text = text .. "Given up: " .. table.concat(lost, ", ") .. "." end
		Mp.Notify("Exchange with " .. name, text)
	end
end

function Mp.ApplyCovert(msg)
	local name = Mp.PeerName(msg.from)
	local n = type(msg.n) == "number" and Mp.Floor(Mp.Clamp(msg.n, 0, 20)) or 0
	if msg.effect == "drones" then
		local killed = Mp.KillDrones(n)
		Mp.Notify("Covert operation", "Agents of " .. name .. " made off with " .. killed .. " of our drones.")
	elseif msg.effect == "colonists" then
		-- the colonists themselves are removed through the delta
		Mp.Notify("Covert operation", name .. " lured away some of our colonists.")
	elseif msg.effect == "sabotage" then
		local pct = type(msg.pct) == "number" and Mp.Clamp(msg.pct, 1, 50) or 10
		local broken = Mp.SabotageBuildings(pct)
		Mp.Notify("Sabotage", "Agents of " .. name .. " sabotaged " .. broken .. " of our buildings.")
	elseif msg.effect == "tech" then
		Mp.Notify("Covert operation", "Agents of " .. name .. " stole research data from us.")
	end
end

function Mp.ApplyTech(msg)
	local defs = Mp.G("TechDef")
	if type(msg.id) ~= "string" or not defs or not defs[msg.id] then return end
	local known = false
	pcall(function() known = UIColony:IsTechResearched(msg.id) end)
	if known then return end
	if pcall(GrantTech, msg.id) then
		Mp.Notify("Technology exchange", Mp.PeerName(msg.from) .. " shared a technology with us.")
	end
end

----- trade routes --------------------------------------------------------------

Mp.TRADE_GOODS = { "Metals", "Concrete", "Food", "PreciousMetals", "Polymers", "Electronics", "MachineParts", "Fuel" }
local GOOD_NAMES = { PreciousMetals = "Rare Metals", MachineParts = "Machine Parts", funding = "Funding" }
local BASIC = { Metals = true, Concrete = true, Food = true }

function Mp.GoodName(res)
	return GOOD_NAMES[res] or tostring(res)
end

function Mp.Max(a, b)
	if a > b then return a end
	return b
end

local function is_good(res)
	for _, id in ipairs(Mp.TRADE_GOODS) do
		if id == res then return true end
	end
	return false
end

-- price of one unit, from the game's cargo presets
local function unit_price(res)
	local price
	pcall(function()
		local cargo = Presets.Cargo
		local def = cargo["Basic Resources"][res] or cargo["Advanced Resources"][res]
		price = def.price // def.pack
	end)
	return price
end

-- What one unit of `sell` is worth, in wire units of `want`:
-- whole millions for funding, thousandths of a unit for a resource.
function Mp.FairPrice(sell, want)
	if want == "funding" then
		return BASIC[sell] and 3 or 15      -- the stock routes ask 1-5M / 10-20M
	end
	local a, b = unit_price(sell), unit_price(want)
	if a and b and b > 0 then
		return Mp.Clamp(a * 1000 // b // 100 * 100, 100, 50000)
	end
	return 1000
end

-- A peer offers us a trade route: we receive msg.imp from them and pay msg.exp.
-- Without terms (older builds) the game picks them at random.
function Mp.ApplyRoute(msg)
	local ai = Mp.FindRival(msg.from)
	if not ai or not Mp.G("OpenTradeRoute") then return end
	local imp, exp, qty
	if is_good(msg.imp) and (msg.exp == "funding" or is_good(msg.exp)) and msg.imp ~= msg.exp
		and type(msg.qty) == "number" then
		imp, exp = msg.imp, msg.exp
		if exp == "funding" then
			local mil = const.Scale and const.Scale.mil or 1000000
			qty = Mp.Floor(Mp.Clamp(msg.qty, 1, 100)) * mil
		else
			local scale = const.ResourceScale or 1000
			qty = Mp.Floor(Mp.Clamp(msg.qty, 100, 50000)) * scale // 1000
		end
	end
	local before = #(ai.trade_routes or "")
	local ok, err = pcall(OpenTradeRoute, ai, imp, exp, qty)
	if not ok then
		Mp.Log("OpenTradeRoute failed:", err)
		return
	end
	-- with explicit terms the stock code does not record whose route it is
	local routes = ai.trade_routes or {}
	local route = routes[#routes]
	if route and #routes > before and not route.sponsor then
		route.sponsor = ai.sponsor
	end
	Mp.Log("trade route opened with", Mp.PeerName(msg.from), tostring(imp), tostring(exp), tostring(qty))
end

-- Dispatch one network message. Runs inside a game-time thread.
function Mp.HandleGameMessage(msg)
	local t = msg.t
	if t == "snap" then Mp.ApplySnapshot(msg)
	elseif t == "delta" then Mp.ApplyDelta(msg)
	elseif t == "standing" then Mp.ApplyStanding(msg)
	elseif t == "covert" then Mp.ApplyCovert(msg)
	elseif t == "tech" then Mp.ApplyTech(msg)
	elseif t == "route" then Mp.ApplyRoute(msg)
	end
end

----- report our own covert operations against human rivals --------------------

function OnMsg.ClassesPreprocess(classdefs)
	local def = type(classdefs) == "table" and rawget(classdefs, "MarsCovertOp") or Mp.G("MarsCovertOp")
	if type(def) ~= "table" or not def.Execute or rawget(def, "mp_wrapped") then return end
	def.mp_wrapped = true
	local execute = def.Execute
	def.Execute = function(self, rocket, ...)
		local target = self.target_player
		local peer = target and target.mp_peer
		if not peer then return execute(self, rocket, ...) end
		local info = {
			t = "covert",
			effect = self.effect,
			n = self.effect == "drones" and self.stolen_drones or self.recruit_num,
			pct = self.damage_buildings,
		}
		local before = target.resources.standing
		local change = self.standing_change
		local results = { execute(self, rocket, ...) }
		-- the stock code only touches the standing when the operation succeeded
		if change ~= 0 and target.resources.standing ~= before then
			Mp.Send(info, peer)
		end
		return (table.unpack or rawget(_G, "unpack"))(results)
	end
end
