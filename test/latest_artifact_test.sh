#!/usr/bin/env bash
# Exercises latest_artifact.sh against mocked GitHub API responses.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/latest_artifact.sh"
failures=0

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "${expected}" != "${actual}" ]; then
    echo "FAIL: ${name}"
    echo "  expected: ${expected}"
    echo "  actual:   ${actual}"
    failures=$((failures + 1))
    return
  fi
  echo "PASS: ${name}"
}

assert_file() {
  local name="$1" path="$2"
  if [ ! -f "${path}" ]; then
    echo "FAIL: ${name} (missing ${path})"
    failures=$((failures + 1))
    return
  fi
  echo "PASS: ${name}"
}

assert_no_file() {
  local name="$1" path="$2"
  if [ -f "${path}" ]; then
    echo "FAIL: ${name} (unexpected ${path})"
    failures=$((failures + 1))
    return
  fi
  echo "PASS: ${name}"
}

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if ! grep -Fq "${needle}" <<< "${haystack}"; then
    echo "FAIL: ${name}"
    echo "  missing: ${needle}"
    echo "  in: ${haystack}"
    failures=$((failures + 1))
    return
  fi
  echo "PASS: ${name}"
}

write_fake_curl() {
  local bin_dir="$1"
  cat > "${bin_dir}/curl" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
url=""
outfile=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o)
      outfile="$2"
      shift 2
      ;;
    -H)
      shift 2
      ;;
    -sS|-sSL|-s|-S|-L)
      shift
      ;;
    http://*|https://*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

if [ -z "${url}" ]; then
  echo "fake curl: no url" >&2
  exit 1
fi

# Do not honor a workflows-collection lookup; the script must resolve
# the workflow from the current run instead.
if [[ "${url}" == *"/actions/workflows?"* ]] || [[ "${url}" == *"/actions/workflows?per_page="* ]]; then
  echo '{"message":"unexpected workflows list request"}'
  exit 0
fi

case "${SCENARIO}" in
  happy)
    if [[ "${url}" == */actions/runs/555 && "${url}" != */artifacts* ]]; then
      echo '{"id":555,"workflow_id":999}'
    elif [[ "${url}" == */actions/workflows/999/runs* ]]; then
      echo '{"total_count":1,"workflow_runs":[{"id":456,"run_number":10,"pull_requests":[{"number":42}]}]}'
    elif [[ "${url}" == */actions/runs/456/artifacts* ]]; then
      echo '{"artifacts":[{"name":"dismiss-stale-approvals-shas","id":777}]}'
    elif [[ "${url}" == */actions/artifacts/777/zip ]]; then
      cp "${FIXTURE_ZIP}" "${outfile}"
    else
      echo "fake curl: unmatched happy url ${url}" >&2
      exit 1
    fi
    ;;
  malformed)
    if [[ "${url}" == */actions/runs/555 && "${url}" != */artifacts* ]]; then
      echo '{"id":555}'
    else
      echo "fake curl: unmatched malformed url ${url}" >&2
      exit 1
    fi
    ;;
  invalid_json)
    if [[ "${url}" == */actions/runs/555 && "${url}" != */artifacts* ]]; then
      echo 'not-json'
    else
      echo "fake curl: unmatched invalid_json url ${url}" >&2
      exit 1
    fi
    ;;
  no_pr)
    if [[ "${url}" == */actions/runs/555 && "${url}" != */artifacts* ]]; then
      echo '{"id":555,"workflow_id":999}'
    elif [[ "${url}" == */actions/workflows/999/runs* ]]; then
      echo '{"total_count":1,"workflow_runs":[{"id":456,"run_number":10,"pull_requests":[{"number":99}]}]}'
    else
      echo "fake curl: unmatched no_pr url ${url}" >&2
      exit 1
    fi
    ;;
  *)
    echo "fake curl: unknown SCENARIO ${SCENARIO}" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "${bin_dir}/curl"
}

