#!/usr/bin/env bash
set -euo pipefail

# Full bootstrap + deploy for Slack AI Assistant on ECS Fargate.
#
# Usage:
#   export AWS_REGION=us-east-1          # optional, default us-east-1
#   export SECRETS_FILE=deploy/secrets-template.json   # optional
#   ./deploy/deploy.sh
#
# Flags:
#   --bootstrap-only   Create AWS infra only (no Docker build/deploy)
#   --skip-bootstrap   Skip infra setup (image build + ECS deploy only)
#   --sync-wiki        Re-copy water_knowledge/wiki into EFS before deploying
#   --sync-wiki-only   Build/push image and sync wiki to EFS (no ECS redeploy)
#
# The water-knowledge wiki is served from EFS so it can be updated without
# rebuilding the image. Set WIKI_EFS=no to skip EFS entirely and read the copy
# baked into the container instead.
#
# Required for first run:
#   - aws CLI configured (aws sts get-caller-identity works)
#   - docker (unless --bootstrap-only)
#   - jq
#   - SECRETS_FILE with SLACK_BOT_TOKEN, SLACK_APP_TOKEN, OPENAI_API_KEY, etc.

AWS_REGION="${AWS_REGION:-us-east-1}"
ECR_REPO="${ECR_REPO:-slack-ai-assistant}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
CLUSTER="${ECS_CLUSTER:-slack-ai-assistant}"
SERVICE="${ECS_SERVICE:-slack-ai-assistant}"
TASK_FAMILY="${ECS_TASK_FAMILY:-slack-ai-assistant}"
CONTAINER_NAME="${CONTAINER_NAME:-slack-ai-assistant}"
LOG_GROUP="${LOG_GROUP:-/ecs/slack-ai-assistant}"
SECRET_NAME="${APP_SECRETS_NAME:-slack-ai-assistant/prod}"
EXECUTION_ROLE="${ECS_EXECUTION_ROLE:-ecsTaskExecutionRole}"
TASK_ROLE="${ECS_TASK_ROLE:-slack-ai-assistant-task-role}"
SG_NAME="${SG_NAME:-slack-ai-assistant-sg}"
SECRETS_FILE="${SECRETS_FILE:-deploy/secrets-template.json}"

# Water-knowledge wiki on EFS.
WIKI_EFS="${WIKI_EFS:-yes}"
WIKI_EFS_TOKEN="${WIKI_EFS_TOKEN:-slack-ai-assistant-wiki}"
WIKI_EFS_AP_NAME="${WIKI_EFS_AP_NAME:-slack-ai-assistant-wiki-ap}"
WIKI_EFS_SG_NAME="${WIKI_EFS_SG_NAME:-slack-ai-assistant-efs-sg}"
WIKI_MOUNT_PATH="${WIKI_MOUNT_PATH:-/mnt/water_knowledge}"
WIKI_SYNC_FAMILY="${WIKI_SYNC_FAMILY:-slack-ai-assistant-wiki-sync}"
# uid/gid of appuser in the image; the access point pins ownership to match.
WIKI_EFS_UID="${WIKI_EFS_UID:-1000}"

BOOTSTRAP_ONLY=no
SKIP_BOOTSTRAP=no
SYNC_WIKI=no
SYNC_WIKI_ONLY=no
NEED_WIKI_SYNC=no
WIKI_FS_ID=""
WIKI_AP_ID=""
EFS_SG_ID=""

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

usage() {
  sed -n '3,25p' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bootstrap-only) BOOTSTRAP_ONLY=yes; shift ;;
    --skip-bootstrap) SKIP_BOOTSTRAP=yes; shift ;;
    --sync-wiki) SYNC_WIKI=yes; shift ;;
    --sync-wiki-only) SYNC_WIKI_ONLY=yes; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

# Empty string rather than the literal "None" the CLI prints for a missing value.
aws_value() {
  local out
  out="$("$@" 2>/dev/null || true)"
  [[ "$out" == "None" ]] && out=""
  printf '%s' "$out"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 1
  fi
}

resolve_account_id() {
  if [[ -z "${AWS_ACCOUNT_ID:-}" ]]; then
    AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  fi
  ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}"
}

