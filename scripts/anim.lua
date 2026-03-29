-- ============================================================================
-- anim.lua  —  通用 NanoVG 动画工具库
-- ============================================================================
-- 目前包含：
--   ShadowTrail  —  拖影/残影文字滑入动画
--     阴影固定在终点位置，文字从偏移处滑入，产生"拖影"视觉效果
-- ============================================================================

local M = {}

-- ────────────────────────────────────────────────────────────────────────────
-- 缓动函数
-- ────────────────────────────────────────────────────────────────────────────
local function easeOutCubic(t)
    t = t - 1
    return t * t * t + 1
end

local function easeOutQuint(t)
    t = t - 1
    return t * t * t * t * t + 1
end

local function lerp(a, b, t)
    return a + (b - a) * t
end

local function clamp01(t)
    if t < 0 then return 0 end
    if t > 1 then return 1 end
    return t
end

-- ────────────────────────────────────────────────────────────────────────────
-- darkenColor: 将颜色变暗
--   r,g,b  0-255
--   factor 0-1 (0=全黑, 1=原色)
-- ────────────────────────────────────────────────────────────────────────────
local function darkenColor(r, g, b, factor)
    return math.floor(r * factor),
           math.floor(g * factor),
           math.floor(b * factor)
end

-- ============================================================================
-- ShadowTrail  —  拖影文字动画
-- ============================================================================
-- 用法:
--   local trail = Anim.ShadowTrail.new({
--       text     = "RE",
--       font     = "sans",
--       fontSize = 32,
--       color    = {0, 240, 240, 255},   -- RGBA
--       x        = 100,  y = 80,         -- 目标终点坐标
--       offsetX  = -60,  offsetY = 0,    -- 起始偏移（相对终点）
--       duration = 0.8,                  -- 动画时长（秒）
--       delay    = 0.0,                  -- 开始延迟（秒）
--       shadowLayers = 4,                -- 拖影层数
--       darken   = 0.35,                 -- 阴影暗化系数 (0=全黑 1=原色)
--       ease     = "cubic",              -- "cubic" | "quint"
--       align    = NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE,  -- 对齐方式
--   })
--
--   -- 每帧更新时间：
--   trail:update(dt)
--
--   -- 在 NanoVGRender 中绘制（需在 nvgBeginFrame/nvgEndFrame 之间）：
--   trail:draw(nvg)
--
--   -- 重置动画（从头播放）：
--   trail:reset()
--
--   -- 查询是否播放完成：
--   trail:isDone()
-- ============================================================================

local ShadowTrail = {}
ShadowTrail.__index = ShadowTrail

