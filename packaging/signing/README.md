# Developer ID signing and notarization

Glint is distributed directly through GitHub Releases and Homebrew, **not the Mac App Store**.
The release pipeline requires an Apple **Developer ID Application** certificate, hardened
runtime, a secure timestamp and successful Apple notarization. It staples tickets to the app
before creating the ZIP, and to the signed DMG before generating checksums. Gatekeeper stays
enabled; the cask does not remove quarantine.

Published releases through 1.5.3 are legacy, unnotarized builds. They are not retroactively
re-signed or replaced. The first Developer ID release requires a one-time Screen Recording
re-grant for users upgrading from those builds.

## Requirements and public signing policy

- Active Apple Developer Program membership, Xcode command-line tools including `notarytool`
  and `stapler`, and `jq`.
- A valid Developer ID Application identity with its private key. The release identity is
  `Developer ID Application: Ashley Rhodes (TB3Z5R7SY8)`.
- A notarization credential: a local Keychain profile, or an App Store Connect **team API key**
  authorized for the notary service. The API's name does not imply App Store distribution;
  no app listing, App Store provisioning profile or App Store upload is needed.

`developer-id-requirement.txt` requires an Apple-trusted Developer ID Application certificate
for team `TB3Z5R7SY8`. `designated-requirement.txt` also requires bundle identifier
`io.github.mrashrhodes.glint`. These are public policy files, not credentials. Production
verification always uses them, even when `GLINT_REQUIREMENT_FILE` points at a test requirement.
Do not replace them with a self-signed certificate hash.

## Certificate and encrypted backup

Create a Developer ID Application certificate in the Apple Developer account using a CSR
generated on the Mac that will hold its private key. Install the issued certificate in
Keychain Access and confirm that it appears under **My Certificates**, with its private key.
Check that `security find-identity -v -p codesigning` lists the expected identity.

In Keychain Access, export **only that certificate and its private key** as a password-protected
PKCS#12 (`.p12`). Do not export the entire login keychain. Keep the `.p12` outside the repository,
for example `~/.glint-signing/developer-id/glint-developer-id.p12`, with permissions `0600`
inside a `0700` directory. Store its strong password separately in Keychain or a password manager.
Never commit private keys, passwords, `.p12` files or base64 encodings of them.

Keep an encrypted copy off this Mac and verify recovery by importing it into a temporary
keychain, comparing the certificate fingerprint and signing a disposable test binary. Remove
that keychain afterward and restore the original keychain search list. Losing the private key
cannot be repaired by downloading the public certificate again.

## Notarization credentials

Create a dedicated team API key for notarization with only the role Apple requires for the
notary service. Download its `.p8` once, store it outside the repository with permissions `0600`,
and record its key ID and issuer ID. Back up the key securely; revoke and replace it if exposed.

For local releases, store the credentials in Keychain (substitute your own IDs and path):

```bash
xcrun notarytool store-credentials glint-notary \
  --key "$HOME/.glint-signing/developer-id/AuthKey_KEYID.p8" \
  --key-id KEYID --issuer ISSUER_UUID
GLINT_NOTARY_PROFILE=glint-notary Scripts/notarize.sh --check-credentials
```

Alternatively set `GLINT_NOTARY_KEY_PATH`, `GLINT_NOTARY_KEY_ID` and
`GLINT_NOTARY_ISSUER_ID` together. A nonempty `GLINT_NOTARY_PROFILE` takes precedence;
`GLINT_NOTARY_KEYCHAIN` optionally selects the keychain containing that profile.
Credential preflight contacts Apple and fails before building when authentication fails.

## GitHub Actions setup

Use a GitHub environment named **release**, restricted to deployment from **tags matching
`v*`**, not branches. Restrict who can create release tags and consider required environment
reviewers according to the repository's protection policy. Only the tag-triggered release job
uses this environment; pull-request CI never receives production signing credentials.

Set these **environment secrets**, not repository variables:

| Secret | Value |
| --- | --- |
| `GLINT_SIGNING_P12_BASE64` | Base64 of the encrypted Developer ID `.p12`. |
| `GLINT_SIGNING_P12_PASSWORD` | The `.p12` password. |
| `GLINT_NOTARY_KEY_P8_BASE64` | Base64 of the dedicated notarization `.p8`. |
| `GLINT_NOTARY_KEY_ID` | The API key's key ID. |
| `GLINT_NOTARY_ISSUER_ID` | The team API key's issuer ID. |

