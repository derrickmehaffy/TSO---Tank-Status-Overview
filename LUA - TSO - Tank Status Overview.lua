-- TSO - Tank Status Overview
-- 12-box PA overview dashboard (no umbilical controls)
--
-- FEATURES:
--   - Set up to 12 Pipe Analyzers with custom labels to track exactly what you need
--   - 12 overview boxes (3 columns x 4 rows)
--   - Each box: label, pressure bar + percent, volume bar + percent, temperature
--   - 12 PA assignment dropdowns (1:1 to boxes)(PA 3 is for Box 3 and such)

-- ==================== SURFACES & VIEW ====================

local surfaces = {
    overview = ss.ui.surface("overview"),
    settings = ss.ui.surface("settings"),
}
local s = surfaces.overview
local view = "overview"

local W, H = 480, 272
local size = ss.ui.surface("overview"):size()
if size then
    W = size.w or W
    H = size.h or H
end

local elapsed = 0
local currenttime = 0
local LIVE_REFRESH_TICKS = 6
local BOX_COUNT = 12

local handles = {
    view = nil,
    header = {},
    nav = {},
    footer = {},
    overview = {},
}

-- ==================== CONSTANTS ====================

local LT = ic.enums.LogicType
local LBM = ic.enums.LogicBatchMethod
local hash = ic.hash
local batch_read_name = ic.batch_read_name

-- ==================== PERSISTENT MEMORY MAP ====================

local MEM_PA_PREFAB_BEGIN = 0
local MEM_PA_NAMEHASH_BEGIN = 12
local MEM_LABELHASH_BEGIN = 24
local MEM_LABELSTR_BEGIN = 36
local MEM_PRESSURE_MAX = 144
local MEM_VOLUME_MAX = 145
local MEM_REFRESH_TICKS = 146
local MEM_REG_PREFAB_BEGIN = 147
local MEM_REG_NAMEHASH_BEGIN = 159
local MEM_SAFETY_MARGIN = 171

local LABEL_MAX_CHARS = 24
local LABEL_CHARS_PER_SLOT = 3
local LABEL_DATA_SLOTS = 8
local LABEL_SLOT_STRIDE = 1 + LABEL_DATA_SLOTS

local PA_PREFAB_FILTERS = {
    gas = hash("StructurePipeAnalysizer"),
    liquid = hash("StructureLiquidPipeAnalyzer"),
}

local REG_PREFAB_FILTERS = {
    vanilla = hash("StructureBackPressureRegulator"),
    mirrored = hash("StructureBackPressureRegulatorMirrored"),
    liquid_vanilla = hash("StructureBackLiquidPressureRegulator"),
    liquid_mirrored = hash("StructureBackLiquidPressureRegulatorMirrored"),
}

local REG_SETTING_MAX = 60795  -- hardware ceiling for gas back-pressure regulator Setting (kPa)
local HYSTERESIS_GAP_PCT = 20

local function is_liquid_reg(prefab_hash)
    local p = tonumber(prefab_hash) or 0
    return p == REG_PREFAB_FILTERS.liquid_vanilla or p == REG_PREFAB_FILTERS.liquid_mirrored
end

-- ==================== STATE ====================

local box_labels = {}
local pa_devices = {}
local pa_readings = {}
local settings_subview = "labels"
local pa_picker_idx = nil
local pa_pressure_max_range = 20000
local pa_volume_max_range = 1000

for i = 1, BOX_COUNT do
    box_labels[i] = "Box " .. i
    pa_devices[i] = { prefab = 0, namehash = 0 }
    pa_readings[i] = {
        pressure = nil,
        temperature = nil,
        volume = nil,
        network_fault = nil,
    }
end

local reg_devices = {}
local reg_readings = {}
local reg_state = {}
local reg_picker_idx = nil
local safety_margin_pct = 10
local reg_on_threshold = 0
local reg_off_threshold = 0

for i = 1, BOX_COUNT do
    reg_devices[i] = { prefab = 0, namehash = 0 }
    reg_readings[i] = { on = nil, ratio = nil, setting = nil, error = nil }
    reg_state[i] = "off"
end

-- ==================== COLORS ====================

local C = {
    bg = "#0A0E1A",
    header = "#0C1220",
    panel = "#0F1628",
    panel_light = "#151D30",
    divider = "#1A2540",
    text = "#E2E8F0",
    text_dim = "#64748B",
    text_muted = "#475569",
    accent = "#38BDF8",
    green = "#22C55E",
    yellow = "#EAB308",
    orange = "#F97316",
    red = "#EF4444",
    light_blue = "#38BDF8",
    dark_blue = "#1E3A8A",
    bar_bg = "#1F2937",
}

-- ==================== UI WRITE CACHE ====================

local _ui_state = setmetatable({}, { __mode = "k" })

local function ui_set_props(h, new_props)
    if h == nil then return end
    local s = _ui_state[h]
    if s == nil then s = { props = {}, style = {} }; _ui_state[h] = s end
    local changed = false
    for k, v in pairs(new_props) do
        if s.props[k] ~= v then
            s.props[k] = v
            changed = true
        end
    end
    if changed then
        h:set_props(new_props)
    end
end

local function ui_set_style(h, new_style)
    if h == nil then return end
    local s = _ui_state[h]
    if s == nil then s = { props = {}, style = {} }; _ui_state[h] = s end
    local changed = false
    for k, v in pairs(new_style) do
        if s.style[k] ~= v then
            s.style[k] = v
            changed = true
        end
    end
    if changed then
        h:set_style(new_style)
    end
end

local function ui_cache_reset()
    _ui_state = setmetatable({}, { __mode = "k" })
end

-- ==================== MEMORY HELPERS ====================

local function write(address, value)
    mem_write(address, value)
end

local function read(address)
    return mem_read(address) or 0
end

local function safe_batch_read_name(prefab, namehash, logic_type, method)
    if batch_read_name == nil then
        return nil
    end
    if prefab == nil or namehash == nil then
        return nil
    end

    local prefab_num = tonumber(prefab) or 0
    local namehash_num = tonumber(namehash) or 0
    if prefab_num == 0 or namehash_num == 0 then
        return nil
    end

    return batch_read_name(prefab_num, namehash_num, logic_type, method)
end

local _safe_write_err_state = { last = 0, dropped = 0 }

local function safe_batch_write_name(prefab, namehash, logic_type, value)
    if ic.batch_write_name == nil then return end
    if prefab == nil or namehash == nil then return end
    local prefab_num = tonumber(prefab) or 0
    local namehash_num = tonumber(namehash) or 0
    if prefab_num == 0 or namehash_num == 0 then return end
    local ok, err = xpcall(function()
        ic.batch_write_name(prefab_num, namehash_num, logic_type, value)
    end, function(e) return e end)
    if not ok then
        local now = util.clock_time() or 0
        if now - _safe_write_err_state.last >= 1.0 then
            local dropped = _safe_write_err_state.dropped
            _safe_write_err_state.last = now
            _safe_write_err_state.dropped = 0
            print("safe_batch_write_name error: " .. tostring(err) .. " (dropped " .. dropped .. " since last log)")
        else
            _safe_write_err_state.dropped = _safe_write_err_state.dropped + 1
        end
    end
end

-- ==================== HELPERS ====================

local function fmt(v, d)
    if v == nil then return "--" end
    d = d or 1
    return string.format("%." .. d .. "f", v)
end

local function sanitize_label(index, value)
    local text = tostring(value or "")
    text = text:gsub("|", "/")
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    if text == "" then
        return "Box " .. index
    end
    return text
end

local function sanitize_max_range(value, fallback)
    local n = tonumber(value)
    if n == nil or n <= 0 then
        return fallback
    end
    return n
end

