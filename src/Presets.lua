--!strict
--[[
	Appearance presets for newly added road segments, shown as image tiles in
	the Presets section of the panel. Selecting one applies its attributes to
	segments created with the Add Straight/Curve buttons; with none selected,
	new segments inherit their appearance from the selection or the nearest
	segment as usual.

	Image is the tile picture (screenshot of the preset); PlaceholderColor
	shows while an image id hasn't been provided yet.
]]

export type Preset = {
	Key: string,
	Name: string,
	Image: string,
	PlaceholderColor: Color3,
	Attributes: { [string]: any },
}

local List: { Preset } = {
	{
		Key = "Classic",
		Name = "Classic Roblox",
		Image = "rbxassetid://84342795346543",
		PlaceholderColor = Color3.fromRGB(26, 42, 52),
		-- The ProceduralModel generator defaults
		Attributes = {
			LaneWidth = 24,
			LaneCount = 2,
			SidewalkWidth = 8,
			TextureLaneMarkings = false,
			HaveLaneMarkings = true,
			RoadMaterial = Enum.Material.Concrete,
			RoadColor = Color3.fromRGB(26, 42, 52),
			SidewalkColor = Color3.fromRGB(163, 162, 165),
			CenterlineColor = Color3.fromRGB(244, 205, 47),
			LaneMarkingColor = Color3.fromRGB(163, 161, 165),
		},
	},
	{
		Key = "Dirt",
		Name = "Dirt Road",
		Image = "rbxassetid://108785564035719",
		PlaceholderColor = Color3.fromRGB(104, 60, 30),
		-- Single unmarked lane of dirt, no sidewalks; the blend skirt (off by
		-- default) is dirt as well rather than the usual grass
		Attributes = {
			LaneWidth = 24,
			LaneCount = 1,
			SidewalkWidth = 0,
			TextureLaneMarkings = false,
			HaveLaneMarkings = false,
			RoadMaterial = Enum.Material.Ground,
			RoadColor = Color3.fromRGB(104, 60, 30),
			SidewalkColor = Color3.fromRGB(104, 60, 30),
			BlendMaterial = Enum.Material.Ground,
			BlendColor = Color3.fromRGB(104, 60, 30),
		},
	},
	{
		Key = "RealisticSidewalk",
		Name = "Real, Sidewalk",
		Image = "rbxassetid://94872746387137",
		PlaceholderColor = Color3.fromRGB(20, 20, 22),
		-- Black asphalt, white edge/divider lines, saturated yellow center
		Attributes = {
			LaneWidth = 24,
			LaneCount = 2,
			SidewalkWidth = 8,
			TextureLaneMarkings = true,
			HaveLaneMarkings = true,
			-- Asphalt renders fairly light, so it needs a pure black tint
			RoadMaterial = Enum.Material.Asphalt,
			RoadColor = Color3.fromRGB(0, 0, 0),
			SidewalkColor = Color3.fromRGB(163, 162, 165),
			CenterlineColor = Color3.fromRGB(255, 191, 0),
			LaneMarkingColor = Color3.fromRGB(235, 235, 235),
		},
	},
	{
		Key = "RealisticOpen",
		Name = "Real, no Sidewalk",
		Image = "rbxassetid://85463536875783",
		PlaceholderColor = Color3.fromRGB(28, 28, 30),
		Attributes = {
			LaneWidth = 24,
			LaneCount = 2,
			SidewalkWidth = 0,
			TextureLaneMarkings = true,
			HaveLaneMarkings = true,
			-- Asphalt renders fairly light, so it needs a pure black tint
			RoadMaterial = Enum.Material.Asphalt,
			RoadColor = Color3.fromRGB(0, 0, 0),
			SidewalkColor = Color3.fromRGB(163, 162, 165),
			CenterlineColor = Color3.fromRGB(255, 191, 0),
			LaneMarkingColor = Color3.fromRGB(235, 235, 235),
		},
	},
	{
		Key = "Cobblestone",
		Name = "Cobblestone Path",
		Image = "rbxassetid://122561563144022",
		PlaceholderColor = Color3.fromRGB(132, 123, 111),
		Attributes = {
			LaneWidth = 16,
			LaneCount = 1,
			SidewalkWidth = 0,
			TextureLaneMarkings = false,
			HaveLaneMarkings = false,
			RoadMaterial = Enum.Material.Cobblestone,
			RoadColor = Color3.fromRGB(132, 123, 111),
			SidewalkColor = Color3.fromRGB(132, 123, 111),
		},
	},
	{
		Key = "Pebble",
		Name = "Pebble Path",
		Image = "rbxassetid://119185543748250",
		PlaceholderColor = Color3.fromRGB(140, 140, 136),
		Attributes = {
			LaneWidth = 16,
			LaneCount = 1,
			SidewalkWidth = 0,
			TextureLaneMarkings = false,
			HaveLaneMarkings = false,
			RoadMaterial = Enum.Material.Pebble,
			RoadColor = Color3.fromRGB(140, 140, 136),
			SidewalkColor = Color3.fromRGB(140, 140, 136),
		},
	},
}

local ByKey: { [string]: Preset } = {}
for _, preset in List do
	ByKey[preset.Key] = preset
end

return {
	List = List,
	ByKey = ByKey,
}
