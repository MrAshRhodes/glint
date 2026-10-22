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
| `make app` | Assembles `dist/Glint.app` for this Mac and signs it ad-hoc (`CONFIG=debug` for a debug build). |
| `make universal` | Same, with arm64 and x86_64 slices merged by `lipo`. |
| `make run` | `make app`, then opens the app. It is a menu bar app, so look for its icon in the menu bar. |
| `make install` | Builds and copies `Glint.app` to `INSTALL_DIR` (default `/Applications`; quit a running Glint first). |
| `make zip` / `make dmg` | Release packaging into `dist/`: a universal build, the archive and its `.sha256`. |
| `make tap` | Renders the Homebrew cask to `dist/glint.rb`. |
| `make prepare-release VERSION=X.Y.Z` | Writes `VERSION` and moves the changelog's Unreleased entries into a dated `X.Y.Z` section, updating the comparison links. |
| `make icon` | Redraws `Resources/AppIcon.icns` and `docs/assets/icon-1024.png`. |
| `make clean` | Removes `.build` and `dist`. |

Every SwiftPM call goes through `Scripts/swiftw.sh`. With Xcode installed it is plain `swift`; on a Command Line Tools-only Mac it adds the flags described next.

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
3. `.github/workflows/release.yml` first checks that `CHANGELOG.md` at the tag has a `## [1.2.3]` section and stops before building if it does not; to recover, delete the tag (`git push origin :refs/tags/v1.2.3 && git tag -d v1.2.3`), complete step 1 and tag again. It then builds the universal app, creates the GitHub release with that changelog section followed by `.github/release-notes-header.md` as its notes, and attaches the zip, the dmg and their checksums. Tags containing a `-` (for example `v1.3.0-beta.1`) are marked as pre-releases, use the Unreleased entries as notes when they have no section of their own, and do not touch the Homebrew tap. Preview the notes with `node .github/scripts/changelog.cjs notes 1.2.3`.
4. Update the tap. If the repository secret `TAP_GITHUB_TOKEN` exists (a token that can push to the tap repository), the workflow does it. Otherwise, once the release workflow has finished, run `Scripts/update_tap.sh --version 1.2.3 --from-release`.

Published releases are immutable. The cask pins the sha256 of the release zip, and every build differs byte for byte, so replacing an asset would break `brew install` for everyone. The workflow therefore never overwrites an existing release: a re-run only retries the tap update, and `--from-release` always hashes the zip that is actually published. To rebuild a broken release, delete the release and its tag first, or cut a new version.

### Homebrew tap

Users install with `brew install --cask mrashrhodes/tap/glint`. The cask lives in the `MrAshRhodes/homebrew-tap` repository and is rendered from `packaging/homebrew/glint.rb.tmpl` by `Scripts/render_cask.sh`.

Updates are manual: users quit Glint, run `brew update && brew upgrade --cask glint`, then reopen it. `brew update` alone does not upgrade the app. Glint's Check for Updates action checks the latest GitHub release, not the tap; finish the tap update before announcing that Homebrew users can upgrade.

- Preview what a release would publish: `Scripts/update_tap.sh --version X.Y.Z --from-release --dry-run`. It prints the cask and diffs it against the tap without changing anything.
- Create the tap repository the first time (needs `gh auth login`): `Scripts/update_tap.sh --create`.
- The cask removes the quarantine flag in a `postflight_steps` block, because the app is not notarized. That skips Gatekeeper's check for this one app, which is why the cask caveats say so. Remove the block from the template if you would rather have users clear the flag themselves.

### Signing and permissions

- Builds are signed ad-hoc (`codesign --sign -`) because there is no Developer ID certificate. macOS ties the Screen Recording permission to the code signature, and an ad-hoc signature changes with every build, so after rebuilding you may have to grant it again: remove Glint in System Settings > Privacy & Security > Screen & System Audio Recording, add it back, or run `tccutil reset ScreenCapture io.github.mrashrhodes.glint`.
- With a certificate, set `GLINT_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"` and the build also enables the hardened runtime and a secure timestamp. Notarization is not scripted.
- Before installing or updating a downloaded build, follow the [manual-download verification steps](README.md#install) using the ZIP or DMG and its matching `.sha256` file from the same official release. Continue only when verification succeeds and reports `OK`; otherwise stop without installing or clearing quarantine. If you trust the verified release and Gatekeeper blocks its first launch, clear the quarantine flag once: `xattr -dr com.apple.quarantine /Applications/Glint.app`. This bypasses the app's Gatekeeper quarantine check; do not ignore a malware warning.

### Environment variables

| Variable | Used by | Meaning |
| --- | --- | --- |
| `VERSION`, `CONFIG`, `INSTALL_DIR` | `make` | Release version, `release` or `debug`, install location. |
| `GLINT_SIGN_IDENTITY` | `build_app.sh`, `package_release.sh` | Code signing identity (default `-`, ad-hoc). |
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
