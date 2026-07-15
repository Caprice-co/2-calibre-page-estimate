# Calibre Page Count Estimate Patch - *Updated v5*

## Applies to Zen UI, Bookshelf Plugin, Simple UI 

A standalone KOReader user patch that shows a page-count estimate for
KEPUB/EPUB/FB2 books that haven't been opened yet - sourced from Calibre's metadata -
anywhere UI would otherwise show nothing: mosaic
covers, list rows, and the Author/Series/Tags navigation views.

<img width="2356" height="800" alt="Before and After" src="https://github.com/user-attachments/assets/1c73f5e5-1a97-4438-ab6e-82035a1c6dbf" />
<img width="2356" height="800" alt="Untitled" src="https://github.com/user-attachments/assets/9d13d47a-0c4c-43af-8a0f-17a0d767905d" />


# What it does:

This patch does the same job as directly editing `browser_page_count.lua` /
`browser_list_item_layout.lua`, but without touching them. It's a single
file in `koreader/patches/`, which KOReader loads and applies at startup,
completely separately from the plugin folder. That means:

- Updating or reinstalling UI or plugings won't remove it.
- It doesn't matter which UI or plugings version you're running.
- Uninstalling this patch is just deleting one file.

It works by wrapping `BookInfoManager:getBookInfo()` - the shared
function CoverBrowser already call to look up a book's page
count. When the real lookup comes back empty, this quietly fills in an
estimate before handing the result back. Everything downstream just sees
a number where it used to see nothing; no other code has to know this
patch exists.


## How the estimate is chosen

In order, first hit wins:

0. **Publisher page numbers, from the book itself.** EPUB3 lets a book
   declare a "page-list" nav - a mapping from locations in the text to
   the actual page numbers of a specific print edition (the ones you'd
   cite in a reference). EPUB2's older NCX format has an equivalent
   `<pageList>`. When present, this is a *real* page count, not an
   estimate. Most ordinary ebooks don't have this - it shows up mostly
   in textbooks, academic titles, and EPUBs specifically produced to
   preserve print pagination - but when it's there, nothing else here
   beats it. Doesn't need Calibre or `metadata.calibre` at all, since it
   only reads the book file. This is also the slowest check (it unzips
   the book), so results are cached per file + modification time, so it
   only costs anything the first time each book is checked in a session.

1. **`#words` column** -> converted to an estimated page count using
   `words × CHARS_PER_WORD ÷ CHARS_PER_PAGE`. This is the one meant to
   land close to what you'll see once you actually open the book.

2. **`#pages` column** -> used directly, no math. This is *not*
   guaranteed to match your `CHARS_PER_PAGE` setting - it's whatever
   that column holds (often a source device's own pagination).

3. **Embedded `#pages` in the book's `.opf`** -> used directly, same as
   above. Slowest of the three (unzips the book), only tried if the first
   two came up empty.

If none of the four have anything for a book, nothing changes - same as
if this patch weren't installed.

## Safety: never touches books you've already opened

This patch only fills in a page count for books that have **never been
opened** (no `.sdr` sidecar exists yet). If a book has a sidecar, this
patch leaves `BookInfoManager`'s result untouched, even if its `.pages`
field happens to be empty.

This matters because some code elsewhere (a "time left in book"
calculation, for instance) may read that same `.pages` field expecting
it to be the document's true raw page count. Since only opened books have
reading progress/statistics for that kind of calculation to apply to,
gating on "never opened" means this patch can never end up feeding an
estimate into math that expects a real number - regardless of any plugin, 
happens to be reading it.

# Requirements for tiers 1-3

Your Calibre library needs at least one of `#words` or `#pages` custom
columns, synced to the device as `metadata.calibre` (e.g. via the Calibre plugin). 
Tier 0 has no such requirement.
   
**usually those custom columns are filled with a "Count Pages" Calibre plugin or similar**

# Configuration

Three constants near the top of the file:

```lua
local ENABLE_WORDS_ESTIMATE = true
local CHARS_PER_PAGE = 1500
local CHARS_PER_WORD = 6
```

- `ENABLE_WORDS_ESTIMATE`: set to `false` if you use KOReader's **raw**
  (rendered) page count rather than stable page numbers. Tier 1 (the
  `#words`-based estimate) specifically targets stable page counts --
  `CHARS_PER_PAGE` doesn't have a meaningful equivalent for raw counts,
  since those shift with your current font/margins. Turning this off
  skips tier 1 entirely and goes straight to tiers 0/2/3, which are all
  real numbers from elsewhere (the book's own publisher pagination, or a
  Calibre/device page count) rather than a KOReader-page-mode-dependent
  estimate, so they're meaningful either way.

- `CHARS_PER_PAGE`: match this to your KOReader reader setting for
  "characters per page" under stable page number mode. Only affects tier 1,
  and only when `ENABLE_WORDS_ESTIMATE` is true.

- `CHARS_PER_WORD`: average characters per word including the trailing
  space, used to turn a word count into an estimated character count.
  `6` is a conventional rough default (~5 letters + 1 space); adjust if
  you find the estimate consistently running high or low.

**Edit the numbers directly in the file on your device (or on your
computer before copying it over), save, restart KOReader to apply.**

To edit the numbers you can just:

- Connect the device via USB.
- Open koreader/patches/2-calibre-page-estimate.lua directly in any text editor (on your computer).
- Find these three lines near the top and change the numbers.
- Save, eject the Kobo, restart KOReader to apply.

## If you still have the earlier patches installed

Update to avoid bugs.


# Install

1. Create a `patches` folder inside your `koreader` folder, if you don't
   have one already (same level as `koreader/settings.reader.lua`).
2. Copy `2-calibre-page-estimate.lua` into it.
3. Restart KOReader.

No other setup needed, beyond having a Calibre library with the metadata
described below.


## Uninstall

Delete `2-calibre-page-estimate.lua` from `koreader/patches/` and
restart.

## NOTE for Bookshelf Plugin 

This Patch is an alternative because Bookshelf Plugin has in-build feature that recognises number of pages and applying those to the cover badges. 
If you include page number in p(xxx) format in the name of the book - for example: 
Dark Moon Defender - Sharon Shinn - p(917) - the bookshelf will display pages on its own. 

One way to do that you need is set up calibre setting to "send to device" in this format:

{title} - {authors} - p({#pages})  - prior to sending the book to device. Or changing names manually.
