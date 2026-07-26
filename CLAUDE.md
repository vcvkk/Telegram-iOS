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
   python3 build-system/merge-tools/check_api_drift.py --upstream /tmp/upstream/release-<NEW>
   python3 build-system/merge-tools/check_syntax_debt.py --upstream /tmp/upstream/release-<NEW>
   ```
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

   Add an entry to `fork_registry.json` whenever a bump turns out to have
   dropped something.
6. **CI.** Both workflows run on `master` only: `validate.yml` (debug, compile
   only, `--keep_going`, error digest in the run summary) for fast feedback,
   and `main.yml` for the full release build. Pushes to other branches do not
   trigger CI. Don't push in bursts — each push cancels the previous run of
   both workflows, and a cancelled run does not save the bazel cache.