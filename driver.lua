DRIVER_GITHUB_REPO = "black-ops-drivers/control4-controlbyweb"
DRIVER_FILENAMES = {
  "controlbyweb.c4z",
}
--
require("lib.utils")
require("vendor.drivers-common-public.global.handlers")
require("vendor.drivers-common-public.global.lib")
require("vendor.drivers-common-public.global.timer")
require("vendor.drivers-common-public.global.url")

JSON = require("vendor.JSON")

local log = require("lib.logging")
local bindings = require("lib.bindings")
local githubUpdater = require("lib.github-updater")

local api = require("api")

local function updateStatus(status)
  UpdateProperty("Driver Status", not IsEmpty(status) and status or "Unknown")
end

function OnDriverLateInit()
  if not CheckMinimumVersion() then
    return
  end
  gInitialized = false
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  log:trace("OnDriverLateInit()")

  C4:AllowExecute(true)
  C4:FileSetDir("c29tZXNwZWNpYWxrZXk=++11")
  bindings:restoreBindings()

  -- Fire OnPropertyChanged to set the initial Headers and other Property
  -- global sets, they'll change if Property is changed.
  for p, _ in pairs(Properties) do
    local status, err = pcall(OnPropertyChanged, p)
    if not status then
      log:error(err)
    end
  end
  gInitialized = true
  Connect()
end

function OPC.Driver_Version(propertyValue)
  log:trace("OPC.Driver_Version('%s')", propertyValue)
  C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
end

function OPC.Log_Mode(propertyValue)
  log:trace("OPC.Log_Mode('%s')", propertyValue)
  log:setLogMode(propertyValue)
  CancelTimer("LogMode")
  if not log:isEnabled() then
    return
  end
  log:warn("Log mode '%s' will expire in 3 hours", propertyValue)
  SetTimer("LogMode", 3 * ONE_HOUR, function()
    log:warn("Setting log mode to 'Off' (timer expired)")
    UpdateProperty("Log Mode", "Off", true)
  end)
end

function OPC.Log_Level(propertyValue)
  log:trace("OPC.Log_Level('%s')", propertyValue)
  log:setLogLevel(propertyValue)
  if log:getLogLevel() >= 6 and log:isPrintEnabled() then
    DEBUGPRINT = true
    DEBUG_TIMER = true
    DEBUG_RFN = true
    DEBUG_URL = true
  else
    DEBUGPRINT = false
    DEBUG_TIMER = false
    DEBUG_RFN = false
    DEBUG_URL = false
  end
end

function OPC.IP_Address(propertyValue)
  log:trace("OPC.IP_Address('%s')", propertyValue)
  api:setIpAddress(propertyValue)
  Connect()
end

function OPC.Username(propertyValue)
  log:trace("OPC.Username('%s')", propertyValue)
  api:setUsername(propertyValue)
  Connect()
end

function OPC.Password(propertyValue)
  log:trace("OPC.Password('%s')", not IsEmpty(propertyValue) and "****" or "")
  api:setPassword(propertyValue)
  Connect()
end

function Connect()
  log:trace("Connect()")
  if not gInitialized then
    updateStatus("Disconnected")
    return
  end
  if not api:isConfigured() then
    updateStatus("Not configured")
    return
  end

  updateStatus("Connecting")
  local lastUpdateTime = os.time() -- Don't check for updates on the first cycle

  local refresh = function()
    local now = os.time()
    local secondsSinceLastUpdate = now - lastUpdateTime
    if toboolean(Properties["Automatic Updates"]) and secondsSinceLastUpdate > (30 * 60) then
      log:info("Checking for driver update (timer expired)")
      lastUpdateTime = now
      updateStatus("Updating driver...")
      UpdateDrivers()
    elseif api:isConfigured() then
      if not api:hasAuthenticationFailure() then
        log:debug("Fetching device statuses from the API (timer expired)")
        if not api:hasApiFailure() then
          updateStatus("Connected")
        end
        RefreshStatus()
      else
        updateStatus("Invalid username and/or password")
      end
    else
      updateStatus("Not configured")
    end
  end
  -- Perform the initial refresh then schedule it on a repeating timer
  refresh()
  SetTimer("Refresh", 5 * ONE_SECOND, refresh, true)
