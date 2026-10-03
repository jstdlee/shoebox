# Shoebox test plan

Two layers:

1. **Automated (GitHub Actions, iOS Simulator):** 149 XCTest cases over
   ShoeboxCore: SigV4 (AWS published vectors), S3 client, key layout, schedule,
   retention, state files, and the full backup engine with fake PhotoKit, fake job
   system and fake bucket. CI also builds the app and extension for Simulator and device.
2. **On device (later):** the scenarios below. These cover what can't be faked:
   PhotoKit, the background upload extension, iOS scheduling and real providers.

Mark each run with the date, device, iOS version, provider and result.

---

## 1. Automated coverage (what's already proven)

| Suite | Covers |
|---|---|
| `SigV4Tests` | AWS test suite `get-vanilla`; S3 doc examples: GET with Range, PUT with storage class, `?lifecycle`, ListObjects (unsorted query), presigned GET; expiry clamp; session token (header + query); header trimming; ports; strict query/URI encoding incl. Unicode |
| `S3ConfigTests` | endpoint/region/bucket/prefix validation, bucket name rules, path vs virtual-hosted URLs, ports, key ↔ URL round trip (incl. presigned, Unicode, `+&=?#%`), foreign URLs rejected, `BackgroundUploadURLBase` matching, content types |
| `KeyLayoutTests` | key shape, stable names across snapshots, same-filename collisions, time-zone month folders, undated assets, Live Photo / edited / RAW suffixes, duplicate resources, filename sanitizing and length cap, snapshot id parsing |
| `ScheduleTests` | never backed up, exact interval boundary, daily, clamping, clock moved backwards |
| `RetentionTests` | keep N, unsorted input, active never deleted, abandoned partials, partials newer than all complete kept, partials don't count, clamping |
| `ResourcePolicyTests` | internal resources never uploaded, video / Live Photo motion / edits toggles |
| `FailureClassifierTests` | retry until max, permanent URL errors, unknown errors |
| `S3XMLTests`, `S3ClientTests`, `S3SnapshotStoreTests` | list/delete/error XML, truncated XML, escaping, signed PUT/HEAD/LIST/DELETE, Content-MD5, pagination, manifest-last deletion, delete budget, per-key delete errors |
| `StateStoreTests`, `FileLockTests` | state round trip, corrupt state recovery, 5k-asset plan, append log, cleanup, history cap, manifest JSON format, cross-instance locking |
| `BackupEngineTests` | not configured / missing keys / bad bucket / endpoint outside URL base / no photo access; first run; presigned destinations; full lifecycle + manifest; temp cleanup; empty library; not due / due / interval from start; Back up now (+ during active); same-second ids; job limit across passes; resources spanning batches; cursor resume; limitExceeded atomicity; stop flag; photos added / deleted mid-snapshot; video and Live Photo toggles; retry with fresh URL; give up after N; permanent errors; retry of deleted asset; manifest upload failure; lost jobs; foreign jobs; duplicate success; retention keep N / abandoned partials / spread over passes / list failure / after settings change; lock held; restart mid-snapshot |

### Automated tests still worth adding

- [ ] Fuzz `KeyLayout.sanitize` + `S3Config.key(fromObjectURL:)` round trip with random Unicode filenames.
- [ ] Engine with `jobLimit = 1` and a 1,000-asset library: check pass count and that no key repeats.
- [ ] Engine: settings change mid-snapshot (e.g. videos turned off). Decide on the expected behavior first: finish with the plan it started with?
- [ ] Engine: prefix changed mid-snapshot. Keys already in flight no longer parse; they should end up failed, not stuck.
- [ ] `S3SnapshotStore.listSnapshots` with more than 1,000 snapshot prefixes (pagination).
- [ ] Integration test against a real bucket in CI (R2 test bucket, keys in GitHub secrets): real PUT to a presigned URL, list, delete, manifest.
- [ ] UI test (XCUITest) for the settings form: validation messages, Save, demo mode.
- [ ] Performance: `FileStateStore` plan load with 100k identifiers.

---

## 2. On-device scenarios

