--[[
	LavaService - the LavaFloor sits below the tile grid with CanCollide on, so
	a player who falls off a sunken tile lands on it instead of dropping into
	the void. Touching it is instantly fatal: the moment any Humanoid's part
	hits the lava, that Humanoid dies. Works for players and AIService bots.

	The debounce set guards one kill per Humanoid so a corpse resting on the
	lava does not re-fire on every physics touch.
]]

local Workspace = game:GetService("Workspace")

local arena = Workspace:WaitForChild("BullrushArena")
local lava = arena:WaitForChild("LavaFloor")
lava.CanCollide = true -- guarantee they land on it, not through it
lava.CanTouch = true -- guarantee Touched fires (part ships with CanTouch off)

local burning: { [Humanoid]: boolean } = {} -- one kill per humanoid

lava.Touched:Connect(function(hit: BasePart)
	local character = hit.Parent
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 and not burning[humanoid] then
		burning[humanoid] = true
		humanoid.Died:Once(function()
			burning[humanoid] = nil
		end)
		humanoid.Health = 0
	end
end)
