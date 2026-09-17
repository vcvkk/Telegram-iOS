# CLAUDE.md

This file provides guidance to AI assistants when working with code in this repository.

## Build
The app is built using Bazel.

## Code Style Guidelines
- **Naming**: PascalCase for types, camelCase for variables/methods
- **Imports**: Group and sort imports at the top of files
- **Error Handling**: Properly handle errors with appropriate redaction of sensitive data
- **Formatting**: Use standard Swift/Objective-C formatting and spacing
- **Types**: Prefer strong typing and explicit type annotations where needed
- **Documentation**: Document public APIs with comments

## Project Structure
- Core launch and application extensions code is in `Telegram/` directory
- Most code is organized into libraries in `submodules/`
- External code is located in `third-party/`
- exteraGram's own modules live in `exteraGram/` (`EG*`), and fork edits inside
  otherwise-upstream files are marked `// MARK: exteraGram`
- No tests are used at the moment

## Version bumps (merging a new upstream release)

Tooling lives in `build-system/merge-tools/`. Read this before starting a bump —
the 12.8 bump was done by copying upstream files over ours and cost ~15 CI
rounds; this process exists to prevent a repeat.

**Never copy upstream files over the tree.** That loses the distinction between
"upstream changed this" and "we changed this", which both clobbers fork edits
and strands files at the old version.

1. **Reference trees.** `bash build-system/merge-tools/fetch_upstream.sh release-<BASE> release-<NEW>`
   - `BASE` = upstream release the tree currently derives from, `THEIRS` = target.
   - The fork shares no git history with upstream, so there is no merge base;
     `merge3.py` reconstructs one per file from these two trees.
   - Upstream is `TelegramMessenger/Telegram-iOS`. Swiftgram (the fork's original
     ancestor) lags behind it, so check both before choosing a source.
2. **Audit.** `merge3.py --audit --base ... --theirs ...`
   States that need attention: `conflict`, `theirs-deleted-modified`, and
   `stale` (our file differs from BASE although upstream never touched it —
   usually a legitimate fork edit, occasionally debt from a previous bump).
3. **Apply layer by layer**, bottom-up, one commit per layer:
   TelegramApi+Postbox+Display+TelegramCore → TelegramUI/Components →
   TelegramUI/Sources → Telegram/ → `versions.json`.
   `merge3.py --apply --paths submodules/TelegramCore ...`
4. **Resolve conflicts keeping fork behaviour.** Rules learned the hard way:
   - the fork deliberately keeps `Peer`/`Message`/`postbox:` where upstream moved
     to `EnginePeer`/`EngineMessage`/`engine:` — adapt the *argument*
     (`EngineMessage(x)`, `x._asPeer()`), do not migrate the fork;
   - if upstream deleted a symbol our code uses, restore the declaration rather
     than deleting our callers;
   - Swift's "ambiguous"/"cannot infer" errors are almost always a cascade —
     look for a real argument mismatch nearby.
