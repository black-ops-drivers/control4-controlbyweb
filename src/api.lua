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
  return self:_get("/state.xml"):next(function(stateBody)
    return self:_get("/diagnostics.xml"):next(function(diagnosticsBody)
      return {
        state = Select(stateBody, "datavalues") or {},
        diagnostics = Select(diagnosticsBody, "datavalues") or {},
      }
    end)
  end)
end

function API:controlRelay(relayNumber, state)
  log:trace("API:controlRelay(%s, %s)", relayNumber, state)
  return self:_get("/state.xml?relay" .. relayNumber .. "State=" .. (state and "1" or "0"))
end

function API:pulseRelay(relayNumber, duration)
  log:trace("API:pulseRelay(%s, %s)", relayNumber, duration)
  local path = "/state.xml?relay" .. relayNumber .. "State=2"
  if type(duration) == "number" and duration > 0 then
    path = path .. "&pulseTime" .. relayNumber .. "=" .. (duration / 1000)
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