run_script() {
  local workdir="$1"
  (
    cd "${workdir}"
    PATH="${workdir}/bin:${PATH}" \
      bash "${SCRIPT}" "token" "owner/repo" "42" "feature-branch" "555" "dismiss-stale-approvals-shas"
  )
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

# --- happy path: current run yields workflow_id and a matching prior run ---
happy="${tmpdir}/happy"
mkdir -p "${happy}/bin"
write_fake_curl "${happy}/bin"
python3 - << PY
import zipfile
from pathlib import Path
root = Path("${happy}")
member = root / "shas.txt"
member.write_text("prev-head\nprev-base")
with zipfile.ZipFile(root / "fixture.zip", "w") as zf:
    zf.write(member, arcname="shas.txt")
member.unlink()
PY
export FIXTURE_ZIP="${happy}/fixture.zip"
export SCENARIO=happy
set +e
happy_out="$(run_script "${happy}" 2>&1)"
happy_status=$?
set -e
assert_eq "happy exit 0" "0" "${happy_status}"
assert_file "happy downloads shas.txt" "${happy}/shas.txt"
assert_eq "happy shas.txt contents" $'prev-head\nprev-base' "$(cat "${happy}/shas.txt")"
assert_contains "happy logs workflow id" "Latest workflow ID: 999" "${happy_out}"
assert_contains "happy logs run id" "Latest workflow run ID: 456" "${happy_out}"

# --- malformed current-run payload: fail-safe, no shas.txt ---
malformed="${tmpdir}/malformed"
mkdir -p "${malformed}/bin"
write_fake_curl "${malformed}/bin"
export SCENARIO=malformed
export FIXTURE_ZIP="${happy}/fixture.zip"
set +e
malformed_out="$(run_script "${malformed}" 2>&1)"
malformed_status=$?
set -e
assert_eq "malformed exit 0" "0" "${malformed_status}"
assert_no_file "malformed does not create shas.txt" "${malformed}/shas.txt"
assert_contains "malformed logs parse failure" "Failed to parse GitHub response with jq:" "${malformed_out}"
assert_contains "malformed logs current-run url" "https://api.github.com/repos/owner/repo/actions/runs/555" "${malformed_out}"
assert_contains "malformed logs response body" '{"id":555}' "${malformed_out}"

# --- current-run body is not JSON: fail-safe, no shas.txt ---
invalid_json="${tmpdir}/invalid_json"
mkdir -p "${invalid_json}/bin"
write_fake_curl "${invalid_json}/bin"
export SCENARIO=invalid_json
set +e
invalid_json_out="$(run_script "${invalid_json}" 2>&1)"
invalid_json_status=$?
set -e
assert_eq "invalid JSON exit 0" "0" "${invalid_json_status}"
assert_no_file "invalid JSON does not create shas.txt" "${invalid_json}/shas.txt"
assert_contains "invalid JSON logs parse failure" "Failed to parse GitHub response with jq:" "${invalid_json_out}"
assert_contains "invalid JSON logs current-run url" "https://api.github.com/repos/owner/repo/actions/runs/555" "${invalid_json_out}"
assert_contains "invalid JSON logs response body" "not-json" "${invalid_json_out}"

# --- prior runs exist but none match the PR ---
no_pr="${tmpdir}/no_pr"
mkdir -p "${no_pr}/bin"
write_fake_curl "${no_pr}/bin"
export SCENARIO=no_pr
set +e
no_pr_out="$(run_script "${no_pr}" 2>&1)"
no_pr_status=$?
set -e
assert_eq "no matching PR exit 0" "0" "${no_pr_status}"
assert_no_file "no matching PR does not create shas.txt" "${no_pr}/shas.txt"
assert_contains "no matching PR keeps existing message" "No successful workflow run found for PR 42 on branch feature-branch" "${no_pr_out}"

# --- action.yml wiring and surrounding MATCH fail-safe ---
action_yml="${ROOT}/action.yml"
assert_contains "action passes github.run_id as argument 5" '"${{ github.run_id }}" "dismiss-stale-approvals-shas"' "$(cat "${action_yml}")"
assert_contains "missing previous SHAs still set MATCH=-1" 'echo "MATCH=-1" >> $GITHUB_ENV' "$(cat "${action_yml}")"
assert_contains "changed diff still sets MATCH=0" 'echo "MATCH=0" >> $GITHUB_ENV' "$(cat "${action_yml}")"

if [ "${failures}" -ne 0 ]; then
  echo "${failures} failure(s)"
  exit 1
fi
echo "all tests passed"
