-- ============================================================================
-- RE:Flip - 翻转重启
-- 重力翻转俄罗斯方块：点击翻转重力，消行重启到对面
-- 24h Game Jam | Theme: RE (Restart)
-- ============================================================================

local UI = require("urhox-libs/UI")

-- ============================================================================
-- 游戏配置
-- ============================================================================
local CONFIG = {
    Title = "RE:Flip",
    -- 网格尺寸
    COLS = 8,
    ROWS = 16,
    CELL_SIZE = 0,        -- 运行时根据屏幕计算
    -- 游戏节奏
    DROP_INTERVAL = 0.6,  -- 方块下落间隔（秒）
    DROP_SPEED_MIN = 0.15, -- 最快速度
    SPEED_UP_RATE = 0.005, -- 每消一行加速
    -- 重启机制
    RESTART_DELAY = 0.3,  -- 消行后碎片重启延迟
    RESTART_BLOCKS = 3,   -- 消行后重启到对面的方块数量
    -- 颜色方案（霓虹风格）
    COLORS = {
        { 255, 80, 120, 255 },   -- 粉红
        { 80, 200, 255, 255 },   -- 青蓝
        { 255, 200, 60, 255 },   -- 金黄
        { 120, 255, 120, 255 },  -- 翠绿
        { 200, 120, 255, 255 },  -- 紫色
        { 255, 140, 60, 255 },   -- 橘色
    },
    BG_COLOR = { 12, 14, 24, 255 },
    GRID_COLOR = { 40, 45, 65, 80 },
    GRID_BORDER_COLOR = { 60, 70, 100, 180 },
}

-- ============================================================================
-- 游戏状态
-- ============================================================================
local gameState = "menu"   -- menu / playing / gameover

---@type number[][]
local grid = {}            -- grid[row][col] = colorIndex or 0

local currentBlock = nil   -- { col, row, colorIndex, gravityDown }
local gravityDown = true   -- true=从上往下, false=从下往上

local dropTimer = 0
local dropInterval = CONFIG.DROP_INTERVAL

local score = 0
local linesCleared = 0
local highScore = 0
local combo = 0

-- 重启队列: 消行后等待重生的方块
local restartQueue = {}    -- { { col, colorIndex, delay, timer } }

-- 消行动画
local clearAnimations = {} -- { { row, timer, maxTime } }

-- 屏幕布局（运行时计算）
local layout = {
    gridX = 0, gridY = 0,
    gridW = 0, gridH = 0,
    cellSize = 0,
    screenW = 0, screenH = 0,
}

-- UI 引用
local uiRoot_ = nil

-- ============================================================================
-- 生命周期
-- ============================================================================

function Start()
    graphics.windowTitle = CONFIG.Title

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
    SubscribeToEvents()

    print("=== RE:Flip Started ===")
end

function Stop()
    UI.Shutdown()
end

-- ============================================================================
-- 布局计算
-- ============================================================================

function CalculateLayout()
    local dpr = graphics:GetDPR()
    local physW = graphics:GetWidth()
    local physH = graphics:GetHeight()
    layout.screenW = physW / dpr
    layout.screenH = physH / dpr

    -- 根据屏幕高度计算 cell 大小，留出上下 HUD 空间
    local availableH = layout.screenH * 0.75
    local availableW = layout.screenW * 0.9
    local cellByH = math.floor(availableH / CONFIG.ROWS)
    local cellByW = math.floor(availableW / CONFIG.COLS)
    layout.cellSize = math.min(cellByH, cellByW)

    CONFIG.CELL_SIZE = layout.cellSize
    layout.gridW = layout.cellSize * CONFIG.COLS
    layout.gridH = layout.cellSize * CONFIG.ROWS
    layout.gridX = (layout.screenW - layout.gridW) / 2
    layout.gridY = (layout.screenH - layout.gridH) / 2 + 10

    print(string.format("Layout: screen=%dx%d cell=%d grid=%dx%d at (%d,%d)",
        layout.screenW, layout.screenH, layout.cellSize,
        layout.gridW, layout.gridH, layout.gridX, layout.gridY))
end

-- ============================================================================
-- 网格初始化
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
-- UI 创建
-- ============================================================================

