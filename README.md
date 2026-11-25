# dav-hermes-ci

Builds an **unsigned** DAVDrive .ipa on GitHub-hosted macOS runners (free for this
public repo). Re-sign with AltStore / SideStore / a 99 USD developer certificate on
the phone side — no App Store Connect, no Apple ID needed in CI.

- Trigger: Actions → Test IPA → Run workflow (or push to branch `ios-build-test`).
- Artifact: `DAVDrive-unsigned-<version>-<build>.ipa` (contains `Payload/DAVDrive.app`
  with the File Provider extension).
- Source of record: `crazyquark/dav-drive` (this repo carries the same sources for CI).
