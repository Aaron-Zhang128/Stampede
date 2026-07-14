--[[
	Main UI controller — ALL client UI code lives in this one script (Gui > Main).
	  1. Frame manager  — open/close windows with a pop tween, one open at a time
	  2. HUD hookup     — SideUI buttons open frames; deals/cash "+"/quick buttons deep-link the Store
	  3. Button feel    — hover grow + press squash on every button
	  4. Ambient life   — floating lucky blocks, breathing starbursts, swaying SALE!/header icons, pulsing "!"
	  5. Marquees       — lucky block cards scroll their possible items
	  6. Notifications  — server-pushed red/green/white info cards (Remotes.Notify);
	                      plus the elimination side feed on the right edge — head
	                      shot + red ELIMINATED per victim (Remotes.Eliminated)
	  7. HUD counters   — Cash mirrors leaderstats.Money, Speed mirrors Humanoid.WalkSpeed
	  8. Round summary  — Frames.Summary auto-opens once you're back in the lobby
	                      with the winner's portrait, your placement, and your
	                      itemized Money payout (Remotes.RoundSummary);
	                      "2x Rewards?" prompts a dev product
	  9. Revenge lane controls — ◀ SEND BULL ▶ panel shown while the overhead
	                      bull-cam is up; talks to BullrushClient over the
	                      RevengeViewBridge (same bridge as "Become a Bull")
	  10. Fortune wheel — Frames.Spinner runs the kit's 6-slice wheel against
	                      SpinService (server-committed spins, SpinAck replay)
	  11. Bull roll     — code-built gacha carousel (BullRoll/BullAck); results
	                      land in the same inventory attributes section 12 reads
	  12. Bull index    — Frames.Index reworked into the bull INVENTORY: rarity
	                      tabs, ViewportFrame previews of the real bull models,
	                      click an owned card to equip it (BullEquip)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local SocialService = game:GetService("SocialService")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")

local player = Players.LocalPlayer
local gui = script.Parent
local SideUI = gui:WaitForChild("SideUI")
local Frames = gui:WaitForChild("Frames")
local Store = Frames:WaitForChild("Store")
local storeContainer = Store:WaitForChild("StoreFrame"):WaitForChild("Container")

local function ensureScale(obj)
	local s = obj:FindFirstChildOfClass("UIScale")
	if not s then
		s = Instance.new("UIScale")
		s.Parent = obj
	end
	return s
end

local function tween(obj, info, props)
	local tw = TweenService:Create(obj, info, props)
	tw:Play()
	return tw
end

-- assigned in section 6; forward-declared so earlier handlers (Invite) can show cards
local pushNotif

---------------------------------------------------------------- 1) frame manager
local POP_IN = TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local POP_OUT = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local currentFrame = nil
local tokens = {}

local function bump(frame)
	tokens[frame] = (tokens[frame] or 0) + 1
	return tokens[frame]
end

local function closeFrame(frame)
	if not frame or not frame.Visible then
		return
	end
	local token = bump(frame)
	if currentFrame == frame then
		currentFrame = nil
	end
	local scale = ensureScale(frame)
	tween(scale, POP_OUT, { Scale = 0.75 }).Completed:Once(function()
		if tokens[frame] == token then
			frame.Visible = false
			scale.Scale = 1
		end
	end)
end

local function openFrame(frame)
	if currentFrame == frame then
		closeFrame(frame)
		return
	end
	if currentFrame then
		closeFrame(currentFrame)
	end
	bump(frame)
	currentFrame = frame
	local scale = ensureScale(frame)
	scale.Scale = 0.7
	frame.Visible = true
	tween(scale, POP_IN, { Scale = 1 })
end

-- The container itself must be visible or every window opens invisibly (its
-- children toggle, it doesn't) — force it in case an Explorer click hid it.
Frames.Visible = true
-- start hidden + wire every Close button inside each window
for _, frame in ipairs(Frames:GetChildren()) do
	if frame:IsA("GuiObject") then
		frame.Visible = false
		for _, d in ipairs(frame:GetDescendants()) do
			if d:IsA("GuiButton") and d.Name == "Close" then
				d.Active = true -- the kit ships some closes inert (Summary's was Active=false)
				d.Activated:Connect(function()
					closeFrame(frame)
				end)
			end
		end
	end
end

---------------------------------------------------------------- 1b) lobby shop door
-- the lobby Shop stall carries a Custom-styled ProximityPrompt (dressed by
-- ExpressivePrompts, which PushClient installs). Triggering it opens the Shop1
-- window. Scan descendants (retrying while the map streams in) so a future
-- reparent of the stall can't silently break the door, exactly like the wheel.
do
	local Shop1 = Frames:FindFirstChild("Shop1")
	if Shop1 then
		task.spawn(function()
			local prompt
			local deadline = os.clock() + 60
			repeat
				for _, d in ipairs(workspace:GetDescendants()) do
					if d:IsA("ProximityPrompt") and d.Name == "ShopPrompt" then
						prompt = d
						break
					end
				end
				if not prompt then
					task.wait(0.3)
				end
			until prompt or os.clock() >= deadline
			if prompt then
				prompt.Triggered:Connect(function(who)
					if who == player then
						openFrame(Shop1)
					end
				end)
			end
		end)
	end
end

---------------------------------------------------------------- 2) HUD -> frames
local function scrollStoreTo(sectionName)
	local targetY = 0
	local section = sectionName and storeContainer:FindFirstChild(sectionName)
	if section then
		targetY = (section.AbsolutePosition.Y - storeContainer.AbsolutePosition.Y) + storeContainer.CanvasPosition.Y - 6
	end
	local maxY = math.max(0, storeContainer.AbsoluteCanvasSize.Y - storeContainer.AbsoluteWindowSize.Y)
	targetY = math.clamp(targetY, 0, maxY)
	tween(storeContainer, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		CanvasPosition = Vector2.new(0, targetY),
	})
end

local function openStoreAt(sectionName)
	if currentFrame ~= Store then
		openFrame(Store)
	end
	task.defer(function()
		RunService.Heartbeat:Wait() -- let the layout resolve before measuring
		scrollStoreTo(sectionName)
	end)
end

local handled = {}
local function wire(btn, fn)
	if btn and btn:IsA("GuiButton") then
		handled[btn] = true
		btn.Activated:Connect(fn)
	end
end

-- deep links first (these share names like "Buy" with plain frame-openers)
local counters = SideUI:FindFirstChild("Counters")
if counters then
	local cash = counters:FindFirstChild("Cash")
	local speed = counters:FindFirstChild("Speed")
	wire(cash and cash:FindFirstChild("Buy"), function()
		openStoreAt("Cash")
	end)
	wire(speed and speed:FindFirstChild("Buy"), function()
		openStoreAt("Gamepasses")
	end)
end

-- Deal-pack buttons (Starter/PRO) are retired from the HUD; the push button
-- takes their right-edge spot. Wiring stays in case they come back.
local right = SideUI:FindFirstChild("Right")
local rightButtons = right and right:FindFirstChild("Buttons")
if rightButtons then
	wire(rightButtons:FindFirstChild("Deal1"), function()
		openStoreAt("StarterPack")
	end)
	wire(rightButtons:FindFirstChild("Deal2"), function()
		openStoreAt("PROPack")
	end)
end
if right then
	right.Visible = false
end

local quickButtons = Store:FindFirstChild("QuickButtons")
if quickButtons then
	wire(quickButtons:FindFirstChild("Limiteds"), function()
		scrollStoreTo(nil) -- top of the store
	end)
	wire(quickButtons:FindFirstChild("Limiteds1"), function()
		scrollStoreTo("LuckyBlocks")
	end)
end

-- The UI kit ships its "Off" state gradients grey; toggles that want a red
-- stop-state retint them to this ramp (mirrors the green "On" ramp, light
-- top -> deep bottom). Used by the bull cam button and the AFK toggle.
local RED_OFF = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 120, 104)),
	ColorSequenceKeypoint.new(0.1, Color3.fromRGB(255, 120, 104)),
	ColorSequenceKeypoint.new(0.9, Color3.fromRGB(216, 12, 12)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(204, 8, 8)),
})

-- "Become a Bull" button (former "Slow" toggle): enters/exits the revenge
-- bull-cam. BullrushClient owns the camera + eligibility rules and exposes a
-- client-local bridge (ReplicatedStorage.RevengeViewBridge BindableEvent):
-- Fire() toggles the cam; its "Eligible"/"CanThrow"/"Viewing" attributes
-- drive the button's visibility and label. Since the 2026-07-13 widening
-- EVERY round spectator may also throw, so CanThrow tracks Eligible and the
-- label reads "Become a Bull"; the "Bull Cam" fallback stays for any future
-- watch-only split.
-- The kit's On/Off gradient pair doubles as the state look (On = ready to
-- enter, Off = currently viewing, retinted red so "Exit Cam" reads as a
-- stop control).
local function wireBullCamButton(btn)
	handled[btn] = true
	btn.Visible = false -- only round spectators of an ACTIVE round see it
	for _, d in ipairs(btn:GetDescendants()) do
		if d:IsA("UIGradient") and d.Name == "Off" then
			d.Color = RED_OFF
		end
	end
	local function apply(viewing, canThrow)
		local label = btn:FindFirstChild("Name")
		if label and label:IsA("TextLabel") then
			label.Text = if viewing then "Exit Cam"
				elseif canThrow then "Become a Bull"
				else "Bull Cam"
		end
		for _, d in ipairs(btn:GetDescendants()) do
			if d:IsA("UIGradient") or d:IsA("UIStroke") then
				if d.Name == "On" then
					d.Enabled = not viewing
				elseif d.Name == "Off" then
					d.Enabled = viewing
				end
			end
		end
	end
	apply(false, false)
	task.spawn(function()
		local bridge = ReplicatedStorage:WaitForChild("RevengeViewBridge", 30)
		if not (bridge and bridge:IsA("BindableEvent")) then
			return -- BullrushClient absent; the button just stays hidden
		end
		local function refresh()
			btn.Visible = bridge:GetAttribute("Eligible") == true
			apply(bridge:GetAttribute("Viewing") == true, bridge:GetAttribute("CanThrow") == true)
		end
		bridge:GetAttributeChangedSignal("Eligible"):Connect(refresh)
		bridge:GetAttributeChangedSignal("CanThrow"):Connect(refresh)
		bridge:GetAttributeChangedSignal("Viewing"):Connect(refresh)
		refresh()
		btn.Activated:Connect(function()
			bridge:Fire()
		end)
		-- Attention pulse: while the button is up and the player is NOT already
		-- in the cam, it breathes ±6% so a freshly-eliminated player notices
		-- their way into revenge. Manual RenderStepped math like every looped
		-- animation here (Run-mode tween freeze); it drives Size, not the
		-- UIScale, so section 3's hover/press tweens ride on top untouched.
		local baseSize = btn.Size
		RunService.RenderStepped:Connect(function()
			if btn.Visible and bridge:GetAttribute("Viewing") ~= true then
				local k = 1 + 0.06 * math.sin(os.clock() * 4)
				btn.Size = UDim2.new(
					baseSize.X.Scale * k, baseSize.X.Offset * k,
					baseSize.Y.Scale * k, baseSize.Y.Offset * k)
			elseif btn.Size ~= baseSize then
				btn.Size = baseSize -- parked at rest while hidden / in the cam
			end
		end)
	end)
end

-- generic name -> frame mapping for every HUD layout variant
local FRAME_MAP = {
	Store = "Store",
	Gifts = "Daily",
	Index = "Index",
	Rebirth = "Rebirth1",
	Buy = "StockShop",
	Sell = "Sell",
	Config = "Config/Settings",
}

for _, d in ipairs(SideUI:GetDescendants()) do
	if d:IsA("GuiButton") and not handled[d] then
		if d.Name == "Button1" then
			wireBullCamButton(d)
		elseif d.Name == "Invite" then
			handled[d] = true
			d.Activated:Connect(function()
				-- Roblox invite flow: gate on CanSendGameInviteAsync, then open
				-- the platform's invite-friends dialog. Both throw where social
				-- features are unavailable (Studio, unpublished places, guests),
				-- so fall back to a card instead of failing silently.
				local ok, canSend = pcall(function()
					return SocialService:CanSendGameInviteAsync(player)
				end)
				if ok and canSend then
					local inviteOptions
					pcall(function()
						inviteOptions = Instance.new("ExperienceInviteOptions")
						inviteOptions.PromptMessage = "Rally your friends!"
					end)
					local prompted = pcall(function()
						SocialService:PromptGameInvite(player, inviteOptions)
					end)
					if prompted then
						return
					end
				end
				if pushNotif then
					pushNotif("Invites not available", "red", 3)
				end
			end)
		elseif d.Name == "Gifts" then
			-- No Daily HUD button (user request 2026-07-13): the daily reward
			-- system stays live — the window still auto-opens on join when a
			-- reward is ready (section 13) — but the left-side button is gone.
			handled[d] = true
			d.Visible = false
		else
			local target = FRAME_MAP[d.Name]
			local frame = target and Frames:FindFirstChild(target)
			if frame then
				handled[d] = true
				d.Activated:Connect(function()
					openFrame(frame)
				end)
			end
		end
	end
end

---------------------------------------------------------------- 3) button feel
local HOVER_TI = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_TI = TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Shared UI sounds: clone the library's "Click" tick (SoundService.GameSFX) per
-- event so rapid fires overlap cleanly, route it through the SFX mixer group,
-- and let Debris reap it. Missing/moderated sound -> silent no-op, never errors.
local sfxGroup = SoundService:FindFirstChild("GameSFX")
local clickTemplate = sfxGroup and sfxGroup:FindFirstChild("Click")
local function playUiSound(volume, pitch)
	if not clickTemplate then
		return
	end
	local ok, s = pcall(function()
		return clickTemplate:Clone()
	end)
	if not ok or not s then
		return
	end
	s.SoundGroup = sfxGroup
	s.Volume = volume
	s.PlaybackSpeed = pitch
	s.Parent = SoundService
	pcall(function()
		s:Play()
	end)
	Debris:AddItem(s, 2)
end
-- Click = full weight; hover = the same tick pitched up and much quieter, so it
-- reads as a light blip under the pointer rather than a second click.
local function playClick()
	playUiSound(1.6, 1)
end
local function playHover()
	playUiSound(0.9, 1.5)
end
-- One-shot from any named SFX-library template (same clone-route-reap idea as
-- playUiSound, but not locked to the Click tick). Used for the round-end reveal
-- stings. Missing/moderated template -> silent no-op, never errors.
local function playSfx(name, volume, pitch, lifetime)
	local template = sfxGroup and sfxGroup:FindFirstChild(name)
	if not template then
		return
	end
	local ok, s = pcall(function()
		return template:Clone()
	end)
	if not ok or not s then
		return
	end
	s.SoundGroup = sfxGroup
	if volume then
		s.Volume = volume
	end
	if pitch then
		s.PlaybackSpeed = pitch
	end
	s.Parent = SoundService
	pcall(function()
		s:Play()
	end)
	Debris:AddItem(s, lifetime or 6)
end

---------------------------------------------------------------- 2c) HUD push button
-- Combat shove button. Cloned from the Index side button (so it inherits the
-- HUD kit look) and dropped on the right edge, in the spot the (now hidden)
-- deal-pack buttons used to hold. Its icon is swapped to a boxing glove and
-- the decorative ring recolored green.
--
-- All the gameplay — targeting the NEAREST player, the red target aura, F /
-- gamepad input, cooldown timing — lives in StarterPlayerScripts.PushClient;
-- this button only presents state and forwards taps (the one-LocalScript UI
-- rule). The two meet at ReplicatedStorage.PushBridge, created by PushClient:
--     a tap        -> PushBridge:Fire()
--     its attributes drive the look:
--        Enabled          -> button shown at all (you're alive; lobby included)
--        HasTarget        -> bright (someone in range this round) vs dim (nobody)
--        CooldownDuration -> the drain sweep's length
--        ReadyAt          -> os.clock() the cooldown lapses; drives the sweep
do
	local GLOVE_IMAGE = "rbxassetid://125148837464247"
	local RING_GREEN = Color3.fromRGB(85, 255, 127) -- same green as the self-aura

	-- The HUD ships in a few layout variants (Lef1 / Left2 / Left3); grab the
	-- first Index button that exists as the clone template.
	local template
	for _, d in ipairs(SideUI:GetDescendants()) do
		if d.Name == "Index" and d:IsA("ImageButton") then
			template = d
			break
		end
	end

	if template then
		-- The push button is combat-critical, so it gets its own ScreenGui at
		-- the highest DisplayOrder in the place — above even NotifGui (10000),
		-- so notif cards and the elimination feed can never sit on top of it.
		-- Main resets on spawn but this gui doesn't, so drop the previous
		-- life's copy before making a fresh one (same dance as NotifGui).
		local oldPushGui = gui.Parent:FindFirstChild("PushGui")
		if oldPushGui then
			oldPushGui:Destroy()
		end
		local pushGui = Instance.new("ScreenGui")
		pushGui.Name = "PushGui"
		pushGui.DisplayOrder = 20000
		pushGui.ResetOnSpawn = false
		pushGui.IgnoreGuiInset = false
		pushGui.Parent = gui.Parent

		-- Square holder pinned to the right edge, mid-lower (clear of other HUD).
		local holder = Instance.new("Frame")
		holder.Name = "PushButton"
		holder.BackgroundTransparency = 1
		holder.AnchorPoint = Vector2.new(1, 0.5)
		holder.Position = UDim2.fromScale(0.985, 0.5)
		-- Both axes scaled: a zero-width Size collapses to 0x0 under the aspect
		-- constraint. The constraint then squares it off the height.
		holder.Size = UDim2.fromScale(0.15, 0.15)
		holder.Visible = false
		holder.Parent = pushGui

		local aspect = Instance.new("UIAspectRatioConstraint")
		aspect.AspectRatio = 1
		aspect.DominantAxis = Enum.DominantAxis.Height
		aspect.Parent = holder

		local btn = template:Clone()
		btn.Name = "Push"
		btn.AnchorPoint = Vector2.new(0.5, 0.5)
		btn.Position = UDim2.fromScale(0.5, 0.5)
		btn.Size = UDim2.fromScale(1, 1)
		btn.Visible = true
		btn.Active = true
		btn.Parent = holder

		-- Swap the glyph for the glove and recolor the decorative ring green.
		local icon = btn:FindFirstChild("Icon")
		if icon and icon:IsA("ImageLabel") then
			icon.Image = GLOVE_IMAGE
			icon.ImageColor3 = Color3.new(1, 1, 1)
		end
		local decor = btn:FindFirstChild("Decor")
		local ring = decor and decor:FindFirstChild("Highlight")
		local ringStroke = ring and ring:FindFirstChild("UIStroke")
		if ringStroke and ringStroke:IsA("UIStroke") then
			ringStroke.Color = RING_GREEN
		end
		local nameLabel = btn:FindFirstChild("Name")
		if nameLabel and nameLabel:IsA("TextLabel") then
			nameLabel.Text = "PUSH"
		end

		-- Compact keybind badge straddling the button's TOP-RIGHT CORNER (half
		-- in, half out, like a notification pip), keyed to the player's current
		-- input device (F on keyboard, TAP on touch, Y on gamepad) and updated
		-- live so switching device relabels it. Rides along with the button
		-- (child of btn), so it shows/hides with it. Its center is biased just
		-- inside the corner so the outward overhang stays within the button's
		-- 1.5%-of-screen right margin.
		local UserInputService = game:GetService("UserInputService")

		local function activationHint(): string
			local lastInput = UserInputService:GetLastInputType()
			if lastInput == Enum.UserInputType.Touch then
				return "TAP"
			elseif lastInput.Name:find("Gamepad") then
				return "Y"
			elseif not UserInputService.KeyboardEnabled and UserInputService.TouchEnabled then
				return "TAP"
			end
			return "F"
		end

		local hintLabel = Instance.new("TextLabel")
		hintLabel.Name = "PushHint"
		hintLabel.AnchorPoint = Vector2.new(0.5, 0.5)
		hintLabel.Position = UDim2.fromScale(1, 0) -- centered right on the tip of the top-right corner
		hintLabel.Size = UDim2.fromScale(0.56, 0.42)
		hintLabel.BackgroundTransparency = 1 -- no pill: just the glyph, kept crisp by its outline
		hintLabel.Font = Enum.Font.GothamBlack
		hintLabel.TextScaled = true
		hintLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		hintLabel.TextXAlignment = Enum.TextXAlignment.Center
		hintLabel.Text = activationHint()
		hintLabel.ZIndex = 21 -- above the cooldown curtain
		hintLabel.Parent = btn
		-- Minimal padding now that there's no fill — just enough that the glyph's
		-- outline doesn't clip the frame edge.
		local hintPad = Instance.new("UIPadding")
		hintPad.PaddingTop = UDim.new(0.04, 0)
		hintPad.PaddingBottom = UDim.new(0.04, 0)
		hintPad.PaddingLeft = UDim.new(0.04, 0)
		hintPad.PaddingRight = UDim.new(0.04, 0)
		hintPad.Parent = hintLabel
		local hintCorner = Instance.new("UICorner")
		hintCorner.CornerRadius = UDim.new(0.35, 0)
		hintCorner.Parent = hintLabel
		-- A Contextual black outline hugs the glyph so the letter stays crisp
		-- now that there's no fill behind it.
		local hintTextStroke = Instance.new("UIStroke")
		hintTextStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		hintTextStroke.Color = Color3.fromRGB(0, 0, 0)
		hintTextStroke.Thickness = 2
		hintTextStroke.Parent = hintLabel
		-- Soft top-lit sheen on the glyph so it doesn't read as flat.
		local hintGradient = Instance.new("UIGradient")
		hintGradient.Rotation = 90
		hintGradient.Color = ColorSequence.new(
			Color3.fromRGB(255, 255, 255),
			Color3.fromRGB(170, 170, 170)
		)
		hintGradient.Parent = hintLabel
		UserInputService.LastInputTypeChanged:Connect(function()
			hintLabel.Text = activationHint()
		end)

		-- Cooldown drain: a dark curtain over the button that shrinks from full
		-- height down to nothing across the cooldown.
		local curtain = Instance.new("Frame")
		curtain.Name = "Cooldown"
		curtain.AnchorPoint = Vector2.new(0.5, 1)
		curtain.Position = UDim2.fromScale(0.5, 1)
		curtain.Size = UDim2.fromScale(1, 0)
		curtain.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		curtain.BackgroundTransparency = 0.5
		curtain.BorderSizePixel = 0
		curtain.ZIndex = 20
		curtain.Visible = false
		curtain.Parent = btn
		local curtainCorner = Instance.new("UICorner")
		curtainCorner.CornerRadius = UDim.new(0.25, 0)
		curtainCorner.Parent = curtain

		local ICON_BRIGHT = 0 -- glove opacity when a target is in range and ready
		local ICON_DIM = 0.2 -- still clearly visible with nobody in range / while cooling
		local RING_BRIGHT = 0.1
		local RING_DIM = 0.4

		-- Wait for PushClient to publish the bridge, then bind the look + taps.
		task.spawn(function()
			local bridge = ReplicatedStorage:WaitForChild("PushBridge", 30)
			if not bridge then
				return
			end

			local function isCooling()
				return os.clock() < (bridge:GetAttribute("ReadyAt") or 0)
			end

			local function applyLook()
				holder.Visible = bridge:GetAttribute("Enabled") == true
				hintLabel.Visible = holder.Visible
				if not holder.Visible then
					curtain.Visible = false
					return
				end
				local cooling = isCooling()
				local bright = bridge:GetAttribute("HasTarget") == true and not cooling
				if icon then
					icon.ImageTransparency = bright and ICON_BRIGHT or ICON_DIM
				end
				if ringStroke then
					ringStroke.Transparency = bright and RING_BRIGHT or RING_DIM
				end
				curtain.Visible = cooling
			end

			bridge:GetAttributeChangedSignal("Enabled"):Connect(applyLook)
			bridge:GetAttributeChangedSignal("HasTarget"):Connect(applyLook)
			bridge:GetAttributeChangedSignal("ReadyAt"):Connect(applyLook)

			-- Drain the curtain only while the button is up and on cooldown.
			RunService.RenderStepped:Connect(function()
				if not (holder.Visible and curtain.Visible) then
					return
				end
				local readyAt = bridge:GetAttribute("ReadyAt") or 0
				local duration = bridge:GetAttribute("CooldownDuration") or 0
				local remaining = readyAt - os.clock()
				if remaining <= 0 then
					curtain.Visible = false
					applyLook() -- restore the bright/dim look now the shove is ready
					return
				end
				curtain.Size = UDim2.fromScale(1, duration > 0 and math.clamp(remaining / duration, 0, 1) or 0)
			end)

			btn.Activated:Connect(function()
				bridge:Fire()
				playClick()
			end)
			btn.MouseEnter:Connect(playHover)

			applyLook()
		end)
	end
end

-- Settings audio sliders: drag the handle across a row (or click the track) to
-- set the matching SoundGroup volume live. "Music" -> SoundService.BackgroundMusic,
-- "Sound Effects" -> SoundService.GameSFX. Missing group/slider -> silent no-op.
do
	local UserInputService = game:GetService("UserInputService")
	local settingsFrame = Frames:FindFirstChild("Config/Settings")
	local container = settingsFrame and settingsFrame:FindFirstChild("Container")

	local function wireVolumeSlider(row, group)
		local sliderFrame = row and row:FindFirstChild("Slider")
		local handle = sliderFrame and sliderFrame:FindFirstChild("Button")
		if not (handle and group) then
			return
		end

		-- handle center travels 0..1 across the Slider frame; alpha IS the volume
		local function applyAlpha(alpha)
			alpha = math.clamp(alpha, 0, 1)
			handle.Position = UDim2.new(alpha, 0, 0.5, 0)
			group.Volume = alpha
		end

		-- start the handle where the group's current volume already sits
		applyAlpha(group.Volume)

		local dragging = false
		local function updateFromX(x)
			local width = sliderFrame.AbsoluteSize.X
			if width > 0 then
				applyAlpha((x - sliderFrame.AbsolutePosition.X) / width)
			end
		end
		local function beginDrag(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true
				updateFromX(input.Position.X)
			end
		end

		handle.InputBegan:Connect(beginDrag)
		sliderFrame.Active = true -- let clicks on the track jump the handle
		sliderFrame.InputBegan:Connect(beginDrag)

		UserInputService.InputChanged:Connect(function(input)
			if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch) then
				updateFromX(input.Position.X)
			end
		end)
		UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				dragging = false
			end
		end)
	end

	if container then
		wireVolumeSlider(container:FindFirstChild("Slider1"), SoundService:FindFirstChild("BackgroundMusic"))
		wireVolumeSlider(container:FindFirstChild("Slider2"), SoundService:FindFirstChild("GameSFX"))
	end

	-- AFK toggle: opt out of the NEXT round. Row is a clone of a volume-slider row
	-- (keeps the kit card chrome + left "AFK Mode" label); the Slider is swapped for
	-- a clone of the bull-cam Button1 (SideUI.Left3), which already ships On/Off
	-- UIGradient states — ON = green, and we RETINT its grey "Off" gradients to red
	-- so the button flips green<->red. Toggling fires Remotes.SetAFK; the server
	-- keeps the truth in the replicated "AFK" attribute, which drives the button.
	local templateRow = container and container:FindFirstChild("Slider1")
	local btnTemplate = SideUI:FindFirstChild("Left3")
	btnTemplate = btnTemplate and btnTemplate:FindFirstChild("Buttons")
	btnTemplate = btnTemplate and btnTemplate:FindFirstChild("Other")
	btnTemplate = btnTemplate and btnTemplate:FindFirstChild("Button1")
	if templateRow and btnTemplate then
		local row = templateRow:Clone()
		row.Name = "AFKToggle"
		row.LayoutOrder = 3
		local label = row:FindFirstChild("Name")
		if label then
			label.Text = "AFK Mode"
		end

		-- swap the volume Slider for the toggle button, in the same right-hand slot
		local oldSlider = row:FindFirstChild("Slider")
		local slotPos = oldSlider and oldSlider.Position or UDim2.new(0.958, 0, 0.5, 0)
		if oldSlider then
			oldSlider:Destroy()
		end

		local btn = btnTemplate:Clone()
		btn.Name = "Toggle"
		btn.Visible = true -- the live Button1 starts hidden; the clone must show
		btn.AnchorPoint = Vector2.new(1, 0.5) -- pin to the row's right edge
		btn.Position = slotPos
		btn.Size = UDim2.new(0.27, 0, 0.66, 0)

		-- retint the shipped grey "Off" gradients to the shared red ramp
		for _, d in ipairs(btn:GetDescendants()) do
			if d:IsA("UIGradient") and d.Name == "Off" then
				d.Color = RED_OFF
			end
		end
		btn.Parent = row
		row.Parent = container

		-- ON = green (enable every "On" gradient/stroke, disable "Off"); reverse for
		-- OFF = red. Same by-name mechanism wireBullCamButton uses.
		local function paint(on)
			local btnLabel = btn:FindFirstChild("Name")
			if btnLabel and btnLabel:IsA("TextLabel") then
				btnLabel.Text = on and "AFK: ON" or "AFK: OFF"
			end
			for _, d in ipairs(btn:GetDescendants()) do
				if d:IsA("UIGradient") or d:IsA("UIStroke") then
					if d.Name == "On" then
						d.Enabled = on
					elseif d.Name == "Off" then
						d.Enabled = not on
					end
				end
			end
		end
		paint(player:GetAttribute("AFK") == true)

		task.spawn(function()
			local bullrush = ReplicatedStorage:WaitForChild("Bullrush", 30)
			local remotes = bullrush and bullrush:FindFirstChild("Remotes")
			local setAfk = remotes and remotes:WaitForChild("SetAFK", 30)
			btn.Activated:Connect(function()
				local want = not (player:GetAttribute("AFK") == true)
				player:SetAttribute("AFK", want) -- optimistic; server confirms + replicates
				paint(want)
				if setAfk then
					setAfk:FireServer(want)
				end
			end)
			-- keep the button honest if the server ever changes the value itself
			player:GetAttributeChangedSignal("AFK"):Connect(function()
				paint(player:GetAttribute("AFK") == true)
			end)
		end)
	end
end

local function addButtonFeedback(btn)
	local scale = ensureScale(btn)
	local base = scale.Scale
	local hovering = false
	btn.MouseEnter:Connect(function()
		hovering = true
		playHover()
		tween(scale, HOVER_TI, { Scale = base * 1.07 })
	end)
	btn.MouseLeave:Connect(function()
		hovering = false
		tween(scale, HOVER_TI, { Scale = base })
	end)
	btn.MouseButton1Down:Connect(function()
		tween(scale, PRESS_TI, { Scale = base * 0.92 })
	end)
	btn.MouseButton1Up:Connect(function()
		tween(scale, HOVER_TI, { Scale = hovering and base * 1.07 or base })
	end)
	-- Click SFX on a genuine activation (press+release, or gamepad/keyboard);
	-- Activated rather than MouseButton1Down so a scroll-drag that starts on a
	-- card button doesn't machine-gun the sound.
	btn.Activated:Connect(playClick)
end

for _, d in ipairs(gui:GetDescendants()) do
	if d:IsA("GuiButton") then
		addButtonFeedback(d)
	end
end

---------------------------------------------------------------- 4) ambient life
local anims = {}
local marquees = {}

local ALWAYS = function()
	return true
end

local function gateOf(frame)
	return function()
		return frame.Visible
	end
end

-- which window (child of Frames) does this element live in? nil = HUD, always animated
local function topGate(obj)
	local node = obj
	while node and node.Parent ~= Frames do
		node = node.Parent
		if node == gui or node == nil then
			return ALWAYS
		end
	end
	return node and gateOf(node) or ALWAYS
end

local function addAnim(kind, obj, amp, speed, gate)
	local entry = {
		kind = kind,
		obj = obj,
		amp = amp,
		speed = speed,
		gate = gate or topGate(obj),
		phase = #anims * 1.7,
	}
	if kind == "pulse" then
		entry.scale = ensureScale(obj)
	end
	table.insert(anims, entry)
end

-- starbursts: rotating UI breaks ClipsDescendants, so only spin the one inside a
-- CanvasGroup (which clips properly); everything else gets a soft breathe instead
for _, d in ipairs(gui:GetDescendants()) do
	if d:IsA("ImageLabel") and d.Name == "Starbust" then
		-- parent must be the CanvasGroup: the store itself is one, but it only
		-- clips at its outer edge, so rays would still spill across the cards
		if d.Parent:IsA("CanvasGroup") then
			addAnim("spin", d, 0, 9, nil)
		else
			addAnim("pulse", d, 0.04, 1.1, nil)
		end
	end
end

-- weightless float — LUCKY BLOCKS ONLY (regular shop items stay still).
-- two detuned sine waves + a slow sideways drift so it reads as drifting in
-- water, not a metronome. each block's icon moves as one unit with its big
-- transparent ghost echo so they never separate. amp = 10% of on-screen height.
local floats = {}
local function addFloat(objs, speed, phase, rotAmp, gate)
	local set = {}
	for _, o in ipairs(objs) do
		if o then
			table.insert(set, { obj = o, base = o.Position, baseRot = o.Rotation })
		end
	end
	if #set > 0 then
		table.insert(floats, { set = set, speed = speed, phase = phase, rot = rotAmp, gate = gate })
	end
end

local exclusiveBanner = storeContainer:FindFirstChild("Exclusive")
if exclusiveBanner then
	-- the banner block ships tilted -10° and unclipped by design, so a soft
	-- extra tilt on top of that is safe here
	addFloat({ exclusiveBanner:FindFirstChild("Icon") }, 0.9, 0, 4, gateOf(Store))
end
local luckyBlocksFolder = storeContainer:FindFirstChild("LuckyBlocks")
if luckyBlocksFolder then
	local i = 0
	for _, card in ipairs(luckyBlocksFolder:GetChildren()) do
		if card:IsA("Frame") then
			i += 1
			local decor = card:FindFirstChild("Decor")
			-- no rotation on these: the cards clip their contents, and rotated
			-- UI escapes ClipsDescendants — translation only
			addFloat({
				card:FindFirstChild("Icon"),
				decor and decor:FindFirstChild("Icon"),
			}, 1.0 + i * 0.08, i * 2.1, 0, gateOf(Store))
		end
	end
end

-- window header icons rock gently
for _, frame in ipairs(Frames:GetChildren()) do
	local header = frame:FindFirstChild("Header")
	local icon = header and header:FindFirstChild("Icon")
	if icon then
		addAnim("sway", icon, 6, 2.2, gateOf(frame))
	end
end

-- SALE! tags wiggle, "!" notifs pulse, boost icons breathe
for _, d in ipairs(SideUI:GetDescendants()) do
	if d:IsA("TextLabel") then
		if d.Text == "SALE!" then
			addAnim("sway", d, 9, 3.2, ALWAYS)
		elseif d.Text == "!" then
			addAnim("pulse", d, 0.12, 4.5, ALWAYS)
		end
	end
end
local boosts = SideUI:FindFirstChild("Boosts")
if boosts then
	for _, slot in ipairs(boosts:GetChildren()) do
		local icon = slot:IsA("Frame") and slot:FindFirstChild("Icon")
		if icon then
			addAnim("pulse", icon, 0.05, 2, ALWAYS)
		end
	end
end

