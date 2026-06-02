local component = require("component")
local computer = require("computer")
local event = require("event")

------------------------------------------------------------
-- CONFIG
------------------------------------------------------------

local POLL_SECONDS = 5

-- Optional fixed component settings.
local LSC_ADDRESS = nil
local LSC_COMPONENT_TYPE = "LSC"
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

local function componentType(address)
  local ok, kind = pcall(function()
    return component.type(address)
  end)

  if ok then return kind end
  return "unknown"
end

local function findLscComponent()
  if LSC_ADDRESS ~= nil and LSC_ADDRESS ~= "" then
    return firstComponent(nil, LSC_ADDRESS), LSC_ADDRESS, componentType(LSC_ADDRESS)
  end

  for address in component.list(LSC_COMPONENT_TYPE) do
    return component.proxy(address), address, componentType(address)
  end

  return nil, nil, nil
end

local lsc, lscAddress, lscType = findLscComponent()
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

local function fmtNumber(value)
  if value == nil then return "?" end

  local sign = ""
  local n = tonumber(value) or 0
  if n < 0 then
    sign = "-"
    n = -n
  end

  local text = tostring(math.floor(n + 0.5))

  while true do
    local nextText, changed = string.gsub(text, "^(-?%d+)(%d%d%d)", "%1,%2")
    text = nextText
    if changed == 0 then break end
  end

  return sign .. text
end

local function fmtSignedRateEuT(rateEuPerSecond)
  if rateEuPerSecond == nil then return "?" end

  local euPerTick = rateEuPerSecond / 20
  local prefix = ""
  if euPerTick > 0 then prefix = "+" end

  return prefix .. fmtNumber(euPerTick) .. " EU/t"
end

local function fmtSignedRateMbS(rateMbPerSecond)
  if rateMbPerSecond == nil then return "?" end

  local prefix = ""
  if rateMbPerSecond > 0 then prefix = "+" end

  return prefix .. fmtNumber(rateMbPerSecond) .. " mB/s"
end

local function callNumber(proxy, methodName)
  if proxy == nil then
    return nil, "no component"
  end

  local method = proxy[methodName]
  if type(method) ~= "function" then
    return nil, "missing " .. methodName
  end

  local ok, value = pcall(method)
  if not ok then
    return nil, tostring(value)
  end

  if value == nil then
    return nil, methodName .. " returned nil"
  end

  return tonumber(value), nil
end

local function shortAddress(address)
  if address == nil then return "auto" end
  return string.sub(tostring(address), 1, 8)
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

  drawBox(1, 3, W, 10, " POWER / LSC ", C.blue)
  drawStaticText(3, 5, "LSC Fill:", C.fg)
  drawStaticText(30, 5, "Stored:", C.dim)
  drawStaticText(3, 8, "Net:", C.dim)
  drawStaticText(30, 8, "ETA:", C.dim)
  drawStaticText(3, 10, "I/O:", C.dim)
  drawStaticText(30, 10, "Adapter:", C.dim)

  drawBox(1, 14, W, 6, " AE2 FLUID NET ", C.cyan)
  drawStaticText(3, 16, "Benzene:", C.dim)
  drawStaticText(3, 17, "Nitrobenzene:", C.dim)
  drawStaticText(28, 15, "Stored", C.dim)
  drawStaticText(48, 15, "Net", C.dim)

  drawBox(1, 21, W, H - 21, " AE2 CRAFTING CPUS ", C.purple)
  drawStaticText(3, 23, "CPUs:", C.dim)
  drawStaticText(18, 23, "Busy:", C.dim)
  drawStaticText(35, 23, "Idle:", C.dim)

  drawStaticText(3, 25, " #  STAT   TIME     JOB / CPU", C.dim)
  drawStaticText(3, 26, string.rep("-", math.min(W - 6, 78)), C.dim)
end

------------------------------------------------------------
-- STATE
------------------------------------------------------------

local lastEnergy = nil
local lastEnergyTime = nil
local netRateEuPerSecond = nil

local fluidState = {
  benzene = { label = "Benzene", name = "benzene" },
  nitrobenzene = { label = "Nitrobenzene", name = "nitrobenzene" }
}

-- Tracks when each CPU became busy and what final output it was crafting.
local cpuState = {}

