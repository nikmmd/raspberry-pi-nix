#!/usr/bin/env nix
#! nix shell nixpkgs#bash nixpkgs#git nixpkgs#gh nixpkgs#jq --command bash
set -euo pipefail

summary_file="${1:-kernel-update-summary.md}"
repo="raspberrypi/linux"

if [[ -z "${GITHUB_TOKEN:-}" && -z "${GH_TOKEN:-}" ]]; then
  echo "GITHUB_TOKEN or GH_TOKEN must be set" >&2
  exit 1
fi

if [[ -z "${GH_TOKEN:-}" ]]; then
  export GH_TOKEN="$GITHUB_TOKEN"
fi

tracked_series=(
  "v6_12|rpi-6.12.y|rpi-linux-6_12-src"
  "v6_18|rpi-6.18.y|rpi-linux-6_18-src"
)

accepted=()
skipped=()
unchanged=()

write_output() {
  local name="$1"
  local value="$2"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$name" "$value" >> "$GITHUB_OUTPUT"
  fi
}

resolve_branch_sha() {
  local branch="$1"

  gh api "/repos/${repo}/git/ref/heads/${branch}" --jq '.object.sha'
}

current_locked_rev() {
  local input="$1"

  jq -r --arg input "$input" '.nodes[$input].locked.rev // ""' flake.lock
}

status_signal_is_good() {
  local sha="$1"
  local status_json
  local total_count
  local state

  status_json="$(gh api "/repos/${repo}/commits/${sha}/status")"
  total_count="$(jq -r '.total_count' <<< "$status_json")"
  state="$(jq -r '.state' <<< "$status_json")"

  if [[ "$total_count" == "0" ]]; then
    return 2
  fi

  if [[ "$state" == "success" ]]; then
    return 0
  fi

  return 1
}

check_runs_signal_is_good() {
  local sha="$1"
  local checks_json
  local total_count
  local bad_count

  checks_json="$(gh api -H "Accept: application/vnd.github+json" "/repos/${repo}/commits/${sha}/check-runs?per_page=100")"
  total_count="$(jq -r '.total_count' <<< "$checks_json")"

  if [[ "$total_count" == "0" ]]; then
    return 2
  fi

  bad_count="$(
    jq -r '
      [
        .check_runs[]
        | select(
            (.status != "completed")
            or (
              (.conclusion // "") as $conclusion
              | (["success", "neutral", "skipped"] | index($conclusion) | not)
            )
          )
      ]
      | length
    ' <<< "$checks_json"
  )"

  if [[ "$bad_count" == "0" ]]; then
    return 0
  fi

  return 1
}

upstream_commit_is_good() {
  local sha="$1"
  local saw_signal=0
  local failed_signal=0

  set +e
  status_signal_is_good "$sha"
  local status_result=$?
  check_runs_signal_is_good "$sha"
  local checks_result=$?
  set -e

  case "$status_result" in
    0) saw_signal=1 ;;
    1) failed_signal=1 ;;
    2) ;;
    *) failed_signal=1 ;;
  esac

  case "$checks_result" in
    0) saw_signal=1 ;;
    1) failed_signal=1 ;;
    2) ;;
    *) failed_signal=1 ;;
  esac

  if [[ "$failed_signal" == "1" ]]; then
    return 1
  fi

  if [[ "$saw_signal" != "1" ]]; then
    return 2
  fi

  return 0
}

{
  echo "## Raspberry Pi kernel update summary"
  echo
  echo "Tracked upstream repository: \`${repo}\`"
  echo
} > "$summary_file"

for entry in "${tracked_series[@]}"; do
  IFS='|' read -r version branch input <<< "$entry"
  sha="$(resolve_branch_sha "$branch")"

  set +e
  upstream_commit_is_good "$sha"
  result=$?
  set -e

  case "$result" in
    0)
      current_rev="$(current_locked_rev "$input")"
      if [[ "$current_rev" == "$sha" ]]; then
        echo "Keeping ${version} (${branch}) at ${sha}: already locked"
        unchanged+=("${version}|${branch}|${input}|${sha}")
      else
        echo "Accepting ${version} (${branch}) at ${sha}"
        nix flake lock --override-input "$input" "github:${repo}?rev=${sha}"
        accepted+=("${version}|${branch}|${input}|${sha}")
      fi
      ;;
    1)
      echo "Skipping ${version} (${branch}) at ${sha}: upstream checks are not successful"
      skipped+=("${version}|${branch}|${sha}|upstream checks are not successful")
      ;;
    2)
      echo "Skipping ${version} (${branch}) at ${sha}: no visible upstream checks or statuses"
      skipped+=("${version}|${branch}|${sha}|no visible upstream checks or statuses")
      ;;
    *)
      echo "Skipping ${version} (${branch}) at ${sha}: unexpected check result ${result}"
      skipped+=("${version}|${branch}|${sha}|unexpected check result ${result}")
      ;;
  esac
done

{
  if (( ${#accepted[@]} > 0 )); then
    echo "### Accepted updates"
    echo
    for item in "${accepted[@]}"; do
      IFS='|' read -r version branch input sha <<< "$item"
      echo "- \`${version}\` / \`${branch}\` / \`${input}\`: \`${sha}\`"
    done
    echo
  fi

  if (( ${#unchanged[@]} > 0 )); then
    echo "### Already current"
    echo
    for item in "${unchanged[@]}"; do
      IFS='|' read -r version branch input sha <<< "$item"
      echo "- \`${version}\` / \`${branch}\` / \`${input}\`: \`${sha}\`"
    done
    echo
  fi

  if (( ${#skipped[@]} > 0 )); then
    echo "### Skipped updates"
    echo
    for item in "${skipped[@]}"; do
      IFS='|' read -r version branch sha reason <<< "$item"
      echo "- \`${version}\` / \`${branch}\`: \`${sha}\` (${reason})"
    done
    echo
  fi
} >> "$summary_file"

if git diff --quiet -- flake.lock; then
  write_output "changed" "false"
else
  write_output "changed" "true"
fi