Setup for all: build from Xcode to a real iPhone on iOS 26.1+. The extension does not
run in the Simulator. On iOS 27+ turn on **Settings → Developer → Photos → Resource
Upload Test Mode** so the system runs the extension promptly.

### A. First run and configuration

| ID | Scenario | Steps | Expected |
|---|---|---|---|
| A1 | Fresh install, no settings | Launch | Status "No backups yet", endpoint prefilled with the build's upload base |
| A2 | Save with missing fields | Leave bucket empty → Save | Alert lists the problems; nothing saved |
| A3 | Wrong keys | Enter bad secret → Test connection | "Connection failed: HTTP 403 SignatureDoesNotMatch" (or InvalidAccessKeyId) |
| A4 | Right keys, read-only token | Test connection | List OK, write fails with 403 → clear message |
| A5 | Correct R2 config | Test connection | "Connection OK"; no `.shoebox-probe` object left in the bucket |
| A6 | Endpoint outside upload base | Enter another account's endpoint → Save | Alert explains SHOEBOX_UPLOAD_URL_BASE |
| A7 | Photo permission: deny | Turn on background backup → Don't Allow | Message pointing to Settings; no snapshot starts |
| A8 | Photo permission: limited | Choose "Limited Access" | Treated as not authorized (full access required); no partial snapshot |
| A9 | Enable background | Allow Full Access | "Background backup is on"; `uploadJobExtensionEnabled` true after relaunch |
| A10 | Keychain after reinstall | Delete app, reinstall | Settings are gone (App Group removed); decide if that is OK |

### B. First backup (happy path)

| ID | Scenario | Steps | Expected |
|---|---|---|---|
| B1 | Small library (~20 items) | Back up now, lock phone, wait | All uploads finish; `manifest.json` present; History shows counts |
| B2 | Key layout | Browse bucket | `prefix/snapshots/<id>/YYYY/MM/<name>_<hash>.<ext>`; months match local time |
| B3 | File integrity | `scripts/restore.sh latest ./r`, compare with originals exported from Photos | Byte-identical originals (HEIC/JPEG/MOV/DNG) |
| B4 | Live Photos | Library with Live Photos | `.HEIC` + `.MOV` with the same stem |
| B5 | Edited photos | Edit a photo in Photos | Original + `_edited` render; no `.plist` adjustment files |
| B6 | RAW + JPEG | ProRAW or imported RAW+JPEG pair | `_alt` file present |
| B7 | Screenshots, screen recordings, bursts, panoramas, slo-mo, cinematic | One of each | All back up; note any resource type mapped to `other` |
| B8 | Hidden album | Hide a photo | Included (`includeHiddenAssets`) |
| B9 | Shared albums / iCloud Shared Library | Items only in a shared library | Record what PhotoKit returns; decide if they should be included |
| B10 | Content-Type | Inspect object metadata | `image/heic`, `video/quicktime`, etc. |

### C. Background behavior (the core feature)

| ID | Scenario | Steps | Expected |
|---|---|---|---|
| C1 | App never opened after setup | Start backup, kill the app from the switcher, wait overnight on charger + Wi-Fi | Snapshot completes without opening the app |
| C2 | Device locked | Start backup, lock immediately | Uploads continue; Keychain + App Group readable while locked (after first unlock) |
| C3 | Reboot mid-snapshot | Restart phone, don't unlock | Nothing runs before first unlock; resumes after unlock |
| C4 | Scheduled run | Interval 1 day, wait 24–48h without opening app | New snapshot starts (via extension or app refresh) and completes |
| C5 | Cellular only | Wi-Fi off | Record whether the system uploads on cellular (26.1 has no option; 27 adds `preventsExpensiveNetworkAccess`) |
| C6 | Low Power Mode | Enable during snapshot | Uploads pause or slow; resume later; no errors recorded |
| C7 | Airplane mode mid-upload | Toggle on for 10 min, then off | Failed jobs retried with fresh URLs; no permanent failures |
| C8 | Background upload switched off | Disable in app mid-snapshot, re-enable | Lost jobs detected and requeued (`reconcileLostJobs`) |
| C9 | **iCloud Photos on** (known forum report: extension never scheduled) | iCloud Photos on + "Optimize iPhone Storage" | **Critical:** does the extension run? Are originals downloaded from iCloud before upload? |
| C10 | iCloud Photos on, "Download and Keep Originals" | Same as C9 | Compare with C9 |
| C11 | App and extension at once | Tap Back up now repeatedly while the extension runs | No duplicate jobs (file lock); UI shows the same active snapshot |
| C12 | Termination | Watch logs while the system suspends the extension | `notifyTermination` → pass exits quickly; next run continues |
| C13 | Resumable-upload preflight | Proxy (e.g. Charles on a test device) | The system sends `OPTIONS` to the endpoint; S3/R2 don't support RUFH; check it falls back to a plain PUT and succeeds |
| C14 | Battery / thermal | Full 10k-photo run | Record battery used and time taken; no thermal warnings |

