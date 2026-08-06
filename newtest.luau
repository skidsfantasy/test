-- Live perfect-hold analyzer and automatic release controller for the game's
-- existing Aero Shoot signal.
--
-- This controller is input-agnostic. It begins from the game's Shoot=true
-- signal and controls the matching Shoot=false signal, regardless of whether
-- the source was a keyboard key, controller binding, touch button, or script.
--
-- Paired jumpshot animations:
--   animationBaseline =
--       PauseMarkerTime / ShotSpeed
--       + abs(ReleaseKeyframeTime - PauseMarkerTime) / 2.5
--
-- Single-track shots (moving, fade, close, layup, floater, post, etc.):
--   animationBaseline = ReleaseMarkerTime / ShotSpeed
--
-- The formula-only fallback interval starts from Shoot=true itself:
--   serverHoldFallback = animationBaseline
--
-- Primary auto-release reads RegisterPacket's actual greenEnd, derives the
-- Vertical meter's real green band from Config.Meters.Vertical.GetGreenWindow,
-- converts its center into FillGradient.Offset coordinates, and releases at the
-- interpolated live meter crossing. The animation formula is only a watchdog
-- fallback if meter replication stalls.
--
-- The printed expected remote hold is an animation diagnostic. The direct meter
-- crossing and literal Shoot=false minus Shoot=true duration are deterministic
-- on the client; network jitter can still affect when the server receives them.
--
-- Auto-release behavior:
--   * Shoot=true is never delayed or replaced.
--   * Any early input-generated Shoot=false is held until the meter crossing.
--   * If the input remains held, one synthetic Shoot=false is sent there.
--   * A later duplicate false is consumed, so exactly one false is forwarded.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local AnimationClipProvider = game:GetService("AnimationClipProvider")
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")

local player = Players.LocalPlayer
local environment = getgenv()

local oldMonitor = rawget(environment, "__PerfectHoldMonitor")
if type(oldMonitor) == "table" and type(rawget(oldMonitor, "Stop")) == "function" then
	pcall(function()
		oldMonitor:Stop()
	end)
end

local function isLiveAero(candidate)
	return type(candidate) == "table"
		and type(rawget(candidate, "Controllers")) == "table"
		and type(rawget(candidate, "Services")) == "table"
		and rawget(candidate, "Player") == player
		and candidate.Services.InputService ~= nil
		and candidate.Services.InputService.Shoot ~= nil
		and type(candidate.Services.InputService.Shoot.Fire) == "function"
end

local function findAero()
	local cached = rawget(environment, "__PerfectHoldAero")
	if isLiveAero(cached) then
		return cached
	end

	local runtimeEnvironment = getrenv()
	local runtimeGlobal = type(runtimeEnvironment) == "table"
		and rawget(runtimeEnvironment, "_G")
		or nil
	local globalAero = type(runtimeGlobal) == "table"
		and rawget(runtimeGlobal, "Aero")
		or nil
	if isLiveAero(globalAero) then
		environment.__PerfectHoldAero = globalAero
		return globalAero
	end

	local deadline = os.clock() + 2
	repeat
		for _, object in ipairs(getgc(true)) do
			if isLiveAero(object) then
				environment.__PerfectHoldAero = object
				return object
			end
		end
		task.wait()
	until os.clock() >= deadline

	error("[PerfectHold] Could not find the live Aero client table")
end

local aero = findAero()
local shootSignal = aero.Services.InputService.Shoot
local originalFire = shootSignal.Fire

local shootingAnimations = ReplicatedStorage
	:WaitForChild("Assets")
	:WaitForChild("Animations")
	:WaitForChild("Server")
	:WaitForChild("Shooting")

local animationsByName = {}
for _, object in ipairs(shootingAnimations:GetDescendants()) do
	if object:IsA("Animation") then
		animationsByName[object.Name] = object
	end
end

local timingNames = {
	"Very Early",
	"Early",
	"Slightly Early",
	"Good",
	"Perfect",
	"Slightly Late",
	"Late",
	"Very Late",
}

local animationMetadataCache = {}

local monitor = {
	Connections = {},
	ActiveShot = nil,
	History = {},
	OriginalFire = originalFire,
	ShootSignal = shootSignal,
	Stopped = false,
	AutoReleaseEnabled = true,
	HighPrecision = true,
	ReleaseBias = 0.020,
	MeterSyncEnabled = true,
	MeterTargetY = -1.405,
	MeterGeometryLeadY = 0,
	MeterTransitScale = 0.25,
	MeterGreenAimFraction = 0.5,
	MeterTriggerDelay = 0,
	MeterFallbackGrace = 1.5,
	FrameDuration = 1 / 60,
	RecentFrameDuration = 1 / 60,
	MaxSpinTime = 0.065,
	ShotIndex = 0,
	PacketIndex = 0,
}

local function autoActiveForShot(shot)
	return monitor.AutoReleaseEnabled
		and shot.AutoEligible
		and not shot.AutoCancelled
end

local function getCharacter()
	local characters = workspace:FindFirstChild("Characters")
	return characters and characters:FindFirstChild(player.Name)
end

local function minNumber(oldValue, newValue)
	if type(newValue) ~= "number" then
		return oldValue
	end
	if oldValue == nil or newValue < oldValue then
		return newValue
	end
	return oldValue
end

local function parseSequence(sequence)
	local metadata = {
		Markers = {},
		NamedRelease = nil,
		KeyframeCount = 0,
	}

	for _, keyframe in ipairs(sequence:GetKeyframes()) do
		metadata.KeyframeCount += 1

		if keyframe.Name == "Release" then
			metadata.NamedRelease = minNumber(
				metadata.NamedRelease,
				keyframe.Time
			)
		end

		for _, marker in ipairs(keyframe:GetMarkers()) do
			metadata.Markers[marker.Name] = minNumber(
				metadata.Markers[marker.Name],
				keyframe.Time
			)
		end
	end

	return metadata
