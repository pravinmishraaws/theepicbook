#!/bin/bash
#
# pipeline-triage.sh
# Read-only Azure DevOps dual-pipeline failure-triage tool for EpicBook.
#
# Queries the Infrastructure Pipeline and the Application Pipeline,
# retrieves run metadata AND real step-console log text (via the Build
# Logs REST API), classifies any failure into a known category, and
# writes a sanitized, structured health report.
#
# This script performs NO write, retry, cancel, approve, or delete
# operations against Azure DevOps. It only reads.

# Corrected version: LF endings; validated HTTP/JSON; fresh per-run logs;
# fixed grep; private temporary directory; filtered output; explicit latest run.
# Prerequisites: az CLI + azure-devops extension, curl, jq; az login with
# an identity authorized to read both pipelines and their Build Logs API.
# PAT-only az devops login does not provide the Entra token used below.
# Reports are heuristic evidence, not proof of a root cause.
# Exit codes: 0 healthy, 1 warning, 2 pipeline failure, 3 tool/config/API error.
set -uo pipefail
umask 077
# Do not run with bash -x: shell tracing can reveal access tokens.

# ---------------------------------------------------------------------
# Configuration — replace only the clearly marked student values below.
# Never place a PAT, password, or other secret in this file.
# ---------------------------------------------------------------------

full_name="EZEOBI CHINECHEREM"
ado_org="https://dev.azure.com/anjanamuthunayake"              # e.g. https://dev.azure.com/DMI-Cohort-3
ado_project="EpicBook-Deployment"          # e.g. Epicbook Deployment
ado_infra_pipeline_id="38"    # numeric ID of the Infrastructure Pipeline
ado_app_pipeline_id="139"      # numeric ID of the Application Pipeline

# Azure DevOps resource ID used to request an AAD access token for the
# REST API (this is a public, fixed constant — not a secret).
ado_resource_id="499b84ac-1321-427f-aa17-267ca6975798"

# ---------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------

base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
report_dir="$base_dir/reports"
report_file="$report_dir/pipeline-health-report.txt"

# ---------------------------------------------------------------------
# Failure-category patterns: "Category Name|regex1|regex2|..."
# All matching categories are reported. Counts represent findings, not
# pipeline totals. All matching is case-insensitive.
# ---------------------------------------------------------------------

categories=(
  "Dependency Installation Failure|npm ERR!|ENOENT|ERESOLVE|pip install.*error|ModuleNotFoundError|package not found"
  "Build or Compilation Failure|build failed|compilation error|SyntaxError|TS[0-9]{4}|webpack.*failed"
  "Test Failure|tests? failed|AssertionError|FAIL |[0-9]+ failing|expect\\(received\\)"
  "Authentication, Authorization, or SSH Failure|401 Unauthorized|403 Forbidden|TF400813|invalid_grant|token has expired|permission denied \\(publickey\\)|Bad credentials"
  "Agent Availability, Timeout, or Queue Failure|no agent found|agent.*offline|timed out waiting for an agent|job.*timed out|runner.*offline|no agent pool"
  "Terraform Infrastructure or Provisioning Failure|Error: .*[Tt]erraform|Error acquiring the state lock|ResourceGroupNotFound|InvalidParameterValue|Error: Provider produced inconsistent|plan failed|apply failed|Error: creating"
  "Ansible, Nginx, or Application Deployment Failure|ansible-playbook.*failed|FAILED! =>|UNREACHABLE!|nginx: \\[emerg\\]|nginx.*failed to start|systemctl.*failed|deployment failed"
)

# ---------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------

pass_count=0
warning_count=0
failure_count=0
error_count=0

if ! mkdir -p "$report_dir" || ! : > "$report_file"; then
  printf '%s\n' '[ERROR] Cannot create report directory/file' >&2
  exit 3
fi
work_dir=$(mktemp -d) || exit 3
trap 'rm -rf -- "$work_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------------------------------------------------------------------
# Output / logging helpers
# ---------------------------------------------------------------------

write_line() {
  if ! printf '%s\n' "$1" | sanitize_stream | tee -a "$report_file"; then
    printf '%s\n' '[ERROR] Cannot write report' >&2
    exit 3
  fi
}

mark_pass() {
  write_line "[PASS] $1"
  pass_count=$((pass_count + 1))
}

