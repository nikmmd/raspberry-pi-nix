#!/usr/bin/env bash
set -euo pipefail

: "${UPDATE_KIND:?}" "${VERSION:?}" "${TARGET_REV:?}" "${SHORT_REV:?}"
: "${BASE_BRANCH:?}" "${BRANCH_NAME:?}" "${REPOSITORY_OWNER:?}"
SUMMARY_FILE="${SUMMARY_FILE:-kernel-update-summary.md}"
case "$UPDATE_KIND" in
  source)
    allowed_paths=(flake.lock)
    commit_title="chore(kernel): update Raspberry Pi ${VERSION#v} kernel"
    commit_body="Update the checked-good ${VERSION} kernel lock to ${TARGET_REV}."
    ;;
  binary)
    allowed_paths=(flake.nix flake.lock)
    commit_title="chore(kernel): update Raspberry Pi ${VERSION#v} binary kernel"
    commit_body="Update the ${VERSION} firmware binary input to ${TARGET_REV}."
    ;;
  *) echo "Unknown kernel update kind: $UPDATE_KIND" >&2; exit 1 ;;
esac

check_paths() {
  local path allowed found
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    found=false
    for allowed in "${allowed_paths[@]}"; do
      if [[ "$path" == "$allowed" ]]; then found=true; break; fi
    done
    if [[ "$found" != true ]]; then
      echo "Refusing to publish $BRANCH_NAME with unexpected changed path: $path" >&2
      exit 1
    fi
  done
}

changed_paths="$(git diff --name-only HEAD)"
check_paths <<< "$changed_paths"
git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
gh auth setup-git

git switch -C "$BRANCH_NAME"
git add -- "${allowed_paths[@]}"
git commit -m "$commit_title" -m "$commit_body"

remote_ref="refs/heads/$BRANCH_NAME"
remote_sha="$(git ls-remote --heads origin "$remote_ref" | cut -f1)"
if [[ -n "$remote_sha" ]]; then
  git fetch origin "$remote_ref"
  if [[ "$(git show -s --format='%ae' "$remote_sha")" != '41898282+github-actions[bot]@users.noreply.github.com' ]]; then
    echo "Refusing to overwrite non-bot branch $BRANCH_NAME" >&2
    exit 1
  fi
  changed_paths="$(git diff --name-only "origin/$BASE_BRANCH...$remote_sha")"
  check_paths <<< "$changed_paths"
  if ! git diff --quiet "$remote_sha" HEAD; then
    git push --force-with-lease="$remote_ref:$remote_sha" origin "HEAD:$remote_ref"
  fi
else
  git push --force-with-lease="$remote_ref:" origin "HEAD:$remote_ref"
fi

pr_number="$(
  gh api --method GET "/repos/$GITHUB_REPOSITORY/pulls" \
    -f state=open -f base="$BASE_BRANCH" \
    -f head="$REPOSITORY_OWNER:$BRANCH_NAME" --jq '.[0].number // empty'
)"
display_version="${VERSION#v}"
display_version="${display_version/_/.}"
if [[ "$UPDATE_KIND" == binary ]]; then
  title="chore(kernel): update Raspberry Pi ${display_version} binary to ${SHORT_REV}"
else
  title="chore(kernel): update Raspberry Pi ${display_version} to ${SHORT_REV}"
fi
if [[ -n "$pr_number" ]]; then
  gh pr edit "$pr_number" --title "$title" --body-file "$SUMMARY_FILE"
else
  gh pr create --base "$BASE_BRANCH" --head "$BRANCH_NAME" \
    --title "$title" --body-file "$SUMMARY_FILE"
fi
