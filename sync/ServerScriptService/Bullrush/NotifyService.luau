--[[
	NotifyService - pushes cards onto the client's notification stack
	(top-right of the HUD, built in BullrushClient).

	Four styles:
	  "red"   - red gradient card, danger / bad news
	  "green" - green gradient card, rewards / good news
	  "white" - plain white text on a neutral card, general info
	  "chat"  - no card at all: the client prints it into the chat window
	            as a system line ("[System]: <text>"); an optional `rarity`
	            (BullCatalog.Rarities key) tints the line in that rarity's
	            shared text gradient

	send() accepts round participants directly and silently skips bot
	proxies (see AIService) - only real Players own a PlayerGui.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local notifyRemote = ReplicatedStorage.Bullrush.Remotes.Notify

export type Style = "red" | "green" | "white" | "chat"

local NotifyService = {}

-- One player. duration in seconds (client defaults it when nil).
function NotifyService.send(player, text: string, style: Style?, duration: number?, rarity: string?)
	if typeof(player) == "Instance" and player:IsA("Player") then
		notifyRemote:FireClient(player, text, style or "white", duration, rarity)
	end
end

-- Everyone currently in the server.
function NotifyService.broadcast(text: string, style: Style?, duration: number?, rarity: string?)
	notifyRemote:FireAllClients(text, style or "white", duration, rarity)
end

return NotifyService
