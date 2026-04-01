#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

COMMIT_ID="${1:-}"
if [ -z "$COMMIT_ID" ]; then
  COMMIT_ID=$(git rev-parse HEAD 2>/dev/null) || \
    { echo "Error: no commit ID provided and not in a git repo"; exit 1; }
fi

# Resolve the current active ASG (may have been renamed by a previous Blue/Green deployment)
CURRENT_ASG=$(aws deploy get-deployment-group \
  --application-name "$APP_NAME" --deployment-group-name "$DG_NAME" \
  --region "$REGION" \
  --query "deploymentGroupInfo.autoScalingGroups[0].name" --output text)

echo ">>> Current ASG: $CURRENT_ASG"

echo ">>> Suspending ASG scaling processes..."
aws autoscaling suspend-processes \
  --auto-scaling-group-name "$CURRENT_ASG" \
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

  # Find the new green ASG
  NEW_ASG=$(aws deploy get-deployment-group \
    --application-name "$APP_NAME" --deployment-group-name "$DG_NAME" \
    --region "$REGION" \
    --query "deploymentGroupInfo.autoScalingGroups[0].name" --output text)

  echo ">>> New ASG: $NEW_ASG"

  # Re-attach scaling policies, alarms, and metrics to the new ASG
  if [ "$NEW_ASG" != "$CURRENT_ASG" ]; then
    echo ">>> Migrating scaling policies and alarms to new ASG..."

    aws autoscaling enable-metrics-collection \
      --auto-scaling-group-name "$NEW_ASG" \
      --granularity "1Minute" \
      --region "$REGION"

    SCALE_UP_ARN=$(aws autoscaling put-scaling-policy \
      --auto-scaling-group-name "$NEW_ASG" \
      --policy-name "${APP_NAME}-scale-up" \
      --policy-type StepScaling \
      --adjustment-type ChangeInCapacity \
      --step-adjustments MetricIntervalLowerBound=0,ScalingAdjustment=1 \
      --region "$REGION" --query "PolicyARN" --output text)

    SCALE_DOWN_ARN=$(aws autoscaling put-scaling-policy \
      --auto-scaling-group-name "$NEW_ASG" \
      --policy-name "${APP_NAME}-scale-down" \
      --policy-type StepScaling \
      --adjustment-type ChangeInCapacity \
      --step-adjustments MetricIntervalUpperBound=0,ScalingAdjustment=-1 \
      --region "$REGION" --query "PolicyARN" --output text)

    aws cloudwatch put-metric-alarm \
      --alarm-name "${APP_NAME}-cpu-high" \
      --metric-name CPUUtilization --namespace AWS/EC2 \
      --statistic Average --period 60 --evaluation-periods 2 \
      --threshold 80 --comparison-operator GreaterThanThreshold \
      --dimensions "Name=AutoScalingGroupName,Value=$NEW_ASG" \
      --alarm-actions "$SCALE_UP_ARN" \
      --region "$REGION" >/dev/null

    aws cloudwatch put-metric-alarm \
      --alarm-name "${APP_NAME}-cpu-low" \
      --metric-name CPUUtilization --namespace AWS/EC2 \
      --statistic Average --period 60 --evaluation-periods 2 \
      --threshold 10 --comparison-operator LessThanThreshold \
      --dimensions "Name=AutoScalingGroupName,Value=$NEW_ASG" \
      --alarm-actions "$SCALE_DOWN_ARN" \
      --region "$REGION" >/dev/null
  fi

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
  NEW_ASG="$CURRENT_ASG"
  EXITCODE=1
fi

echo ">>> Resuming ASG scaling processes..."
aws autoscaling resume-processes \
  --auto-scaling-group-name "$NEW_ASG" \
  --scaling-processes AlarmNotification ScheduledActions \
  --region "$REGION"

exit "${EXITCODE:-0}"