For file-backed secrets, pipe directly into `gh` rather than printing them:

```bash
base64 < "$HOME/.glint-signing/developer-id/glint-developer-id.p12" |
  gh secret set GLINT_SIGNING_P12_BASE64 --env release --repo MrAshRhodes/glint
base64 < "$HOME/.glint-signing/developer-id/AuthKey_KEYID.p8" |
  gh secret set GLINT_NOTARY_KEY_P8_BASE64 --env release --repo MrAshRhodes/glint
```

Enter the other values using GitHub's secret editor or protected standard input. Remove
obsolete repository-level self-signed signing secrets once the migration is confirmed;
environment secrets override same-named repository secrets, but stale credentials are confusing.
`TAP_GITHUB_TOKEN` remains separate and is only for updating the Homebrew tap.

The workflow imports the identity into a temporary keychain, decodes the `.p8` into a private
runner temporary file, and removes both in `always()` cleanup steps before publication.
Missing credentials, a wrong identity, failed or incomplete notarization, missing tickets
and Gatekeeper rejection all stop the release. There is no ad-hoc or self-signed escape hatch.
Never enable shell tracing around credentials.

## Local packaging and verification

With the Developer ID identity installed and the Keychain profile configured:

```bash
GLINT_SIGN_IDENTITY="Developer ID Application: Ashley Rhodes (TB3Z5R7SY8)" \
GLINT_NOTARY_PROFILE=glint-notary \
  Scripts/package_release.sh --version X.Y.Z --require-universal --notarize
```

The script builds both architectures, checks the Apple signing policy, notarizes and staples
the app, creates the ZIP, and checks the freshly extracted app. It then creates, signs,
notarizes and staples the DMG. Only after each final artifact is complete is its checksum
written; the Homebrew cask is rendered last. A ZIP itself cannot be stapled.

```bash
Scripts/verify_signature.sh dist/Glint.app --require-notarized
xcrun stapler validate dist/Glint-X.Y.Z.dmg
spctl --assess --type open --context context:primary-signature --verbose=2 dist/Glint-X.Y.Z.dmg
(cd dist && shasum -a 256 -c Glint-X.Y.Z.zip.sha256 -c Glint-X.Y.Z.dmg.sha256)
```

Do not publish output from ordinary `make zip` or `make dmg`: those local-development commands
do not request notarization. The tag workflow always passes `--notarize --require-universal`.
Follow [Cutting a release](../../CONTRIBUTING.md#cutting-a-release); never overwrite published
assets, since the Homebrew cask pins their checksum. A prerelease tag exercises the protected
workflow without updating the tap, but **does publish a GitHub prerelease**.

## Permissions, renewal and tests

macOS stores an app's designated requirement with its Screen Recording grant. Ad-hoc builds
pin one build's hash. Legacy self-signed Glint builds pinned a certificate hash; Developer ID
builds use an Apple trust chain, team identifier and bundle identifier instead.

When upgrading from 1.5.3 or earlier to the first Developer ID release, choose
**Re-authorize Screen Recording...** in Preferences > About, allow Glint in System Settings,
then relaunch. Subsequent Developer ID builds are expected to preserve the grant. Renewing
the certificate within the same team should preserve the requirement, but verify the new
build against the previous released app's actual designated requirement before shipping.
Changing the team or bundle identifier needs an explicit migration and permission re-grant.

`make signing-cert` creates a **throwaway self-signed test identity**, not a release credential.
Its default output is `~/.glint-signing/test`, including its test requirement file. It refuses
to overwrite either production requirement, even with `--force`. CI passes a runner-temporary
output directory and uses this identity to exercise `Scripts/check_signing_continuity.sh`
without production secrets. The check proves signature continuity, not macOS's actual TCC
behavior. `node --test .github/scripts/notarize.test.cjs` covers failure gates with mocked
Apple tools; real notarization still requires the protected credentials.

Before announcing the first Developer ID release, test on a clean Mac: download through a
browser so quarantine is present, verify checksums, install from both ZIP and DMG without
clearing quarantine, launch and capture after granting Screen Recording. Also test an upgrade
from a legacy release (one re-grant) and between two Developer ID builds (grant retained).
Local signature checks alone do not establish those end-user behaviors.
