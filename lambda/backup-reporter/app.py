"""Weekly AWS Backup status reporter.

This Lambda produces a periodic health report for the backup estate and
delivers it to an SNS topic (which fans out to email / Slack). It is the
operational counterpart to the restore-tester: where the restore-tester proves
that recovery points are *usable*, the reporter proves that backups are
*happening* — and surfaces failures early instead of at restore time.

The function looks back over a configurable window (default: the trailing 7
days) and aggregates three AWS Backup job families:

    backup jobs   -> were resources actually protected?
    copy jobs     -> did cross-region DR copies succeed?
    restore jobs  -> did the automated restore tests pass?

It computes per-family counts, a success rate, and a list of recent failures,
renders a human-readable report, publishes it to SNS, and emits CloudWatch
metrics so the report itself can be alarmed on (e.g. success rate < 100%).

Design note: all AWS access is confined to a thin gathering layer. The
aggregation and rendering logic (``summarize_jobs``, ``build_report``,
``format_report_text``) are pure functions over plain dictionaries, which keeps
them trivially unit-testable without mocking the AWS control plane.
"""

from __future__ import annotations

import datetime as _dt
import json
import logging
import os
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
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN", "")
CW_NAMESPACE = os.environ.get("CW_NAMESPACE", "BackupDR/Reporting")
REPORT_WINDOW_DAYS = int(os.environ.get("REPORT_WINDOW_DAYS", "7"))
ENVIRONMENT = os.environ.get("ENVIRONMENT", "production")
PROJECT_NAME = os.environ.get("PROJECT_NAME", "backup-dr")
# Cap the number of individual failures listed in the report body so a bad day
# does not produce a multi-megabyte SNS message.
MAX_FAILURES_LISTED = int(os.environ.get("MAX_FAILURES_LISTED", "20"))

_BOTO_CONFIG = Config(retries={"max_attempts": 5, "mode": "standard"})

# Terminal states that count as a hard failure for each job family. AWS Backup
# uses ``State`` for backup/copy jobs and ``Status`` for restore jobs; we treat
# them uniformly here.
FAILURE_STATES = {"FAILED", "ABORTED", "EXPIRED"}
SUCCESS_STATES = {"COMPLETED"}
PARTIAL_STATES = {"PARTIAL"}


class BackupReporterError(Exception):
    """Raised when the report cannot be gathered or delivered."""


# --------------------------------------------------------------------------- #
# Data model
# --------------------------------------------------------------------------- #
@dataclass
class JobSummary:
    """Aggregated counts for a single job family (backup, copy, or restore)."""

    family: str
    total: int = 0
    completed: int = 0
    failed: int = 0
    partial: int = 0
    in_progress: int = 0
    by_state: Dict[str, int] = field(default_factory=dict)
    failures: List[Dict[str, str]] = field(default_factory=list)

    @property
    def success_rate(self) -> float:
        """Completed jobs as a percentage of jobs that reached a terminal state.

        In-progress jobs are excluded from the denominator so a report run that
        catches a job mid-flight does not artificially depress the rate.
        """
        terminal = self.completed + self.failed + self.partial
        if terminal == 0:
            return 100.0
        return round(100.0 * self.completed / terminal, 2)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "family": self.family,
            "total": self.total,
            "completed": self.completed,
            "failed": self.failed,
            "partial": self.partial,
            "in_progress": self.in_progress,
            "success_rate": self.success_rate,
            "by_state": self.by_state,
            "failures": self.failures,
        }


@dataclass
class BackupReport:
    """The complete report for a single window."""

    account_id: str
    region: str
    environment: str
    window_start: str
    window_end: str
    summaries: List[JobSummary] = field(default_factory=list)

    @property
    def total_failures(self) -> int:
        return sum(s.failed for s in self.summaries)

    @property
    def healthy(self) -> bool:
        return self.total_failures == 0

    def to_dict(self) -> Dict[str, Any]:
        return {
            "account_id": self.account_id,
            "region": self.region,
            "environment": self.environment,
            "window_start": self.window_start,
            "window_end": self.window_end,
            "healthy": self.healthy,
            "total_failures": self.total_failures,
            "summaries": [s.to_dict() for s in self.summaries],
        }


# --------------------------------------------------------------------------- #
# AWS access — thin gathering layer (the only impure part of the module)
# --------------------------------------------------------------------------- #
def _client(service: str):
    return boto3.client(service, config=_BOTO_CONFIG)


