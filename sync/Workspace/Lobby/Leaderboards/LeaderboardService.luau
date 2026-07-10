--!strict
-- LeaderboardService — modular logic for the physical global Top-15 leaderboards
-- in the lobby. Lives on the boards themselves: this ModuleScript + a sibling Boot
-- Script sit under Workspace.Lobby.Leaderboards, and Boot calls start(folder) with
-- that folder (whose Wins / Money brick Parts get the SurfaceGui screens).
--
-- Pushes every online player's Money / Wins (read from their leaderstats mirror,
-- which UserData.DataHandler keeps in sync) into two OrderedDataStores, then reads
-- the global Top 15 and renders it onto the SurfaceGui of each brick.
--
-- Global ranking needs a PUBLISHED place with Studio API access enabled. When the
-- DataStore is unavailable (unpublished place, API off, transient failure) the board
-- falls back to a live ranking of the players currently in THIS server, so it is
-- never blank and doubles as an in-Studio preview.
--
-- Deliberately basic: a flat dark panel, an accent title with a divider, and plain
-- rank / name / value text rows. Only flair is a gold/silver/bronze tint on the
-- top-three rank numbers. The footer counts down to the next refresh.

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")

local Leaderboard = {}

----------------------------------------------------------------------
-- Config
----------------------------------------------------------------------
local TOP_N = 15
local PUSH_INTERVAL = 60    -- seconds between writing online players' stats to the store
local REFRESH_INTERVAL = 30 -- seconds between reading the store + re-rendering

local FONT = Enum.Font.GothamBlack -- the game's face (GothamSSm Heavy)

-- Keep it flat and simple: dark panel, near-black ink for the border + text
-- outline (the outline is what keeps the text readable), white names.
local INK = Color3.fromRGB(13, 14, 18)     -- border + text outline
local PANEL = Color3.fromRGB(28, 29, 36)   -- flat panel background
local WHITE = Color3.fromRGB(255, 255, 255)
local DIM = Color3.fromRGB(150, 155, 168)  -- empty seats + footer

local MEDAL = {
	Color3.fromRGB(255, 205, 60),  -- 1st gold
	Color3.fromRGB(207, 216, 230), -- 2nd silver
	Color3.fromRGB(224, 148, 74),  -- 3rd bronze
}

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