---------------------------------------------------------------- 5) marquees
-- The lucky-block marquees show the ACTUAL prizes you can roll for: each
-- Store Secret/Alien/GOD card (Config.LUCKY_BLOCKS) and each Shop1 Lucky Box
-- card (Config.BULLS.BOXES) scrolls its own pool's reward tiles, and the
-- "[OP] LUCKY BLOCK" banner shows a static highlight reel of the standout
-- prizes. Each prize is a self-contained chip in the game's
-- roll/index card style (dark plate + rarity-coloured border + GothamBlack
-- white/INK-stroke labels): bull = real model preview + name, money = the amount,
-- cards also show the odds. All labels sit INSIDE the clipped plate (the kit's
-- own outcome item floats its label above the box, which clips off in a tight
-- tile - so we don't reuse it). Runs async (waits for assets), then registers
-- the card strips into `marquees` for the seamless scroll (the banner stays
-- static). Also wires the banner's Timer as a real weekly countdown.
task.spawn(function()
	local luckyBlocksFolder = storeContainer:FindFirstChild("LuckyBlocks")
	local bannerFrame = storeContainer:FindFirstChild("Exclusive")
	if not (luckyBlocksFolder or bannerFrame) then
		return
	end

	local bullrush = ReplicatedStorage:WaitForChild("Bullrush", 30)
	local okConfig, cfg = pcall(require, bullrush and bullrush:WaitForChild("Config", 30))
	if not (okConfig and typeof(cfg) == "table" and typeof(cfg.LUCKY_BLOCKS) == "table") then
		return
	end
	local okCatalog, BullCatalog = pcall(require, bullrush:WaitForChild("BullCatalog", 30))
	if not okCatalog then
		BullCatalog = nil
	end
	local assets = ReplicatedStorage:WaitForChild("BullrushAssets", 15)
	local modelsFolder = assets and assets:FindFirstChild("Bulls")
	local fallbackModel = assets and assets:FindFirstChild("BullTemplate")

	local KIT_FONT = Enum.Font.GothamBlack
	local INK = Color3.fromRGB(15, 15, 15)
	local PAPER = Color3.fromRGB(255, 255, 255)
	local function rarityColor(r)
		local rr = BullCatalog and BullCatalog.Rarities and BullCatalog.Rarities[r]
		return (rr and rr.color) or Color3.fromRGB(200, 200, 200)
	end

	-- real bull model preview into a prize tile (nil model -> caller's label carries it)
	local function buildBullPreviewInto(parent, bull)
		local source = bull
			and ((bull.modelName and modelsFolder and modelsFolder:FindFirstChild(bull.modelName)) or fallbackModel)
		if not source then
			return
		end
		local viewport = Instance.new("ViewportFrame")
		viewport.BackgroundTransparency = 1
		viewport.ZIndex = 3 -- above the box fill, below the kit Rate/Chance labels
		viewport.AnchorPoint = Vector2.new(0.5, 0.5)
		viewport.Position = UDim2.fromScale(0.5, 0.46)
		viewport.Size = UDim2.fromScale(0.96, 0.9)
		viewport.Ambient = Color3.fromRGB(165, 160, 155)
		viewport.LightColor = Color3.fromRGB(255, 250, 240)
		viewport.LightDirection = Vector3.new(-0.4, -1, -0.6)
		local model = source:Clone()
		model:PivotTo(CFrame.new())
		local center, size = Vector3.zero, Vector3.new(10, 10, 10)
		pcall(function()
			local cf, bbox = model:GetBoundingBox()
			center, size = cf.Position, bbox
		end)
		local camera = Instance.new("Camera")
		camera.CFrame = CFrame.lookAt(center + Vector3.new(-0.55, 0.42, -1).Unit * size.Magnitude * 0.72, center)
		camera.Parent = viewport
		viewport.CurrentCamera = camera
		model.Parent = viewport
		viewport.Parent = parent
	end

	-- Self-contained prize chip in the game's roll/index card style (dark plate,
	-- rarity-coloured border, GothamBlack white+INK-stroke labels INSIDE the box).
	-- Bull -> real model preview + name at the bottom; money -> the amount centred;
	-- cards also show the roll odds top-left (showChance). Everything sits inside
	-- the clipped plate - no kit-item floating labels that overflow/clip.
	local MONEY_GREEN = Color3.fromRGB(70, 200, 90)

	-- Money text wears the SAME look as the HUD Cash counter (bottom-left):
	-- copy its green UIGradient + text colour + stroke colour onto the label so
	-- every "$" reads as money, exactly like the cash readout.
	local cashStyleSource
	do
		local counters = SideUI and SideUI:FindFirstChild("Counters")
		local cash = counters and counters:FindFirstChild("Cash")
		cashStyleSource = cash and cash:FindFirstChild("Amount")
	end
	local function paintMoneyStyle(lbl)
		if not (cashStyleSource and lbl) then
			return
		end
		lbl.TextColor3 = cashStyleSource.TextColor3
		local src = cashStyleSource:FindFirstChildOfClass("UIGradient")
		if src then
			local g = lbl:FindFirstChildOfClass("UIGradient") or Instance.new("UIGradient")
			g.Color = src.Color
			g.Transparency = src.Transparency
			g.Rotation = src.Rotation
			g.Parent = lbl
		end
		local srcStroke = cashStyleSource:FindFirstChildOfClass("UIStroke")
		local stroke = lbl:FindFirstChildOfClass("UIStroke")
		if srcStroke and stroke then
			stroke.Color = srcStroke.Color -- keep the label's own thickness
		end
	end

	local function buildPrizeTile(reward, order, widthScale, showChance)
		local isBull = reward.kind == "bull"
		local bull = isBull and BullCatalog and BullCatalog.get(reward.bullId) or nil
		local accent = isBull and rarityColor(bull and bull.rarity or "COMMON") or MONEY_GREEN

		local tile = Instance.new("Frame")
		tile.Name = tostring(order)
		tile.LayoutOrder = order
		tile.BackgroundTransparency = 1
		tile.Size = UDim2.new(widthScale, 0, 1, 0)

		local plate = Instance.new("Frame")
		plate.Name = "Plate"
		plate.AnchorPoint = Vector2.new(0.5, 0.5)
		plate.Position = UDim2.fromScale(0.5, 0.5)
		plate.Size = UDim2.fromScale(0.9, 0.88)
		plate.BackgroundColor3 = INK
		plate.BackgroundTransparency = 0.25
		plate.ClipsDescendants = true
		plate.Parent = tile
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.12, 0)
		corner.Parent = plate
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 2
		stroke.Color = accent
		stroke.Parent = plate

		-- white GothamBlack + INK stroke, the kit's label idiom, always INSIDE
		local function label(text, posY, anchorY, sizeY, color)
			local l = Instance.new("TextLabel")
			l.BackgroundTransparency = 1
			l.Font = KIT_FONT
			l.Text = text
			l.TextColor3 = color or PAPER
			l.TextScaled = true
			l.ZIndex = 5
			l.AnchorPoint = Vector2.new(0.5, anchorY)
			l.Position = UDim2.fromScale(0.5, posY)
			l.Size = UDim2.fromScale(0.9, sizeY)
			local st = Instance.new("UIStroke")
			st.Thickness = 1.5
			st.Color = INK
			st.Parent = l
			l.Parent = plate
			return l
		end

		if isBull then
			buildBullPreviewInto(plate, bull)
			label(tostring(reward.label), 0.98, 1, 0.24) -- name along the bottom
		else
			-- amount centred (the hero), painted like the HUD Cash counter
			paintMoneyStyle(label(tostring(reward.label), 0.5, 0.5, 0.5))
		end

		if showChance and reward.weight then
			label(reward.weight .. "%", 0.02, 0, 0.2, accent) -- roll odds, top
		end
		return tile
	end

	-- clear the kit's placeholder items (keep the layout) and rebuild from prizes
	local function fillStrip(strip, rewards, widthScale, showChance)
		for _, c in ipairs(strip:GetChildren()) do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		for i, reward in ipairs(rewards) do
			buildPrizeTile(reward, i, widthScale, showChance).Parent = strip
		end
	end

	-- A lucky block rolls a rarity by its `weights`, then a UNIFORM bull within
	-- that rarity (BullCatalog.roll). So the honest "what you can get" preview is
	-- every rollable bull whose rarity the block can hit, each labelled with its
	-- true per-bull odds:  P(bull) = (rarityWeight / total) / (#bulls of rarity).
	-- Derived straight from `weights` + BullCatalog so the reel can never drift
	-- from what actually rolls. (The blocks were reworked from a hand-authored
	-- REWARDS list to rarity `weights`; this rebuilds the tiles from the new shape.)
	local rOrder = BullCatalog and BullCatalog.Rarities
	local function prizesForWeights(weights)
		local prizes = {}
		if typeof(weights) ~= "table" or not BullCatalog then
			return prizes
		end
		local total = 0
		for _, w in pairs(weights) do
			total += math.max(tonumber(w) or 0, 0)
		end
		if total <= 0 then
			return prizes
		end
		-- bucket rollable bulls by rarity the block can actually hit
		local byRarity = {}
		for id, bull in BullCatalog.Bulls do
			if bull.rollable ~= false and (tonumber(weights[bull.rarity]) or 0) > 0 then
				byRarity[bull.rarity] = byRarity[bull.rarity] or {}
				table.insert(byRarity[bull.rarity], { id = id, bull = bull })
			end
		end
		for rarity, list in byRarity do
			local perBull = (math.max(tonumber(weights[rarity]) or 0, 0) / total) / #list * 100
			local figure = (("%.1f"):format(perBull):gsub("%.0$", "")) -- strip float dust
			for _, entry in ipairs(list) do
				table.insert(prizes, {
					kind = "bull", bullId = entry.id, label = entry.bull.name,
					weight = figure, rarity = entry.bull.rarity,
				})
			end
		end
		-- low -> high rarity ramp, stable by name within a rarity
		table.sort(prizes, function(a, b)
			local ra = (rOrder and rOrder[a.rarity] and rOrder[a.rarity].order) or 0
			local rb = (rOrder and rOrder[b.rarity] and rOrder[b.rarity].order) or 0
			if ra ~= rb then
				return ra < rb
			end
			return a.label < b.label
		end)
		return prizes
	end

	-- scrolling per-card marquees: each card shows its own tier's prizes
	local CARD_OF = { SECRET = "Secret", ALIEN = "Alien", GOD = "GOD" }
	local ITEM_W = 0.233
	local cardIndex = 0
	for _, tierId in ipairs({ "SECRET", "ALIEN", "GOD" }) do
		local tier = cfg.LUCKY_BLOCKS[tierId]
		local card = luckyBlocksFolder and luckyBlocksFolder:FindFirstChild(CARD_OF[tierId])
		local outcomes = card and card:FindFirstChild("Outcomes")
		local strip = outcomes and outcomes:FindFirstChild("Frame - This will be tweened")
		local layout = strip and strip:FindFirstChildOfClass("UIListLayout")
		local prizes = tier and prizesForWeights(tier.weights) or {}
		if tier and layout and #prizes > 0 then
			outcomes.ClipsDescendants = true
			layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
			fillStrip(strip, prizes, ITEM_W, true) -- cards show each prize's odds
			local n = #prizes
			-- clone the row once so the scroll loops seamlessly
			for i = 1, n do
				local orig = strip:FindFirstChild(tostring(i))
				if orig then
					local clone = orig:Clone()
					clone.Name = "m" .. i
					clone.LayoutOrder = i + n
					clone.Parent = strip
				end
			end
			cardIndex += 1
			table.insert(marquees, {
				frame = strip,
				period = n * (ITEM_W + layout.Padding.Scale),
				-- alternate direction per card so the shop feels alive, not mechanical
				speed = (cardIndex % 2 == 0) and -0.095 or 0.11,
				gate = gateOf(Store),
			})
		end
	end

	-- Shop1 "Lucky Boxes" cards (Basic/Super/Mega) get the SAME possible-rolls
	-- reel as the Store lucky blocks: every bull the box can roll scrolls
	-- through the card's empty middle band as a prize chip with its true odds,
	-- so the card shows what's inside instead of just naming its tier. The
	-- cards are (re)built async by section 11's buildBoxShop (kit clones named
	-- by boxId), so dress whatever already exists and watch ChildAdded for the
	-- rebuild. Chips are sized square against the wide kit card (~4 visible).
	local BOX_ITEM_W = 0.195
	local BOX_PAD = 0.02
	local shop1 = Frames:FindFirstChild("Shop1")
	local shop1Container = shop1 and shop1:FindFirstChild("Container")
	local BOXES = typeof(cfg.BULLS) == "table" and typeof(cfg.BULLS.BOXES) == "table"
		and cfg.BULLS.BOXES or nil
	if shop1Container and BOXES then
		local boxCardIndex = 0
		local function dressBoxCard(card)
			local box = card:IsA("Frame") and BOXES[card.Name]
			if not box or card:FindFirstChild("Outcomes") then
				return
			end
			local prizes = prizesForWeights(box.weights)
			if #prizes == 0 then
				return
			end
			-- the tier tag ("Basic"/"Super"/"Mega") sits exactly in the reel's
			-- band and just repeats the card name — the reel replaces it
			local info = card:FindFirstChild("Info")
			local tag = info and info:FindFirstChild("Rarity")
			if tag and tag:IsA("GuiObject") then
				tag.Visible = false
			end
			-- the free band between the Info row (top) and the odds row
			-- (bottom), right of the box-art IconFrame — stopping short of the
			-- kit buy button, which owns the card's right side from y~0.55 up
			local outcomes = Instance.new("Frame")
			outcomes.Name = "Outcomes"
			outcomes.BackgroundTransparency = 1
			outcomes.ClipsDescendants = true
			outcomes.AnchorPoint = Vector2.new(0, 0.5)
			outcomes.Position = UDim2.fromScale(0.22, 0.485)
			outcomes.Size = UDim2.fromScale(0.475, 0.42)
			local strip = Instance.new("Frame")
			strip.Name = "Strip"
			strip.BackgroundTransparency = 1
			strip.AnchorPoint = Vector2.new(0.5, 0.5)
			strip.Position = UDim2.fromScale(0.5, 0.5)
			strip.Size = UDim2.fromScale(1, 1)
			strip.Parent = outcomes
			local layout = Instance.new("UIListLayout")
			layout.FillDirection = Enum.FillDirection.Horizontal
			layout.VerticalAlignment = Enum.VerticalAlignment.Center
			layout.SortOrder = Enum.SortOrder.LayoutOrder
			layout.Padding = UDim.new(BOX_PAD, 0)
			layout.Parent = strip
			fillStrip(strip, prizes, BOX_ITEM_W, true) -- chips carry their odds
			outcomes.Parent = card

			local n = #prizes
			if n * (BOX_ITEM_W + BOX_PAD) <= 1 then
				-- tiny pool fits the band: a static centred reel, like the OP banner
				layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
				return
			end
			layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
			for i = 1, n do -- clone the row once so the scroll loops seamlessly
				local orig = strip:FindFirstChild(tostring(i))
				if orig then
					local clone = orig:Clone()
					clone.Name = "m" .. i
					clone.LayoutOrder = i + n
					clone.Parent = strip
				end
			end
			boxCardIndex += 1
			table.insert(marquees, {
				frame = strip,
				period = n * (BOX_ITEM_W + BOX_PAD),
				-- a touch slower than the Store reels: this strip is slightly
				-- wider on screen, so the same pixel pace needs less scale-speed
				speed = (boxCardIndex % 2 == 0) and -0.07 or 0.08,
				gate = gateOf(shop1),
			})
		end
		for _, c in ipairs(shop1Container:GetChildren()) do
			dressBoxCard(c)
		end
		shop1Container.ChildAdded:Connect(function(c)
			task.defer(dressBoxCard, c) -- let buildBoxShop finish painting the clone
		end)
	end

	-- banner Timer: a real weekly limited-offer countdown (pure client urgency).
	-- Fixed 7-day cycle anchored to a Monday, driven off the server clock so
	-- every player sees the same time remaining.
	local timerLabel = bannerFrame and bannerFrame:FindFirstChild("Timer")
	if timerLabel and timerLabel:IsA("TextLabel") then
		local PERIOD = 7 * 24 * 3600
		local ANCHOR = 1704067200 -- 2024-01-01 00:00 UTC (a Monday)
		local function fmt(s)
			local d = s // 86400
			local h = (s % 86400) // 3600
			local m = (s % 3600) // 60
			if d > 0 then
				return ("%dd %dh left"):format(d, h)
			elseif h > 0 then
				return ("%dh %dm left"):format(h, m)
			else
				return ("%dm %ds left"):format(m, s % 60)
			end
		end
		task.spawn(function()
			while timerLabel.Parent do
				local remaining = PERIOD - ((workspace:GetServerTimeNow() - ANCHOR) % PERIOD)
				timerLabel.Text = fmt(math.floor(remaining))
				task.wait(1)
			end
		end)
	end
end)

---------------------------------------------------------------- 5b) lucky blocks
-- Store "LuckyBlocks" cards (Secret / Alien / GOD): premium Robux BULL rolls.
-- Each card's BuyButtons.1 prompts its Config.PRODUCTS lucky-block product; the
-- receipt opens one roll of the tier's own rarity pool server-side
-- (BullRollService.grantRolls) and the bull-carousel reveal (section 11)
-- auto-opens off the "ROLLED" ack. Card name + price are painted from
-- Config.LUCKY_BLOCKS so the shop can't drift from config (id 0 /
-- not-yet-published -> red "coming soon" card, same idiom as the wheel).
task.spawn(function()
	local luckyBlocksFrame = storeContainer:FindFirstChild("LuckyBlocks")
	if not luckyBlocksFrame then
		return
	end
	local bullrush = ReplicatedStorage:WaitForChild("Bullrush", 30)
	local okConfig, cfg = pcall(require, bullrush and bullrush:WaitForChild("Config", 30))
	if not (okConfig and typeof(cfg) == "table" and typeof(cfg.LUCKY_BLOCKS) == "table") then
		return
	end
	local Marketplace = game:GetService("MarketplaceService")
	local CARD_OF = { SECRET = "Secret", ALIEN = "Alien", GOD = "GOD" } -- tierId -> kit card name

	-- wire one buy button -> its Robux product prompt (0/unpublished => coming soon)
	local function wireBuyButton(buyButton, productKey)
		if not (buyButton and buyButton:IsA("GuiButton")) then
			return
		end
		buyButton.Activated:Connect(function()
			local productId = tonumber(cfg.PRODUCTS[productKey]) or 0
			if productId <= 0 then
				if pushNotif then
					pushNotif("Lucky Blocks are coming soon!", "red", 3)
				end
				return
			end
			local ok = pcall(function()
				Marketplace:PromptProductPurchase(player, productId)
			end)
			if not ok and pushNotif then
				pushNotif("Store not available", "red", 3)
			end
		end)
	end

	-- Secret/Alien/GOD: one card each in the LuckyBlocks row (single buy button)
	for tierId, tier in cfg.LUCKY_BLOCKS do
		local card = CARD_OF[tierId] and luckyBlocksFrame:FindFirstChild(CARD_OF[tierId])
		if card then
			local nameLabel = card:FindFirstChild("Name")
			if nameLabel and nameLabel:IsA("TextLabel") then
				nameLabel.Text = tier.name
			end
			local bb = card:FindFirstChild("BuyButtons")
			local btn = bb and bb:FindFirstChild("1")
			local info = btn and btn:FindFirstChild("Info")
			local priceLabel = info and info:FindFirstChild("Price")
			if priceLabel and priceLabel:IsA("TextLabel") then
				priceLabel.Text = tostring(tier.price)
				-- then the live Robux price async, so the card can't drift from the real product
				local productId = tonumber(cfg.PRODUCTS[tier.product]) or 0
				if productId > 0 then
					task.spawn(function()
						local ok, prod = pcall(function()
							return Marketplace:GetProductInfo(productId, Enum.InfoType.Product)
						end)
						if ok and prod and prod.PriceInRobux then
							priceLabel.Text = tostring(prod.PriceInRobux)
						end
					end)
				end
			end
			wireBuyButton(btn, tier.product)
		end
	end

	-- OP Lucky Block lives on the featured "Exclusive" card at the top: its 3 buy
	-- buttons are the x1 / x3 / x10 elite BULL rolls (Config.BULLS.OP_ROLL). Buying
	-- prompts the Robux product; the receipt rolls elite bulls (BullRollService)
	-- and the bull carousel auto-opens. Prices/labels are already set in the kit.
	local opRoll = cfg.BULLS and cfg.BULLS.OP_ROLL
	local exclusive = storeContainer:FindFirstChild("Exclusive")
	local exBuys = exclusive and exclusive:FindFirstChild("BuyButtons")
	if opRoll and exBuys then
		for i, bundle in ipairs(opRoll.bundles or {}) do
			wireBuyButton(exBuys:FindFirstChild(tostring(i)), bundle.product)
		end
	end

	-- Paint the Exclusive card's outcome slots with the ACTUAL elite bulls this
	-- crate can roll instead of the kit's placeholder brainrot art. The pool =
	-- rollable bulls whose rarity is weighted in OP_ROLL.box.weights (EPIC +
	-- LEGENDARY only). Each slot becomes a real ViewportFrame render of the bull
	-- model (same 3/4-front recipe as the Celestial card / index cards) plus its
	-- TRUE odds: BullCatalog.roll picks a rarity by weight then a uniform bull
	-- within it, so a bull's chance = rarityWeight/totalWeight / bullsInThatRarity.
	local outcomes = exclusive and exclusive:FindFirstChild("Outcomes")
	local weights = opRoll and opRoll.box and opRoll.box.weights
	local okCat, BullCatalog = pcall(require, bullrush:WaitForChild("BullCatalog", 30))
	if outcomes and okCat and typeof(BullCatalog) == "table" and typeof(weights) == "table" then
		local bullsFolder = ReplicatedStorage:FindFirstChild("BullrushAssets")
		bullsFolder = bullsFolder and bullsFolder:FindFirstChild("Bulls")

		-- rollable bulls in the weighted rarities, + per-rarity counts / total weight
		local elite, counts, totalW = {}, {}, 0
		for id, bull in BullCatalog.Bulls do
			if bull.rollable ~= false and (weights[bull.rarity] or 0) > 0 then
				counts[bull.rarity] = (counts[bull.rarity] or 0) + 1
				local rr = BullCatalog.Rarities[bull.rarity]
				table.insert(elite, { id = id, bull = bull, order = rr and rr.order or 0 })
			end
		end
		for rarity, c in counts do
			if c > 0 then totalW += (weights[rarity] or 0) end
		end

		-- kit slots (named "1".."n") left->right; trim the elite list to fit and
		-- show it rarest-LAST so the card builds up to the top prize on the right
		local slots = {}
		for _, ch in outcomes:GetChildren() do
			if ch:IsA("Frame") then table.insert(slots, ch) end
		end
		table.sort(slots, function(a, b) return a.Name < b.Name end)
		table.sort(elite, function(a, b) -- rarest first, so trimming drops commons
			if a.order ~= b.order then return a.order > b.order end
			return a.id < b.id
		end)
		while #elite > #slots do table.remove(elite) end
		table.sort(elite, function(a, b) -- rarest last for the display order
			if a.order ~= b.order then return a.order < b.order end
			return a.id < b.id
		end)

		for i, slot in ipairs(slots) do
			local entry = elite[i]
			if not entry then
				slot.Visible = false -- fewer elite bulls than kit slots: hide the extra
			else
				slot.Visible = true
				local rarity = BullCatalog.Rarities[entry.bull.rarity]
				local chance = 0
				if totalW > 0 and counts[entry.bull.rarity] then
					chance = (weights[entry.bull.rarity] or 0) / totalW / counts[entry.bull.rarity] * 100
				end
				local chanceLabel = slot:FindFirstChild("Chance")
				if chanceLabel and chanceLabel:IsA("TextLabel") then
					chanceLabel.Text = if chance >= 10
						then string.format("%d%%", math.floor(chance + 0.5))
						else string.format("%.1f%%", chance)
				end
				-- the kit's "$10/s" Rate label becomes the bull's name
				local rateLabel = slot:FindFirstChild("Rate")
				if rateLabel and rateLabel:IsA("TextLabel") then
					rateLabel.Text = entry.bull.name
				end
				-- tint the slot outline by rarity so the tiers read at a glance
				local stroke = slot:FindFirstChild("UIStroke")
				if stroke and rarity then
					stroke.Color = rarity.color
				end
				-- swap the brainrot Icon for a real bull render (falls back to the
				-- generic legendary skin if a modelName is ever missing)
				local icon = slot:FindFirstChild("Icon")
				local source = entry.bull.modelName and bullsFolder
					and bullsFolder:FindFirstChild(entry.bull.modelName)
				if icon and icon:IsA("GuiObject") and source then
					local viewport = Instance.new("ViewportFrame")
					viewport.Name = "Icon"
					viewport.BackgroundTransparency = 1
					viewport.AnchorPoint = icon.AnchorPoint
					viewport.Position = icon.Position
					viewport.Size = icon.Size
					viewport.ZIndex = icon.ZIndex
					viewport.Ambient = Color3.fromRGB(165, 160, 155)
					viewport.LightColor = Color3.fromRGB(255, 250, 240)
					viewport.LightDirection = Vector3.new(-0.4, -1, -0.6)
					local uicorner = icon:FindFirstChildWhichIsA("UICorner")
					if uicorner then
						uicorner:Clone().Parent = viewport
					end
					local model = source:Clone()
					model:PivotTo(CFrame.new())
					local center, size = Vector3.zero, Vector3.new(10, 10, 10)
					pcall(function()
						local cf, bbox = model:GetBoundingBox()
						center, size = cf.Position, bbox
					end)
					local camera = Instance.new("Camera")
					camera.CFrame = CFrame.lookAt(center + Vector3.new(-0.55, 0.42, -1).Unit * size.Magnitude * 0.72, center)
					camera.Parent = viewport
					viewport.CurrentCamera = camera
					model.Parent = viewport
					viewport.Parent = slot
					icon:Destroy()
				end
			end
		end
	end
end)

---------------------------------------------------------------- 5c) passes + luck
-- Store gamepass / server-luck cards -> MonetizationService. Each card's buy
-- button prompts its pass (PromptGamePassPurchase) or the Server Luck product
-- (PromptProductPurchase); the price label is painted live from GetProductInfo
-- and owned passes flip to a greyed "Owned". The kit ships the Super/Mega luck
-- slots directly; all ids are 0 until published -> a buy shows a "coming soon"
-- card (same idiom as elsewhere).
task.spawn(function()
	local Marketplace = game:GetService("MarketplaceService")
	local bullrush = ReplicatedStorage:WaitForChild("Bullrush", 30)
	local okCfg, cfg = pcall(require, bullrush and bullrush:WaitForChild("Config", 30))
	if not (okCfg and typeof(cfg) == "table") then
		return
	end
	local gamepasses = storeContainer:FindFirstChild("Gamepasses")
	-- (Celestial Bull has its own purpose-built Store card in the Container; it is
	-- wired further down.)

	local function priceBtn(card)
		local bb = card and card:FindFirstChild("BuyButtons")
		local btn = bb and (bb:FindFirstChild("1") or bb:FindFirstChildWhichIsA("GuiButton"))
		local info = btn and btn:FindFirstChild("Info")
		return btn, info and info:FindFirstChild("Price")
	end

	-- wire one card: name, description, live price, buy prompt, owned state (passes only)
	local function wire(card, name, id, infoType, ownedAttr, desc)
		if not card then
			return
		end
		id = tonumber(id) or 0
		local nameLabel = card:FindFirstChild("Name")
		if nameLabel and nameLabel:IsA("TextLabel") then
			nameLabel.Text = name
		end
		-- blurb advertising the perk (gamepass cards call it "Des", VIP/ServerLuck "TextLabel")
		local descLabel = card:FindFirstChild("Des") or card:FindFirstChild("TextLabel")
		if desc and descLabel and descLabel:IsA("TextLabel") then
			descLabel.Text = desc
		end
		local btn, priceLabel = priceBtn(card)

		local function isOwned()
			return ownedAttr ~= nil and player:GetAttribute(ownedAttr) == true
		end
		local function refresh()
			local owned = isOwned()
			if btn then
				btn.Active = not owned
				btn.AutoButtonColor = not owned
			end
			if priceLabel and owned then
				priceLabel.Text = "Owned"
			end
		end
		-- live Robux price from the asset (async; only while not owned / configured)
		if priceLabel and id ~= 0 and not isOwned() then
			task.spawn(function()
				local ok, info = pcall(function()
					return Marketplace:GetProductInfo(id, infoType)
				end)
				if ok and info and info.PriceInRobux and not isOwned() then
					priceLabel.Text = tostring(info.PriceInRobux)
				end
			end)
		end
		if btn and btn:IsA("GuiButton") then
			btn.Activated:Connect(function()
				if id <= 0 then
					if pushNotif then
						pushNotif(name .. " is coming soon!", "red", 3)
					end
					return
				end
				if isOwned() then
					return
				end
				local ok, err = pcall(function()
					if infoType == Enum.InfoType.GamePass then
						Marketplace:PromptGamePassPurchase(player, id)
					else
						Marketplace:PromptProductPurchase(player, id)
					end
				end)
				if not ok then
					warn(("Store: purchase prompt failed for %s (id %d): %s"):format(name, id, tostring(err)))
				end
			end)
		end
		if ownedAttr then
			player:GetAttributeChangedSignal(ownedAttr):Connect(refresh)
		end
		refresh()
	end

	local P = cfg.PASSES or {}
	local D = cfg.PRODUCTS or {}
	local GP = Enum.InfoType.GamePass
	wire(gamepasses and gamepasses:FindFirstChild("2xCash"), "2x Cash", P.DOUBLE_MONEY, GP, "HasDoubleMoney",
		"")
	wire(gamepasses and gamepasses:FindFirstChild("SuperLuck"), "Super Luck", P.LUCK_SUPER, GP, "LuckSuper",
		"3X Luck")
	wire(gamepasses and gamepasses:FindFirstChild("MEGALuck"), "Mega Luck", P.LUCK_MEGA, GP, "LuckMega",
		"5X Luck")
	wire(storeContainer:FindFirstChild("VIP"), "VIP", P.VIP, GP, "IsVIP",
		"+50% cash, 1.5x luck, 2x votes")
	wire(storeContainer:FindFirstChild("ServerLuck"), "Server Luck", D.SERVER_LUCK, Enum.InfoType.Product, nil,
		"2x odds server-wide, 30 min")

	-- Celestial Bull: the user's purpose-built Store card (own art + Speed +
	-- "X Remaining!" urgency), wired to the Celestial Bull pass. Speed is pulled from
	-- the catalog so it can't drift; the "Remaining" count is deterministic client
	-- urgency (same for everyone, off the server clock -- like the banner Timer), not
	-- real stock.
	local celestialCard = storeContainer:FindFirstChild("CelestialBull")
	if celestialCard then
		wire(celestialCard, "Celestial Bull", P.STRAWBERRY_ELEPHANT, GP, "HasStrawberryElephant", nil)

		local infoFrame = celestialCard:FindFirstChild("InfoFrame")
		local infoLabel = infoFrame and infoFrame:FindFirstChild("Info")
		if infoLabel and infoLabel:IsA("TextLabel") then
			local okCat, catalog = pcall(require, bullrush:FindFirstChild("BullCatalog"))
			local bull = okCat and typeof(catalog) == "table" and catalog.Bulls and catalog.Bulls.STRAWBERRY
			local speed = bull and bull.speed
			-- the InfoFrame now carries a shoe icon (SpeedIcon) as the "speed"
			-- glyph, so the label is just the number
			infoLabel.Text = speed and ("%d"):format(speed) or ""
		end

		local amountLabel = celestialCard:FindFirstChild("AmountLeft")
		if amountLabel and amountLabel:IsA("TextLabel") then
			local PERIOD = 7 * 24 * 3600
			local ANCHOR = 1704067200 -- 2024-01-01 00:00 UTC
			local STOCK_MAX, STOCK_MIN = 500, 7
			task.spawn(function()
				while amountLabel.Parent do
					local f = ((workspace:GetServerTimeNow() - ANCHOR) % PERIOD) / PERIOD
					local left = math.floor(STOCK_MAX - f * (STOCK_MAX - STOCK_MIN) + 0.5)
					amountLabel.Text = ("%d Remaining!"):format(left)
					task.wait(20)
				end
			end)
		end
	end
end)

---------------------------------------------------------------- 5d) money packs
-- Store "Cash" section: buy Robux -> Money. The kit ships 6 card slots (3 columns
-- x 2); we paint the first #MONEY_PACKS from Config (name + Money amount + live
-- Robux price) and wire each buy to the product, then hide any spare slots.
task.spawn(function()
	local Marketplace = game:GetService("MarketplaceService")
	local bullrush = ReplicatedStorage:WaitForChild("Bullrush", 30)
	local okCfg, cfg = pcall(require, bullrush and bullrush:WaitForChild("Config", 30))
	if not (okCfg and typeof(cfg) == "table" and typeof(cfg.MONEY_PACKS) == "table") then
		return
	end
	local cashSection = storeContainer:FindFirstChild("Cash")
	if not cashSection then
		return
	end
	-- Pack amounts read as $5K / $1.2M rather than $5,000 (truncated one decimal,
	-- so a value never rounds up into the next unit). Falls back to the config label.
	local function shortCash(n)
		n = math.floor(tonumber(n) or 0)
		if n < 1000 then
			return "$" .. n
		end
		for _, u in ipairs({ { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }) do
			if n >= u[1] then
				local s = tostring(math.floor(n / u[1] * 10) / 10):gsub("%.0$", "")
				return "$" .. s .. u[2]
			end
		end
		return "$" .. n
	end
	-- card slots in fill order: column1(1,2), column2(1,2), column3(1,2)
	local slots = {}
	for _, colName in ipairs({ "column1", "column2", "column3" }) do
		local col = cashSection:FindFirstChild(colName)
		if col then
			for _, n in ipairs({ "1", "2" }) do
				local card = col:FindFirstChild(n)
				if card and card:IsA("GuiObject") then
					table.insert(slots, card)
				end
			end
		end
	end

	for i, card in ipairs(slots) do
		local pack = cfg.MONEY_PACKS[i]
		if not pack then
			card.Visible = false -- no pack for this spare slot
		else
			local id = tonumber(cfg.PRODUCTS[pack.product]) or 0
			local nameLabel = card:FindFirstChild("Name")
			if nameLabel and nameLabel:IsA("TextLabel") then
				nameLabel.Text = pack.name
			end
			local info = card:FindFirstChild("Info")
			local amount = info and info:FindFirstChild("Amount")
			if amount and amount:IsA("TextLabel") then
				amount.Text = pack.amount and shortCash(pack.amount) or pack.label
			end
			local bb = card:FindFirstChild("BuyButtons")
			local btn = bb and (bb:FindFirstChild("1") or bb:FindFirstChildWhichIsA("GuiButton"))
			local info2 = btn and btn:FindFirstChild("Info")
			local priceLabel = info2 and info2:FindFirstChild("Price")
			if priceLabel and id ~= 0 then
				task.spawn(function()
					local ok, prod = pcall(function()
						return Marketplace:GetProductInfo(id, Enum.InfoType.Product)
					end)
					if ok and prod and prod.PriceInRobux then
						priceLabel.Text = tostring(prod.PriceInRobux)
					end
				end)
			end
			if btn and btn:IsA("GuiButton") then
				btn.Activated:Connect(function()
					if id <= 0 then
						if pushNotif then
							pushNotif(pack.name .. " is coming soon!", "red", 3)
						end
						return
					end
					pcall(function()
						Marketplace:PromptProductPurchase(player, id)
					end)
				end)
			end
		end
	end
end)

---------------------------------------------------------------- 5e) hide booster packs
-- Booster Packs (Starter/PRO packs + their "Booster Packs" header) are hidden
-- FOR NOW; the "Money" section below collapses up into their spot on its own
-- (a UIListLayout skips Visible=false children). Flip these back on to restore.
for _, name in ipairs({ "StarterPack", "PROPack", "TextFrame3" }) do
	local section = storeContainer:FindFirstChild(name)
	if section then
		section.Visible = false
	end
end

---------------------------------------------------------------- animation loop
RunService.RenderStepped:Connect(function()
	local t = os.clock()
	for _, a in ipairs(anims) do
		if a.gate() then
			if a.kind == "spin" then
				a.obj.Rotation = (t * a.speed + a.phase * 57.3) % 360
			elseif a.kind == "sway" then
				a.obj.Rotation = math.sin(t * a.speed + a.phase) * a.amp
			elseif a.kind == "pulse" then
				a.scale.Scale = 1 + math.sin(t * a.speed + a.phase) * a.amp
			end
		end
	end
	for _, fl in ipairs(floats) do
		if fl.gate() then
			if not fl.amp then
				local h = fl.set[1].obj.AbsoluteSize.Y
				if h > 0 then
					fl.amp = math.clamp(h * 0.10, 4, 14)
				end
			end
			if fl.amp then
				local w, p = fl.speed, fl.phase
				local dy = (math.sin(t * w + p) * 0.7 + math.sin(t * w * 1.7 + p * 2 + 1) * 0.3) * fl.amp
				local dx = math.sin(t * w * 0.55 + p + 1.3) * fl.amp * 0.25
				local dr = fl.rot ~= 0 and math.sin(t * w * 0.8 + p + 0.6) * fl.rot or nil
				for _, e in ipairs(fl.set) do
					e.obj.Position = e.base + UDim2.fromOffset(dx, dy)
					if dr then
						e.obj.Rotation = e.baseRot + dr
					end
				end
			end
		end
	end
	for _, m in ipairs(marquees) do
		if m.gate() then
			m.frame.Position = UDim2.new(0.5 - (t * m.speed) % m.period, 0, 0.5, 0)
		end
	end
end)
---------------------------------------------------------------- 6) notifications
-- Server-pushed game info cards (ReplicatedStorage.Bullrush.Remotes.Notify,
-- fired by NotifyService). Every card keeps the kit's stock black-bar look;
-- the style colours the TEXT itself: "red"/"green" run a vertical light-to-
-- dark gradient down the glyphs (danger / good news), "white" stays plain.
-- Cards clone SideUI.Top.Notif and stack under the top HUD, newest first.
-- The stack also hosts two sticky cards: the intermission countdown
-- ("NEXT: <mode> — 12s"), repainted from the per-second RoundState resends,
-- and the dead-spectator alive counter (section 6b).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local notifTemplate = SideUI:WaitForChild("Top"):WaitForChild("Notif")

local NOTIF_LIFETIME = 4
local NOTIF_MAX = 5
-- Vertical text gradients: hot highlight at the top of the glyphs, rich
-- saturated middle, deep shade at the baseline — classic juicy game-UI type.
local NOTIF_TEXT_TINTS = {
	red = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 176, 158)),
		ColorSequenceKeypoint.new(0.45, Color3.fromRGB(255, 72, 48)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(158, 12, 8)),
	}),
	green = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(182, 255, 178)),
		ColorSequenceKeypoint.new(0.45, Color3.fromRGB(72, 224, 96)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(16, 128, 46)),
	}),
}

-- Notifs get their own ScreenGui at an extreme DisplayOrder so they always
-- render above every other gui (shop panels, Bullrush HUD at DisplayOrder 10,
-- spinner/roll overlays, etc.) — nothing may cover a notification. Main
-- resets on spawn but this gui doesn't, so drop the previous life's copy
-- before making a fresh one.
local oldNotifGui = gui.Parent:FindFirstChild("NotifGui")
if oldNotifGui then
	oldNotifGui:Destroy()
end
local notifGui = Instance.new("ScreenGui")
notifGui.Name = "NotifGui"
notifGui.DisplayOrder = 10000
notifGui.ResetOnSpawn = false
notifGui.IgnoreGuiInset = false
notifGui.Parent = gui.Parent

local notifStack = Instance.new("Frame")
notifStack.Name = "NotifStack"
notifStack.AnchorPoint = Vector2.new(0.5, 0)
notifStack.Position = UDim2.new(0.5, 0, 0.08, 0)
notifStack.Size = UDim2.new(0.4, 0, 0.3, 0)
notifStack.BackgroundTransparency = 1
notifStack.Parent = notifGui

local notifLayout = Instance.new("UIListLayout")
notifLayout.FillDirection = Enum.FillDirection.Vertical
notifLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
notifLayout.SortOrder = Enum.SortOrder.LayoutOrder
notifLayout.Padding = UDim.new(0, 4)
notifLayout.Parent = notifStack

local notifCounter = 0