load_secrets_payload() {
  if [[ ! -f "${ROOT_DIR}/${SECRETS_FILE}" && ! -f "${SECRETS_FILE}" ]]; then
    echo "Secrets file not found: ${SECRETS_FILE}" >&2
    echo "Create it from deploy/secrets-template.json or set SECRETS_FILE." >&2
    exit 1
  fi

  if [[ -f "${ROOT_DIR}/${SECRETS_FILE}" ]]; then
    SECRETS_PATH="${ROOT_DIR}/${SECRETS_FILE}"
  else
    SECRETS_PATH="${SECRETS_FILE}"
  fi

  for key in SLACK_BOT_TOKEN SLACK_APP_TOKEN OPENAI_API_KEY; do
    if ! jq -e --arg k "$key" '.[$k] | length > 0' "$SECRETS_PATH" >/dev/null; then
      echo "Missing or empty key in ${SECRETS_PATH}: ${key}" >&2
      exit 1
    fi
  done

  S3_BUCKET="$(jq -r '.S3_SESSION_BUCKET // empty' "$SECRETS_PATH")"
  if [[ -z "$S3_BUCKET" ]]; then
    S3_BUCKET="${S3_SESSION_BUCKET:-}"
  fi
  if [[ -z "$S3_BUCKET" ]]; then
    echo "Set S3_SESSION_BUCKET in ${SECRETS_PATH} or export S3_SESSION_BUCKET." >&2
    exit 1
  fi
}

ensure_ecs_service_linked_role() {
  log "Ensuring ECS service-linked role exists..."
  aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com >/dev/null 2>&1 || true
}

ensure_s3_bucket() {
  log "Ensuring S3 bucket s3://${S3_BUCKET} exists..."
  if aws s3api head-bucket --bucket "$S3_BUCKET" 2>/dev/null; then
    log "S3 bucket already exists."
    return 0
  fi

  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$S3_BUCKET" --region "$AWS_REGION"
  else
    aws s3api create-bucket \
      --bucket "$S3_BUCKET" \
      --region "$AWS_REGION" \
      --create-bucket-configuration "LocationConstraint=${AWS_REGION}"
  fi
}

ensure_secret() {
  log "Ensuring Secrets Manager secret ${SECRET_NAME} exists in ${AWS_REGION}..."
  if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    log "Secret already exists; skipping create."
    return 0
  fi

  UPDATED_PAYLOAD="$(mktemp)"
  jq --arg region "$AWS_REGION" \
    '.SESSION_BACKEND = "s3" | .AWS_REGION = $region' \
    "$SECRETS_PATH" > "$UPDATED_PAYLOAD"

  aws secretsmanager create-secret \
    --name "$SECRET_NAME" \
    --secret-string "file://${UPDATED_PAYLOAD}" \
    --region "$AWS_REGION" >/dev/null
  rm -f "$UPDATED_PAYLOAD"
}

ensure_iam_role() {
  local role_name="$1"
  local trust_file="$2"

  if aws iam get-role --role-name "$role_name" >/dev/null 2>&1; then
    log "IAM role ${role_name} already exists."
    return 0
  fi

  log "Creating IAM role ${role_name}..."
  aws iam create-role \
    --role-name "$role_name" \
    --assume-role-policy-document "file://${trust_file}" \
    --description "Slack AI Assistant ${role_name}" >/dev/null
}

ensure_execution_role() {
  local trust_file
  trust_file="$(mktemp)"
  cat > "$trust_file" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ecs-tasks.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

  ensure_iam_role "$EXECUTION_ROLE" "$trust_file"
  rm -f "$trust_file"

  aws iam attach-role-policy \
    --role-name "$EXECUTION_ROLE" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy \
    2>/dev/null || true

  local logs_policy_file
  logs_policy_file="$(mktemp)"
  cat > "$logs_policy_file" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["logs:CreateLogGroup"],
      "Resource": "arn:aws:logs:${AWS_REGION}:${AWS_ACCOUNT_ID}:log-group:/ecs/*"
    }
  ]
}
EOF

  aws iam put-role-policy \
    --role-name "$EXECUTION_ROLE" \
    --policy-name ECSCreateLogGroup \
    --policy-document "file://${logs_policy_file}"
  rm -f "$logs_policy_file"
}

