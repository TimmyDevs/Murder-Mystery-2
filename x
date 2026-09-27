--[[
    MM2 Hub (Obsidian UI)
    Farm + Combat + Fun in one script.

    Farm  : coins are Coin_Server parts in <Map>.CoinContainer, picked up by touch.
            The farm glides your character from coin to coin, skips coins near the
            murderer, and handles full bags (hide under the map / reset / stay).
    Combat: Sheriff auto-shoot murderer (Gun.Shoot) and Murderer kill-all
            (KnifeStabbed + HandleTouched).
    Fun   : spinbot, fly, infinite jump, spin fling, moon gravity, rainbow body.
]]

local REPO = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/"
local SCRIPT_NAME = "MM2 Hub"
local GAME_NAME = "MurderMystery2"
local SELF_PATH = "mm2_autofarm.lua"

if getgenv().Library and getgenv().Library.Unload and not getgenv().Library.Unloaded then
    pcall(getgenv().Library.Unload, getgenv().Library)
end

if not game:IsLoaded() then game.Loaded:Wait() end

local Library = loadstring(game:HttpGet(REPO .. "Library.lua"))()
local ThemeManager = loadstring(game:HttpGet(REPO .. "addons/ThemeManager.lua"))()
local SaveManager = loadstring(game:HttpGet(REPO .. "addons/SaveManager.lua"))()

local Options = Library.Options
local Toggles = Library.Toggles

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer
local env = getgenv()

local Connections = {}
local function track(conn)
    table.insert(Connections, conn)
    return conn
end

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local Gameplay = Remotes:WaitForChild("Gameplay")

local RoundClient
task.spawn(function()
    local ok, mod = pcall(require, ReplicatedStorage:WaitForChild("Modules"):WaitForChild("CurrentRoundClient"))
    if ok then RoundClient = mod end
end)

--// State \\--
local state = {
    bags = {},             -- bagName -> {n, max}
    sessionCoins = 0,
    roundCoins = 0,
    rounds = 0,
    startTime = os.clock(),
    startXP = LocalPlayer:GetAttribute("XP") or 0,
    startLevel = LocalPlayer:GetAttribute("Level") or 0,
    status = "Idle",
    hidden = false,
    resetThisRound = false,
    roundId = 0,
    busy = false,          -- true while the gun grab owns the character
    gunGrabs = 0,
}
env.MM2FarmState = state

track(Gameplay:WaitForChild("CoinsStarted").OnClientEvent:Connect(function()
    table.clear(state.bags)
    state.roundCoins = 0
    state.resetThisRound = false
    state.roundId += 1
    state.rounds += 1
end))

track(Gameplay:WaitForChild("CoinCollected").OnClientEvent:Connect(function(bag, n, max)
    if type(bag) ~= "string" or type(n) ~= "number" then return end
    local prev = state.bags[bag]
    local gained = n - (prev and prev.n or 0)
    if gained > 0 and gained < 20 then
        state.sessionCoins += gained
        state.roundCoins += gained
    end
    state.bags[bag] = { n = n, max = max or math.huge }
end))

--// Round helpers \\--
local function getChar()
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if hum and hrp and hum.Health > 0 then return char, hum, hrp end
end

-- Round maps carry a MapID attribute (seen live: MilBase has MapID "MilBase"); prefer those,
-- fall back to any model with a CoinContainer.
local function getMap()
    local fallback, fallbackCC
    for _, m in ipairs(workspace:GetChildren()) do
        if m:IsA("Model") then
            local cc = m:FindFirstChild("CoinContainer")
            if cc then
                if m:GetAttribute("MapID") then return m, cc end
                fallback, fallbackCC = fallback or m, fallbackCC or cc
            end
        end
    end
    return fallback, fallbackCC
end

local function myRound()
    local data = RoundClient and RoundClient.PlayerData
    return data and data[LocalPlayer.Name]
end

local function inRound()
    local me = myRound()
    return me ~= nil and not me.Dead and getMap() ~= nil
end

local function holderOf(toolName)
    for _, p in ipairs(Players:GetPlayers()) do
        local bp = p:FindFirstChild("Backpack")
        if (bp and bp:FindFirstChild(toolName)) or (p.Character and p.Character:FindFirstChild(toolName)) then
            return p
        end
    end
end

local function roleHolder(role)
    local data = RoundClient and RoundClient.PlayerData
    if data then
        for name, v in pairs(data) do
            if v.Role == role and not v.Dead then return Players:FindFirstChild(name) end
        end
    end
end

local function murderer()
    local p = roleHolder("Murderer") or holderOf("Knife")
    if p and p ~= LocalPlayer then return p end
end

-- Role for ESP: round data first, then whoever is holding the knife/gun.
local function roleOf(p)
    local data = RoundClient and RoundClient.PlayerData
    local d = data and data[p.Name]
    if d and d.Dead then return nil end
    local bp = p:FindFirstChild("Backpack")
    local char = p.Character
    local hasKnife = (bp and bp:FindFirstChild("Knife")) or (char and char:FindFirstChild("Knife"))
    local hasGun = (bp and bp:FindFirstChild("Gun")) or (char and char:FindFirstChild("Gun"))
    if hasKnife then return "Murderer" end
    if d and d.Role == "Murderer" then return "Murderer" end
    if hasGun then return (d and d.Role == "Sheriff") and "Sheriff" or "Hero" end
    if d then return d.Role == "Sheriff" and "Sheriff" or "Innocent" end
    return nil
end

-- The sheriff's gun drops on death as <Map>.GunDrop, a Part tagged "GunDrop" (seen live).
local CollectionService = game:GetService("CollectionService")
local function findGunDrop()
    for _, g in ipairs(CollectionService:GetTagged("GunDrop")) do
        if g:IsA("BasePart") and g:IsDescendantOf(workspace) then return g end
    end
    local g = workspace:FindFirstChild("GunDrop", true)
    if g and g:IsA("BasePart") then return g end
    if g and g:IsA("Model") then return g.PrimaryPart or g:FindFirstChildWhichIsA("BasePart", true) end
end

local function murdererPos()
    local m = murderer()
    local hrp = m and m.Character and m.Character:FindFirstChild("HumanoidRootPart")
    return hrp and hrp.Position, m
end

local function bagFull(id)
    local b = state.bags[id or "Coin"]
    return b ~= nil and b.n >= b.max
end

local function allBagsFull()
    local any = false
    for _, b in pairs(state.bags) do
        any = true
        if b.n < b.max then return false end
    end
    return any
end

local badCoins = setmetatable({}, { __mode = "k" }) -- coin -> failed arrivals
local function coinAlive(coin)
    if not coin or not coin.Parent or (badCoins[coin] or 0) >= 2 then return false end
    local v = coin:FindFirstChild("CoinVisual")
    return v ~= nil and not v:GetAttribute("Collected")
end

local function pickCoin(cc, hrp)
    local mpos = murdererPos()
    local safe = Options.SafeRadius.Value
    local avoid = Toggles.AvoidMurderer.Value and mpos ~= nil and myRound() and myRound().Role ~= "Murderer"
    local best, bestScore, fallback, fallbackD
    for _, c in ipairs(cc:GetChildren()) do
        if c.Name == "Coin_Server" and coinAlive(c) and not bagFull(c:GetAttribute("CoinID")) then
            local d = (c.Position - hrp.Position).Magnitude
            if avoid then
                local md = (c.Position - mpos).Magnitude
                if md >= safe then
                    if not bestScore or d < bestScore then best, bestScore = c, d end
                elseif not fallbackD or md > fallbackD then
                    fallback, fallbackD = c, md
                end
            elseif not bestScore or d < bestScore then
                best, bestScore = c, d
            end
        end
    end
    return best or (avoid and nil or fallback)
end

--// Movement \\--
local noclipConn
local function setNoclip(on)
    if on and not noclipConn then
        noclipConn = RunService.Stepped:Connect(function()
            local char = LocalPlayer.Character
            if not char then return end
            for _, p in ipairs(char:GetDescendants()) do
                if p:IsA("BasePart") and p.CanCollide then p.CanCollide = false end
            end
        end)
    elseif not on and noclipConn then
        noclipConn:Disconnect()
        noclipConn = nil
    end
end

local function unanchor()
    local _, _, hrp = getChar()
    if hrp and hrp.Anchored then hrp.Anchored = false end
    state.hidden = false
end

-- Tweens the root part to a target (same method the live test used). Cancels early when shouldStop() says so.
local TweenService = game:GetService("TweenService")
local function glideTo(getTarget, shouldStop, timeout)
    local _, _, hrp = getChar()
    local target = getTarget()
    if not hrp or not target then return false end
    local dist = (target - hrp.Position).Magnitude
    if dist < 1 then return true end
    local tween = TweenService:Create(hrp, TweenInfo.new(dist / Options.FarmSpeed.Value, Enum.EasingStyle.Linear), { CFrame = CFrame.new(target) })
    local finished = false
    local conn = tween.Completed:Connect(function() finished = true end)
    tween:Play()
    local t0 = os.clock()
    while not finished do
        task.wait(0.05)
        if Library.Unloaded or not getChar() or (shouldStop and shouldStop()) or os.clock() - t0 > (timeout or 30) then
            tween:Cancel()
            conn:Disconnect()
            return false
        end
    end
    conn:Disconnect()
    return true
end

local function murdererTooClose()
    if not Toggles.AvoidMurderer.Value then return false end
    local me = myRound()
    if me and me.Role == "Murderer" then return false end
    local mpos = murdererPos()
    local _, _, hrp = getChar()
    return mpos ~= nil and hrp ~= nil and (mpos - hrp.Position).Magnitude < Options.PanicRadius.Value
end

local function hideUnderMap(map)
    local _, _, hrp = getChar()
    if not hrp or state.hidden then return end
    local cf, size = map:GetBoundingBox()
    local bottom = cf.Position.Y - size.Y / 2 - 20
    local spot = Vector3.new(hrp.Position.X, bottom, hrp.Position.Z)
    state.status = "Bag full: hiding under the map"
    glideTo(function() return spot end, function() return state.busy or not Toggles.AutoFarm.Value end, 20)
    local _, _, hrp2 = getChar()
    if hrp2 and Toggles.AutoFarm.Value then
        hrp2.AssemblyLinearVelocity = Vector3.zero
        hrp2.Anchored = true
        state.hidden = true
    end
end

local function onBagFull(map)
    if Toggles.AutoEndgame and Toggles.AutoEndgame.Value then
        state.status = "Bag full: running endgame combo"
        return
    end
    local action = Options.FullAction.Value
    if action == "Hide under map" then
        hideUnderMap(map)
    elseif action == "Reset character" then
        if not state.resetThisRound then
            state.resetThisRound = true
            local _, hum = getChar()
            if hum then hum.Health = 0 end
        end
        state.status = "Bag full: reset, waiting for next round"
    else
        state.status = "Bag full: standing by"
    end
end

