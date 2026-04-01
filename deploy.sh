#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

COMMIT_ID="${1:-}"
if [ -z "$COMMIT_ID" ]; then
  COMMIT_ID=$(git rev-parse HEAD 2>/dev/null) || \
    { echo "Error: no commit ID provided and not in a git repo"; exit 1; }
fi

echo ">>> Suspending ASG scaling processes..."
aws autoscaling suspend-processes \
  --auto-scaling-group-name "$ASG_NAME" \
  --scaling-processes AlarmNotification ScheduledActions \
  --region "$REGION"

echo ">>> Creating deployment (commit: $COMMIT_ID)..."

DEPLOYMENT_ID=$(aws deploy create-deployment \
  --application-name "$APP_NAME" \
  --deployment-group-name "$DG_NAME" \
  --github-location "repository=$GITHUB_REPO,commitId=$COMMIT_ID" \
  --ignore-application-stop-failures \
  --region "$REGION" \
  --query "deploymentId" --output text)

echo "    Deployment ID: $DEPLOYMENT_ID"
echo ""
echo ">>> Waiting for deployment to complete..."

if aws deploy wait deployment-successful \
  --deployment-id "$DEPLOYMENT_ID" \
  --region "$REGION"; then
  echo "=== Deployment Succeeded ==="

  echo ">>> Cleaning up stale ASGs..."
  aws autoscaling describe-auto-scaling-groups \
    --region "$REGION" \
    --query "AutoScalingGroups[?DesiredCapacity==\`0\` && contains(AutoScalingGroupName, '${APP_NAME}')].[AutoScalingGroupName]" \
    --output text | while read -r asg; do
    [ -z "$asg" ] && continue
    echo "    Deleting: $asg"
    aws autoscaling delete-auto-scaling-group \
      --auto-scaling-group-name "$asg" \
      --region "$REGION" 2>/dev/null || true
  done
else
  echo "=== Deployment Failed ==="
  aws deploy get-deployment --deployment-id "$DEPLOYMENT_ID" --region "$REGION" \
    --query "deploymentInfo.{Status:status,ErrorInfo:errorInformation}"
  EXITCODE=1
fi

echo ">>> Resuming ASG scaling processes..."
aws autoscaling resume-processes \
  --auto-scaling-group-name "$ASG_NAME" \
  --scaling-processes AlarmNotification ScheduledActions \
  --region "$REGION"

exit "${EXITCODE:-0}"