ensure_task_role() {
  local trust_file policy_file rendered_policy
  trust_file="$(mktemp)"
  cat > "$trust_file" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ecs-tasks.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

  ensure_iam_role "$TASK_ROLE" "$trust_file"
  rm -f "$trust_file"

  policy_file="${ROOT_DIR}/deploy/iam-task-role-policy.json"
  rendered_policy="$(mktemp)"
  sed \
    -e "s/ACCOUNT_ID/${AWS_ACCOUNT_ID}/g" \
    -e "s/AWS_REGION/${AWS_REGION}/g" \
    -e "s/S3_BUCKET/${S3_BUCKET}/g" \
    -e "s|SECRET_NAME|${SECRET_NAME}|g" \
    -e "s/EFS_FS_ID/${WIKI_FS_ID:-none}/g" \
    -e "s/EFS_AP_ID/${WIKI_AP_ID:-none}/g" \
    "$policy_file" > "$rendered_policy"

  # Without a filesystem the EFS statement would only name placeholders, so drop it.
  # ClientWrite is what lets the one-off sync task seed the wiki; the app itself
  # mounts read-only.
  if [[ -z "$WIKI_FS_ID" || -z "$WIKI_AP_ID" ]]; then
    jq 'del(.Statement[] | select(.Sid == "WikiEfsAccess"))' \
      "$rendered_policy" > "${rendered_policy}.tmp"
    mv "${rendered_policy}.tmp" "$rendered_policy"
  fi

  aws iam put-role-policy \
    --role-name "$TASK_ROLE" \
    --policy-name SlackAIAssistantTaskPolicy \
    --policy-document "file://${rendered_policy}"
  rm -f "$rendered_policy"

  log "Waiting for IAM roles to propagate..."
  sleep 10
}

ensure_wiki_efs() {
  if [[ "$WIKI_EFS" != "yes" ]]; then
    log "WIKI_EFS=no; skipping EFS. The agent will read the wiki baked into the image."
    return 0
  fi

  log "Ensuring EFS filesystem for the water-knowledge wiki..."
  WIKI_FS_ID="$(aws_value aws efs describe-file-systems \
    --creation-token "$WIKI_EFS_TOKEN" \
    --query 'FileSystems[0].FileSystemId' \
    --output text --region "$AWS_REGION")"

  if [[ -z "$WIKI_FS_ID" ]]; then
    WIKI_FS_ID="$(aws efs create-file-system \
      --creation-token "$WIKI_EFS_TOKEN" \
      --encrypted \
      --performance-mode generalPurpose \
      --throughput-mode elastic \
      --tags "Key=Name,Value=${WIKI_EFS_TOKEN}" \
      --query FileSystemId --output text --region "$AWS_REGION")"
    log "Created EFS ${WIKI_FS_ID}. It starts empty, so the wiki is seeded after the image build."
    NEED_WIKI_SYNC=yes
  else
    log "EFS already exists: ${WIKI_FS_ID}"
  fi

  local state=""
  for _ in $(seq 1 60); do
    state="$(aws_value aws efs describe-file-systems --file-system-id "$WIKI_FS_ID" \
      --query 'FileSystems[0].LifeCycleState' --output text --region "$AWS_REGION")"
    [[ "$state" == "available" ]] && break
    sleep 5
  done
  if [[ "$state" != "available" ]]; then
    echo "EFS ${WIKI_FS_ID} did not become available (state=${state:-unknown})." >&2
    exit 1
  fi

  # Mount targets speak NFS on 2049; the task SG only has egress rules, so the
  # filesystem needs its own SG that trusts the task SG.
  EFS_SG_ID="$(aws_value aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${WIKI_EFS_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION")"

  if [[ -z "$EFS_SG_ID" ]]; then
    log "Creating security group ${WIKI_EFS_SG_NAME}..."
    EFS_SG_ID="$(aws ec2 create-security-group \
      --group-name "$WIKI_EFS_SG_NAME" \
      --description "Slack AI Assistant wiki EFS mount targets" \
      --vpc-id "$VPC_ID" \
      --query GroupId --output text --region "$AWS_REGION")"
  fi

  aws ec2 authorize-security-group-ingress \
    --group-id "$EFS_SG_ID" \
    --protocol tcp --port 2049 \
    --source-group "$SG_ID" \
    --region "$AWS_REGION" >/dev/null 2>&1 || true

  # A mount target is per-AZ: tasks can only mount through one in their own subnet.
  local mt_id
  mt_id="$(aws_value aws efs describe-mount-targets \
    --file-system-id "$WIKI_FS_ID" \
    --query "MountTargets[?SubnetId=='${SUBNET_ID}'].MountTargetId | [0]" \
    --output text --region "$AWS_REGION")"

  if [[ -z "$mt_id" ]]; then
    log "Creating EFS mount target in ${SUBNET_ID}..."
    mt_id="$(aws efs create-mount-target \
      --file-system-id "$WIKI_FS_ID" \
      --subnet-id "$SUBNET_ID" \
      --security-groups "$EFS_SG_ID" \
      --query MountTargetId --output text --region "$AWS_REGION")"
  fi

  log "Waiting for mount target ${mt_id} to become available..."
  for _ in $(seq 1 60); do
    state="$(aws_value aws efs describe-mount-targets --mount-target-id "$mt_id" \
      --query 'MountTargets[0].LifeCycleState' --output text --region "$AWS_REGION")"
    [[ "$state" == "available" ]] && break
    sleep 5
  done
  if [[ "$state" != "available" ]]; then
    echo "Mount target ${mt_id} did not become available (state=${state:-unknown})." >&2
    exit 1
  fi

  # The access point pins the exposed subdirectory and the POSIX identity, so the
  # container (which runs as appuser, not root) owns what it mounts.
  WIKI_AP_ID="$(aws_value aws efs describe-access-points \
    --file-system-id "$WIKI_FS_ID" \
    --query "AccessPoints[?Name=='${WIKI_EFS_AP_NAME}'].AccessPointId | [0]" \
    --output text --region "$AWS_REGION")"

  if [[ -z "$WIKI_AP_ID" ]]; then
    log "Creating EFS access point ${WIKI_EFS_AP_NAME}..."
    WIKI_AP_ID="$(aws efs create-access-point \
      --file-system-id "$WIKI_FS_ID" \
      --tags "Key=Name,Value=${WIKI_EFS_AP_NAME}" \
      --posix-user "Uid=${WIKI_EFS_UID},Gid=${WIKI_EFS_UID}" \
      --root-directory "Path=/water_knowledge,CreationInfo={OwnerUid=${WIKI_EFS_UID},OwnerGid=${WIKI_EFS_UID},Permissions=0755}" \
      --query AccessPointId --output text --region "$AWS_REGION")"
  fi

  log "Wiki EFS ready: fs=${WIKI_FS_ID} access_point=${WIKI_AP_ID} mount=${WIKI_MOUNT_PATH}"
}

