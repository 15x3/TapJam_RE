-- ============================================================================
-- RE:Flip - 分裂棋盘俄罗斯方块
-- M-001: 骨架（棋盘渲染 + 出生 + 翻转 + 移动/旋转 + 碰撞锁定 + 虚拟按键）
-- M-002: 核心玩法（消行 + 传送 + Game Over + 分数）
-- ============================================================================

local UI = require("urhox-libs/UI")
local ImageCache = require("urhox-libs/UI/Core/ImageCache")
local Filters = require("filters")
local Anim = require("anim")

-- 日志
local LOG = true
local function log(...)
    if LOG then print("[RE:Flip]", ...) end
end

-- ============================================================================
-- 持久化存档（累计分数 & 滤镜解锁）
-- ============================================================================
---@diagnostic disable-next-line: undefined-global
local cjson = cjson
local UNLOCK_COST = 500        -- 每解锁一个滤镜需要的累计分数
local totalScore_ = 0          -- 历史累计总分

local function loadProgress()
    if not fileSystem:FileExists("progress.json") then return end
    local file = File("progress.json", FILE_READ)
    if not file:IsOpen() then return end
    local ok, data = pcall(cjson.decode, file:ReadString())
    file:Close()
    if ok and data then
        totalScore_ = data.totalScore or 0
        local unlocked = math.floor(totalScore_ / UNLOCK_COST) + 1  -- +1 for Original
        Filters.setUnlocked(unlocked)
        log(string.format("Progress loaded: totalScore=%d unlocked=%d/%d",
            totalScore_, Filters.getUnlocked(), Filters.getTotal()))
    end
end

local function saveProgress()
    local file = File("progress.json", FILE_WRITE)
    if not file:IsOpen() then return end
    file:WriteString(cjson.encode({ totalScore = totalScore_ }))
    file:Close()
    log("Progress saved: totalScore=" .. totalScore_)
end

--- Game Over 时调用：累加本局分数，检查新解锁
local function commitScore(roundScore)
    if roundScore <= 0 then return end
    local oldUnlocked = Filters.getUnlocked()
    totalScore_ = totalScore_ + roundScore
    local newUnlocked = math.floor(totalScore_ / UNLOCK_COST) + 1
    Filters.setUnlocked(newUnlocked)
    saveProgress()
    if Filters.getUnlocked() > oldUnlocked then
        log(string.format("NEW FILTER UNLOCKED! Now %d/%d",
            Filters.getUnlocked(), Filters.getTotal()))
    end
end

-- ============================================================================
-- 常量
-- ============================================================================
local COLS       = 10
local ROWS       = 24
local HALF_ROWS  = 12          -- 上半区 1-12, 下半区 13-24

local CELL_SIZE  = 18          -- 基准像素，每格大小（Start() 中动态计算）
local BOARD_W    = COLS * CELL_SIZE
local BOARD_H    = ROWS * CELL_SIZE

-- 下落间隔（秒）
local DROP_INTERVAL = 0.8

-- 方向枚举
local DIR_UP   = -1   -- 向天花板堆积
local DIR_DOWN =  1   -- 向地板堆积

-- 颜色表（RGBA）: I O T S Z L J
local COLORS = {
    [1] = { 0, 240, 240, 255 },   -- I  cyan
    [2] = { 240, 240, 0, 255 },   -- O  yellow
    [3] = { 160, 0, 240, 255 },   -- T  purple
    [4] = { 0, 240, 0, 255 },     -- S  green
    [5] = { 240, 0, 0, 255 },     -- Z  red
    [6] = { 240, 160, 0, 255 },   -- L  orange
    [7] = { 0, 0, 240, 255 },     -- J  blue
}

-- ============================================================================
-- SRS 方块定义 (4 旋转态)
-- 坐标 {col_offset, row_offset}，row_offset 正 = 向下(朝地板)
-- ============================================================================

local TETROMINOES = {
    -- I
    {
        { {-1,0}, {0,0}, {1,0}, {2,0} },
        { {0,-1}, {0,0}, {0,1}, {0,2} },
        { {-1,0}, {0,0}, {1,0}, {2,0} },
        { {0,-1}, {0,0}, {0,1}, {0,2} },
    },
    -- O
    {
        { {0,0}, {1,0}, {0,1}, {1,1} },
        { {0,0}, {1,0}, {0,1}, {1,1} },
        { {0,0}, {1,0}, {0,1}, {1,1} },
        { {0,0}, {1,0}, {0,1}, {1,1} },
    },
    -- T
    {
        { {-1,0}, {0,0}, {1,0}, {0,-1} },
        { {0,-1}, {0,0}, {0,1}, {1,0} },
        { {-1,0}, {0,0}, {1,0}, {0,1} },
        { {0,-1}, {0,0}, {0,1}, {-1,0} },
    },
    -- S
    {
        { {-1,0}, {0,0}, {0,-1}, {1,-1} },
        { {0,-1}, {0,0}, {1,0}, {1,1} },
        { {-1,1}, {0,1}, {0,0}, {1,0} },
        { {-1,-1}, {-1,0}, {0,0}, {0,1} },
    },
    -- Z
    {
        { {-1,-1}, {0,-1}, {0,0}, {1,0} },
        { {1,-1}, {1,0}, {0,0}, {0,1} },
        { {-1,0}, {0,0}, {0,1}, {1,1} },
        { {0,-1}, {0,0}, {-1,0}, {-1,1} },
    },
    -- L
    {
        { {-1,0}, {0,0}, {1,0}, {1,-1} },
        { {0,-1}, {0,0}, {0,1}, {1,1} },
        { {-1,1}, {-1,0}, {0,0}, {1,0} },
        { {-1,-1}, {0,-1}, {0,0}, {0,1} },
    },
    -- J
    {
        { {-1,-1}, {-1,0}, {0,0}, {1,0} },
        { {0,-1}, {0,0}, {1,-1}, {0,1} },
        { {-1,0}, {0,0}, {1,0}, {1,1} },
        { {0,-1}, {0,0}, {0,1}, {-1,1} },
    },
}

-- SRS wall kick data (JLSTZ)
local KICK_JLSTZ = {
    { {0,0}, {-1,0}, {-1,-1}, {0,2}, {-1,2} },
    { {0,0}, {1,0}, {1,1}, {0,-2}, {1,-2} },
    { {0,0}, {1,0}, {1,-1}, {0,2}, {1,2} },
    { {0,0}, {-1,0}, {-1,1}, {0,-2}, {-1,-2} },
}
-- SRS wall kick data (I)
local KICK_I = {
    { {0,0}, {-2,0}, {1,0}, {-2,1}, {1,-2} },
    { {0,0}, {-1,0}, {2,0}, {-1,-2}, {2,1} },
    { {0,0}, {2,0}, {-1,0}, {2,-1}, {-1,2} },
    { {0,0}, {1,0}, {-2,0}, {1,2}, {-2,-1} },
}

-- ============================================================================
-- 游戏状态
-- ============================================================================

---@type table<integer, table<integer, integer>>
local board = {}

-- 当前方块
local curType  = 0    -- 1-7
local curRot   = 1    -- 1-4 (Lua索引)
local curCol   = 0    -- 方块中心列 (1-based)
local curRow   = 0    -- 方块中心行 (1-based)
local curDir   = DIR_DOWN  -- 当前方块的方向（出生时锁定）
local dirChosen = true     -- 本方块是否已确认方向（新机制：始终 true）
local nextDir  = DIR_DOWN  -- 下一个方块的方向（翻转按钮控制这个）

-- 强制翻转机制
local FLIP_FORCE_THRESHOLD = 8  -- 平均约 7 块消一行，7+1 = 8 块未翻转则强制
local flipCounter_ = 0          -- 自上次翻转后放置的方块数
local flippedThisPiece_ = false  -- 当前方块下落期间是否已翻转过（每块只允许一次）

-- 计时
local dropTimer = 0

-- 随机袋
local bag = {}
local bagIndex = 0

-- UI 引用
local uiRoot_ = nil
local flipBtnRef_ = nil
local scoreLabelRef_ = nil
local levelLabelRef_ = nil
local comboLabelRef_ = nil
local nextPreviewRef_ = nil  -- 方块预览 widget
local nextDirLabelRef_ = nil   -- 下一方向标签
local flipCountLabelRef_ = nil -- 翻转倒计时标签
-- Game Over 用 NanoVG 绘制，不用 UI 面板

-- 游戏状态
local gameState = "title"  -- "title" | "playing" | "paused" | "gameover"
-- 暂停菜单
local pauseMenuIndex_ = 1   -- 当前选中项 (1=返回游戏, 2=重新开始, 3=切换滤镜)
local PAUSE_ITEMS = { "RESUME", "RETRY", "FILTER" }
local score = 0
local level = 1
local linesCleared = 0      -- 总消行数（用于升级）
local combo = 0              -- 连击数（连续消行）
local comboGrace_ = 0        -- 连击宽限：剩余几个方块内未消除才重置 combo
local COMBO_GRACE_PIECES = 3 -- 连击宽限方块数
local comboFlashTimer_ = 0   -- 连击闪绿计时器（> 0 时背景闪绿）

-- 动画系统
local animState = "none"  -- "none" | "clearing" | "teleporting" | "teleport_control"
local animTimer = 0
local ANIM_CLEAR_DURATION   = 0.35  -- 消行闪烁时长
local ANIM_TELEPORT_DURATION = 0.40  -- 传送飞行时长

-- 消行动画数据
local animClearRows = {}
-- 传送动画数据: { {col, fromRow, toRow, colorIdx}, ... }
local animTeleportBlocks = {}
-- 消行后待执行的压缩和传送逻辑
local animPendingClearData = nil

-- 传送方块控制状态（teleport_control 阶段）
-- teleCtrlBlocks: { {col, row, colorIdx}, ... } 当前可移动的方块群
-- teleCtrlDir: 该方块群的下落方向 (DIR_UP 或 DIR_DOWN)
-- teleCtrlDropTimer: 自动下落计时
local teleCtrlBlocks = {}
local teleCtrlDir = DIR_DOWN
local teleCtrlDropTimer = 0
local TELE_CTRL_DROP_INTERVAL = 0.12  -- 传送方块自动下落很快

-- 防抖：防止手机触摸多次触发
local gameTime_ = 0
local titleTrails_ = nil   -- 标题拖影动画组
local COOLDOWN = 0.18  -- 秒
local lastRotateTime_ = -1
local lastHardDropTime_ = -1

-- 音效
---@type Scene
local audioScene_ = nil
---@type Node
local sfxNode_ = nil
local SFX = {}  -- { move=Sound, rotate=Sound, clear=Sound, flip=Sound, gameover=Sound }
---@type SoundSource
local bgmSource_ = nil

-- 震屏效果
local shakeTimer_ = 0
local shakeDuration_ = 0
local shakeIntensity_ = 0

-- 消行粒子效果
local particles_ = {}  -- { {x, y, vx, vy, life, maxLife, r, g, b}, ... }

-- ============================================================================
-- 引导层系统
-- ============================================================================
local tutorial_ = {
    active = false,     -- 引导是否激活
    step   = 0,         -- 当前步骤 (1-5)
    shown  = false,     -- 是否已经展示过（只展示一次）
    fadeIn = 0,         -- 淡入动画计时器
}
local TUTORIAL_STEPS = {
    {
        title = "操作方式",
        lines = {
            "◀ ▶ 左右移动方块",
            "「转」旋转方块",
            "▼  加速下落",
        },
        hint = "点击继续",
    },
    {
        title = "分裂棋盘",
        lines = {
            "方块从中线出生",
            "自动沿预定方向下落",
            "",
            "上半区：向天花板堆积",
            "下半区：向地板堆积",
        },
        hint = "点击继续",
    },
    {
        title = "翻转预约",
        lines = {
            "按「翻」预约方向",
            "对下一个方块生效！",
            "",
            "当前方块方向已锁定",
            "右侧面板查看预约",
        },
        hint = "点击继续",
    },
    {
        title = "强制翻转",
        lines = {
            "连续" .. FLIP_FORCE_THRESHOLD .. "块未翻转？",
            "系统会强制翻转！",
            "",
            "主动翻转可重置计数",
            "留意右侧倒计时",
        },
        hint = "点击继续",
    },
    {
        title = "消行传送",
        lines = {
            "消除一行后",
            "相邻行会传送到对面！",
            "",
            "连锁消行 = 超高分！",
        },
        hint = "点击开始游戏",
    },
}

--- 触发震屏
local function triggerShake(intensity, duration)
    shakeIntensity_ = intensity
    shakeDuration_ = duration
    shakeTimer_ = 0
end

