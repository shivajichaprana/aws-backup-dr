"""Automated AWS Backup restore-test worker.

This Lambda is the single compute unit behind the weekly restore-testing
Step Functions workflow defined in ``terraform/restore-workflow.tf``. A backup
is only as good as your ability to restore it, so this job continuously proves
that recovery points are usable by actually restoring one and validating the
result, then tearing it down to avoid cost.

The function is *action dispatched*: the state machine invokes it once per
state, passing an ``action`` field. Each action is a small, independently
testable unit of work:

    select   -> pick a random recent recovery point from the vault
    restore  -> start a restore job into the sandbox account
    status   -> poll the restore job until terminal
    verify   -> run resource-type-specific integrity checks
    teardown -> delete the restored resource
    report   -> emit CloudWatch metrics summarising the test

Cross-account restores are supported: when ``RESTORE_TEST_ROLE_ARN`` is set the
worker assumes that role (expected to live in an isolated sandbox account) for
all data-plane calls (EC2/RDS/DynamoDB/EFS) and for the restore job itself.
When it is unset, the worker operates in its own account, which is useful for
local development and single-account deployments.
"""

from __future__ import annotations

import datetime as _dt
import logging
import os
import random
import time
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

# --------------------------------------------------------------------------- #
# Logging
# --------------------------------------------------------------------------- #
logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO").upper())

# --------------------------------------------------------------------------- #
# Configuration (resolved from environment at cold start)
# --------------------------------------------------------------------------- #
BACKUP_VAULT_NAME = os.environ.get("BACKUP_VAULT_NAME", "")
# IAM role AWS Backup assumes to perform the restore (the project backup role).
BACKUP_RESTORE_ROLE_ARN = os.environ.get("BACKUP_RESTORE_ROLE_ARN", "")
# Optional cross-account role assumed for all sandbox data-plane operations.
RESTORE_TEST_ROLE_ARN = os.environ.get("RESTORE_TEST_ROLE_ARN", "")
LOOKBACK_DAYS = int(os.environ.get("LOOKBACK_DAYS", "7"))
CW_NAMESPACE = os.environ.get("CW_NAMESPACE", "BackupDR/RestoreTesting")
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN", "")
ENVIRONMENT = os.environ.get("ENVIRONMENT", "production")
# Comma-separated allow-list of resource types eligible for restore testing.
SUPPORTED_RESOURCE_TYPES = [
    t.strip()
    for t in os.environ.get(
        "SUPPORTED_RESOURCE_TYPES", "EBS,RDS,DynamoDB,EFS"
    ).split(",")
    if t.strip()
]

_BOTO_CONFIG = Config(retries={"max_attempts": 5, "mode": "standard"})


class RestoreTestError(Exception):
    """Raised when a restore test cannot proceed or fails verification.

    Raising this (rather than returning an error dict) lets the Step Functions
    state machine catch the failure and route to the teardown + notify path.
    """


@dataclass
class TestContext:
    """Mutable state threaded through the workflow via the SFN event payload."""

    test_id: str
    resource_type: str = ""
    recovery_point_arn: str = ""
    source_resource_arn: str = ""
    restore_job_id: str = ""
    restored_resource_arn: str = ""
    status: str = "PENDING"
    started_at: str = ""
    details: Dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_event(cls, event: Dict[str, Any]) -> "TestContext":
        ctx = event.get("context", {})
        return cls(
            test_id=ctx.get("test_id") or _new_test_id(),
            resource_type=ctx.get("resource_type", ""),
            recovery_point_arn=ctx.get("recovery_point_arn", ""),
            source_resource_arn=ctx.get("source_resource_arn", ""),
            restore_job_id=ctx.get("restore_job_id", ""),
            restored_resource_arn=ctx.get("restored_resource_arn", ""),
            status=ctx.get("status", "PENDING"),
            started_at=ctx.get("started_at", ""),
            details=ctx.get("details", {}),
        )

    def to_dict(self) -> Dict[str, Any]:
        return {
            "test_id": self.test_id,
            "resource_type": self.resource_type,
            "recovery_point_arn": self.recovery_point_arn,
            "source_resource_arn": self.source_resource_arn,
            "restore_job_id": self.restore_job_id,
            "restored_resource_arn": self.restored_resource_arn,
            "status": self.status,
            "started_at": self.started_at,
            "details": self.details,
        }


# --------------------------------------------------------------------------- #
# Session / client helpers
# --------------------------------------------------------------------------- #
def _local_session() -> boto3.session.Session:
    return boto3.session.Session()


