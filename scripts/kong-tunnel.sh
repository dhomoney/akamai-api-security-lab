#!/usr/bin/env bash
# Opens an SSH tunnel to whichever ECS node is running the Kong task.
# Usage: ./scripts/kong-tunnel.sh [local_port]
# Default local port: 18001 → Kong Admin API at http://localhost:18001

set -euo pipefail

PROFILE="${AWS_PROFILE:-SA_Standard_Access-491489166083}"
REGION="us-east-2"
CLUSTER="homoney-akamai-lab-cluster"
SERVICE="homoney-akamai-lab-kong"
KEY="keys/lab_key"
LOCAL_PORT="${1:-18001}"

cd "$(dirname "$0")/.."

echo "Looking up Kong task..."
TASK_ARN=$(aws ecs list-tasks \
  --profile "$PROFILE" --region "$REGION" \
  --cluster "$CLUSTER" --service-name "$SERVICE" \
  --query 'taskArns[0]' --output text)

if [[ "$TASK_ARN" == "None" || -z "$TASK_ARN" ]]; then
  echo "ERROR: No running Kong task found in cluster $CLUSTER."
  exit 1
fi
echo "  Task: $TASK_ARN"

CI_ARN=$(aws ecs describe-tasks \
  --profile "$PROFILE" --region "$REGION" \
  --cluster "$CLUSTER" --tasks "$TASK_ARN" \
  --query 'tasks[0].containerInstanceArn' --output text)
echo "  Container instance: $CI_ARN"

EC2_ID=$(aws ecs describe-container-instances \
  --profile "$PROFILE" --region "$REGION" \
  --cluster "$CLUSTER" --container-instances "$CI_ARN" \
  --query 'containerInstances[0].ec2InstanceId' --output text)
echo "  EC2 instance: $EC2_ID"

NODE_IP=$(aws ec2 describe-instances \
  --profile "$PROFILE" --region "$REGION" \
  --instance-ids "$EC2_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
echo "  Node IP: $NODE_IP"

BASTION_IP=$(cd terraform && terraform output -raw bastion_public_ip 2>/dev/null)
echo "  Bastion: $BASTION_IP"

echo ""
echo "Kong Admin API will be available at http://localhost:${LOCAL_PORT}"
echo "Press Ctrl+C to close the tunnel."
echo ""

ssh -i "$KEY" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ExitOnForwardFailure=yes \
  -L "${LOCAL_PORT}:localhost:8001" \
  -J "ec2-user@${BASTION_IP}" \
  "ec2-user@${NODE_IP}" \
  -N
