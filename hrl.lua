------------------------------------------------------------------------------
-- HRL - Clientside
-- Author: EffakT
-- Version 1.0
------------------------------------------------------------------------------
-- Settings
join_death_grace_period = tick_rate() * 2 -- 2 seconds in ticks
live_reporting = 0 -- 1 to report on every lap. fal0se to report when no longer in a game

-- Variables
clua_version = 2.042

enabled = 1

lastTickTime = 0
bestCurrentLap = 32000 -- In ticks (Random high number to start at)
lastLapTime = 0 -- In ticks
race = 0
player_ping = 0
last_ping_check = 0
ping_threshold = 100
player_died = 0
map_load_time = 0
player_is_dead = 0
should_report = 1


player_hash = read_string(0x006B7FBD) -- sometimes this value isn't here D:

----------------------------------------------------------
-- Utility Functions
----------------------------------------------------------

--- Performs an HTTP POST request.
function http_post(url, data, method)
    if method == nil then
        method = 'POST'
    end
    data = string.gsub(data, '"', "\\")
    os.execute("powershell Invoke-WebRequest '" .. url .. "' -TimeoutSec 5 -Method " .. method .. " -Body '" .. data ..
                   "'")
end

--- Sends lap time data to a specified URL.
-- @param URL The URL to send the lap time data to.
-- @param json The lap time data in JSON format.
function SendTime(URL, json)
    http_post(URL, json, "POST")
end

--- Checks the current map and game type.
function CheckMapAndGametype()
    local game_type = read_byte(0x0087AB50) -- 5 is race

    if game_type == 5 then
        race = 1
        mode = read_byte(0x0087AB9C)
    else
        race = 0
    end
end

--- Initializes variables and checks game type on map load.
function onMapLoad()
    bestCurrentLap = 32000
    lastLapTime = 0
    player_ping = 0
    player_died = 0
    map_load_time = ticks()

    CheckMapAndGametype()
end

--- Retrieves the player's current ping.
-- @return The player's ping.
function GetPlayerPing()
    if player and server_type == "dedicated" then
        return read_dword(player + 0xDC)
    else
        return 0
    end
end

--- Checks and logs player pings.
function CheckPings()
    local current_ticks = ticks()
    local time_since_last = current_ticks - last_ping_check

    if time_since_last >= 30 then
        local ping = GetPlayerPing()

        if player_ping > 0 and (ping - player_ping) > ping_threshold then
            player_warps = 1
            console_out("We just detected a ping spike. This lap will not count")
        end

        player_ping = ping
        last_ping_check = current_ticks
    end
end

--- Retrieves the player's name.
-- @param player The player object.
-- @return The player's name.
function getPlayerName(player)
    if isEmpty(player) then
        return nil
    end

    local nameLength = 12
    local offset = 0x0004
    return read_widestring(player + offset, nameLength)
end

--- Checks if the player is driving a vehicle.
-- @param player_address The player's dynamic memory address.
-- @return 1 if driving, 0 if not.
function isDriver(player_address)
    local is_driver = 0
    local vehicle_objectid = read_dword(player_address + 0x11C)
    if vehicle_objectid ~= 0xFFFFFFFF then
        local vehicle = get_object(vehicle_objectid)
        local driver = read_dword(vehicle + 0x324)
        if driver == player_address then
            is_driver = 1
        end
    end
    return is_driver
end

----------------------------------------------------------
-- Event Handlers
----------------------------------------------------------

--- Handles tick events.
function onTick()

    if (enabled == 0) then
        return
    end

    if (isPGCR() or map == "ui") then
        if (live_reporting == 0 and should_report == 1) then
            bulkSendTimes()
        end
    end

    if race == 0 then
        return
    end

    CheckPings()

    local player = get_player()
    if isEmpty(player) then
        return
    end

    local player_address = get_dynamic_player()
    if not player_address then
        handlePlayerDeath()
        return
    end

    -- if we get here, player is alive
    player_is_dead = 0

    local current_time = read_word(player + 0xC4)

    if shouldSkipLap(current_time) then
        if (current_time ~= lastLapTime) then
            startNewLap(current_time)
        end
        return
    end

    updateBestLap(current_time)

    if not isDriver(player_address) or player_died == 1 or player_warps == 1 then
        startNewLap(current_time)
        return
    end

    logCurrentLap()
end

--- Handles player death events.
function handlePlayerDeath()
    player_is_dead = 1
    if ticks() - map_load_time > join_death_grace_period then
        player_died = 1
    end
end

function isPGCR()
    -- idk what this is, but seems related to ui?
    local game_over_state_address = 0x0087AA10

    local game_over_state = read_byte(game_over_state_address)
    -- 0 = not game over
    -- 1 = f1 screen
    -- 2 = PGCR
    -- 3 = Players can quit

    -- if ui not visible, bail
    if (game_over_state ~= 2) then
        return false
    end
    return true
end

--- Determines whether to skip processing the current lap.
-- @param current_time The current lap time.
-- @return True if the lap should be skipped, false otherwise.
function shouldSkipLap(current_time)
    return current_time == lastLapTime or current_time >= bestCurrentLap or current_time <= 0
end

--- Updates the best current lap time.
-- @param current_time The current lap time.
function updateBestLap(current_time)
    bestCurrentLap = current_time
end

--- Logs the current lap time.
function logCurrentLap()
    local player = get_player()
    local current_time = read_word(player + 0xC4)

    local lapTimeSeconds = current_time / tick_rate()

    logTime(lapTimeSeconds)

    console_out("log_time" .. lapTimeSeconds)