end

local function loadAnimationMetadata(animation)
	local cacheKey = animation.AnimationId
	if animationMetadataCache[cacheKey] then
		return animationMetadataCache[cacheKey]
	end

	-- getObjects returns a fresh sequence. This avoids the Roblox providers'
	-- shared cached Instance being poisoned by another script calling :Destroy().
	local objectLoadError
	for attempt = 1, 3 do
		local previousIdentity
		pcall(function()
			previousIdentity = getthreadidentity()
			if previousIdentity < 8 then
				setthreadidentity(8)
			end
		end)
		local okObjects, objects = pcall(function()
			return game:GetObjects(animation.AnimationId)
		end)
		if previousIdentity then
			pcall(setthreadidentity, previousIdentity)
		end

		if okObjects
			and type(objects) == "table"
			and objects[1]
			and objects[1].GetKeyframes
		then
			local sequence = objects[1]
			local okParse, metadata = pcall(parseSequence, sequence)
			pcall(function()
				sequence:Destroy()
			end)
			if okParse and metadata.KeyframeCount > 0 then
				animationMetadataCache[cacheKey] = metadata
				return metadata
			end
			objectLoadError = okParse
				and "fresh sequence contained no keyframes"
				or tostring(metadata)
		else
			objectLoadError = okObjects
				and "GetObjects returned no sequence"
				or tostring(objects)
		end

		if attempt < 3 then
			task.wait(0.05)
		end
	end

	for _, loader in ipairs({
		function()
			return AnimationClipProvider:GetAnimationClipAsync(animation.AnimationId)
		end,
		function()
			return KeyframeSequenceProvider:GetKeyframeSequenceAsync(animation.AnimationId)
		end,
	}) do
		local ok, sequence = pcall(loader)
		if ok and sequence and sequence.GetKeyframes then
			local metadata = parseSequence(sequence)
			-- Provider results are shared cached Instances. Never destroy them.
			if metadata.KeyframeCount > 0 then
				animationMetadataCache[cacheKey] = metadata
				return metadata
			end
		end
	end

	return nil, (
		"animation metadata could not be loaded for %s (%s)"
	):format(animation.Name, tostring(objectLoadError))
end

-- Warm every animation that can supply a timing cue while this file still has
-- executor identity. Base clips never supply the cue themselves; paired shots
-- use their matching Release clip. Doing this before installing the wrapper
-- keeps first-use asset loading off the shot's critical timing path.
local warmedAnimationCount = 0
for name, animation in pairs(animationsByName) do
	if not name:match("Base$") then
		local cacheKey = animation.AnimationId
		local wasCached = animationMetadataCache[cacheKey] ~= nil
		local ok, metadata = pcall(loadAnimationMetadata, animation)
		if not wasCached and ok and metadata then
			warmedAnimationCount += 1
		end
	end
end

local function resolveTiming(baseAnimationName, shotSpeed)
	if type(baseAnimationName) ~= "string" or baseAnimationName == "" then
		return nil, "BaseAnimation is missing"
	end
	if type(shotSpeed) ~= "number" or shotSpeed <= 0 then
		return nil, "ShotSpeed is invalid"
	end

	local paired = baseAnimationName:match("Base$") ~= nil
	local timingAnimationName = paired
		and baseAnimationName:gsub("Base$", "Release")
		or baseAnimationName
	local animation = animationsByName[timingAnimationName]
	if not animation then
		return nil, ("animation asset %s was not found"):format(timingAnimationName)
	end

	local metadata, metadataError = loadAnimationMetadata(animation)
	if not metadata then
		return nil, metadataError
	end

	if paired then
		local pauseTime = metadata.Markers.Pause
		local releaseTime = metadata.NamedRelease
		if type(pauseTime) ~= "number" then
			return nil, ("%s has no Pause marker"):format(timingAnimationName)
		end
		if type(releaseTime) ~= "number" then
			return nil, ("%s has no named Release keyframe"):format(
				timingAnimationName
			)
		end

		local firstLeg = pauseTime / shotSpeed
		local releaseLeg = math.abs(releaseTime - pauseTime) / 2.5
		return {
			AnimationName = timingAnimationName,
			AnimationBaseline = firstLeg + releaseLeg,
			CueDescription = (
				"Pause %.9f / %.9f + |Release %.9f - Pause| / 2.5"
			):format(pauseTime, shotSpeed, releaseTime),
			PauseTime = pauseTime,
			ReleaseTime = releaseTime,
			Mode = "paired jumpshot",
		}
	end

	local releaseTime = metadata.Markers.Release or metadata.NamedRelease
	local cueKind = metadata.Markers.Release and "Release marker"
		or "Release keyframe fallback"
	if type(releaseTime) ~= "number" then
		return nil, ("%s has no Release cue"):format(timingAnimationName)
	end

	return {
		AnimationName = timingAnimationName,
		AnimationBaseline = releaseTime / shotSpeed,
		CueDescription = ("%s %.9f / %.9f"):format(
			cueKind,
			releaseTime,
			shotSpeed
		),
		ReleaseTime = releaseTime,
		Mode = "single track",
	}
end

local function getGoal(character)
	local ok, packet = pcall(function()
		return aero.Controllers.Attributes:Get(character)
	end)
	if ok and type(packet) == "table" and typeof(packet.Goal) == "Instance" then
		return packet.Goal
	end

	local attributes = character and character:FindFirstChild("Attributes")
	local goalValue = attributes and attributes:FindFirstChild("Goal")
	if goalValue and goalValue:IsA("ObjectValue") then
		return goalValue.Value
	end

	return nil
end