------------------------------------------------------------
-- POWER UPDATE
------------------------------------------------------------

local function updatePower()
  if lsc == nil then
    writeField(3, 6, W - 6, "No LSC adapter component found", C.red)
    return
  end

  local stored, storedErr = callNumber(lsc, "getStoredEU")
  local capacity, capacityErr = callNumber(lsc, "getEUCapacity")

  if stored == nil or capacity == nil or capacity <= 0 then
    writeField(3, 6, W - 6, "LSC read failed: " .. tostring(storedErr or capacityErr), C.red)
    return
  end

  local now = computer.uptime()
  local pct = math.floor((stored * 100 / capacity) + 0.5)
  local pc = pctColor(pct)

  if lastEnergy ~= nil and lastEnergyTime ~= nil then
    local elapsed = now - lastEnergyTime
    if elapsed > 0 then
      netRateEuPerSecond = (stored - lastEnergy) / elapsed
    end
  end

  lastEnergy = stored
  lastEnergyTime = now

  writeField(14, 5, 8, tostring(pct) .. "%", pc)
  drawBar(3, 6, math.min(W - 6, 50), pct, pc)
  writeField(38, 5, W - 40, fmtNumber(stored) .. " / " .. fmtNumber(capacity) .. " EU", C.fg)

  local rateColor = C.dim
  if netRateEuPerSecond ~= nil and netRateEuPerSecond > 0 then rateColor = C.green end
  if netRateEuPerSecond ~= nil and netRateEuPerSecond < 0 then rateColor = C.red end
  writeField(8, 8, 20, fmtSignedRateEuT(netRateEuPerSecond), rateColor)

  local eta = "stable"
  local etaColor = C.dim
  if netRateEuPerSecond ~= nil and netRateEuPerSecond > 0 then
    eta = "Full in " .. fmtDuration((capacity - stored) / netRateEuPerSecond)
    etaColor = C.green
  elseif netRateEuPerSecond ~= nil and netRateEuPerSecond < 0 then
    eta = "Empty in " .. fmtDuration(stored / -netRateEuPerSecond)
    etaColor = C.red
  end
  writeField(35, 8, W - 37, eta, etaColor)

  writeField(8, 10, 20, "n/a", C.dim)

  writeField(39, 10, W - 41, tostring(lscType or "adapter") .. " " .. shortAddress(lscAddress), C.dim)
end

------------------------------------------------------------
-- FLUID UPDATE
------------------------------------------------------------

local function getFluidAmount(fluidName)
  if me == nil then
    return nil, "no me_controller"
  end

  if type(me.getFluidInNetwork) ~= "function" then
    return nil, "missing getFluidInNetwork"
  end

  local ok, stack = pcall(function()
    return me.getFluidInNetwork(fluidName)
  end)

  if not ok then
    return nil, tostring(stack)
  end

  if stack == nil then
    return 0, nil
  end

  return tonumber(stack.size or stack.amount or 0) or 0, nil
end

local function updateFluidRow(y, fluid)
  local amount, err = getFluidAmount(fluid.name)

  if amount == nil then
    writeField(15, y, W - 17, err, C.red)
    return
  end

  local now = computer.uptime()
  local rate = nil

  if fluid.amount ~= nil and fluid.time ~= nil then
    local elapsed = now - fluid.time
    if elapsed > 0 then
      rate = (amount - fluid.amount) / elapsed
    end
  end

  fluid.amount = amount
  fluid.time = now

  local rateColor = C.dim
  if rate ~= nil and rate > 0 then rateColor = C.green end
  if rate ~= nil and rate < 0 then rateColor = C.red end

  writeField(15, y, 25, fmtNumber(amount) .. " mB", C.fg)
  writeField(48, y, W - 50, fmtSignedRateMbS(rate), rateColor)
end

local function updateFluids()
  updateFluidRow(16, fluidState.benzene)
  updateFluidRow(17, fluidState.nitrobenzene)
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
  local firstRow = 27
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

  writeField(10, 23, 5, tostring(#cpuList), C.fg)
  writeField(25, 23, 5, tostring(busyCount), busyCount > 0 and C.yellow or C.green)
  writeField(41, 23, 5, tostring(#cpuList - busyCount), C.green)

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
    updateFluids()
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
