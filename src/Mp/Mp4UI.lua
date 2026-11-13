-- P2P multiplayer: config file, main loop and the in-game menu.
-- The menu is reached through a permanent "Multiplayer" on-screen notification.

Mp = rawget(_G, "Mp") or {}
Mp.tick_count = Mp.tick_count or 0

local CONFIG = "AppData/multiplayer.cfg"
local MENU_ID = "MpMenu"
local MENU_ICON = "UI/Icons/Notifications/New/placeholder_2.tga"
local POPUP_IMAGE = "UI/Messages/outsource.tga"

----- config ------------------------------------------------------------------

function Mp.SaveConfig()
	local cfg = Mp.cfg
	if not cfg then return end
	local text = table.concat({
		"# Surviving Mars P2P multiplayer settings",
		"name=" .. cfg.name,
		"host=" .. cfg.host,
		"port=" .. cfg.port,
		"id=" .. cfg.id,
		"",
	}, "\r\n")
	local ok, err = pcall(AsyncStringToFile, CONFIG, text)
	if not ok or err then Mp.Log("could not save config:", tostring(err)) end
end

function Mp.LoadConfig()
	local cfg = { name = "", host = "127.0.0.1", port = Mp.DEFAULT_PORT, id = "" }
	local ok, err, data = pcall(AsyncFileToString, CONFIG)
	if ok and not err and type(data) == "string" then
		for line in data:gmatch("[^\r\n]+") do
			local k, v = line:match("^%s*(%a+)%s*=%s*(.-)%s*$")
			if k == "name" or k == "host" or k == "id" then
				cfg[k] = v
			elseif k == "port" then
				cfg.port = tonumber(v) or cfg.port
			end
		end
	end
	local dirty = false
	if not cfg.id:match("^%w+$") or #cfg.id < 4 or #cfg.id > 32 then
		cfg.id = Mp.NewId()
		dirty = true
	end
	if cfg.name == "" then
		cfg.name = "Player" .. (AsyncRand(900) + 100)
		dirty = true
	end
	cfg.port = Mp.Clamp(Mp.Floor(cfg.port), 1, 65535)
	Mp.cfg = cfg
	if dirty then Mp.SaveConfig() end
	Mp.Log("config loaded: name", cfg.name, "host", cfg.host, "port", cfg.port)
end

----- popups ------------------------------------------------------------------

-- Returns the index of the chosen entry.
local function popup(title, text, choices)
	local params = {
		title = Mp.Text(title),
		text = Mp.Text(text),
		image = POPUP_IMAGE,
		start_minimized = false,
		dont_pause = true,
	}
	for i, choice in ipairs(choices) do
		params["choice" .. i] = Mp.Text(choice)
	end
	local ok, res = pcall(WaitPopupNotification, false, params, false, terminal.desktop)
	if not ok then
		Mp.Log("popup failed:", res)
		return #choices
	end
	return res
end