local function horizontalDistance(character, goal)
	if not character or typeof(goal) ~= "Instance" or not goal:IsA("BasePart") then
		return nil
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil
	end

	return ((root.Position - goal.Position) * Vector3.new(1, 0, 1)).Magnitude
end

local function printFeedback(shot)
	if shot.FeedbackPrinted or not shot.Feedback then
		return
	end
	if not shot.ActualPrinted then
		return
	end

	shot.FeedbackPrinted = true
	print(("[PerfectHold #%d] Server result: %s Release"):format(
		shot.Id,
		shot.Feedback
	))
end

local function printActual(shot)
	if shot.ActualPrinted or not shot.Ended or not shot.ExpectedPrinted then
		return
	end

	shot.ActualPrinted = true
	local actualRemote = shot.RemoteEndLocal - shot.RemoteStartLocal

	if shot.AutoReleased then
		shot.ActualEffectiveHold = actualRemote
		print((
			"[PerfectHold #%d] Actual enforced shoot-remote hold: %.9f s"
		):format(shot.Id, shot.ActualEffectiveHold))
		print((
			"[PerfectHold #%d] Auto-release target=%.9f s"
			.. " | actual=%.9f s | scheduler error=%+.3f ms"
			.. " | source=%s"
		):format(
			shot.Id,
			shot.ExpectedServerHold,
			actualRemote,
			(actualRemote - shot.ExpectedServerHold) * 1000,
			tostring(shot.ReleaseSource)
		))
	else
		print(("[PerfectHold #%d] Actual shoot-remote hold: %.9f s"):format(
			shot.Id,
			shot.RemoteEndLocal - shot.RemoteStartLocal
		))
	end

	local diagnostic = (
		"[PerfectHold #%d] animation baseline=%.9f s"
		.. " | server target=%.9f s"
		.. " | remote actual=%.9f s"
		.. " | mode=%s | %s"
		.. " | ShotSpeed=%.9f | BaseAnimation=%s"
	):format(
		shot.Id,
		shot.Timing.AnimationBaseline,
		shot.ExpectedServerHold,
		actualRemote,
		shot.Timing.Mode,
		shot.Timing.CueDescription,
		shot.ShotSpeed,
		shot.BaseAnimation
	)

	local comparedHold = shot.ActualEffectiveHold or actualRemote
	if comparedHold then
		diagnostic ..= (" | remote delta=%+.9f s"):format(
			comparedHold - shot.ExpectedServerHold
		)
	end
	if shot.RemoteEndServer then
		local releaseRTT = shot.ReleaseRTT or player:GetNetworkPing()
		shot.EstimatedActualServerHold = (
			actualRemote
			+ releaseRTT
			- shot.StartRTT
		)
		diagnostic ..= (" | estimated server actual=%.9f s"):format(
			shot.EstimatedActualServerHold
		)
	end
	if shot.AppliedReleaseBias and shot.AppliedReleaseBias ~= 0 then
		diagnostic ..= (" | calibration bias=%+.3f ms"):format(
			shot.AppliedReleaseBias * 1000
		)
	end
	if typeof(shot.ReleaseMeterOffset) == "Vector2" then
		diagnostic ..= (" | release meter=(%.6f, %.6f)"):format(
			shot.ReleaseMeterOffset.X,
			shot.ReleaseMeterOffset.Y
		)
	end
	if shot.Distance then
		diagnostic ..= (" | distance=%.3f studs"):format(shot.Distance)
	end
	if shot.GreenEndNormalized then
		diagnostic ..= (" | green endpoint=%.9f normalized"):format(
			shot.GreenEndNormalized
		)
	end
	if shot.DirectMeterTargetY then
		diagnostic ..= (
			" | direct meter target Y=%.9f"
			.. " (raw %.9f)"
		):format(
			shot.DirectMeterTargetY,
			shot.RawDirectMeterTargetY
		)
	end
	if shot.DirectMeterEndpointY then
		diagnostic ..= (
			" | actual bar endpoint Y=%.9f"
			.. " | green band=[%.9f, %.9f]"
			.. " | aim=%.9f"
		):format(
			shot.DirectMeterEndpointY,
			shot.GreenStartNormalized,
			shot.GreenEndNormalized,
			shot.GreenAimNormalized
		)
	end
	if shot.MeterTransitTime then
		diagnostic ..= (
			" | meter transit=%.3f ms"
			.. " | observed send Y=%.9f"
		):format(
			shot.MeterTransitTime * 1000,
			shot.PredictedObservedSendY
		)
	end

	print(diagnostic)
	printFeedback(shot)
end

local function printExpected(shot)
	if shot.ExpectedPrinted then
		return
	end

	shot.ExpectedPrinted = true

	print((
		"[PerfectHold #%d] Formula fallback shoot-remote hold: %.9f s"
	):format(shot.Id, shot.ExpectedServerHold))

	printActual(shot)
end

local autoFalsePayload = {
	Shoot = false,
}

local function recordRemoteEnd(shot, eventLocal, eventServer, source)
	if shot.Ended then
		return false
	end

	shot.RemoteEndLocal = eventLocal
	shot.RemoteEndServer = eventServer
	shot.ReleaseSource = source
	shot.Ended = true

	if shot.ReleaseDeadlineLocal then
		shot.SchedulerError = eventLocal - shot.ReleaseDeadlineLocal
	end

	task.defer(printActual, shot)
	return true
end

