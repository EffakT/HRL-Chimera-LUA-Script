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

json = require('json')

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

    -- data = string.gsub(data, '"', "\\")
    -- command = "powershell Invoke-WebRequest '"..url.."' -TimeoutSec 5 -Method "..method.." -Body '"..data.."' -ContentType 'application/json'"
    data = string.gsub(data, '"', ";")
    command = "wget -qO- --tries 1 --connect-timeout 5 --timeout 5 --post-data \"" .. data .. "\" " .. url

    write_file("last_command", command)
    -- io.popen(command)
    os.execute(command)

    -- need to escape double-quotes
    -- data = string.gsub(data, '"', "\\\"")
    -- command = "powershell Invoke-WebRequest '" .. url .. "' -TimeoutSec 5 -Method " .. method .. " -Body '" .. data .."'"
    -- write_file("last_command", command)
    -- io.popen(command)
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
    playerName = read_widestring(player + offset, nameLength)

    playerName = string.toutf8(playerName)

    return playerName
end

--- Checks if the player is driving a vehicle.
-- @param player_address The player's dynamic memory address.
-- @return 1 if driving, 0 if not.
function isDriver(player_address)

    local is_driver = 1;
    local vehicle_objectid = read_dword(player_address + 0x11C)
    if (tonumber(vehicle_objectid) ~= 0xFFFFFFFF) then
        local vehicle = get_object(tonumber(vehicle_objectid))
        local driver = read_dword(vehicle + 0x324)
        driver = get_object(tonumber(driver))
        if (driver == player_address) then
            is_driver = 1
        else
            is_driver = 0
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
    local server_ip = server_ip_table[1]
    local server_port = server_ip_table[2]

    local playerName = getPlayerName(player)
    local current_map = map

    local timestamp = os.time(os.date("!*t"))

    local object = {
        ip = server_ip,
        port = server_port,
        player_hash = player_hash,
        player_uuid = player_uuid,
        player_name = playerName,
        map_name = current_map,
        map_label = "",
        race_type = mode,
        player_time = best_time,
        timestamp = timestamp
    }
    if debug == 1 then
        -- json =
        object["test"] = 1
        --     '{"ip":"' .. server_ip .. '", "port":"' .. server_port .. '", "player_hash": "' .. player_hash .. '", "player_uuid": "'.. player_uuid ..'", "player_name":"' .. playerName ..
        --         '", "map_name": "' .. current_map .. '", "map_label": "", "race_type": "' .. mode ..
        --         '", "player_time":"' .. best_time .. '", "timestamp":"' .. timestamp .. '", "test":"true"}'
    else
        -- json =
        --     '{"ip":"' .. server_ip .. '", "port":"' .. server_port .. '", "player_hash": "' .. player_hash .. '", "player_uuid": "'.. player_uuid ..'", "player_name":"' .. playerName ..
        --         '", "map_name": "' .. current_map .. '", "map_label": "", "race_type": "' .. mode ..
        --         '", "player_time":"' .. best_time .. '", "timestamp":"' .. timestamp .. '"}'
    end

    if (live_reporting == 1) then
        -- SendTime("https://haloraceleaderboard.effakt.info/api/newtime", json)
        return
    end
    local json_file = ""
    if file_exists("json") then
        json_file = read_file("json")
    end
    json_file = json_file .. "\n" .. json.encode(object)

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

    local new_object = {}

    json_split = splitString(json_file, "\n")
    -- local json_to_send = "["

    for k, v in pairs(json_split) do

        new_object[k] = json.decode(v)

        -- json_to_send = json_to_send .. v

        -- if (k < tablelength(json_split)) then
        --     json_to_send = json_to_send .. ","
        -- end
    end

    -- json_to_send = json_to_send .. "]"

    json_to_send = json.encode(new_object)

    SendTime("https://dev.hrl.effakt.info/api/bulknewtime", json_to_send)
    -- SendTime("http://localhost:3000/api/bulknewtime", json_to_send)

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

