
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local VIM = game:GetService("VirtualInputManager")
local HttpService = game:GetService("HttpService")
local RS = game:GetService("ReplicatedStorage")

local LP = Players.LocalPlayer
local Packets = require(RS.Modules.Packets)
local BlockInput = Packets.Combat.packets.BlockInput

local SLOT_COUNT = 10

local CFG = {
    Enabled = true,
    RollOnCooldown = false,
    RollBehind = true,
    DodgeGrimoire = false,
    RollCancel = false,
    NoParryM1 = true,
    NoParryTabbed = true,
    NoParryTyping = true,
    NoParryEmote = true,
    PingComp = true,
    SkillBuffer = false,
    Logger = false,
    Autoload = true,
    StartSilent = false,
    ESP = false,
    ESPHighlight = true,
    ESPNameTag = true,
    Filter = "All",
    UIKey = "RightControl",
    ParryLead = 0.1,
    InstantCutoff = 0.15,
    ParryWindow = 0.15,
    FallbackDelay = 0.9,
    Range = 24,
    RollCancelDelay = 0.05,
    ParryCooldown = 0.6,
    PingScale = 1,
    BroomSpeed = 1.0,

    SlotKey1 = "One",
    SlotKey2 = "Two",
    SlotKey3 = "Three",
    SlotKey4 = "Four",
    SlotKey5 = "Five",
    SlotKey6 = "Six",
    SlotKey7 = "Seven",
    SlotKey8 = "Eight",
    SlotKey9 = "Nine",
    SlotKey10 = "Zero",
    SlotArmed1 = false,
    SlotArmed2 = false,
    SlotArmed3 = false,
    SlotArmed4 = false,
    SlotArmed5 = false,
    SlotArmed6 = false,
    SlotArmed7 = false,
    SlotArmed8 = false,
    SlotArmed9 = false,
    SlotArmed10 = false,
    WhitelistOnly = false,
    NPCESP = false,
    QuestESP = false,
    RemoteBase = "https://raw.githubusercontent.com/meowlollll/meowparry/main/",

    TimingsFiles = {
        "CloverRPG/clover-animation-timings.json",
        "CloverRPG\\clover-animation-timings.json",
        "clover-animation-timings.json",
    },
}

local CONFIG_FILE = "CloverRPG/meowparry-config.json"
local CONFIG_SKIP = {
    TimingsFiles = true, RemoteBase = true,
    SlotArmed1 = true, SlotArmed2 = true, SlotArmed3 = true, SlotArmed4 = true, SlotArmed5 = true,
    SlotArmed6 = true, SlotArmed7 = true, SlotArmed8 = true, SlotArmed9 = true, SlotArmed10 = true,
}

local function saveConfig()
    local out = {}
    for k, v in CFG do
        if not CONFIG_SKIP[k] and type(v) ~= "table" then out[k] = v end
    end
    pcall(writefile, CONFIG_FILE, HttpService:JSONEncode(out))
end

local function loadConfig()
    local okRead, text = pcall(readfile, CONFIG_FILE)
    if not okRead then return end
    local okDecode, data = pcall(HttpService.JSONDecode, HttpService, text)
    if not okDecode or type(data) ~= "table" then return end
    for k, v in data do
        if CFG[k] ~= nil and not CONFIG_SKIP[k] and type(v) == type(CFG[k]) then CFG[k] = v end
    end
end

if CFG.Autoload then loadConfig() end

local HIT_PATTERNS = {
    "^HitWindow", "^SlamHit$", "^Impact$", "^Strike$", "^Kick$", "^Slash$",
    "^Attack%d*$", "^Slam$", "^Palm$", "^Throw$", "^Release$", "^Swing$",
    "^Hit$", "^Shoot$", "^Explosion$", "^Roar$",

    "^DoSkill$", "^FinalStrike$", "^SpinWindow", "^Fire$", "^Beam$",
}

local IGNORE_PATHS = {
    "Movement", "Misc", "Emotes", "Items", "Hit.", "Blocks", "Parrys",
    "Broom", "Idles", "Rigs", "Stagger", "GrimoireAnimations", "Carry",
}

local function isHitName(name)
    for _, pat in HIT_PATTERNS do
        if string.find(name, pat) then return true end
    end
    return false
end

local function pathIgnored(path)
    for _, pat in IGNORE_PATHS do
        if string.find(path, pat, 1, true) then return true end
    end
    return false
end

local BY_ID = {}
do
    local raw
    for _, path in CFG.TimingsFiles do
        local okRead, text = pcall(readfile, path)
        if okRead then
            raw = text
            break
        end
    end

    if not raw then
        local okHttp, text = pcall(function()
            return game:HttpGet(CFG.RemoteBase .. "clover-animation-timings.json")
        end)
        if okHttp then raw = text end
    end
    local ok, err = pcall(function()
        assert(raw, "no timings file locally or at " .. CFG.RemoteBase)
        local data = HttpService:JSONDecode(raw)
        for _, a in data.animations do
            local hits = {}
            if not pathIgnored(a.path) then
                for _, e in a.events or {} do
                    if isHitName(e.name) then
                        table.insert(hits, e.time)
                    end
                end
                table.sort(hits)
            end

            local misdirect = string.find(a.path, "Misdirect", 1, true) ~= nil
            local instant = #hits > 0 and hits[1] < CFG.InstantCutoff
            local skip = misdirect or instant

            local attack = not pathIgnored(a.path) and (string.find(a.path, "Skills.", 1, true)
                or string.find(a.path, "Magic.", 1, true)
                or string.find(a.path, "Server.", 1, true)
                or string.find(a.path, "NPCS.", 1, true)
                or string.find(a.path, "Combat.", 1, true)
                or string.find(a.path, "Crit.", 1, true))
            BY_ID[tostring(a.assetId)] = {path = a.path, hits = hits, attack = attack and true or false, skip = skip}
        end
    end)
    if not ok then
        warn("[autoparry] timings not loaded, generic mode only: " .. tostring(err))
    end
