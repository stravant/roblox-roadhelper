--!strict
local Plugin = script.Parent.Parent
local Packages = Plugin.Packages
local React = require(Packages.React)
local e = React.createElement

local Colors = require("./PluginGui/Colors")
local SubPanel = require("./PluginGui/SubPanel")
local NumberInput = require("./PluginGui/NumberInput")
local Checkbox = require("./PluginGui/Checkbox")
local PluginGui = require("./PluginGui/PluginGui")
local OperationButton = require("./PluginGui/OperationButton")
local PluginGuiTypes = require("./PluginGui/Types")

local createRoadSession = require("./createRoadSession")
local RoadMath = require("./RoadMath")
local Settings = require("./Settings")

local function createNextOrder(): () -> number
	local order = 0
	return function()
		order += 1
		return order
	end
end

local function TutorialStub(props: PluginGuiTypes.TutorialElementProps)
	return nil :: any
end

local ROADHELPER_CONFIG: PluginGuiTypes.PluginGuiConfig = {
	PluginName = "RoadHelper",
	PendingText = "Click the end of a road segment to select that endpoint.",
	TutorialElement = TutorialStub :: any,
}

local function describeStatus(state: createRoadSession.SelectionState): string
	if state.Kind == "none" then
		return "Click the end of a road segment to select that endpoint."
	elseif state.Kind == "open" then
		return "<b>Open endpoint selected.</b>"
			.. "\nDrag the handles to move it, the rings to adjust its angles, or drag one of the cones to extend the road with a new segment."
	else
		return "<b>Joint selected.</b>"
			.. "\nDrag the handles to move the joint, or the rings to adjust its angles. Both segments follow."
	end
end

local function StatusPanel(props: {
	SelectionState: createRoadSession.SelectionState,
	LayoutOrder: number?,
})
	return e(SubPanel, {
		Title = "Status",
		LayoutOrder = props.LayoutOrder,
	}, {
		Status = e("TextLabel", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			TextColor3 = Colors.WHITE,
			RichText = true,
			Text = describeStatus(props.SelectionState),
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			Font = Enum.Font.SourceSans,
			TextSize = 18,
		}),
	})
end

local function ParametersPanel(props: {
	SelectionState: createRoadSession.SelectionState,
	SetAdjustValue: (axis: RoadMath.AdjustAxis, value: number) -> (),
	SetBlend: (value: boolean) -> (),
	LayoutOrder: number?,
})
	local state = props.SelectionState
	if state.Kind == "none" then
		return nil :: any
	end
	local nextOrder = createNextOrder()
	return e(SubPanel, {
		Title = "Parameters (Attributes)",
		Padding = UDim.new(0, 6),
		LayoutOrder = props.LayoutOrder,
	}, {
		DirectionInput = e(NumberInput, {
			Label = "Direction",
			Value = state.Dir,
			Unit = "°",
			LayoutOrder = nextOrder(),
			ValueEntered = function(value: number): number?
				props.SetAdjustValue("Dir", value)
				return value
			end,
		}),
		GradeInput = e(NumberInput, {
			Label = "Grade",
			Value = state.Grade,
			Unit = "°",
			LayoutOrder = nextOrder(),
			ValueEntered = function(value: number): number?
				props.SetAdjustValue("Grade", value)
				return value
			end,
		}),
		BankInput = e(NumberInput, {
			Label = "Bank",
			Value = state.Bank,
			Unit = "°",
			LayoutOrder = nextOrder(),
			ValueEntered = function(value: number): number?
				props.SetAdjustValue("Bank", value)
				return value
			end,
		}),
		HaveSkirt = e(Checkbox, {
			Label = "Have skirt",
			Checked = state.Blend,
			LayoutOrder = nextOrder(),
			Changed = props.SetBlend,
		}),
	})
end

