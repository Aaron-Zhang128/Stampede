--[[
	CelestialBull lobby display - buy prompt.

	The floating Celestial Bull by the practice pad wears the Star mutation
	aura and carries a "Buy" ProximityPrompt. Triggering it prompts the
	Celestial Bull game pass (Config.PASSES.STRAWBERRY_ELEPHANT - the pass's
	PASS_BENEFITS row in MonetizationService grants the STRAWBERRY bull on
	purchase, so there is nothing to grant here). Players who already have the
	bull (pass OR a lucky roll - it's rollable too) get a notify instead of a
	prompt, so nobody re-buys a bull they own.

	The hover animation + hiding the prompt for owners is client-side
	(StarterPlayerScripts.CelestialBullDisplay); this script is the server
	half only.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local MonetizationService = require(ServerScriptService.Bullrush.MonetizationService)
local NotifyService = require(ServerScriptService.Bullrush.NotifyService)
local DataHandler = require(ServerScriptService.UserData.DataHandler)

local prompt = script.Parent:WaitForChild("Root"):WaitForChild("BuyPrompt")

prompt.Triggered:Connect(function(player)
	local ownsPass = MonetizationService.ownsPass(player, "STRAWBERRY_ELEPHANT")
	local ok, hasBull = pcall(DataHandler.HasBull, player, "STRAWBERRY")
	if ownsPass or (ok and hasBull) then
		NotifyService.send(player, "Already yours!", "green", 3)
		return
	end
	MonetizationService.promptPass(player, "STRAWBERRY_ELEPHANT")
end)