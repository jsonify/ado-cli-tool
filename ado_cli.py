#!/usr/bin/env python3
"""Azure DevOps CLI: the engine behind ADO Desk, also usable on its own.

Every command prints one JSON envelope to stdout. See docs/ENGINE_REFERENCE.md
for the commands, flags, result shapes and error codes.
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
    """Connection settings and defaults resolved from the environment by load_config().

    The token is excluded from repr() so it never appears in logs or tracebacks.
    Optional fields are empty strings (never None) when unset.
    """
    token: str = field(repr=False)
    org: str
    project: str
    team: str
    assignee: str
    area_path: str
    iteration_path: str
    ssl_cert_file: str
    ssl_cert_dir: str = ""


def utc_timestamp() -> str:
    """Return the current UTC time as an ISO 8601 string with a +00:00 offset.

    Used for the "timestamp" field of every JSON envelope.
    """
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

    def inline_code(escaped: str) -> str:
        """Turn `code` spans in already-escaped text into <code> elements."""
        return re.sub(
            r'`([^`]+)`',
            r'<code style="background-color: #f6f8fa; padding: 2px 4px; border-radius: 3px;">\1</code>',
            escaped,
        )

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
            html_lines.append(f"<li>{inline_code(content)}</li>")
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
                    html_lines.append(f"{inline_code(html.escape(line))}<br />")
    
    if in_list:
        html_lines.append(f"</{list_type}>")
    if in_code_block:
        html_lines.append("</code></pre>")

    return "".join(html_lines)


def envelope_success(command: str, cfg: Config, result: Any) -> dict[str, Any]:
    """Build the success envelope printed to stdout for a completed command.

    Args:
        command: Subcommand name (e.g. "create").
        cfg: Active configuration; supplies "organization" and "project".
        result: Command-specific payload returned by a cmd_* function.

    Returns:
        {"success": True, "command", "timestamp", "organization", "project", "result"}
    """
    return {
        "success": True,
        "command": command,
        "timestamp": utc_timestamp(),
        "organization": cfg.org,
        "project": cfg.project,
        "result": result,
    }


def envelope_error(command: str, cfg: Config | None, code: str, message: str) -> dict[str, Any]:
    """Build the failure envelope printed to stdout when a command fails.

    Args:
        command: Subcommand name.
        cfg: Active configuration, or None when config loading itself failed
            (organization and project are then null).
        code: Machine-readable error code (see map_api_error and CliError).
        message: Human-readable error message.

    Returns:
        {"success": False, "command", "timestamp", "organization", "project",
        "error": {"code", "message"}}
    """
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
    """Write a dict to stdout as pretty-printed JSON (2-space indent, key order preserved).

    This is the only stdout output the CLI produces on a handled path.
    """
    print(json.dumps(data, indent=2, sort_keys=False))


def normalize_org(raw_org: str) -> str:
    """Turn ADO_ORG into a full organization base URL with no trailing slash.

    Accepts either an https:// URL (returned as-is minus the trailing slash) or a
    bare organization name, which becomes https://dev.azure.com/<name>.

    Raises:
        ValueError: The value uses another scheme (http://, file://, ...), starts
            with "/", or is an https URL without a host.
    """
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
    """Return a non-empty environment variable, trying an optional fallback name.

    Currently unused; load_config() uses require_env_any().

    Raises:
        ValueError: Neither variable is set to a non-blank value.
    """
    value = os.getenv(primary, "").strip()
    if value:
        return value
    if fallback:
        value = os.getenv(fallback, "").strip()
        if value:
            return value
    raise ValueError(f"Missing required environment variable: {primary}" + (f" or {fallback}" if fallback else ""))


def require_env_any(*names: str) -> str:
    """Return the first non-blank value among the given environment variable names.

    Values are stripped of surrounding whitespace.

    Raises:
        ValueError: None of the variables is set to a non-blank value.
    """
    for name in names:
        value = os.getenv(name, "").strip()
        if value:
            return value
    raise ValueError("Missing required environment variable: " + " or ".join(names))


def _strip_optional_quotes(value: str) -> str:
    """Remove one pair of matching surrounding single or double quotes from a .env value."""
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
        return value[1:-1]
    return value


def load_dotenv_defaults() -> None:
    """Load .env values without overwriting already-exported environment variables.

    File selection: if ADO_ENV_FILE is set, only that file is considered (a missing
    file is silently ignored). Otherwise the first existing file among
    ./.env (current working directory) and <script dir>/../.env is used.

    Parsing: blank lines and lines starting with "#" are skipped, an optional
    leading "export " is removed, and one pair of surrounding quotes is stripped.
    Inline comments and escape sequences are not processed.
    """
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
    """Build a Config from the environment, after applying .env defaults.

    Required (first non-blank name wins):
        token:   ADO_TOKEN, AZURE_DEVOPS_PAT, ADO_PAT
        org:     ADO_ORG, AZURE_DEVOPS_ORG (normalized by normalize_org)
        project: ADO_PROJECT, AZURE_DEVOPS_PROJECT
    Optional: ADO_TEAM, ADO_ASSIGNEE, ADO_AREA_PATH, ADO_ITERATION_PATH,
    SSL_CERT_FILE (a CA bundle file), SSL_CERT_DIR (a directory of CA certificates).

    Raises:
        ValueError: A required variable is missing, ADO_ORG is invalid, SSL_CERT_FILE
            is not an existing file or SSL_CERT_DIR is not an existing directory.
            main() reports this as CONFIG_ERROR before any command runs.
    """
    load_dotenv_defaults()

    token = require_env_any("ADO_TOKEN", "AZURE_DEVOPS_PAT", "ADO_PAT")
    org = normalize_org(require_env_any("ADO_ORG", "AZURE_DEVOPS_ORG"))
    project = require_env_any("ADO_PROJECT", "AZURE_DEVOPS_PROJECT")
    team = os.getenv("ADO_TEAM", "").strip()
    assignee = os.getenv("ADO_ASSIGNEE", "").strip()
    area_path = os.getenv("ADO_AREA_PATH", "").strip()
    iteration_path = os.getenv("ADO_ITERATION_PATH", "").strip()
    ssl_cert_file = os.getenv("SSL_CERT_FILE", "").strip()
    if ssl_cert_file and not os.path.isfile(ssl_cert_file):
        raise ValueError(f"SSL_CERT_FILE must be an existing CA bundle file: {ssl_cert_file}")
    ssl_cert_dir = os.getenv("SSL_CERT_DIR", "").strip()
    if ssl_cert_dir and not os.path.isdir(ssl_cert_dir):
        raise ValueError(f"SSL_CERT_DIR must be an existing directory: {ssl_cert_dir}")

    return Config(
        token=token,
        org=org,
        project=project,
        team=team,
        assignee=assignee,
        area_path=area_path,
        iteration_path=iteration_path,
        ssl_cert_file=ssl_cert_file,
        ssl_cert_dir=ssl_cert_dir,
    )


class AdoClient:
    """Minimal Azure DevOps REST client built on urllib (standard library only).

    Project-scoped calls go through request(); team-scoped calls (team settings,
    iterations) go through team_request(). Both return parsed JSON or raise
    AdoApiError.
    """
    def __init__(self, cfg: Config) -> None:
        """Prepare the project base URL, the Basic auth header and the TLS context.

        The PAT is sent as Basic auth with an empty user name. SSL_CERT_FILE and
        SSL_CERT_DIR (validated by load_config) become the context's cafile and capath;
        when neither is set, the system defaults are used.
        """
        self.cfg = cfg
        project_encoded = urllib.parse.quote(cfg.project, safe="")
        self.base_url = f"{cfg.org}/{project_encoded}/_apis"
        auth = base64.b64encode(f":{cfg.token}".encode("utf-8")).decode("utf-8")
        self.auth_header = f"Basic {auth}"
        self.ssl_context = ssl.create_default_context(
            cafile=cfg.ssl_cert_file or None,
            capath=cfg.ssl_cert_dir or None,
        )

    def _dispatch(self, method: str, url: str, payload: Any = None, content_type: str | None = None) -> Any:
        """Send one HTTP request and return the parsed JSON response.

        Only https URLs with a host are allowed (CWE-939). A non-None payload is
        JSON-encoded and sent with content_type (default "application/json"). The
        timeout is 60 seconds.

        Returns:
            The decoded JSON body, or {} for an empty body.

        Raises:
            AdoApiError: Non-https URL (status None); HTTP status >= 400 (message taken
                from the ADO "message" field when present); a non-JSON success body;
                or a network error or timeout (status None).
        """
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
        """Call a project-scoped endpoint: {org}/{project}/_apis/{path}.

        Args:
            method: HTTP verb.
            path: Path relative to _apis, including the query string (api-version etc.).
            payload: Optional JSON-serializable body.
            content_type: Body content type, e.g. "application/json-patch+json".
        """
        url = f"{self.base_url}/{path.lstrip('/')}"
        return self._dispatch(method, url, payload, content_type)

    def team_request(self, method: str, path: str, team: str | None = None, payload: Any = None, content_type: str | None = None) -> Any:
        """Issue a request against the team-scoped work API (teamsettings, iterations, etc.).

        URL: {org}/{project}/{team}/_apis/{path}. The team is the explicit argument,
        falling back to ADO_TEAM.

        Raises:
            CliError: CONFIG_ERROR when no team is available.
            AdoApiError: As in _dispatch.
        """
        resolved_team = team or self.cfg.team
        if not resolved_team:
            raise CliError("CONFIG_ERROR", "ADO_TEAM environment variable is required for iteration commands (or pass --team)")
        project_encoded = urllib.parse.quote(self.cfg.project, safe="")
        team_encoded = urllib.parse.quote(resolved_team, safe="")
        team_base = f"{self.cfg.org}/{project_encoded}/{team_encoded}/_apis"
        url = f"{team_base}/{path.lstrip('/')}"
        return self._dispatch(method, url, payload, content_type)


class AdoApiError(Exception):
    """An HTTP, network or response-format failure from Azure DevOps.

    Attributes:
        status: HTTP status code, or None for non-HTTP failures.
        message: Error text (the ADO "message" field when available).
    """
    def __init__(self, status: int | None, message: str) -> None:
        self.status = status
        self.message = message
        super().__init__(message)


class CliError(Exception):
    """A failure detected by the CLI itself, carrying the envelope error code.

    Codes raised in this module: VALIDATION_ERROR, CONFIG_ERROR, API_ERROR,
    NO_ITERATION_MATCH.
    """
    def __init__(self, code: str, message: str) -> None:
        self.code = code
        self.message = message
        super().__init__(message)


# The code a 404 maps to, per command. Commands not listed report NOT_FOUND.
NOT_FOUND_CODES = {
    "get": "STORY_NOT_FOUND",
    "update": "STORY_NOT_FOUND",
    "delete": "STORY_NOT_FOUND",
    "comment": "STORY_NOT_FOUND",
    "iteration-get": "ITERATION_NOT_FOUND",
    "iteration-update-goal": "ITERATION_NOT_FOUND",
}


def map_api_error(err: AdoApiError, command: str | None = None) -> tuple[str, str]:
    """Map an AdoApiError to an envelope (code, message) pair.

    401/403 -> AUTH_ERROR; 404 -> the command's code in NOT_FOUND_CODES
    (STORY_NOT_FOUND for work item commands, ITERATION_NOT_FOUND for commands
    that take an iteration GUID), else NOT_FOUND; 400 -> VALIDATION_ERROR;
    anything else -> API_ERROR.
    """
    if err.status in (401, 403):
        return ("AUTH_ERROR", err.message)
    if err.status == 404:
        return (NOT_FOUND_CODES.get(command or "", "NOT_FOUND"), err.message)
    if err.status == 400:
        return ("VALIDATION_ERROR", err.message)
    return ("API_ERROR", err.message)


def build_work_item_url(cfg: Config, item_id: int | str) -> str:
    """Return the browser URL for a work item: {org}/{project}/_workitems/edit/{id}."""
    project_encoded = urllib.parse.quote(cfg.project, safe="")
    return f"{cfg.org}/{project_encoded}/_workitems/edit/{item_id}"


def _escape_wiql_literal(value: str) -> str:
    """Escape a value for use inside a single-quoted WIQL string by doubling single quotes."""
    return value.replace("'", "''")


def _validate_date(value: str, *, flag: str) -> str:
    """Check a YYYY-MM-DD date argument and return it zero-padded.

    strptime accepts unpadded parts, so "2025-1-5" becomes "2025-01-05".

    Raises:
        CliError: VALIDATION_ERROR naming the offending --<flag>.
    """
    try:
        parsed = dt.datetime.strptime(value, "%Y-%m-%d")
    except ValueError as exc:
        raise CliError("VALIDATION_ERROR", f"Invalid --{flag} '{value}'. Use YYYY-MM-DD.") from exc
    return parsed.strftime("%Y-%m-%d")


def _validate_from_date(from_date: str) -> str:
    """Validate --from-date (see _validate_date)."""
    return _validate_date(from_date, flag="from-date")


def _validate_to_date(to_date: str) -> str:
    """Validate --to-date (see _validate_date)."""
    return _validate_date(to_date, flag="to-date")


def _sanitize_rich_text(value: Any) -> str:
    """Flatten an ADO rich-text field to plain text.

    Tags are replaced with spaces, HTML entities are unescaped and whitespace is
    collapsed. None becomes "".
    """
    if value is None:
        return ""
    text = str(value)
    text = re.sub(r"<[^>]+>", " ", text)
    text = html.unescape(text)
    return re.sub(r"\s+", " ", text).strip()


def _build_closed_stories_wiql(
    project: str,
    work_item_types: list[str],
    states: list[str],
    from_date_iso: str,
    to_date_iso: str | None,
) -> str:
    """Build the WIQL query for export-closed-stories.

    Selects ids in the project with any of the work item types and any of the
    states, completed in the date range: ClosedDate >= from_date_iso and, if given,
    <= to_date_iso. WIQL compares date-only literals at day precision, so both ends
    are inclusive days. Azure DevOps only sets ClosedDate in the Closed state, so
    items in any of the other states (Resolved, by default) match on ResolvedDate
    instead.
    """
    def in_range(date_field: str) -> str:
        condition = f"[{date_field}] >= '{from_date_iso}'"
        if to_date_iso:
            condition += f" AND [{date_field}] <= '{to_date_iso}'"
        return condition

    escaped_states = ", ".join(f"'{_escape_wiql_literal(s)}'" for s in states)
    escaped_types = ", ".join(f"'{_escape_wiql_literal(t)}'" for t in work_item_types)
    escaped_project = _escape_wiql_literal(project)

    completed = f"({in_range('Microsoft.VSTS.Common.ClosedDate')})"
    open_states = [s for s in states if s.lower() != "closed"]
    if open_states:
        escaped_open = ", ".join(f"'{_escape_wiql_literal(s)}'" for s in open_states)
        completed = (
            f"({completed} OR ([System.State] IN ({escaped_open}) "
            f"AND {in_range('Microsoft.VSTS.Common.ResolvedDate')}))"
        )

    return (
        "SELECT [System.Id] "
        "FROM WorkItems "
        f"WHERE [System.TeamProject] = '{escaped_project}' "
        f"AND [System.WorkItemType] IN ({escaped_types}) "
        f"AND [System.State] IN ({escaped_states}) "
        f"AND {completed}"
    )

def _assignee_matches(expected: str, actual: str | None) -> bool:
    """Loosely compare a person's name against an identity display name.

    After collapsing whitespace and case-folding, it matches when the strings are
    equal, when both split into the same set of alphanumeric tokens ("Doe, Jane"
    equals "Jane Doe"), or when expected has at least 2 tokens and all of them
    appear in actual. Tokens are split on anything outside [a-z0-9], so non-ASCII
    letters act as separators. Returns False if either side is empty.
    """
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
    """Split a list into consecutive slices of at most size items.

    Used to stay within the 200-id limit of the workitemsbatch API.
    """
    return [values[i : i + size] for i in range(0, len(values), size)]


def cmd_create(args: argparse.Namespace, client: AdoClient) -> dict[str, Any]:
    """Create a work item (command: create).

    POST wit/workitems/${type} as a JSON Patch. Always sets Title, Description
    (Markdown converted by format_description_html; "" when omitted) and
    WorkItemType. AreaPath and IterationPath fall back to ADO_AREA_PATH and
    ADO_ITERATION_PATH when the flag is omitted; passing an empty value skips the
    field. --parent-id adds a Hierarchy-Reverse (child -> parent) link. --ac values
    become an HTML list in AcceptanceCriteria. --secondary-assignee writes
    Custom.SecondaryAssignee, which must exist in the process template or ADO
    returns 400.

    Args:
        args: title, type, description, acceptance_criteria, area_path,
            iteration_path, parent_id, assigned_to, secondary_assignee.
        client: Authenticated AdoClient.

    Returns:
        {"id", "title", "state", "parentId", "assignedTo", "secondaryAssignee",
        "url"}. assignedTo and secondaryAssignee are whatever ADO returns (usually
        an identity object), and url is the browser URL.

    Raises:
        CliError: API_ERROR if the response has no id.
    """
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
    """Fetch one work item with all fields (command: get).

    GET wit/workitems/{id}?$expand=all.

    Returns:
        {"id", "title", "state", "assignedTo", "url", "fields"}. url is the REST
        API URL returned by ADO, not the browser URL. fields is the raw ADO field
        map. Relations are fetched but not included in the result.
    """
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
    """Update fields on a work item (command: update).

    PATCH wit/workitems/{id} with one JSON Patch "add" op (which replaces the
    value) for each flag that is not None. An explicit empty string is sent as
    an empty value. Description is converted from Markdown; --ac replaces the
    whole AcceptanceCriteria list; --add-comment writes System.History, so it
    shows up in the work item's Discussion.

    Args:
        args: id plus any of title, state, assigned_to, secondary_assignee,
            description, acceptance_criteria, add_comment, priority (int),
            story_points (float).
        client: Authenticated AdoClient.

    Returns:
        {"id", "title", "state", "url", "updatedFieldsCount"}. url is the browser
        URL, and updatedFieldsCount is the number of patch ops sent.

    Raises:
        CliError: VALIDATION_ERROR when no update flags are given.
    """
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
    """Delete a work item (command: delete).

    DELETE wit/workitems/{id} without destroy=true, so the item goes to the
    Recycle Bin and can be restored.

    Returns:
        {"id", "deleted": True, "response"}. response is the raw ADO response.
    """
    path = f"wit/workitems/{args.id}?api-version={API_VERSION}"
    data = client.request("DELETE", path)
    return {
        "id": args.id,
        "deleted": True,
        "response": data,
    }


def cmd_comment(args: argparse.Namespace, client: AdoClient) -> dict[str, Any]:
    """Add a comment to a work item (command: comment).

    POST wit/workItems/{id}/comments (api-version 7.1-preview.3). --body-file,
    when given, replaces --body. The text is sent unchanged: ADO renders it as
    HTML and does not convert Markdown.

    Returns:
        {"id", "commentId"}.

    Raises:
        CliError: VALIDATION_ERROR when the body is empty.
    """
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
    r"""Pick the current or next monthly iteration under a path prefix (command: iteration-pick).

    Reads the project iteration tree (classificationnodes/iterations, $depth=4)
    and builds backslash-separated paths starting with the root node's name
    (normally the project name). Despite the flag name, --area-path is matched as
    a prefix of these iteration paths, not of area paths.

    Selection:
      1. Keep paths ending in "\FY##\<Month> <YYYY>" (full English month name).
      2. Work out the fiscal year of the reference date (--on, or today). The year
         starts in September: Sep 2025 to Aug 2026 is FY26. Keep only paths
         containing that label, or all candidates if none match.
      3. Return the earliest iteration whose month is on or after the reference
         month, or the latest one if all are in the past.

    Returns:
        {"path", "name" (e.g. "October 2025"), "fiscalYear" (e.g. "FY26")}.

    Raises:
        CliError: VALIDATION_ERROR for a blank --area-path or a malformed --on;
            NO_ITERATION_MATCH when nothing under the prefix or nothing in the
            expected format is found.
    """
    area = (args.area_path or "").strip()
    if not area:
        raise CliError("VALIDATION_ERROR", "--area-path is required")

    on = getattr(args, "on", None)
    ref = dt.datetime.strptime(_validate_date(on, flag="on"), "%Y-%m-%d") if on else dt.datetime.now()

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

    valid: list[tuple[str, dt.datetime]] = []
    for p, my in fy_matches:
        try:
            valid.append((p, dt.datetime.strptime(my, "%B %Y")))
        except ValueError:
            continue
    if not valid:
        raise CliError("NO_ITERATION_MATCH", f"No valid month-year in {fy_label}")

    ref_month = dt.datetime(ref.year, ref.month, 1)
    valid.sort(key=lambda x: x[1])
    chosen = next((v for v in valid if v[1] >= ref_month), valid[-1])

    return {
        "path": chosen[0],
        "name": chosen[1].strftime("%B %Y"),
        "fiscalYear": fy_label,
    }

def cmd_iteration_list(args: argparse.Namespace, client: AdoClient) -> dict[str, Any]:
    """List the iterations selected for a team (command: iteration-list).

    GET {team}/_apis/work/teamsettings/iterations, optionally with
    $timeframe=current|past|future. Only iterations the team has subscribed to are
    returned, not the whole project tree.

    Returns:
        {"count", "iterations": [{"id", "name", "path", "startDate", "finishDate",
        "timeFrame"}]}. id is the iteration GUID used by iteration-get. Dates are
        ISO strings or null.

    Raises:
        CliError: CONFIG_ERROR when neither --team nor ADO_TEAM is set.
    """
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
    """Fetch one team iteration by GUID (command: iteration-get).

    GET {team}/_apis/work/teamsettings/iterations/{id}.

    Returns:
        {"id", "name", "path", "startDate", "finishDate", "timeFrame", "goalText",
        "raw"}. goalText is read from attributes.goalText and is null when ADO does
        not return it. raw is the full ADO response.

    Raises:
        CliError: CONFIG_ERROR when no team is available.
    """
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
    """Set the sprint goal text of a team iteration (command: iteration-update-goal).

    PATCH {team}/_apis/work/teamsettings/iterations/{id} with
    {"attributes": {"goalText": ...}}. --goal-file, when given, replaces --goal,
    and its contents are stripped. An empty --goal= is allowed and clears the goal.

    Returns:
        {"id", "name", "goalText"} as returned by ADO.

    Raises:
        CliError: VALIDATION_ERROR when neither flag is given; CONFIG_ERROR when no
            team is available.
    """
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
    """Reduce an ADO identity field to a display string.

    Identity objects return displayName, falling back to uniqueName. Strings are
    returned as-is. Anything else returns None.
    """
    if isinstance(value, dict):
        return value.get("displayName") or value.get("uniqueName")
    if isinstance(value, str):
        return value
    return None


def _identity_matches(expected: str, value: Any) -> bool:
    """Match a person's name or email against an ADO identity field.

    Checks the identity's displayName and uniqueName (usually the email), so
    ADO_ASSIGNEE can hold either. A string identity ("Jane Doe <jane@example.com>")
    is checked whole and by the email inside the angle brackets. An email must match
    exactly (ignoring case); a name is compared with _assignee_matches.
    """
    if isinstance(value, dict):
        candidates = [value.get("displayName"), value.get("uniqueName")]
    elif isinstance(value, str):
        email = re.search(r"<([^<>]+)>", value)
        candidates = [value, email.group(1) if email else None]
    else:
        return False
    candidates = [candidate for candidate in candidates if candidate]
    if "@" in expected:
        wanted = expected.strip().casefold()
        return any(candidate.strip().casefold() == wanted for candidate in candidates)
    return any(_assignee_matches(expected, candidate) for candidate in candidates)


def cmd_iteration_closed_stories(args: argparse.Namespace, client: AdoClient) -> dict[str, Any]:
    """Summarize User Stories in one iteration with a given state (command: iteration-closed-stories).

    A WIQL query matches the work item type "User Story" (hard-coded),
    IterationPath equal to --iteration-path (an exact match, so child iterations
    are excluded) and State equal to --state (default "Closed"). Fields are then
    fetched in batches of 200 through workitemsbatch.

    Returns:
        {"query": {"iterationPath", "state", "workItemType"},
         "summary": {"storyCount", "totalStoryPoints", "byAssignee" (name -> count,
                     most first; "Unassigned" when empty), "topTags" (up to 10
                     [{"tag", "count"}])},
         "stories": [{"id", "title", "state", "closedDate", "assignedTo" (display
                      name), "storyPoints" (0.0 if unset), "tags" (list), "url"}]}
        Stories are sorted by closedDate, newest first. When nothing matches, the
        same shape is returned with zeros and empty lists.
    """
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
    """List one person's closed work items in a date range and write them to a JSON file (command: export-closed-stories).

    A WIQL query matches the types (--work-item-type, comma-separated), the states
    and the completion date within
    [--from-date, --to-date], with the end date inclusive: ClosedDate for Closed
    items, ResolvedDate for items in the other states (ADO only sets ClosedDate on
    Closed). Fields are batch-fetched,
    then filtered on the client with _identity_matches, because the query does not
    filter by assignee. Rich-text fields are flattened to plain text, and the
    completion date is written as M/D/YYYY. Items are sorted newest first.

    The file is written to --output (default
    data/ado_closed_stories_since_<from-date>.json, relative to the working
    directory) unless --no-output is given. Parent directories are created. The
    file holds {"organization", "project", "fromDate", "fromDateIso", "toDate",
    "toDateIso", "workItemType", "workItemTypes", "states", "assignee", "count",
    "items": [{"id", "date", "title", "state", "workItemType", "assignedTo",
    "tags", "description", "acceptanceCriteria", "url"}]}.

    Returns:
        {"count", "output" (None with --no-output), "fromDate", "toDate",
        "workItemType", "workItemTypes", "states", "assignee", "items"}, with the
        same items as the file.

    Raises:
        CliError: VALIDATION_ERROR for bad dates, --to-date before --from-date,
            empty --work-item-type or --states, or no assignee (--assigned-to or
            ADO_ASSIGNEE).
    """
    from_date_iso = _validate_from_date(args.from_date)
    to_date_iso = _validate_to_date(args.to_date) if args.to_date else None
    if to_date_iso and to_date_iso < from_date_iso:
        raise CliError("VALIDATION_ERROR", "--to-date must be on or after --from-date")

    work_item_types = [t.strip() for t in args.work_item_type.split(",") if t.strip()]
    if not work_item_types:
        raise CliError("VALIDATION_ERROR", "--work-item-type cannot be empty")
    states = [state.strip() for state in args.states.split(",") if state.strip()]
    if not states:
        raise CliError("VALIDATION_ERROR", "--states cannot be empty")

    assignee = (args.assigned_to or client.cfg.assignee).strip()
    if not assignee:
        raise CliError("VALIDATION_ERROR", "--assigned-to is required (or set ADO_ASSIGNEE in .env)")

    output_path = None if args.no_output else (args.output or f"data/ado_closed_stories_since_{from_date_iso}.json")
    wiql = _build_closed_stories_wiql(client.cfg.project, work_item_types, states, from_date_iso, to_date_iso)

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
        "Microsoft.VSTS.Common.ResolvedDate",
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

    # (raw completion date, item) pairs. ADO returns UTC ISO 8601 strings, so they sort as text.
    dated_items: list[tuple[str, dict[str, Any]]] = []
    for item in raw_items:
        fields = item.get("fields", {})
        assigned_to = _normalize_identity_name(fields.get("System.AssignedTo"))
        if not _identity_matches(assignee, fields.get("System.AssignedTo")):
            continue

        # Closed items carry ClosedDate; Resolved (and other non-Closed) items only ResolvedDate.
        completed_raw = fields.get("Microsoft.VSTS.Common.ClosedDate") or fields.get("Microsoft.VSTS.Common.ResolvedDate")
        completed_date = ""
        if completed_raw:
            try:
                parsed = dt.datetime.fromisoformat(str(completed_raw).replace("Z", "+00:00"))
                completed_date = f"{parsed.month}/{parsed.day}/{parsed.year}"
            except ValueError:
                completed_date = _sanitize_rich_text(completed_raw)

        dated_items.append(
            (
                str(completed_raw or ""),
                {
                    "id": item.get("id", ""),
                    "date": completed_date,
                    "title": _sanitize_rich_text(fields.get("System.Title")),
                    "state": _sanitize_rich_text(fields.get("System.State")),
                    "workItemType": _sanitize_rich_text(fields.get("System.WorkItemType")),
                    "assignedTo": _sanitize_rich_text(assigned_to),
                    "tags": _sanitize_rich_text(fields.get("System.Tags")),
                    "description": _sanitize_rich_text(fields.get("System.Description")),
                    "acceptanceCriteria": _sanitize_rich_text(fields.get("Microsoft.VSTS.Common.AcceptanceCriteria")),
                    "url": build_work_item_url(client.cfg, item.get("id", "")),
                },
            )
        )

    # Newest first. workitemsbatch doesn't keep the query's order, so sort here.
    dated_items.sort(key=lambda pair: pair[0], reverse=True)
    items = [item for _, item in dated_items]

    payload: dict[str, Any] = {
        "organization": client.cfg.org,
        "project": client.cfg.project,
        "fromDate": args.from_date,
        "fromDateIso": from_date_iso,
        "toDate": args.to_date,
        "toDateIso": to_date_iso,
        "workItemType": args.work_item_type,
        "workItemTypes": work_item_types,
        "states": states,
        "assignee": assignee,
        "count": len(items),
        "items": items,
    }

    if output_path:
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
        "workItemTypes": work_item_types,
        "states": states,
        "assignee": assignee,
        "items": items,
    }

def cmd_export_modifications(args: argparse.Namespace, client: AdoClient) -> dict[str, Any]:
    """List every revision a user made in a date range (command: export-modifications).

    Pages through wit/reporting/workitemrevisions (up to 2000 per page) starting at
    --from-date, following continuationToken until isLastBatch, and skips revisions
    outside [--from-date, --to-date]. Revisions are matched to --user on
    System.ChangedBy with _identity_matches. Every revision in the project in the
    range is downloaded, so wide ranges can be slow.

    Nothing is written to disk. The items are returned in the envelope.

    Returns:
        {"user", "fromDate", "toDate", "count", "items": [{"id", "revision",
        "changedDate" (raw ISO), "changedBy", "title", "state", "workItemType",
        "url"}]}. There is one item per revision, so a work item can appear more
        than once. Items are sorted by changedDate, newest first.

    Raises:
        CliError: VALIDATION_ERROR for bad dates or a blank --user; API_ERROR for
            an invalid ChangedDate or broken pagination (missing or repeated
            continuation token).
    """
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
                continue

            changed_by = _normalize_identity_name(fields.get("System.ChangedBy"))
            if not _identity_matches(user, fields.get("System.ChangedBy")):
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

        # The reporting API pages by watermark, which is not guaranteed to follow
        # System.ChangedDate, so a revision past --to-date doesn't mean the rest are.
        # Read to the last batch rather than risk silently dropping in-range revisions.
        if batch_result.get("isLastBatch"):
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

# Work item states that never go in the weekly report.
WEEKLY_EXCLUDED_STATES = ("Removed",)
# States that mean an item hasn't been started; open items in other states are listed first under "Next week".
WEEKLY_NOT_STARTED_STATES = ("New", "Proposed", "To Do", "Approved")


def _split_states(raw: str, *, flag: str) -> list[str]:
    """Split a comma-separated --<flag> value into trimmed, non-empty state names.

    Raises:
        CliError: VALIDATION_ERROR when no state is left.
    """
    states = [state.strip() for state in raw.split(",") if state.strip()]
    if not states:
        raise CliError("VALIDATION_ERROR", f"--{flag} cannot be empty")
    return states


def _local_date(value: Any) -> dt.date | None:
    """The local calendar day of an ADO UTC timestamp, or None if it is missing or unreadable.

    The engine runs on the user's machine, so local time puts a Friday-evening close on Friday.
    """
    if not value:
        return None
    try:
        parsed = dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.astimezone().date()


def _build_weekly_report_wiql(
    project: str,
    area_path: str,
    since_iso: str,
    done_states: list[str],
    use_me: bool,
    exclude_types: list[str] | None = None,
) -> str:
    """Build the WIQL query for one area path of weekly-report.

    Selects items under the area path (child areas included) that changed on or
    after since_iso or are still open (not in done_states), excluding Removed and
    any work item type in exclude_types. With use_me the query keeps only items
    assigned to the PAT's owner (@Me); otherwise the caller filters by assignee on
    the client.
    """
    escaped_done = ", ".join(f"'{_escape_wiql_literal(s)}'" for s in done_states)
    escaped_excluded = ", ".join(f"'{_escape_wiql_literal(s)}'" for s in WEEKLY_EXCLUDED_STATES)
    query = (
        "SELECT [System.Id] "
        "FROM WorkItems "
        f"WHERE [System.TeamProject] = '{_escape_wiql_literal(project)}' "
        f"AND [System.AreaPath] UNDER '{_escape_wiql_literal(area_path)}' "
        f"AND [System.State] NOT IN ({escaped_excluded}) "
        f"AND ([System.ChangedDate] >= '{since_iso}' OR [System.State] NOT IN ({escaped_done}))"
    )
    if exclude_types:
        escaped_types = ", ".join(f"'{_escape_wiql_literal(t)}'" for t in exclude_types)
        query += f" AND [System.WorkItemType] NOT IN ({escaped_types})"
    if use_me:
        query += " AND [System.AssignedTo] = @Me"
    return query


def _state_transitions(client: AdoClient, item_id: int, from_date: dt.date, to_date: dt.date) -> tuple[str, str] | None:
    """The (first old state, last new state) of an item's state changes within [from_date, to_date].

    Reads wit/workItems/{id}/updates. The old state is "" when the item was created in the range.
    Returns None when the state did not change in the range.
    """
    updates = client.request("GET", f"wit/workItems/{item_id}/updates?$top=200&api-version={API_VERSION}")
    changes: list[tuple[str, str]] = []
    for update in updates.get("value", []):
        fields = update.get("fields") or {}
        state = fields.get("System.State")
        if not isinstance(state, dict) or "newValue" not in state:
            continue
        changed = fields.get("System.ChangedDate")
        day = _local_date(changed.get("newValue") if isinstance(changed, dict) else update.get("revisedDate"))
        if day is None or not from_date <= day <= to_date:
            continue
        changes.append((str(state.get("oldValue") or ""), str(state.get("newValue") or "")))
    if not changes:
        return None
    return (changes[0][0], changes[-1][1])


def _weekly_markdown(report: dict[str, Any]) -> str:
    """Render a weekly-report result as Markdown, one ## section per area path."""
    def link(item: dict[str, Any]) -> str:
        title = item["title"].replace("[", "\\[").replace("]", "\\]")
        return f"[#{item['id']}]({item['url']}) {title}"

    lines = [f"# Weekly report: {report['rangeLabel']}", ""]
    for section in report["sections"]:
        lines += [f"## {section['name']}", ""]
        for heading, key in WEEKLY_SECTIONS:
            items = section[key]
            lines.append(f"### {heading}")
            lines.append("")
            if not items:
                lines.append("- None")
            for item in items:
                lines.append(f"- {link(item)} ({_weekly_detail(key, item)})")
            lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def _weekly_html(report: dict[str, Any]) -> str:
    """Render a weekly-report result as simple HTML for pasting into an email."""
    esc = html.escape
    parts = [f"<h1>Weekly report: {esc(report['rangeLabel'])}</h1>"]
    for section in report["sections"]:
        parts.append(f"<h2>{esc(section['name'])}</h2>")
        for heading, key in WEEKLY_SECTIONS:
            items = section[key]
            parts.append(f"<h3>{esc(heading)}</h3><ul>")
            if not items:
                parts.append("<li>None</li>")
            for item in items:
                parts.append(
                    f"<li><a href=\"{esc(item['url'])}\">#{item['id']}</a> {esc(item['title'])} "
                    f"({esc(_weekly_detail(key, item))})</li>"
                )
            parts.append("</ul>")
    return "".join(parts)


# (heading, section key) in report order.
WEEKLY_SECTIONS = (
    ("Completed", "completed"),
    ("Progressed", "progressed"),
    ("Blockers", "blocked"),
    ("Next week", "upcoming"),
)


def _weekly_detail(key: str, item: dict[str, Any]) -> str:
    """The parenthesized detail after an item in the weekly report, e.g. "Task, Active → Resolved"."""
    kind = item["workItemType"] or "Item"
    if key == "completed":
        return f"{kind}, {item['state']} {_short_day(item['date'])}".rstrip()
    if key == "progressed":
        return f"{kind}, {item['fromState'] or 'Created'} → {item['state']}"
    if key == "blocked":
        since = _short_day(item["date"])
        return f"{kind}, blocked since {since}" if since else f"{kind}, blocked"
    return f"{kind}, {item['state']}"


def _short_day(iso_day: str | None) -> str:
    """ "2026-10-23" → "Oct 23", or "" when unset."""
    if not iso_day:
        return ""
    day = dt.date.fromisoformat(iso_day)
    return f"{day.strftime('%b')} {day.day}"


def _range_label(from_date: dt.date, to_date: dt.date) -> str:
    """ "Oct 19 – 25, 2026", "Sep 28 – Oct 4, 2026" or "Dec 29, 2025 – Jan 4, 2026"."""
    if from_date.year != to_date.year:
        return f"{_short_day(from_date.isoformat())}, {from_date.year} – {_short_day(to_date.isoformat())}, {to_date.year}"
    if from_date.month != to_date.month:
        return f"{_short_day(from_date.isoformat())} – {_short_day(to_date.isoformat())}, {to_date.year}"
    if from_date == to_date:
        return f"{_short_day(from_date.isoformat())}, {to_date.year}"
    return f"{_short_day(from_date.isoformat())} – {to_date.day}, {to_date.year}"


def cmd_weekly_report(args: argparse.Namespace, client: AdoClient) -> dict[str, Any]:
    """Build a status report for one person across one or more area paths (command: weekly-report).

    For each --area-path (child areas included; ADO_AREA_PATH when none is given),
    one WIQL query finds the person's items that changed since --from-date or are
    still open, and their fields are batch-fetched. Items are then sorted into:

    - completed: in --done-states, with a completion date (Closed Date, else
      Resolved Date) in [--from-date, --to-date].
    - progressed: not done or blocked, with a state change in the range. The
      item's updates are read to get the state it started the week in.
    - blocked: in --blocked-states now, whenever that happened.
    - upcoming: up to --next-count other open items, started ones first, then by
      priority and most recently changed.

    Work item types listed in --exclude-types (comma-separated) are left out.
    Dates are compared as local calendar days. Without --assigned-to or
    ADO_ASSIGNEE, items are those assigned to the PAT's owner (@Me); with a name,
    the assignee is matched loosely on the client (see _identity_matches).

    The report is returned as Markdown and HTML, and the Markdown is also written
    to --output when given.

    Returns:
        {"fromDate", "toDate", "rangeLabel", "assignee", "areaPaths", "sections":
        [{"areaPath", "name", "completed", "progressed", "blocked", "upcoming"}],
        "markdown", "html", "output"}. Each item has {"id", "title",
        "workItemType", "state", "fromState", "date", "priority", "iteration",
        "url"}; "date" (YYYY-MM-DD) is the completion day for completed items and
        the day the state last changed otherwise.

    Raises:
        CliError: VALIDATION_ERROR for bad dates, --to-date before --from-date,
            empty state lists, a negative --next-count or no area path.
    """
    today = dt.date.today()
    to_date = dt.date.fromisoformat(_validate_to_date(args.to_date)) if args.to_date else today
    from_date = (
        dt.date.fromisoformat(_validate_from_date(args.from_date)) if args.from_date else to_date - dt.timedelta(days=6)
    )
    if to_date < from_date:
        raise CliError("VALIDATION_ERROR", "--to-date must be on or after --from-date")
    done_states = _split_states(args.done_states, flag="done-states")
    blocked_states = _split_states(args.blocked_states, flag="blocked-states")
    exclude_types = [t.strip() for t in (args.exclude_types or "").split(",") if t.strip()]
    if args.next_count < 0:
        raise CliError("VALIDATION_ERROR", "--next-count cannot be negative")

    area_paths = [path.strip() for path in (args.area_paths or []) if path.strip()]
    if not area_paths and client.cfg.area_path:
        area_paths = [client.cfg.area_path]
    if not area_paths:
        raise CliError("VALIDATION_ERROR", "--area-path is required (or set ADO_AREA_PATH in .env)")

    assignee = (args.assigned_to if args.assigned_to is not None else client.cfg.assignee).strip()
    done_keys = {s.casefold() for s in done_states}
    blocked_keys = {s.casefold() for s in blocked_states}
    not_started_keys = {s.casefold() for s in WEEKLY_NOT_STARTED_STATES}
    # A day early, since WIQL compares UTC days and the range is in local days.
    since_iso = (from_date - dt.timedelta(days=1)).isoformat()

    requested_fields = [
        "System.Id",
        "System.Title",
        "System.State",
        "System.WorkItemType",
        "System.AssignedTo",
        "System.IterationPath",
        "System.ChangedDate",
        "Microsoft.VSTS.Common.ClosedDate",
        "Microsoft.VSTS.Common.ResolvedDate",
        "Microsoft.VSTS.Common.StateChangeDate",
        "Microsoft.VSTS.Common.Priority",
    ]

    sections: list[dict[str, Any]] = []
    for area_path in area_paths:
        wiql = _build_weekly_report_wiql(
            client.cfg.project, area_path, since_iso, done_states, use_me=not assignee, exclude_types=exclude_types
        )
        wiql_result = client.request("POST", f"wit/wiql?api-version={API_VERSION}", payload={"query": wiql})
        ids = [int(item["id"]) for item in wiql_result.get("workItems", []) if item.get("id") is not None]

        raw_items: list[dict[str, Any]] = []
        for id_chunk in _chunked(ids, 200):
            batch_payload = {"ids": id_chunk, "fields": requested_fields, "errorPolicy": "Omit"}
            batch_result = client.request("POST", f"wit/workitemsbatch?api-version={API_VERSION}", payload=batch_payload)
            raw_items.extend(batch_result.get("value", []))

        completed: list[tuple[str, dict[str, Any]]] = []
        progressed: list[tuple[str, dict[str, Any]]] = []
        blocked: list[tuple[str, dict[str, Any]]] = []
        open_items: list[tuple[str, dict[str, Any]]] = []
        for raw in raw_items:
            fields = raw.get("fields", {})
            if assignee and not _identity_matches(assignee, fields.get("System.AssignedTo")):
                continue
            state = _sanitize_rich_text(fields.get("System.State"))
            state_key = state.casefold()
            priority = fields.get("Microsoft.VSTS.Common.Priority")
            iteration = str(fields.get("System.IterationPath") or "")
            state_changed = _local_date(fields.get("Microsoft.VSTS.Common.StateChangeDate"))
            item: dict[str, Any] = {
                "id": raw.get("id"),
                "title": _sanitize_rich_text(fields.get("System.Title")),
                "workItemType": _sanitize_rich_text(fields.get("System.WorkItemType")),
                "state": state,
                "fromState": None,
                "date": state_changed.isoformat() if state_changed else None,
                "priority": int(priority) if isinstance(priority, (int, float)) else None,
                "iteration": iteration.split("\\")[-1] if iteration else None,
                "url": build_work_item_url(client.cfg, raw.get("id", "")),
            }

            if state_key in done_keys:
                finished = _local_date(
                    fields.get("Microsoft.VSTS.Common.ClosedDate") or fields.get("Microsoft.VSTS.Common.ResolvedDate")
                )
                if finished and from_date <= finished <= to_date:
                    item["date"] = finished.isoformat()
                    completed.append((item["date"], item))
                continue
            if state_key in blocked_keys:
                blocked.append((item["date"] or "", item))
                continue

            if state_changed and from_date <= state_changed <= to_date:
                transition = _state_transitions(client, int(raw["id"]), from_date, to_date)
                if transition and transition[0] != transition[1]:
                    item["fromState"] = transition[0]
                    progressed.append((item["date"] or "", item))

            open_items.append((str(fields.get("System.ChangedDate") or ""), item))

        completed.sort(key=lambda pair: pair[0], reverse=True)
        progressed.sort(key=lambda pair: pair[0], reverse=True)
        blocked.sort(key=lambda pair: pair[0])
        # Started first, then priority (1 is highest, unset last), then most recently changed.
        open_items.sort(key=lambda pair: pair[0], reverse=True)
        open_items.sort(key=lambda pair: (pair[1]["state"].casefold() in not_started_keys, pair[1]["priority"] or 99))
        sections.append(
            {
                "areaPath": area_path,
                "name": area_path.rstrip("\\").split("\\")[-1],
                "completed": [item for _, item in completed],
                "progressed": [item for _, item in progressed],
                "blocked": [item for _, item in blocked],
                "upcoming": [item for _, item in open_items[: args.next_count]],
            }
        )

    report: dict[str, Any] = {
        "fromDate": from_date.isoformat(),
        "toDate": to_date.isoformat(),
        "rangeLabel": _range_label(from_date, to_date),
        "assignee": assignee or "@Me",
        "areaPaths": area_paths,
        "sections": sections,
    }
    report["markdown"] = _weekly_markdown(report)
    report["html"] = _weekly_html(report)
    report["output"] = None
    if args.output:
        output_dir = os.path.dirname(args.output)
        if output_dir:
            os.makedirs(output_dir, exist_ok=True)
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(report["markdown"])
        report["output"] = args.output
    return report



def build_parser() -> argparse.ArgumentParser:
    """Define the argparse command line: one subparser per command, each with its flags.

    Flag names map to cmd_* argument attributes (for example --assigned-to becomes
    args.assigned_to). Callers should pass values as --flag=value so that values
    beginning with "-" are not read as options.
    """
    parser = argparse.ArgumentParser(description="Azure DevOps CLI (the engine behind ADO Desk)")
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
        help="Comma-separated ADO work item types to query (default: User Story)",
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
    export_closed_stories.add_argument(
        "--no-output",
        dest="no_output",
        action="store_true",
        help="Return the items without writing a file",
    )
    export_mods = subparsers.add_parser("export-modifications", help="Export all modifications by a user in a date range")
    export_mods.add_argument("--user", required=True, help="User's display name (e.g. 'Jason Rueckert')")
    export_mods.add_argument("--from-date", required=True, help="Start date in YYYY-MM-DD format")
    export_mods.add_argument("--to-date", default=None, help="End date in YYYY-MM-DD format")

    weekly = subparsers.add_parser("weekly-report", help="Completed, progressed, blocked and next items across area paths")
    weekly.add_argument("--area-path", dest="area_paths", action="append", default=None, help="Area path, child areas included (can be specified multiple times). Defaults to ADO_AREA_PATH")
    weekly.add_argument("--from-date", default=None, help="Start date in YYYY-MM-DD format (inclusive). Default: 6 days before --to-date")
    weekly.add_argument("--to-date", default=None, help="End date in YYYY-MM-DD format (inclusive). Default: today")
    weekly.add_argument("--assigned-to", dest="assigned_to", default=None, help="Assigned-to display name. Defaults to ADO_ASSIGNEE, then the token's owner")
    weekly.add_argument("--done-states", default="Closed,Resolved,Done", help="Comma-separated completed states (default: Closed,Resolved,Done)")
    weekly.add_argument("--blocked-states", default="Blocked", help="Comma-separated blocked states (default: Blocked)")
    weekly.add_argument("--next-count", type=int, default=3, help="Open items to list under Next week, per area path (default: 3)")
    weekly.add_argument("--exclude-types", dest="exclude_types", default="", help="Comma-separated work item types to leave out (e.g. Epic,Feature)")
    weekly.add_argument("--output", default="", help="Also write the Markdown report to this path")

    return parser


def main(argv: list[str]) -> int:
    """Run the CLI: parse arguments, load config, dispatch the command and print one envelope.

    Returns the process exit code: 0 on success, 1 for any handled failure. Every
    handled path prints exactly one JSON envelope to stdout. Argument errors are
    the exception: argparse prints usage to stderr and exits with code 2 without an
    envelope. Unexpected exceptions (for example a missing --body-file) are
    reported as API_ERROR.
    """
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
        elif args.command == "weekly-report":
            result = cmd_weekly_report(args, client)
        else:
            raise CliError("VALIDATION_ERROR", f"Unknown command: {args.command}")

        print_json(envelope_success(args.command, cfg, result))
        return 0
    except CliError as e:
        print_json(envelope_error(args.command, cfg, e.code, e.message))
        return 1
    except AdoApiError as e:
        code, message = map_api_error(e, args.command)
        print_json(envelope_error(args.command, cfg, code, message))
        return 1
    except Exception as e:  # pragma: no cover - defensive JSON contract fallback
        print_json(envelope_error(args.command, cfg, "API_ERROR", str(e) or "Unexpected error"))
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
