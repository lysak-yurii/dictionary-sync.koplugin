local Device = require("device")
local logger = require("logger")
local Event = require("ui/event")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ButtonDialog = require("ui/widget/buttondialog")
local InputDialog = require("ui/widget/inputdialog")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local CenterContainer = require("ui/widget/container/centercontainer")
local Size = require("ui/size")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")
local Screen = Device.screen
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local ButtonTable = require("ui/widget/buttontable")
local TitleBar = require("ui/widget/titlebar")
local FrameContainer = require("ui/widget/container/framecontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local DictSync = InputContainer:new {
    name = "lingueez",
    meta = nil,
    is_doc_only = true,
    settings_file = DataStorage:getSettingsDir() .. "/lingueez.lua",
    settings = nil,
}

-- Central hosted Lingueez project. Shipped in source on purpose: the anon key is a
-- PUBLIC client key and Row-Level Security isolates each signed-in user's rows, so
-- it is safe to distribute. Both can be overridden via SUPABASE_URL / SUPABASE_KEY.
local DEFAULT_SUPABASE_URL = "https://dtyrmkynrideeknsdlrn.supabase.co"
local DEFAULT_SUPABASE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImR0eXJta3lucmlkZWVrbnNkbHJuIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODE4Njc1MTQsImV4cCI6MjA5NzQ0MzUxNH0.dds5SyMBN9u-0TUumB2nSCx68FJfpm3n63fLq1n9o10"

-- Language mapping from KOReader codes to dictionary app language names
local LANGUAGE_MAP = {
    ["en"] = "English",
    ["de"] = "German",
    ["fr"] = "French",
    ["es"] = "Spanish",
    ["it"] = "Italian",
    ["pt"] = "Portuguese",
    ["ru"] = "Russian",
    ["ja"] = "Japanese",
    ["zh"] = "Chinese",
    ["zh-CN"] = "Chinese",
    ["zh-HK"] = "Cantonese",
    ["uk"] = "Ukrainian",
    ["el"] = "Greek",
    ["nl"] = "Dutch",
    ["pl"] = "Polish",
    ["bg"] = "Bulgarian",
    ["hr"] = "Croatian",
    ["cs"] = "Czech",
    ["da"] = "Danish",
    ["et"] = "Estonian",
    ["fi"] = "Finnish",
    ["hu"] = "Hungarian",
    ["lv"] = "Latvian",
    ["lt"] = "Lithuanian",
    ["no"] = "Norwegian",
    ["ro"] = "Romanian",
    ["sk"] = "Slovak",
    ["sl"] = "Slovenian",
    ["sv"] = "Swedish",
    ["ar"] = "Arabic",
    ["hi"] = "Hindi",
    ["ko"] = "Korean",
    ["tr"] = "Turkish",
    ["vi"] = "Vietnamese",
}

-- Reverse map: language name to code (for translation APIs)
local LANGUAGE_CODE_MAP = {}
for code, name in pairs(LANGUAGE_MAP) do
    LANGUAGE_CODE_MAP[name] = code
end

-- Map KOReader language code to dictionary app language name
function DictSync:mapLanguageCode(code)
    if not code then return "English" end
    -- Try exact match first
    if LANGUAGE_MAP[code] then
        return LANGUAGE_MAP[code]
    end
    -- Try lowercase
    if LANGUAGE_MAP[code:lower()] then
        return LANGUAGE_MAP[code:lower()]
    end
    -- Try splitting on hyphen (e.g., "zh-CN" -> "zh")
    local base_code = code:match("^([^-]+)")
    if base_code and LANGUAGE_MAP[base_code] then
        return LANGUAGE_MAP[base_code]
    end
    -- Return capitalized version as fallback
    return "English"
end

-- Detect document language from KOReader
function DictSync:detectDocumentLanguage()
    -- Check configured source language first
    local configured_lang = self.settings:readSetting("source_language")
    if configured_lang and configured_lang ~= "" then
        return configured_lang
    end
    
    -- If source_language is empty or not set, we want auto-detect
    -- Try to get language from current document
    if self.ui and self.ui.document then
        local document = self.ui.document
        -- Try to get language from document metadata
        local props = document:getProps()
        if props and props.language then
            local detected_lang = self:mapLanguageCode(props.language)
            if detected_lang then
                -- Return detected language if found
                return detected_lang
            end
        end
    end
    
    -- For auto-detect, return nil so translateWord can use "auto"
    -- Don't fallback to user's language setting - let the API auto-detect
    return nil
end

-- Translate using DeepL API
function DictSync:translateWithDeepL(word, source_lang_code, target_lang_code, api_key)
    if not api_key or api_key == "" then
        return nil, "No DeepL API key configured"
    end
    
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local json = require("json")
    local response_body = {}
    
    -- Determine API endpoint (free or paid) based on user setting
    local use_paid_api = self.settings:readSetting("deepl_use_paid_api") or false
    local api_url = use_paid_api and "https://api.deepl.com/v2/translate" or "https://api-free.deepl.com/v2/translate"
    
    -- DeepL language codes need to be uppercase
    local target_code = target_lang_code:upper()
    local source_code = nil
    if source_lang_code and source_lang_code ~= "auto" and source_lang_code ~= "AUTO" then
        source_code = source_lang_code:upper()
    end
    
    -- Build form data string manually (DeepL expects form-urlencoded)
    -- Note: DeepL dropped form-body auth_key in November 2025 — the key is now
    -- sent via the Authorization header below.
    local form_parts = {
        "text=" .. self:urlEncode(word),
        "target_lang=" .. self:urlEncode(target_code),
    }
    
    if source_code then
        table.insert(form_parts, "source_lang=" .. self:urlEncode(source_code))
    end
    
    local form_data = table.concat(form_parts, "&")
    
    local success, result, status_code, headers = pcall(function()
        return http.request({
            url = api_url,
            method = "POST",
            headers = {
                ["Content-Type"] = "application/x-www-form-urlencoded",
                ["Authorization"] = "DeepL-Auth-Key " .. api_key,
            },
            source = ltn12.source.string(form_data),
            sink = ltn12.sink.table(response_body),
            timeout = 10,
        })
    end)
    
    if not success then
        return nil, "Network error: " .. tostring(result)
    end
    
    if status_code == 200 then
        local response_text = table.concat(response_body)
        local success_decode, response_data = pcall(function()
            return json.decode(response_text)
        end)
        
        if success_decode and response_data and response_data.translations and #response_data.translations > 0 then
            return response_data.translations[1].text, nil
        else
            -- Try to get error message from response
            if success_decode and response_data and response_data.message then
                return nil, "DeepL error: " .. response_data.message
            end
            return nil, "Failed to parse DeepL response: " .. (response_text:sub(1, 100) or "empty response")
        end
    elseif status_code == 403 then
        return nil, "DeepL API authentication failed (HTTP 403). Check your API key and ensure you've selected the correct API type (Free/Paid) in settings."
    elseif status_code == 456 then
        return nil, "DeepL API quota exceeded"
    elseif status_code == 400 then
        local response_text = table.concat(response_body)
        local success_decode, response_data = pcall(function()
            return json.decode(response_text)
        end)
        if success_decode and response_data and response_data.message then
            return nil, "DeepL API error: " .. response_data.message
        end
        return nil, "DeepL API bad request (HTTP 400). Check language codes."
    else
        local response_text = table.concat(response_body)
        return nil, "DeepL API error: HTTP " .. tostring(status_code) .. " - " .. (response_text:sub(1, 100) or "no details")
    end
end

-- Translate using Google Translate (free API)
function DictSync:translateWithGoogle(word, source_lang_code, target_lang_code)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local json = require("json")
    local response_body = {}
    
    -- Google Translate free API endpoint
    local url = string.format("https://translate.googleapis.com/translate_a/single?client=gtx&sl=%s&tl=%s&dt=t&q=%s",
        self:urlEncode(source_lang_code),
        self:urlEncode(target_lang_code),
        self:urlEncode(word)
    )
    
    local success, result, status_code, headers = pcall(function()
        return http.request({
            url = url,
            method = "GET",
            headers = {
                ["User-Agent"] = "Mozilla/5.0",
            },
            sink = ltn12.sink.table(response_body),
            timeout = 10,
        })
    end)
    
    if not success then
        return nil, "Network error: " .. tostring(result)
    end
    
    if status_code == 200 then
        local response_text = table.concat(response_body)
        local success_decode, response_data = pcall(function()
            return json.decode(response_text)
        end)
        
        if success_decode and response_data and response_data[1] and response_data[1][1] then
            -- Google returns: [[["translated_text",...]]]
            local translation = response_data[1][1][1]
            return translation, nil
        else
            return nil, "Failed to parse Google Translate response"
        end
    else
        return nil, "Google Translate error: HTTP " .. tostring(status_code)
    end
end

-- DeepL language code mapping (DeepL uses uppercase ISO codes)
local DEEPL_LANG_MAP = {
    ["en"] = "EN",
    ["de"] = "DE",
    ["fr"] = "FR",
    ["es"] = "ES",
    ["it"] = "IT",
    ["pt"] = "PT",
    ["ru"] = "RU",
    ["ja"] = "JA",
    ["zh"] = "ZH",
    ["uk"] = "UK",
    ["el"] = "EL",
    ["nl"] = "NL",
    ["pl"] = "PL",
    ["bg"] = "BG",
    ["cs"] = "CS",
    ["da"] = "DA",
    ["fi"] = "FI",
    ["hu"] = "HU",
    ["lv"] = "LV",
    ["lt"] = "LT",
    ["ro"] = "RO",
    ["sk"] = "SK",
    ["sl"] = "SL",
    ["sv"] = "SV",
    ["ar"] = "AR",
    ["hi"] = "HI",
    ["ko"] = "KO",
    ["tr"] = "TR",
    ["vi"] = "VI",
}

-- Wrapper function: try DeepL first, fallback to Google
function DictSync:translateWord(word, source_lang_name, target_lang_name)
    -- Convert language names to codes
    local source_code = "auto"
    if source_lang_name and source_lang_name ~= "" then
        source_code = LANGUAGE_CODE_MAP[source_lang_name] or "auto"
    end
    
    local target_code = "en"
    if target_lang_name and target_lang_name ~= "" then
        target_code = LANGUAGE_CODE_MAP[target_lang_name] or "en"
    end
    
    -- Check if user wants to force Google Translate
    local force_google = self.settings:readSetting("force_google_translate") or false
    
    -- Try DeepL first if API key is configured and not forcing Google
    if not force_google then
        local deepl_key = self.settings:readSetting("deepl_api_key")
        if deepl_key and deepl_key ~= "" then
            -- Convert to DeepL language codes (uppercase ISO codes)
            local deepl_source = nil
            if source_code ~= "auto" then
                deepl_source = DEEPL_LANG_MAP[source_code:lower()]
            end
            local deepl_target = DEEPL_LANG_MAP[target_code:lower()] or "EN"
            
            if deepl_target then
                local translation, error_msg = self:translateWithDeepL(word, deepl_source or "auto", deepl_target, deepl_key)
                if translation then
                    return translation, nil
                end
                -- If DeepL fails, fall through to Google
                logger.warn("Lingueez: DeepL translation failed: " .. (error_msg or "unknown error"))
            else
                logger.warn("Lingueez: Language not supported by DeepL, falling back to Google")
            end
        end
    end
    
    -- Fallback to Google Translate (use lowercase codes)
    local google_source = source_code == "auto" and "auto" or source_code:lower()
    local google_target = target_code:lower()
    local translation, error_msg = self:translateWithGoogle(word, google_source, google_target)
    if translation then
        return translation, nil
    end
    
    return nil, error_msg or "Translation failed"
end

