-- ============================================================================
-- RE:Flip - 翻转重启
-- 经典俄罗斯方块 + 重力翻转 + 消行重启到对面
-- 24h Game Jam | Theme: RE (Restart)
-- ============================================================================

local UI = require("urhox-libs/UI")

-- ============================================================================
-- 游戏配置
-- ============================================================================
local CONFIG = {
    Title = "RE:Flip",
    COLS = 10,
    ROWS = 20,

    -- 节奏
    INITIAL_DROP_INTERVAL = 0.8,
    MIN_DROP_INTERVAL = 0.08,
    SPEED_ACCEL = 0.004,
    LOCK_DELAY = 0.5,
    RESTART_GRACE = 1.8,
    SOFT_DROP_INTERVAL = 0.04,

    -- DAS (键盘自动重复)
    DAS_DELAY = 0.16,
    DAS_REPEAT = 0.04,

    -- 方块颜色（霓虹风格，索引对应方块类型 1-7）
    PIECE_COLORS = {
        { 0, 230, 230, 255 },     -- 1: I 青
        { 230, 230, 0, 255 },     -- 2: O 黄
        { 170, 0, 255, 255 },     -- 3: T 紫
        { 0, 230, 100, 255 },     -- 4: S 绿
        { 230, 50, 50, 255 },     -- 5: Z 红
        { 50, 50, 230, 255 },     -- 6: J 蓝
        { 230, 150, 0, 255 },     -- 7: L 橙
    },

    BG_COLOR = { 10, 12, 22 },
    GRID_LINE_RGBA = { 35, 40, 58, 45 },
    GRID_BORDER_RGBA = { 70, 80, 120, 200 },
    GHOST_ALPHA = 35,
}

-- ============================================================================
-- 方块形状定义（基础矩阵，旋转在运行时计算）
-- ============================================================================
local BASE_SHAPES = {
    -- 1: I
    {
        { 0, 0, 0, 0 },
        { 1, 1, 1, 1 },
        { 0, 0, 0, 0 },
        { 0, 0, 0, 0 },
    },
    -- 2: O
    {
        { 1, 1 },
        { 1, 1 },
    },
    -- 3: T
    {
        { 0, 1, 0 },
        { 1, 1, 1 },
        { 0, 0, 0 },
    },
    -- 4: S
    {
        { 0, 1, 1 },
        { 1, 1, 0 },
        { 0, 0, 0 },
    },
    -- 5: Z
    {
        { 1, 1, 0 },
        { 0, 1, 1 },
        { 0, 0, 0 },
    },
    -- 6: J
    {
        { 1, 0, 0 },
        { 1, 1, 1 },
        { 0, 0, 0 },
    },
    -- 7: L
    {
        { 0, 0, 1 },
        { 1, 1, 1 },
        { 0, 0, 0 },
    },
}

--- 预计算旋转表 ROTATIONS[type][rotState] = matrix
---@type table<number, table<number, number[][]>>
local ROTATIONS = {}

--- 矩阵顺时针旋转 90 度
local function RotateMatrixCW(m)
    local rows = #m
    local cols = #m[1]
    local result = {}
    for c = 1, cols do
        result[c] = {}
        for r = rows, 1, -1 do
            result[c][rows - r + 1] = m[r][c]
        end
    end
    return result
end

local function InitRotations()
    for i, shape in ipairs(BASE_SHAPES) do
        ROTATIONS[i] = {}
        local cur = shape
        for rot = 1, 4 do
            ROTATIONS[i][rot] = cur
            cur = RotateMatrixCW(cur)
        end
    end
end

-- ============================================================================
-- 游戏状态
-- ============================================================================
local gameState = "menu" -- menu / playing / gameover

---@type number[][]
local grid = {} -- grid[row][col] = colorIndex (0=空)

-- 当前方块
local current = nil -- { type, rot, row, col }
local gravityDown = true

-- 下落计时
local dropTimer = 0
local dropInterval = CONFIG.INITIAL_DROP_INTERVAL

-- 锁定延迟
local lockTimer = 0
local isLocking = false

-- 重启机制
local nextFromOpposite = false
local isRestartPiece = false
local restartGraceTimer = 0
local restartDropDir = 0 -- 重启方块的固定下落方向 (-1 or 1)

-- 软降
local isSoftDrop = false

