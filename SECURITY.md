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

## Response and disclosure

Glint is maintained on a reasonable-effort basis. We will investigate reports
and coordinate fixes and disclosure where possible, but cannot promise a
response or resolution deadline.
