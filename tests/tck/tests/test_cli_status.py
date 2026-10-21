"""A completed TCK report must also provide an honest process exit status."""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from tests.tck import __main__ as cli
from tests.tck.backends.base import QueryResult


class StubBackend:
    name = 'extension'

    def __init__(self, error=False):
        self.error = error
        self.closed = False

    def reset(self):
        pass

    def execute(self, query, parameters=None):
        if self.error:
            return QueryResult(error='GraphQLiteError', error_message='deliberate backend failure')
        return QueryResult(headers=['x'], rows=[[1]])

    def close(self):
        self.closed = True


@pytest.mark.parametrize('expected,error,status,exit_code', [
    (1, False, 'pass', 0),
    (2, False, 'fail', 1),
    (1, True, 'error', 1),
])
def test_verdict_controls_exit_and_preserves_report(tmp_path: Path, monkeypatch,
                                                   expected, error, status, exit_code):
    feature = tmp_path / 'status.feature'
    feature.write_text(
        'Feature: terminal status\n'
        '  Scenario: observed verdict\n'
        '    Given an empty graph\n'
        '    When executing query:\n'
        '      """\n'
        '      RETURN 1 AS x\n'
        '      """\n'
        '    Then the result should be, in order:\n'
        '      | x |\n'
        f'      | {expected} |\n'
    )
    backend = StubBackend(error=error)
    monkeypatch.setattr(cli, '_select_backends', lambda *_args, **_kwargs: [backend])
    output = tmp_path / 'results.json'
    actual = cli.main(['--features', str(tmp_path), '--out', str(output), '--quiet'])
    assert actual == exit_code
    assert backend.closed
    report = json.loads(output.read_text())
    assert len(report) == 1
    assert report[0]['status'] == status


def test_unavailable_backend_remains_a_setup_failure(tmp_path: Path, monkeypatch):
    monkeypatch.setattr(cli, '_select_backends', lambda *_args, **_kwargs: [])
    assert cli.main(['--features', str(tmp_path), '--quiet']) == 2
