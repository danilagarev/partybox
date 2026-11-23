#!/usr/bin/env bash
set -euo pipefail

repository="repos/$GITHUB_REPOSITORY"
select_run='
  select(.head_repository.full_name == $repo and .head_branch == "main" and
    .event == "push" and .status == "completed" and .conclusion == "success")
'

case "$GITHUB_EVENT_NAME" in
  workflow_run)
    run=$(jq -ce --arg repo "$GITHUB_REPOSITORY" '
      select(.action == "completed" and .workflow.path == ".github/workflows/ci.yml") |
      .workflow_run | '"$select_run" "$GITHUB_EVENT_PATH")
    sha=$(jq -er .head_sha <<< "$run")
    main=$(gh api "$repository/git/ref/heads/main" --jq .object.sha)
    if [[ $sha != "$main" ]]; then
      echo "Checks commit $sha has been superseded by $main. Skipping automatic deployment."
      exit 0
    fi
    ;;
  workflow_dispatch)
    [[ $GITHUB_REF == refs/heads/main ]]
    sha=${INPUT_SHA:-$GITHUB_SHA}
    [[ $sha =~ ^[a-f0-9]{40}$ ]] || { echo 'A full lowercase commit SHA is required.' >&2; exit 1; }
    runs=$(gh api --method GET "$repository/actions/workflows/ci.yml/runs" \
      -f head_sha="$sha" -f branch=main -f event=push -f status=success -f per_page=100)
    if ! run=$(jq -ce --arg repo "$GITHUB_REPOSITORY" --arg sha "$sha" '
      [.workflow_runs[] | '"$select_run"' | select(.head_sha == $sha)][0] // empty
    ' <<< "$runs"); then
      echo 'This SHA needs a successful Checks push on main.' >&2
      exit 1
    fi
    ;;
  *) exit 1 ;;
esac

run_id=$(jq -er .id <<< "$run")
attempt=$(jq -er .run_attempt <<< "$run")
[[ $sha =~ ^[a-f0-9]{40}$ && $run_id =~ ^[1-9][0-9]*$ && $attempt =~ ^[1-9][0-9]*$ ]]
artifact="partybox-release-web-$sha-$attempt"
if [[ $GITHUB_EVENT_NAME == workflow_dispatch ]]; then
  # Successful runs before attempt-specific release artifacts used this older name.
  found=$(gh api --method GET "$repository/actions/runs/$run_id/artifacts" \
    -f name="$artifact" --jq '.artifacts[] | select(.expired == false) | .name')
  [[ $found == "$artifact" ]] || artifact="partybox-web-$sha"
fi

{
  printf 'sha=%s\n' "$sha"
  printf 'run_id=%s\n' "$run_id"
  printf 'artifact=%s\n' "$artifact"
} >> "$GITHUB_OUTPUT"