local function bar_percent(value, max_value)
    if value == nil then
        return 0
    end
    local max_num = tonumber(max_value) or 0
    if max_num <= 0 then
        return 0
    end
    local ratio = value / max_num
    if ratio < 0 then ratio = 0 end
    if ratio > 1 then ratio = 1 end
    return math.floor(ratio * 100 + 0.5)
end

local function percent_text(value, max_value)
    if value == nil then
        return "--"
    end
    return tostring(bar_percent(value, max_value)) .. "%"
end

local function save_label_string_to_memory(index, value)
    local base = MEM_LABELSTR_BEGIN + (index - 1) * LABEL_SLOT_STRIDE
    local text = tostring(value or "")
    local text_len = math.min(#text, LABEL_MAX_CHARS)

    write(base, text_len)

    local offset = 1
    for slot = 1, LABEL_DATA_SLOTS do
        local b1, b2, b3 = 0, 0, 0

        if offset <= text_len then
            b1 = string.byte(text, offset) or 0
            offset = offset + 1
        end
        if offset <= text_len then
            b2 = string.byte(text, offset) or 0
            offset = offset + 1
        end
        if offset <= text_len then
            b3 = string.byte(text, offset) or 0
            offset = offset + 1
        end

        local packed = b1 + (b2 * 256) + (b3 * 65536)
        write(base + slot, packed)
    end
end

local function load_label_string_from_memory(index)
    local base = MEM_LABELSTR_BEGIN + (index - 1) * LABEL_SLOT_STRIDE
    local stored_len = tonumber(read(base)) or 0
    if stored_len <= 0 then
        return nil
    end

    local text_len = math.min(stored_len, LABEL_MAX_CHARS)
    local bytes = {}

    for slot = 1, LABEL_DATA_SLOTS do
        local packed = math.floor(tonumber(read(base + slot)) or 0)
        local b1 = packed % 256
        packed = math.floor(packed / 256)
        local b2 = packed % 256
        packed = math.floor(packed / 256)
        local b3 = packed % 256

        table.insert(bytes, string.char(b1))
        table.insert(bytes, string.char(b2))
        table.insert(bytes, string.char(b3))
    end

    local raw = table.concat(bytes)
    if #raw < text_len then
        return nil
    end
    return raw:sub(1, text_len)
end

local function label_from_hash(index, label_hash)
    local hash_value = tonumber(label_hash) or 0
    if hash_value == 0 then
        return "Box " .. index
    end

    local ok, resolved = pcall(namehash_name, hash_value)
    if not ok or resolved == nil then
        return "Box " .. index
    end

    return sanitize_label(index, resolved)
end

local function load_box_label(index)
    local stored = load_label_string_from_memory(index)
    if stored ~= nil and stored ~= "" then
        return sanitize_label(index, stored)
    end

    local legacy = label_from_hash(index, read(MEM_LABELHASH_BEGIN + index - 1))
    local clean = sanitize_label(index, legacy)
    save_label_string_to_memory(index, clean)
    return clean
end

local function save_box_label(index, value)
    if index < 1 or index > BOX_COUNT then return end
    local clean = sanitize_label(index, value)
    box_labels[index] = clean
    write(MEM_LABELHASH_BEGIN + index - 1, hash(clean))
    save_label_string_to_memory(index, clean)
end

local function save_pa_state(index)
    if index < 1 or index > BOX_COUNT then return end
    write(MEM_PA_PREFAB_BEGIN + index - 1, pa_devices[index].prefab)
    write(MEM_PA_NAMEHASH_BEGIN + index - 1, pa_devices[index].namehash)
end

local function save_pa_ranges()
    pa_pressure_max_range = sanitize_max_range(pa_pressure_max_range, 20000)
    pa_volume_max_range = sanitize_max_range(pa_volume_max_range, 1000)
    write(MEM_PRESSURE_MAX, pa_pressure_max_range)
    write(MEM_VOLUME_MAX, pa_volume_max_range)
end

local function sanitize_safety_margin(value)
    local n = tonumber(value) or 10
    if n < 0 then n = 0 end
    if n > 49 then n = 49 end
    return math.floor(n + 0.5)
end

local function recompute_reg_thresholds()
    local max_p = tonumber(pa_pressure_max_range) or 0
    local on_pct  = (100 - safety_margin_pct) / 100
    local off_pct = (100 - safety_margin_pct - HYSTERESIS_GAP_PCT) / 100
    if off_pct < 0 then off_pct = 0 end
    reg_on_threshold  = max_p * on_pct
    reg_off_threshold = max_p * off_pct
end

local function save_safety_margin()
    safety_margin_pct = sanitize_safety_margin(safety_margin_pct)
    write(MEM_SAFETY_MARGIN, safety_margin_pct)
    recompute_reg_thresholds()
end

local function save_reg_state(index)
    if index < 1 or index > BOX_COUNT then return end
    write(MEM_REG_PREFAB_BEGIN + index - 1, reg_devices[index].prefab)
    write(MEM_REG_NAMEHASH_BEGIN + index - 1, reg_devices[index].namehash)
end

local function pressure_value_color(value)
    if value == nil then return C.text_dim end
    local p = bar_percent(value, pa_pressure_max_range)
    if p >= 90 then return C.red end
    if p >= 70 then return C.orange end
    if p >= 35 then return C.yellow end
    return C.green
end

local function volume_value_color(value)
    if value == nil then return C.text_dim end
    local p = bar_percent(value, pa_volume_max_range)
    if p >= 20 then return C.green end
    if p >= 10 then return C.yellow end
    return C.red
end

local function temperature_value_color(value)
    if value == nil then return C.text_dim end
    local c = util.temp(value, "K", "C")
    if c > 50 then return C.red end
    if c > 35 then return C.orange end
    if c > 20 then return C.green end
    if c > 10 then return C.light_blue end
    return C.dark_blue
end

local function format_pressure_label(value)
    if value == nil then return "--" end
    if value >= 1000 then
        return fmt(value / 1000, 2) .. " MPa"
    end
    if value >= 1 then
        return fmt(value, 1) .. " kPa"
    end
    return fmt(value * 1000, 0) .. " Pa"
end

local function format_volume_label(value)
    if value == nil then return "--" end
    if value >= 1000 then
        return fmt(value / 1000, 2) .. " kL"
    end
    return fmt(value, 1) .. " L"
end

local function format_temperature_label(value)
    if value == nil then return "--" end
    return fmt(util.temp(value, "K", "C"), 1) .. " C"
end

local function reg_status_for_box(idx)
    local reg = reg_devices[idx]
    local prefab = tonumber(reg and reg.prefab) or 0
    if reg == nil or prefab == 0 then
        return "No BPR", C.text_muted
    end
    local r = reg_readings[idx] or {}
    local err = tonumber(r.error) or 0
    if err >= 1 then
        return "Error", C.red
    end
    local on = tonumber(r.on) or 0
    if on < 1 then
        return "Off", C.text_dim
    end
    -- Venting iff the paired PA reading has crossed the reg's pinned Setting.
    -- Gas regs compare pressure vs max kPa; liquid regs compare volume vs max L.
    local readings = pa_readings[idx] or {}
    if is_liquid_reg(prefab) then
        local vol = tonumber(readings.volume)
        local max_v = tonumber(pa_volume_max_range) or 0
        if vol ~= nil and max_v > 0 and vol >= max_v then
            return "Venting", C.orange
        end
    else
        local pressure = tonumber(readings.pressure)
        local max_p = tonumber(pa_pressure_max_range) or 0
        if pressure ~= nil and max_p > 0 and pressure >= max_p then
            return "Venting", C.orange
        end
    end
    return "On", C.green
end

local function device_matches_prefabs(dev, allowed_prefabs)
    local prefab_hash = tonumber(dev and dev.prefab_hash) or 0
    for _, allowed in ipairs(allowed_prefabs) do
        if prefab_hash == allowed then
            return true
        end
    end
    return false
end

local function device_list_safe()
    local ok, result = pcall(device_list)
    if not ok or result == nil then return {} end
    return result
end

local function refresh_pa_fast()
    for i = 1, BOX_COUNT do
        local device = pa_devices[i]
        local prefab = tonumber(device.prefab) or 0
        local namehash = tonumber(device.namehash) or 0
        if prefab ~= 0 and namehash ~= 0 then
            pa_readings[i].pressure      = safe_batch_read_name(prefab, namehash, LT.Pressure, LBM.Average)
            pa_readings[i].network_fault = safe_batch_read_name(prefab, namehash, LT.NetworkFault, LBM.Average)
        else
            pa_readings[i].pressure = nil
            pa_readings[i].network_fault = nil
        end
    end
end

local function refresh_pa_slow()
    for i = 1, BOX_COUNT do
        local device = pa_devices[i]
        local prefab = tonumber(device.prefab) or 0
        local namehash = tonumber(device.namehash) or 0
        if prefab ~= 0 and namehash ~= 0 then
            pa_readings[i].temperature = safe_batch_read_name(prefab, namehash, LT.Temperature, LBM.Average)
            pa_readings[i].volume      = safe_batch_read_name(prefab, namehash, LT.VolumeOfLiquid, LBM.Average)
        else
            pa_readings[i].temperature = nil
            pa_readings[i].volume = nil
        end
    end
end

local function refresh_reg_fast()
    for i = 1, BOX_COUNT do
        local reg = reg_devices[i]
        local prefab = tonumber(reg.prefab) or 0
        local namehash = tonumber(reg.namehash) or 0
        if prefab ~= 0 and namehash ~= 0 then
            reg_readings[i].on    = safe_batch_read_name(prefab, namehash, LT.On, LBM.Average)
            reg_readings[i].ratio = safe_batch_read_name(prefab, namehash, LT.Ratio, LBM.Average)
            reg_readings[i].error = safe_batch_read_name(prefab, namehash, LT.Error, LBM.Average)
        else
            reg_readings[i].on = nil
            reg_readings[i].ratio = nil
            reg_readings[i].error = nil
        end
    end
end

local function compute_reg_target(idx, last_state)
    local reg = reg_devices[idx]
    local prefab = tonumber(reg and reg.prefab) or 0
    local readings = pa_readings[idx] or {}

    if is_liquid_reg(prefab) then
        local vol = tonumber(readings.volume)
        local max_v = tonumber(pa_volume_max_range) or 0
        if vol == nil or max_v <= 0 then return "off" end
        local vol_pct = (vol / max_v) * 100
        local on_pct  = 100 - safety_margin_pct
        local off_pct = on_pct - HYSTERESIS_GAP_PCT
        if off_pct < 0 then off_pct = 0 end
        if vol_pct >= on_pct then return "on" end
        if vol_pct <= off_pct then return "off" end
        return last_state or "off"
    end

    local pressure = tonumber(readings.pressure)
    if pressure == nil or pa_pressure_max_range == nil or pa_pressure_max_range <= 0 then
        return "off"
    end
    if pressure >= reg_on_threshold then return "on" end
    if pressure <= reg_off_threshold then return "off" end
    return last_state or "off"
end

local function apply_reg_state(index, target)
    local reg = reg_devices[index]
    local prefab = tonumber(reg.prefab) or 0
    local namehash = tonumber(reg.namehash) or 0
    if prefab == 0 or namehash == 0 then return end
    if reg_state[index] == target then return end
    local on_value = (target == "on") and 1 or 0
    safe_batch_write_name(prefab, namehash, LT.On, on_value)
    reg_state[index] = target
end

local function evaluate_and_apply_reg_targets()
    for i = 1, BOX_COUNT do
        local reg = reg_devices[i]
        if (tonumber(reg.prefab) or 0) ~= 0 then
            local err = tonumber(reg_readings[i].error) or 0
            if err < 1 then
                local target = compute_reg_target(i, reg_state[i])
                apply_reg_state(i, target)
            end
        end
    end
end

local function push_reg_setting(index)
    local reg = reg_devices[index]
    local prefab = tonumber(reg.prefab) or 0
    local namehash = tonumber(reg.namehash) or 0
    if prefab == 0 or namehash == 0 then return end
    local setting
    if is_liquid_reg(prefab) then
        -- Liquid BPR Setting is volume ratio 0-100%. Match the gas threshold shape
        -- by pinning at (100 - safety_margin_pct) so it bleeds above the same
        -- fraction of the tank as the gas regs do relative to max pressure.
        setting = math.max(0, math.min(100, 100 - safety_margin_pct))
    else
        setting = math.min(pa_pressure_max_range, REG_SETTING_MAX)
    end
    safe_batch_write_name(prefab, namehash, LT.Setting, setting)
end

local function push_all_reg_settings()
    for i = 1, BOX_COUNT do
        push_reg_setting(i)
    end
end

local function get_header_status()
    local leaking_boxes = {}

    for i = 1, BOX_COUNT do
        local device = pa_devices[i]
        local prefab = tonumber(device.prefab) or 0
        local namehash = tonumber(device.namehash) or 0
        local network_fault = tonumber(pa_readings[i].network_fault) or 0

        if prefab ~= 0 and namehash ~= 0 and network_fault >= 1 then
            table.insert(leaking_boxes, box_labels[i])
        end
    end

    if #leaking_boxes > 0 then
        local cycle_step = math.floor(elapsed / math.max(1, LIVE_REFRESH_TICKS))
        local cycle_index = (cycle_step % #leaking_boxes) + 1
        return string.format("Leak %d/%d: %s", cycle_index, #leaking_boxes, leaking_boxes[cycle_index]), C.red
    end

    return "ONLINE", C.accent
end

local function reset_handles()
    handles = {
        view = nil,
        header = {},
        nav = {},
        footer = {},
        overview = {},
    }
    ui_cache_reset()
end

-- ==================== INITIALIZATION ====================

local function initialize_settings()
    for i = 1, BOX_COUNT do
        pa_devices[i].prefab = tonumber(read(MEM_PA_PREFAB_BEGIN + i - 1)) or 0
        pa_devices[i].namehash = tonumber(read(MEM_PA_NAMEHASH_BEGIN + i - 1)) or 0
        reg_devices[i].prefab = tonumber(read(MEM_REG_PREFAB_BEGIN + i - 1)) or 0
        reg_devices[i].namehash = tonumber(read(MEM_REG_NAMEHASH_BEGIN + i - 1)) or 0
        box_labels[i] = load_box_label(i)
    end

    pa_pressure_max_range = sanitize_max_range(read(MEM_PRESSURE_MAX), pa_pressure_max_range)
    pa_volume_max_range = sanitize_max_range(read(MEM_VOLUME_MAX), pa_volume_max_range)
    local stored_ticks = tonumber(read(MEM_REFRESH_TICKS)) or 0
    if stored_ticks >= 1 then
        LIVE_REFRESH_TICKS = math.min(120, stored_ticks)
    end
    local stored_margin = tonumber(read(MEM_SAFETY_MARGIN)) or 0
    if stored_margin > 0 then
        safety_margin_pct = sanitize_safety_margin(stored_margin)
    end
    recompute_reg_thresholds()
end

-- ==================== RENDER HELPERS ====================

local dashboard_render
local set_view

local function render_header()
    local status_text, status_color = get_header_status()

    local header = s:element({
        id = "header_bg",
        type = "panel",
        rect = { unit = "px", x = 0, y = 0, w = W, h = 30 },
        style = { bg = C.header }
    })

    header:element({
        id = "title",
        type = "label",
        rect = { unit = "px", x = 14, y = 6, w = 300, h = 20 },
        props = { text = "TSO - Tank Status Overview" },
        style = { font_size = 14, color = C.text, align = "left" }
    })

    handles.header.status_dot = header:element({
        id = "status_dot",
        type = "panel",
        rect = { unit = "px", x = W - 90, y = 12, w = 6, h = 6 },
        style = { bg = status_color }
    })

    handles.header.status_label = header:element({
        id = "status_label",
        type = "label",
        rect = { unit = "px", x = W - 82, y = 7, w = 78, h = 18 },
        props = { text = status_text },
        style = { font_size = 11, color = status_color, align = "left" }
    })
end

local function update_header_dynamic()
    local status_text, status_color = get_header_status()
    ui_set_style(handles.header.status_dot, { bg = status_color })
    ui_set_props(handles.header.status_label, { text = status_text })
    ui_set_style(handles.header.status_label, { font_size = 11, color = status_color, align = "left" })
end

local function render_nav_tabs()
    local tabs = {
        { id = "nav_overview", text = "OVERVIEW", page = "overview" },
        { id = "nav_settings", text = "SETTINGS", page = "settings" },
    }

    local tab_w = math.floor((W - 10) / #tabs)

    for i, tab in ipairs(tabs) do
        local active = (view == tab.page)
        local target_page = tab.page
        handles.nav[tab.page] = s:element({
            id = tab.id,
            type = "button",
            rect = { unit = "px", x = (i - 1) * tab_w + 5, y = 34, w = tab_w - 4, h = 22 },
            props = { text = tab.text },
            style = {
                bg = active and "#6844aa" or "#333344",
                text = "#FFFFFF",
                font_size = 11,
                gradient = active and "#3b1f88" or "#1c1c2e",
                gradient_dir = "vertical"
            },
            on_click = function()
                set_view(target_page)
            end
        })
    end
end

local function render_footer()
    local footer = s:element({
        id = "footer_bg",
        type = "panel",
        rect = { unit = "px", x = 0, y = H - 18, w = W, h = 18 },
        style = { bg = C.header }
    })

    local gt = util.game_time()
    local gtH = math.floor(gt / 3600)
    local gtM = math.floor((gt % 3600) / 60)

    handles.footer.left = footer:element({
        id = "footer_left",
        type = "label",
        rect = { unit = "px", x = 8, y = 3, w = 120, h = 14 },
        props = { text = "Time: " .. currenttime },
        style = { font_size = 8, color = C.text_muted, align = "left" }
    })

    handles.footer.right = footer:element({
        id = "footer_right",
        type = "label",
        rect = { unit = "px", x = W - 200, y = 3, w = 192, h = 14 },
        props = { text = string.format("Tick %.0f | ELAPSED %dh %02dm", math.floor(elapsed), gtH, gtM) },
        style = { font_size = 8, color = C.text_muted, align = "right" }
    })
end

local function update_nav_dynamic()
    local active_ov = (view == "overview")
    ui_set_style(handles.nav.overview, {
        bg = active_ov and "#6844aa" or "#333344",
        text = "#FFFFFF",
        font_size = 11,
        gradient = active_ov and "#3b1f88" or "#1c1c2e",
        gradient_dir = "vertical"
    })
    local active_set = (view == "settings")
    ui_set_style(handles.nav.settings, {
        bg = active_set and "#6844aa" or "#333344",
        text = "#FFFFFF",
        font_size = 11,
        gradient = active_set and "#3b1f88" or "#1c1c2e",
        gradient_dir = "vertical"
    })
end

local function update_footer_dynamic()
    local gt = util.game_time()
    local gtH = math.floor(gt / 3600)
    local gtM = math.floor((gt % 3600) / 60)
    ui_set_props(handles.footer.left, { text = "Time: " .. currenttime })
    ui_set_props(handles.footer.right, { text = string.format("Tick %.0f | ELAPSED %dh %02dm", math.floor(elapsed), gtH, gtM) })
end

-- ==================== OVERVIEW (12 BOXES) ====================

local function render_overview_box(idx, x, y, w, h)
    local r = pa_readings[idx]
    local p_pct = bar_percent(r.pressure, pa_pressure_max_range)
    local v_pct = bar_percent(r.volume, pa_volume_max_range)
    -- Scale row spacing and bar thickness with box height. sf=1 at h=90 (matches
    -- the original layout); sf=2 at h=180 so content fills tall boxes.
    local sf = h / 90
    if sf < 1 then sf = 1 end
    local temp_label_y = y + math.floor(15 * sf)
    local temp_value_y = y + math.floor(23 * sf)
    local pressure_row_y = y + math.floor(34 * sf)
    local pressure_bar_y = y + math.floor(43 * sf)
    local volume_row_y = y + math.floor(51 * sf)
    local volume_bar_y = y + math.floor(60 * sf)
    local reg_row_y = y + math.floor(69 * sf)
    local bar_h = math.max(5, math.floor(5 * sf))

    s:element({
        id = "box_" .. idx .. "_bg",
        type = "panel",
        rect = { unit = "px", x = x, y = y, w = w, h = h },
        style = { bg = C.panel }
    })

    handles.overview["box_" .. idx .. "_label"] = s:element({
        id = "box_" .. idx .. "_label",
        type = "label",
        rect = { unit = "px", x = x + 4, y = y + 3, w = w - 8, h = 10 },
        props = { text = box_labels[idx] },
        style = { font_size = 9, color = C.text, align = "center" }
    })

    s:element({
        id = "box_" .. idx .. "_temp_label",
        type = "label",
        rect = { unit = "px", x = x + 6, y = temp_label_y, w = w - 12, h = 8 },
        props = { text = "Temp" },
        style = { font_size = 6, color = C.text_dim, align = "center" }
    })

    handles.overview["box_" .. idx .. "_t_value"] = s:element({
        id = "box_" .. idx .. "_t_value",
        type = "label",
        rect = { unit = "px", x = x + 6, y = temp_value_y, w = w - 12, h = 9 },
        props = { text = format_temperature_label(r.temperature) },
        style = { font_size = 7, color = temperature_value_color(r.temperature), align = "center" }
    })

    s:element({
        id = "box_" .. idx .. "_p_label",
        type = "label",
        rect = { unit = "px", x = x + 6, y = pressure_row_y, w = 48, h = 8 },
        props = { text = "Pressure" },
        style = { font_size = 6, color = C.text_dim, align = "left" }
    })

    handles.overview["box_" .. idx .. "_p_value"] = s:element({
        id = "box_" .. idx .. "_p_value",
        type = "label",
        rect = { unit = "px", x = x + 54, y = pressure_row_y, w = w - 60, h = 8 },
        props = { text = format_pressure_label(r.pressure) .. " [" .. percent_text(r.pressure, pa_pressure_max_range) .. "]" },
        style = { font_size = 7, color = pressure_value_color(r.pressure), align = "left" }
    })

    s:element({
        id = "box_" .. idx .. "_p_bar_bg",
        type = "panel",
        rect = { unit = "px", x = x + 6, y = pressure_bar_y, w = w - 12, h = bar_h },
        style = { bg = C.bar_bg }
    })

    handles.overview["box_" .. idx .. "_p_bar_fill"] = s:element({
        id = "box_" .. idx .. "_p_bar_fill",
        type = "panel",
        rect = { unit = "px", x = x + 6, y = pressure_bar_y, w = math.max(1, math.floor((w - 12) * p_pct / 100)), h = bar_h },
        style = { bg = pressure_value_color(r.pressure) }
    })

    s:element({
        id = "box_" .. idx .. "_v_label",
        type = "label",
        rect = { unit = "px", x = x + 6, y = volume_row_y, w = 64, h = 8 },
        props = { text = "Liquid Volume" },
        style = { font_size = 6, color = C.text_dim, align = "left" }
    })

    handles.overview["box_" .. idx .. "_v_value"] = s:element({
        id = "box_" .. idx .. "_v_value",
        type = "label",
        rect = { unit = "px", x = x + 68, y = volume_row_y, w = w - 74, h = 8 },
        props = { text = format_volume_label(r.volume) .. " [" .. percent_text(r.volume, pa_volume_max_range) .. "]" },
        style = { font_size = 7, color = volume_value_color(r.volume), align = "left" }
    })

    s:element({
        id = "box_" .. idx .. "_v_bar_bg",
        type = "panel",
        rect = { unit = "px", x = x + 6, y = volume_bar_y, w = w - 12, h = bar_h },
        style = { bg = C.bar_bg }
    })

    handles.overview["box_" .. idx .. "_v_bar_fill"] = s:element({
        id = "box_" .. idx .. "_v_bar_fill",
        type = "panel",
        rect = { unit = "px", x = x + 6, y = volume_bar_y, w = math.max(1, math.floor((w - 12) * v_pct / 100)), h = bar_h },
        style = { bg = volume_value_color(r.volume) }
    })

    local reg_text, reg_color = reg_status_for_box(idx)

    s:element({
        id = "box_" .. idx .. "_reg_label",
        type = "label",
        rect = { unit = "px", x = x + 6, y = reg_row_y, w = 30, h = 8 },
        props = { text = "BPR" },
        style = { font_size = 6, color = C.text_dim, align = "left" }
    })

    handles.overview["box_" .. idx .. "_reg_value"] = s:element({
        id = "box_" .. idx .. "_reg_value",
        type = "label",
        rect = { unit = "px", x = x + 38, y = reg_row_y, w = w - 44, h = 8 },
        props = { text = reg_text },
        style = { font_size = 7, color = reg_color, align = "left" }
    })
end

local MAX_BOX_W = 240
local MAX_BOX_H = 180

local function render_overview()
    local top = 58
    local bottom = H - 22
    local left = 6
    local right = W - 6
    local gap_x = 6
    local gap_y = 6

    local configured = {}
    for i = 1, BOX_COUNT do
        if (tonumber(pa_devices[i].prefab) or 0) ~= 0 then
            table.insert(configured, i)
        end
    end

    if #configured == 0 then
        s:element({
            id = "overview_empty",
            type = "label",
            rect = { unit = "px", x = left, y = top + math.floor((bottom - top) / 2) - 8, w = right - left, h = 16 },
            props = { text = "Assign a Pipe Analyzer in Settings > PA" },
            style = { font_size = 10, color = C.text_dim, align = "center" }
        })
        return
    end

    local count = #configured
    local cols = math.min(3, count)
    local rows = math.ceil(count / cols)
    local grid_w = right - left
    local grid_h = bottom - top
    local natural_w = math.floor((grid_w - gap_x * (cols - 1)) / cols)
    local natural_h = math.floor((grid_h - gap_y * (rows - 1)) / rows)
    local box_w = math.min(MAX_BOX_W, natural_w)
    local box_h = math.min(MAX_BOX_H, natural_h)

    for pos = 1, count do
        local idx = configured[pos]
        local c = (pos - 1) % cols
        local r = math.floor((pos - 1) / cols)
        local x = left + c * (box_w + gap_x)
        local y = top + r * (box_h + gap_y)
        render_overview_box(idx, x, y, box_w, box_h)
    end
end

local function update_overview_dynamic()
    for idx = 1, BOX_COUNT do
        local r = pa_readings[idx]
        ui_set_props(handles.overview["box_" .. idx .. "_label"], { text = box_labels[idx] })
        ui_set_props(handles.overview["box_" .. idx .. "_p_value"], {
            text = format_pressure_label(r.pressure) .. " [" .. percent_text(r.pressure, pa_pressure_max_range) .. "]"
        })
        ui_set_style(handles.overview["box_" .. idx .. "_p_value"], {
            font_size = 7, color = pressure_value_color(r.pressure), align = "left"
        })
        ui_set_props(handles.overview["box_" .. idx .. "_v_value"], {
            text = format_volume_label(r.volume) .. " [" .. percent_text(r.volume, pa_volume_max_range) .. "]"
        })
        ui_set_style(handles.overview["box_" .. idx .. "_v_value"], {
            font_size = 7, color = volume_value_color(r.volume), align = "left"
        })
        ui_set_props(handles.overview["box_" .. idx .. "_t_value"], {
            text = format_temperature_label(r.temperature)
        })
        ui_set_style(handles.overview["box_" .. idx .. "_t_value"], {
            font_size = 7, color = temperature_value_color(r.temperature), align = "center"
        })
        local reg_text, reg_color = reg_status_for_box(idx)
        ui_set_props(handles.overview["box_" .. idx .. "_reg_value"], { text = reg_text })
        ui_set_style(handles.overview["box_" .. idx .. "_reg_value"], {
            font_size = 7, color = reg_color, align = "left"
        })
    end
end

-- ==================== SETTINGS ====================

local function render_settings()
    local content_y = 60
    local panel_x = 8
    local panel_y = content_y
    local panel_w = W - 16
    local panel_h = H - content_y - 22
    local tab_y = panel_y + 8
    local tab_w = math.floor((panel_w - 14) / 3)

    local function render_settings_subtabs()
        local tabs = {
            { id = "settings_labels", text = "LABELS", key = "labels" },
            { id = "settings_pa", text = "PA", key = "pa" },
            { id = "settings_reg", text = "BPR", key = "reg" },
        }

        for index, tab in ipairs(tabs) do
            local active = settings_subview == tab.key
            local target_key = tab.key
            s:element({
                id = tab.id,
                type = "button",
                rect = { unit = "px", x = panel_x + 6 + (index - 1) * tab_w, y = tab_y, w = tab_w - 2, h = 20 },
                props = { text = tab.text },
                style = {
                    bg = active and C.accent or C.panel_light,
                    text = active and C.bg or C.text,
                    font_size = 9,
                    gradient = active and "#0f4c63" or "#182133",
                    gradient_dir = "vertical"
                },
                on_click = function()
                    settings_subview = target_key
                    dashboard_render(true)
                end
            })
        end
    end

    local function render_labels_subview(base_y)
        s:element({
            id = "settings_title",
            type = "label",
            rect = { unit = "px", x = panel_x + 14, y = base_y, w = panel_w - 28, h = 14 },
            props = { text = "Overview Box Labels" },
            style = { font_size = 10, color = C.accent, align = "left" }
        })

        for i = 1, BOX_COUNT do
            local idx = i
            local col = (i <= 6) and 0 or 1
            local row = (i - 1) % 6
            local row_y = base_y + 18 + row * 23
            local col_x = panel_x + 14 + col * 228

            s:element({
                id = "label_row_" .. i .. "_text",
                type = "label",
                rect = { unit = "px", x = col_x, y = row_y + 2, w = 78, h = 15 },
                props = { text = "Name " .. i },
                style = { font_size = 8, color = C.text, align = "left" }
            })

            s:element({
                id = "label_row_" .. i .. "_input",
                type = "textinput",
                rect = { unit = "px", x = col_x + 66, y = row_y, w = 150, h = 20 },
                props = { value = box_labels[i], placeholder = box_labels[i] },
                on_change = function(new_value)
                    save_box_label(idx, new_value)
                end
            })
        end
    end

    local function render_pa_picker(base_y, idx)
        s:element({
            id = "pa_picker_back",
            type = "button",
            rect = { unit = "px", x = panel_x + 14, y = base_y, w = 70, h = 20 },
            props = { text = "< Back" },
            style = {
                bg = C.panel_light, text = C.text, font_size = 9,
                gradient = "#182133", gradient_dir = "vertical", align = "center"
            },
            on_click = function()
                pa_picker_idx = nil
                dashboard_render(true)
            end
        })

        s:element({
            id = "pa_picker_title",
            type = "label",
            rect = { unit = "px", x = panel_x + 96, y = base_y + 3, w = panel_w - 110, h = 16 },
            props = { text = "Select Pipe Analyzer for PA Box " .. idx },
            style = { font_size = 10, color = C.accent, align = "left" }
        })

        local list_y = base_y + 28
        local list_h = panel_y + panel_h - list_y - 6
        if list_h < 40 then list_h = 40 end

        local devs = device_list_safe()
        local candidates = {}
        for _, dev in ipairs(devs) do
            if device_matches_prefabs(dev, { PA_PREFAB_FILTERS.gas, PA_PREFAB_FILTERS.liquid }) then
                table.insert(candidates, dev)
            end
        end

        local row_h = 22
        local content_height = math.max(list_h, (#candidates + 1) * row_h + 8)

        local scroll = s:element({
            id = "pa_picker_scroll",
            type = "scrollview",
            rect = { unit = "px", x = panel_x + 14, y = list_y, w = panel_w - 28, h = list_h },
            props = { content_height = tostring(content_height) },
            style = { bg = C.panel, scrollbar_bg = C.panel_light, scrollbar_handle = C.accent }
        })

        local inner_w = panel_w - 48
        local current_p = tonumber(pa_devices[idx].prefab) or 0
        local current_n = tonumber(pa_devices[idx].namehash) or 0
        local unassigned = (current_p == 0 and current_n == 0)

        scroll:element({
            id = "pa_picker_unassign",
            type = "button",
            rect = { unit = "px", x = 6, y = 4, w = inner_w - 12, h = row_h - 4 },
            props = { text = (unassigned and "> " or "   ") .. "(Unassigned)" },
            style = {
                bg = unassigned and C.accent or C.panel_light,
                text = unassigned and C.bg or C.text_dim,
                font_size = 9,
                gradient = unassigned and "#0f4c63" or "#182133",
                gradient_dir = "vertical", align = "left"
            },
            on_click = function()
                pa_devices[idx].prefab = 0
                pa_devices[idx].namehash = 0
                save_pa_state(idx)
                pa_picker_idx = nil
                dashboard_render(true)
            end
        })

        for i, dev in ipairs(candidates) do
            local label = tostring((dev and dev.display_name) or ("Device " .. i))
            local dev_p = tonumber(dev.prefab_hash) or 0
            local dev_n = tonumber(dev.name_hash) or 0
            local selected = (current_p == dev_p and current_n == dev_n)
            local picked_ref = dev
            scroll:element({
                id = "pa_picker_row_" .. i,
                type = "button",
                rect = { unit = "px", x = 6, y = i * row_h + 4, w = inner_w - 12, h = row_h - 4 },
                props = { text = (selected and "> " or "   ") .. label },
                style = {
                    bg = selected and C.accent or C.panel_light,
                    text = selected and C.bg or C.text,
                    font_size = 9,
                    gradient = selected and "#0f4c63" or "#182133",
                    gradient_dir = "vertical", align = "left"
                },
                on_click = function()
                    pa_devices[idx].prefab = tonumber(picked_ref.prefab_hash) or 0
                    pa_devices[idx].namehash = tonumber(picked_ref.name_hash) or 0
                    save_pa_state(idx)
                    pa_picker_idx = nil
                    dashboard_render(true)
                end
            })
        end
    end

    local function render_pa_subview(base_y)
        if pa_picker_idx ~= nil then
            render_pa_picker(base_y, pa_picker_idx)
            return
        end

        s:element({
            id = "settings_title",
            type = "label",
            rect = { unit = "px", x = panel_x + 14, y = base_y, w = panel_w - 28, h = 14 },
            props = { text = "Pipe Analyzer Assignment" },
            style = { font_size = 10, color = C.accent, align = "left" }
        })

        s:element({
            id = "pressure_max_label",
            type = "label",
            rect = { unit = "px", x = panel_x + 14, y = base_y + 20, w = 90, h = 14 },
            props = { text = "Press Max (kPa)" },
            style = { font_size = 8, color = C.text, align = "left" }
        })

        s:element({
            id = "pressure_max_input",
            type = "textinput",
            rect = { unit = "px", x = panel_x + 98, y = base_y + 18, w = 90, h = 20 },
            props = { value = tostring(pa_pressure_max_range), placeholder = "20000" },
            on_change = function(new_value)
                pa_pressure_max_range = sanitize_max_range(new_value, pa_pressure_max_range)
                save_pa_ranges()
                recompute_reg_thresholds()
                push_all_reg_settings()
                dashboard_render(true)
            end
        })

        s:element({
            id = "volume_max_label",
            type = "label",
            rect = { unit = "px", x = panel_x + 206, y = base_y + 20, w = 80, h = 14 },
            props = { text = "Volume Max (L)" },
            style = { font_size = 8, color = C.text, align = "left" }
        })

        s:element({
            id = "volume_max_input",
            type = "textinput",
            rect = { unit = "px", x = panel_x + 278, y = base_y + 18, w = 90, h = 20 },
            props = { value = tostring(pa_volume_max_range), placeholder = "1000" },
            on_change = function(new_value)
                pa_volume_max_range = sanitize_max_range(new_value, pa_volume_max_range)
                save_pa_ranges()
                dashboard_render(true)
            end
        })

        s:element({
            id = "refresh_ticks_label",
            type = "label",
            rect = { unit = "px", x = panel_x + 338, y = base_y, w = 44, h = 14 },
            props = { text = "Ref. Ticks" },
            style = { font_size = 8, color = C.text, align = "left" }
        })

        s:element({
            id = "refresh_ticks_input",
            type = "textinput",
            rect = { unit = "px", x = panel_x + 384, y = base_y, w = 40, h = 20 },
            props = { value = tostring(LIVE_REFRESH_TICKS), placeholder = "6" },
            on_change = function(new_value)
                local n = math.max(1, math.min(120, tonumber(new_value) or LIVE_REFRESH_TICKS))
                LIVE_REFRESH_TICKS = n
                write(MEM_REFRESH_TICKS, n)
                dashboard_render(true)
            end
        })

        local list_y = base_y + 48
        local list_h = panel_y + panel_h - list_y - 6
        if list_h < 40 then list_h = 40 end

        local row_h = 22
        local content_height = math.max(list_h, BOX_COUNT * row_h + 8)

        local scroll = s:element({
            id = "pa_list_scroll",
            type = "scrollview",
            rect = { unit = "px", x = panel_x + 14, y = list_y, w = panel_w - 28, h = list_h },
            props = { content_height = tostring(content_height) },
            style = { bg = C.panel, scrollbar_bg = C.panel_light, scrollbar_handle = C.accent }
        })

        local inner_w = panel_w - 48
        local change_w = 58
        local clear_w = 48
        local name_x = 82
        local name_w = inner_w - name_x - change_w - clear_w - 20
        if name_w < 40 then name_w = 40 end
        local change_x = name_x + name_w + 4
        local clear_x = change_x + change_w + 4

        local devs = device_list_safe()

        for i = 1, BOX_COUNT do
            local idx = i
            local y = (i - 1) * row_h + 4
            local p = tonumber(pa_devices[idx].prefab) or 0
            local n = tonumber(pa_devices[idx].namehash) or 0
            local bound = (p ~= 0 and n ~= 0)
            local device_label = "--"
            if bound then
                for _, dev in ipairs(devs) do
                    if (tonumber(dev.prefab_hash) or 0) == p and (tonumber(dev.name_hash) or 0) == n then
                        device_label = tostring(dev.display_name or device_label)
                        break
                    end
                end
            end

            scroll:element({
                id = "pa_list_hdr_" .. i,
                type = "label",
                rect = { unit = "px", x = 6, y = y + 3, w = 72, h = 16 },
                props = { text = "PA Box " .. i },
                style = { font_size = 9, color = C.text, align = "left" }
            })

            scroll:element({
                id = "pa_list_name_" .. i,
                type = "label",
                rect = { unit = "px", x = name_x, y = y + 3, w = name_w, h = 16 },
                props = { text = device_label },
                style = { font_size = 9, color = bound and C.text or C.text_dim, align = "left" }
            })

            scroll:element({
                id = "pa_list_change_" .. i,
                type = "button",
                rect = { unit = "px", x = change_x, y = y, w = change_w, h = row_h - 4 },
                props = { text = "Change" },
                style = {
                    bg = C.panel_light, text = C.text, font_size = 8,
                    gradient = "#182133", gradient_dir = "vertical", align = "center"
                },
                on_click = function()
                    pa_picker_idx = idx
                    dashboard_render(true)
                end
            })

            if bound then
                scroll:element({
                    id = "pa_list_clear_" .. i,
                    type = "button",
                    rect = { unit = "px", x = clear_x, y = y, w = clear_w, h = row_h - 4 },
                    props = { text = "Clear" },
                    style = {
                        bg = C.panel_light, text = C.red, font_size = 8,
                        gradient = "#182133", gradient_dir = "vertical", align = "center"
                    },
                    on_click = function()
                        pa_devices[idx].prefab = 0
                        pa_devices[idx].namehash = 0
                        save_pa_state(idx)
                        dashboard_render(true)
                    end
                })
            end
        end
    end

    local function render_reg_picker(base_y, idx)
        s:element({
            id = "reg_picker_back",
            type = "button",
            rect = { unit = "px", x = panel_x + 14, y = base_y, w = 70, h = 20 },
            props = { text = "< Back" },
            style = {
                bg = C.panel_light, text = C.text, font_size = 9,
                gradient = "#182133", gradient_dir = "vertical", align = "center"
            },
            on_click = function()
                reg_picker_idx = nil
                dashboard_render(true)
            end
        })

        s:element({
            id = "reg_picker_title",
            type = "label",
            rect = { unit = "px", x = panel_x + 96, y = base_y + 3, w = panel_w - 110, h = 16 },
            props = { text = "Select Regulator for BPR Box " .. idx },
            style = { font_size = 10, color = C.accent, align = "left" }
        })

        local list_y = base_y + 28
        local list_h = panel_y + panel_h - list_y - 6
        if list_h < 40 then list_h = 40 end

        local devs = device_list_safe()
        local candidates = {}
        for _, dev in ipairs(devs) do
            if device_matches_prefabs(dev, {
                REG_PREFAB_FILTERS.vanilla,
                REG_PREFAB_FILTERS.mirrored,
                REG_PREFAB_FILTERS.liquid_vanilla,
                REG_PREFAB_FILTERS.liquid_mirrored,
            }) then
                table.insert(candidates, dev)
            end
        end

        local row_h = 22
        local content_height = math.max(list_h, (#candidates + 1) * row_h + 8)

        local scroll = s:element({
            id = "reg_picker_scroll",
            type = "scrollview",
            rect = { unit = "px", x = panel_x + 14, y = list_y, w = panel_w - 28, h = list_h },
            props = { content_height = tostring(content_height) },
            style = { bg = C.panel, scrollbar_bg = C.panel_light, scrollbar_handle = C.accent }
        })

        local inner_w = panel_w - 48
        local current_p = tonumber(reg_devices[idx].prefab) or 0
        local current_n = tonumber(reg_devices[idx].namehash) or 0
        local unassigned = (current_p == 0 and current_n == 0)

        scroll:element({
            id = "reg_picker_unassign",
            type = "button",
            rect = { unit = "px", x = 6, y = 4, w = inner_w - 12, h = row_h - 4 },
            props = { text = (unassigned and "> " or "   ") .. "(Unassigned)" },
            style = {
                bg = unassigned and C.accent or C.panel_light,
                text = unassigned and C.bg or C.text_dim,
                font_size = 9,
                gradient = unassigned and "#0f4c63" or "#182133",
                gradient_dir = "vertical", align = "left"
            },
            on_click = function()
                reg_devices[idx].prefab = 0
                reg_devices[idx].namehash = 0
                save_reg_state(idx)
                reg_state[idx] = "off"
                reg_picker_idx = nil
                dashboard_render(true)
            end
        })

        for i, dev in ipairs(candidates) do
            local label = tostring((dev and dev.display_name) or ("Device " .. i))
            local dev_p = tonumber(dev.prefab_hash) or 0
            local dev_n = tonumber(dev.name_hash) or 0
            local selected = (current_p == dev_p and current_n == dev_n)
            local picked_ref = dev
            scroll:element({
                id = "reg_picker_row_" .. i,
                type = "button",
                rect = { unit = "px", x = 6, y = i * row_h + 4, w = inner_w - 12, h = row_h - 4 },
                props = { text = (selected and "> " or "   ") .. label },
                style = {
                    bg = selected and C.accent or C.panel_light,
                    text = selected and C.bg or C.text,
                    font_size = 9,
                    gradient = selected and "#0f4c63" or "#182133",
                    gradient_dir = "vertical", align = "left"
                },
                on_click = function()
                    reg_devices[idx].prefab = tonumber(picked_ref.prefab_hash) or 0
                    reg_devices[idx].namehash = tonumber(picked_ref.name_hash) or 0
                    save_reg_state(idx)
                    reg_state[idx] = "off"
                    push_reg_setting(idx)
                    reg_picker_idx = nil
                    dashboard_render(true)
                end
            })
        end
    end

    local function render_reg_subview(base_y)
        if reg_picker_idx ~= nil then
            render_reg_picker(base_y, reg_picker_idx)
            return
        end

        s:element({
            id = "settings_title",
            type = "label",
            rect = { unit = "px", x = panel_x + 14, y = base_y, w = panel_w - 28, h = 14 },
            props = { text = "Back Pressure Regulator Assignment" },
            style = { font_size = 10, color = C.accent, align = "left" }
        })

        s:element({
            id = "safety_margin_label",
            type = "label",
            rect = { unit = "px", x = panel_x + 14, y = base_y + 20, w = 110, h = 14 },
            props = { text = "Safety Margin %" },
            style = { font_size = 8, color = C.text, align = "left" }
        })

        s:element({
            id = "safety_margin_input",
            type = "textinput",
            rect = { unit = "px", x = panel_x + 124, y = base_y + 18, w = 60, h = 20 },
            props = { value = tostring(safety_margin_pct), placeholder = "10" },
            on_change = function(new_value)
                safety_margin_pct = sanitize_safety_margin(new_value)
                save_safety_margin()
                push_all_reg_settings()
                dashboard_render(true)
            end
        })

        s:element({
            id = "safety_margin_hint",
            type = "label",
            rect = { unit = "px", x = panel_x + 192, y = base_y + 20, w = panel_w - 206, h = 14 },
            props = { text = string.format("On >= %.0f kPa | Off < %.0f kPa", reg_on_threshold, reg_off_threshold) },
            style = { font_size = 7, color = C.text_dim, align = "left" }
        })

        local list_y = base_y + 48
        local list_h = panel_y + panel_h - list_y - 6
        if list_h < 40 then list_h = 40 end

        local row_h = 22
        local content_height = math.max(list_h, BOX_COUNT * row_h + 8)

        local scroll = s:element({
            id = "reg_list_scroll",
            type = "scrollview",
            rect = { unit = "px", x = panel_x + 14, y = list_y, w = panel_w - 28, h = list_h },
            props = { content_height = tostring(content_height) },
            style = { bg = C.panel, scrollbar_bg = C.panel_light, scrollbar_handle = C.accent }
        })

        local inner_w = panel_w - 48
        local change_w = 58
        local clear_w = 48
        local name_x = 82
        local name_w = inner_w - name_x - change_w - clear_w - 20
        if name_w < 40 then name_w = 40 end
        local change_x = name_x + name_w + 4
        local clear_x = change_x + change_w + 4

        local devs = device_list_safe()

        for i = 1, BOX_COUNT do
            local idx = i
            local y = (i - 1) * row_h + 4
            local p = tonumber(reg_devices[idx].prefab) or 0
            local n = tonumber(reg_devices[idx].namehash) or 0
            local bound = (p ~= 0 and n ~= 0)
            local device_label = "--"
            if bound then
                for _, dev in ipairs(devs) do
                    if (tonumber(dev.prefab_hash) or 0) == p and (tonumber(dev.name_hash) or 0) == n then
                        device_label = tostring(dev.display_name or device_label)
                        break
                    end
                end
            end

            scroll:element({
                id = "reg_list_hdr_" .. i,
                type = "label",
                rect = { unit = "px", x = 6, y = y + 3, w = 72, h = 16 },
                props = { text = "BPR Box " .. i },
                style = { font_size = 9, color = C.text, align = "left" }
            })

            scroll:element({
                id = "reg_list_name_" .. i,
                type = "label",
                rect = { unit = "px", x = name_x, y = y + 3, w = name_w, h = 16 },
                props = { text = device_label },
                style = { font_size = 9, color = bound and C.text or C.text_dim, align = "left" }
            })

            scroll:element({
                id = "reg_list_change_" .. i,
                type = "button",
                rect = { unit = "px", x = change_x, y = y, w = change_w, h = row_h - 4 },
                props = { text = "Change" },
                style = {
                    bg = C.panel_light, text = C.text, font_size = 8,
                    gradient = "#182133", gradient_dir = "vertical", align = "center"
                },
                on_click = function()
                    reg_picker_idx = idx
                    dashboard_render(true)
                end
            })

            if bound then
                scroll:element({
                    id = "reg_list_clear_" .. i,
                    type = "button",
                    rect = { unit = "px", x = clear_x, y = y, w = clear_w, h = row_h - 4 },
                    props = { text = "Clear" },
                    style = {
                        bg = C.panel_light, text = C.red, font_size = 8,
                        gradient = "#182133", gradient_dir = "vertical", align = "center"
                    },
                    on_click = function()
                        reg_devices[idx].prefab = 0
                        reg_devices[idx].namehash = 0
                        save_reg_state(idx)
                        reg_state[idx] = "off"
                        dashboard_render(true)
                    end
                })
            end
        end
    end

    s:element({
        id = "settings_bg",
        type = "panel",
        rect = { unit = "px", x = panel_x, y = panel_y, w = panel_w, h = panel_h },
        style = { bg = "#0A0A15" }
    })

    render_settings_subtabs()

    local subview_y = tab_y + 28
    if settings_subview == "labels" then
        render_labels_subview(subview_y)
    elseif settings_subview == "reg" then
        render_reg_subview(subview_y)
    else
        render_pa_subview(subview_y)
    end
end

-- ==================== MAIN RENDER ====================

dashboard_render = function(force_rebuild)
    if force_rebuild == nil then
        force_rebuild = true
    end

    local desired = view or "overview"
    if surfaces[desired] == nil then desired = "overview" end
    s = surfaces[desired]

    if force_rebuild or handles.view ~= desired then
        s:clear()
        reset_handles()

        s:element({
            id = "bg",
            type = "panel",
            rect = { unit = "px", x = 0, y = 0, w = W, h = H },
            style = { bg = C.bg }
        })

        render_header()
        render_nav_tabs()

        if desired == "overview" then
            render_overview()
        else
            render_settings()
        end

        render_footer()
        handles.view = desired
        ss.ui.activate(desired)
        s:commit()
        return
    end

    update_nav_dynamic()
    update_header_dynamic()
    update_footer_dynamic()
    if desired == "overview" then
        update_overview_dynamic()
    end

    ss.ui.activate(desired)
    s:commit()
end

set_view = function(name)
    local desired = name or "overview"
    if surfaces[desired] == nil then desired = "overview" end
    view = desired
    s = surfaces[desired]
    ss.ui.activate(desired)
    dashboard_render(true)
end

-- ==================== SERIALIZATION ====================

function serialize()
    local state = {
        view = view,
        settings_subview = settings_subview,
        box_labels = box_labels,
        pa_devices = pa_devices,
        reg_devices = reg_devices,
        pa_pressure_max_range = pa_pressure_max_range,
        pa_volume_max_range = pa_volume_max_range,
        safety_margin_pct = safety_margin_pct,
    }
    local ok, json = pcall(util.json.encode, state)
    if not ok then return nil end
    return json
end

function deserialize(blob)
    if type(blob) ~= "string" or blob == "" then return end
    local ok, decoded = pcall(util.json.decode, blob)
    if not ok or type(decoded) ~= "table" then return end

    if type(decoded.view) == "string" then
        view = decoded.view
    end
    if type(decoded.settings_subview) == "string" then
        settings_subview = decoded.settings_subview
    end

    local decoded_labels = decoded.box_labels or decoded.socket_labels
    if type(decoded_labels) == "table" then
        for i = 1, BOX_COUNT do
            save_box_label(i, decoded_labels[i] or box_labels[i])
        end
    end

    if type(decoded.pa_devices) == "table" then
        for i = 1, BOX_COUNT do
            local item = decoded.pa_devices[i]
            if type(item) == "table" then
                pa_devices[i].prefab = tonumber(item.prefab) or pa_devices[i].prefab
                pa_devices[i].namehash = tonumber(item.namehash) or pa_devices[i].namehash
                save_pa_state(i)
            end
        end
    end

    if type(decoded.reg_devices) == "table" then
        for i = 1, BOX_COUNT do
            local item = decoded.reg_devices[i]
            if type(item) == "table" then
                reg_devices[i].prefab = tonumber(item.prefab) or reg_devices[i].prefab
                reg_devices[i].namehash = tonumber(item.namehash) or reg_devices[i].namehash
                save_reg_state(i)
            end
        end
    end

    pa_pressure_max_range = sanitize_max_range(decoded.pa_pressure_max_range, pa_pressure_max_range)
    pa_volume_max_range = sanitize_max_range(decoded.pa_volume_max_range, pa_volume_max_range)
    if decoded.safety_margin_pct ~= nil then
        safety_margin_pct = sanitize_safety_margin(decoded.safety_margin_pct)
    end
    save_pa_ranges()
    save_safety_margin()
end

-- ==================== BOOT ====================

initialize_settings()
push_all_reg_settings()
set_view(view)

-- ==================== MAIN LOOP ====================

local tick = 0
local resync_counter = 0
local RESYNC_EVERY = 60

while true do
    tick = tick + 1
    elapsed = elapsed + 1
    currenttime = util.clock_time()

    refresh_pa_fast()
    refresh_reg_fast()
    evaluate_and_apply_reg_targets()
    update_header_dynamic()

    if tick % LIVE_REFRESH_TICKS == 0 then
        refresh_pa_slow()
        resync_counter = resync_counter + 1
        if resync_counter >= RESYNC_EVERY then
            resync_counter = 0
            push_all_reg_settings()
        end
        if view == "overview" then
            -- Full rebuild so bar widths reflect fresh readings; update_overview_dynamic
            -- only touches text/style, not element geometry.
            dashboard_render(true)
        end
    end

    ic.yield()
end