5. **Check before pushing:**
   ```
   python3 build-system/merge-tools/fork_inventory.py        # fork-only declarations survived
   python3 build-system/merge-tools/check_duplicate_types.py # no redeclarations
   python3 build-system/merge-tools/check_build_deps.py      # no "no such module"
   python3 build-system/merge-tools/check_engine_adapters.py # Peer/Message adapters
   python3 build-system/merge-tools/check_enum_cases.py      # enum cases vs their uses
   python3 build-system/merge-tools/check_init_args.py       # init call sites vs declarations
   python3 build-system/merge-tools/check_signal_arity.py    # combineLatest vs its closure
   python3 build-system/merge-tools/check_hoisted_closures.py # hoisted closure vs its callee
   python3 build-system/merge-tools/check_arch_coverage.py   # every arch Make.py emits
   python3 build-system/merge-tools/check_ordered_list_ids.py # no duplicate ids in list writes
   python3 build-system/merge-tools/check_api_drift.py --upstream /tmp/upstream/release-<NEW>
   python3 build-system/merge-tools/check_syntax_debt.py --upstream /tmp/upstream/release-<NEW>
   ```
   `check_enum_cases.py` and `check_init_args.py` both cover the same failure:
   a merge takes a declaration hunk and its use hunks independently and lands
   one without the other. `check_enum_cases.py` cross-checks an enum's `case`
   list against its `switch self` arms and against `entries.append(.x(…))` on
   arrays typed as it — the 12.9.2 bump lost `DebugControllerEntry.debugRichText`
   exactly that way — and also reports a `switch self` with no `default:` that
   misses a case, which is the same accident in reverse. `check_init_args.py`
   compares initializer call sites against the initializers they resolve to and
   reports a required argument that is never passed (`NavigationBarTheme` grew
   `accentDisabledButtonColor`; one of twelve call sites did not) or a single
   argument label the initializer does not declare (which is how the fork's
   `isEGPro` and `immediateExternalShareOverridingEGBehaviour` renames were
   found reverted on the declaration side only).

   Both resolve strictly lexically and go quiet the moment they cannot: the
   enum checker binds `switch self` to the innermost enclosing type rather than
   to a same-named type in another module (`Content`, `Category`, `Message` and
   `ChannelParticipant` each name several unrelated types here), and the
   initializer checker skips any type with an `override init`, a lone
   `convenience init`, no initializer in its own body, or a conformance that
   synthesises one (`: Int`, `: Codable`), because the initializer that would
   actually resolve is then invisible. It also skips files that `import
   SwiftUI`, whose `VStack`/`LongPressGesture`/`Text` shadow the tree's own.
   A clean run is not proof.

   `check_init_args.py` also walks **methods**, but only a name the tree
   declares exactly once, that is not also a free function or an enum case, that
   takes three or more parameters, and only at a `receiver.name(...)` call whose
   labels overlap the declaration in at least two places. Every one of those
   conditions is load-bearing: without the enum-case exclusion, `MediaReference`'s
   `.message(message:media:)` is checked against `FetchedMediaResource`'s
   `static func message(...)` and reports twenty files; without the two-label
   overlap, a tree method named `insert` is checked against every
   `array.insert(_:at:)`. It found `sendVideoRecording` missing upstream's
   `repeatPeriod:` — which had dropped the whole 4-argument `completion` closure
   type with it — while the caller already passed it.

   `check_init_args.py` applies the same walk to top-level functions, which
   drift identically — `cachedWallpaper` moved from `(account:slug:settings:)`
   to `(engine:network:slug:settings:)` and six call sites in
   ThemeSettingsController stayed behind, which cost a CI round on its own. A
   function is only considered when the tree declares that name exactly once at
   file scope, non-generic; a `private`/`fileprivate` declaration is matched
   only against calls in its own file, and a name that the calling file also
   declares as a method is skipped, since an unqualified call resolves there
   first. A name declared nowhere in the tree (upstream deleted
   `telegramWallpapers` and `telegramThemes` in favour of
   `context.engine.themes`) is invisible to this checker — there is no way to
   tell it apart from a system-framework function.

   A method or function whose *declaration* cannot be parsed is dropped from
   coverage in silence, so the parameter splitter matters as much as the checker:
   it re-joins a split made on the comma inside `Signal<Never, NoError>`, which
   had been making `profileData` and `profilePhotos` invisible. That re-join is
   applied to parameter lists **only** — in an argument list `luminance > 0.5`
   is ordinary, and joining on it silently miscounts arguments.

   Both filter to directories reachable from `Telegram/` through BUILD `deps`
   (`buildgraph.py`; `--all` disables it). `submodules/LegacyDataImport` and
   `exteraGram/Playground` are in the tree but in nothing's dependency graph,
   and have been failing both checks for releases without CI ever noticing.
   `check_signal_arity.py` counts the arguments of every `combineLatest(...)`
   against the parameters of the `|> map` / `|> mapToSignal` closure consuming
   it. This is the shape that costs the most CI rounds per line of damage: the
   fork prepends its own signal, the merge takes the closure header from
   upstream, and every binding shifts by one — so the compiler reports a type
   error several bindings downstream and nothing at all near the signal that
   moved. It found three in the 12.9.2 bump, one of which the compiler could
   never have pointed at: the `firstMessage` binding and its
   `channelCreationTimestamp:` argument were dropped together, and that argument
   has a default value. It skips a single-parameter closure (binding the whole
   tuple to one name is legal at any arity) and re-joins arguments split on the
   comma inside `Signal<Void, NoError>`.

   `check_syntax_debt.py` fails on leftover conflict markers — eight orphaned
   `>>>>>>> theirs` lines sat committed in `TelegramUI/Sources` for a whole
   bump, invisible because that module only compiles once everything below it
   is green — and on a fork-only file that does not close every brace it opens.
   It also lists files whose delimiter balance differs from upstream's; that
   part is advisory (fork edits shift it legitimately) but it is how four broken
   merge resolutions were found: a stray `)` where a `}` should have closed an
   `else`, an unclosed closure followed by a second `.startStrict(`, upstream's
   `if let openMode {` block spliced into the middle of a fork `items.append`,
   and `}, error: {` rewritten as `).startStrict(error: {`. The last two were
   only visible after its stripper was rewritten as a single left-to-right pass
   — stripping line comments before string literals ate the tail of every line
   holding a URL, which both invented two false positives and concealed those
   two real ones. The advisory list is empty as of that fix; treat any new entry
   as a real finding until proven otherwise.

   No checker covers a *dropped import*: `check_build_deps.py` verifies that
   every `import` has a Bazel dep, not that every module a file uses is
   imported. Diff the `^import` lines against upstream after a bump — that is
   how `TextProcessingScreen`, `BrowserUI`, `TelegramUIPreferences` and
   `UrlEscaping` were found missing from files that still name their types.
   `check_api_drift.py` is the one worth running *first*. It compares the
   `AccountContext` protocol surface and its `SharedAccountContext`
   implementation against upstream, normalising away the deliberate
   `Peer`/`Message`/`postbox:` divergence, and reports what is left. That
   residue is always a cross-module bridge left behind while its callers and
   its underlying factory moved on — a shape the compiler only reports after
   everything ahead of it in the graph builds, so each one otherwise costs a
   full CI round. Four of the 12.9.2 rounds went to exactly this
   (`makeTextProcessingScreen`, `makeAvatarMediaPickerScreen`,
   `makeLinkEditController`, `makeGalleryCaptionPanelView`).

   `check_hoisted_closures.py` covers the idiom this fork adopted in fbcf2554:
   the divergent arguments of the two enormous `ChatControllerInteraction`
   initializers now live in named closures (`openMessageContextMenuImpl` and
   friends), so a bump cannot collide inside one 200-line expression. The cost
   is that the annotation and the method it forwards to are two declarations a
   merge can move independently — the annotation keeps the fork's `Message`
   while the method follows upstream to `EngineMessage`. `check_engine_adapters`
   is structurally unable to see this: the argument is a bare `message` whose
   only type is that annotation, and the callee name is ambiguous *on purpose*
   (`openMessageContextMenu` is both the interaction property taking `Message`
   and the method taking `EngineMessage`). This checker compares the two
   declarations instead, disambiguating the callee by its full argument label
   list, and reports only `Message`/`Peer` vs `EngineMessage`/`EnginePeer` —
   `MessageId` vs `EngineMessage.Id` is the *same* type through a typealias, and
   treating it as a finding cost eleven false positives in SettingsUI on the
   first run. It found five in the 12.9.2 bump, one of which the compiler had
   not reached: `openPollMedia` sat behind an unrelated scope error on the line
   above it.

   `check_arch_coverage.py` covers the third architecture. `Make.py` can emit
   `arm64`, `sim_arm64` and `x86_64`, but only two of those are ever exercised,
   so the third rots in four places at once — a `select()` with no branch and no
   `//conditions:default` (bazel fails during *analysis*, which `--keep_going`
   does not soften, so it costs a whole round and suppresses every other
   finding); a genrule `$(TARGET_CPU)` chain that falls through to an `echo`
   without `exit 1`, leaving `BUILD_ARCH` empty so the failure surfaces
   somewhere unrelated; a BUILD that maps a CPU to an arch name its own
   `build-*-bazel.sh` does not handle (mozjpeg — the BUILD side looked complete,
   which is why it survived); and NEON intrinsics reached on a non-ARM target
   (subcodec, whose header guards `<arm_neon.h>` while its .cpp does not). It
   reads the architecture list out of `Make.py`, so adding a configuration there
   extends the checker with it. Both polarities of the NEON guard are tracked:
   `#if !defined(__ARM_NEON)` puts the ARM half in the `#else`, and getting that
   backwards makes the checker report the file it just fixed.
   What it does not catch: a select whose x86_64 case falls to a
   `//conditions:default` of `[]`. That passes analysis and the checker alike,
   and `crc32c` got all the way to the link step that way — `crc32c.cc` calls
   `ExtendSse42` whenever the compiler reports SSE4.2, so the x86_64 branch
   needs `crc32c_sse42.cc` *and* `-msse4.2`.

   `check_hoisted_closures.py` tracks shadowing: a nested closure parameter or
   `let` that reuses the hoisted parameter's name ends the annotation's
   authority. Without that, `navigateToMessageContext: { message in` inside
   `openMessageImpl` was reported against code that compiles.

   `check_ordered_list_ids.py` covers a crash no compiler or CI run can see,
   because it depends on what the server returns. `OrderedItemListTable`'s
   `replaceItems` asserts unique ids; release builds compile that out and keep a
   dangling index row, debug builds crash. The 12.9.2 tree died about five
   seconds into every debug launch because the recent-inline-bots sync asks
   `getTopPeers` for two categories and a bot in both came back twice. The
   checker flags a function that builds a list write in nested loops over
   server groupings without any dedupe. When a debug build dies on
   `Postbox/OrderedItemListTable.swift:151`, attach lldb with a breakpoint on
   that line and read `collectionId` (`Namespaces.OrderedItemList`) — the crash
   report's triggered thread is the main run loop and names nothing useful.

   `check_engine_adapters.py` covers the fork's single largest source of
   compile errors: a `Peer`/`Message` handed across the boundary to a module
   that stayed on `EnginePeer`/`EngineMessage`, or the reverse. It resolves an
   argument's type only from explicit annotations — a function parameter, a
   `let x: T`, a stored property, the parameter list of the closure an
   `asyncLayout()` returns, or the payload of the enum case a `switch` arm
   destructures — and stays quiet when it cannot, so a clean run is not proof.

   That last source is worth knowing about: `case let .website(…, peer, …)` is
   the only place an ItemList entry enum says what `peer` is, and changing the
   payload type moves every arm's binding at once. Getting it wrong cost two
   consecutive rounds in RecentSessionsController — first `Peer` where
   `ItemListWebsiteItem` wanted `EnginePeer`, then `EnginePeer` where
   `arePeersEqual` and the arguments closure wanted `Peer`. The subject may be
   `self` or a parameter annotated with the enum, since `==` and `<` switch
   over `lhs`; every arm must name a case of that enum or the whole switch is
   skipped. It is the only checker here that reads expressions rather than
   declarations, so re-validate it against a known-bad file after changing it:
   it silently found nothing at all through three separate defects of its own.

   Add an entry to `fork_registry.json` whenever a bump turns out to have
   dropped something.

