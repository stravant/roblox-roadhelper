--!strict
local CoreGui = game:GetService("CoreGui")

local Packages = script.Parent.Parent.Packages
local React = require(Packages.React)
local ReactRoblox = require(Packages.ReactRoblox)
local Signal = require(Packages.Signal)

local createRoadSession = require("./createRoadSession")
local Presets = require("./Presets")
local Settings = require("./Settings")
local RoadHelperGui = require("./RoadHelperGui")
local RoadMath = require("./RoadMath")
local PluginGuiTypes = require("./PluginGui/Types")

return function(plugin: Plugin, panel: DockWidgetPluginGui, buttonClicked: Signal.Signal<>, setButtonActive: (active: boolean) -> ())
	local session: createRoadSession.RoadSession? = nil
	local sessionChangedCn: Signal.Connection? = nil

	local active = false
	local pluginActive = false

	local activeSettings = Settings.Load(plugin)

	local reactRoot: ReactRoblox.RootType? = nil
	local reactScreenGui: LayerCollector? = nil

	local handleAction: (string) -> () = nil

	local function destroyReactRoot()
		if reactRoot then
			reactRoot:unmount()
			reactRoot = nil
		end
		if reactScreenGui then
			reactScreenGui:Destroy()
			reactScreenGui = nil
		end
	end
	local function createReactRoot()
		if panel.Enabled then
			reactRoot = ReactRoblox.createRoot(panel)
		else
			local screen = Instance.new("ScreenGui")
			screen.Name = "RoadHelperMainGui"
			screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
			screen.Parent = CoreGui
			reactScreenGui = screen
			reactRoot = ReactRoblox.createRoot(screen)
		end
	end

	local function getGuiState(): PluginGuiTypes.PluginGuiMode
		if not active then
			return "inactive"
		else
			return "active"
		end
	end

	local function updateUI()
		local needsUI = active or panel.Enabled
		if needsUI then
			if not reactRoot then
				createReactRoot()
			elseif panel.Enabled and reactScreenGui ~= nil then
				-- Moved to panel, need to destroy old gui and recreate root
				destroyReactRoot()
				createReactRoot()
			elseif not panel.Enabled and reactScreenGui == nil then
				-- Moved to screen gui, need to destroy old gui and recreate root
				destroyReactRoot()
				createReactRoot()
			end

			assert(reactRoot, "We just created it")
			reactRoot:render(React.createElement(RoadHelperGui, {
				GuiState = getGuiState(),
				SelectionState = if session then session.GetSelectionState() else { Kind = "none" :: "none" },
				SetAdjustValue = function(axis: RoadMath.AdjustAxis, value: number)
					if session then
						session.SetAdjustValue(axis, value)
					end
				end,
				SetBlend = function(value: boolean)
					if session then
						session.SetBlend(value)
					end
				end,
				SetSegmentAttribute = function(name: string, value: any)
					if session then
						session.SetSegmentAttribute(name, value)
					end
				end,
				SetSizing = function(name: string, value: number)
					if session then
						session.SetSizing(name, value)
					end
				end,
				AddSegment = function(kind: RoadMath.SegmentKind)
					if session then
						local preset = Presets.ByKey[activeSettings.SelectedPreset]
						session.AddInFrontOfCamera(
							kind,
							activeSettings.AlignToWorld,
							if preset then preset.Attributes else nil
						)
					end
				end,
				AddIntersection = function(throughRoad: boolean)
					if session then
						local preset = Presets.ByKey[activeSettings.SelectedPreset]
						session.AddIntersectionInFrontOfCamera(
							throughRoad,
							activeSettings.AlignToWorld,
							if preset then preset.Attributes else nil
						)
					end
				end,
				CurrentSettings = activeSettings,
				UpdatedSettings = updateUI,
				HandleAction = handleAction,
				Panelized = panel.Enabled,
			}))
		elseif reactRoot then
			destroyReactRoot()
		end
	end

	local function destroySession()
		if sessionChangedCn then
			sessionChangedCn:Disconnect()
			sessionChangedCn = nil
		end
		if session then
			session.Destroy()
			session = nil
		end
	end

	local function setActive(newActive: boolean)
		if active == newActive then
			return
		end
		setButtonActive(newActive)
		active = newActive
		if newActive then
			local newSession = createRoadSession(plugin)
			sessionChangedCn = newSession.ChangeSignal:Connect(updateUI)
			session = newSession
			if not pluginActive then
				plugin:Activate(true)
				pluginActive = true
			end
		else
			destroySession()
		end
		updateUI()
	end

	local function closeRequested()
		setActive(false)
		plugin:Deactivate()
	end

	function handleAction(action: string)
		if action == "cancel" then
			closeRequested()
		elseif action == "reset" then
			setActive(true)
		elseif action == "togglePanelized" then
			panel.Enabled = not panel.Enabled
			updateUI()
		else
			warn("Unknown action: " .. action)
		end
	end

	local clickedCn = buttonClicked:Connect(function()
		if active then
			closeRequested()
		else
			setActive(true)
		end
	end)

	-- Initial UI show in the case where we're in Panelized mode
	updateUI()

	-- When the user selects a different tool, stop doing anything
	plugin.Deactivation:Connect(function()
		pluginActive = false
		setActive(false)
	end)

	plugin.Unloading:Connect(function()
		destroySession()
		setActive(false)
		destroyReactRoot()
		Settings.Save(plugin, activeSettings)
		clickedCn:Disconnect()
	end)
end