end

local refreshers = {}
local lastPress = 0

local LEARN_FILE = "CloverRPG/learned-timings.json"
local learned = {}
do
    local okRead, text = pcall(readfile, LEARN_FILE)
    if okRead then
        local okDecode, data = pcall(HttpService.JSONDecode, HttpService, text)
        if okDecode and type(data) == "table" then learned = data end
    end
end
local function saveLearned()
    pcall(writefile, LEARN_FILE, HttpService:JSONEncode(learned))
end
local activeNoMarker = {}

local function learnFromHit()
    local now = os.clock()
    for i = #activeNoMarker, 1, -1 do
        local a = activeNoMarker[i]
        if now - a.t > 4 or not a.track.IsPlaying then
            table.remove(activeNoMarker, i)
        elseif a.track.TimePosition > 0 and a.track.TimePosition <= a.track.Length then
            local t = a.track.TimePosition
            learned[a.id] = learned[a.id] and (learned[a.id] * 0.6 + t * 0.4) or t
            saveLearned()
            table.remove(activeNoMarker, i)
            if CFG.Logger then print(string.format("[learn] %s hit at %.3fs", a.id, learned[a.id])) end
            return
        end
    end
end
local blockUntil = 0
local holding = false
local windowFocused = true

UIS.WindowFocusReleased:Connect(function() windowFocused = false end)
UIS.WindowFocused:Connect(function() windowFocused = true end)

local function getRoot(model)
    return model and model:FindFirstChild("HumanoidRootPart")
end

local function attackerBehind(myRoot, theirRoot)
    local toAttacker = theirRoot.Position - myRoot.Position
    if toAttacker.Magnitude < 0.01 then return false end
    return myRoot.CFrame.LookVector:Dot(toAttacker.Unit) < -0.3
end

local function attacking()
    if UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then return true end
    local char = LP.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local animator = hum and hum:FindFirstChildOfClass("Animator")
    if not animator then return false end
    for _, t in animator:GetPlayingAnimationTracks() do
        local path = t.Animation and t.Animation:GetFullName() or ""
        if t.Priority.Value >= Enum.AnimationPriority.Action.Value
            and (string.find(path, "Server.", 1, true)
                or string.find(path, "Skills.", 1, true)
                or string.find(path, "Combat.", 1, true)) then
            return true
        end
    end
    return false
end

local function emoting()
    local char = LP.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local animator = hum and hum:FindFirstChildOfClass("Animator")
    if not animator then return false end
    for _, t in animator:GetPlayingAnimationTracks() do
        local path = t.Animation and t.Animation:GetFullName() or ""
        if string.find(path, "Emotes", 1, true) then return true end
    end
    return false
end

local function paused()
    if CFG.NoParryTabbed and not windowFocused then return true end
    if CFG.NoParryTyping and UIS:GetFocusedTextBox() then return true end
    if CFG.NoParryEmote and emoting() then return true end
    return false
end

local DODGE_KEY = Enum.KeyCode.Q

local function pressKey(key)
    VIM:SendKeyEvent(true, key, false, game)
    task.wait(0.05)
    VIM:SendKeyEvent(false, key, false, game)
end

local function fireBuffered()
    if not CFG.SkillBuffer then return end
    for i = 1, SLOT_COUNT do
        if CFG["SlotArmed" .. i] then
            CFG["SlotArmed" .. i] = false
            if refreshers["SlotArmed" .. i] then refreshers["SlotArmed" .. i]() end
            pressKey(Enum.KeyCode[CFG["SlotKey" .. i]])
            if CFG.Logger then print("[skill] slot " .. i .. " " .. CFG["SlotKey" .. i]) end
        end
    end
end

local RollInput = Packets.Combat.packets.RollInput

local function dodgeInPlace()
    pressKey(DODGE_KEY)
    RollInput.send({Action = "Cancel"})
    if CFG.Logger then print("[dodge] Q + cancel") end
    fireBuffered()
end

local function roll()
    dodgeInPlace()
end

local function cancelRoll()
    dodgeInPlace()
end

local function holdBlock(duration)
    blockUntil = math.max(blockUntil, os.clock() + duration)
    if holding then return end
    holding = true
    task.spawn(function()
        while os.clock() < blockUntil do
            BlockInput.send({Action = "Block Input"})
            task.wait(0.03)
        end
        BlockInput.send({Action = "End Block"})
        holding = false
    end)
end

