# Security

## Supported versions

Security fixes target the latest release. Please update before checking whether
a problem still occurs. Reports affecting older versions are welcome, but a fix
may require upgrading.

## Report a vulnerability

Please report suspected vulnerabilities privately through
[GitHub private vulnerability reporting](https://github.com/MrAshRhodes/glint/security/advisories/new).

Do not open a public issue or pull request containing vulnerability details,
sensitive screenshots or a working exploit. Please keep details private while
we investigate and agree on disclosure.

Include:

- The Glint version, macOS version and installation method.
- What happened, what you expected and the potential security impact.
- Clear reproduction steps and a minimal example using synthetic data.
- Any relevant settings, commands, URL scheme requests or export formats.
- Whether the problem also occurs in the latest release.

Review attachments and diagnostic output before sharing. Do not include real
credentials, private screenshots or unrelated personal information.

## Scope

Relevant reports include:

- Redaction bypasses, including exported images or magnified details revealing
  pixels that should have been replaced by Solid, Pixelate or automatic redaction.
- Unintended capture, file access or disclosure through the URL scheme or CLI.
- Exposure of screenshot contents through diagnostics, temporary files or recovery.
- Problems with release signing, download verification or update integrity.

Automatic detection can miss sensitive information. Review every image before
sharing. Blur is obfuscation, not safe redaction, and redaction does not erase
original images or separately saved raw captures.

Releases from 1.5.4 onward are signed with an Apple Developer ID certificate
and notarized by Apple, and Gatekeeper checks stay enabled. Releases 1.5.3 and
earlier are legacy builds signed with Glint's own certificate and are not
notarized; they are not retroactively replaced. Reports of ways to bypass the
documented signing, notarization or integrity checks are welcome.

## Update integrity and credentials

Direct downloads released after 1.5.5 use Sparkle 2. Update checks fetch the latest
stable release's appcast over HTTPS and require its EdDSA signature. Downloaded
archives must pass EdDSA verification before extraction, and Sparkle also checks
the app's code signature before installation. This update key is separate from
the Apple Developer ID identity; releases still require Apple notarization.
Homebrew-managed copies do not use Sparkle to replace themselves.

Automatic checks are off by default. No update request is made until the user
checks manually or opts into a schedule, and no system profile is sent. Downloads
and installation both require user confirmation. Source builds without the
release public key cannot use in-app updates.

Private signing and notarization material belongs in the protected GitHub
**release** environment and secure local storage, never in source, app bundles,
logs, command history or public variables. Only the Sparkle **public** key is
embedded in the app. See the [maintainer signing guide](packaging/signing/README.md)
for Keychain storage, encrypted backups and CI setup. Report suspected key
exposure privately using the reporting channel above.

## Response and disclosure

Glint is maintained on a reasonable-effort basis. We will investigate reports
and coordinate fixes and disclosure where possible, but cannot promise a
response or resolution deadline.
