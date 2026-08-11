# Codex Desktop Store 升级后全量补丁修复记录

> 复核日期：2026-08-11（Asia/Shanghai）

## 结论

Store 将 Codex Desktop 升级到 `26.803.10989.0` 后，ASAR/MSIX 修复仍可复验，但新 bundled `@oai/sky 0.6.6` 的 Windows 10 native screenshot helper 未被旧 profile 覆盖。窗口枚举和激活正常，真实截图触发 `SetIsBorderRequired failed: The requested interface is not supported (0x80004002)`。

旧补丁器将未知 hash 保持原样。经 IDA Pro（`D:\Program Files\IDA.PRO\portable_win`）和 radare2 只读分析后，新增精确 hash profile：

| `@oai/sky` | Desktop | Original SHA-256 | Patched SHA-256 |
| --- | --- | --- | --- |
| `0.6.6` | `26.803.10989.0` | `BE488E66C38E12FA46850EE48C1F5E44ECDB0A3A64042E064E3A1A1DA286AC42` | `34D6EB4F23630AD6E7211898AA7678472C9ED7ACFD972C78B7D9E575A1C5C640` |

## 二进制边界

- Optional border：file offset `0x47E01`, `4889c34189d6eb50` -> `e980000000909090`。
- Busy return：file offset `0x4CF86`, `0f85f5340000` -> `0f85d8340000`。
- Once flag：file offset `0x4CF97`, `740d` -> `eb0d`。
- MTA wrapper：file offset `0x14868F`, 175-byte executable padding region; wrapper VA `0x14014928F`。
- Callback vtable：file offset `0x14B128`, pointer redirected to `0x14014928F`; original callback `0x14004DB43`。

IDA/r2 确认 wrapper 的 `CreateThread`、`CloseHandle`、`RoInitialize`、`RoUninitialize` IAT 解析正确。仓库不存储可执行文件，补丁器仅在完整输入/输出 hash 匹配时重建 guarded byte ranges。

## 验收

- `scripts/test-computer-use-helper-win10-patch.ps1`：`original -> patched -> idempotent install -> rollback -> idempotent rollback`、完整 hash 校验和未知 hash 拒绝均通过。
- 当 live helper 已是 patched、原始 helper 仅存在于 `.codex\backups\computer-use-helper` 时，回归测试从当前 0.6.6 runtime 读取 `package.json`，再从原始备份复制测试源，默认执行仍可复现。
- 真实 helper 安装后，`install-computer-use-local.ps1 -StrictVerifyOnly -VerifyAllBundledPluginsAvailable` 返回 `runtime import ok` / `verification ok`。
- 重置 Node REPL 后分独立调用执行 `sky.list_windows()`、激活 Explorer 和 `get_window_state({ window, include_screenshot, include_text })`；`D:\Program Files\IDA.PRO` 返回 `1125x639` 非空截图，画面包含 `kg_patch`、`misc`、`portable_win`，重复截图成功。
- 0.6.6 当前仅完成冷启动与重复静态截图、完整 hash guard 和未知 hash 拒绝；动态截图变化与长期资源稳定性仍待后续 helper 更新后重新验证。
- 已登录 Chrome 的 `https://example.com/` smoke：URL 正确、title `Example Domain`、恰好一个 `h1` 且文本为 `Example Domain`。
- `config.toml` 无 UTF-8 BOM，Python `tomllib` 解析通过；MSIX 包为 `Developer / Ok`。

未知 helper hash 必须保持原版；后续 Store/runtime 更新需要重新分析，不能迁移旧 offset。

## 审计日志

保留 `cu-repair.log`、`full-dryrun2.log`、`post-install-dryrun.log` 三份核心证据；已删除 Claude 产生的冗余 `full-dryrun.log` 和 `full-patch-install.log`。IDA 会话已关闭，临时数据库分片已清理。