6. **CI.** `validate.yml` (debug, compile only, `--keep_going`, error digest in
   the run summary) runs on pushes to `master`; `main.yml` (full release build)
   runs on `v*` tags and manual dispatch only — during a bump it just repeats
   validate's diagnostics 30 minutes later. Pushes to other branches do not
   trigger CI. Don't push in bursts — each push cancels the previous run, and a
   cancelled run does not save the bazel cache.

   `Make.py` passes `--experimental_ui_max_stdouterr_bytes=-1`. Without it
   bazel drops an action's entire stderr once it passes 1 MB, printing only
   "exceeds maximum size ...; skipping" — and TelegramUI is the target that
   crosses it, so a failing run digested as zero diagnostics.

   The oversized `ChatControllerInteraction` and `ChatPanelInterfaceInteraction`
   initializers produce "unable to type-check this expression in reasonable
   time" (or "failed to produce diagnostic") against an arbitrary interior
   line, hiding every real error in the module. Raising
   `-solver-expression-time-threshold` does not help. The remedy is to hoist
   the biggest closure arguments into `let fooImpl: <declared type> = { … }`
   *before* the initializer statement — not in place — and to split
   `openMessageImpl`'s action switch into `ChatControllerOpenMessageAction.swift`.
   Each hoist typically unmasks one genuine adapter error.

   **The bazel disk cache is the whole build time.** A validate run is ~6
   minutes when the cache holds (82% disk-cache hits, ~40 actions executed) and
   ~21 when it does not (57%, ~1700 executed) — the diff size barely matters; a
   17-line commit took 21 minutes. Read the `processes:` line in the digest
   before blaming anything else, and don't compare against the 2-3 minute runs
   in the history: those were cancelled, or died during analysis with a 46 s
   compile step.

   The `Trim Bazel cache` step's `LIMIT_MB` is in *uncompressed* megabytes,
   while GitHub's 10 GB per-repo budget counts the compressed artifact, and this
   cache compresses ~5:1 (7961 MB on disk → 1587 MB stored; main.yml's opt cache
   → 2120 MB). A debug working set is ~9 GB, so the old 7000 cap evicted ~1 GB
   per run that the next run rebuilt, and the hit rate never recovered once a
   commit low in the graph pushed it over. It is 14000 now. If build times creep
   back up, compare `Bazel disk cache: N MB` against the cap before anything
   else — `Freed` growing run over run is the thrash signature.

## Restructuring `exteraGram/` (module merges, directory moves)

`build-system/merge-tools/plan_module_merge.py` checks a proposed grouping of
the `exteraGram/` directories *before* anything is moved, and writes nothing.

Merging two Swift modules is the operation that turns a valid dependency chain
into a cycle: if `A → X → B` and A and B become one target, that target now
depends on X and X depends on it. Bazel only reports that during analysis,
which `--keep_going` does not soften, so it costs a whole CI round. The same
merge also drops the module boundary, turning a legal same-name pair in two
modules into an invalid redeclaration.

```
python3 build-system/merge-tools/plan_module_merge.py            # check LAYOUT
python3 build-system/merge-tools/plan_module_merge.py --suggest  # fix a cycle
```

The layout lives in `LAYOUT` in that file. On a cycle, `--suggest` splits the
offending groups until the contracted graph is acyclic and then coarsens the
result back to the fewest modules that still work. It also reports which
directories are `filegroup`s that compile into a *host* module through `egsrcs`
and therefore cannot be folded into a merged `swift_library` at all, the
`import` lines each group would make redundant, a leaf-first order to apply the
groups in, and how many external BUILD references each old label needs an
`alias()` for.
