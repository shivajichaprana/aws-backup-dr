"""Unit tests for the restore-tester Lambda's pure helpers and dispatch."""

from __future__ import annotations

import pytest


def test_resource_type_from_arn(restore_app):
    f = restore_app._resource_type_from_arn
    assert f("arn:aws:ec2:us-east-1:123456789012:volume/vol-abc") == "EBS"
    assert f("arn:aws:rds:us-east-1:123456789012:db:mydb") == "RDS"
    assert f("arn:aws:dynamodb:us-east-1:123456789012:table/t") == "DynamoDB"
    assert f("arn:aws:elasticfilesystem:us-east-1:123456789012:file-system/fs-1") == "EFS"
    assert f("arn:aws:s3:::some-bucket") == "Unknown"


def test_parse_iso(restore_app):
    assert restore_app._parse_iso("") is None
    assert restore_app._parse_iso("not-a-date") is None
    parsed = restore_app._parse_iso("2026-05-27T03:00:00+00:00")
    assert parsed is not None
    assert parsed.year == 2026 and parsed.month == 5 and parsed.day == 27


def test_new_test_id_prefix(restore_app):
    tid = restore_app._new_test_id()
    assert tid.startswith("rt-")
    assert len(tid) > len("rt-")


def test_test_context_round_trip(restore_app):
    event = {"context": {"test_id": "rt-x", "resource_type": "EBS", "status": "RUNNING"}}
    ctx = restore_app.TestContext.from_event(event)
    assert ctx.test_id == "rt-x"
    assert ctx.resource_type == "EBS"
    assert ctx.status == "RUNNING"
    d = ctx.to_dict()
    assert d["test_id"] == "rt-x"
    assert d["resource_type"] == "EBS"


def test_test_context_generates_id_when_missing(restore_app):
    ctx = restore_app.TestContext.from_event({})
    assert ctx.test_id.startswith("rt-")


def test_handler_rejects_unknown_action(restore_app):
    with pytest.raises(restore_app.RestoreTestError):
        restore_app.handler({"action": "explode"}, None)
