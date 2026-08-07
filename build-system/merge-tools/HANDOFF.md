# Handoff: exteraGram iOS — Telegram 12.9.2 version bump

Written for whoever (or whatever) picks this up next, on a fresh account with no
memory of the session that produced it. Everything here is checked into the repo
on purpose: the container is ephemeral and `/tmp` does not survive it.

Read `CLAUDE.md` first — it has the short version of the bump process. This file
is the long version: current state, what each tool is for, the failure modes that
were actually hit, and the plan that was approved but not started.

---

## 1. Where things stand

**Task:** merge upstream `TelegramMessenger/Telegram-iOS` release-12.9.2 into the
fork, which derived from release-12.8. `versions.json` is already on `12.9.2`.

**Branch:** develop on `claude/explore-project-FdwPa`, and push **every** commit
to `master` as well — CI only runs on `master`.

**Status at handoff:** not green yet. The merge itself is applied in full (all
four layers); what remains is a shrinking tail of compile errors, worked one CI
round at a time. Round-by-round error counts so far:
25 → 7 → 3 → 8 → 5 → 5 → 5 → 18 → 38 → 48 → 24 → release-only asset errors → 33.
The count is not monotonic because each fixed layer unblocks the next one — a
module that never compiled cannot report anything.

Last commit at handoff: `a32663c0`.

**Two facts worth knowing before touching anything:**

