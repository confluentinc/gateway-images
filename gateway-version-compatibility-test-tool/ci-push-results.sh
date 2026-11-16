#!/bin/bash
# Push this job's newest version-compatibility.sh results as a workflow artifact, for
# ci-report.sh to merge: ci-results/<suite>/<job index>/. A job with no results still pushes an
# (empty) directory, so ci-report.sh reports it rather than missing it.
#
#   ./ci-push-results.sh <suite: standard|tbm>
set -uo pipefail

latest="$(ls -t compatibility-results/ 2>/dev/null | head -n1)"
if [[ -n "$latest" ]]; then
    src="compatibility-results/${latest}"
else
    echo "⚠️ No results to push"
    src="$(mktemp -d)"
    touch "$src/NO_RESULTS"
fi
artifact push workflow "$src" --destination "ci-results/${1}/${SEMAPHORE_JOB_INDEX:-1}" --force