end

--- Starts a new lap.
-- @param lapTime The lap time to set (optional).
function startNewLap(lapTime)
    player_died = 0
    player_warps = 0
    lastLapTime = lapTime
end

--- Logs the lap time to the server.
-- @param best_time The best lap time to log.
function logTime(best_time)
    local player = get_player()
    if isEmpty(player) then
        return
    end

    local server_ip = read_string(0x006A3F38)
    local server_ip_table = splitString(server_ip, ":")
    local server_port = server_ip_table[2]


    local playerName = getPlayerName(player)
    local current_map = map

    local timestamp = os.time(os.date("!*t"))

    local json
    if debug == 1 then
        json =
            '{"port":"' .. server_port .. '", "player_hash": "' .. player_hash .. '", "player_name":"' .. playerName ..
                '", "map_name": "' .. current_map .. '", "map_label": "", "race_type": "' .. mode ..
                '", "player_time":"' .. best_time .. '", "timestamp":"' .. timestamp .. '", "test":"true"}'
    else
        json =
            '{"port":"' .. server_port .. '", "player_hash": "' .. player_hash .. '", "player_name":"' .. playerName ..
                '", "map_name": "' .. current_map .. '", "map_label": "", "race_type": "' .. mode ..
                '", "player_time":"' .. best_time .. '", "timestamp":"' .. timestamp .. '"}'
    end

    if (live_reporting == 1) then
        -- SendTime("https://haloraceleaderboard.effakt.info/api/newtime", json)
        return
    end
    local json_file = ""
    if file_exists("json") then
        json_file = read_file("json")
    end
    json_file = json_file .. "\n" .. json

    -- write new line to file, \n json
    write_file("json", json_file)

    should_report = 1
end

function bulkSendTimes()

    should_report = 0

    local json_file = read_file("json")

    if (isEmpty(json_file)) then
        return
    end

    json_split = splitString(json_file, "\n")
    local json_to_send = "["

    for k, v in pairs(json_split) do
        json_to_send = json_to_send .. v

        if (k < tablelength(json_split)) then
            json_to_send = json_to_send .. ","
        end
    end

    json_to_send = json_to_send .. "]"

    -- SendTime("https://haloraceleaderboard.effakt.info/api/bulknewtime", json_to_send)
    SendTime("http://localhost:3000/api/bulknewtime", json_to_send)

    -- clear the file
    write_file("json", "")

end

function tablelength(T)
    local count = 0
    for _ in pairs(T) do
        count = count + 1
    end
    return count
end

--- Checks if a string is empty or nil.
-- @param s The string to check.
-- @return True if empty or nil, false otherwise.
function isEmpty(s)
    return s == nil or s == ''
end

--- Reads a wide string from memory.
-- @param Address The memory address to read from.
-- @param Size The size of the string to read.
-- @return The string read from memory.
function read_widestring(Address, Size)
    local str = ''
    for i = 0, Size - 1 do
        local byte = read_byte(Address + (i * 2))
        if byte ~= 0 then
            str = str .. string.char(byte)
        end
    end
    return str
end

--- Splits a string into parts based on a separator.
-- @param inputstr The input string to split.
-- @param sep The separator pattern (default is whitespace).
-- @return A table containing split parts of the string.
function splitString(inputstr, sep)
    local t = {}
    for str in inputstr:gmatch("([^" .. sep .. "]+)") do
        table.insert(t, str)
    end
    return t
end

function onCommand(command)

    local separatorPos = command:find(" ")
    if (separatorPos ~= nil and command:sub(1, separatorPos - 1) == "hrl") then
        local setting = command:sub(separatorPos + 1):lower()
        if (setting == "true" or setting == "1") then
            write_file("enabled", "1")
            enabled = 1
            console_out("Enabled HRL")
        elseif (setting == "false" or setting == "0") then
            write_file("enabled", "0")
            enabled = 0
            console_out("Disabled HRL")
        else
            console_out("Invalid argument in hrl command. Expected true or false.", 1.0, 0.25, 0.25)
        end
    elseif (command == "hrl_debug") then
        local player = get_player()
        local current_time = read_word(player + 0xC4)
        console_out("----------------------------------------------------------")
        console_out("enabled:" .. enabled)
        console_out("current_time:" .. current_time)
        console_out("bestCurrentLap:" .. bestCurrentLap)
        console_out("lastLapTime:" .. lastLapTime)
        console_out("race:" .. race)
        console_out("player_ping:" .. player_ping)
        console_out("last_ping_check:" .. last_ping_check)
        console_out("player_died:" .. player_died)
        console_out("map_load_time:" .. map_load_time)
        console_out("player_is_dead:" .. player_is_dead)
        console_out("map:" .. map)
        console_out("should_report:" .. should_report)
        console_out("live_reporting:" .. live_reporting)
        console_out("player_hash:" .. player_hash)
        console_out("----------------------------------------------------------")
        return true
    else
        return true
    end
    return false
end

----------------------------------------------------------
-- Callback Registrations
----------------------------------------------------------

-- Read command setting
if file_exists("enabled") then
    isEnabled = read_file("enabled") == "1"
    if (isEnabled) then
        enabled = 1
    else
        enabled = 0
    end
end
-- Register callback functions
set_callback("map load", "onMapLoad")
set_callback("tick", "onTick")
set_callback("command", "onCommand")
-- MapLoad needs to run instantly incase of scripts loading mid game

onMapLoad()