--- 创建拖影动画实例
---@param opts table 配置参数
function ShadowTrail.new(opts)
    local self = setmetatable({}, ShadowTrail)
    self.text        = opts.text or ""
    self.font        = opts.font or "sans"
    self.fontSize    = opts.fontSize or 24
    self.color       = opts.color or {255, 255, 255, 255}  -- {r,g,b,a}
    self.x           = opts.x or 0
    self.y           = opts.y or 0
    self.offsetX     = opts.offsetX or -50
    self.offsetY     = opts.offsetY or 0
    self.duration    = opts.duration or 0.6
    self.delay       = opts.delay or 0.0
    self.shadowLayers = opts.shadowLayers or 4
    self.darken      = opts.darken or 0.35
    self.ease        = opts.ease or "cubic"
    self.align       = opts.align or (NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

    -- 内部状态
    self.elapsed = 0
    self.done    = false
    return self
end

--- 重置动画
function ShadowTrail:reset()
    self.elapsed = 0
    self.done = false
end

--- 更新时间（每帧调用）
function ShadowTrail:update(dt)
    if self.done then return end
    self.elapsed = self.elapsed + dt
    if self.elapsed >= self.delay + self.duration then
        self.done = true
    end
end

--- 查询是否完成
function ShadowTrail:isDone()
    return self.done
end

--- 获取当前进度 0-1
function ShadowTrail:getProgress()
    local t = (self.elapsed - self.delay) / self.duration
    return clamp01(t)
end

--- 绘制（在 nvgBeginFrame/nvgEndFrame 之间调用）
function ShadowTrail:draw(nvg)
    local raw = self:getProgress()
    if raw <= 0 and self.delay > 0 then return end  -- 延迟期间不绘制

    local easeFn = self.ease == "quint" and easeOutQuint or easeOutCubic
    local progress = easeFn(clamp01(raw))

    local r, g, b, a = self.color[1], self.color[2], self.color[3], self.color[4] or 255
    local dr, dg, db = darkenColor(r, g, b, self.darken)

    -- 当前文字位置（从偏移滑向终点）
    local curX = lerp(self.x + self.offsetX, self.x, progress)
    local curY = lerp(self.y + self.offsetY, self.y, progress)

    -- 设置字体
    nvgFontFace(nvg, self.font)
    nvgFontSize(nvg, self.fontSize)
    nvgTextAlign(nvg, self.align)

    -- 绘制拖影层：从终点（阴影端）到当前位置之间插值
    -- 越靠近终点的层越暗/越透明
    local layers = self.shadowLayers
    if layers > 0 and progress < 1.0 then
        for i = 1, layers do
            local frac = i / (layers + 1)  -- 0..1 之间均匀分布
            local sx = lerp(self.x, curX, frac)
            local sy = lerp(self.y, curY, frac)

            -- 越靠近终点（frac 小）→ 越暗越透明
            local layerAlpha = math.floor(a * (0.15 + 0.45 * frac) * (1.0 - progress))
            local lr = math.floor(lerp(dr, r, frac * 0.5))
            local lg = math.floor(lerp(dg, g, frac * 0.5))
            local lb = math.floor(lerp(db, b, frac * 0.5))

            nvgFillColor(nvg, nvgRGBA(lr, lg, lb, layerAlpha))
            nvgText(nvg, sx, sy, self.text)
        end

        -- 终点处的阴影（最暗）
        local shadowAlpha = math.floor(a * 0.5 * (1.0 - progress))
        nvgFillColor(nvg, nvgRGBA(dr, dg, db, shadowAlpha))
        nvgText(nvg, self.x, self.y, self.text)
    end

    -- 绘制主文字（最上层）
    -- 动画完成后显示完全不透明的原色
    local mainAlpha = a
    if raw < 0.1 then
        -- 淡入
        mainAlpha = math.floor(a * (raw / 0.1))
    end
    nvgFillColor(nvg, nvgRGBA(r, g, b, mainAlpha))
    nvgText(nvg, curX, curY, self.text)
end

M.ShadowTrail = ShadowTrail

-- ============================================================================
-- 便捷函数：创建一组拖影动画（带级联延迟）
-- ============================================================================
--- 批量创建拖影动画，每个元素自动递增延迟
---@param items table[] 配置数组，每项同 ShadowTrail.new 的 opts
---@param cascade number 级联延迟间隔（秒），默认 0.15
---@return table[] trails 动画实例数组
function M.createTrailGroup(items, cascade)
    cascade = cascade or 0.15
    local trails = {}
    for i, opts in ipairs(items) do
        opts.delay = (opts.delay or 0) + (i - 1) * cascade
        trails[i] = ShadowTrail.new(opts)
    end
    return trails
end

--- 批量更新
function M.updateAll(trails, dt)
    for _, t in ipairs(trails) do
        t:update(dt)
    end
end

--- 批量绘制
function M.drawAll(nvg, trails)
    for _, t in ipairs(trails) do
        t:draw(nvg)
    end
end

--- 批量重置
function M.resetAll(trails)
    for _, t in ipairs(trails) do
        t:reset()
    end
end

--- 批量查询是否全部完成
function M.allDone(trails)
    for _, t in ipairs(trails) do
        if not t:isDone() then return false end
    end
    return true
end

return M
