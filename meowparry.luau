-- clover auto parry ui
-- timings: clover-animation-timings.json (same folder, readfile)
-- F6 toggles auto parry, UI key toggles the window (default RightShift)

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local VIM = game:GetService("VirtualInputManager")
local HttpService = game:GetService("HttpService")
local RS = game:GetService("ReplicatedStorage")

local LP = Players.LocalPlayer
local Packets = require(RS.Modules.Packets)
local BlockInput = Packets.Combat.packets.BlockInput

local SLOT_COUNT = 5

local CFG = {
    Enabled = true,
    RollOnCooldown = true,
    RollBehind = true,
    DodgeGrimoire = false,
    RollCancel = true,
    NoParryM1 = true,
    NoParryTabbed = true,   -- F7: no parry while the Roblox window is not focused
    NoParryTyping = true,   -- F8: no parry while a text box has focus
    NoParryEmote = true,    -- F9: no parry while an emote anim is playing
    PingComp = true,
    SkillBuffer = false,
    Logger = false,
    Filter = "All",
    UIKey = "RightShift",
    ParryLead = 0.1,
    InstantCutoff = 0.15,   -- first hit marker sooner than this after the anim starts = instant move, not parried
    ParryWindow = 0.15,
    FallbackDelay = 0.35,
    Range = 24,
    RollCancelDelay = 0.05,
    ParryCooldown = 0.6,
    PingScale = 1,
    -- hotbar: each slot is a key the game already binds to a skill. FILL: match these to your binds
    SlotKey1 = "One",
    SlotKey2 = "Two",
    SlotKey3 = "Three",
    SlotKey4 = "Four",
    SlotKey5 = "Five",
    SlotArmed1 = false,
    SlotArmed2 = false,
    SlotArmed3 = false,
    SlotArmed4 = false,
    SlotArmed5 = false,
    RemoteBase = "https://raw.githubusercontent.com/meowlollll/meowparry/main/",
    -- readfile is relative to the executor workspace, so try the likely folder layouts
    TimingsFiles = {
        "CloverRPG/clover-animation-timings.json",
        "CloverRPG\\clover-animation-timings.json",
        "clover-animation-timings.json",
    },
}

