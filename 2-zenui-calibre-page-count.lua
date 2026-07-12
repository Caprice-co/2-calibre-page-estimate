--[[
    2-zenui-calibre-page-count.lua

    Standalone KOReader user patch. Adds a page-count estimate, sourced
    from Calibre's metadata, for KEPUB/EPUB/FB2 books that have never been
    opened in KOReader and have no cached page count yet -- covers Zen
    UI's cover/list page badges (mosaic and list, main library and
    Author/Series/Tags navigation), and anything else in KOReader that
    reads a book's page count via BookInfoManager.

    This does NOT modify any Zen UI (or CoverBrowser) file -- it's a
    single, self-contained file dropped into koreader/patches/, so it
    survives Zen UI updates and CoverBrowser updates alike. It works by
    wrapping the shared BookInfoManager:getBookInfo() function that both
    plugins already call: when the real lookup comes back with no page
    count, this fills one in before handing the result back, so from the
    caller's point of view a number was just... there. Nothing else about
    that result is touched.

    INSTALL: put this file in koreader/patches/ and restart KOReader.

    REQUIRES: a Calibre library with a #words and/or #pages custom column
    (e.g. populated by the "Count Pages" Calibre plugin), synced to the
    device as metadata.calibre. Falls back to a #pages column embedded in
    the book's own internal .opf if metadata.calibre has neither (same
    place Project: Title reads its count from) -- EPUB only, and requires
    `unzip` to be available.

    Source priority, cheapest/most-accurate first:
      1. #words custom column -> estimated stable page count, using the
         chars-per-page divisor set below (CHARS_PER_PAGE).
      2. #pages custom column, used as-is (not derived from
         CHARS_PER_PAGE -- it's someone else's page count, often the
         device's own pagination via Count Pages).
      3. #pages embedded inside the book's own .opf.
]]

local userpatch = require("userpatch")

------------------------------------------------------------------------------
-- Configuration -- edit these two to taste.
------------------------------------------------------------------------------

-- Match this to your KOReader reader setting for "characters per page" in
-- stable page number mode. Only affects the #words-based estimate (source 1
-- above).
local CHARS_PER_PAGE = 1500

-- Average characters per word, including the trailing space -- the
-- conventional rough estimate (~5 letters + 1 space) used to turn a word
-- count into an estimated character count for source 1 above.
local CHARS_PER_WORD = 6

------------------------------------------------------------------------------
-- Calibre metadata reading (metadata.calibre + embedded OPF)
------------------------------------------------------------------------------

local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

-- cache[root_dir] = { mtime = <metadata.calibre mtime>, by_lpath = { [lpath] = {words=?, pages=?} } }
local metadata_cache = {}

local function findMetadataCalibre(dir, max_levels)
    max_levels = max_levels or 6
    local cur = dir
    for _ = 1, max_levels do
        local candidate = cur .. "/metadata.calibre"
        if lfs.attributes(candidate, "mode") == "file" then
            return candidate, cur
        end
        local parent = cur:match("^(.*)/[^/]+$")
        if not parent or parent == cur then break end
        cur = parent
    end
    return nil, nil
end

local function readCustomColumn(entry, column)
    local um = entry.user_metadata
    if type(um) == "table" and type(um[column]) == "table" then
        local v = um[column]["#value#"]
        if type(v) == "number" then
            return v
        end
    end
    return nil
end

local function loadMetadataIndex(meta_path, root)
    local attr = lfs.attributes(meta_path)
    local mtime = attr and attr.modification
    local cached = metadata_cache[root]
    if cached and cached.mtime == mtime then
        return cached.by_lpath
    end

    local f = io.open(meta_path, "r")
    if not f then
        logger.warn("zenui-calibre-page-estimate: could not open", meta_path)
        return nil
    end
    local content = f:read("*a")
    f:close()

    local ok, data = pcall(json.decode, content)
    if not ok or type(data) ~= "table" then
        logger.warn("zenui-calibre-page-estimate: failed to parse", meta_path)
        return nil
    end

    local by_lpath = {}
    for _, entry in ipairs(data) do
        local lpath = entry.lpath
        if lpath then
            by_lpath[lpath] = {
                words = readCustomColumn(entry, "#words"),
                pages = readCustomColumn(entry, "#pages"),
            }
        end
    end

    metadata_cache[root] = { mtime = mtime, by_lpath = by_lpath }
    return by_lpath
