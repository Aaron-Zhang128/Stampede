--[[
	RagdollUtil — NON-lethal, recoverable ragdoll (shared: runs on client OR server).

	RagdollService.launch() is the LETHAL "bull connects" ragdoll: it DESTROYS the
	Motor6Ds and kills the humanoid. This is the opposite — a knockdown you get back
	UP from. It DISABLES the motors (keeps them) and hangs a loose BallSocketConstraint
	in each joint's place so the rig flops, then reverses it on recover().

	Keeping the motors matters: the character stays ONE assembly, so a player can
	ragdoll their OWN character on their OWN client without losing network ownership.
	(Destroying the motors splits the rig into ~15 fresh assemblies that drop the
	"player owns their character" ownership — the exact failure documented in
	RagdollService's header, which is why THAT path is server-authoritative.) The
	same code runs on a server-owned bot rig.

		RagdollUtil.ragdoll(character, impulse?)  -- flop; optional Vector3 launch velocity
		RagdollUtil.recover(character)            -- stand back up
		RagdollUtil.isRagdolled(character)        -- bool

	All idempotent + pcall-guarded: safe to double-call, and safe if the character
	dies / despawns mid-ragdoll (a pending recover then just no-ops).
]]

local RagdollUtil = {}

local SOCKET = "RagdollSocket"
local ATTACH0 = "RagdollAtt0"
local ATTACH1 = "RagdollAtt1"

function RagdollUtil.isRagdolled(character: Model?): boolean
	return character ~= nil and character:GetAttribute("Ragdolled") == true
end

-- Flop the rig. `impulse` (optional) is a world velocity written to the root so the
-- body gets knocked in a direction as it goes down.
function RagdollUtil.ragdoll(character: Model?, impulse: Vector3?)
	if not character or not character.Parent then
		return
	end
	if character:GetAttribute("Ragdolled") == true then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root then
		return
	end
	character:SetAttribute("Ragdolled", true)

	humanoid.AutoRotate = false
	humanoid.PlatformStand = true
	pcall(function()
		humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	end)

	-- Free every joint: disable the Motor6D (kept, so recover() can re-enable it)
	-- and hang a loose BallSocketConstraint in its place so the limb flops.
	for _, motor in character:GetDescendants() do
		if motor:IsA("Motor6D") and motor.Part0 and motor.Part1 and motor.Enabled then
			local a0 = Instance.new("Attachment")
			a0.Name = ATTACH0
			a0.CFrame = motor.C0
			a0.Parent = motor.Part0
			local a1 = Instance.new("Attachment")
			a1.Name = ATTACH1
			a1.CFrame = motor.C1
			a1.Parent = motor.Part1
			local socket = Instance.new("BallSocketConstraint")
			socket.Name = SOCKET
			socket.Attachment0 = a0
			socket.Attachment1 = a1
			socket.LimitsEnabled = true
			socket.TwistLimitsEnabled = true
			socket.Parent = motor.Part0
			motor.Enabled = false
		end
	end

	-- Limbs collide so the body rests on the ground; the invisible root box would
	-- snag, so leave it pass-through. Originals stashed to restore on recover().
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
			part:SetAttribute("RagdollWasCanCollide", part.CanCollide)
			part.CanCollide = true
		end
	end

	if impulse then
		root.AssemblyLinearVelocity = impulse
	end
end

-- Stand back up: drop the ragdoll constraints, re-enable the motors, restore the
-- humanoid so it walks again.
function RagdollUtil.recover(character: Model?)
	if not character or character:GetAttribute("Ragdolled") ~= true then
		return
	end
	character:SetAttribute("Ragdolled", nil)

	for _, inst in character:GetDescendants() do
		if inst.Name == SOCKET or inst.Name == ATTACH0 or inst.Name == ATTACH1 then
			inst:Destroy()
		elseif inst:IsA("Motor6D") and not inst.Enabled then
			inst.Enabled = true
		end
	end

	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") then
			local was = part:GetAttribute("RagdollWasCanCollide")
			if was ~= nil then
				part.CanCollide = was
				part:SetAttribute("RagdollWasCanCollide", nil)
			end
		end
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.PlatformStand = false
		humanoid.AutoRotate = true
		if humanoid.Health > 0 then
			pcall(function()
				humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
			end)
		end
	end
end

return RagdollUtil