function CreateUI()
    uiRoot_ = UI.Panel {
        id = "gameRoot",
        width = "100%",
        height = "100%",
        pointerEvents = "box-none",
        children = {
            -- 顶部 HUD
            UI.Panel {
                id = "topHud",
                position = "absolute",
                top = 8, left = 0, right = 0,
                height = 50,
                flexDirection = "row",
                justifyContent = "space-between",
                alignItems = "center",
                paddingLeft = 16, paddingRight = 16,
                pointerEvents = "none",
                children = {
                    UI.Label {
                        id = "titleLabel",
                        text = "RE:Flip",
                        fontSize = 20,
                        fontColor = { 200, 120, 255, 255 },
                    },
                    UI.Label {
                        id = "scoreLabel",
                        text = "0",
                        fontSize = 22,
                        fontColor = { 255, 255, 255, 255 },
                    },
                },
            },

            -- 重力方向指示器
            UI.Label {
                id = "gravityLabel",
                text = "v",
                fontSize = 28,
                fontColor = { 255, 200, 60, 200 },
                position = "absolute",
                bottom = 16,
                left = 0, right = 0,
                textAlign = "center",
            },
        },
    }

    UI.SetRoot(uiRoot_)
end

-- ============================================================================
-- 事件订阅
-- ============================================================================

function SubscribeToEvents()
    SubscribeToEvent("Update", "HandleUpdate")
    SubscribeToEvent("MouseButtonDown", "HandleClick")
    SubscribeToEvent("TouchBegin", "HandleTouch")
    SubscribeToEvent("KeyDown", "HandleKeyDown")
    SubscribeToEvent("NanoVGRender", "HandleNanoVGRender")
end

-- ============================================================================
-- 游戏逻辑
-- ============================================================================

