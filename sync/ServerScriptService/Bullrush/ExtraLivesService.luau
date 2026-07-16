--[[
	ExtraLivesService — extra-lives ability (PASSIVE).

	While a player carries this ability they hold EXTRA_LIVES.HEARTS lives, shown
	as a row of hearts over their head. A lethal hit SPENDS a heart and revives
	them (brief forcefield i-frames) instead of eliminating; only when the last
	heart is gone are they truly out. There's no input — this is a passive buff
	you grant, plus a consume() hook you call from the elimination path.

	WIRING (left to you):
	  * On round start (or on equip), call ExtraLivesService.grant(player) — or
	    grant(player, n) for a custom count. That paints the hearts and sets the
	    replicated "Lives" attribute.
	  * In your elimination path (RoundService.eliminate, or wherever a hit would
	    kill), call ExtraLivesService.consume(player) FIRST:
	        if ExtraLivesService.consume(player) then
	            -- survived: a heart was spent. Keep them alive / re-heal here.
	            return
	        end
	        -- no lives left: let the normal elimination run.
	    consume() returns true when a heart was spent, false on the last life.
	  * On round end / real elimination, call ExtraLivesService.clear(player).

	The hearts BillboardGui is built SERVER-side so every client sees it, and it
	re-paints on respawn (CharacterAdded) while lives remain.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Bullrush.Config)
local NotifyService = require(script.Parent.NotifyService)
local SoundService = game:GetService("SoundService")

-- Positional one-shot from the curated GameSFX library, parented to `at` so it
-- plays in 3D at the effect and every nearby client hears it (server-built, same
-- idiom as PushService.playImpactSound). Silent if the library sound is missing.
local function playSfxAt(name: string, at: BasePart?)
	if not at then
		return
	end
	local group = SoundService:FindFirstChild("GameSFX")
	local template = group and group:FindFirstChild(name)
	if not (template and template:IsA("Sound")) then
		return
	end
	local ok, sound = pcall(function()
		return template:Clone()
	end)
	if not ok or not sound then
		return
	end
	sound.Looped = false
	sound.RollOffMaxDistance = 100
	sound.Parent = at
	pcall(function()
		sound:Play()
	end)
	task.delay(6, function()
		if sound then
			sound:Destroy()
		end
	end)
end

local ExtraLivesService = {}

local CFG = Config.EXTRA_LIVES
local lives: { [Player]: number } = {}

-- (Re)build / refresh the overhead hearts on the player's Head. Sits just above
-- the @username nametag. Destroys itself once lives hit zero.
local function paintHearts(player: Player)
	local n = lives[player]
	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	if not head then
		return
	end

	local gui = head:FindFirstChild("ExtraLives")
	if not gui then
		if not n or n <= 0 then
			return
		end
		gui = Instance.new("BillboardGui")
		gui.Name = "ExtraLives"
		gui.Size = UDim2.fromOffset(34 * CFG.HEARTS, 32)
		gui.StudsOffsetWorldSpace = Vector3.new(0, 3.4, 0)
		gui.AlwaysOnTop = true
		gui.MaxDistance = 90
		gui.Parent = head

		-- A row of heart IMAGES (CFG.HEART_IMAGE, the uploaded art): lit for a life in
		-- hand, dimmed for a spent one.
		local row = Instance.new("Frame")
		row.Name = "Row"
		row.BackgroundTransparency = 1
		row.Size = UDim2.fromScale(1, 1)
		row.Parent = gui
		local layout = Instance.new("UIListLayout")
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
		layout.Padding = UDim.new(0, 2)
		layout.Parent = row

		for i = 1, CFG.HEARTS do
			local heart = Instance.new("ImageLabel")
			heart.Name = "Heart" .. i
			heart.BackgroundTransparency = 1
			heart.Size = UDim2.fromScale(1, 1)
			heart.SizeConstraint = Enum.SizeConstraint.RelativeYY -- square, sized off the row height
			heart.ScaleType = Enum.ScaleType.Fit
			heart.Image = CFG.HEART_IMAGE
			heart.LayoutOrder = i
			heart.Parent = row
		end
	end

	if not n or n <= 0 then
		gui:Destroy()
		return
	end

	-- Fill state: hearts 1..n are lit, the rest dimmed (spent).
	local row = gui:FindFirstChild("Row")
	if row then
		for i = 1, CFG.HEARTS do
			local heart = row:FindFirstChild("Heart" .. i)
			if heart and heart:IsA("ImageLabel") then
				local filled = i <= n
				heart.ImageColor3 = filled and Color3.new(1, 1, 1) or Color3.fromRGB(70, 70, 78)
				heart.ImageTransparency = filled and 0 or 0.4
			end
		end
	end
end

-- Grant (or reset) a player's extra lives and paint the hearts. Call at round
-- start / on equip.
function ExtraLivesService.grant(player: Player, count: number?)
	local n = count or CFG.HEARTS
	lives[player] = n
	player:SetAttribute("Lives", n)
	paintHearts(player)
end

function ExtraLivesService.getLives(player: Player): number
	return lives[player] or 0
end

-- Spend a life. Returns true if a heart was spent and the player should stay in
-- (revive them), false if that was their last life (let elimination proceed).
-- Actually keeping the player alive / re-healing is the CALLER's job — this only
-- spends the heart and plays the revive shimmer.
function ExtraLivesService.consume(player: Player): boolean
	local n = lives[player]
	if not n or n <= 1 then
		-- Last life (or none): out for real. Zero it out + drop the hearts.
		if n and n > 0 then
			lives[player] = 0
			player:SetAttribute("Lives", 0)
			paintHearts(player)
		end
		return false
	end

	n -= 1
	lives[player] = n
	player:SetAttribute("Lives", n)
	paintHearts(player)

	-- Revive feedback: a brief forcefield shimmer (i-frames are visual only here;
	-- gate real damage in your caller if you want true invulnerability).
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if character and humanoid and humanoid.Health > 0 then
		local ff = Instance.new("ForceField")
		ff.Visible = true
		ff.Parent = character
		Debris:AddItem(ff, CFG.REVIVE_IFRAMES)
	end
	playSfxAt("Correct", character and character:FindFirstChild("HumanoidRootPart"))
	NotifyService.send(player, ("Extra life! %d left"):format(n), "green", 2)
	return true
end

-- Drop a player's lives + hearts entirely (round end / real elimination).
function ExtraLivesService.clear(player: Player)
	lives[player] = nil
	player:SetAttribute("Lives", nil)
	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	local gui = head and head:FindFirstChild("ExtraLives")
	if gui then
		gui:Destroy()
	end
end

function ExtraLivesService.init()
	-- Respawn: repaint the hearts if the player still has lives (the old
	-- BillboardGui died with the previous character).
	local function hookCharacter(player: Player)
		player.CharacterAdded:Connect(function()
			task.wait(0.2) -- let Head + the nametag settle first
			if (lives[player] or 0) > 0 then
				paintHearts(player)
			end
		end)
	end
	for _, player in Players:GetPlayers() do
		hookCharacter(player)
	end
	Players.PlayerAdded:Connect(hookCharacter)

	Players.PlayerRemoving:Connect(function(player)
		lives[player] = nil
	end)
end

return ExtraLivesService
