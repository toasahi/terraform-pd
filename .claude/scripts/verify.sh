#!/usr/bin/env bash
# Deterministic verifier for the agent loops (the "test" facet of the workflow).
#
# Usage: .claude/scripts/verify.sh [--scope changed|all] [--level fast|full] [--base <ref>]
#   --scope changed  only checks what the branch touched (default; vs merge-base with the base ref,
#                    plus uncommitted and untracked files)
#   --scope all      checks the whole repository (same set as CI)
#   --level fast     terraform fmt, lambda typecheck + vitest, harness tests, bash -n   (Stop gate)
#   --level full     fast + terraform validate / test, tflint, checkov                   (default)
#   --base <ref>     base ref for --scope changed (default: origin/main, falls back to HEAD)
#
# Output: one line per check (PASS / FAIL / SKIP) and a final "RESULT: PASS|FAIL|UNVERIFIED".
# Exit:   0 = PASS, 1 = FAIL, 3 = UNVERIFIED (nothing failed, but a needed tool was missing),
#         2 = usage error. A missing tool is never reported as PASS.
set -uo pipefail

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }

scope=changed
level=full
base=origin/main
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) scope="${2:-}"; shift 2 ;;
    --level) level="${2:-}"; shift 2 ;;
    --base) base="${2:-}"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ "${scope}" =~ ^(changed|all)$ && "${level}" =~ ^(fast|full)$ ]] || { usage >&2; exit 2; }

ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "${ROOT}" || exit 2
LOG_DIR="$(mktemp -d)"
trap 'rm -rf "${LOG_DIR}"' EXIT

failed=0
skipped=0

run() { # name command...
  local name="$1"; shift
  local log="${LOG_DIR}/$(echo "${name}" | tr -c 'a-zA-Z0-9' '_').log"
  if "$@" >"${log}" 2>&1; then
    echo "PASS ${name}"
  else
    echo "FAIL ${name}"
    # Name the failing node tests first (spec "✖" / TAP "not ok"): the tail below may not reach them.
    grep -E '^[[:space:]]*(✖ |not ok )' "${log}" | awk '!seen[$0]++' | head -n 20 | sed 's/^/     ! /'
    tail -n 40 "${log}" | sed 's/^/     | /'
    failed=$((failed + 1))
  fi
}

skip() { echo "SKIP $1 ($2)"; skipped=$((skipped + 1)); }

have() { command -v "$1" >/dev/null 2>&1; }

# --- what changed -------------------------------------------------------------------------------
if [[ "${scope}" == all ]]; then
  changed="$(git ls-files; git ls-files --others --exclude-standard)"
else
  merge_base="$(git merge-base HEAD "${base}" 2>/dev/null || git rev-parse HEAD)"
  changed="$( {
    git diff --name-only "${merge_base}"
    git ls-files --others --exclude-standard
  } | sort -u)"
fi
changed="$(echo "${changed}" | while read -r f; do [[ -n "${f}" && -e "${f}" ]] && echo "${f}"; done)"

tf_files="$(echo "${changed}" | grep -E '\.(tf|tftest\.hcl)$' || true)"
tf_dirs="$(echo "${changed}" | grep -E '\.(tf|tftest\.hcl)$|\.terraform\.lock\.hcl$' |
  sed -E -n 's#^(modules/[^/]+)/.*#\1#p; s#^(envs/[^/]+/[^/]+/[^/]+)/.*#\1#p' | sort -u)"
# A module change is validated through every root that may call it.
if echo "${tf_dirs}" | grep -q '^modules/'; then
  tf_dirs="$(printf '%s\n' "${tf_dirs}" $(ls -d envs/*/*/*/ | sed 's#/$##') | sort -u)"
fi
[[ "${scope}" == all ]] && tf_dirs="$(ls -d modules/* envs/*/*/*/ | sed 's#/$##')"
lambda_changed="$(echo "${changed}" | grep -E '^lambda/' || true)"
harness_changed="$(echo "${changed}" | grep -E '^\.claude/' || true)"
sh_files="$(echo "${changed}" | grep -E '\.sh$' || true)"

echo "verify: scope=${scope} level=${level} files=$(echo "${changed}" | grep -c . || true)"

# --- fast ---------------------------------------------------------------------------------------
if [[ -n "${tf_files}" ]]; then
  if have terraform; then
    # shellcheck disable=SC2086
    run "terraform fmt" terraform fmt -check -diff ${tf_files}
  else
    skip "terraform fmt" "terraform not installed"
  fi
fi

if [[ -n "${lambda_changed}" ]]; then
  if have pnpm && [[ -d lambda/node_modules ]]; then
    run "lambda typecheck" pnpm --dir lambda typecheck
    run "lambda test" pnpm --dir lambda test
  else
    skip "lambda typecheck/test" "pnpm or lambda/node_modules missing"
  fi
fi

if [[ -n "${harness_changed}" ]]; then
  if have node; then
    run "harness test" node --test --test-reporter=spec "${ROOT}/.claude/scripts/test/*.test.mjs"
  else
    skip "harness test" "node not installed"
  fi
fi

for f in ${sh_files}; do
  run "bash -n ${f}" bash -n "${f}"
done

# --- full ---------------------------------------------------------------------------------------
if [[ "${level}" == full ]]; then
  for d in ${tf_dirs}; do
    [[ -d "${d}" ]] || continue
    if ! have terraform; then
      skip "terraform validate ${d}" "terraform not installed"
      continue
    fi
    run "terraform init ${d}" terraform -chdir="${d}" init -backend=false -input=false -no-color
    run "terraform validate ${d}" terraform -chdir="${d}" validate -no-color
    if [[ -d "${d}/tests" ]]; then
      run "terraform test ${d}" terraform -chdir="${d}" test -no-color
    fi
  done
  if [[ -n "${tf_dirs}" ]]; then
    if have tflint; then
      for d in ${tf_dirs}; do
        [[ -d "${d}" ]] && run "tflint ${d}" tflint --chdir="${d}" --config="${ROOT}/.tflint.hcl"
      done
    else
      skip "tflint" "tflint not installed"
    fi
    if have checkov; then
      run "checkov" checkov -d . --config-file .checkov.yaml --quiet --compact
    else
      skip "checkov" "checkov not installed"
    fi
  fi
fi

if ((failed > 0)); then
  echo "RESULT: FAIL (${failed} failed, ${skipped} skipped)"
  exit 1
elif ((skipped > 0)); then
  echo "RESULT: UNVERIFIED (${skipped} skipped because a tool is missing)"
  exit 3
fi
echo "RESULT: PASS"
exit 0
