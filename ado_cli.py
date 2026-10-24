#!/usr/bin/env python3
"""Custom Azure DevOps CLI prototype.

This is the Python implementation track for the future custom CLI. It coexists
with ado.sh while migration is in progress.
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import html
import json
import os
import re
import ssl
import sys
import urllib.parse
import urllib.error
import urllib.request
from pathlib import Path
from dataclasses import dataclass, field
from typing import Any

API_VERSION = "7.1"
COMMENT_API_VERSION = "7.1-preview.3"
ITERATION_API_VERSION = "7.1"
ALLOWED_URL_SCHEMES = ("https",)


@dataclass
class Config:
    token: str = field(repr=False)
    org: str
    project: str
    team: str
    assignee: str
    area_path: str
    iteration_path: str
    ssl_cert_file: str


def utc_timestamp() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def format_description_html(text: str) -> str:
    """Convert basic Markdown (newlines, bullets, code blocks) to HTML for ADO fields.
    
    Args:
        text: Plain text or Markdown-style string
        
    Returns:
        HTML formatted string
    """
    if not text:
        return ""

    lines = text.splitlines()
    html_lines = []
    in_list = False
    list_type = None  # "ul" or "ol"
    in_code_block = False
    
    for line in lines:
        stripped = line.lstrip()
        
        # Handle code blocks
        if stripped.startswith("```"):
            if in_list:
                html_lines.append(f"</{list_type}>")
                in_list = False
                list_type = None
            
            if not in_code_block:
                html_lines.append("<pre style=\"background-color: #f6f8fa; padding: 10px; border-radius: 3px;\"><code>")
                in_code_block = True
            else:
                html_lines.append("</code></pre>")
                in_code_block = False
            continue
            
        if in_code_block:
            html_lines.append(html.escape(line) + "\n")
            continue

        # Handle lists
        is_ul = stripped.startswith(("- ", "* "))
        is_ol = stripped.startswith(("1. ", "2. ", "3. ", "4. ", "5. ", "6. ", "7. ", "8. ", "9. "))
        
        if is_ul or is_ol:
            current_type = "ul" if is_ul else "ol"
            if not in_list:
                html_lines.append(f"<{current_type}>")
                in_list = True
                list_type = current_type
            elif list_type != current_type:
                html_lines.append(f"</{list_type}><{current_type}>")
                list_type = current_type
            
            if is_ul:
                content = html.escape(stripped[2:])
            else:
                space_idx = stripped.find(" ")
                content = html.escape(stripped[space_idx + 1:])
            html_lines.append(f"<li>{content}</li>")
            continue
        else:
            if in_list:
                html_lines.append(f"</{list_type}>")
                in_list = False
                list_type = None
            
            if not stripped:
                html_lines.append("<br />")
            else:
                # Handle headings
                if stripped.startswith("### "):
                    html_lines.append(f"<h3>{html.escape(stripped[4:])}</h3>")
                elif stripped.startswith("## "):
                    html_lines.append(f"<h2>{html.escape(stripped[3:])}</h2>")
                elif stripped.startswith("# "):
                    html_lines.append(f"<h1>{html.escape(stripped[2:])}</h1>")
                else:
                    # Inline code backticks
                    line_html = html.escape(line)
                    line_html = re.sub(
                        r'`([^`]+)`',
                        r'<code style="background-color: #f6f8fa; padding: 2px 4px; border-radius: 3px;">\1</code>',
                        line_html,
                    )
                    html_lines.append(f"{line_html}<br />")
    
    if in_list:
        html_lines.append(f"</{list_type}>")
    if in_code_block:
        html_lines.append("</code></pre>")

    return "".join(html_lines)


def envelope_success(command: str, cfg: Config, result: Any) -> dict[str, Any]:
    return {
        "success": True,
        "command": command,
        "timestamp": utc_timestamp(),
        "organization": cfg.org,
        "project": cfg.project,
        "result": result,
    }


def envelope_error(command: str, cfg: Config | None, code: str, message: str) -> dict[str, Any]:
    return {
        "success": False,
        "command": command,
        "timestamp": utc_timestamp(),
        "organization": cfg.org if cfg else None,
        "project": cfg.project if cfg else None,
        "error": {
            "code": code,
            "message": message,
        },
    }


def format_acceptance_criteria(criteria: list[str] | None) -> str:
    """Convert acceptance criteria list to HTML <ul><li> format for ADO field.
    
    Args:
        criteria: List of criterion text strings, or None/empty list
        
    Returns:
        HTML formatted string, or empty string if no criteria
    """
    if not criteria:
        return ""
    
    items = []
    for item in criteria:
        # Strip leading dashes/bullets if present
        text = item.lstrip("- •*").strip()
        # Escape HTML special characters
        text = html.escape(text)
        items.append(f"<li>{text}</li>")
    
    if not items:
        return ""
    
    return "<ul>" + "".join(items) + "</ul>"


def print_json(data: dict[str, Any]) -> None:
    print(json.dumps(data, indent=2, sort_keys=False))


def normalize_org(raw_org: str) -> str:
    raw_org = raw_org.strip()
    if raw_org.startswith("https://"):
        parsed = urllib.parse.urlparse(raw_org)
        if parsed.scheme != "https" or not parsed.netloc:
            raise ValueError(f"Invalid ADO_ORG URL: {raw_org}")
        return raw_org.rstrip("/")
    # Treat as a bare org name; reject anything containing a scheme separator
    if "://" in raw_org or raw_org.startswith("/"):
        raise ValueError(f"Invalid ADO_ORG value (must be https:// or bare org name): {raw_org}")
    return f"https://dev.azure.com/{urllib.parse.quote(raw_org, safe='')}".rstrip("/")


def require_env(primary: str, fallback: str | None = None) -> str:
    value = os.getenv(primary, "").strip()
    if value:
        return value
    if fallback:
        value = os.getenv(fallback, "").strip()
        if value:
            return value
    raise ValueError(f"Missing required environment variable: {primary}" + (f" or {fallback}" if fallback else ""))


def require_env_any(*names: str) -> str:
    for name in names:
        value = os.getenv(name, "").strip()
        if value:
            return value
    raise ValueError("Missing required environment variable: " + " or ".join(names))


def _strip_optional_quotes(value: str) -> str:
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
        return value[1:-1]
    return value


def load_dotenv_defaults() -> None:
    """Load .env values without overwriting already-exported environment variables."""
    explicit_env = os.getenv("ADO_ENV_FILE", "").strip()
    candidates: list[Path] = []

    if explicit_env:
        candidates.append(Path(explicit_env).expanduser())
    else:
        cwd_env = Path.cwd() / ".env"
        repo_env = Path(__file__).resolve().parent.parent / ".env"
        candidates.extend([cwd_env, repo_env])

    env_path = next((p for p in candidates if p.exists() and p.is_file()), None)
    if env_path is None:
        return

    for raw_line in env_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export ") :].strip()
        if "=" not in line:
            continue

        key, value = line.split("=", 1)
        key = key.strip()
        if not key or key in os.environ:
            continue

        parsed_value = _strip_optional_quotes(value.strip())
        os.environ[key] = parsed_value


def load_config() -> Config:
    load_dotenv_defaults()

    token = require_env_any("ADO_TOKEN", "AZURE_DEVOPS_PAT", "ADO_PAT")
    org = normalize_org(require_env_any("ADO_ORG", "AZURE_DEVOPS_ORG"))
    project = require_env_any("ADO_PROJECT", "AZURE_DEVOPS_PROJECT")
    team = os.getenv("ADO_TEAM", "").strip()
    assignee = os.getenv("ADO_ASSIGNEE", "").strip()
    area_path = os.getenv("ADO_AREA_PATH", "").strip()
    iteration_path = os.getenv("ADO_ITERATION_PATH", "").strip()
    ssl_cert_file = os.getenv("SSL_CERT_FILE", "").strip()

    return Config(
        token=token,
        org=org,
        project=project,
        team=team,
        assignee=assignee,
        area_path=area_path,
        iteration_path=iteration_path,
        ssl_cert_file=ssl_cert_file,
    )


class AdoClient:
    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg
        project_encoded = urllib.parse.quote(cfg.project, safe="")
        self.base_url = f"{cfg.org}/{project_encoded}/_apis"
        auth = base64.b64encode(f":{cfg.token}".encode("utf-8")).decode("utf-8")
        self.auth_header = f"Basic {auth}"
        self.ssl_context = ssl.create_default_context(
            cafile=cfg.ssl_cert_file
            if cfg.ssl_cert_file and os.path.exists(cfg.ssl_cert_file)
            else None
        )

    def _dispatch(self, method: str, url: str, payload: Any = None, content_type: str | None = None) -> Any:
        """Low-level HTTP dispatch. Validates the URL scheme and executes the request."""
        # Enforce scheme allowlist (https only) to prevent file://, http://, ftp://, etc. (CWE-939)
        parsed_url = urllib.parse.urlparse(url)
        if parsed_url.scheme not in ALLOWED_URL_SCHEMES or not parsed_url.netloc:
            raise AdoApiError(status=None, message=f"Refusing to open non-https URL: {url}")

        headers = {
            "Authorization": self.auth_header,
            "Accept": "application/json",
        }
        if payload is not None:
            headers["Content-Type"] = content_type or "application/json"

        body = json.dumps(payload).encode("utf-8") if payload is not None else None
        request = urllib.request.Request(
            url=url,
            data=body,
            headers=headers,
            method=method.upper(),
        )

        try:
            with urllib.request.urlopen(request, timeout=60, context=self.ssl_context) as response:
                raw = response.read()
                status = response.status
            if status >= 400:
                body = raw.decode("utf-8", errors="replace") if raw else ""
                message = body or f"HTTP {status}"
                try:
                    parsed = json.loads(body) if body else {}
                    message = parsed.get("message", message)
                except json.JSONDecodeError:
                    pass
                raise AdoApiError(status=status, message=message)
            if not raw:
                return {}
            try:
                return json.loads(raw.decode("utf-8"))
            except json.JSONDecodeError as exc:
                raise AdoApiError(status=status, message=f"Unexpected non-JSON response from Azure DevOps (HTTP {status}).") from exc
        except urllib.error.HTTPError as exc:
            raw = exc.read()
            body_text = raw.decode("utf-8", errors="replace") if raw else ""
            message = body_text or f"HTTP {exc.code}"
            try:
                parsed_body = json.loads(body_text) if body_text else {}
                message = parsed_body.get("message", message)
            except json.JSONDecodeError:
                pass
            raise AdoApiError(status=exc.code, message=message) from exc
        except (urllib.error.URLError, TimeoutError) as exc:
            raise AdoApiError(status=None, message=str(exc.reason if isinstance(exc, urllib.error.URLError) else exc)) from exc

    def request(self, method: str, path: str, payload: Any = None, content_type: str | None = None) -> Any:
        url = f"{self.base_url}/{path.lstrip('/')}"
        return self._dispatch(method, url, payload, content_type)

    def team_request(self, method: str, path: str, team: str | None = None, payload: Any = None, content_type: str | None = None) -> Any:
        """Issue a request against the team-scoped work API (teamsettings, iterations, etc.)."""
        resolved_team = team or self.cfg.team
        if not resolved_team:
            raise CliError("CONFIG_ERROR", "ADO_TEAM environment variable is required for iteration commands (or pass --team)")
        project_encoded = urllib.parse.quote(self.cfg.project, safe="")
        team_encoded = urllib.parse.quote(resolved_team, safe="")
        team_base = f"{self.cfg.org}/{project_encoded}/{team_encoded}/_apis"
        url = f"{team_base}/{path.lstrip('/')}"
        return self._dispatch(method, url, payload, content_type)


class AdoApiError(Exception):
    def __init__(self, status: int | None, message: str) -> None:
        self.status = status
        self.message = message
        super().__init__(message)


class CliError(Exception):
    def __init__(self, code: str, message: str) -> None:
        self.code = code
        self.message = message
        super().__init__(message)


def map_api_error(err: AdoApiError) -> tuple[str, str]:
    if err.status in (401, 403):
        return ("AUTH_ERROR", err.message)
    if err.status == 404:
        return ("STORY_NOT_FOUND", err.message)
    if err.status == 400:
        return ("VALIDATION_ERROR", err.message)
    return ("API_ERROR", err.message)


def build_work_item_url(cfg: Config, item_id: int | str) -> str:
    project_encoded = urllib.parse.quote(cfg.project, safe="")
    return f"{cfg.org}/{project_encoded}/_workitems/edit/{item_id}"


def _escape_wiql_literal(value: str) -> str:
    return value.replace("'", "''")


def _validate_date(value: str, *, flag: str) -> str:
    try:
        parsed = dt.datetime.strptime(value, "%Y-%m-%d")
    except ValueError as exc:
        raise CliError("VALIDATION_ERROR", f"Invalid --{flag} '{value}'. Use YYYY-MM-DD.") from exc
    return parsed.strftime("%Y-%m-%d")


def _validate_from_date(from_date: str) -> str:
    return _validate_date(from_date, flag="from-date")


def _validate_to_date(to_date: str) -> str:
    return _validate_date(to_date, flag="to-date")


def _sanitize_rich_text(value: Any) -> str:
    if value is None:
        return ""
    text = str(value)
    text = re.sub(r"<[^>]+>", " ", text)
    text = html.unescape(text)
    return re.sub(r"\s+", " ", text).strip()


def _build_closed_stories_wiql(
    project: str,
    work_item_type: str,
    states: list[str],
    from_date_iso: str,
    to_date_iso: str | None,
) -> str:
    escaped_states = ", ".join(f"'{_escape_wiql_literal(s)}'" for s in states)
    escaped_type = _escape_wiql_literal(work_item_type)
    escaped_project = _escape_wiql_literal(project)

    wiql = (
        "SELECT [System.Id] "
        "FROM WorkItems "
        f"WHERE [System.TeamProject] = '{escaped_project}' "
        f"AND [System.WorkItemType] = '{escaped_type}' "
        f"AND [System.State] IN ({escaped_states}) "
        f"AND [Microsoft.VSTS.Common.ClosedDate] >= '{from_date_iso}' "
    )
    if to_date_iso:
        wiql += f"AND [Microsoft.VSTS.Common.ClosedDate] <= '{to_date_iso}' "
    wiql += "ORDER BY [Microsoft.VSTS.Common.ClosedDate] DESC"
    return wiql

def _assignee_matches(expected: str, actual: str | None) -> bool:
    if not actual:
        return False

    expected_clean = re.sub(r"\s+", " ", expected).strip().casefold()
    actual_clean = re.sub(r"\s+", " ", actual).strip().casefold()
    if not expected_clean or not actual_clean:
        return False
    if expected_clean == actual_clean:
        return True

    expected_tokens = sorted(t for t in re.split(r"[^a-z0-9]+", expected_clean) if t)
    actual_tokens = sorted(t for t in re.split(r"[^a-z0-9]+", actual_clean) if t)
    if expected_tokens == actual_tokens:
        return True
    return len(expected_tokens) >= 2 and set(expected_tokens).issubset(actual_tokens)


def _chunked(values: list[int], size: int) -> list[list[int]]:
    return [values[i : i + size] for i in range(0, len(values), size)]


def cmd_create(args: argparse.Namespace, client: AdoClient) -> dict[str, Any]:
    description_html = format_description_html(args.description)
    ops: list[dict[str, Any]] = [
        {"op": "add", "path": "/fields/System.Title", "value": args.title},
        {"op": "add", "path": "/fields/System.Description", "value": description_html},
        {"op": "add", "path": "/fields/System.WorkItemType", "value": args.type},
    ]

    area_path = args.area_path if args.area_path is not None else client.cfg.area_path
    iteration_path = args.iteration_path if args.iteration_path is not None else client.cfg.iteration_path

    if area_path:
        ops.append({"op": "add", "path": "/fields/System.AreaPath", "value": area_path})
    if iteration_path:
        ops.append({"op": "add", "path": "/fields/System.IterationPath", "value": iteration_path})

    if args.parent_id is not None:
        project_encoded = urllib.parse.quote(client.cfg.project, safe="")
        parent_url = f"{client.cfg.org}/{project_encoded}/_apis/wit/workItems/{int(args.parent_id)}"
        ops.append(
            {
                "op": "add",
                "path": "/relations/-",
                "value": {
                    "rel": "System.LinkTypes.Hierarchy-Reverse",
                    "url": parent_url,
                },
            }
        )

    if args.assigned_to:
        ops.append({"op": "add", "path": "/fields/System.AssignedTo", "value": args.assigned_to})
    if args.secondary_assignee:
        ops.append({"op": "add", "path": "/fields/Custom.SecondaryAssignee", "value": args.secondary_assignee})

    # Format and add acceptance criteria if provided
    acceptance_criteria_html = format_acceptance_criteria(args.acceptance_criteria)
    if acceptance_criteria_html:
        ops.append({"op": "add", "path": "/fields/Microsoft.VSTS.Common.AcceptanceCriteria", "value": acceptance_criteria_html})

    work_item_type = urllib.parse.quote(args.type, safe="")
    path = f"wit/workitems/${work_item_type}?api-version={API_VERSION}"
    data = client.request("POST", path, payload=ops, content_type="application/json-patch+json")

    item_id = data.get("id")
    if not item_id:
        raise CliError("API_ERROR", "Create succeeded but response did not include an id")

    fields = data.get("fields", {})
    return {
        "id": item_id,
        "title": fields.get("System.Title", args.title),
        "state": fields.get("System.State"),
        "parentId": args.parent_id,
        "assignedTo": fields.get("System.AssignedTo"),
        "secondaryAssignee": fields.get("Custom.SecondaryAssignee"),
        "url": build_work_item_url(client.cfg, item_id),
    }


def cmd_get(args: argparse.Namespace, client: AdoClient) -> dict[str, Any]:
    path = f"wit/workitems/{args.id}?$expand=all&api-version={API_VERSION}"
    data = client.request("GET", path)
    fields = data.get("fields", {})
    return {
        "id": data.get("id", args.id),
        "title": fields.get("System.Title"),
        "state": fields.get("System.State"),
        "assignedTo": fields.get("System.AssignedTo"),
        "url": data.get("url"),
        "fields": fields,
    }


def cmd_update(args: argparse.Namespace, client: AdoClient) -> dict[str, Any]:
    ops: list[dict[str, Any]] = []

    def add_field(path: str, value: Any) -> None:
        if value is not None:
            ops.append({"op": "add", "path": path, "value": value})

    add_field("/fields/System.Title", args.title)
    add_field("/fields/System.State", args.state)
    add_field("/fields/System.AssignedTo", args.assigned_to)
    add_field("/fields/Custom.SecondaryAssignee", args.secondary_assignee)
    
    description_html = format_description_html(args.description) if args.description is not None else None
    add_field("/fields/System.Description", description_html)
    
    acceptance_criteria_html = format_acceptance_criteria(args.acceptance_criteria) if args.acceptance_criteria is not None else None
    add_field("/fields/Microsoft.VSTS.Common.AcceptanceCriteria", acceptance_criteria_html)
    add_field("/fields/System.History", args.add_comment)

    if args.priority is not None:
        add_field("/fields/Microsoft.VSTS.Common.Priority", int(args.priority))
    if args.story_points is not None:
        add_field("/fields/Microsoft.VSTS.Scheduling.StoryPoints", float(args.story_points))

    if not ops:
        raise CliError("VALIDATION_ERROR", "No update fields provided")

    path = f"wit/workitems/{args.id}?api-version={API_VERSION}"
    data = client.request("PATCH", path, payload=ops, content_type="application/json-patch+json")
    fields = data.get("fields", {})

    return {
        "id": data.get("id", args.id),
        "title": fields.get("System.Title"),
        "state": fields.get("System.State"),
        "url": build_work_item_url(client.cfg, data.get("id", args.id)),
        "updatedFieldsCount": len(ops),
    }


def cmd_delete(args: argparse.Namespace, client: AdoClient) -> dict[str, Any]:
    path = f"wit/workitems/{args.id}?api-version={API_VERSION}"
    data = client.request("DELETE", path)
    return {
        "id": args.id,
        "deleted": True,
        "response": data,
    }


def cmd_comment(args: argparse.Namespace, client: AdoClient) -> dict[str, Any]:
    body = args.body
    if args.body_file:
        with open(args.body_file, "r", encoding="utf-8") as f:
            body = f.read()

    if not body:
        raise CliError("VALIDATION_ERROR", "--body or --body-file is required")

    path = f"wit/workItems/{args.id}/comments?api-version={COMMENT_API_VERSION}"
    data = client.request("POST", path, payload={"text": body}, content_type="application/json")

    return {
        "id": args.id,
        "commentId": data.get("id"),
    }

def cmd_iteration_pick(args: argparse.Namespace, client: AdoClient) -> dict[str, Any]:
    import re
    from datetime import datetime

    area = (args.area_path or "").strip()
    if not area:
        raise CliError("VALIDATION_ERROR", "--area-path is required")

    ref = datetime.strptime(args.on, "%Y-%m-%d") if getattr(args, "on", None) else datetime.now()

    path = (
        f"wit/classificationnodes/iterations"
        f"?api-version={API_VERSION}&$depth=4"
    )
    root = client.request("GET", path)

    paths: list[str] = []

    def walk(node: dict, prefix: str = "") -> None:
        name = node.get("name", "")
        cur = (prefix + chr(92) + name).lstrip(chr(92))
        paths.append(cur)
        for child in node.get("children", []) or []:
            walk(child, cur)

    walk(root)

    area_prefix = area + chr(92)
    scoped = [p for p in paths if p == area or p.startswith(area_prefix)]
    if not scoped:
        raise CliError("NO_ITERATION_MATCH", f"No iterations under area: {area}")

    fy_num = (ref.year + 1) % 100 if ref.month >= 9 else ref.year % 100
    fy_label = f"FY{fy_num:02d}"

    leaf_re = re.compile(r"^(.*?)\\FY\d{2}\\([A-Z][a-z]+ \d{4})$", re.IGNORECASE)
    candidates: list[tuple[str, str]] = []
    for p in scoped:
        m = leaf_re.match(p)
        if m:
            candidates.append((p, m.group(2)))
    if not candidates:
        raise CliError("NO_ITERATION_MATCH", r"No paths matching *\FY##\Month YYYY")

    fy_matches = [c for c in candidates if fy_label in c[0]] or candidates

    valid: list[tuple[str, datetime]] = []
    for p, my in fy_matches:
        try:
            valid.append((p, datetime.strptime(my, "%B %Y")))
        except ValueError:
            continue
    if not valid:
        raise CliError("NO_ITERATION_MATCH", f"No valid month-year in {fy_label}")

    ref_month = datetime(ref.year, ref.month, 1)
    valid.sort(key=lambda x: x[1])
    chosen = next((v for v in valid if v[1] >= ref_month), valid[-1])

    return {
        "path": chosen[0],
        "name": chosen[1].strftime("%B %Y"),
        "fiscalYear": fy_label,
    }

def cmd_iteration_list(args: argparse.Namespace, client: AdoClient) -> dict[str, Any]:
    team = getattr(args, "team", None) or None
    path = f"work/teamsettings/iterations?api-version={ITERATION_API_VERSION}"
    if getattr(args, "timeframe", None):
        path += f"&$timeframe={urllib.parse.quote(args.timeframe, safe='')}"
    data = client.team_request("GET", path, team=team)
    iterations = data.get("value", [])
    return {
        "count": len(iterations),
        "iterations": [
            {
                "id": it.get("id"),
                "name": it.get("name"),
                "path": it.get("path"),
                "startDate": it.get("attributes", {}).get("startDate"),
                "finishDate": it.get("attributes", {}).get("finishDate"),
                "timeFrame": it.get("attributes", {}).get("timeFrame"),
            }
            for it in iterations
        ],
    }


def cmd_iteration_get(args: argparse.Namespace, client: AdoClient) -> dict[str, Any]:
    team = getattr(args, "team", None) or None
    path = f"work/teamsettings/iterations/{args.id}?api-version={ITERATION_API_VERSION}"
    data = client.team_request("GET", path, team=team)
    attrs = data.get("attributes", {})
    return {
        "id": data.get("id"),
        "name": data.get("name"),
        "path": data.get("path"),
        "startDate": attrs.get("startDate"),
        "finishDate": attrs.get("finishDate"),
        "timeFrame": attrs.get("timeFrame"),
        "goalText": attrs.get("goalText"),
        "raw": data,
    }


def cmd_iteration_update_goal(args: argparse.Namespace, client: AdoClient) -> dict[str, Any]:
    team = getattr(args, "team", None) or None

    goal_text = args.goal
    if args.goal_file:
        with open(args.goal_file, "r", encoding="utf-8") as f:
            goal_text = f.read().strip()

    if goal_text is None:
        raise CliError("VALIDATION_ERROR", "--goal or --goal-file is required")

    path = f"work/teamsettings/iterations/{args.id}?api-version={ITERATION_API_VERSION}"
    payload = {"attributes": {"goalText": goal_text}}
    data = client.team_request("PATCH", path, team=team, payload=payload)
    attrs = data.get("attributes", {})
    return {
        "id": data.get("id"),
        "name": data.get("name"),
        "goalText": attrs.get("goalText"),
    }


def _normalize_identity_name(value: Any) -> str | None:
    if isinstance(value, dict):
        return value.get("displayName") or value.get("uniqueName")
    if isinstance(value, str):
        return value
    return None


def cmd_iteration_closed_stories(args: argparse.Namespace, client: AdoClient) -> dict[str, Any]:
    iteration_path = args.iteration_path
    state = args.state

    escaped_project = _escape_wiql_literal(client.cfg.project)
    escaped_iteration = _escape_wiql_literal(iteration_path)
    escaped_state = _escape_wiql_literal(state)
    wiql = (
        "SELECT [System.Id] "
        "FROM WorkItems "
        f"WHERE [System.TeamProject] = '{escaped_project}' "
        "AND [System.WorkItemType] = 'User Story' "
        f"AND [System.IterationPath] = '{escaped_iteration}' "
        f"AND [System.State] = '{escaped_state}' "
        "ORDER BY [Microsoft.VSTS.Common.ClosedDate] DESC"
    )

    wiql_result = client.request("POST", f"wit/wiql?api-version={API_VERSION}", payload={"query": wiql})
    ids = [item.get("id") for item in wiql_result.get("workItems", []) if item.get("id") is not None]

    if not ids:
        return {
            "query": {
                "iterationPath": iteration_path,
                "state": state,
                "workItemType": "User Story",
            },
            "summary": {
                "storyCount": 0,
                "totalStoryPoints": 0,
                "byAssignee": {},
                "topTags": [],
            },
            "stories": [],
        }

    requested_fields = [
        "System.Id",
        "System.Title",
        "System.State",
        "System.AssignedTo",
        "System.Tags",
        "Microsoft.VSTS.Scheduling.StoryPoints",
        "Microsoft.VSTS.Common.ClosedDate",
    ]
    raw_items: list[dict[str, Any]] = []
    for id_chunk in _chunked([int(item_id) for item_id in ids], 200):
        batch_payload = {
            "ids": id_chunk,
            "fields": requested_fields,
            "errorPolicy": "Omit",
        }
        batch_result = client.request("POST", f"wit/workitemsbatch?api-version={API_VERSION}", payload=batch_payload)
        raw_items.extend(batch_result.get("value", []))

    stories: list[dict[str, Any]] = []
    by_assignee: dict[str, int] = {}
    tag_counts: dict[str, int] = {}
    total_story_points = 0.0

    for item in raw_items:
        fields = item.get("fields", {})
        story_id = fields.get("System.Id", item.get("id"))
        assigned_to = _normalize_identity_name(fields.get("System.AssignedTo"))
        assignee_key = assigned_to or "Unassigned"

        story_points_raw = fields.get("Microsoft.VSTS.Scheduling.StoryPoints")
        try:
            story_points = float(story_points_raw) if story_points_raw is not None else 0.0
        except (TypeError, ValueError):
            story_points = 0.0

        total_story_points += story_points
        by_assignee[assignee_key] = by_assignee.get(assignee_key, 0) + 1

        tags_raw = fields.get("System.Tags") or ""
        tags = [t.strip() for t in str(tags_raw).split(";") if t.strip()]
        for tag in tags:
            tag_counts[tag] = tag_counts.get(tag, 0) + 1

        stories.append(
            {
                "id": story_id,
                "title": fields.get("System.Title"),
                "state": fields.get("System.State"),
                "closedDate": fields.get("Microsoft.VSTS.Common.ClosedDate"),
                "assignedTo": assigned_to,
                "storyPoints": story_points,
                "tags": tags,
                "url": build_work_item_url(client.cfg, story_id),
            }
        )

    stories.sort(key=lambda s: (s.get("closedDate") or ""), reverse=True)
    top_tags = sorted(tag_counts.items(), key=lambda x: (-x[1], x[0]))[:10]

    return {
        "query": {
            "iterationPath": iteration_path,
            "state": state,
            "workItemType": "User Story",
        },
        "summary": {
            "storyCount": len(stories),
            "totalStoryPoints": total_story_points,
            "byAssignee": dict(sorted(by_assignee.items(), key=lambda x: (-x[1], x[0]))),
            "topTags": [{"tag": tag, "count": count} for tag, count in top_tags],
        },
        "stories": stories,
    }


def cmd_export_closed_stories(args: argparse.Namespace, client: AdoClient) -> dict[str, Any]:
    from_date_iso = _validate_from_date(args.from_date)
    to_date_iso = _validate_to_date(args.to_date) if args.to_date else None
    if args.to_date and args.to_date < args.from_date:
        raise CliError("VALIDATION_ERROR", "--to-date must be on or after --from-date")

    query_to_date_iso = None
    if to_date_iso:
        query_to_date_iso = (dt.datetime.strptime(to_date_iso, "%Y-%m-%d") + dt.timedelta(days=1)).strftime("%Y-%m-%d")

    states = [state.strip() for state in args.states.split(",") if state.strip()]
    if not states:
        raise CliError("VALIDATION_ERROR", "--states cannot be empty")

    assignee = (args.assigned_to or client.cfg.assignee).strip()
    if not assignee:
        raise CliError("VALIDATION_ERROR", "--assigned-to is required (or set ADO_ASSIGNEE in .env)")

    output_path = args.output or f"data/ado_closed_stories_since_{args.from_date}.json"
    wiql = _build_closed_stories_wiql(client.cfg.project, args.work_item_type, states, from_date_iso, query_to_date_iso)

    wiql_result = client.request("POST", f"wit/wiql?api-version={API_VERSION}", payload={"query": wiql})
    ids = [item.get("id") for item in wiql_result.get("workItems", []) if item.get("id") is not None]

    requested_fields = [
        "System.Id",
        "System.Title",
        "System.State",
        "System.WorkItemType",
        "System.AssignedTo",
        "System.Tags",
        "Microsoft.VSTS.Common.ClosedDate",
        "System.Description",
        "Microsoft.VSTS.Common.AcceptanceCriteria",
    ]

    raw_items: list[dict[str, Any]] = []
    for id_chunk in _chunked([int(item_id) for item_id in ids], 200):
        batch_payload = {
            "ids": id_chunk,
            "fields": requested_fields,
            "errorPolicy": "Omit",
        }
        batch_result = client.request("POST", f"wit/workitemsbatch?api-version={API_VERSION}", payload=batch_payload)
        raw_items.extend(batch_result.get("value", []))

    items: list[dict[str, Any]] = []
    for item in raw_items:
        fields = item.get("fields", {})
        assigned_to = _normalize_identity_name(fields.get("System.AssignedTo"))
        if not _assignee_matches(assignee, assigned_to):
            continue

        closed_date_raw = fields.get("Microsoft.VSTS.Common.ClosedDate")
        closed_date = ""
        if closed_date_raw:
            try:
                parsed = dt.datetime.fromisoformat(str(closed_date_raw).replace("Z", "+00:00"))
                closed_date = f"{parsed.month}/{parsed.day}/{parsed.year}"
            except ValueError:
                closed_date = _sanitize_rich_text(closed_date_raw)

        items.append(
            {
                "id": item.get("id", ""),
                "date": closed_date,
                "title": _sanitize_rich_text(fields.get("System.Title")),
                "state": _sanitize_rich_text(fields.get("System.State")),
                "workItemType": _sanitize_rich_text(fields.get("System.WorkItemType")),
                "assignedTo": _sanitize_rich_text(assigned_to),
                "tags": _sanitize_rich_text(fields.get("System.Tags")),
                "description": _sanitize_rich_text(fields.get("System.Description")),
                "acceptanceCriteria": _sanitize_rich_text(fields.get("Microsoft.VSTS.Common.AcceptanceCriteria")),
            }
        )

    payload: dict[str, Any] = {
        "organization": client.cfg.org,
        "project": client.cfg.project,
        "fromDate": args.from_date,
        "fromDateIso": from_date_iso,
        "toDate": args.to_date,
        "toDateIso": to_date_iso,
        "workItemType": args.work_item_type,
        "states": states,
        "assignee": assignee,
        "count": len(items),
        "items": items,
    }

    output_dir = os.path.dirname(output_path)
    if output_dir:
        os.makedirs(output_dir, exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)
        f.write("\n")

    return {
        "count": len(items),
        "output": output_path,
        "fromDate": args.from_date,
        "toDate": args.to_date,
        "workItemType": args.work_item_type,
        "states": states,
        "assignee": assignee,
    }

def cmd_export_modifications(args: argparse.Namespace, client: AdoClient) -> dict[str, Any]:
    from_date_iso = _validate_from_date(args.from_date)
    to_date_iso = _validate_to_date(args.to_date) if args.to_date else None
    if to_date_iso and to_date_iso < from_date_iso:
        raise CliError("VALIDATION_ERROR", "--to-date must be on or after --from-date")

    from_datetime = dt.datetime.strptime(from_date_iso, "%Y-%m-%d").replace(tzinfo=dt.timezone.utc)
    to_datetime = (
        dt.datetime.strptime(to_date_iso, "%Y-%m-%d").replace(tzinfo=dt.timezone.utc)
        + dt.timedelta(days=1)
        if to_date_iso
        else None
    )
    user = args.user.strip()
    if not user:
        raise CliError("VALIDATION_ERROR", "--user cannot be empty")

    requested_fields = [
        "System.Id",
        "System.Title",
        "System.State",
        "System.WorkItemType",
        "System.ChangedDate",
        "System.ChangedBy",
    ]

    items: list[dict[str, Any]] = []
    continuation_token: str | None = None
    seen_tokens: set[str] = set()

    while True:
        params: dict[str, str] = {
            "fields": ",".join(requested_fields),
            "includeIdentityRef": "true",
            "$maxPageSize": "2000",
            "api-version": API_VERSION,
        }
        if continuation_token:
            params["continuationToken"] = continuation_token
        else:
            params["startDateTime"] = (from_datetime - dt.timedelta(seconds=1)).isoformat().replace("+00:00", "Z")

        batch_result = client.request(
            "GET",
            f"wit/reporting/workitemrevisions?{urllib.parse.urlencode(params)}",
        )
        reached_end = False
        for revision in batch_result.get("values", []):
            fields = revision.get("fields", {})
            changed_date_raw = fields.get("System.ChangedDate")
            if not changed_date_raw:
                continue
            try:
                changed_datetime = dt.datetime.fromisoformat(str(changed_date_raw).replace("Z", "+00:00"))
            except ValueError as exc:
                raise CliError("API_ERROR", f"ADO returned an invalid System.ChangedDate: {changed_date_raw}") from exc

            if changed_datetime < from_datetime:
                continue
            if to_datetime and changed_datetime >= to_datetime:
                reached_end = True
                continue

            changed_by = _normalize_identity_name(fields.get("System.ChangedBy"))
            if not _assignee_matches(user, changed_by):
                continue

            item_id = fields.get("System.Id", revision.get("id", ""))
            items.append(
                {
                    "id": item_id,
                    "revision": revision.get("rev"),
                    "changedDate": changed_date_raw,
                    "changedBy": changed_by,
                    "title": _sanitize_rich_text(fields.get("System.Title")),
                    "state": _sanitize_rich_text(fields.get("System.State")),
                    "workItemType": _sanitize_rich_text(fields.get("System.WorkItemType")),
                    "url": build_work_item_url(client.cfg, item_id),
                }
            )

        if batch_result.get("isLastBatch") or reached_end:
            break
        continuation_token = batch_result.get("continuationToken")
        if not continuation_token:
            raise CliError("API_ERROR", "ADO reporting API returned an incomplete batch without a continuation token")
        if continuation_token in seen_tokens:
            raise CliError("API_ERROR", "ADO reporting API repeated a continuation token")
        seen_tokens.add(continuation_token)

    items.sort(key=lambda item: item["changedDate"], reverse=True)

    return {
        "user": user,
        "fromDate": args.from_date,
        "toDate": args.to_date,
        "count": len(items),
        "items": items,
    }

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Azure DevOps custom CLI prototype")
    subparsers = parser.add_subparsers(dest="command", required=True)

    create = subparsers.add_parser("create", help="Create a work item")
    create.add_argument("--title", required=True, help="Work item title")
    create.add_argument("--type", default="User Story", help="Work item type")
    create.add_argument("--description", default="", help="Work item description")
    create.add_argument("--ac", "--acceptance-criteria", dest="acceptance_criteria", action="append", default=None, help="Acceptance criterion (can be specified multiple times)")
    create.add_argument("--area-path", default=None, help="Area path override")
    create.add_argument("--iteration-path", default=None, help="Iteration path override")
    create.add_argument("--parent-id", type=int, default=None, help="Parent work item id (creates hierarchy link)")
    create.add_argument("--assigned-to", dest="assigned_to", default=None, help="Assigned-to email or display name")
    create.add_argument("--secondary-assignee", dest="secondary_assignee", default=None, help="Secondary assignee email or display name")

    get = subparsers.add_parser("get", help="Get a work item")
    get.add_argument("--id", type=int, required=True, help="Work item id")

    update = subparsers.add_parser("update", help="Update a work item")
    update.add_argument("--id", type=int, required=True, help="Work item id")
    update.add_argument("--title", default=None)
    update.add_argument("--state", default=None)
    update.add_argument("--assigned-to", dest="assigned_to", default=None)
    update.add_argument("--secondary-assignee", dest="secondary_assignee", default=None, help="Secondary assignee email or display name")
    update.add_argument("--priority", type=int, default=None)
    update.add_argument("--story-points", type=float, dest="story_points", default=None)
    update.add_argument("--description", default=None)
    update.add_argument("--ac", "--acceptance-criteria", dest="acceptance_criteria", action="append", default=None, help="Acceptance criterion (can be specified multiple times)")
    update.add_argument("--add-comment", dest="add_comment", default=None)

    delete = subparsers.add_parser("delete", help="Delete a work item")
    delete.add_argument("--id", type=int, required=True, help="Work item id")

    comment = subparsers.add_parser("comment", help="Post a work item comment")
    comment.add_argument("--id", type=int, required=True, help="Work item id")
    comment.add_argument("--body", default="", help="Comment body")
    comment.add_argument("--body-file", default="", help="Comment body file")

    # --- Iteration commands ---
    iter_list = subparsers.add_parser("iteration-list", help="List team iterations")
    iter_list.add_argument("--team", default=None, help="Team name (overrides ADO_TEAM env var)")
    iter_list.add_argument("--timeframe", default=None, choices=["current", "past", "future"], help="Filter by timeframe")

    iter_get = subparsers.add_parser("iteration-get", help="Get a team iteration (includes sprint goal)")
    iter_get.add_argument("--id", required=True, help="Iteration GUID")
    iter_get.add_argument("--team", default=None, help="Team name (overrides ADO_TEAM env var)")

    iter_update_goal = subparsers.add_parser("iteration-update-goal", help="Update the sprint goal text of an iteration")
    iter_update_goal.add_argument("--id", required=True, help="Iteration GUID")
    iter_update_goal.add_argument("--goal", default=None, help="Sprint goal text")
    iter_update_goal.add_argument("--goal-file", dest="goal_file", default=None, help="File containing the sprint goal text")
    iter_update_goal.add_argument("--team", default=None, help="Team name (overrides ADO_TEAM env var)")

    iter_closed_stories = subparsers.add_parser(
        "iteration-closed-stories",
        help="List closed User Stories for a specific iteration path with summary data",
    )
    iter_closed_stories.add_argument(
        "--iteration-path",
        required=True,
        help="Exact ADO iteration path (e.g. CloudModernization\\SREO Artifactory\\Sprint 42)",
    )
    iter_closed_stories.add_argument(
        "--state",
        default="Closed",
        help="State to filter by (default: Closed)",
    )
    iter_pick = subparsers.add_parser(
        "iteration-pick",
        help="Pick nearest iteration under an area subtree (FY-aware)",
    )
    iter_pick.add_argument("--area-path", required=True)
    iter_pick.add_argument("--on", help="Reference date YYYY-MM-DD (default today)")

    export_closed_stories = subparsers.add_parser(
        "export-closed-stories",
        help="Export closed stories since a date to JSON",
    )
    export_closed_stories.add_argument(
        "--from-date",
        default="2025-01-01",
        help="Start date in YYYY-MM-DD format (inclusive)",
    )
    export_closed_stories.add_argument(
        "--to-date",
        default=None,
        help="End date in YYYY-MM-DD format (inclusive)",
    )
    export_closed_stories.add_argument(
        "--work-item-type",
        default="User Story",
        help="ADO work item type to query (default: User Story)",
    )
    export_closed_stories.add_argument(
        "--states",
        default="Closed,Resolved",
        help="Comma-separated states to include (default: Closed,Resolved)",
    )
    export_closed_stories.add_argument(
        "--assigned-to",
        dest="assigned_to",
        default=None,
        help="Assigned-to display name. Defaults to ADO_ASSIGNEE from .env",
    )
    export_closed_stories.add_argument(
        "--output",
        default="",
        help="Output JSON path. Default: data/ado_closed_stories_since_<from-date>.json",
    )
    export_mods = subparsers.add_parser("export-modifications", help="Export all modifications by a user in a date range")
    export_mods.add_argument("--user", required=True, help="User's display name (e.g. 'Jason Rueckert')")
    export_mods.add_argument("--from-date", required=True, help="Start date in YYYY-MM-DD format")
    export_mods.add_argument("--to-date", default=None, help="End date in YYYY-MM-DD format")

    return parser


def main(argv: list[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        cfg = load_config()
    except ValueError as e:
        print_json(envelope_error(args.command, None, "CONFIG_ERROR", str(e)))
        return 1

    try:
        client = AdoClient(cfg)
        if args.command == "create":
            result = cmd_create(args, client)
        elif args.command == "get":
            result = cmd_get(args, client)
        elif args.command == "update":
            result = cmd_update(args, client)
        elif args.command == "delete":
            result = cmd_delete(args, client)
        elif args.command == "comment":
            result = cmd_comment(args, client)
        elif args.command == "iteration-list":
            result = cmd_iteration_list(args, client)
        elif args.command == "iteration-get":
            result = cmd_iteration_get(args, client)
        elif args.command == "iteration-update-goal":
            result = cmd_iteration_update_goal(args, client)
        elif args.command == "iteration-closed-stories":
            result = cmd_iteration_closed_stories(args, client)
        elif args.command == "iteration-pick":
            result = cmd_iteration_pick(args, client)
        elif args.command == "export-closed-stories":
            result = cmd_export_closed_stories(args, client)
        elif args.command == "export-modifications":
            result = cmd_export_modifications(args, client)
        else:
            raise CliError("VALIDATION_ERROR", f"Unknown command: {args.command}")

        print_json(envelope_success(args.command, cfg, result))
        return 0
    except CliError as e:
        print_json(envelope_error(args.command, cfg, e.code, e.message))
        return 1
    except AdoApiError as e:
        code, message = map_api_error(e)
        print_json(envelope_error(args.command, cfg, code, message))
        return 1
    except Exception as e:  # pragma: no cover - defensive JSON contract fallback
        print_json(envelope_error(args.command, cfg, "API_ERROR", str(e) or "Unexpected error"))
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
