#!/bin/bash
set -euo pipefail

# ============================================================
# Configuration
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

command -v jq >/dev/null || { echo "Error: jq is required but not installed"; exit 1; }

# ============================================================
# Auto-discover infrastructure
# ============================================================

AWS_PARTITION=$(aws sts get-caller-identity \
  --query "Arn" --output text --region "$REGION" | cut -d: -f2)

echo ">>> Discovering VPC and subnets..."

VPC_ID="${VPC_ID:-$(aws ec2 describe-vpcs \
  --filters Name=is-default,Values=true \
  --query "Vpcs[0].VpcId" --output text --region "$REGION")}"

SUBNETS=$(aws ec2 describe-subnets \
  --filters Name=vpc-id,Values="$VPC_ID" \
  --query "Subnets[*].SubnetId" --output text --region "$REGION")

AMI_ID=$(aws ec2 describe-images --owners amazon \
  --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" \
  --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text --region "$REGION")

echo "    VPC:     $VPC_ID"
echo "    Subnets: $SUBNETS"
echo "    AMI:     $AMI_ID"

# ============================================================
# Helper functions
# ============================================================

create_role() {
  local role_name="$1" service="$2"
  aws iam create-role \
    --role-name "$role_name" \
    --assume-role-policy-document "{
      \"Version\":\"2012-10-17\",
      \"Statement\":[{
        \"Effect\":\"Allow\",
        \"Principal\":{\"Service\":\"$service\"},
        \"Action\":\"sts:AssumeRole\"
      }]
    }" --region "$REGION" 2>/dev/null || true
}

attach_policy() {
  aws iam attach-role-policy \
    --role-name "$1" --policy-arn "$2" 2>/dev/null || true
}

get_or_create_sg() {
  local name="$1" desc="$2"
  aws ec2 create-security-group \
    --group-name "$name" --description "$desc" \
    --vpc-id "$VPC_ID" --region "$REGION" \
    --query "GroupId" --output text 2>/dev/null || \
  aws ec2 describe-security-groups \
    --filters Name=group-name,Values="$name" Name=vpc-id,Values="$VPC_ID" \
    --query "SecurityGroups[0].GroupId" --output text --region "$REGION"
}

# ============================================================
# 1. IAM Roles
# ============================================================

echo ">>> Creating IAM roles..."

create_role "CodeDeployServiceRole" "codedeploy.amazonaws.com"
attach_policy "CodeDeployServiceRole" \
  "arn:${AWS_PARTITION}:iam::aws:policy/service-role/AWSCodeDeployRole"
attach_policy "CodeDeployServiceRole" \
  "arn:${AWS_PARTITION}:iam::aws:policy/AutoScalingFullAccess"

create_role "EC2CodeDeployRole" "ec2.amazonaws.com"
attach_policy "EC2CodeDeployRole" \
  "arn:${AWS_PARTITION}:iam::aws:policy/AmazonSSMManagedInstanceCore"
attach_policy "EC2CodeDeployRole" \
  "arn:${AWS_PARTITION}:iam::aws:policy/service-role/AmazonEC2RoleforAWSCodeDeploy"

aws iam create-instance-profile \
  --instance-profile-name EC2CodeDeployProfile \
  --region "$REGION" 2>/dev/null || true
aws iam add-role-to-instance-profile \
  --instance-profile-name EC2CodeDeployProfile \
  --role-name EC2CodeDeployRole 2>/dev/null || true

CODEDEPLOY_ROLE_ARN=$(aws iam get-role \
  --role-name CodeDeployServiceRole --query "Role.Arn" --output text)

echo "    Waiting for instance profile propagation..."
sleep 10

# ============================================================
# 2. Security Groups
# ============================================================

echo ">>> Creating security groups..."

ALB_SG=$(get_or_create_sg "$ALB_SG_NAME" "ALB security group")
EC2_SG=$(get_or_create_sg "$EC2_SG_NAME" "EC2 security group")