-- Shared card factory: clone the template, drop its stacking layout, style the
-- text. Used by pushNotif's transient cards AND the sticky intermission
-- countdown card below. Returns nil if the template lost its label (e.g. a
-- test harness cloned a destroyed copy) rather than error in a remote handler.
local function buildNotifCard(text, style)
	local card = notifTemplate:Clone()
	card.Size = UDim2.new(1, 0, 0, 36)
	card.Position = UDim2.new()
	card.Visible = true

	-- One line per card: the template's inner list layout was for stacking
	-- text in place, which would fight our per-card colours.
	local list = card:FindFirstChildOfClass("UIListLayout")
	if list then
		list:Destroy()
	end
	local label = card:FindFirstChild("Text")
	if not (label and label:IsA("TextLabel")) then
		card:Destroy()
		return nil, nil
	end
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.new(0.5, 0, 0.5, 0)
	label.Size = UDim2.new(1, -24, 1, -14)
	label.Text = text

	local tint = NOTIF_TEXT_TINTS[style]
	if tint then
		-- The bar keeps its stock black look for every style; good/bad news
		-- lives in the lettering. UIGradient multiplies the text colour, so
		-- white glyphs take the ramp exactly as authored.
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		local textGradient = Instance.new("UIGradient")
		textGradient.Rotation = 90 -- top of the glyphs -> baseline
		textGradient.Color = tint
		textGradient.Parent = label
	end
	return card, label
end

-- fade-and-destroy, shared by expiring notifs and the retiring countdown card
local function fadeOutCard(card, label)
	local stroke = label and label:FindFirstChildOfClass("UIStroke")
	tween(card, TweenInfo.new(0.35), { BackgroundTransparency = 1 })
	if label then
		tween(label, TweenInfo.new(0.35), { TextTransparency = 1 })
	end
	if stroke then
		tween(stroke, TweenInfo.new(0.35), { Transparency = 1 })
	end
	task.delay(0.4, function()
		card:Destroy()
	end)
end

-- Big on-field kickoff countdown: replaces the old "<MODE> — GO!" broadcast.
-- During the post-teleport `starting` phase the sticky card stays hidden and
-- each remaining second lands as a huge center-screen digit instead (5..1),
-- with SoundDirector playing the matching Ticker on every one. Lives in
-- notifGui so no panel can cover it.
local startCountLabel = Instance.new("TextLabel")
startCountLabel.Name = "StartCountdown"
startCountLabel.AnchorPoint = Vector2.new(0.5, 0.5)
startCountLabel.Position = UDim2.new(0.5, 0, 0.35, 0)
startCountLabel.Size = UDim2.new(0.3, 0, 0.22, 0)
startCountLabel.BackgroundTransparency = 1
startCountLabel.Font = Enum.Font.GothamBlack
startCountLabel.TextScaled = true
startCountLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
startCountLabel.TextTransparency = 1
startCountLabel.Parent = notifGui

local startCountStroke = Instance.new("UIStroke")
startCountStroke.Color = Color3.fromRGB(0, 0, 0)
startCountStroke.Thickness = 4
startCountStroke.Transparency = 1
startCountStroke.Parent = startCountLabel

local startCountScale = ensureScale(startCountLabel)
local lastStartSecond = nil -- dedupes the per-second resends; nil = hidden

local function showStartCount(seconds)
	if lastStartSecond == seconds then
		return
	end
	lastStartSecond = seconds
	startCountLabel.Text = tostring(seconds)
	startCountLabel.TextTransparency = 0
	startCountStroke.Transparency = 0
	startCountScale.Scale = 1.5 -- each digit slams in from oversized
	tween(startCountScale, POP_IN, { Scale = 1 })
end

local function hideStartCount()
	if lastStartSecond == nil then
		return
	end
	lastStartSecond = nil
	tween(startCountLabel, TweenInfo.new(0.25), { TextTransparency = 1 })
	tween(startCountStroke, TweenInfo.new(0.25), { Transparency = 1 })
end

local intermissionCard = nil -- the sticky countdown card; exempt from eviction
local aliveCard = nil -- sticky "N PLAYERS ALIVE" card for dead spectators; also exempt
local waitingCard = nil -- sticky "Waiting for players..." card (WAITING state); also exempt
local waitingLabel = nil

function pushNotif(text, style, duration) -- assigns the forward-declared local
	local card, label = buildNotifCard(text, style)
	if not card then
		return
	end
	notifCounter += 1
	card.Name = "Notif" .. notifCounter
	card.LayoutOrder = -notifCounter -- newest on top
	card.Parent = notifStack

	-- Evict the oldest card once the stack is full (highest LayoutOrder).
	-- The sticky cards (intermission countdown, alive counter) neither count
	-- nor get evicted.
	local cards = {}
	for _, c in ipairs(notifStack:GetChildren()) do
		if c:IsA("Frame") and c ~= intermissionCard and c ~= aliveCard and c ~= waitingCard then
			table.insert(cards, c)
		end
	end
	if #cards > NOTIF_MAX then
		table.sort(cards, function(a, b)
			return a.LayoutOrder > b.LayoutOrder
		end)
		cards[1]:Destroy()
	end

	local scale = ensureScale(card)
	scale.Scale = 0.6
	tween(scale, POP_IN, { Scale = 1 })

	task.delay(duration or NOTIF_LIFETIME, function()
		if not card.Parent then
			return -- already evicted
		end
		fadeOutCard(card, label)
	end)
end

-- Hook up the remote off the main thread; the UI must never stall (or break)
-- if the Bullrush systems are missing from a place copy.
task.spawn(function()
	local bullrush = ReplicatedStorage:WaitForChild("Bullrush", 30)
	local remotes = bullrush and bullrush:FindFirstChild("Remotes")
	local notifyRemote = remotes and remotes:FindFirstChild("Notify")
	if not (notifyRemote and notifyRemote:IsA("RemoteEvent")) then
		warn("[Main] Notify remote missing; notification cards disabled")
		return
	end

	-- Rare-roll chat lines wear their rarity's shared text gradient
	-- (Config.rarityGradient). Chat labels can't take a UIGradient, so the
	-- gradient is sampled left -> right into rich-text <font color> runs.
	local okChatCat, chatCatalog = pcall(require, bullrush:FindFirstChild("BullCatalog"))
	local okChatCfg, chatCfg = pcall(require, bullrush:FindFirstChild("Config"))
	local function rarityRichText(text, rarity)
		local rr = okChatCat and chatCatalog and chatCatalog.Rarities and chatCatalog.Rarities[rarity]
		if not (rr and rr.color and okChatCfg and chatCfg and chatCfg.rarityGradient) then
			return text
		end
		local keypoints = chatCfg.rarityGradient(rr.color).Keypoints
		local function sample(t)
			for i = 1, #keypoints - 1 do
				local a, b = keypoints[i], keypoints[i + 1]
				if t <= b.Time then
					local span = b.Time - a.Time
					return a.Value:Lerp(b.Value, if span > 0 then (t - a.Time) / span else 0)
				end
			end
			return keypoints[#keypoints].Value
		end
		-- utf8-safe split (font tags mid-codepoint would corrupt the char),
		-- escaping the rich-text metacharacters in the raw message
		local chars = {}
		for _, code in utf8.codes(text) do
			local ch = utf8.char(code)
			if ch == "&" then
				ch = "&amp;"
			elseif ch == "<" then
				ch = "&lt;"
			elseif ch == ">" then
				ch = "&gt;"
			end
			table.insert(chars, ch)
		end
		local n = #chars
		-- fixed number of colour runs (not per character) keeps markup small
		local per = math.ceil(n / math.min(n, 16))
		local runs = {}
		for i = 1, n, per do
			local last = math.min(i + per - 1, n)
			local col = sample(if n > 1 then ((i + last) / 2 - 1) / (n - 1) else 0)
			table.insert(runs, ('<font color="#%02X%02X%02X">%s</font>'):format(
				math.round(col.R * 255), math.round(col.G * 255), math.round(col.B * 255),
				table.concat(chars, "", i, last)))
		end
		return table.concat(runs)
	end

	notifyRemote.OnClientEvent:Connect(function(text, style, duration, rarity)
		if typeof(text) ~= "string" or text == "" then
			return
		end
		-- "chat" style (roll announcements) prints a system line in the chat
		-- window instead of stacking a card. RBXGeneral is the default channel
		-- TextChatService creates; if chat is disabled/absent, drop silently
		-- (server-wide flavour text, never gameplay-critical).
		if style == "chat" then
			local TextChatService = game:GetService("TextChatService")
			local channels = TextChatService:FindFirstChild("TextChannels")
			local general = channels and channels:FindFirstChild("RBXGeneral")
			if general and general:IsA("TextChannel") then
				local body = text:sub(1, 120)
				if typeof(rarity) == "string" then
					local ok, rich = pcall(rarityRichText, body, rarity)
					if ok then
						body = rich
					end
				end
				general:DisplaySystemMessage("[System]: " .. body)
			end
			return
		end
		pushNotif(
			text:sub(1, 120),
			(if typeof(style) == "string" then style else "white"),
			tonumber(duration)
		)
	end)

	-- Two things ride the per-second RoundState resends (Main.server round loop):
	-- the CurrentArea HUD banner shows the current/upcoming GAME TYPE (mode), and a
	-- single sticky notif card shows JUST the countdown during intermission.
	local currentArea = SideUI:FindFirstChild("Top") and SideUI.Top:FindFirstChild("CurrentArea")
	local areaWordA = currentArea and currentArea:FindFirstChild("Rarity")    -- accent (gradient) word
	local areaWordB = currentArea and currentArea:FindFirstChild("TextLabel") -- plain white word
	-- mode.name -> { accent word, white word, accent colour }
	local GAME_TYPE = {
		["Classic"] = { "Classic", "Mode", Color3.fromRGB(95, 175, 255) },
		["Mega Grid"] = { "Large", "Grid", Color3.fromRGB(255, 150, 40) },
		["Small Grid"] = { "Small", "Grid", Color3.fromRGB(90, 220, 110) },
		["Stampede"] = { "Stampede", "Mode", Color3.fromRGB(255, 80, 70) },
		["Team Rush"] = { "Teams", "Mode", Color3.fromRGB(200, 120, 255) },
		["High Speed"] = { "High", "Speed", Color3.fromRGB(255, 221, 51) },
	}
	local function paintGameType(modeName)
		if not (currentArea and areaWordA and areaWordA:IsA("TextLabel")) then
			return
		end
		local g = GAME_TYPE[modeName]
		local col = (g and g[3]) or Color3.fromRGB(255, 255, 255)
		areaWordA.Text = (g and g[1]) or modeName
		if areaWordB and areaWordB:IsA("TextLabel") then
			areaWordB.Text = (g and g[2]) or "Round"
		end
		-- retint the accent word's kit gradient (ships named "Epic") to the mode colour
		local grad = areaWordA:FindFirstChildOfClass("UIGradient")
		if grad then
			grad.Rotation = -90
			grad.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, col:Lerp(Color3.new(1, 1, 1), 0.45)),
				ColorSequenceKeypoint.new(0.1, col:Lerp(Color3.new(1, 1, 1), 0.45)),
				ColorSequenceKeypoint.new(0.9, col),
				ColorSequenceKeypoint.new(1, col),
			})
		end
		if not currentArea.Visible then
			currentArea.Visible = true
			local scale = ensureScale(currentArea)
			scale.Scale = 0.6
			tween(scale, POP_IN, { Scale = 1 })
		end
	end

	local stateRemote = remotes:FindFirstChild("RoundState")
	if stateRemote and stateRemote:IsA("RemoteEvent") then
		local intermissionLabel = nil
		local waitingToken = 0 -- bumped by non-WAITING states to cancel a pending show
		local waitingPending = false -- a delayed show is already scheduled
		if currentArea then
			currentArea.Visible = false -- hidden until the first state that carries a mode
		end
		stateRemote.OnClientEvent:Connect(function(state, info)
			info = if typeof(info) == "table" then info else {}

			-- WAITING card: sticky "Waiting for players" with cycling dots while
			-- the server sits below MIN_PLAYERS (the server resends WAITING every
			-- 0.5s for as long as that holds). WAITING also blips past ONCE at
			-- the top of every round loop on a busy server (straight into
			-- INTERMISSION), so the card only appears after the state has stuck
			-- around for a second; any other state cancels the pending show.
			if state == "WAITING" then
				if not (waitingCard and waitingCard.Parent) and not waitingPending then
					waitingPending = true
					local token = waitingToken
					task.delay(1, function()
						waitingPending = false
						if token ~= waitingToken or (waitingCard and waitingCard.Parent) then
							return
						end
						local card, label = buildNotifCard("Waiting for players.", "white")
						if not card then
							return
						end
						card.Name = "WaitingForPlayers"
						card.LayoutOrder = -1e9 -- pinned above every transient card
						card.Parent = notifStack
						waitingCard, waitingLabel = card, label
						local scale = ensureScale(card)
						scale.Scale = 0.6
						tween(scale, POP_IN, { Scale = 1 })
						-- One loop per card: it dies with the card, so repeated
						-- WAITING resends can't stack a second animator.
						task.spawn(function()
							local dots = 1
							while card.Parent do
								label.Text = "Waiting for players" .. string.rep(".", dots)
								dots = dots % 3 + 1
								task.wait(0.5)
							end
						end)
					end)
				end
			else
				waitingToken += 1 -- cancels a pending show scheduled above
				if waitingCard then
					local card, label = waitingCard, waitingLabel
					waitingCard, waitingLabel = nil, nil
					if card.Parent then
						fadeOutCard(card, label)
					end
				end
			end

			-- GAME TYPE banner: show the mode whenever one is known, hide otherwise (WAITING)
			local modeName = if typeof(info.modeName) == "string" then info.modeName else nil
			if modeName then
				paintGameType(modeName)
			elseif currentArea then
				currentArea.Visible = false
			end

			-- COUNTDOWN card: just the timer, one sticky card, only during the
			-- lobby intermission. The post-teleport `starting` phase (Main.server)
			-- skips the card entirely and lands as the big center-screen digits.
			local timeLeft = tonumber(info.timeLeft)
			local starting = state == "INTERMISSION" and timeLeft ~= nil and info.starting == true
			if starting then
				showStartCount(math.max(1, math.floor(timeLeft + 0.5)))
			else
				hideStartCount()
			end
			if state == "INTERMISSION" and timeLeft and not starting then
				local seconds = math.max(0, math.floor(timeLeft + 0.5))
				local text = ("NEXT ROUND IN %ds"):format(seconds)
				if intermissionCard and intermissionCard.Parent then
					if intermissionLabel then
						intermissionLabel.Text = text
					end
				else
					local card, label = buildNotifCard(text, "white")
					if card then
						card.Name = "IntermissionTimer"
						card.LayoutOrder = -1e9 -- pinned above every transient card
						card.Parent = notifStack
						intermissionCard, intermissionLabel = card, label
						local scale = ensureScale(card)
						scale.Scale = 0.6
						tween(scale, POP_IN, { Scale = 1 })
					end
				end
			elseif intermissionCard then
				local card, label = intermissionCard, intermissionLabel
				intermissionCard, intermissionLabel = nil, nil
				if card.Parent then
					fadeOutCard(card, label)
				end
			end
		end)
	end
end)

-- Elimination side feed: eliminations skip the notif card stack and show on
-- the right edge instead, newest on top. Three row shapes, keyed by the
-- cause the server sends with Remotes.Eliminated:
--   PUSH   [pusher head] Pusher ELIMINATED Victim [victim head]
--   FELL   Victim FELL [victim head]           (boundary / void / reset)
--   other  Victim ELIMINATED [victim head]     (BULL, REVENGE, LEFT)
-- Lives in notifGui so panels can't cover it.
local ELIM_LIFETIME = 3
local ELIM_MAX = 6

local elimStack = Instance.new("Frame")
elimStack.Name = "ElimStack"
elimStack.AnchorPoint = Vector2.new(1, 0.5)
-- Centered in the upper third of the right edge: high enough that a full
-- stack can't spill over the push button parked at the edge's midpoint.
elimStack.Position = UDim2.new(1, -10, 0.32, 0)
elimStack.Size = UDim2.new(0, 340, 0, 320)
elimStack.BackgroundTransparency = 1
elimStack.Parent = notifGui

local elimLayout = Instance.new("UIListLayout")
elimLayout.FillDirection = Enum.FillDirection.Vertical
elimLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
elimLayout.VerticalAlignment = Enum.VerticalAlignment.Center
elimLayout.SortOrder = Enum.SortOrder.LayoutOrder
elimLayout.Padding = UDim.new(0, 6)
elimLayout.Parent = elimStack

-- The feed is fixed-pixel (340-wide stack, 40px rows, 22px lettering), so on
-- a phone viewport it eats a big slice of the right edge. One UIScale on the
-- stack shrinks the whole feed toward the viewport (same 1280x720 baseline
-- and 0.65 floor as the vote panel); touch-only devices (phone/tablet, same
-- test as the push button's TAP hint) take a further ELIM_TOUCH_SCALE cut,
-- because even the floored size crowds the right edge next to touch controls.
-- Desktop keeps scale 1. Scaling happens about the stack's (1, 0.5)
-- AnchorPoint, so it stays pinned to the right edge, and each row's own
-- pop-in UIScale composes on top.
local UserInputService = game:GetService("UserInputService")
local ELIM_TOUCH_SCALE = 0.49
local elimStackScale = ensureScale(elimStack)
local function elimFitScale(): number
	local cam = workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	local fit = math.clamp(math.min(vp.X / 1280, vp.Y / 720), 0.65, 1)
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		fit *= ELIM_TOUCH_SCALE
	end
	return fit
end
local function refitElim()
	elimStackScale.Scale = elimFitScale()
end
-- refit on rotation / window resize (the camera can be swapped out on
-- respawn, so re-hook whenever CurrentCamera changes)
local function watchElimViewport()
	local cam = workspace.CurrentCamera
	if cam then
		cam:GetPropertyChangedSignal("ViewportSize"):Connect(refitElim)
	end
	refitElim()
end
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchElimViewport)
watchElimViewport()

local elimCounter = 0

local ELIM_VERB_RED = "#FF4A3C" -- ELIMINATED lettering
local ELIM_VERB_ICE = "#A8CEFF" -- FELL lettering

-- Names land inside RichText markup, and display names are player-typed.
local function richEscape(s)
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- Display name + UserId for the head shot. Bots aren't real players (no
-- UserId to thumbnail), so they resolve to their raw name and no head.
local function elimIdentity(name)
	local p = Players:FindFirstChild(name)
	if p and p:IsA("Player") and p.UserId > 0 then
		return p.DisplayName, p.UserId
	end
	return name, nil
end

local function pushElim(victimName, cause, byName)
	elimCounter += 1
	local row = Instance.new("Frame")
	row.Name = "Elim" .. elimCounter
	row.LayoutOrder = -elimCounter -- newest on top
	row.AutomaticSize = Enum.AutomaticSize.X
	row.Size = UDim2.new(0, 0, 0, 40)
	row.BackgroundTransparency = 1

	-- Heads and lettering flow right-to-left off the screen edge; the
	-- victim's head is always the rightmost element, so "who died" reads
	-- as a steady column even when row shapes mix.
	local rowLayout = Instance.new("UIListLayout")
	rowLayout.FillDirection = Enum.FillDirection.Horizontal
	rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rowLayout.Padding = UDim.new(0, 6)
	rowLayout.Parent = row

	local victimDisplay = elimIdentity(victimName)
	local text
	if cause == "PUSH" and typeof(byName) == "string" and byName ~= "" then
		local pusherDisplay = elimIdentity(byName)
		text = ('%s <font color="%s">ELIMINATED</font> %s'):format(
			richEscape(pusherDisplay), ELIM_VERB_RED, richEscape(victimDisplay))
	elseif cause == "FELL" then
		text = ('%s <font color="%s">FELL</font>'):format(
			richEscape(victimDisplay), ELIM_VERB_ICE)
	else -- BULL, REVENGE, LEFT, and anything untagged
		text = ('%s <font color="%s">ELIMINATED</font>'):format(
			richEscape(victimDisplay), ELIM_VERB_RED)
	end

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.LayoutOrder = 2
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Size = UDim2.new(0, 0, 0, 24)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.RichText = true
	label.Text = text
	label.TextSize = 22
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(0, 0, 0)
	stroke.Thickness = 2
	stroke.Parent = label
	label.Parent = row

	row.Parent = elimStack

	-- Evict the oldest row once the feed is full (highest LayoutOrder).
	local rows = {}
	for _, r in ipairs(elimStack:GetChildren()) do
		if r:IsA("Frame") then
			table.insert(rows, r)
		end
	end
	if #rows > ELIM_MAX then
		table.sort(rows, function(a, b)
			return a.LayoutOrder > b.LayoutOrder
		end)
		rows[1]:Destroy()
	end

	local scale = ensureScale(row)
	scale.Scale = 0.6
	tween(scale, POP_IN, { Scale = 1 })

	task.delay(ELIM_LIFETIME, function()
		if not row.Parent then
			return -- already evicted
		end
		tween(label, TweenInfo.new(0.35), { TextTransparency = 1 })
		tween(stroke, TweenInfo.new(0.35), { Transparency = 1 })
		for _, child in ipairs(row:GetChildren()) do
			if child:IsA("ImageLabel") then
				tween(child, TweenInfo.new(0.35), {
					ImageTransparency = 1,
					BackgroundTransparency = 1,
				})
			end
		end
		task.delay(0.4, function()
			row:Destroy()
		end)
	end)
end

task.spawn(function()
	local bullrush = ReplicatedStorage:WaitForChild("Bullrush", 30)
	local remotes = bullrush and bullrush:FindFirstChild("Remotes")
	local elimRemote = remotes and remotes:FindFirstChild("Eliminated")
	if not (elimRemote and elimRemote:IsA("RemoteEvent")) then
		warn("[Main] Eliminated remote missing; elimination feed disabled")
		return
	end
	elimRemote.OnClientEvent:Connect(function(playerName, _aliveCount, cause, byName)
		if typeof(playerName) ~= "string" or playerName == "" then
			return
		end
		pushElim(playerName, cause, byName)
	end)
end)

---------------------------------------------------------------- 6b) alive counter
-- Spectators keep score: while an ACTIVE round is on and YOU are outside it
-- (eliminated, joined mid-round, sat out in the lobby), a sticky card in the
-- notif stack shows how many players are still in ("5 PLAYERS ALIVE").
-- Visibility rides RevengeViewBridge's "Eligible" attribute (BullrushClient
-- maintains it as ACTIVE + round spectator — the same gate as the bull-cam
-- button); the count rides Remotes.Eliminated (fires per elimination with the
-- remaining count) topped up by RoundState ACTIVE resends (per-wave
-- aliveCount, catches leavers between eliminations — and seeds a fresh
-- joiner via the PlayerAdded resend in Main.server).
task.spawn(function()
	local bullrush = ReplicatedStorage:WaitForChild("Bullrush", 30)
	local remotes = bullrush and bullrush:FindFirstChild("Remotes")
	local bridge = ReplicatedStorage:WaitForChild("RevengeViewBridge", 30)
	if not (remotes and bridge and bridge:IsA("BindableEvent")) then
		return -- Bullrush systems absent from this place copy; no counter
	end

	local lastAlive = nil -- freshest server-reported alive count, tracked always
	local aliveLabel = nil

	local function aliveText()
		return if lastAlive == 1 then "1 PLAYER ALIVE" else lastAlive .. " PLAYERS ALIVE"
	end

	local function refresh()
		local show = bridge:GetAttribute("Eligible") == true and lastAlive ~= nil
		if show then
			if aliveCard and aliveCard.Parent then
				if aliveLabel then
					aliveLabel.Text = aliveText()
				end
			else
				local card, label = buildNotifCard(aliveText(), "red")
				if card then
					card.Name = "AliveCounter"
					card.LayoutOrder = -1e9 + 1 -- sticky, pinned like the countdown card
					card.Parent = notifStack
					aliveCard, aliveLabel = card, label
					local scale = ensureScale(card)
					scale.Scale = 0.6
					tween(scale, POP_IN, { Scale = 1 })
				end
			end
		elseif aliveCard then
			local card, label = aliveCard, aliveLabel
			aliveCard, aliveLabel = nil, nil
			if card.Parent then
				fadeOutCard(card, label)
			end
		end
	end

	bridge:GetAttributeChangedSignal("Eligible"):Connect(refresh)

	local elimRemote = remotes:FindFirstChild("Eliminated")
	if elimRemote and elimRemote:IsA("RemoteEvent") then
		elimRemote.OnClientEvent:Connect(function(_playerName, aliveCount)
			if tonumber(aliveCount) then
				lastAlive = tonumber(aliveCount)
				refresh()
			end
		end)
	end

	local stateRemote = remotes:FindFirstChild("RoundState")
	if stateRemote and stateRemote:IsA("RemoteEvent") then
		stateRemote.OnClientEvent:Connect(function(state, info)
			if state == "ACTIVE" and typeof(info) == "table" and tonumber(info.aliveCount) then
				lastAlive = tonumber(info.aliveCount)
			end
			refresh()
		end)
	end

	refresh()
end)

---------------------------------------------------------------- 7) HUD counters
-- Live readouts for the SideUI.Counters row: Cash shows leaderstats.Money
-- (DataHandler mirrors the profile there) and Speed shows the character's
-- actual Humanoid.WalkSpeed. Each binding runs off the main thread so a
-- missing folder (e.g. data failed to load in Studio) can't stall the UI.
local function comma(n)
	local s = tostring(math.floor(n + 0.5))
	while true do
		local out, replaced = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
		s = out
		if replaced == 0 then
			return s
		end
	end
end

local cashLabel = counters and counters:FindFirstChild("Cash")
cashLabel = cashLabel and cashLabel:FindFirstChild("Amount")
if cashLabel then
	cashLabel.Text = "$0"

	-- Floating "+$X"/"-$X" delta that pops to the RIGHT of the Cash counter
	-- whenever Money changes. The label is a clone of the counter's Amount so it
	-- wears the exact money-green gradient/stroke; spends disable the gradient
	-- and go red. Changes landing while a popup is still holding fold into it
	-- (one label, summed amount) instead of stacking. It lives in its own
	-- max-DisplayOrder ScreenGui so it draws over every other panel; it can't
	-- sit inside the Cash frame anyway — the UIListLayout there would lay it out.
	local DELTA_HOLD = 0.9 -- seconds the popup lingers (restarts on fold-in)
	local DELTA_FADE = 0.45
	local activeDelta -- popup still in its hold window; nil once fading starts

	local deltaGui = Instance.new("ScreenGui")
	deltaGui.Name = "CashDeltaGui"
	deltaGui.ResetOnSpawn = false
	deltaGui.DisplayOrder = 1000
	deltaGui.Parent = gui.Parent

	-- The Cash frame itself is kit-sized far wider than its content, so anchor
	-- off the right edge of its widest visible child (Amount text / Buy button).
	local function contentRightEdge(frame)
		local right = frame.AbsolutePosition.X
		for _, child in frame:GetChildren() do
			if child:IsA("GuiObject") and child.Visible then
				right = math.max(right, child.AbsolutePosition.X + child.AbsoluteSize.X)
			end
		end
		return right
	end

	-- Gains get the library ka-ching (GameSFX.Cash), same clone-and-reap idiom
	-- as playUiSound so overlapping pops never cut each other off.
	local function playKaching()
		-- GameSFX.Kaching = full register cha-ching (the old "Cash" clip is a very
		-- quiet 0.7s stub; still used by SoundDirector, kept as the fallback here)
		local template = sfxGroup and (sfxGroup:FindFirstChild("Kaching") or sfxGroup:FindFirstChild("Cash"))
		if not (template and template:IsA("Sound")) then
			return
		end
		local ok, s = pcall(function()
			return template:Clone()
		end)
		if not ok or not s then
			return
		end
		s.SoundGroup = sfxGroup
		s.Volume = 3 -- new recording runs quiet; tune here once heard in game
		s.Parent = SoundService
		pcall(function()
			s:Play()
		end)
		Debris:AddItem(s, 4)
	end

	local function popDelta(delta)
		local popup = activeDelta
		if popup and popup.label.Parent then
			popup.amount += delta
			popup.epoch += 1
		else
			local cashFrame = cashLabel.Parent
			local label = cashLabel:Clone()
			label.Name = "CashDelta"
			label.AnchorPoint = Vector2.new(0, 1)
			label.TextXAlignment = Enum.TextXAlignment.Left
			label.TextScaled = true
			label.ZIndex = 10
			label.Parent = deltaGui
			local origin = cashLabel.AbsolutePosition - deltaGui.AbsolutePosition
			label.Position = UDim2.fromOffset(
				contentRightEdge(cashFrame) - deltaGui.AbsolutePosition.X + 12,
				origin.Y - 2
			)
			label.Size = UDim2.fromOffset(200, math.max(18, math.floor(cashLabel.AbsoluteSize.Y * 0.9 + 0.5)))
			popup = { label = label, amount = delta, epoch = 1 }
			activeDelta = popup
			if delta > 0 then -- ka-ching once per popup, not per fold-in
				playKaching()
			end
		end

		local amount = popup.amount
		if amount == 0 then -- a gain and a spend cancelled out mid-hold
			popup.label:Destroy()
			if activeDelta == popup then
				activeDelta = nil
			end
			return
		end
		local label = popup.label
		label.Text = (amount > 0 and "+$" or "-$") .. comma(math.abs(amount))
		local gradient = label:FindFirstChildOfClass("UIGradient")
		if gradient then
			gradient.Enabled = amount > 0
		end
		label.TextColor3 = amount > 0 and cashLabel.TextColor3 or Color3.fromRGB(235, 80, 80)

		local myEpoch = popup.epoch
		task.delay(DELTA_HOLD, function()
			if popup.epoch ~= myEpoch or not label.Parent then
				return -- a newer change restarted the clock (or we're gone)
			end
			if activeDelta == popup then
				activeDelta = nil -- changes from here on get a fresh popup
			end
			local info = TweenInfo.new(DELTA_FADE, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			TweenService:Create(label, info, {
				Position = label.Position - UDim2.fromOffset(0, 26),
				TextTransparency = 1,
			}):Play()
			local stroke = label:FindFirstChildOfClass("UIStroke")
			if stroke then
				TweenService:Create(stroke, info, { Transparency = 1 }):Play()
			end
			Debris:AddItem(label, DELTA_FADE + 0.1)
		end)
	end

	task.spawn(function()
		local leaderstats = player:WaitForChild("leaderstats", 30)
		local money = leaderstats and leaderstats:WaitForChild("Money", 10)
		if not money then
			warn("[Main] leaderstats.Money missing; Cash counter left at $0")
			return
		end
		local lastMoney = money.Value -- no popup for the initial load
		local function refresh()
			cashLabel.Text = "$" .. comma(money.Value)
		end
		money.Changed:Connect(function(value)
			local delta = value - lastMoney
			lastMoney = value
			refresh()
			if delta ~= 0 then
				popDelta(delta)
			end
		end)
		refresh()
	end)
end

local boostLabel = counters and counters:FindFirstChild("Boost")
boostLabel = boostLabel and boostLabel:FindFirstChild("CurrentBoost")
if boostLabel then
	-- FriendBoostService replicates the friends-in-server money boost here.
	local function refreshBoost()
		local percent = tonumber(player:GetAttribute("FriendBoostPercent")) or 0
		boostLabel.Text = ("Friend Boost: +%d%%"):format(percent)
	end
	player:GetAttributeChangedSignal("FriendBoostPercent"):Connect(refreshBoost)
	refreshBoost()
end

-- Bottom-right perk badges (SideUI.Boosts). The kit ships a VIP crown slot and a
-- Luck clover slot (its Amount label placeholders "+150%"); we drive them off the
-- player's live attributes: IsVIP for the crown, RollLuck (the total Epic/Legendary
-- roll multiplier MonetizationService replicates) for the clover. The container
-- (and each unearned slot) hides until a perk is actually active.
local boostsFrame = SideUI:FindFirstChild("Boosts")
if boostsFrame then
	local vipSlot = boostsFrame:FindFirstChild("VIP")
	local luckSlot = boostsFrame:FindFirstChild("Luck")
	local luckAmount = luckSlot and luckSlot:FindFirstChild("Icon")
	luckAmount = luckAmount and luckAmount:FindFirstChild("Amount")

	-- "×2", "×7.5" — one decimal, trailing ".0" trimmed.
	local function fmtLuck(m)
		return "×" .. (string.format("%.1f", m):gsub("%.0$", ""))
	end

	local function refreshBoosts()
		local isVip = player:GetAttribute("IsVIP") == true
		local luck = tonumber(player:GetAttribute("RollLuck")) or 1
		local hasLuck = luck > 1.0001
		if vipSlot then
			vipSlot.Visible = isVip
		end
		if luckSlot then
			luckSlot.Visible = hasLuck
		end
		if luckAmount and hasLuck then
			luckAmount.Text = fmtLuck(luck)
		end
		boostsFrame.Visible = isVip or hasLuck
	end

	player:GetAttributeChangedSignal("IsVIP"):Connect(refreshBoosts)
	player:GetAttributeChangedSignal("RollLuck"):Connect(refreshBoosts)
	refreshBoosts()
end

local speedLabel = counters and counters:FindFirstChild("Speed")
speedLabel = speedLabel and speedLabel:FindFirstChild("Amount")
if speedLabel then
	speedLabel.Text = "24" -- default WalkSpeed, shown until the humanoid binds
	local walkSpeedConn
	local function bindCharacter(character)
		if walkSpeedConn then
			walkSpeedConn:Disconnect()
			walkSpeedConn = nil
		end
		local humanoid = character:WaitForChild("Humanoid", 10)
		if not humanoid then
			return
		end
		local function refresh()
			speedLabel.Text = tostring(math.floor(humanoid.WalkSpeed + 0.5))
		end
		walkSpeedConn = humanoid:GetPropertyChangedSignal("WalkSpeed"):Connect(refresh)
		refresh()
	end
	player.CharacterAdded:Connect(bindCharacter)
	if player.Character then
		task.spawn(bindCharacter, player.Character)
	end
end

---------------------------------------------------------------- 8) round summary
-- Round-end recap (Frames.Summary): the server mails every REAL participant a
-- RoundSummary payload at round end (EconomyService.settle - see the contract
-- in GridUtil's header). The payload is HELD until the player is back in the
-- lobby (the WAITING/INTERMISSION state right after the teleport), then the
-- tab auto-opens with the winner's portrait + name — or, when the herd got
-- everyone, the wave bull itself (real BullTemplate model in a ViewportFrame)
-- standing in as the winner — the winner's equipped bull (real catalog model
-- in a ViewportFrame) in the corner TinyBox — falling back to your portrait +
-- placement on herd/bot wins — plus the Money you earned, and an itemized
-- breakdown line; it auto-closes when the next round goes ACTIVE. The kit's XP row stays hidden until an XP system exists. The
-- "2x Rewards?" button prompts the Config.PRODUCTS.DOUBLE_ROUND dev product;
-- the server answers a granted receipt with an { update = true } resend.
local MarketplaceService = game:GetService("MarketplaceService")

