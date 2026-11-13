local name = "P2P Multiplayer"
return {
	name = "multiplayer",
	display_name = rawget(_G, "Untranslated") and Untranslated(name) or name,
	enabled = true,
	-- required: the DLC loader drops any pack that does not declare this
	required_lua_revision = 1011140,
}
