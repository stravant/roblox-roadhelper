local TestTypes = require("./TestTypes")

local ChangeHistoryService = game:GetService("ChangeHistoryService")

--[[
	Ground-truth checks for the undo recording pattern the session uses:
	a TryBeginRecording .. FinishRecording(Commit) pair spanning multiple
	property changes across multiple frames must undo as a single step.
]]

return function(t: TestTypes.TestContext)
	t.test("recording spans multi-frame changes as one undo step", function()
		local part = Instance.new("Part")
		part.Name = "RecordingSpecPart"
		part.Anchored = true
		part.Size = Vector3.new(1, 1, 1)
		part.Parent = workspace
		ChangeHistoryService:SetWaypoint("RecordingSpec Baseline")

		local recording = ChangeHistoryService:TryBeginRecording("RecordingSpec Drag")
		t.expect(recording ~= nil).toBe(true)

		for i = 2, 6 do
			part.Size = Vector3.new(i, i, i)
			task.wait(0.05)
		end
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		t.expect(part.Size).toBe(Vector3.new(6, 6, 6))
		t.expect(ChangeHistoryService:GetCanUndo()).toBe(true)

		-- Step the undo stack, recording each state, until we reach the
		-- original size (or give up). We must reach it in ONE step.
		local undoneNames = {}
		local cn = ChangeHistoryService.OnUndo:Connect(function(name)
			table.insert(undoneNames, name)
		end)
		local steps = 0
		while part.Size ~= Vector3.new(1, 1, 1) and steps < 10 and ChangeHistoryService:GetCanUndo() do
			ChangeHistoryService:Undo()
			task.wait(0.1)
			steps += 1
		end
		cn:Disconnect()
		local reached = part.Size == Vector3.new(1, 1, 1)

		-- Restore and clean up
		for _ = 1, steps do
			ChangeHistoryService:Redo()
			task.wait(0.05)
		end
		part:Destroy()

		if not reached then
			t.fail("Never got back to the original size! Undone: " .. table.concat(undoneNames, " | "))
		end
		if steps ~= 1 then
			t.fail(`Took {steps} undo steps, expected 1. Undone: ` .. table.concat(undoneNames, " | "))
		end
	end)
end
