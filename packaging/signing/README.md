# Developer ID signing and notarization

Glint is distributed directly through GitHub Releases and Homebrew, **not the Mac App Store**.
The release pipeline requires an Apple **Developer ID Application** certificate, hardened
runtime, a secure timestamp and successful Apple notarization. It staples tickets to the app
before creating the ZIP, and to the signed DMG before generating checksums. Gatekeeper stays
enabled; the cask does not remove quarantine.

Published releases through 1.5.3 are legacy, unnotarized builds. They are not retroactively
re-signed or replaced. The first Developer ID release requires a one-time Screen Recording
re-grant for users upgrading from those builds.

In-app updates use a second, unrelated signature. Developer ID and notarization are what make
macOS trust a download; the Ed25519 key pair described in
[Sparkle update signing](#sparkle-update-signing) is what lets an installed copy trust an update.
They have different keys and secrets, and neither replaces the other.

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

## Sparkle update signing

Direct-download copies update themselves with [Sparkle 2](https://sparkle-project.org). Every
release embeds the **public** half of an Ed25519 key pair as `SUPublicEDKey`. An installed copy
accepts only an appcast feed and an update archive signed by the matching **private** key, and
Sparkle also checks the new app's code signature before installing. This key pair is separate from
the Developer ID certificate and the notarization key above.

Treat the private key like the Developer ID `.p12`. Whoever holds it can sign a feed that every
installed copy will accept. Installed copies trust the public key they shipped with, so a lost or
replaced key strands them on their current version: generate one pair, keep it, do not rotate it
casually and never sign a release with a test key. Only the public key is public. Keep the private
key out of the repository, app bundles, logs, shell history, pull-request workflows, repository
variables, the clipboard and chat.

Generate the pair once on the Mac you release from. These commands keep the private key in the login
Keychain, publish the public key as the release environment **variable** `GLINT_SPARKLE_PUBLIC_KEY`
(`build_app.sh` embeds it) and store the private key as the environment **secret**
`GLINT_SPARKLE_PRIVATE_KEY`. macOS may ask you to allow the tool's Keychain access.

```bash
Scripts/swiftw.sh build   # resolves Sparkle's signing tools into .build/artifacts
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin

# Creates the key, or reuses the one already in this Keychain account, and prints its public half.
"$SPARKLE_BIN/generate_keys" --account glint-release

"$SPARKLE_BIN/generate_keys" --account glint-release -p |
  gh variable set GLINT_SPARKLE_PUBLIC_KEY --env release --repo MrAshRhodes/glint
```

Export the private key into an owner-only directory outside the repository, upload it through
standard input and delete it. The pause before deletion is for putting a copy in an **encrypted**
backup, such as a password manager or an encrypted offline disk image. GitHub cannot show a secret
again, and the Keychain is the only other copy.

```bash
(
  set +x
  set -e
  umask 077
  dir="$(mktemp -d "${TMPDIR:-/tmp}/glint-sparkle.XXXXXX")"
  key="$dir/private-key"
  trap 'rm -f "$key"; rmdir "$dir"' EXIT
  "$SPARKLE_BIN/generate_keys" --account glint-release -x "$key"
  gh secret set GLINT_SPARKLE_PRIVATE_KEY --env release --repo MrAshRhodes/glint < "$key"
  printf 'Store %s in an encrypted backup now, then press Return to delete it. ' "$key"
  read -r _
)
```

The exported file is the base64 private seed and equals the Keychain item's contents. Never commit
it, sync it to a cloud folder, print it or keep an unencrypted copy once the backup exists. To check
the result without revealing anything, `gh secret list --env release --repo MrAshRhodes/glint` shows
only the secret's name and `gh variable list --env release --repo MrAshRhodes/glint` shows the
public key. To restore the key on another Mac, remove any existing "Private key for signing Sparkle
updates" Keychain item and import the backup with `"$SPARKLE_BIN/generate_keys" --account glint-release -f FILE`.

Until the public key variable exists, `release.yml` stops before building; stable releases also
need the private key secret, because their update feed must be signed.

## GitHub Actions setup

Use a GitHub environment named **release**, restricted to deployment from **tags matching
`v*`**, not branches. Restrict who can create release tags and consider required environment
reviewers according to the repository's protection policy. Only the tag-triggered release job
uses this environment; pull-request CI never receives production signing credentials.

Set these **environment secrets**, not repository secrets or variables:

| Secret | Value |
| --- | --- |
| `GLINT_SIGNING_P12_BASE64` | Base64 of the encrypted Developer ID `.p12`. |
| `GLINT_SIGNING_P12_PASSWORD` | The `.p12` password. |
| `GLINT_NOTARY_KEY_P8_BASE64` | Base64 of the dedicated notarization `.p8`. |
| `GLINT_NOTARY_KEY_ID` | The API key's key ID. |
| `GLINT_NOTARY_ISSUER_ID` | The team API key's issuer ID. |
| `GLINT_SPARKLE_PRIVATE_KEY` | The Sparkle update-signing private key, from [Sparkle update signing](#sparkle-update-signing). |
| `TAP_GITHUB_TOKEN` | Optional. Lets the workflow update the Homebrew tap; see below. |

Also set one **environment variable**, not a secret: `GLINT_SPARKLE_PUBLIC_KEY`, the matching
public key from `generate_keys -p`. It is public by design and ends up in every app's
`Info.plist`, so no secret belongs in a variable.

For file-backed secrets, pipe directly into `gh` rather than printing them:

```bash
base64 < "$HOME/.glint-signing/developer-id/glint-developer-id.p12" |
  gh secret set GLINT_SIGNING_P12_BASE64 --env release --repo MrAshRhodes/glint
base64 < "$HOME/.glint-signing/developer-id/AuthKey_KEYID.p8" |
  gh secret set GLINT_NOTARY_KEY_P8_BASE64 --env release --repo MrAshRhodes/glint
```

Enter the other values using GitHub's secret editor or protected standard input. Never paste a
credential into chat, an issue or a command argument.

A secret stored at **repository** level is readable by every workflow in the repository, without the
release environment's tag restriction. Keep all release credentials, including `TAP_GITHUB_TOKEN`,
in the environment. For the tap, use a fine-grained personal access token limited to the
`MrAshRhodes/homebrew-tap` repository with only Contents read and write access, and an expiry you
will renew. Environment secrets take precedence over same-named repository secrets, so migrate
safely: add the environment secrets, confirm a protected release run works, then delete the
repository-level `GLINT_SIGNING_P12_BASE64`, `GLINT_SIGNING_P12_PASSWORD` and `TAP_GITHUB_TOKEN`
entries (`gh secret list --repo MrAshRhodes/glint` shows names only; delete each with
`gh secret delete NAME --repo MrAshRhodes/glint`). GitHub never reveals a stored secret, so keep each
source credential in your password manager. If a credential may have been exposed, revoke or
replace it rather than just moving it.

The workflow imports the identity into a temporary keychain, decodes the `.p8` into a private
runner temporary file, and removes both in `always()` cleanup steps before publication.
Missing credentials, a wrong identity, failed or incomplete notarization, missing tickets
and Gatekeeper rejection all stop the release. There is no ad-hoc or self-signed escape hatch.
Never enable shell tracing around credentials. Apple's `security` command-line tool takes the
`.p12` password as an argument while `Scripts/import_signing_identity.sh` imports the identity, so
another process on the same machine could briefly read it from the process list. Hosted GitHub
runners are ephemeral and single-job. If you ever release from a self-hosted runner, keep it
dedicated and single-user, and for local releases install the identity in your own login keychain
instead of running the import script on a shared Mac.

## Local packaging and verification

With the Developer ID identity installed and the Keychain profile configured, also pass the
public update key: a real signing identity refuses to build an app that cannot verify updates.
The default build number is the git commit count; pass `--build-number` to test an update from an
installed release, since Sparkle offers an update only when its `CFBundleVersion` is higher than
the installed copy's.

```bash
GLINT_SIGN_IDENTITY="Developer ID Application: Ashley Rhodes (TB3Z5R7SY8)" \
GLINT_NOTARY_PROFILE=glint-notary \
GLINT_SPARKLE_PUBLIC_KEY="$(gh variable get GLINT_SPARKLE_PUBLIC_KEY --env release --repo MrAshRhodes/glint)" \
  Scripts/package_release.sh --version X.Y.Z --require-universal --notarize
```

The script builds both architectures, checks the Apple signing policy and the Sparkle settings
(public key, signed-feed requirement, opt-in checks and Sparkle's nested helpers signed like the
app), notarizes and staples the app, creates the ZIP, and checks the freshly extracted app. It
then creates, signs, notarizes and staples the DMG. Only after each final artifact is complete is
its checksum written; the Homebrew cask is rendered last. A ZIP itself cannot be stapled.

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

## Publishing the update feed

Stable releases also publish `appcast.xml` and its `.sha256`. Installed copies read the feed at
`https://github.com/MrAshRhodes/glint/releases/latest/download/appcast.xml`, which GitHub resolves
to the latest non-prerelease. The tag workflow runs `Scripts/generate_appcast.sh X.Y.Z` after the
final notarized ZIP exists:

- It reads `GLINT_SPARKLE_PRIVATE_KEY` and `GLINT_SPARKLE_PUBLIC_KEY` from the environment, with
  no Keychain fallback, and hands the private key to Sparkle's tools on standard input, never as
  a file or an argument.
- It signs the exact final ZIP and the feed, embeds this release's changelog notes, lists only
  this release and publishes no delta updates.
- It verifies that the app inside the ZIP carries the same public key and requires a signed
  feed and verification before extraction, that the feed's URL, length, version, build number and
  macOS requirement match the ZIP, and that both signatures verify against the public key
  embedded in the app. Any mismatch stops the release before publication.
- A prerelease tag (one containing `-`) publishes no feed and is never offered as an update.

Never change the ZIP or the feed after they are signed. Sparkle also offers an update only when
its `CFBundleVersion` is higher than the installed copy's, and the release workflow's run number is
that build number. The workflow therefore compares the number with the latest release's and stops
when it is not higher. If the workflow is renamed or recreated, its run numbers restart; do not
bypass the guard. Change the build-number source (for example with a documented offset) so the
numbers keep increasing, and test it before tagging.

Only the protected tag workflow generates the real feed. `node --test .github/scripts/appcast.test.cjs`
exercises `generate_appcast.sh` with Sparkle's real tools and a published RFC 8032 test-vector
key, never a release key; it needs the Sparkle tools that `Scripts/swiftw.sh build` resolves.

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

A self-signed identity has no Apple Team ID, so the hardened runtime's library validation would
refuse to load the embedded Sparkle framework and the app would crash at launch. Test builds made
with it are therefore signed without the hardened runtime, and `Scripts/build_app.sh` says so.
Developer ID builds always use the hardened runtime, and
`Scripts/verify_signature.sh --require-developer-id` fails an app, or any of Sparkle's nested
helpers, that lacks it. CI also embeds a well-formed placeholder public key, which is not a secret,
in those throwaway builds. They are never shipped or offered to anyone. The mocked updater tests
and the feed generator test do not prove macOS's real permission behavior or a real in-app update.

Before announcing the first Developer ID release, test on a clean Mac: download through a
browser so quarantine is present, verify checksums, install from both ZIP and DMG without
clearing quarantine, launch and capture after granting Screen Recording. Also test an upgrade
from a legacy release (one re-grant) and between two Developer ID builds (grant retained).
Local signature checks alone do not establish those end-user behaviors.

The first release that includes Sparkle can only be installed by hand, so the first real in-app
update can be tested only once a second release exists. Before announcing in-app updates, test it
on a clean Mac: install the older notarized release from a browser download, choose
**Check for Updates…**, and confirm that Glint asks before downloading and again before installing
and relaunching. Afterward confirm that Screen Recording is still granted and that the replaced app
passes `Scripts/verify_signature.sh PATH_TO_GLINT.APP --require-notarized`, which includes the
Gatekeeper assessment. Also check that a Homebrew-managed copy shows its command and is never
replaced by Sparkle.