local function online_peers()
	local list = {}
	for _, peer in pairs(Mp.peers) do
		if peer.online then list[#list + 1] = peer end
	end
	table.sort(list, function(a, b) return a.name < b.name end)
	return list
end

local function status_text()
	local lines = {}
	if Mp.role == "host" then
		lines[#lines + 1] = "Hosting on port " .. Mp.cfg.port .. " as " .. Mp.cfg.name .. "."
	elseif Mp.role == "client" then
		lines[#lines + 1] = (Mp.connected and "Connected to " or "Connecting to ") .. Mp.cfg.host .. ":" .. Mp.cfg.port .. " as " .. Mp.cfg.name .. "."
	else
		lines[#lines + 1] = "Not connected. You are " .. Mp.cfg.name .. "."
	end
	local peers = online_peers()
	if #peers > 0 then
		local names = {}
		for _, peer in ipairs(peers) do names[#names + 1] = peer.name end
		lines[#lines + 1] = "Players: " .. table.concat(names, ", ")
	elseif Mp.role then
		lines[#lines + 1] = "No other players yet."
	end
	if not Mp.SpaceRace() then
		lines[#lines + 1] = "Space Race is required: other players appear as rival colonies."
	end
	lines[#lines + 1] = "Other players show up in the Planetary View as rival colonies. Settings: %AppData%\\Surviving Mars\\multiplayer.cfg"
	return table.concat(lines, "<newline><newline>")
end

local function ask_address()
	local default = Mp.cfg.host .. ":" .. Mp.cfg.port
	local ok, text = pcall(WaitInputText, "Host address (ip:port)", default)
	if not ok then
		Mp.Notify("Multiplayer", "Text input is unavailable; set host= and port= in multiplayer.cfg instead.")
		return false
	end
	if type(text) ~= "string" or text == "" then return false end
	local host, port = text:match("^%s*([%w%.%-]+):(%d+)%s*$")
	if not host then host = text:match("^%s*([%w%.%-]+)%s*$") end
	if not host then
		Mp.Notify("Multiplayer", "That address was not understood.")
		return false
	end
	Mp.cfg.host = host
	Mp.cfg.port = Mp.Clamp(tonumber(port) or Mp.cfg.port, 1, 65535)
	Mp.SaveConfig()
	return true
end

-- Pick one entry from a list longer than a popup can show (4 buttons):
-- three entries per page plus "More...", and "Cancel" on the last page.
local function pick_paged(title, text, items)
	local pos = 1
	while pos <= #items do
		local choices, map = {}, {}
		local last = #items - pos + 1 <= 3
		for i = pos, Mp.Min(pos + 2, #items) do
			choices[#choices + 1] = Mp.GoodName(items[i])
			map[#choices] = items[i]
		end
		choices[#choices + 1] = last and "Cancel" or "More..."
		local pick = popup(title, text, choices)
		if map[pick] then return map[pick] end
		if last then return end
		pos = pos + 3
	end
end

local function offer_route()
	local peers = online_peers()
	if #peers == 0 then
		Mp.Notify("Multiplayer", "Nobody to trade with yet.")
		return
	end
	local choices = {}
	for i = 1, Mp.Min(#peers, 3) do choices[i] = peers[i].name end
	choices[#choices + 1] = "Cancel"
	local pick = popup("Offer a trade route",
		"Open a trade route from your colony to another player. They will see it in their Planetary View and can send rockets along it.",
		choices)
	local peer = peers[pick]
	if pick >= #choices or not peer then return end

	local sell = pick_paged("You sell", "Which resource does " .. peer.name .. " receive from you on each trade rocket?", Mp.TRADE_GOODS)
	if not sell then return end
	local wants = { "funding" }
	for _, res in ipairs(Mp.TRADE_GOODS) do
		if res ~= sell then wants[#wants + 1] = res end
	end
	local want = pick_paged("You receive", "What do you want in return for " .. Mp.GoodName(sell) .. "?", wants)
	if not want then return end

	local fair = Mp.FairPrice(sell, want)
	local unit = want == "funding" and "M" or (" " .. Mp.GoodName(want))
	local function label(qty)
		if want == "funding" then return qty .. unit end
		return (qty // 1000) .. "." .. ((qty % 1000) // 100) .. unit
	end
	local prices = { Mp.Max(fair // 2, 1), fair, fair * 2 }
	local price = popup("Price", "How much " .. (want == "funding" and "funding" or Mp.GoodName(want))
		.. " do you want for each unit of " .. Mp.GoodName(sell) .. "?",
		{ "Cheap: " .. label(prices[1]), "Fair: " .. label(prices[2]), "Expensive: " .. label(prices[3]), "Cancel" })
	if not prices[price] then return end

	Mp.Send({ t = "route", imp = sell, exp = want, qty = prices[price] }, peer.id)
	Mp.Notify("Multiplayer", "Trade route offered to " .. peer.name .. ": " .. Mp.GoodName(sell)
		.. " for " .. label(prices[price]) .. " per unit.")
end

function Mp.Menu()
	if Mp.menu_open or not Mp.cfg then return end
	Mp.menu_open = true
	local ok, err = pcall(function()
		if not Mp.role then
			local pick = popup("Multiplayer", status_text(), {
				"Host a game (port " .. Mp.cfg.port .. ")",
				"Join " .. Mp.cfg.host .. ":" .. Mp.cfg.port,
				"Join another address...",
				"Close",
			})
			if pick == 1 then
				local e = Mp.Host(Mp.cfg.port)
				Mp.Notify("Multiplayer", e and ("Could not host: " .. tostring(e)) or ("Hosting on port " .. Mp.cfg.port .. "."))
			elseif pick == 2 then
				Mp.Join(Mp.cfg.host, Mp.cfg.port)
			elseif pick == 3 then
				if ask_address() then Mp.Join(Mp.cfg.host, Mp.cfg.port) end
			end
		else
			local pick = popup("Multiplayer", status_text(), { "Offer a trade route", "Disconnect", "Close" })
			if pick == 1 then
				offer_route()
			elseif pick == 2 then
				Mp.Disconnect()
				Mp.Notify("Multiplayer", "Disconnected.")
			end
		end
	end)
	Mp.menu_open = false
	if not ok then Mp.Log("menu error:", err) end
end

local function ensure_menu_button()
	local colony = Mp.G("UIColony")
	local shown = false
	pcall(function()
		shown = IsOnScreenNotificationShown(MENU_ID .. tostring(MainMapID)) or IsOnScreenNotificationShown(MENU_ID)
	end)
	if shown and Mp.menu_for == colony then return end
	Mp.menu_for = colony
	local ok, err = pcall(AddCustomOnScreenNotification, MENU_ID,
		Mp.Text("Multiplayer"), Mp.Text("Host or join a game"), MENU_ICON,
		function() CreateRealTimeThread(Mp.Menu) end,
		{ dismissable = false })
	if not ok then Mp.Log("menu button failed:", err) end
end

----- main loop ---------------------------------------------------------------

local function handle_session_message(msg)
	if msg.t == "hello" then
		local id = msg.id
		if type(id) ~= "string" or id == Mp.MyId() then return true end
		local peer = Mp.peers[id] or { id = id }
		local name = type(msg.name) == "string" and msg.name:gsub("[%c<>]", ""):sub(1, 24) or "Player"
		if name == "" then name = "Player" end
		peer.name = name
		peer.sponsor = type(msg.sponsor) == "string" and msg.sponsor or ""
		peer.online = true
		Mp.peers[id] = peer
		Mp.Log("peer online:", name, id)
		return true
	elseif msg.t == "bye" then
		local peer = Mp.peers[msg.id]
		if peer and peer.online then
			peer.online = false
			Mp.Notify("Multiplayer", peer.name .. " left the game.")
		end
		return true
	end
end

function Mp.Tick()
	Mp.tick_count = Mp.tick_count + 1
	local inbox = Mp.inbox
	Mp.inbox = {}
	local in_game = Mp.InGame()

	for _, msg in ipairs(inbox) do
		if not handle_session_message(msg) and in_game and Mp.peers[msg.from] then
			CreateGameTimeThread(function()
				local ok, err = pcall(Mp.HandleGameMessage, msg)
				if not ok then Mp.Log("handler error (" .. tostring(msg.t) .. "):", err) end
			end)
		end
	end

	if not in_game then
		Mp.menu_for = false
		return
	end
	ensure_menu_button()
	if not Mp.role or not Mp.connected then return end

	-- our sponsor is only known once a colony exists; re-announce when it changes
	local sponsor = Mp.hello_sponsor
	local hello = Mp.HelloMsg()
	if hello.sponsor ~= sponsor then Mp.Send(hello) end

	for id, peer in pairs(Mp.peers) do
		if peer.online then
			local ai = Mp.EnsureRival(peer)
			if ai then Mp.FlushDeltas(ai, id) end
		else
			Mp.base[id] = nil   -- changes made while a player is away are not replayed
		end
	end

	if Mp.tick_count % 5 == 0 then
		Mp.Send(Mp.BuildSnapshot())
	end
end

function Mp.Start()
	if Mp.thread and IsValidThread(Mp.thread) then return end
	Mp.thread = CreateRealTimeThread(function()
		local ok, err = pcall(Mp.LoadConfig)
		if not ok then
			Mp.Log("config error:", err)
			Mp.cfg = { name = "Player", host = "127.0.0.1", port = Mp.DEFAULT_PORT, id = Mp.NewId() }
		end
		Mp.Log("multiplayer pack running")
		while true do
			Sleep(1000)
			local ok2, err2 = pcall(Mp.Tick)
			if not ok2 then Mp.Log("tick error:", err2) end
		end
	end)
end

function OnMsg.ClassesBuilt()
	Mp.Start()
end

function OnMsg.Autorun()
	Mp.Start()
end