ensure_ecr_repo() {
  log "Ensuring ECR repository ${ECR_REPO} exists..."
  if aws ecr describe-repositories --repository-names "$ECR_REPO" --region "$AWS_REGION" >/dev/null 2>&1; then
    log "ECR repository already exists."
    return 0
  fi
  aws ecr create-repository --repository-name "$ECR_REPO" --region "$AWS_REGION" >/dev/null
}

ensure_log_group() {
  log "Ensuring CloudWatch log group ${LOG_GROUP} exists..."
  if aws logs describe-log-groups \
    --log-group-name-prefix "$LOG_GROUP" \
    --region "$AWS_REGION" \
    --query "logGroups[?logGroupName=='${LOG_GROUP}'].logGroupName" \
    --output text 2>/dev/null | grep -q "$LOG_GROUP"; then
    log "Log group already exists."
    return 0
  fi
  aws logs create-log-group --log-group-name "$LOG_GROUP" --region "$AWS_REGION"
}

ensure_ecs_cluster() {
  log "Ensuring ECS cluster ${CLUSTER} exists..."
  local status
  status="$(aws ecs describe-clusters \
    --clusters "$CLUSTER" \
    --region "$AWS_REGION" \
    --query 'clusters[0].status' \
    --output text 2>/dev/null || echo NONE)"

  if [[ "$status" == "ACTIVE" ]]; then
    log "ECS cluster already active."
    return 0
  fi

  aws ecs create-cluster --cluster-name "$CLUSTER" --region "$AWS_REGION" >/dev/null
}