local function parry()
    lastPress = os.clock()
    if CFG.Logger then print(string.format("[press] lead %.0fms", CFG.ParryLead * 1000)) end

    holdBlock(CFG.ParryLead + CFG.ParryWindow)

    if CFG.RollCancel then
        task.delay(CFG.RollCancelDelay, cancelRoll)
    elseif CFG.RollOnCooldown then
        task.delay(CFG.ParryCooldown, roll)
    else
        task.delay(CFG.ParryLead + CFG.ParryWindow, fireBuffered)
    end
end

local function run(action)
    action()
end

local function genericAttack(track)
    if track.Looped then return false end
    if track.Length < 0.2 then return false end

    local name = track.Name
    local bigMove = string.find(name, "Slam", 1, true) or string.find(name, "Jump", 1, true)
        or string.find(name, "Leap", 1, true) or string.find(name, "Ground", 1, true)
    if not bigMove and track.Priority.Value < Enum.AnimationPriority.Action.Value then return false end
    local path = track.Animation and track.Animation:GetFullName() or ""
    return not pathIgnored(path)
end

local function onTrack(model, track)
    if not CFG.Enabled then return end

    local player = Players:GetPlayerFromCharacter(model)
    if CFG.Filter == "PVE" and player then return end
    if CFG.Filter == "PVP" and not player then return end

    local myRoot = getRoot(LP.Character)
    local theirRoot = getRoot(model)
    if not myRoot or not theirRoot then return end
    if (myRoot.Position - theirRoot.Position).Magnitude > CFG.Range then return end

    local id = track.Animation and string.match(track.Animation.AnimationId, "%d+")
    if not id then return end

    if CFG.Logger then
        print("[seen]", model.Name, id, track.Priority.Name, track.Looped, track.Length)
    end

    local entry = BY_ID[id]
    if entry and entry.skip then return end
    if entry then
        if #entry.hits == 0 and not entry.attack then return end
    elseif not genericAttack(track) then
        return
    end

    if CFG.Logger then
        print("[anim]", model.Name, id, entry and entry.path or "unknown", track.Length)
    end

    local grimoire = entry ~= nil and (string.find(entry.path, "Magic.", 1, true) or string.find(entry.path, "Skills.", 1, true)) ~= nil
    local behind = (CFG.RollBehind and attackerBehind(myRoot, theirRoot))
        or (CFG.DodgeGrimoire and grimoire)
    local ping = CFG.PingComp and (LP:GetNetworkPing() * CFG.PingScale * 0.5) or 0
    local speed = math.max(track.Speed, 0.05)
    local scheduled = entry ~= nil and #entry.hits > 0
    local times
    if scheduled then
        times = entry.hits
    else

        times = {learned[id] or track.Length * CFG.FallbackDelay}
        local now = os.clock()
        for i = #activeNoMarker, 1, -1 do
            if now - activeNoMarker[i].t > 4 then table.remove(activeNoMarker, i) end
        end
        table.insert(activeNoMarker, {track = track, id = id, t = now})
    end

    for _, h in times do
        local at = math.max(0, h / speed - CFG.ParryLead - ping)
        task.delay(at, function()
            if not track.IsPlaying or not CFG.Enabled then return end
            run(function()
                if paused() then
                    if CFG.Logger then print("[decide] paused -> skip") end
                    return
                end
                if behind then
                    if CFG.Logger then print("[decide] dodge -> roll") end
                    roll()
                elseif CFG.NoParryM1 and attacking() then
                    if CFG.Logger then print("[decide] M1 held -> skip") end
                else
                    if CFG.Logger then print("[decide] parry") end
                    parry()
                end
            end)
        end)
    end
end

local function watchHumanoid(char)
    local hum = char:WaitForChild("Humanoid")
    local last = hum.Health
    hum.HealthChanged:Connect(function(h)
        if h < last then learnFromHit() end
        if h < last and CFG.Logger then
            local since = os.clock() - lastPress
            print(string.format("[hit] took %.1f dmg, %.0fms after last press", last - h, since * 1000))
        end
        last = h
    end)
end
LP.CharacterAdded:Connect(watchHumanoid)
if LP.Character then watchHumanoid(LP.Character) end

local hooked = {}
local function hookAnimator(animator)
    if hooked[animator] then return end
    local model = animator:FindFirstAncestorOfClass("Model")
    if not model or model == LP.Character then return end
    hooked[animator] = true
    animator.AnimationPlayed:Connect(function(track)
        onTrack(model, track)
    end)
end

for _, d in workspace:GetDescendants() do
    if d:IsA("Animator") then hookAnimator(d) end
end
workspace.DescendantAdded:Connect(function(d)
    if d:IsA("Animator") then hookAnimator(d) end
end)

local C = {
    Bg = Color3.fromRGB(26, 17, 25),
    Bar = Color3.fromRGB(34, 22, 32),
    Panel = Color3.fromRGB(31, 20, 30),
    Item = Color3.fromRGB(48, 31, 46),
    Accent = Color3.fromRGB(184, 128, 168),
    Text = Color3.fromRGB(234, 224, 232),
    Dim = Color3.fromRGB(142, 120, 138),
    Line = Color3.fromRGB(92, 60, 86),
}
local FONT = Enum.Font.Gotham
local TS = 12