end

local function updateValue(name, value, type)
  log:trace("updateValue(%s, %s, %s)", name, value, type)
  if type ~= nil then
    if Variables[name] == nil then
      C4:AddVariable(name, value or "", type, true, false)
    else
      C4:SetVariable(name, value)
    end
  end
  if Properties[name] ~= nil and Properties[name] ~= value then
    UpdateProperty(name, value, true)
  end
end

local function updateRelay(relayNumber, value)
  log:trace("updateRelay(%s %s)", relayNumber, value)
  value = toboolean(value)

  updateValue("Relay " .. relayNumber .. " State", value and "1" or "0", "BOOL")

  local bindingKey = "relay" .. relayNumber
  local binding =
    bindings:getOrAddDynamicBinding("controlbyweb", bindingKey, "PROXY", true, "Relay " .. relayNumber, "RELAY")
  if binding == nil then
    log:error("number of connections exceeds this driver's limit!")
    return nil
  end

  RFP[binding.bindingId] = function(idBinding, strCommand, tParams, args)
    log:trace("RFP idBinding=%s strCommand=%s tParams=%s args=%s", idBinding, strCommand, tParams, args)
    local response
    local pulseTime = 0
    if strCommand == "ON" or strCommand == "CLOSE" then
      response = api:controlRelay(relayNumber, true)
    elseif strCommand == "OFF" or strCommand == "OPEN" then
      response = api:controlRelay(relayNumber, false)
    elseif strCommand == "TOGGLE" then
      response = api:controlRelay(relayNumber, not value)
    elseif strCommand == "TRIGGER" then
      pulseTime = tonumber_locale(tParams.TIME) or 0
      response = api:pulseRelay(relayNumber, pulseTime)
    end
    if response ~= nil then
      response:next(function()
        log:debug("%s command sent to relay%s", strCommand, relayNumber)
        SetTimer("RefreshAfterCommand", 500, RefreshStatus)
        if pulseTime then
          SetTimer("RefreshAfterPulseCommand", pulseTime + 250, RefreshStatus)
        end
      end, function(error)
        log:error("An error occurred sending %s command to relay%s; %s", strCommand, relayNumber, error)
      end)
    end
  end
  SendToProxy(binding.bindingId, value and "CLOSED" or "OPENED", {}, "NOTIFY")

  return binding
end

local function updateDigitalInput(digitalInputNumber, value)
  log:trace("updateDigitalInput(%s %s)", digitalInputNumber, value)
  value = toboolean(value)

  updateValue("Input " .. digitalInputNumber .. " State", value and "1" or "0", "BOOL")

  local bindingKey = "digitalInput" .. digitalInputNumber
  local binding = bindings:getOrAddDynamicBinding(
    "controlbyweb",
    bindingKey,
    "PROXY",
    true,
    "Input " .. digitalInputNumber,
    "CONTACT_SENSOR"
  )
  if binding == nil then
    log:error("number of connections exceeds this driver's limit!")
    return nil
  end
  SendToProxy(binding.bindingId, value and "CLOSED" or "OPENED", {}, "NOTIFY")

  return binding
end

