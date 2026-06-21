import argparse
import base64
import datetime as dt
import hashlib
import http.server
import json
import os
import pathlib
import secrets
import shutil
import socket
import socketserver
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser


ISSUER = "https://auth.openai.com"
CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
SCOPE = "openid profile email offline_access api.connectors.read api.connectors.invoke"
DEFAULT_PROXY = "http://127.0.0.1:10808"
CLIENTS_ENDPOINT = "https://chatgpt.com/backend-api/wham/remote/control/clients"


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def now_utc() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def jwt_payload(token: str) -> dict:
    parts = token.split(".")
    if len(parts) < 2:
        raise ValueError("token is not a JWT")
    payload = parts[1] + "=" * ((4 - len(parts[1]) % 4) % 4)
    return json.loads(base64.urlsafe_b64decode(payload.encode("ascii")))


def token_meta(token: str | None) -> dict:
    if not token:
        return {}
    try:
        payload = jwt_payload(token)
    except Exception as exc:
        return {"parse_error": str(exc)}
    meta = {
        key: payload.get(key)
        for key in ("iss", "aud", "scp", "scope", "exp", "iat")
        if key in payload
    }
    if isinstance(payload.get("exp"), int):
        meta["expires_at"] = (
            dt.datetime.fromtimestamp(payload["exp"], dt.timezone.utc)
            .isoformat()
            .replace("+00:00", "Z")
        )
        meta["expired"] = payload["exp"] <= int(now_utc().timestamp())
    return meta


def make_opener(proxy: str | None) -> urllib.request.OpenerDirector:
    if proxy is None:
        return urllib.request.build_opener(urllib.request.ProxyHandler({}))
    return urllib.request.build_opener(
        urllib.request.ProxyHandler({"http": proxy, "https": proxy})
    )


def summarize_http_error(exc: urllib.error.HTTPError) -> dict:
    body = exc.read()
    try:
        parsed = json.loads(body.decode("utf-8", "replace"))
    except Exception:
        parsed = {}
    summary = {"status": exc.code}
    for key in ("error", "error_description", "message", "detail"):
        if key in parsed:
            summary[key] = parsed[key]
    return summary


def print_json(payload: dict) -> None:
    print(json.dumps(payload, ensure_ascii=False, indent=2))


def pick_port(preferred: list[int]) -> int:
    for port in preferred:
        try:
            sock = socket.socket()
            sock.bind(("127.0.0.1", port))
            actual = sock.getsockname()[1]
            sock.close()
            return actual
        except OSError:
            continue
    raise RuntimeError("no callback port available")


def load_remote(remote_path: pathlib.Path) -> tuple[dict | None, dict | None]:
    if not remote_path.exists():
        return None, {"ok": False, "reason": "remote_json_missing"}
    try:
        return json.loads(remote_path.read_text(encoding="utf-8")), None
    except Exception as exc:
        return None, {"ok": False, "reason": "remote_json_unreadable", "error": str(exc)}


def verify_remote(
    remote_path: pathlib.Path,
    proxy: str | None,
    timeout_seconds: int,
    endpoint: str = CLIENTS_ENDPOINT,
) -> dict:
    remote, error = load_remote(remote_path)
    if error:
        return {**error, "remote_path": str(remote_path)}

    assert remote is not None
    meta = token_meta(remote.get("access_token"))
    base = {
        "remote_path": str(remote_path),
        "disabled": bool(remote.get("disabled")),
        "token_meta": meta,
        "proxy": proxy or "",
        "endpoint": endpoint,
    }
    if remote.get("disabled"):
        return {**base, "ok": False, "reason": "remote_json_disabled"}
    if not remote.get("access_token"):
        return {**base, "ok": False, "reason": "access_token_missing"}
    if meta.get("expired"):
        return {**base, "ok": False, "reason": "access_token_expired"}

    request = urllib.request.Request(
        endpoint,
        headers={
            "Accept": "application/json",
            "Authorization": "Bearer " + remote["access_token"],
            "User-Agent": "CodexDesktop/26.616.5445.0",
        },
        method="GET",
    )
    opener = make_opener(proxy)
    try:
        with opener.open(request, timeout=timeout_seconds) as response:
            response.read(1024)
            return {**base, "ok": response.status == 200, "status": response.status}
    except urllib.error.HTTPError as exc:
        return {
            **base,
            "ok": False,
            "reason": "endpoint_http_error",
            **summarize_http_error(exc),
        }
    except Exception as exc:
        return {**base, "ok": False, "reason": "endpoint_request_failed", "error": str(exc)}


