#!/usr/bin/env bash
# Exercise release replacement without building an image or contacting GitHub.
# Run: bash test-publish-latest.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/artifacts"

cat >"$scratch/bin/git" <<'STUB'
#!/usr/bin/env bash
printf 'git' >> "$STUB_CALLS"
printf ' <%s>' "$@" >> "$STUB_CALLS"
printf '\n' >> "$STUB_CALLS"
if [[ "${STUB_SCENARIO:-}" == tag-failure && "$1" == push ]]; then
    exit 1
fi
STUB

cat >"$scratch/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'gh' >> "$STUB_CALLS"
printf ' <%s>' "$@" >> "$STUB_CALLS"
printf '\n' >> "$STUB_CALLS"
case "$1 $2" in
    'api repos/example/repo/releases')
        [[ "$STUB_SCENARIO" != api-failure ]] || exit 1
        if [[ "$STUB_SCENARIO" != first-release ]]; then
            echo 42
        fi
        ;;
    'api repos/example/repo/releases/42/assets')
        # Ensure the currently uploaded archive is excluded from deletion.
        [[ "$5" == ".[] | select(.name != \"$ARCHIVE_NAME\") | .id" ]] || exit 90
        if [[ "$STUB_SCENARIO" != same-name ]]; then
            printf '101\n102\n'
        fi
        ;;
    'api --method')
        [[ "$3" == DELETE && "$4" == repos/example/repo/releases/assets/* ]] || exit 90
        [[ "$STUB_SCENARIO" != delete-failure ]] || exit 1
        ;;
    'release upload')
        [[ "$3" == latest && "$4" == "$RUNNER_TEMP/$ARCHIVE_NAME" && "$5" == --clobber ]] || exit 90
        [[ "$STUB_SCENARIO" != upload-failure ]] || exit 1
        ;;
    'release create'|'release edit')
        [[ "$3" == latest ]] || exit 90
        ;;
    *) exit 90 ;;
esac
STUB
chmod +x "$scratch/bin/git" "$scratch/bin/gh"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

run() {
    local scenario="$1" extension="${2:-xz}"
    export PATH="$scratch/bin:$PATH"
    export GH_REPO=example/repo GITHUB_SHA=0123456789abcdef
    export SQLDEVELOPER_VERSION=26.2.0.186.2220
    export RUNNER_TEMP="$scratch/artifacts"
    export ARCHIVE_NAME="oracle-sqldeveloper-x86_64.tar.$extension"
    export GITHUB_STEP_SUMMARY="$scratch/summary"
    export STUB_SCENARIO="$scenario" STUB_CALLS="$scratch/calls"
    : >"$STUB_CALLS"
    : >"$GITHUB_STEP_SUMMARY"
    printf 'archive\n' >"$RUNNER_TEMP/$ARCHIVE_NAME"
    printf 'SQL Developer %s\n' "$SQLDEVELOPER_VERSION" >"$RUNNER_TEMP/release-notes.md"
    if [[ "$scenario" == missing-archive ]]; then
        : >"$RUNNER_TEMP/$ARCHIVE_NAME"
    fi
    status=0
    bash "$here/.github/scripts/publish-latest.sh" || status=$?
}

run first-release
[[ "$status" == 0 ]] || fail 'first publish must succeed'
grep -Fq 'gh <release> <create> <latest>' "$STUB_CALLS" || fail 'create a missing release'
grep -Fq '<--verify-tag>' "$STUB_CALLS" || fail 'creation must use the already updated tag'
grep -Fq '<--title> <Latest — SQL Developer 26.2.0.186.2220>' "$STUB_CALLS" || fail 'title must identify the version'
grep -Fq "<--notes-file> <$RUNNER_TEMP/release-notes.md> <--latest>" "$STUB_CALLS" || fail 'creation must use the new body and mark latest'
if grep -Eq '<upload>|<edit>|<DELETE>' "$STUB_CALLS"; then
    fail 'a new release must not use the replacement path'
fi

for extension in xz gz; do
    run existing "$extension"
    [[ "$status" == 0 ]] || fail "replacement must succeed for $extension"
    grep -Fxq 'git <tag> <--force> <latest> <0123456789abcdef>' "$STUB_CALLS" || fail 'move only latest to the built commit'
    grep -Fxq 'git <push> <--force> <origin> <refs/tags/latest>' "$STUB_CALLS" || fail 'push only the latest tag'
    grep -Fq 'gh <release> <upload> <latest>' "$STUB_CALLS" || fail 'upload the new archive'
    grep -Fq '<--clobber>' "$STUB_CALLS" || fail 'replace an existing same-name asset'
    [[ "$(grep -c '<DELETE>' "$STUB_CALLS")" == 2 ]] || fail 'remove every obsolete asset'
    grep -Fq 'gh <release> <edit> <latest>' "$STUB_CALLS" || fail 'update the existing release'
    grep -Fq "<--notes-file> <$RUNNER_TEMP/release-notes.md>" "$STUB_CALLS" || fail 'replace the entire old body'
    grep -Fq '<--draft=false> <--prerelease=false> <--latest>' "$STUB_CALLS" || fail 'publish as the latest stable release'
    order=$(grep -E '<upload>|<DELETE>|<edit>' "$STUB_CALLS" | sed -E 's/.*<(upload|DELETE|edit)>.*/\1/' | tr '\n' ' ')
    [[ "$order" == 'upload DELETE DELETE edit ' ]] || fail 'upload before cleanup, then replace the body'
    grep -Fq 'Published SQL Developer 26.2.0.186.2220:' "$GITHUB_STEP_SUMMARY" || fail 'summarize the published version'
done

run same-name
[[ "$status" == 0 ]] || fail 'same-name replacement must succeed'
if grep -Fq '<DELETE>' "$STUB_CALLS"; then
    fail 'do not delete the new archive when there are no obsolete assets'
fi

for scenario in api-failure tag-failure upload-failure delete-failure missing-archive; do
    run "$scenario"
    [[ "$status" != 0 ]] || fail "$scenario must fail the publish"
    [[ ! -s "$GITHUB_STEP_SUMMARY" ]] || fail "$scenario must not report success"
    if grep -Eq '<create>|<edit>' "$STUB_CALLS"; then
        fail "$scenario must not publish a new release body"
    fi
    if [[ "$scenario" != delete-failure ]] && grep -Fq '<DELETE>' "$STUB_CALLS"; then
        fail "$scenario must not delete differently named old assets"
    fi
    if [[ "$scenario" == api-failure || "$scenario" == missing-archive ]] && grep -Fq 'git ' "$STUB_CALLS"; then
        fail "$scenario must not move the tag"
    fi
done

echo ok
