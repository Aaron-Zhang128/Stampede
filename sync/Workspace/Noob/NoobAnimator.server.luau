-- NoobAnimator: guarantees the shop noob statue has a replicated Animator.
-- Playback happens CLIENT-SIDE (BullrushClient) because a server-side
-- AnimationTrack:Play() only replicates to players present at that instant --
-- live players all join after this script runs, so they saw a frozen statue.
local rig = script.Parent
local humanoid = rig:WaitForChild("Humanoid")
if not humanoid:FindFirstChildOfClass("Animator") then
	Instance.new("Animator").Parent = humanoid
end
