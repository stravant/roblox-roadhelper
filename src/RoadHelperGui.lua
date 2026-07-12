--!strict
local Plugin = script.Parent.Parent
local Packages = Plugin.Packages
local React = require(Packages.React)
local e = React.createElement

local Colors = require("./PluginGui/Colors")
local SubPanel = require("./PluginGui/SubPanel")
local NumberInput = require("./PluginGui/NumberInput")
local Checkbox = require("./PluginGui/Checkbox")
local ChipForToggle = require("./PluginGui/ChipForToggle")
local HelpGui = require("./PluginGui/HelpGui")
local PluginGui = require("./PluginGui/PluginGui")
local OperationButton = require("./PluginGui/OperationButton")
local PluginGuiTypes = require("./PluginGui/Types")

local createRoadSession = require("./createRoadSession")
local Presets = require("./Presets")
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
	elseif (state :: any).SegmentKind == "Intersection" then
		if state.Kind == "open" then
			return "<b>Intersection exit selected.</b>"
				.. "\nDrag a cone to extend this exit; the central handles move the whole intersection."
		else
			return "<b>Connected intersection exit selected.</b>"
		end
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
	SetSegmentAttribute: (name: string, value: any) -> (),
	LayoutOrder: number?,
})
	local state = props.SelectionState
	if state.Kind == "none" then
		return nil :: any
	end
	if (state :: any).SegmentKind == "Intersection" then
		return e(SubPanel, {
			Title = "Parameters (Attributes)",
			Padding = UDim.new(0, 6),
			LayoutOrder = props.LayoutOrder,
		}, {
			AngleInput = e(HelpGui.WithHelpIcon, {
				Help = e(HelpGui.BasicTooltip, {
					HelpRichText = "The angle between the intersection's two roads. The angled road's exits swing to match, and joined roads follow.",
				}),
				LayoutOrder = 1,
				Subject = e(NumberInput, {
					Label = "Angle",
					Value = (state :: any).IntersectionAngle,
					Unit = "°",
					ValueEntered = function(value: number): number?
						local clamped = math.clamp(value, 25, 155)
						props.SetSegmentAttribute("IntersectionAngle", clamped)
						return clamped
					end,
				}),
			}),
			HaveSkirt = e(HelpGui.WithHelpIcon, {
				Help = e(HelpGui.BasicTooltip, {
					HelpRichText = "Adds a sloped fill skirt along the intersection's edges that ramps down into the surrounding terrain.",
				}),
				LayoutOrder = 2,
				Subject = e(Checkbox, {
					Label = "Have skirt",
					Checked = state.Blend,
					Changed = props.SetBlend,
				}),
			}),
		})
	end
	local nextOrder = createNextOrder()
	return e(SubPanel, {
		Title = "Parameters (Attributes)",
		Padding = UDim.new(0, 6),
		LayoutOrder = props.LayoutOrder,
	}, {
		DirectionInput = e(HelpGui.WithHelpIcon, {
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Horizontal angle of the road face at this end, pivoting about the endpoint. A joined neighbor's end follows so the joint stays sealed.",
			}),
			LayoutOrder = nextOrder(),
			Subject = e(NumberInput, {
				Label = "Direction",
				Value = state.Dir,
				Unit = "°",
				ValueEntered = function(value: number): number?
					props.SetAdjustValue("Dir", value)
					return value
				end,
			}),
		}),
		GradeInput = e(HelpGui.WithHelpIcon, {
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Vertical slope of the road at this end. Positive slopes upward heading out of the segment.",
			}),
			LayoutOrder = nextOrder(),
			Subject = e(NumberInput, {
				Label = "Grade",
				Value = state.Grade,
				Unit = "°",
				ValueEntered = function(value: number): number?
					props.SetAdjustValue("Grade", value)
					return value
				end,
			}),
		}),
		BankInput = e(HelpGui.WithHelpIcon, {
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Roll of the road surface at this end, for banking corners. The surface twists smoothly between the two ends' bank angles.",
			}),
			LayoutOrder = nextOrder(),
			Subject = e(NumberInput, {
				Label = "Bank",
				Value = state.Bank,
				Unit = "°",
				ValueEntered = function(value: number): number?
					props.SetAdjustValue("Bank", value)
					return value
				end,
			}),
		}),
		HaveSkirt = e(HelpGui.WithHelpIcon, {
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Adds a sloped fill skirt along the road edges that ramps down into the surrounding terrain, hiding the hard seam.",
			}),
			LayoutOrder = nextOrder(),
			Subject = e(Checkbox, {
				Label = "Have skirt",
				Checked = state.Blend,
				Changed = props.SetBlend,
			}),
		}),
	})