aws ec2 authorize-security-group-ingress \
  --group-id "$ALB_SG" --protocol tcp --port 80 --cidr 0.0.0.0/0 \
  --region "$REGION" 2>/dev/null || true

aws ec2 authorize-security-group-ingress \
  --group-id "$EC2_SG" --protocol tcp --port 80 --source-group "$ALB_SG" \
  --region "$REGION" 2>/dev/null || true

# ============================================================
# 3. ALB + Target Group
# ============================================================

echo ">>> Creating ALB and target group..."

IFS=$'\t' read -ra SUBNET_ARRAY <<< "$SUBNETS"

ALB_ARN=$(aws elbv2 create-load-balancer \
  --name "$ALB_NAME" \
  --subnets "${SUBNET_ARRAY[@]}" \
  --security-groups "$ALB_SG" \
  --scheme internet-facing --type application \
  --region "$REGION" \
  --query "LoadBalancers[0].LoadBalancerArn" --output text 2>/dev/null) || \
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "$ALB_NAME" \
  --query "LoadBalancers[0].LoadBalancerArn" --output text --region "$REGION")

TG_ARN=$(aws elbv2 create-target-group \
  --name "$TG_NAME" \
  --protocol HTTP --port 80 \
  --vpc-id "$VPC_ID" --target-type instance \
  --health-check-path "/" \
  --region "$REGION" \
  --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null) || \
TG_ARN=$(aws elbv2 describe-target-groups \
  --names "$TG_NAME" \
  --query "TargetGroups[0].TargetGroupArn" --output text --region "$REGION")

aws elbv2 modify-target-group-attributes \
  --target-group-arn "$TG_ARN" \
  --attributes Key=deregistration_delay.timeout_seconds,Value=30 \
  --region "$REGION" >/dev/null

aws elbv2 modify-target-group \
  --target-group-arn "$TG_ARN" \
  --health-check-interval-seconds 10 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 2 \
  --health-check-timeout-seconds 5 \
  --region "$REGION" >/dev/null

aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP --port 80 \
  --default-actions Type=forward,TargetGroupArn="$TG_ARN" \
  --region "$REGION" 2>/dev/null || true

# ============================================================
# 4. Launch Template + ASG
# ============================================================

echo ">>> Creating launch template and ASG..."

USERDATA=$(base64 <<'USERDATA_EOF' | tr -d '\n'
#!/bin/bash
dnf install -y ruby wget --allowerasing
cd /home/ec2-user
USERDATA_EOF
)
# Append region-specific CodeDeploy agent install (needs variable expansion)
USERDATA=$(echo "$USERDATA" | base64 -d; cat <<EOF
wget https://aws-codedeploy-${REGION}.s3.${REGION}.amazonaws.com/latest/install
chmod +x ./install
./install auto
EOF
)
USERDATA=$(echo "$USERDATA" | base64 | tr -d '\n')

LT_DATA=$(jq -n \
  --arg ami "$AMI_ID" \
  --arg type "$INSTANCE_TYPE" \
  --arg sg "$EC2_SG" \
  --arg ud "$USERDATA" \
  '{
    ImageId: $ami,
    InstanceType: $type,
    IamInstanceProfile: { Name: "EC2CodeDeployProfile" },
    Monitoring: { Enabled: true },
    UserData: $ud,
    NetworkInterfaces: [{
      DeviceIndex: 0,
      AssociatePublicIpAddress: true,
      Groups: [$sg]
    }]
  }')

if aws ec2 describe-launch-templates --launch-template-names "$LT_NAME" \
  --region "$REGION" &>/dev/null; then
  aws ec2 create-launch-template-version \
    --launch-template-name "$LT_NAME" \
    --launch-template-data "$LT_DATA" \
    --region "$REGION" >/dev/null
  # shellcheck disable=SC2016  # $Latest is a literal AWS API value
  aws ec2 modify-launch-template \
    --launch-template-name "$LT_NAME" \
    --default-version '$Latest' \
    --region "$REGION" >/dev/null
