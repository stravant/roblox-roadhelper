# RoadHelper

A Roblox Studio plugin for working with procedural road segments (`ProceduralModel`
instances driven by `StraightRoadGenerator` / `CurveRoadGenerator`). Select road
endpoints in the viewport, then:

- **Move** the endpoint with axis handles — resizes/repositions the segment(s),
  flipping sides automatically when needed.
- **Rotate** the endpoint with arc handles — edits the `AdjustBlue*`/`AdjustRed*`
  dir/grade/bank angles, keeping closed joints continuous.
- **Add** segments off an open endpoint with left/straight/right handles (click for a
  default size, drag to place), or via the panel's Add buttons.

Built on the Redupe plugin's architecture (DraggerFramework handles + React UI).

## Building

```bash
rojo build -p "RoadHelper V1.0.rbxmx"
```
