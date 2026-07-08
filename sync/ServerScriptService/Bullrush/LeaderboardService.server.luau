--!strict
-- LeaderboardService — plain physical global Top-10 leaderboards in the lobby.
--
-- Pushes every online player's Money / Wins (read from their leaderstats mirror,
-- which UserData.DataHandler keeps in sync) into two OrderedDataStores, then reads
-- the global Top 10 and renders it onto the SurfaceGui screen of the two brick Parts
-- Workspace.Lobby.Leaderboards.{Wins,Money}.
--
-- Global ranking needs a PUBLISHED place with Studio API access enabled. When the
-- DataStore is unavailable (unpublished place, API off, transient failure) the board
-- falls back to a live ranking of the players currently in THIS server, so it is
-- never blank and doubles as an in-Studio preview.
--
-- One part, one screen, styled to match the game's UI kit: GothamSSm-Heavy white
-- glyphs with a near-black outline + vertical gradient, on a rounded ink-bordered
-- panel with a bright accent header and medal-chip podium rows.
-- Rendered server-side (no client script), so it lives here rather than StarterGui.Main.

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local Workspace = game:GetService("Workspace")

----------------------------------------------------------------------
-- Config
----------------------------------------------------------------------
local TOP_N = 10
local PUSH_INTERVAL = 60    -- seconds between writing online players' stats to the store
local REFRESH_INTERVAL = 30 -- seconds between reading the store + re-rendering

local FONT = Enum.Font.GothamBlack -- the game's face (GothamSSm Heavy)

-- The game's UI kit look = WHITE glyphs + a near-black UIStroke outline + a
-- vertical light->saturated UIGradient on the text, all on chunky rounded
-- panels with dark borders (lifted straight off the shop frames + Cash counter).
-- We rebuild that DNA here so the board reads hand-made, not flat.
local INK = Color3.fromRGB(13, 14, 18)        -- outline / border ink (kit's ~RGB15 stroke)
local PANEL_TOP = Color3.fromRGB(41, 44, 56)  -- panel body sheen, top
local PANEL_BOT = Color3.fromRGB(23, 24, 32)  -- panel body sheen, bottom
local ROW_BG = Color3.fromRGB(46, 49, 63)     -- default row pill
local WHITE = Color3.fromRGB(255, 255, 255)
local DIM = Color3.fromRGB(150, 155, 168)

local MEDAL = {
	Color3.fromRGB(255, 205, 60),  -- 1st gold
	Color3.fromRGB(207, 216, 230), -- 2nd silver
	Color3.fromRGB(224, 148, 74),  -- 3rd bronze
}

local function lighten(c: Color3, f: number): Color3
	return c:Lerp(Color3.new(1, 1, 1), f)
end
local function darken(c: Color3, f: number): Color3
	return c:Lerp(Color3.new(0, 0, 0), f)
end

local function corner(inst: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = inst
end

local function stroke(inst: Instance, color: Color3, thickness: number)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	s.Parent = inst -- Contextual mode: outlines glyphs on text, the border on frames
end

-- The kit's signature: a vertical light-top -> saturated-bottom ramp on the text.
local function textGradient(label: TextLabel, top: Color3, bottom: Color3)
	local g = Instance.new("UIGradient")
	g.Rotation = 90
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, top),
		ColorSequenceKeypoint.new(0.12, top),
		ColorSequenceKeypoint.new(1, bottom),
	})
	g.Parent = label
end