local summaryFrame = Frames:FindFirstChild("Summary")
local summaryMain = summaryFrame and summaryFrame:FindFirstChild("Main")
if summaryMain then
	local seeker = summaryMain:FindFirstChild("Seeker")
	local winnerIcon = seeker and seeker:FindFirstChild("PlayerIcon")
	local winnerLabel = seeker and seeker:FindFirstChild("PlayerName")
	local coinsAmount = summaryMain:FindFirstChild("CoinsAmount")
	local xpAmount = summaryMain:FindFirstChild("XpAmount")
	local doubleButton = summaryMain:FindFirstChild("2xRewards")
	local tinyBox = summaryMain:FindFirstChild("TinyBox")
	local tinyIcon = tinyBox and tinyBox:FindFirstChild("ImageLabel")
	local tinyText = tinyBox and tinyBox:FindFirstChild("TextLabel")

	-- The kit's caption labels are unnamed (" "); identify them by their
	-- designed text before we retitle anything.
	local xpCaption, coinsCaption
	for _, child in ipairs(summaryMain:GetChildren()) do
		if child:IsA("TextLabel") then
			if child.Text == "Xp" then
				xpCaption = child
			elseif child.Text == "Coins" then
				coinsCaption = child
			end
		end
	end

	-- Money text everywhere in the recap wears the SAME style as the HUD's
	-- bottom-left Cash counter (green gradient + dark-green stroke), copied
	-- from that label at runtime so a future retint can't drift apart.
	local cashStyleSource = counters and counters:FindFirstChild("Cash")
	cashStyleSource = cashStyleSource and cashStyleSource:FindFirstChild("Amount")
	local function paintMoneyStyle(label)
		if not (cashStyleSource and label) then
			return
		end
		label.TextColor3 = cashStyleSource.TextColor3
		local sourceGradient = cashStyleSource:FindFirstChildOfClass("UIGradient")
		if sourceGradient then
			local gradient = label:FindFirstChildOfClass("UIGradient")
			if not gradient then
				gradient = Instance.new("UIGradient")
				gradient.Parent = label
			end
			gradient.Color = sourceGradient.Color
			gradient.Transparency = sourceGradient.Transparency
			gradient.Rotation = sourceGradient.Rotation
		end
		local sourceStroke = cashStyleSource:FindFirstChildOfClass("UIStroke")
		local stroke = label:FindFirstChildOfClass("UIStroke")
		if sourceStroke and stroke then
			stroke.Color = sourceStroke.Color -- keep the label's own thickness
		end
	end

	-- Earnings receipt: a matching dark panel hanging off the card's right
	-- edge (the purchased card design itself stays untouched) with one row
	-- per payout category - kit-styled label left, gold amount right.
	-- Templates are cloned from the kit's own coins labels BEFORE any rows
	-- move or retitle, so they inherit the font/stroke/gradient look.
	local earningsPanel, earningsRows, rowLabelTemplate, rowAmountTemplate
	if coinsCaption and coinsAmount then
		earningsPanel = Instance.new("Frame")
		earningsPanel.Name = "EarningsPanel"
		earningsPanel.AnchorPoint = Vector2.new(0, 0.5)
		earningsPanel.Position = UDim2.new(1.02, 0, 0.46, 0)
		earningsPanel.Size = UDim2.new(0.44, 0, 0.66, 0)
		earningsPanel.BackgroundColor3 = summaryMain.BackgroundColor3
		earningsPanel.BackgroundTransparency = summaryMain.BackgroundTransparency
		earningsPanel.Visible = false
		for _, deco in ipairs(summaryMain:GetChildren()) do
			if deco:IsA("UICorner") or deco:IsA("UIStroke") then
				deco:Clone().Parent = earningsPanel
			end
		end

		local header = coinsCaption:Clone()
		header.Name = "Header"
		local headerRatio = header:FindFirstChildOfClass("UIAspectRatioConstraint")
		if headerRatio then
			headerRatio:Destroy()
		end
		header.AnchorPoint = Vector2.new(0.5, 0)
		header.Position = UDim2.new(0.5, 0, 0.04, 0)
		header.Size = UDim2.new(0.9, 0, 0.11, 0)
		header.TextXAlignment = Enum.TextXAlignment.Center
		header.Text = "Earnings"
		header.Parent = earningsPanel

		earningsRows = Instance.new("Frame")
		earningsRows.Name = "Rows"
		earningsRows.BackgroundTransparency = 1
		earningsRows.AnchorPoint = Vector2.new(0.5, 0)
		earningsRows.Position = UDim2.new(0.5, 0, 0.18, 0)
		earningsRows.Size = UDim2.new(0.86, 0, 0.78, 0)
		earningsRows.Parent = earningsPanel
		local rowsLayout = Instance.new("UIListLayout")
		rowsLayout.FillDirection = Enum.FillDirection.Vertical
		rowsLayout.SortOrder = Enum.SortOrder.LayoutOrder
		rowsLayout.Padding = UDim.new(0.012, 0)
		rowsLayout.Parent = earningsRows

		-- white label so the gold amount pops
		rowLabelTemplate = coinsCaption:Clone()
		local labelGradient = rowLabelTemplate:FindFirstChildOfClass("UIGradient")
		if labelGradient then
			labelGradient:Destroy()
		end
		local labelRatio = rowLabelTemplate:FindFirstChildOfClass("UIAspectRatioConstraint")
		if labelRatio then
			labelRatio:Destroy()
		end
		rowLabelTemplate.TextColor3 = Color3.fromRGB(255, 255, 255)
		rowLabelTemplate.TextXAlignment = Enum.TextXAlignment.Left
		rowLabelTemplate.AnchorPoint = Vector2.new(0, 0.5)
		rowLabelTemplate.Position = UDim2.new(0, 0, 0.5, 0)
		rowLabelTemplate.Size = UDim2.new(0.6, 0, 1, 0)

		rowAmountTemplate = coinsAmount:Clone()
		local amountRatio = rowAmountTemplate:FindFirstChildOfClass("UIAspectRatioConstraint")
		if amountRatio then
			amountRatio:Destroy()
		end
		rowAmountTemplate.TextXAlignment = Enum.TextXAlignment.Right
		rowAmountTemplate.AnchorPoint = Vector2.new(1, 0.5)
		rowAmountTemplate.Position = UDim2.new(1, 0, 0.5, 0)
		rowAmountTemplate.Size = UDim2.new(0.38, 0, 1, 0)

		paintMoneyStyle(header)
		paintMoneyStyle(rowAmountTemplate) -- rows clone the template, style included

		earningsPanel.Parent = summaryFrame
	end

	local function rebuildEarnings(lines)
		if not earningsRows then
			return
		end
		for _, child in ipairs(earningsRows:GetChildren()) do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
		earningsPanel.Visible = #lines > 0
		for i, line in ipairs(lines) do
			local row = Instance.new("Frame")
			row.Name = "Row" .. i
			row.BackgroundTransparency = 1
			row.Size = UDim2.new(1, 0, 0.12, 0)
			row.LayoutOrder = i
			local label = rowLabelTemplate:Clone()
			label.Text = tostring(line.label)
			label.Parent = row
			local amount = rowAmountTemplate:Clone()
			amount.Text = "+" .. comma(tonumber(line.amount) or 0)
			amount.Parent = row
			row.Parent = earningsRows
		end
	end

	-- No XP system yet: hide that row and move the money row up into its slot;
	-- the currency in this game is Money, so say so.
	if xpCaption and xpAmount and coinsCaption and coinsAmount then
		xpCaption.Visible = false
		xpAmount.Visible = false
		coinsCaption.Position = xpCaption.Position
		coinsAmount.Position = xpAmount.Position
		coinsCaption.Text = "Money"
		paintMoneyStyle(coinsCaption)
		paintMoneyStyle(coinsAmount)
	end
	if winnerIcon then
		winnerIcon.ScaleType = Enum.ScaleType.Fit -- portraits are square; don't stretch
		winnerIcon.BackgroundTransparency = 1 -- bust PNGs are transparent; kit ships a white plate
	end

	local PLACEHOLDER_PORTRAIT = winnerIcon and winnerIcon.Image or ""
	local defaultNameColor = winnerLabel and winnerLabel.TextColor3
	local TEAM_NAME_COLORS = {
		RED = Color3.fromRGB(255, 92, 74),
		BLUE = Color3.fromRGB(96, 156, 255),
	}

	local function portrait(userId)
		return ("rbxthumb://type=AvatarBust&id=%d&w=420&h=420"):format(userId)
	end

	-- When THE HERD gets everyone there's no player to portrait, so a
	-- ViewportFrame sitting exactly where the kit's winner ImageLabel is
	-- (same slot/aspect) shows the wave bull itself — the real BullTemplate
	-- model that ran everyone down. The ImageLabel stays behind for
	-- player/team wins. The model resolves in the startup task.spawn below,
	-- before any payload can arrive.
	local bullFallbackModel
	local bullModelsFolder -- BullrushAssets.Bulls; per-bull skins for the TinyBox render
	local herdViewport
	if winnerIcon then
		herdViewport = Instance.new("ViewportFrame")
		herdViewport.Name = "HerdWinner"
		herdViewport.BackgroundTransparency = 1
		herdViewport.AnchorPoint = winnerIcon.AnchorPoint
		herdViewport.Position = winnerIcon.Position
		herdViewport.Size = winnerIcon.Size
		herdViewport.ZIndex = winnerIcon.ZIndex
		herdViewport.Ambient = Color3.fromRGB(165, 160, 155)
		herdViewport.LightColor = Color3.fromRGB(255, 250, 240)
		herdViewport.LightDirection = Vector3.new(-0.4, -1, -0.6)
		local iconRatio = winnerIcon:FindFirstChildOfClass("UIAspectRatioConstraint")
		if iconRatio then
			iconRatio:Clone().Parent = herdViewport
		end
		herdViewport.Visible = false
		herdViewport.Parent = seeker
	end

	-- (re)render the wave bull into the winner viewport; returns false when
	-- the model isn't available so populate() can fall back to the kit's
	-- placeholder portrait
	local function renderHerdBull()
		if not (herdViewport and bullFallbackModel) then
			return false
		end
		-- keep the aspect constraint; only the previous render gets swept
		for _, old in ipairs(herdViewport:GetChildren()) do
			if old:IsA("Model") or old:IsA("Camera") then
				old:Destroy()
			end
		end
		local model = bullFallbackModel:Clone()
		model:PivotTo(CFrame.new())
		local center, size = Vector3.zero, Vector3.new(10, 10, 10)
		pcall(function()
			local cf, bbox = model:GetBoundingBox()
			center, size = cf.Position, bbox
		end)
		local camera = Instance.new("Camera")
		-- same 3/4-front framing as the Index cards (bulls face -Z)
		camera.CFrame = CFrame.lookAt(center + Vector3.new(-0.55, 0.42, -1).Unit * size.Magnitude * 0.72, center)
		camera.Parent = herdViewport
		herdViewport.CurrentCamera = camera
		model.Parent = herdViewport
		return true
	end

	-- The corner TinyBox shows the ROUND WINNER's equipped bull — the real
	-- catalog model in a ViewportFrame (same 3/4 framing as the Index cards),
	-- so the recap ends on "here's what the champion was riding". A ViewportFrame
	-- sits exactly over the kit's TinyBox ImageLabel; the ImageLabel stays behind
	-- as the fallback (herd rounds / bot winners with no model -> your portrait +
	-- placement, the kit's original behaviour).
	local tinyBullViewport
	if tinyBox then
		tinyBullViewport = Instance.new("ViewportFrame")
		tinyBullViewport.Name = "WinnerBull"
		tinyBullViewport.BackgroundTransparency = 1
		if tinyIcon then
			tinyBullViewport.AnchorPoint = tinyIcon.AnchorPoint
			tinyBullViewport.Position = tinyIcon.Position
			tinyBullViewport.Size = tinyIcon.Size
			tinyBullViewport.ZIndex = tinyIcon.ZIndex
			local ratio = tinyIcon:FindFirstChildOfClass("UIAspectRatioConstraint")
			if ratio then
				ratio:Clone().Parent = tinyBullViewport
			end
		else
			tinyBullViewport.Size = UDim2.fromScale(1, 1)
		end
		tinyBullViewport.Ambient = Color3.fromRGB(165, 160, 155)
		tinyBullViewport.LightColor = Color3.fromRGB(255, 250, 240)
		tinyBullViewport.LightDirection = Vector3.new(-0.4, -1, -0.6)
		tinyBullViewport.Visible = false
		tinyBullViewport.Parent = tinyBox
	end

	-- (re)render the winner's equipped bull into the TinyBox; returns false when
	-- there's no bull to show (no winnerBull payload / no model) so populate()
	-- falls back to the player's portrait + placement.
	local function renderTinyBull(modelName)
		if not tinyBullViewport then
			return false
		end
		for _, old in ipairs(tinyBullViewport:GetChildren()) do
			if old:IsA("Model") or old:IsA("Camera") then
				old:Destroy()
			end
		end
		local source = (modelName and bullModelsFolder and bullModelsFolder:FindFirstChild(modelName))
			or bullFallbackModel
		if not source then
			return false
		end
		local model = source:Clone()
		model:PivotTo(CFrame.new())
		local center, size = Vector3.zero, Vector3.new(10, 10, 10)
		pcall(function()
			local cf, bbox = model:GetBoundingBox()
			center, size = cf.Position, bbox
		end)
		local camera = Instance.new("Camera")
		camera.CFrame = CFrame.lookAt(center + Vector3.new(-0.55, 0.42, -1).Unit * size.Magnitude * 0.72, center)
		camera.Parent = tinyBullViewport
		tinyBullViewport.CurrentCamera = camera
		model.Parent = tinyBullViewport
		return true
	end

	local function ordinal(n)
		local tens = n % 100
		local suffix = "TH"
		if tens < 11 or tens > 13 then
			local ones = n % 10
			suffix = if ones == 1 then "ST" elseif ones == 2 then "ND" elseif ones == 3 then "RD" else "TH"
		end
		return tostring(n) .. suffix
	end

	local canDouble = false
	local productId = 0 -- filled from Config once the Bullrush folder resolves

	local function populate(data)
		local herdWon = data.winnerName == nil
		local showBull = herdWon and renderHerdBull()
		if herdViewport then
			herdViewport.Visible = showBull
		end
		if winnerIcon then
			winnerIcon.Visible = not showBull
			winnerIcon.Image = if data.winnerUserId then portrait(data.winnerUserId) else PLACEHOLDER_PORTRAIT
		end
		if winnerLabel then
			if data.winnerName then
				winnerLabel.Text = data.winnerName .. " WINS!"
				winnerLabel.TextColor3 = TEAM_NAME_COLORS[data.teamColor] or defaultNameColor
			else
				winnerLabel.Text = "THE HERD WINS!"
				winnerLabel.TextColor3 = defaultNameColor
			end
		end
		-- TinyBox: the winner's equipped bull (real model) when we have one,
		-- otherwise the kit's original your-portrait + placement.
		local winnerBull = if typeof(data.winnerBull) == "table" then data.winnerBull else nil
		local showTinyBull = winnerBull ~= nil and renderTinyBull(winnerBull.modelName)
		if tinyBullViewport then
			tinyBullViewport.Visible = showTinyBull
		end
		if tinyIcon then
			tinyIcon.Visible = not showTinyBull
			if not showTinyBull then
				tinyIcon.Image = portrait(player.UserId)
			end
		end
		if tinyText then
			if showTinyBull then
				tinyText.Text = winnerBull.name or "Bull"
			else
				tinyText.Text = ordinal(tonumber(data.placement) or 1)
			end
		end
		if coinsAmount then
			coinsAmount.Text = "+" .. comma(tonumber(data.total) or 0)
		end
		rebuildEarnings(data.lines or {})
		canDouble = data.canDouble == true
		if doubleButton then
			doubleButton.Visible = canDouble
		end
		-- Sting the reveal so the winner announcement actually lands: a triumphant
		-- fanfare when someone claimed the round (punchier when the winner is YOU),
		-- the defeat cue when the herd wiped everyone out.
		if herdWon then
			playSfx("Lose sound effects", 1.0, 1, 6)
		else
			local youWon = (tonumber(data.placement) or 0) == 1
			playSfx("winner!", if youWon then 1.6 else 1.15, 1, 4)
		end
	end

	if doubleButton then
		doubleButton.Visible = false
		doubleButton.Activated:Connect(function()
			if not canDouble then
				return
			end
			if productId <= 0 then
				-- unpublished stub: no product exists to prompt yet
				pushNotif("2x Rewards is coming soon!", "red", 3)
				return
			end
			local ok = pcall(function()
				MarketplaceService:PromptProductPurchase(player, productId)
			end)
			if not ok then
				pushNotif("Store not available", "red", 3)
			end
		end)
	end

	task.spawn(function()
		local bullrush = ReplicatedStorage:WaitForChild("Bullrush", 30)
		local remotes = bullrush and bullrush:FindFirstChild("Remotes")
		local summaryRemote = remotes and remotes:FindFirstChild("RoundSummary")
		local stateRemote = remotes and remotes:FindFirstChild("RoundState")
		if not (summaryRemote and summaryRemote:IsA("RemoteEvent")) then
			warn("[Main] RoundSummary remote missing; summary tab disabled")
			return
		end
		local okConfig, bullrushConfig = pcall(require, bullrush:WaitForChild("Config"))
		if okConfig and typeof(bullrushConfig) == "table" and typeof(bullrushConfig.PRODUCTS) == "table" then
			productId = tonumber(bullrushConfig.PRODUCTS.DOUBLE_ROUND) or 0
		end
		local bullAssets = ReplicatedStorage:FindFirstChild("BullrushAssets")
		bullFallbackModel = bullAssets and bullAssets:FindFirstChild("BullTemplate")
		bullModelsFolder = bullAssets and bullAssets:FindFirstChild("Bulls")

		-- The payload lands while the winner banner is still up and the player
		-- is standing in the arena; hold it until the post-round state change
		-- (WAITING/INTERMISSION fires right after the lobby teleport) so the
		-- recap only ever opens back in the lobby.
		local pendingSummary: { [string]: any }? = nil
		local SUMMARY_AUTOCLOSE = 5 -- seconds the recap stays up before folding on its own
		local autoCloseToken = 0

		summaryRemote.OnClientEvent:Connect(function(data)
			if typeof(data) ~= "table" then
				return
			end
			if data.update then
				-- a "2x Rewards?" purchase landed: refresh in place, no reopen
				if coinsAmount then
					coinsAmount.Text = "+" .. comma(tonumber(data.total) or 0)
				end
				canDouble = data.canDouble == true
				if doubleButton then
					doubleButton.Visible = canDouble
				end
				return
			end
			pendingSummary = data
		end)

		if stateRemote and stateRemote:IsA("RemoteEvent") then
			stateRemote.OnClientEvent:Connect(function(state)
				if (state == "WAITING" or state == "INTERMISSION") and pendingSummary then
					local data = pendingSummary
					pendingSummary = nil
					populate(data)
					if currentFrame ~= summaryFrame then
						openFrame(summaryFrame)
					end
					-- fold on its own after a short read; the token keeps a
					-- stale timer from closing a NEWER recap (or whatever
					-- window the player opened after dismissing this one)
					autoCloseToken += 1
					local token = autoCloseToken
					task.delay(SUMMARY_AUTOCLOSE, function()
						if token == autoCloseToken and currentFrame == summaryFrame then
							closeFrame(summaryFrame)
						end
					end)
				elseif state == "ACTIVE" then
					-- The recap is over once the next round actually starts.
					pendingSummary = nil
					if currentFrame == summaryFrame then
						closeFrame(summaryFrame)
					end
				end
			end)
		end
	end)
end

---------------------------------------------------------------- 9) revenge lane controls
-- Visible only while BullrushClient's overhead bull-cam is up (the
-- RevengeViewBridge "Viewing" attribute) AND the viewer may actually throw
-- ("CanThrow": since 2026-07-13 every round spectator — eliminated players
-- AND late/first joiners watching from the lobby — the server bars only
-- players still alive on the grid): ◀ ▶ mirror the Left/Right arrow keys and walk the lane ring, the
-- label reads the current pick ("ROW 3 →"), and SEND BULL fires the throw —
-- or counts down the server cooldown ("ReadyIn" attribute). BullrushClient
-- owns selection state, the lane tile highlight, and the RevengeThrow
-- remote; this section is pure chrome, per the all-UI-in-this-script rule.
-- Commands ride the same bridge the "Become a Bull" button uses:
-- Fire("left" | "right" | "send").
do
	local panel = Instance.new("Frame")
	panel.Name = "RevengeControls"
	panel.AnchorPoint = Vector2.new(0.5, 1)
	panel.Position = UDim2.new(0.5, 0, 1, -28)
	panel.Size = UDim2.new(0, 400, 0, 104)
	panel.BackgroundTransparency = 1
	panel.Visible = false
	panel.Parent = gui

	-- The buttons are CLONES of the kit's Button1 (the "Become a Bull"
	-- ImageButton): same body image, bevel decor, stroke, and the On/Off
	-- gradient pair (On = green, Off = red — wireBullCamButton retints the
	-- template's grey before this clones it), which doubles as the SEND BULL
	-- ready/cooldown look — exactly how wireBullCamButton restyles the
	-- original. Clones carry no connections; feel is re-wired through
	-- addButtonFeedback like every other button.
	local kitTemplate
	for _, d in ipairs(SideUI:GetDescendants()) do
		if d.Name == "Button1" and d:IsA("GuiButton") then
			kitTemplate = d
			break
		end
	end

	-- The kit's Stud texture tiles by SCALE (TileSize {0.5,0},{2,0}), tuned to
	-- the WIDE Button1. Cloned onto our skinny ◀ ▶ buttons — whose aspect ratio
	-- is nothing like Button1's — that scale tiling squishes each stud into a
	-- tall, thin smear. Fix: retile every revenge button by a fixed PIXEL size
	-- (the template's own rendered tile) so studs stay square and uniform. The
	-- template is a laid-out SideUI element, so its AbsoluteSize is real here; a
	-- square fallback covers the off chance layout hasn't resolved yet.
	local studTile: UDim2
	do
		local tmplStud = kitTemplate and kitTemplate:FindFirstChild("Stud", true)
		local abs = tmplStud and tmplStud.AbsoluteSize
		if tmplStud and abs and abs.X > 0 and abs.Y > 0 then
			local ts = tmplStud.TileSize
			studTile = UDim2.fromOffset(
				math.round(ts.X.Scale * abs.X + ts.X.Offset),
				math.round(ts.Y.Scale * abs.Y + ts.Y.Offset)
			)
		else
			studTile = UDim2.fromOffset(72, 72) -- square fallback ≈ template stud
		end
	end

	local selLabel = Instance.new("TextLabel")
	selLabel.Name = "Selection"
	selLabel.BackgroundTransparency = 1
	selLabel.Size = UDim2.new(1, 0, 0, 28)
	selLabel.Font = Enum.Font.GothamBlack
	selLabel.TextSize = 24
	selLabel.TextColor3 = Color3.fromRGB(240, 238, 230)
	selLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	selLabel.TextStrokeTransparency = 0.4
	selLabel.Text = ""
	selLabel.Parent = panel
	local tmplLabel = kitTemplate and kitTemplate:FindFirstChild("Name")
	if tmplLabel and tmplLabel:IsA("TextLabel") then
		selLabel.Font = tmplLabel.Font -- match the kit's face
	end

	local function setButtonText(btn, text)
		local label = btn:FindFirstChild("Name")
		if label and label:IsA("TextLabel") then
			label.Text = text
		end
	end

	-- On = green gradient, Off = red (inherited from the retinted template) —
	-- the kit's own state pair.
	local function setButtonState(btn, on)
		for _, d in ipairs(btn:GetDescendants()) do
			if d:IsA("UIGradient") or d:IsA("UIStroke") then
				if d.Name == "On" then
					d.Enabled = on
				elseif d.Name == "Off" then
					d.Enabled = not on
				end
			end
		end
	end

	local function makeButton(name, text, anchorX, xScale, width)
		local btn
		if kitTemplate then
			btn = kitTemplate:Clone()
			btn.Visible = true -- the live Button1 is hidden at startup; the clone must not be
			setButtonText(btn, text)
			local label = btn:FindFirstChild("Name")
			if label and label:IsA("TextLabel") then
				label.TextScaled = true
			end
		else
			-- kit layout renamed? plain fallback so the feature still works
			btn = Instance.new("TextButton")
			btn.BackgroundColor3 = Color3.fromRGB(26, 26, 34)
			btn.BorderSizePixel = 0
			btn.Font = Enum.Font.GothamBlack
			btn.TextColor3 = Color3.fromRGB(255, 255, 255)
			btn.TextSize = 24
			btn.Text = text
		end
		btn.Name = name
		btn.AnchorPoint = Vector2.new(anchorX, 1)
		btn.Position = UDim2.new(xScale, 0, 1, 0)
		btn.Size = UDim2.new(0, width, 0, 64)
		-- retile the stud texture in fixed pixels so it isn't scale-squished on
		-- the skinny arrows (see studTile above)
		local stud = btn:FindFirstChild("Stud", true)
		if stud and (stud:IsA("ImageLabel") or stud:IsA("ImageButton")) then
			stud.TileSize = studTile
		end
		setButtonState(btn, true)
		btn.Parent = panel
		addButtonFeedback(btn)
		return btn
	end

	local leftBtn = makeButton("Left", "◀", 0, 0, 72)
	local sendBtn = makeButton("Send", "SEND BULL", 0.5, 0.5, 220)
	local rightBtn = makeButton("Right", "▶", 1, 1, 72)

	local function applySendState(readyIn)
		local ready = readyIn <= 0
		local text = if ready then "SEND BULL" else ("READY IN %d"):format(readyIn)
		if sendBtn:IsA("TextButton") then
			sendBtn.Text = text
			sendBtn.BackgroundColor3 = if ready
				then Color3.fromRGB(60, 175, 90)
				else Color3.fromRGB(125, 45, 40)
		else
			setButtonText(sendBtn, text)
		end
		setButtonState(sendBtn, ready)
	end

	task.spawn(function()
		local bridge = ReplicatedStorage:WaitForChild("RevengeViewBridge", 30)
		if not (bridge and bridge:IsA("BindableEvent")) then
			return -- BullrushClient absent; the panel just stays hidden
		end
		local function refresh()
			panel.Visible = bridge:GetAttribute("Viewing") == true
				and bridge:GetAttribute("CanThrow") == true
			selLabel.Text = tostring(bridge:GetAttribute("SelectionText") or "")
			applySendState(tonumber(bridge:GetAttribute("ReadyIn")) or 0)
		end
		for _, attr in ipairs({ "Viewing", "CanThrow", "SelectionText", "ReadyIn" }) do
			bridge:GetAttributeChangedSignal(attr):Connect(refresh)
		end
		refresh()
		leftBtn.Activated:Connect(function()
			bridge:Fire("left")
		end)
		rightBtn.Activated:Connect(function()
			bridge:Fire("right")
		end)
		sendBtn.Activated:Connect(function()
			bridge:Fire("send")
		end)
	end)
end

---------------------------------------------------------------- 10) fortune wheel
-- Frames.Spinner: the kit's 6-slice wheel, run against SpinService.
-- Slice labels + odds are painted from Config.SPINNER.REWARDS (the same table
-- the server rolls), so the wheel can't lie about its odds. The Spin button
-- spends a banked spin (SpinRequest); the server answers SpinAck "SPUN" with
-- the slice plus the revolutions/jitter it committed to, and this section
-- replays it: a classic ~6s decelerating spin (cubic ease-out on
-- Wheel.Spin.Rotation), Ticker per slice edge passing the arrow, Drumroll
-- over the final crawl, then winner!/Cash and a green card. The lobby wheel
-- model spins in sync via FortuneWheelClient off the SpinStarted broadcast
-- (world FX, not UI, so it lives outside this script). x1/x10 buttons prompt
-- the SPIN_1/SPIN_10 dev products (red "coming soon" card while the ids are
-- 0). Spin counts ride the "Spins"/"NextFreeSpin" player attributes
-- SpinService maintains, so there is no fetch remote.
do
	local spinnerFrame = Frames:FindFirstChild("Spinner")
	local wheel = spinnerFrame and spinnerFrame:FindFirstChild("Wheel")
	local spinDial = wheel and wheel:FindFirstChild("Spin")
	local buttons = spinnerFrame and spinnerFrame:FindFirstChild("Buttons")
	local spinButton = buttons and buttons:FindFirstChild("Spin")
	local spinButtonLabel = spinButton and spinButton:FindFirstChild("Amount")
	local buyOne = buttons and buttons:FindFirstChild("1")
	local buyTen = buttons and buttons:FindFirstChild("3") -- kit names the x10 button "3"
	local timerLabel = spinnerFrame and spinnerFrame:FindFirstChild("Timer")

	if spinnerFrame and spinDial and spinButton then
		local SLICE_ANGLE = 60

		local spinRemote = nil -- resolved async below; nil = wheel not live yet
		local productIds = { SPIN_1 = 0, SPIN_10 = 0 }
		local spinning = false

		-- the lobby wheel's FACE is a SurfaceGui replica of this window's
		-- wheel, painted from the same reward table (surfaceDial = its dial;
		-- built once the wheel model resolves, further down). Config and the
		-- wheel model arrive on independent clocks, so painting is a shared
		-- function both waiters call.
		local spinnerRewards, surfaceDial

		local function paintDial(dial)
			if not (dial and spinnerRewards) then
				return
			end
			for i, reward in ipairs(spinnerRewards) do
				local slice = dial:FindFirstChild(tostring(i))
				local nameLabel = slice and slice:FindFirstChild("Name")
				local chanceLabel = slice and slice:FindFirstChild("Chance")
				if nameLabel and nameLabel:IsA("TextLabel") then
					nameLabel.Text = tostring(reward.label)
				end
				if chanceLabel and chanceLabel:IsA("TextLabel") then
					chanceLabel.Text = tostring(reward.weight) .. "%"
				end
			end
		end

		-- both spinners share the dial-angle math (slice 1 up at angle 0);
		-- parking the UI dial at 0 keeps them mirrored from the first frame
		spinDial.Rotation = 0

		-- one-shot library sounds (same clone-and-reap idiom as playUiSound,
		-- but by name - the spinner uses more of the kit than Click)
		local function playSfx(name, volume, pitch)
			if not sfxGroup then
				return nil
			end
			local template = sfxGroup:FindFirstChild(name)
			if not (template and template:IsA("Sound")) then
				return nil
			end
			local sound
			pcall(function()
				sound = template:Clone()
				sound.Volume = volume
				sound.PlaybackSpeed = pitch or 1
				if sfxGroup:IsA("SoundGroup") then
					sound.SoundGroup = sfxGroup
				end
				sound.Parent = gui
				sound:Play()
			end)
			if sound then
				Debris:AddItem(sound, 12)
			end
			return sound
		end

		local function refreshSpinCount()
			if spinButtonLabel and spinButtonLabel:IsA("TextLabel") then
				spinButtonLabel.Text = ("Spin (%d)"):format(tonumber(player:GetAttribute("Spins")) or 0)
			end
		end

		-- billboardLabel floats over the lobby wheel (built once the wheel
		-- model resolves, further down); the window's Timer label and the
		-- billboard both repaint from the same clock.
		local billboardLabel, billboardReadyGradient

		local function timerText()
			local nextAt = tonumber(player:GetAttribute("NextFreeSpin"))
			if not nextAt then
				return nil
			end
			local remaining = math.floor(nextAt - workspace:GetServerTimeNow())
			if remaining <= 0 then
				return "Free spin ready…"
			elseif remaining >= 3600 then
				return ("Free spin in %dh %dm"):format(remaining // 3600, (remaining % 3600) // 60)
			elseif remaining >= 60 then
				return ("Free spin in %dm %ds"):format(remaining // 60, remaining % 60)
			else
				return ("Free spin in %ds"):format(remaining)
			end
		end

		local function refreshTimer()
			local text = timerText()
			if timerLabel and timerLabel:IsA("TextLabel") then
				timerLabel.Text = text or ""
			end
			-- over the wheel, banked spins trump the countdown, and the
			-- money-green gradient flags that there's something to claim
			if billboardLabel then
				local spins = tonumber(player:GetAttribute("Spins")) or 0
				if spins > 0 then
					billboardLabel.Text = spins == 1 and "FREE SPIN READY!" or ("%d SPINS READY!"):format(spins)
				else
					billboardLabel.Text = text or ""
				end
				if billboardReadyGradient then
					billboardReadyGradient.Enabled = spins > 0
				end
			end
		end

		player:GetAttributeChangedSignal("Spins"):Connect(function()
			refreshSpinCount()
			refreshTimer() -- the billboard's READY state rides the spin count
		end)
		player:GetAttributeChangedSignal("NextFreeSpin"):Connect(refreshTimer)
		refreshSpinCount()
		task.spawn(function()
			while true do
				refreshTimer()
				task.wait(1)
			end
		end)

		-- the reward card + payout sounds once the wheel stops
		local function announce(data)
			local reward = typeof(data.reward) == "table" and data.reward or {}
			if reward.kind == "bull" then
				if data.isNew then
					pushNotif(("New bull: %s!"):format(tostring(reward.label)), "green", 5)
				else
					pushNotif(("%s again — +%s Money"):format(
						tostring(reward.label), comma(tonumber(data.consolation) or 0)), "green", 5)
				end
			elseif reward.kind == "box" then
				-- the lucky block: the slice label is the box, data.bullName is what dropped
				local won = tostring(data.bullName or data.bullId)
				if data.isNew then
					pushNotif(("%s — new bull %s!"):format(tostring(reward.label), won), "green", 5)
				else
					pushNotif(("%s — %s dupe, +%s Money"):format(
						tostring(reward.label), won, comma(tonumber(data.refund) or 0)), "green", 5)
				end
			elseif reward.kind == "spin" then
				pushNotif("Free spin! Spin again", "green", 4)
			elseif reward.label == "JACKPOT" then
				pushNotif(("JACKPOT! +%s Money!"):format(comma(tonumber(reward.amount) or 0)), "green", 6)
			else
				pushNotif(("You won +%s Money!"):format(comma(tonumber(reward.amount) or 0)), "green", 4)
			end
			playSfx("winner!", 0.6)
			if reward.kind == "money"
				or (reward.kind == "bull" and not data.isNew)
				or (reward.kind == "box" and not data.isNew) then
				playSfx("Cash", 0.6)
			end
		end

		-- classic decelerate: cubic ease-out over the server's duration,
		-- ticking every slice edge (30 deg off the slice centers) that
		-- crosses the arrow. Slice i is authored at (i-1)*60 inside the
		-- dial, so it rests under the top arrow at Rotation = -(i-1)*60.
		local function animateSpin(data, onFinished)
			local startRotation = spinDial.Rotation
			local targetMod = -((tonumber(data.index) or 1) - 1) * SLICE_ANGLE + (tonumber(data.jitter) or 0)
			local delta = (targetMod - startRotation) % 360 + (tonumber(data.revolutions) or 4) * 360
			local duration = tonumber(data.duration) or 6

			playSfx("Spin_Start", 0.6)
			local drumroll = nil
			local lastEdge = math.floor((startRotation + SLICE_ANGLE / 2) / SLICE_ANGLE)
			local elapsed = 0
			local connection
			connection = RunService.RenderStepped:Connect(function(dt)
				elapsed = math.min(elapsed + dt, duration)
				local alpha = 1 - (1 - elapsed / duration) ^ 3
				local rotation = startRotation + delta * alpha

				local edge = math.floor((rotation + SLICE_ANGLE / 2) / SLICE_ANGLE)
				if edge ~= lastEdge then
					lastEdge = edge
					playSfx("Ticker", 0.35)
				end
				if not drumroll and duration - elapsed <= 2 then
					drumroll = playSfx("Drumroll", 0.4)
				end

				if elapsed >= duration then
					spinDial.Rotation = targetMod % 360 -- exact rest, no float drift
					connection:Disconnect()
					if drumroll then
						pcall(function()
							drumroll:Stop()
							drumroll:Destroy()
						end)
					end
					spinning = false
					announce(data)
					if onFinished then
						onFinished()
					end
				else
					spinDial.Rotation = rotation % 360
				end
			end)
		end

		spinButton.Activated:Connect(function()
			if spinning or not spinRemote then
				return
			end
			if (tonumber(player:GetAttribute("Spins")) or 0) < 1 then
				pushNotif("Out of spins!", "red", 3)
				return
			end
			spinning = true -- optimistic; cleared by the ack (or the deny)
			spinRemote:FireServer()
		end)

		-- x1/x10 Robux spins: same dev-product idiom as the summary's 2x button
		local function wireBuy(btn, productKey)
			if not (btn and btn:IsA("GuiButton")) then
				return
			end
			btn.Activated:Connect(function()
				local productId = tonumber(productIds[productKey]) or 0
				if productId <= 0 then
					pushNotif("Buying spins is coming soon!", "red", 3)
					return
				end
				local ok = pcall(function()
					MarketplaceService:PromptProductPurchase(player, productId)
				end)
				if not ok then
					pushNotif("Store not available", "red", 3)
				end
			end)
		end
		wireBuy(buyOne, "SPIN_1")
		wireBuy(buyTen, "SPIN_10")

		task.spawn(function()
			local bullrush = ReplicatedStorage:WaitForChild("Bullrush", 30)
			local remotes = bullrush and bullrush:FindFirstChild("Remotes")
			local requestRemote = remotes and remotes:WaitForChild("SpinRequest", 30)
			local ackRemote = remotes and remotes:FindFirstChild("SpinAck")
			if not (requestRemote and ackRemote) then
				warn("[Main] Spin remotes missing; fortune wheel disabled")
				return
			end

			local okConfig, bullrushConfig = pcall(require, bullrush:WaitForChild("Config"))
			if okConfig and typeof(bullrushConfig) == "table" then
				if typeof(bullrushConfig.PRODUCTS) == "table" then
					productIds.SPIN_1 = bullrushConfig.PRODUCTS.SPIN_1 or 0
					productIds.SPIN_10 = bullrushConfig.PRODUCTS.SPIN_10 or 0
				end
				-- live Robux prices on the x1/x10 buy buttons (same idiom as the
				-- Store cards) so the labels can't drift from the real products
				local function paintPrice(btn, productKey)
					local id = tonumber(productIds[productKey]) or 0
					local info = btn and btn:FindFirstChild("Info")
					local priceLabel = info and info:FindFirstChild("Price")
					if id <= 0 or not (priceLabel and priceLabel:IsA("TextLabel")) then
						return
					end
					task.spawn(function()
						local ok, prod = pcall(function()
							return MarketplaceService:GetProductInfo(id, Enum.InfoType.Product)
						end)
						if ok and prod and prod.PriceInRobux then
							priceLabel.Text = tostring(prod.PriceInRobux)
						end
					end)
				end
				paintPrice(buyOne, "SPIN_1")
				paintPrice(buyTen, "SPIN_10")
				-- slice labels + odds come from the shared reward table
				if typeof(bullrushConfig.SPINNER) == "table" then
					spinnerRewards = bullrushConfig.SPINNER.REWARDS
					paintDial(spinDial)
					paintDial(surfaceDial)
				end
			end

			ackRemote.OnClientEvent:Connect(function(kind, data)
				data = typeof(data) == "table" and data or {}
				if kind == "SPUN" then
					animateSpin(data)
				elseif kind == "GRANTED" then
					pushNotif(("+%d spins!"):format(tonumber(data.granted) or 0), "green", 4)
				elseif kind == "DENIED" then
					spinning = false
					if data.reason == "NO_SPINS" then
						pushNotif("No spins left", "red", 3)
					elseif data.reason == "DATA_NOT_LOADED" then
						pushNotif("Still loading — try again", "red", 3)
					end
				end
			end)
			spinRemote = requestRemote -- arm the button only once acks are wired
		end)

		-- the lobby wheel is the door: its ProximityPrompt opens this window,
		-- and just standing in the neon ring at the wheel auto-opens it too
		-- (stepping out closes it again). Edge-triggered on the ring, so
		-- closing with the X while still inside STAYS closed until you step
		-- out and back in - the prompt covers reopening in place. The
		-- auto-open also never steals the screen from another open window.
		task.spawn(function()
			-- the wheel was reparented under Workspace.Lobby in the map rework,
			-- so a plain workspace:WaitForChild("FortuneWheel") no longer resolves.
			-- Scan descendants (retrying while it streams in) so a future move
			-- can't silently break both doors again.
			local wheelModel
			do
				local deadline = os.clock() + 60
				repeat
					for _, m in ipairs(workspace:GetDescendants()) do
						if m:IsA("Model") and m.Name == "FortuneWheel" then
							wheelModel = m
							break
						end
					end
					if not wheelModel then
						task.wait(0.2)
					end
				until wheelModel or os.clock() >= deadline
			end
			if not wheelModel then
				return
			end
			local prompt = wheelModel:FindFirstChildWhichIsA("ProximityPrompt", true)
			if prompt then
				prompt.Triggered:Connect(function(who)
					if who == player then
						openFrame(spinnerFrame)
					end
				end)
			end

			-- the disc's printed face (the only decal-bearing part) is what the
			-- face mirror below paints; it SPINS with the disc, so it's the
			-- wrong anchor for a steady label.
			local facePart
			for _, part in ipairs(wheelModel:GetDescendants()) do
				if part:IsA("BasePart") and part:FindFirstChildOfClass("Decal") then
					facePart = part
					break
				end
			end

			-- FortuneWheelClient spins the whole Disc model about its pivot (the
			-- hub). Anything ON the disc orbits that axis, so a billboard adorned
			-- there whirls around with the wheel. Pin an invisible, still marker
			-- at the hub - the disc pivot's WORLD POSITION, which rotation about
			-- itself never moves - and adorn the label to that. It's the wheel's
			-- true centre and dead steady. (The wheel MODEL's own pivot sits off
			-- on the stand, which is why the model made the label float wide.)
			local disc = wheelModel:FindFirstChild("Disc")
			local hub = Instance.new("Part")
			hub.Name = "SpinTimerHub"
			hub.Anchored = true
			hub.CanCollide = false
			hub.CanQuery = false
			hub.CanTouch = false
			hub.Transparency = 1
			hub.Size = Vector3.new(0.2, 0.2, 0.2)
			hub.CFrame = CFrame.new(((disc or wheelModel):GetPivot()).Position)
			hub.Parent = wheelModel

			-- free-spin timer floating over the wheel, dressed in the kit's
			-- own look: the label is a CLONE of the window's Timer (font,
			-- stroke and color travel with it), and the READY green is the
			-- HUD Cash counter's gradient. Lives in PlayerGui with the still
			-- hub marker as adornee (centred over the wheel), so each player
			-- reads their own clock.
			if timerLabel and timerLabel:IsA("TextLabel") then
				local billboard = Instance.new("BillboardGui")
				billboard.Name = "SpinTimerBillboard"
				billboard.ResetOnSpawn = false -- survive respawns (default true destroys it)
				billboard.Adornee = hub
				billboard.Size = UDim2.new(16, 0, 3.4, 0) -- studs
				billboard.StudsOffsetWorldSpace = Vector3.new(0, 9.5, 0)
				billboard.MaxDistance = 120
				billboard.LightInfluence = 0
				local label = timerLabel:Clone()
				label.Name = "Timer"
				label.AnchorPoint = Vector2.new(0.5, 0.5)
				label.Position = UDim2.fromScale(0.5, 0.5)
				label.Size = UDim2.fromScale(1, 1)
				label.TextScaled = true
				label.Text = ""
				label.Visible = true
				local ratio = label:FindFirstChildOfClass("UIAspectRatioConstraint")
				if ratio then
					ratio:Destroy()
				end
				local cashAmount = counters and counters:FindFirstChild("Cash")
				cashAmount = cashAmount and cashAmount:FindFirstChild("Amount")
				local sourceGradient = cashAmount and cashAmount:FindFirstChildOfClass("UIGradient")
				if sourceGradient and not label:FindFirstChildOfClass("UIGradient") then
					billboardReadyGradient = sourceGradient:Clone()
					billboardReadyGradient.Enabled = false
					billboardReadyGradient.Parent = label
				end
				label.Parent = billboard
				billboard.Parent = player:WaitForChild("PlayerGui")
				billboardLabel = label
				refreshTimer()
			end

			-- the wheel FACE mirrors the UI wheel: a SurfaceGui replica of
			-- the window's wheel, adorned to the disc's face part. The part
			-- itself already rotates (FortuneWheelClient) with the same
			-- dial-angle math, so the mirror needs no animation of its own -
			-- slice 1 is drawn pointing up, the disc's rest pose. The
			-- placeholder decal is hidden locally; the model's red pointer
			-- stands in for the UI arrow, so the replica's arrow goes.
			-- (facePart resolved above, shared with the free-spin billboard.)
			if facePart and wheel then
				local decal = facePart:FindFirstChildOfClass("Decal")
				local surface = Instance.new("SurfaceGui")
				surface.Name = "WheelFaceMirror"
				surface.ResetOnSpawn = false -- survive respawns (default true destroys it)
				surface.Adornee = facePart
				surface.Face = decal and decal.Face or Enum.NormalId.Back
				surface.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
				surface.PixelsPerStud = 60
				surface.LightInfluence = 0
				if decal then
					decal.Transparency = 1
				end
				local replica = wheel:Clone()
				replica.Name = "Wheel"
				replica.AnchorPoint = Vector2.new(0.5, 0.5)
				replica.Position = UDim2.fromScale(0.5, 0.5)
				replica.Size = UDim2.fromScale(1, 1)
				local square = Instance.new("UIAspectRatioConstraint")
				square.AspectRatio = 1
				square.Parent = replica
				local arrow = replica:FindFirstChild("Arrow")
				if arrow then
					arrow:Destroy()
				end
				local dial = replica:FindFirstChild("Spin")
				if dial then
					dial.Rotation = 0
				end
				replica.Parent = surface
				surface.Parent = player:WaitForChild("PlayerGui")
				surfaceDial = dial
				paintDial(surfaceDial)
			end

			local ring = wheelModel:FindFirstChild("Ring")
			local center = ring and ring.Position or wheelModel:GetPivot().Position
			-- the neon ring IS the zone: its visible edge plus a step of slack
			local radius = (ring and math.max(ring.Size.Y, ring.Size.Z) / 2 or 10) + 1
			local wasInside = false
			while true do
				local character = player.Character
				local hrp = character and character:FindFirstChild("HumanoidRootPart")
				local inside = false
				if hrp then
					local offset = hrp.Position - center
					inside = Vector2.new(offset.X, offset.Z).Magnitude <= radius
				end
				if inside ~= wasInside then
					wasInside = inside
					if inside then
						if currentFrame == nil then
							openFrame(spinnerFrame)
						end
					elseif currentFrame == spinnerFrame then
						closeFrame(spinnerFrame)
					end
				end
				task.wait(0.25)
			end
		end)
	end
end


---------------------------------------------------------------- 11) bull roll
-- LUCKY BOXES + the gacha reveal (ReplicatedStorage.Bullrush.BullCatalog +
-- ServerScriptService.Bullrush.BullRollService). Frames.Shop1 is reworked into
-- the "Lucky Boxes" shop: one kit card per Config.BULLS.BOXES box (name, tier
-- tag, a RichText odds line, a $cost buy button). Buying a box fires
-- BullRoll:FireServer(boxId); the "ROLLED" ack AUTO-OPENS the reveal wheel
-- (rollFrame) — the shop window closes itself via openFrame's one-at-a-time
-- rule. The wheel's green button re-buys the same box ("ROLL AGAIN"); the gold
-- button is the ROBUX ROLL shell — it prompts the Config.PRODUCTS.BULL_ROLL dev
-- product and the server-side receipt opens a Config.BULLS.ROBUX_BOX box (id 0
-- until published -> "coming soon" card).
--
-- The server rolls the result and answers the caller: BullRoll:FireServer(boxId)
-- -> BullAck "ROLLED" { results = {{bullId,rarity,isNew,refund}}, boxId, money,
-- source }. The reveal is pure presentation: a horizontal strip of rarity-tinted
-- cards — each showing the bull's REAL model in a ViewportFrame (section 12's
-- 3/4-front camera recipe) — scrolls fast, cubic-eases to a stop with the won
-- bull under the center marker, ticks per card, drumroll on the final crawl. A
-- multi-result ack (e.g. the 10-roll BULL_ROLL_10 product, if it's ever sold)
-- still runs ONE carousel (landing on the rarest of the batch) then pops the
-- results grid. All motion is manual RenderStepped math, never a TweenService
-- loop (Run-mode tween freeze — see the marquee/ambient sections).
do
	-- resolved async (remotes + Config + Catalog) at the bottom of this block
	local BullCatalog = nil
	local ackRemote = nil
	local rollRemote = nil        -- nil until acks wired = buttons stay inert
	local BOXES = nil             -- Config.BULLS.BOXES once Config resolves
	local rarityGradient = nil    -- Config.rarityGradient(col) -> shared rarity text ramp
	local lastBoxId = nil         -- box behind the current reveal (ROLL AGAIN re-buys it)
	local productIds = { BULL_ROLL = 0, BULL_ROLL_10 = 0 }
	local modelsFolder = nil      -- ReplicatedStorage.BullrushAssets.Bulls (tier skins)
	local fallbackModel = nil     -- ...BullrushAssets.BullTemplate (default look)

	-- geometry (pixels): the strip lives in a clipped viewport and only its X
	-- offset animates; the won bull always sits at WINNER_INDEX in the strip.
	local CARD_W, CARD_H, PAD = 150, 190, 14
	local STEP = CARD_W + PAD
	local STRIP_LEN = 55
	local WINNER_INDEX = 48
	local DURATION = 4.6

	local rolling = false
	local activeConn = nil        -- the live RenderStepped, so a new roll can pre-empt

	-- one-shot kit sounds (same clone-and-reap idiom as the spinner's playSfx)
	local function playSfx(name, volume, pitch)
		if not sfxGroup then
			return nil
		end
		local template = sfxGroup:FindFirstChild(name)
		if not (template and template:IsA("Sound")) then
			return nil
		end
		local sound
		pcall(function()
			sound = template:Clone()
			sound.Volume = volume
			sound.PlaybackSpeed = pitch or 1
			if sfxGroup:IsA("SoundGroup") then
				sound.SoundGroup = sfxGroup
			end
			sound.Parent = gui
			sound:Play()
		end)
		if sound then
			Debris:AddItem(sound, 12)
		end
		return sound
	end

	local function rarityColor(rarity)
		if BullCatalog and BullCatalog.Rarities[rarity] then
			return BullCatalog.Rarities[rarity].color
		end
		return Color3.fromRGB(170, 170, 170)
	end
	local function rarityOrder(rarity)
		if BullCatalog and BullCatalog.Rarities[rarity] then
			return BullCatalog.Rarities[rarity].order
		end
		return 0
	end

	-- rollable ids for the filler cards (visual only); rebuilt when the catalog resolves
	local fillerIds = { "STARTER" }
	local function randomFiller()
		return fillerIds[math.random(1, #fillerIds)]
	end

	-------------------------------------------------- kit style kit
	-- Tokens harvested from the shop UI so the cards + 10x grid match the rest of the
	-- game: GothamBlack, white text over a thin near-black stroke. (The clickable
	-- BUTTONS aren't built from these — cloneButton clones the real HUD buttons.)
	local KIT_FONT = Enum.Font.GothamBlack
	local INK = Color3.fromRGB(15, 15, 15)           -- the kit's outline/shadow black
	local PAPER = Color3.fromRGB(255, 255, 255)
	-- gradient pair lifted off the kit's gold buttons (bright top -> saturated bottom)
	local GRAD = {
		GOLD = { Color3.fromRGB(255, 251, 0), Color3.fromRGB(255, 147, 0) }, -- 10x grid title
	}

	-- the kit's 4-stop vertical ramp: flat bright band up top, flat saturated band
	-- at the bottom, blend through the middle
	local function kitGradient(pair, rotation)
		local g = Instance.new("UIGradient")
		g.Rotation = rotation or 90
		g.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, pair[1]),
			ColorSequenceKeypoint.new(0.1, pair[1]),
			ColorSequenceKeypoint.new(0.9, pair[2]),
			ColorSequenceKeypoint.new(1, pair[2]),
		})
		return g
	end

	local function kitStroke(parent, color, thickness)
		local s = Instance.new("UIStroke")
		s.Color = color or INK
		s.Thickness = thickness or 2.5
		s.Parent = parent
		return s
	end

	-- white GothamBlack label with the kit's dark outline
	local function kitLabel(text, strokeColor)
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.Text = text
		l.Font = KIT_FONT
		l.TextScaled = true
		l.TextColor3 = PAPER
		kitStroke(l, strokeColor or INK, 2)
		return l
	end

	-- Every button in the game is the same instance (rounded plate + stud + gradient +
	-- GothamBlack label). Rather than rebuild it, we CLONE a real one from the HUD so
	-- the roll buttons are pixel-identical to the rest of the UI, then just retext +
	-- resize. Sources: the green Sell / orange Buy HUD buttons and the Spinner's X.
	local function resolve(...)
		local node = gui
		for _, name in ipairs({ ... }) do
			node = node and node:FindFirstChild(name)
		end
		return node
	end
	local SRC_GREEN = resolve("SideUI", "Top", "Buttons", "Sell")
	local SRC_ORANGE = resolve("SideUI", "Top", "Buttons", "Buy")
	local SRC_CLOSE = resolve("Frames", "Spinner", "Close", "Close")
	-- the Store's gold "Exclusive x10" button: premium look, ships with a Robux icon + price
	local SRC_GOLD10 = resolve("Frames", "Store", "StoreFrame", "Container", "Exclusive", "BuyButtons", "3")

	-- clone a real game button, retext its label, drop layout-only bits, wire the
	-- shared hover/press/click feedback. Returns the button + its label (so setRolling
	-- can retext live). Falls back to a plain green button if the kit ever moves.
	local function cloneButton(source, text)
		local btn, label
		if source and source:IsA("GuiButton") then
			btn = source:Clone()
			btn.LayoutOrder = 0
			btn.Visible = true
			btn.Active = true
			for _, d in ipairs(btn:GetDescendants()) do
				if d:IsA("UIAspectRatioConstraint") then
					d:Destroy()
				end
			end
			label = btn:FindFirstChild("Amount") or btn:FindFirstChild("Name")
			if not (label and label:IsA("TextLabel")) then
				label = btn:FindFirstChildWhichIsA("TextLabel", true)
			end
		else
			btn = Instance.new("ImageButton")
			btn.BackgroundColor3 = Color3.fromRGB(60, 150, 70)
			btn.Image = ""
			local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 10); c.Parent = btn
			kitStroke(btn, INK, 2.5)
			label = kitLabel(text, INK)
			label.AnchorPoint = Vector2.new(0.5, 0.5)
			label.Position = UDim2.new(0.5, 0, 0.46, 0)
			label.Size = UDim2.new(0.86, 0, 0.5, 0)
			label.Parent = btn
		end
		if label then
			label.Text = text
		end
		addButtonFeedback(btn)
		return btn, label
	end

	-------------------------------------------------- panel
	-- MINIMAL roll screen (user: "literally just the horizontal wheel + the two spin
	-- buttons, nothing else — no background, no other parts"). rollFrame is a
	-- TRANSPARENT container that only groups + positions the wheel, the two buttons,
	-- and a small X, so the pop tween scales them together and openFrame/closeFrame
	-- still work. Its height is fixed to the (fixed-px) wheel + gap + button row.
	local BTN_H = 58
	local GAP = 14
	local resultsPanel -- forward-declared; the X handler hides it if a 10x grid is up
	local rollFrame = Instance.new("Frame")
	rollFrame.Name = "BullRoll"
	rollFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	rollFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
	rollFrame.Size = UDim2.new(0.6, 0, 0, (CARD_H + 24) + GAP + BTN_H)
	rollFrame.BackgroundTransparency = 1
	rollFrame.BorderSizePixel = 0
	rollFrame.Visible = false

	-- the horizontal wheel: a transparent clip region (cards float, no backdrop)
	local carousel = Instance.new("Frame")
	carousel.Name = "Carousel"
	carousel.AnchorPoint = Vector2.new(0.5, 0)
	carousel.Position = UDim2.new(0.5, 0, 0, 0)
	carousel.Size = UDim2.new(1, 0, 0, CARD_H + 24)
	carousel.BackgroundTransparency = 1
	carousel.BorderSizePixel = 0
	carousel.ClipsDescendants = true
	carousel.Parent = rollFrame

	local strip = Instance.new("Frame")
	strip.Name = "Strip"
	strip.AnchorPoint = Vector2.new(0, 0.5)
	strip.Position = UDim2.new(0, 0, 0.5, 0)
	strip.Size = UDim2.new(0, 0, 0, CARD_H)
	strip.AutomaticSize = Enum.AutomaticSize.X
	strip.BackgroundTransparency = 1
	do
		local list = Instance.new("UIListLayout")
		list.FillDirection = Enum.FillDirection.Horizontal
		list.HorizontalAlignment = Enum.HorizontalAlignment.Left
		list.VerticalAlignment = Enum.VerticalAlignment.Center
		list.SortOrder = Enum.SortOrder.LayoutOrder
		list.Padding = UDim.new(0, PAD)
		list.Parent = strip
	end
	strip.Parent = carousel

	local marker = Instance.new("Frame")
	marker.Name = "Marker"
	marker.AnchorPoint = Vector2.new(0.5, 0.5)
	marker.Position = UDim2.new(0.5, 0, 0.5, 0)
	marker.Size = UDim2.new(0, 5, 1, -8)
	marker.BackgroundColor3 = Color3.fromRGB(255, 236, 140)
	marker.BorderSizePixel = 0
	marker.ZIndex = 5
	do
		local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(1, 0); c.Parent = marker
		kitStroke(marker, INK, 2)
	end
	marker.Parent = carousel

	-- matching arrows above and below the landing slot (both painted the won rarity)
	local function makeArrow(name, glyph, anchorY, posY)
		local a = Instance.new("TextLabel")
		a.Name = name
		a.BackgroundTransparency = 1
		a.AnchorPoint = Vector2.new(0.5, anchorY)
		a.Position = UDim2.new(0.5, 0, posY, 0)
		a.Size = UDim2.new(0, 28, 0, 28)
		a.Text = glyph
		a.Font = KIT_FONT
		a.TextScaled = true
		a.TextColor3 = Color3.fromRGB(255, 236, 140)
		a.ZIndex = 6
		kitStroke(a, INK, 2)
		a.Parent = carousel
		return a
	end
	local pointer = makeArrow("Pointer", "▼", 1, 0)      -- above, pointing down
	local pointerBottom = makeArrow("PointerB", "▲", 0, 1) -- below, pointing up

	-- small close X (clone of the Spinner's), floating just above the wheel's top-right
	local closeBtn = cloneButton(SRC_CLOSE, "X")
	closeBtn.Name = "Close"
	closeBtn.AnchorPoint = Vector2.new(1, 1)
	closeBtn.Position = UDim2.new(1, 0, 0, -8)
	closeBtn.Size = UDim2.new(0, 40, 0, 40)
	closeBtn.Parent = rollFrame
	closeBtn.Activated:Connect(function()
		if resultsPanel then
			resultsPanel.Visible = false
		end
		closeFrame(rollFrame)
	end)

	-- the two spin buttons, directly under the wheel = clones of the HUD green Sell /
	-- gold Store x10 buttons, retexted. rollLabel is retexted live by setRolling.
	local rollButton, rollLabel = cloneButton(SRC_GREEN, "ROLL")
	rollButton.Name = "RollX1"
	rollButton.AnchorPoint = Vector2.new(0.5, 1)
	rollButton.Position = UDim2.new(0.31, 0, 1, 0)
	rollButton.Size = UDim2.new(0.36, 0, 0.2, 0)
	rollButton.Parent = rollFrame

	-- gold ROBUX ROLL button (cloned from the Store's premium gold button): a
	-- SHELL for buying a roll with Robux — prompts the Config.PRODUCTS.BULL_ROLL
	-- dev product (the receipt opens a Config.BULLS.ROBUX_BOX box server-side).
	-- Until the product id is published (id 0) it answers with a "coming soon"
	-- card. The clone's native layout floats the label above the plate and shows
	-- a Store price row — recenter the label and hide that row so it's a clean
	-- single-label gold button mirroring the green one.
	local robuxButton, robuxLabel = cloneButton(SRC_GOLD10, "9 \u{E002}") -- Bull Roll X1 = 9 R$
	robuxButton.Name = "RobuxRoll"
	robuxButton.AnchorPoint = Vector2.new(0.5, 1)
	robuxButton.Position = UDim2.new(0.69, 0, 1, 0)
	robuxButton.Size = UDim2.new(0.36, 0, 0.2, 0)
	if robuxLabel then
		-- match the green button's Name label geometry exactly so both read centered.
		-- the gold button's label ships TextXAlignment=Left, so force center too or the
		-- text hugs the left edge.
		robuxLabel.AnchorPoint = Vector2.new(0.5, 0.5)
		robuxLabel.Position = UDim2.new(0.5, 0, 0.45, 0)
		robuxLabel.Size = UDim2.new(0.9, 0, 0.575, 0)
		robuxLabel.TextXAlignment = Enum.TextXAlignment.Center
		robuxLabel.TextYAlignment = Enum.TextYAlignment.Center
	end
	local robuxInfo = robuxButton:FindFirstChild("Info")
	if robuxInfo then
		robuxInfo.Visible = false
	end
	-- the gold button ships with chunkier stud tiling than the green one; copy the
	-- green button's finer TileSize so both stud textures read identically
	local robuxStud = robuxButton:FindFirstChild("Stud", true)
	local greenStud = SRC_GREEN and SRC_GREEN:FindFirstChild("Stud", true)
	if robuxStud and greenStud then
		robuxStud.TileSize = greenStud.TileSize
	end
	robuxButton.Parent = rollFrame

	-- results grid overlay (10x rolls): a full-screen modal parented to the ScreenGui
	-- (the roll screen itself has no background, so the grid brings its own dim
	-- backdrop). ZIndex 10 clears every sibling (max is 3). Tap anywhere to dismiss.
	resultsPanel = Instance.new("TextButton")
	resultsPanel.Name = "BullRollResults"
	resultsPanel.AutoButtonColor = false
	resultsPanel.Text = ""
	resultsPanel.AnchorPoint = Vector2.new(0.5, 0.5)
	resultsPanel.Position = UDim2.new(0.5, 0, 0.5, 0)
	resultsPanel.Size = UDim2.new(1, 0, 1, 0)
	resultsPanel.BackgroundColor3 = Color3.fromRGB(14, 12, 18)
	resultsPanel.BackgroundTransparency = 0.15
	resultsPanel.BorderSizePixel = 0
	resultsPanel.Visible = false
	resultsPanel.ZIndex = 10
	resultsPanel.Parent = gui
	-- close the grid whenever the roll screen goes away (X, frame-switch, etc.)
	rollFrame:GetPropertyChangedSignal("Visible"):Connect(function()
		if not rollFrame.Visible then
			resultsPanel.Visible = false
		end
	end)

	local gridTitle = kitLabel("YOUR 10 ROLLS", INK)
	gridTitle.AnchorPoint = Vector2.new(0.5, 0)
	gridTitle.Position = UDim2.new(0.5, 0, 0.05, 0)
	gridTitle.Size = UDim2.new(0.8, 0, 0.1, 0)
	gridTitle.ZIndex = 21
	kitGradient(GRAD.GOLD).Parent = gridTitle -- gold text ramp, the kit "premium header" look
	gridTitle.Parent = resultsPanel

	local gridHolder = Instance.new("Frame")
	gridHolder.BackgroundTransparency = 1
	gridHolder.AnchorPoint = Vector2.new(0.5, 0.5)
	gridHolder.Position = UDim2.new(0.5, 0, 0.52, 0)
	gridHolder.Size = UDim2.new(0.92, 0, 0.7, 0)
	gridHolder.ZIndex = 21
	do
		local g = Instance.new("UIGridLayout")
		g.CellSize = UDim2.new(0.18, 0, 0.46, 0)
		g.CellPadding = UDim2.new(0.014, 0, 0.03, 0)
		g.SortOrder = Enum.SortOrder.LayoutOrder
		g.HorizontalAlignment = Enum.HorizontalAlignment.Center
		g.Parent = gridHolder
	end
	gridHolder.Parent = resultsPanel

	local gridHint = kitLabel("tap to continue", INK)
	gridHint.AnchorPoint = Vector2.new(0.5, 1)
	gridHint.Position = UDim2.new(0.5, 0, 0.97, 0)
	gridHint.Size = UDim2.new(0.6, 0, 0.06, 0)
	gridHint.TextColor3 = Color3.fromRGB(210, 205, 220)
	gridHint.ZIndex = 21
	gridHint.Parent = resultsPanel

	resultsPanel.Activated:Connect(function()
		resultsPanel.Visible = false
	end)

	rollFrame.Parent = Frames

	-------------------------------------------------- card builder
	-- Copies the Shop UI card (Frames.Shop1.Container.<n>): a dark translucent plate
	-- with a thin INK outline + a cyan Highlight rim; a nested "IconFrame" whose border
	-- is a rarity-colored GRADIENT stroke, holding the icon; and white GothamBlack Name
	-- + a rarity label whose text carries the tier gradient. opts = { badge, badgeColor,
	-- zIndex, mutation = BullCatalog.Mutations id -> a colored "NAME" pill over the
	-- icon box (viewports can't render particles, so the aura shows as its tag) }.
	local CYAN = Color3.fromRGB(118, 214, 255) -- the shop cards' fixed Highlight-rim accent

	-- The icon = a ViewportFrame rendering the bull's REAL model (tier skins from
	-- BullrushAssets.Bulls, BullTemplate for commons) with section 12's 3/4-front
	-- camera — bulls face -Z, so the eye sits off the -Z side, high and to the
	-- left. Falls back to a BULL text glyph until the assets resolve or if a
	-- modelName ever goes missing.
	local function buildBullPreview(parent, bull, z)
		local source = bull
			and ((bull.modelName and modelsFolder and modelsFolder:FindFirstChild(bull.modelName)) or fallbackModel)
		if not source then
			local icon = Instance.new("TextLabel")
			icon.BackgroundTransparency = 1
			icon.Size = UDim2.fromScale(1, 1)
			icon.Text = "BULL"
			icon.TextScaled = true
			icon.Font = KIT_FONT
			icon.TextColor3 = PAPER
			icon.ZIndex = z
			icon.Parent = parent
			return
		end
		local viewport = Instance.new("ViewportFrame")
		viewport.Name = "BullPreview"
		viewport.BackgroundTransparency = 1
		viewport.AnchorPoint = Vector2.new(0.5, 0.5)
		viewport.Position = UDim2.fromScale(0.5, 0.5)
		viewport.Size = UDim2.fromScale(0.96, 0.92)
		viewport.ZIndex = z
		viewport.Ambient = Color3.fromRGB(165, 160, 155)
		viewport.LightColor = Color3.fromRGB(255, 250, 240)
		viewport.LightDirection = Vector3.new(-0.4, -1, -0.6)
		local model = source:Clone()
		model:PivotTo(CFrame.new())
		local center, size = Vector3.zero, Vector3.new(10, 10, 10)
		pcall(function()
			local cf, bbox = model:GetBoundingBox()
			center, size = cf.Position, bbox
		end)
		local camera = Instance.new("Camera")
		camera.CFrame = CFrame.lookAt(center + Vector3.new(-0.55, 0.42, -1).Unit * size.Magnitude * 0.72, center)
		camera.Parent = viewport
		viewport.CurrentCamera = camera
		model.Parent = viewport
		viewport.Parent = parent
	end
	local function makeCard(bullId, size, opts)
		opts = opts or {}
		local z = opts.zIndex or 1
		local bull = BullCatalog and BullCatalog.get(bullId) or nil
		local rarity = (bull and bull.rarity) or "COMMON"
		local col = rarityColor(rarity)
		-- per-tier ramp built from the tier color, same juicy shape as the notif
		-- text (NOTIF_TEXT_TINTS): bright highlight at the top of the glyphs, the
		-- saturated tier colour through the middle, a deep shade at the baseline.
		-- Rotation 90 runs top -> bottom so the highlight lands up top.
		local tierHi   = col:Lerp(PAPER, 0.55) -- lit top edge
		local tierDeep = col:Lerp(INK, 0.5)    -- shaded baseline
		local function tierGradient(rotation)
			local g = Instance.new("UIGradient")
			g.Rotation = rotation or 90
			g.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, tierHi),
				ColorSequenceKeypoint.new(0.45, col),
				ColorSequenceKeypoint.new(1, tierDeep),
			})
			return g
		end

		local card = Instance.new("Frame")
		card.Size = size
		card.BackgroundColor3 = INK
		card.BackgroundTransparency = 0.15 -- reads solid over the world (shop cards sit on a panel)
		card.BorderSizePixel = 0
		card.ClipsDescendants = true
		card.ZIndex = z
		local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 10); corner.Parent = card
		kitStroke(card, INK, 2)

		-- shop's signature cyan Highlight rim (an inset transparent frame with a cyan stroke)
		local rim = Instance.new("Frame")
		rim.Name = "Highlight"
		rim.BackgroundTransparency = 1
		rim.AnchorPoint = Vector2.new(0.5, 0.5)
		rim.Position = UDim2.fromScale(0.5, 0.5)
		rim.Size = UDim2.new(1, -6, 1, -6)
		rim.ZIndex = z
		do
			local rc = Instance.new("UICorner"); rc.CornerRadius = UDim.new(0, 8); rc.Parent = rim
			local rs = Instance.new("UIStroke"); rs.Color = CYAN; rs.Thickness = 1.5; rs.Transparency = 0.3; rs.Parent = rim
		end
		rim.Parent = card

		-- IconFrame: a nested dark box whose border is the rarity gradient (shop's icon box)
		local iconFrame = Instance.new("Frame")
		iconFrame.Name = "IconFrame"
		iconFrame.BackgroundColor3 = INK
		iconFrame.BackgroundTransparency = 0.35
		iconFrame.AnchorPoint = Vector2.new(0.5, 0)
		iconFrame.Position = UDim2.new(0.5, 0, 0.05, 0)
		iconFrame.Size = UDim2.new(0.84, 0, 0.55, 0)
		iconFrame.ZIndex = z
		do
			local ic = Instance.new("UICorner"); ic.CornerRadius = UDim.new(0, 8); ic.Parent = iconFrame
			local rarStroke = Instance.new("UIStroke"); rarStroke.Thickness = 2.5; rarStroke.Parent = iconFrame
			tierGradient(90).Parent = rarStroke -- lit-top -> shaded-bottom tier border
		end
		buildBullPreview(iconFrame, bull, z)
		iconFrame.Parent = card

		local nameLabel = kitLabel((bull and bull.name) or "???", INK)
		nameLabel.Size = UDim2.new(1, -10, 0.15, 0)
		nameLabel.Position = UDim2.new(0, 5, 0.64, 0)
		nameLabel.ZIndex = z
		nameLabel.Parent = card

		-- rarity text: white with an INK outline + the juicy tier gradient
		local rarLabel = kitLabel(rarity, INK)
		rarLabel.Size = UDim2.new(1, -10, 0.11, 0)
		rarLabel.Position = UDim2.new(0, 5, 0.82, 0)
		rarLabel.ZIndex = z
		tierGradient(90).Parent = rarLabel
		rarLabel.Parent = card

		if opts.badge then
			local badge = Instance.new("TextLabel")
			badge.AnchorPoint = Vector2.new(0.5, 0.5)
			badge.Position = UDim2.new(0.5, 0, 0.95, 0)
			badge.Size = UDim2.new(0.72, 0, 0.14, 0)
			badge.BackgroundColor3 = opts.badgeColor or Color3.fromRGB(70, 180, 80)
			badge.Text = opts.badge
			badge.Font = KIT_FONT
			badge.TextScaled = true
			badge.TextColor3 = PAPER
			badge.ZIndex = z + 1
			local bc = Instance.new("UICorner"); bc.CornerRadius = UDim.new(1, 0); bc.Parent = badge
			-- one stroke outlines both the pill and its glyphs (kit look)
			kitStroke(badge, INK, 2)
			badge.Parent = card
		end

		-- mutation pill: floats over the top of the icon box in the mutation's
		-- own color. Only real results pass one — filler strip cards stay plain,
		-- so a pill scrolling past always means the aura actually dropped.
		local mut = opts.mutation and BullCatalog and BullCatalog.Mutations
			and BullCatalog.Mutations[opts.mutation]
		if mut then
			local pill = Instance.new("TextLabel")
			pill.Name = "MutationTag"
			pill.AnchorPoint = Vector2.new(0.5, 0.5)
			pill.Position = UDim2.new(0.5, 0, 0.09, 0)
			pill.Size = UDim2.new(0.82, 0, 0.12, 0)
			pill.BackgroundColor3 = mut.color
			pill.Text = mut.name:upper()
			pill.Font = KIT_FONT
			pill.TextScaled = true
			pill.TextColor3 = PAPER
			pill.ZIndex = z + 1
			local pc = Instance.new("UICorner"); pc.CornerRadius = UDim.new(1, 0); pc.Parent = pill
			kitStroke(pill, INK, 2)
			pill.Parent = card
		end
		return card
	end

	-------------------------------------------------- strip + animation
	local winnerCard = nil -- the WINNER_INDEX card, popped when the wheel lands
	local function buildStrip(headline) -- headline = the winning result {bullId, mutation?}
		winnerCard = nil
		for _, c in ipairs(strip:GetChildren()) do
			if c:IsA("Frame") then
				c:Destroy()
			end
		end
		for i = 1, STRIP_LEN do
			local isWinner = i == WINNER_INDEX
			local id = isWinner and headline.bullId or randomFiller()
			local card = makeCard(id, UDim2.fromOffset(CARD_W, CARD_H),
				if isWinner then { mutation = headline.mutation } else nil)
			card.LayoutOrder = i
			card.Parent = strip
			if isWinner then
				winnerCard = card
			end
		end
	end

	-- (The CurrentArea HUD banner now shows the round GAME TYPE, driven by RoundState
	-- in section 6 — it is no longer a roll-rarity banner.)

	local function announce(results, headline)
		local h = BullCatalog and BullCatalog.get(headline.bullId) or nil
		local hname = (h and h.name) or headline.bullId
		-- a mutation drop outranks the bull news in the card copy
		local function mutSuffix(r)
			local mut = r.mutation and BullCatalog and BullCatalog.Mutations
				and BullCatalog.Mutations[r.mutation]
			return if mut then (" — %s MUTATION!"):format(mut.name:upper()) else ""
		end
		if #results <= 1 then
			local r = results[1] or headline
			if r.isNew then
				pushNotif(("New bull: %s!%s"):format(hname, mutSuffix(r)), "green", 5)
			else
				pushNotif(("%s again — +%s Money%s"):format(hname, comma(r.refund or 0), mutSuffix(r)), "green", 4)
			end
		else
			local newCount = 0
			for _, r in ipairs(results) do
				if r.isNew then
					newCount += 1
				end
			end
			pushNotif(("10x roll: %d new! Best: %s%s"):format(newCount, hname, mutSuffix(headline)), "green", 5)
		end
	end

	local function showGrid(results)
		for _, c in ipairs(gridHolder:GetChildren()) do
			if c:IsA("Frame") then
				c:Destroy()
			end
		end
		for i, r in ipairs(results) do
			local badge = r.isNew and "NEW" or ("+" .. comma(r.refund or 0))
			local badgeColor = r.isNew and Color3.fromRGB(70, 180, 80) or Color3.fromRGB(190, 150, 55)
			local mini = makeCard(r.bullId, UDim2.fromScale(1, 1),
				{ badge = badge, badgeColor = badgeColor, zIndex = 21, mutation = r.mutation })
			mini.LayoutOrder = i
			mini.Parent = gridHolder
		end
		resultsPanel.Visible = true
	end

	-- Banked free openings for a box (the FreeBoxRolls JSON attribute — new
	-- players join with one free BASIC). The server spends these before Money,
	-- so wherever a price shows, a banked roll must read FREE instead.
	local function freeRollsFor(boxId)
		local ok, bank = pcall(function()
			return game:GetService("HttpService"):JSONDecode(player:GetAttribute("FreeBoxRolls") or "{}")
		end)
		return (ok and typeof(bank) == "table" and tonumber(bank[boxId])) or 0
	end

	local function setRolling(state)
		rolling = state
		local box = (BOXES and lastBoxId) and BOXES[lastBoxId] or nil
		rollLabel.Text = state and "ROLLING…"
			or (box and (freeRollsFor(lastBoxId) > 0 and "ROLL AGAIN  FREE"
				or ("ROLL AGAIN  $%s"):format(comma(box.cost))) or "ROLL AGAIN")
		-- dim the plate while a roll is in flight so it reads as busy
		rollButton.ImageTransparency = state and 0.35 or 0
	end

	local function animateReveal(results)
		if activeConn then
			activeConn:Disconnect()
			activeConn = nil
		end
		results = results or {}
		if #results == 0 then
			setRolling(false)
			return
		end
		-- headline = rarest of the batch (the card the carousel lands on)
		local headline = results[1]
		for _, r in ipairs(results) do
			if rarityOrder(r.rarity) > rarityOrder(headline.rarity) then
				headline = r
			end
		end

		resultsPanel.Visible = false
		marker.BackgroundColor3 = Color3.fromRGB(255, 220, 120)
		pointer.TextColor3 = Color3.fromRGB(255, 220, 120)
		pointerBottom.TextColor3 = Color3.fromRGB(255, 220, 120)
		buildStrip(headline)
		-- The strip is STRIP_LEN cards, each a ViewportFrame cloning a real bull
		-- model — a heavy layout pass. Two fixed frames wasn't always enough for it
		-- to settle, so the winner's MEASURED centre could still be stale and the
		-- carousel would land a FILLER card (wrong name) under the pointer even
		-- though the right bull was popped + granted. Wait until the list has
		-- actually sized itself (frame-count safety cap) before measuring.
		--
		-- The measure must also wait out openFrame's POP_IN: a roll that arrives
		-- through a window transition (the FIRST roll of a session — Shop1 buy ->
		-- openFrame(rollFrame)) measures while the UIScale is still tweening
		-- 0.7 -> 1, and marker/winner AbsolutePositions read in SHRUNK pixels.
		-- The winner sits ~47 cards out, so even a 0.95 scale shorts the travel
		-- by whole cards and the wheel eases to rest on a filler (the landing
		-- looks nothing like the rolled bull). Back easing overshoots and crosses
		-- 1.0 mid-flight, so require Scale == 1 on two CONSECUTIVE frames — only
		-- the tween's completion write holds it there. ROLL AGAIN rolls (window
		-- already open, scale parked at 1) pass immediately.
		local EXPECTED_W = STRIP_LEN * STEP - PAD -- N cards + (N-1) gaps
		local rollScale = ensureScale(rollFrame)
		local settleFrames, scaleSettled = 0, 0
		repeat
			RunService.Heartbeat:Wait()
			settleFrames += 1
			scaleSettled = if rollScale.Scale == 1 then scaleSettled + 1 else 0
		until (winnerCard and winnerCard.AbsoluteSize.X > 0
				and strip.AbsoluteSize.X >= EXPECTED_W * 0.9
				and scaleSettled >= 2)
			or settleFrames >= 60

		local vpCenter = carousel.AbsoluteSize.X / 2
		-- Land the ACTUAL winner card on the ACTUAL marker using measured geometry
		-- instead of index math: the pointer was resting one card off the bull that
		-- actually pops and gets rewarded. Reading the winner's rendered centre and
		-- the marker's centre live makes the pointer land on the rewarded card no
		-- matter what the list layout does (padding, a stray leading child, etc.).
		local function centerX(o)
			return o.AbsolutePosition.X + o.AbsoluteSize.X / 2
		end
		-- tiny jitter for a touch of life, never a whole slot (keeps pointer/pop/reward aligned)
		local jitter = (math.random() * 2 - 1) * (CARD_W * 0.04)
		local baseOffset = strip.Position.X.Offset
		local targetOffset
		if winnerCard then
			targetOffset = baseOffset + (centerX(marker) - centerX(winnerCard)) + jitter
		else -- shouldn't happen (buildStrip always sets it); fall back to index math
			targetOffset = vpCenter - ((WINNER_INDEX - 1) * STEP + CARD_W / 2) + jitter
		end
		-- begin the scroll well to the right of the landing so it sweeps left onto the winner
		local startOffset = targetOffset + (WINNER_INDEX - 3) * STEP
		local delta = targetOffset - startOffset
		strip.Position = UDim2.new(0, startOffset, 0.5, 0)

		playSfx("Spin_Start", 0.6)
		local elapsed, drum, lastIdx = 0, nil, nil
		activeConn = RunService.RenderStepped:Connect(function(dt)
			elapsed = math.min(elapsed + dt, DURATION)
			local alpha = 1 - (1 - elapsed / DURATION) ^ 3
			local x = startOffset + delta * alpha
			strip.Position = UDim2.new(0, x, 0.5, 0)

			local idx = math.floor((vpCenter - x - CARD_W / 2) / STEP + 0.5) + 1
			if idx ~= lastIdx then
				lastIdx = idx
				playSfx("Ticker", 0.3)
			end
			if not drum and DURATION - elapsed <= 1.2 then
				drum = playSfx("Drumroll", 0.4)
			end

			if elapsed >= DURATION then
				-- Everything is fully laid out by now, so re-measure and snap the
				-- ACTUAL winner card dead-centre under the marker (keeping the
				-- intended jitter). Corrects any residual drift from measuring a
				-- not-yet-settled strip up front, so the name under the pointer
				-- ALWAYS matches the bull that was rolled. ~0px no-op when the
				-- up-front measure was already good.
				if winnerCard then
					targetOffset += (centerX(marker) + jitter) - centerX(winnerCard)
				end
				strip.Position = UDim2.new(0, targetOffset, 0.5, 0)
				activeConn:Disconnect()
				activeConn = nil
				if drum then
					pcall(function()
						drum:Stop()
						drum:Destroy()
					end)
				end
				-- landing flourish: paint the marker/arrows the won rarity and pop the
				-- winning card so it punches out of the row
				local col = rarityColor(headline.rarity)
				marker.BackgroundColor3 = col
				pointer.TextColor3 = col
				pointerBottom.TextColor3 = col
				if winnerCard then
					local ws = ensureScale(winnerCard)
					ws.Scale = 1
					tween(ws, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1.1 })
				end
				playSfx("winner!", 0.6)
				announce(results, headline)
				if #results > 1 then
					showGrid(results)
				end
				setRolling(false)
			end
		end)
	end

	-------------------------------------------------- buttons
	-- "ROLL AGAIN": buy the same box the current reveal came from (lastBoxId
	-- defaults to the cheapest box until the first purchase lands)
	rollButton.Activated:Connect(function()
		if rolling or not rollRemote or not lastBoxId then
			return
		end
		setRolling(true)
		rollRemote:FireServer(lastBoxId)
	end)

	-- Robux roll shell: prompt the dev product and let the server-side receipt
	-- do the rolling (BullRollService.init registers the handler; the "ROLLED"
	-- ack with source="ROBUX" drives the same reveal). No product id yet ->
	-- "coming soon" card, so the button is safe to ship before publishing.
	robuxButton.Activated:Connect(function()
		local pid = tonumber(productIds.BULL_ROLL) or 0
		if pid <= 0 then
			pushNotif("Robux rolls are coming soon!", "red", 3)
			return
		end
		local ok = pcall(function()
			MarketplaceService:PromptProductPurchase(player, pid)
		end)
		if not ok then
			pushNotif("Store not available", "red", 3)
		end
	end)

	-- (The old "press B" test opener is gone: buying a lucky box in Shop1 —
	-- opened from the lobby shop stall — auto-opens this reveal.)

	-------------------------------------------------- lucky box shop (Frames.Shop1)
	-- Reworks the kit's "Pickaxes" shop into the LUCKY BOXES window: one kit card
	-- per Config.BULLS.BOXES box, cheapest first. Each card keeps the kit chrome
	-- and gets: Name = box name, the Rarity tag = box tier (gradient retinted to
	-- the box color), the Power row = per-rarity drop odds (RichText, rarity-
	-- colored), and the kit Buy button = "$cost" -> BullRoll:FireServer(boxId).
	-- The "ROLLED" ack below auto-opens the reveal wheel, and openFrame's
	-- one-window rule closes this shop as it does.
	local RARITY_ORDER = { "COMMON", "UNCOMMON", "RARE", "EPIC", "LEGENDARY" }
	local BOX_EMOJI = { BASIC = "BASIC", SUPER = "SUPER", MEGA = "MEGA" } -- placeholder icons

	local function colorHex(c)
		return string.format("#%02X%02X%02X",
			math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
	end

	-- the roll cards' juicy 3-stop tier ramp as a ColorSequence, for retinting
	-- the kit cards' "Legendary" gradients to each box's color
	local function boxRamp(col)
		return ColorSequence.new({
			ColorSequenceKeypoint.new(0, col:Lerp(PAPER, 0.55)),
			ColorSequenceKeypoint.new(0.45, col),
			ColorSequenceKeypoint.new(1, col:Lerp(INK, 0.5)),
		})
	end

	-- Odds row: one label per rarity figure ("64%", "25%", ...), each carrying
	-- the shared rarity gradient (Config.rarityGradient) so the numbers read like the
	-- rarity labels everywhere else. Per-figure gradients need per-figure labels -- a
	-- single RichText label can only take one gradient across the whole string. (The
	-- mutation odds that used to trail the row as "MUT 8%" have been dropped.)
	local TextService = game:GetService("TextService")
	local function buildOdds(container, weights)
		-- Odds row in the kit Power.Power slot (original spot, where the kit's
		-- "67,420" power figure sat). Each figure is its OWN text box sized to its
		-- true glyph width via a UIAspectRatioConstraint (DominantAxis=Height), so
		-- TextScaled is always HEIGHT-bound: every figure renders at the same full
		-- row-height size, packed left on the row baseline with even gaps -- never
		-- the tiny width-bound numbers the old evenly-spread slots produced.
		container.Visible = true
		container.RichText = false
		container.Text = ""
		container.AutomaticSize = Enum.AutomaticSize.None
		container.ClipsDescendants = false
		container.AnchorPoint = Vector2.new(0, 1)
		container.Position = UDim2.new(0.01, 0, 1, 0)
		container.Size = UDim2.new(0.4, 0, 0.7, 0) -- 0.7 of the Power row height
		local strip = container.Parent and container.Parent:FindFirstChild("OddsStrip")
		if strip then
			strip:Destroy()
		end
		for _, c in ipairs(container:GetChildren()) do
			if c.Name == "OddsFig" or c:IsA("UIListLayout") then
				c:Destroy()
			end
		end
		local order = {}
		local total = 0
		for _, r in ipairs(RARITY_ORDER) do
			local w = math.max(tonumber(weights[r]) or 0, 0)
			if w > 0 then
				total += w
				table.insert(order, { r = r, w = w })
			end
		end
		if total <= 0 or #order == 0 then
			return
		end
		local function pctFigure(pct)
			-- one decimal, trailing ".0" stripped (float dust otherwise turns a clean 7 into "7.0%")
			return (("%.1f%%"):format(pct):gsub("%.0%%", "%%"))
		end
		local layout = Instance.new("UIListLayout")
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0.018, 0)
		layout.Parent = container
		for i, entry in ipairs(order) do
			local fig = Instance.new("TextLabel")
			fig.Name = "OddsFig"
			fig.LayoutOrder = i
			fig.BackgroundTransparency = 1
			fig.Size = UDim2.new(0, 0, 1, 0) -- width comes from the aspect constraint
			fig.Font = container.Font
			fig.TextScaled = true
			fig.TextColor3 = PAPER
			fig.Text = pctFigure(entry.w / total * 100)
			fig.ZIndex = container.ZIndex
			-- measure the real text aspect so the box hugs the glyphs (hair of slack
			-- so TextScaled never flips to width-bound)
			local aspect = #fig.Text * 0.62
			pcall(function()
				local bounds = TextService:GetTextSize(fig.Text, 100, fig.Font, Vector2.new(4000, 200))
				aspect = bounds.X / 100
			end)
			local arc = Instance.new("UIAspectRatioConstraint")
			arc.AspectRatio = math.max(aspect, 0.5) * 1.04
			-- ScaleWithParentSize + Height: width = ratio x row height (the default
			-- FitWithinMaxSize treats the label's zero width as a max -> collapses to 0x0)
			arc.AspectType = Enum.AspectType.ScaleWithParentSize
			arc.DominantAxis = Enum.DominantAxis.Height
			arc.Parent = fig
			local grad = Instance.new("UIGradient")
			grad.Rotation = 90
			grad.Color = (rarityGradient and rarityGradient(rarityColor(entry.r)))
				or ColorSequence.new(rarityColor(entry.r))
			grad.Parent = fig
			local stroke = Instance.new("UIStroke")
			stroke.Thickness = 2
			stroke.Color = INK
			stroke.Parent = fig
			fig.Parent = container
		end
	end

	local function buildBoxShop()
		local shopFrame = Frames:FindFirstChild("Shop1")
		local shopContainer = shopFrame and shopFrame:FindFirstChild("Container")
		if not (shopFrame and shopContainer and BOXES) then
			return
		end
		local header = shopFrame:FindFirstChild("Header")
		local headerName = header and header:FindFirstChild("Name")
		if headerName and headerName:IsA("TextLabel") then
			headerName.Text = "Lucky Boxes"
		end
		-- the kit header ships a pickaxe glyph; swap it for a real lucky-box image
		-- (the Mega box art) in the same slot, falling back to a BOX text glyph if no
		-- box carries an image
		local headerIcon = header and header:FindFirstChild("Icon")
		if headerIcon and headerIcon:IsA("ImageLabel") then
			local headerImage = (BOXES.MEGA and BOXES.MEGA.image)
				or (BOXES.BASIC and BOXES.BASIC.image)
			if not headerImage then
				for _, b in BOXES do
					if b.image then headerImage = b.image break end
				end
			end
			local oldGlyph = headerIcon:FindFirstChild("BoxGlyph")
			if oldGlyph then oldGlyph:Destroy() end
			if headerImage then
				headerIcon.Image = headerImage
				headerIcon.ImageColor3 = Color3.new(1, 1, 1)
				headerIcon.ImageTransparency = 0
			else
				headerIcon.Image = ""
				local glyph = Instance.new("TextLabel")
				glyph.Name = "BoxGlyph"
				glyph.BackgroundTransparency = 1
				glyph.Size = UDim2.fromScale(1, 1)
				glyph.Text = "BOX"
				glyph.TextScaled = true
				glyph.Font = KIT_FONT
				glyph.Parent = headerIcon
			end
		end

		-- keep one kit card as the template, clear the demo pickaxes (cards =
		-- Frames with an Info child; the SPACE spacers/layout/adjuster survive)
		local template = nil
		for _, child in ipairs(shopContainer:GetChildren()) do
			if child:IsA("Frame") and child:FindFirstChild("Info") then
				if not template then
					template = child:Clone()
				end
				child:Destroy()
			end
		end
		if not template then
			return
		end

		local ids = {}
		for id in BOXES do
			table.insert(ids, id)
		end
		table.sort(ids, function(a, b)
			return (BOXES[a].order or 99) < (BOXES[b].order or 99)
		end)

		for i, boxId in ipairs(ids) do
			local box = BOXES[boxId]
			local card = template:Clone()
			card.Name = boxId
			card.LayoutOrder = box.order or i

			local locked = card:FindFirstChild("Locked")
			if locked then
				locked.Visible = false
			end

			local info = card:FindFirstChild("Info")
			local nameLabel = info and info:FindFirstChild("Name")
			if nameLabel and nameLabel:IsA("TextLabel") then
				nameLabel.Text = box.name or boxId
			end
			local tagLabel = info and info:FindFirstChild("Rarity")
			if tagLabel and tagLabel:IsA("TextLabel") then
				tagLabel.Text = box.tag or ""
				local g = tagLabel:FindFirstChildWhichIsA("UIGradient")
				if g and box.color then
					g.Color = boxRamp(box.color)
				end
			end

			-- icon box: show the box's own art on the kit Icon (or fall back to a
			-- box emoji if a box has no image); the kit's rarity-gradient border
			-- stroke retints to the box color
			local iconFrame = card:FindFirstChild("IconFrame")
			if iconFrame then
				local img = iconFrame:FindFirstChild("Icon")
				local stroke = iconFrame:FindFirstChildWhichIsA("UIStroke")
				local strokeGrad = stroke and stroke:FindFirstChildWhichIsA("UIGradient")
				if strokeGrad and box.color then
					strokeGrad.Color = boxRamp(box.color)
				end
				if box.image and img and img:IsA("ImageLabel") then
					-- real box art: keep the kit Icon, just repoint + show it
					img.Image = box.image
					img.ImageColor3 = Color3.new(1, 1, 1)
					img.ImageTransparency = 0
					img.Visible = true
				else
					if img and img:IsA("GuiObject") then
						img.Visible = false
					end
					local emoji = Instance.new("TextLabel")
					emoji.Name = "BoxIcon"
					emoji.BackgroundTransparency = 1
					emoji.AnchorPoint = Vector2.new(0.5, 0.5)
					emoji.Position = UDim2.fromScale(0.5, 0.5)
					emoji.Size = UDim2.fromScale(0.8, 0.8)
					emoji.Text = BOX_EMOJI[boxId] or "BOX"
					emoji.TextScaled = true
					emoji.Font = KIT_FONT
					emoji.TextColor3 = PAPER
					emoji.Parent = iconFrame
				end
			end

			-- the kit "Power" row becomes the odds line
			local power = card:FindFirstChild("Power")
			local powerLabel = power and power:FindFirstChild("Power")
			if powerLabel and powerLabel:IsA("TextLabel") then
				local pIcon = power:FindFirstChild("Icon")
				if pIcon and pIcon:IsA("GuiObject") then
					pIcon.Visible = false
				end
				buildOdds(powerLabel, box.weights or {})
			end

			-- buy button: the kit's money button retexted to the box cost; the
			-- Robux button hides (no per-box Robux products yet)
			local buyButtons = card:FindFirstChild("BuyButtons")
			local robuxBtn = buyButtons and buyButtons:FindFirstChild("BuyRobux")
			if robuxBtn and robuxBtn:IsA("GuiObject") then
				robuxBtn.Visible = false
			end
			local buyBtn = buyButtons and buyButtons:FindFirstChild("Buy/Equip/Equipped/Locked")
			if buyBtn and buyBtn:IsA("GuiButton") then
				buyBtn.Active = true
				local costLabel = buyBtn:FindFirstChild("Cost/Equip/Equipped/Locked")
				if costLabel and costLabel:IsA("TextLabel") then
					-- a banked free roll (new-player gift) shows FREE until spent;
					-- the attribute flips the moment the server consumes it
					local function paintCost()
						costLabel.Text = freeRollsFor(boxId) > 0 and "FREE"
							or ("$" .. comma(box.cost or 0))
					end
					paintCost()
					player:GetAttributeChangedSignal("FreeBoxRolls"):Connect(paintCost)
				end
				-- force the green "Buy" look (the template may ship Equipped/Locked)
				for _, d in ipairs(buyBtn:GetChildren()) do
					if d:IsA("UIGradient") then
						d.Enabled = (d.Name == "Buy/Equip")
					end
				end
				addButtonFeedback(buyBtn) -- clones carry no connections; rewire feel+sfx
				buyBtn.Activated:Connect(function()
					if rolling or not rollRemote then
						return
					end
					lastBoxId = boxId
					setRolling(true)
					rollRemote:FireServer(boxId)
				end)
			end

			card.Parent = shopContainer
		end
	end

	-------------------------------------------------- wire remotes + config
	task.spawn(function()
		local bullrush = ReplicatedStorage:WaitForChild("Bullrush", 30)
		local remotes = bullrush and bullrush:FindFirstChild("Remotes")
		local requestRemote = remotes and remotes:WaitForChild("BullRoll", 30)
		ackRemote = remotes and remotes:FindFirstChild("BullAck")
		if not (requestRemote and ackRemote) then
			warn("[Main] Bull roll remotes missing; roll UI disabled")
			return
		end

		local okCatalog, catalog = pcall(require, bullrush:WaitForChild("BullCatalog"))
		if okCatalog and typeof(catalog) == "table" then
			BullCatalog = catalog
			fillerIds = {}
			for id, b in BullCatalog.Bulls do
				if b.rollable ~= false then
					table.insert(fillerIds, id)
				end
			end
			if #fillerIds == 0 then
				fillerIds = { "STARTER" }
			end
		end

		-- model sources for the card previews (same folders section 12 uses);
		-- missing assets just mean cards keep the BULL glyph fallback
		local assets = ReplicatedStorage:WaitForChild("BullrushAssets", 10)
		modelsFolder = assets and assets:FindFirstChild("Bulls")
		fallbackModel = assets and assets:FindFirstChild("BullTemplate")

		local okConfig, config = pcall(require, bullrush:WaitForChild("Config"))
		if okConfig and typeof(config) == "table" then
			if typeof(config.BULLS) == "table" and typeof(config.BULLS.BOXES) == "table" then
				BOXES = config.BULLS.BOXES
				rarityGradient = config.rarityGradient -- shared gradient for the odds figures
				-- ROLL AGAIN targets the cheapest box until a purchase overrides it
				local bestCost
				for id, box in BOXES do
					local cost = tonumber(box.cost) or math.huge
					if not bestCost or cost < bestCost then
						bestCost, lastBoxId = cost, id
					end
				end
			end
			if typeof(config.PRODUCTS) == "table" then
				productIds.BULL_ROLL = tonumber(config.PRODUCTS.BULL_ROLL) or 0
				productIds.BULL_ROLL_10 = tonumber(config.PRODUCTS.BULL_ROLL_10) or 0
			end
		end
		setRolling(false) -- paints the button label now that the box cost is known
		buildBoxShop()    -- Shop1 -> the Lucky Boxes window (needs BOXES + catalog)

		ackRemote.OnClientEvent:Connect(function(kind, data)
			data = typeof(data) == "table" and data or {}
			if kind == "ROLLED" then
				if typeof(data.boxId) == "string" and (not BOXES or BOXES[data.boxId]) then
					lastBoxId = data.boxId -- ROLL AGAIN re-buys what was just opened
				end
				-- buying a box (Shop1 / ROLL AGAIN / Robux) jumps straight into the
				-- reveal; openFrame's one-window rule closes the shop on the way
				if currentFrame ~= rollFrame then
					openFrame(rollFrame)
				end
				setRolling(true)
				animateReveal(data.results)
			elseif kind == "DENIED" then
				setRolling(false)
				if data.reason == "NO_MONEY" then
					local cost = tonumber(data.cost)
					pushNotif(cost and ("Need $%s for this box"):format(comma(cost))
						or "Not enough Money for that box", "red", 3)
				elseif data.reason == "DATA_NOT_LOADED" then
					pushNotif("Still loading — try again", "red", 3)
				elseif data.reason == "BAD_BOX" then
					pushNotif("That box isn't available", "red", 3)
				elseif data.reason == "NOT_OWNED" or data.reason == "BAD_ID" then
					pushNotif("That bull can't be equipped", "red", 3)
				end
			end
			-- "EQUIPPED" acks live in section 12 (bull index) — never handle them here
		end)

		rollRemote = requestRemote -- arm the buttons only once acks are wired
	end)