-- 分数
local score = 0
local linesCleared = 0
local level = 1
local highScore = 0
local combo = 0

-- 消行动画
local clearAnimations = {}

-- DAS (键盘长按自动重复)
local dasDir = 0
local dasTimer = 0
local dasTriggered = false

-- 屏幕布局
local layout = {
    screenW = 0, screenH = 0,
    gridX = 0, gridY = 0,
    gridW = 0, gridH = 0,
    cellSize = 0,
}

-- UI
local uiRoot_ = nil

-- ============================================================================
-- 生命周期
-- ============================================================================

function Start()
    graphics.windowTitle = CONFIG.Title
    InitRotations()

    UI.Init({
        fonts = {
            { family = "sans", weights = {
                normal = "Fonts/MiSans-Regular.ttf",
            } }
        },
        scale = UI.Scale.DEFAULT,
    })

    CalculateLayout()
    InitGrid()
    CreateUI()

    SubscribeToEvent("Update", "HandleUpdate")
    SubscribeToEvent("KeyDown", "HandleKeyDown")
    SubscribeToEvent("KeyUp", "HandleKeyUp")
    SubscribeToEvent("MouseButtonDown", "HandleMouseClick")
    SubscribeToEvent("TouchBegin", "HandleTouchBegin")
    SubscribeToEvent("NanoVGRender", "HandleNanoVGRender")

    print("=== RE:Flip Started ===")
    print("Controls: Arrows=move/rotate, Space=flip, C=hard drop")
end

function Stop()
    UI.Shutdown()
end

-- ============================================================================
-- 布局
-- ============================================================================

function CalculateLayout()
    local dpr = graphics:GetDPR()
    layout.screenW = math.floor(graphics:GetWidth() / dpr)
    layout.screenH = math.floor(graphics:GetHeight() / dpr)

    local btnAreaH = 96
    local hudH = 52
    local pad = 16
    local availH = layout.screenH - btnAreaH - hudH - pad
    local availW = layout.screenW * 0.92

    local cellByH = availH / CONFIG.ROWS
    local cellByW = availW / CONFIG.COLS
    layout.cellSize = math.floor(math.min(cellByH, cellByW))

    layout.gridW = layout.cellSize * CONFIG.COLS
    layout.gridH = layout.cellSize * CONFIG.ROWS
    layout.gridX = math.floor((layout.screenW - layout.gridW) / 2)
    layout.gridY = hudH + math.floor((availH - layout.gridH) / 2)

    print(string.format("[Layout] screen=%dx%d cell=%d grid=%dx%d at(%d,%d)",
        layout.screenW, layout.screenH, layout.cellSize,
        layout.gridW, layout.gridH, layout.gridX, layout.gridY))
end

-- ============================================================================
-- 网格
-- ============================================================================

function InitGrid()
    grid = {}
    for r = 1, CONFIG.ROWS do
        grid[r] = {}
        for c = 1, CONFIG.COLS do
            grid[r][c] = 0
        end
    end
end

-- ============================================================================
-- 方块核心操作
-- ============================================================================

--- 获取当前方块的矩阵
local function GetMatrix(pieceType, rot)
    return ROTATIONS[pieceType][rot]
end

--- 检查方块能否放在指定位置
local function CanPlace(pType, rot, row, col)
    local m = GetMatrix(pType, rot)
    for r = 1, #m do
        for c = 1, #m[r] do
            if m[r][c] == 1 then
                local gr = row + r - 1
                local gc = col + c - 1
                if gr < 1 or gr > CONFIG.ROWS or gc < 1 or gc > CONFIG.COLS then
                    return false
                end
                if grid[gr][gc] ~= 0 then
                    return false
                end
            end
        end
    end
    return true
end

--- 获取方块的当前下落方向
local function GetDropStep()
    if isRestartPiece then
        return restartDropDir
    end
    return gravityDown and 1 or -1
end

--- 获取 ghost 行（方块直降的位置）
local function GetGhostRow()
    if not current then return nil end
    local step = GetDropStep()
    local testRow = current.row
    while CanPlace(current.type, current.rot, testRow + step, current.col) do
        testRow = testRow + step
    end
    return testRow
end

