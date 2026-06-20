param(
  [switch]$DryRun,
  [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
  [string]$Provider,
  [string]$BackupRoot,
  [int]$BusyTimeoutMs = 10000
)

$ErrorActionPreference = 'Stop'
$LogPrefix = '[codex-provider-history-sync]'

function Write-Log([string]$Message) {
  Write-Host "$LogPrefix $Message"
}

if (-not $BackupRoot) {
  $BackupRoot = Join-Path $CodexHome 'backups_state\provider-sync-agent'
}

$python = Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $python) {
  throw "$LogPrefix error: python not found"
}

$script = @'
import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import sqlite3
import time

def log(message):
    print(f"[codex-provider-history-sync] {message}", flush=True)

def read_text(path):
    return path.read_text(encoding="utf-8", errors="replace")

def current_provider(codex_home, override):
    if override:
        return override
    config = codex_home / "config.toml"
    text = read_text(config) if config.exists() else ""
    match = re.search(r"(?m)^model_provider\s*=\s*(['\"]?)([^'\"\r\n#]+)\1", text)
    return match.group(2).strip() if match else "openai"

def state_db_paths(codex_home):
    candidates = [codex_home / "sqlite" / "state_5.sqlite", codex_home / "state_5.sqlite"]
    result = []
    seen = set()
    for candidate in candidates:
        if candidate.exists():
            resolved = candidate.resolve()
            key = str(resolved).lower()
            if key not in seen:
                seen.add(key)
                result.append(resolved)
    return result

def table_exists(con, table):
    return con.execute("select count(*) from sqlite_master where type='table' and name=?", (table,)).fetchone()[0] > 0

def table_columns(con, table):
    if not table_exists(con, table):
        return []
    return [row[1] for row in con.execute(f'pragma table_info("{table}")')]

def provider_counts_sqlite(db_path):
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        if "model_provider" not in table_columns(con, "threads"):
            return {"error": "threads.model_provider missing"}
        rows = list(con.execute(
            "select archived, coalesce(nullif(model_provider,''),'(missing)') provider, count(*) "
            "from threads group by archived, provider order by archived, provider"
        ))
        return {f"{'archived' if archived else 'active'}:{provider}": count for archived, provider, count in rows}
    finally:
        con.close()

def provider_counts_all(paths):
    return {str(path): provider_counts_sqlite(path) for path in paths}

def iter_rollouts(codex_home):
    for dirname in ("sessions", "archived_sessions"):
        root = codex_home / dirname
        if root.exists():
            yield from root.rglob("rollout-*.jsonl")

def first_line(path):
    with path.open("rb") as handle:
        raw = handle.readline()
    sep = b""
    line = raw
    if line.endswith(b"\r\n"):
        line, sep = line[:-2], b"\r\n"
    elif line.endswith(b"\n"):
        line, sep = line[:-1], b"\n"
    return line.decode("utf-8", errors="replace"), sep.decode("ascii", errors="ignore") or "\n"

def scan_rollouts(codex_home, target):
    counts = {}
    changes = []
    read_errors = []
    user_event_ids = set()
    cwd_by_id = {}
    for path in iter_rollouts(codex_home):
        try:
            line, sep = first_line(path)
            parsed = json.loads(line)
            if parsed.get("type") != "session_meta" or not isinstance(parsed.get("payload"), dict):
                continue
            payload = parsed["payload"]
            provider = payload.get("model_provider") or "(missing)"
            bucket = "archived_sessions" if "archived_sessions" in path.parts else "sessions"
            counts[(bucket, provider)] = counts.get((bucket, provider), 0) + 1
            thread_id = payload.get("id")
            cwd = payload.get("cwd")
            if isinstance(thread_id, str) and thread_id and isinstance(cwd, str) and cwd.strip():
                cwd_by_id[thread_id] = cwd
            try:
                text = path.read_text(encoding="utf-8", errors="replace")
                if thread_id and '"type":"event_msg"' in text and '"role":"user"' in text:
                    user_event_ids.add(thread_id)
            except Exception:
                pass
            if provider != target:
                next_parsed = dict(parsed)
                next_payload = dict(payload)
                next_payload["model_provider"] = target
                next_parsed["payload"] = next_payload
                changes.append({
                    "path": str(path),
                    "sep": sep,
                    "next": json.dumps(next_parsed, ensure_ascii=False, separators=(",", ":")),
                    "mtime": path.stat().st_mtime,
                    "provider": provider,
                    "thread_id": thread_id,
                })
        except Exception as exc:
            read_errors.append({"path": str(path), "error": str(exc)})
    return counts, changes, read_errors, user_event_ids, cwd_by_id

def backup_sqlite(db_path, dest):
    dest.parent.mkdir(parents=True, exist_ok=True)
    source = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    target = sqlite3.connect(dest)
    try:
        source.backup(target)
    finally:
        target.close()
        source.close()
    return str(dest)