local function commafmt(n: number): string
	local s = tostring(math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end

-- Board definitions. `key` is the child brick Part of Workspace.Lobby.Leaderboards.
local BOARDS = {
	{
		key = "Wins",
		stat = "Wins",
		store = "Bullrush_LB_Wins_v1",
		title = "TOP WINS",
		accent = Color3.fromRGB(255, 199, 46),
		fmt = function(v: number) return commafmt(v) end,
	},
	{
		key = "Money",
		stat = "Money",
		store = "Bullrush_LB_Money_v1",
		title = "TOP MONEY",
		accent = Color3.fromRGB(74, 214, 118),
		fmt = function(v: number) return "$" .. commafmt(v) end,
	},
}

----------------------------------------------------------------------
-- Board part lookup (build a fallback brick if it's missing)
----------------------------------------------------------------------
local function findBoardPart(cfg): BasePart
	local lobby = Workspace:FindFirstChild("Lobby")
	local folder = lobby and lobby:FindFirstChild("Leaderboards")
	local part = folder and folder:FindFirstChild(cfg.key)
	if part and part:IsA("BasePart") then
		return part
	end
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Leaderboards"
		folder.Parent = lobby or Workspace
	end
	local brick = Instance.new("Part")
	brick.Name = cfg.key
	brick.Anchored = true
	brick.Size = Vector3.new(16, 12, 1)
	brick.Color = Color3.fromRGB(34, 35, 42)
	brick.Material = Enum.Material.SmoothPlastic
	brick.CFrame = CFrame.new(cfg.key == "Wins" and 184 or 216, 37.26, 120)
	brick.Parent = folder
	return brick
end

----------------------------------------------------------------------
-- Build the screen once; keep row references for cheap updates
----------------------------------------------------------------------
type Row = { rank: TextLabel, name: TextLabel, value: TextLabel }
type BoardUI = { rows: { Row }, footer: TextLabel }

local function newLabel(parent: Instance, color: Color3, strokePx: number?): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = FONT
	l.TextScaled = true
	l.TextColor3 = color
	l.Parent = parent
	if strokePx and strokePx > 0 then
		stroke(l, INK, strokePx)
	end
	return l
end

local function buildUI(cfg): BoardUI
	local part = findBoardPart(cfg)

	local existing = part:FindFirstChild("Board")
	if existing then existing:Destroy() end

	local gui = Instance.new("SurfaceGui")
	gui.Name = "Board"
	gui.Face = Enum.NormalId.Front -- Front face normal is -Z, toward the spawn
	gui.LightInfluence = 0
	gui.PixelsPerStud = 50
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.ResetOnSpawn = false
	gui.Adornee = part
	gui.Parent = part

	-- Panel body: a near-black rounded slab with a soft top->bottom sheen and a
	-- chunky ink border, exactly like the kit's shop frames.
	local screen = Instance.new("Frame")
	screen.Name = "Screen"
	screen.Size = UDim2.fromScale(1, 1)
	screen.BackgroundColor3 = PANEL_BOT
	screen.BorderSizePixel = 0
	screen.Parent = gui
	corner(screen, 22)
	stroke(screen, INK, 7)
	do
		local g = Instance.new("UIGradient")
		g.Rotation = 90
		g.Color = ColorSequence.new(PANEL_TOP, PANEL_BOT)
		g.Parent = screen
	end

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0.055, 0)
	pad.PaddingRight = UDim.new(0.055, 0)
	pad.PaddingTop = UDim.new(0.05, 0)
	pad.PaddingBottom = UDim.new(0.04, 0)
	pad.Parent = screen

	-- Header banner: a bright accent gradient pill (light top -> accent bottom)
	-- with an ink border and a white outlined title - the colour the board is
	-- "about". Mirrors the kit's blue/cyan shop headers.
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.fromScale(1, 0.145)
	header.BackgroundColor3 = cfg.accent
	header.BorderSizePixel = 0
	header.Parent = screen
	corner(header, 14)
	stroke(header, INK, 4)
	do
		local g = Instance.new("UIGradient")
		g.Rotation = 90
		g.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, lighten(cfg.accent, 0.38)),
			ColorSequenceKeypoint.new(0.12, lighten(cfg.accent, 0.22)),
			ColorSequenceKeypoint.new(1, darken(cfg.accent, 0.14)),
		})
		g.Parent = header
	end

	local title = newLabel(header, WHITE, 4)
	title.Size = UDim2.fromScale(0.92, 0.6)
	title.Position = UDim2.fromScale(0.04, 0.2)
	title.Text = cfg.title
	title.ZIndex = 2

	-- Rows
	local list = Instance.new("Frame")
	list.Name = "Rows"
	list.Position = UDim2.fromScale(0, 0.185)
	list.Size = UDim2.fromScale(1, 0.755)
	list.BackgroundTransparency = 1
	list.Parent = screen

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0.013, 0)
	layout.Parent = list

	local rows: { Row } = {}
	for i = 1, TOP_N do
		local medal = MEDAL[i]

		-- Row pill. The podium (1-3) rides a dark tint of its medal colour so
		-- the top three read apart from the field without shouting.
		local row = Instance.new("Frame")
		row.Name = "Row" .. i
		row.LayoutOrder = i
		row.Size = UDim2.fromScale(1, (1 - 0.013 * (TOP_N - 1)) / TOP_N)
		row.BackgroundColor3 = medal and darken(medal, 0.68) or ROW_BG
		row.BorderSizePixel = 0
		row.Parent = list
		corner(row, 10)
		stroke(row, INK, medal and 3 or 2)

		local rpad = Instance.new("UIPadding")
		rpad.PaddingLeft = UDim.new(0.018, 0)
		rpad.PaddingRight = UDim.new(0.025, 0)
		rpad.Parent = row

		-- Rank chip: a square rounded badge, medal-coloured (with its own sheen)
		-- for the podium, dark slate otherwise.
		local badge = Instance.new("Frame")
		badge.Name = "Badge"
		badge.AnchorPoint = Vector2.new(0, 0.5)
		badge.Position = UDim2.fromScale(0, 0.5)
		badge.Size = UDim2.fromScale(1, 0.8)
		badge.BackgroundColor3 = medal or Color3.fromRGB(58, 62, 80)
		badge.BorderSizePixel = 0
		badge.Parent = row
		corner(badge, 7)
		stroke(badge, INK, 2.5)
		local ratio = Instance.new("UIAspectRatioConstraint")
		ratio.AspectRatio = 1
		ratio.DominantAxis = Enum.DominantAxis.Height
		ratio.Parent = badge
		if medal then
			local g = Instance.new("UIGradient")
			g.Rotation = 90
			g.Color = ColorSequence.new(lighten(medal, 0.32), darken(medal, 0.14))
			g.Parent = badge
		end

		-- Podium numerals sit on bright metal, so ink them; the rest stay white.
		local rank = newLabel(badge, medal and INK or WHITE, medal and 0 or 2)
		rank.Name = "Rank"
		rank.Size = UDim2.fromScale(0.78, 0.66)
		rank.Position = UDim2.fromScale(0.11, 0.17)
		rank.Text = tostring(i)

		local name = newLabel(row, WHITE, 2)
		name.Name = "Name"
		name.Position = UDim2.fromScale(0.135, 0.16)
		name.Size = UDim2.fromScale(0.52, 0.68)
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.TextTruncate = Enum.TextTruncate.AtEnd
		name.Text = "—"

		local value = newLabel(row, lighten(cfg.accent, 0.15), 2.5)
		value.Name = "Value"
		value.Position = UDim2.fromScale(0.67, 0.16)
		value.Size = UDim2.fromScale(0.33, 0.68)
		value.TextXAlignment = Enum.TextXAlignment.Right
		textGradient(value, lighten(cfg.accent, 0.42), darken(cfg.accent, 0.06))
		value.Text = ""

		rows[i] = { rank = rank, name = name, value = value }
	end

	-- Footer (data-source hint)
	local footer = newLabel(screen, DIM, 0)
	footer.Name = "Footer"
	footer.Position = UDim2.fromScale(0, 0.955)
	footer.Size = UDim2.fromScale(1, 0.042)
	footer.Text = ""

	return { rows = rows, footer = footer }
