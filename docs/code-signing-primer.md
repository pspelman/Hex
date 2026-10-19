# Code Signing, Certificates, and Distribution: A Working Primer

Written for Phil while setting up a fresh Mac for Hex (October 2026). The first
half is general and applies equally to a macOS app shipped outside the App Store
(Hex) and an iPhone app shipped through the App Store. The second half is the
Hex-specific state and checklist.

## 1. The vocabulary, in dependency order

Everything else makes sense once these five things are distinct in your head.

**Private key.** A secret generated on one Mac and stored in that Mac's login
keychain. It never leaves the machine unless you export it on purpose. This is
the thing that actually signs. Lose it and the matching certificate is useless.

**Certificate Signing Request (CSR).** The public half of that key plus your
name, sent to Apple. Xcode does this invisibly when you click "+" in Manage
Certificates. Keychain Access can do it manually via Certificate Assistant.

**Certificate.** Apple's signed statement that "this public key belongs to team
V64NFXWFVH and may be used for purpose X, until date Y." Apple keeps a copy; you
download it into the keychain. A certificate without its private key is just a
public document.

**Identity.** Certificate plus matching private key, together, in one keychain.
Only an identity can sign. `security find-identity -v -p codesigning` lists the
ones that are valid for code signing. The "Not in Keychain" rows you saw in
Xcode are certificates whose private keys live on your old Macs. They are
harmless and can be revoked at developer.apple.com.

**Provisioning profile.** An Apple-signed bundle saying "app ID A, signed by
certificates B, may run on devices C with entitlements D." iOS always requires
one. macOS development builds only need one for restricted entitlements
(iCloud, push, etc.). Hex's entitlements (sandbox, network client, user-selected
files, Apple events) are not restricted, so Hex has never needed a profile and
your fresh Mac has none.

## 2. Certificate types you will actually use

| Certificate | Platform | Used for | Who can create |
| --- | --- | --- | --- |
| Apple Development | iOS + macOS | Running on your own devices, local builds | Any team member |
| Apple Distribution | iOS + macOS | App Store and TestFlight uploads, Ad Hoc | Admin or Account Holder |
| Developer ID Application | macOS only | Apps shipped outside the App Store (Hex) | Account Holder only |
| Developer ID Installer | macOS only | Signing `.pkg` installers | Account Holder only |

Xcode's Apple Accounts pane shows the Account Holder as "Admin", so do not
read that label as a missing permission.

Rules of thumb:

- Development certs are disposable. Make a new one per Mac. Revoking one breaks
  nothing you have shipped.
- Developer ID certs are precious. Apple caps how many a team can hold, and the
  private key only exists where it was created. Back it up the day you make it.
- Distribution certs sit in between. They are replaceable, but a replacement
  means re-creating any manual profiles that reference the old one.

## 3. The trust chain and the one trap that bit you

Every Apple-issued cert chains: Apple Root CA, then the Worldwide Developer
Relations (WWDR) intermediate, then your cert. The system needs the intermediate
in a keychain to validate your identity. Certs issued today chain to the G3
intermediate. A fresh macOS install sometimes ships only the expired 2013 G1
intermediate, which produces exactly the symptom you hit: Xcode shows the cert,
but `find-identity` reports zero valid identities and builds fail to sign.

Fix, which is already applied on this Mac:

```bash
curl -O https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer
security import AppleWWDRCAG3.cer -k ~/Library/Keychains/login.keychain-db
security find-identity -v -p codesigning
```

If Apple rotates to a G4 or later intermediate in the future, the same symptom
has the same cure with a different file from apple.com/certificateauthority.

## 4. Backing up and moving identities between Macs

Xcode 27 removed the "Export Accounts" button from the Apple Accounts pane, so
Keychain Access is the way to back up an identity. The `.p12` it produces is
also the format CI systems and other tools expect.