local function AddPanel(props: {
	CurrentSettings: Settings.RoadHelperSettings,
	UpdatedSettings: () -> (),
	AddSegment: (kind: RoadMath.SegmentKind) -> (),
	LayoutOrder: number?,
})
	local nextOrder = createNextOrder()
	return e(SubPanel, {
		Title = "Add",
		Padding = UDim.new(0, 8),
		LayoutOrder = props.LayoutOrder,
	}, {
		Hint = e("TextLabel", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			TextColor3 = Colors.OFFWHITE,
			Text = "Add a segment in front of the camera:",
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			Font = Enum.Font.SourceSans,
			TextSize = 16,
			LayoutOrder = nextOrder(),
		}),
		AlignToWorld = e(Checkbox, {
			Label = "Align to world",
			Checked = props.CurrentSettings.AlignToWorld,
			LayoutOrder = nextOrder(),
			Changed = function(checked: boolean)
				props.CurrentSettings.AlignToWorld = checked
				props.UpdatedSettings()
			end,
		}),
		Buttons = e("Frame", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = nextOrder(),
		}, {
			ListLayout = e("UIListLayout", {
				SortOrder = Enum.SortOrder.LayoutOrder,
				FillDirection = Enum.FillDirection.Horizontal,
				Padding = UDim.new(0, 4),
			}),
			StraightButton = e("Frame", {
				Size = UDim2.new(0.5, -2, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				LayoutOrder = 1,
			}, {
				Button = e(OperationButton, {
					Text = "Straight",
					Height = 28,
					Disabled = false,
					Color = Colors.ACTION_BLUE,
					OnClick = function()
						props.AddSegment("Straight")
					end,
				}),
			}),
			CurveButton = e("Frame", {
				Size = UDim2.new(0.5, -2, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				LayoutOrder = 2,
			}, {
				Button = e(OperationButton, {
					Text = "Curve",
					Height = 28,
					Disabled = false,
					Color = Colors.ACTION_BLUE,
					OnClick = function()
						props.AddSegment("Curve")
					end,
				}),
			}),
		}),
	})
end

local function CloseButton(props: {
	HandleAction: (string) -> (),
	LayoutOrder: number?,
})
	return e("Frame", {
		Size = UDim2.fromScale(1, 0),
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder,
		AutomaticSize = Enum.AutomaticSize.Y,
	}, {
		Padding = e("UIPadding", {
			PaddingTop = UDim.new(0, 8),
			PaddingBottom = UDim.new(0, 12),
			PaddingLeft = UDim.new(0, 12),
			PaddingRight = UDim.new(0, 12),
		}),
		CancelButton = e(OperationButton, {
			Text = "Close <i>RoadHelper</i>",
			Color = Colors.DARK_RED,
			Disabled = false,
			Height = 30,
			OnClick = function()
				props.HandleAction("cancel")
			end,
		}),
	})
end

local function RoadHelperGui(props: {
	GuiState: PluginGuiTypes.PluginGuiMode,
	SelectionState: createRoadSession.SelectionState,
	SetAdjustValue: (axis: RoadMath.AdjustAxis, value: number) -> (),
	SetBlend: (value: boolean) -> (),
	AddSegment: (kind: RoadMath.SegmentKind) -> (),
	CurrentSettings: Settings.RoadHelperSettings,
	UpdatedSettings: () -> (),
	HandleAction: (string) -> (),
	Panelized: boolean,
})
	local nextOrder = createNextOrder()
	return e(PluginGui, {
		Config = ROADHELPER_CONFIG,
		State = {
			Mode = props.GuiState,
			Settings = props.CurrentSettings,
			UpdatedSettings = props.UpdatedSettings,
			HandleAction = props.HandleAction,
			Panelized = props.Panelized,
		},
	}, {
		StatusPanel = e(StatusPanel, {
			SelectionState = props.SelectionState,
			LayoutOrder = nextOrder(),
		}),
		ParametersPanel = e(ParametersPanel, {
			SelectionState = props.SelectionState,
			SetAdjustValue = props.SetAdjustValue,
			SetBlend = props.SetBlend,
			LayoutOrder = nextOrder(),
		}),
		AddPanel = e(AddPanel, {
			CurrentSettings = props.CurrentSettings,
			UpdatedSettings = props.UpdatedSettings,
			AddSegment = props.AddSegment,
			LayoutOrder = nextOrder(),
		}),
		CloseButton = e(CloseButton, {
			HandleAction = props.HandleAction,
			LayoutOrder = nextOrder(),
		}),
	})
end

return RoadHelperGui