class CallbackServer(socketserver.TCPServer):
    allow_reuse_address = True


def run_pkce_flow(
    remote_path: pathlib.Path,
    backup_dir: pathlib.Path,
    log_path: pathlib.Path,
    proxy: str | None,
    timeout_seconds: int,
    no_open: bool,
) -> dict:
    log_path.parent.mkdir(parents=True, exist_ok=True)

    def log(event: str, **fields: object) -> None:
        payload = {"time": now_utc().isoformat(), "event": event, **fields}
        with log_path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(payload, ensure_ascii=False) + "\n")

    verifier = b64url(secrets.token_bytes(64))
    challenge = b64url(hashlib.sha256(verifier.encode("ascii")).digest())
    state = b64url(secrets.token_bytes(32))
    port = pick_port([1455, 1456, 1457, 1458, 0])
    redirect_uri = f"http://localhost:{port}/auth/callback"
    result: dict[str, dict[str, list[str]]] = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, fmt: str, *args: object) -> None:
            return

        def do_GET(self) -> None:
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path != "/auth/callback":
                self.send_response(404)
                self.end_headers()
                return
            result["query"] = urllib.parse.parse_qs(parsed.query)
            body = (
                "Codex remote-control authorization received. "
                "You can return to Codex."
            ).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            threading.Thread(target=self.server.shutdown, daemon=True).start()

    params = {
        "response_type": "code",
        "client_id": CLIENT_ID,
        "redirect_uri": redirect_uri,
        "scope": SCOPE,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "id_token_add_organizations": "true",
        "codex_cli_simplified_flow": "true",
        "state": state,
        "originator": "codex_cli_rs",
    }
    auth_url = ISSUER + "/oauth/authorize?" + urllib.parse.urlencode(params)
    log("auth_url_ready", port=port, redirect_uri=redirect_uri, proxy=proxy or "")
    print("Open this URL in the browser, finish ChatGPT authorization, then return here:")
    print(auth_url)

    with CallbackServer(("127.0.0.1", port), Handler) as server:
        threading.Thread(target=server.serve_forever, daemon=True).start()
        if not no_open:
            try:
                os.startfile(auth_url)  # type: ignore[attr-defined]
            except Exception:
                webbrowser.open(auth_url)
            log("browser_opened")
        started = time.time()
        while time.time() - started < timeout_seconds and "query" not in result:
            time.sleep(0.25)
        server.server_close()

    if "query" not in result:
        log("callback_timeout", timeout_seconds=timeout_seconds)
        return {"ok": False, "reason": "callback_timeout"}

    query = result["query"]
    if query.get("state", [None])[0] != state:
        log("callback_state_mismatch")
        return {"ok": False, "reason": "callback_state_mismatch"}
    if "error" in query:
        error = {
            "ok": False,
            "reason": "callback_error",
            "error": query.get("error", [None])[0],
            "error_description": query.get("error_description", [None])[0],
        }
        log("callback_error", **{k: v for k, v in error.items() if k != "ok"})
        return error

    code = query.get("code", [None])[0]
    if not code:
        log("callback_missing_code")
        return {"ok": False, "reason": "callback_missing_code"}

    body = urllib.parse.urlencode(
        {
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirect_uri,
            "client_id": CLIENT_ID,
            "code_verifier": verifier,
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        ISSUER + "/oauth/token",
        data=body,
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
            "User-Agent": "CodexDesktop/26.616.5445.0",
        },
        method="POST",
    )
    opener = make_opener(proxy)
    try:
        with opener.open(request, timeout=60) as response:
            raw = response.read()
            status = response.status
    except urllib.error.HTTPError as exc:
        error = summarize_http_error(exc)
        log("token_exchange_failed", **error)
        return {"ok": False, "reason": "token_exchange_failed", **error}
    except Exception as exc:
        log("token_exchange_failed", error=str(exc))
        return {"ok": False, "reason": "token_exchange_failed", "error": str(exc)}

    token_response = json.loads(raw.decode("utf-8"))
    if not token_response.get("access_token") or not token_response.get("refresh_token"):
        keys = sorted(token_response.keys())
        log("token_exchange_incomplete", status=status, keys=keys)
        return {"ok": False, "reason": "token_exchange_incomplete", "status": status, "keys": keys}

    access_payload = jwt_payload(token_response["access_token"])
    id_payload = jwt_payload(token_response["id_token"]) if token_response.get("id_token") else {}
    access_auth = access_payload.get("https://api.openai.com/auth") or {}
    id_auth = id_payload.get("https://api.openai.com/auth") or {}
    account_id = (
        access_auth.get("chatgpt_account_id")
        or access_auth.get("account_id")
        or id_auth.get("chatgpt_account_id")
        or id_auth.get("account_id")
    )
    expires_at = access_payload.get("exp")
    remote_data = {
        "access_token": token_response["access_token"],
        "refresh_token": token_response["refresh_token"],
        "id_token": token_response.get("id_token"),
        "account_id": account_id,
        "email": id_payload.get("email"),
        "type": "codex",
        "disabled": False,
        "last_refresh": now_utc().astimezone().isoformat(),
        "expired": (
            dt.datetime.fromtimestamp(expires_at, dt.timezone.utc)
            .isoformat()
            .replace("+00:00", "Z")
            if expires_at
            else None
        ),
    }
    remote_data = {key: value for key, value in remote_data.items() if value is not None}

    backup_dir.mkdir(parents=True, exist_ok=True)
    backup = None
    if remote_path.exists():
        backup = backup_dir / (
            "remote.json." + dt.datetime.now().strftime("%Y%m%d-%H%M%S") + ".bak"
        )
        shutil.copy2(remote_path, backup)

    remote_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = remote_path.with_suffix(".json.tmp")
    tmp.write_text(
        json.dumps(remote_data, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    os.replace(tmp, remote_path)
    try:
        os.chmod(remote_path, 0o600)
    except Exception:
        pass

    meta = token_meta(token_response["access_token"])
    log(
        "remote_json_written",
        status=status,
        backup=str(backup) if backup else None,
        remote_path=str(remote_path),
        token_meta=meta,
        account_id_present=bool(account_id),
        email_present=bool(id_payload.get("email")),
    )
    verify = verify_remote(remote_path, proxy, 60)
    return {
        "ok": bool(verify.get("ok")),
        "remote_path": str(remote_path),
        "backup": str(backup) if backup else None,
        "token_meta": meta,
        "verify": verify,
        "log": str(log_path),
    }


def main() -> int:
    home = pathlib.Path.home()
    codex_home = home / ".codex"
    parser = argparse.ArgumentParser(
        description="Verify or regenerate isolated Codex phone remote-control auth."
    )
    parser.add_argument("--verify-only", action="store_true", help="Only test .codex/remote.json.")
    parser.add_argument(
        "--proxy",
        default=DEFAULT_PROXY,
        help='Proxy for auth/token and verify requests. Use --proxy "" to disable.',
    )
    parser.add_argument("--timeout-seconds", type=int, default=600)
    parser.add_argument("--no-open", action="store_true", help="Print the auth URL without opening it.")
    parser.add_argument(
        "--log",
        default=str(codex_home / "remote-control-auth-refresh.log"),
        help="Non-secret JSONL log path.",
    )
    args = parser.parse_args()

    proxy = args.proxy if args.proxy else None
    remote_path = codex_home / "remote.json"
    if args.verify_only:
        result = verify_remote(remote_path, proxy, min(args.timeout_seconds, 120))
        print_json(result)
        return 0 if result.get("ok") else 1

    result = run_pkce_flow(
        remote_path=remote_path,
        backup_dir=codex_home / "backups" / "remote-control-auth",
        log_path=pathlib.Path(args.log),
        proxy=proxy,
        timeout_seconds=args.timeout_seconds,
        no_open=args.no_open,
    )
    print_json(result)
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
