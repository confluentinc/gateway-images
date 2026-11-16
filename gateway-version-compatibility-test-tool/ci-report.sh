#!/bin/bash
# CI report for one suite of version-compatibility.sh: merge the results its jobs pushed as
# workflow artifacts (ci-push-results.sh), parse them, upload to S3 and post to Slack. Exits 1
# on test failures, on combinations that ended without an outcome (a job's run died part way,
# or produced no results at all) and on failed S3 uploads; setup failures only warn (they're
# infrastructure).
#
#   ./ci-report.sh <suite: standard|tbm> <title> <s3 folder>
#
# Env: RESULTS_TIMESTAMP, S3_BUCKET, GW_VERSION, SLACK_WEBHOOK_URL (optional), and Semaphore's.
set -uo pipefail

SUITE="$1" TITLE="$2" S3_FOLDER="$3"
RESULTS_S3_PATH="s3://${S3_BUCKET}/${S3_FOLDER}/${GW_VERSION}/${RESULTS_TIMESTAMP}"
PULLED="ci-artifacts/${SUITE}"
MERGED="compatibility-results/${SUITE}-${RESULTS_TIMESTAMP}"

# Each job's results sit under ci-artifacts/<suite>/<job index>/; the per-combination files are
# uniquely named, so they merge into one directory (the jobs' own reports are regenerated). Each
# job also lists the combinations it set out to test (expected_combinations.txt).
mkdir -p "$MERGED"
EXPECTED=()
MISSING=()
if artifact pull workflow "ci-results/${SUITE}" -d "$PULLED"; then
    for d in "$PULLED"/*/; do
        cp -R "$d"*_metrics.txt "$d"*_status.txt "$d"*_junit "$d"*_html "$MERGED"/ 2>/dev/null || true
        if [[ -f "${d}expected_combinations.txt" ]]; then
            while IFS= read -r id; do
                [[ -n "$id" ]] && EXPECTED+=("$id")
            done < "${d}expected_combinations.txt"
        else
            MISSING+=("job $(basename "$d"): no results")
        fi
    done
fi
for id in "${EXPECTED[@]}"; do
    if [[ ! -f "$MERGED/${id}_metrics.txt" && ! -f "$MERGED/${id}_status.txt" ]]; then
        MISSING+=("$id")
    fi
done
MISSING_TESTS=${#MISSING[@]}

PASSED_TESTS=$(find "$MERGED" -maxdepth 1 -name "*_metrics.txt" | wc -l | tr -d ' ')
FAILED_TESTS=0
SETUP_FAILED_TESTS=0
while IFS= read -r sf; do
    if grep -q "^SETUP_FAILED:" "$sf" 2>/dev/null; then
        SETUP_FAILED_TESTS=$((SETUP_FAILED_TESTS + 1))
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
done < <(find "$MERGED" -maxdepth 1 -name "*_status.txt")
TOTAL_TESTS=$((PASSED_TESTS + FAILED_TESTS + SETUP_FAILED_TESTS))
echo "Raw Counts - Total: ${TOTAL_TESTS}, Passed: ${PASSED_TESTS}, Failed: ${FAILED_TESTS}, Setup Failed: ${SETUP_FAILED_TESTS}, No Outcome: ${MISSING_TESTS}"
if [[ "$MISSING_TESTS" -gt 0 ]]; then
    printf '❌ No outcome: %s\n' "${MISSING[@]}"
fi

UPLOAD_FAILED=0
if [[ "$TOTAL_TESTS" -gt 0 ]]; then
    ./version-compatibility.sh --parse "$MERGED" || echo "⚠️ Report generation failed"
    SUCCESS_RATE=$(( (PASSED_TESTS * 100) / TOTAL_TESTS ))
    cat > test_summary.txt << EOF
${TITLE} Results
==========================================
Gateway Version: ${GW_VERSION}
Timestamp: ${RESULTS_TIMESTAMP}
Total Test Combinations: ${TOTAL_TESTS}
Passed: ${PASSED_TESTS}
Failed: ${FAILED_TESTS}
Setup Failed: ${SETUP_FAILED_TESTS}
No Outcome: ${MISSING_TESTS}
Success Rate: ${SUCCESS_RATE}%
Results Location: ${RESULTS_S3_PATH}

EOF
    if [[ "$MISSING_TESTS" -gt 0 ]]; then
        printf 'No outcome (run ended early):\n' >> test_summary.txt
        printf '  %s\n' "${MISSING[@]}" >> test_summary.txt
        echo >> test_summary.txt
    fi
    cat "$MERGED/reports/compatibility_summary.txt" >> test_summary.txt 2>/dev/null || true

    aws s3 cp "$MERGED/" "${RESULTS_S3_PATH}/" --recursive || UPLOAD_FAILED=1
    aws s3 cp test_summary.txt "s3://${S3_BUCKET}/${S3_FOLDER}/${GW_VERSION}/latest_summary.txt" || UPLOAD_FAILED=1
    echo "${RESULTS_TIMESTAMP}" | aws s3 cp - "s3://${S3_BUCKET}/${S3_FOLDER}/${GW_VERSION}/test_runs/${RESULTS_TIMESTAMP}.marker" || UPLOAD_FAILED=1
    if [[ "$UPLOAD_FAILED" -eq 0 ]]; then
        echo "✅ Results uploaded to ${RESULTS_S3_PATH}"
    fi
else
    echo "Test execution may have failed completely: no results" > test_summary.txt
    if aws s3 cp test_summary.txt "s3://${S3_BUCKET}/${S3_FOLDER}/${GW_VERSION}/failed_run_${RESULTS_TIMESTAMP}.txt"; then
        echo "❌ No results: failure marker uploaded"
    else
        UPLOAD_FAILED=1
    fi
fi
if [[ "$UPLOAD_FAILED" -ne 0 ]]; then
    echo "❌ S3 upload failed"
    printf '\n❌ S3 upload failed: results may be missing from %s\n' "$RESULTS_S3_PATH" >> test_summary.txt
fi

if [[ "$TOTAL_TESTS" -eq 0 || "$FAILED_TESTS" -gt 0 || "$MISSING_TESTS" -gt 0 ]]; then
    COLOR="danger" STATUS="❌ TEST FAILURES"
    [[ "$TOTAL_TESTS" -gt 0 ]] || STATUS="❌ FAILED"
elif [[ "$UPLOAD_FAILED" -ne 0 ]]; then
    COLOR="danger" STATUS="❌ S3 UPLOAD FAILED"
elif [[ "$SETUP_FAILED_TESTS" -gt 0 ]]; then
    COLOR="warning" STATUS="⚠️ SETUP FAILURES"
else
    COLOR="good" STATUS="✅ PASSED"
fi

if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
    jq -n --arg color "$COLOR" --arg title "${TITLE} ${STATUS}" \
        --arg text "Branch: ${SEMAPHORE_GIT_BRANCH:-}
Commit: ${SEMAPHORE_GIT_SHA:0:7}

\`\`\`
$(cat test_summary.txt)
\`\`\`" \
        --arg s3 "$RESULTS_S3_PATH" \
        --arg wf "<https://semaphore.ci.confluent.io/workflows/${SEMAPHORE_WORKFLOW_ID:-}|View Workflow>" '{
          username: "Semaphore CI", icon_emoji: ":gear:",
          attachments: [{color: $color, title: $title, text: $text, fields: [
            {title: "Results Location", value: $s3, short: false},
            {title: "Workflow", value: $wf, short: true}]}]}' \
      | curl -sS --connect-timeout 10 --max-time 30 -X POST -H 'Content-type: application/json' \
          --data @- "$SLACK_WEBHOOK_URL" || echo "⚠️ Slack notification failed"
    echo
else
    echo "⚠️ SLACK_WEBHOOK_URL not set, skipping Slack notification"
fi

if [[ "$TOTAL_TESTS" -eq 0 ]]; then
    echo "❌ ${TITLE}: no results"
    exit 1
elif [[ "$FAILED_TESTS" -gt 0 || "$MISSING_TESTS" -gt 0 ]]; then
    echo "❌ ${TITLE}: ${FAILED_TESTS} test failures, ${MISSING_TESTS} without an outcome"
    exit 1
elif [[ "$UPLOAD_FAILED" -ne 0 ]]; then
    echo "❌ ${TITLE}: S3 upload failed"
    exit 1
elif [[ "$SETUP_FAILED_TESTS" -gt 0 ]]; then
    echo "⚠️ ${TITLE}: ${SETUP_FAILED_TESTS} setup failures (infrastructure; not failing the pipeline)"
fi
echo "✅ ${TITLE} completed"