def _paginate(
    fn: Callable[..., Dict[str, Any]],
    result_key: str,
    **kwargs: Any,
) -> List[Dict[str, Any]]:
    """Collect every page from a boto3 ``list_*`` call that uses NextToken.

    boto3's built-in paginators do not cover every AWS Backup list operation,
    so we implement the token loop directly to keep behaviour consistent.
    """
    items: List[Dict[str, Any]] = []
    token: Optional[str] = None
    while True:
        params = dict(kwargs)
        if token:
            params["NextToken"] = token
        resp = fn(**params)
        items.extend(resp.get(result_key, []))
        token = resp.get("NextToken")
        if not token:
            break
    return items


def gather_jobs(client, since: _dt.datetime) -> Dict[str, List[Dict[str, Any]]]:
    """Fetch backup, copy, and restore jobs created on/after ``since``.

    Each list operation is best-effort: a failure to read one family is logged
    and yields an empty list rather than aborting the whole report, so a
    transient API error never silences the entire backup estate.
    """
    families: Dict[str, List[Dict[str, Any]]] = {}

    def _safe(name: str, fn: Callable[..., Dict[str, Any]], key: str, **kw: Any):
        try:
            families[name] = _paginate(fn, key, **kw)
            logger.info("Gathered %d %s jobs", len(families[name]), name)
        except ClientError as exc:  # pragma: no cover - network error path
            logger.error("Failed to list %s jobs: %s", name, exc)
            families[name] = []

    _safe("backup", client.list_backup_jobs, "BackupJobs", ByCreatedAfter=since)
    _safe("copy", client.list_copy_jobs, "CopyJobs", ByCreatedAfter=since)
    _safe("restore", client.list_restore_jobs, "RestoreJobs", ByCreatedAfter=since)
    return families


# --------------------------------------------------------------------------- #
# Aggregation — pure functions
# --------------------------------------------------------------------------- #
def _job_state(job: Dict[str, Any]) -> str:
    """Normalise the terminal-state field across job families.

    Backup and copy jobs expose ``State``; restore jobs expose ``Status``.
    """
    return str(job.get("State") or job.get("Status") or "UNKNOWN").upper()


def _job_identifier(job: Dict[str, Any]) -> str:
    for key in ("BackupJobId", "CopyJobId", "RestoreJobId"):
        if job.get(key):
            return str(job[key])
    return "unknown"


def summarize_jobs(family: str, jobs: List[Dict[str, Any]]) -> JobSummary:
    """Aggregate a list of job dicts into a :class:`JobSummary`."""
    summary = JobSummary(family=family, total=len(jobs))
    for job in jobs:
        state = _job_state(job)
        summary.by_state[state] = summary.by_state.get(state, 0) + 1

        if state in SUCCESS_STATES:
            summary.completed += 1
        elif state in FAILURE_STATES:
            summary.failed += 1
            if len(summary.failures) < MAX_FAILURES_LISTED:
                summary.failures.append(
                    {
                        "id": _job_identifier(job),
                        "state": state,
                        "resource_type": str(job.get("ResourceType", "n/a")),
                        "resource_arn": str(job.get("ResourceArn", "n/a")),
                        "message": str(job.get("StatusMessage", ""))[:300],
                    }
                )
        elif state in PARTIAL_STATES:
            summary.partial += 1
        else:
            summary.in_progress += 1
    return summary


def build_report(
    account_id: str,
    region: str,
    families: Dict[str, List[Dict[str, Any]]],
    window_start: _dt.datetime,
    window_end: _dt.datetime,
) -> BackupReport:
    """Assemble a :class:`BackupReport` from gathered job families."""
    summaries = [
        summarize_jobs(family, families.get(family, []))
        for family in ("backup", "copy", "restore")
    ]
    return BackupReport(
        account_id=account_id,
        region=region,
        environment=ENVIRONMENT,
        window_start=window_start.isoformat(),
        window_end=window_end.isoformat(),
        summaries=summaries,
    )


# --------------------------------------------------------------------------- #
# Rendering — pure function
# --------------------------------------------------------------------------- #
def format_report_text(report: BackupReport) -> str:
    """Render a human-readable report body suitable for email / Slack."""
    status_word = "HEALTHY" if report.healthy else "ATTENTION REQUIRED"
    lines: List[str] = [
        f"AWS Backup Weekly Report — {status_word}",
        "=" * 56,
        f"Account     : {report.account_id}",
        f"Region      : {report.region}",
        f"Environment : {report.environment}",
        f"Window      : {report.window_start}  ->  {report.window_end}",
        "",
    ]

    labels = {
        "backup": "Backup jobs",
        "copy": "Cross-region copy jobs",
        "restore": "Restore (test) jobs",
    }
    for summary in report.summaries:
        label = labels.get(summary.family, summary.family)
        lines.append(f"{label}")
        lines.append("-" * 56)
        lines.append(
            f"  total={summary.total}  completed={summary.completed}  "
            f"failed={summary.failed}  partial={summary.partial}  "
            f"in_progress={summary.in_progress}"
        )
        lines.append(f"  success rate: {summary.success_rate}%")
        if summary.by_state:
            breakdown = ", ".join(
                f"{state}={count}" for state, count in sorted(summary.by_state.items())
            )
            lines.append(f"  by state: {breakdown}")
        if summary.failures:
            lines.append("  failures:")
            for fail in summary.failures:
                lines.append(
                    f"    - [{fail['state']}] {fail['resource_type']} "
                    f"{fail['id']} :: {fail['message'] or 'no message'}"
                )
        lines.append("")

    if report.healthy:
        lines.append("All backup, copy, and restore activity completed successfully.")
    else:
        lines.append(
            f"ACTION: {report.total_failures} failed job(s) detected. "
            "Investigate the failures listed above before the next backup window."
        )
    return "\n".join(lines)


