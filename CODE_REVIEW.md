# Code review: Concordance and Athenaeum against USER_GUIDE.md

Reviewed 10 November 2026, at commit `c01c9ab`.

This review comes from reading the code. The test suites were not run: no
KOReader build was available. Findings 3, 4 and D were confirmed by
executing the real modules under a stand-in Lua interpreter (with `logger`
and the archive reader stubbed); the rest are unverified at runtime.

The identity logic was reviewed a second time in more detail (see "Book
identity"). That pass narrowed finding 5.

Assumptions:

- "User manual" means `USER_GUIDE.md`.
- Concordance web is out of scope.
- The WebDAV and OPDS servers are the user's own, but the network path to
  them may not be trusted.

## Higher-impact findings

### 1. The guide's deletion promise does not match the code

`USER_GUIDE.md:73` says "nothing you delete is deleted elsewhere without
asking", and line 214 says "Deletions don't sync". The code propagates
several deletions silently:

- **Highlights:** removing 5 or fewer in one comparison deletes them
  everywhere (`concordance/annstore.lua:373`, threshold `> 5`). A book with
  5 or fewer highlights whose sidecar is reset loses them on every device.
  `ANNOTATIONS.md` records the count-only rule as a deliberate decision, so
  this is a guide wording problem unless the rule is revisited.
- **Settings files:** a file deleted on one device is deleted on the server
  and then on the others (`concordance/settings_engine.lua:637`, `:659`).
- **Ratings, reviews, custom metadata and collection membership:** clearing
  one propagates.

Suggested fix: reword the guide to say which deletions sync (only
statistics and history removals do not).

### 2. A pulled `settings.reader.lua` is likely never to take effect and to be pushed back

- Staged files are copied into place when Concordance's `main.lua` loads
  (`concordance.koplugin/main.lua:99`).
- KOReader has already loaded `settings.reader.lua` into memory by then and
  rewrites it on its next flush.
- The next sync then sees a local change and uploads the old content over
  the newer server copy, with no conflict copy.
- Nothing in `Engine.excluded` or `Engine.behaviour`
  (`concordance/settings_engine.lua:64`, `:92`) handles this file, and the
  guide lists "Settings" as synced.
- The same applies to any file KOReader core reads before plugins load,
  such as `defaults.custom.lua`.

Suggested fix: exclude these files with a logged reason, or apply them
earlier (for example from a user patch).

### 3. Settings sync accepts `..` in paths that come from the server (confirmed at the filter)

- `Engine.kind` and `Engine.excluded` both pass
  `settings/../../../etc/passwd` and `settings/x/../concordance/device.lua`
  under a `/settings/**` rule, and `fonts/../patches/9-evil.lua` under
  `< /fonts/**`.
- `safePath` (`concordance/settings_engine.lua:362`) rejects only tabs and
  newlines.
- A hostile or corrupted manifest or listing can therefore write or delete
  outside KOReader's folder, or reach the "never synced" files. On Kobo,
  KOReader runs as root.

Suggested fix: reject any manifest or listing path with an empty, `.` or
`..` segment, as `badPattern` already does for patterns.

### 4. Athenaeum's guard runs the hooked function twice after a plugin error (confirmed)

- In `athenaeum/guard.lua:87-104`, if the hook body throws after it has
  already called the original, the wrapper calls the original again.
- For `FileManager:deleteFile` the second call acts on a file that is
  already gone and returns failure. For `showReader` it would open the book
  twice.
- This is the path meant to keep "your books and the file browser" working.

Suggested fix: remember the original's results inside `call_orig` and
return them instead of calling again.

### 5. Title-only matching can wrongly join two different books

- `athenaeum/matcher.lua:170` falls back to the title alone, even when
  the file names an author that contradicts the catalog's.
- `Library.links()` (`athenaeum/library.lua:449`) passes that match to
  Concordance as a "link" identity fact, which is never removed and is
  synced to every device.
- A link only counts for a file with no identity fact read from the file
  itself (`concordance/idstore.lua:377-387`). Concordance reads every EPUB
  in Athenaeum's folder, so the scope is narrower than the matcher
  alone suggests:
  - **Permanent wrong joins** are limited to PDFs, other non-EPUB formats,
    and EPUBs with no UUID. Their status, rating and statistics merge with
    the catalog book's on every device.
  - **EPUBs with a UUID** can still be wrongly joined for a while. File
    reading is capped at 60 seconds per sync (5 for a manual one), so the
    link can count until the file is read. During that window statistics
    rows are merged, and that merge is not undone.
- **The guide overstates the feature.** `USER_GUIDE.md:192` says books
  matched by title share status, rating and statistics. For most
  title-matched EPUBs they will not, because the file's own UUIDs override
  the link.

Suggested fix: use the title-only fallback only when the file has no
author, or when its author string contains the catalog's first author.
Also consider a way to retract a link, and correct the guide.

### 6. A local edit is reverted when the stored record carries a later timestamp

- In `concordance/annstore.lua:335-348` and `concordance/bookstore.lua:377`,
  a new local change only wins if its time beats the merged record's.
- If another device's clock ran ahead, the edit loses and the next apply
  overwrites it with the older content.
- `ANNOTATIONS.md` accepts clock risk, but this case is avoidable.

Suggested fix: when the device had already applied the merged record,
stamp the change `max(now, merged.updated + 1)`.

## Book identity

A closer read of `idformat.lua`, `idstore.lua`, `idscan.lua`,
`identity.lua` and the parts of `bookstore.lua`, `engine.lua` and
`plugin.lua` that use them. Finding D was confirmed by running
`idscan.lua`; the rest are from reading only.

### A. Different books by the same author that share a UUID are joined

The guard only blocks a group when titles and first authors both differ
(`concordance/idstore.lua:474`). Any UUID in the file counts, including
the publisher's, which templates and some tools reuse across a series. Two
such books then share status, rating, review, custom metadata (including a
custom title), collections, history and statistics. Highlights are not
affected, because they need a matching body signature.

### B. A legitimate edit that changes both title and author blocks the join for good

The guard looks at every fact ever recorded for the group, and facts are
never removed. Fixing a subtitle and the author's name, in one or more
Calibre edits, leaves the versions unjoined, with no way to clear it.

### C. A ninth version unjoins the whole book, and status can revert

- Groups above 8 MD5s are not joined (`concordance/idstore.lua:472`).
  Every re-download after a Calibre edit adds an MD5, and so does a
  replaced file's sidecar (`concordance/idstore.lua:215`).
- When the limit is passed, all versions part. This affects the
  longest-lived, most-edited books.
- On parting, a version with its own older record (for example "reading")
  is likely to be set back to it by `BookStore:plan`
  (`concordance/bookstore.lua:416`), even though the device showed
  "finished". This path was not run.

### D. The body signature can match for different text (confirmed)

A spine file that is not found in the archive contributes a fixed
placeholder (`concordance/idscan.lua:137`). Two versions whose spine files
could not be read got the same signature in a test, despite different
bodies. Highlights and reading positions would then cross between
different editions. This needs both files to fail the same way, so it is
unlikely.

### E. Never-opened cloud files are re-read after KOReader starts in a book

- Athenaeum does not load its catalog when KOReader starts in the
  reader, so its file list is empty (`concordance/plugin.lua:403`).
- A sync then drops the "already read" record of every downloaded file
  that has not been opened (`concordance/engine.lua:349`,
  `concordance/idstore.lua:262`).
- They are all read again once the file browser opens. Nothing is lost;
  the cost is repeated work on each such start.

### F. Cloud book state ignores the guard

`statesByUuid` (`concordance/bookstore.lua:574`) combines every file that
names a UUID, whether or not its group passed the guards. Lookups use the
catalog's own UUID, which is rarely shared, so the effect is small.

### Smaller point

Athenaeum's matcher and Concordance's scanner parse identifiers
differently (`athenaeum/matcher.lua:64` requires the `dc:` prefix; the
scanner does not). A file can be matched by title in one and by UUID in
the other.

### What holds up

- Only UUIDs join files; ISBNs and other identifiers never do.
- Facts read from a file override links, and disagreeing links cancel out.
- Position sharing requires both a shared UUID and the same body
  signature.
- Grouping is deterministic, so every device reaches the same groups from
  the same facts.

### Suggested changes

- Change the guard to act on title difference alone unless there is
  stronger evidence (a shared body signature, or a shared catalog UUID).
- Replace the fixed limit of 8 with one that ignores superseded versions,
  or raise it and report when it is hit.
- Give no signature when any spine item is unreadable.
- Skip the "forget files that are gone" step when Athenaeum's list is
  empty because its catalog is not loaded.

## Medium and low findings

- **Empty catalog wipes the cache:** `athenaeum/sync.lua:187` deletes
  every unseen book after a full sync. A valid but empty feed (expired
  login, restricted anonymous view) removes all cloud books until the next
  sync. Skip the delete when zero books were seen or the count is far below
  `/stats`.
- **KEPUB downloads (uncertain):** `athenaeum/downloads.lua:25` saves
  them as `Title.kepub`. KOReader may not open that extension, and the book
  would then show neither as a cloud entry nor as a readable file. Not
  checked against KOReader.
- **Series numbers:** `athenaeum/sync.lua:225` uses the position in the
  series feed, so gaps or fractional indexes display wrongly. The guide
  does not mention this.
- **Work done while offline:** `concordance.koplugin/main.lua:209-232`
  re-reads sidecars, collections and history on every wake-up and book
  close before checking connectivity.
- **Statistics re-export edge case:** `concordance/store.lua:811-830` can
  update an event in a non-target row of a version group without marking
  it exported under that row's MD5. It is later uploaded as this device's
  own; merges stay idempotent.
- **Highlight key collision:** keys are creation-time strings
  (`concordance/annformat.lua:194`). Two devices creating different
  highlights in one book in the same second collide, and one replaces the
  other.
- **Upload verification:** an upload counts as verified when the PROPFIND
  returns no parsable size (`concordance/webdav.lua:238`,
  `concordance/netjob.lua:379`).
- **Stray folders as devices:** `validDeviceId`
  (`concordance/netjob.lua:104`) accepts any alphanumeric folder name of 4
  to 64 characters.
- **Badge mismatch:** a second file of an already matched book goes to
  "unmatched" (`athenaeum/matcher.lua:176`) and gets the "not in the
  cloud library" badge.
- **Passwords containing `%`:** `athenaeum/http.lua:30` uses LuaSocket's
  `user`/`password` fields, the mangling that Concordance's `DESIGN.md`
  documents and avoids.
- **First-look dating:** `concordance/booksync.lua:91` dates existing
  values at noon on the modified day, so they can beat a genuinely later
  same-day change from another device.

## Guide claims that match the code

- The automatic sync triggers and the 20-second start delay.
- Statistics merging: idempotent, longest duration wins.
- Upload safety: temporary name, `MOVE` with `Overwrite: F`, then a size
  check.
- The 5-item hold dialog for mass highlight removal.
- A reset sidecar does not clear status or rating elsewhere.
- Settings conflicts keep the newer copy and save the other.
- The refusal to sync settings while pulled files wait for a restart.
- Quick and full sync schedules, and the weekly cover check.
- Download naming and dating.

## Not reviewed, or only skimmed

- **Athenaeum:** `search.lua`, `badge.lua`, `zenos_source.lua`,
  `timing.lua`, most of `covers.lua`.
- **Concordance:** parts of
  `collsync.lua` and `histsync.lua`, `migrate.lua`, `updates.lua`, and the
  transport code in `remote.lua`.
- **Shared:** the updater was skimmed only; it checks a SHA-256 published
  alongside the download, which shows integrity, not authenticity.

## Overall assessment

The design of Concordance's sync core (statistics, highlights, book data)
holds up on reading:

- **Merging is safe by construction.** Records merge idempotently and in
  any order, so repeated or out-of-order imports cannot corrupt state.
- **Failure handling is consistent.** Uploads are verified before anything
  is marked sent, imports are transactional, and an interrupted sync
  repeats rather than loses work.
- **Risky cases were considered.** Reset sidecars, restored backups, moved
  folders and shared device IDs each have explicit handling.

"Sound overall" goes further than this review can support:

- Nothing was run, apart from the two confirmed findings.
- Coverage was incomplete (see "Not reviewed, or only skimmed").
- Reading file by file finds local defects. It is weak at finding problems
  in how modules interact over time, which is where sync systems usually
  fail.

Running the existing suites (`scripts/test.sh`,
`scripts/test-concordance.sh`, `tests/athenaeum/run_tests.sh`) is the
cheapest way to strengthen the assessment.

## Design improvements

These assume the current constraints stay: a plain WebDAV server with no
logic of its own, and no changes to KOReader itself. Items 1 and 2 give
the most: they address the only ways found for synced data to end up wrong
on every device with no means of repair.

1. **Order changes by a logical clock, not the device clock.** Each
   highlight and book property already carries an `updated` integer. If a
   device stamps a change as the larger of "now" and "one more than the
   newest value it has seen for that record", a later edit always beats
   what it was based on, whatever the clocks say. The segment format does
   not change, and older devices keep working. (Finding 6.)

2. **Make inferred book matches retractable.** Facts read from a file (its
   UUID, its body signature) can stay permanent. Matches that are guesses,
   such as Athenaeum's title matches, should be a separate record type
   that can be withdrawn, so a wrong join can be undone on every device.
   The same applies to the guards: they judge a group by every fact ever
   recorded, so one bad or outdated fact blocks or forces a join for good.
   (Findings 5, A, B and C.)

3. **Fold the four streams into one implementation.** Highlights, book
   data and identity each repeat the same store pattern: transaction
   wrapper, "wins" rule, outbox, export, mark-sent and import.
   `concordance/engine.lua` repeats near-identical blocks per stream in its
   export and collect steps. A single stream interface with per-stream
   record handlers would remove the chance of the copies drifting apart,
   and would make a fifth stream cheap.

4. **Validate everything from the server at one boundary.** Segment
   contents are strictly validated, but settings sync's manifest paths are
   not. One path type, checked once where server data enters, would cover
   the manifest, folder listings and any future source. (Finding 3.)

5. **Change when pulled settings are applied.** Applying at plugin load
   cannot work for files KOReader core has already read. Two options:
   - Swap the files in just before the restart Concordance already offers,
     after KOReader's final flush. More useful, but not checked against
     KOReader's shutdown order.
   - Declare core-owned files unsupported and refuse them with a logged
     reason.

   (Finding 2.)

6. **Shrink Athenaeum's hook surface.** It already registers as a
   ZenOS book source. Since the plugin requires ZenOS anyway, a ZenOS-side
   interface could replace the wrappers around `FileChooser`,
   `ReadHistory`, `DocSettings` and the delete functions. Fewer replaced
   functions means fewer ways a KOReader update breaks it. This depends on
   ZenOS accepting such an interface, which was not assessed.

7. **Make catalog deletion two-step.** Mark books missing after a full
   sync, and remove them only after a second consecutive sync agrees or
   the count matches the server's `/stats`. That removes the empty-feed
   wipe without a special case.

8. **Add convergence tests.** The stores take their dependencies as
   arguments, so a test can simulate several devices making random edits,
   deletions and syncs in random order, then check that all end in the
   same state. This targets the cross-module interactions that file-by-file
   reading is weak at.

9. **Make the contract between the two plugins explicit.** They find each
   other through `package.loaded` lookups in both directions. A small
   versioned interface table would state what each may rely on.

## Conditions the guide does not state

The guide's guarantees ("nothing is lost", "the later change wins") hold
only with correct device clocks and a trustworthy server and network path.
The guide states neither condition.
