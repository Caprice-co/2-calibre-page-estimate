# Calibre Page Count Estimate Patch - for Zen UI, Bookshelf Plugin and Simple UI 

A standalone KOReader user patch that shows a page-count estimate for
KEPUB/EPUB/FB2 books that haven't been opened yet -- sourced from Calibre's metadata --
anywhere UI would otherwise show nothing: mosaic
covers, list rows, and the Author/Series/Tags navigation views.

<img width="2356" height="800" alt="Before and After" src="https://github.com/user-attachments/assets/1c73f5e5-1a97-4438-ab6e-82035a1c6dbf" />
<img width="2356" height="800" alt="Untitled" src="https://github.com/user-attachments/assets/9d13d47a-0c4c-43af-8a0f-17a0d767905d" />


## What it does:

This patch does the same job as directly editing `browser_page_count.lua` /
`browser_list_item_layout.lua`, but without touching them. It's a single
file in `koreader/patches/`, which KOReader loads and applies at startup,
completely separately from the plugin folder. That means:

- Updating or reinstalling UI or plugings won't remove it.
- It doesn't matter which UI or plugings version you're running.
- Uninstalling this patch is just deleting one file.

It works by wrapping `BookInfoManager:getBookInfo()` -- the shared
function CoverBrowser already call to look up a book's page
count. When the real lookup comes back empty, this quietly fills in an
estimate before handing the result back. Everything downstream just sees
a number where it used to see nothing; no other code has to know this
patch exists.


# Requirements

Your Calibre library needs at least one of:

- A **`#words`** custom column (word count) -- gives the closest estimate
  to KOReader's own "stable page number."
- A **`#pages`** custom column (any page count) -- used as a fallback,
  as-is.

   **usually those custom columns are filled with a "Count Pages" Calibre plugin**

...synced to the device as `metadata.calibre` (e.g. via the Calibre plugin,
or however your workflow already gets `metadata.calibre` 
onto the device). If neither column has data for a given book, the patch 
falls back to a `#pages` value embedded inside that book's own internal
`.opf` file, if one happens to be there (same place the Project: Title 
plugin reads its count from) -- EPUB only, and needs `unzip` available 
on the device.

If none of the three sources have anything for a book, nothing changes --
same as if this patch weren't installed.

## How the estimate is chosen

In order, first hit wins:

1. **`#words` column** -> converted to an estimated page count using
   `words × CHARS_PER_WORD ÷ CHARS_PER_PAGE`. This is the one meant to
   land close to what you'll see once you actually open the book.
2. **`#pages` column** -> used directly, no math. This is *not*
   guaranteed to match your `CHARS_PER_PAGE` setting -- it's whatever
   that column holds (often a source device's own pagination).
3. **Embedded `#pages` in the book's `.opf`** -> used directly, same as
   above. Slowest of the three (unzips the book), only tried if the first
   two came up empty.

# Configuration

Two constants near the top of the file:

```lua
local CHARS_PER_PAGE = 1500
local CHARS_PER_WORD = 6
```

- `CHARS_PER_PAGE`: match this to your KOReader reader setting for
  "characters per page" under stable page number mode. Only affects the
  `#words`-based estimate (source 1 above).
- `CHARS_PER_WORD`: average characters per word including the trailing
  space, used to turn a word count into an estimated character count.
  `6` is a conventional rough default (~5 letters + 1 space); adjust if
  you find the estimate consistently running high or low.

To edit the numbers you can just:

- Connect the device via USB.
- Open koreader/patches/2-calibre-page-count.lua directly in any text editor (on your computer).
- Find these two lines near the top and change the numbers.

Save, eject the Kobo, restart KOReader to apply.

## If you don't want to change anything in the code, and don't want the patch
to calculate pages based on words, make sure the column 
**#words** remains empty, then it will apply **#pages** column only.**

# Install

1. Create a `patches` folder inside your `koreader` folder, if you don't
   have one already (same level as `koreader/settings.reader.lua`).
2. Copy `2-calibre-page-count.lua` into it.
3. Restart KOReader.

No other setup needed, beyond having a Calibre library with the metadata
described below.


## Uninstall

Delete `2-calibre-page-count.lua` from `koreader/patches/` and
restart.


