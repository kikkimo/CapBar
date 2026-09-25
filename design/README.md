# CapBar 视觉设计

打开 [capbar-visual-study.html](capbar-visual-study.html) 查看可交互的独立设计稿。HTML 内含样式和演示交互，可直接在浏览器中打开；图片保存在 `assets/`，不依赖被 Git 忽略的 `references/AIBar/`。

左侧截图为 AIBar 实际界面，右侧 CapBar 界面与数字均为设计示意，并未连接真实账号。

设计约定：

- “个人”“工作”“主账号”等是用户配置的显示名称；服务类型和账号目录决定读取对象。默认目录自动加入，显示名称可改。
- 顶部“全部刷新”刷新所有账号；每个账号右侧按钮仅刷新该账号。
- 五小时和七天窗口分别展示剩余额度及各自的重置时间。未返回的窗口不显示；窗口存在但重置时间缺失时，明确显示“重置时间未提供”。
- 账号按 Claude 与 Codex 分组；单个账号失败不影响其他账号。

AIBar 截图取自 [inxight/aibar](https://github.com/inxight/aibar)；许可文本见 [AIBar-LICENSE.txt](assets/AIBar-LICENSE.txt)。
