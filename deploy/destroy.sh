#!/usr/bin/env bash
set -euo pipefail

# Tear down AWS resources created for this app.
#
# Usage:
#   ./deploy/destroy.sh --yes
#
# Optional flags:
#   --delete-secret     Also delete Secrets Manager secret
#   --delete-s3         Also empty and delete the S3 session bucket
#   --delete-iam-roles  Also delete custom IAM roles (not ecsTaskExecutionRole)
#   --delete-sg         Also delete slack-ai-assistant-sg security group
#   --delete-efs        Also delete the wiki EFS filesystem AND ITS CONTENTS
#
# Note: --delete-sg needs --delete-efs too if EFS exists, because the EFS
# security group references the task security group and blocks its deletion.
#
# Examples:
#   ./deploy/destroy.sh --yes
#   ./deploy/destroy.sh --yes --delete-secret --delete-s3

AWS_REGION="${AWS_REGION:-us-east-1}"
ECS_CLUSTER="${ECS_CLUSTER:-slack-ai-assistant}"
ECS_SERVICE="${ECS_SERVICE:-slack-ai-assistant}"
ECS_TASK_FAMILY="${ECS_TASK_FAMILY:-slack-ai-assistant}"
ECR_REPO="${ECR_REPO:-slack-ai-assistant}"
LOG_GROUP="${LOG_GROUP:-/ecs/slack-ai-assistant}"
SECRET_NAME="${SECRET_NAME:-slack-ai-assistant/prod}"
S3_BUCKET="${S3_BUCKET:-agenttutorial-sinha}"
TASK_ROLE="${TASK_ROLE:-slack-ai-assistant-task-role}"
SG_NAME="${SG_NAME:-slack-ai-assistant-sg}"
WIKI_EFS_TOKEN="${WIKI_EFS_TOKEN:-slack-ai-assistant-wiki}"
WIKI_EFS_SG_NAME="${WIKI_EFS_SG_NAME:-slack-ai-assistant-efs-sg}"

CONFIRM=no
DELETE_SECRET=no
DELETE_S3=no
DELETE_IAM_ROLES=no
DELETE_SG=no
DELETE_EFS=no

usage() {
  sed -n '3,22p' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)
      CONFIRM=yes
      shift
      ;;
    --delete-secret)
      DELETE_SECRET=yes
      shift
      ;;
    --delete-s3)
      DELETE_S3=yes
      shift
      ;;
    --delete-iam-roles)
      DELETE_IAM_ROLES=yes
      shift
      ;;
    --delete-sg)
      DELETE_SG=yes
      shift
      ;;
    --delete-efs)
      DELETE_EFS=yes
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$CONFIRM" != "yes" ]]; then
  echo "Refusing to delete AWS resources without --yes" >&2
  echo "Example: ./deploy/destroy.sh --yes" >&2
  exit 1
fi

echo "Region: ${AWS_REGION}"
echo "This will delete ECS service/cluster, ECR repo, log group, and task definitions."
echo "Optional: secret=${DELETE_SECRET}, s3=${DELETE_S3}, iam=${DELETE_IAM_ROLES}, sg=${DELETE_SG}, efs=${DELETE_EFS}"
echo

delete_ecs_service() {
  if ! aws ecs describe-services \
    --cluster "$ECS_CLUSTER" \
    --services "$ECS_SERVICE" \
    --region "$AWS_REGION" \
    --query 'services[0].status' \
    --output text 2>/dev/null | grep -qv None; then
    echo "ECS service not found: ${ECS_SERVICE}"
    return 0
  fi

  echo "Scaling ECS service to 0..."
  aws ecs update-service \
    --cluster "$ECS_CLUSTER" \
    --service "$ECS_SERVICE" \
    --desired-count 0 \
    --region "$AWS_REGION" \
    --output text >/dev/null || true

  echo "Deleting ECS service..."
  aws ecs delete-service \
    --cluster "$ECS_CLUSTER" \
    --service "$ECS_SERVICE" \
    --force \
    --region "$AWS_REGION" \
    --output text >/dev/null || true

  echo "Waiting for ECS service to become inactive..."
  aws ecs wait services-inactive \
    --cluster "$ECS_CLUSTER" \
    --services "$ECS_SERVICE" \
    --region "$AWS_REGION" 2>/dev/null || true
}