local function commafmt(n: number): string
	local s = tostring(math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end

-- m:ss countdown text.
local function clockfmt(sec: number): string
	sec = math.max(0, math.floor(sec + 0.5))
	return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

-- Board definitions. `key` is the child brick Part of the Leaderboards folder.
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
-- Board part lookup (build a fallback brick under the folder if it's missing)
----------------------------------------------------------------------
local function findBoardPart(cfg, folder: Instance): BasePart
	local part = folder:FindFirstChild(cfg.key)
	if part and part:IsA("BasePart") then
		return part
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

local function buildUI(cfg, folder: Instance): BoardUI
	local part = findBoardPart(cfg, folder)

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

	-- Flat dark panel with a thin ink border. That's it.
	local screen = Instance.new("Frame")
	screen.Name = "Screen"
	screen.Size = UDim2.fromScale(1, 1)
	screen.BackgroundColor3 = PANEL
	screen.BorderSizePixel = 0
	screen.Parent = gui
	corner(screen, 10)
	stroke(screen, INK, 4)

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0.05, 0)
	pad.PaddingRight = UDim.new(0.05, 0)
	pad.PaddingTop = UDim.new(0.045, 0)
	pad.PaddingBottom = UDim.new(0.035, 0)
	pad.Parent = screen

	-- Plain accent title, no pill.
	local title = newLabel(screen, cfg.accent, 3)
	title.Name = "Title"
	title.Position = UDim2.fromScale(0, 0)
	title.Size = UDim2.fromScale(1, 0.1)
	title.Text = cfg.title

	-- Thin divider under the title.
	local divider = Instance.new("Frame")
	divider.Name = "Divider"
	divider.Position = UDim2.fromScale(0, 0.125)
	divider.Size = UDim2.new(1, 0, 0, 2)
	divider.BackgroundColor3 = INK
	divider.BorderSizePixel = 0
	divider.Parent = screen

	-- Rows
	local list = Instance.new("Frame")
	list.Name = "Rows"
	list.Position = UDim2.fromScale(0, 0.16)
	list.Size = UDim2.fromScale(1, 0.8)
	list.BackgroundTransparency = 1
	list.Parent = screen

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0.006, 0)
	layout.Parent = list

	local rows: { Row } = {}
	for i = 1, TOP_N do
		local medal = MEDAL[i]

		-- Plain transparent row; just three text columns.
		local row = Instance.new("Frame")
		row.Name = "Row" .. i
		row.LayoutOrder = i
		row.Size = UDim2.fromScale(1, (1 - 0.006 * (TOP_N - 1)) / TOP_N)
		row.BackgroundTransparency = 1
		row.Parent = list

		-- Rank number (podium tinted gold/silver/bronze, the rest white).
		local rank = newLabel(row, medal or WHITE, 2)
		rank.Name = "Rank"
		rank.Position = UDim2.fromScale(0, 0)
		rank.Size = UDim2.fromScale(0.11, 1)
		rank.TextXAlignment = Enum.TextXAlignment.Left
		rank.Text = tostring(i)

		local name = newLabel(row, WHITE, 2)
		name.Name = "Name"
		name.Position = UDim2.fromScale(0.15, 0)
		name.Size = UDim2.fromScale(0.53, 1)
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.TextTruncate = Enum.TextTruncate.AtEnd
		name.Text = "—"

		local value = newLabel(row, cfg.accent, 2)
		value.Name = "Value"
		value.Position = UDim2.fromScale(0.66, 0)
		value.Size = UDim2.fromScale(0.34, 1)
		value.TextXAlignment = Enum.TextXAlignment.Right
		value.Text = ""

		rows[i] = { rank = rank, name = name, value = value }
	end

	-- Footer (counts down to the next refresh)
	local footer = newLabel(screen, DIM, 0)
	footer.Name = "Footer"
	footer.Position = UDim2.fromScale(0, 0.965)
	footer.Size = UDim2.fromScale(1, 0.035)
	footer.Text = ""

	return { rows = rows, footer = footer }
end

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
local boardUI: { [string]: BoardUI } = {}
local nextUpdateAt = 0 -- os.clock() timestamp of the next scheduled refresh

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

local function fetchTop(cfg): { { userId: number, value: number } }
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
			return out
		end
	end
	return localTop(cfg)
end

----------------------------------------------------------------------
-- Render
----------------------------------------------------------------------
local function render(cfg)
	local ui = boardUI[cfg.key]
	if not ui then return end
	-- Rank numbers are baked in at build time (row i is always rank i), so a
	-- refresh only swaps the name/value text and dims the empty seats.
	local data = fetchTop(cfg)
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
end

local function renderAll()
	for _, cfg in ipairs(BOARDS) do
		render(cfg)
	end
	-- Baseline the countdown to when this fresh data landed.
	nextUpdateAt = os.clock() + REFRESH_INTERVAL
end

-- Footer countdown, ticked once a second between refreshes.
local function updateCountdown()
	local text = "NEXT UPDATE IN " .. clockfmt(nextUpdateAt - os.clock())
	for _, cfg in ipairs(BOARDS) do
		local ui = boardUI[cfg.key]
		if ui then ui.footer.Text = text end
	end
end

----------------------------------------------------------------------
-- Entry point
----------------------------------------------------------------------
function Leaderboard.start(folder: Instance)
	for _, cfg in ipairs(BOARDS) do
		boardUI[cfg.key] = buildUI(cfg, folder)
	end

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
	updateCountdown()

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

	task.spawn(function()
		while true do
			updateCountdown()
			task.wait(1)
		end
	end)
end

return Leaderboard
