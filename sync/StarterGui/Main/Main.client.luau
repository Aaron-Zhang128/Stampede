--[[
	Main UI controller — ALL client UI code lives in this one script (Gui > Main).
	  1. Frame manager  — open/close windows with a pop tween, one open at a time
	  2. HUD hookup     — SideUI buttons open frames; deals/cash "+"/quick buttons deep-link the Store
	  3. Button feel    — hover grow + press squash on every button
	  4. Ambient life   — floating lucky blocks, breathing starbursts, swaying SALE!/header icons, pulsing "!"
	  5. Marquees       — lucky block cards scroll their possible items
	  6. Notifications  — server-pushed red/green/white info cards (Remotes.Notify)
	  7. HUD counters   — Cash mirrors leaderstats.Money, Speed mirrors Humanoid.WalkSpeed
	  8. Round summary  — Frames.Summary auto-opens at round end with the winner's
	                      portrait, your placement, and your itemized Money payout
	                      (Remotes.RoundSummary); "2x Rewards?" prompts a dev product
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
	playUiSound(0.8, 1)
end
local function playHover()
	playUiSound(0.45, 1.5)
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

local notifStack = Instance.new("Frame")
notifStack.Name = "NotifStack"
notifStack.AnchorPoint = Vector2.new(0.5, 0)
notifStack.Position = UDim2.new(0.5, 0, 0.19, 0)
notifStack.Size = UDim2.new(0.4, 0, 0.3, 0)
notifStack.BackgroundTransparency = 1
notifStack.Parent = gui

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
-- in GridUtil's header). The tab auto-opens with the winner's portrait + name,
-- your own portrait + placement in the corner TinyBox, the Money you earned,
-- and an itemized breakdown line; it auto-closes when the next round cycle
-- starts. The kit's XP row stays hidden until an XP system exists. The
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

	-- One itemized line under the money row, cloned from the coins caption so
	-- it inherits the kit's font/stroke/gradient. Built BEFORE the rows move:
	-- it takes over the coins row's original slot.
	local breakdown
	if coinsCaption then
		breakdown = coinsCaption:Clone()
		breakdown.Name = "Breakdown"
		local ratio = breakdown:FindFirstChildOfClass("UIAspectRatioConstraint")
		if ratio then
			ratio:Destroy() -- full-width line; the ratio lock would fight the resize
		end
		breakdown.Size = UDim2.new(0.94, 0, coinsCaption.Size.Y.Scale * 0.62, 0)
		breakdown.Position = UDim2.new(0.5, 0, coinsCaption.Position.Y.Scale + 0.015, 0)
		breakdown.AnchorPoint = Vector2.new(0.5, coinsCaption.AnchorPoint.Y)
		breakdown.TextXAlignment = Enum.TextXAlignment.Center
		breakdown.Text = ""
		breakdown.Parent = summaryMain
	end

	-- No XP system yet: hide that row and move the money row up into its slot;
	-- the currency in this game is Money, so say so.
	if xpCaption and xpAmount and coinsCaption and coinsAmount then
		xpCaption.Visible = false
		xpAmount.Visible = false
		coinsCaption.Position = xpCaption.Position
		coinsAmount.Position = xpAmount.Position
		coinsCaption.Text = "Money"
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
		if breakdown then
			local parts = {}
			for _, line in ipairs(data.lines or {}) do
				table.insert(parts, ("%s +%s"):format(tostring(line.label), comma(tonumber(line.amount) or 0)))
			end
			breakdown.Text = table.concat(parts, "  •  ")
		end
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
			populate(data)
			if currentFrame ~= summaryFrame then
				openFrame(summaryFrame)
			end
		end)

		-- The recap is over once the next round cycle starts.
		if stateRemote and stateRemote:IsA("RemoteEvent") then
			stateRemote.OnClientEvent:Connect(function(state)
				if (state == "INTERMISSION" or state == "ACTIVE") and currentFrame == summaryFrame then
					closeFrame(summaryFrame)
				end
			end)
		end
	end)
end