local function transmitRelease(shot, source)
	if monitor.Stopped
		or shot.Ended
		or shot.ReleaseCommitted
		or shot.Superseded
	then
		return false
	end

	-- Luau is non-preemptive. Commit before Fire so the timer, an input-generated
	-- release, and the watchdog can never forward duplicate false packets.
	shot.ReleaseCommitted = true
	shot.ReleaseState = "sending"

	local eventLocal = os.clock()
	local payload = shot.PendingReleasePayload or autoFalsePayload
	local ok, releaseError = pcall(
		originalFire,
		shootSignal,
		payload
	)
	local eventServer = workspace:GetServerTimeNow()

	if not ok then
		shot.ReleaseCommitted = false
		shot.ReleaseState = "failed"
		warn(("[PerfectHold #%d] Auto-release failed: %s"):format(
			shot.Id,
			tostring(releaseError)
		))
		return false
	end

	shot.ReleaseState = "sent"
	shot.AutoReleased = true
	shot.ReleaseRTT = player:GetNetworkPing()
	local character = getCharacter()
	if character then
		shot.ReleaseMeterOffset = character:GetAttribute("meterOffset")
		shot.ReleaseMeterRotation = character:GetAttribute("meterRotation")
	end
	recordRemoteEnd(shot, eventLocal, eventServer, source)

	if not shot.NaturalFalseSeen then
		monitor.PendingAutoShot = shot
	end

	return true
end

local function waitForReleaseDeadline(shot, token)
	while not monitor.Stopped
		and autoActiveForShot(shot)
		and not shot.Ended
		and not shot.Superseded
		and shot.ReleaseToken == token
	do
		local remaining = shot.ReleaseDeadlineLocal - os.clock()
		if remaining <= 0 then
			break
		end

		if not monitor.HighPrecision then
			task.wait(remaining)
		else
			local spinWindow = math.clamp(
				math.max(
					monitor.FrameDuration * 1.5,
					monitor.RecentFrameDuration * 1.25
				),
				0.008,
				monitor.MaxSpinTime
			)

			if remaining > spinWindow then
				task.wait(remaining - spinWindow)
			else
				-- A short final spin avoids an entire extra scheduler frame.
				-- It is capped by MaxSpinTime and never spans the whole shot.
				repeat
					remaining = shot.ReleaseDeadlineLocal - os.clock()
				until (
					remaining <= 0
					or monitor.Stopped
					or not autoActiveForShot(shot)
					or shot.Ended
					or shot.Superseded
					or shot.ReleaseToken ~= token
				)
				break
			end
		end
	end

	if not monitor.Stopped
		and autoActiveForShot(shot)
		and not shot.Ended
		and not shot.Superseded
		and shot.ReleaseToken == token
	then
		transmitRelease(shot, "predicted target")
	end
end

local function armAutoRelease(shot)
	if not autoActiveForShot(shot)
		or shot.Ended
		or shot.Superseded
	then
		return
	end

	shot.TargetResolved = true
	shot.ReleaseState = "armed"
	shot.NominalReleaseDeadlineLocal = (
		shot.RemoteStartLocal + shot.ExpectedServerHold
	)
	shot.ReleaseDeadlineLocal = (
		shot.NominalReleaseDeadlineLocal
		+ (
			monitor.MeterSyncEnabled
				and monitor.MeterFallbackGrace
				or 0
		)
	)
	shot.ReleaseToken = {}
	local token = shot.ReleaseToken

	if os.clock() >= shot.ReleaseDeadlineLocal then
		transmitRelease(shot, "late-resolve immediate release")
		return
	end

	task.spawn(waitForReleaseDeadline, shot, token)
end

local function resolveShot(shot)
	local deadline = os.clock() + 1.25
	local character
	local shotStartTime
	local baseAnimation
	local shotSpeed

	repeat
		if monitor.Stopped or shot.Superseded then
			return
		end

		character = getCharacter()
		shotStartTime = character and character:GetAttribute("ShotStartTime")

		if character
			and type(shotStartTime) == "number"
			and shotStartTime ~= shot.PreviousShotStartTime
		then
			-- The timestamp may replicate one event before the other shot fields.
			RunService.Heartbeat:Wait()
			if character == getCharacter()
				and character:GetAttribute("ShotStartTime") == shotStartTime
			then
				baseAnimation = character:GetAttribute("BaseAnimation")
				shotSpeed = character:GetAttribute("ShotSpeed")
				if type(baseAnimation) == "string"
					and type(shotSpeed) == "number"
					and shotSpeed > 0
				then
					break
				end
			end
		end

		task.wait()
	until os.clock() >= deadline

	if not character
		or type(shotStartTime) ~= "number"
		or shotStartTime == shot.PreviousShotStartTime
		or type(baseAnimation) ~= "string"
		or type(shotSpeed) ~= "number"
		or shotSpeed <= 0
	then
		shot.Rejected = true
		if autoActiveForShot(shot) and not shot.Ended then
			transmitRelease(shot, "rejected-shot failsafe")
		end
		if monitor.ActiveShot == shot then
			monitor.ActiveShot = nil
		end
		if shot.Ended then
			warn((
				"[PerfectHold #%d] Shoot=true was not accepted as a shot;"
				.. " no timing target is available"
			):format(shot.Id))
		end
		return
	end

	shot.ServerShotStartTime = shotStartTime
	shot.Accepted = true
	shot.BaseAnimation = baseAnimation
	shot.ShotSpeed = shotSpeed
	shot.Distance = horizontalDistance(character, getGoal(character))

	local timing, timingError = resolveTiming(baseAnimation, shotSpeed)
	if not timing then
		warn(("[PerfectHold #%d] %s"):format(shot.Id, tostring(timingError)))
		if autoActiveForShot(shot) and not shot.Ended then
			transmitRelease(shot, "timing-resolution failsafe")
		end
		return
	end

	shot.Timing = timing
	-- The watchdog is anchored to the already-observed Shoot=true remote, so it
	-- remains device-independent as well.
	shot.InputDelay = 0
	shot.FormulaServerHold = math.max(
		0,
		timing.AnimationBaseline - shot.InputDelay
	)
	shot.AppliedReleaseBias = monitor.ReleaseBias
	shot.ExpectedServerHold = math.max(
		0,
		shot.FormulaServerHold + shot.AppliedReleaseBias
	)
	shot.TargetRTT = player:GetNetworkPing()

	shot.TargetResolved = true
	armAutoRelease(shot)
	task.defer(printExpected, shot)
