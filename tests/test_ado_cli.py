"""Unit tests for ado_cli.py. Standard library only: python3 -m unittest discover -s tests"""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import ado_cli  # noqa: E402


def make_config(**overrides) -> ado_cli.Config:
    values = dict(
        token="t",
        org="https://dev.azure.com/acme",
        project="Proj",
        team="",
        assignee="",
        area_path="",
        iteration_path="",
        ssl_cert_file="",
    )
    values.update(overrides)
    return ado_cli.Config(**values)


class FakeClient:
    """Answers request() from a list of (method, path prefix, response) in order."""

    def __init__(self, responses: list[tuple[str, str, object]], **cfg) -> None:
        self.cfg = make_config(**cfg)
        self.responses = list(responses)
        self.calls: list[tuple[str, str, object]] = []

    def request(self, method: str, path: str, payload=None, content_type=None):
        self.calls.append((method, path, payload))
        expected_method, prefix, response = self.responses.pop(0)
        assert method == expected_method and path.startswith(prefix), (method, path)
        return response


def closed_args(**overrides) -> argparse.Namespace:
    values = dict(
        from_date="2025-01-01",
        to_date=None,
        work_item_type="User Story",
        states="Closed,Resolved",
        assigned_to="Jane Doe",
        output="",
        no_output=True,
    )
    values.update(overrides)
    return argparse.Namespace(**values)


class ClosedStoriesWiqlTests(unittest.TestCase):
    def test_end_date_is_to_date_itself(self):
        wiql = ado_cli._build_closed_stories_wiql("Proj", ["User Story"], ["Closed"], "2025-01-01", "2025-01-10")
        self.assertIn("[Microsoft.VSTS.Common.ClosedDate] <= '2025-01-10'", wiql)
        self.assertNotIn("2025-01-11", wiql)

    def test_several_types(self):
        wiql = ado_cli._build_closed_stories_wiql("Proj", ["User Story", "Task"], ["Closed"], "2025-01-01", None)
        self.assertIn("[System.WorkItemType] IN ('User Story', 'Task')", wiql)


class ExportClosedStoriesTests(unittest.TestCase):
    def test_inverted_unpadded_range_is_rejected(self):
        client = FakeClient([])
        with self.assertRaises(ado_cli.CliError) as ctx:
            ado_cli.cmd_export_closed_stories(closed_args(from_date="2025-10-01", to_date="2025-9-30"), client)
        self.assertEqual(ctx.exception.code, "VALIDATION_ERROR")

    def test_query_uses_inclusive_to_date(self):
        client = FakeClient([("POST", "wit/wiql", {"workItems": []})])
        ado_cli.cmd_export_closed_stories(closed_args(from_date="2025-1-1", to_date="2025-1-10"), client)
        query = client.calls[0][2]["query"]
        self.assertIn("<= '2025-01-10'", query)
        self.assertIn(">= '2025-01-01'", query)

    def test_returns_items_without_writing(self):
        batch = {
            "value": [
                {
                    "id": 123456,
                    "fields": {
                        "System.Title": "Story",
                        "System.State": "Closed",
                        "System.WorkItemType": "User Story",
                        "System.AssignedTo": {"displayName": "Jane Doe", "uniqueName": "jane@acme.com"},
                        "Microsoft.VSTS.Common.ClosedDate": "2025-01-05T10:00:00Z",
                    },
                },
                {"id": 7, "fields": {"System.AssignedTo": {"displayName": "Someone Else"}}},
            ]
        }
        client = FakeClient([("POST", "wit/wiql", {"workItems": [{"id": 123456}, {"id": 7}]}), ("POST", "wit/workitemsbatch", batch)])
        result = ado_cli.cmd_export_closed_stories(closed_args(work_item_type="User Story, Task"), client)
        self.assertIsNone(result["output"])
        self.assertEqual(result["workItemTypes"], ["User Story", "Task"])
        self.assertEqual(result["count"], 1)
        self.assertEqual(result["items"][0]["id"], 123456)
        self.assertEqual(result["items"][0]["date"], "1/5/2025")
        self.assertTrue(result["items"][0]["url"].endswith("/_workitems/edit/123456"))

    def test_default_filename_uses_padded_date(self):
        client = FakeClient([("POST", "wit/wiql", {"workItems": []})])
        with tempfile.TemporaryDirectory() as tmp:
            cwd = os.getcwd()
            os.chdir(tmp)
            try:
                result = ado_cli.cmd_export_closed_stories(closed_args(from_date="2025-1-5", no_output=False), client)
                self.assertEqual(result["output"], "data/ado_closed_stories_since_2025-01-05.json")
                with open(result["output"], encoding="utf-8") as f:
                    self.assertEqual(json.load(f)["count"], 0)
            finally:
                os.chdir(cwd)


