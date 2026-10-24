# 外部只读访问与单次刷新

从 0.3.0 起提供。需要运行 CapBar 并在设置中开启相应权限。

## 设置

打开 CapBar → 账号与设置 → 外部访问：

1. **启用外部访问**：允许本机工具查询账号身份、额度与已有统计。默认关闭。
2. **允许外部单次刷新**：额外允许一次性刷新。默认关闭，不会开启定时采样。

没有远程配置、账号管理或定时任务接口。查询陈旧快照也不会自动探测。

## MCP

点击“复制 MCP 配置”，把配置加入 MCP 客户端。复制的路径指向当前运行的 App；正式安装后请从安装版本重新复制。

Claude Code 可配置 stdio 服务，例如（将路径替换为当前 App 内的实际路径）：

```sh
claude mcp add --transport stdio capbar -- /Applications/CapBar.app/Contents/MacOS/capbar-mcp
```

Codex 可通过 MCP 设置添加同一个可执行程序，或使用 CLI：

```sh
codex mcp add capbar -- /Applications/CapBar.app/Contents/MacOS/capbar-mcp
```

更改刷新许可后，重新连接 MCP 客户端以重新获取工具列表。服务端每次都会检查许可，不会因为客户端缓存了工具而绕过关闭状态。

只读工具：`capbar_get_status`、`capbar_list_accounts`、`capbar_get_quotas`、`capbar_get_usage`、`capbar_get_statistics`、`capbar_get_records`、`capbar_get_refresh_status`。

可选工具：`capbar_refresh_once`。

## 本地接口

HTTP/JSON 运行于 `<用户私有临时目录>/capbar-<uid>/api.sock`，不监听 TCP 端口。

```sh
curl --unix-socket "$(getconf DARWIN_USER_TEMP_DIR)capbar-$(id -u)/api.sock" \
  --header @"$HOME/Library/Application Support/CapBar/ExternalAccess/authorization.header" \
  http://capbar.local/v1/status
```

```sh
curl --unix-socket "$(getconf DARWIN_USER_TEMP_DIR)capbar-$(id -u)/api.sock" \
  --header @"$HOME/Library/Application Support/CapBar/ExternalAccess/authorization.header" \
  --header 'Content-Type: application/json' \
  --data '{"selector":{"all":true}}' \
  http://capbar.local/v1/quotas/query
```

不要将密钥/header 文件上传到仓库或粘贴到对话。配置复制操作不包含密钥。重置访问密钥会立即使旧密钥失效。

## 单次刷新流程

1. get_status 取得当前 instance_id。
2. 生成 request_key（UUID），调用 refresh_once，携带 selector、instance_id 和 request_key。
3. 按返回的 job_id 每隔约 2 秒查一次进度，终态后停止。
4. get_quotas 读取结果；失败项仍保留旧快照和原采集时间。

网络重试复用同一 request_key。App 重启后旧任务不恢复执行，先重新读取状态和快照。已有账号刷新会被复用；正在排队时关闭许可，未启动的外部项会跳过。

## 统计含义

- 当前额度：每个窗口的剩余与已用百分比、采集时间、重置时间。
- 区间用量：与界面相同的近七日绘图间隔；缺测为 null。
- 服务合计：以该服务第一个账号为基准折算，属于估算等效使用量。
- 历史日/七日纪录：已结束的本地自然日，缺测计 0；不包含当天。
- 用量统计关闭后仍可读旧历史；外部查询/刷新不自动开启统计。

完整参数和返回字段见 [设计文档](design/external-api-and-mcp.md)。