resolve_network() {
  log "Resolving default VPC networking..."
  VPC_ID="$(aws ec2 describe-vpcs \
    --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' \
    --output text \
    --region "$AWS_REGION")"

  if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
    echo "No default VPC found in ${AWS_REGION}. Set SUBNET_ID and SG_ID manually." >&2
    exit 1
  fi

  SUBNET_ID="${SUBNET_ID:-$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=default-for-az,Values=true" \
    --query 'Subnets[0].SubnetId' \
    --output text \
    --region "$AWS_REGION")}"

  if [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "None" ]]; then
    echo "No default subnet found in VPC ${VPC_ID}." >&2
    exit 1
  fi

  SG_ID="$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || true)"

  if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
    log "Creating security group ${SG_NAME}..."
    SG_ID="$(aws ec2 create-security-group \
      --group-name "$SG_NAME" \
      --description "Slack AI Assistant ECS outbound" \
      --vpc-id "$VPC_ID" \
      --query GroupId \
      --output text \
      --region "$AWS_REGION")"
    aws ec2 authorize-security-group-egress \
      --group-id "$SG_ID" \
      --protocol -1 \
      --cidr 0.0.0.0/0 \
      --region "$AWS_REGION" >/dev/null 2>&1 || true
  fi

  log "Using subnet=${SUBNET_ID}, security_group=${SG_ID}"
}

bootstrap_aws() {
  require_cmd aws
  require_cmd jq

  resolve_account_id
  load_secrets_payload
  ensure_ecs_service_linked_role
  ensure_s3_bucket
  ensure_secret
  ensure_execution_role
  # resolve_network first: the EFS mount target needs the VPC, subnet and task SG,
  # and the task role policy needs the filesystem and access point IDs.
  resolve_network
  ensure_wiki_efs
  ensure_task_role
  ensure_ecr_repo
  ensure_log_group
  ensure_ecs_cluster

  log "AWS bootstrap complete."
}

render_task_definition() {
  local output_file="$1"
  # Shared with the GitHub Actions deploy so both attach the same EFS volume.
  AWS_ACCOUNT_ID="$AWS_ACCOUNT_ID" \
  AWS_REGION="$AWS_REGION" \
  CONTAINER_NAME="$CONTAINER_NAME" \
  WIKI_EFS_TOKEN="$WIKI_EFS_TOKEN" \
  WIKI_EFS_AP_NAME="$WIKI_EFS_AP_NAME" \
  WIKI_MOUNT_PATH="$WIKI_MOUNT_PATH" \
    bash "${ROOT_DIR}/deploy/render-task-def.sh" "$output_file" "${ECR_URI}:${IMAGE_TAG}"
}

build_and_push_image() {
  require_cmd docker

  log "Logging in to ECR..."
  aws ecr get-login-password --region "${AWS_REGION}" \
    | docker login --username AWS --password-stdin \
      "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

  log "Building image for ECS Fargate (linux/amd64)..."
  docker build --platform linux/amd64 -t "${ECR_REPO}:${IMAGE_TAG}" "${ROOT_DIR}"

  log "Pushing ${ECR_URI}:${IMAGE_TAG}..."
  docker tag "${ECR_REPO}:${IMAGE_TAG}" "${ECR_URI}:${IMAGE_TAG}"
  docker push "${ECR_URI}:${IMAGE_TAG}"
}