def _sandbox_session() -> boto3.session.Session:
    """Return a session for the sandbox account.

    Assumes ``RESTORE_TEST_ROLE_ARN`` when provided so that restores never touch
    production resources; otherwise falls back to the current account.
    """
    if not RESTORE_TEST_ROLE_ARN:
        return _local_session()

    sts = _local_session().client("sts", config=_BOTO_CONFIG)
    resp = sts.assume_role(
        RoleArn=RESTORE_TEST_ROLE_ARN,
        RoleSessionName=f"restore-test-{int(time.time())}",
        DurationSeconds=3600,
    )
    creds = resp["Credentials"]
    return boto3.session.Session(
        aws_access_key_id=creds["AccessKeyId"],
        aws_secret_access_key=creds["SecretAccessKey"],
        aws_session_token=creds["SessionToken"],
    )


def _client(service: str, *, sandbox: bool = False):
    session = _sandbox_session() if sandbox else _local_session()
    return session.client(service, config=_BOTO_CONFIG)


# --------------------------------------------------------------------------- #
# Small utilities
# --------------------------------------------------------------------------- #
def _new_test_id() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("rt-%Y%m%d-%H%M%S")


def _utcnow() -> _dt.datetime:
    return _dt.datetime.now(_dt.timezone.utc)


def _parse_iso(value: str) -> Optional[_dt.datetime]:
    if not value:
        return None
    try:
        return _dt.datetime.fromisoformat(value)
    except ValueError:
        return None


def _resource_type_from_arn(arn: str) -> str:
    """Best-effort mapping of a resource ARN to an AWS Backup resource type."""
    if ":ec2:" in arn and ":volume/" in arn:
        return "EBS"
    if ":rds:" in arn:
        return "RDS"
    if ":dynamodb:" in arn:
        return "DynamoDB"
    if ":elasticfilesystem:" in arn:
        return "EFS"
    return "Unknown"


# --------------------------------------------------------------------------- #
# Action: select a recovery point
# --------------------------------------------------------------------------- #
def select_recovery_point(ctx: TestContext) -> Dict[str, Any]:
    """Pick a random recovery point created within the look-back window.

    Randomising the choice means that, over many weeks, the whole spread of
    recovery points and resource types gets exercised rather than always the
    newest one.
    """
    if not BACKUP_VAULT_NAME:
        raise RestoreTestError("BACKUP_VAULT_NAME is not configured")

    backup = _client("backup")
    cutoff = _utcnow() - _dt.timedelta(days=LOOKBACK_DAYS)
    candidates: List[Dict[str, Any]] = []

    paginator = backup.get_paginator("list_recovery_points_by_backup_vault")
    page_kwargs = {"BackupVaultName": BACKUP_VAULT_NAME}
    for page in paginator.paginate(**page_kwargs):
        for rp in page.get("RecoveryPoints", []):
            created = rp.get("CreationDate")
            if created and created.replace(tzinfo=_dt.timezone.utc) < cutoff:
                continue
            if rp.get("Status") != "COMPLETED":
                continue
            resource_type = rp.get("ResourceType", "")
            if resource_type not in SUPPORTED_RESOURCE_TYPES:
                continue
            candidates.append(rp)

    logger.info(
        "Found %d eligible recovery points in vault %s (look-back %dd)",
        len(candidates),
        BACKUP_VAULT_NAME,
        LOOKBACK_DAYS,
    )

    if not candidates:
        ctx.status = "NO_RECOVERY_POINTS"
        _emit_metric("EligibleRecoveryPoints", 0)
        return {"action_result": "no_recovery_points", "context": ctx.to_dict()}

    chosen = random.choice(candidates)
    ctx.recovery_point_arn = chosen["RecoveryPointArn"]
    ctx.resource_type = chosen.get("ResourceType", "")
    ctx.source_resource_arn = chosen.get("ResourceArn", "")
    ctx.status = "SELECTED"
    ctx.started_at = _utcnow().isoformat()
    ctx.details["recovery_point_created"] = str(chosen.get("CreationDate", ""))
    ctx.details["backup_size_bytes"] = chosen.get("BackupSizeInBytes", 0)

    _emit_metric("EligibleRecoveryPoints", len(candidates))
    logger.info(
        "Selected recovery point %s (type=%s)",
        ctx.recovery_point_arn,
        ctx.resource_type,
    )
    return {"action_result": "selected", "context": ctx.to_dict()}