end

local DETAIL_LEVELS = {
	{ Label = "Low", MaxAngle = 15 },
	{ Label = "Normal", MaxAngle = 10 },
	{ Label = "High", MaxAngle = 5 },
}

local function DetailPanel(props: {
	SelectionState: createRoadSession.SelectionState,
	SetSegmentAttribute: (name: string, value: any) -> (),
	LayoutOrder: number?,
})
	local state = props.SelectionState
	if state.Kind == "none" then
		return nil :: any
	end
	local chips: { [string]: any } = {
		ListLayout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Left,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		Corner = e("UICorner", {
			CornerRadius = UDim.new(0, 4),
		}),
	}
	for index, level in DETAIL_LEVELS do
		chips[level.Label] = e(ChipForToggle, {
			Text = level.Label,
			IsCurrent = state.MaxAngle == level.MaxAngle,
			LayoutOrder = index,
			OnClick = function()
				props.SetSegmentAttribute("MaxAngle", level.MaxAngle)
			end,
		})
	end
	return e(SubPanel, {
		Title = "Detail Level",
		Padding = UDim.new(0, 6),
		LayoutOrder = props.LayoutOrder,
	}, {
		Chips = e(HelpGui.WithHelpIcon, {
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "How finely the road surface is tessellated (how many degrees of turn or twist each row of parts may span). Higher detail looks smoother but uses more parts.",
			}),
			LayoutOrder = 2,
			Subject = e("Frame", {
				Size = UDim2.new(1, 0, 0, 0),
				BorderSizePixel = 0,
				BackgroundColor3 = Colors.ACTION_BLUE,
				AutomaticSize = Enum.AutomaticSize.Y,
			}, chips),
		}),
	})
end

local LANE_MARKING_MODES = { "None", "Parts", "Textured" }

local function LaneMarkingsPanel(props: {
	SelectionState: createRoadSession.SelectionState,
	SetLaneMarkings: (mode: string) -> (),
	LayoutOrder: number?,
})
	local state = props.SelectionState
	if state.Kind == "none" then
		return nil :: any
	end
	local current = if not (state :: any).HaveLaneMarkings
		then "None"
		elseif state.TextureLaneMarkings then "Textured"
		else "Parts"
	local chips: { [string]: any } = {
		ListLayout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Left,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		Corner = e("UICorner", {
			CornerRadius = UDim.new(0, 4),
		}),
	}
	for index, mode in LANE_MARKING_MODES do
		chips[mode] = e(ChipForToggle, {
			Text = mode,
			IsCurrent = current == mode,
			LayoutOrder = index,
			OnClick = function()
				props.SetLaneMarkings(mode)
			end,
		})
	end
	return e(SubPanel, {
		Title = "Lane Markings",
		LayoutOrder = props.LayoutOrder,
	}, {
		Chips = e(HelpGui.WithHelpIcon, {
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "\u{2022} <b>None</b> hides the lane markings, leaving clear pavement to paint custom markings on."
					.. "\n\u{2022} <b>Parts</b> draws them as solid colored strips."
					.. "\n\u{2022} <b>Textured</b> paints them with textures, including properly dashed divider lines, at a small perf cost.",
			}),
			Subject = e("Frame", {
				Size = UDim2.new(1, 0, 0, 0),
				BorderSizePixel = 0,
				BackgroundColor3 = Colors.ACTION_BLUE,
				AutomaticSize = Enum.AutomaticSize.Y,
			}, chips),
		}),
	})
end

