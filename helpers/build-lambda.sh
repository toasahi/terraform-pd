#!/usr/bin/env bash
# Builds the Lambda deployment package (lambda/dist/lambda.zip) consumed by the
# envs/*/alert-pipeline root module: an esbuild bundle (ESM, Node.js 24) of the TypeScript / Effect
# handlers, shared by the authorizer / ingest / router / dispatcher functions.
#
# Usage: helpers/build-lambda.sh [--skip-tests]
# Requires: Node.js 24 with corepack (pnpm version comes from lambda/package.json), zip.
set -euo pipefail

usage() {
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
}

run_tests=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-tests) run_tests=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v node >/dev/null || { echo "node is required" >&2; exit 1; }
command -v zip >/dev/null || { echo "zip is required" >&2; exit 1; }
command -v pnpm >/dev/null || corepack enable

cd "$(dirname "$0")/../lambda"
pnpm install --frozen-lockfile
pnpm typecheck
if [[ "$run_tests" == true ]]; then
  pnpm test
fi
pnpm build
