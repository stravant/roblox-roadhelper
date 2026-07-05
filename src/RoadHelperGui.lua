--!strict
local Plugin = script.Parent.Parent
local Packages = Plugin.Packages
local React = require(Packages.React)
local e = React.createElement

local Colors = require("./PluginGui/Colors")
local SubPanel = require("./PluginGui/SubPanel")
local NumberInput = require("./PluginGui/NumberInput")
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

local BLUE = Color3.fromRGB(70, 130, 255)
local RED = Color3.fromRGB(255, 70, 70)

local function TutorialStub(props: PluginGuiTypes.TutorialElementProps)
	return nil :: any
end

local ROADHELPER_CONFIG: PluginGuiTypes.PluginGuiConfig = {
	PluginName = "RoadHelper",
	PendingText = "Click a road endpoint marker in the 3D view to select it.",
	TutorialElement = TutorialStub :: any,
}

local function describeSelection(state: createRoadSession.SelectionState): string
	if state.Kind == "none" then
		return "Click a road endpoint marker to select it."
	end
	local endName = if state.EndpointId == "Blue" then "blue end" else "red end"
	local segName = if state.SegmentKind == "Straight" then "StraightRoad" else "CurveRoad"
	if state.Kind == "open" then
		return `<b>Open endpoint</b> — {segName} ({endName})\nDrag the arrows in front of it to extend the road.`
	else
		local otherName = if state.OtherSegmentKind == "Straight" then "StraightRoad" else "CurveRoad"
		return `<b>Closed joint</b> — {segName} ({endName}) to {otherName}`
	end
end

local function SelectionPanel(props: {
	SelectionState: createRoadSession.SelectionState,
	SetAdjustValue: (axis: RoadMath.AdjustAxis, value: number) -> (),
	LayoutOrder: number?,
})
	local state = props.SelectionState
	local nextOrder = createNextOrder()

	local children: { [string]: any } = {}
	children.Status = e("TextLabel", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		TextColor3 = if state.Kind == "none"
			then Colors.OFFWHITE
			else (if state.EndpointId == "Blue" then BLUE else RED),
		RichText = true,
		Text = describeSelection(state),
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = Enum.Font.SourceSans,
		TextSize = 18,
		LayoutOrder = nextOrder(),
	})

	if state.Kind ~= "none" then
		children.DirInput = e(NumberInput, {
			Label = "Dir",
			Value = state.Dir,
			Unit = "°",
			LayoutOrder = nextOrder(),
			ValueEntered = function(value: number): number?
				props.SetAdjustValue("Dir", value)
				return value
			end,
		})
		children.GradeInput = e(NumberInput, {
			Label = "Grade",
			Value = state.Grade,
			Unit = "°",
			LayoutOrder = nextOrder(),
			ValueEntered = function(value: number): number?
				props.SetAdjustValue("Grade", value)
				return value
			end,
		})
		children.BankInput = e(NumberInput, {
			Label = "Bank",
			Value = state.Bank,
			Unit = "°",
			LayoutOrder = nextOrder(),
			ValueEntered = function(value: number): number?
				props.SetAdjustValue("Bank", value)
				return value
			end,
		})
	end

	return e(SubPanel, {
		Title = "Endpoint",
		LayoutOrder = props.LayoutOrder,
	}, children)
end

local function AddPanel(props: {
	AddSegment: (kind: RoadMath.SegmentKind) -> (),
	LayoutOrder: number?,
})
	local nextOrder = createNextOrder()
	return e(SubPanel, {
		Title = "Add",
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

local function DonePanel(props: {
	HandleAction: (string) -> (),
	LayoutOrder: number?,
})
	return e(SubPanel, {
		Title = "",
		LayoutOrder = props.LayoutOrder,
	}, {
		Button = e(OperationButton, {
			Text = "Done",
			Height = 28,
			Disabled = false,
			Color = Color3.fromRGB(0, 150, 60),
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
		SelectionPanel = e(SelectionPanel, {
			SelectionState = props.SelectionState,
			SetAdjustValue = props.SetAdjustValue,
			LayoutOrder = nextOrder(),
		}),
		AddPanel = e(AddPanel, {
			AddSegment = props.AddSegment,
			LayoutOrder = nextOrder(),
		}),
		DonePanel = e(DonePanel, {
			HandleAction = props.HandleAction,
			LayoutOrder = nextOrder(),
		}),
	})
end

return RoadHelperGui
