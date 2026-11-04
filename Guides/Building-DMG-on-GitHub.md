# Build a developer DMG on GitHub Actions

The **Build DMG** workflow builds the pushed `support-import-password` branch on a
GitHub-hosted macOS runner with Xcode. It runs the Unit Tests scheme, archives a
universal Apple silicon + Intel application, creates a DMG and SHA-256 checksum,
and uploads them as a workflow artifact. No local Xcode installation is needed.

1. Push changes to `support-import-password`.
2. Open the repository's **Actions → Build DMG** and select the run for that commit.
3. After it succeeds, download **Sequel-Ace-DMG-<commit>** from **Artifacts**.
4. Unzip the artifact, open the DMG, and drag **Sequel Ace.app** into Applications.

Artifacts expire after 14 days. Logs and XCTest results remain available as a
separate diagnostics artifact for 7 days, including on a failed build. The
workflow does not create a GitHub Release or publish to the App Store. If the
workflow also exists on the default branch, it can be run manually with **Run
workflow**, selecting `support-import-password` as the branch.

This is a Debug build, ad-hoc signed for Apple silicon compatibility. It has no
Apple Developer ID signature or notarization, and does not require signing
certificates, provisioning profiles, or repository secrets. macOS may require
approval in **System Settings → Privacy & Security → Open Anyway**. Removing
quarantine alone does not guarantee macOS will permit a build to run.

The artifact includes its source commit and build settings in `BUILD-INFO.txt`.
Verify its checksum after extracting the download:

```sh
shasum -a 256 -c Sequel-Ace-*.dmg.sha256
```

GitHub-hosted runner usage is subject to the repository/account's Actions billing
and usage limits. The workflow has a 60-minute timeout and cancels older DMG runs
on the same branch when a newer commit is pushed.
