"""Unit + integration tests for the backup-reporter Lambda."""

from __future__ import annotations

import datetime as _dt

import boto3
import pytest
from moto import mock_aws


# --------------------------------------------------------------------------- #
# Pure aggregation logic
# --------------------------------------------------------------------------- #
def test_job_state_normalises_state_and_status(reporter_app):
    assert reporter_app._job_state({"State": "completed"}) == "COMPLETED"
    assert reporter_app._job_state({"Status": "failed"}) == "FAILED"
    assert reporter_app._job_state({}) == "UNKNOWN"


def test_summarize_jobs_counts_each_bucket(reporter_app):
    jobs = [
        {"State": "COMPLETED", "BackupJobId": "1"},
        {"State": "COMPLETED", "BackupJobId": "2"},
        {"State": "FAILED", "BackupJobId": "3", "StatusMessage": "boom"},
        {"State": "PARTIAL", "BackupJobId": "4"},
        {"State": "RUNNING", "BackupJobId": "5"},
    ]
    s = reporter_app.summarize_jobs("backup", jobs)
    assert s.total == 5
    assert s.completed == 2
    assert s.failed == 1
    assert s.partial == 1
    assert s.in_progress == 1
    assert s.by_state["COMPLETED"] == 2
    assert s.failures[0]["id"] == "3"
    assert s.failures[0]["message"] == "boom"


def test_success_rate_excludes_in_progress(reporter_app):
    jobs = [
        {"State": "COMPLETED", "BackupJobId": "1"},
        {"State": "COMPLETED", "BackupJobId": "2"},
        {"State": "COMPLETED", "BackupJobId": "3"},
        {"State": "RUNNING", "BackupJobId": "4"},  # not counted in denominator
    ]
    s = reporter_app.summarize_jobs("backup", jobs)
    assert s.success_rate == 100.0


def test_success_rate_with_failures(reporter_app):
    jobs = [
        {"State": "COMPLETED", "BackupJobId": "1"},
        {"State": "FAILED", "BackupJobId": "2"},
    ]
    s = reporter_app.summarize_jobs("backup", jobs)
    assert s.success_rate == 50.0


def test_empty_summary_is_fully_healthy(reporter_app):
    s = reporter_app.summarize_jobs("copy", [])
    assert s.total == 0
    assert s.success_rate == 100.0


def test_failures_are_capped(reporter_app, monkeypatch):
    monkeypatch.setattr(reporter_app, "MAX_FAILURES_LISTED", 3)
    jobs = [{"State": "FAILED", "BackupJobId": str(i)} for i in range(10)]
    s = reporter_app.summarize_jobs("backup", jobs)
    assert s.failed == 10
    assert len(s.failures) == 3  # capped, but count is accurate


def test_build_report_orders_families_and_aggregates(reporter_app):
    start = _dt.datetime(2026, 5, 20, tzinfo=_dt.timezone.utc)
    end = _dt.datetime(2026, 5, 27, tzinfo=_dt.timezone.utc)
    families = {
        "backup": [{"State": "FAILED", "BackupJobId": "1"}],
        "copy": [{"State": "COMPLETED", "CopyJobId": "2"}],
        "restore": [{"Status": "COMPLETED", "RestoreJobId": "3"}],
    }
    report = reporter_app.build_report("123456789012", "us-east-1", families, start, end)
    assert [s.family for s in report.summaries] == ["backup", "copy", "restore"]
    assert report.total_failures == 1
    assert report.healthy is False


def test_format_report_text_healthy(reporter_app):
    start = _dt.datetime(2026, 5, 20, tzinfo=_dt.timezone.utc)
    end = _dt.datetime(2026, 5, 27, tzinfo=_dt.timezone.utc)
    report = reporter_app.build_report("123456789012", "us-east-1", {}, start, end)
    text = reporter_app.format_report_text(report)
    assert "HEALTHY" in text
    assert "completed successfully" in text


def test_format_report_text_lists_failures(reporter_app):
    start = _dt.datetime(2026, 5, 20, tzinfo=_dt.timezone.utc)
    end = _dt.datetime(2026, 5, 27, tzinfo=_dt.timezone.utc)
    families = {
        "backup": [
            {"State": "FAILED", "BackupJobId": "job-9", "ResourceType": "EBS",
             "StatusMessage": "snapshot failed"}
        ]
    }
    report = reporter_app.build_report("123456789012", "us-east-1", families, start, end)
    text = reporter_app.format_report_text(report)
    assert "ATTENTION REQUIRED" in text
    assert "job-9" in text
    assert "snapshot failed" in text


# --------------------------------------------------------------------------- #
# Integration: handler against moto (SNS + STS + CloudWatch are real mocks;
# only the backup-job source is stubbed because moto's AWS Backup job listing
# is limited).
# --------------------------------------------------------------------------- #
@mock_aws
def test_handler_publishes_and_returns_report(reporter_app, monkeypatch):
    sns = boto3.client("sns", region_name="us-east-1")
    topic_arn = sns.create_topic(Name="backup-alerts")["TopicArn"]
    monkeypatch.setattr(reporter_app, "SNS_TOPIC_ARN", topic_arn)

    canned = {
        "backup": [
            {"State": "COMPLETED", "BackupJobId": "ok"},
            {"State": "FAILED", "BackupJobId": "bad", "ResourceType": "RDS"},
        ],
        "copy": [{"State": "COMPLETED", "CopyJobId": "c1"}],
        "restore": [],
    }
    monkeypatch.setattr(reporter_app, "gather_jobs", lambda client, since: canned)

    result = reporter_app.handler({}, None)

    assert result["account_id"] == "123456789012"
    assert result["total_failures"] == 1
    assert result["healthy"] is False
    families = {s["family"]: s for s in result["summaries"]}
    assert families["backup"]["completed"] == 1
    assert families["backup"]["failed"] == 1


@mock_aws
def test_handler_skips_publish_without_topic(reporter_app, monkeypatch):
    monkeypatch.setattr(reporter_app, "SNS_TOPIC_ARN", "")
    monkeypatch.setattr(
        reporter_app, "gather_jobs", lambda client, since: {"backup": [], "copy": [], "restore": []}
    )
    result = reporter_app.handler({}, None)
    assert result["healthy"] is True
    assert result["total_failures"] == 0
