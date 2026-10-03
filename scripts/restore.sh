#!/usr/bin/env bash
# Restore helpers using the AWS CLI (works with R2/MinIO/B2 via --endpoint-url).
#
#   export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...
#   export S3_ENDPOINT=https://<account>.r2.cloudflarestorage.com  S3_BUCKET=photos  S3_PREFIX=iphone
#   export AWS_DEFAULT_REGION=auto        # R2; use the bucket region for AWS
#
#   scripts/restore.sh list                     # snapshots, newest last, with completion status
#   scripts/restore.sh latest ./restore         # download the newest complete snapshot
#   scripts/restore.sh get 20260929T020000Z ./restore
set -euo pipefail

: "${S3_ENDPOINT:?set S3_ENDPOINT}" "${S3_BUCKET:?set S3_BUCKET}"
PREFIX="${S3_PREFIX:-}"
ROOT="${PREFIX:+${PREFIX%/}/}snapshots/"
aws_s3() { aws --endpoint-url "$S3_ENDPOINT" "$@"; }

snapshots() {
  aws_s3 s3api list-objects-v2 --bucket "$S3_BUCKET" --prefix "$ROOT" --delimiter / \
    --query 'CommonPrefixes[].Prefix' --output text | tr '\t' '\n' | sed -n "s#^${ROOT}\([0-9TZ]*\)/\$#\1#p" | sort
}

is_complete() {
  aws_s3 s3api head-object --bucket "$S3_BUCKET" --key "${ROOT}$1/manifest.json" >/dev/null 2>&1
}

case "${1:-}" in
  list)
    for id in $(snapshots); do
      if is_complete "$id"; then echo "$id complete"; else echo "$id incomplete"; fi
    done ;;
  latest)
    dest="${2:?destination folder}"
    for id in $(snapshots | sort -r); do
      if is_complete "$id"; then exec "$0" get "$id" "$dest"; fi
    done
    echo "no complete snapshot found" >&2; exit 1 ;;
  get)
    id="${2:?snapshot id}"; dest="${3:?destination folder}"
    aws_s3 s3 sync "s3://$S3_BUCKET/${ROOT}$id/" "$dest/$id/" ;;
  *)
    sed -n '2,12p' "$0"; exit 1 ;;
esac