end

---------------------------------------------------------------- 12) bull index
-- Frames.Index reworked into the BULL INVENTORY (user request 2026-07-08):
-- the kit's left TypeButtons become the five rarity tabs, the card grid fills
-- with every catalog bull of the selected tab (a ViewportFrame renders the
-- bull's ACTUAL model — tier skins from ReplicatedStorage.BullrushAssets.Bulls,
-- BullTemplate for commons; unowned bulls show as a blacked-out silhouette
-- named "???", the kit's own convention), and clicking an owned card equips it
-- for revenge charges (BullEquip; the EquippedBull attribute confirms and
-- repaints, section 11's shared BullAck handler explains any DENIED — only the
-- "EQUIPPED" ack is handled here, so no card is ever shown twice). The bottom
-- Quests strip becomes the collection meter. Inventory rides the Bulls (JSON)
-- + BullMutations (JSON) + EquippedBull player attributes (Data.server on
-- join, BullRollService after rolls), so the window stays current even while
-- closed — no fetch remote.
do
	local HttpService = game:GetService("HttpService")

	local indexFrame = Frames:FindFirstChild("Index")
	local container = indexFrame and indexFrame:FindFirstChild("Container")
	local typeButtons = indexFrame and indexFrame:FindFirstChild("TypeButtons")
	if indexFrame and container and typeButtons then
		local header = indexFrame:FindFirstChild("Header")
		local headerName = header and header:FindFirstChild("Name")
		local quests = indexFrame:FindFirstChild("Quests")

		-- keep one kit card as the template, clear the demo brainrots NOW so
		-- the window never flashes kit content (cards = Frames with an inner
		-- "Frame"; the SPACE spacer + layout/padding/adjuster survive)
		local cardTemplate = nil
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Frame") and child:FindFirstChild("Frame") then
				if not cardTemplate then
					cardTemplate = child:Clone()
				end
				child:Destroy()
			end
		end
		if headerName and headerName:IsA("TextLabel") then
			headerName.Text = "Bulls"
		end

		-- kit tab buttons -> rarity tabs, in ascending-tier order
		local RARITIES = { "COMMON", "UNCOMMON", "RARE", "EPIC", "LEGENDARY" }
		local DISPLAY = {
			COMMON = "Common", UNCOMMON = "Uncommon", RARE = "Rare",
			EPIC = "Epic", LEGENDARY = "Legendary",
		}
		local TAB_SOURCE = { "Normal", "Gold", "Diamond", "Rainbow", "Clover" }

		task.spawn(function()
			local bullrush = ReplicatedStorage:WaitForChild("Bullrush", 30)
			local remotes = bullrush and bullrush:FindFirstChild("Remotes")
			local equipRemote = remotes and remotes:WaitForChild("BullEquip", 30)
			local ackRemote = remotes and remotes:FindFirstChild("BullAck")
			local okCatalog, BullCatalog = pcall(require, bullrush:WaitForChild("BullCatalog"))
			if not (equipRemote and okCatalog and typeof(BullCatalog) == "table" and cardTemplate) then
				warn("[Main] Bull index prerequisites missing; inventory UI disabled")
				return
			end
			local assets = ReplicatedStorage:WaitForChild("BullrushAssets", 10)
			local modelsFolder = assets and assets:FindFirstChild("Bulls")
			local fallbackModel = assets and assets:FindFirstChild("BullTemplate")

			-- catalog by rarity, slowest bull first within a tab
			local totalBulls = 0
			local byRarity = {}
			for id, bull in BullCatalog.Bulls do
				totalBulls += 1
				local list = byRarity[bull.rarity]
				if not list then
					list = {}
					byRarity[bull.rarity] = list
				end
				table.insert(list, id)
			end
			for _, list in byRarity do
				table.sort(list, function(a, b)
					local ba, bb = BullCatalog.Bulls[a], BullCatalog.Bulls[b]
					if ba.speed ~= bb.speed then
						return ba.speed < bb.speed
					end
					return ba.name < bb.name
				end)
			end

			local function ownedSet()
				local ok, decoded = pcall(function()
					return HttpService:JSONDecode(player:GetAttribute("Bulls") or "{}")
				end)
				return (ok and type(decoded) == "table") and decoded or {}
			end

			-- { bullId = { mutId = true } }, mirrored by BullRollService after rolls
			local function mutationsByBull()
				local ok, decoded = pcall(function()
					return HttpService:JSONDecode(player:GetAttribute("BullMutations") or "{}")
				end)
				return (ok and type(decoded) == "table") and decoded or {}
			end

			local currentRarity = "COMMON"

			-- 3/4-front render of the bull's real model; silhouetted when
			-- unowned (ImageColor3 tints the whole rendered image)
			local function buildPreview(inner, bull, owned)
				local kitIcon = inner:FindFirstChild("Icon")
				if kitIcon and kitIcon:IsA("ImageLabel") then
					kitIcon.Visible = false
				end
				local viewport = Instance.new("ViewportFrame")
				viewport.Name = "BullPreview"
				viewport.BackgroundTransparency = 1
				viewport.AnchorPoint = Vector2.new(0.5, 0.5)
				viewport.Position = UDim2.fromScale(0.5, 0.5)
				viewport.Size = UDim2.fromScale(0.96, 0.82)
				viewport.ZIndex = 0 -- kit name/info labels sit above at 1
				viewport.Ambient = Color3.fromRGB(165, 160, 155)
				viewport.LightColor = Color3.fromRGB(255, 250, 240)
				viewport.LightDirection = Vector3.new(-0.4, -1, -0.6)
				viewport.ImageColor3 = if owned then Color3.new(1, 1, 1) else Color3.fromRGB(16, 14, 18)
				local source = (bull.modelName and modelsFolder and modelsFolder:FindFirstChild(bull.modelName))
					or fallbackModel
				if source then
					local model = source:Clone()
					model:PivotTo(CFrame.new())
					local center, size = Vector3.zero, Vector3.new(10, 10, 10)
					pcall(function()
						local cf, bbox = model:GetBoundingBox()
						center, size = cf.Position, bbox
					end)
					local camera = Instance.new("Camera")
					-- front faces -Z, so eye off the -Z side, high and to the left
					camera.CFrame = CFrame.lookAt(center + Vector3.new(-0.55, 0.42, -1).Unit * size.Magnitude * 0.72, center)
					camera.Parent = viewport
					viewport.CurrentCamera = camera
					model.Parent = viewport
				end
				viewport.Parent = inner
			end

			local function rebuild()
				local owned = ownedSet()
				local mutations = mutationsByBull()
				local equippedId = player:GetAttribute("EquippedBull") or "STARTER"

				for _, child in ipairs(container:GetChildren()) do
					if child:IsA("Frame") and child:FindFirstChild("Frame") then
						child:Destroy()
					end
				end

				for i, id in ipairs(byRarity[currentRarity] or {}) do
					local bull = BullCatalog.Bulls[id]
					local has = owned[id] == true
					local card = cardTemplate:Clone()
					card.Name = id
					card.LayoutOrder = i
					local inner = card:FindFirstChild("Frame")
					if inner then
						local nameLabel = inner:FindFirstChild("Name")
						if nameLabel and nameLabel:IsA("TextLabel") then
							nameLabel.Text = if has then bull.name else "???"
						end
						local info = inner:FindFirstChild("Info")
						local typeLabel = info and info:FindFirstChild("Type")
						local rarityLabel = info and info:FindFirstChild("Rarity")
						if typeLabel and typeLabel:IsA("TextLabel") then
							typeLabel.Text = ("Speed %d"):format(bull.speed)
						end
						if rarityLabel and rarityLabel:IsA("TextLabel") then
							rarityLabel.Text = DISPLAY[currentRarity] or currentRarity
							local tier = BullCatalog.Rarities[currentRarity]
							local tcol = (tier and tier.color) or Color3.fromRGB(200, 200, 200)
							-- the kit ships a rainbow "BrainrotGod" UIGradient on this label,
							-- and a gradient overrides TextColor3 — so swap it for the roll
							-- wheel cards' juicy tier ramp (bright highlight at the top of
							-- the glyphs, saturated tier colour through the middle, deep
							-- shade at the baseline)
							for _, g in ipairs(rarityLabel:GetChildren()) do
								if g:IsA("UIGradient") then
									g:Destroy()
								end
							end
							rarityLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
							local rg = Instance.new("UIGradient")
							rg.Rotation = 90
							rg.Color = ColorSequence.new({
								ColorSequenceKeypoint.new(0, tcol:Lerp(Color3.new(1, 1, 1), 0.55)),
								ColorSequenceKeypoint.new(0.45, tcol),
								ColorSequenceKeypoint.new(1, tcol:Lerp(Color3.fromRGB(15, 15, 15), 0.5)),
							})
							rg.Parent = rarityLabel
						end
						buildPreview(inner, bull, has)

						-- owned mutations ride a RichText strip over the top of the
						-- preview, each name in its own color; ★ marks the one the
						-- bull WEARS on throws (rarest — BullCatalog.bestMutation,
						-- the same pick the server makes)
						local ownedMuts = has and mutations[id] or nil
						if ownedMuts and next(ownedMuts) ~= nil then
							local worn = BullCatalog.bestMutation and BullCatalog.bestMutation(ownedMuts) or nil
							local mutIds = {}
							for mutId in ownedMuts do
								if BullCatalog.Mutations[mutId] then
									table.insert(mutIds, mutId)
								end
							end
							table.sort(mutIds, function(a, b)
								if a == worn then return true end
								if b == worn then return false end
								return (BullCatalog.Mutations[a].order or 99) < (BullCatalog.Mutations[b].order or 99)
							end)
							local pieces = {}
							for _, mutId in ipairs(mutIds) do
								local m = BullCatalog.Mutations[mutId]
								local hex = string.format("#%02X%02X%02X",
									math.floor(m.color.R * 255 + 0.5),
									math.floor(m.color.G * 255 + 0.5),
									math.floor(m.color.B * 255 + 0.5))
								table.insert(pieces, ('<font color="%s">%s%s</font>'):format(
									hex, if mutId == worn then "★" else "", m.name))
							end
							local nameSource = inner:FindFirstChild("Name")
							if #pieces > 0 and nameSource and nameSource:IsA("TextLabel") then
								local tag = nameSource:Clone()
								tag.Name = "MutationTag"
								tag.RichText = true
								tag.Text = table.concat(pieces, " ")
								tag.TextColor3 = Color3.fromRGB(255, 255, 255)
								tag.Position = UDim2.fromScale(0.03, 0.03)
								tag.Size = UDim2.fromScale(0.93, 0.11)
								tag.ZIndex = 2
								for _, g in ipairs(tag:GetChildren()) do
									if g:IsA("UIGradient") then
										g:Destroy()
									end
								end
								tag.Parent = inner
							end
						end

						if id == equippedId then
							local stroke = inner:FindFirstChildWhichIsA("UIStroke")
							if stroke then
								stroke.Color = Color3.fromRGB(90, 220, 110)
							end
							local nameSource = inner:FindFirstChild("Name")
							if nameSource and nameSource:IsA("TextLabel") then
								local tag = nameSource:Clone()
								tag.Name = "EquippedTag"
								tag.Text = "EQUIPPED"
								tag.TextColor3 = Color3.fromRGB(90, 220, 110)
								tag.Position = UDim2.fromScale(0.03, 0.8)
								tag.Size = UDim2.fromScale(0.93, 0.13)
								tag.ZIndex = 2
								for _, g in ipairs(tag:GetChildren()) do
									if g:IsA("UIGradient") then
										g:Destroy()
									end
								end
								tag.Parent = inner
							end
						end

						-- whole card = the equip button (hover grows the card
						-- itself; a UIScale on an invisible overlay shows nothing)
						local btn = Instance.new("TextButton")
						btn.Name = "EquipButton"
						btn.BackgroundTransparency = 1
						btn.Text = ""
						btn.Size = UDim2.fromScale(1, 1)
						btn.ZIndex = 5
						local innerScale = ensureScale(inner)
						btn.MouseEnter:Connect(function()
							playHover()
							tween(innerScale, HOVER_TI, { Scale = 1.06 })
						end)
						btn.MouseLeave:Connect(function()
							tween(innerScale, HOVER_TI, { Scale = 1 })
						end)
						btn.Activated:Connect(function()
							playClick()
							if not has then
								if pushNotif then
									pushNotif("Roll to unlock " .. bull.name .. "!", "white", 2.5)
								end
							elseif id ~= (player:GetAttribute("EquippedBull") or "STARTER") then
								equipRemote:FireServer(id)
							end
						end)
						btn.Parent = card
					end
					card.Parent = container
				end
			end

			local tabs = {}
			local function paintTabs()
				for rarity, btn in tabs do
					local active = rarity == currentRarity
					local sel = btn:FindFirstChild("Selected")
					local unsel = btn:FindFirstChild("NotSelected")
					if sel and sel:IsA("UIGradient") then
						sel.Enabled = active
					end
					if unsel and unsel:IsA("UIGradient") then
						unsel.Enabled = not active
					end
				end
				if headerName and headerName:IsA("TextLabel") then
					headerName.Text = "Bulls: " .. (DISPLAY[currentRarity] or currentRarity)
				end
			end

			for i, sourceName in ipairs(TAB_SOURCE) do
				local rarity = RARITIES[i]
				local btn = typeButtons:FindFirstChild(sourceName)
				if btn and btn:IsA("GuiButton") then
					tabs[rarity] = btn
					local label = btn:FindFirstChild("Name")
					if label and label:IsA("TextLabel") then
						label.Text = DISPLAY[rarity]
						-- the kit's gold/diamond/rainbow letter ramps fight the tier colors,
						-- so swap them for the SAME tier ramp the card rarity labels wear
						-- (lit top -> saturated middle -> shaded baseline) so the tabs read
						-- with the same gradient look as everything else.
						for _, g in ipairs(label:GetChildren()) do
							if g:IsA("UIGradient") then
								g:Destroy()
							end
						end
						local tier = BullCatalog.Rarities[rarity]
						if tier and tier.color then
							local col = tier.color
							-- white text: a UIGradient MULTIPLIES TextColor3, so the label
							-- must stay white for the ramp to show at full value (exactly how
							-- the card rarity labels do it). Tinting it first would double up
							-- the tier colour and read too dark.
							label.TextColor3 = Color3.fromRGB(255, 255, 255)
							local grad = Instance.new("UIGradient")
							grad.Rotation = 90 -- top -> baseline, highlight up top
							grad.Color = ColorSequence.new({
								ColorSequenceKeypoint.new(0, col:Lerp(Color3.fromRGB(255, 255, 255), 0.55)),
								ColorSequenceKeypoint.new(0.45, col),
								ColorSequenceKeypoint.new(1, col:Lerp(Color3.fromRGB(15, 15, 15), 0.5)),
							})
							grad.Parent = label
						end
					end
					btn.Activated:Connect(function()
						if currentRarity ~= rarity then
							currentRarity = rarity
							paintTabs()
							rebuild()
						end
					end)
				end
			end

			-- Quests strip -> collection meter (the one-line equip hint below it is
			-- hidden per user request 2026-07-10)
			local progress = quests and quests:FindFirstChild("Progress")
			local progressBar = progress and progress:FindFirstChild("Bar")
			local progressAmount = progress and progress:FindFirstChild("Amount")
			local questDes = quests and quests:FindFirstChild("QuestDes")
			if questDes then
				questDes.Visible = false
			end
			local function refreshMeter()
				local owned = ownedSet()
				local count = 0
				for id in owned do
					if BullCatalog.Bulls[id] then
						count += 1
					end
				end
				if progressAmount and progressAmount:IsA("TextLabel") then
					progressAmount.Text = ("%d/%d Collected"):format(count, totalBulls)
				end
				if progressBar then
					progressBar.Size = UDim2.new(
						math.clamp(count / math.max(totalBulls, 1), 0, 1), 0,
						progressBar.Size.Y.Scale, progressBar.Size.Y.Offset)
				end
			end

			player:GetAttributeChangedSignal("Bulls"):Connect(function()
				refreshMeter()
				rebuild()
			end)
			player:GetAttributeChangedSignal("EquippedBull"):Connect(rebuild)
			player:GetAttributeChangedSignal("BullMutations"):Connect(rebuild)

			-- ONLY the EQUIPPED ack: section 11's handler owns every DENIED
			-- reason, so a second connection here would double the red cards.
			if ackRemote then
				ackRemote.OnClientEvent:Connect(function(kind, data)
					if kind == "EQUIPPED" and typeof(data) == "table" then
						local bull = data.bullId and BullCatalog.Bulls[data.bullId]
						if bull and pushNotif then
							pushNotif("Equipped " .. bull.name .. "!", "green", 3)
						end
					end
				end)
			end

			paintTabs()
			refreshMeter()
			rebuild()
		end)
	end
