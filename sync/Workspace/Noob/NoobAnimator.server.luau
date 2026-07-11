-- NoobAnimator: idle loop + constant greeter wave for the shop noob statue
local rig = script.Parent
local humanoid = rig:WaitForChild("Humanoid")
local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator")
animator.Parent = humanoid

-- Classic Roblox-owned R6 animations (playable in any game)
local IDLE_ID = "rbxassetid://180435571"
local WAVE_ID = "rbxassetid://128777973"

local function load(id, priority, looped)
	local anim = Instance.new("Animation")
	anim.AnimationId = id
	local track = animator:LoadAnimation(anim)
	track.Priority = priority
	track.Looped = looped
	return track
end

local idleTrack = load(IDLE_ID, Enum.AnimationPriority.Idle, true)
idleTrack:Play()

local waveTrack = load(WAVE_ID, Enum.AnimationPriority.Action, true)
waveTrack:Play()