# --------------------------------------------------------------------------- #
# Delivery — impure
# --------------------------------------------------------------------------- #
def publish_report(sns_client, topic_arn: str, report: BackupReport, body: str) -> None:
    """Publish the rendered report to SNS."""
    if not topic_arn:
        logger.warning("SNS_TOPIC_ARN not set; skipping SNS publish")
        return
    state = "HEALTHY" if report.healthy else "ATTENTION"
    subject = f"[{state}] {PROJECT_NAME} backup report — {report.environment}"
    sns_client.publish(
        TopicArn=topic_arn,
        # SNS subjects are capped at 100 characters.
        Subject=subject[:100],
        Message=body,
        MessageAttributes={
            "healthy": {"DataType": "String", "StringValue": str(report.healthy)},
            "environment": {"DataType": "String", "StringValue": report.environment},
            "total_failures": {
                "DataType": "Number",
                "StringValue": str(report.total_failures),
            },
        },
    )
    logger.info("Published backup report to SNS topic %s", topic_arn)


def emit_metrics(cw_client, namespace: str, report: BackupReport) -> None:
    """Emit per-family CloudWatch metrics derived from the report."""
    now = _dt.datetime.now(tz=_dt.timezone.utc)
    metric_data: List[Dict[str, Any]] = [
        {
            "MetricName": "TotalFailures",
            "Timestamp": now,
            "Value": float(report.total_failures),
            "Unit": "Count",
            "Dimensions": [{"Name": "Environment", "Value": report.environment}],
        }
    ]
    for summary in report.summaries:
        dims = [
            {"Name": "Environment", "Value": report.environment},
            {"Name": "JobFamily", "Value": summary.family},
        ]
        metric_data.append(
            {
                "MetricName": "JobsFailed",
                "Timestamp": now,
                "Value": float(summary.failed),
                "Unit": "Count",
                "Dimensions": dims,
            }
        )
        metric_data.append(
            {
                "MetricName": "JobSuccessRate",
                "Timestamp": now,
                "Value": summary.success_rate,
                "Unit": "Percent",
                "Dimensions": dims,
            }
        )
    try:
        cw_client.put_metric_data(Namespace=namespace, MetricData=metric_data)
        logger.info("Emitted %d datapoints to %s", len(metric_data), namespace)
    except ClientError as exc:  # pragma: no cover - telemetry must not break run
        logger.error("Failed to emit CloudWatch metrics: %s", exc)


# --------------------------------------------------------------------------- #
# Entry point
# --------------------------------------------------------------------------- #
def _window(now: Optional[_dt.datetime] = None) -> tuple[_dt.datetime, _dt.datetime]:
    end = now or _dt.datetime.now(tz=_dt.timezone.utc)
    start = end - _dt.timedelta(days=REPORT_WINDOW_DAYS)
    return start, end


def handler(event: Optional[Dict[str, Any]], context: Any) -> Dict[str, Any]:
    """Lambda entry point. Gathers, renders, delivers, and returns the report.

    Triggered weekly by an EventBridge schedule (see ``terraform/reporter.tf``).
    The ``event`` is unused for scheduled runs but accepted for manual/test
    invocations.
    """
    logger.info("Starting backup report; window=%d day(s)", REPORT_WINDOW_DAYS)
    start, end = _window()

    sts = _client("sts")
    try:
        account_id = sts.get_caller_identity()["Account"]
    except ClientError as exc:
        raise BackupReporterError(f"Unable to resolve account identity: {exc}") from exc

    region = boto3.session.Session().region_name or "unknown"

    backup = _client("backup")
    families = gather_jobs(backup, start)
    report = build_report(account_id, region, families, start, end)

    body = format_report_text(report)
    logger.info("Report body:\n%s", body)

    publish_report(_client("sns"), SNS_TOPIC_ARN, report, body)
    emit_metrics(_client("cloudwatch"), CW_NAMESPACE, report)

    result = report.to_dict()
    logger.info("Backup report complete: %s", json.dumps(result.get("summaries")))
    return result