end

---------------------------------------------------------------- 13) daily reward
-- Frames.Daily wired to DailyRewardService: the kit's 7 prebuilt day-cards
-- (Container.1..7) become the 7-day loop, each painted from Config.DAILY.REWARDS.
-- The claimable day shows the bright "Claim" button (fires DailyRequest); days
-- already claimed THIS cycle read "Claimed", future days + the current day while
-- it's still on cooldown read "Locked" (the kit's three-state button = a Claim
-- gradient vs a Claimed/Locked gradient toggled by .Enabled, plus a text label).
-- State + countdown ride the DailyDay/DailyReady/DailyStreak/NextDailyClaim
-- player attributes (DailyRewardService, no fetch remote), so the window stays
-- current even while closed. The HUD "Gifts" button already opens it (FRAME_MAP).
do
	local dailyFrame = Frames:FindFirstChild("Daily")
	local container = dailyFrame and dailyFrame:FindFirstChild("Container")
	if dailyFrame and container then
		local header = dailyFrame:FindFirstChild("Header")
		local headerName = header and header:FindFirstChild("Name")
		local nextReward = dailyFrame:FindFirstChild("NextReward")
		if headerName and headerName:IsA("TextLabel") then
			headerName.Text = "Daily Rewards"
		end

		-- kit cards ship with brainrot placeholder icons; swap in the fortune
		-- wheel's own slice art (section 10) so the daily track matches the
		-- wheel instead of flat emoji (user request 2026-07-09): the coin for
		-- money days, the spin token for spin days, and the La Vacca bull for
		-- the Lucky Box day (its reward IS a bull).
		local KIND_ICON = {
			money = "rbxassetid://92705764395288", -- wheel "+100" coin
			spin = "rbxassetid://135276741715203", -- spin icon placed on the Day 3 card
			box = "rbxassetid://82545220922324", -- wheel "La Vacca" bull
		}
		-- per-day icon overrides beat the kind default: Day 1 wears fortune
		-- wheel slice #6's art instead of the shared money coin (user request
		-- 2026-07-09).
		local DAY_ICON = {
			[1] = "rbxassetid://107981444977206", -- fortune wheel slice #6 icon
		}
		-- emoji fallback for any reward kind without a wheel icon
		local GLYPH = { money = "$", spin = "SPIN", box = "BOX" }

		task.spawn(function()
			local bullrush = ReplicatedStorage:WaitForChild("Bullrush", 30)
			local remotes = bullrush and bullrush:FindFirstChild("Remotes")
			local requestRemote = remotes and remotes:WaitForChild("DailyRequest", 30)
			local ackRemote = remotes and remotes:WaitForChild("DailyAck", 30)
			local okConfig, Config = pcall(require, bullrush:WaitForChild("Config"))
			if not (requestRemote and ackRemote and okConfig and typeof(Config) == "table"
				and typeof(Config.DAILY) == "table" and typeof(Config.DAILY.REWARDS) == "table") then
				warn("[Main] Daily reward prerequisites missing; daily UI disabled")
				return
			end
			local REWARDS = Config.DAILY.REWARDS
			local COOLDOWN = Config.DAILY.CLAIM_COOLDOWN

			-- Card colours (user request 2026-07-13, replaces the 07-10 traffic
			-- light): GREEN = the claimable day, RED = the single next-up day
			-- (the one with the live unlock countdown), GREY = everything else
			-- (claimed days and later locked days). Each card owns its own
			-- gradients, so we recolour per-card.
			local CLAIM_GREEN = ColorSequence.new(Color3.fromRGB(126, 217, 87), Color3.fromRGB(46, 160, 67))
			local TIMER_RED = ColorSequence.new(Color3.fromRGB(255, 96, 84), Color3.fromRGB(196, 40, 40))
			local INACTIVE_GREY = ColorSequence.new(Color3.fromRGB(150, 150, 150), Color3.fromRGB(88, 88, 88))

			-- "5h 12m" / "8m 3s" / "12s" — shared by the card countdowns + NextReward
			local function formatDuration(seconds: number): string
				seconds = math.max(0, math.floor(seconds))
				if seconds >= 3600 then
					return ("%dh %dm"):format(seconds // 3600, (seconds % 3600) // 60)
				elseif seconds >= 60 then
					return ("%dm %ds"):format(seconds // 60, seconds % 60)
				end
				return ("%ds"):format(seconds)
			end

			-- map the kit's day-cards (named "1".."7") to their reward
			local cards: { [number]: Instance } = {}
			for _, reward in ipairs(REWARDS) do
				local card = container:FindFirstChild(tostring(reward.day))
				if card then
					cards[reward.day] = card
				end
			end

			-- money-day amounts wear the HUD Cash counter's green (user request
			-- 2026-07-09): copy its colour + gradient + stroke off the live
			-- bottom-left label so a future retint of the counter carries here too
			-- (section 7 / the round summary style money the same way).
			local cashStyleSource = counters and counters:FindFirstChild("Cash")
			cashStyleSource = cashStyleSource and cashStyleSource:FindFirstChild("Amount")
			local function paintMoneyStyle(label)
				if not (cashStyleSource and label) then
					return
				end
				label.TextColor3 = cashStyleSource.TextColor3
				local srcGrad = cashStyleSource:FindFirstChildOfClass("UIGradient")
				if srcGrad then
					local grad = label:FindFirstChildOfClass("UIGradient")
					if not grad then
						grad = Instance.new("UIGradient")
						grad.Parent = label
					end
					grad.Color = srcGrad.Color
					grad.Transparency = srcGrad.Transparency
					grad.Rotation = srcGrad.Rotation
				end
				local srcStroke = cashStyleSource:FindFirstChildOfClass("UIStroke")
				local stroke = label:FindFirstChildOfClass("UIStroke")
				if srcStroke and stroke then
					stroke.Color = srcStroke.Color -- keep the label's own thickness
				end
			end

			-- paint each card's static content once: "Day N", the reward label,
			-- and the wheel icon (or an emoji glyph fallback) over the kit icon
			for day, card in cards do
				local reward = REWARDS[day]
				local nameLabel = card:FindFirstChild("Name")
				local amountLabel = card:FindFirstChild("Amount")
				if nameLabel and nameLabel:IsA("TextLabel") then
					nameLabel.Text = "Day " .. day
				end
				if amountLabel and amountLabel:IsA("TextLabel") then
					amountLabel.Text = reward.label
					if reward.kind == "money" then
						paintMoneyStyle(amountLabel)
					end
				end
				local icon = card:FindFirstChild("Icon")
				if icon and icon:IsA("ImageLabel") then
					local assetId = DAY_ICON[day] or KIND_ICON[reward.kind]
					if assetId then
						-- reuse the fortune wheel's slice art (no placeholder tint)
						icon.Image = assetId
						icon.BackgroundTransparency = 1
						icon.ScaleType = Enum.ScaleType.Fit
						local stale = icon:FindFirstChild("Glyph")
						if stale then
							stale:Destroy()
						end
					else
						-- no wheel icon for this kind: fall back to an emoji glyph
						icon.Image = ""
						icon.BackgroundTransparency = 1
						local glyph = icon:FindFirstChild("Glyph")
						if not glyph then
							glyph = Instance.new("TextLabel")
							glyph.Name = "Glyph"
							glyph.BackgroundTransparency = 1
							glyph.Size = UDim2.fromScale(1, 1)
							glyph.Font = Enum.Font.GothamBlack
							glyph.TextScaled = true
							glyph.Parent = icon
						end
						glyph.Text = GLYPH[reward.kind] or "?"
					end
				end
			end

			-- CLAIMED = a past day this cycle (day < the day-to-claim-next);
			-- CLAIM   = the day-to-claim-next, and a reward is ready right now;
			-- LOCKED  = a future day, or the current day still on cooldown.
			-- DailyDay resets to 1 at the top of each new cycle, so this wraps.
			local function stateOf(day: number): string
				local currentDay = tonumber(player:GetAttribute("DailyDay")) or 1
				local ready = player:GetAttribute("DailyReady") == true
				if day < currentDay then
					return "CLAIMED"
				elseif day == currentDay and ready then
					return "CLAIM"
				end
				return "LOCKED"
			end

			local function renderCard(day: number)
				local card = cards[day]
				local button = card and card:FindFirstChild("Claim/Claimed/Locked")
				if not button then
					return
				end
				-- The pill colour players actually SEE belongs to Decor.Stud — an
				-- ImageLabel with an OPAQUE white background at a higher ZIndex
				-- that covers the whole button and carries its OWN Claim +
				-- Claimed/Locked gradient pair. The button's identical pair sits
				-- underneath it and never shows, so recolour BOTH surfaces.
				local surfaces = { button }
				local decor = button:FindFirstChild("Decor")
				local stud = decor and decor:FindFirstChild("Stud")
				if stud then
					table.insert(surfaces, stud)
				end
				local btnLabel = button:FindFirstChild("Claim/Claimed/Locked") -- the TextLabel child
				local currentDay = tonumber(player:GetAttribute("DailyDay")) or 1
				local ready = player:GetAttribute("DailyReady") == true
				local state = stateOf(day)
				local isClaim = state == "CLAIM"
				-- the single next-up locked day: today while it's still on cooldown,
				-- or tomorrow once a reward is ready — the only red card and the
				-- only one previewing a countdown
				local nextLockedDay = if ready then currentDay + 1 else currentDay

				for _, surface in surfaces do
					local claimGrad = surface:FindFirstChild("Claim")          -- bright, "claimable" look
					local dimGrad = surface:FindFirstChild("Claimed/Locked")   -- red/grey, inactive look
					if claimGrad and claimGrad:IsA("UIGradient") then
						claimGrad.Enabled = isClaim
						if isClaim then
							claimGrad.Color = CLAIM_GREEN
						end
					end
					if dimGrad and dimGrad:IsA("UIGradient") then
						dimGrad.Enabled = not isClaim
						-- claimed days can never be the next-up day (they're behind
						-- currentDay), so this cleanly leaves them grey too
						if day == nextLockedDay then
							dimGrad.Color = TIMER_RED
						else
							dimGrad.Color = INACTIVE_GREY
						end
					end
				end
				if btnLabel and btnLabel:IsA("TextLabel") then
					if state == "CLAIMED" then
						btnLabel.Text = "Claimed"
					elseif isClaim then
						btnLabel.Text = "Claim"
					else
						-- LOCKED: only the next-up day previews a countdown; every
						-- later day just reads "Locked" (no more 40h/60h chain)
						if day == nextLockedDay then
							local now = workspace:GetServerTimeNow()
							local base = if ready then now else (tonumber(player:GetAttribute("NextDailyClaim")) or now)
							local unlockAt = base + (day - currentDay) * COOLDOWN
							btnLabel.Text = formatDuration(unlockAt - now)
						else
							btnLabel.Text = "Locked"
						end
					end
				end
				-- only the ready card reacts to clicks (the Activated guard below
				-- double-checks, but this also kills the hover-depress on dead cards)
				button.Active = isClaim
				button.AutoButtonColor = isClaim
			end

			local function renderAll()
				for day in cards do
					renderCard(day)
				end
			end

			-- Auto-open the window ONCE on join when a reward is waiting (user
			-- request 2026-07-09). Gated to the FIRST attribute seed: a player who
			-- joins on cooldown is disarmed then, so the window never pops itself
			-- later when the timer laps mid-session. Only opens when nothing else
			-- is already up, so it never steals focus from the round summary etc.
			local autoOpenChecked = false
			local function maybeAutoOpen()
				if autoOpenChecked then
					return
				end
				local ready = player:GetAttribute("DailyReady")
				if ready == nil then
					return -- attributes not seeded yet; wait for the server
				end
				autoOpenChecked = true
				if ready == true and currentFrame == nil then
					openFrame(dailyFrame)
				end
			end

			-- NextReward = the countdown; mirrors the wheel's timer (section 10),
			-- reading NextDailyClaim against the synced server clock.
			local function refreshTimer()
				if not (nextReward and nextReward:IsA("TextLabel")) then
					return
				end
				if player:GetAttribute("DailyReady") == true then
					nextReward.Text = ""
					return
				end
				local nextAt = tonumber(player:GetAttribute("NextDailyClaim"))
				if not nextAt or nextAt <= 0 then
					nextReward.Text = ""
					return
				end
				local remaining = nextAt - workspace:GetServerTimeNow()
				if remaining <= 0 then
					nextReward.Text = ""
				else
					nextReward.Text = "Next reward in: " .. formatDuration(remaining)
				end
			end

			-- claim wiring: every card's button is connected, but only the one
			-- that's actually claimable right now fires the request
			for day, card in cards do
				local button = card:FindFirstChild("Claim/Claimed/Locked")
				if button and button:IsA("GuiButton") then
					button.Activated:Connect(function()
						if stateOf(day) == "CLAIM" then
							requestRemote:FireServer()
						end
					end)
				end
			end

			-- "Skip All" header button: pays Robux (DAILY_CLAIM_ALL dev product)
			-- to bank the whole 7-day loop at once, skipping every cooldown. The
			-- server's receipt handler runs grantClaimAll and echoes CLAIMED_ALL
			-- back through DailyAck (handled below).
			do
				local buttons = header and header:FindFirstChild("Buttons")
				local skipAll = buttons and buttons:FindFirstChild("SkipAll")
				local claimAllId = typeof(Config.PRODUCTS) == "table" and Config.PRODUCTS.DAILY_CLAIM_ALL
				if skipAll and skipAll:IsA("GuiButton") and claimAllId then
					skipAll.Activated:Connect(function()
						MarketplaceService:PromptProductPurchase(player, claimAllId)
					end)
				elseif skipAll then
					warn("[Main] Daily SkipAll button present but DAILY_CLAIM_ALL product id missing")
				end
			end

			-- reward feedback (the attribute changes re-render the track)
			ackRemote.OnClientEvent:Connect(function(kind, data)
				if kind == "CLAIMED" and typeof(data) == "table" then
					local reward = typeof(data.reward) == "table" and data.reward or {}
					if reward.kind == "money" then
						if pushNotif then
							pushNotif(("Daily reward: +$%s!"):format(comma(tonumber(reward.amount) or 0)), "green", 4)
						end
					elseif reward.kind == "spin" then
						local n = tonumber(reward.amount) or 0
						if pushNotif then
							pushNotif(("Daily reward: +%d wheel spin%s!"):format(n, if n == 1 then "" else "s"), "green", 4)
						end
					elseif reward.kind == "box" then
						local okCat, BullCatalog = pcall(require, bullrush:FindFirstChild("BullCatalog"))
						local bull = okCat and typeof(BullCatalog) == "table" and data.bullId and BullCatalog.Bulls[data.bullId]
						local bullName = (bull and bull.name or tostring(data.bullId)):upper()
						if pushNotif then
							if data.isNew then
								pushNotif(("Daily reward: %s — a new bull!"):format(bullName), "green", 5)
							else
								pushNotif(("Daily reward: %s (duplicate) +$%s"):format(bullName, comma(tonumber(data.refund) or 0)), "green", 5)
							end
						end
					end
					renderAll()
					refreshTimer()
				elseif kind == "CLAIMED_ALL" and typeof(data) == "table" then
					-- the Robux "Skip All" purchase banked the whole loop at once
					if pushNotif then
						local n = typeof(data.rewards) == "table" and #data.rewards or 0
						pushNotif(("Claimed all %d daily rewards!"):format(n), "green", 5)
					end
					renderAll()
					refreshTimer()
				elseif kind == "DENIED" and typeof(data) == "table" and pushNotif then
					if data.reason == "COOLDOWN" then
						pushNotif("Reward not ready yet!", "red", 4)
					elseif data.reason == "DATA_NOT_LOADED" then
						pushNotif("Still loading — try again", "red", 4)
					end
				end
			end)

			-- the server seeds/flips DailyReady / advances DailyDay; re-render on
			-- any of it, and take the one-shot join auto-open on the first seed
			for _, attr in { "DailyDay", "DailyReady", "DailyStreak", "NextDailyClaim" } do
				player:GetAttributeChangedSignal(attr):Connect(function()
					renderAll()
					refreshTimer()
					maybeAutoOpen()
				end)
			end

			renderAll()
			maybeAutoOpen() -- in case the attributes were already seeded before this ran
			task.spawn(function()
				while true do
					renderAll() -- ticks the locked cards' live unlock countdowns
					refreshTimer()
					task.wait(1)
				end
			end)
		end)
	end
end

---------------------------------------------------------------- 14) round vote
-- Bottom-center HUD panel shown during intermission: vote for the next round's
-- game type among the server's random ballot (Remotes.RoundState.voteOptions),
-- with a live counter per option (info.voteCounts). Clicking casts/changes the
-- vote via Remotes.VoteMode; the server echoes new counts on the next resend.
-- Cards are built FROM SCRATCH in the house UI DNA (dark glass, mode-tinted
-- accents, gold-ramp headline, INK strokes) — NOT cloned from kit frames. A
-- previous version cloned the Daily day-card, which dragged its Starburst/
-- Highlight decor + gold Claim gradient along and flashed a full-screen
-- yellow box on click.
-- Cards are TEXT-ONLY: the mode name is the hero, in the house gold-ramp
-- headline (user request 2026-07-13 — replaced the ViewportFrame arena
-- renders; the whole field-picture rig went with it, and the cards/panel
-- shrank to fit the shorter content).
-- Self-contained on its own overlay so it shows over whatever frame is open.
-- The panel holds off until the player has respawned back in the lobby, then
-- waits a short beat, so it never pops up over the arena / winner banner.
do
	local INK = Color3.fromRGB(15, 15, 15)
	local PAPER = Color3.fromRGB(255, 255, 255)
	local SELECT_GREEN = Color3.fromRGB(126, 217, 87) -- house claim-green (matches the Daily ready state)
	local GLASS = Color3.fromRGB(26, 22, 32)
	local REVEAL_PAUSE = 2 -- seconds after the lobby respawn before the panel slides in
	-- mode.name -> accent colour (matches the CurrentArea banner's GAME_TYPE map)
	local MODE_COLOR = {
		["Classic"] = Color3.fromRGB(95, 175, 255),
		["Mega Grid"] = Color3.fromRGB(255, 150, 40),
		["Small Grid"] = Color3.fromRGB(90, 220, 110),
		["Stampede"] = Color3.fromRGB(255, 80, 70),
		["Team Rush"] = Color3.fromRGB(200, 120, 255),
		["Low Gravity"] = Color3.fromRGB(120, 220, 255),
		["High Speed"] = Color3.fromRGB(255, 221, 51),
	}
	-- house gold ramp for the card's mode-name headline (same family as the
	-- shop/daily headers: warm cream down to deep gold)
	local GOLD_RAMP = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 243, 194)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 205, 110)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 170, 60)),
	})

	local voteRemote = nil -- Remotes.VoteMode, resolved off-thread below

	local voteGui = Instance.new("ScreenGui")
	voteGui.Name = "VoteGui"
	voteGui.DisplayOrder = -20 -- LOWEST priority: the Main ScreenGui (shop +
	-- every tab frame) sits at DisplayOrder -10 (NOT the default 0!), the
	-- Bullrush HUD at 10, notifs at 10000 — -20 keeps the vote HUD under all
	-- of them, so any open tab covers it (user request 2026-07-10)
	voteGui.ResetOnSpawn = false
	voteGui.IgnoreGuiInset = false
	voteGui.Enabled = false
	voteGui.Parent = gui.Parent

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 1)
	-- bottom edge 48px up: floats clear of the XP bar instead of sitting flush
	-- on it (raised from -18 on user request 2026-07-13)
	panel.Position = UDim2.new(0.5, 0, 1, -48)
	panel.Size = UDim2.new(0, 510, 0, 164)
	panel.BackgroundTransparency = 1
	panel.Parent = voteGui
	ensureScale(panel)

	-- The panel is fixed-pixel (510x164), so on a phone viewport it swallows
	-- most of the screen. Shrink the whole panel toward the viewport (min of the
	-- width/height ratios vs a 1280x720 baseline, floored so the buttons stay
	-- tappable); desktop keeps scale 1.
	local function fitScale(): number
		local cam = workspace.CurrentCamera
		local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
		return math.clamp(math.min(vp.X / 1280, vp.Y / 720), 0.65, 1)
	end

	local header = Instance.new("TextLabel")
	header.Name = "Header"
	header.AnchorPoint = Vector2.new(0.5, 0)
	header.Position = UDim2.new(0.5, 0, 0, 0)
	header.Size = UDim2.new(1, 0, 0.183, 0) -- 30/164 of the panel height (scale)
	header.BackgroundTransparency = 1
	header.Font = Enum.Font.GothamBlack
	header.TextColor3 = PAPER
	header.TextStrokeColor3 = INK
	header.TextStrokeTransparency = 0.2
	header.TextScaled = true
	local headerSizeCap = Instance.new("UITextSizeConstraint")
	headerSizeCap.MaxTextSize = 24 -- preserve the original 24px cap on desktop
	headerSizeCap.Parent = header
	header.Text = "VOTE NEXT MODE"
	local headerStroke = Instance.new("UIStroke")
	headerStroke.Color = INK
	headerStroke.Thickness = 2
	headerStroke.Parent = header
	header.Parent = panel

	-- floating close X: a CLONE of the kit's red X (the Spinner's close button,
	-- same source §11's roll screen clones) so it's pixel-identical to every
	-- other close in the game — red stud plate + white "X" already on board,
	-- just reanchored to the panel's top-right. Scratch red fallback if the kit
	-- ever moves. Wired to hide() further down, after hide/revealToken exist.
	local closeSrc = gui:FindFirstChild("Frames")
	closeSrc = closeSrc and closeSrc:FindFirstChild("Spinner")
	closeSrc = closeSrc and closeSrc:FindFirstChild("Close")
	closeSrc = closeSrc and closeSrc:FindFirstChild("Close")
	local closeBtn
	if closeSrc and closeSrc:IsA("GuiButton") then
		closeBtn = closeSrc:Clone()
		closeBtn.Visible = true
		closeBtn.Active = true
		for _, d in ipairs(closeBtn:GetDescendants()) do
			if d:IsA("UIAspectRatioConstraint") then
				d:Destroy()
			end
		end
	else
		closeBtn = Instance.new("TextButton")
		closeBtn.BackgroundColor3 = Color3.fromRGB(255, 80, 70)
		closeBtn.BorderSizePixel = 0
		closeBtn.AutoButtonColor = false
		closeBtn.Font = Enum.Font.GothamBlack
		closeBtn.Text = "X"
		closeBtn.TextColor3 = PAPER
		closeBtn.TextSize = 16
		local closeCorner = Instance.new("UICorner")
		closeCorner.CornerRadius = UDim.new(0, 10)
		closeCorner.Parent = closeBtn
		local closeStroke = Instance.new("UIStroke")
		closeStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		closeStroke.Color = INK
		closeStroke.Thickness = 2
		closeStroke.Parent = closeBtn
	end
	closeBtn.Name = "Close"
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	-- Scale-relative to the panel: 6/510 nudge right, -6/164 nudge up; size is
	-- 34/510 x 34/164 of the panel. The panel is a fixed 510x164 that only ever
	-- scales uniformly, so dual-axis scale stays square with no aspect constraint.
	closeBtn.Position = UDim2.new(1.0118, 0, -0.0366, 0)
	closeBtn.Size = UDim2.new(0.0667, 0, 0.2073, 0)
	closeBtn.Parent = panel
	addButtonFeedback(closeBtn)

	local row = Instance.new("Frame")
	row.Name = "Row"
	row.AnchorPoint = Vector2.new(0.5, 1)
	row.Position = UDim2.new(0.5, 0, 1, 0)
	row.Size = UDim2.new(1, 0, 0, 126)
	row.BackgroundTransparency = 1
	row.Parent = panel

	local rowLayout = Instance.new("UIListLayout")
	rowLayout.FillDirection = Enum.FillDirection.Horizontal
	rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rowLayout.Padding = UDim.new(0, 14)
	rowLayout.Parent = row

	-- id -> { card, stroke, count, btnLabel } for the cards currently on the row
	local cards = {}
	local currentKey = nil -- concat of the ballot's ids; rebuild when it changes
	local myVote = nil

	-- 4-stop kit colour ramp (flat bright band up top -> flat saturated bottom)
	local function modeRamp(col)
		return ColorSequence.new({
			ColorSequenceKeypoint.new(0, col:Lerp(PAPER, 0.35)),
			ColorSequenceKeypoint.new(0.1, col:Lerp(PAPER, 0.35)),
			ColorSequenceKeypoint.new(0.9, col),
			ColorSequenceKeypoint.new(1, col),
		})
	end

	local function styleSelection()
		for id, c in cards do
			local selected = (id == myVote)
			if c.stroke then
				c.stroke.Color = if selected then SELECT_GREEN else c.strokeColor
				c.stroke.Thickness = if selected then 3 else c.strokeThick
				c.stroke.Transparency = if selected then 0 else c.strokeTransp
			end
			if c.accentStroke then
				c.accentStroke.Color = if selected then SELECT_GREEN else c.accentColor
				c.accentStroke.Thickness = if selected then 2 else 1.5
				c.accentStroke.Transparency = if selected then 0.1 else 0.4
			end
			c.count.TextColor3 = if selected then SELECT_GREEN else PAPER
			if c.btnLabel then
				c.btnLabel.Text = if selected then "VOTED" else "VOTE"
			end
		end
	end

	local function buildCards(options)
		for _, c in cards do
			c.card:Destroy()
		end
		table.clear(cards)
		for i, opt in options do
			local name = tostring(opt.name or opt.id or "?")
			local col = MODE_COLOR[name] or Color3.fromRGB(150, 150, 150)

			-- dark-glass plate with a faint mode-tinted sheen bleeding in from
			-- the top (white bg so the gradient's colours render verbatim)
			local card = Instance.new("Frame")
			card.Name = "Vote_" .. tostring(opt.id)
			card.LayoutOrder = i
			card.Size = UDim2.new(0, 150, 0, 118)
			card.BackgroundColor3 = PAPER
			card.BorderSizePixel = 0
			local cardCorner = Instance.new("UICorner")
			cardCorner.CornerRadius = UDim.new(0, 12)
			cardCorner.Parent = card
			local sheen = Instance.new("UIGradient")
			sheen.Rotation = 90
			sheen.Color = ColorSequence.new(col:Lerp(GLASS, 0.8), GLASS)
			sheen.Parent = card
			local stroke = Instance.new("UIStroke")
			stroke.Color = INK
			stroke.Thickness = 2.5
			stroke.Parent = card

			-- inner mode-tinted accent stroke: an inset ring that sits just
			-- inside the INK outline for a layered, beveled plate edge
			local accent = Instance.new("Frame")
			accent.Name = "Accent"
			accent.AnchorPoint = Vector2.new(0.5, 0.5)
			accent.Position = UDim2.new(0.5, 0, 0.5, 0)
			accent.Size = UDim2.new(1, -6, 1, -6)
			accent.BackgroundTransparency = 1
			accent.BorderSizePixel = 0
			accent.ZIndex = card.ZIndex
			local accentCorner = Instance.new("UICorner")
			accentCorner.CornerRadius = UDim.new(0, 9)
			accentCorner.Parent = accent
			local accentStroke = Instance.new("UIStroke")
			accentStroke.Color = col
			accentStroke.Thickness = 1.5
			accentStroke.Transparency = 0.4
			accentStroke.Parent = accent
			accent.Parent = card

			card.Parent = row

			-- the mode name IS the card art now: a big gold-ramp headline filling
			-- the top half (two-word names wrap to two stacked lines via
			-- TextScaled — that's the intended look, not a squeeze)
			local nameLabel = Instance.new("TextLabel")
			nameLabel.Name = "Name"
			nameLabel.AnchorPoint = Vector2.new(0.5, 0)
			nameLabel.Position = UDim2.new(0.5, 0, 0, 8)
			nameLabel.Size = UDim2.new(1, -16, 0, 44)
			nameLabel.BackgroundTransparency = 1
			nameLabel.Font = Enum.Font.GothamBlack
			nameLabel.Text = name
			nameLabel.TextColor3 = PAPER
			nameLabel.TextScaled = true
			local nameFit = Instance.new("UITextSizeConstraint")
			nameFit.MaxTextSize = 20
			nameFit.Parent = nameLabel
			local nameGrad = Instance.new("UIGradient")
			nameGrad.Rotation = 90
			nameGrad.Color = GOLD_RAMP
			nameGrad.Parent = nameLabel
			local nameStroke = Instance.new("UIStroke")
			nameStroke.Color = INK
			nameStroke.Thickness = 2
			nameStroke.Parent = nameLabel
			nameLabel.Parent = card

			-- live vote counter (turns gold once this card is the local pick)
			local countLabel = Instance.new("TextLabel")
			countLabel.Name = "Count"
			countLabel.AnchorPoint = Vector2.new(0.5, 0)
			countLabel.Position = UDim2.new(0.5, 0, 0, 54)
			countLabel.Size = UDim2.new(1, -12, 0, 16)
			countLabel.BackgroundTransparency = 1
			countLabel.Font = Enum.Font.GothamBold
			countLabel.Text = "0 votes"
			countLabel.TextColor3 = PAPER
			countLabel.TextSize = 13
			local countStroke = Instance.new("UIStroke")
			countStroke.Color = INK
			countStroke.Thickness = 1.2
			countStroke.Parent = countLabel
			countLabel.Parent = card

			-- the VOTE button: mode-tinted ramp pill with the shared hover/press feel
			local button = Instance.new("TextButton")
			button.Name = "VoteBtn"
			button.AnchorPoint = Vector2.new(0.5, 1)
			button.Position = UDim2.new(0.5, 0, 1, -10)
			button.Size = UDim2.new(1, -24, 0, 34)
			button.BackgroundColor3 = PAPER -- gradient below is the visible ramp
			button.BorderSizePixel = 0
			button.AutoButtonColor = false
			button.Text = ""
			local btnCorner = Instance.new("UICorner")
			btnCorner.CornerRadius = UDim.new(0, 10)
			btnCorner.Parent = button
			local btnGrad = Instance.new("UIGradient")
			btnGrad.Rotation = 90
			btnGrad.Color = modeRamp(col)
			btnGrad.Parent = button
			local btnStroke = Instance.new("UIStroke")
			btnStroke.Color = INK
			btnStroke.Thickness = 2.5
			btnStroke.Parent = button

			-- inner PAPER highlight ring: an inset outline just inside the INK
			-- edge that reads as a glossy bevel on the pill
			local btnInner = Instance.new("Frame")
			btnInner.Name = "InnerRing"
			btnInner.AnchorPoint = Vector2.new(0.5, 0.5)
			btnInner.Position = UDim2.new(0.5, 0, 0.5, 0)
			btnInner.Size = UDim2.new(1, -5, 1, -5)
			btnInner.BackgroundTransparency = 1
			btnInner.BorderSizePixel = 0
			btnInner.ZIndex = button.ZIndex
			local btnInnerCorner = Instance.new("UICorner")
			btnInnerCorner.CornerRadius = UDim.new(0, 8)
			btnInnerCorner.Parent = btnInner
			local btnInnerStroke = Instance.new("UIStroke")
			btnInnerStroke.Color = PAPER
			btnInnerStroke.Thickness = 1.25
			btnInnerStroke.Transparency = 0.55
			btnInnerStroke.Parent = btnInner
			btnInner.Parent = button
			local btnLabel = Instance.new("TextLabel")
			btnLabel.Name = "Label"
			btnLabel.AnchorPoint = Vector2.new(0.5, 0.5)
			btnLabel.Position = UDim2.new(0.5, 0, 0.5, 0)
			btnLabel.Size = UDim2.new(1, -8, 1, -8)
			btnLabel.BackgroundTransparency = 1
			btnLabel.Font = Enum.Font.GothamBlack
			btnLabel.Text = "VOTE"
			btnLabel.TextColor3 = PAPER
			btnLabel.TextScaled = true
			local btnFit = Instance.new("UITextSizeConstraint")
			btnFit.MaxTextSize = 16
			btnFit.Parent = btnLabel
			local btnLabelStroke = Instance.new("UIStroke")
			btnLabelStroke.Color = INK
			btnLabelStroke.Thickness = 1.4
			btnLabelStroke.Parent = btnLabel
			btnLabel.Parent = button
			button.Parent = card
			addButtonFeedback(button)
			local id = opt.id
			button.Activated:Connect(function()
				if myVote == id then
					return
				end
				myVote = id
				styleSelection()
				if voteRemote then
					voteRemote:FireServer(id)
				end
			end)

			-- selection rides the card's own outline; resting look is fixed INK
			cards[opt.id] = {
				card = card,
				stroke = stroke,
				accentStroke = accentStroke,
				accentColor = col,
				strokeColor = INK,
				strokeThick = 2.5,
				strokeTransp = 0,
				count = countLabel,
				btnLabel = btnLabel,
			}
		end
	end

	local function applyCounts(counts)
		if typeof(counts) ~= "table" then
			return
		end
		for id, c in cards do
			if c.count then
				local n = tonumber(counts[id]) or 0
				c.count.Text = n .. (if n == 1 then " vote" else " votes")
			end
		end
	end

	local shown = false
	local function show()
		if shown then
			return
		end
		shown = true
		voteGui.Enabled = true
		local target = fitScale()
		local scale = ensureScale(panel)
		scale.Scale = 0.6 * target
		tween(scale, POP_IN, { Scale = target })
	end
	local function hide()
		if not shown then
			return
		end
		shown = false
		local scale = ensureScale(panel)
		local tw = tween(scale, POP_OUT, { Scale = 0.6 * fitScale() })
		tw.Completed:Connect(function()
			if not shown then
				voteGui.Enabled = false
			end
		end)
	end

	-- refit on rotation / window resize while the panel is up (the camera can be
	-- swapped out on respawn, so re-hook whenever CurrentCamera changes)
	local function watchViewport()
		local cam = workspace.CurrentCamera
		if cam then
			cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
				if shown then
					ensureScale(panel).Scale = fitScale()
				end
			end)
		end
	end
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchViewport)
	watchViewport()

	-- Hold the panel back until the local player is actually spawned in the lobby
	-- (respawned after the round), then wait REVEAL_PAUSE for a deliberate beat.
	-- The token cancels a pending reveal if the round starts before it fires.
	local revealToken = 0

	-- X = dismiss for this ballot: hide now, cancel any reveal still pending;
	-- the next NEW ballot (key change -> scheduleReveal) brings the panel back
	closeBtn.Activated:Connect(function()
		revealToken += 1
		hide()
	end)

	local function characterReady(): boolean
		local char = player.Character
		local humanoid = char and char:FindFirstChildOfClass("Humanoid")
		return humanoid ~= nil and humanoid.Health > 0 and char:FindFirstChild("HumanoidRootPart") ~= nil
	end
	local function scheduleReveal()
		revealToken += 1
		local token = revealToken
		task.spawn(function()
			while token == revealToken and not characterReady() do
				task.wait(0.1)
			end
			if token ~= revealToken then
				return
			end
			task.wait(REVEAL_PAUSE)
			if token == revealToken then
				show()
			end
		end)
	end

	-- Hook the remotes off the main thread; UI must never stall if Bullrush is
	-- missing from a place copy.
	task.spawn(function()
		local bullrush = ReplicatedStorage:WaitForChild("Bullrush", 30)
		local remotes = bullrush and bullrush:FindFirstChild("Remotes")
		local stateRemote = remotes and remotes:FindFirstChild("RoundState")
		voteRemote = remotes and remotes:FindFirstChild("VoteMode")
		if not (stateRemote and stateRemote:IsA("RemoteEvent")) then
			return
		end
		stateRemote.OnClientEvent:Connect(function(state, info)
			info = if typeof(info) == "table" then info else {}
			local options = info.voteOptions
			if state == "INTERMISSION" and typeof(options) == "table" and #options > 0 then
				local key = ""
				for _, opt in options do
					key ..= tostring(opt.id) .. ","
				end
				if key ~= currentKey then
					currentKey = key
					myVote = nil -- fresh ballot
					buildCards(options)
					scheduleReveal() -- reveal once we're back in the lobby, after a beat
				end
				applyCounts(info.voteCounts)
				styleSelection()
				local seconds = math.max(0, math.floor((tonumber(info.timeLeft) or 0) + 0.5))
				header.Text = ("VOTE NEXT MODE — %ds"):format(seconds)
			else
				currentKey = nil
				myVote = nil
				revealToken += 1 -- cancel any pending reveal
				hide()
			end
		end)
	end)
