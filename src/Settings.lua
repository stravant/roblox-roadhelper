local InitialPosition = Vector2.new(24, 24)
local kSettingsKey = "roadHelperState"

local PluginGuiTypes = require("./PluginGui/Types")

export type RoadHelperSettings = PluginGuiTypes.PluginGuiSettings & {
	AlignToWorld: boolean,
	SelectedPreset: string,
}

local function loadSettings(plugin: Plugin): RoadHelperSettings
	local raw = plugin:GetSetting(kSettingsKey) or {}
	return {
		WindowPosition = Vector2.new(
			raw.WindowPositionX or InitialPosition.X,
			raw.WindowPositionY or InitialPosition.Y
		),
		WindowAnchor = Vector2.new(
			raw.WindowAnchorX or 0,
			raw.WindowAnchorY or 0
		),
		WindowHeightDelta = if raw.WindowHeightDelta ~= nil then raw.WindowHeightDelta else 0,
		HaveHelp = if raw.HaveHelp ~= nil then raw.HaveHelp else true,
		DoneTutorial = if raw.DoneTutorial ~= nil then raw.DoneTutorial else false,
		AlignToWorld = if raw.AlignToWorld ~= nil then raw.AlignToWorld else true,
		SelectedPreset = if raw.SelectedPreset ~= nil then raw.SelectedPreset else "",
	}
end

local function saveSettings(plugin: Plugin, settings: RoadHelperSettings)
	plugin:SetSetting(kSettingsKey, {
		WindowPositionX = settings.WindowPosition.X,
		WindowPositionY = settings.WindowPosition.Y,
		WindowAnchorX = settings.WindowAnchor.X,
		WindowAnchorY = settings.WindowAnchor.Y,
		WindowHeightDelta = settings.WindowHeightDelta,
		HaveHelp = settings.HaveHelp,
		DoneTutorial = settings.DoneTutorial,
		AlignToWorld = settings.AlignToWorld,
		SelectedPreset = settings.SelectedPreset,
	})
end

return {
	Load = loadSettings,
	Save = saveSettings,
}