end

local boardUI: { [string]: BoardUI } = {}
for _, cfg in ipairs(BOARDS) do
	boardUI[cfg.key] = buildUI(cfg)
end

----------------------------------------------------------------------
-- Name resolution (cached)
----------------------------------------------------------------------
local nameCache: { [number]: string } = {}
local function nameFor(userId: number): string
	if nameCache[userId] then return nameCache[userId] end
	local online = Players:GetPlayerByUserId(userId)
	if online then
		nameCache[userId] = online.DisplayName
		return online.DisplayName
	end
	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	if ok and name then
		nameCache[userId] = name
		return name
	end
	return "User " .. userId
end

----------------------------------------------------------------------
-- Data: read stats, push to store, fetch top N
----------------------------------------------------------------------
local function statValue(player: Player, stat: string): number?
	local ls = player:FindFirstChild("leaderstats")
	local sv = ls and ls:FindFirstChild(stat)
	if sv and sv:IsA("ValueBase") then
		return math.max(0, math.floor((sv :: any).Value))
	end
	return nil
end

local lastPushed: { [number]: { [string]: number } } = {}

local function pushPlayer(player: Player)
	local cache = lastPushed[player.UserId]
	if not cache then
		cache = {}
		lastPushed[player.UserId] = cache
	end
	for _, cfg in ipairs(BOARDS) do
		local value = statValue(player, cfg.stat)
		if value ~= nil and cache[cfg.key] ~= value then
			local ok, store = pcall(function()
				return DataStoreService:GetOrderedDataStore(cfg.store)
			end)
			if ok and store then
				local sok = pcall(function()
					store:SetAsync(tostring(player.UserId), value)
				end)
				if sok then
					cache[cfg.key] = value
				end
			end
		end
	end