--// Farm loop (started after the UI exists) \\--
local function farmLoop()
    local lastRound = -1
    while not Library.Unloaded do
        if state.busy then
            task.wait(0.1)
            continue
        end
        if not Toggles.AutoFarm.Value then
            setNoclip(false)
            if state.hidden then unanchor() end
            state.status = "Idle"
            task.wait(0.25)
            continue
        end

        local map, cc = getMap()
        local me = myRound()
        local char, hum, hrp = getChar()

        if state.roundId ~= lastRound then
            lastRound = state.roundId
            if state.hidden then unanchor() end
        end

        if not (map and me and char) then
            setNoclip(false)
            if state.hidden then unanchor() end
            state.status = me and me.Dead and "Dead, waiting for next round" or "Waiting for a round"
            task.wait(0.5)
            continue
        end
        if me.Dead then
            state.status = "Dead, waiting for next round"
            task.wait(0.5)
            continue
        end
        if me.Role == "Murderer" and not Toggles.FarmAsMurderer.Value then
            state.status = "You're the murderer (farm paused)"
            task.wait(0.5)
            continue
        end

        if allBagsFull() then
            setNoclip(true)
            onBagFull(map)
            task.wait(0.5)
            continue
        end
        if state.hidden then unanchor() end

        local coin = pickCoin(cc, hrp)
        if not coin then
            state.status = murdererTooClose() and "Murderer nearby, waiting" or "No coins available, waiting"
            if Toggles.HideWhenIdle.Value then hideUnderMap(map) end
            task.wait(0.3)
            continue
        end
        if state.hidden then unanchor() end

        setNoclip(true)
        state.status = string.format("Going to coin (%.0f studs)", (coin.Position - hrp.Position).Magnitude)
        local reached = glideTo(
            function() return coin.Parent and coin.Position end,
            function()
                return state.busy or not Toggles.AutoFarm.Value or not coinAlive(coin) or murdererTooClose()
            end,
            25
        )
        if reached then
            local t0 = os.clock()
            while coinAlive(coin) and os.clock() - t0 < 0.5 do RunService.Heartbeat:Wait() end
            if coinAlive(coin) then
                -- touch didn't register: step off and let the next pass re-touch it, give up after 2
                badCoins[coin] = (badCoins[coin] or 0) + 1
                local _, _, hrp2 = getChar()
                if hrp2 then hrp2.CFrame = hrp2.CFrame + Vector3.new(0, 3, 0) end
            end
        end
        task.wait(Options.CoinDelay.Value)
    end
end

--// Anti-AFK \\--
track(LocalPlayer.Idled:Connect(function()
    if not Toggles.AntiAFK.Value then return end
    local vu = game:GetService("VirtualUser")
    vu:CaptureController()
    vu:ClickButton2(Vector2.new())
end))

--// Keep loading after server hop \\--
local function queueSelf()
    if not queue_on_teleport or env.MM2FarmQueued then return end
    if not (isfile and isfile(SELF_PATH)) then return end
    env.MM2FarmQueued = true
    queue_on_teleport(string.format([[
        if not game:IsLoaded() then game.Loaded:Wait() end
        task.wait(3)
        getgenv().MM2FarmAutoStart = true
        local ok, src = pcall(readfile, %q)
        if ok and src then pcall(function() loadstring(src)() end) end
    ]], SELF_PATH))
end

--// UI \\--
local Window = Library:CreateWindow({
    Title = SCRIPT_NAME,
    Footer = GAME_NAME .. " | v1.6",
    NotifySide = "Right",
    ShowCustomCursor = false,
    Center = true,
    AutoShow = true,
})

local Tabs = {
    Main = Window:AddTab("Farm", "coins"),
    Player = Window:AddTab("Player", "user"),
    ["UI Settings"] = Window:AddTab("UI Settings", "settings"),
}

local FarmBox = Tabs.Main:AddLeftGroupbox("Coin Farm", "coins")
FarmBox:AddToggle("AutoFarm", {
    Text = "Auto Farm Coins",
    Default = false,
    Tooltip = "Glides to every coin on the map until your bag is full",
}):AddKeyPicker("AutoFarmKey", { Default = "F", Mode = "Toggle", SyncToggleState = true, Text = "Auto Farm" })
FarmBox:AddSlider("FarmSpeed", {
    Text = "Move Speed",
    Default = 24, Min = 16, Max = 30, Rounding = 0, Suffix = " studs/s",
    Tooltip = "25 was tested safe. 40 got kicked, so it's capped at 30",
})
FarmBox:AddSlider("CoinDelay", { Text = "Delay Between Coins", Default = 0, Min = 0, Max = 2, Rounding = 1, Suffix = "s" })
FarmBox:AddDropdown("FullAction", {
    Text = "When Bag Is Full",
    Values = { "Hide under map", "Reset character", "Stand still" },
    Default = "Hide under map",
    Tooltip = "Hiding keeps you alive for the survival XP",
})
FarmBox:AddToggle("FarmAsMurderer", { Text = "Farm While Murderer", Default = true })
FarmBox:AddToggle("HideWhenIdle", { Text = "Hide While Waiting For Coins", Default = false, Tooltip = "Waits under the map when no safe coin is left" })

local SafeBox = Tabs.Main:AddLeftGroupbox("Safety", "shield")
SafeBox:AddToggle("AvoidMurderer", { Text = "Avoid Murderer", Default = true, Tooltip = "Skips coins near the knife holder and backs off when they get close" })
SafeBox:AddSlider("SafeRadius", { Text = "Skip Coins Within", Default = 25, Min = 5, Max = 80, Rounding = 0, Suffix = " studs of murderer" })
SafeBox:AddSlider("PanicRadius", { Text = "Back Off When Murderer Within", Default = 18, Min = 5, Max = 60, Rounding = 0, Suffix = " studs" })
SafeBox:AddToggle("AntiAFK", { Text = "Anti AFK", Default = true })
SafeBox:AddToggle("KeepLoading", {
    Text = "Keep Loading After Server Hop",
    Default = true,
    Tooltip = "Re-runs this script (from " .. SELF_PATH .. " in your executor workspace) when you join a new server",
    Callback = function(v) if v then queueSelf() end end,
})

local StatusBox = Tabs.Main:AddRightGroupbox("Status", "activity")
local StatusLabel = StatusBox:AddLabel("Idle", true)
local RoundLabel = StatusBox:AddLabel("", true)
local BagLabel = StatusBox:AddLabel("", true)

local StatsBox = Tabs.Main:AddRightGroupbox("Session", "chart-line")
local StatsLabel = StatsBox:AddLabel("", true)
StatsBox:AddButton({
    Text = "Reset Stats",
    Func = function()
        state.sessionCoins = 0
        state.rounds = 0
        state.startTime = os.clock()
        state.startXP = LocalPlayer:GetAttribute("XP") or 0
        state.startLevel = LocalPlayer:GetAttribute("Level") or 0
    end,
})

local MoveBox = Tabs.Player:AddLeftGroupbox("Movement", "footprints")
MoveBox:AddToggle("SpeedEnabled", { Text = "WalkSpeed", Default = false })
MoveBox:AddSlider("SpeedValue", { Text = "Speed", Default = 16, Min = 16, Max = 30, Rounding = 0 })
track(RunService.Heartbeat:Connect(function()
    if not Toggles.SpeedEnabled.Value then return end
    local _, hum = getChar()
    if hum then hum.WalkSpeed = Options.SpeedValue.Value end
end))

--// Auto grab gun \\--
local GunBox = Tabs.Main:AddRightGroupbox("Gun", "crosshair")
GunBox:AddToggle("AutoGrabGun", { Text = "Auto Grab Dropped Gun", Default = false, Tooltip = "Teleports onto the gun the moment the sheriff drops it" })
GunBox:AddToggle("GunReturn", { Text = "Teleport Back After Grab", Default = true })
GunBox:AddToggle("GunSafeCheck", { Text = "Skip If Murderer Is On The Gun", Default = true })
GunBox:AddSlider("GunSafeRadius", { Text = "Murderer Distance From Gun", Default = 15, Min = 5, Max = 50, Rounding = 0, Suffix = " studs" })
GunBox:AddButton({ Text = "Grab Gun Now", Func = function() env.MM2GrabNow = true end })

local function grabGun(force)
    local gun = findGunDrop()
    local _, _, hrp = getChar()
    local me = myRound()
    if not (gun and hrp and me) or me.Dead then return end
    if roleOf(LocalPlayer) == "Murderer" then return end
    if not force and Toggles.GunSafeCheck.Value then
        local mpos = murdererPos()
        if mpos and (mpos - gun.Position).Magnitude < Options.GunSafeRadius.Value then
            state.status = "Gun dropped, murderer is camping it"
            return
        end
    end
    state.busy = true
    local ok = pcall(function()
        if hrp.Anchored then hrp.Anchored = false state.hidden = false end
        local back = hrp.CFrame
        local t0 = os.clock()
        while gun.Parent and os.clock() - t0 < 1.5 do
            hrp.CFrame = CFrame.new(gun.Position)
            hrp.AssemblyLinearVelocity = Vector3.zero
            RunService.Heartbeat:Wait()
            if holderOf("Gun") == LocalPlayer then break end
        end
        if holderOf("Gun") == LocalPlayer then state.gunGrabs += 1 end
        if Toggles.GunReturn.Value then
            task.wait(0.15)
            local _, _, hrp2 = getChar()
            if hrp2 then hrp2.CFrame = back end
        end
    end)
    state.busy = false
    return ok
end

task.spawn(function()
    while not Library.Unloaded do
        local force = env.MM2GrabNow
        env.MM2GrabNow = nil
        if (force or Toggles.AutoGrabGun.Value) and findGunDrop() then grabGun(force) end
        task.wait(0.1)
    end
end)

--// Anti fling \\--
local SafeExtra = Tabs.Main:AddLeftGroupbox("Protection", "shield-check")
SafeExtra:AddToggle("AntiFling", { Text = "Anti Fling", Default = true, Tooltip = "Other players can't push you, and any crazy spin/launch on you gets cancelled" })
track(RunService.Stepped:Connect(function()
    if not Toggles.AntiFling.Value then return end
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and p.Character then
            for _, part in ipairs(p.Character:GetChildren()) do
                if part:IsA("BasePart") and part.CanCollide then part.CanCollide = false end
            end
        end
    end
    local _, _, hrp = getChar()
    if hrp and not hrp.Anchored then
        if hrp.AssemblyAngularVelocity.Magnitude > 40 then hrp.AssemblyAngularVelocity = Vector3.zero end
        local v = hrp.AssemblyLinearVelocity
        if v.Magnitude > 150 then hrp.AssemblyLinearVelocity = Vector3.new(0, math.clamp(v.Y, -60, 60), 0) end
    end
end))

--// ESP + X-ray \\--
local EspTab = Window:AddTab("Visuals", "eye")
local PlayerEspBox = EspTab:AddLeftGroupbox("Player ESP", "users")
PlayerEspBox:AddToggle("PlayerESP", { Text = "Player ESP", Default = false })
PlayerEspBox:AddToggle("EspMurderer", { Text = "Murderer", Default = true }):AddColorPicker("ColMurderer", { Default = Color3.fromRGB(255, 50, 50) })
PlayerEspBox:AddToggle("EspSheriff", { Text = "Sheriff / Hero", Default = true }):AddColorPicker("ColSheriff", { Default = Color3.fromRGB(60, 140, 255) })
PlayerEspBox:AddToggle("EspInnocent", { Text = "Innocents", Default = true }):AddColorPicker("ColInnocent", { Default = Color3.fromRGB(80, 255, 120) })
PlayerEspBox:AddToggle("EspNames", { Text = "Name, Role, Distance", Default = true })
PlayerEspBox:AddToggle("EspFill", { Text = "Fill Body", Default = true })

local ItemEspBox = EspTab:AddRightGroupbox("Item ESP", "coins")
ItemEspBox:AddToggle("CoinESP", { Text = "Coin ESP", Default = false }):AddColorPicker("ColCoin", { Default = Color3.fromRGB(255, 215, 0) })
ItemEspBox:AddToggle("GunESP", { Text = "Dropped Gun ESP", Default = true }):AddColorPicker("ColGun", { Default = Color3.fromRGB(60, 140, 255) })

local WorldBox = EspTab:AddRightGroupbox("World", "globe")
WorldBox:AddToggle("Xray", { Text = "X-Ray", Default = false, Tooltip = "Makes the map see-through (only for you)" })
WorldBox:AddSlider("XrayAmount", { Text = "X-Ray Strength", Default = 0.6, Min = 0.1, Max = 0.95, Rounding = 2 })

local espFolder = Instance.new("Folder")
espFolder.Name = "MM2FarmESP"
espFolder.Parent = (gethui and gethui()) or game:GetService("CoreGui")