-- URL encode helper
function DictSync:urlEncode(str)
    if not str then return "" end
    str = string.gsub(str, "([^%w%-%.%_%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    return str
end

-- === Backend mode + credentials =========================================
-- Resolved Supabase URL: the user's custom override if set, else the built-in
-- central Lingueez project.
function DictSync:getSupabaseUrl()
    local url = self.settings and self.settings:readSetting("supabase_url")
    if url and url ~= "" then return url end
    return DEFAULT_SUPABASE_URL
end

-- Resolved Supabase anon/public key (matches getSupabaseUrl).
function DictSync:getSupabaseKey()
    local key = self.settings and self.settings:readSetting("supabase_key")
    if key and key ~= "" then return key end
    return DEFAULT_SUPABASE_KEY
end

-- True when SUPABASE_URL points somewhere other than the built-in central project.
function DictSync:isCustomServer()
    local url = self.settings and self.settings:readSetting("supabase_url")
    url = url and url:match("^%s*(.-)%s*$") or ""
    return url ~= "" and url ~= DEFAULT_SUPABASE_URL
end

-- === Auth session state =================================================
-- Whether a sync action is permitted: custom mode never needs login; account
-- mode requires a stored access token.
function DictSync:isAuthed()
    if self:isCustomServer() then return true end
    local token = self.settings and self.settings:readSetting("auth_access_token")
    return token ~= nil and token ~= ""
end

-- Guard for sync actions: true if allowed, otherwise prompt the user to sign in.
function DictSync:ensureAuthed()
    if self:isAuthed() then return true end
    UIManager:show(InfoMessage:new{
        text = "Please sign in first:\nLingueez → Configure → Sign in",
    })
    return false
end

-- Clear the stored session (sign-out / failed refresh).
function DictSync:clearSession()
    if not self.settings then return end
    for _, k in ipairs({ "auth_access_token", "auth_refresh_token",
                         "auth_expires_at", "auth_user_id", "auth_user_email" }) do
        self.settings:delSetting(k)
    end
    self.settings:flush()
end

-- Return a non-expired access token in account mode, refreshing if it is within
-- 60s of expiry. Returns nil if not logged in or the refresh failed.
function DictSync:getValidAccessToken()
    if not self.settings then return nil end
    local token = self.settings:readSetting("auth_access_token")
    if not token or token == "" then return nil end
    local expires_at = tonumber(self.settings:readSetting("auth_expires_at")) or 0
    if os.time() >= (expires_at - 60) then
        if not self:refreshSession() then return nil end
        token = self.settings:readSetting("auth_access_token")
    end
    return token
end

-- The "Authorization: Bearer ..." value for a PostgREST request. Custom mode uses
-- the anon key (as today); account mode uses the user JWT so RLS resolves auth.uid(),
-- falling back to the anon key when not signed in (request will be RLS-restricted).
function DictSync:getBearerToken()
    local key = self:getSupabaseKey()
    if self:isCustomServer() then
        return "Bearer " .. key
    end
    local token = self:getValidAccessToken()
    return "Bearer " .. (token or key)
end

-- Check if word exists in Supabase
function DictSync:checkWordExists(language1, word1, language2, word2)
    if not self.settings then return nil, "Settings not initialized" end
    
    local supabase_url = self:getSupabaseUrl()
    local supabase_key = self:getSupabaseKey()
    local supabase_bearer = self:getBearerToken()
    
    if not supabase_url or not supabase_key then
        return nil, "Supabase credentials not configured"
    end
    
    local url = string.format("%s/rest/v1/words?language1=eq.%s&word1=eq.%s&language2=eq.%s&word2=eq.%s&deleted_at=is.null",
        supabase_url,
        self:urlEncode(language1),
        self:urlEncode(word1),
        self:urlEncode(language2),
        self:urlEncode(word2)
    )
    
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local response_body = {}
    
    local success, result, status_code, headers = pcall(function()
        return http.request({
            url = url,
            method = "GET",
            headers = {
                ["apikey"] = supabase_key,
                ["Authorization"] = supabase_bearer,
                ["Content-Type"] = "application/json",
            },
            sink = ltn12.sink.table(response_body),
            timeout = 10,
        })
    end)
    
    if not success then
        return nil, "Network error: " .. tostring(result)
    end
    
    if status_code == 200 then
        local json = require("json")
        local success_decode, data = pcall(function()
            return json.decode(table.concat(response_body))
        end)
        if success_decode and data and #data > 0 then
            return data[1], nil
        end
        return nil, nil
    elseif status_code == 401 or status_code == 403 then
        return nil, "Authentication failed. Please check your API key."
    else
        return nil, "HTTP " .. tostring(status_code) .. ": " .. table.concat(response_body)
    end
end

-- Save word to Supabase
function DictSync:saveWordToSupabase(word_data)
    if not self.settings then return false, "Settings not initialized" end
    
    local supabase_url = self:getSupabaseUrl()
    local supabase_key = self:getSupabaseKey()
    local supabase_bearer = self:getBearerToken()
    
    if not supabase_url or not supabase_key then
        return false, "Supabase credentials not configured"
    end
    
    -- Prepare payload with auto-set fields
    local payload = {
        language1 = word_data.language1,
        word1 = word_data.word1,
        language2 = word_data.language2,
        word2 = word_data.word2,
        source = "koreader",  -- Always set to "koreader"
        status = "New",       -- Always set to "New"
        favorite = word_data.favorite or false
    }
    
    -- Add optional fields if provided
    if word_data.definition then
        payload.definition = word_data.definition
    end
    if word_data.definition2 then
        payload.definition2 = word_data.definition2
    end
    
    local json = require("json")
    local payload_json = json.encode(payload)
    
    -- Check if word already exists
    local existing_word, error_msg = self:checkWordExists(
        word_data.language1,
        word_data.word1,
        word_data.language2,
        word_data.word2
    )
    
    if error_msg then
        return false, "Error checking for existing word: " .. error_msg
    end
    
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local response_body = {}
    
    if existing_word then
        -- Update existing word
        local url = string.format("%s/rest/v1/words?id=eq.%s",
            supabase_url,
            self:urlEncode(tostring(existing_word.id))
        )
        
        local success, result, status_code, headers = pcall(function()
            return http.request({
                url = url,
                method = "PATCH",
                headers = {
                    ["apikey"] = supabase_key,
                    ["Authorization"] = supabase_bearer,
                    ["Content-Type"] = "application/json",
                    ["Prefer"] = "return=representation",
                },
                source = ltn12.source.string(payload_json),
                sink = ltn12.sink.table(response_body),
                timeout = 10,
            })
        end)
        
        if not success then
            return false, "Network error: " .. tostring(result)
        end
        
        if status_code == 200 or status_code == 204 then
            return true, "Word updated successfully"
        elseif status_code == 401 or status_code == 403 then
            return false, "Authentication failed. Please check your API key."
        else
            return false, "HTTP " .. tostring(status_code) .. ": " .. table.concat(response_body)
        end
    else
        -- Insert new word
        local url = string.format("%s/rest/v1/words",
            supabase_url
        )
        
        local success, result, status_code, headers = pcall(function()
            return http.request({
                url = url,
                method = "POST",
                headers = {
                    ["apikey"] = supabase_key,
                    ["Authorization"] = supabase_bearer,
                    ["Content-Type"] = "application/json",
                    ["Prefer"] = "return=representation",
                },
                source = ltn12.source.string(payload_json),
                sink = ltn12.sink.table(response_body),
                timeout = 10,
            })
        end)
        
        if not success then
            return false, "Network error: " .. tostring(result)
        end
        
        if status_code == 201 or status_code == 200 then
            return true, "Word saved successfully"
        elseif status_code == 401 or status_code == 403 then
            return false, "Authentication failed. Please check your API key."
        elseif status_code == 409 then
            return false, "Duplicate word detected. Word already exists in database."
        else
            local error_msg = table.concat(response_body)
            local success_decode, error_data = pcall(function()
                return json.decode(error_msg)
            end)
            if success_decode and error_data and error_data.message then
                return false, "Error: " .. error_data.message
            end
            return false, "HTTP " .. tostring(status_code) .. ": " .. error_msg
        end
    end
end

-- ============================================
-- TEXTS: SUPABASE OPERATIONS
-- ============================================

-- Check whether a text with this title already exists
function DictSync:checkTextExists(title)
    if not self.settings then return nil, "Settings not initialized" end

    local supabase_url = self:getSupabaseUrl()
    local supabase_key = self:getSupabaseKey()
    local supabase_bearer = self:getBearerToken()

    if not supabase_url or not supabase_key then
        return nil, "Supabase credentials not configured"
    end

    local url = string.format("%s/rest/v1/texts?title=eq.%s&deleted_at=is.null",
        supabase_url,
        self:urlEncode(title)
    )

    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local response_body = {}

    local success, result, status_code, headers = pcall(function()
        return http.request({
            url = url,
            method = "GET",
            headers = {
                ["apikey"] = supabase_key,
                ["Authorization"] = supabase_bearer,
                ["Content-Type"] = "application/json",
            },
            sink = ltn12.sink.table(response_body),
            timeout = 10,
        })
    end)

    if not success then
        return nil, "Network error: " .. tostring(result)
    end

    if status_code == 200 then
        local json = require("json")
        local success_decode, data = pcall(function()
            return json.decode(table.concat(response_body))
        end)
        if success_decode and data and #data > 0 then
            return data[1], nil
        end
        return nil, nil
    elseif status_code == 401 or status_code == 403 then
        return nil, "Authentication failed. Please check your API key."
    else
        return nil, "HTTP " .. tostring(status_code) .. ": " .. table.concat(response_body)
    end
end

-- Save a text (current chapter) to Supabase. Updates an existing koreader text
-- with the same title, otherwise inserts a new row.
function DictSync:saveTextToSupabase(text_data)
    if not self.settings then return false, "Settings not initialized" end

    local supabase_url = self:getSupabaseUrl()
    local supabase_key = self:getSupabaseKey()
    local supabase_bearer = self:getBearerToken()

    if not supabase_url or not supabase_key then
        return false, "Supabase credentials not configured"
    end

    if not text_data.title or text_data.title == "" then
        return false, "Cannot save text without a title"
    end
    if not text_data.text or text_data.text == "" then
        return false, "Cannot save an empty text"
    end

    local payload = {
        title = text_data.title,
        text = text_data.text,
    }
    if text_data.language then
        payload.language = text_data.language
    end

    local json = require("json")
    local payload_json = json.encode(payload)

    -- Check if a text with this title already exists
    local existing_text, error_msg = self:checkTextExists(text_data.title)
    if error_msg then
        return false, "Error checking for existing text: " .. error_msg
    end

    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local response_body = {}

    if existing_text then
        -- Update existing text
        local url = string.format("%s/rest/v1/texts?id=eq.%s",
            supabase_url,
            self:urlEncode(tostring(existing_text.id))
        )

        local success, result, status_code, headers = pcall(function()
            return http.request({
                url = url,
                method = "PATCH",
                headers = {
                    ["apikey"] = supabase_key,
                    ["Authorization"] = supabase_bearer,
                    ["Content-Type"] = "application/json",
                    ["Prefer"] = "return=representation",
                },
                source = ltn12.source.string(payload_json),
                sink = ltn12.sink.table(response_body),
                timeout = 10,
            })
        end)

        if not success then
            return false, "Network error: " .. tostring(result)
        end

        if status_code == 200 or status_code == 204 then
            return true, "Text updated successfully"
        elseif status_code == 401 or status_code == 403 then
            return false, "Authentication failed. Please check your API key."
        else
            return false, "HTTP " .. tostring(status_code) .. ": " .. table.concat(response_body)
        end
    else
        -- Insert new text
        local url = string.format("%s/rest/v1/texts", supabase_url)

        local success, result, status_code, headers = pcall(function()
            return http.request({
                url = url,
                method = "POST",
                headers = {
                    ["apikey"] = supabase_key,
                    ["Authorization"] = supabase_bearer,
                    ["Content-Type"] = "application/json",
                    ["Prefer"] = "return=representation",
                },
                source = ltn12.source.string(payload_json),
                sink = ltn12.sink.table(response_body),
                timeout = 10,
            })
        end)

        if not success then
            return false, "Network error: " .. tostring(result)
        end

        if status_code == 201 or status_code == 200 then
            return true, "Text saved successfully"
        elseif status_code == 401 or status_code == 403 then
            return false, "Authentication failed. Please check your API key."
        else
            local err = table.concat(response_body)
            local success_decode, error_data = pcall(function()
                return json.decode(err)
            end)
            if success_decode and error_data and error_data.message then
                return false, "Error: " .. error_data.message
            end
            return false, "HTTP " .. tostring(status_code) .. ": " .. err
        end
    end
end

-- Fetch texts from Supabase with pagination (excludes soft-deleted rows)
function DictSync:fetchTextsFromSupabase(page, page_size)
    page = page or 1
    page_size = page_size or 25

    if not self.settings then return nil, "Settings not initialized" end

    local supabase_url = self:getSupabaseUrl()
    local supabase_key = self:getSupabaseKey()
    local supabase_bearer = self:getBearerToken()

    if not supabase_url or not supabase_key then
        return nil, "Supabase credentials not configured"
    end

    local offset = (page - 1) * page_size
    local data_url = string.format(
        "%s/rest/v1/texts?deleted_at=is.null&order=created_at.desc&limit=%d&offset=%d",
        supabase_url, page_size, offset
    )

    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local response_body = {}

    local success, result, status_code, headers = pcall(function()
        return http.request({
            url = data_url,
            method = "GET",
            headers = {
                ["apikey"] = supabase_key,
                ["Authorization"] = supabase_bearer,
                ["Content-Type"] = "application/json",
                ["Prefer"] = "count=exact",
            },
            sink = ltn12.sink.table(response_body),
            timeout = 10,
        })
    end)

    if not success then
        return nil, "Network error: " .. tostring(result)
    end

    if status_code == 200 or status_code == 206 then
        local json = require("json")
        local success_decode, data = pcall(function()
            return json.decode(table.concat(response_body))
        end)

        if not success_decode then
            return nil, "Failed to parse JSON response: " .. tostring(data)
        end
        if type(data) ~= "table" then
            return nil, "Invalid response format: expected array"
        end

        local total_count = 0
        if headers["content-range"] then
            total_count = tonumber(headers["content-range"]:match("/(%d+)") or "0")
        end
        local total_pages = math.ceil(total_count / page_size)

        return {
            texts = data,
            page = page,
            page_size = page_size,
            total_count = total_count,
            total_pages = total_pages,
            has_next = page < total_pages,
            has_prev = page > 1,
        }, nil
    elseif status_code == 401 or status_code == 403 then
        return nil, "Authentication failed. Please check your API key."
    else
        return nil, "HTTP " .. tostring(status_code) .. ": " .. table.concat(response_body)
    end
end

-- ============================================
-- FETCH WORDS FROM SUPABASE WITH PAGINATION
-- ============================================

-- Fetch tags from Supabase
function DictSync:fetchTagsFromSupabase(limit, offset)
    if not self.settings then return {}, "Settings not initialized" end
    
    local supabase_url = self:getSupabaseUrl()
    local supabase_key = self:getSupabaseKey()
    local supabase_bearer = self:getBearerToken()
    
    if not supabase_url or not supabase_key then
        return {}, "Supabase credentials not configured"
    end
    
    local query = {"order=tag_name.asc"}
    local prefer_exact_count = false
    if limit then
        table.insert(query, "limit=" .. tostring(limit))
        if offset and offset > 0 then
            table.insert(query, "offset=" .. tostring(offset))
        end
        prefer_exact_count = true
    end
    
    local url = string.format("%s/rest/v1/tags?%s",
        supabase_url,
        table.concat(query, "&")
    )
    
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local response_body = {}
    
    local success, result, status_code, headers = pcall(function()
        return http.request({
            url = url,
            method = "GET",
            headers = {
                ["apikey"] = supabase_key,
                ["Authorization"] = supabase_bearer,
                ["Content-Type"] = "application/json",
                ["Prefer"] = prefer_exact_count and "count=exact" or nil,
            },
            sink = ltn12.sink.table(response_body),
            timeout = 10,
        })
    end)
    
    if not success then
        return {}, "Network error: " .. tostring(result)
    end
    
    if status_code == 200 or status_code == 206 then
        local json = require("json")
        local success_decode, data = pcall(function()
            return json.decode(table.concat(response_body))
        end)
        
        if success_decode and data then
            local has_more = false
            if limit then
                has_more = #data == limit
                if not has_more and headers and (headers["content-range"] or headers["Content-Range"]) then
                    local range_header = headers["content-range"] or headers["Content-Range"]
                    local start_idx, end_idx, total = range_header:match("(%d+)%-(%d+)/(%d+)")
                    if start_idx and end_idx and total then
                        has_more = tonumber(end_idx) + 1 < tonumber(total)
                    end
                end
            end
            return data, nil, has_more
        else
            return {}, "Failed to parse response"
        end
    else
        return {}, "HTTP " .. tostring(status_code)
    end
end

-- Get word IDs that have specific tags
function DictSync:getWordIdsByTags(tag_names)
    if not tag_names or #tag_names == 0 then
        return nil  -- No tag filter
    end
    
    if not self.settings then return nil, "Settings not initialized" end
    
    local supabase_url = self:getSupabaseUrl()
    local supabase_key = self:getSupabaseKey()
    local supabase_bearer = self:getBearerToken()
    
    if not supabase_url or not supabase_key then
        return nil, "Supabase credentials not configured"
    end
    
    -- First, get tag IDs by names
    local tag_ids = {}
    local all_tags, error_msg = self:fetchTagsFromSupabase()
    if error_msg then
        return nil, error_msg
    end
    
    for _, tag_name in ipairs(tag_names) do
        for _, tag in ipairs(all_tags) do
            if tag.tag_name == tag_name then
                table.insert(tag_ids, tag.tag_id)
                break
            end
        end
    end
    
    if #tag_ids == 0 then
        return {}, nil  -- No matching tags found
    end
    
    -- Get word_ids that have any of these tags
    local tag_ids_str = table.concat(tag_ids, ",")
    local url = string.format("%s/rest/v1/word_tags?tag_id=in.(%s)&select=word_id",
        supabase_url,
        tag_ids_str
    )
    
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local response_body = {}
    
    local success, result, status_code, headers = pcall(function()
        return http.request({
            url = url,
            method = "GET",
            headers = {
                ["apikey"] = supabase_key,
                ["Authorization"] = supabase_bearer,
                ["Content-Type"] = "application/json",
            },
            sink = ltn12.sink.table(response_body),
            timeout = 10,
        })
    end)
    
    if not success then
        return nil, "Network error: " .. tostring(result)
    end
    
    if status_code == 200 then
        local json = require("json")
        local success_decode, data = pcall(function()
            return json.decode(table.concat(response_body))
        end)
        
        if success_decode and data then
            local word_ids = {}
            for _, item in ipairs(data) do
                table.insert(word_ids, item.word_id)
            end
            return word_ids, nil
        else
            return nil, "Failed to parse response"
        end
    else
        return nil, "HTTP " .. tostring(status_code)
    end
end

local function cloneWordRecord(word)
    local copy = {}
    if word then
        for k, v in pairs(word) do
            copy[k] = v
        end
    end
    return copy
end

local function createFieldMap()
    return {
        word1 = "word1",
        word2 = "word2",
        language1 = "language1",
        language2 = "language2",
        definition = "definition",
        definition2 = "definition2",
    }
end

local function remapField(field, field_map)
    if field_map and field_map[field] then
        return field_map[field]
    end
    return field
end

local function assignRemapped(payload, field_map, field, value)
    if value == nil then
        return
    end
    local target_field = remapField(field, field_map)
    payload[target_field] = value
end

local function swapFieldMap(field_map)
    if not field_map then
        return
    end
    field_map.word1, field_map.word2 = field_map.word2, field_map.word1
    field_map.language1, field_map.language2 = field_map.language2, field_map.language1
    field_map.definition, field_map.definition2 = field_map.definition2, field_map.definition
end

local function swapWordLanguages(record, field_map)
    record.word1, record.word2 = record.word2, record.word1
    record.language1, record.language2 = record.language2, record.language1
    record.definition, record.definition2 = record.definition2, record.definition
    swapFieldMap(field_map)
end

local function normalizeWordForFilters(word, filter_language1, filter_language2)
    local normalized = cloneWordRecord(word)
    normalized.id = normalized.id or normalized.ID
    normalized._field_map = normalized._field_map or createFieldMap()

    local lang1 = normalized.language1
    local lang2 = normalized.language2
    local include_word = true

    if filter_language1 and filter_language2 then
        if lang1 == filter_language1 and lang2 == filter_language2 then
            -- already ordered
        elseif lang1 == filter_language2 and lang2 == filter_language1 then
            swapWordLanguages(normalized, normalized._field_map)
        else
            include_word = false
        end
    elseif filter_language1 then
        if lang1 == filter_language1 then
            -- ok
        elseif lang2 == filter_language1 then
            swapWordLanguages(normalized, normalized._field_map)
        else
            include_word = false
        end
    elseif filter_language2 then
        if lang2 == filter_language2 then
            -- ok
        elseif lang1 == filter_language2 then
            swapWordLanguages(normalized, normalized._field_map)
        else
            include_word = false
        end
    end

    return normalized, include_word
end

-- Fetch words from Supabase with pagination and filters
function DictSync:fetchWordsFromSupabase(page, page_size, filters)
    page = page or 1
    page_size = page_size or 25  -- Default to 25 words per page
    filters = filters or {}
    
    if not self.settings then return nil, "Settings not initialized" end
    
    local supabase_url = self:getSupabaseUrl()
    local supabase_key = self:getSupabaseKey()
    local supabase_bearer = self:getBearerToken()
    
    if not supabase_url or not supabase_key then
        return nil, "Supabase credentials not configured"
    end
    
    -- Calculate offset for pagination
    local offset = (page - 1) * page_size
    
    -- Build base query
    local query_parts = {
        "deleted_at=is.null",  -- Exclude soft-deleted words
        "order=created_at.desc",  -- Most recent first
    }
    local or_language_clauses = {}
    local or_search_clauses = {}
    
    -- Handle tag filtering first (requires special handling)
    local word_ids_with_tags = nil
    local error_msg = nil
    if filters.tags and #filters.tags > 0 then
        word_ids_with_tags, error_msg = self:getWordIdsByTags(filters.tags)
        if error_msg then
            return nil, "Error filtering by tags: " .. error_msg
        end
        if word_ids_with_tags and #word_ids_with_tags == 0 then
            -- No words match the tags, return empty result
            return {
                words = {},
                page = page,
                page_size = page_size,
                total_count = 0,
                total_pages = 0,
                has_next = false,
                has_prev = page > 1
            }, nil
        end
    end
    
    -- Add other filters
    if filters.language1 or filters.language2 then
        if filters.language1 and filters.language2 then
            local lang1 = self:urlEncode(filters.language1)
            local lang2 = self:urlEncode(filters.language2)
            table.insert(or_language_clauses, string.format("and(language1.eq.%s,language2.eq.%s)", lang1, lang2))
            table.insert(or_language_clauses, string.format("and(language1.eq.%s,language2.eq.%s)", lang2, lang1))
        else
            local lang = self:urlEncode(filters.language1 or filters.language2)
            table.insert(or_language_clauses, "language1.eq." .. lang)
            table.insert(or_language_clauses, "language2.eq." .. lang)
        end
    end
    if filters.favorite ~= nil then
        table.insert(query_parts, "favorite=eq." .. tostring(filters.favorite))
    end
    if filters.search then
        local search_pattern = "%" .. filters.search .. "%"
        local encoded_pattern = self:urlEncode(search_pattern)
        table.insert(or_search_clauses, "word1.ilike." .. encoded_pattern)
        table.insert(or_search_clauses, "word2.ilike." .. encoded_pattern)
    end

    local function buildOrExpression(clauses)
        return "or(" .. table.concat(clauses, ",") .. ")"
    end

    if #or_language_clauses > 0 and #or_search_clauses > 0 then
        table.insert(query_parts, string.format("and=(%s,%s)", buildOrExpression(or_language_clauses), buildOrExpression(or_search_clauses)))
    elseif #or_language_clauses > 0 then
        table.insert(query_parts, "or=(" .. table.concat(or_language_clauses, ",") .. ")")
    elseif #or_search_clauses > 0 then
        table.insert(query_parts, "or=(" .. table.concat(or_search_clauses, ",") .. ")")
    end
    
    -- If we have tag-filtered word IDs, we need to filter by ID
    if word_ids_with_tags and #word_ids_with_tags > 0 then
        local ids_str = table.concat(word_ids_with_tags, ",")
        table.insert(query_parts, "id=in.(" .. ids_str .. ")")
    end
    
    -- Build URL
    local base_url = string.format("%s/rest/v1/words?%s",
        supabase_url,
        table.concat(query_parts, "&")
    )
    
    -- Get the actual data with pagination
    local data_url = base_url .. "&limit=" .. page_size .. "&offset=" .. offset
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local response_body = {}
    
    success, result, status_code, headers = pcall(function()
        return http.request({
            url = data_url,
            method = "GET",
            headers = {
                ["apikey"] = supabase_key,
                ["Authorization"] = supabase_bearer,
                ["Content-Type"] = "application/json",
                ["Prefer"] = "count=exact",
            },
            sink = ltn12.sink.table(response_body),
            timeout = 10,
        })
    end)
    
    if not success then
        return nil, "Network error: " .. tostring(result)
    end
    
    -- HTTP 200 (OK) and 206 (Partial Content) are both valid for paginated requests
    if status_code == 200 or status_code == 206 then
        local json = require("json")
        local response_text = table.concat(response_body)
        local success_decode, data = pcall(function()
            return json.decode(response_text)
        end)
        
        if not success_decode then
            logger.err("Lingueez: JSON decode failed: " .. tostring(data))
            return nil, "Failed to parse JSON response: " .. tostring(data)
        end
        
        if not data then
            return nil, "Empty response from server"
        end
        
        -- Ensure data is a table/array
        if type(data) ~= "table" then
            logger.err("Lingueez: Response is not a table: " .. type(data))
            return nil, "Invalid response format: expected array, got " .. type(data)
        end
        
        -- Get total count from headers if available
        local total_count = 0
        if headers["content-range"] then
            total_count = tonumber(headers["content-range"]:match("/(%d+)") or "0")
        end
        
        local total_pages = math.ceil(total_count / page_size)
        
        local normalized_words = {}
        for _, word in ipairs(data) do
            local normalized, include_word = normalizeWordForFilters(word, filters.language1, filters.language2)
            if include_word then
                table.insert(normalized_words, normalized)
            end
        end

        data = normalized_words

        logger.dbg("Lingueez: Fetched " .. #data .. " words, total: " .. total_count)
        
        return {
            words = data,
            page = page,
            page_size = page_size,
            total_count = total_count,
            total_pages = total_pages,
            has_next = page < total_pages,
            has_prev = page > 1
        }, nil
    elseif status_code == 401 or status_code == 403 then
        return nil, "Authentication failed. Please check your API key."
    else
        local error_msg = "HTTP " .. tostring(status_code)
        if response_body and #response_body > 0 then
            local response_text = table.concat(response_body)
            -- Try to parse error message from JSON if possible
            local json = require("json")
            local success_decode, error_data = pcall(function()
                return json.decode(response_text)
            end)
            if success_decode and error_data and error_data.message then
                error_msg = error_msg .. ": " .. error_data.message
            elseif string.len(response_text) < 200 then
                error_msg = error_msg .. ": " .. response_text
            else
                error_msg = error_msg .. ": " .. response_text:sub(1, 200) .. "..."
            end
        end
        return nil, error_msg
    end
end

-- Get tags for a specific word
function DictSync:getWordTags(word_id)
    if not self.settings then return {}, "Settings not initialized" end
    
    local supabase_url = self:getSupabaseUrl()
    local supabase_key = self:getSupabaseKey()
    local supabase_bearer = self:getBearerToken()
    
    if not supabase_url or not supabase_key then
        return {}, "Supabase credentials not configured"
    end
    
    local url = string.format("%s/rest/v1/word_tags?word_id=eq.%s&select=*,tags(tag_name)",
        supabase_url,
        self:urlEncode(tostring(word_id))
    )
    
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local response_body = {}
    
    local success, result, status_code, headers = pcall(function()
        return http.request({
            url = url,
            method = "GET",
            headers = {
                ["apikey"] = supabase_key,
                ["Authorization"] = supabase_bearer,
                ["Content-Type"] = "application/json",
            },
            sink = ltn12.sink.table(response_body),
            timeout = 10,
        })
    end)
    
    if not success then
        return {}, "Network error: " .. tostring(result)
    end
    
    if status_code == 200 then
        local json = require("json")
        local success_decode, data = pcall(function()
            return json.decode(table.concat(response_body))
        end)
        
        if success_decode and data then
            local tag_names = {}
            for _, item in ipairs(data) do
                if item.tags and item.tags.tag_name then
                    table.insert(tag_names, item.tags.tag_name)
                end
            end
            return tag_names, nil
        else
            return {}, "Failed to parse response"
        end
    else
        return {}, "HTTP " .. tostring(status_code)
    end
end

-- Fetch Wikipedia definition
function DictSync:fetchWikipediaDefinition(word, language)
    -- Map language to Wikipedia language code
    local lang_code = "en"  -- Default to English
    if language then
        local lang_map = {
            ["English"] = "en",
            ["German"] = "de",
            ["French"] = "fr",
            ["Spanish"] = "es",
            ["Italian"] = "it",
            ["Portuguese"] = "pt",
            ["Russian"] = "ru",
            ["Japanese"] = "ja",
            ["Chinese"] = "zh",
            ["Greek"] = "el",
            ["Dutch"] = "nl",
            ["Polish"] = "pl",
        }
        lang_code = lang_map[language] or "en"
    end
    
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local json = require("json")
    
    local function fetchExtract(title)
        if not title or title == "" then
            return nil, "Empty title"
        end
        local encoded_title = self:urlEncode(title)
        local url = string.format(
            "https://%s.wikipedia.org/w/api.php?action=query&prop=extracts&format=json&exintro=true&explaintext=true&redirects=1&origin=*&titles=%s",
            lang_code,
            encoded_title
        )
        local response_body = {}
        local success, result, status_code = pcall(function()
            return http.request({
                url = url,
                method = "GET",
                headers = {
                    ["User-Agent"] = "KOReader Lingueez Plugin",
                },
                sink = ltn12.sink.table(response_body),
                timeout = 10,
            })
        end)
        if not success then
            return nil, "Network error: " .. tostring(result)
        end
        if status_code ~= 200 then
            local detail = table.concat(response_body)
            if detail == "" then
                detail = "HTTP " .. tostring(status_code)
            else
                detail = "HTTP " .. tostring(status_code) .. ": " .. detail
            end
            return nil, detail
        end
        local response_text = table.concat(response_body)
        local success_decode, data = pcall(function()
            return json.decode(response_text)
        end)
        if not success_decode or not data or not data.query or not data.query.pages then
            return nil, "Failed to parse response"
        end
        for _, page in pairs(data.query.pages) do
            if not page.missing and page.extract and page.extract ~= "" then
                return page.extract, nil
            end
        end
        return nil, "No definition found"
    end
    
    local function searchTitle(query)
        local encoded_query = self:urlEncode(query or "")
        local url = string.format(
            "https://%s.wikipedia.org/w/api.php?action=query&list=search&format=json&srwhat=text&srlimit=1&origin=*&srsearch=%s",
            lang_code,
            encoded_query
        )
        local response_body = {}
        local success, result, status_code = pcall(function()
            return http.request({
                url = url,
                method = "GET",
                headers = {
                    ["User-Agent"] = "KOReader Lingueez Plugin",
                },
                sink = ltn12.sink.table(response_body),
                timeout = 10,
            })
        end)
        if not success then
            return nil, "Network error: " .. tostring(result)
        end
        if status_code ~= 200 then
            return nil, "HTTP " .. tostring(status_code)
        end
        local success_decode, data = pcall(function()
            return json.decode(table.concat(response_body))
        end)
        if success_decode and data and data.query and data.query.search and data.query.search[1] then
            return data.query.search[1].title, nil
        end
        return nil, "No related articles found"
    end
    
    -- Try exact title first
    local extract, err = fetchExtract(word)
    if extract then
        return extract, nil
    end
    
    -- Fall back to best search result
    local best_title, search_err = searchTitle(word)
    if best_title then
        local extract2, err2 = fetchExtract(best_title)
        if extract2 then
            return extract2, nil
        end
        return nil, err2 or err or "No definition found"
    end
    
    return nil, search_err or err or "No definition found"
end

-- Update word definition in Supabase
-- Fetch a single word by ID from Supabase
function DictSync:fetchWordById(word_id, filters)
    filters = filters or self.words_filters or {}
    if not self.settings then return nil, "Settings not initialized" end
    
    local supabase_url = self:getSupabaseUrl()
    local supabase_key = self:getSupabaseKey()
    local supabase_bearer = self:getBearerToken()
    
    if not supabase_url or not supabase_key then
        return nil, "Supabase credentials not configured"
    end
    
    local url = string.format("%s/rest/v1/words?id=eq.%s",
        supabase_url,
        self:urlEncode(tostring(word_id))
    )
    
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local response_body = {}
    
    local success, result, status_code, headers = pcall(function()
        return http.request({
            url = url,
            method = "GET",
            headers = {
                ["apikey"] = supabase_key,
                ["Authorization"] = supabase_bearer,
                ["Content-Type"] = "application/json",
            },
            sink = ltn12.sink.table(response_body),
            timeout = 10,
        })
    end)
    
    if not success then
        return nil, "Network error: " .. tostring(result)
    end
    
    if status_code == 200 then
        local json = require("json")
        local words = json.decode(table.concat(response_body))
        if words and #words > 0 then
            local normalized = normalizeWordForFilters(words[1], filters.language1, filters.language2)
            return normalized, nil
        else
            return nil, "Word not found"
        end
    elseif status_code == 401 or status_code == 403 then
        return nil, "Authentication failed. Please check your API key."
    else
        return nil, "HTTP " .. tostring(status_code) .. ": " .. table.concat(response_body)
    end
end

local socket_gettime = nil
do
    local ok, socket_lib = pcall(require, "socket")
    if ok and socket_lib and socket_lib.gettime then
        socket_gettime = socket_lib.gettime
    end
end

local function getPreciseUtcTimestamp()
    local time_sec = os.time()
    local time_usec = 0
    if socket_gettime then
        local ok, precise_time = pcall(socket_gettime)
        if ok and type(precise_time) == "number" then
            time_sec = math.floor(precise_time)
            time_usec = math.floor((precise_time - time_sec) * 1000000 + 0.5)
        end
    end
    local date_str = os.date("!%Y-%m-%d %H:%M:%S", time_sec)
    return string.format("%s.%06d", date_str, time_usec)
end

local function ensureEditedSourceTag(source_value)
    if not source_value or source_value == "" then
        return "koreader_edited"
    end
    if source_value:match("_edited$") then
        return source_value
    end
    return source_value .. "_edited"
end

local function decodeSupabaseErrorMessage(response_text)
    if not response_text or response_text == "" then
        return nil
    end
    local ok, decoded = pcall(function()
        local json = require("json")
        return json.decode(response_text)
    end)
    if ok and type(decoded) == "table" then
        return decoded.message or decoded.error or decoded.hint or decoded.details
    end
    return nil
end

function DictSync:fetchWordSource(supabase_url, supabase_key, word_id)
    if not supabase_url or not supabase_key or not word_id then
        return nil, "Supabase credentials or word id missing"
    end
    local supabase_bearer = self:getBearerToken()

    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local response_body = {}
    
    local success, result, status_code = pcall(function()
        return http.request({
            url = string.format("%s/rest/v1/words?id=eq.%s&select=source",
                supabase_url,
                tostring(word_id)
            ),
            method = "GET",
            headers = {
                ["apikey"] = supabase_key,
                ["Authorization"] = supabase_bearer,
            },
            sink = ltn12.sink.table(response_body),
            timeout = 10,
        })
    end)
    
    if not success then
        return nil, "Network error: " .. tostring(result)
    end
    
    local response_text = table.concat(response_body)
    
    if status_code == 200 then
        local json = require("json")
        local ok, data = pcall(function()
            return json.decode(response_text)
        end)
        if ok and data and #data > 0 then
            return data[1].source, nil
        end
        return nil, "Word not found"
    elseif status_code == 401 or status_code == 403 then
        return nil, "Authentication failed. Please check your API key."
    elseif status_code == 404 then
        return nil, "Word not found"
    else
        local detail = decodeSupabaseErrorMessage(response_text) or response_text
        return nil, string.format("HTTP %s: %s", tostring(status_code), detail ~= "" and detail or "Unknown error")
    end
end

function DictSync:updateWordDefinition(word_id, definition, definition2, existing_source)
    if not self.settings then return false, "Settings not initialized" end
    if not word_id then return false, "Word ID missing" end
    
    local supabase_url = self:getSupabaseUrl()
    local supabase_key = self:getSupabaseKey()
    local supabase_bearer = self:getBearerToken()
    
    if not supabase_url or not supabase_key then
        return false, "Supabase credentials not configured"
    end
    
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local json = require("json")
    
    local payload = {}
    if definition ~= nil then
        payload.definition = definition
    end
    if definition2 ~= nil then
        payload.definition2 = definition2
    end
    
    payload.edited_at = getPreciseUtcTimestamp()
    
    local source_value = existing_source or ""
    if not source_value or source_value == "" then
        local current_source, source_error = self:fetchWordSource(supabase_url, supabase_key, word_id)
        if current_source then
            source_value = current_source
        elseif source_error then
            logger.warn("Lingueez: Could not fetch source for word " .. tostring(word_id) .. ": " .. source_error)
        end
    end
    if source_value and source_value ~= "" then
        payload.source = ensureEditedSourceTag(source_value)
    end
    
    local payload_json = json.encode(payload)
    
    local url = string.format("%s/rest/v1/words?id=eq.%s",
        supabase_url,
        tostring(word_id)
    )
    
    local response_body = {}
    
    local success, result, status_code, headers = pcall(function()
        return http.request({
            url = url,
            method = "PATCH",
            headers = {
                ["apikey"] = supabase_key,
                ["Authorization"] = supabase_bearer,
                ["Content-Type"] = "application/json",
                ["Prefer"] = "return=representation",
            },
            source = ltn12.source.string(payload_json),
            sink = ltn12.sink.table(response_body),
            timeout = 10,
        })
    end)
    
    if not success then
        logger.err("Lingueez: Definition update network error: " .. tostring(result))
        return false, "Network error: " .. tostring(result)
    end
    
    local response_text = table.concat(response_body)
    local function decodeResponse()
        if not response_text or response_text == "" then
            return nil
        end
        local ok, decoded = pcall(function()
            return json.decode(response_text)
        end)
        return ok and decoded or nil
    end
    
    if status_code == 200 then
        local decoded = decodeResponse()
        if decoded then
            if type(decoded) == "table" and decoded.message then
                return false, decoded.message
            end
            if type(decoded) == "table" and next(decoded) ~= nil then
                return true, "Definition updated successfully"
            end
        end
        logger.warn("Lingueez: Definition update returned empty body for word " .. tostring(word_id))
        return true, "Definition update requested"
    elseif status_code == 204 then
        return true, "Definition updated successfully"
    elseif status_code == 401 or status_code == 403 then
        return false, "Authentication failed. Please check your API key."
    else
        local detail = decodeSupabaseErrorMessage(response_text) or response_text
        return false, "HTTP " .. tostring(status_code) .. ": " .. (detail ~= "" and detail or "Unknown error")
    end
end

function DictSync:updateWordEntry(word_id, word_data)
    if not self.settings then return false, "Settings not initialized" end
    if not word_id then return false, "Word ID missing" end
    if not word_data then return false, "Word data missing" end
    
    local supabase_url = self:getSupabaseUrl()
    local supabase_key = self:getSupabaseKey()
    local supabase_bearer = self:getBearerToken()
    
    if not supabase_url or not supabase_key then
        return false, "Supabase credentials not configured"
    end
    
    local field_map = word_data._field_map or createFieldMap()
    local payload = {}
    assignRemapped(payload, field_map, "word1", word_data.word1)
    assignRemapped(payload, field_map, "language1", word_data.language1)
    assignRemapped(payload, field_map, "word2", word_data.word2)
    assignRemapped(payload, field_map, "language2", word_data.language2)
    if word_data.definition ~= nil then
        assignRemapped(payload, field_map, "definition", word_data.definition)
    end
    if word_data.definition2 ~= nil then
        assignRemapped(payload, field_map, "definition2", word_data.definition2)
    end
    
    payload.edited_at = getPreciseUtcTimestamp()
    
    local source_value = word_data.source or word_data.Source
    if not source_value or source_value == "" then
        local current_source, source_error = self:fetchWordSource(supabase_url, supabase_key, word_id)
        if current_source then
            source_value = current_source
        elseif source_error then
            logger.warn("Lingueez: Could not fetch source for word " .. tostring(word_id) .. ": " .. source_error)
        end
    end
    if source_value and source_value ~= "" then
        payload.source = ensureEditedSourceTag(source_value)
    end
    
    local json = require("json")
    local payload_json = json.encode(payload)
    
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local response_body = {}
    
    local success, result, status_code = pcall(function()
        return http.request({
            url = string.format("%s/rest/v1/words?id=eq.%s",
                supabase_url,
                tostring(word_id)
            ),
            method = "PATCH",
            headers = {
                ["apikey"] = supabase_key,
                ["Authorization"] = supabase_bearer,
                ["Content-Type"] = "application/json",
                ["Prefer"] = "return=representation",
            },
            source = ltn12.source.string(payload_json),
            sink = ltn12.sink.table(response_body),
            timeout = 10,
        })
    end)
    
    if not success then
        logger.err("Lingueez: Word update network error: " .. tostring(result))
        return false, "Network error: " .. tostring(result)
    end
    
    local response_text = table.concat(response_body)
    local function decodeResponse()
        if not response_text or response_text == "" then
            return nil
        end
        local ok, decoded = pcall(function()
            return json.decode(response_text)
        end)
        return ok and decoded or nil
    end
    
    if status_code == 200 then
        local decoded = decodeResponse()
        if decoded then
            if type(decoded) == "table" and decoded.message then
                return false, decoded.message
            end
            if type(decoded) == "table" and next(decoded) ~= nil then
                return true, "Word updated successfully"
            end
        end
        logger.warn("Lingueez: Word update returned empty body for word " .. tostring(word_id))
        return true, "Word update requested"
    elseif status_code == 204 then
        return true, "Word updated successfully"
    elseif status_code == 401 or status_code == 403 then
        return false, "Authentication failed. Please check your API key."
    else
        local detail = decodeSupabaseErrorMessage(response_text) or response_text
        return false, "HTTP " .. tostring(status_code) .. ": " .. (detail ~= "" and detail or "Unknown error")
    end
end

-- === Supabase Auth (GoTrue) =============================================
-- Sign-in against the built-in central project so per-user RLS scopes the
-- user's words/texts/tags. Login is only meaningful in account mode; custom
-- (personal-schema) servers are anonymous and never call these.

-- Minimal SHA-256 (LuaJIT BitOp) for PKCE s256 code challenges.
local bit = require("bit")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local rshift, lshift, ror, tobit = bit.rshift, bit.lshift, bit.ror, bit.tobit

local SHA256_K = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
}

local function u32be(n)
    return string.char(band(rshift(n, 24), 0xff), band(rshift(n, 16), 0xff),
                       band(rshift(n, 8), 0xff), band(n, 0xff))
end

local function sha256_bytes(message)
    local h0,h1,h2,h3,h4,h5,h6,h7 =
        0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19
    local len = #message
    local msg = message .. "\128"
    while (#msg % 64) ~= 56 do msg = msg .. "\0" end
    local bitlen = len * 8
    msg = msg .. u32be(math.floor(bitlen / 4294967296)) .. u32be(bitlen % 4294967296)
    for chunk = 1, #msg, 64 do
        local w = {}
        for i = 0, 15 do
            local b1,b2,b3,b4 = string.byte(msg, chunk + i*4, chunk + i*4 + 3)
            w[i] = bor(lshift(b1, 24), lshift(b2, 16), lshift(b3, 8), b4)
        end
        for i = 16, 63 do
            local s0 = bxor(ror(w[i-15], 7), ror(w[i-15], 18), rshift(w[i-15], 3))
            local s1 = bxor(ror(w[i-2], 17), ror(w[i-2], 19), rshift(w[i-2], 10))
            w[i] = tobit(w[i-16] + s0 + w[i-7] + s1)
        end
        local a,b,c,d,e,f,g,h = h0,h1,h2,h3,h4,h5,h6,h7
        for i = 0, 63 do
            local S1 = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local t1 = tobit(h + S1 + ch + SHA256_K[i+1] + w[i])
            local S0 = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
            local maj = bxor(band(a, b), band(a, c), band(b, c))
            local t2 = tobit(S0 + maj)
            h = g; g = f; f = e; e = tobit(d + t1)
            d = c; c = b; b = a; a = tobit(t1 + t2)
        end
        h0=tobit(h0+a); h1=tobit(h1+b); h2=tobit(h2+c); h3=tobit(h3+d)
        h4=tobit(h4+e); h5=tobit(h5+f); h6=tobit(h6+g); h7=tobit(h7+h)
    end
    return u32be(h0)..u32be(h1)..u32be(h2)..u32be(h3)..u32be(h4)..u32be(h5)..u32be(h6)..u32be(h7)
end

local B64URL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local function base64url(data)
    local function ch(v) return B64URL:sub(v + 1, v + 1) end
    local out, i, n = {}, 1, #data
    while i <= n do
        local b1 = string.byte(data, i)
        local b2 = string.byte(data, i + 1)
        local b3 = string.byte(data, i + 2)
        local x = lshift(b1, 16) + lshift(b2 or 0, 8) + (b3 or 0)
        out[#out+1] = ch(band(rshift(x, 18), 0x3f))
        out[#out+1] = ch(band(rshift(x, 12), 0x3f))
        if b2 then out[#out+1] = ch(band(rshift(x, 6), 0x3f)) end
        if b3 then out[#out+1] = ch(band(x, 0x3f)) end
        i = i + 3
    end
    return table.concat(out)
end

local PKCE_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
local function random_verifier(length)
    length = length or 64
    local t = {}
    for i = 1, length do
        local idx = math.random(1, #PKCE_CHARS)
        t[i] = PKCE_CHARS:sub(idx, idx)
    end
    return table.concat(t)
end

-- POST to a GoTrue endpoint; returns (decoded_table, nil) on 2xx or (nil, message).
function DictSync:authPost(path, body_table, with_token)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local json = require("json")
    local body = json.encode(body_table or {})
    local response_body = {}
    local headers = {
        ["apikey"] = self:getSupabaseKey(),
        ["Content-Type"] = "application/json",
        ["Content-Length"] = tostring(#body),
    }
    if with_token then
        local tok = self.settings and self.settings:readSetting("auth_access_token")
        if tok and tok ~= "" then headers["Authorization"] = "Bearer " .. tok end
    end
    local success, code = pcall(function()
        local _, c = http.request({
            url = self:getSupabaseUrl() .. path,
            method = "POST",
            headers = headers,
            source = ltn12.source.string(body),
            sink = ltn12.sink.table(response_body),
            timeout = 15,
        })
        return c
    end)
    if not success then
        return nil, "Network error: " .. tostring(code)
    end
    local text = table.concat(response_body)
    local decoded
    pcall(function() decoded = json.decode(text) end)
    if type(code) == "number" and code >= 200 and code < 300 then
        return decoded or {}, nil
    end
    local msg = decoded and (decoded.error_description or decoded.msg
        or decoded.error or decoded.message) or text
    return nil, (msg and msg ~= "") and msg or ("HTTP " .. tostring(code))
end

-- Persist a GoTrue token response into the settings store.
function DictSync:storeSession(data)
    if not data or not data.access_token or not self.settings then return false end
    self.settings:saveSetting("auth_access_token", data.access_token)
    if data.refresh_token then
        self.settings:saveSetting("auth_refresh_token", data.refresh_token)
    end
    local expires_at = tonumber(data.expires_at)
    if not expires_at then
        expires_at = os.time() + (tonumber(data.expires_in) or 3600)
    end
    self.settings:saveSetting("auth_expires_at", expires_at)
    local user = data.user or {}
    if user.id then self.settings:saveSetting("auth_user_id", user.id) end
    if user.email then self.settings:saveSetting("auth_user_email", user.email) end
    self.settings:flush()
    return true
end

-- Email/password sign-in. Returns (true) or (false, message).
function DictSync:signInWithPassword(email, password)
    if not email or email == "" or not password or password == "" then
        return false, "Email and password are required"
    end
    local data, err = self:authPost("/auth/v1/token?grant_type=password",
        { email = email, password = password })
    if not data or not data.access_token then
        return false, err or "Sign-in failed"
    end
    self:storeSession(data)
    return true, nil
end

-- Refresh the access token using the stored refresh token. Clears the session
-- (forcing re-login) if the refresh token is no longer valid.
function DictSync:refreshSession()
    local rtoken = self.settings and self.settings:readSetting("auth_refresh_token")
    if not rtoken or rtoken == "" then return false end
    local data = self:authPost("/auth/v1/token?grant_type=refresh_token",
        { refresh_token = rtoken })
    if not data or not data.access_token then
        self:clearSession()
        return false
    end
    self:storeSession(data)
    return true
end

-- Sign out: best-effort server-side revoke, then clear local session.
function DictSync:signOut()
    pcall(function() self:authPost("/auth/v1/logout", {}, true) end)
    self:clearSession()
    return true
end

-- Redirect target for the Google OAuth flow. Must be whitelisted in the Supabase
-- project's auth settings (Authentication -> URL Configuration -> Redirect URLs).
-- Defaults to the loopback the desktop app uses: nothing runs there from a phone/
-- e-reader browser, so the single-use ?code=... is left untouched and stays visible
-- in the address bar for the user to copy and paste back into the plugin.
function DictSync:getOAuthRedirectUrl()
    local r = self.settings and self.settings:readSetting("oauth_redirect_url")
    if r and r ~= "" then return r end
    return "http://127.0.0.1:53682"
end

-- Build the Google authorize URL (PKCE s256) and stash the code verifier.
-- redirect_override lets the QR flow point at the phone relay page; otherwise the
-- manual-paste flow uses the loopback default.
function DictSync:buildGoogleAuthUrl(redirect_override)
    math.randomseed(os.time() + math.floor(os.clock() * 1000))
    local verifier = random_verifier(64)
    self.settings:saveSetting("auth_pkce_verifier", verifier)
    self.settings:flush()
    local challenge = base64url(sha256_bytes(verifier))
    return string.format(
        "%s/auth/v1/authorize?provider=google&code_challenge=%s&code_challenge_method=s256&redirect_to=%s",
        self:getSupabaseUrl(),
        self:urlEncode(challenge),
        self:urlEncode(redirect_override or self:getOAuthRedirectUrl()))
end

-- Static relay page (GitHub Pages) where the phone drops the OAuth code into the
-- device_auth rendezvous table for the reader to poll. Must be whitelisted in the
-- Supabase project's redirect URLs.
function DictSync:getOAuthRelayUrl()
    local r = self.settings and self.settings:readSetting("oauth_relay_url")
    if r and r ~= "" then return r end
    return "https://lingueez.app/koreader-link.html"
end

-- One poll of the rendezvous table; returns the auth code string or nil. Uses the
-- anon key directly (the user isn't signed in yet).
function DictSync:pollDeviceLink(device_id)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local json = require("json")
    local key = self:getSupabaseKey()
    local url = string.format("%s/rest/v1/device_auth?device_id=eq.%s&select=code",
        self:getSupabaseUrl(), self:urlEncode(device_id))
    local response_body = {}
    local ok, status = pcall(function()
        local _, c = http.request({
            url = url,
            method = "GET",
            headers = {
                ["apikey"] = key,
                ["Authorization"] = "Bearer " .. key,
                ["Content-Type"] = "application/json",
            },
            sink = ltn12.sink.table(response_body),
            timeout = 10,
        })
        return c
    end)
    if not ok or status ~= 200 then return nil end
    local data
    pcall(function() data = json.decode(table.concat(response_body)) end)
    if type(data) == "table" and data[1] and data[1].code and data[1].code ~= "" then
        return data[1].code
    end
    return nil
end

-- Best-effort delete of the rendezvous row after a successful exchange.
function DictSync:deleteDeviceLink(device_id)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local key = self:getSupabaseKey()
    local url = string.format("%s/rest/v1/device_auth?device_id=eq.%s",
        self:getSupabaseUrl(), self:urlEncode(device_id))
    pcall(function()
        http.request({
            url = url,
            method = "DELETE",
            headers = {
                ["apikey"] = key,
                ["Authorization"] = "Bearer " .. key,
            },
            sink = ltn12.sink.table({}),
            timeout = 10,
        })
    end)
end

-- Exchange the pasted authorization code (or full redirect URL) for a session.
function DictSync:exchangeCodeForSession(code)
    local verifier = self.settings and self.settings:readSetting("auth_pkce_verifier")
    if not verifier or verifier == "" then
        return false, "No pending Google sign-in. Please start again."
    end
    if not code or code == "" then return false, "Authorization code is required" end
    code = code:match("^%s*(.-)%s*$")
    local extracted = code:match("[?&]code=([^&#]+)")
    if extracted then code = extracted end
    local data, err = self:authPost("/auth/v1/token?grant_type=pkce",
        { auth_code = code, code_verifier = verifier })
    if not data or not data.access_token then
        return false, err or "Code exchange failed"
    end
    self.settings:delSetting("auth_pkce_verifier")
    self:storeSession(data)
    return true, nil
end

-- Modal showing a QR of the Google authorize URL plus Cancel / manual-entry
-- buttons, modeled on this plugin's WordDetailViewer pattern.
local GoogleQRViewer = InputContainer:extend{
    width = nil,
    qr_text = nil,
    title_text = "Scan to sign in with Google",
    hint_text = nil,
    buttons = nil,
    on_close_callback = nil,
}

function GoogleQRViewer:init()
    local QRWidget = require("ui/widget/qrwidget")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local screen_min = math.min(Screen:getWidth(), Screen:getHeight())
    local qr_size = math.floor(screen_min * 0.66)
    self.width = self.width or math.floor(screen_min * 0.86)

    local titlebar = TitleBar:new{
        width = self.width,
        title = self.title_text,
        with_bottom_line = true,
        close_callback = self.close_callback,
    }

    local qr = QRWidget:new{
        text = self.qr_text,
        width = qr_size,
        height = qr_size,
    }

    local hint = FrameContainer:new{
        padding = Size.padding.large,
        bordersize = 0,
        TextBoxWidget:new{
            text = self.hint_text or "",
            face = Font:getFace("cfont", 16),
            width = self.width - 2 * Size.padding.large,
            alignment = "center",
        },
    }

    local button_table = ButtonTable:new{
        width = self.width,
        buttons = self.buttons,
        show_parent = self,
        zero_sep = true,
    }

    local frame = FrameContainer:new{
        radius = Size.radius.window,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        VerticalGroup:new{
            align = "center",
            titlebar,
            CenterContainer:new{
                dimen = Geom:new{ w = self.width, h = qr:getSize().h },
                qr,
            },
            CenterContainer:new{
                dimen = Geom:new{ w = self.width, h = hint:getSize().h },
                hint,
            },
            CenterContainer:new{
                dimen = Geom:new{ w = self.width, h = button_table:getSize().h },
                button_table,
            },
        },
    }

    local movable = MovableContainer:new{ frame }
    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() },
        movable,
    }
end

function GoogleQRViewer:onShow()
    UIManager:setDirty(self, function()
        return "ui", self[1][1].dimen
    end)
    return true
end

function GoogleQRViewer:paintTo(...)
    InputContainer.paintTo(self, ...)
    self.dimen = self[1][1].dimen
end

function GoogleQRViewer:onCloseWidget()
    if self.on_close_callback then self.on_close_callback() end
    UIManager:setDirty(nil, function()
        return "ui", self[1][1].dimen
    end)
end

function GoogleQRViewer:onClose()
    UIManager:close(self)
    return true
end

-- Friendly phone-assisted Google sign-in: show a QR, poll the rendezvous table
-- until the phone delivers the auth code, then finish the PKCE exchange.
function DictSync:showGoogleQRSignIn()
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            math.randomseed(os.time() + math.floor(os.clock() * 1000000))
            local device_id = random_verifier(32)
            local relay = self:getOAuthRelayUrl() .. "?device=" .. self:urlEncode(device_id)
            local auth_url = self:buildGoogleAuthUrl(relay)

            local viewer
            local stopped = false
            local poll
            local deadline = os.time() + 300

            local function haltPoll()
                stopped = true
                UIManager:unschedule(poll)
            end
            local function closeViewer()
                if viewer then
                    local v = viewer
                    viewer = nil
                    UIManager:close(v)
                end
            end

            poll = function()
                if stopped then return end
                local code = self:pollDeviceLink(device_id)
                if code then
                    closeViewer()  -- triggers onCloseWidget -> haltPoll
                    local ok, err = self:exchangeCodeForSession(code)
                    self:deleteDeviceLink(device_id)
                    UIManager:show(InfoMessage:new{
                        text = ok
                            and ("Signed in as " .. (self.settings:readSetting("auth_user_email") or "your account"))
                            or ("Google sign-in failed: " .. tostring(err)),
                    })
                    if ok then self:refreshConfigDialog() end
                    return
                end
                if os.time() >= deadline then
                    closeViewer()
                    UIManager:show(InfoMessage:new{ text = "Sign-in timed out. Please try again." })
                    return
                end
                UIManager:scheduleIn(2, poll)
            end

            viewer = GoogleQRViewer:new{
                qr_text = auth_url,
                hint_text = "Scan with your phone and sign in with Google.\n"
                    .. "Your reader will sign in automatically — just wait.",
                on_close_callback = haltPoll,
                close_callback = function() closeViewer() end,
                buttons = {
                    {
                        { text = "Cancel", callback = function() closeViewer() end },
                        { text = "Enter code manually", callback = function()
                            closeViewer()
                            self:doGoogleManualEntry()
                        end },
                    },
                },
            }
            UIManager:show(viewer)
            UIManager:scheduleIn(2, poll)
        end)
    end)
end

-- Fallback manual-paste Google sign-in (also covers devices without a camera or a
-- KOReader build lacking QRWidget). Reachable from the QR dialog.
function DictSync:doGoogleManualEntry()
    local url = self:buildGoogleAuthUrl()
    local code_dialog
    code_dialog = InputDialog:new{
        title = "Sign in with Google",
        input = "",
        input_type = "text",
        description = "1. Open this URL in a browser and sign in:\n\n" .. url
            .. "\n\n2. After approving you'll land on a blank/\"can't connect\""
            .. " page — that's expected. Copy the FULL address-bar URL"
            .. "\n(it contains code=...) and paste it below.",
        buttons = {
            {
                {
                    text = "Cancel",
                    callback = function() UIManager:close(code_dialog) end,
                },
                {
                    text = "Submit code",
                    callback = function()
                        local code = code_dialog:getInputText()
                        UIManager:close(code_dialog)
                        NetworkMgr:runWhenOnline(function()
                            Trapper:wrap(function()
                                local ok, err = self:exchangeCodeForSession(code)
                                UIManager:show(InfoMessage:new{
                                    text = ok and "Signed in with Google"
                                        or ("Google sign-in failed: " .. tostring(err)),
                                })
                                if ok then self:refreshConfigDialog() end
                            end)
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(code_dialog)
    code_dialog:onShowKeyboard()
end

-- Close and reopen the config dialog (if any) so it reflects new auth state.
function DictSync:refreshConfigDialog()
    if self.config_dialog then
        UIManager:close(self.config_dialog)
        self.config_dialog = nil
    end
    UIManager:nextTick(function() self:showConfigDialog() end)
end

-- Load .env file if it exists
function DictSync:loadEnvFile()
    local DataStorage = require("datastorage")
    local T = require("ffi/util").template
    local PLUGIN_DIR = T("%1/plugins/lingueez.koplugin/", DataStorage:getDataDir())
    local ENV_FILE_PATH = PLUGIN_DIR .. ".env"
    
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(ENV_FILE_PATH, "mode") == "file" then
        logger.info("Lingueez: Found .env file, loading...")
        local file = io.open(ENV_FILE_PATH, "r")
        if file then
            for line in file:lines() do
                -- Skip comments and empty lines
                line = line:match("^%s*(.-)%s*$") -- trim
                if line ~= "" and not line:match("^#") then
                    local key, value = line:match("^([^=]+)=(.+)$")
                    if key and value then
                        key = key:match("^%s*(.-)%s*$") -- trim key
                        value = value:match("^%s*(.-)%s*$") -- trim value
                        -- Remove quotes if present
                        value = value:match("^['\"](.-)['\"]$") or value
                        
                        if key == "SUPABASE_URL" then
                            if not self.settings:has("supabase_url") or self.settings:readSetting("supabase_url") == "" then
                                self.settings:saveSetting("supabase_url", value)
                                logger.info("Lingueez: Loaded SUPABASE_URL from .env")
                            end
                        elseif key == "SUPABASE_KEY" then
                            if not self.settings:has("supabase_key") or self.settings:readSetting("supabase_key") == "" then
                                self.settings:saveSetting("supabase_key", value)
                                logger.info("Lingueez: Loaded SUPABASE_KEY from .env")
                            end
                        elseif key == "DEEPL_API_KEY" then
                            if not self.settings:has("deepl_api_key") or self.settings:readSetting("deepl_api_key") == "" then
                                self.settings:saveSetting("deepl_api_key", value)
                                logger.info("Lingueez: Loaded DEEPL_API_KEY from .env")
                            end
                        elseif key == "DEEPL_USE_PAID_API" then
                            local use_paid = (value:lower() == "true" or value:lower() == "1" or value:lower() == "yes")
                            self.settings:saveSetting("deepl_use_paid_api", use_paid)
                            logger.info("Lingueez: Loaded DEEPL_USE_PAID_API from .env: " .. tostring(use_paid))
                        elseif key == "SHOW_ADVANCED" then
                            local show_advanced = (value:lower() == "true" or value:lower() == "1" or value:lower() == "yes")
                            self.settings:saveSetting("show_advanced", show_advanced)
                            logger.info("Lingueez: Loaded SHOW_ADVANCED from .env: " .. tostring(show_advanced))
                        end
                    end
                end
            end
            file:close()
            self.settings:flush()
            logger.info("Lingueez: .env file loaded successfully")
        end
    else
        logger.info("Lingueez: No .env file found at " .. ENV_FILE_PATH)
    end
end

-- Configuration UI
function DictSync:showConfigDialog()
    -- Close any existing config dialog to prevent stacking
    if self.config_dialog then
        UIManager:close(self.config_dialog)
        self.config_dialog = nil
    end
    
    -- Load .env file first
    self:loadEnvFile()
    
    local function showUrlDialog()
        local url_dialog
        url_dialog = InputDialog:new{
            title = "Supabase URL",
            input = self.settings:readSetting("supabase_url") or "",
            input_type = "text",
            description = "Enter your Supabase project URL\n(e.g., https://xxxxx.supabase.co)\n\nOr create .env file in plugin folder with:\nSUPABASE_URL=your_url",
            buttons = {
                {
                    {
                        text = "Cancel",
                        callback = function()
                            UIManager:close(url_dialog)
                        end,
                    },
                    {
                        text = "Save",
                        callback = function()
                            local success, result = pcall(function()
                                local url = url_dialog:getInputText()
                                if url then
                                    self.settings:saveSetting("supabase_url", url)
                                    self.settings:flush()
                                    UIManager:close(url_dialog)
                                    UIManager:show(InfoMessage:new{
                                        text = "Supabase URL saved",
                                    })
                                else
                                    UIManager:show(InfoMessage:new{
                                        text = "Error: Could not read input",
                                    })
                                end
                            end)
                            if not success then
                                logger.err("Lingueez: Error saving Supabase URL: " .. tostring(result))
                                UIManager:show(InfoMessage:new{
                                    text = "Error saving URL: " .. tostring(result),
                                })
                            end
                        end,
                    },
                },
            },
        }
        UIManager:show(url_dialog)
        url_dialog:onShowKeyboard()
    end
    
    local function showKeyDialog()
        local key_dialog
        key_dialog = InputDialog:new{
            title = "Supabase API Key",
            input = self.settings:readSetting("supabase_key") or "",
            input_type = "text",
            description = "Enter your Supabase anon/public key\n\nOr create .env file in plugin folder with:\nSUPABASE_KEY=your_key",
            buttons = {
                {
                    {
                        text = "Cancel",
                        callback = function()
                            UIManager:close(key_dialog)
                        end,
                    },
                    {
                        text = "Save",
                        callback = function()
                            local success, result = pcall(function()
                                local key = key_dialog:getInputText()
                                if key then
                                    self.settings:saveSetting("supabase_key", key)
                                    self.settings:flush()
                                    UIManager:close(key_dialog)
                                    UIManager:show(InfoMessage:new{
                                        text = "Supabase API key saved",
                                    })
                                else
                                    UIManager:show(InfoMessage:new{
                                        text = "Error: Could not read input",
                                    })
                                end
                            end)
                            if not success then
                                logger.err("Lingueez: Error saving Supabase API key: " .. tostring(result))
                                UIManager:show(InfoMessage:new{
                                    text = "Error saving API key: " .. tostring(result),
                                })
                            end
                        end,
                    },
                },
            },
        }
        UIManager:show(key_dialog)
        key_dialog:onShowKeyboard()
    end
    
    local function testConnection()
        local supabase_url = self:getSupabaseUrl()
        local supabase_key = self:getSupabaseKey()
        local supabase_bearer = self:getBearerToken()
        
        -- Show loading message
        UIManager:show(InfoMessage:new{
            text = "Testing connection...",
            timeout = 1,
        })
        
        -- Test connection asynchronously to avoid blocking
        NetworkMgr:runWhenOnline(function()
            Trapper:wrap(function()
                -- Test connection by checking if we can query the words table
                local http = require("socket.http")
                local ltn12 = require("ltn12")
                local response_body = {}
                
                local url = string.format("%s/rest/v1/words?limit=1",
                    supabase_url
                )
                
                local success, result, status_code, headers = pcall(function()
                    return http.request({
                        url = url,
                        method = "GET",
                        headers = {
                            ["apikey"] = supabase_key,
                            ["Authorization"] = supabase_bearer,
                            ["Content-Type"] = "application/json",
                        },
                        sink = ltn12.sink.table(response_body),
                        timeout = 10,
                    })
                end)
                
                UIManager:nextTick(function()
                    if not success then
                        UIManager:show(InfoMessage:new{
                            text = "Connection failed: " .. tostring(result) .. "\n\nPlease check your internet connection and Supabase URL.",
                        })
                    elseif status_code == 200 then
                        UIManager:show(InfoMessage:new{
                            text = "Connection successful!",
                        })
                    elseif status_code == 401 or status_code == 403 then
                        UIManager:show(InfoMessage:new{
                            text = "Authentication failed: HTTP " .. tostring(status_code) .. "\n\nPlease check your Supabase API key.",
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = string.format("Connection failed: HTTP %d\n%s", status_code, table.concat(response_body)),
                        })
                    end
                end)
            end)
        end)
    end
    
    local function testDeepLConnection()
        local deepl_key = self.settings:readSetting("deepl_api_key")
        
        if not deepl_key or deepl_key == "" then
            UIManager:show(InfoMessage:new{
                text = "Please configure DeepL API key first",
            })
            return
        end
        
        -- Show loading message
        UIManager:show(InfoMessage:new{
            text = "Testing DeepL API...",
            timeout = 1,
        })
        
        -- Test DeepL API by translating a test word
        NetworkMgr:runWhenOnline(function()
            Trapper:wrap(function()
                -- Use proper language codes for DeepL
                local translation, error_msg = self:translateWithDeepL("test", "EN", "DE", deepl_key)
                
                UIManager:nextTick(function()
                    if translation then
                        UIManager:show(InfoMessage:new{
                            text = "DeepL API connection successful!\n\nTest translation: 'test' → '" .. translation .. "'",
                        })
                    else
                        -- Show more detailed error message
                        local error_details = error_msg or "Unknown error"
                        local api_type = self.settings:readSetting("deepl_use_paid_api") and "Paid" or "Free"
                        local endpoint = self.settings:readSetting("deepl_use_paid_api") and "api.deepl.com" or "api-free.deepl.com"
                        UIManager:show(InfoMessage:new{
                            text = "DeepL API test failed: " .. error_details .. "\n\nCurrent API type: " .. api_type .. " (" .. endpoint .. ")\n\nPlease check:\n- API key is correct\n- API type matches your account\n- Internet connection is working",
                        })
                    end
                end)
            end)
        end)
    end
    
    local function showDeepLKeyDialog()
        local deepl_dialog
        deepl_dialog = InputDialog:new{
            title = "DeepL API Key (Optional)",
            input = self.settings:readSetting("deepl_api_key") or "",
            input_type = "text",
            description = "Enter your DeepL API key (optional)\n\nIf set, DeepL will be used for translation.\nOtherwise, Google Translate (free) will be used.\n\nOr create .env file with:\nDEEPL_API_KEY=your_key",
            buttons = {
                {
                    {
                        text = "Cancel",
                        callback = function()
                            UIManager:close(deepl_dialog)
                        end,
                    },
                    {
                        text = "Save",
                        callback = function()
                            local key = deepl_dialog:getInputText()
                            self.settings:saveSetting("deepl_api_key", key)
                            self.settings:flush()
                            UIManager:close(deepl_dialog)
                            UIManager:show(InfoMessage:new{
                                text = "DeepL API key saved",
                            })
                        end,
                    },
                },
            },
        }
        UIManager:show(deepl_dialog)
        deepl_dialog:onShowKeyboard()
    end
    
    local function showDeepLTypeDialog()
        local current_type = self.settings:readSetting("deepl_use_paid_api") or false
        local type_dialog
        type_dialog = ButtonDialog:new{
            title = "DeepL API Type",
            text = "Select your DeepL API type:\n\nCurrent: " .. (current_type and "Paid API" or "Free API"),
            buttons = {
                {
                    {
                        text = "Free API",
                        callback = function()
                            self.settings:saveSetting("deepl_use_paid_api", false)
                            self.settings:flush()
                            UIManager:close(type_dialog)
                            UIManager:show(InfoMessage:new{
                                text = "DeepL API type set to Free",
                            })
                        end,
                    },
                    {
                        text = "Paid API",
                        callback = function()
                            self.settings:saveSetting("deepl_use_paid_api", true)
                            self.settings:flush()
                            UIManager:close(type_dialog)
                            UIManager:show(InfoMessage:new{
                                text = "DeepL API type set to Paid",
                            })
                        end,
                    },
                },
                {
                    {
                        text = "Cancel",
                        callback = function()
                            UIManager:close(type_dialog)
                        end,
                    },
                },
            },
        }
        UIManager:show(type_dialog)
    end
    
    local function showSourceLanguageDialog()
        -- Build language list from LANGUAGE_MAP
        local language_names = {}
        for code, name in pairs(LANGUAGE_MAP) do
            table.insert(language_names, name)
        end
        table.sort(language_names)
        
        local current_lang = self.settings:readSetting("source_language") or ""
        
        -- Declare dialog variable first to avoid closure issues
        local lang_dialog
        
        -- Build language buttons first
        local lang_buttons = {}
        table.insert(lang_buttons, {
            text = "Auto-detect",
            callback = function()
                self.settings:saveSetting("source_language", "")
                self.settings:flush()
                UIManager:close(lang_dialog)
                UIManager:show(InfoMessage:new{
                    text = "Source language set to Auto-detect",
                })
            end,
        })
        
        for _, name in ipairs(language_names) do
            table.insert(lang_buttons, {
                text = name,
                callback = function()
                    self.settings:saveSetting("source_language", name)
                    self.settings:flush()
                    UIManager:close(lang_dialog)
                    UIManager:show(InfoMessage:new{
                        text = "Source language set to " .. name,
                    })
                end,
            })
        end
        
        table.insert(lang_buttons, {
            text = "Cancel",
            callback = function()
                UIManager:close(lang_dialog)
            end,
        })
        
        -- Split into rows of 2
        local button_rows = {}
        for i = 1, #lang_buttons, 2 do
            local row = {lang_buttons[i]}
            if lang_buttons[i + 1] then
                table.insert(row, lang_buttons[i + 1])
            end
            table.insert(button_rows, row)
        end
        
        -- Create dialog with complete buttons array
        lang_dialog = ButtonDialog:new{
            title = "Source Language",
            text = "Select source language (language of the book):\n\nCurrent: " .. (current_lang ~= "" and current_lang or "Auto-detect"),
            buttons = button_rows,
        }
        
        UIManager:show(lang_dialog)
    end
    
    local function showTargetLanguageDialog()
        -- Build language list from LANGUAGE_MAP
        local language_names = {}
        for code, name in pairs(LANGUAGE_MAP) do
            table.insert(language_names, name)
        end
        table.sort(language_names)
        
        local current_lang = self.settings:readSetting("target_language") or "English"
        
        -- Declare dialog variable first to avoid closure issues
        local lang_dialog
        
        -- Build language buttons first
        local lang_buttons = {}
        for _, name in ipairs(language_names) do
            table.insert(lang_buttons, {
                text = name,
                callback = function()
                    self.settings:saveSetting("target_language", name)
                    self.settings:flush()
                    UIManager:close(lang_dialog)
                    UIManager:show(InfoMessage:new{
                        text = "Target language set to " .. name,
                    })
                end,
            })
        end
        
        table.insert(lang_buttons, {
            text = "Cancel",
            callback = function()
                UIManager:close(lang_dialog)
            end,
        })
        
        -- Split into rows of 2
        local button_rows = {}
        for i = 1, #lang_buttons, 2 do
            local row = {lang_buttons[i]}
            if lang_buttons[i + 1] then
                table.insert(row, lang_buttons[i + 1])
            end
            table.insert(button_rows, row)
        end
        
        -- Create dialog with complete buttons array
        lang_dialog = ButtonDialog:new{
            title = "Target Language",
            text = "Select target language (translation language):\n\nCurrent: " .. current_lang,
            buttons = button_rows,
        }
        
        UIManager:show(lang_dialog)
    end
    
    -- Get current force_google setting for button text
    local force_google = self.settings:readSetting("force_google_translate") or false
    local toggle_button_text = force_google and "Use DeepL (if configured)" or "Use Google Translate"
    
    local function toggleGoogleForce()
        -- Prevent multiple rapid clicks
        if self.toggling then
            return
        end
        self.toggling = true
        
        local current = self.settings:readSetting("force_google_translate") or false
        self.settings:saveSetting("force_google_translate", not current)
        self.settings:flush()
        
        -- Close the current dialog
        if self.config_dialog then
            UIManager:close(self.config_dialog)
            self.config_dialog = nil
        end
        
        UIManager:show(InfoMessage:new{
            text = not current and "Now using Google Translate (even if DeepL is configured)" or "Now using DeepL (if configured), Google as fallback",
        })
        
        -- Reopen config dialog to show updated button text
        UIManager:nextTick(function()
            self.toggling = false
            self:showConfigDialog()
        end)
    end
    
    local config_dialog

    -- Close and reopen the config dialog so its buttons reflect new auth/mode state.
    local function refreshConfig()
        if self.config_dialog then
            UIManager:close(self.config_dialog)
            self.config_dialog = nil
        end
        UIManager:nextTick(function() self:showConfigDialog() end)
    end

    local function showLoginDialog()
        local MultiInputDialog = require("ui/widget/multiinputdialog")
        local login_dialog
        login_dialog = MultiInputDialog:new{
            title = "Sign in",
            description = "New to Lingueez? Create your account at lingueez.app, then sign in here.",
            fields = {
                { description = "Email", input_type = "text", hint = "you@example.com" },
                { description = "Password", input_type = "text", text_type = "password" },
            },
            buttons = {
                {
                    {
                        text = "Cancel",
                        callback = function() UIManager:close(login_dialog) end,
                    },
                    {
                        text = "Sign in",
                        callback = function()
                            local fields = login_dialog:getFields()
                            local email, password = fields[1], fields[2]
                            UIManager:close(login_dialog)
                            NetworkMgr:runWhenOnline(function()
                                Trapper:wrap(function()
                                    local ok, err = self:signInWithPassword(email, password)
                                    UIManager:show(InfoMessage:new{
                                        text = ok
                                            and ("Signed in as " .. (self.settings:readSetting("auth_user_email") or email))
                                            or ("Sign-in failed: " .. tostring(err)),
                                    })
                                    if ok then refreshConfig() end
                                end)
                            end)
                        end,
                    },
                },
            },
        }
        UIManager:show(login_dialog)
        login_dialog:onShowKeyboard()
    end

    local function doSignOut()
        Trapper:wrap(function()
            self:signOut()
            UIManager:show(InfoMessage:new{ text = "Signed out" })
            refreshConfig()
        end)
    end

    local function disconnectCustomServer()
        self.settings:delSetting("supabase_url")
        self.settings:delSetting("supabase_key")
        self.settings:flush()
        UIManager:show(InfoMessage:new{ text = "Reconnected to the built-in server" })
        refreshConfig()
    end

    -- Build the button rows dynamically. The Account section shows on the built-in
    -- server; the extra server fields stay hidden unless show_advanced is set.
    local is_custom = self:isCustomServer()
    local show_advanced = self.settings:readSetting("show_advanced") or is_custom
    local logged_in = (self.settings:readSetting("auth_access_token") or "") ~= ""

    local buttons = {}

    if not is_custom then
        if logged_in then
            local email = self.settings:readSetting("auth_user_email") or "(account)"
            table.insert(buttons, {
                { text = "Signed in: " .. email, callback = function()
                    UIManager:show(InfoMessage:new{ text = "Signed in as " .. email })
                end },
            })
            table.insert(buttons, {{ text = "Sign out", callback = doSignOut }})
        else
            table.insert(buttons, {
                { text = "Sign in (email)", callback = showLoginDialog },
                { text = "Sign in with Google", callback = function() self:showGoogleQRSignIn() end },
            })
        end
        table.insert(buttons, {})  -- separator
    end

    if show_advanced then
        table.insert(buttons, {
            { text = "Set Supabase URL", callback = showUrlDialog },
            { text = "Set API Key", callback = showKeyDialog },
        })
        table.insert(buttons, {{ text = "Test Supabase Connection", callback = testConnection }})
        if is_custom then
            table.insert(buttons, {
                { text = "Disconnect — use built-in server", callback = disconnectCustomServer },
            })
        end
    else
        table.insert(buttons, {{ text = "Test Supabase Connection", callback = testConnection }})
    end
    table.insert(buttons, {})  -- separator

    -- DeepL section
    table.insert(buttons, {
        { text = "Set DeepL API Key", callback = showDeepLKeyDialog },
        { text = "Set DeepL API Type", callback = showDeepLTypeDialog },
    })
    table.insert(buttons, {{ text = "Test DeepL API", callback = testDeepLConnection }})
    -- Language section
    table.insert(buttons, {
        { text = "Set Source Language", callback = showSourceLanguageDialog },
        { text = "Set Target Language", callback = showTargetLanguageDialog },
    })
    -- Options
    table.insert(buttons, {{ text = toggle_button_text, callback = toggleGoogleForce }})
    table.insert(buttons, {})  -- separator
    -- Close
    table.insert(buttons, {
        { text = "Close", callback = function()
            UIManager:close(config_dialog)
            self.config_dialog = nil
        end },
    })

    config_dialog = ButtonDialog:new{
        title = "Lingueez Configuration",
        buttons = buttons,
    }
    -- Store reference to prevent multiple dialogs
    self.config_dialog = config_dialog
    UIManager:show(config_dialog)
end

-- Quick save dialog
function DictSync:showQuickSaveDialog(word1, language1, word2, language2, actual_lang_to_save)
    -- Add parameter validation with fallback values
    word1 = word1 or "[Not set]"
    -- language1 is the display language (may include "(Auto-detect)")
    language1 = language1 or "Auto-detect"
    word2 = word2 or ""
    language2 = language2 or "[Not set]"
    -- actual_lang_to_save is the language to actually save (nil if we couldn't detect)
    -- Log what we received
    logger.dbg("Lingueez: showQuickSaveDialog - actual_lang_to_save param: " .. (actual_lang_to_save or "nil"))
    logger.dbg("Lingueez: showQuickSaveDialog - language1 (display): " .. (language1 or "nil"))
    
    -- If nil, try to extract from display language or use a fallback
    if not actual_lang_to_save or actual_lang_to_save == "" then
        -- Try to extract language name from display string (e.g., "Greek (Auto-detect)" -> "Greek")
        if language1 and language1 ~= "Auto-detect" then
            local extracted = language1:match("^([^(]+)")
            if extracted then
                actual_lang_to_save = extracted:match("^%s*(.-)%s*$")  -- trim
                logger.dbg("Lingueez: Extracted language from display: " .. actual_lang_to_save)
            end
        end
        -- If still nil, log warning but don't default to English yet - let the save callback handle it
        if not actual_lang_to_save or actual_lang_to_save == "" then
            logger.warn("Lingueez: actual_lang_to_save is still nil after extraction attempt")
        end
    end
    
    -- Log for debugging (can be removed later if not needed)
    logger.dbg("Lingueez: Quick save dialog - word: " .. word1 .. ", display lang: " .. language1 .. ", save lang: " .. (actual_lang_to_save or "nil") .. ", translation: " .. (word2 or ""))
    
    -- Build description text: languages on first line (subtle), word on second line (prominent with diamond style)
    local languages_text = string.format("%s to %s", language1, language2)
    local description = string.format("  %s\n\n\n ◄ %s ►", languages_text, word1)
    
    -- Use InputDialog with formatted description
    local quick_dialog
    quick_dialog = InputDialog:new{
        title = "Save to Lingueez",
        description = description,
        input = word2 or "",  -- Translation in input field for editing
        input_type = "text",
        buttons = {
            {
                {
                    text = "Quick Save",
                    callback = function()
                        -- Get translation from input field
                        local translation = quick_dialog:getInputText() or ""
                        UIManager:close(quick_dialog)
                        
                        if translation and translation ~= "" then
                            -- Has translation, save directly
                            -- Use actual_lang_to_save instead of display language1
                            -- Ensure we have a valid language (not nil or "Auto-detect")
                            local lang_to_save = actual_lang_to_save
                            if not lang_to_save or lang_to_save == "" or lang_to_save == "Auto-detect" then
                                -- Try to extract from display language
                                if language1 and language1 ~= "Auto-detect" then
                                    local extracted = language1:match("^([^(]+)")
                                    if extracted then
                                        lang_to_save = extracted:match("^%s*(.-)%s*$")  -- trim
                                    end
                                end
                                -- If still not found, log error but use English as last resort
                                if not lang_to_save or lang_to_save == "" then
                                    logger.warn("Lingueez: Could not determine language for saving, using English as fallback")
                                    lang_to_save = "English"
                                end
                            end
                            
                            NetworkMgr:runWhenOnline(function()
                                Trapper:wrap(function()
                                    self:doSaveWord({
                                        word1 = word1,
                                        language1 = lang_to_save,  -- Use actual detected language, not display text
                                        word2 = translation,
                                        language2 = language2,
                                    })
                                end)
                            end)
                        else
                            -- No translation, show error
                            UIManager:show(InfoMessage:new{
                                text = "Please enter a translation",
                            })
                        end
                    end,
                },
                {
                    text = "Edit",
                    callback = function()
                        -- Get current translation from input field
                        local current_translation = quick_dialog:getInputText() or ""
                        UIManager:close(quick_dialog)
                        self:showEditDialog(word1, language1, current_translation, language2)
                    end,
                },
            },
            {
                {
                    text = "Cancel",
                    callback = function()
                        UIManager:close(quick_dialog)
                    end,
                },
            },
        },
    }
    
    UIManager:show(quick_dialog)
end

-- Edit dialog - simplified since languages are configured centrally
function DictSync:showEditDialog(word1, language1, word2, language2, definition, definition2, word_id, on_save_callback, field_map)
    -- Get languages from settings (configured centrally)
    local configured_source_lang = self.settings:readSetting("source_language") or ""
    local configured_target_lang = self.settings:readSetting("target_language") or "English"
    
    -- Use provided languages or fall back to configured ones
    local final_language1 = language1 or (configured_source_lang ~= "" and configured_source_lang or self:detectDocumentLanguage() or "English")
    local final_language2 = language2 or configured_target_lang
    
    local word_data = {
        word1 = word1 or "",
        language1 = final_language1,
        word2 = word2 or "",
        language2 = final_language2,
        definition = definition or "",
        definition2 = definition2 or "",
        id = word_id,
    }
    word_data._field_map = field_map
    
    -- Show word1 input
    local word1_dialog
    word1_dialog = InputDialog:new{
        title = "Edit Word",
        input = word_data.word1,
        input_type = "text",
        description = string.format("Word (%s):", final_language1),
        buttons = {
            {
                {
                    text = "Cancel",
                    callback = function()
                        UIManager:close(word1_dialog)
                    end,
                },
                {
                    text = "Next",
                    callback = function()
                        word_data.word1 = word1_dialog:getInputText() or word_data.word1
                        UIManager:close(word1_dialog)
                        UIManager:nextTick(function()
                            -- Show word2 (translation) input
                            local word2_dialog
                            word2_dialog = InputDialog:new{
                                title = "Edit Translation",
                                input = word_data.word2,
                                input_type = "text",
                                description = string.format("Translation (%s):", final_language2),
                                buttons = {
                                    {
                                        {
                                            text = "Cancel",
                                            callback = function()
                                                UIManager:close(word2_dialog)
                                            end,
                                        },
                                        {
                                            text = "Back",
                                            callback = function()
                                                UIManager:close(word2_dialog)
                                                UIManager:nextTick(function()
                                                    self:showEditDialog(
                                                        word_data.word1,
                                                        final_language1,
                                                        word_data.word2,
                                                        final_language2,
                                                        word_data.definition,
                                                        word_data.definition2,
                                                        word_data.id,
                                                        on_save_callback,
                                                        word_data._field_map
                                                    )
                                                end)
                                            end,
                                        },
                                        {
                                            text = "Save",
                                            callback = function()
                                                word_data.word2 = word2_dialog:getInputText() or word_data.word2
                                                UIManager:close(word2_dialog)
                                                
                                                -- Validate before saving
                                                if not word_data.word1 or word_data.word1 == "" then
                                                    UIManager:show(InfoMessage:new{
                                                        text = "Error: Word is required",
                                                    })
                                                    return
                                                end
                                                
                                                if not word_data.word2 or word_data.word2 == "" then
                                                    UIManager:show(InfoMessage:new{
                                                        text = "Error: Translation is required",
                                                    })
                                                    return
                                                end
                                                
                                                -- Save or update word in Supabase
                                                NetworkMgr:runWhenOnline(function()
                                                    Trapper:wrap(function()
                                                        if word_data.id then
                                                            local success, message = self:updateWordEntry(word_data.id, word_data)
                                                            UIManager:nextTick(function()
                                                                if success then
                                                                    UIManager:show(InfoMessage:new{
                                                                        text = "Word updated",
                                                                    })
                                                                    if on_save_callback then
                                                                        on_save_callback()
                                                                    end
                                                                else
                                                                    UIManager:show(InfoMessage:new{
                                                                        text = "Error updating word: " .. (message or "Unknown error"),
                                                                    })
                                                                end
                                                            end)
                                                        else
                                                            self:doSaveWord(word_data)
                                                        end
                                                    end)
                                                end)
                                            end,
                                        },
                                    },
                                },
                            }
                            UIManager:show(word2_dialog)
                            word2_dialog:onShowKeyboard()
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(word1_dialog)
    word1_dialog:onShowKeyboard()
end

-- Save word and show result
function DictSync:doSaveWord(word_data)
    -- Validate required fields
    if not word_data.word1 or word_data.word1 == "" then
        UIManager:show(InfoMessage:new{
            text = "Error: Word 1 is required",
        })
        return
    end
    
    if not word_data.language1 or word_data.language1 == "" then
        UIManager:show(InfoMessage:new{
            text = "Error: Language 1 is required",
        })
        return
    end
    
    if not word_data.word2 or word_data.word2 == "" then
        UIManager:show(InfoMessage:new{
            text = "Error: Word 2 (translation) is required",
        })
        return
    end
    
    if not word_data.language2 or word_data.language2 == "" then
        UIManager:show(InfoMessage:new{
            text = "Error: Language 2 is required",
        })
        return
    end
    
    -- Show saving message
    UIManager:show(InfoMessage:new{
        text = "Saving word...",
        timeout = 1,
    })
    
    -- Save to Supabase asynchronously to avoid blocking
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            -- Save to Supabase
            local success, message = self:saveWordToSupabase(word_data)
            
            UIManager:nextTick(function()
                if success then
                    UIManager:show(InfoMessage:new{
                        text = message or "Word saved successfully!",
                    })
                else
                    UIManager:show(InfoMessage:new{
                        text = "Error saving word: " .. (message or "Unknown error"),
                    })
                end
            end)
        end)
    end)
end

-- Handle word selection from KOReader
function DictSync:handleWordSelection(selected_text)
    if not selected_text or selected_text == "" then
        return
    end
    if not self:ensureAuthed() then return end
    
    -- Get source language (from settings or auto-detect)
    -- If nil, translateWord will use "auto" for auto-detection
    local source_lang = self:detectDocumentLanguage()
    
    -- Get target language (from settings or default to English)
    local target_lang = self.settings:readSetting("target_language") or "English"
    
    -- Determine actual language to save and display language
    local is_auto_detect = (source_lang == nil)
    local actual_lang_to_save = source_lang  -- Will be nil if auto-detect
    local display_source_lang
    
    if is_auto_detect then
        -- Try to detect from document metadata for display
        local detected_from_doc = nil
        if self.ui and self.ui.document then
            local document = self.ui.document
            local props = document:getProps()
            if props then
                -- Try multiple ways to get language
                if props.language then
                    detected_from_doc = self:mapLanguageCode(props.language)
                    logger.dbg("Lingueez: Found language in props.language: " .. tostring(props.language) .. " -> " .. (detected_from_doc or "nil"))
                end
                -- Also try lang property (some documents use this)
                if not detected_from_doc and props.lang then
                    detected_from_doc = self:mapLanguageCode(props.lang)
                    logger.dbg("Lingueez: Found language in props.lang: " .. tostring(props.lang) .. " -> " .. (detected_from_doc or "nil"))
                end
                -- Try to get from document info
                if not detected_from_doc and document.getDocumentInfo then
                    local success, doc_info = pcall(function() return document:getDocumentInfo() end)
                    if success and doc_info and doc_info.language then
                        detected_from_doc = self:mapLanguageCode(doc_info.language)
                        logger.dbg("Lingueez: Found language in doc_info.language: " .. tostring(doc_info.language) .. " -> " .. (detected_from_doc or "nil"))
                    end
                end
            else
                logger.dbg("Lingueez: document:getProps() returned nil or no props")
            end
        else
            logger.dbg("Lingueez: No UI or document available for language detection")
        end
        
        -- If still not detected, try to detect from word characters
        if not detected_from_doc then
            -- Check if word contains Greek characters by looking for common Greek letters
            -- Greek letters in UTF-8: α (0xCE 0xB1), β (0xCE 0xB2), etc.
            -- Check for UTF-8 sequences that indicate Greek
            local has_greek = false
            for i = 1, #selected_text - 1 do
                local byte1 = string.byte(selected_text, i)
                local byte2 = string.byte(selected_text, i + 1)
                -- Greek lowercase: 0xCE 0xB1-0xCE 0xBF (α-ο) and 0xCF 0x80-0xCF 0x8F (π-ώ)
                -- Greek uppercase: 0xCE 0x91-0xCE 0x9F (Α-Ω)
                if byte1 == 0xCE then
                    if (byte2 >= 0x91 and byte2 <= 0x9F) or  -- Α-Ω
                       (byte2 >= 0xB1 and byte2 <= 0xBF) then  -- α-ο
                        has_greek = true
                        break
                    end
                elseif byte1 == 0xCF then
                    if byte2 >= 0x80 and byte2 <= 0x8F then  -- π-ώ
                        has_greek = true
                        break
                    end
                end
            end
            
            if has_greek then
                detected_from_doc = "Greek"
                logger.dbg("Lingueez: Detected Greek from word characters")
            end
        end
        
        -- Log what we detected for debugging
        logger.dbg("Lingueez: Auto-detect - final detected_from_doc: " .. (detected_from_doc or "nil"))
        logger.dbg("Lingueez: Selected text: " .. selected_text)
        
        if detected_from_doc then
            -- Show detected language with (Auto-detect) indicator
            display_source_lang = string.format("%s (Auto-detect)", detected_from_doc)
            actual_lang_to_save = detected_from_doc  -- Use detected language for saving
            logger.info("Lingueez: Using detected language: " .. detected_from_doc .. " for display and saving")
        else
            -- Can't detect, just show Auto-detect
            display_source_lang = "Auto-detect"
            actual_lang_to_save = nil
            logger.warn("Lingueez: Could not detect language from document or word characters for: " .. selected_text)
        end
    else
        -- Language is explicitly set, use it as-is
        display_source_lang = source_lang
        actual_lang_to_save = source_lang
    end
    
    -- Show loading message
    UIManager:show(InfoMessage:new{
        text = "Translating...",
        timeout = 1,
    })
    
    -- Translate automatically
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            local translation, error_msg = self:translateWord(selected_text, source_lang, target_lang)
            
            UIManager:nextTick(function()
                if translation and translation ~= "" then
                    -- Translation successful - show quick save dialog with translation
                    -- Pass display info and actual language for saving
                    self:showQuickSaveDialog(selected_text, display_source_lang, translation, target_lang, actual_lang_to_save)
                else
                    -- Translation failed - show edit dialog with empty translation
                    UIManager:show(InfoMessage:new{
                        text = "Translation failed: " .. (error_msg or "Unknown error") .. "\n\nYou can enter translation manually.",
                        timeout = 3,
                    })
                    self:showEditDialog(selected_text, source_lang, "", target_lang)
                end
            end)
        end)
    end)
end

-- ============================================
-- UI: FILTER DIALOG
-- ============================================

local function cloneFilters(filters)
    local copy = {}
    if not filters then
        return copy
    end
    for key, value in pairs(filters) do
        if key == "tags" and type(value) == "table" then
            copy.tags = {}
            for i = 1, #value do
                copy.tags[i] = value[i]
            end
        else
            copy[key] = value
        end
    end
    return copy
end

local function summarizeFilters(filters)
    filters = filters or {}
    local summary = {}
    if filters.language1 then
        table.insert(summary, "Lang1: " .. filters.language1)
    end
    if filters.language2 then
        table.insert(summary, "Lang2: " .. filters.language2)
    end
    if filters.search then
        table.insert(summary, "Search: " .. filters.search)
    end
    if filters.favorite ~= nil then
        table.insert(summary, "Favorite: " .. (filters.favorite and "Yes" or "No"))
    end
    if filters.tags and #filters.tags > 0 then
        table.insert(summary, "Tags: " .. table.concat(filters.tags, ", "))
    end
    if #summary == 0 then
        return "No filters applied"
    end
    return table.concat(summary, "\n")
end

function DictSync:dismissWordsFilterDialog()
    local dialog = self.filter_dialog
    self.filter_dialog = nil
    if dialog then
        UIManager:close(dialog)
    end
    self._filter_working_copy = nil
end

function DictSync:showWordsFilterDialog(callback)
    local tags_per_page = 12
    self._tag_filter_page = self._tag_filter_page or 1
    
    if not self._filter_working_copy then
        self._filter_working_copy = cloneFilters(self.words_filters)
    end
    local current_filters = self._filter_working_copy
    
    local function refreshFilterDialog()
        if self.filter_dialog then
            UIManager:close(self.filter_dialog)
            self.filter_dialog = nil
        end
        self:showWordsFilterDialog(callback)
    end
    
    local function getSortedLanguages()
        if not self._sorted_language_names then
            local lang_names = {}
            for _, name in pairs(LANGUAGE_MAP) do
                table.insert(lang_names, name)
            end
            table.sort(lang_names)
            self._sorted_language_names = lang_names
        end
        return self._sorted_language_names
    end
    
    local function showLanguageSelectionDialog(title, current_value, setter, dialog_key)
        local languages = getSortedLanguages()
        local page_size = 20
        local total_pages = math.max(1, math.ceil(#languages / page_size))
        local dialog_ref
        
        local function openPage(page_number)
            local buttons = {}
            local function addRow(row_buttons)
                table.insert(buttons, row_buttons)
            end
            
            if page_number == 1 then
                addRow({
                    {
                        text = (not current_value and "✓ " or "") .. "Any",
                        callback = function()
                            setter(nil)
                            if dialog_ref then UIManager:close(dialog_ref) end
                            refreshFilterDialog()
                        end,
                    },
                })
            end
            
            local start_idx = (page_number - 1) * page_size + 1
            local end_idx = math.min(start_idx + page_size - 1, #languages)
            for i = start_idx, end_idx do
                local name = languages[i]
                addRow({
                    {
                        text = (current_value == name and "✓ " or "") .. name,
                        callback = function()
                            setter(name)
                            if dialog_ref then UIManager:close(dialog_ref) end
                            refreshFilterDialog()
                        end,
                    },
                })
            end
            
            local nav_row = {}
            if page_number > 1 then
                table.insert(nav_row, {
                    text = "◀ Previous",
                    callback = function()
                        if dialog_ref then UIManager:close(dialog_ref) end
                        openPage(page_number - 1)
                    end,
                })
            end
            if page_number < total_pages then
                table.insert(nav_row, {
                    text = "Next ▶",
                    callback = function()
                        if dialog_ref then UIManager:close(dialog_ref) end
                        openPage(page_number + 1)
                    end,
                })
            end
            if #nav_row > 0 then
                addRow(nav_row)
            end
            
            if dialog_ref then
                UIManager:close(dialog_ref)
            end
            dialog_ref = ButtonDialog:new{
                title = string.format("%s (Page %d/%d)", title, page_number, total_pages),
                buttons = buttons,
            }
            self[dialog_key] = dialog_ref
            UIManager:show(dialog_ref)
        end
        
        openPage(1)
    end
    
    local function formatLanguageLabel(value)
        return value or "Any"
    end

    local function formatSearchLabel(value)
        if value and value ~= "" then
            if #value > 30 then
                return value:sub(1, 27) .. "..."
            end
            return value
        end
        return "Any"
    end
    
    local function summarizeSelectedTags()
        if current_filters.tags and #current_filters.tags > 0 then
            local summary = table.concat(current_filters.tags, ", ")
            if #summary > 40 then
                summary = summary:sub(1, 37) .. "..."
            end
            return summary
        end
        return "None"
    end

    local function showTagsDialog()
        local tag_dialog
        local function openTagPage(page_number)
            local offset = (page_number - 1) * tags_per_page
            local tag_page, tag_error, tag_has_more = self:fetchTagsFromSupabase(tags_per_page, offset)
            if tag_error then
                UIManager:show(InfoMessage:new{
                    text = "Could not fetch tags: " .. tag_error,
                })
                return
            end

            if tag_dialog then
                UIManager:close(tag_dialog)
            end

            local buttons = {}
            if #tag_page == 0 then
                table.insert(buttons, {
                    {
                        text = "No tags available",
                        callback = function()
                            UIManager:close(tag_dialog)
                        end,
                    },
                })
            else
                for _, tag in ipairs(tag_page) do
                    local is_selected = false
                    if current_filters.tags then
                        for _, selected_tag in ipairs(current_filters.tags) do
                            if selected_tag == tag.tag_name then
                                is_selected = true
                                break
                            end
                        end
                    end

                    table.insert(buttons, {
                        {
                            text = (is_selected and "✓ " or "") .. tag.tag_name,
                            callback = function()
                                current_filters.tags = current_filters.tags or {}
                                local found = false
                                for i, selected_tag in ipairs(current_filters.tags) do
                                    if selected_tag == tag.tag_name then
                                        table.remove(current_filters.tags, i)
                                        found = true
                                        break
                                    end
                                end
                                if not found then
                                    table.insert(current_filters.tags, tag.tag_name)
                                end
                                openTagPage(page_number)
                            end,
                        },
                    })
                end
            end

            local nav_row = {}
            if page_number > 1 then
                table.insert(nav_row, {
                    text = "◄ Previous",
                    callback = function()
                        self._tag_filter_page = math.max(1, page_number - 1)
                        openTagPage(self._tag_filter_page)
                    end,
                })
            end
            if tag_has_more then
                table.insert(nav_row, {
                    text = "Next ►",
                    callback = function()
                        self._tag_filter_page = page_number + 1
                        openTagPage(self._tag_filter_page)
                    end,
                })
            end
            if #nav_row > 0 then
                table.insert(buttons, nav_row)
            end

            if current_filters.tags and #current_filters.tags > 0 then
                table.insert(buttons, {
                    {
                        text = "Clear Selected Tags",
                        callback = function()
                            current_filters.tags = {}
                            openTagPage(page_number)
                        end,
                    },
                })
            end

            table.insert(buttons, {
                {
                    text = "Done",
                    callback = function()
                        self._tag_filter_page = page_number
                        UIManager:close(tag_dialog)
                        refreshFilterDialog()
                    end,
                },
            })

            local selected_count = current_filters.tags and #current_filters.tags or 0
            local selected_text = "No tags selected"
            if selected_count > 0 then
                selected_text = "Selected: " .. table.concat(current_filters.tags, ", ")
            end

            tag_dialog = ButtonDialog:new{
                title = string.format("Select Tags (Page %d)", page_number),
                text = selected_text,
                buttons = buttons,
            }
            UIManager:show(tag_dialog)
        end

        openTagPage(self._tag_filter_page or 1)
    end
    
    -- Language selection
    local function showLanguage1Dialog()
        showLanguageSelectionDialog(
            "Filter by Language 1",
            current_filters.language1,
            function(value)
                current_filters.language1 = value
            end,
            "lang1_dialog"
        )
    end
    
    local function showLanguage2Dialog()
        showLanguageSelectionDialog(
            "Filter by Language 2",
            current_filters.language2,
            function(value)
                current_filters.language2 = value
            end,
            "lang2_dialog"
        )
    end
    
    local function showSearchDialog()
        local search_dialog
        search_dialog = InputDialog:new{
            title = "Search Words",
            input = current_filters.search or "",
            input_type = "text",
            description = "Search in word1 and word2",
            buttons = {
                {
                    {
                        text = "Clear",
                        callback = function()
                            current_filters.search = nil
                            UIManager:close(search_dialog)
                            self:showWordsFilterDialog(callback)
                        end,
                    },
                    {
                        text = "Apply",
                        callback = function()
                            local search = search_dialog:getInputText()
                            if search and search ~= "" then
                                current_filters.search = search
                            else
                                current_filters.search = nil
                            end
                            UIManager:close(search_dialog)
                            self:showWordsFilterDialog(callback)
                        end,
                    },
                },
            },
        }
        UIManager:show(search_dialog)
        search_dialog:onShowKeyboard()
    end
    
    local function toggleFavorite()
        if current_filters.favorite == nil then
            current_filters.favorite = true
        elseif current_filters.favorite == true then
            current_filters.favorite = false
        else
            current_filters.favorite = nil
        end
        UIManager:close(self.filter_dialog)
        self:showWordsFilterDialog(callback)
    end
    
    local filter_summary = {}
    if current_filters.language1 then
        table.insert(filter_summary, "Lang1: " .. current_filters.language1)
    end
    if current_filters.language2 then
        table.insert(filter_summary, "Lang2: " .. current_filters.language2)
    end
    if current_filters.search then
        table.insert(filter_summary, "Search: " .. current_filters.search)
    end
    if current_filters.favorite ~= nil then
        table.insert(filter_summary, "Favorite: " .. (current_filters.favorite and "Yes" or "No"))
    end
    if current_filters.tags and #current_filters.tags > 0 then
        table.insert(filter_summary, "Tags: " .. table.concat(current_filters.tags, ", "))
    end
    
    local summary_text = #filter_summary > 0 and table.concat(filter_summary, "\n") or "No filters applied"
    
    local filter_buttons = {
        {
            {
                text = "Language 1: " .. formatLanguageLabel(current_filters.language1),
                callback = showLanguage1Dialog,
            },
            {
                text = "Language 2: " .. formatLanguageLabel(current_filters.language2),
                callback = showLanguage2Dialog,
            },
        },
        {
            {
                text = "Search: " .. formatSearchLabel(current_filters.search),
                callback = showSearchDialog,
            },
            {
                text = "Favorite: " .. (current_filters.favorite == true and "Yes" or current_filters.favorite == false and "No" or "Any"),
                callback = toggleFavorite,
            },
        },
    }
    
    table.insert(filter_buttons, {
        {
            text = "Tags: " .. summarizeSelectedTags(),
            callback = showTagsDialog,
        },
    })
    
    table.insert(filter_buttons, {})
    table.insert(filter_buttons, {
        {
            text = "Clear All",
            callback = function()
                for key in pairs(current_filters) do
                    current_filters[key] = nil
                end
                self._tag_filter_page = 1
                refreshFilterDialog()
            end,
        },
        {
            text = "Apply",
            callback = function()
                self.words_filters = cloneFilters(current_filters)
                self:dismissWordsFilterDialog()
                self._tag_filter_page = 1
                if callback then
                    callback()
                end
            end,
        },
    })
    
    self.filter_dialog = ButtonDialog:new{
        title = "Filter Words",
        text = "Current filters:\n" .. summary_text,
        buttons = filter_buttons,
        close_callback = function()
            self.filter_dialog = nil
            self._filter_working_copy = nil
        end,
    }
    UIManager:show(self.filter_dialog)
end

-- ============================================
-- UI: WORD DETAIL DIALOG
-- ============================================

-- Widget class for word detail dialog
local WordDetailViewer = InputContainer:extend{
    width = Screen:getWidth() * 0.9,
    height = Screen:getHeight() * 0.7,
    text_padding = Size.padding.default,
    text_margin = Size.margin.default,
    button_padding = Size.padding.default,
}

function WordDetailViewer:init()
    local titlebar = TitleBar:new{
        title = self.title_text,
    }
    
    local button_table = ButtonTable:new{
        width = self.width - 2 * self.button_padding,
        buttons = self.buttons,
        show_parent = self,
        zero_sep = true,
    }
    
    local textw_height = self.height - titlebar:getHeight() - button_table:getSize().h
    
    -- Calculate scrollbar width to account for it in width calculation
    local scrollbar_width = ScrollTextWidget.scroll_bar_width + ScrollTextWidget.text_scroll_span
    
    -- Calculate available width for text area (accounting for padding, margin, and scrollbar)
    -- ScrollTextWidget width is the text width, scrollbar is added separately
    local available_text_width = self.width - 2 * self.text_padding - 2 * self.text_margin - scrollbar_width
    
    local scroll_text_w = ScrollTextWidget:new{
        text = self.text,
        face = Font:getFace("smallinfofont"),
        width = available_text_width,
        height = textw_height - 2 * self.text_padding - 2 * self.text_margin,
        dialog = self,
    }
    
    -- Don't set explicit width on textw - let it size based on its content
    -- The CenterContainer will constrain it to self.width
    local textw = FrameContainer:new{
        padding = self.text_padding,
        margin = self.text_margin,
        bordersize = 0,
        scroll_text_w,
    }
    
    local frame = FrameContainer:new{
        radius = Size.radius.window,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        VerticalGroup:new{
            titlebar,
            CenterContainer:new{
                dimen = Geom:new{
                    w = self.width,
                    h = textw:getSize().h,
                },
                textw,
            },
            CenterContainer:new{
                dimen = Geom:new{
                    w = self.width,
                    h = button_table:getSize().h,
                },
                button_table,
            }
        }
    }
    
    local movable = MovableContainer:new{
        frame,
    }
    
    self[1] = CenterContainer:new{
        dimen = Geom:new{
            w = Screen:getWidth(),
            h = Screen:getHeight(),
        },
        movable,
    }
end

function WordDetailViewer:onShow()
    UIManager:setDirty(self, function()
        return "ui", self[1][1].dimen -- MovableContainer
    end)
    return true
end

function WordDetailViewer:paintTo(...)
    InputContainer.paintTo(self, ...)
    self.dimen = self[1][1].dimen -- MovableContainer
end

function WordDetailViewer:onCloseWidget()
    -- Mark the area as dirty for proper cleanup/repaint
    UIManager:setDirty(nil, function()
        return "ui", self[1][1].dimen -- MovableContainer
    end)
end

function WordDetailViewer:onClose()
    UIManager:close(self)
    return true
end

function DictSync:showWordDetailDialog(word_data, on_update_callback)
    if self.filter_dialog then
        self:dismissWordsFilterDialog()
    end
    local word_id = word_data.id
    local word1 = word_data.word1 or ""
    local word2 = word_data.word2 or ""
    local language1 = word_data.language1 or ""
    local language2 = word_data.language2 or ""
    if not word_id then
        UIManager:show(InfoMessage:new{
            text = "Unable to edit word: missing Supabase ID",
        })
        return
    end
    -- Use different variable names to avoid conflicts
    local word_definition = (type(word_data.definition) == "string") and word_data.definition or ""
    local word_definition2 = (type(word_data.definition2) == "string") and word_data.definition2 or ""
    local field_map = word_data._field_map
    local word_source = word_data.source or word_data.Source or ""

    local function getDefinitionField(which_definition)
        local target = (which_definition == 1) and "definition" or "definition2"
        return remapField(target, field_map)
    end
    
    -- Fetch tags for this word
    local word_tags, tag_error = self:getWordTags(word_id)
    if tag_error then
        logger.warn("Lingueez: Could not fetch tags: " .. tag_error)
        word_tags = {}
    end
    
        local function refreshWordDetail()
        NetworkMgr:runWhenOnline(function()
            Trapper:wrap(function()
                local updated_word, fetch_error = self:fetchWordById(word_id, self.words_filters)
                UIManager:nextTick(function()
                    if updated_word then
                        if self.word_detail_dialog then
                            UIManager:close(self.word_detail_dialog)
                            self.word_detail_dialog = nil
                        end
                        self:showWordDetailDialog(updated_word, on_update_callback)
                    else
                        UIManager:show(InfoMessage:new{
                            text = "Updated but failed to refresh: " .. (fetch_error or "Unknown error"),
                        })
                        if on_update_callback then
                            on_update_callback()
                        end
                    end
                end)
            end)
        end)
    end
    
    local function showDefinitionEditDialog(which_definition)
        local current_def = (which_definition == 1) and word_definition or word_definition2
        local def_dialog
        def_dialog = InputDialog:new{
            title = "Edit Definition " .. which_definition,
            input = current_def,
            input_type = "text",
            description = string.format("Definition for %s (%s)", 
                (which_definition == 1) and word1 or word2,
                (which_definition == 1) and language1 or language2),
            buttons = {
                {
                    {
                        text = "Cancel",
                        callback = function()
                            UIManager:close(def_dialog)
                        end,
                    },
                    {
                        text = "Save",
                        callback = function()
                            local new_def = def_dialog:getInputText() or ""
                            UIManager:close(def_dialog)
                            
                            -- Update definition
                            NetworkMgr:runWhenOnline(function()
                                Trapper:wrap(function()
                                    local target_field = getDefinitionField(which_definition)
                                    local update_def = nil
                                    local update_def2 = nil
                                    if target_field == "definition" then
                                        update_def = new_def
                                    else
                                        update_def2 = new_def
                                    end
                                    local success, msg = self:updateWordDefinition(word_id, update_def, update_def2, word_source)
                                    
                                    UIManager:nextTick(function()
                                        if success then
                                            UIManager:show(InfoMessage:new{
                                                text = "Definition updated",
                                            })
                                            word_source = ensureEditedSourceTag(word_source)
                                            refreshWordDetail()
                                        else
                                            UIManager:show(InfoMessage:new{
                                                text = "Error: " .. (msg or "Unknown error"),
                                            })
                                        end
                                    end)
                                end)
                            end)
                        end,
                    },
                },
            },
        }
        UIManager:show(def_dialog)
        def_dialog:onShowKeyboard()
    end
    
    local function fetchWikipediaDefinition(which_word)
        local word_to_fetch = (which_word == 1) and word1 or word2
        local lang_to_use = (which_word == 1) and language1 or language2
        
        UIManager:show(InfoMessage:new{
            text = "Fetching from Wikipedia...",
            timeout = 1,
        })
        
        NetworkMgr:runWhenOnline(function()
            Trapper:wrap(function()
                local wiki_def, error_msg = self:fetchWikipediaDefinition(word_to_fetch, lang_to_use)
                
                UIManager:nextTick(function()
                    if wiki_def then
                        local wiki_viewer
                        local wiki_buttons = {
                            {
                                {
                                    text = "Use This",
                                    callback = function()
                                        if wiki_viewer then
                                            UIManager:close(wiki_viewer)
                                        end
                                        NetworkMgr:runWhenOnline(function()
                                            Trapper:wrap(function()
                                                local target_field = getDefinitionField(which_word)
                                                local update_def = nil
                                                local update_def2 = nil
                                                if target_field == "definition" then
                                                    update_def = wiki_def
                                                else
                                                    update_def2 = wiki_def
                                                end
                                                local success, msg = self:updateWordDefinition(word_id, update_def, update_def2, word_source)
                                                
                                                UIManager:nextTick(function()
                                                    if success then
                                                        UIManager:show(InfoMessage:new{
                                                            text = "Definition updated from Wikipedia",
                                                        })
                                                        word_source = ensureEditedSourceTag(word_source)
                                                        refreshWordDetail()
                                                    else
                                                        UIManager:show(InfoMessage:new{
                                                            text = "Error: " .. (msg or "Unknown error"),
                                                        })
                                                    end
                                                end)
                                            end)
                                        end)
                                    end,
                                },
                                {
                                    text = "Cancel",
                                    callback = function()
                                        if wiki_viewer then
                                            UIManager:close(wiki_viewer)
                                        end
                                    end,
                                },
                            },
                        }
                        
                        wiki_viewer = WordDetailViewer:new{
                            title_text = string.format("Wikipedia: %s (%s)", word_to_fetch, lang_to_use or lang_code or ""),
                            text = wiki_def,
                            buttons = wiki_buttons,
                        }
                        UIManager:show(wiki_viewer)
                    else
                        UIManager:show(InfoMessage:new{
                            text = "Could not fetch from Wikipedia: " .. (error_msg or "Unknown error"),
                        })
                    end
                end)
            end)
        end)
    end
    
    -- Build detail text
    local detail_lines = {
        string.format("Word: %s (%s)", word1, language1),
        string.format("Translation: %s (%s)", word2, language2),
        "",
    }
    
    if #word_tags > 0 then
        table.insert(detail_lines, "Tags: " .. table.concat(word_tags, ", "))
        table.insert(detail_lines, "")
    end
    
    if word_definition and word_definition ~= "" then
        table.insert(detail_lines, "Definition 1:")
        table.insert(detail_lines, word_definition:sub(1, 200) .. (string.len(word_definition) > 200 and "..." or ""))
        table.insert(detail_lines, "")
    end
    
    if word_definition2 and word_definition2 ~= "" then
        table.insert(detail_lines, "Definition 2:")
        table.insert(detail_lines, word_definition2:sub(1, 200) .. (string.len(word_definition2) > 200 and "..." or ""))
        table.insert(detail_lines, "")
    end
    
    if (not word_definition or word_definition == "") and (not word_definition2 or word_definition2 == "") then
        table.insert(detail_lines, "No definitions yet")
    end
    
    local detail_text = table.concat(detail_lines, "\n")
    
    local detail_buttons = {
        {
            {
                text = "Edit Def 1",
                callback = function()
                    UIManager:close(self.word_detail_dialog)
                    showDefinitionEditDialog(1)
                end,
            },
            {
                text = "Edit Def 2",
                callback = function()
                    UIManager:close(self.word_detail_dialog)
                    showDefinitionEditDialog(2)
                end,
            },
        },
        {
            {
                text = "Wikipedia 1",
                callback = function()
                    fetchWikipediaDefinition(1)
                end,
            },
            {
                text = "Wikipedia 2",
                callback = function()
                    fetchWikipediaDefinition(2)
                end,
            },
        },
        {
            {
                text = "Edit Word",
                callback = function()
                    UIManager:close(self.word_detail_dialog)
                            self.word_detail_dialog = nil
                            self:showEditDialog(
                                word1,
                                language1,
                                word2,
                                language2,
                                word_definition,
                                word_definition2,
                                word_id,
                                refreshWordDetail,
                                word_data._field_map
                            )
                end,
            },
        },
        {
            {
                text = "Close",
                id = "close",
                callback = function()
                    UIManager:close(self.word_detail_dialog)
                    self.word_detail_dialog = nil
                end,
            },
        },
    }
    
    -- Create widget viewer
    self.word_detail_dialog = WordDetailViewer:new{
        title_text = word1 .. " → " .. word2,
        text = detail_text,
        buttons = detail_buttons,
    }
    
    UIManager:show(self.word_detail_dialog)
end

-- ============================================
-- UI: WORDS LIST DIALOG
-- ============================================

-- Widget class for words list dialog
local WordsListViewer = InputContainer:extend{
    width = Screen:getWidth() * 0.9,
    height = Screen:getHeight() * 0.7,
    text_padding = Size.padding.default,
    text_margin = Size.margin.default,
    button_padding = Size.padding.default,
}

function WordsListViewer:init()
    local titlebar = TitleBar:new{
        title = self.title_text or "My Words",
    }
    
    local button_table = ButtonTable:new{
        width = self.width - 2 * self.button_padding,
        buttons = self.buttons,
        show_parent = self,
        zero_sep = true,
    }
    self.button_table = button_table
    
    -- Calculate initial text area height
    local textw_height = self.height - titlebar:getHeight() - button_table:getSize().h
    
    -- Minimum height for text area to ensure it's always usable
    local min_text_height = 100
    
    -- If text area would be too small, adjust dialog height dynamically
    if textw_height < min_text_height then
        -- Calculate required height to accommodate all components
        local required_height = titlebar:getHeight() + button_table:getSize().h + min_text_height + 2 * self.text_padding + 2 * self.text_margin
        if required_height > self.height then
            -- Increase dialog height, but cap at 95% of screen height
            self.height = math.min(required_height, Screen:getHeight() * 0.95)
        end
        -- Recalculate textw_height with adjusted dialog height
        textw_height = self.height - titlebar:getHeight() - button_table:getSize().h
    end
    
    -- Ensure textw_height is never negative
    textw_height = math.max(textw_height, min_text_height)
    
    -- Calculate scrollbar width to account for it in width calculation
    local scrollbar_width = ScrollTextWidget.scroll_bar_width + ScrollTextWidget.text_scroll_span
    
    -- Calculate available width for text area (accounting for padding, margin, and scrollbar)
    -- ScrollTextWidget width is the text width, scrollbar is added separately
    local available_text_width = self.width - 2 * self.text_padding - 2 * self.text_margin - scrollbar_width
    
    local scroll_text_w = ScrollTextWidget:new{
        text = self.text,
        face = Font:getFace("smallinfofont"),
        width = available_text_width,
        height = textw_height - 2 * self.text_padding - 2 * self.text_margin,
        dialog = self,
    }
    
    -- Don't set explicit width on textw - let it size based on its content
    -- The CenterContainer will constrain it to self.width
    local textw = FrameContainer:new{
        padding = self.text_padding,
        margin = self.text_margin,
        bordersize = 0,
        scroll_text_w,
    }
    
    local frame = FrameContainer:new{
        radius = Size.radius.window,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        VerticalGroup:new{
            titlebar,
            CenterContainer:new{
                dimen = Geom:new{
                    w = self.width,
                    h = textw:getSize().h,
                },
                textw,
            },
            CenterContainer:new{
                dimen = Geom:new{
                    w = self.width,
                    h = button_table:getSize().h,
                },
                button_table,
            }
        }
    }
    
    local movable = MovableContainer:new{
        frame,
    }
    
    self[1] = CenterContainer:new{
        dimen = Geom:new{
            w = Screen:getWidth(),
            h = Screen:getHeight(),
        },
        movable,
    }
end

function WordsListViewer:onShow()
    UIManager:setDirty(self, function()
        return "ui", self[1][1].dimen -- MovableContainer
    end)
    return true
end

function WordsListViewer:paintTo(...)
    InputContainer.paintTo(self, ...)
    self.dimen = self[1][1].dimen -- MovableContainer
end

function WordsListViewer:onCloseWidget()
    -- Mark the area as dirty for proper cleanup/repaint
    UIManager:setDirty(nil, function()
        return "ui", self[1][1].dimen -- MovableContainer
    end)
end

function WordsListViewer:onClose()
    UIManager:close(self)
    return true
end

function DictSync:showWordsListDialog(page, filters)
    if not self:ensureAuthed() then return end
    page = page or 1
    filters = filters or self.words_filters or {}

    if self.filter_dialog then
        self:dismissWordsFilterDialog()
    end
    
    -- Show loading message
    UIManager:show(InfoMessage:new{
        text = "Loading words...",
        timeout = 1,
    })
    
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            local result, error_msg = self:fetchWordsFromSupabase(page, 25, filters)
            
            UIManager:nextTick(function()
                if not result then
                    UIManager:show(InfoMessage:new{
                        text = "Error loading words: " .. (error_msg or "Unknown error"),
                    })
                    return
                end
                
                -- Validate result structure
                if type(result) ~= "table" then
                    UIManager:show(InfoMessage:new{
                        text = "Error: Invalid response format",
                    })
                    return
                end
                
                if not result.words or type(result.words) ~= "table" then
                    UIManager:show(InfoMessage:new{
                        text = "Error: No words data in response",
                    })
                    return
                end
                
                if #result.words == 0 then
                    UIManager:show(InfoMessage:new{
                        text = "No words found",
                    })
                    return
                end
                
                -- Build word list text
                local word_lines = {}
                for i, word in ipairs(result.words) do
                    -- Ensure word is a table, not a string
                    if type(word) == "table" then
                        local line = string.format("%d. %s (%s) → %s (%s)",
                            (page - 1) * 25 + i,
                            word.word1 or "",
                            word.language1 or "",
                            word.word2 or "",
                            word.language2 or ""
                        )
                        table.insert(word_lines, line)
                    else
                        logger.warn("Lingueez: Word entry is not a table: " .. tostring(word))
                    end
                end
                
                if #word_lines == 0 then
                    UIManager:show(InfoMessage:new{
                        text = "No words to display",
                    })
                    return
                end
                
                local word_text = table.concat(word_lines, "\n")
                
                -- Safety check: ensure we're not accidentally displaying raw JSON
                if word_text:match("^{") or word_text:match("%[%s*{") then
                    logger.err("Lingueez: Detected JSON in word_text, this should not happen!")
                    UIManager:show(InfoMessage:new{
                        text = "Error: Invalid data format. Please check logs.",
                    })
                    return
                end
                
                local page_info = string.format("Page %d of %d (%d total words)\n\n", 
                    result.page or page, result.total_pages or 1, result.total_count or 0)
                
                -- Create buttons for navigation and actions
                local buttons = {}
                
                -- Filter button
                table.insert(buttons, {
                    {
                        text = "Filter",
                        callback = function()
                            UIManager:close(self.words_dialog)
                            self:showWordsFilterDialog(function()
                                self:showWordsListDialog(1, self.words_filters)
                            end)
                        end,
                    },
                })
                
                -- Previous/Next page buttons
                if result.has_prev or result.has_next then
                    local nav_row = {}
                    if result.has_prev then
                        table.insert(nav_row, {
                            text = "◄ Previous",
                            callback = function()
                                UIManager:close(self.words_dialog)
                                self:showWordsListDialog(page - 1, filters)
                            end,
                        })
                    end
                    if result.has_next then
                        table.insert(nav_row, {
                            text = "Next ►",
                            callback = function()
                                UIManager:close(self.words_dialog)
                                self:showWordsListDialog(page + 1, filters)
                            end,
                        })
                    end
                    table.insert(buttons, nav_row)
                end
                
                -- Word selection buttons with paging (4 visible at a time)
                local shortcut_state = {
                    start_index = 1,
                    max_visible = 4,
                }
                
                local function getShortcutLabel(slot_idx)
                    local data_index = shortcut_state.start_index + slot_idx - 1
                    local word = result.words[data_index]
                    if not word then
                        return "—", nil
                    end
                    local word_num = (page - 1) * 25 + data_index
                    local label = string.format("%d. %s", word_num, word.word1 or "")
                    return label, data_index
                end
                
                local function openWordAtIndex(data_index)
                    local word = result.words[data_index]
                    if not word then
                        return
                    end
                    UIManager:close(self.words_dialog)
                    self:showWordDetailDialog(word, function()
                        -- Refresh the list after update
                        self:showWordsListDialog(page, filters)
                    end)
                end
                
                local function makeShortcutCallback(slot_idx)
                    return function()
                        local data_index = shortcut_state.start_index + slot_idx - 1
                        openWordAtIndex(data_index)
                    end
                end
                
                local word_buttons = {}
                for slot = 1, shortcut_state.max_visible do
                    local label = select(1, getShortcutLabel(slot))
                    table.insert(word_buttons, {
                        id = "shortcut_" .. slot,
                        text = label,
                        callback = makeShortcutCallback(slot),
                    })
                end
                
                if #word_buttons > 0 then
                    -- Split into rows of 2
                    for i = 1, #word_buttons, 2 do
                        local row = {word_buttons[i]}
                        if word_buttons[i + 1] then
                            table.insert(row, word_buttons[i + 1])
                        end
                        table.insert(buttons, row)
                    end
                end
                
                local updateShortcutButtonTexts
                local function getMaxShortcutStart()
                    if #result.words <= shortcut_state.max_visible then
                        return 1
                    end
                    return #result.words - shortcut_state.max_visible + 1
                end
                
                local function shiftShortcutWindow(delta)
                    local max_start = getMaxShortcutStart()
                    local new_start = math.max(1, math.min(max_start, shortcut_state.start_index + delta))
                    if new_start ~= shortcut_state.start_index then
                        shortcut_state.start_index = new_start
                        if updateShortcutButtonTexts then
                            updateShortcutButtonTexts()
                        end
                    end
                end
                
                if #result.words > shortcut_state.max_visible then
                    local nav_row = {
                        {
                            id = "shortcut_prev",
                            text = "◄ More",
                            callback = function()
                                shiftShortcutWindow(-shortcut_state.max_visible)
                            end,
                        },
                        {
                            id = "shortcut_next",
                            text = "More ►",
                            callback = function()
                                shiftShortcutWindow(shortcut_state.max_visible)
                            end,
                        },
                    }
                    table.insert(buttons, nav_row)
                end
                
                updateShortcutButtonTexts = function()
                    if not self.words_dialog or not self.words_dialog.button_table then
                        return
                    end
                    for slot = 1, shortcut_state.max_visible do
                        local button = self.words_dialog.button_table:getButtonById("shortcut_" .. slot)
                        if button then
                            local label, data_index = getShortcutLabel(slot)
                            button:setText(label, button.width)
                            if data_index then
                                button:enable()
                            else
                                button:disable()
                            end
                            button:refresh()
                        end
                    end
                    local prev_button = self.words_dialog.button_table:getButtonById("shortcut_prev")
                    if prev_button then
                        if shortcut_state.start_index > 1 then
                            prev_button:enable()
                        else
                            prev_button:disable()
                        end
                        prev_button:refresh()
                    end
                    local next_button = self.words_dialog.button_table:getButtonById("shortcut_next")
                    if next_button then
                        if shortcut_state.start_index < getMaxShortcutStart() then
                            next_button:enable()
                        else
                            next_button:disable()
                        end
                        next_button:refresh()
                    end
                end
                
                -- Close button
                table.insert(buttons, {
                    {
                        text = "Close",
                        callback = function()
                            UIManager:close(self.words_dialog)
                            self.words_dialog = nil
                        end,
                    },
                })
                
                -- Create widget viewer
                self.words_dialog = WordsListViewer:new{
                    title_text = "My Words",
                    text = page_info .. word_text,
                    buttons = buttons,
                }
                
                UIManager:show(self.words_dialog)
                UIManager:nextTick(function()
                    updateShortcutButtonTexts()
                end)
            end)
        end)
    end)
end

-- ============================================
-- UI: FLASHCARDS
-- ============================================

local FlashcardViewer = InputContainer:extend{
    width = Screen:getWidth() * 0.9,
    height = Screen:getHeight() * 0.8,
    text_padding = Size.padding.default,
    text_margin = Size.margin.default,
    button_padding = Size.padding.default,
    owner = nil,
}

function FlashcardViewer:createScrollWidget(text)
    return ScrollTextWidget:new{
        text = text or "",
        face = Font:getFace("smallinfofont"),
        width = self.scroll_text_width,
        height = self.scroll_text_height,
        dialog = self,
    }
end

function FlashcardViewer:init()
    local titlebar = TitleBar:new{
        title = self.title_text or "Flashcards",
    }

    local button_table = ButtonTable:new{
        width = self.width - 2 * self.button_padding,
        buttons = self.buttons,
        show_parent = self,
        zero_sep = true,
    }
    self.button_table = button_table

    local text_area_height = self.height - titlebar:getHeight() - button_table:getSize().h
    text_area_height = math.max(text_area_height, 120)

    local scrollbar_width = ScrollTextWidget.scroll_bar_width + ScrollTextWidget.text_scroll_span
    local available_text_width = self.width - 2 * self.text_padding - 2 * self.text_margin - scrollbar_width

    local scroll_height = math.max(text_area_height - 2 * self.text_padding - 2 * self.text_margin, 80)

    self.scroll_text_width = available_text_width
    self.scroll_text_height = scroll_height
    local scroll_text_w = self:createScrollWidget(self.text or "")
    self.scroll_text_w = scroll_text_w

    local text_frame = FrameContainer:new{
        padding = self.text_padding,
        margin = self.text_margin,
        bordersize = 0,
        scroll_text_w,
    }
    self.text_frame = text_frame

    local frame = FrameContainer:new{
        radius = Size.radius.window,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        VerticalGroup:new{
            titlebar,
            CenterContainer:new{
                dimen = Geom:new{
                    w = self.width,
                    h = text_frame:getSize().h,
                },
                text_frame,
            },
            CenterContainer:new{
                dimen = Geom:new{
                    w = self.width,
                    h = button_table:getSize().h,
                },
                button_table,
            }
        }
    }

    local movable = MovableContainer:new{
        frame,
    }

    self[1] = CenterContainer:new{
        dimen = Geom:new{
            w = Screen:getWidth(),
            h = Screen:getHeight(),
        },
        movable,
    }
end

function FlashcardViewer:onShow()
    UIManager:setDirty(self, function()
        return "ui", self[1][1].dimen
    end)
    return true
end

function FlashcardViewer:paintTo(...)
    InputContainer.paintTo(self, ...)
    self.dimen = self[1][1].dimen
end

function FlashcardViewer:onCloseWidget()
    if self.owner and self.owner.onFlashcardDialogClosed then
        self.owner:onFlashcardDialogClosed()
    end
    UIManager:setDirty(nil, function()
        return "ui", self[1][1].dimen
    end)
end

function FlashcardViewer:onClose()
    UIManager:close(self)
    return true
end

function FlashcardViewer:setCardText(text)
    if not self.text_frame then
        return
    end
    local new_widget = self:createScrollWidget(text or "")
    self.scroll_text_w = new_widget
    self.text_frame:clear()
    self.text_frame[1] = new_widget
    UIManager:setDirty(self, function()
        return "ui", self[1][1].dimen
    end)
end

function DictSync:showFlashcardsLauncher()
    if not self:ensureAuthed() then return end
    local filters = cloneFilters(self.words_filters)
    local summary_text = summarizeFilters(filters)
    local launcher_dialog
    launcher_dialog = ButtonDialog:new{
        title = "Flashcards",
        text = "Study your saved vocabulary with flashcards.\n\nCurrent filters:\n" .. summary_text,
        buttons = {
            {
                {
                    text = "Start Session",
                    callback = function()
                        UIManager:close(launcher_dialog)
                        self:startFlashcardSession(filters)
                    end,
                },
            },
            {
                {
                    text = "Change Filters",
                    callback = function()
                        UIManager:close(launcher_dialog)
                        self:showWordsFilterDialog(function()
                            local updated_filters = cloneFilters(self.words_filters)
                            self:startFlashcardSession(updated_filters)
                        end)
                    end,
                },
            },
            {
                {
                    text = "Cancel",
                    callback = function()
                        UIManager:close(launcher_dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(launcher_dialog)
end

function DictSync:fetchFlashcardWordSet(filters)
    filters = filters or {}
    if not self.settings then
        return nil, "Settings not initialized"
    end

    local configured_limit = self.settings:readSetting("flashcards_max_cards")
    local max_cards = tonumber(configured_limit) or 50
    if max_cards < 1 then
        max_cards = 1
    elseif max_cards > 500 then
        max_cards = 500
    end

    local collected = {}
    local page = 1
    local page_size = math.min(max_cards, 50)

    while #collected < max_cards do
        local result, error_msg = self:fetchWordsFromSupabase(page, page_size, filters)
        if not result then
            return nil, error_msg
        end

        if not result.words or #result.words == 0 then
            break
        end

        for _, word in ipairs(result.words) do
            table.insert(collected, word)
            if #collected >= max_cards then
                break
            end
        end

        if #collected >= max_cards or not result.has_next then
            break
        end
        page = page + 1
    end

    return collected, nil
end

function DictSync:shuffleFlashcardWords(words)
    if not words or #words <= 1 then
        return
    end
    if not self._flashcard_random_seeded then
        math.randomseed(os.time())
        self._flashcard_random_seeded = true
    end
    for i = #words, 2, -1 do
        local j = math.random(i)
        words[i], words[j] = words[j], words[i]
    end
end

function DictSync:startFlashcardSession(filters)
    local active_filters = cloneFilters(filters)
    UIManager:show(InfoMessage:new{
        text = "Preparing flashcards...",
        timeout = 1,
    })

    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            local word_set, error_msg = self:fetchFlashcardWordSet(active_filters)
            UIManager:nextTick(function()
                if not word_set then
                    UIManager:show(InfoMessage:new{
                        text = "Could not load cards: " .. (error_msg or "Unknown error"),
                    })
                    return
                end

                if #word_set == 0 then
                    UIManager:show(InfoMessage:new{
                        text = "No cards match your filters",
                    })
                    return
                end

                self:openFlashcardSession(word_set, active_filters)
            end)
        end)
    end)
end

function DictSync:openFlashcardSession(words, filters)
    self:closeFlashcardSession()
    self:shuffleFlashcardWords(words)
    self.flashcard_session = {
        words = words,
        filters = filters or {},
        current_index = 1,
        revealed = false,
    }

    local buttons = self:createFlashcardButtons()
    local initial_text = self:buildFlashcardText()
    self.flashcard_dialog = FlashcardViewer:new{
        owner = self,
        title_text = "Flashcards",
        text = initial_text or "",
        buttons = buttons,
    }

    UIManager:show(self.flashcard_dialog)
    UIManager:nextTick(function()
        self:updateFlashcardDialog()
    end)
end

function DictSync:createFlashcardButtons()
    return {
        {
            {
                id = "flashcard_reveal",
                text = "Reveal Translation",
                callback = function()
                    self:toggleFlashcardReveal()
                end,
            },
        },
        {
            {
                id = "flashcard_prev",
                text = "◄ Previous",
                callback = function()
                    self:stepFlashcard(-1)
                end,
            },
            {
                id = "flashcard_next",
                text = "Next ►",
                callback = function()
                    self:stepFlashcard(1)
                end,
            },
        },
        {
            {
                id = "flashcard_restart",
                text = "Restart",
                callback = function()
                    self:restartFlashcards(false)
                end,
            },
            {
                id = "flashcard_shuffle",
                text = "Shuffle",
                callback = function()
                    self:restartFlashcards(true)
                end,
            },
        },
        {
            {
                id = "flashcard_filters",
                text = "Change Filters",
                callback = function()
                    self:changeFlashcardFilters()
                end,
            },
            {
                id = "flashcard_close",
                text = "Close",
                callback = function()
                    self:closeFlashcardSession()
                end,
            },
        },
    }
end

local function appendCardText(lines, value)
    if value == nil then
        return
    end
    local value_type = type(value)
    if value_type == "string" then
        if value == "" then
            return
        end
    elseif value_type == "number" or value_type == "boolean" then
        value = tostring(value)
    else
        -- Ignore unsupported types (tables/functions/etc.) to avoid concat crashes
        return
    end
    table.insert(lines, value)
end

local function appendSection(lines, heading, body, opts)
    if not body or body == "" then
        return
    end
    opts = opts or {}
    if heading and heading ~= "" then
        table.insert(lines, heading)
    end
    appendCardText(lines, body)
    if not opts.skip_blank_line then
        table.insert(lines, "")
    end
end

function DictSync:buildFlashcardText()
    local session = self.flashcard_session
    if not session or not session.words or #session.words == 0 then
        return "No cards available."
    end
    local idx = session.current_index or 1
    if idx < 1 then idx = 1 end
    if idx > #session.words then idx = #session.words end
    local word = session.words[idx]
    local lines = {
        string.format("Card %d of %d", idx, #session.words),
    }

    if not word then
        table.insert(lines, "Unable to load card data.")
        return table.concat(lines, "\n\n")
    end

    local prompt = string.format("%s (%s)", word.word1 or "—", word.language1 or "—")
    local answer = string.format("%s (%s)", word.word2 or "—", word.language2 or "—")

    table.insert(lines, "────────────────────")
    appendCardText(lines, prompt)

    if session.revealed then
        appendSection(lines, nil, answer, {skip_blank_line = true})
        table.insert(lines, "────────────────────")
        if word.definition and word.definition ~= "" then
            appendSection(lines, nil, word.definition)
        end
        if word.definition2 and word.definition2 ~= "" then
            appendSection(lines, nil, word.definition2)
        end
    end

    return table.concat(lines, "\n\n")
end

function DictSync:updateFlashcardDialog()
    if not self.flashcard_dialog then
        return
    end
    local text = self:buildFlashcardText()
    if self.flashcard_dialog.setCardText then
        self.flashcard_dialog:setCardText(text)
    end
    self:updateFlashcardButtons()
end

function DictSync:updateFlashcardButtons()
    if not self.flashcard_dialog or not self.flashcard_dialog.button_table then
        return
    end
    local session = self.flashcard_session
    if not session then
        return
    end
    local button_table = self.flashcard_dialog.button_table
    local prev_button = button_table:getButtonById("flashcard_prev")
    if prev_button then
        if session.current_index > 1 then
            prev_button:enable()
        else
            prev_button:disable()
        end
        prev_button:refresh()
    end

    local next_button = button_table:getButtonById("flashcard_next")
    if next_button then
        if session.current_index < #session.words then
            next_button:enable()
        else
            next_button:disable()
        end
        next_button:refresh()
    end

    local reveal_button = button_table:getButtonById("flashcard_reveal")
    if reveal_button then
        local label = session.revealed and "Hide Translation" or "Reveal Translation"
        reveal_button:setText(label, reveal_button.width)
        reveal_button:refresh()
    end
end

function DictSync:toggleFlashcardReveal()
    local session = self.flashcard_session
    if not session then
        return
    end
    session.revealed = not session.revealed
    self:updateFlashcardDialog()
end

function DictSync:stepFlashcard(delta)
    local session = self.flashcard_session
    if not session then
        return
    end
    local new_index = math.min(#session.words, math.max(1, session.current_index + delta))
    if new_index ~= session.current_index then
        session.current_index = new_index
        session.revealed = false
        self:updateFlashcardDialog()
    end
end

function DictSync:restartFlashcards(should_shuffle)
    local session = self.flashcard_session
    if not session then
        return
    end
    if should_shuffle then
        self:shuffleFlashcardWords(session.words)
    end
    session.current_index = 1
    session.revealed = false
    self:updateFlashcardDialog()
end

function DictSync:changeFlashcardFilters()
    self:closeFlashcardSession()
    self:showWordsFilterDialog(function()
        local updated_filters = cloneFilters(self.words_filters)
        self:startFlashcardSession(updated_filters)
    end)
end

function DictSync:closeFlashcardSession()
    if self.flashcard_dialog then
        local dialog = self.flashcard_dialog
        self.flashcard_dialog = nil
        UIManager:close(dialog)
    end
    self.flashcard_session = nil
end

function DictSync:onFlashcardDialogClosed()
    self.flashcard_dialog = nil
    self.flashcard_session = nil
end

-- ============================================
-- TEXTS: CHAPTER EXTRACTION & FILE EXPORT
-- ============================================

-- Extract the plain text of the chapter the user is currently reading.
-- Returns (title, text, language_name) on success, or (nil, error_message).
-- Reliable for reflowable documents (EPUB/FB2/...); scanned PDF/DjVu are not supported.
function DictSync:getCurrentChapterText()
    if not (self.ui and self.ui.document) then
        return nil, "Open a book first."
    end

    local document = self.ui.document

    -- Determine the current page.
    local page
    if self.ui.view and self.ui.view.state and self.ui.view.state.page then
        page = self.ui.view.state.page
    else
        local ok_page, p = pcall(function() return document:getCurrentPage() end)
        if ok_page then page = p end
    end
    if not page then
        return nil, "Could not determine the current page."
    end

    -- Chapter text extraction relies on xpointer ranges, which only reflowable
    -- (CRE) documents provide. Bail out gracefully on other formats.
    if type(document.getTextFromXPointers) ~= "function" then
        return nil, "Chapter capture isn't supported for this document format."
    end

    local toc = self.ui.toc
    if not (toc and type(toc.toc) == "table" and #toc.toc > 0) then
        return nil, "This book has no table of contents to locate the chapter."
    end

    -- Find the chapter boundaries: the TOC entry with the greatest page <= current
    -- page is the chapter start; the next entry (by page) is the chapter end.
    local start_entry, end_entry
    for _, entry in ipairs(toc.toc) do
        if entry.page and entry.page <= page then
            if not start_entry or entry.page >= start_entry.page then
                start_entry = entry
            end
        end
    end
    if not start_entry then
        -- Before the first TOC entry: treat the first chapter as the start.
        start_entry = toc.toc[1]
    end
    for _, entry in ipairs(toc.toc) do
        if entry.page and entry.page > start_entry.page then
            if not end_entry or entry.page < end_entry.page then
                end_entry = entry
            end
        end
    end

    if not (start_entry and start_entry.xpointer) then
        return nil, "Chapter capture isn't supported for this document format."
    end

    local end_xpointer = end_entry and end_entry.xpointer  -- nil = to end of book
    local ok_text, text = pcall(function()
        return document:getTextFromXPointers(start_entry.xpointer, end_xpointer)
    end)
    if not ok_text or not text or text == "" then
        return nil, "Could not extract chapter text from this document."
    end

    -- Build a title: "<Book> — <Chapter>".
    local chapter_title = start_entry.title
    local ok_ct, ct = pcall(function() return toc:getTocTitleByPage(page) end)
    if ok_ct and ct and ct ~= "" then
        chapter_title = ct
    end
    local book_title
    local ok_props, props = pcall(function() return document:getProps() end)
    if ok_props and props and props.title and props.title ~= "" then
        book_title = props.title
    end
    local title
    if book_title and chapter_title then
        title = book_title .. " — " .. chapter_title
    else
        title = chapter_title or book_title or "Untitled chapter"
    end

    -- Language name (e.g. "German"); nil lets the cloud side decide.
    local language
    if ok_props and props and props.language then
        language = self:mapLanguageCode(props.language)
    end

    return title, text, language
end

-- Resolve the export directory for cloud texts, creating it if needed.
function DictSync:getTextsExportDir()
    local dir = self.settings and self.settings:readSetting("texts_export_dir")
    if not dir or dir == "" then
        local home
        if G_reader_settings then
            home = G_reader_settings:readSetting("home_dir")
        end
        local base = home or DataStorage:getDataDir()
        dir = base .. "/dictionary_texts"
    end
    local util = require("util")
    pcall(function() util.makePath(dir) end)
    return dir
end

-- Turn a text title into a safe .txt filename.
local function sanitizeFilename(title)
    local name = title or "text"
    name = name:gsub("[/\\\r\n\t]", " ")      -- path separators / control chars
    name = name:gsub('[<>:"|?*]', "")          -- characters illegal on common FSs
    name = name:gsub("%s+", " ")
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then name = "text" end
    if #name > 120 then name = name:sub(1, 120) end
    return name .. ".txt"
end

-- Write a single cloud text row to a .txt file. Returns (path, nil) or (nil, err).
function DictSync:exportTextToFile(text_row)
    if type(text_row) ~= "table" then
        return nil, "Invalid text record"
    end
    local body = text_row.text or ""
    if body == "" then
        return nil, "Text has no content"
    end

    local dir = self:getTextsExportDir()
    local filename = sanitizeFilename(text_row.title)

    -- De-duplicate filenames so we never clobber an existing export.
    local lfs = require("libs/libkoreader-lfs")
    local path = dir .. "/" .. filename
    if lfs.attributes(path, "mode") then
        local base = filename:gsub("%.txt$", "")
        local i = 2
        repeat
            path = string.format("%s/%s (%d).txt", dir, base, i)
            i = i + 1
        until not lfs.attributes(path, "mode")
    end

    local f, err = io.open(path, "w")
    if not f then
        return nil, "Could not write file: " .. tostring(err)
    end
    -- Prefix the title as a heading for readability when opened as a book.
    if text_row.title and text_row.title ~= "" then
        f:write(text_row.title, "\n\n")
    end
    f:write(body)
    f:close()
    return path, nil
end

-- Fetch every cloud text (paging through results) and export each as a file.
function DictSync:exportAllCloudTexts()
    local page = 1
    local exported = 0
    local total = nil
    while true do
        local result, err = self:fetchTextsFromSupabase(page, 50)
        if not result then
            if exported > 0 then
                break  -- partial success; report what we managed
            end
            return nil, err or "Failed to fetch texts"
        end
        total = result.total_count
        for _, row in ipairs(result.texts) do
            local _, export_err = self:exportTextToFile(row)
            if not export_err then
                exported = exported + 1
            end
        end
        if not result.has_next then
            break
        end
        page = page + 1
    end
    return exported, self:getTextsExportDir()
end

-- Save the current chapter to Supabase (menu action).
function DictSync:handleSaveCurrentChapter()
    if not self:ensureAuthed() then return end
    if not (self.ui and self.ui.document) then
        UIManager:show(InfoMessage:new{ text = "Open a book first." })
        return
    end

    local title, text, language = self:getCurrentChapterText()
    if not title then
        -- getCurrentChapterText returns (nil, error_message)
        UIManager:show(InfoMessage:new{ text = text or "Could not read the current chapter." })
        return
    end

    UIManager:show(InfoMessage:new{ text = "Saving chapter…", timeout = 1 })

    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            local ok, msg = self:saveTextToSupabase({
                title = title,
                text = text,
                language = language,
            })
            UIManager:nextTick(function()
                if ok then
                    UIManager:show(InfoMessage:new{
                        text = "Saved chapter to cloud:\n" .. title,
                    })
                else
                    UIManager:show(InfoMessage:new{
                        text = "Failed to save chapter: " .. (msg or "unknown error"),
                    })
                end
            end)
        end)
    end)
end

-- Export every cloud text to the export folder (menu action).
function DictSync:handleExportAllCloudTexts()
    if not self:ensureAuthed() then return end
    UIManager:show(InfoMessage:new{ text = "Exporting cloud texts…", timeout = 1 })

    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            local exported, dir_or_err = self:exportAllCloudTexts()
            UIManager:nextTick(function()
                if not exported then
                    UIManager:show(InfoMessage:new{
                        text = "Failed to export texts: " .. tostring(dir_or_err),
                    })
                elseif exported == 0 then
                    UIManager:show(InfoMessage:new{ text = "No cloud texts to export." })
                else
                    UIManager:show(InfoMessage:new{
                        text = string.format("Exported %d text(s) to:\n%s", exported, dir_or_err),
                    })
                end
            end)
        end)
    end)
end

-- Browse cloud texts in a list; tapping a row exports that text to a file.
function DictSync:showTextsListDialog(page)
    if not self:ensureAuthed() then return end
    page = page or 1

    UIManager:show(InfoMessage:new{ text = "Loading texts…", timeout = 1 })

    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            local result, err = self:fetchTextsFromSupabase(page, 50)
            UIManager:nextTick(function()
                if not result then
                    UIManager:show(InfoMessage:new{
                        text = "Error loading texts: " .. (err or "Unknown error"),
                    })
                    return
                end
                if #result.texts == 0 then
                    UIManager:show(InfoMessage:new{ text = "No cloud texts found." })
                    return
                end

                local Menu = require("ui/widget/menu")
                local items = {}
                for i, row in ipairs(result.texts) do
                    local num = (page - 1) * result.page_size + i
                    local lang = row.language and (" (" .. row.language .. ")") or ""
                    table.insert(items, {
                        text = string.format("%d. %s%s", num, row.title or "Untitled", lang),
                        callback = function()
                            local path, export_err = self:exportTextToFile(row)
                            if path then
                                UIManager:show(InfoMessage:new{ text = "Exported to:\n" .. path })
                            else
                                UIManager:show(InfoMessage:new{
                                    text = "Export failed: " .. (export_err or "unknown error"),
                                })
                            end
                        end,
                    })
                end

                -- Server-side paging controls as list entries.
                if result.has_prev then
                    table.insert(items, {
                        text = "◄ Previous page",
                        callback = function()
                            if self.texts_menu then UIManager:close(self.texts_menu) end
                            self:showTextsListDialog(page - 1)
                        end,
                    })
                end
                if result.has_next then
                    table.insert(items, {
                        text = "Next page ►",
                        callback = function()
                            if self.texts_menu then UIManager:close(self.texts_menu) end
                            self:showTextsListDialog(page + 1)
                        end,
                    })
                end

                local menu = Menu:new{
                    title = string.format("Cloud texts (page %d/%d)",
                        result.page, math.max(result.total_pages, 1)),
                    item_table = items,
                    is_borderless = true,
                    is_popout = false,
                    width = Screen:getWidth(),
                    height = Screen:getHeight(),
                }
                menu.close_callback = function()
                    UIManager:close(menu)
                    self.texts_menu = nil
                end
                self.texts_menu = menu
                UIManager:show(menu)
            end)
        end)
    end)
end

-- Configure the folder cloud texts are exported into.
function DictSync:showTextsExportDirDialog()
    local dialog
    dialog = InputDialog:new{
        title = "Texts export folder",
        input = self.settings:readSetting("texts_export_dir") or self:getTextsExportDir(),
        description = "Folder where pulled cloud texts are saved as .txt files.",
        buttons = {
            {
                {
                    text = "Cancel",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = "Save",
                    is_enter_default = true,
                    callback = function()
                        local dir = dialog:getInputText()
                        self.settings:saveSetting("texts_export_dir", dir)
                        UIManager:close(dialog)
                        UIManager:show(InfoMessage:new{ text = "Export folder saved:\n" .. dir })
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Add to main menu
function DictSync:addToMainMenu(menu_items)
    logger.info("Lingueez: addToMainMenu called")
    menu_items.lingueez = {
        text = "Lingueez",
        sorting_hint = "tools",
        sub_item_table = {
            {
                text_func = function()
                    if self:isCustomServer() then
                        return "Account: custom server"
                    elseif self:isAuthed() then
                        return "Account: " .. (self.settings:readSetting("auth_user_email") or "signed in")
                    end
                    return "Account: sign in"
                end,
                callback = function()
                    self:showConfigDialog()
                end,
            },
            {
                text = "Configure",
                callback = function()
                    self:showConfigDialog()
                end,
            },
            {
                text = "View My Words",
                callback = function()
                    self.words_filters = {}  -- Reset filters
                    self:showWordsListDialog(1, {})
                end,
            },
            {
                text = "Flashcards",
                callback = function()
                    self:showFlashcardsLauncher()
                end,
            },
            {
                text = "Save current chapter as text",
                callback = function()
                    self:handleSaveCurrentChapter()
                end,
            },
            {
                text = "Cloud texts",
                sub_item_table = {
                    {
                        text = "Export all to folder",
                        keep_menu_open = true,
                        callback = function()
                            self:handleExportAllCloudTexts()
                        end,
                    },
                    {
                        text = "Browse & export…",
                        callback = function()
                            self:showTextsListDialog(1)
                        end,
                    },
                    {
                        text = "Set export folder",
                        keep_menu_open = true,
                        callback = function()
                            self:showTextsExportDirDialog()
                        end,
                    },
                },
            },
            {
                text = "About",
                keep_menu_open = true,
                callback = function()
                    local meta = self.meta or {}
                    UIManager:show(InfoMessage:new{
                        text = (meta.fullname or "Lingueez")
                            .. "\n\nVersion " .. (meta.version or "?")
                            .. "  ·  Build " .. (meta.build or "?"),
                    })
                end,
            },
        },
    }
end

-- Hook into word selection/highlight dialog
function DictSync:init()
    logger.info("Lingueez: init() called")
    
    -- Load our own _meta.lua
    -- The folder name is lingueez.koplugin; the internal plugin id is "lingueez"
    local DataStorage = require("datastorage")
    local T = require("ffi/util").template

    -- Try the actual folder name first
    local PLUGIN_DIR = T("%1/plugins/lingueez.koplugin/", DataStorage:getDataDir())
    local META_FILE_PATH = PLUGIN_DIR .. "_meta.lua"
    
    logger.info("Lingueez: Looking for _meta.lua at: " .. META_FILE_PATH)
    
    local ok, meta = pcall(dofile, META_FILE_PATH)
    if ok and meta then
        self.meta = meta
        logger.info("Lingueez: _meta.lua loaded successfully")
    else
        -- Fallback: derive from the plugin id (in case the folder was renamed)
        local alt_path = T("%1/plugins/%2.koplugin/_meta.lua", DataStorage:getDataDir(), self.name)
        logger.info("Lingueez: Trying alternative path: " .. alt_path)
        local ok2, meta2 = pcall(dofile, alt_path)
        if ok2 and meta2 then
            self.meta = meta2
            logger.info("Lingueez: _meta.lua loaded from alternative path")
        else
            -- Last resort: use default meta
            logger.warn("Lingueez: Failed to load _meta.lua from: " .. META_FILE_PATH .. " and " .. alt_path)
            logger.warn("Lingueez: Error: " .. tostring(meta or meta2))
            self.meta = {
                name = "lingueez",
                fullname = "Lingueez",
                description = "Save words to your Lingueez vocabulary with automatic translation",
                version = "1.0.0",
            }
            logger.info("Lingueez: Using default meta")
        end
    end
    
    -- Check if we're in a document context
    if not self.ui then
        logger.warn("Lingueez: No UI context available")
        return
    end
    
    -- Init settings
    self.settings = LuaSettings:open(self.settings_file)
    logger.info("Lingueez: Settings initialized")
    
    -- Load .env file if it exists (do this early so credentials are available)
    self:loadEnvFile()
    
    -- Register menu to main menu (under "tools")
    -- Make our menu appear in tools section
    local menu_order = require("ui/elements/reader_menu_order")
    if menu_order and menu_order.tools then
        table.insert(menu_order.tools, 1, "lingueez")
    end
    
    if self.ui.menu then
        self.ui.menu:registerToMainMenu(self) -- then self:addToMainMenu will be called
        logger.info("Lingueez: Menu registered")
    else
        logger.warn("Lingueez: No menu available")
    end
    
    -- Add button to highlight dialog (word selection popup)
    if self.ui.highlight then
        self.ui.highlight:addToHighlightDialog("lingueez", function(_reader_highlight_instance)
            return {
                text = "Save to Lingueez",
                callback = function()
                    local selected_text = _reader_highlight_instance.selected_text
                    if selected_text and selected_text.text then
                        NetworkMgr:runWhenOnline(function()
                            Trapper:wrap(function()
                                self:handleWordSelection(selected_text.text)
                            end)
                        end)
                    end
                end,
            }
        end)
        logger.info("Lingueez: Highlight dialog button added")
    else
        logger.warn("Lingueez: No highlight available")
    end
    
    logger.info("Lingueez plugin initialized successfully")
end

-- Add button to dictionary popup (like assistant plugin)
function DictSync:onDictButtonsReady(dict_popup, dict_buttons)
    if not dict_popup or not dict_popup.word then
        return
    end
    
    -- Add "Save to Lingueez" button to dictionary popup
    -- Insert as a row (array of buttons) at position 2, like assistant plugin
    local plugin_buttons = {
        {
            id = "lingueez_save",
            text = "Save to Lingueez",
            font_bold = true,
            callback = function()
                NetworkMgr:runWhenOnline(function()
                    Trapper:wrap(function()
                        self:handleWordSelection(dict_popup.word)
                    end)
                end)
            end,
        }
    }
    
    if #dict_buttons > 1 then
        table.insert(dict_buttons, 2, plugin_buttons) -- add to the second row of buttons
    else
        table.insert(dict_buttons, plugin_buttons) -- add to end if not enough rows
    end
end

return DictSync