--- 生成新方块
function SpawnPiece()
    local pType = math.random(1, 7)
    local rot = 1
    local m = GetMatrix(pType, rot)
    local mW = #m[1]

    -- 水平居中
    local col = math.floor((CONFIG.COLS - mW) / 2) + 1
    local row

    if nextFromOpposite then
        -- 重启方块：从对面出现
        if gravityDown then
            row = CONFIG.ROWS - #m + 1 -- 底部
            restartDropDir = -1         -- 向上移动
        else
            row = 1                     -- 顶部
            restartDropDir = 1          -- 向下移动
        end
        isRestartPiece = true
        restartGraceTimer = CONFIG.RESTART_GRACE
        nextFromOpposite = false
    else
        -- 正常生成
        if gravityDown then
            row = 1
        else
            row = CONFIG.ROWS - #m + 1
        end
        isRestartPiece = false
        restartGraceTimer = 0
    end

    if not CanPlace(pType, rot, row, col) then
        gameState = "gameover"
        if score > highScore then highScore = score end
        SetControlsVisible(false)
        print("Game Over! Score: " .. score)
        return
    end

    current = { type = pType, rot = rot, row = row, col = col }
    dropTimer = 0
    isLocking = false
    lockTimer = 0
end

--- 移动方块
function MovePiece(dc)
    if not current then return false end
    if CanPlace(current.type, current.rot, current.row, current.col + dc) then
        current.col = current.col + dc
        if isLocking then lockTimer = 0 end
        return true
    end
    return false
end

--- 旋转方块（顺时针）
function RotatePiece()
    if not current then return false end
    local newRot = (current.rot % 4) + 1

    -- 直接旋转
    if CanPlace(current.type, newRot, current.row, current.col) then
        current.rot = newRot
        if isLocking then lockTimer = 0 end
        return true
    end

    -- Wall kick 尝试
    local kicks = { { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 }, { 0, -2 }, { 0, 2 } }
    for _, k in ipairs(kicks) do
        if CanPlace(current.type, newRot, current.row + k[1], current.col + k[2]) then
            current.rot = newRot
            current.row = current.row + k[1]
            current.col = current.col + k[2]
            if isLocking then lockTimer = 0 end
            return true
        end
    end
    return false
end

--- 锁定方块到网格
function LockPiece()
    if not current then return end
    local m = GetMatrix(current.type, current.rot)
    for r = 1, #m do
        for c = 1, #m[r] do
            if m[r][c] == 1 then
                local gr = current.row + r - 1
                local gc = current.col + c - 1
                if gr >= 1 and gr <= CONFIG.ROWS and gc >= 1 and gc <= CONFIG.COLS then
                    grid[gr][gc] = current.type
                end
            end
        end
    end
    current = nil
    isLocking = false
    lockTimer = 0
    isRestartPiece = false
    restartGraceTimer = 0

    CheckAndClearLines()
end

--- 硬降
function HardDrop()
    if not current then return end
    local ghostRow = GetGhostRow()
    if ghostRow then
        local dist = math.abs(ghostRow - current.row)
        score = score + dist * 2
        current.row = ghostRow
        LockPiece()
        UpdateScoreDisplay()
    end
end

--- 翻转重力
function FlipGravity()
    if not current then return end
    gravityDown = not gravityDown
    dropTimer = 0
    isLocking = false
    lockTimer = 0

    -- 更新 UI 指示
    local lbl = uiRoot_ and uiRoot_:FindById("gravityLabel")
    if lbl then lbl:SetText(gravityDown and "GRAVITY ▼" or "GRAVITY ▲") end

    print("Gravity: " .. (gravityDown and "DOWN" or "UP"))
end

-- ============================================================================
-- 消行与重启
-- ============================================================================

