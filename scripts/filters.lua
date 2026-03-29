-- ============================================================================
-- RE:Flip 颜色滤镜系统
-- 27 种可热切换的颜色滤镜，用于游戏方块和特效
-- ============================================================================

local M = {}

-- ============================================================
-- 颜色数学工具
-- ============================================================

--- 感知亮度 (ITU BT.601)
local function luminance(r, g, b)
    return 0.299 * r + 0.587 * g + 0.114 * b
end

--- 限制到 0-255 整数
local function clamp(v)
    if v < 0 then return 0 end
    if v > 255 then return 255 end
    return math.floor(v + 0.5)
end

--- 线性插值
local function lerp(a, b, t)
    return a + (b - a) * t
end

--- RGB(0-255) -> HSL(0-1)
local function rgbToHsl(r, g, b)
    r, g, b = r / 255, g / 255, b / 255
    local mx = math.max(r, g, b)
    local mn = math.min(r, g, b)
    local l = (mx + mn) / 2
    if mx == mn then return 0, 0, l end
    local d = mx - mn
    local s = l > 0.5 and d / (2 - mx - mn) or d / (mx + mn)
    local h
    if mx == r then     h = (g - b) / d + (g < b and 6 or 0)
    elseif mx == g then h = (b - r) / d + 2
    else                h = (r - g) / d + 4
    end
    return h / 6, s, l
end

--- HSL(0-1) -> RGB(0-255)
local function hslToRgb(h, s, l)
    if s == 0 then
        local v = clamp(l * 255)
        return v, v, v
    end
    local function hue2rgb(p, q, t)
        if t < 0 then t = t + 1 end
        if t > 1 then t = t - 1 end
        if t < 1 / 6 then return p + (q - p) * 6 * t end
        if t < 1 / 2 then return q end
        if t < 2 / 3 then return p + (q - p) * (2 / 3 - t) * 6 end
        return p
    end
    local q = l < 0.5 and l * (1 + s) or l + s - l * s
    local p = 2 * l - q
    return clamp(hue2rgb(p, q, h + 1 / 3) * 255),
           clamp(hue2rgb(p, q, h) * 255),
           clamp(hue2rgb(p, q, h - 1 / 3) * 255)
end

--- 在调色板中找最近颜色（欧氏距离）
local function nearestPalette(r, g, b, palette)
    local bestDist = math.huge
    local bestR, bestG, bestB = r, g, b
    for _, c in ipairs(palette) do
        local dr, dg, db = r - c[1], g - c[2], b - c[3]
        local dist = dr * dr + dg * dg + db * db
        if dist < bestDist then
            bestDist = dist
            bestR, bestG, bestB = c[1], c[2], c[3]
        end
    end
    return bestR, bestG, bestB
end

--- 将亮度量化为 N 个等级，返回 0-based 索引
local function quantizeLum(r, g, b, levels)
    local lum = luminance(r, g, b) / 255
    local idx = math.floor(lum * levels)
    if idx >= levels then idx = levels - 1 end
    return idx
end

-- ============================================================
-- 滤镜定义
-- ============================================================