### D. Scale

| ID | Scenario | Expected |
|---|---|---|
| D1 | 10k assets | Snapshot completes; the extension stays within its memory limit; plan file about 0.5 MB |
| D2 | 50k+ assets | Record passes, total time, extension memory peak |
| D3 | Video > 5 GB | **Known limit:** S3/R2 single PUT max is 5 GiB, so this fails after N attempts and is listed in `manifest.failed`. Decide: document it, or add multipart later |
| D4 | Library changes during a long snapshot | New photos go into the next snapshot; deleted ones count as skipped |
| D5 | jobLimit value | Log `PHAssetResourceUploadJob.jobLimit` on device; tune batch expectations |

### E. Schedule and retention

| ID | Scenario | Expected |
|---|---|---|
| E1 | Keep latest 2, run 4 snapshots (use Back up now) | Only the 2 newest remain in the bucket |
| E2 | Lower "keep latest" from 5 to 1 → Save | Extra snapshots deleted on the next pass without a new backup |
| E3 | Abandoned partial snapshot: interrupt a snapshot, reset app data, back up again | Old partial deleted once a newer complete one exists |
| E4 | Delete during retention | A snapshot with 20k objects | Deleted over several passes (20k objects per pass); the manifest goes last |
| E5 | Manual clock change | Set date +30 days, open app | Snapshot starts; set back → no "due" loop |
| E6 | Time zone travel | Change zone, back up | Month folders follow the phone's time zone at backup time |

### F. Providers

Run B1, B3 and E1 on each:

| ID | Provider | Notes |
|---|---|---|
| F1 | Cloudflare R2 | region `auto`, path style, token with Object Read & Write scoped to the bucket |
| F2 | AWS S3 | region set, path style on `s3.<region>.amazonaws.com`; the upload base must match |
| F3 | MinIO (self-hosted, valid TLS) | port in the endpoint (`:9000`) → host header and upload base include the port |
| F4 | Backblaze B2 (S3 API) | `s3.<region>.backblazeb2.com` |
| F5 | Wasabi / others | optional |
| F6 | Temporary credentials (STS) | not supported in the UI yet (session token); record if needed |

### G. Failure and recovery

| ID | Scenario | Expected |
|---|---|---|
| G1 | Keys revoked mid-snapshot | Jobs fail (403) → retried → give up after 4 → listed in `manifest.failed`; `lastError` shown |
| G2 | Bucket deleted | Manifest put fails → snapshot stays active, error shown; fix → completes |
| G3 | Bucket full / quota exceeded | Failures recorded; no crash |
| G4 | Photo deleted before its upload | Counted as skipped, or failed "Asset was deleted" |
| G5 | Corrupt `state.json` | Moved aside; a fresh snapshot starts; message shown |
| G6 | Presigned URL expired (job waits more than 7 days) | 403 → re-signed retry succeeds |
| G7 | Phone storage almost full | Record behavior (the system may need space for iCloud downloads) |

### H. Restore

| ID | Scenario | Expected |
|---|---|---|
| H1 | `scripts/restore.sh list` | Snapshots with complete/incomplete status |
| H2 | `restore.sh latest ./dir` | Newest complete snapshot downloaded |
| H3 | Re-import into Photos on a new phone | Photos import; creation dates come from EXIF (keys don't carry dates beyond the month) |
| H4 | `manifest.json` vs bucket contents | `files` list matches objects exactly |
