import importlib.util
import pathlib
import os
import re
import subprocess
import sys
import tempfile
import unittest
import urllib.request
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "remote_auth", ROOT / "scripts" / "refresh-remote-control-auth.py"
)
AUTH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUTH)


class ProxyDefaultsTests(unittest.TestCase):
    def test_default_uses_standard_environment_or_system_handler(self):
        with mock.patch.object(urllib.request, "getproxies", return_value={"https": "http://proxy.test:3128"}):
            opener = AUTH.make_opener(None)
        handlers = [handler for handler in opener.handlers if isinstance(handler, urllib.request.ProxyHandler)]
        self.assertEqual(handlers[0].proxies, {"https": "http://proxy.test:3128"})

    def test_explicit_direct_does_not_load_system_proxies(self):
        with mock.patch.object(urllib.request, "getproxies", side_effect=AssertionError("must remain direct")):
            opener = AUTH.make_opener("")
        self.assertFalse(any(isinstance(handler, urllib.request.ProxyHandler) for handler in opener.handlers))

    def test_explicit_proxy_overrides_discovery(self):
        with mock.patch.object(urllib.request, "getproxies", side_effect=AssertionError("explicit proxy was ignored")):
            opener = AUTH.make_opener("http://explicit.test:8888")
        handler = next(handler for handler in opener.handlers if isinstance(handler, urllib.request.ProxyHandler))
        self.assertEqual(handler.proxies, {"http": "http://explicit.test:8888", "https": "http://explicit.test:8888"})

    def test_cli_preserves_default_direct_and_override_as_different_choices(self):
        for arguments, expected in (([], None), (["--proxy", ""], ""), (["--no-proxy"], ""), (["--proxy", "http://explicit.test:8888"], "http://explicit.test:8888")):
            with self.subTest(expected=expected), mock.patch.object(sys, "argv", ["auth", "--verify-only", *arguments]), mock.patch.object(AUTH, "verify_remote", return_value={"ok": True}) as verify, mock.patch.object(AUTH, "print_json"):
                self.assertEqual(AUTH.main(), 0)
                self.assertEqual(verify.call_args.args[1], expected)

    def test_standard_no_proxy_semantics_are_preserved(self):
        with mock.patch.dict("os.environ", {"no_proxy": ".example.test,api.test:443"}, clear=True):
            self.assertTrue(urllib.request.proxy_bypass_environment("auth.example.test:443"))
            self.assertTrue(urllib.request.proxy_bypass_environment("api.test:443"))
            self.assertFalse(urllib.request.proxy_bypass_environment("api.test:80"))

    def test_all_legacy_patch_hunks_remain_valid_without_a_local_proxy_fallback(self):
        paths = [ROOT / "references" / name for name in (
            "remote-control-native-replacement.patch",
            "remote-control-native-replacement-0.142.4.patch",
            "remote-control-native-replacement-0.145.0-alpha.18.patch",
            "remote-control-native-replacement-0.154.0-alpha.6.2.patch",
        )]
        for path in paths:
            with self.subTest(patch=path.name):
                text = path.read_text(encoding="utf-8")
                self.assertNotIn("10808", text)
                self.assertNotIn("env::set_var", text)
                self.assertNotIn("TcpStream::connect_timeout", text)
                self.assertIn("configured_remote_control_proxy", text)
                self.assertIn('"HTTPS_PROXY"', text)
                self.assertIn('"ALL_PROXY"', text)
                lines = text.splitlines()
                index = 0
                originals = {}
                current_file = None
                while index < len(lines):
                    if lines[index].startswith("--- a/"):
                        current_file = lines[index][6:]
                        originals.setdefault(current_file, [])
                    header = re.match(r"@@ -(\d+),(\d+) \+\d+,(\d+) @@", lines[index])
                    index += 1
                    if not header:
                        continue
                    old_count = new_count = 0
                    original = originals[current_file]
                    old_start = int(header.group(1)) - 1
                    self.assertGreaterEqual(old_start, len(original), "patch hunks must not overlap")
                    original.extend(["// omitted upstream context"] * (old_start - len(original)))
                    while index < len(lines) and not lines[index].startswith(("@@ ", "diff --git ")):
                        line = lines[index]
                        old_count += line.startswith((" ", "-"))
                        new_count += line.startswith((" ", "+"))
                        if line.startswith((" ", "-")):
                            original.append(line[1:])
                        index += 1
                    self.assertEqual((old_count, new_count), (int(header.group(2)), int(header.group(3))))
                subprocess.run(["git", "apply", "--numstat", str(path)], cwd=ROOT, check=True, capture_output=True)
                with tempfile.TemporaryDirectory(prefix="rc-proxy-fixture-", dir=os.environ.get("TEMP")) as fixture:
                    for name, original in originals.items():
                        target = pathlib.Path(fixture) / name
                        target.parent.mkdir(parents=True, exist_ok=True)
                        target.write_text("\n".join(original) + "\n", encoding="utf-8")
                    subprocess.run(["git", "apply", "--check", str(path)], cwd=fixture, check=True, capture_output=True)


if __name__ == "__main__":
    unittest.main()
