-- PlayerCollision: disables player-to-player character collision.
-- Registers a "Players" collision group and assigns every character part to it,
-- so players pass through each other. Bulls, walls, and the floor still collide
-- (they stay in the Default group).

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")

local GROUP = "Players"

-- Register once; guard so a hot-reload / re-run doesn't error.
pcall(function()
	PhysicsService:RegisterCollisionGroup(GROUP)
end)
PhysicsService:CollisionGroupSetCollidable(GROUP, GROUP, false)

local function assign(part: Instance)
	if part:IsA("BasePart") then
		part.CollisionGroup = GROUP
	end
end

local function setupCharacter(character: Model)
	for _, part in character:GetDescendants() do
		assign(part)
	end
	-- Accessories / tools / ragdoll parts added after spawn join the group too.
	character.DescendantAdded:Connect(assign)
end

local function onPlayer(player: Player)
	player.CharacterAdded:Connect(setupCharacter)
	if player.Character then
		setupCharacter(player.Character)
	end
end

Players.PlayerAdded:Connect(onPlayer)
for _, player in Players:GetPlayers() do
	onPlayer(player)
end