local function make(class, props)
    local o = Instance.new(class)
    for k, v in props do o[k] = v end
    return o
end

local gui = make("ScreenGui", {
    Name = "meowmeowv6",
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Global,
})
pcall(function() gui.Parent = game:GetService("CoreGui") end)
if not gui.Parent then gui.Parent = LP:WaitForChild("PlayerGui") end

local win = make("Frame", {
    Name = "Window",
    Size = UDim2.fromOffset(548, 556),
    Position = UDim2.new(0.5, -274, 0.5, -278),
    BackgroundColor3 = C.Bg,
    BorderSizePixel = 0,
    Parent = gui,
})
make("UIStroke", {Color = C.Line, Parent = win})
win.Visible = not CFG.StartSilent

local titleBar = make("Frame", {
    Size = UDim2.new(1, 0, 0, 30),
    BackgroundColor3 = C.Bar,
    BorderSizePixel = 0,
    Parent = win,
})
make("TextLabel", {
    Size = UDim2.new(0.5, 0, 1, 0),
    Position = UDim2.fromOffset(10, 0),
    BackgroundTransparency = 1,
    Text = "meowmeow v6",
    TextColor3 = C.Text,
    Font = Enum.Font.GothamBold,
    TextSize = 13,
    TextXAlignment = Enum.TextXAlignment.Left,
    Parent = titleBar,
})
local search = make("TextBox", {
    Size = UDim2.fromOffset(160, 20),
    Position = UDim2.new(1, -170, 0, 5),
    BackgroundTransparency = 1,
    PlaceholderText = "search...",
    PlaceholderColor3 = C.Dim,
    Text = "",
    TextColor3 = C.Text,
    Font = FONT,
    TextSize = TS,
    TextXAlignment = Enum.TextXAlignment.Right,
    ClearTextOnFocus = false,
    Parent = titleBar,
})

local dragging, dragStart, startPos
titleBar.InputBegan:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging = true
        dragStart = i.Position
        startPos = win.Position
    end
end)
UIS.InputEnded:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
end)
UIS.InputChanged:Connect(function(i)
    if dragging and i.UserInputType == Enum.UserInputType.MouseMovement then
        local d = i.Position - dragStart
        win.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
    end
end)

local items = {}

local function register(label, frame)
    table.insert(items, {label = string.lower(label), frame = frame})
end

search:GetPropertyChangedSignal("Text"):Connect(function()
    local q = string.lower(search.Text)
    for _, e in items do
        e.frame.Visible = (q == "") or (string.find(e.label, q, 1, true) ~= nil)
    end
end)

local tabBar = make("Frame", {
    Size = UDim2.new(1, 0, 0, 32),
    Position = UDim2.fromOffset(0, 30),
    BackgroundColor3 = C.Bar,
    BorderSizePixel = 0,
    Parent = win,
})

local TABS = {"Combat", "Skills", "ESP", "Settings"}
local pages, tabButtons = {}, {}

local function selectTab(name)
    for n, p in pages do p.Visible = (n == name) end
    for n, t in tabButtons do
        t.btn.TextColor3 = (n == name) and C.Text or C.Dim
        t.line.Visible = (n == name)
    end
end

