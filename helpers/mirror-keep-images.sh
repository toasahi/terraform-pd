#!/usr/bin/env bash
# Mirrors the Keep images from Google Artifact Registry into the private ECR repositories created by
# envs/management/ap-northeast-1/foundation, and prints the digests to set in keep/terraform.tfvars.
# (ECR pull through cache does not support *.pkg.dev upstreams.)
#
# Usage: helpers/mirror-keep-images.sh --version <keep version tag> --account <aws account id> [--region ap-northeast-1]
# Requires: crane (github.com/google/go-containerregistry), aws CLI with credentials for the account.
set -euo pipefail

usage() {
  sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
}

version=""
account=""
region="ap-northeast-1"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) version="$2"; shift 2 ;;
    --account) account="$2"; shift 2 ;;
    --region) region="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$version" || -z "$account" ]]; then
  usage >&2
  exit 2
fi
if [[ "$version" == "latest" ]]; then
  echo "pin an explicit Keep version; 'latest' is not reproducible" >&2
  exit 2
fi

command -v crane >/dev/null || { echo "crane is required" >&2; exit 1; }
command -v aws >/dev/null || { echo "aws CLI is required" >&2; exit 1; }

registry="${account}.dkr.ecr.${region}.amazonaws.com"
aws ecr get-login-password --region "$region" | crane auth login "$registry" --username AWS --password-stdin

declare -A images=(
  [keep-api]="us-central1-docker.pkg.dev/keephq/keep/keep-api"
  [keep-ui]="us-central1-docker.pkg.dev/keephq/keep/keep-ui"
)

for name in keep-api keep-ui; do
  source_ref="${images[$name]}:${version}"
  target_ref="${registry}/keep/${name}:${version}"
  echo "copying ${source_ref} -> ${target_ref}" >&2
  crane copy --platform linux/amd64 "$source_ref" "$target_ref"
  digest="$(crane digest "$target_ref")"
  echo "keep_${name/keep-/}_image_digest = \"${digest}\""
done
