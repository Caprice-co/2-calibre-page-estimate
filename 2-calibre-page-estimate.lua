--[[
    2-calibre-page-estimate.lua

    Standalone KOReader user patch. Adds a page count for EPUB/FB2 books
    that have never been opened in KOReader and have no cached page count
    yet -- covers Zen UI's cover/list page badges (mosaic and list, main
    library and Author/Series/Tags navigation), and anything else in
    KOReader that reads a book's page count via BookInfoManager.

    Where possible this is a REAL publisher page count, read from the
    book itself (see tier 0 below); otherwise it falls back to an
    estimate or a count sourced from Calibre's metadata.

    This does NOT modify any Zen UI (or CoverBrowser) file -- it's a
    single, self-contained file dropped into koreader/patches/, so it
    survives Zen UI updates and CoverBrowser updates alike. It works by
    wrapping the shared BookInfoManager:getBookInfo() function that both
    plugins already call: when the real lookup comes back with no page
    count, this fills one in before handing the result back, so from the
    caller's point of view a number was just... there. Nothing else about
    that result is touched.

    INSTALL: put this file in koreader/patches/ and restart KOReader.

    REQUIRES: `unzip` available on the device (used for every tier
    below). Tiers 1-3 additionally need a Calibre library with a #words
    and/or #pages custom column (e.g. populated by the "Count Pages" or 
    other Calibre plugins), synced to the device as metadata.calibre.

    Source priority, most-authoritative first:
      0. Publisher page numbers, read directly from the book's own EPUB3
         "page-list" nav (or EPUB2 NCX <pageList>), when present. This is
         a real page count, not an estimate -- most ordinary ebooks don't
         have this, but textbooks, academic titles, and EPUBs produced to
         preserve print pagination often do. Works with zero Calibre
         setup, since it only reads the book file itself.
      1. #words custom column in metadata.calibre -> estimated stable page
         count (chars-per-page divisor, configurable below).
      2. #pages custom column in metadata.calibre (used as-is).
      3. #pages embedded in the book's own internal .opf

]]

local userpatch = require("userpatch")

------------------------------------------------------------------------------
-- Configuration -- edit these to taste.
------------------------------------------------------------------------------

-- Set to false if you use KOReader's RAW/rendered page count (not stable
-- page numbers). Tier 1 below (the #words -> estimate math) targets the
-- stable page count specifically -- CHARS_PER_PAGE only means something
-- if you have that mode on. With stable page numbers off, a raw page
-- count depends on your current font/margins and can change any time, so
-- there's no equivalent constant to tune tier 1 against; turning it off
-- here skips straight to tiers 0/2/3, which are all real numbers from
-- somewhere else (the book's own publisher pagination, or a Calibre/
-- device page count) rather than KOReader-page-mode-dependent estimates.
local ENABLE_WORDS_ESTIMATE = true

-- Match this to your KOReader reader setting for "characters per page" in
-- stable page number mode. Only affects the #words-based estimate (source 1
-- above), and only when ENABLE_WORDS_ESTIMATE is true.
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
        logger.warn("calibre-page-estimate: could not open", meta_path)
        return nil
    end
    local content = f:read("*a")
    f:close()

    local ok, data = pcall(json.decode, content)
    if not ok or type(data) ~= "table" then
        logger.warn("calibre-page-estimate: failed to parse", meta_path)
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