local function SizingPanel(props: {
	SelectionState: createRoadSession.SelectionState,
	SetSizing: (name: string, value: number) -> (),
	LayoutOrder: number?,
})
	local state = props.SelectionState
	if state.Kind == "none" then
		return nil :: any
	end
	return e(SubPanel, {
		Title = "Sizing",
		Padding = UDim.new(0, 6),
		LayoutOrder = props.LayoutOrder,
	}, {
		LaneCountInput = e(HelpGui.WithHelpIcon, {
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Number of lanes. An odd count adds a shared center turn lane. The bounds adjust so both endpoints stay in place.",
			}),
			LayoutOrder = 1,
			Subject = e(NumberInput, {
				Label = "Lanes",
				Value = state.LaneCount,
				ValueEntered = function(value: number): number?
					local count = math.max(math.round(value), 1)
					props.SetSizing("LaneCount", count)
					return count
				end,
			}),
		}),
		LaneWidthInput = e(HelpGui.WithHelpIcon, {
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Width of each lane in studs. The bounds adjust so both endpoints stay in place.",
			}),
			LayoutOrder = 2,
			Subject = e(NumberInput, {
				Label = "Lane Width",
				Value = state.LaneWidth,
				ValueEntered = function(value: number): number?
					if value <= 0 then
						return nil
					end
					props.SetSizing("LaneWidth", value)
					return value
				end,
			}),
		}),
		SidewalkWidthInput = e(HelpGui.WithHelpIcon, {
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Width of the raised sidewalk on each side, in studs. Zero removes the sidewalks entirely.",
			}),
			LayoutOrder = 3,
			Subject = e(NumberInput, {
				Label = "Sidewalk Width",
				Value = state.SidewalkWidth,
				ValueEntered = function(value: number): number?
					local width = math.max(value, 0)
					props.SetSizing("SidewalkWidth", width)
					return width
				end,
			}),
		}),
		CornerRadiusInput = if (state :: any).SegmentKind == "Intersection"
			then e(HelpGui.WithHelpIcon, {
				Help = e(HelpGui.BasicTooltip, {
					HelpRichText = "The corner curve radius, controlled through the bounding box size beyond what the roads' widths require. Exact for 90 degree intersections; skewed corners vary around it.",
				}),
				LayoutOrder = 4,
				Subject = e(NumberInput, {
					Label = "Corner Radius",
					Value = (state :: any).CornerRadius,
					ValueEntered = function(value: number): number?
						local radius = math.max(value, 0)
						props.SetSizing("CornerRadius", radius)
						return radius
					end,
				}),
			})
			else nil,
	})
end

local function AddPanel(props: {
	SelectionState: createRoadSession.SelectionState,
	CurrentSettings: Settings.RoadHelperSettings,
	UpdatedSettings: () -> (),
	AddSegment: (kind: RoadMath.SegmentKind) -> (),
	AddIntersection: (throughRoad: boolean) -> (),
	LayoutOrder: number?,
})
	-- With an endpoint selected the add handles in the viewport are the way to
	-- extend the road; the camera-add section only applies when nothing is.
	if props.SelectionState.Kind ~= "none" then
		return nil :: any
	end
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
		AlignToWorld = e(HelpGui.WithHelpIcon, {
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Snap added segments to the nearest world axis instead of following the camera's heading.",
			}),
			LayoutOrder = nextOrder(),
			Subject = e(Checkbox, {
				Label = "Align to world",
				Checked = props.CurrentSettings.AlignToWorld,
				Changed = function(checked: boolean)
					props.CurrentSettings.AlignToWorld = checked
					props.UpdatedSettings()
				end,
			}),
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
		IntersectionButtons = e("Frame", {
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
			TButton = e("Frame", {
				Size = UDim2.new(0.5, -2, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				LayoutOrder = 1,
			}, {
				Button = e(OperationButton, {
					Text = "T Junction",
					Height = 28,
					Disabled = false,
					Color = Colors.ACTION_BLUE,
					OnClick = function()
						props.AddIntersection(false)
					end,
				}),
			}),
			XButton = e("Frame", {
				Size = UDim2.new(0.5, -2, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				LayoutOrder = 2,
			}, {
				Button = e(OperationButton, {
					Text = "X Junction",
					Height = 28,
					Disabled = false,
					Color = Colors.ACTION_BLUE,
					OnClick = function()
						props.AddIntersection(true)
					end,
				}),
			}),
		}),
	})
end