def rewrite_rollout(change):
    path = pathlib.Path(change["path"])
    original_mtime = change["mtime"]
    text = path.read_text(encoding="utf-8", errors="replace")
    pos = text.find("\n")
    rest = "" if pos == -1 else text[pos + 1:]
    tmp = path.with_name(path.name + f".provider-sync-agent.{os.getpid()}.{int(time.time()*1000)}.tmp")
    tmp.write_text(change["next"] + change["sep"] + rest, encoding="utf-8", newline="")
    os.replace(tmp, path)
    os.utime(path, (original_mtime, original_mtime))

def update_sqlite(db_path, target, user_event_ids, cwd_by_id, busy_timeout_ms):
    con = sqlite3.connect(db_path, timeout=busy_timeout_ms / 1000)
    try:
        con.execute(f"pragma busy_timeout={int(busy_timeout_ms)}")
        cols = set(table_columns(con, "threads"))
        con.execute("begin immediate")
        provider_rows = con.execute(
            "update threads set model_provider = ? where coalesce(model_provider,'') <> ?",
            (target, target),
        ).rowcount
        user_rows = 0
        if "has_user_event" in cols:
            for thread_id in user_event_ids:
                user_rows += con.execute(
                    "update threads set has_user_event = 1 where id = ? and coalesce(has_user_event,0) <> 1",
                    (thread_id,),
                ).rowcount
        cwd_rows = 0
        if "cwd" in cols:
            for thread_id, cwd in cwd_by_id.items():
                if thread_id and cwd:
                    cwd_rows += con.execute(
                        "update threads set cwd = ? where id = ? and coalesce(cwd,'') <> ?",
                        (cwd, thread_id, cwd),
                    ).rowcount
        con.commit()
        return {"provider_rows": provider_rows, "user_event_rows": user_rows, "cwd_rows": cwd_rows}
    except Exception:
        con.rollback()
        raise
    finally:
        con.close()

def migrate_missing_threads(app_db_path, source_db_path, target, busy_timeout_ms):
    if not app_db_path.exists() or not source_db_path.exists() or app_db_path.resolve() == source_db_path.resolve():
        return {"skipped": True}
    src = sqlite3.connect(f"file:{source_db_path}?mode=ro", uri=True)
    dst = sqlite3.connect(app_db_path, timeout=busy_timeout_ms / 1000)
    src.row_factory = sqlite3.Row
    dst.row_factory = sqlite3.Row
    try:
        dst.execute(f"pragma busy_timeout={int(busy_timeout_ms)}")
        dst_ids = {row[0] for row in dst.execute("select id from threads")}
        missing_ids = [row[0] for row in src.execute("select id from threads") if row[0] not in dst_ids]
        if not missing_ids:
            return {"inserted_threads": 0, "inserted_dynamic_tools": 0, "inserted_spawn_edges": 0}
        src_cols = table_columns(src, "threads")
        dst_cols = table_columns(dst, "threads")
        common = [col for col in dst_cols if col in src_cols]
        quoted = ",".join(f'"{col}"' for col in common)
        select_cols = ",".join(f'"{col}"' for col in common)
        placeholders = ",".join("?" for _ in common)
        dst.execute("begin immediate")
        inserted_threads = 0
        for thread_id in missing_ids:
            row = src.execute(f"select {select_cols} from threads where id = ?", (thread_id,)).fetchone()
            if not row:
                continue
            values = [row[col] for col in common]
            if "model_provider" in common:
                values[common.index("model_provider")] = target
            inserted_threads += dst.execute(
                f"insert or ignore into threads ({quoted}) values ({placeholders})",
                values,
            ).rowcount
        inserted_dynamic_tools = copy_child_rows(src, dst, "thread_dynamic_tools", "thread_id", missing_ids)
        inserted_spawn_edges = copy_spawn_edges(src, dst)
        dst.commit()
        return {
            "inserted_threads": inserted_threads,
            "inserted_dynamic_tools": inserted_dynamic_tools,
            "inserted_spawn_edges": inserted_spawn_edges,
            "source": str(source_db_path),
            "destination": str(app_db_path),
        }
    except Exception:
        dst.rollback()
        raise
    finally:
        src.close()
        dst.close()

def copy_child_rows(src, dst, table, id_col, ids):
    if not table_exists(src, table) or not table_exists(dst, table):
        return 0
    src_cols = table_columns(src, table)
    dst_cols = table_columns(dst, table)
    common = [col for col in dst_cols if col in src_cols]
    quoted = ",".join(f'"{col}"' for col in common)
    select_cols = ",".join(f'"{col}"' for col in common)
    placeholders = ",".join("?" for _ in common)
    total = 0
    for thread_id in ids:
        for row in src.execute(f"select {select_cols} from {table} where {id_col} = ?", (thread_id,)):
            total += dst.execute(
                f"insert or ignore into {table} ({quoted}) values ({placeholders})",
                [row[col] for col in common],
            ).rowcount
    return total