end

---------------------------------------------------------- 15) lobby update board
-- The lobby "Update" notice board advertises the next Roblox Experience Event
-- and lets players RSVP ("sign up") in-game. Roblox's event API is client-only,
-- so this lives in the one UI LocalScript (it just drives the Workspace board):
--   * SocialService:GetUpcomingExperienceEventsAsync() -> soonest upcoming event
--   * SocialService:PromptRsvpToEventAsync(id) -> native RSVP / "notify me" prompt
-- The board has two states: a minimal PROMO group (a big house-styled headline +
-- INVITE FRIENDS button, shown when no event is scheduled) and an EVENT group.
-- With event artwork (ThumbnailIds) the image fills the whole board and only the
-- countdown, RSVP pill and CTA overlay it; without artwork it falls back to the
-- text layout (kicker pill, title, countdown, description). When no event is
-- live a click opens the friend-invite flow instead of the RSVP prompt.
-- Re-fetches every REFRESH_SECONDS; the countdown ticks between fetches.
do
	local GREEN = Color3.fromRGB(120, 226, 140)
	local DIM = Color3.fromRGB(205, 200, 215)

	-- fallback promo copy (overridden by Config.EVENTS_BOARD once it resolves)
	local promo = {
		HEADLINE = "STAY IN THE LOOP",
		CTA = "INVITE FRIENDS",
		REFRESH = 120,
	}

	task.spawn(function()
		-- the board lives under the lobby and may be reparented, so find it
		-- recursively rather than assuming a fixed path.
		local board = workspace:FindFirstChild("Update", true)
		local t0 = os.clock()
		while not board and os.clock() - t0 < 30 do
			task.wait(0.5)
			board = workspace:FindFirstChild("Update", true)
		end
		local dp = board and board:FindFirstChild("DisplayPart")
		local sg = dp and dp:FindFirstChild("Update")
		local root = sg and sg:WaitForChild("Root", 10)
		local cd = dp and dp:FindFirstChildOfClass("ClickDetector")
		if not (root and cd) then
			return -- board missing from this place copy; nothing to drive
		end

		local promoGroup = root:WaitForChild("Promo")
		local headline = promoGroup:WaitForChild("Headline")
		local eventGroup = root:WaitForChild("Event")
		local title = eventGroup:WaitForChild("Title")
		local whenL = eventGroup:WaitForChild("When")
		local desc = eventGroup:WaitForChild("Desc")
		local statusPill = eventGroup:WaitForChild("Status")
		local kicker = eventGroup:FindFirstChild("Kicker")
		local hero = root:WaitForChild("Hero")
		-- When gets repositioned in image mode; remember its authored spot
		local whenHomePos, whenHomeSize = whenL.Position, whenL.Size
		local ctaFrame = root:WaitForChild("Cta")
		local ctaLabel = ctaFrame:WaitForChild("Label")

		-- pull the fallback promo copy from Config if present
		task.spawn(function()
			local bull = ReplicatedStorage:WaitForChild("Bullrush", 30)
			local ok, cfg = pcall(require, bull and bull:WaitForChild("Config"))
			if ok and typeof(cfg) == "table" and typeof(cfg.EVENTS_BOARD) == "table" then
				local e = cfg.EVENTS_BOARD
				promo.HEADLINE = e.HEADLINE or promo.HEADLINE
				promo.CTA = e.CTA or promo.CTA
				promo.REFRESH = tonumber(e.REFRESH_SECONDS) or promo.REFRESH
			end
		end)

		local current -- the event dict currently shown (nil = fallback promo)

		-- ExperienceEvent carries both raw and localized display fields; prefer
		-- the localized ones, falling back to raw, then a default.
		local function pick(ev, displayKey, rawKey, default)
			local v = ev[displayKey]
			if v == nil or v == "" then v = ev[rawKey] end
			if v == nil or v == "" then return default end
			return tostring(v)
		end

		-- StartTime dict -> "STARTS IN 3D 4H  \194\183  JUL 15, 3:00 PM" (blank if unknown)
		local function whenText(ev)
			local st = ev.StartTime
			if typeof(st) ~= "table" or not st.Year then
				return ""
			end
			local ok, dt = pcall(function()
				return DateTime.fromUniversalTime(st.Year, st.Month, st.Day, st.Hour or 0, st.Minute or 0, st.Second or 0, st.Millisecond or 0)
			end)
			if not ok or not dt then
				return ""
			end
			local secs = dt.UnixTimestamp - os.time()
			local lead
			if ev.HasEnded then
				return ""
			elseif secs <= 60 then
				lead = "HAPPENING NOW"
			elseif secs < 3600 then
				lead = ("STARTS IN %dM"):format(math.floor(secs / 60))
			elseif secs < 86400 then
				lead = ("STARTS IN %dH %dM"):format(math.floor(secs / 3600), math.floor((secs % 3600) / 60))
			else
				lead = ("STARTS IN %dD %dH"):format(math.floor(secs / 86400), math.floor((secs % 86400) / 3600))
			end
			local abs = ""
			pcall(function()
				abs = dt:FormatLocalTime("MMM D, h:mm A", "en-us")
			end)
			if abs ~= "" then
				return lead .. "  \194\183  " .. abs:upper()
			end
			return lead
		end

		-- local player's RSVP for the event (prefer the dict field; else fetch)
		local function isGoing(ev)
			local rs = ev.UserRsvpStatus
			if rs == nil then
				local ok, v = pcall(function()
					return SocialService:GetEventRsvpStatusAsync(ev.Id)
				end)
				if ok then
					rs = v
				end
			end
			return rs == Enum.RsvpStatus.Going
		end

		local function render(ev)
			if ev then
				eventGroup.Visible = true
				promoGroup.Visible = false
				title.Text = pick(ev, "DisplayTitle", "Title", "Upcoming Event")
				desc.Text = pick(ev, "DisplayDescription", "Description", "")
				whenL.Text = whenText(ev)
				-- when the event ships artwork, that image IS the board face:
				-- full-bleed hero, with only the countdown + RSVP pill + CTA
				-- kept on top (the thumbnail already carries the title art)
				local thumb = typeof(ev.ThumbnailIds) == "table" and ev.ThumbnailIds[1]
				if thumb then
					hero.Image = "rbxassetid://" .. tostring(thumb)
					hero.ImageTransparency = 0 -- authored at 0.78 for the old faint-bg look
					hero.Visible = true
					whenL.Position = UDim2.fromScale(0, 0.85)
					whenL.Size = UDim2.fromScale(1, 0.12)
				else
					hero.Visible = false
					whenL.Position = whenHomePos
					whenL.Size = whenHomeSize
				end
				if kicker then
					kicker.Visible = not thumb
				end
				title.Visible = not thumb
				desc.Visible = not thumb
				local going = isGoing(ev)
				statusPill.Visible = true
				if going then
					statusPill.Text = "YOU'RE GOING"
					statusPill.TextColor3 = GREEN
					ctaLabel.Text = "YOU'RE IN \226\128\148 TAP TO MANAGE"
				else
					statusPill.Text = "NOT SIGNED UP"
					statusPill.TextColor3 = DIM
					ctaLabel.Text = "TAP TO SIGN UP"
				end
			else
				eventGroup.Visible = false
				promoGroup.Visible = true
				hero.Visible = false
				headline.Text = promo.HEADLINE
				ctaLabel.Text = promo.CTA
			end
		end

		local function fetch()
			local ok, events = pcall(function()
				return SocialService:GetUpcomingExperienceEventsAsync()
			end)
			current = nil
			if ok and typeof(events) == "table" then
				for _, ev in ipairs(events) do
					if typeof(ev) == "table" and ev.Id and not ev.HasEnded then
						current = ev
						break -- array is sorted soonest-first
					end
				end
			end
			render(current)
		end

		-- friend-invite fallback (mirrors the SideUI Invite button flow)
		local function doInvite()
			local ok, canSend = pcall(function()
				return SocialService:CanSendGameInviteAsync(player)
			end)
			if ok and canSend then
				local opts
				pcall(function()
					opts = Instance.new("ExperienceInviteOptions")
					opts.PromptMessage = "Rally your friends!"
				end)
				if pcall(function()
					SocialService:PromptGameInvite(player, opts)
				end) then
					return
				end
			end
			if pushNotif then
				pushNotif("Sign-ups not available", "red", 3)
			end
		end

		local clickBusy = false
		cd.MouseClick:Connect(function()
			if clickBusy then
				return
			end
			clickBusy = true
			task.spawn(function()
				if current then
					local ok, newStatus = pcall(function()
						return SocialService:PromptRsvpToEventAsync(current.Id)
					end)
					if ok then
						current.UserRsvpStatus = newStatus
						render(current)
						if newStatus == Enum.RsvpStatus.Going and pushNotif then
							pushNotif("You're signed up! 🎉", "green", 4)
						end
					else
						doInvite() -- prompt unavailable (Studio/unpublished) -> invite
					end
				else
					doInvite()
				end
				clickBusy = false
			end)
		end)

		-- gentle hover feedback on the CTA
		local hs = Instance.new("UIScale")
		hs.Parent = ctaFrame
		cd.MouseHoverEnter:Connect(function()
			TweenService:Create(hs, TweenInfo.new(0.12), { Scale = 1.05 }):Play()
		end)
		cd.MouseHoverLeave:Connect(function()
			TweenService:Create(hs, TweenInfo.new(0.12), { Scale = 1 }):Play()
		end)

		-- initial load, then keep the countdown ticking + re-fetch periodically
		fetch()
		local sinceFetch = 0
		while true do
			task.wait(15)
			sinceFetch += 15
			if sinceFetch >= (promo.REFRESH or 120) then
				sinceFetch = 0
				fetch()
			elseif current then
				whenL.Text = whenText(current) -- refresh the live countdown
			end
		end
	end)