# --------------------------------------------------------------------------- #
# Action: start the restore job
# --------------------------------------------------------------------------- #
def _restore_metadata(ctx: TestContext) -> Dict[str, str]:
    """Build the resource-type-specific metadata for ``start_restore_job``.

    Restored resources are renamed/isolated and tagged so that the teardown
    step (and any human reviewer) can unambiguously identify test artefacts.
    """
    suffix = ctx.test_id.replace("rt-", "").replace("-", "")[:12]
    rtype = ctx.resource_type

    if rtype == "EBS":
        return {
            # Region restored into is inferred from the recovery point.
            "encrypted": "true",
            "volumeType": "gp3",
        }
    if rtype == "RDS":
        return {
            "DBInstanceIdentifier": f"restoretest-{suffix}",
            "DBInstanceClass": "db.t3.micro",
            "MultiAZ": "false",
            "PubliclyAccessible": "false",
            "DeletionProtection": "false",
        }
    if rtype == "DynamoDB":
        return {"targetTableName": f"restoretest-{suffix}"}
    if rtype == "EFS":
        return {
            "newFileSystem": "true",
            "Encrypted": "true",
            "PerformanceMode": "generalPurpose",
            "CreationToken": f"restoretest-{suffix}",
        }
    raise RestoreTestError(f"Unsupported resource type for restore: {rtype}")


def start_restore(ctx: TestContext) -> Dict[str, Any]:
    """Kick off the restore job into the sandbox account."""
    if not ctx.recovery_point_arn:
        raise RestoreTestError("No recovery_point_arn in context")
    if not BACKUP_RESTORE_ROLE_ARN:
        raise RestoreTestError("BACKUP_RESTORE_ROLE_ARN is not configured")

    backup = _client("backup", sandbox=bool(RESTORE_TEST_ROLE_ARN))
    metadata = _restore_metadata(ctx)

    try:
        resp = backup.start_restore_job(
            RecoveryPointArn=ctx.recovery_point_arn,
            Metadata=metadata,
            IamRoleArn=BACKUP_RESTORE_ROLE_ARN,
            ResourceType=ctx.resource_type,
            IdempotencyToken=ctx.test_id,
        )
    except ClientError as exc:
        raise RestoreTestError(
            f"start_restore_job failed: {exc.response['Error']['Message']}"
        ) from exc

    ctx.restore_job_id = resp["RestoreJobId"]
    ctx.status = "RESTORING"
    logger.info("Started restore job %s", ctx.restore_job_id)
    return {"action_result": "restoring", "context": ctx.to_dict()}


# --------------------------------------------------------------------------- #
# Action: poll restore job status
# --------------------------------------------------------------------------- #
_TERMINAL_OK = {"COMPLETED"}
_TERMINAL_FAIL = {"ABORTED", "FAILED"}


def check_restore_status(ctx: TestContext) -> Dict[str, Any]:
    """Describe the restore job and surface a terminal/pending verdict."""
    if not ctx.restore_job_id:
        raise RestoreTestError("No restore_job_id in context")

    backup = _client("backup", sandbox=bool(RESTORE_TEST_ROLE_ARN))
    resp = backup.describe_restore_job(RestoreJobId=ctx.restore_job_id)
    job_status = resp.get("Status", "UNKNOWN")
    ctx.details["restore_status_message"] = resp.get("StatusMessage", "")
    # Bounded-loop guard: the state machine inspects poll_count to stop waiting
    # forever on a stuck restore job.
    ctx.details["poll_count"] = int(ctx.details.get("poll_count", 0)) + 1

    if job_status in _TERMINAL_OK:
        ctx.restored_resource_arn = resp.get("CreatedResourceArn", "")
        ctx.status = "RESTORED"
        logger.info(
            "Restore job %s completed -> %s",
            ctx.restore_job_id,
            ctx.restored_resource_arn,
        )
    elif job_status in _TERMINAL_FAIL:
        ctx.status = "RESTORE_FAILED"
        raise RestoreTestError(
            f"Restore job {ctx.restore_job_id} ended {job_status}: "
            f"{resp.get('StatusMessage', '')}"
        )
    else:
        ctx.status = "RESTORING"

    return {
        "action_result": job_status,
        "is_complete": job_status in _TERMINAL_OK,
        "context": ctx.to_dict(),
    }