else
  aws ec2 create-launch-template \
    --launch-template-name "$LT_NAME" \
    --launch-template-data "$LT_DATA" \
    --region "$REGION" >/dev/null
fi

aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name "$ASG_NAME" \
  --launch-template "LaunchTemplateName=$LT_NAME,Version=\$Latest" \
  --min-size 1 --max-size 2 --desired-capacity 1 \
  --vpc-zone-identifier "$(echo "$SUBNETS" | tr '\t' ',')" \
  --target-group-arns "$TG_ARN" \
  --health-check-type ELB \
  --health-check-grace-period 60 \
  --region "$REGION" 2>/dev/null || true

aws autoscaling enable-metrics-collection \
  --auto-scaling-group-name "$ASG_NAME" \
  --granularity "1Minute" \
  --region "$REGION"

# ============================================================
# 5. Auto Scaling Policies
# ============================================================

echo ">>> Creating scaling policies and alarms..."

SCALE_UP_ARN=$(aws autoscaling put-scaling-policy \
  --auto-scaling-group-name "$ASG_NAME" \
  --policy-name "${APP_NAME}-scale-up" \
  --policy-type StepScaling \
  --adjustment-type ChangeInCapacity \
  --step-adjustments MetricIntervalLowerBound=0,ScalingAdjustment=1 \
  --region "$REGION" --query "PolicyARN" --output text)

SCALE_DOWN_ARN=$(aws autoscaling put-scaling-policy \
  --auto-scaling-group-name "$ASG_NAME" \
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
  --dimensions "Name=AutoScalingGroupName,Value=$ASG_NAME" \
  --alarm-actions "$SCALE_UP_ARN" \
  --region "$REGION" >/dev/null

aws cloudwatch put-metric-alarm \
  --alarm-name "${APP_NAME}-cpu-low" \
  --metric-name CPUUtilization --namespace AWS/EC2 \
  --statistic Average --period 60 --evaluation-periods 2 \
  --threshold 10 --comparison-operator LessThanThreshold \
  --dimensions "Name=AutoScalingGroupName,Value=$ASG_NAME" \
  --alarm-actions "$SCALE_DOWN_ARN" \
  --region "$REGION" >/dev/null

# ============================================================
# 6. CodeDeploy (Blue/Green)
# ============================================================

echo ">>> Creating CodeDeploy application and deployment group..."

aws deploy create-application \
  --application-name "$APP_NAME" \
  --compute-platform Server \
  --region "$REGION" 2>/dev/null || true

aws deploy create-deployment-group \
  --application-name "$APP_NAME" \
  --deployment-group-name "$DG_NAME" \
  --service-role-arn "$CODEDEPLOY_ROLE_ARN" \
  --auto-scaling-groups "$ASG_NAME" \
  --load-balancer-info "targetGroupInfoList=[{name=$TG_NAME}]" \
  --deployment-style "deploymentType=BLUE_GREEN,deploymentOption=WITH_TRAFFIC_CONTROL" \
  --blue-green-deployment-configuration '{
    "terminateBlueInstancesOnDeploymentSuccess": {
      "action": "TERMINATE",
      "terminationWaitTimeInMinutes": 0
    },
    "deploymentReadyOption": {
      "actionOnTimeout": "CONTINUE_DEPLOYMENT",
      "waitTimeInMinutes": 0
    },
    "greenFleetProvisioningOption": {
      "action": "COPY_AUTO_SCALING_GROUP"
    }
  }' \
  --auto-rollback-configuration "enabled=false" \
  --alarm-configuration '{
    "enabled": true,
    "ignorePollAlarmFailure": false,
    "alarms": [
      { "name": "'"${APP_NAME}"'-cpu-high" }
    ]
  }' \
  --region "$REGION" 2>/dev/null || true

# ============================================================
# Done
# ============================================================

echo ""
echo "=== Setup Complete ==="
echo ""
echo "To deploy:"
echo "  ./deploy.sh"
