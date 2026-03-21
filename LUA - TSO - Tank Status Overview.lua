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
-- Slots 0-11:   Box 1-12 PA prefab hashes
-- Slots 12-23:  Box 1-12 PA name hashes
-- Slots 24-35:  Box 1-12 label text hashes (legacy)
-- Slots 36-143: Box 1-12 label strings (len + 8 data slots each, 3 chars/slot)
-- Slots 144-145: Max ranges (pressure kPa, volume L)

local MEM_PA_PREFAB_BEGIN = 0
local MEM_PA_NAMEHASH_BEGIN = 12
local MEM_LABELHASH_BEGIN = 24
local MEM_LABELSTR_BEGIN = 36
local MEM_PRESSURE_MAX = 144
local MEM_VOLUME_MAX = 145

local LABEL_MAX_CHARS = 24
local LABEL_CHARS_PER_SLOT = 3
local LABEL_DATA_SLOTS = 8
local LABEL_SLOT_STRIDE = 1 + LABEL_DATA_SLOTS

local PA_PREFAB_FILTERS = {
    gas = hash("StructurePipeAnalysizer"),
    liquid = hash("StructureLiquidPipeAnalyzer"),
}

-- ==================== STATE ====================

local box_labels = {}
local pa_devices = {}
local pa_readings = {}
local pa_dropdown_selected = {}
local pa_dropdown_open = {}
local settings_subview = "labels"
local pa_settings_page = 1
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
    pa_dropdown_selected[i] = 0
    pa_dropdown_open[i] = "false"
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

local function device_matches_prefabs(dev, allowed_prefabs)
    local prefab_hash = tonumber(dev and dev.prefab_hash) or 0
    for _, allowed in ipairs(allowed_prefabs) do
        if prefab_hash == allowed then
            return true
        end
    end
    return false
end

local function build_filtered_device_options(devices, allowed_prefabs, current_device)
    local options = { "Select device..." }
    local candidates = {}
    local selected = 0

    for i, dev in ipairs(devices) do
        if device_matches_prefabs(dev, allowed_prefabs) then
            local label = tostring((dev and dev.display_name) or ("Device " .. i))
            label = label:gsub("|", "/")
            table.insert(options, label)
            table.insert(candidates, dev)

            local prefab_hash = tonumber(dev and dev.prefab_hash) or 0
            local name_hash = tonumber(dev and dev.name_hash) or 0
            local current_prefab = (current_device.prefab or 0)
            local current_namehash = (current_device.namehash or 0)
            if current_prefab ~= 0
                and current_namehash ~= 0
                and prefab_hash == current_prefab
                and name_hash == current_namehash then
                selected = #candidates
            end
        end
    end

    if #candidates == 0 then
        options[1] = "No devices found"
    end

    return options, candidates, selected
end

local function refresh_pa_readings()
    for i = 1, BOX_COUNT do
        local device = pa_devices[i]
        local prefab = tonumber(device.prefab) or 0
        local namehash = tonumber(device.namehash) or 0

        if prefab ~= 0 and namehash ~= 0 then
            pa_readings[i].pressure = safe_batch_read_name(prefab, namehash, LT.Pressure, LBM.Average)
            pa_readings[i].temperature = safe_batch_read_name(prefab, namehash, LT.Temperature, LBM.Average)
            pa_readings[i].volume = safe_batch_read_name(prefab, namehash, LT.VolumeOfLiquid, LBM.Average)
            pa_readings[i].network_fault = safe_batch_read_name(prefab, namehash, LT.NetworkFault, LBM.Average)
        else
            pa_readings[i].pressure = nil
            pa_readings[i].temperature = nil
            pa_readings[i].volume = nil
            pa_readings[i].network_fault = nil
        end
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
end

-- ==================== INITIALIZATION ====================

local function initialize_settings()
    for i = 1, BOX_COUNT do
        pa_devices[i].prefab = tonumber(read(MEM_PA_PREFAB_BEGIN + i - 1)) or 0
        pa_devices[i].namehash = tonumber(read(MEM_PA_NAMEHASH_BEGIN + i - 1)) or 0
        box_labels[i] = load_box_label(i)
    end

    pa_pressure_max_range = sanitize_max_range(read(MEM_PRESSURE_MAX), pa_pressure_max_range)
    pa_volume_max_range = sanitize_max_range(read(MEM_VOLUME_MAX), pa_volume_max_range)
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

    if handles.header.status_dot ~= nil then
        handles.header.status_dot:set_style({ bg = status_color })
    end

    if handles.header.status_label ~= nil then
        handles.header.status_label:set_props({ text = status_text })
        handles.header.status_label:set_style({ font_size = 11, color = status_color, align = "left" })
    end
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
    if handles.nav.overview ~= nil then
        local active = view == "overview"
        handles.nav.overview:set_style({
            bg = active and "#6844aa" or "#333344",
            text = "#FFFFFF",
            font_size = 11,
            gradient = active and "#3b1f88" or "#1c1c2e",
            gradient_dir = "vertical"
        })
    end

    if handles.nav.settings ~= nil then
        local active = view == "settings"
        handles.nav.settings:set_style({
            bg = active and "#6844aa" or "#333344",
            text = "#FFFFFF",
            font_size = 11,
            gradient = active and "#3b1f88" or "#1c1c2e",
            gradient_dir = "vertical"
        })
    end