--- 生成消行粒子（使用格子坐标，渲染时转换为像素）
local function spawnClearParticles(rows)
    for _, row in ipairs(rows) do
        for c = 1, COLS do
            local v = board[row] and board[row][c] or 0
            if v > 0 then
                local clr = COLORS[v]
                -- 格子中心坐标（相对于棋盘左上角，单位=格子）
                local gcx = (c - 1) + 0.5
                local gcy = (row - 1) + 0.5
                for _ = 1, math.random(2, 3) do
                    table.insert(particles_, {
                        gx = gcx + (math.random() - 0.5) * 0.5,
                        gy = gcy + (math.random() - 0.5) * 0.5,
                        vx = (math.random() - 0.5) * 10,  -- 格子/秒
                        vy = -math.random() * 6 - 2,
                        life = 0,
                        maxLife = 0.5 + math.random() * 0.4,
                        r = clr[1], g = clr[2], b = clr[3],
                        size = math.random(2, 4),
                    })
                end
            end
        end
    end
end

--- 播放音效
local function playSfx(key)
    if not sfxNode_ or not SFX[key] then return end
    local src = sfxNode_:CreateComponent("SoundSource")
    src.soundType = "Effect"
    src.gain = 0.6
    src.autoRemoveMode = REMOVE_COMPONENT
    src:Play(SFX[key])
end

-- ============================================================================
-- 棋盘操作
-- ============================================================================

local function initBoard()
    board = {}
    for r = 1, ROWS do
        board[r] = {}
        for c = 1, COLS do
            board[r][c] = 0
        end
    end
    log("Board initialized:", COLS, "x", ROWS)
end

local function isCellFree(row, col)
    if row < 1 or row > ROWS then return false end
    if col < 1 or col > COLS then return false end
    -- 方向确认后，限制方块只能在对应半区内活动
    if dirChosen then
        if curDir == DIR_UP and row > HALF_ROWS then return false end
        if curDir == DIR_DOWN and row < HALF_ROWS + 1 then return false end
    end
    return board[row][col] == 0
end

local function getPieceCells(pType, rot, pCol, pRow)
    local shape = TETROMINOES[pType][rot]
    local cells = {}
    for i = 1, #shape do
        cells[i] = { row = pRow + shape[i][2], col = pCol + shape[i][1] }
    end
    return cells
end

local function isValidPosition(pType, rot, pCol, pRow)
    local cells = getPieceCells(pType, rot, pCol, pRow)
    for i = 1, #cells do
        if not isCellFree(cells[i].row, cells[i].col) then
            return false
        end
    end
    return true
end

local function lockPiece()
    local cells = getPieceCells(curType, curRot, curCol, curRow)
    for i = 1, #cells do
        local r = cells[i].row
        local c = cells[i].col
        if r >= 1 and r <= ROWS and c >= 1 and c <= COLS then
            board[r][c] = curType
        end
    end
    log("Piece locked: type=" .. curType, "at col=" .. curCol, "row=" .. curRow)
end

-- ============================================================================
-- M-002: 消行判定 + 传送 + 分数
-- ============================================================================

--- 检查某行是否满
local function isRowFull(row)
    for c = 1, COLS do
        if board[row][c] == 0 then return false end
    end
    return true
end

--- 创建空行
local function emptyRow()
    local r = {}
    for c = 1, COLS do r[c] = 0 end
    return r
end

--- 复制一行数据
local function copyRow(row)
    local r = {}
    for c = 1, COLS do r[c] = board[row][c] end
    return r
end

--- 检查一行是否为空
local function isRowEmpty(row)
    for c = 1, COLS do
        if board[row][c] ~= 0 then return false end
    end
    return true
end

--- 将一行数据传送到对面半区，每个方块在各自列独立自由落体
--- @param rowData table 行数据（10个cell值）
--- @param targetHalf string "upper" | "lower"
local function teleportRow(rowData, targetHalf)
    local placed = 0
    for c = 1, COLS do
        if rowData[c] ~= 0 then
            if targetHalf == "lower" then
                -- 从 row 16 往 row 30 逐行下落，找到该列最深的空位
                local dest = -1
                for r = HALF_ROWS + 1, ROWS do
                    if board[r][c] == 0 then
                        dest = r
                    else
                        break
                    end
                end
                if dest > 0 then
                    board[dest][c] = rowData[c]
                    placed = placed + 1
                end
            else
                -- 从 row 15 往 row 1 逐行上落，找到该列最深的空位
                local dest = -1
                for r = HALF_ROWS, 1, -1 do
                    if board[r][c] == 0 then
                        dest = r
                    else
                        break
                    end
                end
                if dest > 0 then
                    board[dest][c] = rowData[c]
                    placed = placed + 1
                end
            end
        end
    end
    log("Teleported " .. placed .. " blocks to " .. targetHalf)
end

--- 扫描某半区的满行，返回 { clearedRows={行号}, removeSet={}, teleportData={{rowData, srcRow}} }
--- 不修改 board，仅收集数据
local function scanHalf(startRow, endRow, adjDir, teleportTarget)
    local result = { clearedRows = {}, removeSet = {}, teleportData = {}, half = teleportTarget == "lower" and "upper" or "lower" }
    local removeSet = result.removeSet

    for r = startRow, endRow do
        if isRowFull(r) then
            removeSet[r] = true
            table.insert(result.clearedRows, r)
            -- 相邻行（靠中线方向）
            local adj = r + adjDir
            if adj >= startRow and adj <= endRow and not removeSet[adj] and not isRowEmpty(adj) then
                table.insert(result.teleportData, { rowData = copyRow(adj), srcRow = adj })
                removeSet[adj] = true
            end
        end
    end

    return result
end

--- 执行压缩 + 传送（消行动画结束后调用）
local function executeCompactAndTeleport(upperScan, lowerScan)
    -- 上半区压缩
    if #upperScan.clearedRows > 0 then
        local kept = {}
        for r = 1, HALF_ROWS do
            if not upperScan.removeSet[r] then
                table.insert(kept, board[r])
            end
        end
        while #kept < HALF_ROWS do
            table.insert(kept, emptyRow())
        end
        for r = 1, HALF_ROWS do
            board[r] = kept[r]
        end
    end

    -- 下半区压缩
    if #lowerScan.clearedRows > 0 then
        local kept = {}
        for r = HALF_ROWS + 1, ROWS do
            if not lowerScan.removeSet[r] then
                table.insert(kept, board[r])
            end
        end
        while #kept < (ROWS - HALF_ROWS) do
            table.insert(kept, 1, emptyRow())
        end
        for i = 1, (ROWS - HALF_ROWS) do
            board[HALF_ROWS + i] = kept[i]
        end
    end

    -- 收集传送动画数据
    -- 动画终点 = 目标半区的中线入口行（不提前放入 board，由 teleport_control 阶段处理落位）
    local teleBlocks = {}
    for _, td in ipairs(upperScan.teleportData) do
        -- 上半区消行 → 传送到下半区，动画终点 = HALF_ROWS+1
        for c = 1, COLS do
            if td.rowData[c] ~= 0 then
                table.insert(teleBlocks, {
                    col = c,
                    fromRow = td.srcRow,
                    toRow = HALF_ROWS + 1,  -- 中线入口
                    colorIdx = td.rowData[c],
                })
            end
        end
    end
    for _, td in ipairs(lowerScan.teleportData) do
        -- 下半区消行 → 传送到上半区，动画终点 = HALF_ROWS
        for c = 1, COLS do
            if td.rowData[c] ~= 0 then
                table.insert(teleBlocks, {
                    col = c,
                    fromRow = td.srcRow,
                    toRow = HALF_ROWS,  -- 中线入口
                    colorIdx = td.rowData[c],
                })
            end
        end
    end

    return teleBlocks
end