end

local function gradientDirection(rotation)
	local radians = math.rad(rotation)
	return Vector2.new(math.cos(radians), math.sin(radians))
end

local function gradientSpanPixels(gradient, direction)
	local size = gradient.Parent.AbsoluteSize
	local xSpan = math.abs(direction.X) > 0.000001
		and size.X / math.abs(direction.X)
		or math.huge
	local ySpan = math.abs(direction.Y) > 0.000001
		and size.Y / math.abs(direction.Y)
		or math.huge
	return math.min(xSpan, ySpan)
end

local function getFillBoundaryTime(fillGradient)
	for _, keypoint in ipairs(fillGradient.Transparency.Keypoints) do
		if keypoint.Time > 0 and keypoint.Value >= 0.99 then
			return keypoint.Time
		end
	end
	return nil
end

local function computeDirectMeterTarget(character, meterType, greenEnd)
	if meterType ~= "Vertical" or type(greenEnd) ~= "number" then
		return nil
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	local head = character:FindFirstChild("Head")
	local meter = (root and root:FindFirstChild(meterType .. "Meter"))
		or (head and head:FindFirstChild(meterType .. "Meter"))
	if not meter then
		return nil
	end

	local fillGradient = meter:FindFirstChild("FillGradient", true)
	local greenObject = meter:FindFirstChild("Meter_Green", true)
	local greenGradient = greenObject
		and greenObject:FindFirstChildWhichIsA("UIGradient", true)
	if not fillGradient
		or not fillGradient:IsA("UIGradient")
		or not greenGradient
	then
		return nil
	end

	local fillDirection = gradientDirection(fillGradient.Rotation)
	local greenDirection = gradientDirection(greenGradient.Rotation)
	if fillDirection:Dot(greenDirection) > -0.95 then
		return nil
	end

	local fillBoundaryTime = getFillBoundaryTime(fillGradient)
	if not fillBoundaryTime or math.abs(fillDirection.Y) < 0.000001 then
		return nil
	end

	local fillSize = fillGradient.Parent.AbsoluteSize
	local greenSize = greenGradient.Parent.AbsoluteSize
	if fillSize.X <= 0
		or fillSize.Y <= 0
		or greenSize.X <= 0
		or greenSize.Y <= 0
	then
		return nil
	end

	local fillSpan = gradientSpanPixels(fillGradient, fillDirection)
	local greenSpan = gradientSpanPixels(greenGradient, greenDirection)
	local greenOffset = greenGradient.Offset
	local fillOffset = fillGradient.Offset
	local fillBase = (
		(fillBoundaryTime - 0.5) * fillSpan
		+ fillOffset.X * fillSize.X * fillDirection.X
	)

	local function targetYForGreenPoint(point)
		local greenAxis = (
			(point - 0.5) * greenSpan
			+ greenOffset.X * greenSize.X * greenDirection.X
			+ greenOffset.Y * greenSize.Y * greenDirection.Y
		)
		return (
			(-greenAxis - fillBase)
			/ (fillSize.Y * fillDirection.Y)
		)
	end

	-- The Vertical meter's server value is the fading edge of its green band.
	-- Read the other edge from the meter's own generated transparency sequence
	-- instead of assuming that greenEnd is a single ideal point.
	local greenStart = greenEnd
	local ok, generatedWindow = pcall(function()
		return aero.Modules.Config.Meters[meterType].GetGreenWindow(greenEnd)
	end)
	if ok and typeof(generatedWindow) == "NumberSequence" then
		for _, keypoint in ipairs(generatedWindow.Keypoints) do
			if keypoint.Time <= greenEnd
				and keypoint.Value <= 0.01
				and keypoint.Time < greenEnd
			then
				greenStart = math.max(
					greenStart == greenEnd and 0 or greenStart,
					keypoint.Time
				)
			end
		end
	end
	if greenStart > greenEnd then
		greenStart = greenEnd
	end

	local aimPoint = greenStart + (
		greenEnd - greenStart
	) * monitor.MeterGreenAimFraction
	local rawTargetY = targetYForGreenPoint(aimPoint)
	local endpointY = targetYForGreenPoint(greenEnd)
	return rawTargetY,
		rawTargetY + monitor.MeterGeometryLeadY,
		endpointY,
		greenStart,
		aimPoint
end

local function associateGreenPacket(character, greenEnd, isRegistration)
	if character ~= getCharacter() or type(greenEnd) ~= "number" then
		return
	end

	monitor.PacketIndex += 1
	local shot = monitor.ActiveShot
	if shot
		and not shot.Superseded
		and os.clock() >= shot.RemoteStartLocal
	then
		if not isRegistration and not shot.GreenRegistered then
			return
		end
		shot.GreenPacketIndex = monitor.PacketIndex
		shot.GreenEndNormalized = greenEnd
		if isRegistration then
			shot.GreenRegistered = true
		end
		if shot.MeterType then
			local rawTarget,
				adjustedTarget,
				endpointY,
				greenStart,
				aimPoint = computeDirectMeterTarget(
				character,
				shot.MeterType,
				greenEnd
			)
			if adjustedTarget then
				shot.RawDirectMeterTargetY = rawTarget
				shot.DirectMeterTargetY = adjustedTarget
				shot.DirectMeterEndpointY = endpointY
				shot.GreenStartNormalized = greenStart
				shot.GreenAimNormalized = aimPoint
			end
		end
	end
end