for i, name in TABS do
    local btn = make("TextButton", {
        Size = UDim2.new(1 / #TABS, 0, 1, 0),
        Position = UDim2.new((i - 1) / #TABS, 0, 0, 0),
        BackgroundTransparency = 1,
        Text = name,
        TextColor3 = C.Dim,
        Font = FONT,
        TextSize = 13,
        AutoButtonColor = false,
        Parent = tabBar,
    })
    local line = make("Frame", {
        Size = UDim2.new(0.5, 0, 0, 2),
        Position = UDim2.new(0.25, 0, 1, -2),
        BackgroundColor3 = C.Accent,
        BorderSizePixel = 0,
        Visible = false,
        Parent = btn,
    })
    tabButtons[name] = {btn = btn, line = line}
    btn.MouseButton1Click:Connect(function() selectTab(name) end)

    pages[name] = make("Frame", {
        Size = UDim2.new(1, 0, 1, -64),
        Position = UDim2.fromOffset(0, 64),
        BackgroundTransparency = 1,
        Visible = false,
        Parent = win,
    })
end

local function column(page, side, title)
    local panel = make("Frame", {
        Size = UDim2.new(0.5, -12, 1, -8),
        Position = side == "L" and UDim2.fromOffset(8, 4) or UDim2.new(0.5, 4, 0, 4),
        BackgroundColor3 = C.Panel,
        BorderSizePixel = 0,
        Parent = page,
    })
    make("UIStroke", {Color = C.Line, Parent = panel})
    make("TextLabel", {
        Size = UDim2.new(1, 0, 0, 24),
        BackgroundTransparency = 1,
        Text = title,
        TextColor3 = C.Text,
        Font = FONT,
        TextSize = TS,
        Parent = panel,
    })
    make("Frame", {
        Size = UDim2.new(1, -16, 0, 1),
        Position = UDim2.fromOffset(8, 24),
        BackgroundColor3 = C.Line,
        BorderSizePixel = 0,
        Parent = panel,
    })
    local body = make("Frame", {
        Size = UDim2.new(1, -16, 1, -34),
        Position = UDim2.fromOffset(8, 30),
        BackgroundTransparency = 1,
        Parent = panel,
    })
    make("UIListLayout", {Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = body})
    return body
end

local function checkbox(body, label, key)
    local row = make("TextButton", {
        Size = UDim2.new(1, 0, 0, 20),
        BackgroundTransparency = 1,
        Text = "",
        AutoButtonColor = false,
        Parent = body,
    })
    local box = make("Frame", {
        Size = UDim2.fromOffset(14, 14),
        Position = UDim2.fromOffset(2, 3),
        BackgroundColor3 = C.Item,
        BorderSizePixel = 0,
        Parent = row,
    })
    make("UIStroke", {Color = C.Line, Parent = box})
    local fill = make("Frame", {
        Size = UDim2.fromOffset(8, 8),
        Position = UDim2.fromOffset(3, 3),
        BackgroundColor3 = C.Accent,
        BorderSizePixel = 0,
        Visible = CFG[key],
        Parent = box,
    })
    make("TextLabel", {
        Size = UDim2.new(1, -26, 1, 0),
        Position = UDim2.fromOffset(24, 0),
        BackgroundTransparency = 1,
        Text = label,
        TextColor3 = C.Text,
        Font = FONT,
        TextSize = TS,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = row,
    })
    refreshers[key] = function() fill.Visible = CFG[key] end
    row.MouseButton1Click:Connect(function()
        CFG[key] = not CFG[key]
        fill.Visible = CFG[key]
    end)
    register(label, row)
end

local function slider(body, label, key, min, max, step, suffix)
    local holder = make("Frame", {Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1, Parent = body})
    local bar = make("Frame", {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundColor3 = C.Item,
        BorderSizePixel = 0,
        ClipsDescendants = true,
        Parent = holder,
    })
    make("UIStroke", {Color = C.Line, Parent = bar})
    local fill = make("Frame", {
        Size = UDim2.new(0, 0, 1, 0),
        BackgroundColor3 = C.Accent,
        BackgroundTransparency = 0.5,
        BorderSizePixel = 0,
        Parent = bar,
    })
    local text = make("TextLabel", {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        TextColor3 = C.Text,
        Font = FONT,
        TextSize = TS,
        ZIndex = 2,
        Parent = bar,
    })
    local decimals = step < 1 and 2 or 0
    local fmt = "%." .. decimals .. "f"

    local function refresh()
        local v = CFG[key]
        fill.Size = UDim2.new((v - min) / (max - min), 0, 1, 0)
        text.Text = label .. ": " .. string.format(fmt, v) .. suffix
    end
    refreshers[key] = refresh

    local dragging = false
    local function setFrom(x)
        local rel = math.clamp((x - bar.AbsolutePosition.X) / bar.AbsoluteSize.X, 0, 1)
        local raw = min + rel * (max - min)
        CFG[key] = math.clamp(math.floor(raw / step + 0.5) * step, min, max)
        refresh()
    end
    bar.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            setFrom(i.Position.X)
        end
    end)
    UIS.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
    end)
    UIS.InputChanged:Connect(function(i)
        if dragging and i.UserInputType == Enum.UserInputType.MouseMovement then
            setFrom(i.Position.X)
        end
    end)

    refresh()
    register(label, holder)
end

