[CmdletBinding(DefaultParameterSetName = 'Repair')]
param(
  [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
  [Parameter(Mandatory, ParameterSetName = 'Repair')]
  [string[]]$ThreadId,
  [string]$FromModel = 'gpt-5.4',
  [string]$ToModel = 'gpt-5.6-terra',
  [string]$ModelProvider = 'krill',
  [string]$ExpectedReasoningEffort,
  [string]$ToReasoningEffort = 'xhigh',
  [switch]$Apply,
  [switch]$DryRun,
  [Parameter(Mandatory, ParameterSetName = 'SelfTest')]
  [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$LogPrefix = '[codex-thread-model-sync]'

function Write-Log([string]$Message) {
  Write-Host "$LogPrefix $Message"
}

if ($Apply -and $DryRun) {
  throw 'Use either -Apply or -DryRun, not both.'
}

if ($Apply) {
  $runningDesktop = Get-Process Codex -ErrorAction SilentlyContinue
  if ($runningDesktop) {
    throw 'Stop all Codex processes from an external PowerShell before using -Apply.'
  }
}

$python = Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $python) {
  throw "$LogPrefix python not found"
}

$script = @'
import argparse
import hashlib
import json
import os
import shutil
import sqlite3
import tempfile
from datetime import datetime
from pathlib import Path


def compact_json(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def normalize_rollout_path(value):
    text = value or ""
    if text.startswith("\\\\?\\"):
        text = text[4:]
    return Path(text)


def find_state_db(codex_home):
    for candidate in (codex_home / "sqlite" / "state_5.sqlite", codex_home / "state_5.sqlite"):
        if candidate.exists():
            return candidate
    raise SystemExit(f"state db not found under {codex_home}")


def required_columns(conn):
    columns = {row[1] for row in conn.execute("pragma table_info(threads)")}
    needed = {"id", "archived", "thread_source", "model_provider", "model", "reasoning_effort", "rollout_path"}
    missing = sorted(needed - columns)
    if missing:
        raise SystemExit(f"threads table is missing required columns: {', '.join(missing)}")


def select_threads(conn, args):
    placeholders = ",".join("?" for _ in args.thread_id)
    sql = f"""
        select id, rollout_path, model, reasoning_effort
        from threads
        where id in ({placeholders})
          and archived = 0
          and thread_source = 'user'
          and model_provider = ?
          and model = ?
    """
    values = [*args.thread_id, args.model_provider, args.from_model]
    if args.expected_reasoning_effort is not None:
        sql += " and reasoning_effort = ?"
        values.append(args.expected_reasoning_effort)
    return [dict(row) for row in conn.execute(sql, values).fetchall()]


def rewrite_session_meta(path, thread_id, to_model, to_reasoning_effort):
    original = path.read_text(encoding="utf-8")
    first, separator, rest = original.partition("\n")
    if not separator:
        raise ValueError("rollout does not contain a session_meta line")
    meta = json.loads(first.rstrip("\r"))
    payload = meta.get("payload") if isinstance(meta, dict) else None
    if meta.get("type") != "session_meta" or not isinstance(payload, dict):
        raise ValueError("rollout first line is not session_meta")
    if payload.get("id") != thread_id:
        raise ValueError("rollout session_meta id does not match selected thread")
    changed = payload.get("model") != to_model or payload.get("reasoning_effort") != to_reasoning_effort
    payload["model"] = to_model
    payload["reasoning_effort"] = to_reasoning_effort
    return compact_json(meta) + "\n" + rest, changed


def backup_file(path, backup_dir):
    backup_dir.mkdir(parents=True, exist_ok=True)
    fingerprint = hashlib.sha256(str(path).encode("utf-8")).hexdigest()[:12]
    target = backup_dir / f"{path.name}.{fingerprint}.bak"
    shutil.copy2(path, target)
    return str(target)


def backup_sqlite(source, backup_path):
    source_conn = sqlite3.connect(source)
    backup_conn = sqlite3.connect(backup_path)
    try:
        source_conn.backup(backup_conn)
    finally:
        backup_conn.close()
        source_conn.close()


def atomic_write(path, content):
    temporary = path.with_name(path.name + f".thread-model-sync.{os.getpid()}.tmp")
    temporary.write_text(content, encoding="utf-8", newline="")
    os.replace(temporary, path)


def self_test():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        db = root / "state_5.sqlite"
        rollout = root / "rollout.jsonl"
        rollout.write_text(
            '{"type":"session_meta","payload":{"id":"keep","model":"gpt-5.4","reasoning_effort":"medium"}}\n'
            '{"type":"event_msg","payload":{"model":"gpt-5.4"}}\n',
            encoding="utf-8",
        )
        conn = sqlite3.connect(db)
        conn.execute("create table threads (id text, archived integer, thread_source text, model_provider text, model text, reasoning_effort text, rollout_path text)")
        conn.executemany(
            "insert into threads values (?, ?, ?, ?, ?, ?, ?)",
            [
                ("keep", 0, "user", "krill", "gpt-5.4", "medium", str(rollout)),
                ("archived", 1, "user", "krill", "gpt-5.4", "medium", str(rollout)),
                ("assistant", 0, "assistant", "krill", "gpt-5.4", "medium", str(rollout)),
            ],
        )
        conn.row_factory = sqlite3.Row
        args = argparse.Namespace(thread_id=["keep", "archived", "assistant"], model_provider="krill", from_model="gpt-5.4", expected_reasoning_effort="medium")
        assert [row["id"] for row in select_threads(conn, args)] == ["keep"]
        rewritten, changed = rewrite_session_meta(rollout, "keep", "gpt-5.6-terra", "xhigh")
        assert changed
        assert '"model":"gpt-5.6-terra"' in rewritten.splitlines()[0]
        assert rewritten.splitlines()[1] == '{"type":"event_msg","payload":{"model":"gpt-5.4"}}'
        conn.close()
    print(compact_json({"self_test": "passed"}))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--codex-home")
    parser.add_argument("--thread-id", action="append")
    parser.add_argument("--from-model")
    parser.add_argument("--to-model")
    parser.add_argument("--model-provider")
    parser.add_argument("--expected-reasoning-effort")
    parser.add_argument("--to-reasoning-effort")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return

    codex_home = Path(args.codex_home).expanduser()
    db_path = find_state_db(codex_home)
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    required_columns(conn)
    selected = select_threads(conn, args)
    rewritten_rollouts = []
    for row in selected:
        if not row["rollout_path"]:
            raise SystemExit(f"selected thread has no rollout path: {row['id']}")
        path = normalize_rollout_path(row["rollout_path"])
        if not path.exists():
            raise SystemExit(f"selected thread rollout does not exist: {row['id']}")
        content, changed = rewrite_session_meta(path, row["id"], args.to_model, args.to_reasoning_effort)
        if changed:
            rewritten_rollouts.append((path, content))

    report = {
        "db_path": str(db_path),
        "thread_ids_requested": args.thread_id,
        "selected_count": len(selected),
        "selected_thread_ids": [row["id"] for row in selected],
        "from_model": args.from_model,
        "to_model": args.to_model,
        "model_provider": args.model_provider,
        "expected_reasoning_effort": args.expected_reasoning_effort,
        "to_reasoning_effort": args.to_reasoning_effort,
        "planned_rollout_updates": len(rewritten_rollouts),
        "apply": args.apply,
        "sqlite_backup": None,
        "rollout_backups": [],
        "sqlite_updated_rows": 0,
        "rollout_updated_files": 0,
    }
    if not args.apply or not selected:
        print(compact_json(report))
        return

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    backup_root = codex_home / "backups" / "thread-model-sync" / stamp
    sqlite_backup = backup_root / "state_5.sqlite.bak"
    backup_sqlite(db_path, sqlite_backup)
    report["sqlite_backup"] = str(sqlite_backup)
    for path, content in rewritten_rollouts:
        report["rollout_backups"].append(backup_file(path, backup_root / "rollouts"))
        atomic_write(path, content)
    report["rollout_updated_files"] = len(rewritten_rollouts)

    thread_ids = [row["id"] for row in selected]
    placeholders = ",".join("?" for _ in thread_ids)
    conn.execute("begin immediate")
    try:
        updated = conn.execute(
            f"update threads set model = ?, reasoning_effort = ? where id in ({placeholders})",
            [args.to_model, args.to_reasoning_effort, *thread_ids],
        ).rowcount
        if updated != len(thread_ids):
            raise RuntimeError(f"expected to update {len(thread_ids)} rows, updated {updated}")
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()
    report["sqlite_updated_rows"] = updated
    print(compact_json(report))


if __name__ == "__main__":
    main()
'@

$temp = Join-Path $env:TEMP ('codex-thread-model-sync-' + [guid]::NewGuid().ToString('N') + '.py')
try {
  Set-Content -LiteralPath $temp -Value $script -Encoding UTF8
  if ($SelfTest) {
    & $python.Source $temp '--self-test'
  } else {
    $args = @(
      $temp,
      '--codex-home', $CodexHome,
      '--from-model', $FromModel,
      '--to-model', $ToModel,
      '--model-provider', $ModelProvider,
      '--to-reasoning-effort', $ToReasoningEffort
    )
    foreach ($id in $ThreadId) {
      if ([string]::IsNullOrWhiteSpace($id)) {
        throw 'ThreadId cannot contain an empty value.'
      }
      $args += @('--thread-id', $id)
    }
    if ($PSBoundParameters.ContainsKey('ExpectedReasoningEffort')) {
      $args += @('--expected-reasoning-effort', $ExpectedReasoningEffort)
    }
    if ($Apply) {
      $args += '--apply'
    }
    & $python.Source @args
  }
  if ($LASTEXITCODE -ne 0) {
    throw "$LogPrefix helper failed with exit code $LASTEXITCODE"
  }
} finally {
  Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
}
