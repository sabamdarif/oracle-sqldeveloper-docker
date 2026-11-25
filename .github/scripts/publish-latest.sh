#!/usr/bin/env bash
set -euo pipefail

: "${GH_REPO:?}" "${GITHUB_SHA:?}" "${SQLDEVELOPER_VERSION:?}" "${RUNNER_TEMP:?}" "${ARCHIVE_NAME:?}"
archive="$RUNNER_TEMP/$ARCHIVE_NAME"
notes="$RUNNER_TEMP/release-notes.md"
test -s "$archive"
test -s "$notes"
title="Latest — SQL Developer $SQLDEVELOPER_VERSION"

release_id=$(gh api "repos/$GH_REPO/releases" --paginate \
    --jq '.[] | select(.tag_name == "latest") | .id')

git tag --force latest "$GITHUB_SHA"
git push --force origin refs/tags/latest

if [[ -z "$release_id" ]]; then
    gh release create latest "$archive" --verify-tag \
        --title "$title" --notes-file "$notes" --latest
else
    gh release upload latest "$archive" --clobber
    old_assets=$(gh api "repos/$GH_REPO/releases/$release_id/assets" --paginate \
        --jq ".[] | select(.name != \"$ARCHIVE_NAME\") | .id")
    while IFS= read -r asset_id; do
        [[ -n "$asset_id" ]] || continue
        gh api --method DELETE "repos/$GH_REPO/releases/assets/$asset_id"
    done <<<"$old_assets"
    gh release edit latest --title "$title" --notes-file "$notes" \
        --draft=false --prerelease=false --latest
fi

printf 'Published SQL Developer %s: https://github.com/%s/releases/tag/latest\n' \
    "$SQLDEVELOPER_VERSION" "$GH_REPO" >>"$GITHUB_STEP_SUMMARY"