delete_ecs_cluster() {
  if ! aws ecs describe-clusters \
    --clusters "$ECS_CLUSTER" \
    --region "$AWS_REGION" \
    --query 'clusters[0].status' \
    --output text 2>/dev/null | grep -qv None; then
    echo "ECS cluster not found: ${ECS_CLUSTER}"
    return 0
  fi

  echo "Deleting ECS cluster..."
  aws ecs delete-cluster \
    --cluster "$ECS_CLUSTER" \
    --region "$AWS_REGION" \
    --output text >/dev/null || true
}

deregister_task_definitions() {
  echo "Deregistering task definitions for family ${ECS_TASK_FAMILY}..."
  TASK_DEFS="$(aws ecs list-task-definitions \
    --family-prefix "$ECS_TASK_FAMILY" \
    --region "$AWS_REGION" \
    --query 'taskDefinitionArns[]' \
    --output text 2>/dev/null || true)"

  if [[ -z "${TASK_DEFS// }" ]]; then
    echo "No task definitions found."
    return 0
  fi

  for TASK_DEF in $TASK_DEFS; do
    echo "  Deregistering ${TASK_DEF}"
    aws ecs deregister-task-definition \
      --task-definition "$TASK_DEF" \
      --region "$AWS_REGION" \
      --output text >/dev/null || true
  done
}

delete_ecr_repo() {
  if ! aws ecr describe-repositories \
    --repository-names "$ECR_REPO" \
    --region "$AWS_REGION" \
    --query 'repositories[0].repositoryName' \
    --output text 2>/dev/null | grep -qv None; then
    echo "ECR repository not found: ${ECR_REPO}"
    return 0
  fi

  echo "Deleting ECR repository ${ECR_REPO}..."
  aws ecr delete-repository \
    --repository-name "$ECR_REPO" \
    --force \
    --region "$AWS_REGION" \
    --output text >/dev/null
}

delete_log_group() {
  if aws logs describe-log-groups \
    --log-group-name-prefix "$LOG_GROUP" \
    --region "$AWS_REGION" \
    --query "logGroups[?logGroupName=='${LOG_GROUP}'].logGroupName" \
    --output text 2>/dev/null | grep -q "$LOG_GROUP"; then
    echo "Deleting CloudWatch log group ${LOG_GROUP}..."
    aws logs delete-log-group \
      --log-group-name "$LOG_GROUP" \
      --region "$AWS_REGION"
  else
    echo "CloudWatch log group not found: ${LOG_GROUP}"
  fi
}

delete_secret() {
  if [[ "$DELETE_SECRET" != "yes" ]]; then
    return 0
  fi

  echo "Deleting secret ${SECRET_NAME} in ${AWS_REGION}..."
  aws secretsmanager delete-secret \
    --secret-id "$SECRET_NAME" \
    --force-delete-without-recovery \
    --region "$AWS_REGION" \
    --output text >/dev/null 2>&1 || \
  aws secretsmanager delete-secret \
    --secret-id "$SECRET_NAME" \
    --force-delete-without-recovery \
    --region us-west-2 \
    --output text >/dev/null 2>&1 || \
  echo "Secret not found in us-east-1 or us-west-2."
}

delete_s3_bucket() {
  if [[ "$DELETE_S3" != "yes" ]]; then
    return 0
  fi

  if aws s3api head-bucket --bucket "$S3_BUCKET" 2>/dev/null; then
    echo "Emptying and deleting S3 bucket ${S3_BUCKET}..."
    aws s3 rm "s3://${S3_BUCKET}" --recursive
    aws s3api delete-bucket --bucket "$S3_BUCKET"
  else
    echo "S3 bucket not found: ${S3_BUCKET}"
  fi
}

aws_value() {
  local out
  out="$("$@" 2>/dev/null || true)"
  [[ "$out" == "None" ]] && out=""
  printf '%s' "$out"
}

