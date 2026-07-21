#!/usr/bin/env nix
#! nix shell nixpkgs#bash nixpkgs#git nixpkgs#gh nixpkgs#jq --command bash
set -euo pipefail

repo="raspberrypi/linux"
series_json="$(nix eval --json --no-write-lock-file 'path:.#lib.rpiKernelSeries')"

write_output() {
  local name="$1"
  local value="$2"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$name" "$value" >> "$GITHUB_OUTPUT"
  fi
}

list_series() {
  jq -c '[.[].version]' <<< "$series_json"
}

if [[ "${1:-}" == "--list-series" ]]; then
  list_series
  exit 0
fi

version="${1:-}"
summary_file="${2:-kernel-update-summary.md}"

if [[ -z "$version" ]]; then
  echo "usage: $0 --list-series | <version> [summary-file]" >&2
  exit 1
fi

selected="$(jq -c --arg version "$version" '.[] | select(.version == $version)' <<< "$series_json")"

if [[ -z "$selected" ]]; then
  echo "unknown tracked kernel series: ${version}" >&2
  exit 1
fi

if [[ -z "${GITHUB_TOKEN:-}" && -z "${GH_TOKEN:-}" ]]; then
  echo "GITHUB_TOKEN or GH_TOKEN must be set" >&2
  exit 1
fi

if [[ -z "${GH_TOKEN:-}" ]]; then
  export GH_TOKEN="$GITHUB_TOKEN"
fi

branch="$(jq -r '.branch' <<< "$selected")"
input="$(jq -r '.input' <<< "$selected")"
status_total=0
status_state="none"
checks_total=0
checks_success=0
checks_bad=0

resolve_branch_sha() {
  gh api "/repos/${repo}/git/ref/heads/${branch}" --jq '.object.sha'
}

current_locked_rev() {
  jq -er --arg input "$input" '.nodes[$input].locked.rev' flake.lock
}

status_signal_is_good() {
  local sha="$1"
  local status_json

  status_json="$(gh api "/repos/${repo}/commits/${sha}/status")"
  status_total="$(jq -r '.total_count' <<< "$status_json")"
  status_state="$(jq -r '.state' <<< "$status_json")"

  if [[ "$status_total" == "0" ]]; then
    return 2
  fi

  [[ "$status_state" == "success" ]]
}

check_runs_signal_is_good() {
  local sha="$1"
  local checks_json
  local reported_total

  checks_json="$(
    gh api --paginate --slurp \
      -H "Accept: application/vnd.github+json" \
      "/repos/${repo}/commits/${sha}/check-runs?per_page=100"
  )"
  reported_total="$(jq -r '.[0].total_count // 0' <<< "$checks_json")"
  checks_total="$(jq -r '[.[].check_runs[]] | length' <<< "$checks_json")"
  checks_success="$(jq -r '[.[].check_runs[] | select(.status == "completed" and .conclusion == "success")] | length' <<< "$checks_json")"
  checks_bad="$(
    jq -r '
      [
        .[].check_runs[]
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

  if [[ "$checks_total" != "$reported_total" || "$checks_bad" != "0" ]]; then
    return 1
  fi

  if [[ "$checks_success" == "0" ]]; then
    return 2
  fi
}

upstream_commit_is_good() {
  local sha="$1"
  local saw_signal=0
  local failed_signal=0
  local status_result
  local checks_result

  if status_signal_is_good "$sha"; then
    status_result=0
  else
    status_result=$?
  fi

  if check_runs_signal_is_good "$sha"; then
    checks_result=0
  else
    checks_result=$?
  fi

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
}

sha="$(resolve_branch_sha)"
old_rev="$(current_locked_rev)"
short_rev="${sha:0:12}"

write_output "version" "$version"
write_output "upstream_branch" "$branch"
write_output "input" "$input"
write_output "old_rev" "$old_rev"
write_output "new_rev" "$sha"
write_output "short_rev" "$short_rev"

if upstream_commit_is_good "$sha"; then
  result=0
else
  result=$?
fi

case "$result" in
  0) ;;
  1) reason="upstream checks are not successful" ;;
  2) reason="no visible upstream checks or statuses" ;;
  *) reason="unexpected check result ${result}" ;;
esac

if [[ "$result" != "0" ]]; then
  cat > "$summary_file" <<EOF
## Raspberry Pi kernel ${version} update

Update skipped: ${reason}.

- Upstream branch: \`${branch}\`
- Candidate revision: \`${sha}\`
- Combined status: \`${status_state}\` (${status_total} contexts)
- Check runs: ${checks_total} total, ${checks_success} successful, ${checks_bad} unacceptable
EOF
  echo "Skipping ${version} (${branch}) at ${sha}: ${reason}"
  write_output "changed" "false"
  exit 0
fi

commit_json="$(gh api "/repos/${repo}/commits/${sha}")"
subject="$(jq -r '.commit.message | split("\n")[0]' <<< "$commit_json")"
commit_date="$(jq -r '.commit.committer.date' <<< "$commit_json")"
compare_url="https://github.com/${repo}/compare/${old_rev}...${sha}"

cat > "$summary_file" <<EOF
## Raspberry Pi kernel ${version} update

Update \`${version}\` from \`${old_rev}\` to \`${sha}\`.

### Upstream

- Repository: [\`${repo}\`](https://github.com/${repo})
- Branch: [\`${branch}\`](https://github.com/${repo}/tree/${branch})
- Compare: [\`${old_rev:0:12}...${short_rev}\`](${compare_url})
- Commit: ${subject} (\`${commit_date}\`)

### Upstream validation

- Combined status: \`${status_state}\` (${status_total} contexts)
- Check runs: ${checks_total} total, ${checks_success} successful, ${checks_bad} unacceptable
EOF

if [[ "$old_rev" == "$sha" ]]; then
  echo "Keeping ${version} (${branch}) at ${sha}: already locked"
  write_output "changed" "false"
  exit 0
fi

echo "Accepting ${version} (${branch}) at ${sha}"
nix flake lock --override-input "$input" "github:${repo}?rev=${sha}"

if git diff --quiet -- flake.lock; then
  write_output "changed" "false"
else
  write_output "changed" "true"
fi
