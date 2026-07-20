local barSize = UDim.new(0.02075, 0)
--First number is size in scale (percent) and second number is size in offset (pixels)

local scrollingFrame = script.Parent
local scrollingFrameParent = script.Parent.Parent
local grid = scrollingFrame:FindFirstChildOfClass("UIGridLayout")
local padding = scrollingFrame:FindFirstChildOfClass("UIPadding")
local cellHeightScale = grid and grid.CellSize.Y.Scale or 0
local cellHeightOffset = grid and grid.CellSize.Y.Offset or 0
local gapHeightScale = grid and grid.CellPadding.Y.Scale or 0
local gapHeightOffset = grid and grid.CellPadding.Y.Offset or 0

-- AutomaticCanvasSize does not reliably include scale-based grid cells and
-- UIPadding together, which clipped the final skills row. Own the Y canvas from
-- the grid's measured content and include both vertical padding values.
scrollingFrame.AutomaticCanvasSize = Enum.AutomaticSize.None

local function paddingPixels(value: UDim): number
	return scrollingFrame.AbsoluteSize.Y * value.Scale + value.Offset
end

local function update()
	scrollingFrame.ScrollBarThickness = scrollingFrameParent.AbsoluteSize.X * barSize.Scale + barSize.Offset
	if grid then
		local size = scrollingFrame.AbsoluteSize
		-- Convert the designer's scale-based vertical measurements to pixels before
		-- sizing the canvas. Otherwise Roblox resolves Y scale against CanvasSize,
		-- creating a CanvasSize -> cell height -> CanvasSize feedback loop.
		local stableCellHeight = size.Y * cellHeightScale + cellHeightOffset
		local stableGapHeight = size.Y * gapHeightScale + gapHeightOffset
		grid.CellSize = UDim2.new(grid.CellSize.X.Scale, grid.CellSize.X.Offset, 0, stableCellHeight)
		grid.CellPadding = UDim2.new(grid.CellPadding.X.Scale, grid.CellPadding.X.Offset, 0, stableGapHeight)
		local left = if padding then size.X * padding.PaddingLeft.Scale + padding.PaddingLeft.Offset else 0
		local right = if padding then size.X * padding.PaddingRight.Scale + padding.PaddingRight.Offset else 0
		local top = if padding then paddingPixels(padding.PaddingTop) else 0
		local bottom = if padding then paddingPixels(padding.PaddingBottom) else 0
		local cellWidth = size.X * grid.CellSize.X.Scale + grid.CellSize.X.Offset
		local cellHeight = stableCellHeight
		local gapWidth = size.X * grid.CellPadding.X.Scale + grid.CellPadding.X.Offset
		local gapHeight = stableGapHeight
		local availableWidth = math.max(1, size.X - left - right)
		local columns = grid.FillDirectionMaxCells > 0 and grid.FillDirectionMaxCells
			or math.max(1, math.floor((availableWidth + gapWidth) / math.max(1, cellWidth + gapWidth)))
		local cardCount = 0
		for _, child in scrollingFrame:GetChildren() do
			if child:IsA("GuiObject") and child.Visible then
				cardCount += 1
			end
		end
		local rows = math.max(1, math.ceil(cardCount / columns))
		-- Extra breathing room keeps the last card's outline clear of the clip edge.
		local contentHeight = top + bottom + rows * cellHeight + math.max(0, rows - 1) * gapHeight + 12
		scrollingFrame.CanvasSize = UDim2.fromOffset(0, math.ceil(contentHeight))
	end
end

update()
scrollingFrameParent:GetPropertyChangedSignal("AbsoluteSize"):Connect(update)
scrollingFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(update)
scrollingFrame.ChildAdded:Connect(update)
scrollingFrame.ChildRemoved:Connect(update)