end

local function update_footer_dynamic()
    local gt = util.game_time()
    local gtH = math.floor(gt / 3600)
    local gtM = math.floor((gt % 3600) / 60)

    if handles.footer.left ~= nil then
        handles.footer.left:set_props({ text = "Time: " .. currenttime })
    end
    if handles.footer.right ~= nil then
        handles.footer.right:set_props({ text = string.format("Tick %.0f | ELAPSED %dh %02dm", math.floor(elapsed), gtH, gtM) })
    end
end

-- ==================== OVERVIEW (12 BOXES) ====================

local function render_overview_box(idx, x, y, w, h)
    local r = pa_readings[idx]
    local p_pct = bar_percent(r.pressure, pa_pressure_max_range)
    local v_pct = bar_percent(r.volume, pa_volume_max_range)
    local temp_label_y = y + 15
    local temp_value_y = y + 23
    local pressure_row_y = y + 34
    local pressure_bar_y = y + 43
    local volume_row_y = y + 51
    local volume_bar_y = y + 60

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
        rect = { unit = "px", x = x + 6, y = pressure_bar_y, w = w - 12, h = 5 },
        style = { bg = C.bar_bg }
    })

    handles.overview["box_" .. idx .. "_p_bar_fill"] = s:element({
        id = "box_" .. idx .. "_p_bar_fill",
        type = "panel",
        rect = { unit = "px", x = x + 6, y = pressure_bar_y, w = math.max(1, math.floor((w - 12) * p_pct / 100)), h = 5 },
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
        rect = { unit = "px", x = x + 6, y = volume_bar_y, w = w - 12, h = 5 },
        style = { bg = C.bar_bg }
    })

    handles.overview["box_" .. idx .. "_v_bar_fill"] = s:element({
        id = "box_" .. idx .. "_v_bar_fill",
        type = "panel",
        rect = { unit = "px", x = x + 6, y = volume_bar_y, w = math.max(1, math.floor((w - 12) * v_pct / 100)), h = 5 },
        style = { bg = volume_value_color(r.volume) }
    })
end

local function render_overview()
    local top = 58
    local bottom = H - 22
    local left = 6
    local right = W - 6
    local cols = 3
    local rows = 4
    local gap_x = 6
    local gap_y = 6

    local grid_w = right - left
    local grid_h = bottom - top
    local box_w = math.floor((grid_w - gap_x * (cols - 1)) / cols)
    local box_h = math.floor((grid_h - gap_y * (rows - 1)) / rows)

    local idx = 1
    for r = 0, rows - 1 do
        for c = 0, cols - 1 do
            local x = left + c * (box_w + gap_x)
            local y = top + r * (box_h + gap_y)
            render_overview_box(idx, x, y, box_w, box_h)
            idx = idx + 1
        end
    end
end