end

-- Live ranking of players currently in this server (fallback + preview).
local function localTop(cfg): { { userId: number, value: number } }
	local list = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local v = statValue(player, cfg.stat)
		if v ~= nil then
			list[#list + 1] = { userId = player.UserId, value = v }
		end
	end
	table.sort(list, function(a, b) return a.value > b.value end)
	while #list > TOP_N do
		table.remove(list)
	end
	return list
end

local function fetchTop(cfg): ({ { userId: number, value: number } }, boolean)
	local ok, store = pcall(function()
		return DataStoreService:GetOrderedDataStore(cfg.store)
	end)
	if ok and store then
		local ok2, pages = pcall(function()
			return store:GetSortedAsync(false, TOP_N)
		end)
		if ok2 and pages then
			local out = {}
			for _, entry in ipairs(pages:GetCurrentPage()) do
				out[#out + 1] = { userId = tonumber(entry.key) or 0, value = entry.value }
			end
			return out, true
		end
	end
	return localTop(cfg), false
end

----------------------------------------------------------------------
-- Render
----------------------------------------------------------------------
local function render(cfg)
	local ui = boardUI[cfg.key]
	if not ui then return end
	-- Chips + rank colours are baked in at build time (row i is always rank i),
	-- so a refresh only swaps the name/value text and dims the empty seats.
	local data, isGlobal = fetchTop(cfg)
	for i = 1, TOP_N do
		local row = ui.rows[i]
		local entry = data[i]
		if entry then
			row.name.Text = nameFor(entry.userId)
			row.name.TextColor3 = WHITE
			row.name.TextTransparency = 0
			row.value.Text = cfg.fmt(entry.value)
			row.value.TextTransparency = 0
		else
			row.name.Text = "—"
			row.name.TextColor3 = DIM
			row.name.TextTransparency = 0.3
			row.value.Text = ""
			row.value.TextTransparency = 0.3
		end
	end
	ui.footer.Text = isGlobal and "GLOBAL • ALL SERVERS" or "THIS SERVER"
end

local function renderAll()
	for _, cfg in ipairs(BOARDS) do
		render(cfg)
	end
end

----------------------------------------------------------------------
-- Loops + lifecycle
----------------------------------------------------------------------
Players.PlayerRemoving:Connect(function(player)
	pushPlayer(player)
	lastPushed[player.UserId] = nil
end)

game:BindToClose(function()
	for _, player in ipairs(Players:GetPlayers()) do
		pushPlayer(player)
	end
end)

-- Initial paint (uses local fallback until the first store read succeeds).
renderAll()

task.spawn(function()
	while true do
		for _, player in ipairs(Players:GetPlayers()) do
			pushPlayer(player)
		end
		task.wait(PUSH_INTERVAL)
	end
end)

task.spawn(function()
	while true do
		task.wait(REFRESH_INTERVAL)
		renderAll()
	end
end)
