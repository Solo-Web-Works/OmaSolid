#!/usr/bin/env python3
"""OmASolid - SolidTime helper for the Omarchy shell.

Reads its configuration from ~/.config/omarchy/solidtime.json and talks to a
self-hosted SolidTime instance over its REST API. The QML service drives it
through `Process` and reads JSON results from stdout. All HTTP is done with
the Python standard library only, so the plugin has no pip dependencies.

Config file shape:
    {
      "instance": "https://solidtime.example.com",
      "token": "<jwt api token>",
      "organization_id": "<org uuid>",
      "member_id": "<membership id for the chosen org>"
    }

Subcommands (each prints a JSON object on stdout, exit 0 on success):
    init                       -> {"configured": bool, ...config fields}
    config                     -> same as init (current persisted config)
    save-config <json>         -> writes config, prints saved config
    test-config <json>         -> validates without saving; prints user+orgs
    memberships               -> {user, organizations: [{id, name, is_personal, role, member_id}]}
    projects                   -> {clients: [...], projects: [...], tasks: [...]},
                                 grouped by client; projects include client_id
    active                     -> {active: bool, entry: {...}|null}
    start <json>               -> {entry: {...}}  (starts a running timer)
    stop                       -> {entry: {...}|null}  (stops the active timer)
    today                      -> {entries: [...], total_seconds: int}

All timestamps exchanged with the API are UTC, formatted as
"YYYY-MM-DDTHH:MM:SSZ". Durations reported back to QML are integer seconds.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional, Tuple


CONFIG_PATH = os.environ.get("OMASOLID_CONFIG_PATH") or os.path.expanduser("~/.config/omarchy/solidtime.json")
API_PREFIX = "/api/v1"
TIMEOUT_SECONDS = 20


# --------------------------------------------------------------------------- #
# Config helpers
# --------------------------------------------------------------------------- #

def _default_config() -> Dict[str, Any]:
    return {"instance": "", "token": "", "organization_id": "", "member_id": ""}


def _read_config() -> Dict[str, Any]:
    if not os.path.exists(CONFIG_PATH):
        return _default_config()
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return _default_config()
    merged = _default_config()
    merged.update({k: data.get(k, "") for k in _default_config()})
    return merged


def _write_config(config: Dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(CONFIG_PATH), exist_ok=True)
    payload = {k: config.get(k, "") for k in _default_config()}
    text = json.dumps(payload, indent=2) + "\n"
    # 0600 because the token is a bearer credential.
    fd = os.open(CONFIG_PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        # Tighten an existing file that may have been created with looser perms.
        os.fchmod(fd, 0o600)
        os.write(fd, text.encode("utf-8"))
    finally:
        os.close(fd)


def _is_configured(config: Dict[str, Any]) -> bool:
    return bool(config.get("instance") and config.get("token")
                and config.get("organization_id") and config.get("member_id"))


# --------------------------------------------------------------------------- #
# HTTP
# --------------------------------------------------------------------------- #

class ApiError(Exception):
    def __init__(self, message: str, status: int = 0, body: str = ""):
        super().__init__(message)
        self.status = status
        self.body = body


def _base_url(config: Dict[str, Any]) -> str:
    instance = (config.get("instance") or "").rstrip("/")
    if not instance:
        raise ApiError("SolidTime instance URL is not set")
    return instance


def _request(config: Dict[str, Any], method: str, path: str,
             body: Optional[Dict[str, Any]] = None,
             query: Optional[Dict[str, Any]] = None) -> Any:
    token = config.get("token") or ""
    if not token:
        raise ApiError("SolidTime API token is not set")

    if path.startswith("http://") or path.startswith("https://"):
        url = path
    else:
        url = _base_url(config) + API_PREFIX + path

    if query:
        clean = {k: v for k, v in query.items() if v is not None and v != "" and v != []}
        if clean:
            url += ("&" if "?" in url else "?") + urllib.parse.urlencode(clean, doseq=True)

    headers = {
        "Authorization": "Bearer " + token,
        "Accept": "application/json",
    }
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_SECONDS) as response:
            status = response.getcode()
            raw = response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        raw = ""
        try:
            raw = exc.read().decode("utf-8", "replace")
        except OSError:
            pass
        message = "SolidTime returned HTTP %s" % exc.code
        try:
            parsed = json.loads(raw)
            if isinstance(parsed, dict):
                msg = parsed.get("message") or parsed.get("error")
                if isinstance(msg, str):
                    message = msg
        except ValueError:
            pass
        raise ApiError(message, status=exc.code, body=raw)
    except urllib.error.URLError as exc:
        raise ApiError("Could not reach SolidTime: %s" % exc.reason)

    if status == 204 or not raw:
        return None
    try:
        return json.loads(raw)
    except ValueError as exc:
        raise ApiError("SolidTime returned a non-JSON response (%s)" % exc)


def _get(config: Dict[str, Any], path: str, query: Optional[Dict[str, Any]] = None) -> Any:
    return _request(config, "GET", path, body=None, query=query)


def _post(config: Dict[str, Any], path: str, body: Dict[str, Any]) -> Any:
    return _request(config, "POST", path, body=body)


def _put(config: Dict[str, Any], path: str, body: Dict[str, Any]) -> Any:
    return _request(config, "PUT", path, body=body)


# --------------------------------------------------------------------------- #
# Time helpers
# --------------------------------------------------------------------------- #

def _utcnow() -> _dt.datetime:
    return _dt.datetime.now(_dt.timezone.utc)


def _iso(dt: _dt.datetime) -> str:
    # SolidTime expects "YYYY-MM-DDTHH:MM:SSZ".
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_iso(value: str) -> Optional[_dt.datetime]:
    if not value:
        return None
    text = value
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = _dt.datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=_dt.timezone.utc)
    return parsed


def _duration_seconds(start: Optional[_dt.datetime], end: Optional[_dt.datetime]) -> int:
    if start is None:
        return 0
    end = end or _utcnow()
    return max(0, int((end - start).total_seconds()))


def _fmt_duration(seconds: int) -> str:
    seconds = max(0, int(seconds))
    hours, remainder = divmod(seconds, 3600)
    minutes, secs = divmod(remainder, 60)
    if hours:
        return "%d:%02d:%02d" % (hours, minutes, secs)
    return "%d:%02d" % (minutes, secs)


# --------------------------------------------------------------------------- #
# API resource mappers
# --------------------------------------------------------------------------- #

def _membership_to_org(membership: Dict[str, Any]) -> Dict[str, Any]:
    org = membership.get("organization") or {}
    return {
        "id": str(org.get("id") or ""),
        "name": str(org.get("name") or ""),
        "is_personal": bool(org.get("is_personal")),
        "role": str(membership.get("role") or ""),
        "member_id": str(membership.get("id") or ""),
    }


def _client_from_api(item: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "id": str(item.get("id") or ""),
        "name": str(item.get("name") or ""),
    }


def _project_from_api(item: Dict[str, Any], client_name: str = "") -> Dict[str, Any]:
    return {
        "id": str(item.get("id") or ""),
        "name": str(item.get("name") or ""),
        "color": str(item.get("color") or ""),
        "client_id": item.get("client_id") or "",
        "client_name": client_name,
        "is_billable": bool(item.get("is_billable")),
    }


def _task_from_api(item: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "id": str(item.get("id") or ""),
        "name": str(item.get("name") or ""),
        "project_id": str(item.get("project_id") or ""),
        "done": bool(item.get("done")),
    }


def _entry_from_api(item: Dict[str, Any], projects: Optional[Dict[str, Dict[str, Any]]] = None) -> Dict[str, Any]:
    start = _parse_iso(str(item.get("start") or ""))
    end = _parse_iso(str(item.get("end") or "")) if item.get("end") else None
    running = end is None
    project_id = item.get("project_id")
    project_name = ""
    if projects and project_id:
        project_name = projects.get(str(project_id), {}).get("name", "")
    return {
        "id": str(item.get("id") or ""),
        "description": str(item.get("description") or ""),
        "project_id": str(project_id or ""),
        "project_name": project_name,
        "task_id": str(item.get("task_id") or ""),
        "billable": bool(item.get("billable")),
        "start": _iso(start) if start else "",
        "end": _iso(end) if end else "",
        "running": running,
        "duration_seconds": _duration_seconds(start, end),
        "duration": _fmt_duration(_duration_seconds(start, end)),
    }


# --------------------------------------------------------------------------- #
# Subcommands
# --------------------------------------------------------------------------- #

def cmd_init(_args: argparse.Namespace) -> Dict[str, Any]:
    config = _read_config()
    result = {"configured": _is_configured(config), **config}
    return result


def cmd_config(_args: argparse.Namespace) -> Dict[str, Any]:
    return cmd_init(_args)


def cmd_save_config(args: argparse.Namespace) -> Dict[str, Any]:
    payload = _parse_json_arg(args.payload, "config payload")
    config = _default_config()
    for key in ("instance", "token", "organization_id", "member_id"):
        if key in payload:
            config[key] = str(payload[key] or "").strip()
    _write_config(config)
    return {"configured": _is_configured(config), **config}


def cmd_test_config(args: argparse.Namespace) -> Dict[str, Any]:
    payload = _parse_json_arg(args.payload, "config payload")
    candidate = _default_config()
    for key in ("instance", "token", "organization_id", "member_id"):
        if key in payload:
            candidate[key] = str(payload[key] or "").strip()
    # Normalize the instance URL the same way API calls do.
    if candidate["instance"]:
        candidate["instance"] = candidate["instance"].rstrip("/")
    if not (candidate["instance"] and candidate["token"]):
        raise ApiError("Instance URL and API token are required")
    user = _get(candidate, "/users/me")
    memberships = _get(candidate, "/users/me/memberships")
    orgs = [_membership_to_org(m) for m in (memberships.get("data") or [])]
    return {
        "configured": _is_configured(candidate),
        "user": {
            "id": str((user.get("data") or {}).get("id") or ""),
            "name": str((user.get("data") or {}).get("name") or ""),
            "email": str((user.get("data") or {}).get("email") or ""),
            "timezone": str((user.get("data") or {}).get("timezone") or ""),
        },
        "organizations": orgs,
    }


def cmd_memberships(_args: argparse.Namespace) -> Dict[str, Any]:
    config = _require_configured()
    user = _get(config, "/users/me")
    memberships = _get(config, "/users/me/memberships")
    orgs = [_membership_to_org(m) for m in (memberships.get("data") or [])]
    return {
        "user": {
            "id": str((user.get("data") or {}).get("id") or ""),
            "name": str((user.get("data") or {}).get("name") or ""),
            "email": str((user.get("data") or {}).get("email") or ""),
            "timezone": str((user.get("data") or {}).get("timezone") or ""),
        },
        "organizations": orgs,
    }


def cmd_projects(_args: argparse.Namespace) -> Dict[str, Any]:
    config = _require_configured()
    org = config["organization_id"]
    clients_raw = _get(config, "/organizations/%s/clients" % org, query={"archived": "false"})
    projects_raw = _get(config, "/organizations/%s/projects" % org, query={"archived": "false"})
    clients = [_client_from_api(c) for c in (clients_raw.get("data") or [])]
    client_name_by_id = {c["id"]: c["name"] for c in clients}
    client_name_by_id[""] = "No client"

    tasks = []
    try:
        tasks_raw = _get(config, "/organizations/%s/tasks" % org)
        tasks = [_task_from_api(t) for t in (tasks_raw.get("data") or [])]
    except ApiError:
        # Tasks are optional; an instance may not expose them.
        tasks = []

    projects = []
    for item in (projects_raw.get("data") or []):
        cid = item.get("client_id") or ""
        name = client_name_by_id.get(cid, "")
        projects.append(_project_from_api(item, name))

    return {
        "clients": clients,
        "projects": projects,
        "tasks": tasks,
    }


def cmd_active(_args: argparse.Namespace) -> Dict[str, Any]:
    config = _require_configured()
    # The active endpoint always returns *my* running entry.
    try:
        result = _get(config, "/users/me/time-entries/active")
    except ApiError as exc:
        # A 404 (or 200 with empty data) means "no active entry". Treat 404 as none.
        if exc.status == 404:
            return {"active": False, "entry": None}
        raise
    data = result.get("data")
    if not data:
        return {"active": False, "entry": None}
    return {"active": True, "entry": _entry_from_api(data)}


def cmd_start(args: argparse.Namespace) -> Dict[str, Any]:
    config = _require_configured()
    payload = _parse_json_arg(args.payload, "time entry payload")
    project_id = str(payload.get("project_id") or "")
    task_id = str(payload.get("task_id") or "") or None
    description = str(payload.get("description") or "")
    billable = bool(payload.get("billable"))

    if not project_id:
        raise ApiError("A project is required to start a timer")

    body = {
        "member_id": config["member_id"],
        "project_id": project_id,
        "start": _iso(_utcnow()),
        "end": None,
        "description": description,
        "billable": billable,
    }
    if task_id:
        body["task_id"] = task_id

    created = _post(config, "/organizations/%s/time-entries" % config["organization_id"], body)
    entry = _entry_from_api(created.get("data") or {})
    return {"entry": entry, "active": entry.get("running", False)}


def cmd_stop(_args: argparse.Namespace) -> Dict[str, Any]:
    config = _require_configured()
    active = cmd_active(_args)
    entry = active.get("entry")
    if not entry:
        return {"entry": None, "stopped": False}
    end_iso = _iso(_utcnow())
    updated = _put(config,
                   "/organizations/%s/time-entries/%s" % (config["organization_id"], entry["id"]),
                   {"end": end_iso})
    stopped = _entry_from_api(updated.get("data") or {})
    stopped["running"] = False
    stopped["duration_seconds"] = _duration_seconds(_parse_iso(stopped["start"]), _parse_iso(end_iso))
    stopped["duration"] = _fmt_duration(stopped["duration_seconds"])
    return {"entry": stopped, "stopped": True}


def cmd_today(_args: argparse.Namespace) -> Dict[str, Any]:
    config = _require_configured()
    now = _utcnow()
    start_of_day = now.replace(hour=0, minute=0, second=0, microsecond=0)
    # Convert the user's local "today" window to UTC bounds, like the API docs
    # recommend. For simplicity we use today's UTC day boundaries; SolidTime
    # filters by start time in UTC.
    params = {
        "member_id": config["member_id"],
        "start": _iso(start_of_day),
        "end": _iso(now),
        "limit": 500,
        "offset": 0,
    }
    result = _get(config, "/organizations/%s/time-entries" % config["organization_id"], query=params)
    data = result.get("data") or []
    # Resolve project names for nicer display.
    projects = {}
    try:
        projects_raw = _get(config, "/organizations/%s/projects" % config["organization_id"],
                            query={"archived": "false"})
        for item in (projects_raw.get("data") or []):
            projects[str(item.get("id"))] = _project_from_api(item)
    except ApiError:
        pass
    entries = [_entry_from_api(item, projects) for item in data]
    total = sum(e["duration_seconds"] for e in entries)
    return {"entries": entries, "total_seconds": total, "total": _fmt_duration(total)}


# --------------------------------------------------------------------------- #
# Plumbing
# --------------------------------------------------------------------------- #

def _require_configured() -> Dict[str, Any]:
    config = _read_config()
    if not _is_configured(config):
        raise ApiError("Not configured. Open the SolidTime panel and enter your instance URL, API token, and organization.")
    return config


def _parse_json_arg(value: str, label: str) -> Dict[str, Any]:
    if not value:
        raise ApiError("Missing %s" % label)
    try:
        parsed = json.loads(value)
    except ValueError as exc:
        raise ApiError("Invalid %s: %s" % (label, exc))
    if not isinstance(parsed, dict):
        raise ApiError("%s must be a JSON object" % label)
    return parsed


def _emit(result: Dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(result))
    sys.stdout.write("\n")
    sys.stdout.flush()


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="omasolid", description="SolidTime helper for Omarchy")
    parser.add_argument("command", choices=[
        "init", "config", "save-config", "test-config", "memberships",
        "projects", "active", "start", "stop", "today",
    ])
    parser.add_argument("payload", nargs="?", default="")
    args = parser.parse_args(argv)

    handlers = {
        "init": cmd_init,
        "config": cmd_config,
        "save-config": cmd_save_config,
        "test-config": cmd_test_config,
        "memberships": cmd_memberships,
        "projects": cmd_projects,
        "active": cmd_active,
        "start": cmd_start,
        "stop": cmd_stop,
        "today": cmd_today,
    }
    handler = handlers[args.command]

    try:
        result = handler(args)
        result["_ok"] = True
        _emit(result)
        return 0
    except ApiError as exc:
        _emit({"_ok": False, "error": str(exc), "status": getattr(exc, "status", 0)})
        return 1
    except Exception as exc:  # noqa: BLE001 - top-level guard for the QML caller
        _emit({"_ok": False, "error": str(exc)})
        return 1


if __name__ == "__main__":
    sys.exit(main())