function sendDebugTime()

    local server_ip = read_string(0x006A3F38)
    local server_ip_table = splitString(server_ip, ":")
    local server_ip = server_ip_table[1]
    local server_port = server_ip_table[2]

    local timestamp = os.time(os.date("!*t"))
    player_hash = ""
    player_uuid = "tesing"
    -- playerName = "test"

    local player = get_player()
    local playerName = getPlayerName(player)
    current_map = "bloodgulch"
    mode = 0
    best_time = "999999"

    local object = {
        ip = server_ip,
        port = server_port,
        player_hash = player_hash,
        player_uuid = player_uuid,
        player_name = playerName,
        map_name = current_map,
        map_label = "",
        race_type = mode,
        player_time = best_time,
        timestamp = timestamp
    }
    if debug == 1 then
        -- json =
        object["test"] = 1
        --     '{"ip":"' .. server_ip .. '", "port":"' .. server_port .. '", "player_hash": "' .. player_hash .. '", "player_uuid": "'.. player_uuid ..'", "player_name":"' .. playerName ..
        --         '", "map_name": "' .. current_map .. '", "map_label": "", "race_type": "' .. mode ..
        --         '", "player_time":"' .. best_time .. '", "timestamp":"' .. timestamp .. '", "test":"true"}'
    else
        -- json =
        --     '{"ip":"' .. server_ip .. '", "port":"' .. server_port .. '", "player_hash": "' .. player_hash .. '", "player_uuid": "'.. player_uuid ..'", "player_name":"' .. playerName ..
        --         '", "map_name": "' .. current_map .. '", "map_label": "", "race_type": "' .. mode ..
        --         '", "player_time":"' .. best_time .. '", "timestamp":"' .. timestamp .. '"}'
    end

    if (live_reporting == 1) then
        -- SendTime("https://haloraceleaderboard.effakt.info/api/newtime", json)
        return
    end
    local json_file = ""
    if file_exists("json") then
        json_file = read_file("json")
    end
    json_file = json_file .. "\n" .. json.encode(object)

    -- write new line to file, \n json
    write_file("json", json_file)

    should_report = 1

    bulkSendTimes()
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
        local player_address = get_dynamic_player()
        local player = get_player()
        local current_time = read_word(player + 0xC4)
        console_out("----------------------------------------------------------")
        console_out("enabled:" .. enabled)
        console_out("current_time:" .. current_time)
        console_out("bestCurrentLap:" .. bestCurrentLap)
        console_out("lastLapTime:" .. lastLapTime)
        console_out("race:" .. race)
        console_out("player_address:" .. player_address)
        console_out("player_ping:" .. player_ping)
        console_out("last_ping_check:" .. last_ping_check)
        console_out("player_died:" .. player_died)
        console_out("map_load_time:" .. map_load_time)
        console_out("player_is_dead:" .. player_is_dead)
        console_out("map:" .. map)
        console_out("should_report:" .. should_report)
        console_out("live_reporting:" .. live_reporting)
        console_out("player_hash:" .. player_hash)
        console_out("is_driver:" .. isDriver(player_address))
        console_out("----------------------------------------------------------")
        return true
    elseif (command == "hrl_debug_time") then
        console_out("DebugTime Logged")
        sendDebugTime()
        return true
    else
        return true
    end
    return false
end

-- Read command setting
if file_exists("enabled") then
    isEnabled = read_file("enabled") == "1"
    if (isEnabled) then
        enabled = 1
    else
        enabled = 0
    end
end

function getUUID()
    if file_exists("uuid") then
        uuid = read_file("uuid")
        if (not isEmpty(uuid)) then
            return uuid
        end
    end
    response = assert(io.popen('wmic csproduct get uuid'))
    uuid = trim(string.gsub(response:read('*all'), 'UUID', ''))
    if response then
        response:close()
    end
    write_file("uuid", uuid)
    return trim(uuid)
end

function trim(s)
    return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

----------------------------------------------------------
-- Callback Registrations
----------------------------------------------------------
-- Register callback functions
set_callback("map load", "onMapLoad")
set_callback("tick", "onTick")
set_callback("command", "onCommand")
-- MapLoad needs to run instantly incase of scripts loading mid game

player_uuid = getUUID()
onMapLoad()

local char, byte, pairs, floor = string.char, string.byte, pairs, math.floor
local table_insert, table_concat = table.insert, table.concat
local unpack = table.unpack or unpack