function SpawnBlock()
    local col = math.random(1, CONFIG.COLS)
    local colorIndex = math.random(1, #CONFIG.COLORS)
    local row
    if gravityDown then
        row = 1
    else
        row = CONFIG.ROWS
    end

    -- 检查生成位置是否已被占据
    if grid[row][col] ~= 0 then
        -- Game Over
        gameState = "gameover"
        if score > highScore then
            highScore = score
        end
        print("Game Over! Score: " .. score)
        return
    end

    currentBlock = {
        col = col,
        row = row,
        colorIndex = colorIndex,
        gravityDown = gravityDown,
    }
end

function LandBlock()
    if not currentBlock then return end

    local r = math.floor(currentBlock.row + 0.5)
    r = math.max(1, math.min(CONFIG.ROWS, r))

    if grid[r][currentBlock.col] ~= 0 then
        -- 回退一格
        if currentBlock.gravityDown then
            r = r - 1
        else
            r = r + 1
        end
    end

    if r < 1 or r > CONFIG.ROWS then
        gameState = "gameover"
        if score > highScore then highScore = score end
        currentBlock = nil
        return
    end

    grid[r][currentBlock.col] = currentBlock.colorIndex
    currentBlock = nil

    -- 检查消行
    CheckLines()

    -- 生成下一个方块
    SpawnBlock()
end

function CheckLines()
    local cleared = {}

    for r = 1, CONFIG.ROWS do
        local full = true
        for c = 1, CONFIG.COLS do
            if grid[r][c] == 0 then
                full = false
                break
            end
        end
        if full then
            table.insert(cleared, r)
        end
    end

    if #cleared > 0 then
        combo = combo + 1
        local points = #cleared * 100 * combo
        score = score + points
        linesCleared = linesCleared + #cleared

        -- 加速
        dropInterval = math.max(CONFIG.DROP_SPEED_MIN,
            dropInterval - CONFIG.SPEED_UP_RATE * #cleared)

        -- 收集被消行的方块颜色，准备重启到对面
        for _, r in ipairs(cleared) do
            for c = 1, CONFIG.COLS do
                local colorIdx = grid[r][c]
                if colorIdx > 0 then
                    -- 随机选几个重启到对面
                    if math.random() < (CONFIG.RESTART_BLOCKS / CONFIG.COLS) then
                        table.insert(restartQueue, {
                            col = c,
                            colorIndex = colorIdx,
                            delay = CONFIG.RESTART_DELAY + math.random() * 0.5,
                            timer = 0,
                            -- 从对面来：如果此行在上半部就重启到下面，反之亦然
                            fromTop = (r > CONFIG.ROWS / 2),
                        })
                    end
                end
            end
            -- 添加消除动画
            table.insert(clearAnimations, {
                row = r,
                timer = 0,
                maxTime = 0.3,
            })
        end

        -- 消除行（从下往上删以保持索引稳定）
        table.sort(cleared, function(a, b) return a > b end)
        for _, r in ipairs(cleared) do
            table.remove(grid, r)
        end
        -- 补空行
        for _ = 1, #cleared do
            -- 判断空行加在哪一端
            -- 上半消除 → 顶部补空行；下半消除 → 底部补空行
            local emptyRow = {}
            for c = 1, CONFIG.COLS do
                emptyRow[c] = 0
            end
            -- 简化: 消掉的行从上半来就在顶部补，否则底部补
            -- 由于 cleared 已排序(降序)，我们用第一个(最大行号)判断
            if cleared[1] > CONFIG.ROWS / 2 then
                table.insert(grid, emptyRow)  -- 底部补
            else
                table.insert(grid, 1, emptyRow) -- 顶部补
            end
        end

        -- 更新分数显示
        UpdateScoreDisplay()
        print(string.format("Cleared %d lines! Combo: x%d Score: %d Speed: %.2f",
            #cleared, combo, score, dropInterval))
    else
        combo = 0
    end
end

function UpdateRestartQueue(dt)
    local i = 1
    while i <= #restartQueue do
        local item = restartQueue[i]
        item.timer = item.timer + dt
        if item.timer >= item.delay then
            -- 重启方块到对面
            local targetRow
            if item.fromTop then
                -- 重启到顶部
                targetRow = 1
            else
                -- 重启到底部
                targetRow = CONFIG.ROWS
            end

            -- 从目标端开始找空位
            if item.fromTop then
                for r = 1, CONFIG.ROWS do
                    if grid[r][item.col] == 0 then
                        grid[r][item.col] = item.colorIndex
                        break
                    end
                end
            else
                for r = CONFIG.ROWS, 1, -1 do
                    if grid[r][item.col] == 0 then
                        grid[r][item.col] = item.colorIndex
                        break
                    end
                end
            end

            table.remove(restartQueue, i)
        else
            i = i + 1
        end
    end
end

function UpdateClearAnimations(dt)
    local i = 1
    while i <= #clearAnimations do
        clearAnimations[i].timer = clearAnimations[i].timer + dt
        if clearAnimations[i].timer >= clearAnimations[i].maxTime then
            table.remove(clearAnimations, i)
        else
            i = i + 1
        end
    end
end

function FlipGravity()
    gravityDown = not gravityDown

    -- 翻转当前方块的方向
    if currentBlock then
        currentBlock.gravityDown = gravityDown
    end

    -- 更新重力指示器
    local label = uiRoot_:FindById("gravityLabel")
    if label then
        if gravityDown then
            label:SetText("v")
        else
            label:SetText("^")
        end
    end
end

function ResetGame()
    InitGrid()
    score = 0
    linesCleared = 0
    combo = 0
    dropTimer = 0
    dropInterval = CONFIG.DROP_INTERVAL
    gravityDown = true
    currentBlock = nil
    restartQueue = {}
    clearAnimations = {}
    gameState = "playing"
    UpdateScoreDisplay()
    SpawnBlock()

    local label = uiRoot_:FindById("gravityLabel")
    if label then label:SetText("v") end
end

function UpdateScoreDisplay()
    local label = uiRoot_:FindById("scoreLabel")
    if label then
        label:SetText(tostring(score))
    end
end

-- ============================================================================
-- 事件处理
-- ============================================================================

---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType, eventData)
    local dt = eventData["TimeStep"]:GetFloat()

    if gameState == "playing" then
        -- 更新方块下落
        dropTimer = dropTimer + dt
        if dropTimer >= dropInterval then
            dropTimer = 0
            if currentBlock then
                -- 移动方块
                if currentBlock.gravityDown then
                    currentBlock.row = currentBlock.row + 1
                else
                    currentBlock.row = currentBlock.row - 1
                end

                -- 碰撞检测
                local nextRow = math.floor(currentBlock.row + 0.5)
                if currentBlock.gravityDown then
                    if nextRow > CONFIG.ROWS then
                        currentBlock.row = CONFIG.ROWS
                        LandBlock()
                    elseif grid[nextRow][currentBlock.col] ~= 0 then
                        currentBlock.row = nextRow - 1
                        LandBlock()
                    end
                else
                    if nextRow < 1 then
                        currentBlock.row = 1
                        LandBlock()
                    elseif grid[nextRow][currentBlock.col] ~= 0 then
                        currentBlock.row = nextRow + 1
                        LandBlock()
                    end
                end
            end
        end

        -- 更新重启队列
        UpdateRestartQueue(dt)

        -- 更新消除动画
        UpdateClearAnimations(dt)
    end
end

---@param eventType string
---@param eventData MouseButtonDownEventData
function HandleClick(eventType, eventData)
    local button = eventData["Button"]:GetInt()
    if button ~= MOUSEB_LEFT then return end

    if gameState == "menu" then
        ResetGame()
    elseif gameState == "playing" then
        FlipGravity()
    elseif gameState == "gameover" then
        ResetGame()
    end
end

---@param eventType string
---@param eventData TouchBeginEventData
function HandleTouch(eventType, eventData)
    if gameState == "menu" then
        ResetGame()
    elseif gameState == "playing" then
        FlipGravity()
    elseif gameState == "gameover" then
        ResetGame()
    end
end

---@param eventType string
---@param eventData KeyDownEventData
function HandleKeyDown(eventType, eventData)
    local key = eventData["Key"]:GetInt()

    if key == KEY_SPACE then
        if gameState == "menu" then
            ResetGame()
        elseif gameState == "playing" then
            FlipGravity()
        elseif gameState == "gameover" then
            ResetGame()
        end
    elseif key == KEY_ESCAPE then
        if gameState == "playing" then
            gameState = "menu"
        end
    end
end

-- ============================================================================
-- NanoVG 渲染（游戏画面）
-- ============================================================================

function HandleNanoVGRender(eventType, eventData)
    local vg = UI.GetNanoVGContext()
    if not vg then return end

    local dpr = graphics:GetDPR()
    local physW = graphics:GetWidth()
    local physH = graphics:GetHeight()
    local w = physW / dpr
    local h = physH / dpr

    -- 绘制游戏棋盘（在 UI 下层）
    nvgSave(vg)

    if gameState == "playing" or gameState == "gameover" then
        DrawGrid(vg)
        DrawBlocks(vg)
        DrawCurrentBlock(vg)
        DrawClearAnimations(vg)
        DrawGravityIndicator(vg, w, h)
    end

    if gameState == "menu" then
        DrawMenuScreen(vg, w, h)
    elseif gameState == "gameover" then
        DrawGameOverScreen(vg, w, h)
    end

    nvgRestore(vg)
end

function DrawGrid(vg)
    local x, y = layout.gridX, layout.gridY
    local w, h = layout.gridW, layout.gridH
    local cs = layout.cellSize

    -- 棋盘背景
    nvgBeginPath(vg)
    nvgRoundedRect(vg, x - 2, y - 2, w + 4, h + 4, 4)
    nvgFillColor(vg, nvgRGBA(20, 22, 35, 240))
    nvgFill(vg)

    -- 网格线
    nvgStrokeWidth(vg, 0.5)
    nvgStrokeColor(vg, nvgRGBA(table.unpack(CONFIG.GRID_COLOR)))

    for r = 0, CONFIG.ROWS do
        nvgBeginPath(vg)
        nvgMoveTo(vg, x, y + r * cs)
        nvgLineTo(vg, x + w, y + r * cs)
        nvgStroke(vg)
    end
    for c = 0, CONFIG.COLS do
        nvgBeginPath(vg)
        nvgMoveTo(vg, x + c * cs, y)
        nvgLineTo(vg, x + c * cs, y + h)
        nvgStroke(vg)
    end

    -- 中线（两摞的分界线）
    nvgBeginPath(vg)
    nvgMoveTo(vg, x, y + h / 2)
    nvgLineTo(vg, x + w, y + h / 2)
    nvgStrokeWidth(vg, 1.5)
    nvgStrokeColor(vg, nvgRGBA(255, 200, 60, 60))
    nvgStroke(vg)

    -- 边框
    nvgBeginPath(vg)
    nvgRoundedRect(vg, x - 2, y - 2, w + 4, h + 4, 4)
    nvgStrokeWidth(vg, 1.5)
    nvgStrokeColor(vg, nvgRGBA(table.unpack(CONFIG.GRID_BORDER_COLOR)))
    nvgStroke(vg)
end

function DrawBlocks(vg)
    local cs = layout.cellSize
    local padding = 1.5

    for r = 1, CONFIG.ROWS do
        for c = 1, CONFIG.COLS do
            local colorIdx = grid[r][c]
            if colorIdx > 0 then
                local color = CONFIG.COLORS[colorIdx]
                local bx = layout.gridX + (c - 1) * cs + padding
                local by = layout.gridY + (r - 1) * cs + padding
                local bs = cs - padding * 2

                -- 方块主体
                nvgBeginPath(vg)
                nvgRoundedRect(vg, bx, by, bs, bs, 3)
                nvgFillColor(vg, nvgRGBA(color[1], color[2], color[3], color[4]))
                nvgFill(vg)

                -- 高光（左上）
                nvgBeginPath(vg)
                nvgRoundedRect(vg, bx, by, bs, bs / 2, 3)
                nvgFillColor(vg, nvgRGBA(255, 255, 255, 35))
                nvgFill(vg)
            end
        end
    end
end

function DrawCurrentBlock(vg)
    if not currentBlock then return end

    local cs = layout.cellSize
    local padding = 1.5
    local color = CONFIG.COLORS[currentBlock.colorIndex]
    local bx = layout.gridX + (currentBlock.col - 1) * cs + padding
    local by = layout.gridY + (currentBlock.row - 1) * cs + padding
    local bs = cs - padding * 2

    -- 发光效果
    nvgBeginPath(vg)
    nvgRoundedRect(vg, bx - 3, by - 3, bs + 6, bs + 6, 5)
    nvgFillColor(vg, nvgRGBA(color[1], color[2], color[3], 60))
    nvgFill(vg)

    -- 方块主体
    nvgBeginPath(vg)
    nvgRoundedRect(vg, bx, by, bs, bs, 3)
    nvgFillColor(vg, nvgRGBA(color[1], color[2], color[3], 255))
    nvgFill(vg)

    -- 高光
    nvgBeginPath(vg)
    nvgRoundedRect(vg, bx + 1, by + 1, bs - 2, bs / 2 - 1, 2)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 80))
    nvgFill(vg)
end

function DrawClearAnimations(vg)
    local cs = layout.cellSize

    for _, anim in ipairs(clearAnimations) do
        local progress = anim.timer / anim.maxTime
        local alpha = math.floor(255 * (1 - progress))
        local expand = progress * 10

        nvgBeginPath(vg)
        nvgRect(vg,
            layout.gridX - expand,
            layout.gridY + (anim.row - 1) * cs - expand / 2,
            layout.gridW + expand * 2,
            cs + expand)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, alpha))
        nvgFill(vg)
    end
