-- Enemy Projectile Lifter (Sirius) - self-contained loadstring build
-- Generated from enemy-proj-lift.luau. Paste this whole file into your executor.
-- No external host needed: the payload lives in SRC below.

local SRC = [==[local env = getgenv()
if env.EnemyProjLift then pcall(env.EnemyProjLift.Stop) end

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/gen2"))()
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local folder = workspace:WaitForChild("Projectile")
local npc = workspace:WaitForChild("NPCFolders")
local enemyFolder = npc:WaitForChild("EnemyFolder")
local friendlyFolder = npc:WaitForChild("FriendlyFolder")
local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
local ClientProjectile = game.ReplicatedStorage.Events.RemoteEvents:WaitForChild("ClientProjectile")

-- All features start OFF, deliberately: loading the hub must not enable anything behind your
-- back. Flip the toggles you want; everyone and everything stays vanilla until then.
local state = {
	hitbox = false, disarmed = 0,
	ghostDeleted = 0,
	gloom = false, gloomPurged = 0, gloomActive = false,
	anti = false, antiParts = 0,
	antiDepriver = false, depriverStopped = 0, depriverBack = false,
	hpBars = false, hpBarsShown = 0,
	gamek1d = false, gamek1dSaved = 0, gamek1dFaked = 0, gamek1dWiped = 0,
	byEnemy = 0, byFriendly = 0,
	tpTarget = nil,   -- Model currently being aimed at
	tpCount = 0,      -- projectiles redirected this session
	tpBase = false,   -- redirect every friendly projectile at the enemy base
	paint = false, paintColor = Color3.fromRGB(255, 45, 45),
	paintEnemy = true, paintFriendly = true,
}
local decided = setmetatable({}, { __mode = "k" })
local pending = setmetatable({}, { __mode = "k" })
local preexisting = setmetatable({}, { __mode = "k" })
local lastPos = setmetatable({}, { __mode = "k" })
local MAX_TRIES = 30
local PENDING_TIMEOUT = 2
local SPAWN_TRUST = 30
local conns = {}

for _, p in ipairs(folder:GetChildren()) do preexisting[p] = true end

------------------------------------------------------------------ who fired it?
local function boxDist(model, pos)
	local ok, cf, size = pcall(model.GetBoundingBox, model)
	if not ok then return math.huge end
	local rel = cf:PointToObjectSpace(pos)
	local h = size / 2
	return Vector3.new(
		math.max(math.abs(rel.X) - h.X, 0),
		math.max(math.abs(rel.Y) - h.Y, 0),
		math.max(math.abs(rel.Z) - h.Z, 0)
	).Magnitude
end

local function sideDistance(unitFolder, baseName, pos)
	local best = math.huge
	for _, m in ipairs(unitFolder:GetChildren()) do
		if m:IsA("Model") then
			local d = boxDist(m, pos)
			if d < best then best = d end
		end
	end
	local bf = npc:FindFirstChild("BaseFolder")
	local b = bf and bf:FindFirstChild(baseName)
	if b then
		local ok, cf = pcall(b.GetPivot, b)
		if ok then
			local d = (cf.Position - pos).Magnitude
			if d < best then best = d end
		end
	end
	return best
end

local function sideAt(pos)
	local dE = sideDistance(enemyFolder, "Red Base", pos)
	local dF = sideDistance(friendlyFolder, "Blue Base", pos)
	if math.min(dE, dF) > SPAWN_TRUST then return nil end
	return dE < dF and "enemy" or "friendly"
end

local function legacyClassify(p)
	local E, F = {}, {}
	for _, m in ipairs(enemyFolder:GetChildren()) do local ok, cf = pcall(m.GetPivot, m) if ok then E[#E + 1] = cf.Position end end
	for _, m in ipairs(friendlyFolder:GetChildren()) do local ok, cf = pcall(m.GetPivot, m) if ok then F[#F + 1] = cf.Position end end
	if #E == 0 or #F == 0 then return nil end
	local function mean(l) local s = Vector3.zero for _, a in ipairs(l) do s += a end return s / #l end
	local diff = mean(F) - mean(E)
	if diff.Magnitude < 1 then return nil end
	local axis = diff.Unit
	local d = p.AssemblyLinearVelocity:Dot(axis)
	if d > 0.5 then return "enemy" elseif d < -0.5 then return "friendly" end
	local prev = lastPos[p]
	if prev then
		local m = (p.Position - prev):Dot(axis)
		if m > 0.05 then return "enemy" elseif m < -0.05 then return "friendly" end
	end
	lastPos[p] = p.Position
	return nil
end

local function markSide(part, side)
	if decided[part] then return end
	decided[part] = side
	if side == "enemy" then
		state.byEnemy += 1
		pending[part] = { tries = 0, since = os.clock() }
	else
		state.byFriendly += 1
	end
end

------------------------------------------------------------------ enemy projectile hitboxes
local function kill(c)
	local ok = pcall(function() c:Disable() end)
	if not ok then pcall(function() c:Disconnect() end) end
end

local function sweeperMap()
	local map = {}
	local ok, cs = pcall(getconnections, RunService.PostSimulation)
	if not ok then return map end
	for _, c in ipairs(cs) do
		local f = c.Function
		if f then
			local okU, ups = pcall(debug.getupvalues, f)
			if okU then
				for _, v in pairs(ups) do
					if typeof(v) == "Instance" and v:IsA("BasePart") and v.Parent == folder then
						map[v] = map[v] or {}
						table.insert(map[v], c)
						break
					end
				end
			end
		end
	end
	return map
end

local function disarm(p, map)
	local found = false
	local okT, tc = pcall(getconnections, p.Touched)
	if okT then
		for _, c in ipairs(tc) do kill(c) found = true end
	end
	if map[p] then
		for _, c in ipairs(map[p]) do kill(c) found = true end
	end
	pcall(function()
		p.CanTouch = false
		p.CanCollide = false
		p.CanQuery = false
	end)
	return found
end

local ghostDone = setmetatable({}, { __mode = "k" })
local function isGhostwalkerProjectile(p)
	if typeof(p) ~= "Instance" or p.Name ~= "Ghostwalker" then return false end
	if not p:IsA("BasePart") then return false end
	if not p:IsDescendantOf(workspace) then return false end
	if p:IsDescendantOf(npc) then return false end
	return true
end

local function handleGhostwalker(p)
	if not state.hitbox then return end
	if not isGhostwalkerProjectile(p) then return end
	if ghostDone[p] then return end
	if decided[p] == "friendly" then return end
	ghostDone[p] = true
	disarm(p, {})
	pcall(function() p:Destroy() end)
	if p.Parent then
		pcall(function()
			p.CanTouch = false
			p.CanCollide = false
			p.CanQuery = false
			p.Anchored = true
			p.AssemblyLinearVelocity = Vector3.zero
		end)
	end
	state.ghostDeleted += 1
	state.disarmed += 1
end

local function ghostScan()
	if not state.hitbox then return end
	for _, p in ipairs(folder:GetChildren()) do
		if p.Name == "Ghostwalker" then handleGhostwalker(p) end
	end
	local direct = workspace:FindFirstChild("Ghostwalker")
	if direct then handleGhostwalker(direct) end
end

local function projectileStep()
	for _, p in ipairs(folder:GetChildren()) do
		if p:IsA("BasePart") and preexisting[p] and not decided[p] then
			local side = legacyClassify(p)
			if side then markSide(p, side) end
		end
	end

	if next(pending) then
		local now = os.clock()
		local map = state.hitbox and sweeperMap() or {}
		for p, info in pairs(pending) do
			if p.Parent == folder then
				if p.Name == "Ghostwalker" then
					handleGhostwalker(p)
					pending[p] = nil
				else
					local done = true
					if state.hitbox then
						local found = disarm(p, map)
						info.tries += 1
						done = found or info.tries >= MAX_TRIES
						if found then state.disarmed += 1 end
					end
					if done then
						pending[p] = nil
					end
				end
			elseif not p.Parent or now - info.since > PENDING_TIMEOUT then
				pending[p] = nil
			end
		end
	end
	pcall(ghostScan)
end

conns[#conns + 1] = ClientProjectile.OnClientEvent:Connect(function(_, data)
	if type(data) ~= "table" then return end
	local part, spawn = data.Projectile, data.SpawnPosition
	if typeof(part) == "Instance" and part.Name == "Ghostwalker" then
		if typeof(spawn) == "Vector3" and spawn ~= Vector3.zero then
			local side = sideAt(spawn)
			if side then markSide(part, side) end
		end
		handleGhostwalker(part)
		return
	end
	if typeof(part) ~= "Instance" or typeof(spawn) ~= "Vector3" or spawn == Vector3.zero then return end
	local side = sideAt(spawn)
	if side then markSide(part, side) end
end)

------------------------------------------------------------------ Delete Gloom hazard
local gloomParts = {}
local baseline, snapNew, lastSnap = nil, nil, 0

local function snapshot()
	local a = Lighting:FindFirstChildOfClass("Atmosphere")
	return {
		Brightness = Lighting.Brightness, ClockTime = Lighting.ClockTime,
		Ambient = Lighting.Ambient, ColorShift_Top = Lighting.ColorShift_Top,
		Density = a and a.Density,
	}
end

local function purgeInstance(i)
	pcall(function() i:Destroy() end)
	state.gloomPurged += 1
end

local function neuterGloomPart(p)
	if not gloomParts[p] then
		gloomParts[p] = true
		state.gloomPurged += 1
	end
	for _, c in ipairs(p:GetChildren()) do pcall(function() c:Destroy() end) end
end

local function gloomScan()
	if not state.gloom then return end
	local map = workspace:FindFirstChild("Map")
	if map then
		for _, d in ipairs(map:GetDescendants()) do
			if d.Name == "GloomPart" then neuterGloomPart(d) end
		end
	end
	for _, g in ipairs(playerGui:GetChildren()) do
		if g.Name == "Gloom" then purgeInstance(g) end
	end
	for _, c in ipairs(Lighting:GetChildren()) do
		if c.Name == "Darkness" and c:IsA("ColorCorrectionEffect") then purgeInstance(c) end
	end
	local cam = workspace.CurrentCamera
	if cam then
		for _, c in ipairs(cam:GetChildren()) do
			if c.Name == "Darkness" and c:IsA("ColorCorrectionEffect") then purgeInstance(c) end
		end
	end
end

local function gloomStep()
	if not state.gloom then return end
	local active = false
	for p in pairs(gloomParts) do
		if p:IsDescendantOf(workspace) then active = true else gloomParts[p] = nil end
	end
	state.gloomActive = active
	local now = os.clock()
	if active and baseline then
		pcall(function()
			Lighting.Brightness = baseline.Brightness
			Lighting.ClockTime = baseline.ClockTime
			Lighting.Ambient = baseline.Ambient
			Lighting.ColorShift_Top = baseline.ColorShift_Top
			local a = Lighting:FindFirstChildOfClass("Atmosphere")
			if a and baseline.Density then a.Density = baseline.Density end
		end)
	elseif not active and now - lastSnap > 0.5 then
		lastSnap = now
		baseline = snapNew or snapshot()
		snapNew = snapshot()
	end
end

------------------------------------------------------------------ Anti-hit Judgement / Punishment
local antiOriginal = setmetatable({}, { __mode = "k" })
local ANTI_NAMES = { "judgement", "punishment" }

local function isAntiTarget(model)
	local n = model.Name:lower()
	for _, k in ipairs(ANTI_NAMES) do
		if n:find(k, 1, true) then return true end
	end
	return false
end

local function antiPart(d)
	if d:IsA("BasePart") then
		if antiOriginal[d] == nil then antiOriginal[d] = d.CanTouch end
		if d.CanTouch then pcall(function() d.CanTouch = false end) end
		return true
	end
	return false
end

local function antiStep()
	if not state.anti then return end
	local count = 0
	for _, m in ipairs(enemyFolder:GetChildren()) do
		if isAntiTarget(m) then
			for _, d in ipairs(m:GetDescendants()) do
				if antiPart(d) then count += 1 end
			end
		end
	end
	state.antiParts = count
end

local function antiRestore()
	for part, was in pairs(antiOriginal) do
		if part.Parent then pcall(function() part.CanTouch = was end) end
	end
	antiOriginal = setmetatable({}, { __mode = "k" })
	state.antiParts = 0
end

------------------------------------------------------------------ Anti Depriver (camera minigame)
local STASH_NAME = "__antiDepriverStash"
local CHUST_NAME = "ChustUI"

local function cutscenesFolder()
	return game:GetService("ReplicatedStorage"):FindFirstChild("Cutscenes")
end

local function stashFolder()
	local rs = game:GetService("ReplicatedStorage")
	local s = rs:FindFirstChild(STASH_NAME)
	if s then return s end
	local ok, made = pcall(function()
		local f = Instance.new("Folder")
		f.Name = STASH_NAME
		f.Parent = rs
		return f
	end)
	return ok and made or nil
end

local function clearChustAttributes()
	local cross = playerGui:FindFirstChild("CrosshairUI")
	if not cross then return end
	pcall(function() cross:SetAttribute("DepriverHint", nil) end)
	pcall(function() cross:SetAttribute("DepriverParry", nil) end)
end

local function hideChustTemplate()
	local cut = cutscenesFolder()
	local tmpl = cut and cut:FindFirstChild(CHUST_NAME)
	if not tmpl then return false end
	local stash = stashFolder()
	if stash then
		local ok = pcall(function() tmpl.Parent = stash end)
		if ok and tmpl.Parent == stash then return true end
	end
	pcall(function() tmpl:Destroy() end)
	return true
end

local function killLiveChust()
	for _, g in ipairs(playerGui:GetChildren()) do
		if g.Name == CHUST_NAME then pcall(function() g:Destroy() end) end
	end
end

local function depriverScan()
	if not state.antiDepriver then return end
	if hideChustTemplate() then state.depriverStopped += 1 end
	killLiveChust()
	clearChustAttributes()
end

local function depriverRestore()
	local cut = cutscenesFolder()
	local stash = game:GetService("ReplicatedStorage"):FindFirstChild(STASH_NAME)
	if not cut or not stash then return end
	if cut:FindFirstChild(CHUST_NAME) then return end
	for _, c in ipairs(stash:GetChildren()) do
		if c.Name == CHUST_NAME then
			local ok = pcall(function() c.Parent = cut end)
			if ok then state.depriverBack = true end
		end
	end
end

------------------------------------------------------------------ Enable HP bars
local BOSS_HP = 50000
local hpBarOwn = setmetatable({}, { __mode = "k" })
local hpBarAdding = setmetatable({}, { __mode = "k" }) -- models with AddHPBars currently in flight
local HPBAR_STYLES = {
	Enemy = "Enemy", Friendly = "Friendly",
	EnemyBase = "EnemyBase", FriendlyBase = "FriendlyBase", Boss = "Boss",
}
local VisualEffects = nil

local function vfx()
	if VisualEffects then return VisualEffects end
	local ok, m = pcall(require, game:GetService("ReplicatedStorage").Modules.VisualEffects)
	if ok and type(m) == "table" then VisualEffects = m end
	return VisualEffects
end

local function isBossUnit(model)
	local hum = model:FindFirstChild("Humanoid")
	if hum and hum.MaxHealth >= BOSS_HP then return true end
	for k in pairs(model:GetAttributes()) do
		if tostring(k):lower():find("boss", 1, true) then return true end
	end
	return false
end

local function hpBarStyle(model, side)
	local baseFolder = npc:FindFirstChild("BaseFolder")
	local isBase = baseFolder ~= nil and model.Parent == baseFolder
	if side == "enemy" then
		if isBase then return HPBAR_STYLES.EnemyBase end
		return isBossUnit(model) and HPBAR_STYLES.Boss or HPBAR_STYLES.Enemy
	end
	if isBase then return HPBAR_STYLES.FriendlyBase end
	return HPBAR_STYLES.Friendly
end

local function hpBarHost(model)
	return model:FindFirstChild("Head") or model
end

local function killBarConnections(hum, bar)
	local ok, cs = pcall(getconnections, hum.HealthChanged)
	if not ok then return end
	for _, c in ipairs(cs) do
		local f = c.Function
		if f then
			local okU, ups = pcall(debug.getupvalues, f)
			if okU then
				for _, v in pairs(ups) do
					if v == bar then pcall(function() c:Disconnect() end) break end
				end
			end
		end
	end
end

-- Every bar of this style anywhere under the unit. The guard used to look only at the *current*
-- host, and the host changes: hpBarHost() returns Head if the unit has one and the model if it
-- does not, and a unit is still assembling itself for the first few frames after it spawns. So a
-- bar created while the unit was headless landed on the model, and once Head arrived the guard
-- looked only there, saw nothing, and added a second bar. Searching the whole model closes that
-- hole and also cleans up doubles already on the field.
local function barsUnder(model, style)
	local found = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BillboardGui") and d.Name == style then
			found[#found + 1] = d
		end
	end
	return found
end

local function addBar(model, side)
	if not model:IsA("Model") then return false end
	local hum = model:FindFirstChild("Humanoid")
	if not hum or hum.MaxHealth <= 0 then return false end
	local style = hpBarStyle(model, side)
	local host = hpBarHost(model)

	local found = barsUnder(model, style)
	if #found > 0 then
		-- Keep exactly one: prefer the bar under the host we would have used, so a unit's bar
		-- stays at the head and a base's stays on the model; otherwise any well-formed bar.
		-- Everything else is a duplicate - ours from an earlier host switch, or one a second,
		-- overlapping scan managed to add. Drop them instead of leaving them stacked.
		local keep
		for _, b in ipairs(found) do
			if b.Parent == host and b:FindFirstChild("Frame") then keep = b break end
		end
		if not keep then
			for _, b in ipairs(found) do
				if b:FindFirstChild("Frame") then keep = b break end
			end
		end
		if not keep then keep = found[1] end

		for _, b in ipairs(found) do
			if b ~= keep then
				killBarConnections(hum, b)
				hpBarOwn[b] = nil
				pcall(function() b:Destroy() end)
			end
		end
		if keep:FindFirstChild("Frame") then
			hpBarOwn[keep] = hum
			return true
		end
		-- the survivor is a husk with no Frame: drop it and fall through to a clean add
		killBarConnections(hum, keep)
		hpBarOwn[keep] = nil
		pcall(function() keep:Destroy() end)
	end

	-- AddHPBars may yield. A second scan entering here while we are inside it would still see no
	-- bar and add one too - that is how the bases doubled when several BaseFolder.ChildAdded
	-- scans queued up at round start. Hold the model until this add has come back.
	if hpBarAdding[model] then return false end
	hpBarAdding[model] = true
	local ok = pcall(function()
		local v = vfx()
		if v and type(v.AddHPBars) == "function" then v.AddHPBars(model, style, nil) end
	end)
	hpBarAdding[model] = nil
	if not ok then return false end

	found = barsUnder(model, style)
	local bar
	for _, b in ipairs(found) do
		if b:FindFirstChild("Frame") then bar = b break end
	end
	if not bar then bar = found[1] end
	if not bar then return false end
	if bar.Parent == model then
		pcall(function() bar.Adornee = model.PrimaryPart or hum.RootPart or model end)
	end
	hpBarOwn[bar] = hum
	return true
end

local function hpBarScan()
	if not state.hpBars then return end
	local baseFolder = npc:FindFirstChild("BaseFolder")
	for _, m in ipairs(enemyFolder:GetChildren()) do addBar(m, "enemy") end
	for _, m in ipairs(friendlyFolder:GetChildren()) do addBar(m, "friendly") end
	if baseFolder then
		for _, m in ipairs(baseFolder:GetChildren()) do
			if m:IsA("Model") then
				addBar(m, m.Name:lower():find("red", 1, true) and "enemy" or "friendly")
			end
		end
	end
	local live = 0
	for bar in pairs(hpBarOwn) do
		if bar.Parent then
			live += 1
		else
			hpBarOwn[bar] = nil -- destroyed elsewhere; forget it rather than counting it forever
		end
	end
	state.hpBarsShown = live
end

local function hpBarRemove()
	for bar, hum in pairs(hpBarOwn) do
		if hum then killBarConnections(hum, bar) end
		if bar and bar.Parent then pcall(function() bar:Destroy() end) end
	end
	hpBarOwn = setmetatable({}, { __mode = "k" })
	hpBarAdding = setmetatable({}, { __mode = "k" })
	state.hpBarsShown = 0
end

------------------------------------------------------------------ Anti GameK1d
local GAMEK1D_GUI = "FunGui"
local GAMEK1D_LOUD = {
	"Alarm", "Uncanny", "Scream", "Laughing", "Screaming", "Warn", "ShoopDaWhoop",
}
local gkRec = setmetatable({}, { __mode = "k" })
local gkLivesConn = setmetatable({}, { __mode = "k" })
local gkHooked = false

local function gamek1dHook()
	if gkHooked then return end
	if type(hookmetamethod) ~= "function" or type(getnamecallmethod) ~= "function" then return end
	if type(table.pack) ~= "function" or type(table.unpack) ~= "function" then return end
	local prev
	prev = hookmetamethod(game, "__namecall", function(self, ...)
		if state.gamek1d and getnamecallmethod() == "FireServer" and self.Name == "SuccessEvent" then
			local args = table.pack(...)
			if args.n >= 1 then
				args[1] = true
				state.gamek1dFaked += 1
				return prev(self, table.unpack(args, 1, args.n))
			end
		end
		return prev(self, ...)
	end)
	gkHooked = true
end

local function gamek1dTame(gui)
	if typeof(gui) ~= "Instance" or not gui:IsA("ScreenGui") then return end
	local rec = gkRec[gui]
	if not rec then rec = { vis = {}, vol = {}, wiped = 0 } gkRec[gui] = rec end
	local pop = gui:FindFirstChild("PopUps")
	if pop and pop:IsA("GuiObject") then
		if rec.vis[pop] == nil then rec.vis[pop] = pop.Visible end
		pop.Visible = false
	end
	local function quiet(inst)
		if not inst then return end
		if rec.vol[inst] == nil then rec.vol[inst] = inst.Volume end
		if inst.Volume ~= 0 then
			pcall(function() inst:Stop() end)
			inst.Volume = 0
		end
	end
	local sfx = gui:FindFirstChild("SFX")
	for _, name in ipairs(GAMEK1D_LOUD) do
		if sfx then quiet(sfx:FindFirstChild(name)) end
	end
	local yap = gui:FindFirstChild("Yapping")
	if yap then
		for _, c in ipairs(yap:GetChildren()) do if c:IsA("Sound") then quiet(c) end end
	end
	if not gkLivesConn[gui] then
		gkLivesConn[gui] = gui:GetAttributeChangedSignal("Lives"):Connect(function()
			local n = tonumber(gui:GetAttribute("Lives"))
			if n and n <= 0 then
				gui:SetAttribute("Lives", 1)
				state.gamek1dSaved += 1
			end
		end)
	end
	for _, name in ipairs({ "Livestream", "RandomImages" }) do
		local i = gui:FindFirstChild(name)
		if i then
			local n = 0
			for _ in ipairs(i:GetDescendants()) do n += 1 end
			if n == 0 then n = 1 end
			rec.wiped += n
			state.gamek1dWiped += n
			pcall(function() i:Destroy() end)
		end
	end
end

local function gamek1dScan()
	if not state.gamek1d then return end
	pcall(gamek1dHook)
	local gui = playerGui:FindFirstChild(GAMEK1D_GUI)
	if gui then gamek1dTame(gui) end
end

local function gamek1dRestore()
	for gui in pairs(gkLivesConn) do
		local c = gkLivesConn[gui]
		if c then pcall(function() c:Disconnect() end) end
	end
	gkLivesConn = setmetatable({}, { __mode = "k" })
	for gui, rec in pairs(gkRec) do
		for i, was in pairs(rec.vis) do
			if i.Parent then pcall(function() i.Visible = was end) end
		end
		for s, vol in pairs(rec.vol) do
			if s.Parent then pcall(function() s.Volume = vol end) end
		end
	end
	gkRec = setmetatable({}, { __mode = "k" })
end

------------------------------------------------------------------ TP Projectiles to Enemy
-- When a target is selected every friendly projectile in workspace.Projectile is redirected to it
-- each heartbeat. "Redirect" means two things:
--
--   1. p.Position is set to the target's root (or pivot centre) so the part snaps there visually.
--
--   2. The sweeper closure the game registered on RunService.PostSimulation for this projectile
--      carries an upvalue [7] that is the position from the *previous* frame. The sweep check
--      raycasts from that old position to the current one, so if we move the part without updating
--      [7] the raycast flies from somewhere behind us and can miss. Patching [7] to the target
--      position makes the next sweep start right at the target, so the hit registers immediately.
--
-- The target is highlighted with a SelectionBox (neon orange, adornee = the model) while it is
-- selected. The box is destroyed when a different target is chosen or "None" is selected.
-- If the selected model leaves EnemyFolder (death, despawn) the dropdown is reset to "None"
-- automatically.
--
-- Dropdown labels: enemies are listed as "Name (N)" when there are duplicates, e.g.
-- "Blonde Battler (1)" and "Blonde Battler (2)". A unique name is shown as-is.
-- The mapping from label -> model is kept in tpLabelToModel, rebuilt on every Refresh.

local tpLabelToModel = {}   -- label string -> Model
local tpHighlight = nil     -- SelectionBox instance | nil
local tpDropdown = nil      -- Rayfield dropdown handle, set after UI is built

local function tpClearHighlight()
	if tpHighlight then
		pcall(function() tpHighlight:Destroy() end)
		tpHighlight = nil
	end
end

local function tpHighlightModel(model)
	tpClearHighlight()
	if not model then return end
	local box = Instance.new("SelectionBox")
	box.Color3 = Color3.fromRGB(255, 120, 0)
	box.LineThickness = 0.07
	box.SurfaceTransparency = 0.6
	box.SurfaceColor3 = Color3.fromRGB(255, 160, 30)
	box.Adornee = model
	box.Parent = workspace.CurrentCamera
	tpHighlight = box
end

-- build options list + mapping from the current contents of EnemyFolder
local function tpBuildOptions()
	tpLabelToModel = {}
	local counts = {}
	for _, m in ipairs(enemyFolder:GetChildren()) do
		if m:IsA("Model") then
			counts[m.Name] = (counts[m.Name] or 0) + 1
		end
	end
	local idx = {}
	local labels = {}
	for _, m in ipairs(enemyFolder:GetChildren()) do
		if m:IsA("Model") then
			local label
			if counts[m.Name] > 1 then
				idx[m.Name] = (idx[m.Name] or 0) + 1
				label = m.Name .. " (" .. idx[m.Name] .. ")"
			else
				label = m.Name
			end
			tpLabelToModel[label] = m
			labels[#labels + 1] = label
		end
	end
	table.sort(labels)
	table.insert(labels, 1, "None")
	return labels
end

-- sweeper upvalue index for the last-position cache (confirmed = index 7 from live inspection)
local TP_UV_LASTPOS = 7

local function tpGetSweeper(p)
	local ok, cs = pcall(getconnections, RunService.PostSimulation)
	if not ok then return nil end
	for _, c in ipairs(cs) do
		local f = c.Function
		if f then
			local okU, ups = pcall(debug.getupvalues, f)
			if okU then
				for _, v in pairs(ups) do
					if v == p then return f end
				end
			end
		end
	end
	return nil
end

local function tpRedirectProjectile(p, targetPos)
	pcall(function()
		-- patch the sweeper's last-position upvalue before moving the part, so the
		-- raycast that fires this frame starts at targetPos rather than the old location
		local f = tpGetSweeper(p)
		if f then
			pcall(debug.setupvalue, f, TP_UV_LASTPOS, targetPos)
		end
		p.CFrame = CFrame.new(targetPos)
		if not p.Anchored then
			p.AssemblyLinearVelocity = Vector3.zero
			p.AssemblyAngularVelocity = Vector3.zero
		end
	end)
	state.tpCount += 1
end

local function tpTargetPos()
	local m = state.tpTarget
	if not m or not m.Parent then return nil end
	local root = m:FindFirstChild("HumanoidRootPart")
	if root then return root.Position end
	local ok, cf = pcall(m.GetPivot, m)
	if ok then return cf.Position end
	return nil
end

-- Enemy base = Red Base. Confirmed against the live map: enemy units sit around Z = -49.7 and
-- Red Base at Z = -70, while our units sit at Z = +69.5 next to Blue Base at Z = +70, so Red is
-- theirs. Looked up fresh on every step rather than cached, because the base model can be
-- replaced between rounds. HumanoidRootPart first (it is the deliberate aim point), pivot as a
-- fallback for the case where the model has no root part.
local function tpBasePos()
	local bf = npc:FindFirstChild("BaseFolder")
	local b = bf and bf:FindFirstChild("Red Base")
	if not b then return nil end
	local root = b:FindFirstChild("HumanoidRootPart")
	if root then return root.Position end
	local ok, cf = pcall(b.GetPivot, b)
	if ok then return cf.Position end
	return nil
end

local function tpStep()
	-- Base mode takes priority: when it is on there is no unit target, so there is nothing
	-- to arbitrate between. No highlight is drawn for the base.
	if state.tpBase then
		local pos = tpBasePos()
		if not pos then return end
		for _, p in ipairs(folder:GetChildren()) do
			if p:IsA("BasePart") and decided[p] == "friendly" then
				tpRedirectProjectile(p, pos)
			end
		end
		return
	end
	local target = state.tpTarget
	if not target then return end
	-- auto-clear if the unit died / despawned
	if not target:IsDescendantOf(enemyFolder) then
		state.tpTarget = nil
		tpClearHighlight()
		if tpDropdown then pcall(function() tpDropdown:Set("None", true) end) end
		return
	end
	local pos = tpTargetPos()
	if not pos then return end
	for _, p in ipairs(folder:GetChildren()) do
		if p:IsA("BasePart") and decided[p] == "friendly" then
			tpRedirectProjectile(p, pos)
		end
	end
end

-- called from the dropdown callback and from the Refresh button
local function tpSelectLabel(label)
	tpClearHighlight()
	if label == "None" or label == nil then
		state.tpTarget = nil
		return
	end
	local model = tpLabelToModel[label]
	if not model then
		state.tpTarget = nil
		return
	end
	state.tpTarget = model
	tpHighlightModel(model)
end

------------------------------------------------------------------ Unit Painter (Fun tab)
-- Paints every unit in NPCFolders - EnemyFolder and FriendlyFolder alike - to one solid colour.
--
-- Recolouring just the body Parts leaves a unit reading as its own character, because the face
-- Decal, the accessory Handle's Texture and any mesh texture all draw on top of the Part colour.
-- A unit only reads as one colour when all of these are handled too:
--
--   BasePart    - Color. On a mesh this tints the texture map without touching its Texture child,
--                 so the whole mesh takes the colour instead of vanishing.
--   Decal       - hidden. A face decal paints over the Part colour, so leaving it alone is what
--                 makes a "painted" NPC still show its original face.
--   Texture     - hidden, except where its parent is a MeshPart. There it IS the mesh's own map
--                 and hiding it would make the mesh disappear rather than turn the colour.
--   SpecialMesh - TextureId cleared. It has no colour of its own and renders through the parent
--                 part, so clearing the texture is what lets that part's colour show through.
--   BodyColors  - R15 skin colours, in case non-R6 units show up later.
--   Highlight   - matched to the colour, so an outline the game already draws does not sit on top
--                 of the paint as a different hue.
--
-- Units are found continuously rather than snapshotted once: a sweep every 0.5s plus a per-model
-- DescendantAdded hook covers units that spawn later and parts added to a unit already on the
-- field. Originals are recorded on the first paint of each instance and only once, so repainting
-- with a new colour can never overwrite the game's real colours with our own - Restore hands back
-- exactly what was there before.

local paintOriginals = setmetatable({}, { __mode = "k" })  -- instance -> snapshot of what we changed
local paintTracked = setmetatable({}, { __mode = "k" })    -- model -> { folder = key, conn = conn }
local paintPending = nil     -- newest colour pick, applied at most once per frame
local paintSuppress = false  -- makes the next sweep restore instead of paint
local paintTick = 0
local paintToggle = nil      -- Rayfield toggle handle, set once the UI is built

local PAINT_FOLDERS = { enemy = enemyFolder, friendly = friendlyFolder }

-- record an instance's current values, once, so restore can put them back
local function paintRemember(inst, fields)
	if paintOriginals[inst] then return end
	local snap = {}
	for _, field in ipairs(fields) do
		local ok, value = pcall(function() return inst[field] end)
		if ok then snap[field] = value end
	end
	paintOriginals[inst] = snap
end

local function paintOne(inst)
	local colour = state.paintColor
	if inst:IsA("BasePart") then
		paintRemember(inst, { "Color" })
		inst.Color = colour
	elseif inst:IsA("Decal") then
		paintRemember(inst, { "Transparency" })
		inst.Transparency = 1
	elseif inst:IsA("Texture") then
		if not (inst.Parent and inst.Parent:IsA("MeshPart")) then
			paintRemember(inst, { "Transparency" })
			inst.Transparency = 1
		end
	elseif inst:IsA("SpecialMesh") then
		-- SpecialMesh has no Color of its own: it renders through the parent part.
		-- Clearing TextureId is what stops it drawing its own texture over our colour.
		paintRemember(inst, { "TextureId" })
		inst.TextureId = ""
	elseif inst:IsA("BodyColors") then
		paintRemember(inst, {
			"HeadColor", "TorsoColor", "LeftArmColor",
			"RightArmColor", "LeftLegColor", "RightLegColor",
		})
		inst.HeadColor = colour
		inst.TorsoColor = colour
		inst.LeftArmColor = colour
		inst.RightArmColor = colour
		inst.LeftLegColor = colour
		inst.RightLegColor = colour
	elseif inst:IsA("Highlight") then
		paintRemember(inst, { "FillColor", "OutlineColor" })
		inst.FillColor = colour
		inst.OutlineColor = colour
	end
end

-- put one instance back the way the game had it
local function paintRestoreOne(inst)
	local snap = paintOriginals[inst]
	if not snap then return end
	for field, value in pairs(snap) do
		pcall(function() inst[field] = value end)
	end
	paintOriginals[inst] = nil
end

local function paintWants(key)
	if paintSuppress or not state.paint then return false end
	if key == "enemy" then return state.paintEnemy == true end
	if key == "friendly" then return state.paintFriendly == true end
	return false
end

local function paintModel(model)
	for _, inst in ipairs(model:GetDescendants()) do
		-- one property the game locked down must not abort the whole sweep and leave
		-- every other unit half-painted
		pcall(paintOne, inst)
	end
end

local function paintRestoreModel(model)
	for _, inst in ipairs(model:GetDescendants()) do
		pcall(paintRestoreOne, inst)
	end
end

local function paintSweep()
	for key, container in pairs(PAINT_FOLDERS) do
		for _, model in ipairs(container:GetChildren()) do
			if model:IsA("Model") then
				local entry = paintTracked[model]
				if not entry then
					entry = { folder = key }
					paintTracked[model] = entry
					-- parts and accessories can be attached after the unit spawns
					entry.conn = model.DescendantAdded:Connect(function(inst)
						if paintWants(entry.folder) then pcall(paintOne, inst) end
					end)
				end
				-- a unit moved between folders has to follow the new setting
				entry.folder = key
				if paintWants(key) then paintModel(model) else paintRestoreModel(model) end
			end
		end
	end

	-- forget units that have left the NPC folders entirely, dropping their hook too
	for model, entry in pairs(paintTracked) do
		if not model:IsDescendantOf(npc) then
			if entry.conn then pcall(function() entry.conn:Disconnect() end) end
			paintTracked[model] = nil
		end
	end

	-- drop snapshots of instances the game has since destroyed
	paintTick += 1
	if paintTick % 20 == 0 then
		for inst in pairs(paintOriginals) do
			if not inst.Parent then paintOriginals[inst] = nil end
		end
	end
end

-- repaint only units already tracked, skipping the folder walk
local function paintRepaint()
	for model, entry in pairs(paintTracked) do
		if paintWants(entry.folder) then pcall(paintModel, model) end
	end
end

-- Give every unit back its own colours, then let go of the whole painter. Used by the Restore
-- button (which also drops the Enabled toggle) and by Stop. Painting has to be suppressed for
-- that sweep, otherwise it sees the units as still wanted and puts the paint straight back on.
local function paintRestoreAll()
	paintSuppress = true
	pcall(paintSweep)
	paintSuppress = false
	for model, entry in pairs(paintTracked) do
		if entry.conn then pcall(function() entry.conn:Disconnect() end) end
		paintTracked[model] = nil
	end
	paintOriginals = setmetatable({}, { __mode = "k" })
end

------------------------------------------------------------------ UI (Rayfield Gen2)
local WINDOW_NAME = "Stella Hub"
do
	local core = game:GetService("CoreGui")
	for _, d in ipairs(core:GetDescendants()) do
		if d.Name == WINDOW_NAME and d:IsA("Frame") then
			pcall(function() d:Destroy() end)
		end
	end
end

local window = Rayfield:CreateWindow({ name = WINDOW_NAME, subtitle = "Version 1" })
local tab = window:CreateTab({ name = "Main" })
local projTab = window:CreateTab({ name = "Projectiles" })
local funTab = window:CreateTab({ name = "Fun" })
local miscTab = window:CreateTab({ name = "Misc" })

-- Projectiles tab
projTab:CreateDivider({ text = "Enemy projectiles" })
projTab:CreateToggle({
	name = "Delete Enemy Projectiles",
	description = "Disables All Projectiles That exist In the game (Excluding the ones Your friendlies Use.)",
	value = false,
	callback = function(v) state.hitbox = v end,
})

projTab:CreateDivider({ text = "TP Projectiles to Enemy" })
do
	local opts = tpBuildOptions()
	tpDropdown = projTab:CreateDropdown({
		name = "Target enemy",
		description = "Select an enemy. All friendly projectiles will be redirected to them every frame. Highlighted in orange while selected.",
		options = opts,
		value = "None",
		forgetState = true,
		callback = function(label) tpSelectLabel(label) end,
	})
end
projTab:CreateButton({
	name = "Refresh enemy list",
	description = "Re-scans EnemyFolder and updates the dropdown (use after new enemies spawn).",
	callback = function()
		local opts = tpBuildOptions()
		if tpDropdown then pcall(function() tpDropdown:Refresh(opts) end) end
		if state.tpTarget and not state.tpTarget:IsDescendantOf(enemyFolder) then
			state.tpTarget = nil
			tpClearHighlight()
			if tpDropdown then pcall(function() tpDropdown:Set("None", true) end) end
		end
	end,
})

projTab:CreateToggle({
	name = "TP to enemy base",
	description = "Teleports every friendly projectile to the enemy base (Red Base) on each frame, using the same redirect as the unit target. Takes over from Target enemy while it is on. No highlight.",
	value = false,
	callback = function(v)
		state.tpBase = v
		if v then
			-- hand over cleanly: clear the unit target and its box so only the base is aimed at
			state.tpTarget = nil
			tpClearHighlight()
			if tpDropdown then pcall(function() tpDropdown:Set("None", true) end) end
		end
	end,
})

-- Main tab
tab:CreateDivider({ text = "Hazards and units" })
tab:CreateToggle({
	name = "Delete Gloom hazard",
	description = "Makes You Able to see Constantly On stages with Gloom Hazard.",
	value = false,
	callback = function(v)
		state.gloom = v
		if v then pcall(gloomScan) end
	end,
})
tab:CreateToggle({
	name = "Anti-hit Judgement / Punishment",
	description = "Friendly projectiles clip straight through Judgement and Punishment.",
	value = false,
	callback = function(v)
		state.anti = v
		if v then pcall(antiStep) else pcall(antiRestore) end
	end,
})
tab:CreateToggle({
	name = "Anti Depriver minigame",
	description = "Removes the Minigame Of Depriver.",
	value = false,
	callback = function(v)
		state.antiDepriver = v
		if v then pcall(depriverScan) else pcall(depriverRestore) end
	end,
})
tab:CreateToggle({
	name = "Enable HP bars",
	description = "Show the HP Of all Units on the field, Regardless of The difficulty.",
	value = false,
	callback = function(v)
		state.hpBars = v
		if v then pcall(hpBarScan) else pcall(hpBarRemove) end
	end,
})
tab:CreateToggle({
	name = "Anti GameK1d",
	description = "Makes You Immune to die To His Minigames, even on last heart.",
	value = false,
	callback = function(v)
		state.gamek1d = v
		if v then pcall(gamek1dScan) else pcall(gamek1dRestore) end
	end,
})

-- Fun tab
funTab:CreateDivider({ text = "Unit Painter" })
paintToggle = funTab:CreateToggle({
	name = "Unit Painter",
	description = "Paints All Units On the field using The colour selected.",
	value = state.paint,
	callback = function(v)
		state.paint = v
		pcall(paintSweep)
	end,
})
funTab:CreateColorPicker({
	name = "Paint colour",
	description = "Applied to every unit on the field the moment you change it.",
	color = state.paintColor,
	callback = function(c)
		state.paintColor = c
		-- Record the pick, do not paint here. Dragging across the picker fires this callback on
		-- every pointer move, and repainting inside it queued one full repaint per move. Those
		-- flushed one after another each carrying a stale colour, so the units visibly cycled
		-- through every colour the drag had passed over. The frame loop applies only the newest
		-- pick, at most once per frame.
		paintPending = c
	end,
})
funTab:CreateToggle({
	name = "Enemy units",
	description = "Paint the units in EnemyFolder.",
	value = state.paintEnemy,
	callback = function(v)
		state.paintEnemy = v
		pcall(paintSweep)
	end,
})
funTab:CreateToggle({
	name = "Friendly units",
	description = "Paint the units in FriendlyFolder.",
	value = state.paintFriendly,
	callback = function(v)
		state.paintFriendly = v
		pcall(paintSweep)
	end,
})
funTab:CreateButton({
	name = "Revert all Original Colours",
	description = "Restores every unit on the field to its original colours and turns the painter off.",
	callback = function()
		-- switch the painter off first so nothing repaints behind this: the restore sweep runs
		-- suppressed, then the toggle (if alive) is flipped to match.
		state.paint = false
		pcall(paintRestoreAll)
		if paintToggle then pcall(function() paintToggle:Set(false) end) end
	end,
})

-- Performance toggles
-- Potato Graphics (extreme): helper to strip one workspace object down as far as Roblox allows.
-- Original property values are saved in a weak table so toggling off can restore them.
local potatoSaved = setmetatable({}, { __mode = "k" })

local function potatoSave(obj, prop, value)
	local t = potatoSaved[obj]
	if not t then t = {} potatoSaved[obj] = t end
	if t[prop] == nil then t[prop] = value end
end

local function potatoStrip(obj)
	if obj:IsA("MeshPart") then
		potatoSave(obj, "TextureID", obj.TextureID)
		potatoSave(obj, "Material", obj.Material)
		potatoSave(obj, "Reflectance", obj.Reflectance)
		potatoSave(obj, "CastShadow", obj.CastShadow)
		pcall(function()
			obj.TextureID = 0
			obj.Material = Enum.Material.Plastic
			obj.Reflectance = 0
			obj.CastShadow = false
		end)
	elseif obj:IsA("BasePart") then
		potatoSave(obj, "Material", obj.Material)
		potatoSave(obj, "Reflectance", obj.Reflectance)
		potatoSave(obj, "CastShadow", obj.CastShadow)
		pcall(function()
			obj.Material = Enum.Material.Plastic
			obj.Reflectance = 0
			obj.CastShadow = false
		end)
	elseif obj:IsA("SpecialMesh") then
		potatoSave(obj, "TextureId", obj.TextureId)
		pcall(function() obj.TextureId = 0 end)
	elseif obj:IsA("Decal") or obj:IsA("Texture") then
		potatoSave(obj, "Transparency", obj.Transparency)
		pcall(function() obj.Transparency = 1 end)
	elseif obj:IsA("ParticleEmitter") or obj:IsA("Trail") then
		potatoSave(obj, "Enabled", obj.Enabled)
		pcall(function() obj.Enabled = false end)
	elseif obj:IsA("Fire") or obj:IsA("Smoke") or obj:IsA("Sparkles") or obj:IsA("SpotLight") then
		potatoSave(obj, "Enabled", obj.Enabled)
		pcall(function() obj.Enabled = false end)
	elseif obj:IsA("Explosion") then
		potatoSave(obj, "BlastPressure", obj.BlastPressure)
		potatoSave(obj, "BlastRadius", obj.BlastRadius)
		pcall(function()
			obj.BlastPressure = 1
			obj.BlastRadius = 1
		end)
	elseif obj:IsA("Shirt") then
		potatoSave(obj, "ShirtTemplate", obj.ShirtTemplate)
		pcall(function() obj.ShirtTemplate = 0 end)
	elseif obj:IsA("Pants") then
		potatoSave(obj, "PantsTemplate", obj.PantsTemplate)
		pcall(function() obj.PantsTemplate = 0 end)
	elseif obj:IsA("ShirtGraphic") then
		potatoSave(obj, "Graphic", obj.Graphic)
		pcall(function() obj.Graphic = 0 end)
	end
end

local potatoPostFx = {} -- Lighting post-effects we disabled, to restore on toggle off
local function potatoSweep()
	local light = game:GetService("Lighting")
	pcall(function()
		settings().GraphicsQualityLevel = 1
		settings().GlobalShadows = false
		settings().RenderQualityLevel = 1
		light.GlobalShadows = false
		light.FogEnd = 1
		light.FogStart = 1
		light.EnvironmentDiffuseScale = 0
		light.EnvironmentSpecularScale = 0
	end)
	-- Executor-only hidden properties: nuke lighting tech + terrain decoration, harmless if absent.
	if type(sethiddenproperty) == "function" then
		pcall(sethiddenproperty, light, "Technology", 2)
		local terrainHid = workspace:FindFirstChildOfClass("Terrain")
		if terrainHid then pcall(sethiddenproperty, terrainHid, "Decoration", false) end
	end
	for _, obj in ipairs(workspace:GetDescendants()) do
		pcall(function() potatoStrip(obj) end)
	end
	local terrain = workspace:FindFirstChildOfClass("Terrain")
	if terrain then
		potatoSave(terrain, "WaterWaveSize", terrain.WaterWaveSize)
		potatoSave(terrain, "WaterWaveSpeed", terrain.WaterWaveSpeed)
		potatoSave(terrain, "WaterReflectance", terrain.WaterReflectance)
		potatoSave(terrain, "WaterTransparency", terrain.WaterTransparency)
		pcall(function()
			terrain.WaterWaveSize = 0
			terrain.WaterWaveSpeed = 0
			terrain.WaterReflectance = 0
			terrain.WaterTransparency = 1
		end)
	end
	for _, fx in ipairs(light:GetChildren()) do
		if fx:IsA("PostEffect") then
			potatoSave(fx, "Enabled", fx.Enabled)
			pcall(function() fx.Enabled = false end)
			potatoPostFx[fx] = true
		end
	end
end

local function potatoRestore()
	local light = game:GetService("Lighting")
	pcall(function()
		settings().GraphicsQualityLevel = 8
		settings().GlobalShadows = true
		settings().RenderQualityLevel = 5
		light.GlobalShadows = true
		light.FogEnd = 100000
		light.FogStart = 0
		light.EnvironmentDiffuseScale = 1
		light.EnvironmentSpecularScale = 1
	end)
	for obj, props in pairs(potatoSaved) do
		for prop, value in pairs(props) do
			pcall(function() obj[prop] = value end)
		end
	end
	table.clear(potatoSaved)
	for fx in pairs(potatoPostFx) do
		pcall(function() fx.Enabled = true end)
	end
	table.clear(potatoPostFx)
end

miscTab:CreateToggle({
	name = "Potato Graphics (Extreme)",
	description = "Scraps EVERYTHING: lowest quality, no shadows, no textures, no decals, no meshes, no particles, no effects.",
	value = false,
	callback = function(v)
		state.perfPotato = v
		if v then
			pcall(potatoSweep)
		else
			pcall(potatoRestore)
		end
	end,
})


local lastUi, lastAnti, lastDepriver, lastBars, lastGamek1d, lastPaint, lastPotato = 0, 0, 0, 0, 0, 0, 0

local function Stop()
	for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	conns = {}
	pcall(antiRestore)
	pcall(depriverRestore)
	pcall(hpBarRemove)
	pcall(gamek1dRestore)
	pcall(tpClearHighlight)
	state.tpTarget = nil
	state.tpBase = false
	pcall(paintRestoreAll)
	if state.perfPotato then pcall(potatoRestore) end
	pcall(function() window:Destroy() end)
	-- window:Destroy() is a no-op on Rayfield Gen2 (its window table has no working Destroy),
	-- so the frame stays on screen after Stop and only the stale sweep below would remove it
	-- on the *next* load. Remove it here by name so Stop really does close the hub. Only the
	-- frame is destroyed, never its ScreenGui - Rayfield keeps that between loads.
	do
		local core = game:GetService("CoreGui")
		for _, d in ipairs(core:GetDescendants()) do
			if d.Name == WINDOW_NAME and d:IsA("Frame") then
				pcall(function() d:Destroy() end)
			end
		end
	end
	env.EnemyProjLift = nil
end
tab:CreateButton({ name = "Stop and unload", callback = Stop })

------------------------------------------------------------------ watchers
conns[#conns + 1] = folder.ChildAdded:Connect(function() pcall(projectileStep) end)
conns[#conns + 1] = workspace.DescendantAdded:Connect(function(d)
	if state.gloom and d.Name == "GloomPart" then
		task.defer(function() pcall(neuterGloomPart, d) end)
	end
	if state.hitbox and d.Name == "Ghostwalker" then
		task.defer(function() pcall(handleGhostwalker, d) end)
	end
	if state.perfPotato then
		task.defer(function() pcall(potatoStrip, d) end)
	end
end)
conns[#conns + 1] = playerGui.ChildAdded:Connect(function(g)
	if state.gloom and g.Name == "Gloom" then task.defer(function() purgeInstance(g) end) end
	if state.antiDepriver and g.Name == "ChustUI" then task.defer(function() pcall(depriverScan) end) end
	if state.gamek1d and g.Name == GAMEK1D_GUI then
		pcall(gamek1dHook)
		task.defer(function() pcall(gamek1dTame, g) end)
	end
end)
conns[#conns + 1] = Lighting.DescendantAdded:Connect(function(d)
	if state.gloom and d.Name == "Darkness" and d:IsA("ColorCorrectionEffect") then
		task.defer(function() pcall(purgeInstance, d) end)
	end
end)
conns[#conns + 1] = enemyFolder.DescendantAdded:Connect(function(d)
	if state.anti and d:IsA("BasePart") then
		local m = d
		while m and m.Parent ~= enemyFolder do m = m.Parent end
		if m and isAntiTarget(m) then antiPart(d) end
	end
end)
conns[#conns + 1] = game:GetService("ReplicatedStorage").Cutscenes.ChildAdded:Connect(function(c)
	if state.antiDepriver and c.Name == "ChustUI" then task.defer(function() pcall(depriverScan) end) end
end)
for _, unitFolder in ipairs({ enemyFolder, friendlyFolder, npc:FindFirstChild("BaseFolder") }) do
	if unitFolder then
		conns[#conns + 1] = unitFolder.ChildAdded:Connect(function()
			task.defer(function() pcall(hpBarScan) end)
		end)
	end
end
-- auto-refresh dropdown when enemies spawn/despawn
conns[#conns + 1] = enemyFolder.ChildAdded:Connect(function()
	task.defer(function()
		local opts = tpBuildOptions()
		if tpDropdown then pcall(function() tpDropdown:Refresh(opts) end) end
	end)
end)
conns[#conns + 1] = enemyFolder.ChildRemoved:Connect(function()
	task.defer(function()
		local opts = tpBuildOptions()
		if tpDropdown then pcall(function() tpDropdown:Refresh(opts) end) end
		if state.tpTarget and not state.tpTarget:IsDescendantOf(enemyFolder) then
			state.tpTarget = nil
			tpClearHighlight()
			if tpDropdown then pcall(function() tpDropdown:Set("None", true) end) end
		end
	end)
end)

pcall(gloomScan)
pcall(antiStep)
pcall(depriverScan)
pcall(hpBarScan)
pcall(gamek1dScan)
pcall(paintSweep)

conns[#conns + 1] = RunService.Heartbeat:Connect(function()
	pcall(projectileStep)
	pcall(gloomStep)
	pcall(tpStep)
	local now = os.clock()
	-- Drain a colour pick first: newest value only, at most once per frame.
	if paintPending then
		paintPending = nil
		pcall(paintRepaint)
	end
	if now - lastPaint > 0.5 then
		lastPaint = now
		pcall(paintSweep)
	end
	if now - lastAnti > 0.2 then
		lastAnti = now
		pcall(antiStep)
	end
	if now - lastDepriver > 1 then
		lastDepriver = now
		pcall(depriverScan)
	end
	if now - lastBars > 0.5 then
		lastBars = now
		pcall(hpBarScan)
	end
	if now - lastGamek1d > 0.25 then
		lastGamek1d = now
		pcall(gamek1dScan)
	end
	-- Potato Graphics stays aggressive: re-sweep every 5s so anything the game re-adds
	-- (textures, meshes, particles) gets stripped while the toggle is on.
	if state.perfPotato and now - lastPotato > 5 then
		lastPotato = now
		pcall(potatoSweep)
	end
end)

env.EnemyProjLift = {
	Stop = Stop,
	State = state,
	Decided = decided,
	AntiDepriver = { scan = depriverScan, restore = depriverRestore, name = CHUST_NAME },
	HPBars = { scan = hpBarScan, remove = hpBarRemove, styles = HPBAR_STYLES },
	GameK1d = { scan = gamek1dScan, restore = gamek1dRestore, gui = GAMEK1D_GUI },
	TP = { select = tpSelectLabel, buildOptions = tpBuildOptions },
	Paint = { sweep = paintSweep, repaint = paintRepaint, restore = paintRestoreAll },
}
pcall(function()
	window:Notify({ title = WINDOW_NAME, content = "Ready. TP Projectiles is in the Projectiles tab." })
end)
]==]

local chunk, cerr = loadstring(SRC, "=EnemyProjLift")
if not chunk then
    error("EnemyProjLift failed to compile:\n" .. tostring(cerr))
end

local ok, err = pcall(chunk)
if not ok then
    error("EnemyProjLift hit a runtime error:\n" .. tostring(err))
end