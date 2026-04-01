#!/bin/bash
# shellcheck disable=SC2034  # Variables used by sourcing scripts

# --- User-configurable (override via environment) ---
REGION="${AWS_REGION:-us-east-1}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.small}"
APP_NAME="${APP_NAME:-playground}"
DG_NAME="${DG_NAME:-playground-dg}"
GITHUB_REPO="${GITHUB_REPO:-guessi/playground}"

# --- Derived resource names ---
ASG_NAME="${APP_NAME}-asg"
LT_NAME="${APP_NAME}-lt"
ALB_NAME="${APP_NAME}-alb"
TG_NAME="${APP_NAME}-tg"
ALB_SG_NAME="${APP_NAME}-alb-sg"
EC2_SG_NAME="${APP_NAME}-ec2-sg"