end

local function getCalibreColumns(filepath)
    local dir = filepath:match("^(.*)/[^/]+$")
    if not dir then return nil end
    local meta_path, root = findMetadataCalibre(dir)
    if not meta_path then return nil end
    local by_lpath = loadMetadataIndex(meta_path, root)
    if not by_lpath then return nil end
    local lpath = filepath:sub(#root + 2) -- strip "root/"
    return by_lpath[lpath]
end

local function estimatePagesFromWords(words)
    if not words or words <= 0 then return nil end
    local est_chars = words * CHARS_PER_WORD
    local pages = math.floor(est_chars / CHARS_PER_PAGE + 0.5)
    if pages < 1 then pages = 1 end
    return pages
end

-- Last resort: #pages custom column embedded inside the book's own .opf
-- (EPUB only, requires `unzip`). Same place Project: Title reads its
-- count from.
local function getEmbeddedOpfPages(filepath)
    local lower = filepath:lower()
    if not lower:match("%.epub$") and not lower:match("%.kepub%.epub$") then
        return nil
    end

    local locate_cmd = "unzip -lqq \"" .. filepath .. "\" \"*.opf\""
    local opf_file = nil
    local list_out = io.popen(locate_cmd)
    if list_out then
        local line = list_out:read()
        if line then
            opf_file = line:match("(%S+%.opf)%s*$")
        end
        list_out:close()
    end
    if not opf_file then return nil end

    local expand_cmd = "unzip -p \"" .. filepath .. "\" \"" .. opf_file .. "\""
    local dump = io.popen(expand_cmd)
    if not dump then return nil end

    local found_pages_key = false
    local found_value = nil
    for line in dump:lines() do
        if found_pages_key then
            found_value = line:match("\"#value#\": (%d+),")
            if found_value then break end
            if line:match("\"category_sort\":") then break end
        else
            if line:match("#pages") then
                found_pages_key = true
                found_value = line:match("&quot;#value#&quot;: (%d+),")
                if found_value then break end
            end
        end
    end
    dump:close()

    local n = found_value and tonumber(found_value)
    if n and n > 0 then return n end
    return nil
end

-- Try, in order: #words (estimated) -> #pages column (as-is) -> embedded
-- OPF #pages (as-is). Returns the first hit, or nil.
local function getPageEstimate(filepath)
    local cols = getCalibreColumns(filepath)

    if cols and cols.words then
        local est = estimatePagesFromWords(cols.words)
        if est then return est end
    end

    if cols and cols.pages and cols.pages > 0 then
        return cols.pages
    end

    local ok, embedded = pcall(getEmbeddedOpfPages, filepath)
    if ok and embedded then
        return embedded
    end

    return nil
end

------------------------------------------------------------------------------
-- The actual patch: wrap BookInfoManager:getBookInfo
------------------------------------------------------------------------------

local function patchBookInfoManager(_plugin)
    local ok, BookInfoManager = pcall(require, "bookinfomanager")
    if not ok or not BookInfoManager then
        logger.warn("zenui-calibre-page-estimate: bookinfomanager not available")
        return
    end
    if BookInfoManager._zenui_calibre_page_estimate_patched then
        return
    end
    BookInfoManager._zenui_calibre_page_estimate_patched = true

    local orig_getBookInfo = BookInfoManager.getBookInfo
    BookInfoManager.getBookInfo = function(self, filepath, get_cover)
        local bi = orig_getBookInfo(self, filepath, get_cover)
        if bi and bi.pages and bi.pages > 0 then
            return bi -- already has a real page count, leave it alone
        end
        if type(filepath) ~= "string" or filepath == "" then
            return bi
        end
        local ok2, est = pcall(getPageEstimate, filepath)
        if ok2 and est then
            bi = bi or {}
            bi.pages = est
        end
        return bi
    end
end

userpatch.registerPatchPluginFunc("coverbrowser", patchBookInfoManager)
