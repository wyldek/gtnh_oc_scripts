local component = require("component")
local sides = require("sides")
local computer = require("computer")
local event = require("event")

------------------------------------------------------------
-- CONFIG
------------------------------------------------------------

-- Side of the REDSTONE I/O BLOCK receiving the LSC signal.
-- Change this to sides.north / south / east / west / up / down.
local LSC_SIDE = sides.north

local POLL_SECONDS = 5
local STABLE_AFTER_SECONDS = POLL_SECONDS * 3

-- Optional fixed component addresses. Leave nil to use the first matching component.
local REDSTONE_ADDRESS = nil
local ME_CONTROLLER_ADDRESS = nil

------------------------------------------------------------
-- COMPONENTS
------------------------------------------------------------

local gpu = component.gpu

local function firstComponent(kind, address)
  if address ~= nil and address ~= "" then
    local ok, proxy = pcall(function()
      return component.proxy(address)
    end)

    if ok then
      return proxy
    end

    return nil
  end

  for address in component.list(kind) do
    return component.proxy(address)
  end
  return nil
end

local rs = firstComponent("redstone", REDSTONE_ADDRESS)
local me = firstComponent("me_controller", ME_CONTROLLER_ADDRESS)

------------------------------------------------------------
-- COLORS
------------------------------------------------------------

local C = {
  bg      = 0x000000,
  fg      = 0xFFFFFF,
  dim     = 0x777777,
  title   = 0x55FFFF,
  blue    = 0x5599FF,
  green   = 0x55FF55,
  yellow  = 0xFFFF55,
  red     = 0xFF5555,
  purple  = 0xFF55FF,
  cyan    = 0x55FFFF
}

local W, H = gpu.getResolution()
local lastDrawn = {}

local function key(x, y, width)
  return tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(width)
end

local function setFg(color)
  pcall(function() gpu.setForeground(color) end)
end

local function setBg(color)
  pcall(function() gpu.setBackground(color) end)
end