1. Keychain Access, "login" keychain, My Certificates tab.
2. Select the identity (for Hex, "Developer ID Application: Philip Spelman
   (V64NFXWFVH)"). The disclosure triangle must show a private key beneath it.
3. Right-click, Export, choose Personal Information Exchange (.p12), set a
   strong password. It may also ask for the Mac login password.
4. Put the file and its password in 1Password, then delete the file.

Command-line equivalent, which exports every identity in the keychain at once:

```bash
security export -k ~/Library/Keychains/login.keychain-db -t identities \
  -f pkcs12 -P '<strong-password>' -o ~/Desktop/identities.p12
```

Restore on another Mac:

```bash
security import identities.p12 -k ~/Library/Keychains/login.keychain-db \
  -P '<password>' -T /usr/bin/codesign
```

The `-T` flag pre-authorizes `codesign` to use the key. Without it, and for
any key Xcode itself creates, command-line signing fails with
`errSecInternalComponent` until you open the key in Keychain Access, Access
Control tab, and allow all applications. Xcode's own GUI builds are not
affected, which is why the problem only shows up in scripts and CI.

Do this for the Developer ID identity the moment you create it (done for Hex on
2026-10-19), and again for the Apple Distribution identity when you make one
for the iPhone app. Development identities are not worth backing up.

## 5. The iPhone flow (for the hart3s app)

You already have what most people get stuck on: a paid team (V64NFXWFVH), an
Apple ID attached to Xcode, and a working Apple Development identity. The iOS
process adds devices, profiles, and App Store Connect.

**Development, to run on a phone:**

1. Plug in the iPhone, trust the Mac, and enable Developer Mode on the phone
   (Settings, Privacy & Security, Developer Mode).
2. In the target's Signing & Capabilities tab, tick "Automatically manage
   signing" and pick team V64NFXWFVH. Xcode registers the device, creates the
   App ID from the bundle identifier, and generates a development profile.
3. Build and run. The first launch asks you to trust the developer on the phone
   under Settings, General, VPN & Device Management.

**Distribution, to ship through TestFlight and the App Store:**

1. Create the app record at appstoreconnect.apple.com with the same bundle ID.
   This is the step that has no Xcode equivalent and trips people up.
2. In Xcode, Manage Certificates, "+", Apple Distribution. Then export it
   (section 4).
3. Bump the build number. App Store Connect rejects a duplicate
   `CFBundleVersion` for the same marketing version.
4. Product, Archive. In the Organizer, Distribute App, App Store Connect,
   Upload. Automatic signing creates the distribution profile on the fly.
5. The build appears in TestFlight after processing (typically minutes). Add
   internal testers immediately; external testers need a brief Beta App Review.
6. Submit for review from the App Store Connect version page once screenshots,
   privacy answers, and an age rating are filled in.

Command-line equivalents, useful for CI later:

```bash
xcodebuild -scheme <App> -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/App.xcarchive -allowProvisioningUpdates archive

xcodebuild -exportArchive -archivePath build/App.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export \
  -allowProvisioningUpdates
```

`ExportOptions.plist` needs at minimum `method` set to `app-store-connect`
and `teamID` set to `V64NFXWFVH`.

Capabilities that need extra portal setup before automatic signing will succeed:
push notifications, Sign in with Apple, App Groups, iCloud, HealthKit,
associated domains. Add them in Signing & Capabilities and Xcode will update the
App ID, but the matching service (for example an APNs key) is configured
separately in the portal.

## 6. The macOS outside-the-App-Store flow (Hex)

Shipping a Mac app directly needs three things the App Store handles for you:

1. **Developer ID Application identity** to sign the app and DMG.
2. **Notarization**: upload the signed artifact to Apple, which scans it and
   returns a ticket. Staple the ticket so Gatekeeper trusts the app offline.
3. **An update mechanism**, which is Sparkle here.

One-time setup, already done on this Mac, kept here for the next machine:

```bash
# Create the Developer ID cert in Xcode: Manage Certificates, "+", Developer ID Application.
# Then store notarization credentials (app-specific password from appleid.apple.com):
xcrun notarytool store-credentials "AC_PASSWORD" \
  --apple-id <apple-id> --team-id V64NFXWFVH --password <app-specific-password>
```

Per-release commands the release tool runs for you, shown here so the steps are
not a black box:

```bash
codesign --deep --force --options runtime --timestamp \
  --sign "Developer ID Application: Philip Spelman (V64NFXWFVH)" Hex.app
xcrun notarytool submit Hex.dmg --keychain-profile AC_PASSWORD --wait
xcrun stapler staple Hex.dmg
spctl -a -vv -t install Hex.dmg      # Gatekeeper's verdict, should say "accepted"
```

## 7. Sparkle: there is no account

Sparkle is an open-source framework, not a service. "Signing" updates means an
EdDSA key pair that you generate locally. The private key lives in your login
keychain as a generic password item (service `https://sparkle-project.org`,
account `ed25519`). The public key goes in Info.plist as `SUPublicEDKey`. Every
shipped archive is signed with the private key, and the app refuses any update
whose signature does not verify against the public key baked into the running
build. That is why the upstream author's key had to go: Hex builds carrying
their public key would only ever accept updates they signed.

Key facts for this fork:

- Key pair generated 2026-10-18 on this Mac. Public key is in `Hex/Info.plist`.
  Private key is backed up in 1Password.
- To export the private key again:
  ```bash
  ~/Library/Developer/Xcode/DerivedData/Hex-*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x ~/Desktop/hex-sparkle-private.key
  ```
  Then delete the file from the Desktop. Restore on another Mac with
  `generate_keys -i <file>`.
- The feed URL is set to
  `https://github.com/pspelman/Hex/releases/latest/download/appcast.xml`. That
  resolves to whichever GitHub release is marked latest, so each release must
  upload `appcast.xml` as an asset alongside the DMG and ZIP. No S3 bucket
  required. Change `SUFeedURL` if you later move hosting.
- Sparkle's tools live next to `generate_keys` in the same `bin/` directory:
  `sign_update <archive>` prints the signature for one file, and
  `generate_appcast <dir>` writes an `appcast.xml` for every archive in a
  directory using the key from the keychain.

## 8. Quick diagnostics cheat sheet

```bash
security find-identity -v -p codesigning        # what can sign on this Mac
codesign -dv --verbose=2 Hex.app                # who signed it, team, flags
codesign --verify --deep --strict Hex.app       # is the signature intact
spctl -a -vv Hex.app                            # would Gatekeeper allow it
xcrun notarytool history --keychain-profile AC_PASSWORD   # past submissions
xcrun notarytool log <submission-id> --keychain-profile AC_PASSWORD  # why one failed
security find-certificate -a -c "Apple Worldwide Developer Relations" -Z   # which WWDR intermediates exist
```

## 9. Hex state on this Mac as of 2026-10-18

Done:

- Apple ID for team V64NFXWFVH added to Xcode.
- Apple Development identity created and valid; WWDR G3 intermediate imported.
- Developer ID Application identity created, CLI access granted, backed up to
  1Password as a `.p12`.
- `AC_PASSWORD` notarytool profile stored. A full archive, export, notarize,
  staple, and Gatekeeper check passed on 2026-10-19 (submission
  439fa767-26ff-41fa-945e-ad9b51dde082).
- All targets (app and tests) use team V64NFXWFVH.
- Sparkle key pair generated; `SUPublicEDKey` and `SUFeedURL` in Info.plist.
- Homebrew cask `hex.rb` points at pspelman/Hex and the com.pspelman bundle ID.

Working local build:

```bash
xcodebuild -scheme Hex -configuration Release -destination 'platform=macOS,arch=arm64' \
  -skipMacroValidation -allowProvisioningUpdates build
```

Still to do before the first real release:

- Restore or rewrite the release CLI. `CLAUDE.md` describes `tools/src/cli.ts`,
  but this checkout only contains `tools/scripts/add-changeset.ts`.
- Decide whether the release tool keeps uploading to S3 or switches to GitHub
  release assets to match the feed URL above.

Known gap: `xcodebuild test -scheme Hex` does not link under Xcode 27.1 because
the test bundle forces package products into dynamic mode and TCA's dynamic
product fails to link. The `HexCore` package tests (`cd HexCore && swift test`)
are unaffected and are the primary unit-test loop.
