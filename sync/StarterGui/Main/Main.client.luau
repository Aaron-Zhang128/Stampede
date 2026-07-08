--[[
	Main UI controller — ALL client UI code lives in this one script (Gui > Main).
	  1. Frame manager  — open/close windows with a pop tween, one open at a time
	  2. HUD hookup     — SideUI buttons open frames; deals/cash "+"/quick buttons deep-link the Store
	  3. Button feel    — hover grow + press squash on every button
	  4. Ambient life   — floating lucky blocks, breathing starbursts, swaying SALE!/header icons, pulsing "!"
	  5. Marquees       — lucky block cards scroll their possible items
	  6. Notifications  — server-pushed red/green/white info cards (Remotes.Notify)
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

local quickButtons = Store:FindFirstChild("QuickButtons")
if quickButtons then
	wire(quickButtons:FindFirstChild("Limiteds"), function()
		scrollStoreTo(nil) -- top of the store
	end)
	wire(quickButtons:FindFirstChild("Limiteds1"), function()
		scrollStoreTo("LuckyBlocks")
	end)
end

-- "Become a Bull" button (former "Slow" toggle): enters/exits the revenge
-- bull-cam. BullrushClient owns the camera + eligibility rules and exposes a
-- client-local bridge (ReplicatedStorage.RevengeViewBridge BindableEvent):
-- Fire() toggles the cam; its "Eligible"/"Viewing" attributes drive the
-- button's visibility and label. The kit's On/Off gradient pair doubles as
-- the state look (On = ready to enter, Off = currently viewing).
local function wireBullCamButton(btn)
	handled[btn] = true
	btn.Visible = false -- only eliminated players of an ACTIVE round see it
	local function apply(viewing)
		local label = btn:FindFirstChild("Name")
		if label and label:IsA("TextLabel") then
			label.Text = viewing and "Exit Cam" or "Become a Bull"
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
	apply(false)
	task.spawn(function()
		local bridge = ReplicatedStorage:WaitForChild("RevengeViewBridge", 30)
		if not (bridge and bridge:IsA("BindableEvent")) then
			return -- BullrushClient absent; the button just stays hidden
		end
		local function refresh()
			btn.Visible = bridge:GetAttribute("Eligible") == true
			apply(bridge:GetAttribute("Viewing") == true)
		end
		bridge:GetAttributeChangedSignal("Eligible"):Connect(refresh)
		bridge:GetAttributeChangedSignal("Viewing"):Connect(refresh)
		refresh()
		btn.Activated:Connect(function()
			bridge:Fire()
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
						inviteOptions.PromptMessage = "Rally your friends for the stampede!"
					end)
					local prompted = pcall(function()
						SocialService:PromptGameInvite(player, inviteOptions)
					end)
					if prompted then
						return
					end
				end
				if pushNotif then
					pushNotif("Friend invites aren't available right now", "red", 3)
				end
			end)
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
-- lucky block cards: duplicate the item row once, then scroll it on a seamless loop
local luckyBlocks = storeContainer:FindFirstChild("LuckyBlocks")
if luckyBlocks then
	local cardIndex = 0
	for _, card in ipairs(luckyBlocks:GetChildren()) do
		local outcomes = card:IsA("Frame") and card:FindFirstChild("Outcomes")
		local strip = outcomes and outcomes:FindFirstChild("Frame - This will be tweened")
		local layout = strip and strip:FindFirstChildOfClass("UIListLayout")
		if layout then
			layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
			outcomes.ClipsDescendants = true
			local items = {}
			for _, c in ipairs(strip:GetChildren()) do
				if c:IsA("GuiObject") then
					table.insert(items, c)
				end
			end
			table.sort(items, function(a, b)
				return (tonumber(a.Name) or 0) < (tonumber(b.Name) or 0)
			end)
			local itemW = 0
			for i, item in ipairs(items) do
				item.LayoutOrder = i
				itemW = item.Size.X.Scale
				local clone = item:Clone()
				clone.Name = "m" .. i
				clone.LayoutOrder = i + #items
				clone.Parent = strip
			end
			if #items > 0 then
				cardIndex += 1
				table.insert(marquees, {
					frame = strip,
					period = #items * (itemW + layout.Padding.Scale),
					-- alternate direction per card so the shop feels alive, not mechanical
					speed = (cardIndex % 2 == 0) and -0.095 or 0.11,
					gate = gateOf(Store),
				})
			end
		end
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
notifStack.Position = UDim2.new(0.5, 0, 0.19, 0)
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

function pushNotif(text, style, duration) -- assigns the forward-declared local
	notifCounter += 1
	local card = notifTemplate:Clone()
	card.Name = "Notif" .. notifCounter
	card.LayoutOrder = -notifCounter -- newest on top
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
		-- Template lost its label (e.g. a test harness cloned a destroyed
		-- copy): drop the card rather than error inside a remote handler.
		card:Destroy()
		return
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

	card.Parent = notifStack

	-- Evict the oldest card once the stack is full (highest LayoutOrder).
	local cards = {}
	for _, c in ipairs(notifStack:GetChildren()) do
		if c:IsA("Frame") then
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
		local stroke = label:FindFirstChildOfClass("UIStroke")
		tween(card, TweenInfo.new(0.35), { BackgroundTransparency = 1 })
		tween(label, TweenInfo.new(0.35), { TextTransparency = 1 })
		if stroke then
			tween(stroke, TweenInfo.new(0.35), { Transparency = 1 })
		end
		task.delay(0.4, function()
			card:Destroy()
		end)
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
	notifyRemote.OnClientEvent:Connect(function(text, style, duration)
		if typeof(text) ~= "string" or text == "" then
			return
		end
		pushNotif(
			text:sub(1, 120),
			(if typeof(style) == "string" then style else "white"),
			tonumber(duration)
		)
	end)
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
	task.spawn(function()
		local leaderstats = player:WaitForChild("leaderstats", 30)
		local money = leaderstats and leaderstats:WaitForChild("Money", 10)
		if not money then
			warn("[Main] leaderstats.Money missing; Cash counter left at $0")
			return
		end
		local function refresh()
			cashLabel.Text = "$" .. comma(money.Value)
		end
		money.Changed:Connect(refresh)
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

local speedLabel = counters and counters:FindFirstChild("Speed")
speedLabel = speedLabel and speedLabel:FindFirstChild("Amount")
if speedLabel then
	speedLabel.Text = "16" -- default WalkSpeed, shown until the humanoid binds
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
-- tab auto-opens with the winner's portrait + name, your own portrait +
-- placement in the corner TinyBox, the Money you earned, and an itemized
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
		if winnerIcon then
			winnerIcon.Image = if data.winnerUserId then portrait(data.winnerUserId) else PLACEHOLDER_PORTRAIT
		end
		if winnerLabel then
			if data.winnerName then
				winnerLabel.Text = data.winnerName .. " WINS!"
				winnerLabel.TextColor3 = TEAM_NAME_COLORS[data.teamColor] or defaultNameColor
			else
				winnerLabel.Text = "THE HERD WON…"
				winnerLabel.TextColor3 = defaultNameColor
			end
		end
		if tinyIcon then
			tinyIcon.Image = portrait(player.UserId)
		end
		if tinyText then
			tinyText.Text = ordinal(tonumber(data.placement) or 1)
		end
		if coinsAmount then
			coinsAmount.Text = "+" .. comma(tonumber(data.total) or 0)
		end
		rebuildEarnings(data.lines or {})
		canDouble = data.canDouble == true
		if doubleButton then
			doubleButton.Visible = canDouble
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
				pushNotif("Purchases aren't available right now", "red", 3)
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

		-- The payload lands while the winner banner is still up and the player
		-- is standing in the arena; hold it until the post-round state change
		-- (WAITING/INTERMISSION fires right after the lobby teleport) so the
		-- recap only ever opens back in the lobby.
		local pendingSummary: { [string]: any }? = nil

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
-- RevengeViewBridge "Viewing" attribute): ◀ ▶ mirror the Left/Right arrow
-- keys and walk the lane ring, the label reads the current pick ("ROW 3 →"),
-- and SEND BULL fires the throw — or counts down the server cooldown
-- ("ReadyIn" attribute). BullrushClient owns selection state, the lane tile
-- highlight, and the RevengeThrow remote; this section is pure chrome, per
-- the all-UI-in-this-script rule. Commands ride the same bridge the
-- "Become a Bull" button uses: Fire("left" | "right" | "send").
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
	-- gradient pair (On = green, Off = grey), which doubles as the SEND BULL
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

	-- On = green gradient, Off = grey — the kit's own state pair.
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
			selLabel.Text = tostring(bridge:GetAttribute("SelectionText") or "")
			applySendState(tonumber(bridge:GetAttribute("ReadyIn")) or 0)
		end
		for _, attr in ipairs({ "Viewing", "SelectionText", "ReadyIn" }) do
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

		local function refreshTimer()
			if not (timerLabel and timerLabel:IsA("TextLabel")) then
				return
			end
			local nextAt = tonumber(player:GetAttribute("NextFreeSpin"))
			if not nextAt then
				timerLabel.Text = ""
				return
			end
			local remaining = math.floor(nextAt - workspace:GetServerTimeNow())
			if remaining <= 0 then
				timerLabel.Text = "Free spin ready…"
			elseif remaining >= 3600 then
				timerLabel.Text = ("Free spin in %dh %dm"):format(remaining // 3600, (remaining % 3600) // 60)
			elseif remaining >= 60 then
				timerLabel.Text = ("Free spin in %dm %ds"):format(remaining // 60, remaining % 60)
			else
				timerLabel.Text = ("Free spin in %ds"):format(remaining)
			end
		end

		player:GetAttributeChangedSignal("Spins"):Connect(refreshSpinCount)
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
					pushNotif(("You won %s — a new bull!"):format(tostring(reward.label)), "green", 5)
				else
					pushNotif(("Duplicate %s — +%s Money"):format(
						tostring(reward.label), comma(tonumber(data.consolation) or 0)), "green", 5)
				end
			elseif reward.kind == "spin" then
				pushNotif("Free spin! Spin again", "green", 4)
			elseif reward.label == "JACKPOT" then
				pushNotif(("JACKPOT! +%s Money!"):format(comma(tonumber(reward.amount) or 0)), "green", 6)
			else
				pushNotif(("You won +%s Money!"):format(comma(tonumber(reward.amount) or 0)), "green", 4)
			end
			playSfx("winner!", 0.6)
			if reward.kind == "money" or (reward.kind == "bull" and not data.isNew) then
				playSfx("Cash", 0.6)
			end
		end

		-- classic decelerate: cubic ease-out over the server's duration,
		-- ticking every slice edge (30 deg off the slice centers) that
		-- crosses the arrow. Slice i is authored at (i-1)*60 inside the
		-- dial, so it rests under the top arrow at Rotation = -(i-1)*60.
		local function animateSpin(data)
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
				pushNotif("No spins left — buy more or wait for your free one", "red", 3)
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
					pushNotif("Purchases aren't available right now", "red", 3)
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
				-- slice labels + odds come from the shared reward table
				if typeof(bullrushConfig.SPINNER) == "table" then
					for i, reward in ipairs(bullrushConfig.SPINNER.REWARDS) do
						local slice = spinDial:FindFirstChild(tostring(i))
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
						pushNotif("Your data hasn't loaded — try again soon", "red", 3)
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
			local wheelModel = workspace:WaitForChild("FortuneWheel", 60)
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
-- Gacha reveal for the bull roll system (ReplicatedStorage.Bullrush.BullCatalog
-- + ServerScriptService.Bullrush.BullRollService). The WHOLE panel is built here
-- in code (no kit instance) so it drops cleanly into a shop frame later — to wire
-- it up, just call openFrame(rollFrame) from a button (or reparent rollFrame).
--
-- The server rolls the result and answers the caller: BullRoll:FireServer() ->
-- BullAck "ROLLED" { results = {{bullId,rarity,isNew,refund}}, money, source }.
-- This section is pure presentation: a horizontal strip of rarity-tinted
-- placeholder cards (swap the "🐂" TextLabel for a ViewportFrame/thumbnail once
-- the models land) scrolls fast, cubic-eases to a stop with the won bull under
-- the center marker, ticks per card, drumroll on the final crawl. A 10x roll runs
-- ONE carousel (landing on the rarest of the ten) then pops a 5x2 results grid.
-- All motion is manual RenderStepped math, never a TweenService loop (Run-mode
-- tween freeze — see the marquee/ambient sections).
do
	local UserInputService = game:GetService("UserInputService")

	-- resolved async (remotes + Config + Catalog) at the bottom of this block
	local BullCatalog = nil
	local ackRemote = nil
	local rollRemote = nil        -- nil until acks wired = button stays inert
	local ROLL_COST = 200
	local productIds = { BULL_ROLL = 0, BULL_ROLL_10 = 0 }

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

	-------------------------------------------------- panel
	local rollFrame = Instance.new("Frame")
	rollFrame.Name = "BullRoll"
	rollFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	rollFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
	rollFrame.Size = UDim2.new(0.62, 0, 0.56, 0)
	rollFrame.BackgroundColor3 = Color3.fromRGB(30, 24, 20)
	rollFrame.BorderSizePixel = 0
	rollFrame.Visible = false
	do
		local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 14); c.Parent = rollFrame
		local s = Instance.new("UIStroke"); s.Color = Color3.fromRGB(120, 90, 50); s.Thickness = 3; s.Parent = rollFrame
		local ar = Instance.new("UIAspectRatioConstraint"); ar.AspectRatio = 1.55; ar.Parent = rollFrame
	end

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.AnchorPoint = Vector2.new(0.5, 0)
	title.Position = UDim2.new(0.5, 0, 0.04, 0)
	title.Size = UDim2.new(0.8, 0, 0.12, 0)
	title.Text = "BULL ROLL"
	title.Font = Enum.Font.GothamBlack
	title.TextScaled = true
	title.TextColor3 = Color3.fromRGB(255, 210, 130)
	title.Parent = rollFrame

	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "Close"
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.Position = UDim2.new(0.98, 0, 0.04, 0)
	closeBtn.Size = UDim2.new(0.09, 0, 0.12, 0)
	closeBtn.BackgroundColor3 = Color3.fromRGB(120, 45, 40)
	closeBtn.Text = "✕"
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.TextScaled = true
	closeBtn.TextColor3 = Color3.fromRGB(255, 235, 225)
	closeBtn.Active = true
	do
		local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 8); c.Parent = closeBtn
		local ar = Instance.new("UIAspectRatioConstraint"); ar.AspectRatio = 1; ar.Parent = closeBtn
	end
	closeBtn.Parent = rollFrame
	closeBtn.Activated:Connect(function()
		closeFrame(rollFrame)
	end)

	local carousel = Instance.new("Frame")
	carousel.Name = "Carousel"
	carousel.AnchorPoint = Vector2.new(0.5, 0.5)
	carousel.Position = UDim2.new(0.5, 0, 0.48, 0)
	carousel.Size = UDim2.new(0.92, 0, 0, CARD_H + 24)
	carousel.BackgroundColor3 = Color3.fromRGB(18, 14, 11)
	carousel.BorderSizePixel = 0
	carousel.ClipsDescendants = true
	do
		local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 10); c.Parent = carousel
		local s = Instance.new("UIStroke"); s.Color = Color3.fromRGB(80, 62, 40); s.Thickness = 2; s.Parent = carousel
	end
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
	marker.Size = UDim2.new(0, 4, 1, -8)
	marker.BackgroundColor3 = Color3.fromRGB(255, 220, 120)
	marker.BorderSizePixel = 0
	marker.ZIndex = 5
	do
		local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(1, 0); c.Parent = marker
		local s = Instance.new("UIStroke"); s.Color = Color3.fromRGB(255, 170, 60); s.Thickness = 2; s.Transparency = 0.3; s.Parent = marker
	end
	marker.Parent = carousel

	local pointer = Instance.new("TextLabel")
	pointer.Name = "Pointer"
	pointer.BackgroundTransparency = 1
	pointer.AnchorPoint = Vector2.new(0.5, 0)
	pointer.Position = UDim2.new(0.5, 0, 0, -1)
	pointer.Size = UDim2.new(0, 24, 0, 24)
	pointer.Text = "▼"
	pointer.Font = Enum.Font.GothamBold
	pointer.TextScaled = true
	pointer.TextColor3 = Color3.fromRGB(255, 220, 120)
	pointer.ZIndex = 6
	pointer.Parent = carousel

	local rollButton = Instance.new("TextButton")
	rollButton.Name = "RollX1"
	rollButton.AnchorPoint = Vector2.new(0.5, 1)
	rollButton.Position = UDim2.new(0.29, 0, 0.96, 0)
	rollButton.Size = UDim2.new(0.4, 0, 0.16, 0)
	rollButton.BackgroundColor3 = Color3.fromRGB(60, 150, 70)
	rollButton.Text = "ROLL"
	rollButton.Font = Enum.Font.GothamBold
	rollButton.TextScaled = true
	rollButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	do
		local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 10); c.Parent = rollButton
		local s = Instance.new("UIStroke"); s.Color = Color3.fromRGB(30, 80, 35); s.Thickness = 2; s.Parent = rollButton
		local pad = Instance.new("UIPadding"); pad.PaddingTop = UDim.new(0.16, 0); pad.PaddingBottom = UDim.new(0.16, 0); pad.Parent = rollButton
	end
	rollButton.Parent = rollFrame

	local tenButton = Instance.new("TextButton")
	tenButton.Name = "RollX10"
	tenButton.AnchorPoint = Vector2.new(0.5, 1)
	tenButton.Position = UDim2.new(0.71, 0, 0.96, 0)
	tenButton.Size = UDim2.new(0.4, 0, 0.16, 0)
	tenButton.BackgroundColor3 = Color3.fromRGB(190, 150, 55)
	tenButton.Text = "ROLL x10 (Robux)"
	tenButton.Font = Enum.Font.GothamBold
	tenButton.TextScaled = true
	tenButton.TextColor3 = Color3.fromRGB(40, 30, 10)
	do
		local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 10); c.Parent = tenButton
		local s = Instance.new("UIStroke"); s.Color = Color3.fromRGB(120, 90, 30); s.Thickness = 2; s.Parent = tenButton
		local pad = Instance.new("UIPadding"); pad.PaddingTop = UDim.new(0.16, 0); pad.PaddingBottom = UDim.new(0.16, 0); pad.Parent = tenButton
	end
	tenButton.Parent = rollFrame

	-- results grid overlay (10x rolls); the backdrop button doubles as tap-to-dismiss
	local resultsPanel = Instance.new("TextButton")
	resultsPanel.Name = "Results"
	resultsPanel.AutoButtonColor = false
	resultsPanel.Text = ""
	resultsPanel.AnchorPoint = Vector2.new(0.5, 0.5)
	resultsPanel.Position = UDim2.new(0.5, 0, 0.5, 0)
	resultsPanel.Size = UDim2.new(1, 0, 1, 0)
	resultsPanel.BackgroundColor3 = Color3.fromRGB(12, 9, 7)
	resultsPanel.BackgroundTransparency = 0.06
	resultsPanel.BorderSizePixel = 0
	resultsPanel.Visible = false
	resultsPanel.ZIndex = 20
	do
		local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 14); c.Parent = resultsPanel
	end
	resultsPanel.Parent = rollFrame

	local gridTitle = Instance.new("TextLabel")
	gridTitle.BackgroundTransparency = 1
	gridTitle.AnchorPoint = Vector2.new(0.5, 0)
	gridTitle.Position = UDim2.new(0.5, 0, 0.05, 0)
	gridTitle.Size = UDim2.new(0.8, 0, 0.1, 0)
	gridTitle.Text = "YOUR 10 ROLLS"
	gridTitle.Font = Enum.Font.GothamBlack
	gridTitle.TextScaled = true
	gridTitle.TextColor3 = Color3.fromRGB(255, 210, 130)
	gridTitle.ZIndex = 21
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

	local gridHint = Instance.new("TextLabel")
	gridHint.BackgroundTransparency = 1
	gridHint.AnchorPoint = Vector2.new(0.5, 1)
	gridHint.Position = UDim2.new(0.5, 0, 0.97, 0)
	gridHint.Size = UDim2.new(0.6, 0, 0.07, 0)
	gridHint.Text = "tap to continue"
	gridHint.Font = Enum.Font.GothamMedium
	gridHint.TextScaled = true
	gridHint.TextColor3 = Color3.fromRGB(200, 190, 175)
	gridHint.ZIndex = 21
	gridHint.Parent = resultsPanel

	resultsPanel.Activated:Connect(function()
		resultsPanel.Visible = false
	end)

	rollFrame.Parent = Frames

	-------------------------------------------------- card builder
	-- placeholder card: swap the "🐂" icon TextLabel for a ViewportFrame/thumbnail
	-- once real models exist. opts = { badge, badgeColor, zIndex }
	local function makeCard(bullId, size, opts)
		opts = opts or {}
		local z = opts.zIndex or 1
		local bull = BullCatalog and BullCatalog.get(bullId) or nil
		local rarity = (bull and bull.rarity) or "COMMON"
		local col = rarityColor(rarity)

		local card = Instance.new("Frame")
		card.Size = size
		card.BackgroundColor3 = col:Lerp(Color3.new(0, 0, 0), 0.72)
		card.BorderSizePixel = 0
		card.ZIndex = z
		local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 8); corner.Parent = card
		local stroke = Instance.new("UIStroke"); stroke.Color = col; stroke.Thickness = 2; stroke.Parent = card
		local grad = Instance.new("UIGradient")
		grad.Color = ColorSequence.new(col:Lerp(Color3.new(0, 0, 0), 0.5), col:Lerp(Color3.new(0, 0, 0), 0.82))
		grad.Rotation = 90
		grad.Parent = card

		local icon = Instance.new("TextLabel")
		icon.BackgroundTransparency = 1
		icon.Size = UDim2.new(1, 0, 0.52, 0)
		icon.Position = UDim2.new(0, 0, 0.06, 0)
		icon.Text = "🐂"
		icon.TextScaled = true
		icon.Font = Enum.Font.GothamBold
		icon.TextColor3 = col:Lerp(Color3.new(1, 1, 1), 0.15)
		icon.ZIndex = z
		icon.Parent = card

		local nameLabel = Instance.new("TextLabel")
		nameLabel.BackgroundTransparency = 1
		nameLabel.Size = UDim2.new(1, -8, 0.16, 0)
		nameLabel.Position = UDim2.new(0, 4, 0.62, 0)
		nameLabel.Text = (bull and bull.name) or "???"
		nameLabel.Font = Enum.Font.GothamBold
		nameLabel.TextScaled = true
		nameLabel.TextColor3 = Color3.fromRGB(245, 240, 230)
		nameLabel.ZIndex = z
		nameLabel.Parent = card

		local rarLabel = Instance.new("TextLabel")
		rarLabel.BackgroundTransparency = 1
		rarLabel.Size = UDim2.new(1, -8, 0.1, 0)
		rarLabel.Position = UDim2.new(0, 4, 0.8, 0)
		rarLabel.Text = rarity
		rarLabel.Font = Enum.Font.GothamBold
		rarLabel.TextScaled = true
		rarLabel.TextColor3 = col
		rarLabel.ZIndex = z
		rarLabel.Parent = card

		if opts.badge then
			local badge = Instance.new("TextLabel")
			badge.AnchorPoint = Vector2.new(0.5, 0.5)
			badge.Position = UDim2.new(0.5, 0, 0.94, 0)
			badge.Size = UDim2.new(0.7, 0, 0.13, 0)
			badge.BackgroundColor3 = opts.badgeColor or Color3.fromRGB(70, 180, 80)
			badge.Text = opts.badge
			badge.Font = Enum.Font.GothamBold
			badge.TextScaled = true
			badge.TextColor3 = Color3.fromRGB(255, 255, 255)
			badge.ZIndex = z + 1
			local bc = Instance.new("UICorner"); bc.CornerRadius = UDim.new(1, 0); bc.Parent = badge
			badge.Parent = card
		end
		return card
	end

	-------------------------------------------------- strip + animation
	local function buildStrip(headlineBullId)
		for _, c in ipairs(strip:GetChildren()) do
			if c:IsA("Frame") then
				c:Destroy()
			end
		end
		for i = 1, STRIP_LEN do
			local id = (i == WINNER_INDEX) and headlineBullId or randomFiller()
			local card = makeCard(id, UDim2.fromOffset(CARD_W, CARD_H))
			card.LayoutOrder = i
			card.Parent = strip
		end
	end

	local function announce(results, headline)
		local h = BullCatalog and BullCatalog.get(headline.bullId) or nil
		local hname = (h and h.name) or headline.bullId
		if #results <= 1 then
			local r = results[1] or headline
			if r.isNew then
				pushNotif(("You rolled %s — a new bull!"):format(hname), "green", 5)
			else
				pushNotif(("Duplicate %s — +%s Money"):format(hname, comma(r.refund or 0)), "green", 4)
			end
		else
			local newCount = 0
			for _, r in ipairs(results) do
				if r.isNew then
					newCount += 1
				end
			end
			pushNotif(("10x roll: %d new — headline %s!"):format(newCount, hname), "green", 5)
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
			local mini = makeCard(r.bullId, UDim2.fromScale(1, 1), { badge = badge, badgeColor = badgeColor, zIndex = 21 })
			mini.LayoutOrder = i
			mini.Parent = gridHolder
		end
		resultsPanel.Visible = true
	end

	local function setRolling(state)
		rolling = state
		rollButton.AutoButtonColor = not state
		rollButton.Text = state and "ROLLING…" or (("ROLL ($%s)"):format(comma(ROLL_COST)))
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
		buildStrip(headline.bullId)
		RunService.Heartbeat:Wait() -- let the list layout resolve before measuring

		local vpCenter = carousel.AbsoluteSize.X / 2
		local function centerOf(i)
			return (i - 1) * STEP + CARD_W / 2
		end
		local startOffset = vpCenter - centerOf(3)
		local jitter = (math.random() * 2 - 1) * (CARD_W * 0.18)
		local targetOffset = vpCenter - centerOf(WINNER_INDEX) + jitter
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
				strip.Position = UDim2.new(0, targetOffset, 0.5, 0)
				activeConn:Disconnect()
				activeConn = nil
				if drum then
					pcall(function()
						drum:Stop()
						drum:Destroy()
					end)
				end
				-- small flourish: paint the marker the won rarity
				local col = rarityColor(headline.rarity)
				marker.BackgroundColor3 = col
				pointer.TextColor3 = col
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
	rollButton.Activated:Connect(function()
		if rolling or not rollRemote then
			return
		end
		setRolling(true)
		rollRemote:FireServer()
	end)

	tenButton.Activated:Connect(function()
		local pid = tonumber(productIds.BULL_ROLL_10) or 0
		if pid <= 0 then
			pushNotif("10x rolls are coming soon!", "red", 3)
			return
		end
		local ok = pcall(function()
			MarketplaceService:PromptProductPurchase(player, pid)
		end)
		if not ok then
			pushNotif("Purchases aren't available right now", "red", 3)
		end
	end)

	-- TEMP test opener: press B to toggle the panel. Delete this once a shop
	-- button calls openFrame(rollFrame) instead.
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.B then
			openFrame(rollFrame)
		end
	end)

	-- TEMP on-screen test buttons (left edge): fire a FAKE local reveal so the
	-- carousel can be watched without working data (a real roll denies
	-- DATA_NOT_LOADED in the unpublished place). Uses BullCatalog.roll for
	-- realistic rarity variety. Delete this whole block for production.
	local function debugFakeReveal(count)
		if rolling then
			return
		end
		local rng = Random.new()
		local results = {}
		for _ = 1, count do
			local id = BullCatalog and BullCatalog.roll(rng) or "PLOW"
			local bull = BullCatalog and BullCatalog.get(id) or nil
			local rarity = (bull and bull.rarity) or "COMMON"
			local isNew = rng:NextNumber() < 0.55
			local refund = 0
			if not isNew and BullCatalog then
				refund = math.floor(ROLL_COST * (BullCatalog.Rarities[rarity].dupeRefund or 0.25))
			end
			table.insert(results, { bullId = id, rarity = rarity, isNew = isNew, refund = refund })
		end
		if not rollFrame.Visible then
			openFrame(rollFrame)
		end
		setRolling(true)
		animateReveal(results)
	end

	local testHolder = Instance.new("Frame")
	testHolder.Name = "BullRollTEST"
	testHolder.AnchorPoint = Vector2.new(0, 0.5)
	testHolder.Position = UDim2.new(0.012, 0, 0.5, 0)
	testHolder.Size = UDim2.new(0.1, 0, 0.14, 0)
	testHolder.BackgroundTransparency = 1
	testHolder.ZIndex = 50
	do
		local l = Instance.new("UIListLayout")
		l.FillDirection = Enum.FillDirection.Vertical
		l.Padding = UDim.new(0, 6)
		l.HorizontalAlignment = Enum.HorizontalAlignment.Center
		l.VerticalAlignment = Enum.VerticalAlignment.Center
		l.Parent = testHolder
	end
	local function makeTestBtn(text, order, count)
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(1, 0, 0.45, 0)
		b.BackgroundColor3 = Color3.fromRGB(150, 60, 160)
		b.Text = text
		b.Font = Enum.Font.GothamBold
		b.TextScaled = true
		b.TextColor3 = Color3.fromRGB(255, 255, 255)
		b.LayoutOrder = order
		b.ZIndex = 50
		local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 8); c.Parent = b
		local s = Instance.new("UIStroke"); s.Color = Color3.fromRGB(90, 30, 100); s.Thickness = 2; s.Parent = b
		b.Parent = testHolder
		b.Activated:Connect(function()
			debugFakeReveal(count)
		end)
		return b
	end
	makeTestBtn("🐂 TEST ROLL", 1, 1)
	makeTestBtn("TEST x10", 2, 10)
	testHolder.Parent = gui

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

		local okConfig, config = pcall(require, bullrush:WaitForChild("Config"))
		if okConfig and typeof(config) == "table" then
			if typeof(config.BULLS) == "table" then
				ROLL_COST = tonumber(config.BULLS.ROLL_COST) or ROLL_COST
			end
			if typeof(config.PRODUCTS) == "table" then
				productIds.BULL_ROLL = tonumber(config.PRODUCTS.BULL_ROLL) or 0
				productIds.BULL_ROLL_10 = tonumber(config.PRODUCTS.BULL_ROLL_10) or 0
			end
		end
		setRolling(false) -- paints the button label now that ROLL_COST is known

		ackRemote.OnClientEvent:Connect(function(kind, data)
			data = typeof(data) == "table" and data or {}
			if kind == "ROLLED" then
				setRolling(true)
				animateReveal(data.results)
			elseif kind == "DENIED" then
				setRolling(false)
				if data.reason == "NO_MONEY" then
					pushNotif(("Not enough Money — a roll costs $%s"):format(comma(ROLL_COST)), "red", 3)
				elseif data.reason == "DATA_NOT_LOADED" then
					pushNotif("Your data hasn't loaded — try again soon", "red", 3)
				elseif data.reason == "NOT_OWNED" or data.reason == "BAD_ID" then
					pushNotif("That bull can't be equipped", "red", 3)
				end
			end
			-- "EQUIPPED" acks are ignored: this shell has no inventory/equip UI yet
		end)

		rollRemote = requestRemote -- arm the button only once acks are wired
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
-- + EquippedBull player attributes (Data.server on join, BullRollService after
-- rolls), so the window stays current even while closed — no fetch remote.
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
							if tier and tier.color then
								rarityLabel.TextColor3 = tier.color
							end
						end
						buildPreview(inner, bull, has)
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
						-- the kit's gold/diamond/rainbow letter ramps fight the tier colors
						for _, g in ipairs(label:GetChildren()) do
							if g:IsA("UIGradient") then
								g:Destroy()
							end
						end
						local tier = BullCatalog.Rarities[rarity]
						if tier and tier.color then
							label.TextColor3 = tier.color
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

			-- Quests strip -> collection meter + a one-line equip hint
			local progress = quests and quests:FindFirstChild("Progress")
			local progressBar = progress and progress:FindFirstChild("Bar")
			local progressAmount = progress and progress:FindFirstChild("Amount")
			local questDes = quests and quests:FindFirstChild("QuestDes")
			if questDes then
				local amount = questDes:FindFirstChild("Amount")   -- leading words
				local kind = questDes:FindFirstChild("Type")       -- the gradient-highlighted word
				local rest = questDes:FindFirstChild("TextLabel")  -- trailing words
				if amount and amount:IsA("TextLabel") then
					amount.Text = "Equip your"
				end
				if kind and kind:IsA("TextLabel") then
					kind.Text = "fastest"
				end
				if rest and rest:IsA("TextLabel") then
					rest.Text = "bull — it charges when you take revenge!"
				end
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