end

function DrawGravityIndicator(vg, w, h)
    -- 在棋盘两侧画箭头指示重力方向
    local cx = layout.gridX + layout.gridW + 20
    local cy = layout.gridY + layout.gridH / 2
    local arrowLen = 30

    nvgStrokeWidth(vg, 2)
    nvgStrokeColor(vg, nvgRGBA(255, 200, 60, 180))

    nvgBeginPath(vg)
    if gravityDown then
        nvgMoveTo(vg, cx, cy - arrowLen)
        nvgLineTo(vg, cx, cy + arrowLen)
        -- 箭头
        nvgMoveTo(vg, cx - 6, cy + arrowLen - 10)
        nvgLineTo(vg, cx, cy + arrowLen)
        nvgLineTo(vg, cx + 6, cy + arrowLen - 10)
    else
        nvgMoveTo(vg, cx, cy + arrowLen)
        nvgLineTo(vg, cx, cy - arrowLen)
        -- 箭头
        nvgMoveTo(vg, cx - 6, cy - arrowLen + 10)
        nvgLineTo(vg, cx, cy - arrowLen)
        nvgLineTo(vg, cx + 6, cy - arrowLen + 10)
    end
    nvgStroke(vg)
end

function DrawMenuScreen(vg, w, h)
    -- 半透明遮罩
    nvgBeginPath(vg)
    nvgRect(vg, 0, 0, w, h)
    nvgFillColor(vg, nvgRGBA(12, 14, 24, 220))
    nvgFill(vg)

    -- 标题
    nvgFontFace(vg, "sans")
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

    -- "RE:Flip" 大标题
    nvgFontSize(vg, 52)
    nvgFillColor(vg, nvgRGBA(200, 120, 255, 255))
    nvgText(vg, w / 2, h * 0.3, "RE:Flip", nil)

    -- 副标题
    nvgFontSize(vg, 16)
    nvgFillColor(vg, nvgRGBA(255, 200, 60, 200))
    nvgText(vg, w / 2, h * 0.3 + 40, "RESTART FROM THE OTHER SIDE", nil)

    -- 玩法说明
    nvgFontSize(vg, 14)
    nvgFillColor(vg, nvgRGBA(180, 190, 220, 200))
    nvgText(vg, w / 2, h * 0.52, "方块自动下落", nil)
    nvgText(vg, w / 2, h * 0.52 + 24, "点击屏幕 = 翻转重力", nil)
    nvgText(vg, w / 2, h * 0.52 + 48, "填满一行 = 消除", nil)
    nvgText(vg, w / 2, h * 0.52 + 72, "消除的方块会重启到对面", nil)

    -- 开始提示
    local time = GetTime():GetElapsedTime()
    local alpha = math.floor(150 + 105 * math.sin(time * 3))
    nvgFontSize(vg, 20)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, alpha))
    nvgText(vg, w / 2, h * 0.78, "点击开始", nil)

    -- 最高分
    if highScore > 0 then
        nvgFontSize(vg, 14)
        nvgFillColor(vg, nvgRGBA(255, 200, 60, 160))
        nvgText(vg, w / 2, h * 0.85, "Best: " .. highScore, nil)
    end
