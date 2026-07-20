-- Passive mobility abilities: Jump Higher and Double Jump.
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")
local Config = require(ReplicatedStorage.Bullrush.Config)
local player = Players.LocalPlayer
local humanoid: Humanoid? = nil
local baseJumpPower = 50
local baseJumpHeight = 7.2
local extraJumpAvailable = false
local jumpStarted = false
local usedDoubleJump = false
local function playDoubleJumpSound(root: BasePart)
	local group = SoundService:FindFirstChild("GameSFX")
	local template = group and group:FindFirstChild("Jump")
	if not (template and template:IsA("Sound")) then return end
	local sound = template:Clone()
	sound.Looped = false
	sound.TimePosition = 0
	sound.Parent = root
	sound:Play()
	Debris:AddItem(sound, 5)
end
local function equipped(key: string): boolean
	return player:GetAttribute("EquippedAbility") == key
		and (player:GetAttribute("InRound") == true or player:GetAttribute("InPractice") == true)
end
local function applyJumpBuff()
	if not humanoid then return end
	local mult = if equipped("JumpHigher") then Config.JUMP_HIGHER.MULT else 1
	humanoid.JumpPower = baseJumpPower * math.sqrt(mult)
	humanoid.JumpHeight = baseJumpHeight * mult
end
local function bindCharacter(character: Model)
	humanoid = character:WaitForChild("Humanoid") :: Humanoid
	baseJumpPower = humanoid.JumpPower
	baseJumpHeight = humanoid.JumpHeight
	extraJumpAvailable = false
	jumpStarted = false
	usedDoubleJump = false
	local boundHumanoid = humanoid
	humanoid.StateChanged:Connect(function(_, state)
		if humanoid ~= boundHumanoid then return end
		if state == Enum.HumanoidStateType.Landed or state == Enum.HumanoidStateType.Running then
			extraJumpAvailable = false
			jumpStarted = false
			usedDoubleJump = false
		elseif state == Enum.HumanoidStateType.Jumping and equipped("DoubleJump") and not jumpStarted then
			-- The normal first jump has begun; the next JumpRequest is the passive.
			jumpStarted = true
			extraJumpAvailable = true
		end
	end)
	applyJumpBuff()
end
local function handleJumpPress()
	local current = humanoid
	if not current or not equipped("DoubleJump") or not extraJumpAvailable or usedDoubleJump then return end
	if current.FloorMaterial ~= Enum.Material.Air then return end

	-- The second press works while rising OR falling. ChangeState alone can be
	-- ignored while already in Jumping, so author the upward velocity explicitly.
	extraJumpAvailable = false
	usedDoubleJump = true
	local character = current.Parent
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then return end
	local jumpVelocity = if current.UseJumpPower
		then current.JumpPower
		else math.sqrt(2 * workspace.Gravity * current.JumpHeight)
	local velocity = root.AssemblyLinearVelocity
	root.AssemblyLinearVelocity = Vector3.new(velocity.X, jumpVelocity, velocity.Z)
	current:ChangeState(Enum.HumanoidStateType.Jumping)
	playDoubleJumpSound(root)
end

-- JumpRequest is shared by Space, gamepad A, and Roblox's native mobile jump button.
UserInputService.JumpRequest:Connect(function()
	handleJumpPress()
end)
for _, attribute in { "EquippedAbility", "InRound", "InPractice" } do
	player:GetAttributeChangedSignal(attribute):Connect(function()
		if humanoid and not equipped("JumpHigher") then
			humanoid.JumpPower = baseJumpPower
			humanoid.JumpHeight = baseJumpHeight
		end
		extraJumpAvailable = false
		jumpStarted = false
		usedDoubleJump = false
		applyJumpBuff()
	end)
end
if player.Character then task.spawn(bindCharacter, player.Character) end
player.CharacterAdded:Connect(bindCharacter)
