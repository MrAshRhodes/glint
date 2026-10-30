# Contributing to Glint

Thanks for helping to make Glint better. This guide covers building, testing, how the code is organized, and how releases are made.

## Requirements

- macOS 14 (Sonoma) or later, Apple silicon or Intel.
- A Swift 5.9+ toolchain: either full Xcode (CI uses Xcode 26) or only the Command Line Tools (`xcode-select --install`). See [Command Line Tools only](#command-line-tools-only).
- Nothing else. There is no Xcode project and there are no third-party dependencies; Glint is a SwiftPM package plus a few shell scripts.

## Build, run, test

```sh
make help       # list every target
make build      # debug build of every target
make test       # run the test suite
make run        # assemble dist/Glint.app and open it
```

| Target | What it does |
| --- | --- |
| `make build` / `make release` | Debug / optimized build of every target. |
| `make test` | Runs the Swift Testing suite. |
| `make app` | Assembles `dist/Glint.app` for this Mac and signs it, ad-hoc unless `GLINT_SIGN_IDENTITY` is set (`CONFIG=debug` for a debug build). See [Signing and permissions](#signing-and-permissions). |
| `make universal` | Same, with arm64 and x86_64 slices merged by `lipo`. |
| `make run` | `make app`, then opens the app. It is a menu bar app, so look for its icon in the menu bar. |
| `make install` | Builds and copies `Glint.app` to `INSTALL_DIR` (default `/Applications`; quit a running Glint first). |
| `make zip` / `make dmg` | Release packaging into `dist/`: a universal build, the archive and its `.sha256`. |
| `make tap` | Renders the Homebrew cask to `dist/glint.rb`. |
| `make prepare-release VERSION=X.Y.Z` | Writes `VERSION` and moves the changelog's Unreleased entries into a dated `X.Y.Z` section, updating the comparison links. |
| `make signing-cert` | Create a throwaway self-signed certificate for local/CI tests, never release credentials. See [Release signing](#release-signing). |
| `make icon` | Redraws `Resources/AppIcon.icns` and `docs/assets/icon-1024.png`. |
| `make clean` | Removes `.build` and `dist`. |

Every SwiftPM call goes through `Scripts/swiftw.sh`. With Xcode installed it is plain `swift`; on a Command Line Tools-only Mac it adds the flags described next.

### Profiling the capture overlay

Use an optimized build (`make app`, not `CONFIG=debug`). On a Mac with full Xcode,
record Time Profiler and Points of Interest in Instruments, filtering signposts to
subsystem `io.github.mrashrhodes.glint`, category `SelectionOverlay`. Keep cold
(first capture after launching a new process) and warm captures separate. Compare
the same before/after revisions, displays, backing scales, refresh rates and input
path: area cursor motion, dragging (including Shift), and window-hover changes.
The intervals are `OverlaySetup` (synchronous entry work), `WindowEnumeration`,
`PanelCreation`, `OverlayFirstDraw` (session entry through the first panel's draw),
`FirstDraw`/`Draw` (per-view drawing CPU work), and `MouseMoved`, `MouseDragged`,
`MouseDown`, `MouseUp`, and `KeyDown` (handler CPU work). `InvalidationToDraw` spans
the oldest pending visual invalidation through that view's next draw completion;
coalesced events do not reset it. Intervals aborted on close are marked `cancelled`
and must be excluded from latency percentiles. Correlate these with input dispatch
and frame traces: invalidation omits earlier event processing, and draw completion
is **not** screen presentation. Use a presentation trace or external measurement
for real event-to-paint latency.
Report sample counts, p50/p95, and individual stalls over 50 ms in the first two
seconds. Check the actual display budget (16.7 ms at 60 Hz; 8.3 ms at 120 Hz) without
claiming unmeasured refresh rates or hardware. Signposts must not include cursor
coordinates, window metadata, or captured contents.

Signpost intervals can also be collected without Xcode or changes to system logging
settings. Start the collector before exercising an instrumented build, and use a
different output file for each cold/warm run:

```sh
mkdir -p .build/overlay-traces
/usr/bin/log stream --signpost --level debug --style ndjson --timeout 60 \
  --predicate 'subsystem == "io.github.mrashrhodes.glint" AND category == "SelectionOverlay"' \
  > .build/overlay-traces/cold.ndjson
```

The `--signpost` flag is required; `--level debug` alone does not collect these
intervals. Pair begin/end records by process ID, signpost ID, and signpost name,
ignoring the collector's non-event header/footer and cancelled intervals. The
collector stops after 60 seconds. This measures the instrumented intervals, not
WindowServer presentation or main-thread work outside them; retain the live frame
trace requirement above. The command has been smoke-tested against the offscreen
harness, which confirms collection but does not validate live overlay latency.

A bounded, permission-free CPU comparison also works with Command Line Tools:

```sh
Scripts/benchmark-overlay.sh baseline HEAD  # immutable git sources copied under .build/benchmark
Scripts/benchmark-overlay.sh current        # snapshot of current working sources
# Optional: compare clipped dirty regions instead of identical full-bounds draws.
DRAW_MODE=damage Scripts/benchmark-overlay.sh baseline HEAD
DRAW_MODE=damage Scripts/benchmark-overlay.sh current
```

The `swiftc -O` harness uses an unshown 1728 × 1117-point bitmap at 2×, three fixed
scenarios, 20 fresh processes per scenario, and 120 subsequent draws per process.
`ROUNDS=1..30` and `FRAMES=1..1000` bound the run. Each run preserves source hashes,
toolchain/host metadata, raw `samples.jsonl`, and percentile `summary.json` in
`.build/benchmark`. First draw really is the first overlay draw in that process,
but OS caches are not reset; view initialization and state-update time are reported
separately. No capture UI, capture permission request, or global mouse event is used.
These are synchronous CPU drawing measurements, **not** real mouse latency, frame
presentation, or a substitute for the live cold/warm acceptance trace above. Run
comparisons sequentially with other builds and heavy background work stopped. Damage
mode models a single draw with the disjoint dirty-region clip, not separate draws
for overlapping strips; the input sequence is synthetic and unpaced.

Reference CPU comparison for [#42](https://github.com/MrAshRhodes/glint/issues/42):
Apple M2 Max (Mac14,6), 32 GiB, macOS 26.6 (25G5065a), `swiftc -O`, baseline
`348266e6f8502d766c3ce9beefd5589686dcc080`, `DRAW_MODE=damage`, default run sizes.
Both runs were sequential, after tests/builds finished. Times below include state
update plus drawing, in milliseconds; each scenario has 20 fresh-process samples
and 2,400 warm samples. Physical display refresh rate is not part of this test.

| Scenario | First draw before p50/p95 | First draw after p50/p95 | Warm before p50/p95 | Warm after p50/p95 |
| --- | --- | --- | --- | --- |
| Area cursor | 26.852 / 41.412 | 26.532 / 30.770 | 18.052 / 18.801 | 0.302 / 0.347 |
| Area selection | 26.145 / 29.929 | 26.316 / 29.431 | 16.080 / 17.840 | 0.618 / 1.300 |
| Window hover | 26.973 / 30.038 | 27.266 / 31.244 | 18.546 / 19.700 | 0.001 / 4.746 |

The improvement is in repeated redraw work, including moves after the first draw
of a fresh session; **first-draw cost remains**. Window-hover samples include moves
within the same window, which now require no drawing. Neither run recorded a CPU
update/draw over 50 ms within its first two seconds, but this excludes setup and
real event scheduling and does not establish the live acceptance target. Live
cold/warm traces, perceived latency, and physical mixed-display verification remain
outstanding; the signpost collector above is available on a Command Line Tools-only
host, but still requires exercising the actual capture UI.
The per-sample JSONL, summaries, manifests and source snapshots for this comparison
are retained locally under `.build/benchmark/baseline-20261022T151935Z-44265` and
`.build/benchmark/current-20261022T152237Z-60304` (ignored build artifacts; rerun the
commands above on another checkout).

## Command Line Tools only

Glint builds without Xcode, with a few differences:

- SwiftPM's default build engine needs Xcode, so builds use `--build-system native`. `Scripts/swiftw.sh` adds it for you and the resulting deprecation warning can be ignored.
- Swift Testing ships inside the Command Line Tools but is not on the default search paths. `make test` passes the extra flags; spelled out, it is:

  ```sh
  CLT=/Library/Developer/CommandLineTools/Library/Developer
  swift test --build-system native \
    -Xswiftc -F -Xswiftc $CLT/Frameworks \
    -Xlinker -F -Xlinker $CLT/Frameworks \
    -Xlinker -rpath -Xlinker $CLT/Frameworks \
    -Xlinker -rpath -Xlinker $CLT/usr/lib
  ```

- There is no XCTest, `xcodebuild`, `ibtool` or `actool`. That is why tests use Swift Testing, the UI is built in code and the app icon is drawn by `Scripts/make_icon.swift` rather than compiled from an asset catalog.

`Scripts/swiftw.sh` reads three environment variables: `SWIFTW_MODE` (`auto`, `xcode` or `clt`; overrides toolchain detection), `SWIFTW_BUILD_SYSTEM` (always pass `--build-system <value>`) and `SWIFTW_VERBOSE=1` (print the final command).

## Project layout

```
Package.swift             Four targets plus the tests
Sources/GlintCore         Models, compositor/renderer, auto-balance, OCR + redaction, export, presets
Sources/GlintCapture      ScreenCaptureKit capture, selection overlay, window picker, global hotkeys
Sources/GlintEditor       Annotation editor: canvas, tools, inspector sidebar, export actions
Sources/Glint             App shell: menu bar item, preferences, quick-access overlay, URL scheme, updates
Tests/GlintCoreTests      Swift Testing suites for GlintCore
Resources/                Info.plist, entitlements and the generated app icon
Scripts/                  Build, packaging and release scripts
packaging/homebrew/       Homebrew cask template
.github/workflows/        CI and release workflows
site/                     Static product site and user guide (GitHub Pages)
```

## Architecture

```
Glint (executable) ──► GlintCapture ──► GlintCore
        │
        ├────────────► GlintEditor  ──► GlintCore
        └────────────► GlintCore
```

- **GlintCore** is the foundation and has no dependency on the other targets. It holds the document model, the renderer that composites a screenshot onto a background, auto-balance, OCR and redaction, export, and presets. It stays free of windows and views so that it can be unit tested; Foundation, CoreGraphics, CoreImage and Vision are all fine here.
- **GlintCapture** turns "the user wants a screenshot" into an image: ScreenCaptureKit, the selection overlay, the window picker and the global hotkeys.
- **GlintEditor** is the annotation editor: the canvas, the tools and the inspector sidebar.
- **Glint** is the app shell. It owns the menu bar item, preferences, the quick-access overlay, the `glint://` URL scheme and update checks, and wires the other targets together.

## Adding a feature

1. Put the model and the logic in **GlintCore** and write the tests first in `Tests/GlintCoreTests` (`import Testing`, `@Suite`, `@Test`, `#expect`).
2. Build the user interface in **GlintEditor** (editing) or **GlintCapture** (capturing). Keep UI and ScreenCaptureKit types out of GlintCore.
3. Connect it in the **Glint** app shell: a menu item, a preference, a hotkey or a URL scheme command.
4. Run `make test`, then `make run` and try the feature by hand.
5. A new permission needs a usage description in `Resources/Info.plist`. New resources (images, strings) are declared in `Package.swift`; `Scripts/build_app.sh` copies every SwiftPM `*.bundle` into the app on its own.

## Code style

- Follow the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/). Use four-space indentation and keep lines around 120 columns or fewer.
- Prefer value types, small focused files and `let` over `var`. Mark UI code `@MainActor`. Avoid `!` and `try!` outside tests.
- Document public API with `///` comments and explain why, not what.
- Do not add a third-party dependency without discussing it in an issue first.

## Capture snapping and the content-detection gate

The first stage of [#43](https://github.com/MrAshRhodes/glint/issues/43) supports window bounds and display edges only. Window rectangles are sampled front-to-back once per selection session, with covered edge segments removed before interaction. This is geometry, not recognition of arbitrary content. It requires no new permission and no analysis screenshot. Keep candidate building out of mouse-move handlers, use global CG display points rather than physical pixels, and preserve raw input when applying temporary snapping.

### Offline content-edge investigation

`Scripts/probe_content_edges.swift` is a standalone, synthetic-only feasibility probe, **not app code**. Run it with `Scripts/swiftw.sh Scripts/probe_content_edges.swift`; to measure optimized detector time, compile it with `xcrun swiftc -O Scripts/probe_content_edges.swift -o /tmp/glint-content-probe` and run that executable. It never captures the desktop or reads/writes images, history or clipboard.

The baseline accepts axis-aligned contrast runs of at least 48 sample pixels with a grayscale step of at least 40/255, on bounded 512×320 inputs, capped at 64 candidates. These are proposed edge classes, not a general content detector. Ground truth labels the card/control boundaries as targets and decorative stripes/text as non-targets. One-to-one matching allows one sample pixel of coordinate/endpoint error:

| Synthetic fixture | True positives | False positives | Missed target edges |
| --- | ---: | ---: | ---: |
| High-contrast card | 4 | 0 | 0 |
| Low-contrast card | 0 | 0 | 4 |
| Uniform image | 0 | 0 | 0 |
| Decorative stripes | 0 | 40 | 0 |
| Short text-like strokes | 0 | 0 | 0 |
| Long rules/underlines | 0 | 20 | 0 |
| Card moved between snapshots | 4 | 0 | 0 |
| Small control below minimum length | 0 | 0 | 4 |

An optimized local run on 2026-10-22 measured 0.30–0.36 ms for the first detector invocation per fixture and 0.30–0.32 ms warm medians (25 iterations). These timings exclude screen acquisition, downsampling and overlay rendering; they are **not** first-capture or pointer-responsiveness measurements. Aggregate precision is 8/68 (11.8%) and recall 8/16 (50%) on this deliberately mixed set. Real desktop accuracy is unmeasured. Raising confidence from these pixel runs alone cannot distinguish decoration from a meaningful boundary; low-contrast/small targets are missed, and moving content changes candidates between snapshots. **Content detection remains disabled**, with no target-choice UI.

Before enabling a content mode, improve and measure the detector against representative images (including texture, text, low contrast and motion), define supported edge classes and acceptance thresholds, and add asynchronous cancellation/stale-result tests. Analysis must use an in-memory ScreenCaptureKit snapshot with `allowScreencaptureFallback = false`, excluding Glint's windows and requiring the existing Screen Recording grant. Never route analysis through the temporary-PNG fallback, history, export or clipboard. Snapshot acquisition must start only for an explicitly requested capture, not at launch or when opening Preferences. Freeze accepted targets for the drag, release buffers on completion/cancellation, and report permission/detection failure while retaining window/free selection. Permission-denial/cancellation integration checks remain a gate for this unshipped phase.

### Interactive release checks

After `make test` and `make app`, check the same selection through area, area-to-clipboard, OCR-area and timed-area capture. Check live menu/Preferences synchronization, restart persistence and reset. Verify Command-click, including a first click on a secondary display, reaches the non-activating panel without moving it; starting a selection while the hotkey's Command is still held settles to the saved setting once released; stationary Command press/release updates the preview; Shift makes a square in each quadrant; Shift-arrow nudges by 10; and Space/Return/Esc/right-click keep their existing behavior. Compare preview and output at partially occluded edges, with no nearby windows, at display boundaries, and across negative-coordinate/mixed-Retina display arrangements.

Profile both the first overlay and a warm overlay with snapping off/on. Record candidate preparation separately from input handling and drawing; synthetic geometry timings alone cannot establish that first-load lag ([#42](https://github.com/MrAshRhodes/glint/issues/42)) is unchanged. Do not enumerate windows, capture pixels or run a detector per pointer event.

## Reopen Last Image and Output retention

Keeping copied and dragged images is opt-in ([#52](https://github.com/MrAshRhodes/glint/issues/52)). Unit tests use temporary directories, a controllable clock, an injected trash closure and private `UserDefaults` suites, never your real Output folder or Trash.

### Retention release checks

After `make test` and `make app`, point Preferences → Output → History folder at a scratch folder and check both the menu bar menu and the File menu:

1. **Defaults.** After **Reset all preferences**, or when upgrading from a release without this feature, the toggle is off, the period is **Forever**, **Reopen Last Image** is dimmed, and copying, dragging and waiting save and remove nothing (no `.glint-output-index.json` appears).
2. **Copy, drag, reopen.** Turn on **Keep copied and dragged screenshots for reopening**. For editor **Copy ⌘C**, a clipboard-only capture (⌃⌥⌘5), **Copy to clipboard** after capture, **Drag to share** and a quick-access thumbnail drag: finish the action, close the editor or let the thumbnail disappear, replace the clipboard, then choose **Reopen Last Image**. It opens the composed image with annotations and redactions intact and no second frame or background, and repeating the action with the unchanged image creates no duplicate in `Output/`. A failed render keeps nothing; an unwritable Output folder shows a notification while the copy or drag still succeeds.
3. **Restart persistence.** Copy an image and quit Glint immediately. Glint waits up to three seconds for pending writes; if they are still running, it cancels that quit attempt and notifies you to quit again once saving finishes. After relaunching, **Reopen Last Image** still opens it and **Open Recent** lists it. Delete the newest kept file in Finder: the item opens the next newest image, or is dimmed when none is left; an unreadable file is reported and forgotten. Opening either menu must stay responsive during slow cleanup, and its Reopen item updates when the background availability check finishes. Unavailable ordinary recent files are hidden, not forgotten, so reconnecting their drive restores them.
4. **Other settings.** With **Save styled output** on, the kept image is the file already saved, not a second one. `Raw/`, files saved with Save or Save As, and files that were already in `Output/` are never changed.
5. **Cleanup.** Choose **1 day**. With Glint quit, set the `date` (seconds since 1970) of two kept images in the scratch `.glint-output-index.json` to more than a day ago, `touch` one of them, and add a symlink, a pre-existing image, a Raw image and a manual save, then relaunch. Shortly after launch only the untouched back-dated image moves to the Trash. The `touch`ed image stays and is no longer tracked, the other files stay, a file being dragged is skipped, and nothing is removed the instant the picker changes. Choosing **Forever** again removes nothing else.
6. **History off.** Turn **Keep history** off: the toggle is dimmed with an explanation, nothing new is kept or removed, and Glint never turns history back on. Turning it on again resumes keeping and cleanup.

## Product site

The dependency-free site in `site/` is published to <https://mrashrhodes.github.io/glint/> by `.github/workflows/pages.yml` on changes to that directory on `main`, or by manual workflow dispatch. The Pages publishing source must be **GitHub Actions**. Only `site/` is uploaded; research, source and build outputs are not published to Pages.

Preview with `python3 -m http.server 8000 --directory site` and visit <http://localhost:8000/>. Edit `index.html`, `guide.html`, `styles.css` and `site.js` directly. The Light Table shows real pre-rendered exports, not a browser editor: JavaScript adds subject/preset selection, an Original/Finished comparison and command copying. The static preview, installation instructions and guide remain useful without JavaScript. Keep all asset links relative for the `/glint/` project path (the custom 404 uses that absolute prefix).

Run `node --test .github/scripts/site.test.cjs` (Node.js 20+) for asset/link integrity and preview/clipboard regression coverage; CI runs it alongside the app tests. Also check the homepage, guide and 404 in a browser at desktop and narrow mobile widths, with keyboard navigation, reduced motion and JavaScript disabled. Preview requests are latest-wins: a failed or superseded image load must not change the displayed image or selected controls. The site follows the system light/dark preference by default; the header theme toggle (revealed by `site.js`) cycles System → Light → Dark, stores an explicit choice in `localStorage` as `glint-theme` and sets `<html data-theme>`. A small inline script in each page's `<head>` applies that choice before `styles.css` loads to avoid a flash; keep it identical on every page. Check both themes, including with JavaScript disabled.

`Scripts/make_site_assets.sh` draws original sample images and renders them through Glint. It needs a built app and `cwebp`; set `GLINT_BIN` to use a specific build. The fonts are self-hosted with their OFL license texts in `site/fonts/`. Do not add third-party product artwork or comparison branding.

## Packaging, releasing and signing

### Local packages

`make zip` and `make dmg` (or `Scripts/package_release.sh --version X.Y.Z`) build a universal app and write to `dist/`: `Glint-<version>.zip`, `Glint-<version>.dmg`, a `.sha256` file for each, and the Homebrew cask `glint.rb`. If the x86_64 slice cannot be built, `Scripts/build_app.sh --universal` falls back to arm64 only and says so; pass `--require-universal` to make that an error. The release workflow does.

These default local packages are not notarized and must not be published as releases. With Developer ID and notarization credentials configured, pass `--notarize --require-universal`; see the [signing and notarization guide](packaging/signing/README.md#local-packaging-and-verification).

### Cutting a release

1. On a branch from `main`, run `make prepare-release VERSION=X.Y.Z`. It moves the Unreleased entries in the [changelog](CHANGELOG.md) into a new `## [X.Y.Z] - YYYY-MM-DD` section dated today, leaves an empty Unreleased section, updates the version comparison links and writes `VERSION`. It refuses an empty Unreleased section, an existing version or a version older than the latest release. Review the result (adjust the date if the release happens on another day), open the usual issue-linked pull request, merge it to `main` and wait for CI to pass. CI runs `node .github/scripts/changelog.cjs check`, which validates the sections, dates, ordering and links.
2. Tag the merged commit and push the tag: `git tag v1.2.3 && git push origin v1.2.3`. Do not create the release by hand.
3. `.github/workflows/release.yml` first checks that `CHANGELOG.md` at the tag has a `## [1.2.3]` section and stops before building if it does not; to recover, delete the tag (`git push origin :refs/tags/v1.2.3 && git tag -d v1.2.3`), complete step 1 and tag again. It then builds the universal app, signs it with Apple Developer ID, notarizes and staples the app and DMG (see [Release signing](#release-signing)), and verifies the stapled app inside the ZIP. Only then does it create the GitHub release with that changelog section followed by `.github/release-notes-header.md` as its notes and attach the zip, the dmg and their final checksums. Tags containing a `-` (for example `v1.3.0-beta.1`) are marked as pre-releases, use the Unreleased entries as notes when they have no section of their own, and do not touch the Homebrew tap. Preview the notes with `node .github/scripts/changelog.cjs notes 1.2.3`.
4. Update the tap. If the repository secret `TAP_GITHUB_TOKEN` exists (a token that can push to the tap repository), the workflow does it. Otherwise, once the release workflow has finished, run `Scripts/update_tap.sh --version 1.2.3 --from-release`.

Published releases are immutable. The cask pins the sha256 of the release zip, and every build differs byte for byte, so replacing an asset would break `brew install` for everyone. The workflow therefore never overwrites an existing release: a re-run only retries the tap update, and `--from-release` always hashes the zip that is actually published. To rebuild a broken release, delete the release and its tag first, or cut a new version.

### Homebrew tap

Users install with `brew install --cask mrashrhodes/tap/glint`. The cask lives in the `MrAshRhodes/homebrew-tap` repository and is rendered from `packaging/homebrew/glint.rb.tmpl` by `Scripts/render_cask.sh`.

Updates are manual: users quit Glint, run `brew update && brew upgrade --cask glint`, then reopen it. `brew update` alone does not upgrade the app. Glint's Check for Updates action checks the latest GitHub release, not the tap; finish the tap update before announcing that Homebrew users can upgrade.

- Preview what a release would publish: `Scripts/update_tap.sh --version X.Y.Z --from-release --dry-run`. It prints the cask and diffs it against the tap without changing anything.
- Create the tap repository the first time (needs `gh auth login`): `Scripts/update_tap.sh --create`.
- The cask preserves quarantine and Gatekeeper checks. Publish only Developer ID-signed, notarized artifacts; never restore a quarantine-removal workaround.

### Signing and permissions

macOS ties the Screen Recording permission to the app's code signature, specifically its designated requirement. For an ad-hoc signature (`codesign --sign -`) that requirement is the build's own hash, so every rebuild looks like a different app: the old grant stops applying, even if Glint still looks switched on in System Settings ([#39](https://github.com/MrAshRhodes/glint/issues/39)). Developer ID builds instead use the Apple trust chain, team identifier and bundle identifier, allowing later builds to satisfy the same requirement.

- Local builds are signed ad-hoc by default, so after rebuilding you may have to grant the permission again: choose **Re-authorize Screen Recording…** in Preferences → About, or run `tccutil reset ScreenCapture io.github.mrashrhodes.glint`, then switch Glint on when macOS asks and relaunch. To avoid this, set `GLINT_SIGN_IDENTITY` to a code-signing identity of your own, for example a self-signed one created in Keychain Access. Switching between your build and an installed release still needs a re-grant, because they are signed with different certificates.
- The release pipeline requires **Developer ID Application** signing, hardened runtime and a secure timestamp. `GLINT_REQUIRE_STABLE_SIGNATURE=1` also prevents local builds or packages from using ad-hoc signing.
- `Scripts/package_release.sh --notarize` requires Glint's Developer ID identity and configured notarization credentials, and fails unless the final artifacts pass ticket validation and Gatekeeper assessment. See [Release signing](#release-signing).
- Before installing or updating a downloaded build, follow the [manual-download verification steps](README.md#install) using the ZIP or DMG and its matching `.sha256` file from the same official release. Continue only when verification succeeds and reports `OK`; otherwise stop without installing or clearing quarantine. If Gatekeeper rejects the app, stop and investigate rather than bypassing the warning.

### Release signing

Glint uses Developer ID signing and notarization for direct GitHub/Homebrew distribution, not the Mac App Store. Follow the [maintainer signing guide](packaging/signing/README.md) for certificate setup, encrypted backup and recovery, the notarization API key, local packaging, and the five secrets in the protected GitHub **release** environment.

The tag workflow requires the public Apple team and bundle requirements in `packaging/signing/`, notarizes and staples the app and DMG, verifies the app extracted from the ZIP, and generates checksums after stapling. Missing credentials, an invalid signature, incomplete notarization or Gatekeeper rejection stops publication. There is no unsigned or self-signed fallback. Temporary signing and notarization credentials are cleaned up even on failure.

Pull-request CI uses `make signing-cert` only to create a throwaway **test** identity outside the repository. `Scripts/check_signing_continuity.sh` verifies that a rebuilt app satisfies the previous build's requirement without exposing production credentials; it does not prove end-user TCC behavior. The helper cannot overwrite production requirements.

The first Developer ID update from 1.5.3 or earlier needs one Screen Recording re-grant because the legacy signing requirement changes. Subsequent same-team Developer ID updates should preserve the grant. Before renewing the certificate, verify the new build against the previous released app's actual requirement and perform the [manual upgrade checks](packaging/signing/README.md#permissions-renewal-and-tests). Never rotate production identity by running the test certificate helper.

### Environment variables

| Variable | Used by | Meaning |
| --- | --- | --- |
| `VERSION`, `CONFIG`, `INSTALL_DIR` | `make` | Release version, `release` or `debug`, install location. |
| `GLINT_SIGN_IDENTITY` | `build_app.sh`, `package_release.sh` | Code signing identity (default `-`, ad-hoc). Releases require Glint's Developer ID Application identity. |
| `GLINT_REQUIRE_STABLE_SIGNATURE` | `build_app.sh`, `package_release.sh` | `1` fails the build or package when the app would be signed ad-hoc. |
| `GLINT_REQUIREMENT_FILE` | signing verification | Test requirement override; cannot replace the Apple policy enforced by `--require-developer-id` or `--require-notarized`. |
| `GLINT_NOTARY_PROFILE`, `GLINT_NOTARY_KEYCHAIN` | `notarize.sh` | Stored notarytool Keychain profile and optional keychain path. |
| `GLINT_NOTARY_KEY_PATH`, `GLINT_NOTARY_KEY_ID`, `GLINT_NOTARY_ISSUER_ID` | `notarize.sh` | Team API private-key path, key ID and issuer ID; all required when no profile is set. CI decodes the key from its environment secret. |
| `SWIFTW_MODE`, `SWIFTW_BUILD_SYSTEM`, `SWIFTW_VERBOSE` | `swiftw.sh` and everything that calls it | See [Command Line Tools only](#command-line-tools-only). `build_app.sh` defaults the build system to `native`. |
| `TAP_GITHUB_TOKEN` | `update_tap.sh` | Token used to push to the tap (default: your `gh` login). |

## Pull requests

Please follow the [Code of Conduct](CODE_OF_CONDUCT.md). Report vulnerabilities
privately using the [security policy](SECURITY.md), not in a public issue.

Every change to `main` needs an issue and a pull request, including documentation, maintenance, dependency and workflow changes. Do not push directly to `main`.

1. Create or choose an issue in `MrAshRhodes/glint` that describes the change.
2. Create a focused branch from `main`, for example `feat/123-short-description`.
3. Open a pull request to `main` and put `Fixes #123` in its description, outside comments and code blocks. `Closes` and `Resolves` also work, as do same-repository issue URLs. A PR number, nonexistent issue or issue in another repository does not count. Existing closed issues are allowed for follow-up work.
4. Add or update tests for behavior changes. Run `make test` and `make app`; run `node --test .github/scripts/issue-link.test.cjs` when changing the issue-link policy and `node --test .github/scripts/changelog.test.cjs` when changing the changelog tooling (Node.js 20+).
5. Record notable user-visible changes under Unreleased in the [changelog](CHANGELOG.md), grouped as Added, Changed, Deprecated, Removed, Fixed, or Security. Call out breaking changes and any action users need to take. These entries become the release notes, and CI fails if the changelog is malformed, for example when a `[#123]` reference has no link definition at the bottom of the file.
6. Resolve review conversations, bring the branch up to date and wait for the required **Build and test** and **Issue link** checks before merging.

The issue-link check runs again when a PR is opened, reopened, updated, marked ready or its description is edited. It reads the current description and verifies the referenced issues with a read-only token. Do not rename either required job without updating branch protection.

### Main branch protection

Branch protection is configured in GitHub under **Settings > Branches**, not by the CI workflow itself. `main` requires a pull request, resolved conversations, and both checks from GitHub Actions, with the branch up to date before merging. These requirements apply to administrators too; force-pushes and branch deletion are disabled.

No second-person approval is required, so a solo maintainer can merge their own PR after the checks pass. Maintainers should review changes to the policy workflow itself, since it is part of the proposed code on a `pull_request` run. The workflow has no write permissions or deployment secrets and never interpolates PR text into executable code. Normal CI must not receive an admin token to change branch protection.
