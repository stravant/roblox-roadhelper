local createSharedToolbar = require(script.Parent.Packages.createSharedToolbar)
local Signal = require(script.Parent.Packages.Signal)

-- Use the toolbar combiner?
local COMBINE_TOOLBAR = false

local RIBBON_ICON = ""
local TOOLTIP = "Activate RoadHelper, for working with the endpoints of procedural road segments."

local setButtonActive: (active: boolean) -> () = nil
local buttonClicked = Signal.new()

if COMBINE_TOOLBAR then
	local toolbarSettings: createSharedToolbar.SharedToolbarSettings = {
		ButtonName = "RoadHelper",
		ButtonTooltip = TOOLTIP,
		ButtonIcon = RIBBON_ICON,
		ToolbarName = "GeomTools",
		CombinerName = "GeomToolsToolbar",
		ClickedFn = function()
			buttonClicked:Fire()
		end,
	}
	createSharedToolbar(plugin, toolbarSettings)
	function setButtonActive(active: boolean)
		assert(toolbarSettings.Button):SetActive(active)
	end
else
	local toolbar = plugin:CreateToolbar("RoadHelper")
	local button = toolbar:CreateButton("openRoadHelper", TOOLTIP, RIBBON_ICON, "RoadHelper")
	local clickCn = button.Click:Connect(function()
		buttonClicked:Fire()
	end)
	function setButtonActive(active: boolean)
		button:SetActive(active)
	end
	plugin.Unloading:Connect(function()
		clickCn:Disconnect()
	end)
end

-- Create the dockable panel
local params = DockWidgetPluginGuiInfo.new(
	Enum.InitialDockState.Float,
	false, -- Is it initially enabled
	false, -- Override the previous state
	240, -- Default width
	220, -- Default height
	240, -- Minimum width
	220  -- Minimum height
)
local panel = plugin:CreateDockWidgetPluginGuiAsync("RoadHelperPanel", params)

local loaded = false
local function doInitialLoad()
	loaded = true
	require(script.Parent.Src.main)(plugin, panel, buttonClicked, setButtonActive)
end

-- Lazy load the main plugin on first click
local clickedCn = buttonClicked:Connect(function()
	if not loaded then
		doInitialLoad()
		-- Refire event now that the plugin is listening
		buttonClicked:Fire()
	end
end)

panel.Title = "RoadHelper"
panel.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
if panel.Enabled then
	doInitialLoad()
end

plugin.Deactivation:Connect(function()
	clickedCn:Disconnect()
end)