--- 执行消行判定 → 启动动画（或直接完成）
local function checkAndClearLines()
    local upperScan = scanHalf(1, HALF_ROWS, 1, "lower")        -- adjDir=+1 靠中线
    local lowerScan = scanHalf(HALF_ROWS + 1, ROWS, -1, "upper") -- adjDir=-1 靠中线

    local totalCleared = #upperScan.clearedRows + #lowerScan.clearedRows
    if totalCleared == 0 then
        -- 无消除：扣减宽限，耗尽则重置 combo
        comboGrace_ = comboGrace_ - 1
        if comboGrace_ <= 0 then
            combo = 0
            comboGrace_ = 0
        end
        updateScoreDisplay()
        return
    end

    -- 有消除：累加 combo，刷新宽限
    combo = combo + 1
    comboGrace_ = COMBO_GRACE_PIECES
    -- 连击 x2 以上消除时背景闪绿
    if combo >= 2 then
        comboFlashTimer_ = 0.35
    end
    local lineBonus = ({100, 300, 500, 800})[math.min(totalCleared, 4)] or (totalCleared * 200)
    local comboBonus = 1.0 + (combo - 1) * 0.5
    local gained = math.floor(lineBonus * level * comboBonus)
    score = score + gained
    linesCleared = linesCleared + totalCleared
    level = math.floor(linesCleared / 3) + 1
    log(string.format("Score +%d (lines=%d combo=%d level=%d) total=%d",
        gained, totalCleared, combo, level, score))
    updateScoreDisplay()

    -- 收集需要闪烁的行
    animClearRows = {}
    for _, r in ipairs(upperScan.clearedRows) do
        table.insert(animClearRows, r)
    end
    -- 上半区传送行也闪烁
    for _, td in ipairs(upperScan.teleportData) do
        -- 只添加未在 clearedRows 中的行
        if not upperScan.removeSet[td.srcRow] or not isRowFull(td.srcRow) then
            table.insert(animClearRows, td.srcRow)
        end
    end
    for _, r in ipairs(lowerScan.clearedRows) do
        table.insert(animClearRows, r)
    end
    for _, td in ipairs(lowerScan.teleportData) do
        if not lowerScan.removeSet[td.srcRow] or not isRowFull(td.srcRow) then
            table.insert(animClearRows, td.srcRow)
        end
    end

    -- 缓存扫描数据，动画结束后执行
    animPendingClearData = { upperScan = upperScan, lowerScan = lowerScan }

    -- 启动消行动画
    animState = "clearing"
    animTimer = 0
    playSfx("clear")
    -- 震屏 + 粒子（强度随消行数递增）
    triggerShake(math.min(totalCleared * 2, 8), 0.25)
    spawnClearParticles(animClearRows)
    log("Clear anim started: " .. #animClearRows .. " rows")
end

-- 前向声明（这三个函数互相引用，且依赖后面定义的 spawnPiece/triggerGameOver）
local onClearAnimDone
local onTeleportAnimDone
local checkForChainReaction

--- 更新分数 UI
function updateScoreDisplay()
    if scoreLabelRef_ then
        scoreLabelRef_:SetText(tostring(score))
    end
    if levelLabelRef_ then
        levelLabelRef_:SetText("Lv" .. level)
    end
    if comboLabelRef_ then
        if combo >= 2 then
            comboLabelRef_:SetText(combo .. "x")
        else
            comboLabelRef_:SetText("")
        end
    end
end

-- ============================================================================
-- 随机袋 (7-bag)
-- ============================================================================

---@type table|nil
local bag2 = nil  -- 预生成的下一袋

local function refillBag()
    if bag2 then
        bag = bag2
        bag2 = nil
    else
        bag = {1, 2, 3, 4, 5, 6, 7}
        for i = 7, 2, -1 do
            local j = math.random(1, i)
            bag[i], bag[j] = bag[j], bag[i]
        end
    end
    bagIndex = 0
end

local function nextPieceType()
    bagIndex = bagIndex + 1
    if bagIndex > 7 then
        refillBag()
        bagIndex = 1
    end
    return bag[bagIndex]
end

--- 预览下一个方块类型（不消耗）
local function peekNextType()
    local idx = bagIndex + 1
    if idx > 7 then
        -- 需要预生成下一袋，但不影响当前袋
        -- 简单做法：如果即将用完，提前准备第二袋
        if not bag2 then
            bag2 = {1, 2, 3, 4, 5, 6, 7}
            for i = 7, 2, -1 do
                local j = math.random(1, i)
                bag2[i], bag2[j] = bag2[j], bag2[i]
            end
        end
        return bag2[1]
    end
    return bag[idx]
end

-- ============================================================================
-- 出生 / 翻转 / 方向确认
-- ============================================================================

--- @return boolean true=成功出生, false=Game Over
local function spawnPiece()
    -- 方向在出生时锁定为 nextDir
    curDir = nextDir
    dirChosen = true   -- 始终锁定，不再有选择阶段

    curType = nextPieceType()
    curRot  = 1
    curCol  = math.floor(COLS / 2)  -- 列 5
    -- 根据方向选择出生行：DIR_DOWN 在下半区顶部(13)，DIR_UP 在上半区底部(12)
    curRow  = (curDir == DIR_DOWN) and (HALF_ROWS + 1) or HALF_ROWS
    dropTimer = 0
    flippedThisPiece_ = false  -- 新方块：重置翻转许可

    -- 强制翻转检查（出生后检查，超过阈值则翻转 nextDir）
    flipCounter_ = flipCounter_ + 1
    if flipCounter_ > FLIP_FORCE_THRESHOLD then
        nextDir = (nextDir == DIR_DOWN) and DIR_UP or DIR_DOWN
        flipCounter_ = 0
        playSfx("flip")
        log("FORCED FLIP! nextDir=" .. (nextDir == DIR_UP and "UP" or "DOWN"))
    end

    if not isValidPosition(curType, curRot, curCol, curRow) then
        -- 尝试向出生方向偏移一行
        local altRow = (curDir == DIR_DOWN) and (HALF_ROWS + 2) or (HALF_ROWS - 1)
        if not isValidPosition(curType, curRot, curCol, altRow) then
            log("SPAWN BLOCKED - Game Over!")
            return false
        end
        curRow = altRow
    end

    updateFlipButton()
    updateFlipCounterDisplay()
    log("Spawned piece type=" .. curType, "dir=" .. (curDir == DIR_UP and "UP" or "DOWN"),
        "nextDir=" .. (nextDir == DIR_UP and "UP" or "DOWN"), "flipCounter=" .. flipCounter_)
    return true
end

local function flipDirection()
    if gameState ~= "playing" then return end
    if animState ~= "none" then return end
    if flippedThisPiece_ then return end  -- 每块只允许翻转一次
    flippedThisPiece_ = true
    nextDir = (nextDir == DIR_DOWN) and DIR_UP or DIR_DOWN
    flipCounter_ = 0  -- 主动翻转重置计数器
    playSfx("flip")
    updateFlipButton()
    updateFlipCounterDisplay()
    log("Next direction toggled to:", nextDir == DIR_UP and "UP" or "DOWN", "flipCounter reset")
end

--- 确认方向（保留接口但不再有实际作用，方向在出生时已锁定）
local function confirmDirection()
    -- 新机制下 dirChosen 始终为 true，此函数为空操作
end

--- 触发 Game Over
local function triggerGameOver()
    gameState = "gameover"
    curType = 0  -- 停止渲染当前方块
    playSfx("gameover")
    commitScore(score)
    log(string.format("=== GAME OVER === Score: %d  Level: %d  Lines: %d", score, level, linesCleared))
end

-- ============================================================================
-- 动画回调（前向声明的函数体）
-- 必须在 spawnPiece/triggerGameOver 之后定义
-- ============================================================================

function checkForChainReaction()
    local upperScan = scanHalf(1, HALF_ROWS, 1, "lower")
    local lowerScan = scanHalf(HALF_ROWS + 1, ROWS, -1, "upper")
    local totalCleared = #upperScan.clearedRows + #lowerScan.clearedRows
    if totalCleared > 0 then
        log("Chain reaction! " .. totalCleared .. " more lines")
        combo = combo + 1
        comboGrace_ = COMBO_GRACE_PIECES
        if combo >= 2 then
            comboFlashTimer_ = 0.35
        end
        local lineBonus = ({100, 300, 500, 800})[math.min(totalCleared, 4)] or (totalCleared * 200)
        local comboBonus = 1.0 + (combo - 1) * 0.5
        local gained = math.floor(lineBonus * level * comboBonus)
        score = score + gained
        linesCleared = linesCleared + totalCleared
        level = math.floor(linesCleared / 3) + 1
        updateScoreDisplay()

        animClearRows = {}
        for _, r in ipairs(upperScan.clearedRows) do table.insert(animClearRows, r) end
        for _, td in ipairs(upperScan.teleportData) do
            if not upperScan.removeSet[td.srcRow] or not isRowFull(td.srcRow) then
                table.insert(animClearRows, td.srcRow)
            end
        end
        for _, r in ipairs(lowerScan.clearedRows) do table.insert(animClearRows, r) end
        for _, td in ipairs(lowerScan.teleportData) do
            if not lowerScan.removeSet[td.srcRow] or not isRowFull(td.srcRow) then
                table.insert(animClearRows, td.srcRow)
            end
        end

        animPendingClearData = { upperScan = upperScan, lowerScan = lowerScan }
        animState = "clearing"
        animTimer = 0
        playSfx("clear")
        triggerShake(math.min(totalCleared * 3, 10), 0.3)
        spawnClearParticles(animClearRows)
    else
        -- 动画全部结束，出生新方块
        if not spawnPiece() then
            triggerGameOver()
        end
    end
end

function onTeleportAnimDone()
    -- 判断传送目标半区，确定下落方向
    if #animTeleportBlocks > 0 then
        local firstTo = animTeleportBlocks[1].toRow
        if firstTo <= HALF_ROWS then
            teleCtrlDir = DIR_UP  -- 目标在上半区，向天花板堆积
        else
            teleCtrlDir = DIR_DOWN  -- 目标在下半区，向地板堆积
        end

        -- 将传送方块放在目标半区的入口行（中线附近），准备让玩家控制
        teleCtrlBlocks = {}
        for _, tb in ipairs(animTeleportBlocks) do
            -- 入口行：上半区 = HALF_ROWS (row 15)，下半区 = HALF_ROWS+1 (row 16)
            local entryRow
            if teleCtrlDir == DIR_UP then
                entryRow = HALF_ROWS
            else
                entryRow = HALF_ROWS + 1
            end
            table.insert(teleCtrlBlocks, {
                col = tb.col,
                row = entryRow,
                colorIdx = tb.colorIdx,
            })
        end
        animTeleportBlocks = {}
        animState = "teleport_control"
        teleCtrlDropTimer = 0
        log("Teleport control started: " .. #teleCtrlBlocks .. " blocks, dir=" ..
            (teleCtrlDir == DIR_UP and "UP" or "DOWN"))
    else
        animTeleportBlocks = {}
        animState = "none"
        checkForChainReaction()
    end
end

function onClearAnimDone()
    if not animPendingClearData then
        animState = "none"
        return
    end

    local data = animPendingClearData
    animPendingClearData = nil

    local teleBlocks = executeCompactAndTeleport(data.upperScan, data.lowerScan)

    if #teleBlocks > 0 then
        -- 方块不在 board 中，无需移除；直接设置飞行动画
        animTeleportBlocks = teleBlocks
        animState = "teleporting"
        animTimer = 0
        log("Teleport anim started: " .. #animTeleportBlocks .. " blocks")
    else
        animState = "none"
        checkForChainReaction()
    end
end

-- ============================================================================
-- 传送方块控制逻辑
-- ============================================================================

--- 检查传送方块群能否整体平移 dCol
local function canTeleCtrlMove(dCol)
    for _, b in ipairs(teleCtrlBlocks) do
        local newCol = b.col + dCol
        if newCol < 1 or newCol > COLS then return false end
        if board[b.row][newCol] ~= 0 then
            -- 检查不是自己群里的方块占着
            local isOwn = false
            for _, ob in ipairs(teleCtrlBlocks) do
                if ob.row == b.row and ob.col == newCol then isOwn = true; break end
            end
            if not isOwn then return false end
        end
    end
    return true
end

--- 整体左右移动传送方块群
local function moveTeleCtrl(dCol)
    if not canTeleCtrlMove(dCol) then return false end
    for _, b in ipairs(teleCtrlBlocks) do
        b.col = b.col + dCol
    end
    return true
end

--- 让每个传送方块独立下落一步，返回 true 表示至少有一个移动了
local function dropTeleCtrlOneStep()
    local anyMoved = false
    -- 按下落方向排序，避免互相阻挡
    local sorted = {}
    for i, b in ipairs(teleCtrlBlocks) do
        sorted[i] = b
    end
    if teleCtrlDir == DIR_DOWN then
        table.sort(sorted, function(a, b) return a.row > b.row end)  -- 从底部开始
    else
        table.sort(sorted, function(a, b) return a.row < b.row end)  -- 从顶部开始
    end

    for _, b in ipairs(sorted) do
        local nextRow = b.row + teleCtrlDir
        -- 边界检查
        local blocked = false
        if teleCtrlDir == DIR_DOWN then
            if nextRow > ROWS then blocked = true end
        else
            if nextRow < 1 then blocked = true end
        end
        -- 碰撞检查（不是自己群里的方块）
        if not blocked and board[nextRow] and board[nextRow][b.col] ~= 0 then
            local isOwn = false
            for _, ob in ipairs(teleCtrlBlocks) do
                if ob.row == nextRow and ob.col == b.col then isOwn = true; break end
            end
            if not isOwn then blocked = true end
        end
        if not blocked then
            b.row = nextRow
            anyMoved = true
        end
    end
    return anyMoved
end

--- 锁定传送方块群到 board
local function lockTeleCtrlBlocks()
    for _, b in ipairs(teleCtrlBlocks) do
        if b.row >= 1 and b.row <= ROWS and b.col >= 1 and b.col <= COLS then
            board[b.row][b.col] = b.colorIdx
        end
    end
    log("Teleport control locked: " .. #teleCtrlBlocks .. " blocks")
    teleCtrlBlocks = {}
    animState = "none"
    checkForChainReaction()
end

--- 推进引导层：下一步或结束引导并开始游戏
local function advanceTutorial()
    if not tutorial_.active then return false end
    if tutorial_.step < #TUTORIAL_STEPS then
        tutorial_.step = tutorial_.step + 1
        tutorial_.fadeIn = 0
        log("Tutorial step " .. tutorial_.step)
        return true
    else
        -- 最后一步，结束引导并开始游戏
        tutorial_.active = false
        tutorial_.shown = true
        gameState = "playing"
        spawnPiece()
        log("Tutorial done, GAME STARTED")
        return true
    end
end

--- 从标题屏开始游戏
-- 初始化标题拖影动画
local function initTitleTrails()
    -- 坐标使用相对于 midX/midY 的偏移，渲染时动态设置绝对坐标
    titleTrails_ = Anim.createTrailGroup({
        {   -- "RE" 从左侧滑入
            text = "RE", font = "sans", fontSize = 32,
            color = {0, 240, 240, 255},
            x = 0, y = -50,          -- 相对 midX/midY 的偏移
            offsetX = -80, offsetY = 0,
            duration = 0.7,
            shadowLayers = 5,
            darken = 0.3,
            ease = "quint",
        },
        {   -- ":Flip" 从右侧滑入
            text = ":Flip", font = "sans", fontSize = 18,
            color = {255, 180, 50, 255},
            x = 0, y = -18,
            offsetX = 80, offsetY = 0,
            duration = 0.7,
            shadowLayers = 5,
            darken = 0.3,
            ease = "quint",
        },
    }, 0.2)  -- 级联延迟 0.2s
    -- 保存相对坐标，渲染时动态换算为绝对坐标
    for _, trail in ipairs(titleTrails_) do
        trail._relX = trail.x
        trail._relY = trail.y
    end
end

local function startGame()
    if tutorial_.active then
        advanceTutorial()
        return
    end
    if not tutorial_.shown then
        -- 首次：进入引导
        tutorial_.active = true
        tutorial_.step = 1
        tutorial_.fadeIn = 0
        log("Tutorial started")
        return
    end
    -- 已看过引导，直接开始
    gameState = "playing"
    spawnPiece()
    log("=== GAME STARTED ===")
end

local function restartGame()
    initBoard()
    refillBag()
    score = 0
    level = 1
    linesCleared = 0
    combo = 0
    comboGrace_ = 0
    comboFlashTimer_ = 0
    curDir = DIR_DOWN
    nextDir = DIR_DOWN
    flipCounter_ = 0
    flippedThisPiece_ = false
    dirChosen = true
    gameState = "playing"
    -- 重置动画状态
    animState = "none"
    animTimer = 0
    animClearRows = {}
    animTeleportBlocks = {}
    animPendingClearData = nil
    teleCtrlBlocks = {}
    teleCtrlDropTimer = 0
    updateScoreDisplay()
    spawnPiece()
    log("=== GAME RESTARTED ===")
end

--- 锁定方块 → 消行判定 → 出生新方块（统一流程）
--- 如果有消行动画，新方块的出生由动画完成回调 checkForChainReaction 触发
local function lockAndSpawn()
    lockPiece()
    curType = 0  -- 锁定后暂时不显示方块（等待动画或出生）
    checkAndClearLines()
    -- 如果没有动画（没有消行），直接出生
    if animState == "none" then
        if not spawnPiece() then
            triggerGameOver()
        end
    end
    -- 有动画的话，出生在 checkForChainReaction() 中处理
end

--- 更新 FLIP 按钮显示（显示下一个方块的方向）
function updateFlipButton()
    if not flipBtnRef_ then return end
    flipBtnRef_:SetText(nextDir == DIR_UP and "▲上[F]" or "▼下[F]")
end

--- 更新翻转计数器和方向预览显示
function updateFlipCounterDisplay()
    if nextDirLabelRef_ then
        local arrow = nextDir == DIR_UP and "▲" or "▼"
        local clr = nextDir == DIR_UP and { 80, 180, 255, 255 } or { 255, 160, 80, 255 }
        nextDirLabelRef_:SetText(arrow)
        nextDirLabelRef_:SetFontColor(clr)
    end
    if flipCountLabelRef_ then
        local remain = FLIP_FORCE_THRESHOLD - flipCounter_
        if remain <= 3 then
            flipCountLabelRef_:SetFontColor({ 255, 80, 80, 255 })
        else
            flipCountLabelRef_:SetFontColor({ 180, 180, 200, 255 })
        end
        flipCountLabelRef_:SetText(tostring(remain))
    end
end

-- ============================================================================
-- 移动 / 旋转 / 下落
-- ============================================================================

local function movePiece(dCol, dRow)
    if gameState ~= "playing" then return false end
    if animState ~= "none" then return false end
    confirmDirection()
    local newCol = curCol + dCol
    local newRow = curRow + dRow
    if isValidPosition(curType, curRot, newCol, newRow) then
        curCol = newCol
        curRow = newRow
        playSfx("move")
        return true
    end
    return false
end

local function rotatePiece()
    if gameState ~= "playing" then return false end
    if animState ~= "none" then return false end
    if gameTime_ - lastRotateTime_ < COOLDOWN then return false end
    lastRotateTime_ = gameTime_
    confirmDirection()
    local newRot = (curRot % 4) + 1
    local kickTable
    if curType == 1 then
        kickTable = KICK_I[curRot]
    elseif curType == 2 then
        if isValidPosition(curType, newRot, curCol, curRow) then
            curRot = newRot
            playSfx("rotate")
            return true
        end
        return false
    else
        kickTable = KICK_JLSTZ[curRot]
    end

    for _, kick in ipairs(kickTable) do
        local testCol = curCol + kick[1]
        local testRow = curRow + kick[2]
        if isValidPosition(curType, newRot, testCol, testRow) then
            curCol = testCol
            curRow = testRow
            curRot = newRot
            playSfx("rotate")
            return true
        end
    end
    return false
end

local function hardDrop()
    if gameState ~= "playing" then return end
    if animState ~= "none" then return end
    if gameTime_ - lastHardDropTime_ < COOLDOWN then return end
    lastHardDropTime_ = gameTime_
    confirmDirection()
    local step = curDir
    local moved = 0
    while isValidPosition(curType, curRot, curCol, curRow + step) do
        curRow = curRow + step
        moved = moved + 1
    end
    log("Hard drop moved", moved, "rows")
    lockAndSpawn()
end

local function dropOneRow()
    if gameState ~= "playing" then return end
    local step = curDir
    local nextRow = curRow + step
    if nextRow < 1 or nextRow > ROWS then
        lockAndSpawn()
        return
    end
    if isValidPosition(curType, curRot, curCol, nextRow) then
        curRow = nextRow
    else
        lockAndSpawn()
    end
end

-- ============================================================================
-- 像素风格方块绘制
-- ============================================================================

--- 绘制一个像素风格方块（经典 NES 凹凸效果）
--- @param nvg userdata NanoVG context
--- @param x number 左上角 x
--- @param y number 左上角 y
--- @param size number 格子大小
--- @param r number 颜色 R
--- @param g number 颜色 G
--- @param b number 颜色 B
--- @param a number 颜色 A (可选, 默认 255)
local function drawPixelBlock(nvg, x, y, size, r, g, b, a)
    a = a or 255
    local edge = math.max(2, math.floor(size / 8))  -- 边缘宽度

    -- 1) 整体填充基色
    nvgBeginPath(nvg)
    nvgRect(nvg, x, y, size, size)
    nvgFillColor(nvg, nvgRGBA(r, g, b, a))
    nvgFill(nvg)

    -- 2) 高光边（上边+左边）— 更亮
    local hr = math.min(255, r + 80)
    local hg = math.min(255, g + 80)
    local hb = math.min(255, b + 80)
    -- 上边
    nvgBeginPath(nvg)
    nvgRect(nvg, x, y, size, edge)
    nvgFillColor(nvg, nvgRGBA(hr, hg, hb, a))
    nvgFill(nvg)
    -- 左边
    nvgBeginPath(nvg)
    nvgRect(nvg, x, y, edge, size)
    nvgFillColor(nvg, nvgRGBA(hr, hg, hb, a))
    nvgFill(nvg)

    -- 3) 阴影边（下边+右边）— 更暗
    local sr = math.max(0, r - 80)
    local sg = math.max(0, g - 80)
    local sb = math.max(0, b - 80)
    -- 下边
    nvgBeginPath(nvg)
    nvgRect(nvg, x, y + size - edge, size, edge)
    nvgFillColor(nvg, nvgRGBA(sr, sg, sb, a))
    nvgFill(nvg)
    -- 右边
    nvgBeginPath(nvg)
    nvgRect(nvg, x + size - edge, y, edge, size)
    nvgFillColor(nvg, nvgRGBA(sr, sg, sb, a))
    nvgFill(nvg)

    -- 4) 内部小高光块（左上角亮点）
    local inner = edge
    nvgBeginPath(nvg)
    nvgRect(nvg, x + edge, y + edge, inner, inner)
    nvgFillColor(nvg, nvgRGBA(math.min(255, r + 120), math.min(255, g + 120), math.min(255, b + 120), math.floor(a * 0.6)))
    nvgFill(nvg)
