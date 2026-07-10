import argparse
import json
import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse


def to_windows_text(text: str) -> str:
    return text.replace("\n", "\r\n")


def read_json(path: Path):
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def write_json(path: Path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\r\n", encoding="utf-8")


def tail_lines(path: Path, count: int):
    if not path.exists():
        return []
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    return lines[-count:]


def first_non_empty_line(text: str | None):
    if not text:
        return None
    for line in text.splitlines():
        line = line.strip()
        if line:
            return line
    return None


def ps_quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def run_powershell_json(script: str, timeout: int = 15):
    command = [
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-Command",
        script,
    ]
    result = subprocess.run(
        command,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=timeout,
        check=False,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or f"powershell exit {result.returncode}")
    return json.loads(result.stdout)


def get_task_summary(task_name: str):
    script = f"""
$task = Get-ScheduledTask -TaskName {ps_quote(task_name)} -ErrorAction SilentlyContinue
if (-not $task) {{
  [pscustomobject]@{{
    Installed = $false
    Enabled = $false
    State = 'not_installed'
    LastRunTime = $null
    NextRunTime = $null
    LastTaskResult = $null
    Arguments = $null
  }} | ConvertTo-Json -Compress
  return
}}
$info = Get-ScheduledTaskInfo -TaskName {ps_quote(task_name)} -ErrorAction SilentlyContinue
$action = @($task.Actions) | Select-Object -First 1
$enabled = @($task.Triggers | Where-Object {{ $_.Enabled }}) | Select-Object -First 1
[pscustomobject]@{{
  Installed = $true
  Enabled = ($null -ne $enabled)
  State = [string]$task.State
  LastRunTime = if ($info) {{ $info.LastRunTime.ToString('yyyy-MM-dd HH:mm:ss') }} else {{ $null }}
  NextRunTime = if ($info) {{ $info.NextRunTime.ToString('yyyy-MM-dd HH:mm:ss') }} else {{ $null }}
  LastTaskResult = if ($info) {{ $info.LastTaskResult }} else {{ $null }}
  Arguments = if ($action) {{ [string]$action.Arguments }} else {{ $null }}
}} | ConvertTo-Json -Compress
"""
    return run_powershell_json(script)


def get_desktop_process_count():
    script = """
$count = @(
  Get-CimInstance Win32_Process -Filter "Name = 'Codex.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ExecutablePath -and $_.ExecutablePath -like '*\\OpenAI.Codex_*' }
).Count
[pscustomobject]@{ Count = $count } | ConvertTo-Json -Compress
"""
    return int(run_powershell_json(script).get("Count", 0))


def resolve_prop(obj, path):
    current = obj
    for part in path.split("."):
        if current is None:
            return None
        if isinstance(current, dict):
            current = current.get(part)
        else:
            return None
    return current


class GuardStatusBuilder:
    def __init__(self, state_root: Path, task_name: str):
        self.state_root = state_root
        self.task_name = task_name
        self.logs_dir = state_root / "logs"
        self.notifications_dir = state_root / "notifications"
        self.staging_dir = state_root / "staging"
        self.ui_dir = state_root / "ui"
        self.guard_config = read_json(state_root / "guard-config.json") or {}

    def mirror_enabled(self):
        return bool(resolve_prop(self.guard_config, "UpdateSources.MirrorEnabled"))

    def mirror_label(self):
        return resolve_prop(self.guard_config, "UpdateSources.MirrorLabel")

    def mirror_url(self):
        return resolve_prop(self.guard_config, "UpdateSources.MirrorPackageUrl")

    def latest_notification(self):
        files = sorted(self.notifications_dir.glob("*.txt"), key=lambda p: p.stat().st_mtime, reverse=True)
        if not files:
            return None
        path = files[0]
        return {
            "Name": path.name,
            "Path": str(path),
            "Text": path.read_text(encoding="utf-8", errors="replace"),
        }

    def latest_manifest(self):
        manifests = []
        if self.staging_dir.exists():
            for child in self.staging_dir.iterdir():
                manifest = child / "manifest.json"
                if child.is_dir() and manifest.exists():
                    manifests.append(manifest)
        if not manifests:
            return None
        manifests.sort(key=lambda p: p.stat().st_mtime, reverse=True)
        path = manifests[0]
        return {"Path": str(path), "Data": read_json(path) or {}}

    def latest_ready_manifest(self):
        candidates = [
            ("PATCHED_UPDATE_READY", "patched_update_ready"),
            ("READY", "ready"),
            ("CURRENT_VERSION_READY", "current_version_ready"),
        ]
        matches = []
        if self.staging_dir.exists():
            for child in self.staging_dir.iterdir():
                if not child.is_dir():
                    continue
                manifest = child / "manifest.json"
                if not manifest.exists():
                    continue
                for marker_name, state in candidates:
                    marker = child / marker_name
                    if marker.exists():
                        matches.append((marker.stat().st_mtime, state, marker, manifest))
        if not matches:
            return None
        matches.sort(key=lambda item: item[0], reverse=True)
        _, state, marker, manifest = matches[0]
        return {
            "State": state,
            "Marker": str(marker),
            "ManifestPath": str(manifest),
            "Data": read_json(manifest) or {},
        }

    def current_state(self, manifest_data, latest_notification, task, desktop_count, ready_manifest):
        if not task["Installed"]:
            state = "not_installed"
            reason = "scheduled_task_missing"
        elif ready_manifest and ready_manifest["State"] == "patched_update_ready":
            state = "patched_update_ready"
            reason = "patched_update_ready"
        elif ready_manifest and ready_manifest["State"] == "current_version_ready":
            state = "current_version_ready"
            reason = "current_version_ready"
        elif ready_manifest and ready_manifest["State"] == "ready":
            state = "ready"
            reason = "ready"
        elif latest_notification and latest_notification["Name"] == "STORE_OFFLINE_AUTHORIZATION_REQUIRED.txt":
            state = "waiting_for_raw_package_source" if self.mirror_enabled() else "waiting_for_external_payload"
            reason = "store_offline_authorization_required"
        elif latest_notification and latest_notification["Name"] == "NEEDS_UPDATE_SOURCE.txt":
            state = "waiting_for_raw_package_source" if self.mirror_enabled() else "waiting_for_external_payload"
            reason = "needs_update_source"
        elif latest_notification and latest_notification["Name"] == "WAITING_FOR_UPDATE_PAYLOAD.txt":
            state = "waiting_for_update_payload"
            reason = "waiting_for_update_payload"
        elif latest_notification and latest_notification["Name"] == "PREPARE_FAILED.txt":
            state = "prepare_failed"
            reason = "prepare_failed_marker"
        elif latest_notification and latest_notification["Name"] == "NEEDS_ACTION.txt":
            state = "needs_action"
            reason = "needs_action_marker"
        elif latest_notification and latest_notification["Name"] == "CONFIG_CHANGE.txt":
            state = "config_change_only"
            reason = "config_change_only"
        elif latest_notification and latest_notification["Name"] == "UPDATE_ACTIVITY.txt":
            state = "watching"
            reason = "update_activity_marker"
        else:
            state = "idle"
            reason = "task_enabled_no_action_marker"

        if state == "patched_update_ready":
            step = "waiting_for_restart" if desktop_count > 0 else "ready_to_apply"
        elif state == "waiting_for_raw_package_source":
            step = "acquiring_raw_package"
        elif state == "waiting_for_update_payload":
            step = "discovering_update_candidate"
        elif state == "watching":
            step = "watching_for_update_activity"
        elif state == "prepare_failed":
            step = "prepare_failed"
        elif state == "needs_action":
            step = "manual_intervention_required"
        else:
            step = state
        return state, reason, step

    def build(self):
        task = get_task_summary(self.task_name)
        latest_notification = self.latest_notification()
        latest_manifest = self.latest_manifest()
        ready_manifest = self.latest_ready_manifest()
        active_manifest = ready_manifest or latest_manifest
        manifest_data = active_manifest["Data"] if active_manifest else {}
        desktop_count = get_desktop_process_count()
        state, reason, step = self.current_state(manifest_data, latest_notification, task, desktop_count, ready_manifest)

        current_package_version = resolve_prop(manifest_data, "Snapshot.Package.Version") or resolve_prop(manifest_data, "Discovery.CurrentPackageVersion")
        candidate_update_version = resolve_prop(manifest_data, "Payload.PackageVersion") or resolve_prop(manifest_data, "Discovery.SelectedPayload.PackageVersion")
        update_source = resolve_prop(manifest_data, "Discovery.Acquire.MirrorLabel") or self.mirror_label()
        mirror_url = resolve_prop(manifest_data, "Discovery.Acquire.MirrorPackageUrl") or self.mirror_url()
        if update_source and mirror_url:
            update_source = f"{update_source} ({mirror_url})"

        details = resolve_prop(manifest_data, "Details") or []
        last_error_summary = None
        if isinstance(details, list):
          for item in details:
            if item:
              last_error_summary = str(item)
              break
        if not last_error_summary and latest_notification:
            last_error_summary = first_non_empty_line(latest_notification["Text"])

        apply_command = resolve_prop(manifest_data, "ApplyCommand")
        user_action = {
            "patched_update_ready": "Close Codex Desktop, then run the apply command from external PowerShell or VS Code Codex.",
            "waiting_for_raw_package_source": "Mirror raw-package fallback is configured. Run Check Now or wait for the next scheduled retry.",
            "prepare_failed": "Inspect the latest staging verification log for the failure reason.",
            "needs_action": "Resolve the manual action requested by the latest staging manifest.",
        }.get(state, "No immediate action.")

        return {
            "SchemaVersion": 1,
            "CheckedAt": __import__("datetime").datetime.now().astimezone().isoformat(),
            "State": state,
            "Reason": reason,
            "Step": step,
            "EventId": resolve_prop(manifest_data, "EventId"),
            "Safe": state not in {"prepare_failed", "needs_action"},
            "NeedsAction": state in {"prepare_failed", "needs_action"} or step in {"waiting_for_restart", "ready_to_apply"},
            "UserAction": user_action,
            "CurrentPackageVersion": current_package_version,
            "CandidateUpdateVersion": candidate_update_version,
            "UpdateSource": update_source,
            "LastErrorSummary": last_error_summary,
            "Task": task,
            "DesktopProcessCount": desktop_count,
            "LatestNotification": {"Name": latest_notification["Name"], "Path": latest_notification["Path"]} if latest_notification else None,
            "RecentLog": tail_lines(self.logs_dir / "watch.log", 60),
            "ApplyCommand": apply_command,
            "MirrorSourceEnabled": self.mirror_enabled(),
            "MirrorPackageUrl": self.mirror_url(),
            "OpenLogsPath": str(self.logs_dir),
            "OpenStagingPath": resolve_prop(manifest_data, "StagingDir") or str(self.staging_dir),
            "ReadyManifest": {
                "State": ready_manifest["State"],
                "Marker": ready_manifest["Marker"],
                "ManifestPath": ready_manifest["ManifestPath"],
            } if ready_manifest else None,
        }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def write_json(self, payload, status=200):
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def write_bytes(self, data: bytes, content_type: str, status=200):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = urlparse(self.path).path
        try:
            if path in {"/", "/index.html"}:
                self.write_bytes(APP.html_path.read_bytes(), "text/html; charset=utf-8")
                return
            if path == "/favicon.ico":
                self.write_bytes(b"", "image/x-icon", status=204)
                return
            if path == "/api/status":
                self.write_json(APP.status_builder.build())
                return
            if path == "/api/run-check":
                self.write_json(APP.run_check_now())
                return
            if path == "/api/open-logs":
                APP.open_path(APP.logs_dir)
                self.write_json({"status": "opened"})
                return
            if path == "/api/open-staging":
                APP.open_path(Path(APP.status_builder.build()["OpenStagingPath"]))
                self.write_json({"status": "opened"})
                return
            self.write_json({"error": "Not found"}, status=404)
        except Exception as exc:
            APP.write_log(f"request failed: {path}: {exc}")
            self.write_json({"error": str(exc)}, status=500)


class App:
    def __init__(self, args):
        self.state_root = Path(args.state_root)
        self.port = args.port
        self.task_name = args.task_name
        self.html_path = Path(args.html_path)
        self.runner_script = Path(args.runner_script)
        self.logs_dir = self.state_root / "logs"
        self.ui_dir = self.state_root / "ui"
        self.server_path = self.ui_dir / "server.json"
        self.log_path = self.ui_dir / "server.log"
        self.status_builder = GuardStatusBuilder(self.state_root, self.task_name)

    def write_log(self, message: str):
        self.ui_dir.mkdir(parents=True, exist_ok=True)
        line = f"[{__import__('datetime').datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {message}"
        with self.log_path.open("a", encoding="utf-8") as handle:
            handle.write(line + "\n")

    def write_state(self, status: str, error: str | None = None):
        payload = {
            "Status": status,
            "Url": f"http://127.0.0.1:{self.port}/",
            "Pid": os.getpid(),
            "Port": self.port,
            "StateRoot": str(self.state_root),
            "UpdatedAt": __import__("datetime").datetime.now().astimezone().isoformat(),
            "Error": error,
            "LogPath": str(self.log_path),
        }
        if status == "running":
            payload["StartedAt"] = payload["UpdatedAt"]
            payload["ScriptPath"] = str(Path(__file__))
        write_json(self.server_path, payload)

    def open_path(self, path: Path):
        subprocess.Popen(["explorer.exe", str(path)], creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))

    def run_check_now(self):
        task = get_task_summary(self.task_name)
        if task.get("Installed"):
            subprocess.run(
                ["schtasks.exe", "/Run", "/TN", self.task_name],
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=15,
                check=False,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
            return {"status": "started_task", "taskName": self.task_name}
        subprocess.Popen(
            [
                "powershell.exe",
                "-NoProfile",
                "-WindowStyle",
                "Hidden",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(self.runner_script),
                "-StateRoot",
                str(self.state_root),
            ],
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        return {"status": "started_process"}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-root", required=True)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--task-name", default="Codex Desktop Guard")
    parser.add_argument("--html-path", required=True)
    parser.add_argument("--runner-script", required=True)
    args = parser.parse_args()

    global APP
    APP = App(args)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    APP.write_state("running")
    APP.write_log(f"server started: http://127.0.0.1:{args.port}/")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        try:
            APP.server_path.unlink(missing_ok=True)
        except Exception:
            pass
        APP.write_log("server stopped")


if __name__ == "__main__":
    main()
