#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

AWS_PARTITION=$(aws sts get-caller-identity \
  --query "Arn" --output text --region "$REGION" | cut -d: -f2)
VPC_ID="${VPC_ID:-$(aws ec2 describe-vpcs \
  --filters Name=is-default,Values=true \
  --query "Vpcs[0].VpcId" --output text --region "$REGION")}"

# ============================================================
# 1. CodeDeploy
# ============================================================

echo ">>> Deleting CodeDeploy..."

aws deploy delete-deployment-group \
  --application-name "$APP_NAME" --deployment-group-name "$DG_NAME" \
  --region "$REGION" 2>/dev/null || true
aws deploy delete-application \
  --application-name "$APP_NAME" --region "$REGION" 2>/dev/null || true

# ============================================================
# 2. Scaling Policies + Alarms
# ============================================================

echo ">>> Deleting scaling policies and alarms..."

aws cloudwatch delete-alarms \
  --alarm-names "${APP_NAME}-cpu-high" "${APP_NAME}-cpu-low" \
  --region "$REGION" 2>/dev/null || true
aws autoscaling delete-policy \
  --auto-scaling-group-name "$ASG_NAME" --policy-name "${APP_NAME}-scale-up" \
  --region "$REGION" 2>/dev/null || true
aws autoscaling delete-policy \
  --auto-scaling-group-name "$ASG_NAME" --policy-name "${APP_NAME}-scale-down" \
  --region "$REGION" 2>/dev/null || true

# ============================================================
# 3. ASG + Launch Template
# ============================================================

echo ">>> Deleting ASGs..."

aws autoscaling describe-auto-scaling-groups \
  --region "$REGION" \
  --query "AutoScalingGroups[?contains(AutoScalingGroupName, '${APP_NAME}')].[AutoScalingGroupName]" \
  --output text | tr '\t' '\n' | while read -r asg; do
  [ -z "$asg" ] && continue
  echo "    Deleting ASG: $asg"
  aws autoscaling delete-auto-scaling-group \
    --auto-scaling-group-name "$asg" --force-delete \
    --region "$REGION" 2>/dev/null || true
done

echo ">>> Deleting launch template..."

aws ec2 delete-launch-template \
  --launch-template-name "$LT_NAME" --region "$REGION" 2>/dev/null || true

# ============================================================
# 4. ALB + Target Group
# ============================================================

echo ">>> Deleting ALB resources..."

ALB_ARN=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" \
  --query "LoadBalancers[0].LoadBalancerArn" --output text \
  --region "$REGION" 2>/dev/null) || true

if [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
  LISTENER_ARNS=$(aws elbv2 describe-listeners \
    --load-balancer-arn "$ALB_ARN" \
    --query "Listeners[*].ListenerArn" --output text \
    --region "$REGION" 2>/dev/null) || true

  for arn in $LISTENER_ARNS; do
    aws elbv2 delete-listener --listener-arn "$arn" \
      --region "$REGION" 2>/dev/null || true
  done

  aws elbv2 delete-load-balancer \
    --load-balancer-arn "$ALB_ARN" --region "$REGION" 2>/dev/null || true

  echo "    Waiting for ALB deletion..."
  sleep 30
fi

TG_ARN=$(aws elbv2 describe-target-groups --names "$TG_NAME" \
  --query "TargetGroups[0].TargetGroupArn" --output text \
  --region "$REGION" 2>/dev/null) || true

if [ -n "$TG_ARN" ] && [ "$TG_ARN" != "None" ]; then
  aws elbv2 delete-target-group \
    --target-group-arn "$TG_ARN" --region "$REGION" 2>/dev/null || true
fi

# ============================================================
# 5. Security Groups
# ============================================================

echo ">>> Deleting security groups..."

EC2_SG=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values="$EC2_SG_NAME" Name=vpc-id,Values="$VPC_ID" \
  --query "SecurityGroups[0].GroupId" --output text \
  --region "$REGION" 2>/dev/null) || true

ALB_SG=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values="$ALB_SG_NAME" Name=vpc-id,Values="$VPC_ID" \
  --query "SecurityGroups[0].GroupId" --output text \
  --region "$REGION" 2>/dev/null) || true

[ -n "$EC2_SG" ] && [ "$EC2_SG" != "None" ] && \
  aws ec2 delete-security-group --group-id "$EC2_SG" --region "$REGION" 2>/dev/null || true
[ -n "$ALB_SG" ] && [ "$ALB_SG" != "None" ] && \
  aws ec2 delete-security-group --group-id "$ALB_SG" --region "$REGION" 2>/dev/null || true

# ============================================================
# 6. IAM
# ============================================================

echo ">>> Deleting IAM resources..."

aws iam remove-role-from-instance-profile \
  --instance-profile-name EC2CodeDeployProfile \
  --role-name EC2CodeDeployRole 2>/dev/null || true
aws iam delete-instance-profile \
  --instance-profile-name EC2CodeDeployProfile 2>/dev/null || true

for policy in AmazonSSMManagedInstanceCore service-role/AmazonEC2RoleforAWSCodeDeploy; do
  aws iam detach-role-policy --role-name EC2CodeDeployRole \
    --policy-arn "arn:${AWS_PARTITION}:iam::aws:policy/$policy" 2>/dev/null || true
done
aws iam delete-role --role-name EC2CodeDeployRole 2>/dev/null || true

aws iam detach-role-policy --role-name CodeDeployServiceRole \
  --policy-arn "arn:${AWS_PARTITION}:iam::aws:policy/service-role/AWSCodeDeployRole" 2>/dev/null || true
aws iam detach-role-policy --role-name CodeDeployServiceRole \
  --policy-arn "arn:${AWS_PARTITION}:iam::aws:policy/AutoScalingFullAccess" 2>/dev/null || true
aws iam delete-role --role-name CodeDeployServiceRole 2>/dev/null || true

echo ""
echo "=== Teardown Complete ==="
