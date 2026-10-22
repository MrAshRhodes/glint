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
| `make signing-cert` | One-time maintainer setup of the persistent release signing certificate. See [Release signing](#release-signing). |
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

## Product site

The dependency-free site in `site/` is published to <https://mrashrhodes.github.io/glint/> by `.github/workflows/pages.yml` on changes to that directory on `main`, or by manual workflow dispatch. The Pages publishing source must be **GitHub Actions**. Only `site/` is uploaded; research, source and build outputs are not published to Pages.

Preview with `python3 -m http.server 8000 --directory site` and visit <http://localhost:8000/>. Edit `index.html`, `guide.html`, `styles.css` and `site.js` directly. The Light Table shows real pre-rendered exports, not a browser editor: JavaScript adds subject/preset selection, an Original/Finished comparison and command copying. The static preview, installation instructions and guide remain useful without JavaScript. Keep all asset links relative for the `/glint/` project path (the custom 404 uses that absolute prefix).

Run `node --test .github/scripts/site.test.cjs` (Node.js 20+) for asset/link integrity and preview/clipboard regression coverage; CI runs it alongside the app tests. Also check the homepage, guide and 404 in a browser at desktop and narrow mobile widths, with keyboard navigation, reduced motion and JavaScript disabled. Preview requests are latest-wins: a failed or superseded image load must not change the displayed image or selected controls. The site follows the system light/dark preference by default; the header theme toggle (revealed by `site.js`) cycles System → Light → Dark, stores an explicit choice in `localStorage` as `glint-theme` and sets `<html data-theme>`. A small inline script in each page's `<head>` applies that choice before `styles.css` loads to avoid a flash; keep it identical on every page. Check both themes, including with JavaScript disabled.

`Scripts/make_site_assets.sh` draws original sample images and renders them through Glint. It needs a built app and `cwebp`; set `GLINT_BIN` to use a specific build. The fonts are self-hosted with their OFL license texts in `site/fonts/`. Do not add third-party product artwork or comparison branding.

## Packaging, releasing and signing

### Local packages

`make zip` and `make dmg` (or `Scripts/package_release.sh --version X.Y.Z`) build a universal app and write to `dist/`: `Glint-<version>.zip`, `Glint-<version>.dmg`, a `.sha256` file for each, and the Homebrew cask `glint.rb`. If the x86_64 slice cannot be built, `Scripts/build_app.sh --universal` falls back to arm64 only and says so; pass `--require-universal` to make that an error. The release workflow does.

### Cutting a release

1. On a branch from `main`, run `make prepare-release VERSION=X.Y.Z`. It moves the Unreleased entries in the [changelog](CHANGELOG.md) into a new `## [X.Y.Z] - YYYY-MM-DD` section dated today, leaves an empty Unreleased section, updates the version comparison links and writes `VERSION`. It refuses an empty Unreleased section, an existing version or a version older than the latest release. Review the result (adjust the date if the release happens on another day), open the usual issue-linked pull request, merge it to `main` and wait for CI to pass. CI runs `node .github/scripts/changelog.cjs check`, which validates the sections, dates, ordering and links.
2. Tag the merged commit and push the tag: `git tag v1.2.3 && git push origin v1.2.3`. Do not create the release by hand.
3. `.github/workflows/release.yml` first checks that `CHANGELOG.md` at the tag has a `## [1.2.3]` section and stops before building if it does not; to recover, delete the tag (`git push origin :refs/tags/v1.2.3 && git tag -d v1.2.3`), complete step 1 and tag again. It then builds the universal app, signed with the release certificate (see [Release signing](#release-signing)), creates the GitHub release with that changelog section followed by `.github/release-notes-header.md` as its notes, and attaches the zip, the dmg and their checksums. Tags containing a `-` (for example `v1.3.0-beta.1`) are marked as pre-releases, use the Unreleased entries as notes when they have no section of their own, and do not touch the Homebrew tap. Preview the notes with `node .github/scripts/changelog.cjs notes 1.2.3`.
4. Update the tap. If the repository secret `TAP_GITHUB_TOKEN` exists (a token that can push to the tap repository), the workflow does it. Otherwise, once the release workflow has finished, run `Scripts/update_tap.sh --version 1.2.3 --from-release`.

Published releases are immutable. The cask pins the sha256 of the release zip, and every build differs byte for byte, so replacing an asset would break `brew install` for everyone. The workflow therefore never overwrites an existing release: a re-run only retries the tap update, and `--from-release` always hashes the zip that is actually published. To rebuild a broken release, delete the release and its tag first, or cut a new version.

### Homebrew tap

Users install with `brew install --cask mrashrhodes/tap/glint`. The cask lives in the `MrAshRhodes/homebrew-tap` repository and is rendered from `packaging/homebrew/glint.rb.tmpl` by `Scripts/render_cask.sh`.

Updates are manual: users quit Glint, run `brew update && brew upgrade --cask glint`, then reopen it. `brew update` alone does not upgrade the app. Glint's Check for Updates action checks the latest GitHub release, not the tap; finish the tap update before announcing that Homebrew users can upgrade.

- Preview what a release would publish: `Scripts/update_tap.sh --version X.Y.Z --from-release --dry-run`. It prints the cask and diffs it against the tap without changing anything.
- Create the tap repository the first time (needs `gh auth login`): `Scripts/update_tap.sh --create`.
- The cask removes the quarantine flag in a `postflight_steps` block, because the app is not notarized. That skips Gatekeeper's check for this one app, which is why the cask caveats say so. Remove the block from the template if you would rather have users clear the flag themselves.

### Signing and permissions

macOS ties the Screen Recording permission to the app's code signature, specifically its designated requirement. For an ad-hoc signature (`codesign --sign -`) that requirement is the build's own hash, so every rebuild looks like a different app: the old grant stops applying, even if Glint still looks switched on in System Settings ([#39](https://github.com/MrAshRhodes/glint/issues/39)). With a certificate, the requirement names the bundle identifier and the certificate, which every later build signed with the same certificate satisfies.

- Local builds are signed ad-hoc by default, so after rebuilding you may have to grant the permission again: choose **Re-authorize Screen Recording…** in Preferences → About, or run `tccutil reset ScreenCapture io.github.mrashrhodes.glint`, then switch Glint on when macOS asks and relaunch. To avoid this, set `GLINT_SIGN_IDENTITY` to a code-signing identity of your own, for example a self-signed one created in Keychain Access. Switching between your build and an installed release still needs a re-grant, because they are signed with different certificates.
- Releases are signed with the persistent **Glint Release Signing** certificate; see [Release signing](#release-signing). Set `GLINT_REQUIRE_STABLE_SIGNATURE=1` to make a build or package fail instead of producing an ad-hoc signature.
- With an Apple Developer ID certificate, set `GLINT_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"` and the build also enables the hardened runtime and a secure timestamp. Notarization is not scripted.
- Before installing or updating a downloaded build, follow the [manual-download verification steps](README.md#install) using the ZIP or DMG and its matching `.sha256` file from the same official release. Continue only when verification succeeds and reports `OK`; otherwise stop without installing or clearing quarantine. If you trust the verified release and Gatekeeper blocks its first launch, clear the quarantine flag once: `xattr -dr com.apple.quarantine /Applications/Glint.app`. This bypasses the app's Gatekeeper quarantine check; do not ignore a malware warning.

### Release signing

Releases are signed with one persistent, self-signed code-signing certificate named **Glint Release Signing**. Every release then has the same designated requirement, `identifier "io.github.mrashrhodes.glint" and certificate leaf = H"<certificate SHA-1>"`, so macOS keeps Screen Recording permission across updates. It is not an Apple Developer ID: releases are still not notarized, and Gatekeeper behaves as before.

One-time maintainer setup:

1. Run `make signing-cert` (`Scripts/make_signing_cert.sh`). It creates the certificate and its `.p12` in `~/.glint-signing`, outside the repository, writes the expected requirement to `packaging/signing/designated-requirement.txt`, and prints the `gh secret set` commands for the repository secrets `GLINT_SIGNING_P12_BASE64` and `GLINT_SIGNING_P12_PASSWORD`. Run the script with `--set-github-secrets` to set them for you.
2. Commit `packaging/signing/designated-requirement.txt` through the usual issue-linked pull request.
3. Back up the `.p12` and its password somewhere safe, such as a password manager. A lost certificate cannot be recreated.

How releases use it:

- The release workflow imports the identity from the secrets (`Scripts/import_signing_identity.sh`), signs the app with it and checks the result with `Scripts/verify_signature.sh` against the pinned `packaging/signing/designated-requirement.txt`. A different certificate fails the release instead of silently resetting everyone's permission.
- CI checks continuity on every change: `Scripts/check_signing_continuity.sh` builds the app twice with a throwaway certificate and verifies that the second build satisfies the first build's designated requirement.
- Without the signing secrets, the workflow refuses to publish an ad-hoc build. Setting the repository variable `GLINT_ALLOW_ADHOC_RELEASE` to `true` allows one as a last resort, but every user who installs it has to grant Screen Recording again, and users who re-grant it there must grant once more on the next certificate-signed release.
- Losing or rotating the certificate changes the requirement, so every user grants Screen Recording once more after the next update. To rotate deliberately, run `Scripts/make_signing_cert.sh --force`, then update both secrets and commit the new `packaging/signing/designated-requirement.txt` in the same pull request, and call out the one-time re-grant in the changelog. Moving to an Apple Developer ID later works the same way (one more re-grant), but adds notarization.

### Environment variables

| Variable | Used by | Meaning |
| --- | --- | --- |
| `VERSION`, `CONFIG`, `INSTALL_DIR` | `make` | Release version, `release` or `debug`, install location. |
| `GLINT_SIGN_IDENTITY` | `build_app.sh`, `package_release.sh` | Code signing identity (default `-`, ad-hoc). Releases use `Glint Release Signing`. |
| `GLINT_REQUIRE_STABLE_SIGNATURE` | `build_app.sh`, `package_release.sh` | `1` fails the build or package when the app would be signed ad-hoc. |
| `GLINT_ALLOW_ADHOC_RELEASE` | release workflow (repository variable) | `true` lets a release be published without the signing certificate. See [Release signing](#release-signing). |
| `SWIFTW_MODE`, `SWIFTW_BUILD_SYSTEM`, `SWIFTW_VERBOSE` | `swiftw.sh` and everything that calls it | See [Command Line Tools only](#command-line-tools-only). `build_app.sh` defaults the build system to `native`. |
| `TAP_GITHUB_TOKEN` | `update_tap.sh` | Token used to push to the tap (default: your `gh` login). |

## Pull requests

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
