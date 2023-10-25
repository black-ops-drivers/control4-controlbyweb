local log = require("lib.logging")
local persist = require("lib.persist")

local Conditionals = {}

local CONDITIONALS_PERSIST_KEY = "Conditionals"
local CONDITIONAL_ID_START = 10

function Conditionals:new()
  log:trace("Conditionals:new()")
  local properties = {}
  setmetatable(properties, self)
  self.__index = self
  return properties
end

function Conditionals:upsertConditional(namespace, key, conditional, testFunction)
  log:trace("Conditionals:upsertConditional(%s, %s, %s, <testFunction>)", namespace, key, conditional)
  local conditionals = self:_getConditionals()
  local conditionalId = Select(conditionals, namespace, key, "conditionalId") or self:_getNextConditionalId()
  local conditionalName = "CONDITIONAL_" .. conditionalId

  if Select(conditionals, namespace, key) == nil then
    conditional = TableDeepCopy(conditional)
    conditional.conditionalId = conditionalId
    conditional.name = conditionalName

    conditionals[namespace] = conditionals[namespace] or {}
    conditionals[namespace][key] = conditional
    self:_saveConditionals(conditionals)
  end
  TC[conditionalName] = testFunction
  return conditional
end

function Conditionals:deleteConditional(namespace, key)
  log:trace("Conditionals:deleteConditional(%s, %s)", namespace, key)
  local conditionals = self:_getConditionals()
  local conditional = Select(conditionals, namespace, key)
  if IsEmpty(conditional) then
    return
  end

  conditionals[namespace][key] = nil
  if IsEmpty(conditionals[namespace]) then
    conditionals[namespace] = nil
  end
  if IsEmpty(conditionals) then
    conditionals = nil
  end

  TC[conditional.name] = nil

  self:_saveConditionals(conditionals)
end

function Conditionals:_getNextConditionalId()
  log:trace("Conditionals:_getNextConditionalId()")
  local currentConditionals = {}
  for _, keys in pairs(self:_getConditionals()) do
    for _, conditional in pairs(keys) do
      currentConditionals[conditional.conditionalId] = true
    end
  end
  local nextId = CONDITIONAL_ID_START
  while currentConditionals[nextId] ~= nil do
    nextId = nextId + 1
  end
  return nextId
end

function Conditionals:_getConditionals()
  log:trace("Conditionals:_getConditionals()")
  return persist:get(CONDITIONALS_PERSIST_KEY, {})
end

function Conditionals:_saveConditionals(conditionals)
  log:trace("Conditionals:_saveConditionals(%s)", conditionals)
  persist:set(CONDITIONALS_PERSIST_KEY, not IsEmpty(conditionals) and conditionals or nil)
end

local conditionals = Conditionals:new()

function GetConditionals()
  log:trace("GetConditionals()")
  local progConditionals = {}
  for _, keys in pairs(conditionals:_getConditionals()) do
    for _, conditional in pairs(keys) do
      progConditionals[tostring(conditional.conditionalId)] = conditional
    end
  end
  return progConditionals
end

return conditionals