local function writeField(x, y, width, text, color)
  if width == nil or width <= 0 then return end
  if x < 1 or y < 1 or x > W or y > H then return end

  if x + width - 1 > W then
    width = W - x + 1
  end

  text = tostring(text or "")

  if #text > width then
    if width <= 3 then
      text = string.sub(text, 1, width)
    else
      text = string.sub(text, 1, width - 3) .. "..."
    end
  end

  if #text < width then
    text = text .. string.rep(" ", width - #text)
  end

  local k = key(x, y, width)
  local v = text .. "|" .. tostring(color or C.fg)

  -- Only redraw changed fields.
  if lastDrawn[k] == v then return end
  lastDrawn[k] = v

  setFg(color or C.fg)
  gpu.set(x, y, text)
end

local function forceWriteField(x, y, width, text, color)
  local k = key(x, y, width)
  lastDrawn[k] = nil
  writeField(x, y, width, text, color)
end

local function drawStaticText(x, y, text, color)
  setFg(color or C.fg)
  gpu.set(x, y, tostring(text))
end

local function fill(x, y, width, height, char)
  if width <= 0 or height <= 0 then return end
  gpu.fill(x, y, width, height, char or " ")
end

local function drawBox(x, y, width, height, title, color)
  if width < 4 or height < 3 then return end

  setFg(color or C.fg)
  gpu.set(x, y, "+" .. string.rep("-", width - 2) .. "+")

  for row = y + 1, y + height - 2 do
    gpu.set(x, row, "|")
    gpu.set(x + width - 1, row, "|")
  end

  gpu.set(x, y + height - 1, "+" .. string.rep("-", width - 2) .. "+")

  if title then
    drawStaticText(x + 2, y, " " .. title .. " ", C.title)
  end
end

local function pctColor(pct)
  if pct <= 20 then return C.red end
  if pct <= 50 then return C.yellow end
  return C.green
end

local lastBar = ""

local function drawBar(x, y, width, pct, color)
  if width < 4 then return end

  pct = math.max(0, math.min(100, pct))
  local inner = width - 2
  local filled = math.floor((pct / 100) * inner + 0.5)

  local barText = "[" .. string.rep("#", filled) .. string.rep("-", inner - filled) .. "]"
  local state = barText .. "|" .. tostring(color)

  if lastBar == state then return end
  lastBar = state

  writeField(x, y, 1, "[", C.dim)

  if filled > 0 then
    writeField(x + 1, y, filled, string.rep("#", filled), color)
  end

  if inner - filled > 0 then
    writeField(x + 1 + filled, y, inner - filled, string.rep("-", inner - filled), C.dim)
  end

  writeField(x + width - 1, y, 1, "]", C.dim)
end

------------------------------------------------------------
-- DATA HELPERS
------------------------------------------------------------

local function cpuBusy(entry)
  if entry.busy ~= nil then return entry.busy end
  if entry.isBusy ~= nil then return entry.isBusy end
  return false
end

local function cleanItemName(raw)
  if raw == nil then return nil end

  raw = tostring(raw)

  -- Prefer clean labels like "Glowstone Dust".
  if raw ~= "" then
    return raw
  end

  return nil
end

local function itemToName(v)
  if v == nil then return nil end

  if type(v) == "string" then
    return v
  end

  if type(v) ~= "table" then
    return tostring(v)
  end

  -- Your example finalOutput table has:
  -- size = 10
  -- label = Glowstone Dust
  -- name = minecraft:glowstone_dust
  local amount = v.size or v.amount or v.count
  local label = cleanItemName(v.label or v.displayName or v.display_name or v.itemLabel)
  local technical = cleanItemName(v.name or v.id or v.item)

  local name = label or technical

  if name == nil then
    return nil
  end

  if amount ~= nil then
    return tostring(amount) .. " " .. name
  end

  return name
end

local function finalOutputFromEntry(entry)
  if entry == nil then
    return nil, "no cpu entry"
  end

  -- GTNH shape seen from your test:
  -- me.getCpus()[i].cpu.finalOutput()
  if entry.cpu ~= nil and entry.cpu.finalOutput ~= nil then
    local ok, result, err = pcall(function()
      return entry.cpu.finalOutput()
    end)

    if not ok then
      return nil, tostring(result)
    end

    if result ~= nil then
      return result, nil
    end

    if err ~= nil then
      return nil, tostring(err)
    end

    return nil, "no final output"
  end

  -- Fallback if another version exposes finalOutput directly.
  if entry.finalOutput ~= nil then
    local ok, result, err = pcall(function()
      return entry.finalOutput()
    end)

    if not ok then
      return nil, tostring(result)
    end

    if result ~= nil then
      return result, nil
    end

    if err ~= nil then
      return nil, tostring(err)
    end

    return nil, "no final output"
  end

  return nil, "no finalOutput method"
end

local function jobNameForEntry(entry)
  local output, err = finalOutputFromEntry(entry)

  local name = itemToName(output)
  if name ~= nil and name ~= "" then
    return name
  end

  if err ~= nil then
    local lower = string.lower(tostring(err))

    if string.find(lower, "no crafting monitor") then
      return "no crafting monitor"
    end

    return tostring(err)
  end

  return "craft unknown"
end

local function fmtDuration(seconds)
  seconds = math.max(0, math.floor(seconds or 0))

  local h = math.floor(seconds / 3600)
  local m = math.floor((seconds % 3600) / 60)
  local s = seconds % 60

  if h > 0 then
    return string.format("%dh%02dm", h, m)
  elseif m > 0 then
    return string.format("%dm%02ds", m, s)
  else
    return string.format("%ds", s)
  end
end

local function cpuKey(i, entry)
  return tostring(entry.name or ("CPU " .. i)) .. ":" ..
         tostring(entry.storage or "?") .. ":" ..
         tostring(entry.coprocessors or "?") .. ":" ..
         tostring(i)
end

local function cpuDisplayName(i, entry)
  local name = entry.name or ("CPU " .. tostring(i))
  local details = {}

  if entry.storage ~= nil then
    table.insert(details, tostring(entry.storage) .. "B")
  end

  if entry.coprocessors ~= nil then
    table.insert(details, tostring(entry.coprocessors) .. " co")
  end

  if #details == 0 then
    return name
  end

  return name .. " (" .. table.concat(details, ", ") .. ")"
end

local function sortedCpus(cpus)
  local list = {}

  for i, entry in pairs(cpus or {}) do
    if type(entry) == "table" then
      table.insert(list, {
        index = i,
        entry = entry,
        busy = cpuBusy(entry),
        name = tostring(entry.name or ("CPU " .. tostring(i)))
      })
    end
  end

  table.sort(list, function(a, b)
    if a.busy ~= b.busy then
      return a.busy
    end

    if a.name ~= b.name then
      return a.name < b.name
    end

    return tostring(a.index) < tostring(b.index)
  end)

  return list
end

------------------------------------------------------------
-- STATIC UI
------------------------------------------------------------

local function drawStatic()
  W, H = gpu.getResolution()
  lastDrawn = {}
  lastBar = ""

  setBg(C.bg)
  setFg(C.fg)
  fill(1, 1, W, H, " ")

  drawStaticText(2, 1, "GTNH BASE STATUS CENTER", C.title)
  drawStaticText(W - 18, 1, "Refresh: " .. POLL_SECONDS .. "s", C.dim)
  drawStaticText(math.max(1, W - 8), H, "Q: quit", C.dim)

  drawBox(1, 3, W, 8, " POWER / LSC ", C.blue)
  drawStaticText(3, 5, "LSC Fill:", C.fg)
  drawStaticText(3, 8, "Signal:", C.dim)
  drawStaticText(28, 8, "Trend:", C.dim)

  drawBox(1, 12, W, H - 12, " AE2 CRAFTING CPUS ", C.purple)
  drawStaticText(3, 14, "CPUs:", C.dim)
  drawStaticText(18, 14, "Busy:", C.dim)
  drawStaticText(35, 14, "Idle:", C.dim)

  drawStaticText(3, 16, " #  STAT   TIME     JOB / CPU", C.dim)
  drawStaticText(3, 17, string.rep("-", math.min(W - 6, 78)), C.dim)
end

------------------------------------------------------------
-- STATE
------------------------------------------------------------

local lastSignal = nil
local lastChangeTime = nil
local trend = "stable"

-- Tracks when each CPU became busy and what final output it was crafting.
local cpuState = {}

------------------------------------------------------------
-- POWER UPDATE
------------------------------------------------------------

local function updatePower()
  if rs == nil then
    writeField(3, 6, W - 6, "No redstone component found", C.red)
    return
  end

  local ok, signal = pcall(function()
    return rs.getInput(LSC_SIDE)
  end)

  if not ok then
    writeField(3, 6, W - 6, "Redstone read failed: " .. tostring(signal), C.red)
    return
  end

  signal = signal or 0
  local pct = math.floor((signal * 100 / 15) + 0.5)
  local pc = pctColor(pct)

  if lastSignal ~= nil then
    if signal > lastSignal then
      trend = "charging"
      lastChangeTime = computer.uptime()
    elseif signal < lastSignal then
      trend = "draining"
      lastChangeTime = computer.uptime()
    end
  end

  lastSignal = signal

  if lastChangeTime ~= nil and computer.uptime() - lastChangeTime >= STABLE_AFTER_SECONDS then
    trend = "stable"
  end

  writeField(14, 5, 8, tostring(pct) .. "%", pc)
  drawBar(3, 6, math.min(W - 6, 50), pct, pc)
  writeField(13, 8, 10, tostring(signal) .. " / 15", C.fg)

  local trendColor = C.dim
  if trend == "charging" then trendColor = C.green end
  if trend == "draining" then trendColor = C.red end

  writeField(36, 8, 14, trend, trendColor)

  if lastChangeTime then
    local age = math.floor(computer.uptime() - lastChangeTime)
    writeField(52, 8, W - 52, "Last change: " .. age .. "s ago", C.dim)
  else
    writeField(52, 8, W - 52, "Initial reading", C.dim)
  end
end

------------------------------------------------------------
-- CPU UPDATE
------------------------------------------------------------

local function clearCpuRow(y)
  forceWriteField(2, y, W - 2, "", C.fg)
  drawStaticText(1, y, "|", C.purple)
  drawStaticText(W, y, "|", C.purple)
end

local function updateCpus()
  local firstRow = 18
  local lastRow = H - 1

  if me == nil then
    writeField(3, firstRow, W - 6, "No me_controller component found", C.red)
    return
  end

  local ok, cpus = pcall(function()
    return me.getCpus()
  end)

  if not ok then
    writeField(3, firstRow, W - 6, "getCpus failed: " .. tostring(cpus), C.red)
    return
  end

  local now = computer.uptime()
  local busyCount = 0
  local activeKeys = {}
  local cpuList = sortedCpus(cpus)

  for _, cpu in ipairs(cpuList) do
    local i = cpu.index
    local entry = cpu.entry
    local key = cpuKey(i, entry)
    local busy = cpuBusy(entry)
    local job = busy and jobNameForEntry(entry) or ""

    activeKeys[key] = true

    local st = cpuState[key]
    if st == nil then
      st = {
        busy = busy,
        job = job,
        start = busy and now or nil
      }
      cpuState[key] = st
    end

    if busy then
      busyCount = busyCount + 1

      -- Reset timer when CPU starts a new job or final output changes.
      if not st.busy or st.job ~= job then
        st.start = now
        st.job = job
      end
    else
      st.start = nil
      st.job = ""
    end

    st.busy = busy
  end

  for keyName, _ in pairs(cpuState) do
    if not activeKeys[keyName] then
      cpuState[keyName] = nil
    end
  end

  writeField(10, 14, 5, tostring(#cpuList), C.fg)
  writeField(25, 14, 5, tostring(busyCount), busyCount > 0 and C.yellow or C.green)
  writeField(41, 14, 5, tostring(#cpuList - busyCount), C.green)

  if #cpuList == 0 then
    writeField(3, firstRow, W - 6, "No crafting CPUs found", C.dim)
    return
  end

  local y = firstRow

  for _, cpu in ipairs(cpuList) do
    if y > lastRow then
      writeField(3, lastRow, W - 6, "...more CPUs not shown", C.dim)
      break
    end

    local i = cpu.index
    local entry = cpu.entry
    local keyName = cpuKey(i, entry)
    local st = cpuState[keyName]
    local busy = cpuBusy(entry)

    local status = busy and "BUSY" or "idle"
    local statusColor = busy and C.yellow or C.green

    local duration = "-"
    if busy and st and st.start then
      duration = fmtDuration(now - st.start)
    end

    local job
    local jobColor

    if busy then
      job = st.job or jobNameForEntry(entry)

      if job == "no crafting monitor" then
        jobColor = C.red
      else
        jobColor = C.fg
      end
    else
      job = cpuDisplayName(i, entry)
      jobColor = C.dim
    end

    writeField(3, y, 3, tostring(i), C.dim)
    writeField(7, y, 5, status, statusColor)
    writeField(14, y, 8, duration, busy and C.cyan or C.dim)
    writeField(23, y, W - 25, job, jobColor)

    y = y + 1
  end

  while y <= lastRow do
    clearCpuRow(y)
    y = y + 1
  end
end

------------------------------------------------------------
-- MAIN
------------------------------------------------------------

local function showLoopError(err)
  writeField(2, H, W - 10, "Error: " .. tostring(err), C.red)
end

local function shouldQuit(signal, _, char)
  if signal ~= "key_down" then
    return false
  end

  return char == string.byte("q") or char == string.byte("Q")
end

drawStatic()

while true do
  local currentW, currentH = gpu.getResolution()
  if currentW ~= W or currentH ~= H then
    drawStatic()
  end

  local ok, err = pcall(function()
    updatePower()
    updateCpus()
  end)

  if not ok then
    showLoopError(err)
  end

  if shouldQuit(event.pull(POLL_SECONDS)) then
    break
  end
end

setBg(C.bg)
setFg(C.dim)
fill(1, H, W, 1, " ")
gpu.set(2, H, "Status dashboard stopped.")
