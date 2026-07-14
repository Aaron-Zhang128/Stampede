-- NameTag: overhead @username display for every player
-- Plain white text with a black UIStroke, offset-sized BillboardGui above the head.

local Players = game:GetService("Players")

local function attachTag(player: Player, character: Model)
	local head = character:WaitForChild("Head", 10)
	if not head then return end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		-- hide the default Roblox name/health display
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end

	local existing = head:FindFirstChild("NameTag")
	if existing then existing:Destroy() end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "NameTag"
	billboard.Adornee = head
	-- Scale sizing (relative to the head, not fixed pixels): the tag shrinks with
	-- distance like a normal world billboard, so far-off players read as smaller.
	billboard.Size = UDim2.fromScale(5.25, 0.875)
	billboard.StudsOffset = Vector3.new(0, 2, 0)
	billboard.AlwaysOnTop = false
	billboard.MaxDistance = 120
	billboard.ResetOnSpawn = false
	-- full-brightness white regardless of scene lighting
	billboard.LightInfluence = 0

	local label = Instance.new("TextLabel")
	label.Name = "Username"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = "@" .. player.Name
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Font = Enum.Font.GothamMedium
	-- TextScaled so the glyphs scale down with the box as the tag recedes.
	label.TextScaled = true
	label.Parent = billboard

	-- Cap the font so short names don't blow up huge when the box is close.
	local sizeConstraint = Instance.new("UITextSizeConstraint")
	sizeConstraint.MaxTextSize = 17
	sizeConstraint.Parent = label

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Thickness = 1.5
	stroke.Parent = label

	billboard.Parent = head
end

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		attachTag(player, character)
	end)
	if player.Character then
		attachTag(player, player.Character)
	end
end)

for _, player in Players:GetPlayers() do
	player.CharacterAdded:Connect(function(character)
		attachTag(player, character)
	end)
	if player.Character then
		attachTag(player, player.Character)
	end
end
