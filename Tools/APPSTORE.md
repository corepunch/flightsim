# App Store submission with Fastlane

The shared iPhone/iPad and Mac listing is Kestrel Frontier, App Store ID `6831063163`, bundle
identifier `com.corepunch.spacefight`, development team `BM2R8F5YHC`. This setup
uses one app record for both platforms. The Fastlane lanes below target iOS;
archive and distribute the native Mac target through Xcode using the same bundle
identifier, with macOS added to that app record in App Store Connect.
The Mac target signs with `Resources/KestrelFrontier-macOS.entitlements`, enabling
App Sandbox and the incoming/outgoing connections used by multiplayer.

## Game Center

Both Xcode app targets sign with the Game Center entitlement. The universal
bundle ID has Game Center enabled in the developer account. The classic
**Pilot Score** leaderboard in App Store Connect uses
`com.corepunch.spacefight.pilot_score`, descending integer scores and Best Score.
The app displays and submits the local total from the best campaign mission
ratings and the best finished match on each LAN arena.

For the first release with Game Center, enable Game Center on the new app
version and include Pilot Score with that version in App Review. Use an
Apple-signed development or TestFlight build to verify sign-in, score
submission and the leaderboard on each platform.
[Apple's Game Center version setup](https://developer.apple.com/help/app-store-connect/configure-game-center/manage-an-app-version-for-game-center)
and [review instructions](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-game-center-components/).

The Pilot Score entry's context carries the campaign mission the pilot has
reached; mission select reads the friends-only entries to name the friends on
each mission.

Achievements are listed in `Games/KestrelFrontier/Campaign/campaign.json`
("achievements") and reported from the progress record, so progress made
offline or on another device is awarded at the next sign-in. Each one exists in
App Store Connect under the same ID (prefix `com.corepunch.spacefight.`) with
an English title and descriptions, created with `asc game-center achievements
create` and `… localizations create`. Each still needs a 1024×1024 image
(`asc game-center achievements images upload`) before they go to App Review
with an app version. A live achievement cannot be deleted and its points
cannot change, so the set leaves 480 of the 1000 points free.

| ID | Earned by | Points | Hidden |
|---|---|---|---|
| `first_sortie` | Finishing a campaign mission | 10 | |
| `chapter_1` | Finishing missions 1–5 (Strange Orders) | 30 | |
| `chapter_2` | Finishing missions 6–10 (The People We Save) | 40 | yes |
| `chapter_3` | Finishing missions 11–15 (The Machine at Corvid) | 50 | yes |
| `campaign` | Finishing all 20 missions (The Quiet Engine) | 100 | |
| `perfect_1` | Three stars on a mission | 10 | |
| `perfect_5` | Three stars on 5 missions | 30 | |
| `perfect_10` | Three stars on 10 missions | 50 | |
| `perfect_20` | Three stars on every mission | 100 | |
| `first_kill` | A kill in a LAN match | 10 | |
| `match_ace` | Five kills in one LAN match | 40 | |
| `match_flawless` | Five kills and the win in one LAN match | 50 | |

Both targets use the private iCloud Documents container
`iCloud.com.corepunch.spacefight` for GameKit saves. Keep that container
assigned to the universal App ID and refresh provisioning profiles for builds
that use it. A signed cross-device check needs the same iCloud account, iCloud
Drive and Game Center sign-in on each device. Earn different results offline
on two devices, then reconnect and check that both results appear on both.
[Apple's GameKit saved-game setup](https://developer.apple.com/documentation/gamekit/saving-the-player-s-game-data-to-an-icloud-account)

## Fastlane

Fastlane and its dependencies are pinned by `Gemfile` and `Gemfile.lock`.
`Tools/fastlane.sh` selects Homebrew's Ruby and reuses Homebrew's installed gems,
so it does not change Apple's system Ruby or install a second copy of Fastlane.
Commands below run from the repository root.

## Installation

On this Mac, Fastlane is already installed. On another Mac:

```sh
HOMEBREW_NO_AUTO_UPDATE=1 brew install fastlane
./Tools/fastlane.sh lanes
```

If a later Homebrew update no longer provides the locked gems, use a modern Ruby
and Bundler to install the versions in the lockfile, then run `bundle exec fastlane`
instead. To intentionally update the pinned version, change `Gemfile` and run
`bundle update fastlane` using that Ruby. Commit the updated lockfile with it.

## Account access

Fastlane and the `asc` CLI use the active team key named **Default API Key**.
The `asc` profile **corepunch** keeps it in macOS Keychain. Fastlane's local
configuration is `fastlane/private/api_key.json`, with a private-key copy
alongside it; both are excluded from Git. Apple team keys apply across the
team's apps. Keep a secure backup: Apple allows each private key to be
downloaded once. The previous Fastlane configuration is preserved privately.

On a new machine, copy `fastlane/api_key.example.json` to
`fastlane/private/api_key.json`, fill in the key ID and issuer ID, and put the
downloaded `.p8` file in that directory. A relative `key_filepath` is resolved
against `fastlane/private/`. Restrict the directory to your user:

```sh
chmod 700 fastlane/private
chmod 600 fastlane/private/*.json fastlane/private/*.p8
./Tools/fastlane.sh ios status
```

The key uses Apple's documented API; these commands do not require an Apple ID
password or repeated browser login. Revoke a lost key in App Store Connect's
Users and Access → Integrations → App Store Connect API.

## Editing the listing

```sh
./Tools/fastlane.sh ios check
./Tools/fastlane.sh ios status
./Tools/fastlane.sh ios pull
```

`check` works offline and reports missing listing fields. `check strict:true`
exits with an error when fields are missing. This checks local text lengths and
URL syntax, not complete Apple submission readiness or whether URLs are live.
`status` reads the editable version and recent builds from Apple.

`pull` downloads the editable version's saved metadata. It **overwrites local
listing text**, so preserve local edits before running it again. Public text
goes in `fastlane/metadata/`; private review contact information goes in
`fastlane/private/review_information.json`. The complete raw download remains
in `fastlane/private/import/`. No Apple data is changed.

Edit these files in any text editor:

| File | Contents |
|---|---|
| `fastlane/version.txt` | Version to edit and submit; must match the editable Apple version |
| `fastlane/metadata/en-US/name.txt` | Store name |
| `fastlane/metadata/en-US/subtitle.txt` | Subtitle |
| `fastlane/metadata/en-US/description.txt` | Description |
| `fastlane/metadata/en-US/keywords.txt` | Comma-separated keywords |
| `fastlane/metadata/en-US/promotional_text.txt` | Promotional text |
| `fastlane/metadata/en-US/support_url.txt` | Published support page URL |
| `fastlane/metadata/en-US/privacy_url.txt` | Published privacy policy URL |
| `fastlane/metadata/en-US/release_notes.txt` | What's New for updates |
| `fastlane/metadata/copyright.txt` | Copyright holder and year |
| `fastlane/private/review_information.json` | Review contact, notes and optional demo credentials |

Fastlane also downloads category files. Additional locales use sibling folders
such as `fastlane/metadata/de-DE/`. The local checker covers English (U.S.);
Apple validates all uploaded locales.

Upload your text with:

```sh
./Tools/fastlane.sh ios prepare
```

This edits the existing version's metadata and review information. It does not
upload a binary, upload screenshots or submit for review. Fastlane displays an
HTML preview for verification. The local check requires support and privacy
URLs before this command proceeds; publish the pages first.

## Screenshots and builds

Put final App Store screenshots in `fastlane/screenshots/en-US/`, then run:

```sh
./Tools/fastlane.sh ios screenshots
./Tools/fastlane.sh ios upload ipa:/absolute/path/KestrelFrontier.ipa
```

The screenshots command uploads images only and does not clear the existing
screenshots first. Repeated uploads can add duplicates. Use actual supported
device resolutions from [Apple's screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/).
The screenshots themselves are excluded from Git.

Reproducible staged gameplay renders use the actual renderer, ships, HUD and
projectile trails. Their scene layouts and timing are in `Tools/Capture/`:

```sh
./Tools/render-store-scenes.sh
```

See [Capture/README.md](Capture/README.md) for camera and scene adjustments.
Rendering is a manual art workflow, separate from the headless unit suite.

The submitted Mac screenshots are in `fastlane/screenshots-macos/en-US/`.
Mac description and keywords, including trackball support, are in
`fastlane/metadata-macos/en-US/`; the iOS lanes do not upload that directory.
The Header and Search Results assets uploaded through App Store Connect are in
`fastlane/artwork/`. That directory also preserves the generated banner master
and its exact ImageGen prompt. The search image is cropped from real gameplay.

The upload command takes an already signed App Store IPA, checks its bundle ID
and marketing version, and sends it to TestFlight without inviting external
testers. Use Xcode's existing `KestrelFrontier-iOS` scheme to archive and export
the IPA. This setup does not build an archive automatically. Align the source
plists with the store version in
`fastlane/version.txt` before creating a new distribution build, and choose an
unused build number. Signing uses your existing Xcode configuration.
Both Info.plists declare `ITSAppUsesNonExemptEncryption` false (the app makes no
encrypted connections; it only hashes asset files), so uploaded builds skip the
export compliance questions. Revisit it if the app ever adds encryption.

## Submitting for review

After the metadata, screenshots, required declarations and build are ready:

```sh
./Tools/fastlane.sh ios submit build:39
```

Replace `39` with the exact processed build you intend to submit. The command
checks the editable version, selects that build and submits it for review.
It does not re-upload the local listing or screenshots. Release after approval
is manual (`automatic_release: false`). Merely installing or running `check`,
`status` or `pull` never submits the app.

For the November 6, 2026 submission, both platforms use version 1.0, build 40,
and App Store Connect is set to release each version automatically after approval.
Those submissions used Fastlane directly with automatic release enabled; the
lane's default above remains manual for future submissions.

## Other submission forms

The public API does not cover every form. Privacy nutrition labels use a
separate Fastlane action with Apple ID login and potentially 2FA. To answer its
questionnaire and save answers locally without uploading them:

```sh
./Tools/fastlane.sh run upload_app_privacy_details_to_app_store \
  username:YOUR_APPLE_ID app_identifier:com.corepunch.spacefight \
  output_json_path:app_privacy_details.json skip_upload:true
```

After checking the generated answers, upload them explicitly:

```sh
./Tools/fastlane.sh run upload_app_privacy_details_to_app_store \
  username:YOUR_APPLE_ID app_identifier:com.corepunch.spacefight \
  json_path:app_privacy_details.json
```

Age ratings, pricing, availability, accessibility declarations, export
compliance, and account agreements are not changed by these lanes. Apple may
still require those before submission. Do not invent questionnaire answers to
make a readiness check pass.

References: [Fastlane setup](https://docs.fastlane.tools/getting-started/ios/setup/),
[deliver](https://docs.fastlane.tools/actions/deliver/),
[API authentication](https://docs.fastlane.tools/app-store-connect-api/), and
[privacy details](https://docs.fastlane.tools/uploading-app-privacy-details/).