table.insert(monitor.Connections, RunService.RenderStepped:Connect(function(deltaTime)
	if deltaTime > 0 and deltaTime < 0.25 then
		local boundedFrame = math.clamp(deltaTime, 1 / 360, 1 / 15)
		monitor.FrameDuration += (
			boundedFrame
			- monitor.FrameDuration
		) * 0.15
		monitor.RecentFrameDuration = math.max(
			boundedFrame,
			monitor.RecentFrameDuration * 0.96
		)
	end
end))

local function scheduleDirectMeterRelease(shot, deadline, targetY)
	local token = {}
	shot.MeterPredictionToken = token
	shot.PredictedMeterCrossingLocal = deadline
	shot.PredictedMeterTargetY = targetY

	task.spawn(function()
		while not monitor.Stopped
			and autoActiveForShot(shot)
			and not shot.Ended
			and not shot.Superseded
			and shot.MeterPredictionToken == token
		do
			local remaining = deadline - os.clock()
			if remaining <= 0 then
				break
			end
			if remaining > 0.02 then
				task.wait(remaining - 0.015)
			else
				repeat
				remaining = deadline - os.clock()
				until (
					remaining <= 0
					or monitor.Stopped
					or not autoActiveForShot(shot)
					or shot.Ended
					or shot.Superseded
					or shot.MeterPredictionToken ~= token
				)
				break
			end
		end

		if not monitor.Stopped
			and autoActiveForShot(shot)
			and not shot.Ended
			and not shot.Superseded
			and shot.MeterPredictionToken == token
		then
			shot.MeterTriggerPending = true
			shot.MeterTriggerLocal = os.clock()
			shot.MeterTriggerOffset = Vector2.new(0, targetY)
			shot.AppliedMeterTriggerDelay = 0
			transmitRelease(shot, "direct server green-band crossing")
		end
	end)
end

local meterCharacter = getCharacter()
if meterCharacter then
	table.insert(
		monitor.Connections,
		meterCharacter:GetAttributeChangedSignal("meterOffset"):Connect(
			function()
				local shot = monitor.ActiveShot
				local offset = meterCharacter:GetAttribute("meterOffset")
				if not shot
					or shot.Ended
					or shot.Superseded
					or typeof(offset) ~= "Vector2"
				then
					return
				end

				local now = os.clock()
				shot.PreviousMeterSample = shot.LatestMeterSample
				shot.LatestMeterSample = {
					Local = now,
					Offset = offset,
				}

				-- Every new Vertical meter begins near -0.24. Requiring that
				-- reset prevents the previous shot's frozen -1.46 value from
				-- releasing a new shot before its packet is registered.
				if offset.Y > -0.5 then
					shot.MeterResetSeen = true
					shot.PreviousMeterSample = nil
					shot.LatestMeterSample = {
						Local = now,
						Offset = offset,
					}
					shot.MeterSlope = nil
					shot.MeterPredictionToken = nil
					return
				end

				local directTarget = (
					shot.DirectMeterTargetY
					or monitor.MeterTargetY
				)
				if monitor.MeterSyncEnabled
					and shot.MeterResetSeen
					and shot.TargetResolved
					and autoActiveForShot(shot)
					and (
						shot.MeterType == nil
						or shot.MeterType == "Vertical"
					)
					and not shot.MeterTriggerPending
				then
					if offset.Y <= directTarget then
						scheduleDirectMeterRelease(
							shot,
							now,
							directTarget
						)
						return
					end

					local previous = shot.PreviousMeterSample
					if previous then
						local deltaTime = now - previous.Local
						local deltaY = (
							offset.Y - previous.Offset.Y
						)
						if deltaTime >= 0.003
							and deltaTime <= 0.1
							and deltaY < -0.001
						then
							local instantSlope = deltaY / deltaTime
							if instantSlope >= -10
								and instantSlope <= -0.2
							then
								shot.MeterSlope = shot.MeterSlope
									and (
										shot.MeterSlope * 0.65
										+ instantSlope * 0.35
									)
									or instantSlope
								local endpointDelay = (
									(directTarget - offset.Y)
									/ shot.MeterSlope
								)
								local oneWayPing = player:GetNetworkPing()
								local appliedTransitScale = (
									monitor.MeterTransitScale
								)
								local transitTime = (
									shot.RawDirectMeterTargetY
										and (
											oneWayPing
											* appliedTransitScale
										)
										or 0
								)
								local sendDelay = endpointDelay - transitTime
								if endpointDelay >= 0
									and endpointDelay <= 0.5
								then
									sendDelay = math.max(0, sendDelay)
									shot.MeterOneWayPing = oneWayPing
									shot.AppliedMeterTransitScale = (
										appliedTransitScale
									)
									shot.MeterTransitTime = transitTime
									shot.PredictedObservedSendY = (
										offset.Y
										+ shot.MeterSlope * sendDelay
									)
									scheduleDirectMeterRelease(
										shot,
										now + sendDelay,
										shot.PredictedObservedSendY
									)
								end
							end
						end
					end
				end
			end
		)
	)
end

local meterService = ReplicatedStorage
	:WaitForChild("Aero")
	:WaitForChild("AeroRemoteServices")
	:WaitForChild("MeterService")

table.insert(monitor.Connections, meterService.RegisterPacket.OnClientEvent:Connect(
	function(character, meterType, greenEnd)
		local shot = monitor.ActiveShot
		if shot and character == getCharacter() then
			shot.MeterType = meterType
		end
		associateGreenPacket(character, greenEnd, true)
	end
))

table.insert(monitor.Connections, meterService.UpdateGreenWindow.OnClientEvent:Connect(
	function(character, greenEnd)
		associateGreenPacket(character, greenEnd, false)
	end
))

table.insert(monitor.Connections, meterService.UnregisterPacket.OnClientEvent:Connect(
	function(character)
		if character == getCharacter() then
			monitor.PacketIndex += 1
			local shot = monitor.ActiveShot
			if shot
				and not shot.Ended
				and not shot.Superseded
				and shot.GreenRegistered
				and shot.EarlyFalseSuppressed
				and autoActiveForShot(shot)
			then
				transmitRelease(shot, "meter unregistered cleanup")
			end
		end
	end
))