end

-- ============================================================================
-- 渲染 - 自定义 Widget
-- ============================================================================

-- ── 全屏装饰背景（CRT 复古电视风格）─────────────────────────────
local BackgroundImage = UI.Widget:Extend("BackgroundImage")

function BackgroundImage:Init(props)
    props = props or {}
    self._src = props.src or ""
    props.position = "absolute"
    props.left = 0
    props.top = 0
    props.width = "100%"
    props.height = "100%"
    UI.Widget.Init(self, props)
end

function BackgroundImage:Render(nvg)
    local l = self:GetAbsoluteLayout()
    if not l or not l.w or not l.h or l.w <= 0 or l.h <= 0 then return end
    local bx, by = math.floor(l.x), math.floor(l.y)
    local bw, bh = math.floor(l.w), math.floor(l.h)

    -- ── 电视机外壳（深色背景）──
    nvgBeginPath(nvg)
    nvgRect(nvg, bx, by, bw, bh)
    nvgFillColor(nvg, nvgRGBA(8, 6, 4, 255))
    nvgFill(nvg)

    -- ── CRT 屏幕区域（内缩 + 圆角模拟弧面）──
    local margin = math.max(6, math.floor(math.min(bw, bh) * 0.018))
    local sx, sy = bx + margin, by + margin
    local sw, sh = bw - margin * 2, bh - margin * 2
    local cornerR = math.max(8, math.floor(math.min(sw, sh) * 0.04))

    -- 保存状态，用圆角矩形裁剪后续所有 CRT 内容
    nvgSave(nvg)
    nvgIntersectScissor(nvg, sx, sy, sw, sh)

    -- ── 背景图片（带暖色偏移模拟磷光管）──
    local imgHandle = ImageCache.Get(self._src)
    if imgHandle and imgHandle > 0 then
        local imgW, imgH = 1376, 768
        local scaleX = sw / imgW
        local scaleY = sh / imgH
        local scale = math.max(scaleX, scaleY)
        local drawW = imgW * scale
        local drawH = imgH * scale
        local drawX = sx + (sw - drawW) / 2
        local drawY = sy + (sh - drawH) / 2

        local imgPaint = nvgImagePattern(nvg, drawX, drawY, drawW, drawH, 0, imgHandle, 0.80)
        nvgBeginPath(nvg)
        nvgRoundedRect(nvg, sx, sy, sw, sh, cornerR)
        nvgFillPaint(nvg, imgPaint)
        nvgFill(nvg)
    end

    -- ── 磷光暖色调覆盖（模拟 CRT 显色偏暖）──
    nvgBeginPath(nvg)
    nvgRoundedRect(nvg, sx, sy, sw, sh, cornerR)
    nvgFillColor(nvg, nvgRGBA(30, 15, 5, 18))
    nvgFill(nvg)

    -- ── CRT 扫描线（全屏，间距 3px）──
    nvgFillColor(nvg, nvgRGBA(0, 0, 0, 30))
    for scanY = 0, sh - 1, 3 do
        nvgBeginPath(nvg)
        nvgRect(nvg, sx, sy + scanY, sw, 1)
        nvgFill(nvg)
    end

    -- ── CRT 边缘暗角/渐晕（四边变暗模拟弧面玻璃）──
    -- 上边暗化
    local topGrad = nvgLinearGradient(nvg, sx, sy, sx, sy + sh * 0.15,
        nvgRGBA(0, 0, 0, 100), nvgRGBA(0, 0, 0, 0))
    nvgBeginPath(nvg)
    nvgRect(nvg, sx, sy, sw, sh * 0.15)
    nvgFillPaint(nvg, topGrad)
    nvgFill(nvg)
    -- 下边暗化
    local botGrad = nvgLinearGradient(nvg, sx, sy + sh * 0.85, sx, sy + sh,
        nvgRGBA(0, 0, 0, 0), nvgRGBA(0, 0, 0, 100))
    nvgBeginPath(nvg)
    nvgRect(nvg, sx, sy + sh * 0.85, sw, sh * 0.15)
    nvgFillPaint(nvg, botGrad)
    nvgFill(nvg)
    -- 左边暗化
    local leftGrad = nvgLinearGradient(nvg, sx, sy, sx + sw * 0.12, sy,
        nvgRGBA(0, 0, 0, 110), nvgRGBA(0, 0, 0, 0))
    nvgBeginPath(nvg)
    nvgRect(nvg, sx, sy, sw * 0.12, sh)
    nvgFillPaint(nvg, leftGrad)
    nvgFill(nvg)
    -- 右边暗化
    local rightGrad = nvgLinearGradient(nvg, sx + sw * 0.88, sy, sx + sw, sy,
        nvgRGBA(0, 0, 0, 0), nvgRGBA(0, 0, 0, 110))
    nvgBeginPath(nvg)
    nvgRect(nvg, sx + sw * 0.88, sy, sw * 0.12, sh)
    nvgFillPaint(nvg, rightGrad)
    nvgFill(nvg)

    -- ── 四角加深（模拟 CRT 弧面四角最暗）──
    local crnSz = math.floor(math.min(sw, sh) * 0.25)
    local crnAlpha = 80
    -- 左上
    local cTL = nvgLinearGradient(nvg, sx, sy, sx + crnSz, sy + crnSz,
        nvgRGBA(0, 0, 0, crnAlpha), nvgRGBA(0, 0, 0, 0))
    nvgBeginPath(nvg)
    nvgRect(nvg, sx, sy, crnSz, crnSz)
    nvgFillPaint(nvg, cTL)
    nvgFill(nvg)
    -- 右上
    local cTR = nvgLinearGradient(nvg, sx + sw, sy, sx + sw - crnSz, sy + crnSz,
        nvgRGBA(0, 0, 0, crnAlpha), nvgRGBA(0, 0, 0, 0))
    nvgBeginPath(nvg)
    nvgRect(nvg, sx + sw - crnSz, sy, crnSz, crnSz)
    nvgFillPaint(nvg, cTR)
    nvgFill(nvg)
    -- 左下
    local cBL = nvgLinearGradient(nvg, sx, sy + sh, sx + crnSz, sy + sh - crnSz,
        nvgRGBA(0, 0, 0, crnAlpha), nvgRGBA(0, 0, 0, 0))
    nvgBeginPath(nvg)
    nvgRect(nvg, sx, sy + sh - crnSz, crnSz, crnSz)
    nvgFillPaint(nvg, cBL)
    nvgFill(nvg)
    -- 右下
    local cBR = nvgLinearGradient(nvg, sx + sw, sy + sh, sx + sw - crnSz, sy + sh - crnSz,
        nvgRGBA(0, 0, 0, crnAlpha), nvgRGBA(0, 0, 0, 0))
    nvgBeginPath(nvg)
    nvgRect(nvg, sx + sw - crnSz, sy + sh - crnSz, crnSz, crnSz)
    nvgFillPaint(nvg, cBR)
    nvgFill(nvg)

    nvgRestore(nvg)

    -- ── 电视机屏幕边框（圆角矩形描边）──
    -- 内层高光边（模拟玻璃反光）
    nvgBeginPath(nvg)
    nvgRoundedRect(nvg, sx + 1, sy + 1, sw - 2, sh - 2, cornerR - 1)
    nvgStrokeColor(nvg, nvgRGBA(60, 55, 50, 60))
    nvgStrokeWidth(nvg, 1)
    nvgStroke(nvg)
    -- 外层深色边框（电视机壳体）
    nvgBeginPath(nvg)
    nvgRoundedRect(nvg, sx, sy, sw, sh, cornerR)
    nvgStrokeColor(nvg, nvgRGBA(20, 16, 12, 200))
    nvgStrokeWidth(nvg, 2)
    nvgStroke(nvg)
end

-- ── 像素风格信息面板（SNES 金边框）─────────────────────────────────
local PixelInfoPanel = UI.Widget:Extend("PixelInfoPanel")