# --------------------------------------------------------------------------- #
# Action: verify the restored resource
# --------------------------------------------------------------------------- #
def _verify_ebs(arn: str, sess_client: Callable) -> Dict[str, Any]:
    volume_id = arn.split("/")[-1]
    ec2 = sess_client("ec2")
    vol = ec2.describe_volumes(VolumeIds=[volume_id])["Volumes"][0]
    healthy = vol["State"] in ("available", "in-use")
    return {
        "healthy": healthy,
        "checks": {
            "state": vol["State"],
            "size_gib": vol["Size"],
            "encrypted": vol["Encrypted"],
        },
    }


def _verify_rds(arn: str, sess_client: Callable) -> Dict[str, Any]:
    db_id = arn.split(":")[-1]
    rds = sess_client("rds")
    db = rds.describe_db_instances(DBInstanceIdentifier=db_id)["DBInstances"][0]
    healthy = db["DBInstanceStatus"] in ("available", "backing-up")
    return {
        "healthy": healthy,
        "checks": {
            "status": db["DBInstanceStatus"],
            "engine": db.get("Engine"),
            "allocated_storage_gib": db.get("AllocatedStorage"),
        },
    }


def _verify_dynamodb(arn: str, sess_client: Callable) -> Dict[str, Any]:
    table_name = arn.split("/")[-1]
    ddb = sess_client("dynamodb")
    table = ddb.describe_table(TableName=table_name)["Table"]
    healthy = table["TableStatus"] == "ACTIVE"
    return {
        "healthy": healthy,
        "checks": {
            "status": table["TableStatus"],
            "item_count": table.get("ItemCount", 0),
            "size_bytes": table.get("TableSizeBytes", 0),
        },
    }


def _verify_efs(arn: str, sess_client: Callable) -> Dict[str, Any]:
    fs_id = arn.split("/")[-1]
    efs = sess_client("efs")
    fs = efs.describe_file_systems(FileSystemId=fs_id)["FileSystems"][0]
    healthy = fs["LifeCycleState"] == "available"
    return {
        "healthy": healthy,
        "checks": {
            "lifecycle_state": fs["LifeCycleState"],
            "size_bytes": fs.get("SizeInBytes", {}).get("Value", 0),
            "encrypted": fs.get("Encrypted", False),
        },
    }


_VERIFIERS: Dict[str, Callable[[str, Callable], Dict[str, Any]]] = {
    "EBS": _verify_ebs,
    "RDS": _verify_rds,
    "DynamoDB": _verify_dynamodb,
    "EFS": _verify_efs,
}


def verify_integrity(ctx: TestContext) -> Dict[str, Any]:
    """Run resource-type-specific integrity checks on the restored resource."""
    if not ctx.restored_resource_arn:
        raise RestoreTestError("No restored_resource_arn to verify")

    verifier = _VERIFIERS.get(ctx.resource_type)
    if verifier is None:
        raise RestoreTestError(
            f"No verifier registered for {ctx.resource_type}"
        )

    def sess_client(service: str):
        return _client(service, sandbox=bool(RESTORE_TEST_ROLE_ARN))

    result = verifier(ctx.restored_resource_arn, sess_client)
    ctx.details["verification"] = result["checks"]
    ctx.status = "VERIFIED" if result["healthy"] else "VERIFICATION_FAILED"

    if not result["healthy"]:
        raise RestoreTestError(
            f"Integrity check failed for {ctx.restored_resource_arn}: "
            f"{result['checks']}"
        )

    logger.info("Verified restored resource %s", ctx.restored_resource_arn)
    return {"action_result": "verified", "context": ctx.to_dict()}


# --------------------------------------------------------------------------- #
# Action: teardown
# --------------------------------------------------------------------------- #
def _teardown_ebs(arn: str, sess_client: Callable) -> None:
    sess_client("ec2").delete_volume(VolumeId=arn.split("/")[-1])


def _teardown_rds(arn: str, sess_client: Callable) -> None:
    sess_client("rds").delete_db_instance(
        DBInstanceIdentifier=arn.split(":")[-1],
        SkipFinalSnapshot=True,
        DeleteAutomatedBackups=True,
    )


def _teardown_dynamodb(arn: str, sess_client: Callable) -> None:
    sess_client("dynamodb").delete_table(TableName=arn.split("/")[-1])


def _teardown_efs(arn: str, sess_client: Callable) -> None:
    sess_client("efs").delete_file_system(FileSystemId=arn.split("/")[-1])


_TEARDOWN: Dict[str, Callable[[str, Callable], None]] = {
    "EBS": _teardown_ebs,
    "RDS": _teardown_rds,
    "DynamoDB": _teardown_dynamodb,
    "EFS": _teardown_efs,
}


