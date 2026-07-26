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

   Both filter to directories reachable from `Telegram/` through BUILD `deps`
   (`buildgraph.py`; `--all` disables it). `submodules/LegacyDataImport` and
   `exteraGram/Playground` are in the tree but in nothing's dependency graph,
   and have been failing both checks for releases without CI ever noticing.
   `check_syntax_debt.py` fails on leftover conflict markers — eight orphaned
   `>>>>>>> theirs` lines sat committed in `TelegramUI/Sources` for a whole
   bump, invisible because that module only compiles once everything below it
   is green. It also lists files whose delimiter balance differs from
   upstream's; that part is advisory (fork edits shift it legitimately) but it
   is how two broken merge resolutions were found — a stray `)` where a `}`
   should have closed an `else`, and an unclosed closure followed by a second
   `.startStrict(`.
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

   `check_engine_adapters.py` covers the fork's single largest source of
   compile errors: a `Peer`/`Message` handed across the boundary to a module
   that stayed on `EnginePeer`/`EngineMessage`, or the reverse. It resolves an
   argument's type only from explicit annotations — a function parameter, a
   `let x: T`, a stored property, or the parameter list of the closure a
   `asyncLayout()` returns — and stays quiet when it cannot, so a clean run is
   not proof. It is the only checker here that reads expressions rather than
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