mark_warning() {
  write_line "[WARN] $1"
  warning_count=$((warning_count + 1))
}

mark_failure() {
  write_line "[FAIL] $1"
  failure_count=$((failure_count + 1))
}

mark_error() {
  write_line "[ERROR] $1"
  error_count=$((error_count + 1))
}

print_header() {
  write_line "========================================"
  write_line "CI/CD Pipeline Failure Triage Report"
  write_line "========================================"
  write_line "Full Name: $full_name"
  write_line "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  write_line "Provider: Azure DevOps"
  write_line "Organization: $ado_org"
  write_line "Project: $ado_project"
  write_line ""
}

# Best-effort filtering. Redact entire private-key blocks, common secret
# assignments and authorization lines before writing persistent output.
# Unknown/unlabelled secrets can still evade these heuristics.
sanitize_stream() {
  awk '
    {
      lower = tolower($0)
      if (lower ~ /-----begin .*private key-----/) { key=1 }
      if (key) {
        print "[REDACTED: private key material removed]"
        if (lower ~ /-----end .*private key-----/) { key=0 }
        next
      }
      if (lower ~ /authorization[[:space:]]*:|bearer[[:space:]]+[a-z0-9._-]+|password|passwd|client.?secret|access.?token|refresh.?token|personal access token|pat[_-]?token|connection.?string|accountkey|sig=|pwd[[:space:]]*[:=]|token[[:space:]]*["]?[[:space:]]*[:=]|secret[[:space:]]*["]?[[:space:]]*[:=]/) {
        print "[REDACTED: sensitive value removed]"
      } else { print }
    }'
}

sanitize_line() {
  printf '%s\n' "$1" | sanitize_stream
}

# ---------------------------------------------------------------------
# Pre-flight configuration check
# ---------------------------------------------------------------------

