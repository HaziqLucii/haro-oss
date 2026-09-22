"""Test-runner adapters. Vitest (JS/TS) + pytest (Python) + a generic command
escape hatch + a JSON-offense grid adapter (linters); jest/go-test later."""

from .base import TestRunnerAdapter, TestResult
from .command_adapter import CommandAdapter
from .offense import OffenseAdapter
from .pytest_adapter import PytestAdapter
from .vitest import VitestAdapter

__all__ = [
    "TestRunnerAdapter",
    "TestResult",
    "VitestAdapter",
    "PytestAdapter",
    "CommandAdapter",
    "OffenseAdapter",
]