local function PresetTile(props: {
	Preset: Presets.Preset,
	Selected: boolean,
	LayoutOrder: number?,
	OnClick: () -> (),
})
	local preset = props.Preset
	return e("ImageButton", {
		BackgroundColor3 = preset.PlaceholderColor,
		BorderSizePixel = 0,
		Image = preset.Image,
		ImageColor3 = preset.ImageTint or Color3.new(1, 1, 1),
		ScaleType = Enum.ScaleType.Crop,
		AutoButtonColor = true,
		LayoutOrder = props.LayoutOrder,
		[React.Event.MouseButton1Click] = props.OnClick,
	}, {
		Corner = e("UICorner", {
			CornerRadius = UDim.new(0, 6),
		}),
		Stroke = if props.Selected
			then e("UIStroke", {
				Color = Colors.ACTION_BLUE,
				Thickness = 2,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			})
			else nil,
		NameLabel = e("TextLabel", {
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -4),
			Size = UDim2.new(1, -8, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Text = preset.Name,
			TextColor3 = Colors.WHITE,
			TextWrapped = true,
			Font = Enum.Font.SourceSansBold,
			TextSize = 14,
		}, {
			-- A UIStroke outlines the glyphs thicker and more opaque than
			-- the built-in TextStroke can
			Outline = e("UIStroke", {
				Color = Colors.BLACK,
				Thickness = 2,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
			}),
		}),
	})
end

local function PresetsPanel(props: {
	SelectionState: createRoadSession.SelectionState,
	CurrentSettings: Settings.RoadHelperSettings,
	UpdatedSettings: () -> (),
	LayoutOrder: number?,
})
	-- Shown alongside the Add section: presets only affect the add buttons
	if props.SelectionState.Kind ~= "none" then
		return nil :: any
	end
	local tiles: { [string]: any } = {
		Layout = e("UIGridLayout", {
			CellSize = UDim2.new(0.5, -3, 0, 54),
			CellPadding = UDim2.fromOffset(6, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	for index, preset in Presets.List do
		local selected = props.CurrentSettings.SelectedPreset == preset.Key
		tiles[preset.Key] = e(PresetTile, {
			Preset = preset,
			Selected = selected,
			LayoutOrder = index,
			OnClick = function()
				-- Clicking the selected tile deselects it, going back to
				-- inheriting appearance from nearby roads
				props.CurrentSettings.SelectedPreset = if selected then "" else preset.Key
				props.UpdatedSettings()
			end,
		})
	end
	return e(SubPanel, {
		Title = "Preset",
		LayoutOrder = props.LayoutOrder,
	}, {
		Grid = e("Frame", {
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
		}, tiles),
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
	SetSegmentAttribute: (name: string, value: any) -> (),
	SetLaneMarkings: (mode: string) -> (),
	SetSizing: (name: string, value: number) -> (),
	AddSegment: (kind: RoadMath.SegmentKind) -> (),
	AddIntersection: (throughRoad: boolean) -> (),
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
			SetSegmentAttribute = props.SetSegmentAttribute,
			LayoutOrder = nextOrder(),
		}),
		DetailPanel = e(DetailPanel, {
			SelectionState = props.SelectionState,
			SetSegmentAttribute = props.SetSegmentAttribute,
			LayoutOrder = nextOrder(),
		}),
		LaneMarkingsPanel = e(LaneMarkingsPanel, {
			SelectionState = props.SelectionState,
			SetLaneMarkings = props.SetLaneMarkings,
			LayoutOrder = nextOrder(),
		}),
		SizingPanel = e(SizingPanel, {
			SelectionState = props.SelectionState,
			SetSizing = props.SetSizing,
			LayoutOrder = nextOrder(),
		}),
		AddPanel = e(AddPanel, {
			SelectionState = props.SelectionState,
			CurrentSettings = props.CurrentSettings,
			UpdatedSettings = props.UpdatedSettings,
			AddSegment = props.AddSegment,
			AddIntersection = props.AddIntersection,
			LayoutOrder = nextOrder(),
		}),
		PresetsPanel = e(PresetsPanel, {
			SelectionState = props.SelectionState,
			CurrentSettings = props.CurrentSettings,
			UpdatedSettings = props.UpdatedSettings,
			LayoutOrder = nextOrder(),
		}),
		CloseButton = e(CloseButton, {
			HandleAction = props.HandleAction,
			LayoutOrder = nextOrder(),
		}),
	})
end

return RoadHelperGui