end

function DrawGameOverScreen(vg, w, h)
    -- 半透明遮罩
    nvgBeginPath(vg)
    nvgRect(vg, 0, 0, w, h)
    nvgFillColor(vg, nvgRGBA(12, 14, 24, 180))
    nvgFill(vg)

    nvgFontFace(vg, "sans")
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

    -- Game Over
    nvgFontSize(vg, 40)
    nvgFillColor(vg, nvgRGBA(255, 80, 120, 255))
    nvgText(vg, w / 2, h * 0.3, "GAME OVER", nil)

    -- 分数
    nvgFontSize(vg, 28)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 255))
    nvgText(vg, w / 2, h * 0.42, "Score: " .. score, nil)

    -- 消行数
    nvgFontSize(vg, 16)
    nvgFillColor(vg, nvgRGBA(180, 190, 220, 200))
    nvgText(vg, w / 2, h * 0.50, "Lines: " .. linesCleared, nil)

    -- 最高分
    if score >= highScore then
        nvgFontSize(vg, 18)
        nvgFillColor(vg, nvgRGBA(255, 200, 60, 255))
        nvgText(vg, w / 2, h * 0.58, "NEW BEST!", nil)
    else
        nvgFontSize(vg, 16)
        nvgFillColor(vg, nvgRGBA(255, 200, 60, 160))
        nvgText(vg, w / 2, h * 0.58, "Best: " .. highScore, nil)
    end

    -- 重新开始
    local time = GetTime():GetElapsedTime()
    local alpha = math.floor(150 + 105 * math.sin(time * 3))
    nvgFontSize(vg, 18)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, alpha))
    nvgText(vg, w / 2, h * 0.72, "点击重新开始", nil)
end