function CheckAndClearLines()
    local cleared = {}
    for r = 1, CONFIG.ROWS do
        local full = true
        for c = 1, CONFIG.COLS do
            if grid[r][c] == 0 then full = false; break end
        end
        if full then table.insert(cleared, r) end
    end

    if #cleared > 0 then
        combo = combo + 1
        local pts = ({ 100, 300, 500, 800 })[math.min(#cleared, 4)] or 800
        score = score + pts * level * combo
        linesCleared = linesCleared + #cleared
        level = math.floor(linesCleared / 10) + 1

        -- 加速
        dropInterval = math.max(CONFIG.MIN_DROP_INTERVAL,
            CONFIG.INITIAL_DROP_INTERVAL - CONFIG.SPEED_ACCEL * linesCleared)

        -- 删除满行（降序删以保持索引）
        table.sort(cleared, function(a, b) return a > b end)
        for _, r in ipairs(cleared) do
            table.remove(grid, r)
        end
        -- 补空行
        for _ = 1, #cleared do
            local empty = {}
            for c = 1, CONFIG.COLS do empty[c] = 0 end
            if gravityDown then
                table.insert(grid, 1, empty) -- 顶部补
            else
                table.insert(grid, empty)     -- 底部补
            end
        end

        -- 触发重启：下一个方块从对面出现
        nextFromOpposite = true

        -- 消行动画
        for _, r in ipairs(cleared) do
            table.insert(clearAnimations, { row = r, timer = 0, maxTime = 0.25 })
        end

        UpdateScoreDisplay()
        print(string.format("Clear %d | Combo x%d | Score %d | Lv.%d",
            #cleared, combo, score, level))
    else
        combo = 0
    end

    SpawnPiece()
end

-- ============================================================================
-- 主循环
-- ============================================================================

---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType, eventData)
    local dt = eventData["TimeStep"]:GetFloat()

    -- 消行动画（任何状态都更新）
    local i = 1
    while i <= #clearAnimations do
        clearAnimations[i].timer = clearAnimations[i].timer + dt
        if clearAnimations[i].timer >= clearAnimations[i].maxTime then
            table.remove(clearAnimations, i)
        else
            i = i + 1
        end
    end

    if gameState ~= "playing" or not current then return end

    -- DAS（键盘长按自动重复移动）
    if dasDir ~= 0 then
        dasTimer = dasTimer + dt
        if dasTriggered then
            if dasTimer >= CONFIG.DAS_REPEAT then
                dasTimer = 0
                MovePiece(dasDir)
            end
        else
            if dasTimer >= CONFIG.DAS_DELAY then
                dasTriggered = true
                dasTimer = 0
                MovePiece(dasDir)
            end
        end
    end

    -- 软降
    isSoftDrop = input:GetKeyDown(KEY_DOWN)

    -- 重启方块调整期
    if isRestartPiece and restartGraceTimer > 0 then
        restartGraceTimer = restartGraceTimer - dt
        if restartGraceTimer <= 0 then
            HardDrop()
        end
        return -- 调整期间不自动下落
    end

    -- 下落逻辑
    local step = GetDropStep()
    local curInterval = isSoftDrop and CONFIG.SOFT_DROP_INTERVAL or dropInterval

    if isLocking then
        lockTimer = lockTimer + dt
        if lockTimer >= CONFIG.LOCK_DELAY then
            LockPiece()
            UpdateScoreDisplay()
        end
    else
        dropTimer = dropTimer + dt
        if dropTimer >= curInterval then
            dropTimer = 0
            local nextRow = current.row + step
            if CanPlace(current.type, current.rot, nextRow, current.col) then
                current.row = nextRow
                if isSoftDrop then score = score + 1 end
            else
                isLocking = true
                lockTimer = 0
            end
        end
    end
end

-- ============================================================================
-- 输入处理
-- ============================================================================

---@param eventType string
---@param eventData KeyDownEventData
function HandleKeyDown(eventType, eventData)
    local key = eventData["Key"]:GetInt()

    if gameState == "menu" or gameState == "gameover" then
        if key == KEY_SPACE or key == KEY_RETURN then StartGame() end
        return
    end

    -- Playing
    if key == KEY_LEFT then
        MovePiece(-1)
        dasDir = -1; dasTimer = 0; dasTriggered = false
    elseif key == KEY_RIGHT then
        MovePiece(1)
        dasDir = 1; dasTimer = 0; dasTriggered = false
    elseif key == KEY_UP or key == KEY_X then
        RotatePiece()
    elseif key == KEY_SPACE or key == KEY_Z then
        FlipGravity()
    elseif key == KEY_C then
        HardDrop()
        UpdateScoreDisplay()
    end
end

---@param eventType string
---@param eventData KeyUpEventData
function HandleKeyUp(eventType, eventData)
    local key = eventData["Key"]:GetInt()
    if key == KEY_LEFT and dasDir == -1 then dasDir = 0 end
    if key == KEY_RIGHT and dasDir == 1 then dasDir = 0 end
end

--- 屏幕点击（菜单/结算画面切换）
function HandleScreenTap()
    if gameState == "menu" or gameState == "gameover" then
        StartGame()
    end
end

---@param eventType string
---@param eventData MouseButtonDownEventData
function HandleMouseClick(eventType, eventData)
    if eventData["Button"]:GetInt() == MOUSEB_LEFT then HandleScreenTap() end
end

---@param eventType string
---@param eventData TouchBeginEventData
function HandleTouchBegin(eventType, eventData)
    HandleScreenTap()
end

-- ============================================================================
-- 游戏流程
-- ============================================================================

function StartGame()
    InitGrid()
    score = 0
    linesCleared = 0
    level = 1
    combo = 0
    dropTimer = 0
    dropInterval = CONFIG.INITIAL_DROP_INTERVAL
    gravityDown = true
    current = nil
    nextFromOpposite = false
    isRestartPiece = false
    restartGraceTimer = 0
    isLocking = false
    lockTimer = 0
    dasDir = 0; dasTimer = 0; dasTriggered = false
    isSoftDrop = false
    clearAnimations = {}

    gameState = "playing"
    SetControlsVisible(true)
    SpawnPiece()
    UpdateScoreDisplay()

    local lbl = uiRoot_ and uiRoot_:FindById("gravityLabel")
    if lbl then lbl:SetText("GRAVITY ▼") end

    print("=== New Game! ===")
end

function UpdateScoreDisplay()
    local s = uiRoot_ and uiRoot_:FindById("scoreLabel")
    if s then s:SetText(tostring(score)) end
    local l = uiRoot_ and uiRoot_:FindById("levelLabel")
    if l then l:SetText("Lv." .. level) end
end

function SetControlsVisible(visible)
    local ctrl = uiRoot_ and uiRoot_:FindById("controls")
    if ctrl then ctrl:SetVisible(visible) end
end

-- ============================================================================
-- UI
-- ============================================================================

function CreateUI()
    uiRoot_ = UI.Panel {
        id = "root",
        width = "100%", height = "100%",
        pointerEvents = "box-none",
        children = {
            -- HUD 顶栏
            UI.Panel {
                id = "hud",
                position = "absolute",
                top = 0, left = 0, right = 0, height = 44,
                flexDirection = "row",
                justifyContent = "space-between",
                alignItems = "center",
                paddingLeft = 16, paddingRight = 16,
                pointerEvents = "none",
                children = {
                    UI.Label {
                        id = "titleLabel",
                        text = "RE:Flip",
                        fontSize = 18,
                        fontColor = { 180, 100, 255, 255 },
                    },
                    UI.Panel {
                        flexDirection = "row", gap = 12,
                        children = {
                            UI.Label {
                                id = "levelLabel",
                                text = "Lv.1",
                                fontSize = 13,
                                fontColor = { 255, 200, 60, 220 },
                            },
                            UI.Label {
                                id = "scoreLabel",
                                text = "0",
                                fontSize = 20,
                                fontColor = { 255, 255, 255, 255 },
                            },
                        },
                    },
                },
            },

            -- 重力方向提示
            UI.Label {
                id = "gravityLabel",
                text = "GRAVITY ▼",
                fontSize = 11,
                fontColor = { 255, 200, 60, 160 },
                position = "absolute",
                top = 40, left = 0, right = 0,
                textAlign = "center",
                pointerEvents = "none",
            },

            -- 虚拟按键
            CreateControlButtons(),
        },
    }

    UI.SetRoot(uiRoot_)
    -- 初始隐藏控件（菜单状态）
    SetControlsVisible(false)
end

function CreateControlButtons()
    local sz = 54
    local fs = 20
    local bg = { 35, 40, 65, 220 }
    local fg = { 210, 215, 240, 255 }

    return UI.Panel {
        id = "controls",
        position = "absolute",
        bottom = 0, left = 0, right = 0,
        height = 88,
        flexDirection = "row",
        justifyContent = "space-evenly",
        alignItems = "center",
        paddingBottom = 16,
        children = {
            -- 左移
            UI.Button {
                text = "◀", width = sz, height = sz,
                fontSize = fs,
                backgroundColor = bg, fontColor = fg, borderRadius = 12,
                onClick = function()
                    if gameState == "playing" then MovePiece(-1) end
                end,
            },
            -- 右移
            UI.Button {
                text = "▶", width = sz, height = sz,
                fontSize = fs,
                backgroundColor = bg, fontColor = fg, borderRadius = 12,
                onClick = function()
                    if gameState == "playing" then MovePiece(1) end
                end,
            },
            -- 旋转
            UI.Button {
                text = "↻", width = sz, height = sz,
                fontSize = fs + 4,
                backgroundColor = bg, fontColor = fg, borderRadius = 12,
                onClick = function()
                    if gameState == "playing" then RotatePiece() end
                end,
            },
            -- 翻转重力
            UI.Button {
                text = "⟳", width = sz + 8, height = sz,
                fontSize = fs + 4,
                backgroundColor = { 70, 35, 110, 220 },
                fontColor = { 255, 200, 60, 255 },
                borderRadius = 12,
                onClick = function()
                    if gameState == "playing" then FlipGravity() end
                end,
            },
            -- 硬降
            UI.Button {
                text = "⤓", width = sz, height = sz,
                fontSize = fs,
                backgroundColor = { 60, 25, 25, 220 },
                fontColor = { 255, 110, 110, 255 },
                borderRadius = 12,
                onClick = function()
                    if gameState == "playing" then
                        HardDrop()
                        UpdateScoreDisplay()
                    end
                end,
            },
        },
    }
end

-- ============================================================================
-- NanoVG 渲染
-- ============================================================================

function HandleNanoVGRender(eventType, eventData)
    local vg = UI.GetNanoVGContext()
    if not vg then return end

    nvgSave(vg)

    if gameState == "playing" or gameState == "gameover" then
        DrawGrid(vg)
        DrawPlacedBlocks(vg)
        if current then
            DrawGhostPiece(vg)
            DrawCurrentPiece(vg)
        end
        DrawClearEffects(vg)
        DrawGravityArrow(vg)
    end

    if gameState == "menu" then
        DrawMenuScreen(vg)
    elseif gameState == "gameover" then
        DrawGameOverScreen(vg)
    end

    nvgRestore(vg)
end

-- ------ 棋盘 ------

function DrawGrid(vg)
    local x, y = layout.gridX, layout.gridY
    local w, h = layout.gridW, layout.gridH
    local cs = layout.cellSize
    local gl = CONFIG.GRID_LINE_RGBA
    local gb = CONFIG.GRID_BORDER_RGBA

    -- 背景
    nvgBeginPath(vg)
    nvgRoundedRect(vg, x - 1, y - 1, w + 2, h + 2, 4)
    nvgFillColor(vg, nvgRGBA(16, 18, 30, 245))
    nvgFill(vg)

    -- 网格线
    nvgStrokeWidth(vg, 0.5)
    nvgStrokeColor(vg, nvgRGBA(gl[1], gl[2], gl[3], gl[4]))
    for r = 1, CONFIG.ROWS - 1 do
        nvgBeginPath(vg)
        nvgMoveTo(vg, x, y + r * cs)
        nvgLineTo(vg, x + w, y + r * cs)
        nvgStroke(vg)
    end
    for c = 1, CONFIG.COLS - 1 do
        nvgBeginPath(vg)
        nvgMoveTo(vg, x + c * cs, y)
        nvgLineTo(vg, x + c * cs, y + h)
        nvgStroke(vg)
    end

    -- 边框
    nvgBeginPath(vg)
    nvgRoundedRect(vg, x - 1, y - 1, w + 2, h + 2, 4)
    nvgStrokeWidth(vg, 1.5)
    nvgStrokeColor(vg, nvgRGBA(gb[1], gb[2], gb[3], gb[4]))
    nvgStroke(vg)
end

-- ------ 已放置方块 ------

function DrawPlacedBlocks(vg)
    local cs = layout.cellSize
    local pad = 1
    for r = 1, CONFIG.ROWS do
        for c = 1, CONFIG.COLS do
            local ci = grid[r][c]
            if ci > 0 then
                DrawSingleCell(vg, r, c, CONFIG.PIECE_COLORS[ci], 255, false)
            end
        end
    end
end

-- ------ 当前方块 ------

function DrawCurrentPiece(vg)
    if not current then return end
    local m = GetMatrix(current.type, current.rot)
    local color = CONFIG.PIECE_COLORS[current.type]

    for r = 1, #m do
        for c = 1, #m[r] do
            if m[r][c] == 1 then
                local gr = current.row + r - 1
                local gc = current.col + c - 1
                DrawSingleCell(vg, gr, gc, color, 255, true)
            end
        end
    end

    -- 重启方块调整期提示
    if isRestartPiece and restartGraceTimer > 0 then
        nvgFontFace(vg, "sans")
        nvgFontSize(vg, 12)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
        nvgFillColor(vg, nvgRGBA(255, 200, 60, 220))
        local cx = layout.gridX + layout.gridW / 2
        local cy = layout.gridY - 6
        nvgText(vg, cx, cy, string.format("RESTART! %.1fs", restartGraceTimer), nil)
    end
end

-- ------ Ghost 方块 ------

function DrawGhostPiece(vg)
    if not current then return end
    local ghostRow = GetGhostRow()
    if not ghostRow or ghostRow == current.row then return end

    local m = GetMatrix(current.type, current.rot)
    local color = CONFIG.PIECE_COLORS[current.type]
    local cs = layout.cellSize
    local pad = 1

    for r = 1, #m do
        for c = 1, #m[r] do
            if m[r][c] == 1 then
                local gr = ghostRow + r - 1
                local gc = current.col + c - 1
                local bx = layout.gridX + (gc - 1) * cs + pad
                local by = layout.gridY + (gr - 1) * cs + pad
                local bs = cs - pad * 2

                nvgBeginPath(vg)
                nvgRoundedRect(vg, bx, by, bs, bs, 2)
                nvgStrokeWidth(vg, 1)
                nvgStrokeColor(vg, nvgRGBA(color[1], color[2], color[3], CONFIG.GHOST_ALPHA))
                nvgStroke(vg)
            end
        end
    end
end

-- ------ 辅助：绘制一个格子 ------

function DrawSingleCell(vg, gr, gc, color, alpha, glow)
    local cs = layout.cellSize
    local pad = 1
    local bx = layout.gridX + (gc - 1) * cs + pad
    local by = layout.gridY + (gr - 1) * cs + pad
    local bs = cs - pad * 2

    if glow then
        nvgBeginPath(vg)
        nvgRoundedRect(vg, bx - 2, by - 2, bs + 4, bs + 4, 4)
        nvgFillColor(vg, nvgRGBA(color[1], color[2], color[3], 45))
        nvgFill(vg)
    end

    nvgBeginPath(vg)
    nvgRoundedRect(vg, bx, by, bs, bs, 2)
    nvgFillColor(vg, nvgRGBA(color[1], color[2], color[3], alpha))
    nvgFill(vg)

    -- 高光
    nvgBeginPath(vg)
    nvgRoundedRect(vg, bx + 1, by + 1, bs - 2, bs * 0.35, 2)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 30))
    nvgFill(vg)
end

-- ------ 消行特效 ------

function DrawClearEffects(vg)
    local cs = layout.cellSize
    for _, a in ipairs(clearAnimations) do
        local p = a.timer / a.maxTime
        local alpha = math.floor(180 * (1 - p))
        nvgBeginPath(vg)
        nvgRect(vg, layout.gridX, layout.gridY + (a.row - 1) * cs,
            layout.gridW, cs)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, alpha))
        nvgFill(vg)
    end
