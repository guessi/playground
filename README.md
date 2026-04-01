# playground

Nginx Blue/Green deployment to EC2 Auto Scaling Group via AWS CodeDeploy.

## Prerequisites

- AWS CLI configured with appropriate permissions
- `jq` installed
- GitHub repository connected to CodeDeploy (one-time console setup)

## Usage

```bash
# 1. Provision all AWS resources
./setup.sh

# 2. Deploy from GitHub
./deploy.sh              # deploy HEAD
./deploy.sh abc1234      # deploy specific commit

# 3. Tear down all resources when done
./teardown.sh
```

## Configuration

All scripts support environment variable overrides:

| Variable        | Default              |
|-----------------|----------------------|
| `AWS_REGION`    | `us-east-1`          |
| `VPC_ID`        | default VPC          |
| `INSTANCE_TYPE` | `t3.small`           |
| `APP_NAME`      | `playground`         |
| `DG_NAME`       | `playground-dg`      |
| `GITHUB_REPO`   | `guessi/playground`  |

Example:

```bash
AWS_REGION=ap-northeast-1 INSTANCE_TYPE=t3.small ./setup.sh
```

## What setup.sh Creates

1. IAM roles (CodeDeploy service role + EC2 instance profile)
2. Security groups (ALB + EC2)
3. Application Load Balancer + target group
4. Launch template (Amazon Linux 2023 + CodeDeploy agent)
5. Auto Scaling Group (min 1, max 2, desired 1)
6. CodeDeploy application + Blue/Green deployment group