sync_wiki_to_efs() {
  if [[ "$WIKI_EFS" != "yes" ]]; then
    return 0
  fi
  if [[ -z "$WIKI_FS_ID" || -z "$WIKI_AP_ID" ]]; then
    warn "No wiki EFS resolved; skipping wiki sync."
    return 0
  fi
  if [[ -z "${SUBNET_ID:-}" || -z "${SG_ID:-}" ]]; then
    warn "SUBNET_ID/SG_ID unknown (--skip-bootstrap); skipping wiki sync. Export them to sync."
    return 0
  fi

  log "Syncing water_knowledge/wiki into EFS ${WIKI_FS_ID}..."

  # A one-off Fargate task copies the wiki out of the image and into EFS. EFS is
  # only reachable from inside the VPC, so this is the way to seed it without a
  # bastion or a VPN.
  local copy_cmd
  copy_cmd="set -e; "
  copy_cmd+="test -d /app/water_knowledge/wiki || { echo 'image contains no wiki to sync' >&2; exit 1; }; "
  copy_cmd+="mkdir -p ${WIKI_MOUNT_PATH}/wiki; "
  copy_cmd+="cp -a /app/water_knowledge/wiki/. ${WIKI_MOUNT_PATH}/wiki/; "
  copy_cmd+="find ${WIKI_MOUNT_PATH}/wiki -name '*.md' | wc -l | xargs echo 'pages now on efs:'"

  local task_def sync_arn task_arn exit_code
  task_def="$(mktemp)"
  jq -n \
    --arg family "$WIKI_SYNC_FAMILY" \
    --arg exec_role "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${EXECUTION_ROLE}" \
    --arg task_role "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${TASK_ROLE}" \
    --arg image "${ECR_URI}:${IMAGE_TAG}" \
    --arg fs_id "$WIKI_FS_ID" \
    --arg ap_id "$WIKI_AP_ID" \
    --arg mount "$WIKI_MOUNT_PATH" \
    --arg cmd "$copy_cmd" \
    --arg log_group "$LOG_GROUP" \
    --arg region "$AWS_REGION" \
    '{
      family: $family,
      networkMode: "awsvpc",
      requiresCompatibilities: ["FARGATE"],
      cpu: "256",
      memory: "512",
      executionRoleArn: $exec_role,
      taskRoleArn: $task_role,
      volumes: [{
        name: "water-knowledge",
        efsVolumeConfiguration: {
          fileSystemId: $fs_id,
          transitEncryption: "ENABLED",
          authorizationConfig: { accessPointId: $ap_id, iam: "ENABLED" }
        }
      }],
      containerDefinitions: [{
        name: "wiki-sync",
        image: $image,
        essential: true,
        entryPoint: ["sh", "-c"],
        command: [$cmd],
        mountPoints: [{ sourceVolume: "water-knowledge", containerPath: $mount, readOnly: false }],
        logConfiguration: {
          logDriver: "awslogs",
          options: {
            "awslogs-group": $log_group,
            "awslogs-region": $region,
            "awslogs-stream-prefix": "wiki-sync",
            "awslogs-create-group": "true"
          }
        }
      }]
    }' > "$task_def"

  sync_arn="$(aws ecs register-task-definition \
    --cli-input-json "file://${task_def}" \
    --region "$AWS_REGION" \
    --query 'taskDefinition.taskDefinitionArn' --output text)"
  rm -f "$task_def"

  task_arn="$(aws ecs run-task \
    --cluster "$CLUSTER" \
    --task-definition "$sync_arn" \
    --launch-type FARGATE \
    --platform-version 1.4.0 \
    --network-configuration "awsvpcConfiguration={subnets=[${SUBNET_ID}],securityGroups=[${SG_ID}],assignPublicIp=ENABLED}" \
    --region "$AWS_REGION" \
    --query 'tasks[0].taskArn' --output text)"

  log "Waiting for wiki sync task to finish..."
  aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$task_arn" --region "$AWS_REGION"

  exit_code="$(aws_value aws ecs describe-tasks \
    --cluster "$CLUSTER" --tasks "$task_arn" \
    --query 'tasks[0].containers[0].exitCode' --output text --region "$AWS_REGION")"

  if [[ "$exit_code" != "0" ]]; then
    local reason
    reason="$(aws_value aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$task_arn" \
      --query 'tasks[0].stoppedReason' --output text --region "$AWS_REGION")"
    echo "Wiki sync task failed (exit=${exit_code:-unknown}): ${reason:-no reason given}" >&2
    echo "Logs: aws logs tail ${LOG_GROUP} --region ${AWS_REGION}" >&2
    exit 1
  fi

  log "Wiki synced to EFS."
  NEED_WIKI_SYNC=no
}

lookup_wiki_efs_ids() {
  WIKI_FS_ID=""
  WIKI_AP_ID=""
  if [[ "$WIKI_EFS" != "yes" ]]; then
    return 0
  fi

  WIKI_FS_ID="$(aws_value aws efs describe-file-systems \
    --creation-token "$WIKI_EFS_TOKEN" \
    --query 'FileSystems[0].FileSystemId' --output text --region "$AWS_REGION")"
  if [[ -z "$WIKI_FS_ID" ]]; then
    return 1
  fi

  WIKI_AP_ID="$(aws_value aws efs describe-access-points \
    --file-system-id "$WIKI_FS_ID" \
    --query "AccessPoints[?Name=='${WIKI_EFS_AP_NAME}'].AccessPointId | [0]" \
    --output text --region "$AWS_REGION")"
  if [[ -z "$WIKI_AP_ID" ]]; then
    return 1
  fi
}

