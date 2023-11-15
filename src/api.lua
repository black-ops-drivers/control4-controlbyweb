local http = require("lib.http")
local log = require("lib.logging")

local deferred = require("vendor.deferred")

local API = {}

local noop = function() end

function API:new()
  local properties = {
    _ipAddress = nil,
    _username = nil,
    _password = nil,
    _lastState = nil,
    _statusCallback = noop,
    _authenticationFailed = false,
    _apiFailed = false,
  }
  setmetatable(properties, self)
  self.__index = self

  http:setDefaultTimeout(2 * ONE_SECOND)

  return properties
end

function API:setIpAddress(ipAddress)
  log:trace("API:setIpAddress(%s)", ipAddress)
  self._ipAddress = not IsEmpty(ipAddress) and ipAddress or nil
end

function API:setUsername(username)
  log:trace("API:setUsername(%s)", username)
  self._authenticationFailed = false
  self._username = not IsEmpty(username) and username or nil
end

function API:setPassword(password)
  log:trace("API:setPassword(%s)", not IsEmpty(password) and "****" or "")
  self._authenticationFailed = false
  self._password = not IsEmpty(password) and password or nil
end

function API:isConfigured()
  log:trace("API:isConfigured()")
  return not IsEmpty(self._ipAddress) and not IsEmpty(self._username) and not IsEmpty(self._password)
end

function API:hasAuthenticationFailure()
  log:trace("API:hasAuthenticationFailure()")
  return self._authenticationFailed
end

function API:hasApiFailure()
  log:trace("API:hasApiFailure()")
  return self._apiFailed
end

function API:getStatus()
  log:trace("API:getStatus()")
  return self:_get("/state.xml?showUnits=1"):next(function(stateBody)
    return self:_get("/diagnostics.xml"):next(function(diagnosticsBody)
      return {
        state = Select(stateBody, "datavalues"),
        diagnostics = Select(diagnosticsBody, "datavalues"),
      }
    end)
  end)
end

function API:controlRelay(index, state)
  log:trace("API:controlRelay(%s, %s)", index, state)
  return self:_control("relay", index, state)
end

function API:pulseRelay(index, duration)
  log:trace("API:pulseRelay(%s, %s)", index, duration)
  return self:_pulse("relay", index, duration)
end

function API:controlDigitalIO(index, state)
  log:trace("API:controlDigitalIO(%s, %s)", index, state)
  return self:_control("digitalIO", index, state)
end

function API:pulseDigitalIO(index, duration)
  log:trace("API:pulseRelay(%s, %s)", index, duration)
  return self:_pulse("digitalIO", index, duration)
end

function API:_control(name, index, state)
  log:trace("API:_control(%s, %s, %s)", name, index, state)
  return self:_get("/state.xml?" .. name .. index .. "State=" .. (state and "1" or "0"))
end

function API:_pulse(name, index, duration)
  log:trace("API:_pulse(%s, %s, %s)", name, index, duration)
  local path = "/state.xml?" .. name .. index .. "State=2"
  if type(duration) == "number" and duration > 0 then
    path = path .. "&pulseTime" .. index .. "=" .. (duration / 1000)
  end
  return self:_get(path)
end

function API:_get(path)
  log:trace("API:_get()")
  if not self:isConfigured() then
    return reject("missing ip address, username, and/or password")
  end
  local url = self:_createUrl(path)
  return http:get(url, nil, { return_http_failure = true }):next(function(response)
    self._apiFailed = response.code < 200 or response.code >= 300
    self._authenticationFailed = response.code == 401 or response.code == 403
    if self._apiFailed then
      return reject(string.format("HTTP GET request to %s failed with status code %d", url, response.code))
    end
    return ParseXml(response.body)
  end, function(error)
    self._apiFailed = true
    return error
  end)
end

function API:_createUrl(path)
  log:trace("API:_createUrl(%s)", path)
  local login = ""
  if not IsEmpty(self._username) then
    login = self._username
    if not IsEmpty(self._password) then
      login = login .. ":" .. self._password
    end
    login = login .. "@"
  end
  return string.format("http://%s%s%s", login, self._ipAddress, path or "")
end

return API:new()
