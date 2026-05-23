"""Shared pytest fixtures and module loaders for the AWS Backup-DR Lambdas.

Both Lambda packages expose a module named ``app``; importing them under their
own names here avoids the module-name collision when the whole suite runs in a
single interpreter.
"""

from __future__ import annotations

import importlib.util
import os
import pathlib
import sys
import types

import pytest

# A region must be present before the Lambdas construct any boto3 client.
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "testing")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "testing")
os.environ.setdefault("AWS_SECURITY_TOKEN", "testing")
os.environ.setdefault("AWS_SESSION_TOKEN", "testing")

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]


def _load(module_name: str, relative_path: str) -> types.ModuleType:
    """Load a Lambda's ``app.py`` under a unique module name."""
    path = _REPO_ROOT / relative_path
    spec = importlib.util.spec_from_file_location(module_name, path)
    assert spec and spec.loader, f"cannot load {path}"
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="session")
def reporter_app() -> types.ModuleType:
    return _load("reporter_app", "lambda/backup-reporter/app.py")


@pytest.fixture(scope="session")
def restore_app() -> types.ModuleType:
    return _load("restore_app", "lambda/restore-tester/app.py")