end

-- ------ 重力方向箭头 ------

function DrawGravityArrow(vg)
    local cx = layout.gridX + layout.gridW + 14
    local cy = layout.gridY + layout.gridH / 2
    local len = 18

    nvgStrokeWidth(vg, 2)
    nvgStrokeColor(vg, nvgRGBA(255, 200, 60, 130))
    nvgBeginPath(vg)
    if gravityDown then
        nvgMoveTo(vg, cx, cy - len)
        nvgLineTo(vg, cx, cy + len)
        nvgMoveTo(vg, cx - 5, cy + len - 7)
        nvgLineTo(vg, cx, cy + len)
        nvgLineTo(vg, cx + 5, cy + len - 7)
    else
        nvgMoveTo(vg, cx, cy + len)
        nvgLineTo(vg, cx, cy - len)
        nvgMoveTo(vg, cx - 5, cy - len + 7)
        nvgLineTo(vg, cx, cy - len)
        nvgLineTo(vg, cx + 5, cy - len + 7)
    end
    nvgStroke(vg)
end

-- ============================================================================
-- 菜单 / 结算画面
-- ============================================================================

function DrawMenuScreen(vg)
    local w, h = layout.screenW, layout.screenH

    -- 遮罩
    nvgBeginPath(vg)
    nvgRect(vg, 0, 0, w, h)
    nvgFillColor(vg, nvgRGBA(10, 12, 22, 235))
    nvgFill(vg)

    nvgFontFace(vg, "sans")
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

    -- 标题
    nvgFontSize(vg, 46)
    nvgFillColor(vg, nvgRGBA(180, 100, 255, 255))
    nvgText(vg, w / 2, h * 0.22, "RE:Flip", nil)

    nvgFontSize(vg, 13)
    nvgFillColor(vg, nvgRGBA(255, 200, 60, 200))
    nvgText(vg, w / 2, h * 0.22 + 34, "RESTART FROM THE OTHER SIDE", nil)

    -- 说明
    nvgFontSize(vg, 13)
    nvgFillColor(vg, nvgRGBA(180, 190, 220, 200))
    local lines = {
        "经典俄罗斯方块 + 重力翻转",
        "",
        "◀ ▶  移动       ↻  旋转",
        "⟳  翻转重力     ⤓  硬降",
        "",
        "消除整行 → 新方块从对面重启！",
        "管理好上下两端，坚持到底！",
    }
    for i, line in ipairs(lines) do
        nvgText(vg, w / 2, h * 0.42 + (i - 1) * 22, line, nil)
    end

    -- PC 按键提示
    nvgFontSize(vg, 11)
    nvgFillColor(vg, nvgRGBA(120, 130, 160, 150))
    nvgText(vg, w / 2, h * 0.72, "PC: ← → 移动 | ↑ 旋转 | Space 翻转 | C 硬降", nil)

    -- 闪烁提示
    local t = GetTime():GetElapsedTime()
    local alpha = math.floor(130 + 125 * math.sin(t * 3))
    nvgFontSize(vg, 18)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, alpha))
    nvgText(vg, w / 2, h * 0.82, "点击开始游戏", nil)

    if highScore > 0 then
        nvgFontSize(vg, 13)
        nvgFillColor(vg, nvgRGBA(255, 200, 60, 140))
        nvgText(vg, w / 2, h * 0.88, "Best: " .. highScore, nil)
    end
