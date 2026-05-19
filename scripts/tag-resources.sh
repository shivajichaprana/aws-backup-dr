#!/usr/bin/env bash
# =============================================================================
# tag-resources.sh — Tag AWS resources for inclusion in backup plans
# =============================================================================
# Usage:
#   ./scripts/tag-resources.sh [standard|critical] <resource-arn> [<resource-arn>...]
#
# Examples:
#   ./scripts/tag-resources.sh standard arn:aws:ec2:us-east-1:123456789012:volume/vol-abc123
#   ./scripts/tag-resources.sh critical arn:aws:rds:us-east-1:123456789012:db:mydb
#
# Requirements: aws CLI, jq
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
RED=$(tput setaf 1 2>/dev/null || true)
GREEN=$(tput setaf 2 2>/dev/null || true)
YELLOW=$(tput setaf 3 2>/dev/null || true)
RESET=$(tput sgr0 2>/dev/null || true)

info()    { echo "${GREEN}[INFO]${RESET}  $*"; }
warn()    { echo "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo "${RED}[ERROR]${RESET} $*" >&2; }

usage() {
  cat << USAGE
Usage: $(basename "$0") <tier> <resource-arn> [<resource-arn>...]

Tier:
  standard  — Daily backup (tag: Backup=true)
  critical  — Hourly + daily backup (tag: Backup=true, BackupTier=critical)

Resource ARN examples:
  arn:aws:ec2:REGION:ACCOUNT:volume/vol-xxxxxxxx       (EBS volume)
  arn:aws:rds:REGION:ACCOUNT:db:DBIDENTIFIER            (RDS instance)
  arn:aws:dynamodb:REGION:ACCOUNT:table/TABLENAME       (DynamoDB table)
  arn:aws:elasticfilesystem:REGION:ACCOUNT:file-system/fs-xxxxxxxx  (EFS)
  arn:aws:s3:::BUCKETNAME                               (S3 bucket)

USAGE
  exit 1
}

# ---------------------------------------------------------------------------
# Validate args
# ---------------------------------------------------------------------------
if [[ $# -lt 2 ]]; then
  usage
fi

TIER="$1"
shift

if [[ "$TIER" != "standard" && "$TIER" != "critical" ]]; then
  error "Invalid tier '${TIER}'. Must be 'standard' or 'critical'."
  usage
fi

# ---------------------------------------------------------------------------
# Check dependencies
# ---------------------------------------------------------------------------
for cmd in aws jq; do
  if ! command -v "$cmd" &>/dev/null; then
    error "Required command '${cmd}' not found. Please install it."
    exit 1
  fi
done

# Verify AWS credentials
if ! aws sts get-caller-identity &>/dev/null; then
  error "AWS credentials not configured. Run 'aws configure' or set env vars."
  exit 1
fi

# ---------------------------------------------------------------------------
# Tag resources
# ---------------------------------------------------------------------------
TAGGED=0
FAILED=0

for ARN in "$@"; do
  info "Tagging: ${ARN}"

  TAGS="Key=Backup,Value=true"
  if [[ "$TIER" == "critical" ]]; then
    TAGS="${TAGS} Key=BackupTier,Value=critical"
  fi

  # Determine resource type from ARN to use the right tag command
  SERVICE=$(echo "$ARN" | cut -d: -f3)

  case "$SERVICE" in
    s3)
      BUCKET=$(echo "$ARN" | sed 's|arn:aws:s3:::||')
      if aws s3api put-bucket-tagging \
          --bucket "$BUCKET" \
          --tagging "TagSet=[{Key=Backup,Value=true}$([ "$TIER" == "critical" ] && echo ",{Key=BackupTier,Value=critical}")]" 2>&1; then
        info "  ✓ Tagged S3 bucket: ${BUCKET}"
        ((TAGGED++))
      else
        warn "  ✗ Failed to tag S3 bucket: ${BUCKET}"
        ((FAILED++))
      fi
      ;;
    *)
      # Generic resource tagging via aws resourcegroupstaggingapi
      TAG_LIST="Key=Backup,Value=true"
      if [[ "$TIER" == "critical" ]]; then
        TAG_LIST="${TAG_LIST} Key=BackupTier,Value=critical"
      fi

      if aws resourcegroupstaggingapi tag-resources \
          --resource-arn-list "$ARN" \
          --tags "Backup=true$([ "$TIER" == "critical" ] && echo ",BackupTier=critical")" 2>&1; then
        info "  ✓ Tagged: ${ARN}"
        ((TAGGED++))
      else
        warn "  ✗ Failed to tag: ${ARN}"
        ((FAILED++))
      fi
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "Tagging complete"
info "  Tier:    ${TIER}"
info "  Tagged:  ${TAGGED}"
if [[ $FAILED -gt 0 ]]; then
  warn "  Failed:  ${FAILED} (check permissions and ARN format)"
  exit 1
fi
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