local showFeedback = ReplicatedStorage
	:WaitForChild("Aero")
	:WaitForChild("AeroRemoteServices")
	:WaitForChild("InterfaceService")
	:WaitForChild("ShowFeedback")

table.insert(monitor.Connections, showFeedback.OnClientEvent:Connect(
	function(character, _, timingIndex)
		if character ~= getCharacter() then
			return
		end

		local feedback = timingNames[tonumber(timingIndex)]
		if not feedback then
			return
		end

		for index = #monitor.History, 1, -1 do
			local shot = monitor.History[index]
			if shot.Accepted and shot.Ended and not shot.Feedback then
				shot.Feedback = feedback
				printFeedback(shot)
				if monitor.ActiveShot == shot then
					monitor.ActiveShot = nil
				end
				return
			end
		end
	end
))

local function observeRemote(arguments, eventLocal, eventServer, previousStart)
	local payload = arguments[1]
	if type(payload) ~= "table" then
		return
	end

	if payload.Shoot == true then
		if monitor.ActiveShot then
			monitor.ActiveShot.Superseded = true
			monitor.ActiveShot.ReleaseToken = nil
		end

		monitor.ShotIndex += 1
		local shot = {
			Id = monitor.ShotIndex,
			RemoteStartLocal = eventLocal,
			RemoteStartServer = eventServer,
			InputKind = payload.Input,
			PreviousShotStartTime = previousStart,
			StartRTT = player:GetNetworkPing(),
			PendingReleasePayload = {
				Shoot = false,
			},
			ReleaseState = "resolving",
			AutoEligible = monitor.AutoReleaseEnabled,
		}

		monitor.ActiveShot = shot
		monitor.PendingAutoShot = nil
		table.insert(monitor.History, shot)
		while #monitor.History > 20 do
			table.remove(monitor.History, 1)
		end

		task.spawn(resolveShot, shot)
		if autoActiveForShot(shot) then
			task.delay(1.4, function()
				if not monitor.Stopped
					and not shot.Ended
					and not shot.TargetResolved
					and not shot.Superseded
					and autoActiveForShot(shot)
				then
					warn((
						"[PerfectHold #%d] Timing did not resolve;"
						.. " sending failsafe release"
					):format(shot.Id))
					transmitRelease(shot, "unresolved watchdog")
				end
			end)
		end
		return
	end

	if payload.Shoot == false
		and monitor.ActiveShot
		and not monitor.ActiveShot.Ended
	then
		local shot = monitor.ActiveShot
		shot.ReleaseCommitted = true
		shot.ReleaseState = "sent"
		shot.ReleaseRTT = player:GetNetworkPing()
		recordRemoteEnd(
			shot,
			eventLocal,
			eventServer,
			"natural/cancellation"
		)
	end
end

local function cloneReleasePayload(payload)
	local copy = {}
	for key, value in pairs(payload) do
		copy[key] = value
	end
	return copy
end

local function findAssociatedAutoShot()
	if monitor.PendingAutoShot then
		return monitor.PendingAutoShot
	end

	local shot = monitor.ActiveShot
	if shot then
		return shot
	end

	return nil
end

local function interceptInputRelease(payload, eventLocal, eventServer)
	local shot = findAssociatedAutoShot()
	if not shot then
		return false
	end
	if not shot.AutoReleased and not autoActiveForShot(shot) then
		return false
	end

	shot.NaturalFalseSeen = true
	shot.NaturalFalseLocal = eventLocal
	shot.NaturalFalseServer = eventServer
	shot.PendingReleasePayload = cloneReleasePayload(payload)

	if monitor.PendingAutoShot == shot then
		monitor.PendingAutoShot = nil
	end

	-- The meter-controlled packet was already sent; consume the later duplicate.
	if shot.Ended or shot.ReleaseCommitted then
		shot.DuplicateFalseSuppressed = (
			(shot.DuplicateFalseSuppressed or 0) + 1
		)
		return true
	end

	shot.EarlyFalseSuppressed = true

	-- If the timer's exact deadline has already arrived, this input thread can
	-- perform the committed send without waiting for another scheduler turn.
	if shot.ReleaseDeadlineLocal
		and eventLocal >= shot.ReleaseDeadlineLocal
	then
		transmitRelease(shot, "input release at/past target")
	end

	return true
end

local wrapper
wrapper = function(self, ...)
	-- Cached input handlers can retain the pre-install Fire function. When this
	-- wrapper is reached through the function hook after Stop(), behave exactly
	-- like the original instead of continuing to control releases.
	if monitor.Stopped then
		return originalFire(self, ...)
	end

	local arguments = table.pack(...)
	local eventLocal = os.clock()
	local eventServer = workspace:GetServerTimeNow()
	local character = getCharacter()
	local previousStart = character and character:GetAttribute("ShotStartTime")
	local payload = arguments[1]

	if type(payload) == "table"
		and payload.Shoot == false
		and interceptInputRelease(payload, eventLocal, eventServer)
	then
		return
	end

	if type(payload) == "table" and payload.Shoot == true then
		local previousShot = monitor.ActiveShot
		if previousShot
			and not previousShot.Ended
			and autoActiveForShot(previousShot)
		then
			transmitRelease(previousShot, "superseded-shot failsafe")
		end
		if previousShot then
			previousShot.Superseded = true
			previousShot.ReleaseToken = nil
		end
	end

	-- Shoot=true and non-release packets retain the game's original call path.
	local results = table.pack(originalFire(
		self,
		table.unpack(arguments, 1, arguments.n)
	))

	local ok, observerError = pcall(
		observeRemote,
		arguments,
		eventLocal,
		eventServer,
		previousStart
	)
	if not ok then
		warn("[PerfectHold] Observer error:", observerError)
	end

	return table.unpack(results, 1, results.n)