def copy_spawn_edges(src, dst):
    table = "thread_spawn_edges"
    if not table_exists(src, table) or not table_exists(dst, table):
        return 0
    src_cols = table_columns(src, table)
    dst_cols = table_columns(dst, table)
    common = [col for col in dst_cols if col in src_cols]
    quoted = ",".join(f'"{col}"' for col in common)
    select_cols = ",".join(f'"{col}"' for col in common)
    placeholders = ",".join("?" for _ in common)
    dst_ids = {row[0] for row in dst.execute("select id from threads")}
    total = 0
    for row in src.execute(f"select {select_cols} from {table}"):
        if row["parent_thread_id"] in dst_ids and row["child_thread_id"] in dst_ids:
            total += dst.execute(
                f"insert or ignore into {table} ({quoted}) values ({placeholders})",
                [row[col] for col in common],
            ).rowcount
    return total

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--codex-home", required=True)
    parser.add_argument("--provider")
    parser.add_argument("--backup-root", required=True)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--busy-timeout-ms", type=int, default=10000)
    args = parser.parse_args()

    codex_home = pathlib.Path(args.codex_home).expanduser().resolve()
    backup_root = pathlib.Path(args.backup_root).expanduser().resolve()
    provider = current_provider(codex_home, args.provider)
    if not re.match(r"^[A-Za-z0-9_.-]+$", provider):
        raise SystemExit(f"unsafe provider id: {provider!r}")

    config = codex_home / "config.toml"
    config_hash_before = hashlib.sha256(config.read_bytes()).hexdigest() if config.exists() else None
    db_paths = state_db_paths(codex_home)
    counts_before = provider_counts_all(db_paths)
    rollout_counts_before, changes, read_errors, user_event_ids, cwd_by_id = scan_rollouts(codex_home, provider)

    log(f"target provider: {provider}")
    log(f"state dbs: {[str(path) for path in db_paths] or 'not found'}")
    log(f"sqlite before: {counts_before}")
    log(f"rollout before: {{ {', '.join(f'{k[0]}:{k[1]}={v}' for k, v in sorted(rollout_counts_before.items()))} }}")
    log(f"planned rollout first-line updates: {len(changes)}")
    if read_errors:
        log(f"rollout read errors skipped: {len(read_errors)}")

    if args.dry_run:
        sqlite_result = {"dry_run": True}
        backup_dir = None
    else:
        backup_dir = backup_root / time.strftime("%Y%m%d-%H%M%S")
        backup_dir.mkdir(parents=True, exist_ok=True)
        manifest = {
            "target_provider": provider,
            "config_sha256_before": config_hash_before,
            "db_paths": [str(path) for path in db_paths],
            "sqlite_counts_before": counts_before,
            "rollout_counts_before": {f"{k[0]}:{k[1]}": v for k, v in sorted(rollout_counts_before.items())},
            "rollout_changes": changes,
            "rollout_read_errors": read_errors,
        }
        manifest["sqlite_backups"] = [
            backup_sqlite(db, backup_dir / f"{db.parent.name}.{db.name}.bak")
            for db in db_paths
        ]
        (backup_dir / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
        for change in changes:
            rewrite_rollout(change)
        sqlite_result = {
            str(db): update_sqlite(db, provider, user_event_ids, cwd_by_id, args.busy_timeout_ms)
            for db in db_paths
        }
        app_db = codex_home / "sqlite" / "state_5.sqlite"
        legacy_db = codex_home / "state_5.sqlite"
        sqlite_result["migration"] = migrate_missing_threads(app_db, legacy_db, provider, args.busy_timeout_ms)

    config_hash_after = hashlib.sha256(config.read_bytes()).hexdigest() if config.exists() else None
    if config_hash_before != config_hash_after:
        raise SystemExit("config.toml hash changed unexpectedly")
    counts_after = provider_counts_all(db_paths)
    rollout_counts_after, _, read_errors_after, _, _ = scan_rollouts(codex_home, provider)
    log(f"sqlite update: {sqlite_result}")
    log(f"sqlite after: {counts_after}")
    log(f"rollout after: {{ {', '.join(f'{k[0]}:{k[1]}={v}' for k, v in sorted(rollout_counts_after.items()))} }}")
    log(f"config.toml sha256 unchanged: {config_hash_after}")
    if backup_dir:
        log(f"backup: {backup_dir}")
    if read_errors_after:
        log(f"remaining rollout read errors: {len(read_errors_after)}")

if __name__ == "__main__":
    main()
'@

$tempRoot = Join-Path $env:TEMP 'codex-provider-history-sync'
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
$pyPath = Join-Path $tempRoot ('sync-' + [guid]::NewGuid().ToString('N') + '.py')
try {
  Set-Content -LiteralPath $pyPath -Value $script -Encoding UTF8
  $argsList = @(
    $pyPath,
    '--codex-home', $CodexHome,
    '--backup-root', $BackupRoot,
    '--busy-timeout-ms', [string]$BusyTimeoutMs
  )
  if ($Provider) { $argsList += @('--provider', $Provider) }
  if ($DryRun) { $argsList += '--dry-run' }
  Write-Log "using codex home: $CodexHome"
  & $python.Source @argsList
  if ($LASTEXITCODE -ne 0) {
    throw "$LogPrefix error: python sync failed with exit code $LASTEXITCODE"
  }
} finally {
  Remove-Item -LiteralPath $pyPath -Force -ErrorAction SilentlyContinue
}