local filters = {
    -- 1. Original
    { id = "original", name = "Original",
      transform = function(r, g, b, a) return r, g, b, a end },

    -- 2. Game Boy Classic (DMG-01 4-shade green)
    { id = "gameboy", name = "Game Boy",
      transform = function(r, g, b, a)
        local palette = {
            { 15,  56,  15 },
            { 48,  98,  48 },
            { 139, 172, 15 },
            { 155, 188, 15 },
        }
        local shade = palette[quantizeLum(r, g, b, 4) + 1]
        return shade[1], shade[2], shade[3], a
      end },

    -- 3. Game Boy Pocket (4-shade gray)
    { id = "gbpocket", name = "GB Pocket",
      transform = function(r, g, b, a)
        local shades = { 0, 85, 170, 255 }
        local v = shades[quantizeLum(r, g, b, 4) + 1]
        return v, v, v, a
      end },

    -- 4. Virtual Boy (4-shade red)
    { id = "virtualboy", name = "Virtual Boy",
      transform = function(r, g, b, a)
        local shades = {
            { 0, 0, 0 },
            { 85, 0, 0 },
            { 170, 0, 0 },
            { 255, 0, 0 },
        }
        local shade = shades[quantizeLum(r, g, b, 4) + 1]
        return shade[1], shade[2], shade[3], a
      end },

    -- 5. Sepia
    { id = "sepia", name = "Sepia",
      transform = function(r, g, b, a)
        return clamp(r * 0.393 + g * 0.769 + b * 0.189),
               clamp(r * 0.349 + g * 0.686 + b * 0.168),
               clamp(r * 0.272 + g * 0.534 + b * 0.131), a
      end },

    -- 6. Negative
    { id = "negative", name = "Negative",
      transform = function(r, g, b, a)
        return 255 - r, 255 - g, 255 - b, a
      end },

    -- 7. High Contrast B&W
    { id = "hcbw", name = "Hi-Con B&W",
      transform = function(r, g, b, a)
        local v = luminance(r, g, b) > 100 and 255 or 0
        return v, v, v, a
      end },

    -- 8. Cyberpunk Neon
    { id = "cyberpunk", name = "Cyberpunk",
      transform = function(r, g, b, a)
        local h, s, l = rgbToHsl(r, g, b)
        s = math.min(1.0, s * 1.8 + 0.3)
        l = l * 0.85 + 0.1
        if h > 0.2 and h < 0.45 then
            h = h - 0.08
        elseif h < 0.1 or h > 0.9 then
            h = (h + 0.05) % 1.0
        end
        local nr, ng, nb = hslToRgb(h, s, l)
        return nr, ng, nb, a
      end },

    -- 9. Vaporwave
    { id = "vaporwave", name = "Vaporwave",
      transform = function(r, g, b, a)
        local h, s, l = rgbToHsl(r, g, b)
        h = 0.5 + h * 0.35
        s = math.min(1.0, s * 1.4 + 0.2)
        l = l * 0.8 + 0.15
        local nr, ng, nb = hslToRgb(h, s, l)
        return nr, ng, nb, a
      end },

    -- 10. Matrix
    { id = "matrix", name = "Matrix",
      transform = function(r, g, b, a)
        local intensity = luminance(r, g, b) / 255
        return clamp(intensity * 30),
               clamp(intensity * 255),
               clamp(intensity * 40), a
      end },

    -- 11. Sunset (warm)
    { id = "warm", name = "Sunset",
      transform = function(r, g, b, a)
        return clamp(r * 1.2 + 20),
               clamp(g * 0.95 + 10),
               clamp(b * 0.65), a
      end },

    -- 12. Ice (cool)
    { id = "cool", name = "Ice",
      transform = function(r, g, b, a)
        return clamp(r * 0.65),
               clamp(g * 0.9 + 30),
               clamp(b * 1.2 + 40), a
      end },

    -- 13. Amber CRT
    { id = "amber", name = "Amber CRT",
      transform = function(r, g, b, a)
        local lum = luminance(r, g, b) / 255
        return clamp(lum * 255),
               clamp(lum * 176),
               clamp(lum * 40), a
      end },

    -- 14. CGA 4-Color
    { id = "cga", name = "CGA 4-Color",
      transform = function(r, g, b, a)
        local palette = {
            { 0, 0, 0 },
            { 85, 255, 255 },
            { 255, 85, 255 },
            { 255, 255, 255 },
        }
        local nr, ng, nb = nearestPalette(r, g, b, palette)
        return nr, ng, nb, a
      end },

    -- 15. Pastel
    { id = "pastel", name = "Pastel",
      transform = function(r, g, b, a)
        local lum = luminance(r, g, b)
        return clamp(lerp(r, lum * 0.7 + 180, 0.55)),
               clamp(lerp(g, lum * 0.7 + 180, 0.55)),
               clamp(lerp(b, lum * 0.7 + 180, 0.55)), a
      end },

    -- 16. Neon Noir
    { id = "neonnoir", name = "Neon Noir",
      transform = function(r, g, b, a)
        local h, s, l = rgbToHsl(r, g, b)
        if l < 0.4 then
            l = l * 0.3
            s = s * 0.5
        else
            s = math.min(1.0, s * 2.0)
            l = l * 0.9
        end
        local nr, ng, nb = hslToRgb(h, s, l)
        return nr, ng, nb, a
      end },

    -- 17. Tritanopia (blue-blind)
    { id = "tritanopia", name = "Tritanopia",
      transform = function(r, g, b, a)
        return clamp(r * 0.95 + g * 0.05),
               clamp(g * 0.433 + b * 0.567),
               clamp(g * 0.475 + b * 0.525), a
      end },

    -- 18. Protanopia (red-blind)
    { id = "protanopia", name = "Protanopia",
      transform = function(r, g, b, a)
        return clamp(r * 0.567 + g * 0.433),
               clamp(r * 0.558 + g * 0.442),
               clamp(g * 0.242 + b * 0.758), a
      end },

    -- 19. Deuteranopia (green-blind)
    { id = "deuteranopia", name = "Deuteranopia",
      transform = function(r, g, b, a)
        return clamp(r * 0.625 + g * 0.375),
               clamp(r * 0.7 + g * 0.3),
               clamp(g * 0.3 + b * 0.7), a
      end },

    -- 20. Thermal
    { id = "thermal", name = "Thermal",
      transform = function(r, g, b, a)
        local t = luminance(r, g, b) / 255
        local nr, ng, nb
        if t < 0.25 then
            local s = t / 0.25
            nr, ng, nb = 0, 0, clamp(s * 200)
        elseif t < 0.5 then
            local s = (t - 0.25) / 0.25
            nr, ng, nb = clamp(s * 255), 0, clamp((1 - s) * 200)
        elseif t < 0.75 then
            local s = (t - 0.5) / 0.25
            nr, ng, nb = 255, clamp(s * 255), 0
        else
            local s = (t - 0.75) / 0.25
            nr, ng, nb = 255, 255, clamp(s * 255)
        end
        return nr, ng, nb, a
      end },

    -- 21. Ocean Deep
    { id = "ocean", name = "Ocean Deep",
      transform = function(r, g, b, a)
        local lum = luminance(r, g, b) / 255
        return clamp(lum * 20),
               clamp(lum * 120 + 40),
               clamp(lum * 180 + 60), a
      end },

    -- 22. Lavender
    { id = "lavender", name = "Lavender",
      transform = function(r, g, b, a)
        local h, s, l = rgbToHsl(r, g, b)
        h = 0.78 + (h - 0.78) * 0.2
        s = s * 0.7 + 0.15
        l = l * 0.8 + 0.15
        local nr, ng, nb = hslToRgb(h % 1.0, math.min(1.0, s), math.min(1.0, l))
        return nr, ng, nb, a
      end },

    -- 23. Radioactive
    { id = "radioactive", name = "Radioactive",
      transform = function(r, g, b, a)
        local lum = luminance(r, g, b) / 255
        local intensity = lum * lum
        return clamp(intensity * 80),
               clamp(intensity * 255 + 15),
               clamp(intensity * 20), a
      end },

    -- 24. Burnt
    { id = "burnt", name = "Burnt",
      transform = function(r, g, b, a)
        local lum = luminance(r, g, b) / 255
        local t = lum * 0.7
        return clamp(t * 200 + 30),
               clamp(t * 120 + 10),
               clamp(t * 50), a
      end },

    -- 25. Posterize (6-level)
    { id = "posterize", name = "Posterize",
      transform = function(r, g, b, a)
        local step = 255 / 5
        return clamp(math.floor(r / step + 0.5) * step),
               clamp(math.floor(g / step + 0.5) * step),
               clamp(math.floor(b / step + 0.5) * step), a
      end },

    -- 26. Commodore 64
    { id = "c64", name = "C64",
      transform = function(r, g, b, a)
        local palette = {
            { 0, 0, 0 }, { 255, 255, 255 }, { 136, 0, 0 }, { 170, 255, 238 },
            { 204, 68, 204 }, { 0, 204, 85 }, { 0, 0, 170 }, { 238, 238, 119 },
            { 221, 136, 85 }, { 102, 68, 0 }, { 255, 119, 119 }, { 51, 51, 51 },
            { 119, 119, 119 }, { 170, 255, 102 }, { 0, 136, 255 }, { 187, 187, 187 },
        }
        local nr, ng, nb = nearestPalette(r, g, b, palette)
        return nr, ng, nb, a
      end },

    -- 27. Grayscale
    { id = "grayscale", name = "Grayscale",
      transform = function(r, g, b, a)
        local v = clamp(luminance(r, g, b))
        return v, v, v, a
      end },
}