end

function DrawGameOverScreen(vg)
    local w, h = layout.screenW, layout.screenH

    nvgBeginPath(vg)
    nvgRect(vg, 0, 0, w, h)
    nvgFillColor(vg, nvgRGBA(10, 12, 22, 190))
    nvgFill(vg)

    nvgFontFace(vg, "sans")
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

    nvgFontSize(vg, 36)
    nvgFillColor(vg, nvgRGBA(255, 50, 90, 255))
    nvgText(vg, w / 2, h * 0.25, "GAME OVER", nil)

    nvgFontSize(vg, 24)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 255))
    nvgText(vg, w / 2, h * 0.37, tostring(score), nil)

    nvgFontSize(vg, 13)
    nvgFillColor(vg, nvgRGBA(180, 190, 220, 200))
    nvgText(vg, w / 2, h * 0.37 + 28, "SCORE", nil)

    nvgFontSize(vg, 14)
    nvgFillColor(vg, nvgRGBA(180, 190, 220, 180))
    nvgText(vg, w / 2, h * 0.50,
        "Lines " .. linesCleared .. "  |  Level " .. level, nil)

    if score >= highScore and score > 0 then
        nvgFontSize(vg, 16)
        nvgFillColor(vg, nvgRGBA(255, 200, 60, 255))
        nvgText(vg, w / 2, h * 0.57, "NEW BEST!", nil)
    elseif highScore > 0 then
        nvgFontSize(vg, 13)
        nvgFillColor(vg, nvgRGBA(255, 200, 60, 150))
        nvgText(vg, w / 2, h * 0.57, "Best: " .. highScore, nil)
    end

    local t = GetTime():GetElapsedTime()
    local alpha = math.floor(130 + 125 * math.sin(t * 3))
    nvgFontSize(vg, 16)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, alpha))
    nvgText(vg, w / 2, h * 0.72, "点击重新开始", nil)
end
