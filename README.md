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

**CoverBrowser must be enabled.**

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






# Troubleshooting

This patch shows a page count for books you haven't opened yet, sourced
from four different places, roughly in order of how likely a given book
is to have the data at all.
Because of that, "it works for some books but not others" is often
**expected behavior**, not a bug — this guide walks through how to tell
the difference.




## Step 0: confirm the patch actually loaded

Before troubleshooting individual books, rule out an installation
problem:

1. **File location and name.** It must be exactly
   `koreader/patches/2-calibre-page-estimate.lua` — same folder as
   `koreader/settings.reader.lua`, filename unchanged (the `2-` prefix
   matters, it controls when KOReader runs the patch).

2. **Full restart.** Not just closing and reopening a book — fully close
   and relaunch KOReader (or reboot the device) after adding or editing
   the file.

3. **CoverBrowser must be enabled.** This patch activates when the
   CoverBrowser plugin loads (`userpatch.registerPatchPluginFunc
   ("coverbrowser", ...)`). If CoverBrowser is disabled in KOReader's
   plugin settings, this patch never runs at all, and neither does
   whatever UI (Zen UI, Bookshelf, Project: Title, etc.) is showing page
   counts in the first place — check that first if literally nothing
   works, on any book.

4. **The UI's own page-count display must be turned on.** This patch
   only fills in data — it doesn't make Zen UI (or whichever plugin)
   show a page count if that feature is itself switched off. Check your
   file browser / library settings for a "show page count" toggle.

5. **Check for a Lua error.** If the file has been hand-edited (e.g. the
   config constants at the top) and a typo was introduced, KOReader
   would fail to load *this file* silently — the page-count feature
   would just act as if the patch weren't installed, with no crash and
   no visible error in the UI. Check `koreader/crash.log` (or the
   in-app log viewer) for anything mentioning
   `calibre-page-estimate` or a Lua syntax error around the time
   of the last restart.

If all five check out and *no* book shows anything, move to the "not
working for any book" section below. If it works for *some* books,
skip to "works for some books, not others."






## "Not working for any book at all"

1. **Does `metadata.calibre` exist on the device, and where?** This
   patch looks for it by walking upward from each book's own folder
   (checking the book's folder, then its parent, and so on, several
   levels up) until it finds a file literally named `metadata.calibre`.
   If your Calibre sync process places it somewhere the books aren't
   nested under, none of the file-based tiers (1, 2) can find it. It's
   usually at the root of wherever your books folder lives (e.g.
   `/mnt/onboard/metadata.calibre` on a Kobo).

2. Is unzip available on the device? Tiers 0 and 3 both shell out
   to unzip; tiers 1 and 2 don't (they only read metadata.calibre
   with plain file I/O). This is really a platform question, not a
   "some devices have it, some don't at random" one:
   
     - Kobo and Kindle: yes, essentially always. Both run embedded
   Linux with BusyBox, and BusyBox's unzip applet is a standard part
   of that toolset on both platforms — nothing extra to install.

     - Android-based e-readers (Boox and similar, or KOReader running
   on a general Android tablet): not guaranteed. Android doesn't
   enforce any particular set of command-line utilities being present,
   so unzip may simply not exist there — this is a known enough
   limitation that KOReader's own core code deliberately avoids
   shelling out to unzip on Android for its own internal zip
   handling, for exactly this reason.


   *If you're on Kobo or Kindle and tiers 0/3 aren't producing anything
   for any book, unzip availability probably isn't the cause — look
   at the other steps here first. If you're on an Android-based device,
   this is a plausible explanation for tiers 0/3 coming up consistently
   empty while tiers 1/2 (metadata.calibre-only) still work fine.*

3. **Do the book paths in `metadata.calibre` actually match?** This file
   stores each book's path (`lpath`) relative to wherever it's rooted.
   If books were moved, renamed, or re-organized on the device *after*
   the last Calibre sync, the paths this patch computes won't match
   what's in the file, and lookups will silently fail for those books.
   Re-syncing from Calibre (so `metadata.calibre` reflects the current
   file layout) fixes this.






## "Works for some books, not others" (usually expected)

Each book's estimate comes from the first of four sources that has
something for it. It's completely normal for most books to only qualify
for one or two of these, or none:

| Tier | What it needs | How common |
|---|---|---|
| 0. Publisher page-list | The EPUB itself embeds an EPUB3 page-list nav or EPUB2 NCX `<pageList>` | Uncommon — mostly textbooks, academic titles, or EPUBs made to preserve print pagination. Most ordinary ebooks don't have this at all. |
| 1. `#words` Calibre column | That column exists in your Calibre library **and has a value for that specific book** | Depends entirely on your Calibre setup — a column existing doesn't mean every book has been processed to populate it |
| 2. `#pages` Calibre column | Same as above, different column | Same caveat |
| 3. Embedded OPF `#pages` | The custom column was embedded into the file itself when it was converted/sent to your device | Only applies to EPUB, and only if "embed metadata" was on for that transfer |

**To check why a specific book has nothing:** open `metadata.calibre` in
a text editor, search for that book's filename or `lpath`, and look at
its `user_metadata` section. If `#words` and `#pages` are both absent or
empty there, tiers 1–2 have nothing to work with for that book — that's
a Calibre-side data gap, not something this patch can work around. From
there, whether tier 0 or 3 can help depends on whether that specific
file happens to have the relevant embedded data, which varies book to
book and isn't something you can easily predict without checking.







## "The number is different from what I see after opening the book"

Only tier 1 is an *estimate* (word count → characters → pages, using the
`CHARS_PER_PAGE`/`CHARS_PER_WORD` constants near the top of the file) —
it's designed to land close to, not exactly match, what you'll see once
KOReader actually renders the book. Tiers 0, 2, and 3 are real numbers
from elsewhere (the book's own print pagination, or whatever your
Calibre/device page count happens to be), so they may not match
KOReader's page count for entirely different reasons — they're not
supposed to be the same measurement in the first place.

If the tier-1 estimate is consistently running high or low across many
books, try adjusting `CHARS_PER_WORD` (default `6`) up or down slightly.
If you use KOReader's raw (non-stable) page count, tier 1 isn't
meaningful for you at all — set `ENABLE_WORDS_ESTIMATE = false` near the
top of the file instead of trying to tune it.







## "Time left in book is wrong"

This patch itself doesn't touch time-left calculations — it only ever
fills in a page count for books that have **never been opened** (see the
README's "Safety" section). If you're seeing an incorrect time-left
estimate on a book you're actively reading, that's a separate issue from
this patch; check that you're running Zen UI 2.4.4 or later, which fixed
a related bug in how it calculated time-left for books using stable page
numbers.







## Still stuck?

Turn on KOReader's debug logging and check for lines starting with
`calibre-page-estimate` — the patch logs a warning whenever it
can't open or parse `metadata.calibre` for a book, which usually points
straight at the problem (wrong location, malformed JSON, permissions,
etc.).