local function updateOneWireSensor(oneWireSensorNumber, value)
  log:trace("updateOneWireSensor(%s %s)", oneWireSensorNumber, value)
  value = tonumber_locale(value)
  if value == nil then
    value = -1000
  end

  local tempF = value
  local tempC = F2C(tempF)
  local tempFStr = tostring_return_period(tempF)
  local tempCStr = tostring_return_period(tempC)

  updateValue("Sensor " .. oneWireSensorNumber .. " Temp", tempFStr, "NUMBER")

  local bindingKey = "oneWireSensor" .. oneWireSensorNumber
  local isInitialized = bindings:getDynamicBinding("controlbyweb", bindingKey)
  local binding = bindings:getOrAddDynamicBinding(
    "controlbyweb",
    bindingKey,
    "PROXY",
    true,
    "Temperature " .. oneWireSensorNumber,
    "TEMPERATURE_VALUE"
  )
  if binding == nil then
    log:error("number of connections exceeds this driver's limit!")
    return nil
  end
  SendToProxy(binding.bindingId, isInitialized and "VALUE_CHANGED" or "VALUE_INITIALIZE", {
    FAHRENHEIT = tempFStr,
    CELSIUS = tempCStr,
    STATUS = not isInitialized and "active" or nil,
    TIMESTAMP = tostring(os.time()),
  }, "NOTIFY")

  return binding
end

function RefreshStatus()
  log:trace("RefreshStatus()")
  api:getStatus():next(function(status)
    local serialNumber = Select(status, "diagnostics", "serialNumber")
    if IsEmpty(serialNumber) then
      log:error()
      return
    end
    updateValue("Last Poll Time", os.date(), "STRING")
    updateValue("Serial Number", serialNumber, "STRING")
    updateValue("Model Number", Select(status, "diagnostics", "modelNumber"), "STRING")
    updateValue("Firmware Revision", Select(status, "diagnostics", "firmwareRevision"), "STRING")

    local abandonedBindings = bindings:getDynamicBindings("controlbyweb")

    for key, value in pairs(Select(status, "state") or {}) do
      local binding
      local relayNumber = key:match("^relay(%d+)$")
      local digitalInputNumber = key:match("^digitalInput(%d+)$")
      local oneWireSensorNumber = key:match("^oneWireSensor(%d+)$")

      if relayNumber ~= nil then
        binding = updateRelay(relayNumber, value)
      elseif digitalInputNumber ~= nil then
        binding = updateDigitalInput(digitalInputNumber, value)
      elseif oneWireSensorNumber ~= nil then
        binding = updateOneWireSensor(oneWireSensorNumber, value)
      elseif key == "vin" then
        updateValue("Voltage Input", value, "NUMBER")
      elseif key == "utcTime" then
        updateValue("Onboard Timestamp", value, "NUMBER")
      end

      if binding then
        abandonedBindings[binding.key] = nil
        OBC[binding.bindingId] = function(idBinding, strClass, bIsBound, otherDeviceId, otherBindingId)
          log:debug(
            "OBC idBinding=%s strClass=%s bIsBound=%s otherDeviceId=%s otherBindingId=%s",
            idBinding,
            strClass,
            bIsBound,
            otherDeviceId,
            otherBindingId
          )
          if bIsBound then
            RefreshStatus()
          end
        end
      end
    end
    -- Delete any bindings for removed devices
    for bindingKey, binding in pairs(abandonedBindings) do
      log:info("Deleting connection '%s' as it is no longer available", binding.displayName)
      bindings:deleteBinding("controlbyweb", bindingKey)
    end
  end, function(error)
    log:error("An error occurred refreshing status; %s", error)
  end)
end

function EC.UpdateDrivers()
  log:trace("EC.UpdateDrivers()")
  log:print("Updating drivers")
  UpdateDrivers(true)
end

function UpdateDrivers(forceUpdate)
  log:trace("UpdateDrivers(%s)", forceUpdate)
  githubUpdater
    :updateAll(DRIVER_GITHUB_REPO, DRIVER_FILENAMES, Properties["Update Channel"] == "Prerelease", forceUpdate)
    :next(function(updatedDrivers)
      if not IsEmpty(updatedDrivers) then
        log:info("Updated driver(s): %s", table.concat(updatedDrivers, ","))
      else
        log:debug("No driver updates available")
      end
    end, function(error)
      log:error("An error occurred updating drivers; %s", error)
    end)
end
