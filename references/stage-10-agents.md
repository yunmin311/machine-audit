# Stage 10 · Agent 与 CLI 盘点

## 目的
AI agent 工具是本世代新的磁盘/隐私/进程面：数据目录膨胀、凭据散落、沙箱账户、同步外流。按人群裁剪：无 agent 的机器本阶段输出"未发现"。

## 标准动作
1. **agent 数据目录矩阵**（overlay `agent_dirs_extra` 可扩清单）：逐个测体量与最后活动时间——`~/.codex|.Codex|.claude|.zcode|.workbuddy|.local/share/opencode|.dsh|.kilo|.gemini|.qwen|.cc-switch|.agent-browser` 等；子项拆解（sessions/.tmp/plugins）。体量阈值：单工具 >5GB 或总量 >25GB → P2 提示。
2. **CLI 识别**：npm/cargo/uv/pip 渠道清单 + PATH 扫描（claude/codex/gemini/opencode/dsh/kilo/qwen…）——新装 agent = 登记 + 自动纳入下一轮矩阵。
3. **凭据台账**：各 agent 的 auth/credentials/token 文件只列元数据（路径/大小/mtime）；新增 = P1。台账必须包含同步通道交叉检查：**Syncthing/OneDrive 的同步范围若覆盖凭据文件所在目录 = P0**（凭据外传）。
4. **沙箱账户群**：`net user` + `Win32_UserAccount`——agent 工具创建的沙箱账户（命名模式 `*-sbx-*`/`*Sandbox*`）为已知形态；**其他陌生启用账户 = P0**。administrators 组成员核对。
5. **运行态**：agent 相关进程快照（实例数/内存）——多实例/孤儿实例是"卡死连锁"前兆；各 agent 最新日志文件 mtime 与 ERROR 行计数（崩溃循环识别）。
6. **行为与空壳源头检查**：agent 可能在项目内写数据（`.claude/`、`.workbuddy/`、`.smart-env/` 等目录出现在项目根）——登记并提示"确认被 gitignore/同步排除覆盖"。若盘根或容器根反复出现 `YYYY-MM-DD-HH-mm-ss` 纯时间戳空壳或仅含 `<64KB` `memory/` 的伪空壳，须提醒核查客户端（如 WorkBuddy/IDE）默认工作区路径配置并迁入独立 `spaces/` 或 `$env:TEMP`，防止边清进回收站边继续再生。

## 判定
- 凭据进入同步通道 / 陌生启用账户 / agent 日志里的认证错误循环 = P0/P1。
- 新 agent 未登记 = P2（登记本身是轻动作）。

## 坑
- electron 多进程 ≠ 多开异常；syncthing 双进程 = 主+monitor 常态。
- agent 日志的错误行要定性（网络重试噪音 vs 认证失败循环），不能只报数量。
