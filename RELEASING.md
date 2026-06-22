# Releasing Lilypad

Lilypad is distributed outside the Mac App Store: a Developer ID–signed,
**notarized** `.dmg`, with auto-updates via **Sparkle**. This is the runbook.

## One-time setup

1. **Developer ID Application certificate** (team `3H3QVL27U8`) — installed.
   Verify: `security find-identity -v -p codesigning | grep "Developer ID"`.
   ⚠️ Export and back it up (it's irreplaceable): Keychain Access → export the
   identity as a `.p12`, store it in a password manager.

2. **Notary credentials** — store once:
   ```sh
   xcrun notarytool store-credentials "lilypad-notary" \
     --apple-id "<your-apple-id-email>" \
     --team-id "3H3QVL27U8" \
     --password "<app-specific-password>"
   ```
   Create the app-specific password at <https://appleid.apple.com> → Sign-In &
   Security → App-Specific Passwords.

3. **Sparkle signing key** — already generated; the public key is in
   `Lilypad/Info.plist` (`SUPublicEDKey`). ⚠️ Back up the **private** key now —
   if it's lost, you can never sign an update your installed users will accept:
   ```sh
   build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle_private_key.pem
   # store sparkle_private_key.pem in a password manager, then delete the file
   ```

4. **Appcast host** — the feed URL baked into the app is
   `https://bufothefrog.github.io/Lilypad/appcast.xml`. Enable **GitHub Pages**
   for the repo (Settings → Pages → serve from `/docs` on `main`, or a
   `gh-pages` branch) and publish `appcast.xml` there.

## Cutting a release (manual)

```sh
SPARKLE=build/SourcePackages/artifacts/sparkle/Sparkle/bin

# 0. Bump versions (MARKETING_VERSION + CURRENT_PROJECT_VERSION must increase)
#    then commit on a branch and merge to main.

# 1. Clean Developer ID archive
rm -rf build/Lilypad.xcarchive build/export
xcodebuild -project Lilypad.xcodeproj -scheme Lilypad -configuration Release \
  -archivePath build/Lilypad.xcarchive archive \
  CODE_SIGN_IDENTITY="Developer ID Application" CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM=3H3QVL27U8 OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime"

# 2. Export the signed .app (do NOT use `codesign --deep`)
cat > build/exportOptions.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>3H3QVL27U8</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath build/Lilypad.xcarchive \
  -exportPath build/export -exportOptionsPlist build/exportOptions.plist

# 3. Package a DMG (hdiutil; or `brew install create-dmg` for a styled one)
hdiutil create -volname Lilypad -srcfolder build/export/Lilypad.app \
  -ov -format UDZO build/Lilypad.dmg

# 4. Notarize + staple the DMG
xcrun notarytool submit build/Lilypad.dmg --keychain-profile lilypad-notary --wait
xcrun stapler staple build/Lilypad.dmg
spctl -a -vvv -t open --context context:primary-signature build/Lilypad.dmg  # expect: accepted

# 5. Sign the update for Sparkle, then add the entry to appcast.xml
$SPARKLE/sign_update build/Lilypad.dmg
#   -> prints sparkle:edSignature="..." length="..." ; place these in the
#      <enclosure> for this version in docs/appcast.xml, along with the
#      release-notes <description> and the download URL (the GitHub release asset).

# 6. Publish the GitHub release with the notarized DMG
gh release create v1.0.0 --repo bufothefrog/Lilypad --target main \
  --title "Lilypad 1.0.0" --notes-file CHANGELOG-1.0.0.md build/Lilypad.dmg

# 7. Commit the updated docs/appcast.xml so GitHub Pages serves the new feed.
```

Sparkle compares `CFBundleVersion` (`CURRENT_PROJECT_VERSION`), so it **must
strictly increase** every release. The current value is `102`.

## Cutting a release (automated)

Push a tag `vX.Y.Z`; `.github/workflows/release.yml` runs the same pipeline.
It needs these repo **secrets** (Settings → Secrets and variables → Actions):

| Secret | What |
|---|---|
| `MACOS_CERT_P12_BASE64` | `base64 -i DeveloperID.p12` of your exported Developer ID identity |
| `MACOS_CERT_PASSWORD` | the `.p12` export password |
| `KEYCHAIN_PASSWORD` | any throwaway password for the CI keychain |
| `NOTARY_APPLE_ID` | your Apple ID email |
| `NOTARY_TEAM_ID` | `3H3QVL27U8` |
| `NOTARY_PASSWORD` | the app-specific password |
| `SPARKLE_PRIVATE_KEY` | contents of `sparkle_private_key.pem` (from step 3) |

## Recovery / rollback

- **Lost Sparkle private key** → installed users can't be updated; you'd have to
  ship a new key in a new build and ask users to re-download. **Back it up.**
- **Bad release** → delete the GitHub release + tag and revert the `appcast.xml`
  entry before users pick it up; Sparkle only offers what the feed advertises.