------------------------------------------------------------------------------
-- Tier 0: publisher page numbers, read straight from the book itself
------------------------------------------------------------------------------
--
-- EPUB3 lets a book declare a "page-list" nav (a mapping from locations in
-- the text to the actual page numbers of a print edition), and EPUB2's
-- older NCX format has an equivalent <pageList>. When present, this is a
-- REAL page count -- the one you'd cite in a reference -- not an estimate.
-- Not all books have this (most ordinary ebooks don't), but when it's
-- there it's strictly better than anything derived from Calibre metadata,
-- so it's checked first.
--
-- This requires unzipping the book and reading its manifest + nav/ncx
-- file, which is the most expensive check here -- so results (including
-- "checked, found nothing") are cached per file path + mtime, so it only
-- costs anything on the first check per book per KOReader session.

-- cache[filepath] = { mtime = <book file mtime>, pages = N | false }
local page_list_cache = {}

local function unzipRead(filepath, entry_path)
    local cmd = "unzip -p \"" .. filepath .. "\" \"" .. entry_path .. "\""
    local out = io.popen(cmd)
    if not out then return nil end
    local content = out:read("*a")
    out:close()
    if not content or content == "" then return nil end
    return content
end

-- Resolve an href found inside the OPF (relative to the OPF's own
-- location within the zip, per the EPUB spec) against the OPF's path.
local function resolveOpfRelative(opf_path, href)
    href = href:gsub("#.*$", "") -- drop any fragment
    if href:match("^/") then return href:sub(2) end
    local opf_dir = opf_path:match("^(.*)/[^/]+$")
    local combined = opf_dir and (opf_dir .. "/" .. href) or href
    -- Collapse "foo/../" segments.
    while true do
        local new_combined, n = combined:gsub("[^/]+/%.%./", "", 1)
        if n == 0 then break end
        combined = new_combined
    end
    return combined
end

-- Highest plain-arabic-numeral label inside a page-list/pageList block --
-- roman-numeral front matter (i, ii, iii...) is intentionally ignored, so
-- what's returned is the last "real" page number, matching how a print
-- page count is normally reported.
local function maxNumericLabel(block, label_pattern)
    local max_page = nil
    for label in block:gmatch(label_pattern) do
        local n = tonumber(label:match("^%s*(%d+)%s*$"))
        if n and (not max_page or n > max_page) then
            max_page = n
        end
    end
    return max_page
end

local function getPublisherPageCount(filepath)
    local lower = filepath:lower()
    if not lower:match("%.epub$") and not lower:match("%.kepub%.epub$") then
        return nil
    end

    local attr = lfs.attributes(filepath)
    local mtime = attr and attr.modification
    local cached = page_list_cache[filepath]
    if cached and cached.mtime == mtime then
        return cached.pages or nil
    end

    local result = nil
    pcall(function()
        local locate_cmd = "unzip -lqq \"" .. filepath .. "\" \"*.opf\""
        local opf_file = nil
        local list_out = io.popen(locate_cmd)
        if list_out then
            local line = list_out:read()
            if line then opf_file = line:match("(%S+%.opf)%s*$") end
            list_out:close()
        end
        if not opf_file then return end

        local opf_content = unzipRead(filepath, opf_file)
        if not opf_content then return end

        -- EPUB3: <item ... properties="...nav..." href="...">
        local nav_href = nil
        for item_tag in opf_content:gmatch("<item%s[^>]*>") do
            if item_tag:match('properties%s*=%s*"[^"]-nav[^"]-"') then
                nav_href = item_tag:match('href%s*=%s*"([^"]+)"')
                if nav_href then break end
            end
        end
        if nav_href then
            local nav_path = resolveOpfRelative(opf_file, nav_href)
            local nav_content = unzipRead(filepath, nav_path)
            if nav_content then
                local block = nav_content:match('<nav[^>]-epub:type%s*=%s*"page%-list"[^>]*>(.-)</nav>')
                if block then
                    result = maxNumericLabel(block, "<a[^>]*>([^<]+)</a>")
                end
            end
        end

        -- EPUB2 fallback: <item ... media-type="application/x-dtbncx+xml" href="...">
        if not result then
            local ncx_href = nil
            for item_tag in opf_content:gmatch("<item%s[^>]*>") do
                if item_tag:match('media%-type%s*=%s*"application/x%-dtbncx%+xml"') then
                    ncx_href = item_tag:match('href%s*=%s*"([^"]+)"')
                    if ncx_href then break end
                end
            end
            if ncx_href then
                local ncx_path = resolveOpfRelative(opf_file, ncx_href)
                local ncx_content = unzipRead(filepath, ncx_path)
                if ncx_content then
                    local block = ncx_content:match("<pageList[^>]*>(.-)</pageList>")
                    if block then
                        result = maxNumericLabel(block, "<text>([^<]+)</text>")
                    end
                end
            end
        end
    end)

    page_list_cache[filepath] = { mtime = mtime, pages = result or false }
    return result
end

-- Try, in order: publisher page-list (real number, from the book itself)
-- -> #words (estimated) -> #pages column (as-is) -> embedded OPF #pages
-- (as-is). Returns the first hit, or nil.
local function getPageEstimate(filepath)
    local ok0, publisher_pages = pcall(getPublisherPageCount, filepath)
    if ok0 and publisher_pages then
        return publisher_pages
    end

    local cols = getCalibreColumns(filepath)

    if ENABLE_WORDS_ESTIMATE and cols and cols.words then
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
        logger.warn("calibre-page-estimate: bookinfomanager not available")
        return
    end
    if BookInfoManager._calibre_page_estimate_patched then
        return
    end
    BookInfoManager._calibre_page_estimate_patched = true

    local orig_getBookInfo = BookInfoManager.getBookInfo
    BookInfoManager.getBookInfo = function(self, filepath, get_cover)
        local bi = orig_getBookInfo(self, filepath, get_cover)
        if bi and bi.pages and bi.pages > 0 then
            return bi -- already has a real page count, leave it alone
        end
        if type(filepath) ~= "string" or filepath == "" then
            return bi
        end
        -- Safeguard: only inject an estimate for books that have never been
        -- opened (no .sdr sidecar at all). A book with a sidecar has real
        -- reading progress/statistics, and some callers (e.g. a "time left
        -- in book" calculation) may read this same .pages field expecting
        -- it to be the document's true raw page count -- if it were our
        -- estimate instead, that math would be quietly wrong. An unopened
        -- book has no such calculation depending on it, so it's always
        -- safe to fill in there. (Zen UI 2.4.4+ already guards against
        -- this on its own end by preferring the reading-statistics
        -- database's page count for time-left math instead of this field
        -- -- this check just makes the patch safe on its own, regardless
        -- of what's reading from it.)
        local ok_ds, DocSettings = pcall(require, "docsettings")
        if ok_ds and DocSettings and DocSettings:hasSidecarFile(filepath) then
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