validate_config() {
  local missing=0
  ado_org="${ado_org%/}"
  if [[ ! "$ado_org" =~ ^https://dev\.azure\.com/[A-Za-z0-9._-]+$ && ! "$ado_org" =~ ^https://[A-Za-z0-9-]+\.visualstudio\.com$ ]]; then
    write_line "[CONFIG ERROR] Use an Azure DevOps Services organization HTTPS URL"
    missing=1
  fi
  if [[ ! "$ado_infra_pipeline_id" =~ ^[1-9][0-9]*$ || ! "$ado_app_pipeline_id" =~ ^[1-9][0-9]*$ ]]; then
    write_line "[CONFIG ERROR] Both pipeline IDs must be positive integers"
    missing=1
  fi

  [ -z "$ado_org" ] && { write_line "[CONFIG ERROR] ado_org is not set"; missing=1; }
  [ -z "$ado_project" ] && { write_line "[CONFIG ERROR] ado_project is not set"; missing=1; }
  [ -z "$ado_infra_pipeline_id" ] && { write_line "[CONFIG ERROR] ado_infra_pipeline_id is not set"; missing=1; }
  [ -z "$ado_app_pipeline_id" ] && { write_line "[CONFIG ERROR] ado_app_pipeline_id is not set"; missing=1; }
  ! command -v az >/dev/null 2>&1 && { write_line "[CONFIG ERROR] az CLI not found"; missing=1; }
  ! command -v curl >/dev/null 2>&1 && { write_line "[CONFIG ERROR] curl not found"; missing=1; }
  ! command -v jq >/dev/null 2>&1 && { write_line "[CONFIG ERROR] jq not found"; missing=1; }

  if [ "$missing" -eq 1 ]; then
    mark_error "Script configuration incomplete. Cannot proceed."
    print_summary
    exit "$?"
  fi
}

# ---------------------------------------------------------------------
# Fetches real step-console log text for a completed build via the
# Azure DevOps Build Logs REST API (read-only: GET requests only).
# Appends sanitized log text to the given log file.
# ---------------------------------------------------------------------

# REST helper: body stays in memory until it has been checked/sanitized.
# Send the token via stdin config, rather than curl process arguments.
# Do not follow redirects or print remote error bodies/CLI diagnostics.
api_get() {
  local url="$1" token="$2" accept="$3" response http_code
  if ! response=$(printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl --config - --silent --connect-timeout 15 --max-time 120 \
      --proto '=https' -H "Accept: $accept" -w $'\n%{http_code}' "$url" 2>/dev/null); then
    mark_error "Build Logs API request failed (network/TLS/timeout); response not saved"
    return 1
  fi
  http_code="${response##*$'\n'}"
  if [ "$http_code" != "200" ]; then
    mark_error "Build Logs API returned HTTP $http_code; response not saved"
    return 1
  fi
  api_body="${response%$'\n'*}"
}

fetch_build_logs() {
  local build_id="$1" log_file="$2" token encoded_project log_ids log_id
  local api_body="" content
  if ! token=$(az account get-access-token --resource "$ado_resource_id" --query accessToken -o tsv 2>/dev/null) || [ -z "$token" ]; then
    mark_error "Could not obtain an Entra access token; check az login and Azure DevOps access"
    return 1
  fi
  if [[ ! "$token" =~ ^[A-Za-z0-9._-]+$ ]]; then
    mark_error "Access token has an unexpected format"
    return 1
  fi
  encoded_project=$(jq -rn --arg p "$ado_project" '$p|@uri') || return 1
  api_get "$ado_org/$encoded_project/_apis/build/builds/$build_id/logs?api-version=7.1" "$token" "application/json" || return 1
  if ! printf '%s' "$api_body" | jq -e '
      type == "object" and (.value | type == "array") and
      all(.value[]; (.id | type == "number") and (.id > 0) and (.id == (.id | floor)))' >/dev/null 2>&1; then
    mark_error "Build Logs API returned invalid log-list JSON"
    return 1
  fi
  log_ids=$(printf '%s' "$api_body" | jq -r '.value[].id') || return 1
  if [ -z "$log_ids" ]; then
    write_line "No individual logs were returned for build $build_id; no category evidence is available."
    return 0
  fi
  # Stage sanitized logs; publish only when all downloads succeed.
  : > "$work_dir/sanitized.log" || return 1
  for log_id in $log_ids; do
    if ! api_get "$ado_org/$encoded_project/_apis/build/builds/$build_id/logs/$log_id?api-version=7.1" "$token" "text/plain"; then
      return 1
    fi
    content="$api_body"
    if ! { printf -- '--- Build %s / Log %s ---\n' "$build_id" "$log_id";
            printf '%s\n' "$content" | sanitize_stream; } >> "$work_dir/sanitized.log"; then
      mark_error "Could not write sanitized log data"
      return 1
    fi
  done
  if ! cat "$work_dir/sanitized.log" > "$log_file"; then
    mark_error "Could not publish sanitized logs"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------
# Runs the category checks against a pipeline's log file. Only called
# when the pipeline's latest completed run result is "failed".
# Returns 0 if a known category matched, 1 if none matched
# (Unclassified Pipeline Failure).
# ---------------------------------------------------------------------

run_category_checks() {
  local pipeline_label="$1"
  local log_file="$2"
  local matched=1

  local entry
  for entry in "${categories[@]}"
  do
    local category_name="${entry%%|*}"
    local pattern_part="${entry#*|}"
    local pattern="$pattern_part"

    local evidence_line
    evidence_line=$(grep -m 1 -iE "$pattern" "$log_file" 2>/dev/null || true)

    if [ -n "$evidence_line" ]; then
      local sanitized_evidence
      sanitized_evidence=$(sanitize_line "$evidence_line")
      mark_failure "$pipeline_label — $category_name"
      write_line "    Evidence: $sanitized_evidence"
      matched=0
    fi
  done

  return "$matched"
}

# ---------------------------------------------------------------------
# Handles one pipeline end-to-end: fetch metadata, determine state,
# fetch logs and classify if failed.
# ---------------------------------------------------------------------

process_pipeline() {
  local pipeline_label="$1"
  local pipeline_id="$2"
  local log_file="$3"

  write_line "----------------------------------------"
  write_line "$pipeline_label (Pipeline ID: $pipeline_id)"
  write_line "----------------------------------------"

  # Clear even for succeeded, queued, missing, or inaccessible runs.
  if ! : > "$log_file"; then
    mark_error "$pipeline_label — Cannot reset log file"
    return
  fi
  local run_json
  run_json=$(az pipelines runs list \
    --organization "$ado_org" \
    --project "$ado_project" \
    --pipeline-ids "$pipeline_id" \
    --top 1 \
    --query-order QueueTimeDesc \
    --output json 2>/dev/null)

  local az_exit=$?
  if [ "$az_exit" -ne 0 ]; then
    mark_error "$pipeline_label — Azure DevOps CLI request failed; check extension, login, permissions and configuration"
    return
  fi
  if ! printf '%s' "$run_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    mark_error "$pipeline_label — Invalid run-list JSON"
    return
  fi
  local run_count
  run_count=$(printf '%s' "$run_json" | jq 'length')
  if [ "$run_count" -eq 0 ]; then
    mark_warning "$pipeline_label — No run found"
    return
  fi
  if ! printf '%s' "$run_json" | jq -e '.[0] | type == "object" and
      (.id | type == "number") and (.id > 0) and (.id == (.id | floor)) and
      (.status | type == "string") and
      (.result == null or (.result | type == "string"))' >/dev/null 2>&1; then
    mark_error "$pipeline_label — Invalid run metadata"
    return
  fi

  local run_id status result branch finish_time
  run_id=$(echo "$run_json" | jq -r '.[0].id')
  status=$(echo "$run_json" | jq -r '.[0].status')
  result=$(echo "$run_json" | jq -r '.[0].result // "none"')
  branch=$(echo "$run_json" | jq -r '.[0].sourceBranch // "unknown"')
  finish_time=$(echo "$run_json" | jq -r '.[0].finishTime // "unknown"')

  write_line "Run ID: $run_id"
  write_line "Branch: $branch"
  write_line "Status: $status"
  write_line "Result: $result"
  write_line "Completion Time: $finish_time"

  if [ "$status" != "completed" ]; then
    mark_warning "$pipeline_label — Latest run is '$status' (not yet completed); final result unknown"
    return
  fi

  case "$result" in
    succeeded)
      mark_pass "$pipeline_label — Latest completed run succeeded"
      ;;
    canceled)
      mark_warning "$pipeline_label — Latest completed run was canceled"
      ;;
    partiallySucceeded)
      mark_warning "$pipeline_label — Latest completed run partially succeeded"
      ;;
    failed)
      write_line "Retrieving step console logs for build $run_id ..."
      if fetch_build_logs "$run_id" "$log_file"; then
        if run_category_checks "$pipeline_label" "$log_file"; then
          : # a known category already marked as failure above
        else
          mark_failure "$pipeline_label — Unclassified Pipeline Failure (Azure DevOps reported failure but no known pattern matched retrieved log text; manual log review required — root cause not confirmed)"
        fi
      else
        mark_failure "$pipeline_label — Run failed, but log retrieval also failed; root cause not confirmed from available evidence"
      fi
      ;;
    *)
      mark_warning "$pipeline_label — Unrecognized result value: $result"
      ;;
  esac

  write_line ""
}