local function update_overview_dynamic()
    for idx = 1, BOX_COUNT do
        local r = pa_readings[idx]

        if handles.overview["box_" .. idx .. "_label"] ~= nil then
            handles.overview["box_" .. idx .. "_label"]:set_props({ text = box_labels[idx] })
        end
        if handles.overview["box_" .. idx .. "_p_value"] ~= nil then
            handles.overview["box_" .. idx .. "_p_value"]:set_props({ text = format_pressure_label(r.pressure) .. " [" .. percent_text(r.pressure, pa_pressure_max_range) .. "]" })
            handles.overview["box_" .. idx .. "_p_value"]:set_style({ font_size = 7, color = pressure_value_color(r.pressure), align = "left" })
        end
        if handles.overview["box_" .. idx .. "_v_value"] ~= nil then
            handles.overview["box_" .. idx .. "_v_value"]:set_props({ text = format_volume_label(r.volume) .. " [" .. percent_text(r.volume, pa_volume_max_range) .. "]" })
            handles.overview["box_" .. idx .. "_v_value"]:set_style({ font_size = 7, color = volume_value_color(r.volume), align = "left" })
        end
        if handles.overview["box_" .. idx .. "_t_value"] ~= nil then
            handles.overview["box_" .. idx .. "_t_value"]:set_props({ text = format_temperature_label(r.temperature) })
            handles.overview["box_" .. idx .. "_t_value"]:set_style({ font_size = 7, color = temperature_value_color(r.temperature), align = "center" })
        end

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
    local tab_w = math.floor((panel_w - 14) / 2)
    local devices = device_list() or {}

    local function render_settings_subtabs()
        local tabs = {
            { id = "settings_labels", text = "LABELS", key = "labels" },
            { id = "settings_pa", text = "PA", key = "pa" },
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

    local function render_pa_subview(base_y)
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
            end
        })

        local start_idx = pa_settings_page == 1 and 1 or 7
        local end_idx = math.min(start_idx + 5, BOX_COUNT)

        for i = start_idx, end_idx do
            local idx = i
            local row = i - start_idx
            local row_y = base_y + 48 + row * 23
            local col_x = panel_x + 14

            local options, candidates, selected_index = build_filtered_device_options(
                devices,
                { PA_PREFAB_FILTERS.gas, PA_PREFAB_FILTERS.liquid },
                pa_devices[idx]
            )
            local row_candidates = candidates

            pa_dropdown_selected[idx] = selected_index

            s:element({
                id = "pa_" .. i .. "_header",
                type = "label",
                rect = { unit = "px", x = col_x, y = row_y + 2, w = 70, h = 14 },
                props = { text = "PA Box " .. i },
                style = { font_size = 8, color = C.text, align = "left" }
            })

            s:element({
                id = "pa_" .. i .. "_dropdown",
                type = "select",
                rect = { unit = "px", x = col_x + 70, y = row_y, w = 300, h = 20 },
                props = {
                    options = table.concat(options, "|"),
                    selected = pa_dropdown_selected[idx],
                    open = pa_dropdown_open[idx],
                },
                on_toggle = function()
                    pa_dropdown_open[idx] = pa_dropdown_open[idx] == "true" and "false" or "true"
                    dashboard_render(true)
                end,
                on_change = function(optionIndex)
                    local selected_option = tonumber(optionIndex) or 0
                    pa_dropdown_selected[idx] = selected_option
                    pa_dropdown_open[idx] = "false"

                    if selected_option == 0 then
                        pa_devices[idx].prefab = 0
                        pa_devices[idx].namehash = 0
                    else
                        local picked = row_candidates[selected_option]
                        if picked ~= nil then
                            pa_devices[idx].prefab = tonumber(picked.prefab_hash) or 0
                            pa_devices[idx].namehash = tonumber(picked.name_hash) or 0
                        end
                    end

                    save_pa_state(idx)
                    dashboard_render(true)
                end
            })
        end

        local page_button_y = base_y + 48 + (math.min(6, end_idx - start_idx + 1) * 23) + 4

        s:element({
            id = "pa_page_1_btn",
            type = "button",
            rect = { unit = "px", x = panel_x + 172, y = page_button_y, w = 56, h = 20 },
            props = { text = "1-6" },
            style = {
                bg = pa_settings_page == 1 and C.accent or C.panel_light,
                text = pa_settings_page == 1 and C.bg or C.text,
                font_size = 8,
                gradient = pa_settings_page == 1 and "#0f4c63" or "#182133",
                gradient_dir = "vertical"
            },
            on_click = function()
                pa_settings_page = 1
                dashboard_render(true)
            end
        })

        s:element({
            id = "pa_page_2_btn",
            type = "button",
            rect = { unit = "px", x = panel_x + 236, y = page_button_y, w = 56, h = 20 },
            props = { text = "7-12" },
            style = {
                bg = pa_settings_page == 2 and C.accent or C.panel_light,
                text = pa_settings_page == 2 and C.bg or C.text,
                font_size = 8,
                gradient = pa_settings_page == 2 and "#0f4c63" or "#182133",
                gradient_dir = "vertical"
            },
            on_click = function()
                pa_settings_page = 2
                dashboard_render(true)
            end
        })
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

    if desired == "overview" then
        refresh_pa_readings()
    end

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
        pa_pressure_max_range = pa_pressure_max_range,
        pa_volume_max_range = pa_volume_max_range,
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

    pa_pressure_max_range = sanitize_max_range(decoded.pa_pressure_max_range, pa_pressure_max_range)
    pa_volume_max_range = sanitize_max_range(decoded.pa_volume_max_range, pa_volume_max_range)
    save_pa_ranges()
end

-- ==================== BOOT ====================

initialize_settings()
set_view(view)

-- ==================== MAIN LOOP ====================

local tick = 0
while true do
    tick = tick + 1
    elapsed = elapsed + 1
    currenttime = util.clock_time()

    if tick % LIVE_REFRESH_TICKS == 0 then
        if view == "overview" then
            dashboard_render(true)
        end
    end

    ic.yield()
end