end

monitor.Wrapper = wrapper

-- Desktop input currently looks up Shoot.Fire for each event, so replacing the
-- table field is sufficient there. Some touch/mobile controllers cache the Fire
-- closure during initialization. Hooking that closure catches both cached and
-- future callers; hookfunction's return value is the unhooked trampoline used by
-- transmitRelease so the one intended Shoot=false is not intercepted again.
local hookApi = rawget(environment, "hookfunction")
	or rawget(environment, "replaceclosure")
	or hookfunction
	or replaceclosure
if type(hookApi) == "function" then
	local hooked, bypassFire = pcall(hookApi, originalFire, wrapper)
	if hooked and type(bypassFire) == "function" then
		originalFire = bypassFire
		monitor.OriginalFire = bypassFire
		monitor.FunctionHookInstalled = true
	else
		monitor.FunctionHookInstalled = false
		monitor.FunctionHookError = tostring(bypassFire)
	end
end

shootSignal.Fire = wrapper

function monitor:SetAutoRelease(enabled)
	enabled = not not enabled
	if self.AutoReleaseEnabled == enabled then
		return
	end

	if not enabled then
		local shot = self.ActiveShot
		if shot then
			shot.AutoCancelled = true
			shot.ReleaseToken = nil
			if shot.EarlyFalseSuppressed and not shot.Ended then
				transmitRelease(shot, "auto-release disabled flush")
			end
		end
	end

	self.AutoReleaseEnabled = enabled
	local appliesNextShot = enabled
		and self.ActiveShot
		and not self.ActiveShot.Ended
	print(("[PerfectHold] Auto-release %s%s"):format(
		enabled and "enabled" or "disabled",
		appliesNextShot and " (takes effect on the next shot)" or ""
	))
end

function monitor:SetHighPrecision(enabled)
	self.HighPrecision = not not enabled
	print(("[PerfectHold] High-precision scheduler %s"):format(
		self.HighPrecision and "enabled" or "disabled"
	))
end

function monitor:SetReleaseBias(seconds)
	assert(type(seconds) == "number", "release bias must be a number")
	self.ReleaseBias = math.clamp(seconds, -0.1, 0.1)
	print(("[PerfectHold] Release calibration bias set to %+.3f ms"):format(
		self.ReleaseBias * 1000
	))
end

function monitor:SetMeterSync(enabled)
	self.MeterSyncEnabled = not not enabled
	print(("[PerfectHold] Server-meter synchronization %s"):format(
		self.MeterSyncEnabled and "enabled" or "disabled"
	))
end

function monitor:SetMeterTargetY(value)
	assert(type(value) == "number", "meter target must be a number")
	self.MeterTargetY = math.clamp(value, -2, 0)
	print(("[PerfectHold] Vertical meter target set to %.6f"):format(
		self.MeterTargetY
	))
end

function monitor:SetMeterTriggerDelay(seconds)
	assert(type(seconds) == "number", "meter delay must be a number")
	self.MeterTriggerDelay = math.clamp(seconds, 0, 0.05)
	print(("[PerfectHold] Meter trigger delay set to %.3f ms"):format(
		self.MeterTriggerDelay * 1000
	))
end

function monitor:SetMeterGeometryLeadY(value)
	assert(type(value) == "number", "geometry lead must be a number")
	self.MeterGeometryLeadY = math.clamp(value, -0.2, 0.2)
	print(("[PerfectHold] Direct meter geometry lead set to %+.6f"):format(
		self.MeterGeometryLeadY
	))
end

function monitor:SetMeterTransitScale(value)
	assert(type(value) == "number", "transit scale must be a number")
	self.MeterTransitScale = math.clamp(value, 0, 3)
	print(("[PerfectHold] Meter transit scale set to %.3f"):format(
		self.MeterTransitScale
	))
end

function monitor:SetMeterGreenAimFraction(value)
	assert(type(value) == "number", "green aim fraction must be a number")
	self.MeterGreenAimFraction = math.clamp(value, 0, 1)
	print(("[PerfectHold] Green-band aim set to %.1f%%"):format(
		self.MeterGreenAimFraction * 100
	))
end

function monitor:Stop()
	if self.Stopped then
		return
	end

	local shot = self.ActiveShot
	if shot and shot.EarlyFalseSuppressed and not shot.Ended then
		transmitRelease(shot, "monitor-stop flush")
	end

	self.Stopped = true

	if self.ShootSignal.Fire == self.Wrapper then
		self.ShootSignal.Fire = self.OriginalFire
	end

	for _, connection in ipairs(self.Connections) do
		connection:Disconnect()
	end
	table.clear(self.Connections)

	if rawget(environment, "__PerfectHoldMonitor") == self then
		environment.__PerfectHoldMonitor = nil
	end

	print("[PerfectHold] Monitor stopped")
end

environment.__PerfectHoldMonitor = monitor

print("[PerfectHold] Monitor installed")
print("[PerfectHold] Input-agnostic auto-release enabled")
if monitor.FunctionHookInstalled then
	print("[PerfectHold] Cached mobile Shoot.Fire callers are covered")
elseif monitor.FunctionHookError then
	warn(
		"[PerfectHold] Mobile function hook unavailable; table-field fallback only:",
		monitor.FunctionHookError
	)
end
print(
	"[PerfectHold] Direct meter mode: actual greenEnd + live fill crossing"
)
print(("[PerfectHold] Cached %d timing animations"):format(
	warmedAnimationCount
))
print(
	"[PerfectHold] Paired formula: Pause/ShotSpeed"
		.. " + |Release-Pause|/2.5; single-track formula: Release/ShotSpeed"
)