local function makeBillboard(adornee, color, size)
    local bb = Instance.new("BillboardGui")
    bb.AlwaysOnTop = true
    bb.Size = size or UDim2.fromOffset(200, 36)
    bb.StudsOffset = Vector3.new(0, 3, 0)
    bb.Adornee = adornee
    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = UDim2.fromScale(1, 1)
    label.Font = Enum.Font.GothamBold
    label.TextSize = 13
    label.TextStrokeTransparency = 0.3
    label.TextColor3 = color
    label.Parent = bb
    bb.Parent = espFolder
    return bb, label
end

local playerEsp = {} -- player -> {hl, bb, label}
local function clearPlayerEsp(p)
    local e = playerEsp[p]
    if e then
        if e.hl then e.hl:Destroy() end
        if e.bb then e.bb:Destroy() end
        playerEsp[p] = nil
    end
end

local roleColor = {
    Murderer = function() return Options.ColMurderer.Value end,
    Sheriff = function() return Options.ColSheriff.Value end,
    Hero = function() return Options.ColSheriff.Value end,
    Innocent = function() return Options.ColInnocent.Value end,
}
local roleShown = {
    Murderer = function() return Toggles.EspMurderer.Value end,
    Sheriff = function() return Toggles.EspSheriff.Value end,
    Hero = function() return Toggles.EspSheriff.Value end,
    Innocent = function() return Toggles.EspInnocent.Value end,
}

local function updatePlayerEsp()
    local _, _, myHrp = getChar()
    for _, p in ipairs(Players:GetPlayers()) do
        if p == LocalPlayer then continue end
        local char = p.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        local role = Toggles.PlayerESP.Value and hrp and roleOf(p)
        if not (role and roleShown[role]()) then
            clearPlayerEsp(p)
            continue
        end
        local color = roleColor[role]()
        local e = playerEsp[p]
        if not e or not e.hl.Parent or e.hl.Adornee ~= char then
            clearPlayerEsp(p)
            e = {}
            e.hl = Instance.new("Highlight")
            e.hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
            e.hl.Adornee = char
            e.hl.Parent = espFolder
            e.bb, e.label = makeBillboard(char:FindFirstChild("Head") or hrp, color)
            playerEsp[p] = e
        end
        e.hl.FillColor = color
        e.hl.OutlineColor = color
        e.hl.FillTransparency = Toggles.EspFill.Value and 0.65 or 1
        e.bb.Enabled = Toggles.EspNames.Value
        e.label.TextColor3 = color
        local dist = myHrp and math.floor((hrp.Position - myHrp.Position).Magnitude) or 0
        e.label.Text = string.format("%s\n%s | %dm", p.DisplayName, role, dist)
    end
    for p in pairs(playerEsp) do
        if not p.Parent then clearPlayerEsp(p) end
    end
end

local coinEsp = {} -- coin -> billboard
local function updateCoinEsp()
    local _, cc = getMap()
    local want = {}
    if Toggles.CoinESP.Value and cc then
        for _, c in ipairs(cc:GetChildren()) do
            if c.Name == "Coin_Server" and coinAlive(c) then want[c] = true end
        end
    end
    for c, bb in pairs(coinEsp) do
        if not want[c] then bb:Destroy() coinEsp[c] = nil end
    end
    for c in pairs(want) do
        local bb = coinEsp[c]
        if not bb then
            bb = Instance.new("BillboardGui")
            bb.AlwaysOnTop = true
            bb.Size = UDim2.fromOffset(10, 10)
            bb.Adornee = c
            local dot = Instance.new("Frame")
            dot.Size = UDim2.fromScale(1, 1)
            dot.BorderSizePixel = 0
            Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)
            dot.Parent = bb
            bb.Parent = espFolder
            coinEsp[c] = bb
        end
        bb.Frame.BackgroundColor3 = Options.ColCoin.Value
    end
end

local gunEsp = {}
local function updateGunEsp()
    local gun = Toggles.GunESP.Value and findGunDrop()
    if not gun then
        if gunEsp.hl then gunEsp.hl:Destroy() gunEsp.bb:Destroy() gunEsp = {} end
        return
    end
    if gunEsp.adornee ~= gun or not gunEsp.hl or not gunEsp.hl.Parent then
        if gunEsp.hl then gunEsp.hl:Destroy() gunEsp.bb:Destroy() end
        gunEsp = { adornee = gun }
        gunEsp.hl = Instance.new("Highlight")
        gunEsp.hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        gunEsp.hl.Adornee = gun
        gunEsp.hl.Parent = espFolder
        gunEsp.bb, gunEsp.label = makeBillboard(gun, Options.ColGun.Value, UDim2.fromOffset(120, 24))
    end
    local _, _, myHrp = getChar()
    local color = Options.ColGun.Value
    gunEsp.hl.FillColor = color
    gunEsp.hl.OutlineColor = color
    gunEsp.label.TextColor3 = color
    gunEsp.label.Text = string.format("GUN | %dm", myHrp and math.floor((gun.Position - myHrp.Position).Magnitude) or 0)
end

local xrayParts = {} -- part -> true
local function clearXray()
    for part in pairs(xrayParts) do
        if part.Parent then part.LocalTransparencyModifier = 0 end
    end
    table.clear(xrayParts)
end
local function updateXray()
    if not Toggles.Xray.Value then
        if next(xrayParts) then clearXray() end
        return
    end
    local amount = Options.XrayAmount.Value
    local roots = {}
    local map = getMap()
    if map then table.insert(roots, map) end
    local lobby = workspace:FindFirstChild("RegularLobby")
    if lobby then table.insert(roots, lobby) end
    for _, root in ipairs(roots) do
        for _, part in ipairs(root:GetDescendants()) do
            if part:IsA("BasePart") and part.Name ~= "Coin_Server" and not part:IsDescendantOf(root:FindFirstChild("CoinContainer") or espFolder) then
                if part.LocalTransparencyModifier ~= amount then part.LocalTransparencyModifier = amount end
                xrayParts[part] = true
            end
        end
    end
    for part in pairs(xrayParts) do
        if not part.Parent then xrayParts[part] = nil end
    end
end

task.spawn(function()
    local tick = 0
    while not Library.Unloaded do
        pcall(updatePlayerEsp)
        pcall(updateGunEsp)
        if tick % 2 == 0 then pcall(updateCoinEsp) end
        if tick % 5 == 0 then pcall(updateXray) end
        tick += 1
        task.wait(0.2)
    end
end)