def teardown(ctx: TestContext) -> Dict[str, Any]:
    """Delete the restored resource so the test leaves no cost footprint.

    Teardown is best-effort and idempotent: a missing resource is treated as
    already-cleaned-up rather than an error, because this step also runs on the
    failure path where the resource may never have been created.
    """
    if not ctx.restored_resource_arn:
        logger.info("Nothing to tear down (no restored resource)")
        ctx.details["teardown"] = "skipped"
        return {"action_result": "teardown_skipped", "context": ctx.to_dict()}

    handler = _TEARDOWN.get(ctx.resource_type)
    if handler is None:
        logger.warning("No teardown handler for %s", ctx.resource_type)
        ctx.details["teardown"] = "no_handler"
        return {"action_result": "teardown_no_handler", "context": ctx.to_dict()}

    def sess_client(service: str):
        return _client(service, sandbox=bool(RESTORE_TEST_ROLE_ARN))

    try:
        handler(ctx.restored_resource_arn, sess_client)
        ctx.details["teardown"] = "deleted"
        logger.info("Tore down %s", ctx.restored_resource_arn)
    except ClientError as exc:
        code = exc.response["Error"].get("Code", "")
        if code in ("ResourceNotFoundException", "InvalidVolume.NotFound",
                    "DBInstanceNotFound", "FileSystemNotFound"):
            ctx.details["teardown"] = "already_gone"
            logger.info("Resource already gone: %s", ctx.restored_resource_arn)
        else:
            ctx.details["teardown"] = f"error:{code}"
            logger.error("Teardown error (%s): %s", code, exc)
            # Surface teardown failures so the cost-leak gets a metric/alarm.
            _emit_metric("TeardownFailure", 1)
    return {"action_result": "teardown_done", "context": ctx.to_dict()}


# --------------------------------------------------------------------------- #
# Action: report metrics
# --------------------------------------------------------------------------- #
def _emit_metric(name: str, value: float, unit: str = "Count") -> None:
    """Publish a single CloudWatch metric, swallowing telemetry errors."""
    try:
        _client("cloudwatch").put_metric_data(
            Namespace=CW_NAMESPACE,
            MetricData=[
                {
                    "MetricName": name,
                    "Value": value,
                    "Unit": unit,
                    "Dimensions": [
                        {"Name": "Environment", "Value": ENVIRONMENT},
                    ],
                }
            ],
        )
    except ClientError as exc:  # pragma: no cover - telemetry must never fail us
        logger.warning("Failed to emit metric %s: %s", name, exc)


def report(ctx: TestContext) -> Dict[str, Any]:
    """Emit success/failure and duration metrics for the completed test."""
    succeeded = ctx.status in ("VERIFIED",)
    _emit_metric("RestoreTestSuccess", 1 if succeeded else 0)
    _emit_metric("RestoreTestFailure", 0 if succeeded else 1)

    started = _parse_iso(ctx.started_at)
    if started:
        duration = (_utcnow() - started).total_seconds()
        ctx.details["duration_seconds"] = round(duration, 1)
        _emit_metric("RestoreDurationSeconds", duration, unit="Seconds")

    summary = {
        "test_id": ctx.test_id,
        "resource_type": ctx.resource_type,
        "recovery_point_arn": ctx.recovery_point_arn,
        "succeeded": succeeded,
        "status": ctx.status,
        "details": ctx.details,
    }
    logger.info("Restore test summary: %s", summary)
    return {"action_result": "reported", "summary": summary,
            "context": ctx.to_dict()}


# --------------------------------------------------------------------------- #
# Dispatch
# --------------------------------------------------------------------------- #
_ACTIONS: Dict[str, Callable[[TestContext], Dict[str, Any]]] = {
    "select": select_recovery_point,
    "restore": start_restore,
    "status": check_restore_status,
    "verify": verify_integrity,
    "teardown": teardown,
    "report": report,
}


def handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """Lambda entry point.

    Args:
        event: ``{"action": "<action>", "context": {<TestContext fields>}}``.
            ``context`` is omitted on the first (``select``) invocation.
        context: Lambda runtime context (unused).

    Returns:
        A dict with ``action_result`` and the updated ``context`` so the state
        machine can thread state between invocations.
    """
    action = event.get("action")
    if action not in _ACTIONS:
        raise RestoreTestError(
            f"Unknown action '{action}'. Valid: {sorted(_ACTIONS)}"
        )

    ctx = TestContext.from_event(event)
    logger.info("Action=%s test_id=%s status=%s", action, ctx.test_id, ctx.status)
    return _ACTIONS[action](ctx)