-- ============================================================
-- 状态
-- ============================================================

local currentIndex = 1
local unlockedCount = 1  -- 已解锁数量（1 = 仅 Original）

-- ============================================================
-- 公共 API
-- ============================================================

--- 对 RGBA 颜色应用当前滤镜
---@param r number 0-255
---@param g number 0-255
---@param b number 0-255
---@param a number 0-255
---@return number, number, number, number
function M.apply(r, g, b, a)
    return filters[currentIndex].transform(r, g, b, a)
end

--- 便捷方法：从 COLORS 表按索引取色并应用滤镜
---@param colorsTable table  COLORS 表
---@param idx number         颜色索引 1-7
---@return table             {r, g, b, a}
function M.getColor(colorsTable, idx)
    local c = colorsTable[idx]
    if not c then return { 128, 128, 128, 255 } end
    local r, g, b, a = M.apply(c[1], c[2], c[3], c[4])
    return { r, g, b, a }
end

--- 切换到下一个已解锁滤镜
function M.next()
    if unlockedCount <= 1 then return end
    currentIndex = (currentIndex % unlockedCount) + 1
end

--- 切换到上一个已解锁滤镜
function M.prev()
    if unlockedCount <= 1 then return end
    currentIndex = ((currentIndex - 2) % unlockedCount) + 1