local function unicode_to_utf8(code)
    -- converts numeric UTF code (U+code) to UTF-8 string
    local t, h = {}, 128
    while code >= h do
        t[#t + 1] = 128 + code % 64
        code = floor(code / 64)
        h = h > 32 and 32 or h / 2
    end
    t[#t + 1] = 256 - 2 * h + code
    return char(unpack(t)):reverse()
end

local function utf8_to_unicode(utf8str, pos)
    -- pos = starting byte position inside input string (default 1)
    pos = pos or 1
    local code, size = utf8str:byte(pos), 1
    if code >= 0xC0 and code < 0xFE then
        local mask = 64
        code = code - 128
        repeat
            local next_byte = utf8str:byte(pos + size) or 0
            if next_byte >= 0x80 and next_byte < 0xC0 then
                code, size = (code - mask - 2) * 64 + next_byte, size + 1
            else
                code, size = utf8str:byte(pos), 1
            end
            mask = mask * 32
        until code < mask
    end
    -- returns code, number of bytes in this utf8 char
    return code, size
end

local map_1252_to_unicode = {
    [0x80] = 0x20AC,
    [0x81] = 0x81,
    [0x82] = 0x201A,
    [0x83] = 0x0192,
    [0x84] = 0x201E,
    [0x85] = 0x2026,
    [0x86] = 0x2020,
    [0x87] = 0x2021,
    [0x88] = 0x02C6,
    [0x89] = 0x2030,
    [0x8A] = 0x0160,
    [0x8B] = 0x2039,
    [0x8C] = 0x0152,
    [0x8D] = 0x8D,
    [0x8E] = 0x017D,
    [0x8F] = 0x8F,
    [0x90] = 0x90,
    [0x91] = 0x2018,
    [0x92] = 0x2019,
    [0x93] = 0x201C,
    [0x94] = 0x201D,
    [0x95] = 0x2022,
    [0x96] = 0x2013,
    [0x97] = 0x2014,
    [0x98] = 0x02DC,
    [0x99] = 0x2122,
    [0x9A] = 0x0161,
    [0x9B] = 0x203A,
    [0x9C] = 0x0153,
    [0x9D] = 0x9D,
    [0x9E] = 0x017E,
    [0x9F] = 0x0178,
    [0xA0] = 0x00A0,
    [0xA1] = 0x00A1,
    [0xA2] = 0x00A2,
    [0xA3] = 0x00A3,
    [0xA4] = 0x00A4,
    [0xA5] = 0x00A5,
    [0xA6] = 0x00A6,
    [0xA7] = 0x00A7,
    [0xA8] = 0x00A8,
    [0xA9] = 0x00A9,
    [0xAA] = 0x00AA,
    [0xAB] = 0x00AB,
    [0xAC] = 0x00AC,
    [0xAD] = 0x00AD,
    [0xAE] = 0x00AE,
    [0xAF] = 0x00AF,
    [0xB0] = 0x00B0,
    [0xB1] = 0x00B1,
    [0xB2] = 0x00B2,
    [0xB3] = 0x00B3,
    [0xB4] = 0x00B4,
    [0xB5] = 0x00B5,
    [0xB6] = 0x00B6,
    [0xB7] = 0x00B7,
    [0xB8] = 0x00B8,
    [0xB9] = 0x00B9,
    [0xBA] = 0x00BA,
    [0xBB] = 0x00BB,
    [0xBC] = 0x00BC,
    [0xBD] = 0x00BD,
    [0xBE] = 0x00BE,
    [0xBF] = 0x00BF,
    [0xC0] = 0x00C0,
    [0xC1] = 0x00C1,
    [0xC2] = 0x00C2,
    [0xC3] = 0x00C3,
    [0xC4] = 0x00C4,
    [0xC5] = 0x00C5,
    [0xC6] = 0x00C6,
    [0xC7] = 0x00C7,
    [0xC8] = 0x00C8,
    [0xC9] = 0x00C9,
    [0xCA] = 0x00CA,
    [0xCB] = 0x00CB,
    [0xCC] = 0x00CC,
    [0xCD] = 0x00CD,
    [0xCE] = 0x00CE,
    [0xCF] = 0x00CF,
    [0xD0] = 0x00D0,
    [0xD1] = 0x00D1,
    [0xD2] = 0x00D2,
    [0xD3] = 0x00D3,
    [0xD4] = 0x00D4,
    [0xD5] = 0x00D5,
    [0xD6] = 0x00D6,
    [0xD7] = 0x00D7,
    [0xD8] = 0x00D8,
    [0xD9] = 0x00D9,
    [0xDA] = 0x00DA,
    [0xDB] = 0x00DB,
    [0xDC] = 0x00DC,
    [0xDD] = 0x00DD,
    [0xDE] = 0x00DE,
    [0xDF] = 0x00DF,
    [0xE0] = 0x00E0,
    [0xE1] = 0x00E1,
    [0xE2] = 0x00E2,
    [0xE3] = 0x00E3,
    [0xE4] = 0x00E4,
    [0xE5] = 0x00E5,
    [0xE6] = 0x00E6,
    [0xE7] = 0x00E7,
    [0xE8] = 0x00E8,
    [0xE9] = 0x00E9,
    [0xEA] = 0x00EA,
    [0xEB] = 0x00EB,
    [0xEC] = 0x00EC,
    [0xED] = 0x00ED,
    [0xEE] = 0x00EE,
    [0xEF] = 0x00EF,
    [0xF0] = 0x00F0,
    [0xF1] = 0x00F1,
    [0xF2] = 0x00F2,
    [0xF3] = 0x00F3,
    [0xF4] = 0x00F4,
    [0xF5] = 0x00F5,
    [0xF6] = 0x00F6,
    [0xF7] = 0x00F7,
    [0xF8] = 0x00F8,
    [0xF9] = 0x00F9,
    [0xFA] = 0x00FA,
    [0xFB] = 0x00FB,
    [0xFC] = 0x00FC,
    [0xFD] = 0x00FD,
    [0xFE] = 0x00FE,
    [0xFF] = 0x00FF
}
local map_unicode_to_1252 = {}
for code1252, code in pairs(map_1252_to_unicode) do
    map_unicode_to_1252[code] = code1252
end

function string.fromutf8(utf8str)
    local pos, result_1252 = 1, {}
    while pos <= #utf8str do
        local code, size = utf8_to_unicode(utf8str, pos)
        pos = pos + size
        code = code < 128 and code or map_unicode_to_1252[code] or ('?'):byte()
        table_insert(result_1252, char(code))
    end
    return table_concat(result_1252)
end

function string.toutf8(str1252)
    local result_utf8 = {}
    for pos = 1, #str1252 do
        local code = str1252:byte(pos)
        table_insert(result_utf8, unicode_to_utf8(map_1252_to_unicode[code] or code))
    end
    return table_concat(result_utf8)
end
