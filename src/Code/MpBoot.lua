-- P2P multiplayer: loader. Loads the real files from <pack>/Mp/ one by one so
-- that a broken file is reported instead of failing silently.
-- Everything logged also goes to  %AppData%\Surviving Mars\multiplayer.log
-- (the game's own log is only written to disk when the game exits).

local lines = rawget(_G, "MpBootLines") or {}
rawset(_G, "MpBootLines", lines)

local function dbg(line)
	pcall(DebugPrint, line .. "\n")
end

local function log_line(line)
	lines[#lines + 1] = tostring(line)
	if #lines > 400 then table.remove(lines, 1) end
	dbg(line)
	rawset(_G, "MpBootDirty", true)
end
rawset(_G, "MpBootLog", log_line)

-- flush the lines to a file from a thread (file functions need one)
if not rawget(_G, "MpBootFlusher") then
	local ok, thread = pcall(function()
		return CreateRealTimeThread(function()
			local reported
			while true do
				Sleep(2000)
				if rawget(_G, "MpBootDirty") then
					rawset(_G, "MpBootDirty", false)
					local all = rawget(_G, "MpBootLines") or {}
					-- one file per player name and role, so two games on one PC do not overwrite each other
					local mp = rawget(_G, "Mp")
					local who = mp and mp.cfg and tostring(mp.cfg.name):gsub("[^%w]", "") or ""
					local role = mp and mp.role and ("-" .. tostring(mp.role)) or ""
					local file = "AppData/multiplayer" .. (who ~= "" and ("-" .. who) or "") .. role .. ".log"
					local ok2, err = pcall(AsyncStringToFile, file, table.concat(all, "\r\n") .. "\r\n")
					if (not ok2 or err) and not reported then
						reported = true
						dbg("[MP] log file write failed: " .. tostring(ok2) .. " " .. tostring(err))
					end
				end
			end
		end)
	end)
	rawset(_G, "MpBootFlusher", ok and thread or false)
	if not ok then dbg("[MP] boot: no flusher thread: " .. tostring(thread)) end
end

local FILES = { "Mp1Net.lua", "Mp2Rivals.lua", "Mp3Events.lua", "Mp4UI.lua" }

local folder
local ok, err = pcall(function()
	for _, f in ipairs(rawget(_G, "DlcFolders") or {}) do
		if io.exists(f .. "/Mp/" .. FILES[1]) then folder = f end
	end
end)
log_line("[MP] boot: folder " .. tostring(folder) .. (ok and "" or (" (error: " .. tostring(err) .. ")")))

if folder then
	for _, name in ipairs(FILES) do
		local path = folder .. "/Mp/" .. name
		local ok1, chunk, lerr = pcall(loadfile, path)
		if not ok1 or type(chunk) ~= "function" then
			log_line("[MP] boot: cannot load " .. name .. ": " .. tostring(ok1 and lerr or chunk))
		else
			local ok2, rerr = pcall(chunk)
			log_line("[MP] boot: " .. name .. (ok2 and " ok" or (" FAILED: " .. tostring(rerr))))
		end
	end
end
