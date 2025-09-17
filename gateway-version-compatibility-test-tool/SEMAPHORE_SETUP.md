# Semaphore CI Integration Setup

This document explains how to set up the Semaphore CI integration for automated version compatibility testing.

## Overview

The Semaphore integration automatically runs version compatibility tests on a scheduled basis (every Monday at 21:00 UTC). The results are published to an S3 bucket and notifications are sent via Slack.

## Architecture

```
Scheduled (Monday 21:00 UTC) → version-compatibility-tests → S3 + Slack
```

## Files Added/Modified

1. **`.semaphore/version-compatibility-tests.yml`** - New scheduled pipeline for running compatibility tests
2. **`gateway-version-compatibility-test-tool/SEMAPHORE_SETUP.md`** - This setup guide

## Required Configuration

### 1. AWS S3 Access

The pipeline uploads test results to the `gateway-results` S3 bucket. Ensure the Semaphore project has AWS credentials configured with the following permissions:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:PutObjectAcl"
      ],
      "Resource": [
        "arn:aws:s3:::gateway-results/version-testing-results/*"
      ]
    }
  ]
}
```

**To configure AWS credentials in Semaphore:**
1. Go to your Semaphore project settings
2. Navigate to **Configuration** → **Environment Variables**
3. Add the following secrets:
   - `AWS_ACCESS_KEY_ID`
   - `AWS_SECRET_ACCESS_KEY`
   - `AWS_DEFAULT_REGION` (e.g., `us-west-2`)

### 2. Slack Notifications Setup

#### Step 1: Create Slack Incoming Webhook

1. Go to your Slack workspace
2. Navigate to **Apps** → **Manage** → **Custom Integrations** → **Incoming WebHooks**
3. Click **Add to Slack**
4. Select the channel for notifications (e.g., `#gateway-ci` or `#alerts`)
5. Copy the generated Webhook URL

#### Step 2: Configure Semaphore Environment Variable

1. In your Semaphore project settings
2. Go to **Configuration** → **Environment Variables**
3. Add a new secret:
   - **Name**: `SLACK_WEBHOOK_URL`
   - **Value**: Your copied webhook URL (e.g., `https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX`)

## Pipeline Behavior

### Trigger Conditions
- Automatically triggered every Monday at 21:00 UTC
- Runs on the `master` branch only
- Uses the latest gateway images available

### Test Execution
1. **Setup Phase**: 
   - Installs Python dependencies
   - Sets up Docker environment
   
2. **Testing Phase**:
   - Runs all client/server version combinations (currently 7×7 = 49 tests)
   - Each test validates API compatibility through the gateway
   - Collects Prometheus metrics for analysis

3. **Results Phase**:
   - Generates detailed compatibility reports (CSV, JSON, TXT)
   - Uploads all results to S3 with timestamp
   - Creates summary for notifications

4. **Notification Phase**:
   - Sends Slack notification with test summary
   - Includes links to results and workflow

### S3 Upload Structure

Results are uploaded to:
```
s3://gateway-results/version-testing-results/
├── 1.0.0/                          # Gateway version
│   ├── 2025-07-23-18-19-53/        # Timestamped test run (YYYY-MM-DD-HH-MM-SS)
│   │   ├── compatibility_summary.txt     # Human-readable summary
│   │   ├── detailed_api_usage.csv       # Detailed API data
│   │   ├── compatibility_report.json    # Machine-readable results
│   │   ├── api_key_reference.txt        # API mappings
│   │   └── java*_server*_metrics.txt    # Raw metrics per test
│   └── latest_summary.txt          # Always points to latest summary for this version
├── 1.1.0/                          # Another gateway version
│   ├── 2025-07-24-09-30-15/
│   └── latest_summary.txt
└── ...
```

### Slack Notification Format

Notifications include:
- ✅/❌ Status indicator
- Test summary (total/passed/failed)
- Success rate percentage
- Links to S3 results and Semaphore workflow
- Branch and commit information

## Testing the Setup

### Manual Pipeline Trigger

You can manually test the pipeline by:

1. **Via Semaphore UI**:
   - Go to your project in Semaphore
   - Find the `version-compatibility-tests` pipeline
   - Click "Run pipeline" and select your branch

2. **Via Semaphore CLI**:
   ```bash
   sem create workflow version-compatibility-tests.yml --project-name your-project --branch master
   ```

### Validate Configuration

1. **Check AWS Access**:
   ```bash
   # In a Semaphore job, test S3 access:
   aws s3 ls s3://gateway-results/version-testing-results/
   # Should show gateway version directories like 1.0.0/, 1.1.0/, etc.
   ```

2. **Test Slack Webhook**:
   ```bash
   # Test webhook from command line:
   curl -X POST -H 'Content-type: application/json' \
     --data '{"text":"Test message from Semaphore setup"}' \
     $SLACK_WEBHOOK_URL
   ```

## Monitoring and Maintenance

### Expected Execution Time
- **Full test suite**: 30-45 minutes (49 test combinations)
- **Single test**: 1-2 minutes per combination

### Resource Usage
- **Machine Type**: `s1-prod-ubuntu24-04-amd64-1`
- **Execution Limit**: 2 hours
- **Docker**: Required for test containers

### Common Issues

1. **Docker Compose Not Found**:
   - Pipeline automatically installs Docker Compose v2.20.0
   - If issues persist, check Docker daemon status

2. **S3 Upload Failures**:
   - Verify AWS credentials and permissions
   - Check bucket exists and region is correct

3. **Missing Slack Notifications**:
   - Verify `SLACK_WEBHOOK_URL` environment variable is set
   - Test webhook URL manually

4. **Test Failures**:
   - Check individual test logs in Semaphore
   - Review Docker container logs
   - Verify Kafka versions are available

## Customization

### Adding New Kafka Versions

Edit the version arrays in `version-compatibility.sh`:
```bash
CLIENTS=("7.4.0" "7.5.0" "7.6.0" "7.7.0" "7.8.0" "7.9.0" "8.0.0" "8.1.0")
SERVERS=("7.4.0" "7.5.0" "7.6.0" "7.7.0" "7.8.0" "7.9.0" "8.0.0" "8.1.0")
```

### Changing Test Schedule

To modify the test schedule, update the scheduler configuration in `version-compatibility-tests.yml`:
```yaml
scheduler:
  rules:
    - if: "branch = 'master'"
      when: "0 21 * * 1"  # Monday at 21:00 UTC
      # Examples of other schedules:
      # when: "0 9 * * 1-5"   # Weekdays at 9:00 AM UTC
      # when: "0 0 * * 0"     # Every Sunday at midnight UTC
      # when: "0 12 1 * *"    # First day of every month at noon UTC
```

**Cron Format**: `minute hour day month weekday`
- `0 21 * * 1` = 0 minutes, 21 hours (9 PM), any day of month, any month, Monday (1)

### Adjusting Notification Channels

Change the Slack channel by creating a new webhook for the desired channel and updating the `SLACK_WEBHOOK_URL` environment variable.

## Support

For issues with the compatibility testing pipeline:
1. Check Semaphore workflow logs
2. Review S3 bucket for partial results
3. Verify all environment variables are correctly set
4. Test individual components manually

For questions about the test framework itself, see the main [README.md](README.md) in the test tool directory.
