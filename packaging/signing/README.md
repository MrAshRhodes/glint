# Release signing

Every Glint release is signed with one persistent, self-signed code-signing certificate,
**Glint Release Signing**. This keeps macOS privacy permissions such as Screen Recording
working across updates.

## Why

When a user grants Screen Recording, macOS (TCC) stores the app's *designated requirement*.
It honours the grant for any later version of the app that satisfies that requirement.

| Signature                | Designated requirement                                                        | After an update       |
| ------------------------ | ----------------------------------------------------------------------------- | --------------------- |
| ad-hoc (`codesign -s -`) | `cdhash H"…"`: one exact build                                                | permission lost (#39) |
| Glint Release Signing    | `identifier "io.github.mrashrhodes.glint" and certificate leaf = H"<sha1>"` | permission kept       |

The certificate is self-signed, so Gatekeeper treats the app exactly as before; the Homebrew
cask still clears the quarantine attribute. Only permission continuity changes.

## Files

- `designated-requirement.txt`: the requirement releases are signed to. `make signing-cert`
  writes it and it must be committed. `Scripts/verify_signature.sh --require-stable` (run by the
  release workflow) fails a release that does not satisfy it.
- The private key, certificate and `.p12` never go into the repository. By default they live in
  `~/.glint-signing/` (`glint-signing.key`, `glint-signing.crt`, `glint-signing.p12`,
  `glint-signing.p12.password`, `glint-signing.p12.base64`).

## One-time setup (maintainer)

```bash
make signing-cert                                 # or: Scripts/make_signing_cert.sh
gh secret set GLINT_SIGNING_P12_BASE64   < ~/.glint-signing/glint-signing.p12.base64
gh secret set GLINT_SIGNING_P12_PASSWORD < ~/.glint-signing/glint-signing.p12.password
git add packaging/signing/designated-requirement.txt
git commit -m "Add the release signing requirement"
```

`make signing-cert SIGNING_ARGS=--set-github-secrets` runs the two `gh secret set` commands
for you. Back up `glint-signing.p12` and its password (for example in a password manager).

## How releases use it

1. `.github/workflows/release.yml` imports the `.p12` into a temporary keychain
   (`Scripts/import_signing_identity.sh`). The pinned `designated-requirement.txt` must be committed.
   Without the secrets the release fails before building,
   unless the repository variable `GLINT_ALLOW_ADHOC_RELEASE` is `true` (an ad-hoc release resets
   Screen Recording permission for every user who updates).
2. `Scripts/build_app.sh` signs with `GLINT_SIGN_IDENTITY` (hardened runtime, secure timestamp)
   and, with `GLINT_REQUIRE_STABLE_SIGNATURE=1`, verifies the signature;
   `Scripts/package_release.sh` verifies the app inside the zip as well.
3. CI (`.github/workflows/ci.yml`) proves continuity on every push with a throwaway certificate:
   `Scripts/check_signing_continuity.sh` rebuilds the app with a new build number and checks that
   the rebuild satisfies the previous build's designated requirement, while ad-hoc copies do not.

Local builds (`make app`) stay ad-hoc unless `GLINT_SIGN_IDENTITY` is set, so a developer's own
Screen Recording grant has to be renewed after rebuilding.

## Rotating or losing the certificate

A release signed with a different certificate does not satisfy the old requirement: every user
has to re-grant Screen Recording once after updating. Avoid it. If it is unavoidable, run
`Scripts/make_signing_cert.sh --force`, update both secrets, commit the new
`designated-requirement.txt` and say so in the release notes.

## Checking a build

```bash
Scripts/verify_signature.sh dist/Glint.app --require-stable
codesign --display --requirements - /Applications/Glint.app
```