function PixelInfoPanel:Init(props)
    props = props or {}
    self._title = props.title or ""
    self._bgColor = props.bgColor or { 30, 20, 10, 220 }
    self._borderColor = props.borderColor or { 200, 160, 60 }  -- 金色
    UI.Widget.Init(self, props)
end

function PixelInfoPanel:Render(nvg)
    local l = self:GetAbsoluteLayout()
    if not l or not l.w or not l.h or l.w <= 0 or l.h <= 0 then return end
    local bx, by = math.floor(l.x), math.floor(l.y)
    local bw, bh = math.floor(l.w), math.floor(l.h)
    local bc = self._borderColor
    local bg = self._bgColor
    local edge = 2

    -- 外层亮金边
    nvgBeginPath(nvg)
    nvgRoundedRect(nvg, bx, by, bw, bh, 3)
    nvgFillColor(nvg, nvgRGBA(math.min(255, bc[1] + 60), math.min(255, bc[2] + 60), math.min(255, bc[3] + 60), 255))
    nvgFill(nvg)
    -- 内层暗金边
    nvgBeginPath(nvg)
    nvgRoundedRect(nvg, bx + edge, by + edge, bw - edge * 2, bh - edge * 2, 2)
    nvgFillColor(nvg, nvgRGBA(math.max(0, bc[1] - 60), math.max(0, bc[2] - 60), math.max(0, bc[3] - 60), 255))
    nvgFill(nvg)
    -- 背景填充
    nvgBeginPath(nvg)
    nvgRoundedRect(nvg, bx + edge + 1, by + edge + 1, bw - edge * 2 - 2, bh - edge * 2 - 2, 1)
    nvgFillColor(nvg, nvgRGBA(bg[1], bg[2], bg[3], bg[4]))
    nvgFill(nvg)

    -- 标题文字（面板顶部）
    if self._title ~= "" then
        nvgFontFace(nvg, "sans")
        nvgFontSize(nvg, 10)
        nvgTextAlign(nvg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
        nvgFillColor(nvg, nvgRGBA(bc[1], bc[2], bc[3], 255))
        nvgText(nvg, bx + bw / 2, by + edge + 3, self._title)
    end
end

-- ── 棋盘 ──────────────────────────────────────────────────────────
local GameBoard = UI.Widget:Extend("GameBoard")

function GameBoard:Init(props)
    props = props or {}
    -- 不设固定尺寸，让 Flexbox 布局决定可用空间
    props.flexGrow = 1
    props.flexShrink = 1
    props.width = "100%"
    props.height = "100%"
    UI.Widget.Init(self, props)
end

function GameBoard:Render(nvg)
    local l = self:GetAbsoluteLayout()
    if not l or not l.w or not l.h or l.w <= 0 or l.h <= 0 then return end
    local availW = math.floor(l.w)
    local availH = math.floor(l.h)

    -- 从实际布局空间动态计算 CELL_SIZE（核心自适应逻辑）
    local cellW = math.floor(availW / COLS)
    local cellH = math.floor(availH / ROWS)
    CELL_SIZE = math.max(8, math.min(cellW, cellH))
    BOARD_W = COLS * CELL_SIZE
    BOARD_H = ROWS * CELL_SIZE
    -- 同步预览尺寸
    PREVIEW_CELL = math.max(6, math.floor(CELL_SIZE * 0.65))
    PREVIEW_SIZE = PREVIEW_CELL * 5

    -- 在可用空间内居中
    local ox = math.floor(l.x + (availW - BOARD_W) / 2)
    local oy = math.floor(l.y + (availH - BOARD_H) / 2)

    -- 震屏偏移
    if shakeTimer_ < shakeDuration_ then
        local progress = shakeTimer_ / shakeDuration_
        local fade = 1.0 - progress  -- 逐渐衰减
        local amp = shakeIntensity_ * fade
        ox = ox + math.floor(math.sin(shakeTimer_ * 50) * amp)
        oy = oy + math.floor(math.cos(shakeTimer_ * 43) * amp * 0.6)
    end

    -- 棋盘画框（SNES 风格厚立体凸起边框）
    local bdr = 10  -- 画框总厚度

    -- 1) 最外层深色轮廓 (1px)
    nvgBeginPath(nvg)
    nvgRect(nvg, ox - bdr, oy - bdr, BOARD_W + bdr * 2, BOARD_H + bdr * 2)
    nvgFillColor(nvg, nvgRGBA(30, 30, 40, 255))
    nvgFill(nvg)

    -- 2) 外斜面高光（上+左 亮银）
    nvgBeginPath(nvg)
    nvgRect(nvg, ox - bdr + 1, oy - bdr + 1, BOARD_W + bdr * 2 - 2, BOARD_H + bdr * 2 - 2)
    nvgFillColor(nvg, nvgRGBA(220, 220, 230, 255))
    nvgFill(nvg)

    -- 3) 外斜面阴影（下+右 暗灰，覆盖右半和下半）
    -- 右边阴影条
    nvgBeginPath(nvg)
    nvgRect(nvg, ox + BOARD_W + 2, oy - bdr + 1, bdr - 3, BOARD_H + bdr * 2 - 2)
    nvgFillColor(nvg, nvgRGBA(60, 60, 75, 255))
    nvgFill(nvg)
    -- 下边阴影条
    nvgBeginPath(nvg)
    nvgRect(nvg, ox - bdr + 1, oy + BOARD_H + 2, BOARD_W + bdr * 2 - 2, bdr - 3)
    nvgFillColor(nvg, nvgRGBA(60, 60, 75, 255))
    nvgFill(nvg)

    -- 4) 中间主体填充（中灰色）
    local inner = 3
    nvgBeginPath(nvg)
    nvgRect(nvg, ox - bdr + inner, oy - bdr + inner,
        BOARD_W + (bdr - inner) * 2, BOARD_H + (bdr - inner) * 2)
    nvgFillColor(nvg, nvgRGBA(140, 140, 155, 255))
    nvgFill(nvg)

    -- 5) 内斜面阴影（上+左 暗）
    local inn2 = bdr - 2
    nvgBeginPath(nvg)
    nvgRect(nvg, ox - inn2 + inner, oy - inn2 + inner,
        BOARD_W + (inn2 - inner) * 2, BOARD_H + (inn2 - inner) * 2)
    nvgFillColor(nvg, nvgRGBA(80, 80, 95, 255))
    nvgFill(nvg)

    -- 6) 内斜面高光（下+右 亮，覆盖）
    nvgBeginPath(nvg)
    nvgRect(nvg, ox - 2, oy - 2, BOARD_W + 4, BOARD_H + 4)
    nvgFillColor(nvg, nvgRGBA(180, 180, 195, 255))
    nvgFill(nvg)

    -- 7) 最内层深色轮廓 (1px)
    nvgBeginPath(nvg)
    nvgRect(nvg, ox - 1, oy - 1, BOARD_W + 2, BOARD_H + 2)
    nvgFillColor(nvg, nvgRGBA(25, 25, 35, 255))
    nvgFill(nvg)

    -- 半透明背景（上下半区根据方向高亮）
    local halfH = HALF_ROWS * CELL_SIZE
    if gameState == "playing" and curType > 0 then
        -- 当前方向对应的半区用亮色，另一半用暗色
        local activeR, activeG, activeB = 15, 20, 45   -- 活跃半区（偏蓝微亮）
        local inactR, inactG, inactB    = 8, 8, 14     -- 非活跃半区（更暗）
        if curDir == DIR_UP then
            -- 上半区活跃
            nvgBeginPath(nvg)
            nvgRect(nvg, ox, oy, BOARD_W, halfH)
            nvgFillColor(nvg, nvgRGBA(activeR, activeG, activeB, 210))
            nvgFill(nvg)
            nvgBeginPath(nvg)
            nvgRect(nvg, ox, oy + halfH, BOARD_W, halfH)
            nvgFillColor(nvg, nvgRGBA(inactR, inactG, inactB, 220))
            nvgFill(nvg)
        else
            -- 下半区活跃
            nvgBeginPath(nvg)
            nvgRect(nvg, ox, oy, BOARD_W, halfH)
            nvgFillColor(nvg, nvgRGBA(inactR, inactG, inactB, 220))
            nvgFill(nvg)
            nvgBeginPath(nvg)
            nvgRect(nvg, ox, oy + halfH, BOARD_W, halfH)
            nvgFillColor(nvg, nvgRGBA(activeR, activeG, activeB, 210))
            nvgFill(nvg)
        end

        -- ── 半区即将满警告（超过 9 行有方块则闪暗红）──
        local DANGER_THRESHOLD = math.floor(HALF_ROWS * 2 / 3)  -- 三分之二 = 8
        -- 统计上半区已占用行数
        local upperUsed = 0
        for r = 1, HALF_ROWS do
            for c = 1, COLS do
                if board[r][c] ~= 0 then upperUsed = upperUsed + 1; break end
            end
        end
        -- 统计下半区已占用行数
        local lowerUsed = 0
        for r = HALF_ROWS + 1, ROWS do
            for c = 1, COLS do
                if board[r][c] ~= 0 then lowerUsed = lowerUsed + 1; break end
            end
        end
        -- 闪烁暗红覆盖层（正弦脉冲）
        local dangerPulse = 0.5 + 0.5 * math.sin(gameTime_ * 6)
        if upperUsed >= DANGER_THRESHOLD then
            local da = math.floor(dangerPulse * 50 + 15)
            nvgBeginPath(nvg)
            nvgRect(nvg, ox, oy, BOARD_W, halfH)
            nvgFillColor(nvg, nvgRGBA(180, 20, 10, da))
            nvgFill(nvg)
        end
        if lowerUsed >= DANGER_THRESHOLD then
            local da = math.floor(dangerPulse * 50 + 15)
            nvgBeginPath(nvg)
            nvgRect(nvg, ox, oy + halfH, BOARD_W, halfH)
            nvgFillColor(nvg, nvgRGBA(180, 20, 10, da))
            nvgFill(nvg)
        end
    else
        nvgBeginPath(nvg)
        nvgRect(nvg, ox, oy, BOARD_W, BOARD_H)
        nvgFillColor(nvg, nvgRGBA(10, 10, 20, 200))
        nvgFill(nvg)
    end

    -- ── 连击 x2+ 消除时全棋盘闪绿 ──
    if comboFlashTimer_ > 0 then
        local flashAlpha = math.floor((comboFlashTimer_ / 0.35) * 60)
        nvgBeginPath(nvg)
        nvgRect(nvg, ox, oy, BOARD_W, BOARD_H)
        nvgFillColor(nvg, nvgRGBA(30, 220, 60, flashAlpha))
        nvgFill(nvg)
    end

    -- 像素点阵网格（每个交叉点画 1px 小点）
    nvgFillColor(nvg, nvgRGBA(40, 40, 65, 120))
    for r = 1, ROWS - 1 do
        for c = 1, COLS - 1 do
            nvgBeginPath(nvg)
            nvgRect(nvg, ox + c * CELL_SIZE, oy + r * CELL_SIZE, 1, 1)
            nvgFill(nvg)
        end
    end

    -- 中线（像素虚线）
    local centerY = oy + HALF_ROWS * CELL_SIZE
    local dashW = 4
    local gapW = 3
    for px = 0, BOARD_W - 1, dashW + gapW do
        local w = math.min(dashW, BOARD_W - px)
        nvgBeginPath(nvg)
        nvgRect(nvg, ox + px, centerY - 1, w, 2)
        nvgFillColor(nvg, nvgRGBA(255, 100, 100, 200))
        nvgFill(nvg)
    end

    -- 上下半区标签
    nvgFontFace(nvg, "sans")
    nvgFontSize(nvg, 8)
    nvgFillColor(nvg, nvgRGBA(100, 100, 150, 120))
    nvgTextAlign(nvg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
    nvgText(nvg, ox + BOARD_W / 2, oy + 2, "UPPER")
    nvgTextAlign(nvg, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
    nvgText(nvg, ox + BOARD_W / 2, oy + BOARD_H - 2, "LOWER")

    -- 构建消行行号集合（用于闪烁判断）
    local clearRowSet = {}
    if animState == "clearing" then
        for _, r in ipairs(animClearRows) do
            clearRowSet[r] = true
        end
    end

    -- 已锁定方块
    for r = 1, ROWS do
        for c = 1, COLS do
            local v = board[r][c]
            if v > 0 then
                local clr = COLORS[v]
                local cx = ox + (c - 1) * CELL_SIZE
                local cy = oy + (r - 1) * CELL_SIZE

                if clearRowSet[r] then
                    -- 消行闪烁：白色脉冲 + 渐隐
                    local t = animTimer / ANIM_CLEAR_DURATION
                    local flash = math.abs(math.sin(t * math.pi * 3))
                    local fade = 1.0 - t
                    local white = math.floor(flash * 200 * fade)
                    drawPixelBlock(nvg, cx, cy, CELL_SIZE,
                        math.min(255, clr[1] + white),
                        math.min(255, clr[2] + white),
                        math.min(255, clr[3] + white),
                        math.floor(clr[4] * fade))
                else
                    drawPixelBlock(nvg, cx, cy, CELL_SIZE, clr[1], clr[2], clr[3], clr[4])
                end
            end
        end
    end

    -- 传送飞行动画
    if animState == "teleporting" and #animTeleportBlocks > 0 then
        local t = math.min(animTimer / ANIM_TELEPORT_DURATION, 1.0)
        local eased = 1.0 - (1.0 - t) * (1.0 - t)

        for _, tb in ipairs(animTeleportBlocks) do
            local clr = COLORS[tb.colorIdx]
            local cx = ox + (tb.col - 1) * CELL_SIZE
            local fromY = oy + (tb.fromRow - 1) * CELL_SIZE
            local toY   = oy + (tb.toRow - 1) * CELL_SIZE
            local curY  = fromY + (toY - fromY) * eased

            -- 拖尾
            local trailLen = math.abs(toY - fromY) * 0.15 * (1.0 - t)
            local trailDir = (toY > fromY) and -1 or 1
            if trailLen > 1 then
                nvgBeginPath(nvg)
                nvgRect(nvg, cx + 3, curY + (trailDir < 0 and (CELL_SIZE) or (-trailLen)),
                    CELL_SIZE - 6, trailLen)
                nvgFillColor(nvg, nvgRGBA(clr[1], clr[2], clr[3], math.floor(80 * (1.0 - t))))
                nvgFill(nvg)
            end

            -- 方块本体（像素风格，稍亮）
            drawPixelBlock(nvg, cx, math.floor(curY), CELL_SIZE,
                math.min(255, clr[1] + 60),
                math.min(255, clr[2] + 60),
                math.min(255, clr[3] + 60), 255)
        end
    end

    -- 传送控制阶段的可移动方块
    if animState == "teleport_control" and #teleCtrlBlocks > 0 then
        for _, b in ipairs(teleCtrlBlocks) do
            local clr = COLORS[b.colorIdx]
            local cx = ox + (b.col - 1) * CELL_SIZE
            local cy = oy + (b.row - 1) * CELL_SIZE
            -- 脉冲效果
            local pulse = math.abs(math.sin(gameTime_ * 6)) * 0.3 + 0.7
            drawPixelBlock(nvg, cx, cy, CELL_SIZE,
                math.min(255, math.floor(clr[1] * pulse + 80 * (1 - pulse))),
                math.min(255, math.floor(clr[2] * pulse + 80 * (1 - pulse))),
                math.min(255, math.floor(clr[3] * pulse + 80 * (1 - pulse))), 255)
            -- 白色边框高亮
            nvgBeginPath(nvg)
            nvgRect(nvg, cx + 0.5, cy + 0.5, CELL_SIZE - 1, CELL_SIZE - 1)
            nvgStrokeColor(nvg, nvgRGBA(255, 255, 255, math.floor(120 * pulse)))
            nvgStrokeWidth(nvg, 1.0)
            nvgStroke(nvg)
        end
    end

    -- 当前方块
    if curType > 0 then
        local cells = getPieceCells(curType, curRot, curCol, curRow)
        local clr = COLORS[curType]
        for _, cell in ipairs(cells) do
            local cx = ox + (cell.col - 1) * CELL_SIZE
            local cy = oy + (cell.row - 1) * CELL_SIZE
            drawPixelBlock(nvg, cx, cy, CELL_SIZE, clr[1], clr[2], clr[3], clr[4])
        end

        -- 方向指示（大箭头 + 呼吸动画）
        if not dirChosen then
            local arrowMidX = ox + BOARD_W / 2
            local pulse = 0.7 + 0.3 * math.sin(gameTime_ * 5)  -- 呼吸脉冲
            local arrowH = math.floor(CELL_SIZE * 3.5)   -- 箭头总高度
            local arrowW = math.floor(CELL_SIZE * 2.5)   -- 箭头三角宽度
            local shaftW = math.floor(CELL_SIZE * 0.8)   -- 箭杆宽度
            local shaftH = math.floor(arrowH * 0.45)     -- 箭杆高度

            if curDir == DIR_UP then
                -- 向上箭头，从中线出发向上
                local tipY = centerY - arrowH
                local baseY = centerY - (arrowH - shaftH) -- 三角底边
                local ar, ag, ab = 80, 180, 255
                local aa = math.floor(pulse * 220)
                -- 三角形箭头
                nvgBeginPath(nvg)
                nvgMoveTo(nvg, arrowMidX, tipY)
                nvgLineTo(nvg, arrowMidX - arrowW / 2, baseY)
                nvgLineTo(nvg, arrowMidX + arrowW / 2, baseY)
                nvgClosePath(nvg)
                nvgFillColor(nvg, nvgRGBA(ar, ag, ab, aa))
                nvgFill(nvg)
                -- 箭杆
                nvgBeginPath(nvg)
                nvgRect(nvg, arrowMidX - shaftW / 2, baseY, shaftW, shaftH)
                nvgFillColor(nvg, nvgRGBA(ar, ag, ab, math.floor(aa * 0.7)))
                nvgFill(nvg)
            else
                -- 向下箭头，从中线出发向下
                local tipY = centerY + arrowH
                local baseY = centerY + (arrowH - shaftH)  -- 三角顶边
                local ar, ag, ab = 255, 160, 80
                local aa = math.floor(pulse * 220)
                -- 三角形箭头
                nvgBeginPath(nvg)
                nvgMoveTo(nvg, arrowMidX, tipY)
                nvgLineTo(nvg, arrowMidX - arrowW / 2, baseY)
                nvgLineTo(nvg, arrowMidX + arrowW / 2, baseY)
                nvgClosePath(nvg)
                nvgFillColor(nvg, nvgRGBA(ar, ag, ab, aa))
                nvgFill(nvg)
                -- 箭杆
                nvgBeginPath(nvg)
                nvgRect(nvg, arrowMidX - shaftW / 2, centerY, shaftW, shaftH)
                nvgFillColor(nvg, nvgRGBA(ar, ag, ab, math.floor(aa * 0.7)))
                nvgFill(nvg)
            end
        end
    end

    -- ── 暂停菜单覆盖层 ──
    if gameState == "paused" then
        -- 半透明黑色遮罩
        nvgBeginPath(nvg)
        nvgRect(nvg, ox, oy, BOARD_W, BOARD_H)
        nvgFillColor(nvg, nvgRGBA(0, 0, 0, 180))
        nvgFill(nvg)

        local midX = ox + BOARD_W / 2
        local midY = oy + BOARD_H / 2

        -- 标题 "PAUSED"
        nvgFontFace(nvg, "sans")
        nvgTextAlign(nvg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFontSize(nvg, 20)
        nvgFillColor(nvg, nvgRGBA(220, 220, 240, 255))
        nvgText(nvg, midX, midY - 70, "PAUSED")

        -- 菜单项
        local labelsCN = { "返回游戏", "重新开始", "切换滤镜" }
        local startY = midY - 24
        local gap = 28

        for i, item in ipairs(PAUSE_ITEMS) do
            local iy = startY + (i - 1) * gap
            local selected = (i == pauseMenuIndex_)

            if selected then
                -- 选中项高亮背景
                local bgW = BOARD_W * 0.7
                nvgBeginPath(nvg)
                nvgRoundedRect(nvg, midX - bgW / 2, iy - 11, bgW, 22, 2)
                nvgFillColor(nvg, nvgRGBA(180, 40, 40, 160))
                nvgFill(nvg)
            end

            nvgFontFace(nvg, "zpix")
            nvgFontSize(nvg, 16)
            nvgTextAlign(nvg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

            if selected then
                nvgFillColor(nvg, nvgRGBA(255, 255, 255, 255))
            else
                nvgFillColor(nvg, nvgRGBA(180, 60, 60, 255))
            end

            local text
            if item == "FILTER" and selected then
                text = "◀ " .. Filters.getName() .. " ▶"
            elseif item == "FILTER" and Filters.getUnlocked() <= 1 then
                text = "切换滤镜 🔒"
            else
                text = labelsCN[i]
            end

            nvgText(nvg, midX, iy, text)
        end

        -- ── 进度区域 ──
        local progY = startY + #PAUSE_ITEMS * gap + 20
        local unlocked = Filters.getUnlocked()
        local total = Filters.getTotal()

        -- "✦ PROGRESS" 标题
        nvgFontFace(nvg, "sans")
        nvgFontSize(nvg, 12)
        nvgTextAlign(nvg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(nvg, nvgRGBA(255, 80, 80, 255))
        nvgText(nvg, midX, progY, "* PROGRESS")

        -- 累计分数 / 下一解锁门槛
        progY = progY + 20
        nvgFontFace(nvg, "sans")
        nvgFontSize(nvg, 16)
        nvgFillColor(nvg, nvgRGBA(220, 220, 240, 255))
        local curTotal = totalScore_ + score  -- 含本局进行中的分数
        if unlocked >= total then
            nvgText(nvg, midX, progY, string.format("%d ALL", curTotal))
        else
            local nextGoal = unlocked * UNLOCK_COST
            nvgText(nvg, midX, progY, string.format("%d / %d", curTotal, nextGoal))
        end

        -- 进度条
        progY = progY + 18
        local barW = BOARD_W * 0.6
        local barH = 8
        local barX = midX - barW / 2

        -- 背景条
        nvgBeginPath(nvg)
        nvgRoundedRect(nvg, barX, progY, barW, barH, 2)
        nvgFillColor(nvg, nvgRGBA(220, 220, 240, 200))
        nvgFill(nvg)

        -- 填充条
        local progress
        if unlocked >= total then
            progress = 1.0
        else
            local nextGoal = unlocked * UNLOCK_COST
            local prevGoal = (unlocked - 1) * UNLOCK_COST
            progress = math.min(1.0, (curTotal - prevGoal) / (nextGoal - prevGoal))
        end
        if progress > 0 then
            nvgBeginPath(nvg)
            nvgRoundedRect(nvg, barX, progY, barW * progress, barH, 2)
            nvgFillColor(nvg, nvgRGBA(220, 50, 50, 255))
            nvgFill(nvg)
        end

        -- 已解锁 / 总数 提示
        progY = progY + 18
        nvgFontFace(nvg, "zpix")
        nvgFontSize(nvg, 12)
        nvgFillColor(nvg, nvgRGBA(140, 140, 160, 180))
        nvgTextAlign(nvg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgText(nvg, midX, progY, string.format("滤镜 %d/%d 已解锁", unlocked, total))
    end

    -- Game Over 覆盖层（NanoVG 绘制）
    if gameState == "gameover" then
        -- 半透明黑色遮罩
        nvgBeginPath(nvg)
        nvgRect(nvg, ox, oy, BOARD_W, BOARD_H)
        nvgFillColor(nvg, nvgRGBA(0, 0, 0, 160))
        nvgFill(nvg)

        local midX = ox + BOARD_W / 2
        local midY = oy + BOARD_H / 2

        -- GAME OVER 文字
        nvgFontFace(nvg, "sans")
        nvgTextAlign(nvg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFontSize(nvg, 22)
        nvgFillColor(nvg, nvgRGBA(255, 80, 80, 255))
        nvgText(nvg, midX, midY - 36, "GAME OVER")

        -- 最终分数
        nvgFontSize(nvg, 14)
        nvgFillColor(nvg, nvgRGBA(200, 200, 220, 255))
        nvgText(nvg, midX, midY + 4,
            string.format("Score:%d Lv:%d",
                math.floor(score), math.floor(level)))

        -- 重启提示（用 zpix 显示中文）
        nvgFontFace(nvg, "zpix")
        nvgFontSize(nvg, 16)
        nvgFillColor(nvg, nvgRGBA(180, 180, 200, 200))
        nvgText(nvg, midX, midY + 30, "按R/点击重来")
    end

    -- 标题屏覆盖层
    if gameState == "title" then
        -- 全棋盘半透明遮罩
        nvgBeginPath(nvg)
        nvgRect(nvg, ox, oy, BOARD_W, BOARD_H)
        nvgFillColor(nvg, nvgRGBA(8, 8, 18, 200))
        nvgFill(nvg)

        local midX = ox + BOARD_W / 2
        local midY = oy + BOARD_H / 2

        -- 拖影动画绘制标题
        if titleTrails_ then
            -- 动态设置绝对坐标（相对偏移 + midX/midY）
            for _, trail in ipairs(titleTrails_) do
                trail.x = midX + trail._relX
                trail.y = midY + trail._relY
            end
            Anim.drawAll(nvg, titleTrails_)
        end

        -- 闪烁提示（用 zpix 显示中文）
        local blink = math.floor(gameTime_ * 2.5) % 2  -- 2.5Hz 闪烁
        if blink == 0 then
            nvgFontFace(nvg, "zpix")
            nvgFontSize(nvg, 16)
            nvgFillColor(nvg, nvgRGBA(200, 200, 220, 220))
            nvgText(nvg, midX, midY + 30, "点击/回车开始")
        end
    end

    -- 引导层覆盖
    if tutorial_.active and tutorial_.step >= 1 and tutorial_.step <= #TUTORIAL_STEPS then
        local step = TUTORIAL_STEPS[tutorial_.step]
        local alpha = math.min(tutorial_.fadeIn * 4, 1.0)  -- 0.25s 淡入
        local a = math.floor(alpha * 255)

        -- 半透明遮罩
        nvgBeginPath(nvg)
        nvgRect(nvg, ox, oy, BOARD_W, BOARD_H)
        nvgFillColor(nvg, nvgRGBA(5, 5, 15, math.floor(alpha * 210)))
        nvgFill(nvg)

        local midX = ox + BOARD_W / 2
        local midY = oy + BOARD_H / 2

        nvgFontFace(nvg, "zpix")
        nvgTextAlign(nvg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

        -- 步骤指示器 "1/5"
        nvgFontSize(nvg, 12)
        nvgFillColor(nvg, nvgRGBA(120, 120, 140, a))
        nvgText(nvg, midX, oy + 14, tutorial_.step .. "/" .. #TUTORIAL_STEPS)

        -- 标题 — 像素风金色
        nvgFontSize(nvg, 24)
        nvgFillColor(nvg, nvgRGBA(255, 220, 80, a))
        nvgText(nvg, midX, midY - 60, step.title)

        -- 标题下划线
        local titleW = 80
        nvgBeginPath(nvg)
        nvgRect(nvg, midX - titleW / 2, midY - 44, titleW, 1)
        nvgFillColor(nvg, nvgRGBA(255, 220, 80, math.floor(alpha * 120)))
        nvgFill(nvg)

        -- 说明文字
        nvgFontSize(nvg, 14)
        local lineH = 20
        local startY = midY - 18
        for i, line in ipairs(step.lines) do
            if line ~= "" then
                nvgFillColor(nvg, nvgRGBA(220, 220, 240, a))
                nvgText(nvg, midX, startY + (i - 1) * lineH, line)
            end
        end

        -- 底部提示 — 闪烁
        local hintBlink = math.floor(gameTime_ * 2) % 2
        if hintBlink == 0 then
            nvgFontSize(nvg, 14)
            nvgFillColor(nvg, nvgRGBA(180, 220, 255, math.floor(alpha * 200)))
            nvgText(nvg, midX, oy + BOARD_H - 18, step.hint)
        end

        -- 小箭头装饰（标题两侧）
        nvgFontSize(nvg, 14)
        nvgFillColor(nvg, nvgRGBA(0, 240, 240, math.floor(alpha * 180)))
        local arrowBounce = math.sin(gameTime_ * 4) * 2
        nvgText(nvg, midX - 60 - arrowBounce, midY - 60, "▸")
        nvgText(nvg, midX + 60 + arrowBounce, midY - 60, "◂")
    end

    -- 滤镜名称指示器（棋盘右上角，bypass 保护不受滤镜影响）
    Filters.bypass(function()
        local fIdx, fTotal = Filters.getInfo()
        if fIdx > 1 then  -- 非 Original 时才显示
            nvgFontFace(nvg, "zpix")
            nvgFontSize(nvg, 8)
            nvgTextAlign(nvg, NVG_ALIGN_RIGHT + NVG_ALIGN_TOP)
            nvgFillColor(nvg, nvgRGBA(180, 180, 200, 160))
            nvgText(nvg, ox + BOARD_W - 4, oy + 4,
                string.format("[%d/%d] %s", fIdx, fTotal, Filters.getName()))
        end
    end)

    -- CRT 扫描线效果（每隔 3px 画 1px 暗线，更明显）
    nvgFillColor(nvg, nvgRGBA(0, 0, 0, 70))
    for sy = 0, BOARD_H - 1, 3 do
        nvgBeginPath(nvg)
        nvgRect(nvg, ox, oy + sy, BOARD_W, 1)
        nvgFill(nvg)
    end

    -- 消行粒子效果
    for _, p in ipairs(particles_) do
        local alpha = 1.0 - (p.life / p.maxLife)
        local px = ox + p.gx * CELL_SIZE
        local py = oy + p.gy * CELL_SIZE
        local sz = p.size * (0.5 + alpha * 0.5)  -- 逐渐缩小
        nvgBeginPath(nvg)
        nvgRect(nvg, px - sz / 2, py - sz / 2, sz, sz)
        nvgFillColor(nvg, nvgRGBA(p.r, p.g, p.b, math.floor(alpha * 255)))
        nvgFill(nvg)
    end
end

-- ============================================================================
-- 渲染 - 方块预览 Widget
-- ============================================================================

local PREVIEW_CELL = 12  -- 预览格子大小（比棋盘格小）
local PREVIEW_SIZE = PREVIEW_CELL * 5  -- 5×5 格子区域

local NextPreview = UI.Widget:Extend("NextPreview")

function NextPreview:Init(props)
    props = props or {}
    props.width  = PREVIEW_SIZE
    props.height = PREVIEW_SIZE
    UI.Widget.Init(self, props)
end

function NextPreview:Render(nvg)
    local l = self:GetAbsoluteLayout()
    local ox = math.floor(l.x)
    local oy = math.floor(l.y)

    -- 获取下一个方块
    local nextType = peekNextType()
    if nextType and nextType > 0 then
        local shape = TETROMINOES[nextType][1]  -- 第一旋转态
        local clr = COLORS[nextType]

        -- 计算方块包围盒，居中绘制
        local minC, maxC, minR, maxR = 9999, -9999, 9999, -9999
        for _, off in ipairs(shape) do
            if off[1] < minC then minC = off[1] end
            if off[1] > maxC then maxC = off[1] end
            if off[2] < minR then minR = off[2] end
            if off[2] > maxR then maxR = off[2] end
        end
        local shapeW = (maxC - minC + 1) * PREVIEW_CELL
        local shapeH = (maxR - minR + 1) * PREVIEW_CELL
        local startX = ox + (PREVIEW_SIZE - shapeW) / 2 - minC * PREVIEW_CELL
        local startY = oy + (PREVIEW_SIZE - shapeH) / 2 - minR * PREVIEW_CELL

        for _, off in ipairs(shape) do
            local cx = startX + off[1] * PREVIEW_CELL
            local cy = startY + off[2] * PREVIEW_CELL
            drawPixelBlock(nvg, cx, cy, PREVIEW_CELL, clr[1], clr[2], clr[3], clr[4])
        end
    end
end

-- ============================================================================
-- UI 构建 - 像素风格按钮 + 三列布局
-- ============================================================================

--- 像素风格按钮 Widget（贴图渲染）
local PixelButton = UI.Widget:Extend("PixelButton")

function PixelButton:Init(props)
    props = props or {}
    self._label = props.label or ""
    self._pressed = false
    UI.Widget.Init(self, props)
end

function PixelButton:SetText(text)
    self._label = text
end

function PixelButton:OnPointerDown(event)
    if event and event:IsPrimaryAction() then
        self._pressed = true
    end
end

function PixelButton:OnPointerUp(event)
    if event and event:IsPrimaryAction() then
        self._pressed = false
    end
end

function PixelButton:OnClick(event)
    if self.props.onClick then
        self.props.onClick(self, event)
    end
end

function PixelButton:Render(nvg)
    local l = self:GetAbsoluteLayout()
    if not l or not l.w or not l.h then return end
    local bx, by = math.floor(l.x or 0), math.floor(l.y or 0)
    local bw, bh = math.floor(l.w), math.floor(l.h)
    if bw <= 0 or bh <= 0 then return end

    local pressed = self._pressed
    local rd = math.max(4, math.floor(bw * 0.12))  -- 圆角

    -- 按钮底色（SNES 深蓝灰风格）
    local bgR, bgG, bgB = 45, 55, 75
    if pressed then bgR, bgG, bgB = 30, 38, 52 end

    -- 外边框（深色描边）
    nvgBeginPath(nvg)
    nvgRoundedRect(nvg, bx, by, bw, bh, rd)
    nvgFillColor(nvg, nvgRGBA(15, 18, 25, 255))
    nvgFill(nvg)

    -- 按钮主体（内缩 2px）
    local inset = 2
    nvgBeginPath(nvg)
    nvgRoundedRect(nvg, bx + inset, by + inset, bw - inset * 2, bh - inset * 2, rd - 1)
    nvgFillColor(nvg, nvgRGBA(bgR, bgG, bgB, 255))
    nvgFill(nvg)

    -- 高光（上半部分，未按下时）
    if not pressed then
        local hlPaint = nvgLinearGradient(nvg, bx, by + inset, bx, by + bh * 0.5,
            nvgRGBA(255, 255, 255, 40), nvgRGBA(255, 255, 255, 0))
        nvgBeginPath(nvg)
        nvgRoundedRect(nvg, bx + inset, by + inset, bw - inset * 2, bh * 0.5, rd - 1)
        nvgFillPaint(nvg, hlPaint)
        nvgFill(nvg)
    end

    -- 按下时内凹阴影
    if pressed then
        local shPaint = nvgLinearGradient(nvg, bx, by + inset, bx, by + inset + 6,
            nvgRGBA(0, 0, 0, 80), nvgRGBA(0, 0, 0, 0))
        nvgBeginPath(nvg)
        nvgRoundedRect(nvg, bx + inset, by + inset, bw - inset * 2, bh - inset * 2, rd - 1)
        nvgFillPaint(nvg, shPaint)
        nvgFill(nvg)
    end

    -- 文字标签
    if self._label and self._label ~= "" then
        local fontSize = math.max(10, math.floor(bw * 0.32))
        nvgFontFace(nvg, "zpix")
        nvgFontSize(nvg, fontSize)
        nvgTextAlign(nvg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        local ty = by + bh / 2 + (pressed and 1 or 0)
        -- 文字阴影
        nvgFillColor(nvg, nvgRGBA(0, 0, 0, 180))
        nvgText(nvg, bx + bw / 2 + 1, ty + 1, self._label)
        -- 文字主色
        nvgFillColor(nvg, nvgRGBA(230, 235, 245, 255))
        nvgText(nvg, bx + bw / 2, ty, self._label)
    end
end

-- 按钮文字标签映射
local BTN_LABELS = {
    down   = "▼",
    left   = "◀",
    right  = "▶",
    rotate = "转",
    flip   = "翻[F]",
}

local function makeBtn(btnKey, onPress)
    return PixelButton {
        label = BTN_LABELS[btnKey] or btnKey,
        width = "85%",
        maxWidth = 90,
        aspectRatio = 1,
        onClick = function(self) onPress() end,
    }
end

local function createLeftPanel()
    -- 方块预览
    nextPreviewRef_ = NextPreview { id = "nextPreview" }

    -- 分数标签
    scoreLabelRef_ = UI.Label {
        text = "0",
        fontSize = 16,
        fontColor = { 255, 255, 255, 255 },
    }
    levelLabelRef_ = UI.Label {
        text = "Lv1",
        fontSize = 12,
        fontColor = { 180, 220, 255, 255 },
    }
    comboLabelRef_ = UI.Label {
        text = "",
        fontSize = 14,
        fontColor = { 255, 220, 80, 255 },
    }

    return UI.Panel {
        width = "25%",
        minWidth = 55,
        maxWidth = 160,
        height = "100%",
        justifyContent = "space-between",
        alignItems = "flex-end",         -- 靠右对齐，紧贴棋盘
        paddingTop = 12,
        paddingBottom = 20,
        paddingRight = 6,
        children = {
            -- 上方：标题 + 分数（SNES 金边框风格）
            UI.Panel {
                width = "100%",
                alignItems = "center",
                gap = 6,
                children = {
                    -- 标题面板
                    PixelInfoPanel {
                        width = "90%",
                        maxWidth = 100,
                        paddingTop = 6,
                        paddingBottom = 6,
                        paddingLeft = 4,
                        paddingRight = 4,
                        alignItems = "center",
                        borderColor = { 180, 60, 60 },   -- 红色边框
                        bgColor = { 40, 10, 10, 220 },
                        children = {
                            UI.Label { text = "RE", fontSize = 22, fontColor = { 255, 80, 80, 255 } },
                            UI.Label { text = "Flip", fontSize = 14, fontColor = { 255, 180, 100, 255 } },
                        },
                    },
                    -- 分数面板
                    PixelInfoPanel {
                        title = "SCORE",
                        width = "90%",
                        maxWidth = 100,
                        paddingTop = 14,
                        paddingBottom = 6,
                        paddingLeft = 4,
                        paddingRight = 4,
                        alignItems = "center",
                        gap = 2,
                        children = {
                            scoreLabelRef_,
                            levelLabelRef_,
                            comboLabelRef_,
                        },
                    },
                    -- 预览面板
                    PixelInfoPanel {
                        title = "NEXT",
                        width = "90%",
                        maxWidth = 100,
                        paddingTop = 14,
                        paddingBottom = 6,
                        paddingLeft = 4,
                        paddingRight = 4,
                        alignItems = "center",
                        children = {
                            nextPreviewRef_,
                        },
                    },
                },
            },
            -- 下方控制键
            UI.Panel {
                width = "100%",
                alignItems = "center",
                gap = 8,
                children = {
                    makeBtn("down", function()
                        if gameState == "title" then startGame(); return end
                        if gameState == "gameover" then restartGame(); return end
                        confirmDirection()
                        dropOneRow()
                    end),
                    makeBtn("left", function()
                        if gameState == "title" then startGame(); return end
                        if animState == "teleport_control" then moveTeleCtrl(-1)
                        else movePiece(-1, 0) end
                    end),
                },
            },
        },
    }
end

local function createRightPanel()
    flipBtnRef_ = nil  -- 先清空

    local flipBtn = PixelButton {
        id = "flipBtn",
        label = BTN_LABELS.flip,
        width = "85%",
        maxWidth = 90,
        aspectRatio = 1,
        onClick = function(self)
            if gameState == "title" then startGame(); return end
            flipDirection()
        end,
    }
    flipBtnRef_ = flipBtn

    -- 下一方向标签
    nextDirLabelRef_ = UI.Label {
        text = "▼",
        fontSize = 26,
        fontColor = { 255, 160, 80, 255 },
    }
    -- 翻转倒计时标签
    flipCountLabelRef_ = UI.Label {
        text = tostring(FLIP_FORCE_THRESHOLD),
        fontSize = 16,
        fontColor = { 180, 180, 200, 255 },
    }

    return UI.Panel {
        width = "25%",
        minWidth = 55,
        maxWidth = 160,
        height = "100%",
        justifyContent = "space-between",
        alignItems = "flex-start",       -- 靠左对齐，紧贴棋盘
        paddingTop = 12,
        paddingBottom = 20,
        paddingLeft = 6,
        children = {
            -- 上方：FLIP 按钮 + 方向/倒计时面板
            UI.Panel {
                width = "100%",
                alignItems = "center",
                gap = 6,
                children = {
                    flipBtn,
                    -- 下一方向 + 翻转倒计时
                    PixelInfoPanel {
                        title = "NEXT DIR",
                        width = "90%",
                        maxWidth = 100,
                        paddingTop = 14,
                        paddingBottom = 4,
                        paddingLeft = 4,
                        paddingRight = 4,
                        alignItems = "center",
                        gap = 2,
                        borderColor = { 100, 160, 200 },  -- 蓝色边框
                        bgColor = { 10, 20, 35, 220 },
                        children = {
                            nextDirLabelRef_,
                            UI.Label { text = "FLIP IN", fontSize = 10, fontColor = { 120, 120, 150, 255 } },
                            flipCountLabelRef_,
                        },
                    },
                    -- 暂停按钮（手机端用）
                    PixelButton {
                        label = "暂停",
                        width = "70%",
                        maxWidth = 70,
                        aspectRatio = 1,
                        onClick = function(self)
                            if gameState == "playing" and animState == "none" then
                                gameState = "paused"
                                pauseMenuIndex_ = 1
                            end
                        end,
                    },
                },
            },
            -- 下方控制键
            UI.Panel {
                width = "100%",
                alignItems = "center",
                gap = 8,
                children = {
                    makeBtn("rotate", function()
                        if gameState == "title" then startGame(); return end
                        rotatePiece()
                    end),
                    makeBtn("right", function()
                        if gameState == "title" then startGame(); return end
                        if animState == "teleport_control" then moveTeleCtrl(1)
                        else movePiece(1, 0) end
                    end),
                },
            },
        },
    }
end

local function CreateUI()
    uiRoot_ = UI.Panel {
        id = "root",
        width = "100%",
        height = "100%",
        backgroundColor = { 20, 45, 35, 255 },
        children = {
            -- 装饰背景（绝对定位，铺满全屏）
            BackgroundImage { src = "image/edited_bg_morning_no_sun_20260328151103.png" },
            UI.SafeAreaView {
                width = "100%",
                height = "100%",
                flexShrink = 1,
                flexDirection = "row",
                justifyContent = "center",
                alignItems = "center",
                children = {
                    createLeftPanel(),
                    -- 棋盘居中
                    UI.Panel {
                        flexGrow = 1,
                        height = "100%",
                        justifyContent = "center",
                        alignItems = "center",
                        children = {
                            GameBoard { id = "gameBoard" },
                        },
                    },
                    createRightPanel(),
                },
            },
        },
    }
    UI.SetRoot(uiRoot_)
    log("UI created (side layout)")
end

-- ============================================================================
-- 事件处理
-- ============================================================================

--- 根据等级计算下落间隔
local function getDropInterval()
    -- 从 0.8s 逐级加速，最低 0.1s
    return math.max(0.1, DROP_INTERVAL - (level - 1) * 0.05)
end

---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType, eventData)
    local dt = eventData["TimeStep"]:GetFloat()
    gameTime_ = gameTime_ + dt

    -- 标题拖影动画更新
    if titleTrails_ and gameState == "title" then
        Anim.updateAll(titleTrails_, dt)
    end

    -- 引导层淡入更新
    if tutorial_.active then
        tutorial_.fadeIn = tutorial_.fadeIn + dt
    end

    -- 震屏更新
    if shakeTimer_ < shakeDuration_ then
        shakeTimer_ = shakeTimer_ + dt
    end

    -- 连击闪绿计时
    if comboFlashTimer_ > 0 then
        comboFlashTimer_ = comboFlashTimer_ - dt
    end

    -- 粒子更新
    local i = 1
    while i <= #particles_ do
        local p = particles_[i]
        p.life = p.life + dt
        if p.life >= p.maxLife then
            table.remove(particles_, i)
        else
            p.gx = p.gx + p.vx * dt
            p.gy = p.gy + p.vy * dt
            p.vy = p.vy + 15 * dt  -- 重力（格子/秒²）
            i = i + 1
        end
    end

    -- 动画更新
    if animState == "clearing" then
        animTimer = animTimer + dt
        if animTimer >= ANIM_CLEAR_DURATION then
            onClearAnimDone()
        end
        return  -- 动画期间不处理下落
    elseif animState == "teleporting" then
        animTimer = animTimer + dt
        if animTimer >= ANIM_TELEPORT_DURATION then
            onTeleportAnimDone()
        end
        return
    elseif animState == "teleport_control" then
        -- 传送方块自动快速下落
        teleCtrlDropTimer = teleCtrlDropTimer + dt
        if teleCtrlDropTimer >= TELE_CTRL_DROP_INTERVAL then
            teleCtrlDropTimer = teleCtrlDropTimer - TELE_CTRL_DROP_INTERVAL
            if not dropTeleCtrlOneStep() then
                lockTeleCtrlBlocks()
            end
        end
        return
    end

    if gameState ~= "playing" then return end

    -- 只在方向确认后才自动下落
    if dirChosen then
        dropTimer = dropTimer + dt
        local interval = getDropInterval()
        if dropTimer >= interval then
            dropTimer = dropTimer - interval
            dropOneRow()
        end
    end
end

---@param eventType string
---@param eventData KeyDownEventData
function HandleKeyDown(eventType, eventData)
    local key = eventData["Key"]:GetInt()

    -- 引导层激活时：任意键推进
    if tutorial_.active then
        advanceTutorial()
        return
    end

    -- 标题屏：任意键开始
    if gameState == "title" then
        startGame()
        return
    end

    -- Game Over 时：R 或 Enter 重启
    if gameState == "gameover" then
        if key == KEY_R or key == KEY_RETURN then
            restartGame()
        end
        return
    end

    -- ── 暂停菜单 ──
    if gameState == "paused" then
        if key == KEY_UP or key == KEY_W then
            pauseMenuIndex_ = pauseMenuIndex_ - 1
            if pauseMenuIndex_ < 1 then pauseMenuIndex_ = #PAUSE_ITEMS end
        elseif key == KEY_DOWN or key == KEY_S then
            pauseMenuIndex_ = pauseMenuIndex_ + 1
            if pauseMenuIndex_ > #PAUSE_ITEMS then pauseMenuIndex_ = 1 end
        elseif key == KEY_LEFT or key == KEY_A then
            -- 选中 FILTER 时切换上一个滤镜
            if PAUSE_ITEMS[pauseMenuIndex_] == "FILTER" then
                Filters.prev()
            end
        elseif key == KEY_RIGHT or key == KEY_D then
            -- 选中 FILTER 时切换下一个滤镜
            if PAUSE_ITEMS[pauseMenuIndex_] == "FILTER" then
                Filters.next()
            end
        elseif key == KEY_RETURN then
            local item = PAUSE_ITEMS[pauseMenuIndex_]
            if item == "RESUME" then
                gameState = "playing"
            elseif item == "RETRY" then
                gameState = "playing"
                restartGame()
            elseif item == "FILTER" then
                -- Enter on filter = resume
                gameState = "playing"
            end
        elseif key == KEY_ESCAPE then
            gameState = "playing"
        end
        return
    end

    -- ── playing 状态下 Enter 暂停 ──
    if key == KEY_RETURN or key == KEY_ESCAPE then
        if gameState == "playing" and animState == "none" then
            gameState = "paused"
            pauseMenuIndex_ = 1
            return
        end
    end

    -- 传送方块控制阶段：只允许左右移动
    if animState == "teleport_control" then
        if key == KEY_LEFT or key == KEY_A then
            moveTeleCtrl(-1)
        elseif key == KEY_RIGHT or key == KEY_D then
            moveTeleCtrl(1)
        end
        return
    end

    -- 其他动画阶段：忽略输入
    if animState ~= "none" then return end

    if key == KEY_LEFT or key == KEY_A then
        movePiece(-1, 0)
    elseif key == KEY_RIGHT or key == KEY_D then
        movePiece(1, 0)
    elseif key == KEY_UP or key == KEY_W then
        rotatePiece()
    elseif key == KEY_DOWN or key == KEY_S then
        confirmDirection()
        dropOneRow()
    elseif key == KEY_SPACE then
        hardDrop()
    elseif key == KEY_F then
        flipDirection()
    end
end

-- ============================================================================
-- 入口
-- ============================================================================

function Start()
    graphics.windowTitle = "RE:Flip"

    UI.Init({
        fonts = {
            { family = "sans", weights = {
                normal = "Fonts/PressStart2P.ttf",
            } },
            { family = "zpix", weights = {
                normal = "Fonts/zpix.ttf",
            } },
        },
        scale = UI.Scale.DEFAULT,
    })

    -- 布局完全由 Flexbox 百分比驱动，不再依赖 graphics:GetWidth()/GetHeight() 预算
    -- CELL_SIZE / BOARD_W / BOARD_H 由 GameBoard:Render 从实际布局空间动态计算
    -- 侧面板宽度由 CSS 百分比 + minWidth/maxWidth 控制
    -- 按钮尺寸由 width="90%" + aspectRatio=1 + maxWidth 控制
    log("Layout: fully flexbox-driven, no pre-calculation")

    -- 音效初始化
    audioScene_ = Scene()
    sfxNode_ = audioScene_:CreateChild("SFX")
    SFX.move     = cache:GetResource("Sound", "audio/sfx/sfx_move.ogg")
    SFX.rotate   = cache:GetResource("Sound", "audio/sfx/sfx_rotate.ogg")
    SFX.clear    = cache:GetResource("Sound", "audio/sfx/sfx_clear.ogg")
    SFX.flip     = cache:GetResource("Sound", "audio/sfx/sfx_flip.ogg")
    SFX.gameover = cache:GetResource("Sound", "audio/sfx/sfx_gameover.ogg")
    -- BGM
    local bgmSound = cache:GetResource("Sound", "audio/music_1774708739812.ogg")
    if bgmSound then
        bgmSound.looped = true
        bgmSource_ = sfxNode_:CreateComponent("SoundSource")
        bgmSource_.soundType = "Music"
        bgmSource_.gain = 0.35
        bgmSource_:Play(bgmSound)
    end
    log("SFX loaded: move, rotate, clear, flip, gameover + BGM")

    math.randomseed(os.time())
    initBoard()
    refillBag()
    -- spawnPiece() 延迟到玩家从标题屏开始游戏时调用

    CreateUI()

    SubscribeToEvent("Update", "HandleUpdate")
    SubscribeToEvent("KeyDown", "HandleKeyDown")

    -- 初始化标题拖影动画（需要在 CELL_SIZE 计算之后）
    initTitleTrails()

    -- 安装全屏滤镜（包装 nvgRGBA，所有渲染自动经过滤镜）
    loadProgress()
    Filters.installGlobal()

    log("=== RE:Flip Started ===")
end

function Stop()
    UI.Shutdown()
end