delete_wiki_efs() {
  if [[ "$DELETE_EFS" != "yes" ]]; then
    return 0
  fi

  FS_ID="$(aws_value aws efs describe-file-systems \
    --creation-token "$WIKI_EFS_TOKEN" \
    --query 'FileSystems[0].FileSystemId' --output text --region "$AWS_REGION")"

  if [[ -z "$FS_ID" ]]; then
    echo "No wiki EFS found for token ${WIKI_EFS_TOKEN}."
  else
    echo "Deleting wiki EFS ${FS_ID} and its contents..."

    for AP_ID in $(aws_value aws efs describe-access-points --file-system-id "$FS_ID" \
      --query 'AccessPoints[].AccessPointId' --output text --region "$AWS_REGION"); do
      echo "  Deleting access point ${AP_ID}"
      aws efs delete-access-point --access-point-id "$AP_ID" --region "$AWS_REGION" || true
    done

    for MT_ID in $(aws_value aws efs describe-mount-targets --file-system-id "$FS_ID" \
      --query 'MountTargets[].MountTargetId' --output text --region "$AWS_REGION"); do
      echo "  Deleting mount target ${MT_ID}"
      aws efs delete-mount-target --mount-target-id "$MT_ID" --region "$AWS_REGION" || true
    done

    # The filesystem cannot go until every mount target has finished detaching.
    echo "  Waiting for mount targets to detach..."
    for _ in $(seq 1 60); do
      REMAINING="$(aws_value aws efs describe-mount-targets --file-system-id "$FS_ID" \
        --query 'length(MountTargets)' --output text --region "$AWS_REGION")"
      [[ -z "$REMAINING" || "$REMAINING" == "0" ]] && break
      sleep 5
    done

    aws efs delete-file-system --file-system-id "$FS_ID" --region "$AWS_REGION" \
      || echo "Could not delete filesystem ${FS_ID}; check for remaining mount targets."
  fi

  VPC_ID="$(aws_value aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' --output text --region "$AWS_REGION")"
  if [[ -z "$VPC_ID" ]]; then
    return 0
  fi

  EFS_SG_ID="$(aws_value aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${WIKI_EFS_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION")"

  if [[ -n "$EFS_SG_ID" ]]; then
    echo "Deleting security group ${WIKI_EFS_SG_NAME} (${EFS_SG_ID})..."
    for _ in $(seq 1 12); do
      aws ec2 delete-security-group --group-id "$EFS_SG_ID" --region "$AWS_REGION" 2>/dev/null && break
      sleep 5
    done
  fi
}

delete_custom_security_group() {
  if [[ "$DELETE_SG" != "yes" ]]; then
    return 0
  fi

  VPC_ID="$(aws ec2 describe-vpcs \
    --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || true)"

  if [[ -z "${VPC_ID:-}" || "$VPC_ID" == "None" ]]; then
    echo "Default VPC not found; skipping security group delete."
    return 0
  fi

  SG_ID="$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || true)"

  if [[ -n "${SG_ID:-}" && "$SG_ID" != "None" ]]; then
    echo "Deleting security group ${SG_NAME} (${SG_ID})..."
    if ! aws ec2 delete-security-group --group-id "$SG_ID" --region "$AWS_REGION"; then
      echo "Could not delete ${SG_NAME}. If the wiki EFS still exists, its security"
      echo "group references this one - rerun with --delete-efs."
    fi
  else
    echo "Security group not found: ${SG_NAME}"
  fi
}

delete_iam_roles() {
  if [[ "$DELETE_IAM_ROLES" != "yes" ]]; then
    return 0
  fi

  echo "Deleting IAM role ${TASK_ROLE}..."
  ATTACHED_POLICIES="$(aws iam list-attached-role-policies \
    --role-name "$TASK_ROLE" \
    --query 'AttachedPolicies[].PolicyArn' \
    --output text 2>/dev/null || true)"
  for POLICY_ARN in $ATTACHED_POLICIES; do
    aws iam detach-role-policy --role-name "$TASK_ROLE" --policy-arn "$POLICY_ARN" || true
  done

  INLINE_POLICIES="$(aws iam list-role-policies \
    --role-name "$TASK_ROLE" \
    --query 'PolicyNames[]' \
    --output text 2>/dev/null || true)"
  for POLICY_NAME in $INLINE_POLICIES; do
    aws iam delete-role-policy --role-name "$TASK_ROLE" --policy-name "$POLICY_NAME" || true
  done

  aws iam delete-role --role-name "$TASK_ROLE" 2>/dev/null || echo "Could not delete role ${TASK_ROLE}."
  echo "Note: ecsTaskExecutionRole was not deleted (may be shared)."
}

delete_ecs_service
delete_ecs_cluster
deregister_task_definitions
delete_ecr_repo
delete_log_group
delete_secret
delete_s3_bucket
delete_wiki_efs
delete_custom_security_group
delete_iam_roles

echo
echo "Destroy complete."