end

--- 获取当前滤镜名称
---@return string
function M.getName()
    return filters[currentIndex].name
end

--- 获取当前索引和总数
---@return number, number
function M.getInfo()
    return currentIndex, #filters
end

--- 设置已解锁滤镜数量
---@param n number
function M.setUnlocked(n)
    unlockedCount = math.max(1, math.min(n, #filters))
    if currentIndex > unlockedCount then
        currentIndex = 1
    end
end

--- 获取已解锁数量
---@return number
function M.getUnlocked()
    return unlockedCount
end

--- 获取滤镜总数
---@return number
function M.getTotal()
    return #filters
end

-- ============================================================
-- 全屏滤镜：包装全局 nvgRGBA（一次性安装，动态生效）
-- ============================================================

local originalNvgRGBA = nil
local bypassing = false  -- bypass 标记，临时跳过滤镜

--- 一次性安装全局包装（在 Start 中调用一次即可）
function M.installGlobal()
    if originalNvgRGBA then return end  -- 已安装
    originalNvgRGBA = nvgRGBA
    ---@diagnostic disable-next-line: lowercase-global
    nvgRGBA = function(r, g, b, a)
        if currentIndex == 1 or bypassing then
            return originalNvgRGBA(r, g, b, a or 255)
        end
        local fr, fg, fb, fa = filters[currentIndex].transform(r, g, b, a or 255)
        return originalNvgRGBA(fr, fg, fb, fa)
    end
end

--- 在回调内临时跳过滤镜（用于 HUD 指示器等不应被滤镜影响的 UI）
---@param fn function
function M.bypass(fn)
    bypassing = true
    fn()
    bypassing = false
end

return M