local function dropdown(body, label, key, options)
    local holder = make("Frame", {Size = UDim2.new(1, 0, 0, 44), BackgroundTransparency = 1, Parent = body})
    make("TextLabel", {
        Size = UDim2.new(1, 0, 0, 16),
        BackgroundTransparency = 1,
        Text = label,
        TextColor3 = C.Dim,
        Font = FONT,
        TextSize = TS,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = holder,
    })
    local box = make("TextButton", {
        Size = UDim2.new(1, 0, 0, 22),
        Position = UDim2.fromOffset(0, 18),
        BackgroundColor3 = C.Item,
        BorderSizePixel = 0,
        Text = "",
        AutoButtonColor = false,
        Parent = holder,
    })
    make("UIStroke", {Color = C.Line, Parent = box})
    local value = make("TextLabel", {
        Size = UDim2.new(1, -28, 1, 0),
        Position = UDim2.fromOffset(8, 0),
        BackgroundTransparency = 1,
        Text = CFG[key],
        TextColor3 = C.Text,
        Font = FONT,
        TextSize = TS,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = box,
    })
    make("TextLabel", {
        Size = UDim2.fromOffset(20, 22),
        Position = UDim2.new(1, -22, 0, 0),
        BackgroundTransparency = 1,
        Text = "v",
        TextColor3 = C.Dim,
        Font = FONT,
        TextSize = TS,
        Parent = box,
    })

    local list = make("Frame", {
        Size = UDim2.new(1, 0, 0, #options * 20),
        Position = UDim2.new(0, 0, 1, 2),
        BackgroundColor3 = C.Item,
        BorderSizePixel = 0,
        Visible = false,
        ZIndex = 10,
        Parent = box,
    })
    make("UIStroke", {Color = C.Line, Parent = list})
    for i, opt in options do
        local b = make("TextButton", {
            Size = UDim2.new(1, 0, 0, 20),
            Position = UDim2.fromOffset(0, (i - 1) * 20),
            BackgroundTransparency = 1,
            Text = opt,
            TextColor3 = C.Text,
            Font = FONT,
            TextSize = TS,
            AutoButtonColor = false,
            ZIndex = 11,
            Parent = list,
        })
        b.MouseButton1Click:Connect(function()
            CFG[key] = opt
            value.Text = opt
            list.Visible = false
        end)
    end
    box.MouseButton1Click:Connect(function()
        list.Visible = not list.Visible
    end)
    register(label, holder)
end

local HOTKEYS = {
    Enabled = Enum.KeyCode.F6,
}
local HOTKEY_LABELS = {
    Enabled = "Auto Parry",
}
local listening = nil
local keyButtons = {}

local function keybind(body, name)
    local row = make("Frame", {Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1, Parent = body})
    make("TextLabel", {
        Size = UDim2.new(1, -90, 1, 0),
        BackgroundTransparency = 1,
        Text = "Toggle " .. HOTKEY_LABELS[name],
        TextColor3 = C.Text,
        Font = FONT,
        TextSize = TS,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = row,
    })
    local btn = make("TextButton", {
        Size = UDim2.fromOffset(80, 22),
        Position = UDim2.new(1, -80, 0, 0),
        BackgroundColor3 = C.Item,
        BorderSizePixel = 0,
        Text = HOTKEYS[name].Name,
        TextColor3 = C.Text,
        Font = FONT,
        TextSize = TS,
        AutoButtonColor = false,
        Parent = row,
    })
    make("UIStroke", {Color = C.Line, Parent = btn})
    keyButtons[name] = btn
    btn.MouseButton1Click:Connect(function()
        listening = name
        btn.Text = "press a key"
    end)
    register("toggle " .. HOTKEY_LABELS[name], row)
end

local broomVel
local broomConn
local scalingBroom = false
local lastBroomFind = 0

local function findBroomVelocity()
    local char = LP.Character
    if not char then return end
    for _, d in char:GetDescendants() do
        if d:IsA("LinearVelocity") and d.Enabled then
            return d
        end
    end
end

local function hookBroom(lv)
    if broomConn then broomConn:Disconnect() end
    broomVel = lv
    broomConn = lv:GetPropertyChangedSignal("VectorVelocity"):Connect(function()
        if scalingBroom or CFG.BroomSpeed <= 1 then return end
        scalingBroom = true
        local v = lv.VectorVelocity
        lv.VectorVelocity = Vector3.new(v.X * CFG.BroomSpeed, v.Y, v.Z * CFG.BroomSpeed)
        scalingBroom = false
    end)
end

RunService.Heartbeat:Connect(function()
    if CFG.BroomSpeed <= 1 then return end
    if broomVel and broomVel.Parent then return end
    if os.clock() - lastBroomFind < 0.5 then return end
    lastBroomFind = os.clock()
    local lv = findBroomVelocity()
    if lv then hookBroom(lv) end
end)

local whitelist = {}
local playerList
local ESP_TAG = "meowESP"

local function clearESP(player)
    local char = player.Character
    if not char then return end
    local h = char:FindFirstChild(ESP_TAG)
    if h then h:Destroy() end
    local head = char:FindFirstChild("Head")
    local bb = head and head:FindFirstChild(ESP_TAG .. "Tag")
    if bb then bb:Destroy() end
end

local function drawESP(player)
    local char = player.Character
    local root = char and char.PrimaryPart
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local head = char and char:FindFirstChild("Head")
    if not (root and hum and head) then return end

    local h = char:FindFirstChild(ESP_TAG)
    if CFG.ESPHighlight then
        if not h then
            h = make("Highlight", {
                Name = ESP_TAG,
                OutlineColor = Color3.new(1, 1, 1),
                FillTransparency = 0.6,
                OutlineTransparency = 0,
                Adornee = char,
                Parent = char,
            })
        end
        h.FillColor = hum.Health <= 0 and Color3.fromRGB(120, 0, 0) or Color3.fromRGB(255, 0, 0)
    elseif h then
        h:Destroy()
    end

    local bb = head:FindFirstChild(ESP_TAG .. "Tag")
    if CFG.ESPNameTag then
        if not bb then
            bb = make("BillboardGui", {
                Name = ESP_TAG .. "Tag",
                Adornee = head,
                Size = UDim2.new(0, 130, 0, 25),
                StudsOffset = Vector3.new(0, 2, 0),
                AlwaysOnTop = true,
                Parent = head,
            })
            make("TextLabel", {
                Name = "Label",
                Size = UDim2.new(1, 0, 1, 0),
                BackgroundTransparency = 1,
                TextColor3 = Color3.new(1, 1, 1),
                Font = FONT,
                TextScaled = true,
                TextStrokeTransparency = 0.6,
                Parent = bb,
            })
        end
        local myRoot = getRoot(LP.Character)
        local dist = myRoot and math.floor((myRoot.Position - root.Position).Magnitude) or 0
        bb.Label.Text = string.format("%s | %dm | %d hp", player.Name, dist, math.floor(hum.Health))
    elseif bb then
        bb:Destroy()
    end
end

task.spawn(function()
    while true do
        for _, p in Players:GetPlayers() do
            if p ~= LP then
                if CFG.ESP and (not CFG.WhitelistOnly or whitelist[p.Name]) then drawESP(p) else clearESP(p) end
            end
        end
        task.wait(0.3)
    end
end)

local function rebuildPlayers()
    if not playerList then return end
    for _, child in playerList:GetChildren() do
        if child:IsA("TextButton") then child:Destroy() end
    end
    for _, p in Players:GetPlayers() do
        if p ~= LP then
            local row = make("TextButton", {
                Name = p.Name,
                Size = UDim2.new(1, 0, 0, 20),
                BackgroundTransparency = 1,
                Text = "",
                AutoButtonColor = false,
                Parent = playerList,
            })
            local box = make("Frame", {
                Size = UDim2.fromOffset(14, 14),
                Position = UDim2.fromOffset(2, 3),
                BackgroundColor3 = C.Item,
                BorderSizePixel = 0,
                Parent = row,
            })
            make("UIStroke", {Color = C.Line, Parent = box})
            local fill = make("Frame", {
                Size = UDim2.fromOffset(8, 8),
                Position = UDim2.fromOffset(3, 3),
                BackgroundColor3 = C.Accent,
                BorderSizePixel = 0,
                Visible = whitelist[p.Name] == true,
                Parent = box,
            })
            make("TextLabel", {
                Size = UDim2.new(1, -26, 1, 0),
                Position = UDim2.fromOffset(24, 0),
                BackgroundTransparency = 1,
                Text = p.Name,
                TextColor3 = C.Text,
                Font = FONT,
                TextSize = TS,
                TextXAlignment = Enum.TextXAlignment.Left,
                Parent = row,
            })
            row.MouseButton1Click:Connect(function()
                whitelist[p.Name] = not whitelist[p.Name]
                fill.Visible = whitelist[p.Name] == true
            end)
        end
    end
end

Players.PlayerAdded:Connect(rebuildPlayers)
Players.PlayerRemoving:Connect(function(p)
    clearESP(p)
    rebuildPlayers()
end)

local OBJ_TAG = "meowObj"
local NPC_COLOR = Color3.fromRGB(255, 200, 80)
local QUEST_COLOR = Color3.fromRGB(120, 255, 140)

local function anchorOf(inst)
    if inst:IsA("BasePart") then return inst end
    if inst:IsA("Model") then return inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart") end
end

local function clearObject(inst)
    local h = inst:FindFirstChild(OBJ_TAG)
    if h then h:Destroy() end
    local part = anchorOf(inst)
    local bb = part and part:FindFirstChild(OBJ_TAG .. "Tag")
    if bb then bb:Destroy() end
end

local function drawObject(inst, text, color)
    local part = anchorOf(inst)
    if not part then return end
    local h = inst:FindFirstChild(OBJ_TAG)
    if CFG.ESPHighlight then
        if not h then
            h = make("Highlight", {
                Name = OBJ_TAG,
                OutlineColor = Color3.new(1, 1, 1),
                FillTransparency = 0.6,
                OutlineTransparency = 0,
                Adornee = inst,
                Parent = inst,
            })
        end
        h.FillColor = color
    elseif h then
        h:Destroy()
    end
    local bb = part:FindFirstChild(OBJ_TAG .. "Tag")
    if not bb then
        bb = make("BillboardGui", {
            Name = OBJ_TAG .. "Tag",
            Adornee = part,
            Size = UDim2.new(0, 150, 0, 25),
            StudsOffset = Vector3.new(0, 3, 0),
            AlwaysOnTop = true,
            Parent = part,
        })
        make("TextLabel", {
            Name = "Label",
            Size = UDim2.new(1, 0, 1, 0),
            BackgroundTransparency = 1,
            TextColor3 = color,
            Font = FONT,
            TextScaled = true,
            TextStrokeTransparency = 0.6,
            Parent = bb,
        })
    end
    local myRoot = getRoot(LP.Character)
    local dist = myRoot and math.floor((myRoot.Position - part.Position).Magnitude) or 0
    bb.Label.Text = string.format("%s | %dm", text, dist)
end

local function objectTargets()
    local out = {}
    if CFG.NPCESP then
        for _, inst in CollectionService:GetTagged("NPC") do
            table.insert(out, {inst = inst, text = tostring(inst:GetAttribute("NPCId") or inst.Name), color = NPC_COLOR})
        end
    end
    if CFG.QuestESP then
        for _, tag in {"QuestNPC", "QuestObject"} do
            for _, inst in CollectionService:GetTagged(tag) do
                table.insert(out, {inst = inst, text = "! " .. inst.Name, color = QUEST_COLOR})
            end
        end
    end
    return out
end

task.spawn(function()
    local drawn = {}
    while true do
        local now = {}
        for _, t in objectTargets() do
            now[t.inst] = true
            drawObject(t.inst, t.text, t.color)
        end
        for inst in pairs(drawn) do
            if not now[inst] then clearObject(inst) end
        end
        drawn = now
        task.wait(0.5)
    end
end)

local KEY_OPTIONS = {"One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Zero", "Q", "E", "R", "F", "Z", "X", "C"}

local combat = pages.Combat
local left = column(combat, "L", "Main")
checkbox(left, "Enable Auto Parry", "Enabled")
checkbox(left, "Roll On Parry Cooldown", "RollOnCooldown")
checkbox(left, "Roll If Attack Is Behind", "RollBehind")
checkbox(left, "Roll Cancel", "RollCancel")
checkbox(left, "Dodge Grimoire Moves", "DodgeGrimoire")
checkbox(left, "Don't Parry While M1ing", "NoParryM1")
checkbox(left, "Ping Compensation", "PingComp")
dropdown(left, "Auto Parry Filters", "Filter", {"All", "PVE", "PVP"})

local right = column(combat, "R", "Timing")
slider(right, "Parry Lead", "ParryLead", 0, 0.6, 0.01, "s")
slider(right, "Parry Window", "ParryWindow", 0.05, 0.4, 0.01, "s")
slider(right, "Hit At (no marker)", "FallbackDelay", 0.3, 1.2, 0.05, "x anim")
slider(right, "Range", "Range", 5, 40, 1, " studs")
slider(right, "Roll Cancel Delay", "RollCancelDelay", 0, 0.5, 0.01, "s")
slider(right, "Parry Cooldown", "ParryCooldown", 0, 2, 0.05, "s")
slider(right, "Ping Scale", "PingScale", 0, 2, 0.1, "x")
slider(right, "Broom Speed", "BroomSpeed", 1, 2, 0.1, "x")

local skills = pages.Skills
local hotbar = column(skills, "L", "Slots 1-5")
checkbox(hotbar, "Skill Buffer On", "SkillBuffer")
for i = 1, 5 do
    checkbox(hotbar, "Slot " .. i .. " Buffered", "SlotArmed" .. i)
    dropdown(hotbar, "Slot " .. i .. " Key", "SlotKey" .. i, KEY_OPTIONS)
end

local buffer = column(skills, "R", "Slots 6-10")
for i = 6, SLOT_COUNT do
    checkbox(buffer, "Slot " .. i .. " Buffered", "SlotArmed" .. i)
    dropdown(buffer, "Slot " .. i .. " Key", "SlotKey" .. i, KEY_OPTIONS)
end
make("TextLabel", {
    Size = UDim2.new(1, 0, 0, 80),
    BackgroundTransparency = 1,
    Text = "Tick a slot to buffer it. It presses its key once after the next dodge or parry, then unticks. Slot keys must match the skill binds in your game.",
    TextColor3 = C.Dim,
    Font = FONT,
    TextSize = TS,
    TextWrapped = true,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Top,
    Parent = buffer,
})

local settings = pages.Settings
local keys = column(settings, "L", "Keys")
dropdown(keys, "UI Toggle", "UIKey", {"RightShift", "RightControl", "Insert", "Home"})
checkbox(keys, "No Parry While Tabbed Out", "NoParryTabbed")
checkbox(keys, "No Parry While Typing", "NoParryTyping")
checkbox(keys, "No Parry While Emoting", "NoParryEmote")
keybind(keys, "Enabled")
checkbox(keys, "Autoload Config", "Autoload")
checkbox(keys, "Silent Start", "StartSilent")
local saveBtn = make("TextButton", {
    Size = UDim2.new(1, 0, 0, 22),
    BackgroundColor3 = C.Item,
    BorderSizePixel = 0,
    Text = "Save Config",
    TextColor3 = C.Text,
    Font = FONT,
    TextSize = TS,
    AutoButtonColor = false,
    Parent = keys,
})
make("UIStroke", {Color = C.Line, Parent = saveBtn})
saveBtn.MouseButton1Click:Connect(saveConfig)

local debug = column(settings, "R", "Debug")
checkbox(debug, "Print Animation Logs", "Logger")

local esp = column(pages.ESP, "L", "ESP")
checkbox(esp, "ESP On", "ESP")
checkbox(esp, "Highlight", "ESPHighlight")
checkbox(esp, "Name Tag", "ESPNameTag")
checkbox(esp, "Only Whitelisted", "WhitelistOnly")
checkbox(esp, "NPC ESP", "NPCESP")
checkbox(esp, "Quest ESP", "QuestESP")
local playerBody = column(pages.ESP, "R", "Whitelist")
playerList = make("ScrollingFrame", {
    Size = UDim2.new(1, 0, 1, 0),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 4,
    ScrollBarImageColor3 = C.Accent,
    CanvasSize = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    Parent = playerBody,
})
make("UIListLayout", {Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.Name, Parent = playerList})
rebuildPlayers()

selectTab("Combat")

UIS.InputBegan:Connect(function(input, gp)
    if listening then
        if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
        if input.KeyCode ~= Enum.KeyCode.Escape then
            HOTKEYS[listening] = input.KeyCode
        end
        keyButtons[listening].Text = HOTKEYS[listening].Name
        listening = nil
        return
    end
    if gp then return end
    if input.KeyCode == Enum.KeyCode[CFG.UIKey] then
        win.Visible = not win.Visible
        return
    end
    for name, key in HOTKEYS do
        if input.KeyCode == key then
            CFG[name] = not CFG[name]
            refreshers[name]()
            return
        end
    end
end)