--// Skin changer (client-side only) \\--
-- MM2 skin models are private assets, so skins can't be loaded by ID. Instead every
-- knife/gun skin seen on anyone (lobby back-display or in-round tool) is saved to
-- SKIN_FILE as mesh + texture, then rebuilt over your own weapon on demand.
local clearSkins
do
    local HttpService = game:GetService("HttpService")
    local AssetService = game:GetService("AssetService")
    local SKIN_FILE = "mm2_skins.json"
    local ItemDB = {}
    pcall(function() ItemDB = require(ReplicatedStorage:WaitForChild("Database"):WaitForChild("Sync")).Item end)

    local library = {} -- key -> {type, class, mesh, tex, scale, offset, size, name}
    pcall(function()
        if isfile(SKIN_FILE) then library = HttpService:JSONDecode(readfile(SKIN_FILE)) end
    end)
    local liveSource = {} -- key -> a live part showing that skin (cloned to keep particles)

    local function v3(t) return Vector3.new(t[1], t[2], t[3]) end
    local function arr(v) return { v.X, v.Y, v.Z } end

    local function record(key, kind, part)
        if not key or not part or not part:IsA("BasePart") then return false end
        liveSource[key] = part
        if library[key] then return false end
        local entry = { type = kind, name = (ItemDB[key] and ItemDB[key].ItemName) or key, size = arr(part.Size) }
        local sm = part:FindFirstChildWhichIsA("SpecialMesh")
        if part:IsA("MeshPart") then
            entry.class, entry.mesh, entry.tex = "MeshPart", part.MeshId, part.TextureID
        elseif sm then
            entry.class, entry.mesh, entry.tex = "SpecialMesh", sm.MeshId, sm.TextureId
            entry.scale, entry.offset = arr(sm.Scale), arr(sm.Offset)
        else
            return false
        end
        library[key] = entry
        return true
    end

    local function harvest()
        local added = false
        for _, p in ipairs(Players:GetPlayers()) do
            local char = p.Character
            for _, kind in ipairs({ "Knife", "Gun" }) do
                local key = p:GetAttribute("Equipped" .. kind)
                local ref = char and char:FindFirstChild("DisplayRef" .. kind)
                if key and ref and ref.Value and not ref.Value:GetAttribute("MM2SkinHidden") then
                    added = record(key, kind, ref.Value) or added
                end
                local bp = p:FindFirstChild("Backpack")
                local tool = (bp and bp:FindFirstChild(kind)) or (char and char:FindFirstChild(kind))
                local handle = tool and tool:FindFirstChild("Handle")
                local data = tool and tool:FindFirstChild("ItemData")
                if handle and data and not handle:GetAttribute("MM2SkinHidden") then
                    local ok, t = pcall(require, data)
                    local dataKey = ok and type(t) == "table" and next(t)
                    added = record(dataKey or key, kind, handle) or added
                end
            end
        end
        if added then pcall(writefile, SKIN_FILE, HttpService:JSONEncode(library)) end
        return added
    end

    -- Builds a visual copy of a skin: clone of a live part when available, else rebuilt from the saved mesh.
    local function buildVisual(key)
        local src = liveSource[key]
        local vis
        if src and src.Parent and not src:GetAttribute("MM2SkinHidden") then
            vis = src:Clone()
            for _, d in ipairs(vis:GetDescendants()) do
                if d.Name == "MM2SkinOverlay" or d:IsA("Constraint") or d:IsA("JointInstance") or d:IsA("TouchTransmitter") or d:IsA("Sound") or d:IsA("Script") or d:IsA("LocalScript") then d:Destroy() end
            end
            for _, a in ipairs({ "MM2SkinHidden", "MM2SkinKey", "MM2SkinOrigTransparency" }) do vis:SetAttribute(a, nil) end
        else
            local e = library[key]
            if not e then return end
            if e.class == "MeshPart" then
                local ok, mp = pcall(function() return AssetService:CreateMeshPartAsync(Content.fromUri(e.mesh)) end)
                if not ok or not mp then return end
                vis = mp
                vis.TextureID = e.tex or ""
            else
                vis = Instance.new("Part")
                local sm = Instance.new("SpecialMesh")
                sm.MeshType = Enum.MeshType.FileMesh
                sm.MeshId, sm.TextureId = e.mesh, e.tex or ""
                if e.scale then sm.Scale = v3(e.scale) end
                if e.offset then sm.Offset = v3(e.offset) end
                sm.Parent = vis
            end
            vis.Size = v3(e.size)
        end
        vis.Name = "MM2SkinOverlay"
        vis.Anchored = false
        vis.CanCollide, vis.CanTouch, vis.CanQuery, vis.Massless = false, false, false, true
        vis.Transparency = 0
        return vis
    end

    local function restore(part)
        if not part or not part:GetAttribute("MM2SkinHidden") then return end
        local old = part:FindFirstChild("MM2SkinOverlay")
        if old then old:Destroy() end
        part.Transparency = part:GetAttribute("MM2SkinOrigTransparency") or 0
        for _, d in ipairs(part:GetDescendants()) do
            if (d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Light")) and d:GetAttribute("MM2SkinWasOn") then d.Enabled = true end
            if d:IsA("Decal") and d:GetAttribute("MM2SkinOrigT") then d.Transparency = d:GetAttribute("MM2SkinOrigT") end
        end
        part:SetAttribute("MM2SkinHidden", nil)
        part:SetAttribute("MM2SkinKey", nil)
    end

    local function apply(part, key)
        if not part or not key then return end
        if part:GetAttribute("MM2SkinKey") == key and part:FindFirstChild("MM2SkinOverlay") then return end
        restore(part)
        local vis = buildVisual(key)
        if not vis then return end
        part:SetAttribute("MM2SkinOrigTransparency", part.Transparency)
        part.Transparency = 1
        for _, d in ipairs(part:GetDescendants()) do
            if (d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Light")) and d.Enabled then d:SetAttribute("MM2SkinWasOn", true) d.Enabled = false end
            if d:IsA("Decal") then d:SetAttribute("MM2SkinOrigT", d.Transparency) d.Transparency = 1 end
        end
        vis.CFrame = part.CFrame
        local weld = Instance.new("WeldConstraint")
        weld.Part0, weld.Part1 = part, vis
        weld.Parent = vis
        vis.Parent = part
        part:SetAttribute("MM2SkinHidden", true)
        part:SetAttribute("MM2SkinKey", key)
    end

    local function myWeaponParts(kind)
        local parts = {}
        local char = LocalPlayer.Character
        local bp = LocalPlayer:FindFirstChild("Backpack")
        local tool = (bp and bp:FindFirstChild(kind)) or (char and char:FindFirstChild(kind))
        if tool and tool:FindFirstChild("Handle") then table.insert(parts, tool.Handle) end
        local ref = char and char:FindFirstChild("DisplayRef" .. kind)
        if ref and ref.Value then table.insert(parts, ref.Value) end
        return parts
    end

    --// Skin browser UI \\--
    local RarityDB = {}
    pcall(function() RarityDB = require(ReplicatedStorage.Database.Sync).Rarities end)
    local function rarityColor(r)
        local d = RarityDB[r]
        return d and Color3.fromRGB(d.Color.r, d.Color.g, d.Color.b) or Color3.fromRGB(150, 150, 150)
    end
    local function rarityName(r) return (RarityDB[r] and RarityDB[r].Name) or r or "?" end
    local function raritySort(r) return (RarityDB[r] and RarityDB[r].Sort) or 200 end -- lower = rarer

    -- Item images are old Thumbs/Asset URLs; rbxthumb renders any of them.
    local function imageUrl(img)
        if type(img) ~= "string" then return "" end
        if img:find("^rbxthumb") then return img end
        local id = img:match("assetId=(%d+)") or img:match("[?&]id=(%d+)") or img:match("rbxassetid://(%d+)")
        return id and ("rbxthumb://type=Asset&id=" .. id .. "&w=150&h=150") or img
    end

    local CHOICE_FILE = "mm2_skin_choice.json"
    local choice = {}
    pcall(function() if isfile(CHOICE_FILE) then choice = HttpService:JSONDecode(readfile(CHOICE_FILE)) end end)
    local function saveChoice() pcall(writefile, CHOICE_FILE, HttpService:JSONEncode(choice)) end

    local catalog = { Knife = {}, Gun = {} }
    for key, item in pairs(ItemDB) do
        if type(item) == "table" and catalog[item.ItemType] then
            table.insert(catalog[item.ItemType], {
                key = key, name = item.ItemName or key, rarity = item.Rarity,
                event = item.Event, year = item.Year, image = imageUrl(item.Image), chroma = item.Chroma,
            })
        end
    end
    for _, list in pairs(catalog) do
        table.sort(list, function(a, b)
            local ra, rb = raritySort(a.rarity), raritySort(b.rarity)
            if ra ~= rb then return ra < rb end
            return a.name < b.name
        end)
    end
    -- Skins seen live that the database doesn't list still get a card.
    local function ensureCatalog()
        for key, e in pairs(library) do
            local list = catalog[e.type]
            if list and not ItemDB[key] then
                local found = false
                for _, it in ipairs(list) do if it.key == key then found = true break end end
                if not found then table.insert(list, 1, { key = key, name = e.name or key, rarity = "Common", image = "" }) end
            end
        end
    end
    ensureCatalog()

    local selectedKey, selectedType, page = nil, "Knife", 1
    local PER_PAGE, COLS = 12, 3
    local Scheme = Library.Scheme or {}
    local cMain = Scheme.MainColor or Color3.fromRGB(25, 25, 25)
    local cBack = Scheme.BackgroundColor or Color3.fromRGB(15, 15, 15)
    local cFont = Scheme.FontColor or Color3.new(1, 1, 1)
    local cAccent = Scheme.AccentColor or Color3.fromRGB(125, 85, 255)

    local SkinTab = Window:AddTab("Skins", "palette")
    local BrowseBox = SkinTab:AddLeftGroupbox("Skin Browser", "layout-grid")
    local PreviewBox = SkinTab:AddRightGroupbox("Preview", "eye")

    local renderPage -- forward
    BrowseBox:AddInput("SkinSearch", { Text = "Search", Placeholder = "skin name...", Finished = false, Callback = function() page = 1 if renderPage then renderPage() end end })
    BrowseBox:AddDropdown("SkinType", { Text = "Weapon", Values = { "Knife", "Gun" }, Default = "Knife", Callback = function(v) selectedType = v page = 1 if renderPage then renderPage() end end })
    BrowseBox:AddDropdown("SkinShow", { Text = "Show", Values = { "All skins", "Collected only" }, Default = "All skins", Callback = function() page = 1 if renderPage then renderPage() end end })

    -- Grid + pager, embedded in the groupbox.
    local gridRoot = Instance.new("Frame")
    gridRoot.BackgroundTransparency = 1
    gridRoot.Size = UDim2.fromScale(1, 1)
    local grid = Instance.new("Frame")
    grid.BackgroundTransparency = 1
    grid.Size = UDim2.new(1, 0, 1, -30)
    grid.Parent = gridRoot
    local layout = Instance.new("UIGridLayout")
    layout.CellSize = UDim2.new(1 / COLS, -6, 0, 104)
    layout.CellPadding = UDim2.fromOffset(6, 6)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = grid

    local pager = Instance.new("Frame")
    pager.BackgroundTransparency = 1
    pager.Size = UDim2.new(1, 0, 0, 24)
    pager.Position = UDim2.new(0, 0, 1, -24)
    pager.Parent = gridRoot
    local function pagerButton(text, xScale, anchor)
        local b = Instance.new("TextButton")
        b.Size = UDim2.fromOffset(60, 24)
        b.AnchorPoint = Vector2.new(anchor, 0)
        b.Position = UDim2.fromScale(xScale, 0)
        b.BackgroundColor3 = cMain
        b.TextColor3 = cFont
        b.Font = Enum.Font.GothamBold
        b.TextSize = 12
        b.Text = text
        b.AutoButtonColor = true
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 4)
        local s = Instance.new("UIStroke", b) s.Color = Color3.fromRGB(50, 50, 50) s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        b.Parent = pager
        return b
    end
    local prevBtn = pagerButton("< Prev", 0, 0)
    local nextBtn = pagerButton("Next >", 1, 1)
    local pageLabel = Instance.new("TextLabel")
    pageLabel.BackgroundTransparency = 1
    pageLabel.Size = UDim2.new(1, -130, 1, 0)
    pageLabel.Position = UDim2.fromOffset(65, 0)
    pageLabel.TextColor3 = cFont
    pageLabel.Font = Enum.Font.Gotham
    pageLabel.TextSize = 12
    pageLabel.Parent = pager

    BrowseBox:AddUIPassthrough("SkinGrid", { Instance = gridRoot, Height = 4 * 110 + 30 })
    local CountLabel = BrowseBox:AddLabel("", true)

    -- Preview side
    local placeholder = Instance.new("Part")
    placeholder.Size = Vector3.new(0.4, 3, 0.7)
    placeholder.Transparency = 1
    PreviewBox:AddViewport("SkinViewport", { Object = placeholder, Clone = false, Interactive = true, AutoFocus = true, Height = 180 })
    PreviewBox:AddImage("SkinIcon", { Image = "sword", Height = 150, Visible = false })
    local InfoLabel = PreviewBox:AddLabel("Pick a skin on the left.", true)
    PreviewBox:AddButton({
        Text = "Equip This Skin",
        Func = function()
            if not selectedKey then return end
            if not library[selectedKey] then
                Library:Notify({ Title = "Skin Changer", Description = "Not collected yet. It unlocks once you see someone using it.", Time = 4 })
                return
            end
            choice[selectedType] = selectedKey
            saveChoice()
            Toggles.SkinChanger:SetValue(true)
            renderPage()
        end,
    })
    PreviewBox:AddButton({ Text = "Remove Knife Skin", Func = function() choice.Knife = nil saveChoice() renderPage() end })
    PreviewBox:AddButton({ Text = "Remove Gun Skin", Func = function() choice.Gun = nil saveChoice() renderPage() end })
    PreviewBox:AddDivider()
    PreviewBox:AddToggle("SkinChanger", { Text = "Skin Changer On", Default = choice.Knife ~= nil or choice.Gun ~= nil, Tooltip = "Only you see it" })
    local EquippedLabel = PreviewBox:AddLabel("", true)

    local function itemName(key)
        local it = ItemDB[key]
        return (it and it.ItemName) or (library[key] and library[key].name) or key
    end

    local function updatePreview()
        local it = ItemDB[selectedKey] or {}
        local have = library[selectedKey] ~= nil
        local lines = {
            itemName(selectedKey),
            rarityName(it.Rarity) .. ((it.Event and (" | " .. it.Event)) or "") .. ((it.Year and (" " .. it.Year)) or ""),
            have and "Collected: you can equip it" or "Not collected yet: shows up once you see someone using it",
        }
        InfoLabel:SetText(table.concat(lines, "\n"))
        local vis = have and buildVisual(selectedKey)
        if vis then
            for _, d in ipairs(vis:GetDescendants()) do
                if d:IsA("ParticleEmitter") or d:IsA("Trail") then d.Enabled = false end -- particles don't render in viewports
            end
            vis.CFrame = CFrame.Angles(0, math.rad(90), math.rad(-20))
            Options.SkinViewport:SetObject(vis, false)
            Options.SkinViewport:Focus()
            Options.SkinViewport:SetVisible(true)
            Options.SkinIcon:SetVisible(false)
        else
            Options.SkinViewport:SetVisible(false)
            local img = (ItemDB[selectedKey] and imageUrl(ItemDB[selectedKey].Image)) or ""
            if img ~= "" then pcall(function() Options.SkinIcon:SetImage(img) end) end
            Options.SkinIcon:SetVisible(true)
        end
    end

    local function makeCard(entry, order)
        local have = library[entry.key] ~= nil
        local equipped = choice.Knife == entry.key or choice.Gun == entry.key
        local color = rarityColor(entry.rarity)
        local card = Instance.new("TextButton")
        card.Text = ""
        card.AutoButtonColor = false
        card.BackgroundColor3 = cMain
        card.LayoutOrder = order
        Instance.new("UICorner", card).CornerRadius = UDim.new(0, 6)
        local stroke = Instance.new("UIStroke", card)
        stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        stroke.Color = entry.key == selectedKey and Color3.new(1, 1, 1) or color
        stroke.Thickness = entry.key == selectedKey and 2 or 1
        stroke.Transparency = have and 0 or 0.5

        local img = Instance.new("ImageLabel")
        img.BackgroundColor3 = cBack
        img.Size = UDim2.new(1, -8, 0, 60)
        img.Position = UDim2.fromOffset(4, 4)
        img.ScaleType = Enum.ScaleType.Fit
        img.Image = entry.image or ""
        img.ImageTransparency = have and 0 or 0.55
        Instance.new("UICorner", img).CornerRadius = UDim.new(0, 4)
        img.Parent = card

        local name = Instance.new("TextLabel")
        name.BackgroundTransparency = 1
        name.Size = UDim2.new(1, -8, 0, 14)
        name.Position = UDim2.fromOffset(4, 67)
        name.Font = Enum.Font.GothamBold
        name.TextSize = 11
        name.TextTruncate = Enum.TextTruncate.AtEnd
        name.TextColor3 = have and cFont or Color3.fromRGB(140, 140, 140)
        name.Text = entry.name .. (entry.chroma and " (Chroma)" or "")
        name.Parent = card

        local rar = Instance.new("TextLabel")
        rar.BackgroundTransparency = 1
        rar.Size = UDim2.new(1, -8, 0, 12)
        rar.Position = UDim2.fromOffset(4, 83)
        rar.Font = Enum.Font.Gotham
        rar.TextSize = 10
        rar.TextColor3 = color
        rar.Text = rarityName(entry.rarity)
        rar.Parent = card

        local bar = Instance.new("Frame")
        bar.BorderSizePixel = 0
        bar.BackgroundColor3 = color
        bar.BackgroundTransparency = have and 0 or 0.6
        bar.Size = UDim2.new(1, -12, 0, 2)
        bar.Position = UDim2.new(0, 6, 1, -5)
        bar.Parent = card

        if have or equipped then
            local tag = Instance.new("TextLabel")
            tag.Size = UDim2.fromOffset(equipped and 58 or 16, 14)
            tag.Position = UDim2.new(1, -(equipped and 62 or 20), 0, 6)
            tag.BackgroundColor3 = equipped and cAccent or Color3.fromRGB(40, 170, 80)
            tag.TextColor3 = Color3.new(1, 1, 1)
            tag.Font = Enum.Font.GothamBold
            tag.TextSize = 9
            tag.Text = equipped and "EQUIPPED" or "✓"
            Instance.new("UICorner", tag).CornerRadius = UDim.new(0, 3)
            tag.Parent = card
        end

        card.MouseButton1Click:Connect(function()
            selectedKey = entry.key
            renderPage()
            task.spawn(updatePreview)
        end)
        card.Parent = grid
    end

    local function filtered()
        local q = (Options.SkinSearch.Value or ""):lower()
        local onlyHave = Options.SkinShow.Value == "Collected only"
        local out = {}
        for _, e in ipairs(catalog[selectedType]) do
            if (q == "" or e.name:lower():find(q, 1, true) or e.key:lower():find(q, 1, true))
                and (not onlyHave or library[e.key]) then
                table.insert(out, e)
            end
        end
        return out
    end

    renderPage = function()
        for _, c in ipairs(grid:GetChildren()) do
            if c:IsA("GuiObject") then c:Destroy() end
        end
        local list = filtered()
        local pages = math.max(1, math.ceil(#list / PER_PAGE))
        page = math.clamp(page, 1, pages)
        for i = (page - 1) * PER_PAGE + 1, math.min(#list, page * PER_PAGE) do
            makeCard(list[i], i)
        end
        pageLabel.Text = string.format("Page %d / %d  (%d skins)", page, pages, #list)
        local have = { Knife = 0, Gun = 0 }
        for _, e in pairs(library) do if have[e.type] then have[e.type] += 1 end end
        CountLabel:SetText(string.format("Collected %d / %d knives, %d / %d guns. Skins you see on other players get collected automatically.",
            have.Knife, #catalog.Knife, have.Gun, #catalog.Gun))
        EquippedLabel:SetText(string.format("Knife: %s\nGun: %s",
            choice.Knife and itemName(choice.Knife) or "default", choice.Gun and itemName(choice.Gun) or "default"))
    end
    prevBtn.MouseButton1Click:Connect(function() page -= 1 renderPage() end)
    nextBtn.MouseButton1Click:Connect(function() page += 1 renderPage() end)
    renderPage()

    --// Unlock All (client-side) \\--
    -- Adds every item in the game to your own inventory screen and lets the game's
    -- Equip buttons pick them. Equips of items you don't own are kept on your side
    -- (the Equip remote is blocked for them), then shown where possible:
    -- weapons via the skin changer, emotes play for real, pets if their model is loaded.
    local ProfileData, EquipService, InvRemotes, SyncAll
    pcall(function()
        ProfileData = require(ReplicatedStorage.Modules.ProfileData)
        EquipService = require(ReplicatedStorage.ClientServices.EquipService)
        InvRemotes = ReplicatedStorage.Remotes.Inventory
        SyncAll = require(ReplicatedStorage.Database.Sync)
    end)
    local COUNT_CATS = { Weapons = true, Pets = true } -- Owned is key -> amount; others are arrays
    local realOwned, added = {}, {}
    local unlockActive = false
    local oldNamecall

    -- A few database entries are broken (no name, unknown rarity, SortGroup without
    -- SortWithinGroup). Nobody owns them, but they crash the inventory's sort, so skip them.
    local function sortable(v)
        if type(v) ~= "table" or not (v.ItemName or v.Name) then return false end
        if v.Rarity and not (SyncAll.Rarities and SyncAll.Rarities[v.Rarity]) then return false end
        if v.SortGroup ~= nil and v.SortWithinGroup == nil then return false end
        return true
    end
    local function catDB(cat)
        local t = {}
        if cat == "Weapons" then
            for k, v in pairs(SyncAll.Item) do
                if type(v) == "table" and (v.ItemType == "Knife" or v.ItemType == "Gun") and sortable(v) then t[k] = v end
            end
        else
            for k, v in pairs(SyncAll[cat] or {}) do
                if sortable(v) then t[k] = v end
            end
        end
        return t
    end

    local UNLOCK_CATS = { "Weapons", "Pets", "Effects", "Perks", "Radios", "Emotes" }
    local serverOwned = {} -- cat -> copy of the real Owned table from the server

    -- Ground truth comes from the server (same call ProfileData makes on load), so a
    -- previous unlock that was never undone can't leak into "really owned".
    local function snapshotOwned()
        local fresh
        pcall(function() fresh = InvRemotes.GetProfileData:InvokeServer() end)
        for _, cat in ipairs(UNLOCK_CATS) do
            local src = (fresh and fresh[cat] and fresh[cat].Owned) or (ProfileData[cat] and ProfileData[cat].Owned) or {}
            local set, copy = {}, {}
            for k, v in pairs(src) do
                copy[k] = v
                if COUNT_CATS[cat] then
                    if type(v) == "number" and v > 0 then set[k] = true end
                else
                    set[v] = true
                end
            end
            realOwned[cat], serverOwned[cat] = set, copy
        end
        realOwned.Weapons.DefaultKnife, realOwned.Weapons.DefaultGun = true, true
    end

    -- One InventoryDataChanged makes the inventory rebuild itself from ProfileData
    -- and the emote wheel regenerate, so patch everything first, then fire once.
    -- (Don't require Modules.EmoteModule: it waits forever for the old emote system.)
    local function refreshInventory()
        pcall(function() InvRemotes.InventoryDataChanged:Fire("Emotes", "dab", 1) end)
    end

    -- The game's own UpdateInventory crashes removing items that never got a frame,
    -- so on undo drop our added entries from its data (and the emote wheel) first.
    local function cleanInventoryData()
        pcall(function()
            local IM = require(ReplicatedStorage.Modules.InventoryModule) -- already loaded by the game
            for cat, tabs in pairs(IM.MyInventory.Data) do
                local mine = added[cat]
                if mine then
                    for tab, items in pairs(tabs) do
                        for key, it in pairs(items) do
                            if mine[key] then
                                if it.EquipConnection then pcall(function() it.EquipConnection:Disconnect() end) end
                                if it.Frame then it.Frame:Destroy() end
                                items[key] = nil
                                local sort = IM.MyInventory.Sort and IM.MyInventory.Sort[cat] and IM.MyInventory.Sort[cat][tab]
                                local i = sort and table.find(sort, key)
                                if i then table.remove(sort, i) end
                            end
                        end
                    end
                end
            end
        end)
        -- rebuild any real item whose card got destroyed (the game recreates cards with Frame == nil)
        pcall(function()
            local IM = require(ReplicatedStorage.Modules.InventoryModule)
            local dead = false
            for _, tabs in pairs(IM.MyInventory.Data) do
                for _, items in pairs(tabs) do
                    for _, it in pairs(items) do
                        if it.Frame and not it.Frame.Parent then
                            if it.EquipConnection then pcall(function() it.EquipConnection:Disconnect() end) end
                            it.Frame, it.EquipConnection, dead = nil, nil, true
                        end
                    end
                end
            end
            if dead then
                IM.GenerateNewInventoryFrames(IM.SortInventory(IM.MyInventory), LocalPlayer.PlayerGui.MainGUI.Game.Inventory.Main)
                IM.ConnectEquipButtons()
            end
        end)
        pcall(function()
            for _, d in ipairs(LocalPlayer.PlayerGui.CrossPlatform.Emotes:GetDescendants()) do
                -- hide, don't destroy: the wheel remembers what it built and won't rebuild it
                local name = d:GetAttribute("EmoteName")
                if name and added.Emotes and added.Emotes[name] and d:IsA("GuiObject") then
                    d.Visible = false
                    d:SetAttribute("MM2Hidden", true)
                end
            end
        end)
    end

    local function setLocalPet(key)
        local char = LocalPlayer.Character
        if not char then return end
        local pet = char:FindFirstChild("Pet")
        if not key then
            if pet and pet:GetAttribute("MM2Local") then pet:Destroy() end
            return
        end
        if not pet then
            pet = Instance.new("StringValue")
            pet.Name = "Pet"
            pet:SetAttribute("MM2Local", true)
            pet.Parent = char
        end
        if pet.Value ~= key then
            local body = pet:FindFirstChild("Body")
            if body then body:Destroy() end
            pet.Value = key
        end
        if not ReplicatedStorage.Pets:FindFirstChild(key) then
            Library:Notify({ Title = "Unlock All", Description = "That pet's model isn't loaded in this server, so it can't show. Pets in use by players here will work.", Time = 5 })
        end
    end

    local function unlockAll()
        if unlockActive or not ProfileData then return end
        snapshotOwned()
        unlockActive = true
        if not oldNamecall and hookmetamethod then
            local equipRemote = InvRemotes.Equip
            oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
                if unlockActive and self == equipRemote and getnamecallmethod() == "FireServer" then
                    local key, cat = ...
                    local set = realOwned[cat]
                    if set and not set[key] then return nil end -- not really owned: keep it client-side
                end
                return oldNamecall(self, ...)
            end))
        end
        -- Six game scripts rebuild on every inventory change (inventory, crafting, shop,
        -- emotes). ~1000 items in one go times them out, so add in batches of 75 with a
        -- refresh + short pause between batches.
        local n, batch = 0, 0
        for _, cat in ipairs(UNLOCK_CATS) do
            local owned = ProfileData[cat] and ProfileData[cat].Owned
            if owned then
                for key in pairs(catDB(cat)) do
                    if not unlockActive then return end
                    if not realOwned[cat][key] then
                        local new = false
                        if COUNT_CATS[cat] then
                            if not owned[key] then owned[key] = 1 new = true end
                        elseif not table.find(owned, key) then
                            table.insert(owned, key)
                            new = true
                        end
                        if new then
                            added[cat] = added[cat] or {}
                            added[cat][key] = true
                            n += 1
                            batch += 1
                            if batch >= 75 then
                                batch = 0
                                refreshInventory()
                                task.wait(0.4)
                            end
                        end
                    end
                end
            end
        end
        refreshInventory()
        pcall(function()
            for _, d in ipairs(LocalPlayer.PlayerGui.CrossPlatform.Emotes:GetDescendants()) do
                if d:GetAttribute("MM2Hidden") then d.Visible = true d:SetAttribute("MM2Hidden", nil) end
            end
        end)
        pcall(function() LocalPlayer.PlayerGui.MainGUI.Game.Inventory.Main.Radios.NoRadioCover.Visible = false end)
        Library:Notify({ Title = "Unlock All", Description = "Added " .. n .. " items to your inventory. Open it and equip anything.", Time = 5 })
    end

    local function relockAll()
        if not unlockActive then return end
        unlockActive = false
        -- put each Owned table back to exactly what the server has, in place
        for _, cat in ipairs(UNLOCK_CATS) do
            local owned = ProfileData[cat] and ProfileData[cat].Owned
            if owned and serverOwned[cat] then
                table.clear(owned)
                for k, v in pairs(serverOwned[cat]) do owned[k] = v end
            end
        end
        cleanInventoryData()
        refreshInventory()
        table.clear(added)
        -- put the equipped slots back to what the server knows
        for _, kind in ipairs({ "Knife", "Gun" }) do
            local real = LocalPlayer:GetAttribute("Equipped" .. kind)
            if real then ProfileData.Weapons.Equipped[kind] = real EquipService.EquippedChanged:Fire(kind, real) end
        end
        for _, cat in ipairs({ "Pets", "Effects", "Radios", "Perks" }) do
            local eq = ProfileData[cat].Equipped
            if eq then
                for i = #eq, 1, -1 do
                    if not realOwned[cat][eq[i]] then table.remove(eq, i) end
                end
            end
        end
        pcall(function() require(ReplicatedStorage.Modules.InventoryModule).UpdateMyEquip() end)
        pcall(function() LocalPlayer.PlayerGui.MainGUI.Game.Inventory.Main.Radios.NoRadioCover.Visible = not LocalPlayer:GetAttribute("Radio") end)
        setLocalPet(nil)
    end

    -- Weapon key the game's inventory has equipped, when it differs from what the server knows.
    local function inventoryPick(kind)
        if not unlockActive or not ProfileData then return nil end
        local eq = ProfileData.Weapons.Equipped[kind]
        if eq and eq ~= LocalPlayer:GetAttribute("Equipped" .. kind) then return eq end
    end

    local UnlockBox = SkinTab:AddLeftGroupbox("Unlock All", "lock-open")
    UnlockBox:AddToggle("UnlockAll", {
        Text = "Unlock All Items",
        Default = false,
        Tooltip = "Only you see it. Puts every weapon, effect, power, emote, radio and pet in your inventory",
        Callback = function(v)
            if v then task.spawn(unlockAll) else task.spawn(relockAll) end
        end,
    })
    UnlockBox:AddLabel("Everything shows up in your inventory and you can equip it with the game's own buttons.\n\nWhat actually changes:\n- Emotes: all of them play for real, and others see them.\n- Knives/guns: show in your hand if the skin is collected (see the browser).\n- Pets: show if that pet's model is loaded in this server.\n- Effects, powers, radios: inventory only.", true)

    local warned = {}
    local function warnUncollected(key)
        if warned[key] then return end
        warned[key] = true
        Library:Notify({ Title = "Unlock All", Description = itemName(key) .. " is equipped, but its 3D model isn't collected yet, so your weapon looks the same until someone with it is seen.", Time = 6 })
    end

    --// Skin Hunter: hop servers and collect everyone's equipped knife/gun skins \\--
    local TeleportService = game:GetService("TeleportService")
    local HUNT_FILE = "mm2_hunter.json"
    local hunt = { on = false, visited = {}, cursor = nil, hops = 0 }
    pcall(function() if isfile(HUNT_FILE) then hunt = HttpService:JSONDecode(readfile(HUNT_FILE)) end end)
    hunt.visited = hunt.visited or {}
    hunt.hops = hunt.hops or 0
    for id, t in pairs(hunt.visited) do
        if os.time() - t > 6 * 3600 then hunt.visited[id] = nil end -- servers change; forget after 6h
    end
    hunt.visited[game.JobId] = os.time()
    local function saveHunt() pcall(writefile, HUNT_FILE, HttpService:JSONEncode(hunt)) end
    saveHunt()

    local function collectedCount()
        local n = 0
        for _ in pairs(library) do n += 1 end
        return n
    end

    local function fetchServers()
        local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Desc&limit=100&excludeFullGames=true"):format(game.PlaceId)
        if hunt.cursor then url ..= "&cursor=" .. HttpService:UrlEncode(hunt.cursor) end
        local ok, body = pcall(game.HttpGet, game, url)
        if not ok then return nil, "server list request failed" end
        local ok2, data = pcall(HttpService.JSONDecode, HttpService, body)
        if not ok2 or type(data) ~= "table" or type(data.data) ~= "table" then
            return nil, "server list busy (rate limited), retrying"
        end
        return data
    end

    -- The server list API rate-limits hard, so one fetched page is kept in the hunt
    -- file as a queue (fullest first) and only refetched once it runs dry.
    local function pickServer()
        hunt.queue = hunt.queue or {}
        for _ = 1, 4 do
            while #hunt.queue > 0 do
                local s = table.remove(hunt.queue, 1)
                if s.id ~= game.JobId and not hunt.visited[s.id] then
                    saveHunt()
                    return s
                end
            end
            local data, err = fetchServers()
            if not data then return nil, err end
            for _, s in ipairs(data.data) do
                local playing = tonumber(s.playing) or 0
                if s.id ~= game.JobId and not hunt.visited[s.id] and playing >= Options.HuntMinPlayers.Value
                    and playing < (tonumber(s.maxPlayers) or 12) then
                    table.insert(hunt.queue, { id = s.id, playing = playing })
                end
            end
            table.sort(hunt.queue, function(a, b) return a.playing > b.playing end)
            hunt.cursor = data.nextPageCursor -- nil wraps back to page 1
            saveHunt()
        end
        return nil, "no fresh servers found, retrying"
    end

    local HuntBox = SkinTab:AddRightGroupbox("Skin Hunter", "radar")
    HuntBox:AddLabel("Hops servers by itself and saves every knife and gun skin players have equipped. It keeps going (even after each hop) until you turn it off.", true)
    HuntBox:AddToggle("SkinHunter", {
        Text = "Skin Hunter",
        Default = hunt.on,
        Callback = function(v) hunt.on = v saveHunt() end,
    })
    HuntBox:AddSlider("HuntStay", { Text = "Seconds Per Server", Default = 8, Min = 4, Max = 30, Rounding = 0, Suffix = "s" })
    HuntBox:AddSlider("HuntMinPlayers", { Text = "Only Servers With At Least", Default = 6, Min = 1, Max = 11, Rounding = 0, Suffix = " players" })
    local HuntLabel = HuntBox:AddLabel("", true)

    task.spawn(function()
        local arrived = os.clock()
        local startCount = collectedCount()
        local hopping = false
        while not Library.Unloaded do
            if harvest() then ensureCatalog() renderPage() end
            local total = #catalog.Knife + #catalog.Gun
            local gained = collectedCount() - startCount
            if Toggles.SkinHunter.Value then
                local left = math.max(0, Options.HuntStay.Value - (os.clock() - arrived))
                if not hopping then
                    HuntLabel:SetText(string.format("Collected %d / %d skins\nThis server: +%d\nServers visited: %d\nHopping in %ds",
                        collectedCount(), total, gained, hunt.hops, math.ceil(left)))
                end
                if left <= 0 and not hopping then
                    hopping = true
                    HuntLabel:SetText(string.format("Collected %d / %d skins\nFinding the next server...", collectedCount(), total))
                    local server, err = pickServer()
                    if server then
                        hunt.visited[server.id] = os.time()
                        hunt.hops += 1
                        saveHunt()
                        queueSelf() -- make sure the script (and the hunt) reloads in the next server
                        HuntLabel:SetText(string.format("Collected %d / %d skins\nJoining a %d-player server...", collectedCount(), total, server.playing))
                        pcall(TeleportService.TeleportToPlaceInstance, TeleportService, game.PlaceId, server.id, LocalPlayer)
                        task.wait(15) -- still here means the teleport failed; try another
                    else
                        HuntLabel:SetText(string.format("Collected %d / %d skins\n%s", collectedCount(), total, err))
                        task.wait(10)
                    end
                    hopping = false
                end
            else
                arrived = os.clock() -- the stay timer starts when it's switched on
                HuntLabel:SetText(string.format("Collected %d / %d skins\nServers visited: %d", collectedCount(), total, hunt.hops))
            end
            task.wait(1)
        end
    end)

    local function restoreWeapons()
        for _, kind in ipairs({ "Knife", "Gun" }) do
            for _, part in ipairs(myWeaponParts(kind)) do pcall(restore, part) end
        end
    end

    clearSkins = function() -- full cleanup on unload
        restoreWeapons()
        pcall(relockAll)
        if oldNamecall then pcall(hookmetamethod, game, "__namecall", oldNamecall) oldNamecall = nil end
    end

    task.spawn(function()
        local n = 0
        while not Library.Unloaded do
            if n % 6 == 0 and harvest() then ensureCatalog() renderPage() end
            n += 1
            if Toggles.SkinChanger.Value or unlockActive then
                for _, kind in ipairs({ "Knife", "Gun" }) do
                    -- an item picked in the game's inventory (Unlock All) wins over the browser pick
                    local pick = inventoryPick(kind)
                    if pick and not library[pick] then warnUncollected(pick) pick = nil end
                    local key = pick or (Toggles.SkinChanger.Value and choice[kind]) or nil
                    if key and not library[key] then key = nil end
                    for _, part in ipairs(myWeaponParts(kind)) do
                        if key then pcall(apply, part, key) else pcall(restore, part) end
                    end
                end
                if unlockActive and ProfileData then
                    local pet = ProfileData.Pets.Equipped and ProfileData.Pets.Equipped[1]
                    if pet and not realOwned.Pets[pet] then
                        local char = LocalPlayer.Character
                        local pv = char and char:FindFirstChild("Pet")
                        if not pv or pv.Value ~= pet then pcall(setLocalPet, pet) end
                    end
                end
            else
                restoreWeapons()
            end
            task.wait(0.5)
        end
    end)
end

--// Combat + Fun \\--
-- Gun (Sheriff/Hero): Gun.Shoot:FireServer(origin, target). Both are plain position
--   CFrames and the origin is client-supplied, so passing origin == target == the
--   victim's position makes the server's own ray start on the victim -> kills through
--   walls/floors, no line of sight. (Confirmed live from WeaponService.)
-- Knife (Murderer): Knife.Events.KnifeStabbed() opens the stab window, then
--   HandleTouched(part) registers the hit. We teleport onto each target (teleport
--   ignores walls) then fire, so it also kills through geometry.
-- Roles come from CurrentRoundClient.PlayerData, keyed by player name.
do
    local UserInputService = game:GetService("UserInputService")

    local function equipTool(name)
        local char, hum = getChar()
        if not (char and hum) then return end
        local bp = LocalPlayer:FindFirstChild("Backpack")
        local tool = (bp and bp:FindFirstChild(name)) or char:FindFirstChild(name)
        if tool and tool.Parent ~= char then pcall(function() hum:EquipTool(tool) end) end
        return char:FindFirstChild(name) or tool
    end

    local function heldWeapon()
        local char = LocalPlayer.Character
        local bp = LocalPlayer:FindFirstChild("Backpack")
        local function has(n) return (char and char:FindFirstChild(n)) or (bp and bp:FindFirstChild(n)) end
        if has("Knife") then return "Knife" end
        if has("Gun") then return "Gun" end
    end

    -- Build the target list according to the selected mode + range.
    local function enemies(allOverride)
        local mode = Options.KillTarget.Value
        local _, _, myHRP = getChar()
        local range = Options.KillRange.Value
        local list = {}
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LocalPlayer then
                local c = p.Character
                local h = c and c:FindFirstChildOfClass("Humanoid")
                local r = c and c:FindFirstChild("HumanoidRootPart")
                if h and r and h.Health > 0 then
                    local ok = true
                    if not allOverride then
                        local role = roleOf(p)
                        if mode == "Murderer only" then ok = (role == "Murderer")
                        elseif mode == "Innocents" then ok = (role ~= "Murderer" and role ~= "Sheriff" and role ~= "Hero")
                        end -- "Everyone" leaves ok = true
                    end
                    if ok then
                        local d = myHRP and (r.Position - myHRP.Position).Magnitude or 0
                        if allOverride or range <= 0 or not myHRP or d <= range then
                            table.insert(list, { p = p, hrp = r, dist = d })
                        end
                    end
                end
            end
        end
        table.sort(list, function(a, b) return a.dist < b.dist end)
        return list
    end

    ------------------------------------------------------------------
    -- Gun: instant through-wall shots (origin spoofed onto the victim)
    ------------------------------------------------------------------
    -- Live-verified method: the MM2 server validates the shooter's real position and
    -- line of sight, so a still/through-wall shot is rejected. We "blink" onto the
    -- target (~0.08s), fire with the REAL gun origin aimed PAST them (a shot ending
    -- exactly on them doesn't register), then blink back. Kills through any wall.
    local function gunShoot(targets)
        local gun = equipTool("Gun")
        local shoot = gun and gun:FindFirstChild("Shoot")
        if not shoot then return end
        local _, _, myhrp = getChar()
        if not myhrp then return end
        local home = myhrp.CFrame
        for _, t in ipairs(targets) do
            if t.hrp and t.hrp.Parent then
                myhrp.CFrame = t.hrp.CFrame * CFrame.new(0, 0, 3)
                myhrp.AssemblyLinearVelocity = Vector3.zero
                for _ = 1, Options.GunSettle.Value do RunService.Heartbeat:Wait() end -- let the new position reach the server
                if t.hrp.Parent then
                    local pos = t.hrp.Position
                    local att = myhrp:FindFirstChild("GunRaycastAttachment")
                    local o = (att and att.WorldCFrame) or myhrp.CFrame
                    local aim = CFrame.new(pos + (pos - o.Position).Unit * 40) -- aim 40 studs PAST the target
                    for _ = 1, Options.GunBurst.Value do
                        pcall(function() shoot:FireServer(o, aim) end)
                    end
                end
            end
        end
        if Toggles.GunBlinkReturn.Value then
            local _, _, h2 = getChar()
            if h2 then h2.CFrame = home end
        end
    end

    ------------------------------------------------------------------
    -- Knife: teleport-stab every target (teleport ignores walls)
    ------------------------------------------------------------------
    -- Live-verified: the knife's HandleTouched has NO proximity or line-of-sight check
    -- (killed a target 84 studs away with zero movement), so kill-all needs no teleport
    -- at all. We just open a stab and register the hit on each target where we stand.
    local killBusy = false
    local function knifeKill(targets)
        if killBusy then return end
        local knife = equipTool("Knife")
        local Events = knife and knife:FindFirstChild("Events")
        local KnifeStabbed = Events and Events:FindFirstChild("KnifeStabbed")
        local HandleTouched = Events and Events:FindFirstChild("HandleTouched")
        if not (KnifeStabbed and HandleTouched) then return end
        killBusy = true
        pcall(function()
            if Toggles.KillBurst.Value then
                -- one stab, hit everyone in the window (instant wipe if the server allows it)
                KnifeStabbed:FireServer()
                for _, t in ipairs(targets) do
                    local h = t.p.Character and t.p.Character:FindFirstChildOfClass("Humanoid")
                    if h and h.Health > 0 and t.hrp and t.hrp.Parent then
                        pcall(function() HandleTouched:FireServer(t.hrp) end)
                    end
                end
            else
                -- one stab per target, spaced by the server's stab cooldown
                for _, t in ipairs(targets) do
                    if Library.Unloaded then break end
                    local h = t.p.Character and t.p.Character:FindFirstChildOfClass("Humanoid")
                    if h and h.Health > 0 and t.hrp and t.hrp.Parent then
                        pcall(function() KnifeStabbed:FireServer() end)
                        pcall(function() HandleTouched:FireServer(t.hrp) end)
                        task.wait(Options.KillDelay.Value)
                    end
                end
            end
        end)
        killBusy = false
    end

    -- Dispatch by whatever weapon you're holding.
    local function killTargets(list)
        local w = heldWeapon()
        if w == "Gun" then gunShoot(list)
        elseif w == "Knife" then knifeKill(list) end
    end

    local function killMurdererNow()
        local m = murderer()
        local c = m and m.Character
        local r = c and c:FindFirstChild("HumanoidRootPart")
        if r then killTargets({ { p = m, hrp = r, dist = 0 } }) end
    end
    local function killEveryoneNow() killTargets(enemies(true)) end

    local lastShot = 0
    local function autoAttackOnce()
        local w = heldWeapon()
        if not w then return end
        local list = enemies(false)
        if #list == 0 then return end
        if w == "Gun" then
            if tick() - lastShot < Options.AttackDelay.Value then return end
            lastShot = tick()
            gunShoot(list)
        else
            knifeKill(list)
        end
    end

    ------------------------------------------------------------------
    -- Endgame combo: (fling sheriff ->) grab gun -> kill murderer
    ------------------------------------------------------------------
    -- NOTE: flinging/killing another player from the client is impossible here (Roblox
    -- network ownership -- the launch only happens on our screen and the server corrects
    -- it; tested slamming a target at -50000 velocity into the void, they kept 100 HP).
    -- So the endgame can only GRAB a gun that has already dropped (sheriff died), never
    -- force the sheriff to drop it.

    local function killMurdererFor(duration)
        local t0 = os.clock()
        while os.clock() - t0 < duration and not Library.Unloaded do
            if heldWeapon() ~= "Gun" then return false end
            local m = murderer()
            local mc = m and m.Character
            local mh = mc and mc:FindFirstChildOfClass("Humanoid")
            local mr = mc and mc:FindFirstChild("HumanoidRootPart")
            if not (mh and mr) or mh.Health <= 0 then return true end -- murderer down
            gunShoot({ { p = m, hrp = mr, dist = 0 } })
            task.wait(0.15)
        end
        return false
    end

    local endgameBusy = false
    local function runEndgame()
        if endgameBusy then return end
        local me = myRound()
        if not me or me.Dead or me.Role == "Murderer" then return end
        local m = murderer()
        local mh = m and m.Character and m.Character:FindFirstChildOfClass("Humanoid")
        if not (mh and mh.Health > 0) then return end -- no live murderer, nothing to do

        endgameBusy, state.busy = true, true
        local function haveGun() return heldWeapon() == "Gun" end
        pcall(function()
            -- 1. if a gun is on the floor (sheriff already died), grab it
            if not haveGun() and Toggles.EndGrab.Value and findGunDrop() then
                state.status = "Endgame: grabbing dropped gun"
                grabGun(true) ; state.busy = true
            end
            -- 2. kill the murderer (blinks onto them for the shot)
            if haveGun() and Toggles.EndKill.Value then
                state.status = "Endgame: killing the murderer"
                killMurdererFor(6)
            end
        end)
        state.busy, endgameBusy = false, false
    end

    ------------------------------------------------------------------
    -- Combat tab UI
    ------------------------------------------------------------------
    local CombatTab = Window:AddTab("Combat", "swords")

    local AuraBox = CombatTab:AddLeftGroupbox("Auto Kill", "crosshair")
    AuraBox:AddToggle("AutoKill", {
        Text = "Auto Kill (aimbot)",
        Default = false,
        Tooltip = "Holding a Gun -> instant through-wall shots. Holding a Knife -> teleport-stabs your targets.",
    }):AddKeyPicker("AutoKillKey", { Default = "K", Mode = "Toggle", SyncToggleState = true, Text = "Auto Kill" })
    AuraBox:AddDropdown("KillTarget", {
        Text = "Targets",
        Values = { "Murderer only", "Everyone", "Innocents" },
        Default = "Murderer only",
        Tooltip = "Murderer only is safe as sheriff. Everyone / Innocents is murderer chaos.",
    })
    AuraBox:AddSlider("GunSettle", {
        Text = "Blink Settle",
        Default = 3, Min = 1, Max = 8, Rounding = 0, Suffix = " frames",
        Tooltip = "Frames to wait at the target so the server accepts the shot. Lower = faster/less visible but may miss; raise if kills don't register.",
    })
    AuraBox:AddToggle("GunBlinkReturn", { Text = "Blink Back After Shot", Default = true, Tooltip = "Return to your spot instantly after firing (the whole blink is ~0.08s)" })
    AuraBox:AddSlider("AttackDelay", { Text = "Gun Fire Rate", Default = 0.06, Min = 0.03, Max = 1, Rounding = 2, Suffix = "s" })
    AuraBox:AddSlider("GunBurst", { Text = "Shots Per Target", Default = 2, Min = 1, Max = 6, Rounding = 0, Tooltip = "Extra shots guarantee the kill registers" })
    AuraBox:AddSlider("KillRange", { Text = "Range", Default = 0, Min = 0, Max = 500, Rounding = 0, Suffix = " studs (0 = whole map)" })

    local ManualBox = CombatTab:AddLeftGroupbox("Manual", "hand")
    ManualBox:AddButton({ Text = "Kill Murderer Now", Func = function() task.spawn(killMurdererNow) end })
    ManualBox:AddButton({ Text = "Kill Everyone Now", Func = function() task.spawn(killEveryoneNow) end })

    local EndBox = CombatTab:AddRightGroupbox("Endgame (on bag full)", "flag")
    EndBox:AddToggle("AutoEndgame", {
        Text = "Auto Endgame When Bag Full",
        Default = false,
        Tooltip = "Once your coin bag is full: if you have/can grab a gun, kill the murderer.",
    })
    EndBox:AddToggle("EndGrab", { Text = "Grab Dropped Gun", Default = true, Tooltip = "Grabs the gun off the floor if the sheriff has already died" })
    EndBox:AddToggle("EndKill", { Text = "Kill Murderer", Default = true })
    EndBox:AddButton({ Text = "Run Endgame Now", Func = function() task.spawn(runEndgame) end })
    EndBox:AddLabel("Works when you're the sheriff (uses your gun) or an innocent AFTER the sheriff has died and dropped the gun. You cannot force the sheriff to drop it -- flinging other players is impossible (Roblox network ownership).", true)

    local KnifeBox = CombatTab:AddRightGroupbox("Knife Options", "skull")
    KnifeBox:AddSlider("KillDelay", {
        Text = "Delay Per Stab", Default = 0.85, Min = 0, Max = 2, Rounding = 2, Suffix = "s",
        Tooltip = "Server stab cooldown is ~0.85s between kills. Ignored in Burst mode.",
    })
    KnifeBox:AddToggle("KillBurst", {
        Text = "Burst Mode (instant wipe)",
        Default = false,
        Tooltip = "One stab, hit everyone at once. If the server rejects extra hits per stab, use the normal per-stab mode.",
    })
    KnifeBox:AddLabel("Knife kills from ANYWHERE with no movement (no line-of-sight check). Gun must blink onto the target for ~0.08s because the server checks the shooter's position for shots.", true)

    ------------------------------------------------------------------
    -- Fun tab UI + logic
    ------------------------------------------------------------------
    local FunTab = Window:AddTab("Fun", "wand-sparkles")
    local MoveFxBox = FunTab:AddLeftGroupbox("Movement", "wind")

    -- Fly (needs PlatformStand or the humanoid physics fights the mover)
    local flyConn
    local function setFly(on)
        if flyConn then flyConn:Disconnect() flyConn = nil end
        local _, hum, hrp = getChar()
        if hrp then
            local v = hrp:FindFirstChild("MM2FlyV") if v then v:Destroy() end
            local g = hrp:FindFirstChild("MM2FlyG") if g then g:Destroy() end
        end
        if hum then pcall(function() hum.PlatformStand = on and true or false end) end
        if not on or not hrp or not hum then return end
        local bv = Instance.new("BodyVelocity")
        bv.Name, bv.MaxForce, bv.Velocity = "MM2FlyV", Vector3.new(math.huge, math.huge, math.huge), Vector3.zero
        bv.Parent = hrp
        local bg = Instance.new("BodyGyro")
        bg.Name, bg.MaxForce, bg.P = "MM2FlyG", Vector3.new(math.huge, math.huge, math.huge), 1e5
        bg.Parent = hrp
        flyConn = RunService.RenderStepped:Connect(function()
            local _, hum2, h = getChar()
            if not h then return end
            if hum2 then hum2.PlatformStand = true end
            local cam = workspace.CurrentCamera
            local dir = Vector3.zero
            if UserInputService:IsKeyDown(Enum.KeyCode.W) then dir += cam.CFrame.LookVector end
            if UserInputService:IsKeyDown(Enum.KeyCode.S) then dir -= cam.CFrame.LookVector end
            if UserInputService:IsKeyDown(Enum.KeyCode.A) then dir -= cam.CFrame.RightVector end
            if UserInputService:IsKeyDown(Enum.KeyCode.D) then dir += cam.CFrame.RightVector end
            if UserInputService:IsKeyDown(Enum.KeyCode.Space) then dir += Vector3.yAxis end
            if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then dir -= Vector3.yAxis end
            bg.CFrame = cam.CFrame
            local flyV = h:FindFirstChild("MM2FlyV")
            if flyV then flyV.Velocity = (dir.Magnitude > 0 and dir.Unit or Vector3.zero) * Options.FlySpeed.Value end
        end)
    end
    MoveFxBox:AddToggle("Fly", { Text = "Fly (WASD + Space/Shift)", Default = false, Callback = setFly })
        :AddKeyPicker("FlyKey", { Default = "X", Mode = "Toggle", SyncToggleState = true, Text = "Fly" })
    MoveFxBox:AddSlider("FlySpeed", { Text = "Fly Speed", Default = 80, Min = 16, Max = 400, Rounding = 0 })
    -- Reapply fly after respawn
    track(LocalPlayer.CharacterAdded:Connect(function()
        task.wait(0.4)
        if Toggles.Fly.Value then setFly(true) end
    end))

    -- Noclip
    MoveFxBox:AddToggle("FunNoclip", { Text = "Noclip", Default = false, Tooltip = "Walk through everything" })
    track(RunService.Stepped:Connect(function()
        if not Toggles.FunNoclip.Value then return end
        local char = LocalPlayer.Character
        if not char then return end
        for _, p in ipairs(char:GetDescendants()) do
            if p:IsA("BasePart") and p.CanCollide then p.CanCollide = false end
        end
    end))

    -- Spinbot
    MoveFxBox:AddToggle("Spinbot", { Text = "Spinbot", Default = false, Tooltip = "Spins your character in place" })
    MoveFxBox:AddSlider("SpinSpeed", { Text = "Spin Speed", Default = 15, Min = 1, Max = 45, Rounding = 0, Suffix = " deg/frame" })
    track(RunService.Heartbeat:Connect(function()
        if not Toggles.Spinbot.Value then return end
        local _, _, hrp = getChar()
        if hrp then hrp.CFrame = hrp.CFrame * CFrame.Angles(0, math.rad(Options.SpinSpeed.Value), 0) end
    end))

    -- Infinite jump
    MoveFxBox:AddToggle("InfJump", { Text = "Infinite Jump", Default = false })
    track(UserInputService.JumpRequest:Connect(function()
        if not Toggles.InfJump.Value then return end
        local _, hum = getChar()
        if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
    end))

    -- (Spin Fling removed: flinging other players is impossible on this game -- Roblox
    -- network ownership means the launch only shows on your screen and the server undoes it.)

    -- Camera / live FOV
    local CamBox = FunTab:AddRightGroupbox("Camera", "video")
    local DEFAULT_FOV = workspace.CurrentCamera and workspace.CurrentCamera.FieldOfView or 70
    CamBox:AddToggle("FOVEnabled", {
        Text = "Custom FOV",
        Default = false,
        Tooltip = "Live field-of-view changer",
        Callback = function(v)
            if not v then pcall(function() workspace.CurrentCamera.FieldOfView = DEFAULT_FOV end) end
        end,
    })
    CamBox:AddSlider("FOVValue", { Text = "Field Of View", Default = 90, Min = 30, Max = 120, Rounding = 0 })
    track(RunService.RenderStepped:Connect(function()
        if not Toggles.FOVEnabled.Value then return end
        local cam = workspace.CurrentCamera
        if cam then cam.FieldOfView = Options.FOVValue.Value end
    end))

    -- Effects
    local FxBox = FunTab:AddRightGroupbox("Effects", "flame")
    local DEFAULT_GRAVITY = workspace.Gravity
    FxBox:AddToggle("MoonGravity", {
        Text = "Moon Gravity", Default = false,
        Callback = function(v) workspace.Gravity = v and Options.GravityValue.Value or DEFAULT_GRAVITY end,
    })
    FxBox:AddSlider("GravityValue", {
        Text = "Gravity", Default = 50, Min = 5, Max = 196, Rounding = 0,
        Callback = function(val) if Toggles.MoonGravity.Value then workspace.Gravity = val end end,
    })

    local rainbowOrig = {}
    local function restoreRainbow()
        for part, c in pairs(rainbowOrig) do if part.Parent then part.Color = c end end
        table.clear(rainbowOrig)
    end
    FxBox:AddToggle("Rainbow", {
        Text = "Rainbow Body", Default = false,
        Tooltip = "Client-side only, just for you",
        Callback = function(v) if not v then restoreRainbow() end end,
    })
    FxBox:AddSlider("RainbowSpeed", { Text = "Rainbow Speed", Default = 5, Min = 1, Max = 20, Rounding = 0 })
    track(RunService.Heartbeat:Connect(function()
        if not Toggles.Rainbow.Value then return end
        local char = LocalPlayer.Character
        if not char then return end
        local col = Color3.fromHSV((tick() * Options.RainbowSpeed.Value / 10) % 1, 1, 1)
        for _, p in ipairs(char:GetDescendants()) do
            if p:IsA("BasePart") then
                if rainbowOrig[p] == nil then rainbowOrig[p] = p.Color end
                p.Color = col
            end
        end
    end))

    ------------------------------------------------------------------
    -- Auto attack loop
    ------------------------------------------------------------------
    task.spawn(function()
        while not Library.Unloaded do
            if Toggles.AutoKill.Value then pcall(autoAttackOnce) end
            task.wait(0.05)
        end
    end)
    -- Endgame trigger: fires once your bag is full
    task.spawn(function()
        while not Library.Unloaded do
            if Toggles.AutoEndgame.Value and allBagsFull() then pcall(runEndgame) end
            task.wait(0.5)
        end
    end)

    -- Cleanup hook picked up by OnUnload
    getgenv().MM2CombatFunCleanup = function()
        pcall(setFly, false)
        pcall(function() workspace.Gravity = DEFAULT_GRAVITY end)
        pcall(function() workspace.CurrentCamera.FieldOfView = DEFAULT_FOV end)
        pcall(restoreRainbow)
        local _, hum = getChar()
        if hum then pcall(function() hum.PlatformStand = false end) end
    end
end

task.spawn(function()
    while not Library.Unloaded do
        local ok, err = pcall(farmLoop)
        if ok or Library.Unloaded then break end
        state.status = "Error, restarting: " .. tostring(err)
        setNoclip(false)
        task.wait(1)
    end
end)

-- Status refresh
task.spawn(function()
    while not Library.Unloaded do
        StatusLabel:SetText("Status: " .. state.status)
        local me = myRound()
        local m = murderer()
        local sheriff = roleHolder("Sheriff") or holderOf("Gun")
        if me then
            RoundLabel:SetText(string.format("Role: %s\nMurderer: %s\nGun: %s",
                tostring(me.Role), m and m.Name or (me.Role == "Murderer" and "you" or "?"),
                sheriff and (sheriff == LocalPlayer and "you" or sheriff.Name) or "dropped / none"))
        else
            RoundLabel:SetText("Not in a round")
        end
        local bags = {}
        for name, b in pairs(state.bags) do
            table.insert(bags, string.format("%s %d/%s", name, b.n, b.max == math.huge and "?" or tostring(b.max)))
        end
        BagLabel:SetText(#bags > 0 and ("Bags: " .. table.concat(bags, ", ")) or "Bags: none yet")
        local mins = (os.clock() - state.startTime) / 60
        local xp = LocalPlayer:GetAttribute("XP") or 0
        local lvl = LocalPlayer:GetAttribute("Level") or 0
        StatsLabel:SetText(string.format(
            "Coins: %d (%d/hr)\nThis round: %d\nRounds: %d\nGuns grabbed: %d\nLevel %d, XP %d%s\nTime: %dm",
            state.sessionCoins, mins > 0.5 and math.floor(state.sessionCoins / mins * 60) or 0,
            state.roundCoins, state.rounds, state.gunGrabs, lvl, xp,
            lvl == state.startLevel and string.format(" (+%d)", xp - state.startXP) or string.format(" (+%d levels)", lvl - state.startLevel),
            math.floor(mins)))
        task.wait(0.25)
    end
end)

--// UI Settings \\--
local MenuBox = Tabs["UI Settings"]:AddLeftGroupbox("Menu", "wrench")
MenuBox:AddToggle("KeybindMenuOpen", {
    Text = "Show Keybind Menu",
    Default = Library.KeybindFrame.Visible,
    Callback = function(v) Library.KeybindFrame.Visible = v end,
})
MenuBox:AddToggle("ShowCustomCursor", {
    Text = "Custom Cursor",
    Default = false,
    Callback = function(v) Library.ShowCustomCursor = v end,
})
MenuBox:AddDivider()
MenuBox:AddLabel("Menu bind"):AddKeyPicker("MenuKeybind", { Default = "RightShift", NoUI = true, Text = "Menu keybind" })
MenuBox:AddButton({ Text = "Unload", Func = function() Library:Unload() end })
Library.ToggleKeybind = Options.MenuKeybind

Library:OnUnload(function()
    for _, conn in Connections do
        pcall(function() conn:Disconnect() end)
    end
    table.clear(Connections)
    setNoclip(false)
    unanchor()
    pcall(clearXray)
    pcall(clearSkins)
    pcall(function() if getgenv().MM2CombatFunCleanup then getgenv().MM2CombatFunCleanup() end end)
    pcall(function() espFolder:Destroy() end)
    local _, hum = getChar()
    if hum then hum.WalkSpeed = 16 end
end)

ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({ "MenuKeybind" })
ThemeManager:SetFolder(SCRIPT_NAME)
SaveManager:SetFolder(SCRIPT_NAME .. "/" .. GAME_NAME)
SaveManager:BuildConfigSection(Tabs["UI Settings"])
ThemeManager:ApplyToTab(Tabs["UI Settings"])
SaveManager:LoadAutoloadConfig()

-- Remember whether the farm was on so a server hop picks it back up.
Toggles.AutoFarm:OnChanged(function(v)
    pcall(writefile, "mm2_farm_on.txt", v and "1" or "0")
end)
if env.MM2FarmAutoStart then
    env.MM2FarmAutoStart = nil
    local ok, on = pcall(readfile, "mm2_farm_on.txt")
    if ok and on == "1" then Toggles.AutoFarm:SetValue(true) end
end
if Toggles.KeepLoading.Value then queueSelf() end

-- Unloading the previous copy clears getgenv().Library a moment later; point it back at us.
task.delay(1, function()
    if not Library.Unloaded then getgenv().Library = Library end
end)

Library:Notify({ Title = SCRIPT_NAME, Description = "Loaded. F farm | K auto-kill | X fly | RightShift menu", Time = 5 })