local HIT_PATTERNS = {
    "^HitWindow", "^SlamHit$", "^Impact$", "^Strike$", "^Kick$", "^Slash$",
    "^Attack%d*$", "^Slam$", "^Palm$", "^Throw$", "^Release$", "^Swing$",
    "^Hit$", "^Shoot$", "^Explosion$", "^Roar$",
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
    -- no local copy: fetch the json from the repo, so loadstring from GitHub works on its own
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
            -- misdirects and instant hits are not parried: they bait or land before a block can start.
            -- Feint markers are NOT used here: basic chains (Punch, Sword, Katana...) all carry OpenFeint/CloseFeint
            local misdirect = string.find(a.path, "Misdirect", 1, true) ~= nil
            local instant = #hits > 0 and hits[1] < CFG.InstantCutoff
            local skip = misdirect or instant
            -- grimoire and boss moves often have no hit marker in the json, keep them with a fallback delay
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

---------------------------------------------------------------------------
-- combat logic
---------------------------------------------------------------------------

local refreshers = {}
local lastPress = 0
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

-- true while any of the pause checks are on and their condition holds
local function paused()
    if CFG.NoParryTabbed and not windowFocused then return true end
    if CFG.NoParryTyping and UIS:GetFocusedTextBox() then return true end
    if CFG.NoParryEmote and emoting() then return true end
    return false
end

-- dodge and roll cancel both press Q, the game's roll bind
local DODGE_KEY = Enum.KeyCode.Q

local function pressKey(key)
    VIM:SendKeyEvent(true, key, false, game)
    task.wait(0.05)
    VIM:SendKeyEvent(false, key, false, game)
end

-- fires each armed hotbar slot once, then disarms it
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

-- Q starts a roll, which moves you forward. the Cancel packet right after stops that velocity,
-- and the game plays its cancel anim in place (Dash.lua OnCancelled), so this is the on-the-spot dodge
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

-- one shared hold: overlapping parries extend the block instead of stacking loops
local function holdBlock(duration)
    blockUntil = math.max(blockUntil, os.clock() + duration)
    if holding then return end
    holding = true
    task.spawn(function()
        while os.clock() < blockUntil do
            BlockInput.send({Action = "Block Input"})
            task.wait()
        end
        BlockInput.send({Action = "End Block"})
        holding = false
    end)
end

local function parry()
    lastPress = os.clock()
    if CFG.Logger then print(string.format("[press] lead %.0fms", CFG.ParryLead * 1000)) end
    -- block starts ParryLead before the hit, so it must stay up ParryLead + ParryWindow to cover it
    holdBlock(CFG.ParryLead + CFG.ParryWindow)

    if CFG.RollCancel then
        task.delay(CFG.RollCancelDelay, cancelRoll)
    elseif CFG.RollOnCooldown then
        task.delay(CFG.ParryCooldown, roll)
    else
        task.delay(CFG.ParryLead + CFG.ParryWindow, fireBuffered)
    end
end

-- every scheduled hit gets its own action, so multi-hit moves get one parry per hit
local function run(action)
    action()
end

local function genericAttack(track)
    if track.Looped then return false end
    if track.Length < 0.2 then return false end
    -- jumps and slams often play at a lower priority, so the priority check would drop them
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

    -- dodge (roll) instead of parry when the attacker is behind, or for grimoire moves when enabled
    local grimoire = entry ~= nil and (string.find(entry.path, "Magic.", 1, true) or string.find(entry.path, "Skills.", 1, true)) ~= nil
    local behind = (CFG.RollBehind and attackerBehind(myRoot, theirRoot))
        or (CFG.DodgeGrimoire and grimoire)
    local ping = CFG.PingComp and (LP:GetNetworkPing() * CFG.PingScale * 0.5) or 0
    local speed = math.max(track.Speed, 0.05)
    local scheduled = entry ~= nil and #entry.hits > 0
    local times = scheduled and entry.hits or {CFG.FallbackDelay}

    for _, h in times do
        local at = math.max(0, (scheduled and h / speed or h) - CFG.ParryLead - ping)
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

-- damage taken shortly after a press means that parry missed
local function watchHumanoid(char)
    local hum = char:WaitForChild("Humanoid")
    local last = hum.Health
    hum.HealthChanged:Connect(function(h)
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

---------------------------------------------------------------------------
-- ui
---------------------------------------------------------------------------

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
    Name = "meowmeowv5",
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
    Text = "meowmeow v5",
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

local TABS = {"Combat", "Skills", "Settings"}
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

-- hotkeys: click a key button, then press the new key (Escape cancels)
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

local KEY_OPTIONS = {"One", "Two", "Three", "Four", "Five", "Q", "E", "R", "F", "Z", "X", "C"}

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
slider(right, "Fallback Delay", "FallbackDelay", 0.1, 0.8, 0.01, "s")
slider(right, "Range", "Range", 5, 40, 1, " studs")
slider(right, "Roll Cancel Delay", "RollCancelDelay", 0, 0.5, 0.01, "s")
slider(right, "Parry Cooldown", "ParryCooldown", 0, 2, 0.05, "s")
slider(right, "Ping Scale", "PingScale", 0, 2, 0.1, "x")

local skills = pages.Skills
local hotbar = column(skills, "L", "Hotbar")
checkbox(hotbar, "Skill Buffer On", "SkillBuffer")
for i = 1, SLOT_COUNT do
    checkbox(hotbar, "Slot " .. i .. " Buffered", "SlotArmed" .. i)
    dropdown(hotbar, "Slot " .. i .. " Key", "SlotKey" .. i, KEY_OPTIONS)
end

local buffer = column(skills, "R", "Buffer")
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

local debug = column(settings, "R", "Debug")
checkbox(debug, "Print Animation Logs", "Logger")

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
