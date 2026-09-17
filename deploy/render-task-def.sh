#!/usr/bin/env bash
set -euo pipefail

# Render the ECS task definition: substitute account/region, set the image, and
# attach the water-knowledge EFS volume when that filesystem exists.
#
# Shared by deploy/deploy.sh and .github/workflows/deploy.yml on purpose. Both
# render the task definition from the same base JSON, so if only one of them
# knew about EFS, the other would silently deregister the volume on its next
# deploy and the agent would fall back to the copy baked into the image.
#
# Usage: deploy/render-task-def.sh <output-file> <image-uri>

OUTPUT_FILE="${1:?usage: render-task-def.sh <output-file> <image-uri>}"
IMAGE="${2:?usage: render-task-def.sh <output-file> <image-uri>}"

AWS_REGION="${AWS_REGION:-us-east-1}"
CONTAINER_NAME="${CONTAINER_NAME:-slack-ai-assistant}"
WIKI_EFS_TOKEN="${WIKI_EFS_TOKEN:-slack-ai-assistant-wiki}"
WIKI_EFS_AP_NAME="${WIKI_EFS_AP_NAME:-slack-ai-assistant-wiki-ap}"
# WikiTool appends "wiki" to its root, so the pages live at <mount>/wiki/.
WIKI_MOUNT_PATH="${WIKI_MOUNT_PATH:-/mnt/water_knowledge}"
WIKI_VOLUME_NAME="water-knowledge"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_JSON="${ROOT_DIR}/deploy/ecs-task-definition.json"

ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"

# Empty string rather than the literal "None" the CLI prints for a missing value.
aws_value() {
  local out
  out="$("$@" 2>/dev/null || true)"
  [[ "$out" == "None" ]] && out=""
  printf '%s' "$out"
}

lookup_wiki_efs() {
  WIKI_FS_ID="$(aws_value aws efs describe-file-systems \
    --creation-token "$WIKI_EFS_TOKEN" \
    --query 'FileSystems[0].FileSystemId' \
    --output text \
    --region "$AWS_REGION")"

  WIKI_AP_ID=""
  if [[ -n "$WIKI_FS_ID" ]]; then
    WIKI_AP_ID="$(aws_value aws efs describe-access-points \
      --file-system-id "$WIKI_FS_ID" \
      --query "AccessPoints[?Name=='${WIKI_EFS_AP_NAME}'].AccessPointId | [0]" \
      --output text \
      --region "$AWS_REGION")"
  fi
}

sed \
  -e "s/ACCOUNT_ID/${ACCOUNT_ID}/g" \
  -e "s/us-east-1/${AWS_REGION}/g" \
  "$BASE_JSON" > "$OUTPUT_FILE"

jq --arg IMAGE "$IMAGE" --arg NAME "$CONTAINER_NAME" \
  '.containerDefinitions |= map(if .name == $NAME then .image = $IMAGE else . end)' \
  "$OUTPUT_FILE" > "${OUTPUT_FILE}.tmp"
mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"

lookup_wiki_efs

if [[ -z "$WIKI_FS_ID" || -z "$WIKI_AP_ID" ]]; then
  # "Not found" and "the lookup failed" look identical here (missing
  # elasticfilesystem:Describe* on the deploy credentials, say). If the live task
  # definition already mounts EFS, dropping it now would be a silent regression
  # that takes the wiki offline, so refuse instead of guessing.
  LIVE_VOLUME="$(aws ecs describe-task-definition \
    --task-definition "${ECS_TASK_FAMILY:-slack-ai-assistant}" \
    --query 'taskDefinition.volumes[?efsVolumeConfiguration].name | [0]' \
    --output text --region "$AWS_REGION" 2>/dev/null || true)"

  if [[ -n "$LIVE_VOLUME" && "$LIVE_VOLUME" != "None" ]]; then
    echo "render-task-def: the deployed task definition mounts EFS volume '${LIVE_VOLUME}', but no filesystem resolved for token '${WIKI_EFS_TOKEN}'." >&2
    echo "Refusing to deploy a task definition that would unmount the wiki." >&2
    echo "Check that these credentials allow elasticfilesystem:DescribeFileSystems and DescribeAccessPoints, or set WIKI_EFS_TOKEN correctly." >&2
    exit 1
  fi

  echo "render-task-def: no wiki EFS found (token=${WIKI_EFS_TOKEN}); the agent will read the wiki baked into the image." >&2
  exit 0
fi

echo "render-task-def: mounting EFS ${WIKI_FS_ID} (access point ${WIKI_AP_ID}) at ${WIKI_MOUNT_PATH}" >&2

jq \
  --arg NAME "$CONTAINER_NAME" \
  --arg VOLUME "$WIKI_VOLUME_NAME" \
  --arg FS_ID "$WIKI_FS_ID" \
  --arg AP_ID "$WIKI_AP_ID" \
  --arg MOUNT "$WIKI_MOUNT_PATH" \
  '
  .volumes = [{
    name: $VOLUME,
    efsVolumeConfiguration: {
      fileSystemId: $FS_ID,
      transitEncryption: "ENABLED",
      authorizationConfig: { accessPointId: $AP_ID, iam: "ENABLED" }
    }
  }]
  | .containerDefinitions |= map(
      if .name == $NAME then
        .mountPoints = [{ sourceVolume: $VOLUME, containerPath: $MOUNT, readOnly: true }]
        | .environment = (
            ((.environment // []) | map(select(.name != "WATER_WIKI_ROOT")))
            + [{ name: "WATER_WIKI_ROOT", value: $MOUNT }]
          )
      else . end
    )
  ' \
  "$OUTPUT_FILE" > "${OUTPUT_FILE}.tmp"
mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"
