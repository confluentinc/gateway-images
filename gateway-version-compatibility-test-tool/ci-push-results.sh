#!/bin/bash
# Push this job's newest version-compatibility.sh results as a workflow artifact, for
# ci-report.sh to merge: ci-results/<suite>/<job index>/.
#
#   ./ci-push-results.sh <suite: standard|tbm>
set -uo pipefail

latest="$(ls -t compatibility-results/ 2>/dev/null | head -n1)"
if [ -z "$latest" ]; then
    echo "⚠️ No results to push"
    exit 0
fi
artifact push workflow "compatibility-results/${latest}" \
    --destination "ci-results/${1}/${SEMAPHORE_JOB_INDEX:-1}" --force