- Swiftgram (the fork's original ancestor) **never released 12.9**. Its master
  sits at `12.8-278`. This bump therefore takes upstream Telegram directly.
- The 12.8 bump was **not a merge**. Commit `5a815eb8` ("real Telegram 12.8
  merge, 1581 files") has a single parent — upstream files were copied over ours.
  That is the source of most of what is still being fixed, and it is why parts of
  the tree were simultaneously ahead of and behind 12.8. Expect to keep finding
  12.8-era debt, not just 12.9.2 delta.

---

## 2. Reference trees — do this first in a new container

```bash
bash build-system/merge-tools/fetch_upstream.sh release-12.8 release-12.9.2
# -> /tmp/upstream/release-12.8   (BASE:   what the fork derives from)
# -> /tmp/upstream/release-12.9.2 (THEIRS: what we are bumping to)
```

Almost every tool below needs these. The fork shares no git history with
upstream, so there is no merge base; `merge3.py` reconstructs one per file from
these two trees.

---

## 3. The tools, and what each one actually caught

All in `build-system/merge-tools/`. Run all of them before pushing.

| Tool | What it does | What it caught here |
|---|---|---|
| `merge3.py` | Per-file 3-way merge via `git merge-file`. States: clean / conflict / ours-only / theirs-new / theirs-deleted / theirs-deleted-modified / unchanged / **stale** / asset-* | The whole bump. Also, re-run on a single file, it fixed `ChatListItem.swift` in one shot: 81 upstream hunks applied, 1 conflict |
| `check_api_drift.py` | Compares `AccountContext` + `SharedAccountContext` declarations against upstream, **normalising away** the fork's deliberate `Peer`/`Message`/`postbox:` divergence | 4 cross-module bridges left behind while callers and factories moved on. Each would have cost a full CI round |
| `check_syntax_debt.py` | Gates on leftover conflict markers and on a fork-only file that does not close every brace; advisory report of delimiter balance that differs from upstream | 8 orphaned `>>>>>>> theirs` lines **committed** in `TelegramUI/Sources`, plus 4 resolutions that broke the syntax — two of them only after its stripper was fixed (see §7.8) |
| `check_assets.py` | Files in an asset catalog that no `Contents.json` entry references, and vice versa | 10 directories. `AssetCatalogCompile` rejects these, and `validate.yml` cannot see them at all |
| `check_build_deps.py` | `import X` vs Bazel `deps`, using the **transitive** closure; also `find_cycle()` | 5+ "no such module", and one dependency cycle (an analysis-phase failure `--keep_going` does not soften) |
| `check_duplicate_types.py` | Same-module duplicate top-level types | Duplicated methods left by conflict resolutions |
| `fork_inventory.py` | 24 registered fork-only declarations + 56 EG modules + hook-marker counts with floors | Verifies nothing fork-specific was silently dropped |
| `parse_ci_errors.py` | Build log → unique `file:line: error:` + failed modules | Used by both workflows |
| `check_engine_adapters.py` | Peer/Message handed across the boundary to a module on the Engine types, or the reverse. Resolves argument types from explicit annotations only | Added later. Note its blind spot: it reads *call arguments*, so a wrongly-typed **stored property** crossing the boundary is invisible to it — that is exactly what `PeerInfoScreenData.peer` was |
| `plan_module_merge.py` | Checks a proposed `exteraGram/` grouping for induced dependency cycles and type collisions before anything moves | For the Android-parity work in §8 |
| `check_signal_arity.py` | Every `combineLatest(...)` against the `\|> map` / `\|> mapToSignal` closure that consumes it | 3 of these in the 12.9.2 bump. See failure shape §7.7 — it is the highest-cost-per-line shape in this fork |
| `check_init_args.py` | Call sites vs the initializer, free function **or method** they resolve to | `NavigationBarTheme.accentDisabledButtonColor`, `cachedWallpaper`, and — once methods were covered — `recentOnlineSmall`/`recent`/`admins` losing `postbox:`/`network:`, `sendVideoRecording` losing `repeatPeriod:`, and `WebAppParameters` losing `sameOrigin` |

```bash
python3 build-system/merge-tools/check_api_drift.py    --upstream /tmp/upstream/release-12.9.2
python3 build-system/merge-tools/check_syntax_debt.py  --upstream /tmp/upstream/release-12.9.2
python3 build-system/merge-tools/check_assets.py
python3 build-system/merge-tools/check_build_deps.py
python3 build-system/merge-tools/check_duplicate_types.py
python3 build-system/merge-tools/check_engine_adapters.py
python3 build-system/merge-tools/check_enum_cases.py
python3 build-system/merge-tools/check_init_args.py      # ~10 min, run it in the background
python3 build-system/merge-tools/check_signal_arity.py
python3 build-system/merge-tools/fork_inventory.py
```

All of them pass. **They passing does not mean the build is green** — they cover
the classes that were expensive to find, not type checking.

`check_orphans.py` from the original plan was never written; `merge3.py`'s
`theirs-deleted` state covers most of what it was meant to do.

### merge3.py — two rules learned the hard way

1. **One pass per path, ever.** `--apply` is not idempotent. Re-running it over
   an already-resolved path re-conflicts the file and silently undoes the manual
   work. There is now a guard refusing files that already contain conflict
   markers, but the discipline still matters.
2. **Its asset copying is a double-edged tool.** It copies upstream asset files
   in, which is right when the fork carries upstream artwork and wrong when the
   fork replaced it. The app icon and the Watch icon are a single
   `exteraGram.png` here, so upstream's 17 and 11 files landed beside them
   unreferenced. `check_assets.py` exists because of this. If you re-run
   `--apply` over `Images.xcassets` or `*.appiconset`, check assets afterwards.

---

## 4. CI

Both workflows run on `master` **only**. Pushes to other branches trigger
nothing.

- **`validate.yml`** — `debug_arm64`, compile only, `--continueOnError`
  (→ bazel `--keep_going`), error digest in the run summary and repeated as the
  last step. Fast feedback: 150–250 s warm, up to ~1250 s when `AccountContext`
  is touched and the whole graph below it rebuilds.
- **`main.yml`** — full release build (`-c opt` + WMO, dSYM, IPA). Slower to set
  up but, once the tree is mostly green, it has been **finding more than
  validate** and finishing faster (213 s vs 1241 s in one round), because it
  reaches further up the graph.

**`main.yml` sees two classes `validate.yml` structurally cannot:** asset
catalogue compilation, and anything that only surfaces under whole-module
optimisation. Do not treat a green validate as a green build.

**Do not push in bursts.** Each push cancels the previous run of both workflows,
and a cancelled run does not save the bazel cache.

### Reading the logs cheaply

Fetching logs through the GitHub API burns a lot of context. Get the signed URL
and grep locally instead:

```
mcp__github__get_job_logs(owner, repo, job_id=<id>, return_content=false)
  -> logs_url  (a signed blob URL, no auth needed, ~10 min expiry)
curl -sS -o log.txt '<logs_url>'
sed 's/^[0-9T:.-]*Z //' log.txt | awk '/=== [0-9]+ unique diagnostic/,/build stats/'
```

For the release build, extract by file:line instead — the digest step is not in
`main.yml`:

```
sed 's/^[0-9T:.-]*Z //' log.txt \
  | grep -oP '[\w/. +()-]+\.swift:\d+:\d+: error: .{0,120}' \
  | sed 's|^Users/Shared/telegram-ios/||' | sort -u
```

Also note `mcp__github__actions_list` returns ~300 KB for `per_page=1`; it will
overflow. It gets saved to a file — parse that with python instead.

---

## 5. The fork's deliberate divergence — the single most important rule

The fork keeps the **Postbox-level** types where upstream migrated to the Engine
wrappers:

| Fork keeps | Upstream uses |
|---|---|
| `Peer`, `[Peer]`, `Peer?` | `EnginePeer`, `EngineRawPeer` |
| `Message`, `[Message]` | `EngineMessage`, `EngineRawMessage` |
| `postbox:` argument labels | `engine:` |

**Adapt the argument, never migrate the fork.** `x._asPeer()`,
`EngineMessage(x)`, `messages.map { $0._asMessage() }`,
`peer.flatMap(EnginePeer.init)`.

Two traps:

- `EnginePeer.Id` **is a typealias for `PeerId`**, and `EngineMessage.Id` for
  `MessageId`. Parameters of those types are identical on both sides and need no
  adapter. A sweep that ignores this produces 231 "errors" of which 0 are real.
- The adapter is needed in **both** directions, sometimes in the same file.
  `StorageUsageScreen` was missing `._asMessage()` on four appends into the
  fork's `[Message]` arrays *and* carrying a spurious one on two constructions of
  a member that is `EngineMessage`.

Static detection is unreliable: whether a local is `Peer` or `EnginePeer`
depends on which API produced it, which needs real type inference. A sweep over
the 8 genuinely divergent `AccountContext` functions produced 80 candidates; the
ones that turned out real were 13/13 in modules that had not yet compiled, and
the rest were fine. **Let the compiler arbitrate. Do not apply 80 blind edits.**

---

## 6. Failure shapes seen repeatedly — check for these first

Each of these cost at least one CI round. They share a fingerprint: the
declaration lagged while everything around it moved on.

1. **Bridge behind its callers.** `AccountContext` declares something in the old
   shape; every call site and the underlying factory are already new. Examples:
   `makeTextProcessingScreen`, `makeAvatarMediaPickerScreen`,
   `makeLinkEditController`, `makeGalleryCaptionPanelView`, `displaySetPhoto`
   (missing overload). `check_api_drift.py` finds these — **run it first.**
2. **Interaction struct behind its constructions.** `ChatControllerInteraction`
   was three members short while 5 of 8 construction sites already passed them;
   `ChatListNodeInteraction` one short while 11 of 12 did. Compare the init
   parameter list against upstream and count who already passes what — the
   majority tells you which side is wrong.
3. **Usages survived, declaration lost.** `isAIEnabled`, `hasRichMessages`, the
   five `display*Icon` flags, `CommunitiesConfiguration`, `getAnchorRect`,
   `mergeType`'s 5th tuple element. Restore the declaration; do not delete the
   callers.
4. **Declaration survived, consumer lost.** The mirror image, and it fails only
   because of `-warnings-as-errors`: `didJoin` written but never read, `richText`
   built and never used. The fix is usually a guard or a branch upstream added,
   not deleting the variable — `richText` turned out to mean the fork's rich
   messages never rendered at all.
5. **Both halves of a refactor present at once.** `ChatListItem` had the old
   `display*Icon` blocks *and* the new `switch messageTypeIcon` case labels,
   minus the `switch` header. Restoring the header alone would have left two
   parallel mechanisms — take upstream's whole region.
6. **Swift cascades.** "generic parameter could not be inferred", "cannot infer
   contextual base", "'nil' requires a contextual type", "type of expression is
   ambiguous" are almost never the bug. Find the one real argument mismatch in
   the same file; 38 diagnostics in PeerInfoUI collapsed to 7 real causes.
7. **A fork signal in a `combineLatest` whose closure header the merge
   replaced.** The fork prepends its own signal (`regDate`) to a
   `combineLatest`; 12.9.2 rewrote the `mapToSignal { ... }` header, which has
   no parameter for it. Nothing is missing and nothing is extra — every binding
   just shifts by one, so the compiler reports it as `availablePanes` being a
   `PeerView`. Count the signals against the closure parameters; do not read the
   error at face value. `check_signal_arity.py` now does the counting; it found
   three instances in this file alone — the missing `businessConnectedBot`
   *signal*, and a missing `firstMessage` *binding* whose
   `channelCreationTimestamp:` argument had gone with it. That last one shows why
   the compiler is no help: `channelCreationTimestamp` has a default value, so
   dropping the argument is silently legal.
8. **Two hunks of one call spliced into each other.** In
   `ChatControllerOpenLinkContextMenu.swift` upstream's `if let openMode { … }`
   block landed *inside* the fork's `items.append(...)` for the forward action;
   in `ChatController.swift` upstream's `}, error: {` became
   `).startStrict(error: {`, leaving the `next:` closure open. Both are invisible
   to a per-hunk review and neither produces a conflict marker. What finds them
   is delimiter balance measured against the same file upstream — but only after
   `check_syntax_debt.py`'s stripper was fixed (see §9).
9. **An import dropped while its symbol stayed.** The same file lost
   `import BrowserUI` / `TelegramUIPreferences` / `UrlEscaping`, and
   `ChatControllerLoadDisplayNode.swift` lost `import TextProcessingScreen` while
   still calling it. `check_build_deps.py` does *not* catch this — it checks that
   every `import` has a Bazel dep, not that every used module is imported. Diff
   the `^import` lines of every file against upstream after a bump; ~10 files
   differ, and the ones that matter are those whose file still names a type the
   dropped module declares.

10. **`--keep_going` only reports what it can reach.** A module below the failure
   is never compiled, so its errors are invisible. When you fix module X, sweep
   the *same pattern* across the tree before pushing — that is how 29 more
   `iconColor` sites and 6 more `openPeersNearby` sites were found from 2 and 1
   reported.

---

## 7. Bazel specifics

- `egdeps` / `egsrcs` — plain Starlark list variables, declared independently in
  37 upstream-derived BUILD files, holding the fork's own labels so fork
  additions survive merges: `deps = egdeps + [...]`. `check_build_deps.py`
  expands them.
- Watch out for commented-out dep labels (`#  "//exteraGram/..."`),
  `deps = egdeps +[` with no space in `Media/LocalAudioTranscription`, and a dead
  `egdeps` in `LegacyMediaPickerUI`.
- `Make.py` hardcodes the target `Telegram/exteraGram`; you cannot build an
  arbitrary Bazel target through it.
- Everything compiles with `-warnings-as-errors`. An unused variable is a build
  failure.

---

## 8. Approved plan, not started: Android-parity module structure

Full text: `build-system/merge-tools/PLAN-android-parity.md`. Summary:

**Goal.** Make the fork's directory tree mirror the Android exteraGram package
tree so users switching from Android recognise it.

**Source material.** The user supplied the real APK and decompiled sources dated
**14 July 2026** — the current version. The GitHub mirror is stale (June 2023,
9 packages / 51 files vs 25 packages / ~430 files). Root package is
`com.exteragram.messenger`. If you need them again, ask the user; they were
fetched to `/tmp` and are gone.

**Decisions already made with the user:**

- **Media save folders: out of scope.** The current Android version saves to
  `Pictures/Telegram` and `Download/Telegram`; only the camera album
  (`AndroidUtilities.getAlbumDir`) and a legacy internal root still say
  exteraGram. The 2023 layout was reverted upstream of the fork. iOS keeps saving
  to the gallery with no album. The fork's own data dirs (`Documents/EGPlugins`
  etc.) stay as they are — visible in Files only if File Sharing is enabled in
  Feather, which is the expected behaviour.
- **Merge modules, one Swift module per Android package** — the user chose this
  over keeping the 56 fine-grained modules.
- **Module names in lower case**, exactly the Android package names (`utils`,
  `config`, `plugins`). This is legal: the repo already has
  `import sqlcipher` and `import libprisma`. Shadowing risk is negligible —
  there are 5 `Module.Type` references in the whole tree, and
  `EGSimpleSettings` is a *type* inside the same-named module, so all 314
  `EGSimpleSettings.shared` uses survive a module rename untouched.
- **Packages Android does not have get created anyway** (`logging`, `strings`,
  `iap`, `paywall`, `pro`, `status`, `webapp`) rather than dumping into `utils`.
- **Compatibility via `alias()`, not symlinks.** A real directory symlink breaks
  Bazel: the glob picks files up twice and you get type redeclaration. Leave
  `alias(name = "<OldName>", actual = "//exteraGram/messenger/<pkg>:<mod>")` at
  each old label so the 194 `//exteraGram/...` references in 66 BUILD files keep
  working, and retire the aliases only once `check_build_deps.py` shows nobody
  uses them.
- **`path_map.json`** in merge-tools, consumed by `merge3.py`, so a future
  upstream edit arriving on an old path lands on the new one.

**Precondition: master must be green on 12.9.2 first.** Do not start this on a
red tree — bump errors and move errors would be indistinguishable.

**Phase 0 is mandatory and mechanical.** Write
`build-system/merge-tools/plan_module_merge.py` that (1) builds the dependency
graph of the 56 directories, expanding `egdeps`/`egsrcs`; (2) **contracts each
proposed group into one node and checks for cycles** — merging nodes is exactly
the operation that turns a valid chain into a cycle, and a cycle is a
Bazel analysis failure `--keep_going` will not soften; (3) pre-checks type-name
collisions inside each group; (4) prints a leaf-first application order. Fix the
grouping there, before touching the tree.

**Also note:** 15 of the 56 directories are **not modules** — they are
`filegroup`s whose `.swift` files compile into *another* module via `egsrcs`
(`ChatControllerImplExtension`, `EGDBReset`, `EGShowMessageJson`,
`EGSharedAccountContextMigration`, …). They cannot be folded into a merged
`swift_library`; they move but stay filegroups. Same for `EGSettingsBundle`
(`apple_bundle_import`) and `FLEX` (external repo build file referenced from
`MODULE.bazel`).

**Deferred by the user:** a relay to run Android plugins on iOS. Not now.

---

## 9. Known loose ends

- `merge3.py --audit` still reports `stale 314` and `conflict 23`. Most "stale"
  entries are legitimate fork edits, but that bucket is also where 12.8 debt
  hides — `ChatListItem`'s 4-element `mergeType` tuple was found exactly there,
  and it was stale, not conflicting.
- `check_syntax_debt.py`'s advisory list is now **empty** — every file with an
  upstream counterpart matches its delimiter balance. That is worth knowing
  because it was not true before: the tool used to strip comments and strings
  with successive regex substitutions, so `//` inside `"https://t.me/…"` ate the
  rest of the line. That produced two false entries *and hid two real ones*
  (§6.8). It now walks the file once. Three files still come out non-zero in
  absolute terms, all under a `#if`, and all three match upstream exactly — so
  the absolute rule is applied only to fork-only files, where it is a gate.
  If an entry ever reappears in the advisory list, read it: the fingerprint has
  been right every time.
- `peerNearbyData` is still an unused init parameter in `ChatController` (line
  ~674). It was being passed to `ChatPresentationInterfaceState`, which has no
  such member on either side, so the argument was removed at four call sites.
  Whether `ChatPresentationInterfaceState` *should* carry it as a fork field —
  i.e. whether a PeersNearby feature is quietly dead — was not investigated.
- **`WebUI` lost upstream's `sameOrigin` trusted-origin event proxy.** Only the
  compile-critical half was restored: `WebAppParameters` now carries
  `sameOrigin` again, because four call sites in `ChatControllerOpenWebApp.swift`
  pass it. The behaviour is still missing — `WebAppWebView.swift` has no
  `trustedOrigin`, `bindTrustedOrigin`, `setupEventProxySource`,
  `securedEventProxySource` or `isTrustedMainFrameMessage`, and
  `WebAppController` never reads `params.sameOrigin`. So the parameter is
  currently inert and web apps run with the unsecured event proxy. This is a
  security-relevant upstream change; port it deliberately, not as part of a
  build fix.
- `fork_registry.json` has 24 features, 3 hook markers, 4 count floors. **Add an
  entry whenever a bump turns out to have dropped something.**
