# CapBar

计划中的 macOS 菜单栏额度查看工具。目前仅建立仓库并调研参考项目，尚未开始实现。

## 已确认的需求

- 默认读取 `~/.claude` 和 `~/.codex`。
- 可按名称添加多个 Claude Code 或 Codex 账号目录，并分别显示额度、重置时间和数据更新时间。
- 各目录独立读取，不切换 CLI 的全局登录状态。

## AIBar 参考

参考仓库：[inxight/aibar](https://github.com/inxight/aibar)，本地克隆位于 `references/AIBar/`。整个 `references/` 目录已被 `.gitignore` 排除，不会上传到本仓库。

值得参考：

- Claude 与 Codex 的读取和失败状态分开处理，一个服务失败不影响另一个服务。
- Codex 通过本机 `codex app-server` 的 `account/rateLimits/read` 查询；识别五小时与七天窗口时看 `windowDurationMins`，而不是假定 `primary` 的含义。
- Claude 从本机凭据读取 token 后查询用量，展示刷新时间，并在凭据过期时给出提示。
- 菜单栏精简显示，展开面板展示额度和重置时间。

不能直接沿用：

- AIBar 的数据模型只有一个 Claude 和一个 Codex 结果；凭据路径及 Codex 进程也面向默认目录。CapBar 需要以“服务 + 账号目录”为独立配置与刷新单位。
- 自定义 Claude 目录不能无条件回退到默认 Keychain 凭据，否则可能把默认账号的额度误标为另一个账号。
- AIBar 的 README 仍写着 Codex `-a untrusted`，但当前源码已经改成 `-a never`；参考实现时应以实际源码和当前 CLI 支持情况为准。
- Claude 用量接口并非稳定公开 API，后续实现和分发前需再核实兼容性及使用规则。

AIBar 为 MIT 许可；如果后续复制其代码或资源，应遵守许可证与商标要求。当前仓库没有复制 AIBar 源码。