print_summary() {
  local overall_status
  local script_exit_code

  if [ "$error_count" -gt 0 ]; then
    overall_status="ERROR"
    script_exit_code=3
  elif [ "$failure_count" -gt 0 ]; then
    overall_status="FAIL"
    script_exit_code=2
  elif [ "$warning_count" -gt 0 ]; then
    overall_status="WARN"
    script_exit_code=1
  else
    overall_status="HEALTHY"
    script_exit_code=0
  fi

  write_line ""
  write_line "Summary:"
  write_line "PASS: $pass_count"
  write_line "WARN: $warning_count"
  write_line "FAIL: $failure_count"
  write_line "ERROR: $error_count"
  write_line "Overall Status: $overall_status"
  write_line "Script Exit Code: $script_exit_code"
  write_line "Report File: $report_file"
  write_line "Infrastructure Log: $report_dir/infra-last-run.log"
  write_line "Application Log: $report_dir/app-last-run.log"

  return "$script_exit_code"
}

# ---------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------

validate_config
print_header
write_line "Category matches are heuristic evidence; counts represent findings."

process_pipeline "Infrastructure Pipeline" "$ado_infra_pipeline_id" "$report_dir/infra-last-run.log"
process_pipeline "Application Pipeline" "$ado_app_pipeline_id" "$report_dir/app-last-run.log"

print_summary
exit $?