resolve_wiki_efs_ids() {
  if lookup_wiki_efs_ids; then
    return 0
  fi

  if [[ "$WIKI_EFS" != "yes" ]]; then
    echo "WIKI_EFS=no; nothing to sync to EFS." >&2
  elif [[ -z "$WIKI_FS_ID" ]]; then
    echo "No wiki EFS found (token=${WIKI_EFS_TOKEN}). Run ./deploy/deploy.sh --bootstrap-only first." >&2
  else
    echo "No wiki EFS access point found (name=${WIKI_EFS_AP_NAME}). Run ./deploy/deploy.sh --bootstrap-only first." >&2
  fi
  exit 1
}

sync_wiki_only() {
  require_cmd aws
  require_cmd jq
  require_cmd docker

  resolve_account_id
  resolve_wiki_efs_ids
  if [[ -z "${SUBNET_ID:-}" || -z "${SG_ID:-}" ]]; then
    resolve_network
  fi

  build_and_push_image
  sync_wiki_to_efs
  log "Wiki sync complete (ECS service unchanged)."
}

register_task_definition() {
  local rendered
  rendered="$(mktemp)"
  render_task_definition "$rendered"

  TASK_ARN="$(aws ecs register-task-definition \
    --cli-input-json "file://${rendered}" \
    --region "$AWS_REGION" \
    --query 'taskDefinition.taskDefinitionArn' \
    --output text)"
  rm -f "$rendered"
  log "Registered task definition: ${TASK_ARN}"
}

ensure_ecs_service() {
  local status
  status="$(aws ecs describe-services \
    --cluster "$CLUSTER" \
    --services "$SERVICE" \
    --region "$AWS_REGION" \
    --query 'services[0].status' \
    --output text 2>/dev/null || echo NONE)"

  if [[ "$status" == "ACTIVE" ]]; then
    log "Updating ECS service ${SERVICE}..."
    aws ecs update-service \
      --cluster "$CLUSTER" \
      --service "$SERVICE" \
      --task-definition "$TASK_ARN" \
      --desired-count 1 \
      --force-new-deployment \
      --region "$AWS_REGION" \
      --query 'service.serviceName' \
      --output text
    return 0
  fi

  log "Creating ECS service ${SERVICE}..."
  aws ecs create-service \
    --cluster "$CLUSTER" \
    --service-name "$SERVICE" \
    --task-definition "$TASK_ARN" \
    --desired-count 1 \
    --launch-type FARGATE \
    --platform-version 1.4.0 \
    --network-configuration "awsvpcConfiguration={subnets=[${SUBNET_ID}],securityGroups=[${SG_ID}],assignPublicIp=ENABLED}" \
    --region "$AWS_REGION" \
    --query 'service.serviceName' \
    --output text
}

deploy_app() {
  build_and_push_image
  if [[ "$SYNC_WIKI" == "yes" || "$NEED_WIKI_SYNC" == "yes" ]]; then
    sync_wiki_to_efs
  fi
  register_task_definition
  ensure_ecs_service
  log "Deploy complete."
  log "Tail logs: aws logs tail ${LOG_GROUP} --follow --region ${AWS_REGION}"
}

main() {
  if [[ "$SYNC_WIKI_ONLY" == "yes" && "$BOOTSTRAP_ONLY" == "yes" ]]; then
    echo "Cannot combine --sync-wiki-only with --bootstrap-only." >&2
    exit 1
  fi

  if [[ "$SYNC_WIKI_ONLY" == "yes" ]]; then
    sync_wiki_only
    exit 0
  fi

  if [[ "$SKIP_BOOTSTRAP" != "yes" ]]; then
    bootstrap_aws
  else
    require_cmd aws
    require_cmd jq
    resolve_account_id
  fi

  if [[ "$BOOTSTRAP_ONLY" == "yes" ]]; then
    log "Bootstrap only; skipping Docker build and ECS deploy."
    exit 0
  fi

  if [[ "$SKIP_BOOTSTRAP" == "yes" ]]; then
    SUBNET_ID="${SUBNET_ID:-}"
    SG_ID="${SG_ID:-}"
    lookup_wiki_efs_ids || true
  fi

  deploy_app
}

main "$@"