class ExportModificationsTests(unittest.TestCase):
    def revision(self, rev: int, changed: str) -> dict:
        return {
            "rev": rev,
            "fields": {
                "System.Id": 42,
                "System.ChangedDate": changed,
                "System.ChangedBy": {"displayName": "Jane Doe"},
                "System.Title": "Item",
            },
        }

    def test_keeps_reading_past_an_out_of_order_revision(self):
        client = FakeClient(
            [
                (
                    "GET",
                    "wit/reporting/workitemrevisions",
                    {
                        "values": [self.revision(1, "2025-01-20T00:00:00Z"), self.revision(2, "2025-01-05T00:00:00Z")],
                        "isLastBatch": False,
                        "continuationToken": "a",
                    },
                ),
                (
                    "GET",
                    "wit/reporting/workitemrevisions",
                    {"values": [self.revision(3, "2025-01-06T00:00:00Z")], "isLastBatch": True},
                ),
            ]
        )
        args = argparse.Namespace(user="Jane Doe", from_date="2025-01-01", to_date="2025-01-10")
        result = ado_cli.cmd_export_modifications(args, client)
        self.assertEqual([item["revision"] for item in result["items"]], [3, 2])


class IterationPickTests(unittest.TestCase):
    def test_malformed_on_is_a_validation_error(self):
        args = argparse.Namespace(area_path="Proj\\Team", on="2025/10/01")
        with self.assertRaises(ado_cli.CliError) as ctx:
            ado_cli.cmd_iteration_pick(args, FakeClient([]))
        self.assertEqual(ctx.exception.code, "VALIDATION_ERROR")
        self.assertIn("--on", ctx.exception.message)


class MapApiErrorTests(unittest.TestCase):
    def test_not_found_depends_on_command(self):
        err = ado_cli.AdoApiError(404, "missing")
        self.assertEqual(ado_cli.map_api_error(err, "get")[0], "STORY_NOT_FOUND")
        self.assertEqual(ado_cli.map_api_error(err, "iteration-get")[0], "ITERATION_NOT_FOUND")
        self.assertEqual(ado_cli.map_api_error(err, "iteration-list")[0], "NOT_FOUND")
        self.assertEqual(ado_cli.map_api_error(err)[0], "NOT_FOUND")


class SslConfigTests(unittest.TestCase):
    base_env = {"ADO_TOKEN": "t", "ADO_ORG": "acme", "ADO_PROJECT": "Proj", "ADO_ENV_FILE": os.devnull}

    def load(self, **env):
        with mock.patch.dict(os.environ, {**self.base_env, **env}, clear=True):
            return ado_cli.load_config()

    def test_missing_file_is_a_config_error(self):
        with self.assertRaises(ValueError) as ctx:
            self.load(SSL_CERT_FILE="/no/such/bundle.pem")
        self.assertIn("/no/such/bundle.pem", str(ctx.exception))

    def test_directory_is_not_a_cert_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError):
                self.load(SSL_CERT_FILE=tmp)

    def test_cert_dir_is_accepted(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(self.load(SSL_CERT_DIR=tmp).ssl_cert_dir, tmp)

    def test_main_reports_config_error(self):
        out = io.StringIO()
        with mock.patch.dict(os.environ, {**self.base_env, "SSL_CERT_FILE": "/no/such.pem"}, clear=True):
            with contextlib.redirect_stdout(out):
                code = ado_cli.main(["get", "--id=1"])
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(out.getvalue())["error"]["code"], "CONFIG_ERROR")


class WeeklyReportWiqlTests(unittest.TestCase):
    def test_excluded_types(self):
        wiql = ado_cli._build_weekly_report_wiql("Proj", "Proj\\Team", "2025-01-01", ["Closed"], False, ["Epic", "Feature"])
        self.assertIn("[System.WorkItemType] NOT IN ('Epic', 'Feature')", wiql)
        self.assertNotIn("WorkItemType", ado_cli._build_weekly_report_wiql("Proj", "Proj", "2025-01-01", ["Closed"], False))


if __name__ == "__main__":
    unittest.main()
