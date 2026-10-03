# Changelog

Each version has one section. The release workflow copies the section of the tagged
version into the GitHub release page.

## v0.1.1 — 2026-10-03

### Added

- Help › Demo › **Show sample data**: see the app with sample backups on your own iPhone.
  Nothing is uploaded. A row on the main screen turns it off again.

### Changed

- The release IPA can be built with a real upload address (repo variable `SHOEBOX_UPLOAD_URL_BASE`).

## v0.1.0 — 2026-10-03

First release.

### Features

- Backs up the full photo library to S3-compatible storage: Cloudflare R2, AWS S3, MinIO, Backblaze B2.
- Each backup is a full snapshot in its own folder, `snapshots/<time>/`, with a `manifest.json` written last.
- Starts a new backup every N days (1–365). iOS picks the exact time, usually while charging on Wi-Fi.
- Keeps the latest X backups (1–100) and deletes older ones. It never deletes a backup that is still running.
- Uploads in the background with the PhotoKit background upload extension (iOS 26.1+), also when the app is closed or the phone is locked.
- Includes originals, Live Photo motion, edited versions and RAW files. Videos, Live Photo motion and edits each have a switch.
- Retries failed uploads with a fresh upload URL, up to 4 times. Lists files that still fail in the manifest.
- Back up now, Test connection (list, write and delete check), and a history of finished backups.
- Restore script: `scripts/restore.sh` lists and downloads backups with the AWS CLI.

### App

- Status screen with progress, history, and a Back up now button in thumb reach.
- Settings save as you change them. Problems show under the field, not in pop-ups.
- Help screen with the six main concepts.
- SF Symbols, Dynamic Type, haptics, VoiceOver labels, light and dark mode.
- Languages: English, 简体中文, 日本語, 한국어.

### Known limits

- The upload address is fixed when the app is built (Apple's `BackgroundUploadURLBase`). See "Install" below.
- Files over 5 GiB fail: S3 accepts at most 5 GiB in one upload.
- A developer-forum report says that iOS does not run the upload extension when iCloud Photos is on. This is not tested yet.
- Not tested on a real iPhone yet. Use `docs/TEST_PLAN.md`.
