local log = require("lib.logging")
local persist = require("lib.persist")

local Events = {}

local EVENTS_PERSIST_KEY = "Events"
local EVENT_ID_START = 10
local EVENT_ID_END = 999

function Events:new()
  log:trace("Events:new()")
  local properties = {}
  setmetatable(properties, self)
  self.__index = self
  return properties
end

function Events:upsertEvent(namespace, key, name, description)
  log:trace("Events:upsertEvent(%s, %s, %s, %s, %s)", namespace, key, name, description)
  local events = self:_getEvents()
  local event = Select(events, namespace, key)
  if event == nil then
    local eventId = self:_getNextEventId()
    event = {
      eventId = eventId,
      name = name,
      description = description,
    }

    events[namespace] = events[namespace] or {}
    events[namespace][key] = event
    self:_saveEvents(events)
    C4:AddEvent(eventId, name, description)
  end
  return event
end

function Events:fire(namespace, key)
  log:trace("Events:fire(%s, %s)", namespace, key)
  local eventId = Select(self:_getEvents(), namespace, key, "eventId")
  if not IsEmpty(eventId) then
    C4:FireEventByID(eventId)
  end
end

function Events:deleteEvent(namespace, key)
  log:trace("Events:deleteEvent(%s, %s)", namespace, key)
  local events = self:_getEvents()
  local eventId = Select(events, namespace, key, "eventId")
  if IsEmpty(eventId) then
    return
  end

  C4:DeleteEvent(eventId)

  events[namespace][key] = nil
  if IsEmpty(events[namespace]) then
    events[namespace] = nil
  end
  if IsEmpty(events) then
    events = nil
  end

  self:_saveEvents(events)
end

function Events:restoreEvents()
  log:trace("Events:restoreEvents()")
  local usedEventIds = {}
  for _, keys in pairs(self:_getEvents()) do
    for _, event in pairs(keys) do
      usedEventIds[event.eventId] = true
      C4:AddEvent(event.eventId, event.name, event.description)
    end
  end
  for i = EVENT_ID_START, EVENT_ID_END do
    if usedEventIds[i] == nil then
      log:trace("Deleting non-configured event %s, if it exists", i)
      C4:DeleteEvent(i)
    end
  end
end

function Events:_getNextEventId()
  log:trace("Events:_getNextEventId()")
  local currentEvents = {}
  for _, keys in pairs(self:_getEvents()) do
    for _, event in pairs(keys) do
      currentEvents[event.eventId] = true
    end
  end
  local nextId = EVENT_ID_START
  while currentEvents[nextId] ~= nil do
    nextId = nextId + 1
  end
  return nextId
end

function Events:_getEvents()
  log:trace("Events:_getEvents()")
  return persist:get(EVENTS_PERSIST_KEY, {})
end

function Events:_saveEvents(events)
  log:trace("Events:_saveEvents(%s)", events)
  persist:set(EVENTS_PERSIST_KEY, not IsEmpty(events) and events or nil)
end

return Events:new()
