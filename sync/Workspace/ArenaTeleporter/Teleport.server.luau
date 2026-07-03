local Players = game:GetService("Players")

local plate = script.Parent
-- Lands on the ArenaBase strip just outside the north guard wall, between two
-- column pads, facing the arena. Y=23 gives a small safe drop onto base top (19).
local DESTINATION = CFrame.lookAt(Vector3.new(195.8, 23, 159.6), Vector3.new(195.8, 23, 200))
local COOLDOWN = 2

local recent = {}

plate.Touched:Connect(function(hit)
	local character = hit and hit.Parent
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return end
	local now = os.clock()
	for model, t in pairs(recent) do
		if now - t > 30 or not model.Parent then recent[model] = nil end
	end
	if recent[character] and now - recent[character] < COOLDOWN then return end
	recent[character] = now
	character:PivotTo(DESTINATION)
end)
