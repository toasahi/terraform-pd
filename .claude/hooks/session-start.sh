#!/usr/bin/env bash
# SessionStart hook (Claude Code on the web only): installs the tools the verify loop needs.
#   terraform (version from .github/workflows/ci.yml), tflint + aws ruleset (version from .tflint.hcl),
#   lambda/node_modules (pnpm), checkov (best effort, venv).
# When registry.terraform.io is unreachable (egress policy), builds a provider filesystem mirror from
# releases.hashicorp.com for the providers pinned in the committed .terraform.lock.hcl files.
# Every step is best effort: the hook always exits 0 and prints what is available, so the session
# starts and the verify loop reports missing tools as SKIPPED instead of passing silently.
set -uo pipefail

if [[ "${CLAUDE_CODE_REMOTE:-}" != "true" ]]; then
  exit 0
fi

ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
TOOLS="${HOME}/.cache/terraform-pd-tools"
BIN="${TOOLS}/bin"
TFLINT_VERSION="0.64.0"
mkdir -p "${BIN}"
export PATH="${BIN}:${PATH}"

case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64 | arm64) ARCH=arm64 ;;
  *) ARCH=amd64 ;;
esac

status=()
note() { status+=("$1"); }

persist() {
  [[ -n "${CLAUDE_ENV_FILE:-}" ]] && echo "$1" >>"${CLAUDE_ENV_FILE}"
}

fetch_zip_bin() { # url dest-dir
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL --retry 3 -o "${tmp}/a.zip" "$1" && unzip -oq "${tmp}/a.zip" -d "$2"
  local rc=$?
  rm -rf "${tmp}"
  return ${rc}
}

# --- terraform ---------------------------------------------------------------------------------
tf_version="$(sed -n 's/^ *TERRAFORM_VERSION: *//p' "${ROOT}/.github/workflows/ci.yml" | head -1)"
if [[ -n "${tf_version}" ]] && ! terraform version 2>/dev/null | head -1 | grep -q "v${tf_version}$"; then
  fetch_zip_bin "https://releases.hashicorp.com/terraform/${tf_version}/terraform_${tf_version}_linux_${ARCH}.zip" "${BIN}" >/dev/null 2>&1
fi
if terraform version >/dev/null 2>&1; then
  note "terraform: $(terraform version | head -1)"
else
  note "terraform: MISSING (download failed)"
fi

# --- provider mirror (only when the public registry is blocked) --------------------------------
if command -v terraform >/dev/null && ! curl -fsS -o /dev/null --max-time 10 https://registry.terraform.io/.well-known/terraform.json 2>/dev/null; then
  mirror="${TOOLS}/tf-mirror"
  ok=true
  while read -r addr version; do
    ns="${addr#registry.terraform.io/}"
    name="${ns#*/}"
    dir="${mirror}/${addr}"
    file="terraform-provider-${name}_${version}_linux_${ARCH}.zip"
    mkdir -p "${dir}"
    [[ -s "${dir}/${file}" ]] && continue
    curl -fsSL --retry 3 -o "${dir}/${file}" \
      "https://releases.hashicorp.com/terraform-provider-${name}/${version}/${file}" || { ok=false; rm -f "${dir}/${file}"; }
  done < <(awk '/^provider "/ { gsub(/"/, "", $2); p = $2 } /^  version *=/ { gsub(/"/, "", $3); print p, $3 }' \
    "${ROOT}"/envs/*/*/*/.terraform.lock.hcl | sort -u)
  cat >"${TOOLS}/terraformrc" <<RC
provider_installation {
  filesystem_mirror {
    path    = "${mirror}"
    include = ["registry.terraform.io/hashicorp/*"]
  }
}
plugin_cache_dir = "${TOOLS}/plugin-cache"
RC
  mkdir -p "${TOOLS}/plugin-cache"
  persist "export TF_CLI_CONFIG_FILE=\"${TOOLS}/terraformrc\""
  if ${ok}; then note "providers: registry blocked -> filesystem mirror (lock file versions)"; else note "providers: mirror INCOMPLETE"; fi
fi

# --- tflint + aws ruleset ------------------------------------------------------------------------
if ! tflint --version 2>/dev/null | grep -q "${TFLINT_VERSION}"; then
  fetch_zip_bin "https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/tflint_linux_${ARCH}.zip" "${BIN}" >/dev/null 2>&1
fi
ruleset_version="$(awk '/plugin "aws"/ { f = 1 } f && /version/ { gsub(/"/, "", $3); print $3; exit }' "${ROOT}/.tflint.hcl")"
if [[ -n "${ruleset_version}" ]]; then
  pdir="${HOME}/.tflint.d/plugins/github.com/terraform-linters/tflint-ruleset-aws/${ruleset_version}"
  if [[ ! -x "${pdir}/tflint-ruleset-aws" ]]; then
    mkdir -p "${pdir}"
    fetch_zip_bin "https://github.com/terraform-linters/tflint-ruleset-aws/releases/download/v${ruleset_version}/tflint-ruleset-aws_linux_${ARCH}.zip" "${pdir}" >/dev/null 2>&1
  fi
fi
if tflint --version >/dev/null 2>&1; then
  note "tflint: $(tflint --version | head -1), aws ruleset ${ruleset_version:-?}"
else
  note "tflint: MISSING"
fi

# --- lambda dependencies ---------------------------------------------------------------------------
if command -v node >/dev/null; then
  command -v pnpm >/dev/null || corepack enable >/dev/null 2>&1
  if (cd "${ROOT}/lambda" && pnpm install --frozen-lockfile >/dev/null 2>&1); then
    note "lambda: node $(node --version), pnpm install ok"
  else
    note "lambda: pnpm install FAILED"
  fi
else
  note "lambda: node MISSING"
fi

# --- checkov (best effort) -------------------------------------------------------------------------
if [[ ! -x "${TOOLS}/venv/bin/checkov" ]] && command -v python3 >/dev/null; then
  python3 -m venv "${TOOLS}/venv" >/dev/null 2>&1 &&
    timeout 240 "${TOOLS}/venv/bin/pip" install -q checkov >/dev/null 2>&1
fi
if [[ -x "${TOOLS}/venv/bin/checkov" ]]; then
  ln -sf "${TOOLS}/venv/bin/checkov" "${BIN}/checkov"
  note "checkov: installed"
else
  note "checkov: MISSING (verify reports it as SKIPPED)"
fi

persist "export PATH=\"${BIN}:\$PATH\""

echo "[session-start] tool status:"
printf '  - %s\n' "${status[@]}"
exit 0
