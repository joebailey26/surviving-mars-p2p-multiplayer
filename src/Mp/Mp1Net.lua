-- P2P multiplayer: transport layer.
-- Star topology over the engine's raw TCP sockets: one player listens (host),
-- up to three others connect; the host relays messages between clients.
-- Messages are newline-terminated flat text records. Nothing received from the
-- network is ever passed to load()/dofile().

Mp = rawget(_G, "Mp") or {}
Mp.peers = Mp.peers or {}        -- peer id -> { id, name, sponsor, online }
Mp.clients = Mp.clients or {}    -- host only: accepted socket -> true
Mp.inbox = Mp.inbox or {}        -- decoded messages waiting for the game tick
Mp.role = Mp.role or false       -- false | "host" | "client"
Mp.listener = Mp.listener or false
Mp.client = Mp.client or false
Mp.connected = Mp.connected or false
Mp.cfg = Mp.cfg or false

Mp.MAX_CLIENTS = 3
Mp.MAX_LINE = 64 * 1024
Mp.DEFAULT_PORT = 27600

function Mp.Log(...)
	local parts = {}
	for i = 1, select("#", ...) do
		parts[#parts + 1] = tostring((select(i, ...)))
	end
	local line = "[MP] " .. table.concat(parts, " ")
	local boot = rawget(_G, "MpBootLog")
	if boot then
		boot(line)
	else
		pcall(function() DebugPrint(line .. "\n") end)
	end
end

-- Safe global lookup (the game's _G may raise on undefined globals).
function Mp.G(name)
	local ok, v = pcall(function() return _G[name] end)
	if ok then return v end
end

-- The game's Lua has no `math` library, so the few helpers needed live here.
function Mp.Floor(v)
	local ok, i = pcall(function() return (v // 1) | 0 end)
	return ok and i or 0
end

function Mp.Min(a, b)
	if a < b then return a end
	return b
end

function Mp.Abs(v)
	if v < 0 then return -v end
	return v
end

----- serialization -----------------------------------------------------------
-- record := pair ('|' pair)*      pair := key '=' type value
-- key may be "a" or "a.b" (one nesting level); type is n(umber) s(tring) b(ool)

local function esc(s)
	return (tostring(s):gsub("[%%|=%.\r\n]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

local function unesc(s)
	return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function enc_value(v)
	local t = type(v)
	if t == "number" then
		return "n" .. tostring(Mp.Floor(v))   -- everything on the wire is a whole number
	elseif t == "boolean" then
		return v and "b1" or "b0"
	elseif t == "string" then
		return "s" .. esc(v)
	end
end

function Mp.Encode(msg)
	local out = {}
	for k, v in pairs(msg) do
		if type(v) == "table" then
			for k2, v2 in pairs(v) do
				local ev = enc_value(v2)
				if ev then out[#out + 1] = esc(k) .. "." .. esc(k2) .. "=" .. ev end
			end
		else
			local ev = enc_value(v)
			if ev then out[#out + 1] = esc(k) .. "=" .. ev end
		end
	end
	return table.concat(out, "|")
end

local function dec_key(k)
	k = unesc(k)
	if k:match("^%d+$") and #k < 10 then return tonumber(k) end
	return k
end

function Mp.Decode(line)
	local msg, count = {}, 0
	for pair in line:gmatch("[^|]+") do
		count = count + 1
		if count > 5000 then return nil end
		local k, typ, raw = pair:match("^([^=]*)=(%a)(.*)$")
		if not k then return nil end
		local v
		if typ == "n" then
			v = tonumber(raw)
			if not v or v ~= v then return nil end
		elseif typ == "b" then
			v = raw == "1"
		elseif typ == "s" then
			v = unesc(raw)
		else
			return nil
		end
		local a, b = k:match("^([^%.]*)%.(.*)$")
		if a then
			a, b = dec_key(a), dec_key(b)
			if type(msg[a]) ~= "table" then msg[a] = {} end
			msg[a][b] = v
		else
			msg[dec_key(k)] = v
		end
	end
	if type(msg.t) ~= "string" then return nil end
	return msg
end

----- socket class ------------------------------------------------------------

DefineClass.MpSocket = {
	__parents = { "BaseSocket" },
	socket_type = "MpSocket",
	mp_role = "accepted",   -- "listener" | "client" | "accepted"
	mp_peer = false,        -- peer id once the hello arrived
	mp_buf = "",
}

function MpSocket:OnConnect(err, host, port)
	BaseSocket.OnConnect(self, err, host, port)
	local ok, e = pcall(Mp.OnSocketConnect, self, err, host, port)
	if not ok then Mp.Log("OnConnect error:", e) end
	return self
end

function MpSocket:OnDisconnect(reason)
	local ok, e = pcall(Mp.OnSocketClosed, self, reason)
	if not ok then Mp.Log("OnDisconnect error:", e) end
end

function MpSocket:OnReceive(data)
	if type(data) ~= "string" then return end
	local buf = self.mp_buf .. data
	if #buf > 4 * Mp.MAX_LINE then
		Mp.Log("receive buffer overflow, dropping connection")
		self.mp_buf = ""
		Mp.CloseSocket(self)
		return
	end
	while true do
		local nl = buf:find("\n", 1, true)
		if not nl then break end
		local line = buf:sub(1, nl - 1)
		buf = buf:sub(nl + 1)
		if #line > 0 and #line <= Mp.MAX_LINE then
			local ok, e = pcall(Mp.OnLine, self, line)
			if not ok then Mp.Log("message error:", e) end
		end
	end
	self.mp_buf = buf
end

function Mp.SendRaw(sock, msg)
	if not sock then return end
	local ok, err = pcall(sock.Send, sock, Mp.Encode(msg) .. "\n")
	if not ok or err then Mp.Log("send failed:", tostring(ok and err or err)) end
end

function Mp.CloseSocket(sock)
	if not sock then return end
	pcall(sock.Disconnect, sock)
	pcall(sock.delete, sock)
end

----- session -----------------------------------------------------------------

function Mp.MyId()
	return Mp.session_id or (Mp.cfg and Mp.cfg.id) or "?"
end

function Mp.NewId()
	return string.format("%08x%08x", AsyncRand(0x7fffffff), AsyncRand(0x7fffffff))
end

local function valid_id(id)
	return type(id) == "string" and #id >= 4 and #id <= 32 and id:match("^%w+$") ~= nil
end

local function clean_name(name)
	if type(name) ~= "string" then return "Player" end
	name = name:gsub("[%c<>]", ""):sub(1, 24)
	if name == "" then name = "Player" end
	return name
end

function Mp.HelloMsg()
	local sponsor = ""
	local gms = Mp.G("GetMissionSponsor")
	if gms and Mp.G("UIColony") then
		local ok, sp = pcall(gms)
		if ok and sp and sp.id then sponsor = tostring(sp.id) end
	end
	Mp.hello_sponsor = sponsor
	return { t = "hello", id = Mp.MyId(), name = clean_name(Mp.cfg and Mp.cfg.name), sponsor = sponsor }
end

function Mp.Host(port)
	Mp.Disconnect()
	port = tonumber(port) or Mp.DEFAULT_PORT
	local sock = MpSocket:new{ mp_role = "listener" }
	local err = sock:Listen("*", port)
	if err then
		Mp.Log("listen failed on port", port, err)
		pcall(sock.delete, sock)
		return err
	end
	Mp.listener = sock
	Mp.role = "host"
	Mp.connected = true
	Mp.Log("hosting on port", port)
end

function Mp.Join(host, port)
	Mp.Disconnect()
	port = tonumber(port) or Mp.DEFAULT_PORT
	local sock = MpSocket:new{ mp_role = "client" }
	Mp.client = sock
	Mp.role = "client"
	Mp.connected = false
	local err = sock:Connect(10000, host, port)
	if err then
		Mp.Log("connect failed:", err)
		Mp.Disconnect()
		return err
	end
	Mp.Log("connecting to", host, port)
end

function Mp.Disconnect()
	local socks = {}
	for sock in pairs(Mp.clients) do socks[#socks + 1] = sock end
	if Mp.listener then socks[#socks + 1] = Mp.listener end
	if Mp.client then socks[#socks + 1] = Mp.client end
	Mp.clients = {}
	Mp.listener = false
	Mp.client = false
	Mp.role = false
	Mp.connected = false
	for _, sock in ipairs(socks) do Mp.CloseSocket(sock) end
	for _, peer in pairs(Mp.peers) do peer.online = false end
end

-- Send a message to one peer (to = peer id) or to everybody (to = nil).
function Mp.Send(msg, to)
	if not Mp.role then return end
	msg.from = Mp.MyId()
	msg.to = to
	if Mp.role == "client" then
		if Mp.connected then Mp.SendRaw(Mp.client, msg) end
	else
		for sock in pairs(Mp.clients) do
			if sock.mp_peer and (not to or to == sock.mp_peer) then
				Mp.SendRaw(sock, msg)
			end
		end
	end
end

function Mp.OnSocketConnect(sock, err, host, port)
	if sock.mp_role == "client" then
		if sock ~= Mp.client then return end
		if err then
			Mp.Log("could not connect:", err)
			Mp.Disconnect()
			Mp.Notify("Multiplayer", "Could not connect to the host.")
			return
		end
		Mp.connected = true
		Mp.Log("connected to host")
		Mp.SendRaw(sock, Mp.HelloMsg())
	elseif sock.mp_role == "accepted" then
		if Mp.role ~= "host" then
			Mp.CloseSocket(sock)
			return
		end
		local n = 0
		for _ in pairs(Mp.clients) do n = n + 1 end
		if n >= Mp.MAX_CLIENTS then
			Mp.Log("rejecting connection, session full")
			Mp.CloseSocket(sock)
			return
		end
		Mp.clients[sock] = true
		Mp.Log("incoming connection from", tostring(host))
	end
end

function Mp.OnSocketClosed(sock, reason)
	if sock.mp_role == "client" then
		if sock == Mp.client then
			Mp.Log("disconnected from host:", tostring(reason))
			Mp.client = false
			Mp.role = false
			Mp.connected = false
			for _, peer in pairs(Mp.peers) do peer.online = false end
			Mp.Notify("Multiplayer", "Disconnected from the host.")
		end
	elseif sock.mp_role == "accepted" then
		if Mp.clients[sock] then
			Mp.clients[sock] = nil
			local id = sock.mp_peer
			if id then
				Mp.Log("peer left:", id)
				local bye = { t = "bye", id = id }
				Mp.inbox[#Mp.inbox + 1] = bye
				for other in pairs(Mp.clients) do
					if other.mp_peer then Mp.SendRaw(other, bye) end
				end
			end
		end
	end
end

function Mp.OnLine(sock, line)
	local msg = Mp.Decode(line)
	if not msg then return end
	local me = Mp.MyId()

	if sock.mp_role == "client" then
		if msg.t == "dup" then
			-- two games sharing one config file (same PC): use a throwaway id
			Mp.session_id = Mp.NewId()
			Mp.SendRaw(sock, Mp.HelloMsg())
			return
		end
		if msg.from == me then return end
		if msg.to == nil or msg.to == me then
			Mp.inbox[#Mp.inbox + 1] = msg
		end
		return
	end

	if sock.mp_role ~= "accepted" or not Mp.clients[sock] then return end

	if msg.t == "hello" then
		if not valid_id(msg.id) then
			Mp.CloseSocket(sock)
			return
		end
		local taken = msg.id == me
		for other in pairs(Mp.clients) do
			if other ~= sock and other.mp_peer == msg.id then taken = true end
		end
		if taken then
			Mp.SendRaw(sock, { t = "dup" })
			return
		end
		local first = not sock.mp_peer
		sock.mp_peer = msg.id
		msg.from = msg.id
		msg.to = nil
		msg.name = clean_name(msg.name)
		sock.mp_hello = msg
		if first then
			-- tell the newcomer who is already here
			Mp.SendRaw(sock, Mp.HelloMsg())
			for other in pairs(Mp.clients) do
				if other ~= sock and other.mp_hello then Mp.SendRaw(sock, other.mp_hello) end
			end
		end
		for other in pairs(Mp.clients) do
			if other ~= sock and other.mp_peer then Mp.SendRaw(other, msg) end
		end
		Mp.inbox[#Mp.inbox + 1] = msg
		return
	end

	if not sock.mp_peer then return end
	if msg.t == "bye" or msg.t == "dup" then return end  -- host-originated only
	msg.from = sock.mp_peer   -- never trust a client-supplied sender
	if msg.to ~= nil and type(msg.to) ~= "string" then return end
	if msg.to ~= me then
		for other in pairs(Mp.clients) do
			if other ~= sock and other.mp_peer and (msg.to == nil or msg.to == other.mp_peer) then
				Mp.SendRaw(other, msg)
			end
		end
	end
	if msg.to == nil or msg.to == me then
		Mp.inbox[#Mp.inbox + 1] = msg
	end
end
