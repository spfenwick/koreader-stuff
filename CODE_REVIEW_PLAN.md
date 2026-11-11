# Plan for the findings in CODE_REVIEW.md

Written 11 November 2026, against commit `27e1aaf`. Nothing the review
cites has changed since it was written (at `c01c9ab`).

Every finding was checked by reading the cited code, and some against the
local KOReader checkout. All of them hold, though several matter less than
the review suggests.

The suites the review could not run were run: `scripts/test.sh`,
`scripts/test-concordance.sh unit` and `tests/cloudlibrary/run_tests.sh`
all pass with 0 failures. The Concordance integration test (needs rclone)
was not run.

## Verdicts

### Higher-impact findings

| # | Finding | Verdict | Notes |
|---|---|---|---|
| 1 | Guide's deletion promise | Valid, docs only | The code does what `ANNOTATIONS.md` and `SETTINGS.md` describe; only `USER_GUIDE.md:73` and `:214` are wrong. |
| 2 | Pulled `settings.reader.lua` reverts | Valid, narrower | KOReader opens it at `reader.lua:39`, long before plugins load. It is not in the default list, so only users who add `/settings.reader.lua` or `/defaults.custom.lua` are hit. |
| 3 | `..` in server paths | Valid | `safePath` only rejects tabs and newlines, and `parseManifest` and the listing loop accept anything. This is the one real security issue. |
| 4 | Guard calls the original twice | Valid | In `guard.lua`, a throw from the hook after `call_orig` succeeded falls through to `return orig(...)`. |
| 5 | Title-only match joins different books | Valid | `matcher.lua:170` falls back to the title even when the file names a different author, and the link is permanent. |
| 6 | Local edit loses to a future-dated record | Valid | `record()` in both stores drops the edit when `merged.updated > now`, and the next apply reverts it. |

### Book identity

| # | Finding | Verdict | Notes |
|---|---|---|---|
| A | Same-author books sharing a UUID join | Valid | The guard needs both titles and authors to differ. |
| B | Title-and-author edit blocks the join for good | Valid | The guard looks at every fact ever recorded. |
| C | Ninth version unjoins the group | Valid | `MAX_GROUP = 8`. The status revert on parting is plausible but was not run. |
| D | Placeholder signature | Valid, unlikely | `IdScan.combine` uses `"-"` for an unreadable spine item. |
| E | Re-read after starting in a book | Valid | `Library.on_device` is empty until the catalog loads, so `keepScanned` drops those files. |
| F | `statesByUuid` ignores the guard | Valid, small effect | |
| – | Identifier parsing differs | Valid, cosmetic | The matcher needs the `dc:` prefix; the scanner does not. |

### Medium and low

| Finding | Verdict | Notes |
|---|---|---|
| Empty catalog wipes the cache | Valid | `deleteUnseen` runs unconditionally after a full sync. |
| KEPUB downloads | Valid, confirmed | KOReader registers no `kepub` extension, so `Title.kepub` cannot be opened. The matcher already understands `.kepub.epub`. |
| Series numbers | Valid | Uses the position in the feed. |
| Work done while offline | Valid, mostly intended | Observing local changes at the time keeps their timestamps right; leave it. |
| Statistics re-export | Valid by reading | Not reproduced. |
| Highlight key collision | Valid, very rare | Accept and document. |
| Upload verification | Valid | An upload passes when the size is `nil`. |
| Stray folders as devices | Valid, low | |
| Badge mismatch | Valid | A second file of a matched book lands in "unmatched". |
| Passwords containing `%` | Valid | `http.lua` uses LuaSocket's `user`/`password`; Concordance's WebDAV builds the header itself. |
| First-look dating at noon | Valid, low | |

## Plan

### Phase 1: safety fixes (small, each with a test)

1. **Finding 3:** add one path validator that rejects empty, `.` and `..`
   segments, a leading `/` and control characters. Use it in
   `parseManifest`, both listing loops, `scan` and `applyPending` (which
   trusts `pending.tsv`).
2. **Finding 4:** have `call_orig` remember the original's results; on a
   hook error, return them instead of calling again.
3. **Empty catalog:** skip `deleteUnseen` when the full sync saw zero
   books. The two-step delete from the review's design section can come
   later.
4. **KEPUB:** save as `.kepub.epub`.
5. **Passwords with `%`:** build the `Authorization` header by hand in
   `cloudlibrary/http.lua`, as `webdav.lua` does.

### Phase 2: sync correctness

6. **Finding 6:** when the device's last-seen hash equals the merged
   record's, stamp the edit `max(now, merged.updated + 1)` in
   `annstore.lua` and `bookstore.lua`. Add a test with one device's clock
   ahead.
7. **Finding 2:** refuse `settings.reader.lua` and `defaults.custom.lua` in
   `Engine.excluded` with a logged reason, and say so in `SETTINGS.md`.
   Applying them at exit is fragile, because KOReader's final flush happens
   after plugins are gone.
8. **Finding D:** give no signature when any spine item is unreadable.
9. **Finding E:** skip `keepScanned` for Cloud library's files when its
   catalog is not loaded. This needs a "loaded" flag from `Library`.
10. **Upload verification and device IDs:** treat a missing size as
    unverified, and tighten `validDeviceId` to the format Concordance
    generates.

### Phase 3: identity (design changes, bigger)

11. **Finding 5:** use the title-only fallback only when the file has no
    author, or its author string contains the catalog's first author.
12. **Findings 5, B:** make links retractable with a new "unlink" fact, so
    a wrong join can be undone on every device. This changes the identity
    format, so it needs a version check for older devices.
13. **Findings A, B, C:** rework the guard:
    - block on title difference alone unless a body signature or catalog
      UUID is shared;
    - judge by each MD5's latest fact, not all history;
    - count only non-superseded versions towards the limit, and report in
      Status when it is hit.
14. **Finding F and the parsing mismatch:** make `statesByUuid` respect
    `g.ok`, and have the matcher accept un-prefixed `identifier` elements.

### Phase 4: docs and leftovers

15. **Finding 1 and guide conditions:** reword `USER_GUIDE.md:73`, `:192`
    and `:214`, and state the correct-clock and trusted-server conditions.
    Add series numbering and the same-second highlight collision as known
    limits.
16. **Low items:** fix the badge for a second file of a matched book, the
    statistics re-export marking, and noon dating (date first-look values
    at the start of the day so they lose same-day ties).
17. **Tests:** add the multi-device convergence test from the review's
    design section. It is the best guard for phases 2 and 3.

### Skipped

- **ZenOS-side interface** (design item 6): needs ZenOS PRs.
- **Folding the four streams into one** (design item 3): a large refactor
  with no bug behind it.

## Decisions (11 November 2026)

- **Finding 1:** update the docs; the deletion behaviour stays as it is
  (step 15).
- **Step 13:** go ahead with the stricter guard. Some groups joined today
  will part, such as retitled editions without a shared signature.