end

---------------------------------------------------------- 16) practice timer
-- Survival stopwatch for the practice grid: while YOUR InPractice attribute
-- is on (PracticeArena maintains it), a top-center pill — parked in the free
-- band above the CurrentArea banner (which starts at ~13.5% screen height) —
-- runs big live seconds over a BEST line fed by the PracticeBest attribute
-- (the saved PracticeRecord). The clock freezes the instant you die (the
-- server freezes its authoritative copy at the same moment) and the final
-- time rides the ragdoll out until InPractice clears; outlast your best and
-- the BEST line flips to a gold NEW BEST! live, with the server's green card
-- confirming the save. Own non-resetting ScreenGui (same dance as PushGui)
-- since Main resets on spawn.
do
	local GLASS = Color3.fromRGB(26, 22, 32)
	local INK = Color3.fromRGB(15, 15, 15)
	local GOLD = Color3.fromRGB(255, 205, 110)
	local DIM = Color3.fromRGB(205, 200, 215)

	local oldGui = gui.Parent:FindFirstChild("PracticeTimerGui")
	if oldGui then
		oldGui:Destroy()
	end
	local timerGui = Instance.new("ScreenGui")
	timerGui.Name = "PracticeTimerGui"
	timerGui.ResetOnSpawn = false
	-- priority HUD: above everything including notif cards (10000) and cash
	-- deltas (1000) so the stopwatch always reads at the top; only the
	-- full-screen push flash (20000) still draws over it
	timerGui.DisplayOrder = 15000
	timerGui.Parent = gui.Parent

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0)
	panel.Position = UDim2.fromScale(0.5, 0.02)
	panel.Size = UDim2.fromScale(1, 0.095) -- width comes from the aspect constraint
	panel.BackgroundColor3 = GLASS
	panel.BackgroundTransparency = 0.12
	panel.BorderSizePixel = 0
	panel.Visible = false
	panel.Parent = timerGui

	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 2.6
	aspect.DominantAxis = Enum.DominantAxis.Height
	aspect.Parent = panel

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.16, 0)
	corner.Parent = panel

	local stroke = Instance.new("UIStroke")
	stroke.Color = INK
	stroke.Thickness = 2.5
	stroke.Parent = panel

	local function makeLabel(name, y, h, color)
		local l = Instance.new("TextLabel")
		l.Name = name
		l.BackgroundTransparency = 1
		l.AnchorPoint = Vector2.new(0.5, 0)
		l.Position = UDim2.fromScale(0.5, y)
		l.Size = UDim2.fromScale(0.9, h)
		l.Font = Enum.Font.GothamBlack
		l.TextScaled = true
		l.TextColor3 = color
		local s = Instance.new("UIStroke")
		s.Color = INK
		s.Thickness = 2
		s.Parent = l
		l.Parent = panel
		return l
	end
	local timeLabel = makeLabel("Time", 0.08, 0.54, Color3.fromRGB(255, 255, 255))
	local bestLabel = makeLabel("Best", 0.66, 0.25, DIM)

	local runningSince = nil -- os.clock() at stint start; nil = frozen/hidden

	local function fmtSecs(t)
		return string.format("%.1fs", t)
	end

	local function bestValue()
		return tonumber(player:GetAttribute("PracticeBest")) or 0
	end

	local function refreshBest()
		bestLabel.TextColor3 = DIM
		bestLabel.Text = "BEST " .. fmtSecs(bestValue())
	end

	RunService.Heartbeat:Connect(function()
		if not runningSince then
			return
		end
		local elapsed = os.clock() - runningSince
		timeLabel.Text = fmtSecs(elapsed)
		local best = bestValue()
		if best > 0 and elapsed > best then
			bestLabel.TextColor3 = GOLD
			bestLabel.Text = "NEW BEST!"
		end
	end)

	local function show()
		runningSince = os.clock()
		timeLabel.Text = "0.0s"
		refreshBest()
		panel.Visible = true
		local s = ensureScale(panel)
		s.Scale = 0.6
		tween(s, POP_IN, { Scale = 1 })
	end

	local function hide()
		runningSince = nil
		panel.Visible = false
	end

	-- freeze at the moment of death; the panel (and a NEW BEST! flip) stays
	-- readable through the fling and drops when InPractice clears
	local function watchHumanoid(ch)
		local hum = ch:WaitForChild("Humanoid", 10)
		if hum then
			hum.Died:Connect(function()
				runningSince = nil
			end)
		end
	end
	player.CharacterAdded:Connect(watchHumanoid)
	if player.Character then
		task.spawn(watchHumanoid, player.Character)
	end

	player:GetAttributeChangedSignal("InPractice"):Connect(function()
		if player:GetAttribute("InPractice") == true then
			show()
		else
			hide()
		end
	end)
	-- the server rewrites PracticeBest on entry (just before InPractice flips)
	-- and when a record commits at stint end. Only re-render mid-run — while
	-- the frozen post-death panel is up, the gold NEW BEST! should stand.
	player:GetAttributeChangedSignal("PracticeBest"):Connect(function()
		if runningSince then
			refreshBest()
		end
	end)
	if player:GetAttribute("InPractice") == true then
		show() -- gui (re)built while already on the grid
	end
end

---------------------------------------------------------------- 17) level bar
-- Bottom-center XP bar, always on: a green "LVL N" pill plus a fill that shows
-- progress into the current level. Wears the HUD money look (the Cash
-- counter's lime -> pure-green ramp + deep-green stroke) so "XP" visibly IS
-- money earned. Renders straight off the replicated Level/XP attributes
-- (Data.server seeds them on join; LevelService rewrites them as gameplay
-- money lands) with Config.LEVELS.XP_TO_NEXT as the denominator, so the bar
-- can never disagree with the server's curve. Level-up reward cards come from
-- the server (LevelService -> Notify); here a level change pops the pill,
-- flashes the bar white, and blips the UI click pitched up. Hugs the screen's
-- bottom edge, below the vote panel's (section 14) footprint; at MAX_LEVEL the
-- fill locks full and the text reads MAX.
do
	local INK = Color3.fromRGB(15, 15, 15)
	local GLASS = Color3.fromRGB(26, 22, 32)
	-- the Cash counter's money ramp (Counters.Cash.Amount gradient + stroke)
	local MONEY_LIME = Color3.fromRGB(212, 251, 121)
	local MONEY_GREEN = Color3.fromRGB(0, 249, 0)
	local MONEY_DEEP = Color3.fromRGB(16, 60, 23)
	local BAR_SCALE_W = 0.2 -- of screen width (~380px at 1920); height follows the aspect ratio

	local levelsCfg = nil -- Config.LEVELS, resolved off-thread below

	-- Own overlay so the bar survives whatever frame is open and never joins a
	-- kit layout; modest DisplayOrder keeps notif cards / cash deltas above it.
	local xpGui = Instance.new("ScreenGui")
	xpGui.Name = "XPBarGui"
	xpGui.ResetOnSpawn = false
	xpGui.DisplayOrder = 2
	xpGui.Enabled = false -- dark until Config.LEVELS resolves
	xpGui.Parent = gui.Parent

	local holder = Instance.new("Frame")
	holder.Name = "XPBar"
	holder.AnchorPoint = Vector2.new(0.5, 1)
	holder.Position = UDim2.fromScale(0.5, 0.99)
	holder.Size = UDim2.fromScale(BAR_SCALE_W, 0.02)
	holder.BackgroundColor3 = GLASS
	holder.BackgroundTransparency = 0.15
	holder.Parent = xpGui
	local holderRatio = Instance.new("UIAspectRatioConstraint")
	holderRatio.AspectRatio = 23.75 -- the old 380x16 shape, width-dominant
	holderRatio.Parent = holder
	local holderCorner = Instance.new("UICorner")
	holderCorner.CornerRadius = UDim.new(0.5, 0)
	holderCorner.Parent = holder
	local holderStroke = Instance.new("UIStroke")
	holderStroke.Color = INK
	holderStroke.Thickness = 2
	holderStroke.Parent = holder

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.AnchorPoint = Vector2.new(0, 0.5)
	fill.Position = UDim2.fromScale(0.005, 0.5)
	fill.Size = UDim2.fromScale(0, 0.75)
	fill.BackgroundColor3 = Color3.fromRGB(255, 255, 255) -- gradient below paints it
	fill.BorderSizePixel = 0
	fill.Parent = holder
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0.5, 0)
	fillCorner.Parent = fill
	local fillGradient = Instance.new("UIGradient")
	fillGradient.Rotation = 90
	fillGradient.Color = ColorSequence.new(MONEY_LIME, MONEY_GREEN)
	fillGradient.Parent = fill

	-- Candy gloss: a soft white strip along the fill's top edge (scales with it).
	local gloss = Instance.new("Frame")
	gloss.Name = "Gloss"
	gloss.AnchorPoint = Vector2.new(0.5, 0)
	gloss.Position = UDim2.fromScale(0.5, 0.12)
	gloss.Size = UDim2.fromScale(0.94, 0.33)
	gloss.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	gloss.BackgroundTransparency = 0.65
	gloss.BorderSizePixel = 0
	gloss.ZIndex = 2
	gloss.Parent = fill
	local glossCorner = Instance.new("UICorner")
	glossCorner.CornerRadius = UDim.new(0.5, 0)
	glossCorner.Parent = gloss

	local progressLabel = Instance.new("TextLabel")
	progressLabel.Name = "Progress"
	progressLabel.BackgroundTransparency = 1
	progressLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	progressLabel.Position = UDim2.fromScale(0.5, 0.5)
	progressLabel.Size = UDim2.fromScale(1, 0.7) -- the old 11px-on-16px text height
	progressLabel.Font = Enum.Font.GothamBlack
	progressLabel.TextScaled = true
	progressLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	progressLabel.TextStrokeColor3 = MONEY_DEEP
	progressLabel.TextStrokeTransparency = 0.1
	progressLabel.Text = ""
	progressLabel.ZIndex = 3
	progressLabel.Parent = holder

	-- Level pill hanging off the bar's left end, centered on the bar line:
	-- money-green body, deep-green border, white text.
	local pill = Instance.new("TextLabel")
	pill.Name = "LevelPill"
	pill.AnchorPoint = Vector2.new(1, 0.5)
	pill.Position = UDim2.fromScale(-0.02, 0.5)
	pill.Size = UDim2.fromScale(0.17, 1.4)
	pill.BackgroundColor3 = Color3.fromRGB(255, 255, 255) -- gradient below paints it
	pill.Font = Enum.Font.GothamBlack
	pill.TextScaled = true
	pill.TextColor3 = Color3.fromRGB(255, 255, 255)
	pill.TextStrokeColor3 = MONEY_DEEP
	pill.TextStrokeTransparency = 0.05
	pill.Text = "LVL 1"
	pill.ZIndex = 3
	pill.Parent = holder
	local pillCorner = Instance.new("UICorner")
	pillCorner.CornerRadius = UDim.new(0.5, 0)
	pillCorner.Parent = pill
	local pillGradient = Instance.new("UIGradient")
	pillGradient.Rotation = 90
	pillGradient.Color = ColorSequence.new(MONEY_LIME, MONEY_GREEN)
	pillGradient.Parent = pill
	local pillStroke = Instance.new("UIStroke")
	pillStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	pillStroke.Color = MONEY_DEEP
	pillStroke.Thickness = 2
	pillStroke.Parent = pill

	-- Level-up flash: a white sheet over the whole bar, faded out by repaint.
	local flash = Instance.new("Frame")
	flash.Name = "Flash"
	flash.Size = UDim2.fromScale(1, 1)
	flash.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	flash.BackgroundTransparency = 1
	flash.BorderSizePixel = 0
	flash.ZIndex = 5
	flash.Parent = holder
	local flashCorner = Instance.new("UICorner")
	flashCorner.CornerRadius = UDim.new(0.5, 0)
	flashCorner.Parent = flash

	local lastLevel = nil
	local function repaint()
		if not levelsCfg then
			return
		end
		local level = tonumber(player:GetAttribute("Level")) or 1
		local xp = tonumber(player:GetAttribute("XP")) or 0
		local toNext = levelsCfg.XP_TO_NEXT[level]
		pill.Text = ("LVL %d"):format(level)
		local frac
		if level >= (levelsCfg.MAX_LEVEL or 10) or not toNext then
			progressLabel.Text = "MAX!"
			frac = 1
		else
			progressLabel.Text = ("%s / %s XP"):format(comma(xp), comma(toNext))
			frac = math.clamp(xp / toNext, 0, 1)
		end
		tween(fill, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = UDim2.fromScale(0.99 * frac, 0.75) })
		if lastLevel and level > lastLevel then
			local scale = ensureScale(pill)
			scale.Scale = 1.7
			tween(scale, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
			flash.BackgroundTransparency = 0.35
			tween(flash, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ BackgroundTransparency = 1 })
			playUiSound(1.2, 1.3) -- the UI click pitched up = a light "ding"
		end
		lastLevel = level
	end

	player:GetAttributeChangedSignal("Level"):Connect(repaint)
	player:GetAttributeChangedSignal("XP"):Connect(repaint)

	task.spawn(function()
		local bullrush = ReplicatedStorage:WaitForChild("Bullrush", 60)
		local okCfg, cfg = pcall(require, bullrush and bullrush:WaitForChild("Config", 30))
		if okCfg and typeof(cfg) == "table" and typeof(cfg.LEVELS) == "table"
			and typeof(cfg.LEVELS.XP_TO_NEXT) == "table" then
			levelsCfg = cfg.LEVELS
			repaint()
			xpGui.Enabled = true
		end
	end)
end

---------------------------------------------------------------- 18) tutorial
-- First-session guided tour: purely REACTIVE chrome for the server-owned
-- TutorialStep attribute (Bullrush/TutorialService — 0/4 = nothing, 1 = send
-- a bull, 2 = open the free box, 3 = equip the roll). The server advances
-- the step at each action's real source (RevengeService throw,
-- BullRollService roll + equip), so this section never fires anything — it
-- just keeps ONE pulsing gold stroke + ONE ~5-word hint parked on the next
-- thing to press:
--   1: the Become-a-Bull button, then the SEND BULL panel once viewing
--   2: a billboard on the lobby shop stall (Shop1 has no HUD button — the
--      stall's ShopPrompt is its only door), then the BASIC box's buy
--      button once the window is open
--   3: the Index HUD button, then the right rarity tab, then the new card
-- Hard-hides whenever the player is ALIVE in a round (InRound — the tutorial
-- never blocks play), while the roll carousel is up (never talk over a
-- reveal), and while an unrelated window is open. Copy stays kid-simple:
-- one clause, ~5 words, no popups, no skip (steps done independently
-- auto-complete server-side).
do
	local HttpService = game:GetService("HttpService")

	local GOLD = Color3.fromRGB(255, 210, 60)

	-- §12's rarity tab pairing, needed to point at the right Index tab
	local RARITY_TAB = {
		COMMON = "Normal", UNCOMMON = "Gold", RARE = "Diamond",
		EPIC = "Rainbow", LEGENDARY = "Clover",
	}
	local RARITY_RANK = { COMMON = 1, UNCOMMON = 2, RARE = 3, EPIC = 4, LEGENDARY = 5 }

	local BullCatalog = nil -- resolved off-thread; tab targeting degrades without it
	task.spawn(function()
		local bullrush = ReplicatedStorage:WaitForChild("Bullrush", 60)
		local ok, catalog = pcall(require, bullrush and bullrush:WaitForChild("BullCatalog", 30))
		if ok and typeof(catalog) == "table" then
			BullCatalog = catalog
		end
	end)

	local bridge = nil -- RevengeViewBridge (Eligible/Viewing gates for step 1)
	task.spawn(function()
		local b = ReplicatedStorage:WaitForChild("RevengeViewBridge", 30)
		if b and b:IsA("BindableEvent") then
			bridge = b
		end
	end)

	-- Own overlay, like the XP bar: the hint must draw over open frames (the
	-- Shop1/Index targets live inside them).
	local tutGui = Instance.new("ScreenGui")
	tutGui.Name = "TutorialGui"
	tutGui.ResetOnSpawn = false
	tutGui.DisplayOrder = 3
	tutGui.Parent = gui.Parent

	local hint = Instance.new("TextLabel")
	hint.Name = "TutorialHint"
	hint.BackgroundTransparency = 1
	hint.AutomaticSize = Enum.AutomaticSize.XY
	hint.Size = UDim2.fromOffset(0, 0)
	hint.Font = Enum.Font.GothamBlack
	hint.TextSize = 22
	hint.TextColor3 = GOLD
	hint.Visible = false
	-- crisp UIStroke outline (user request) instead of the soft legacy
	-- TextStroke* fuzz; the stall billboard label clones this stroke along
	local hintStroke = Instance.new("UIStroke")
	hintStroke.Color = Color3.fromRGB(0, 0, 0)
	hintStroke.Thickness = 3
	hintStroke.LineJoinMode = Enum.LineJoinMode.Round
	hintStroke.Parent = hint
	hint.Parent = tutGui

	-- One pulsing stroke, reparented onto whatever needs pressing. An Index
	-- rebuild can destroy it along with its card, and a destroyed instance's
	-- Parent is locked — so re-park through pcall and remake on failure.
	local function makeGlow(): UIStroke
		local s = Instance.new("UIStroke")
		s.Name = "TutorialGlow"
		s.Color = GOLD
		s.Thickness = 4
		s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		return s
	end
	local glow = makeGlow()
	local function parkGlow(target: GuiObject?)
		if glow.Parent == target then
			return
		end
		local ok = pcall(function()
			glow.Parent = target
		end)
		if not ok then
			glow = makeGlow()
			glow.Parent = target
		end
	end

	-- World marker for step 2's "get to the stall" leg: a billboard over the
	-- ShopPrompt part, found with the same streaming-proof scan as the shop
	-- door (section 1b) so a stall reparent can't break it either.
	local stallMarker: BillboardGui? = nil
	local stallLabel: TextLabel? = nil
	local stallPart: BasePart? = nil -- guide-arrow destination, set by the same scan
	task.spawn(function()
		local prompt
		local deadline = os.clock() + 120
		repeat
			for _, d in ipairs(workspace:GetDescendants()) do
				if d:IsA("ProximityPrompt") and d.Name == "ShopPrompt" then
					prompt = d
					break
				end
			end
			if not prompt then
				task.wait(0.5)
			end
		until prompt or os.clock() >= deadline
		local part = prompt
			and (if prompt.Parent and prompt.Parent:IsA("BasePart")
				then prompt.Parent
				else prompt:FindFirstAncestorWhichIsA("BasePart"))
		if not part then
			return -- no stall in this place; step 2 still works via the window
		end
		stallPart = part
		local bb = Instance.new("BillboardGui")
		bb.Name = "TutorialStallMarker"
		bb.Adornee = part
		bb.Size = UDim2.fromOffset(260, 56)
		bb.StudsOffsetWorldSpace = Vector3.new(0, 7, 0)
		bb.AlwaysOnTop = true
		bb.MaxDistance = 250
		bb.Enabled = false
		local label = hint:Clone() -- same face/stroke as the screen hint
		label.Name = "Text"
		label.AutomaticSize = Enum.AutomaticSize.None
		label.Size = UDim2.fromScale(1, 1)
		label.Position = UDim2.fromOffset(0, 0)
		label.AnchorPoint = Vector2.new(0, 0)
		label.TextScaled = true
		label.Visible = true
		label.Parent = bb
		bb.Parent = tutGui
		stallMarker = bb
		stallLabel = label
	end)

	-- Guide arrows for the same walk-there leg: the user's red Arrow union in
	-- ReplicatedStorage (a flat plate — tip along local -X, thin along local
	-- Z, probed 2026-07-13), cloned CLIENT-side into a marching trail laid
	-- flat on the floor between the player and the destination. NOSE-TO-TAIL
	-- (user request): the pitch equals the arrow's own length, so each arrow
	-- starts where the one before it ends — one solid unbroken stream that
	-- flows ARROW_MARCH studs/sec toward the target for as long as the leg
	-- is up. Every spot raycasts down to sit on the real floor; a hole in
	-- the ground just hides that arrow.
	local arrowTemplate = ReplicatedStorage:FindFirstChild("Arrow")
	local ARROW_PITCH = if arrowTemplate then arrowTemplate.Size.X else 7.5
	local ARROW_MAX = 12
	local ARROW_MARCH = 8 -- studs/second the trail flows toward the target
	local arrowFolder: Folder? = nil
	local arrows: { BasePart } = {}
	local arrowParams = RaycastParams.new()
	arrowParams.FilterType = Enum.RaycastFilterType.Exclude
	local function setArrowTarget(part: BasePart?)
		if not arrowTemplate then
			return -- template removed; the billboard still marks the spot
		end
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not (part and root) then
			if arrowFolder then
				arrowFolder:Destroy()
				arrowFolder = nil
				arrows = {}
			end
			return
		end
		if not arrowFolder then
			arrowFolder = Instance.new("Folder")
			arrowFolder.Name = "TutorialArrows"
			arrowFolder.Parent = workspace
			for i = 1, ARROW_MAX do
				local a = arrowTemplate:Clone()
				a.Anchored = true
				a.CanCollide = false
				a.CanQuery = false
				a.CanTouch = false
				a.CastShadow = false
				a.Parent = arrowFolder
				arrows[i] = a
			end
		end
		arrowParams.FilterDescendantsInstances = { character, arrowFolder }
		local from = root.Position
		local flat = (part.Position - from) * Vector3.new(1, 0, 1)
		local dist = flat.Magnitude
		local dir = if dist > 0.01 then flat.Unit else Vector3.zAxis
		local phase = (os.clock() * ARROW_MARCH) % ARROW_PITCH
		for i, arrow in arrows do
			local along = 4 + phase + (i - 1) * ARROW_PITCH
			local shown = false
			if along < dist - 6 then -- stop short of the stall (billboard takes over)
				local p = from + dir * along
				local hit = workspace:Raycast(p + Vector3.new(0, 8, 0), Vector3.new(0, -40, 0), arrowParams)
				if hit then
					-- hug whatever it landed on (lobby hill included): the hit
					-- normal is the plate's up, the travel direction projected
					-- onto that surface aims the tip (local -X) at the target
					local up = hit.Normal
					local slopeDir = dir - up * dir:Dot(up)
					if slopeDir.Magnitude > 0.05 then
						local vx = -slopeDir.Unit
						local vy = up:Cross(vx)
						arrow.CFrame = CFrame.fromMatrix(
							hit.Position + up * (arrow.Size.Z / 2 + 0.15), vx, vy)
						shown = true
					end
				end
			end
			arrow.Transparency = if shown then 0 else 1
		end
	end

	-- "Bull sent! Exit Cam!" holds off a beat (user request) so the thrower
	-- actually gets to watch their bull's telegraph + charge before the
	-- tutorial starts walking them out of the cam. Resumed sessions keep the
	-- 0 default, so a rejoiner mid-step sees the exit hint immediately.
	local BULL_SENT_DELAY = 5
	local step2At = 0 -- os.clock() when TutorialStep last flipped to 2
	player:GetAttributeChangedSignal("TutorialStep"):Connect(function()
		if (tonumber(player:GetAttribute("TutorialStep")) or 0) == 2 then
			step2At = os.clock()
		end
	end)

	-- Inventory mirrors, decoded once per change instead of every frame.
	local ownedBulls: { [string]: boolean } = {}
	local freeBasicBanked = false
	local function refreshOwned()
		local ok, decoded = pcall(function()
			return HttpService:JSONDecode(player:GetAttribute("Bulls") or "{}")
		end)
		ownedBulls = (ok and type(decoded) == "table") and decoded or {}
	end
	local function refreshFree()
		local ok, bank = pcall(function()
			return HttpService:JSONDecode(player:GetAttribute("FreeBoxRolls") or "{}")
		end)
		freeBasicBanked = ok and type(bank) == "table" and (tonumber(bank.BASIC) or 0) > 0
	end
	player:GetAttributeChangedSignal("Bulls"):Connect(refreshOwned)
	player:GetAttributeChangedSignal("FreeBoxRolls"):Connect(refreshFree)
	refreshOwned()
	refreshFree()

	-- The bull step 3 teaches: owned, not worn, non-STARTER first, rarest on
	-- ties — the freshly rolled bull under every normal flow.
	local function targetBullId(): string?
		local equipped = player:GetAttribute("EquippedBull") or "STARTER"
		local best, bestRank = nil, -1
		for id in ownedBulls do
			if id ~= equipped then
				local rank = 0
				if id ~= "STARTER" then
					local bull = BullCatalog and BullCatalog.Bulls and BullCatalog.Bulls[id]
					rank = 1 + ((bull and RARITY_RANK[bull.rarity]) or 0)
				end
				if rank > bestRank then
					best, bestRank = id, rank
				end
			end
		end
		return best
	end

	-- SideUI ships several layout VARIANTS (Lef1/Left2/Left3, only one
	-- visible), each with its own Button1/Index — and wireBullCamButton sets
	-- Visible on every Button1, hidden variants included. Aligning to the
	-- first name match can therefore pick a button whose CONTAINER is hidden,
	-- parking the hint against a rect that isn't on screen (the user caught
	-- exactly this on the bull cam). So: collect all namesakes once, then
	-- always target the one whose whole ancestor chain actually renders.
	local hudCandidates: { [string]: { GuiButton } } = {}
	local function isRendered(obj: GuiObject): boolean
		if not obj.Visible then
			return false
		end
		local node = obj.Parent
		while node and not node:IsA("LayerCollector") do
			if node:IsA("GuiObject") and not node.Visible then
				return false
			end
			node = node.Parent
		end
		return node ~= nil -- reached the ScreenGui: it's really on screen
	end
	local function hudButton(name: string): GuiButton?
		local list = hudCandidates[name]
		if list == nil then
			list = {}
			for _, d in ipairs(SideUI:GetDescendants()) do
				if d:IsA("GuiButton") and d.Name == name then
					table.insert(list, d)
				end
			end
			hudCandidates[name] = list
		end
		for _, btn in list do
			if isRendered(btn) then
				return btn
			end
		end
		return nil
	end

	-- Created synchronously by earlier sections, so plain lookups are safe here.
	local revengePanel = gui:FindFirstChild("RevengeControls") -- §9
	local sendBtn = revengePanel and revengePanel:FindFirstChild("Send")
	local rollFrame = Frames:FindFirstChild("BullRoll") -- §11 carousel
	local shop1Frame = Frames:FindFirstChild("Shop1")
	local indexFrame = Frames:FindFirstChild("Index")

	-- What deserves the glow right now: kind "ui" (GuiObject target + text,
	-- plus an optional forced hint side), "stall" (world marker), or nil
	-- (all chrome hidden).
	local function resolve(): (string?, GuiObject?, string?, string?)
		local step = tonumber(player:GetAttribute("TutorialStep")) or 0
		if step < 1 or step > 3 then
			return nil
		end
		if player:GetAttribute("InRound") == true then
			return nil -- playing: the tutorial never blocks (or nags during) a round
		end
		if rollFrame and rollFrame.Visible then
			return nil -- never talk over a spinning reveal
		end

		if step == 1 then
			if bridge and bridge:GetAttribute("Viewing") == true then
				if sendBtn and sendBtn:IsA("GuiObject") and revengePanel.Visible then
					return "ui", sendBtn, "Pick a lane. Hit SEND!"
				end
				return nil
			end
			-- Wait out the death ragdoll (user request): the glow lands once
			-- they're back on their feet in the lobby, not over their corpse.
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if not (humanoid and humanoid.Health > 0) then
				return nil
			end
			local btn = hudButton("Button1")
			if btn and btn.Visible and bridge and bridge:GetAttribute("Eligible") == true then
				return "ui", btn, "Send a bull!"
			end
			return nil -- no ACTIVE round to spectate right now: wait quietly
		elseif step == 2 then
			if bridge and bridge:GetAttribute("Viewing") == true then
				if os.clock() - step2At < BULL_SENT_DELAY then
					return nil -- let them watch their bull run first
				end
				-- Still parked in the overhead cam after the throw: the stall
				-- arrows/billboard are lobby-side and invisible from up here,
				-- so the handoff to the shop phase starts with walking them
				-- out (Button1 reads "Exit Cam" while viewing).
				local btn = hudButton("Button1")
				if btn and btn.Visible then
					return "ui", btn, "Bull sent! Exit Cam!"
				end
				return nil
			end
			if shop1Frame and shop1Frame.Visible then
				local container = shop1Frame:FindFirstChild("Container")
				local card = container and container:FindFirstChild("BASIC")
				local buttons = card and card:FindFirstChild("BuyButtons")
				local buy = buttons and buttons:FindFirstChild("Buy/Equip/Equipped/Locked")
				if buy and buy:IsA("GuiButton") then
					-- pinned to the button's RIGHT (user request): the default
					-- half-screen rule would tuck it left, over the card art
					return "ui", buy,
						if freeBasicBanked then "Grab your first FREE box!" else "Open a lucky box!",
						"right"
				end
				return nil -- cards still building
			end
			if currentFrame == nil then
				return "stall" -- walk them to the stall
			end
			return nil -- some other window is up; don't point behind it
		else -- step 3
			if bridge and bridge:GetAttribute("Viewing") == true then
				-- same overhead dead-end guard as step 2 (they wandered back
				-- into the cam mid-tutorial): point at the exit first
				local btn = hudButton("Button1")
				if btn and btn.Visible then
					return "ui", btn, "Exit Cam! Equip your bull!"
				end
				return nil
			end
			local bullId = targetBullId()
			if indexFrame and indexFrame.Visible then
				local container = indexFrame:FindFirstChild("Container")
				local card = bullId and container and container:FindFirstChild(bullId)
				if card then
					local inner = card:FindFirstChild("Frame")
					return "ui", (inner or card) :: GuiObject, "Tap your new bull!"
				end
				local bull = bullId and BullCatalog and BullCatalog.Bulls and BullCatalog.Bulls[bullId]
				local tabName = bull and RARITY_TAB[bull.rarity]
				local typeButtons = tabName and indexFrame:FindFirstChild("TypeButtons")
				local tab = typeButtons and typeButtons:FindFirstChild(tabName)
				if tab and tab:IsA("GuiButton") then
					return "ui", tab, "Check this tab!"
				end
				return nil
			end
			if currentFrame == nil then
				local btn = hudButton("Index")
				if btn and btn.Visible then
					return "ui", btn, "Equip your new bull!"
				end
			end
			return nil
		end
	end

	-- Manual RenderStepped math like every looped animation here (Run-mode
	-- tween freeze): the stroke breathes, the hint bobs beside its target.
	RunService.RenderStepped:Connect(function()
		local kind, target, text, side = resolve()

		if stallMarker then
			stallMarker.Enabled = kind == "stall"
			if kind == "stall" and stallLabel then
				stallLabel.Text = "Grab your FREE box!"
				stallLabel.TextTransparency = 0.15 - 0.15 * math.sin(os.clock() * 4)
			end
		end
		setArrowTarget(if kind == "stall" then stallPart else nil)

		if kind ~= "ui" or not target then
			parkGlow(nil)
			hint.Visible = false
			return
		end

		parkGlow(target)
		local wave = 0.5 + 0.5 * math.sin(os.clock() * 5)
		glow.Thickness = 3 + 2 * wave
		glow.Transparency = 0.3 - 0.3 * wave

		hint.Text = text or ""
		hint.Visible = true
		local screen = tutGui.AbsoluteSize
		local rel = target.AbsolutePosition - tutGui.AbsolutePosition
		local size = target.AbsoluteSize
		local cx = rel.X + size.X / 2
		local cy = rel.Y + size.Y / 2
		local bob = 4 * math.sin(os.clock() * 3)
		if side ~= "right" and cy > screen.Y * 0.78 then
			-- bottom strip (the SEND BULL panel): sit above the target
			hint.AnchorPoint = Vector2.new(0.5, 1)
			hint.Position = UDim2.fromOffset(cx, rel.Y - 10 + bob)
		elseif side == "right" or cx <= screen.X / 2 then
			hint.AnchorPoint = Vector2.new(0, 0.5)
			hint.Position = UDim2.fromOffset(rel.X + size.X + 14 + bob, cy)
		else
			hint.AnchorPoint = Vector2.new(1, 0.5)
			hint.Position = UDim2.fromOffset(rel.X - 14 - bob, cy)
		end
	end)
end
