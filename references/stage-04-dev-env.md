# Stage 04 · 开发环境 / PATH / 凭据

## 目的
工具链矩阵、PATH 健康度、配置漂移、凭据暴露。按人群裁剪：非开发机（无 git/node）本阶段缩为 PATH+凭据两项。

## 标准动作
1. **版本矩阵**：`where.exe`/`Get-Command` 逐工具定位（git/node/python/pwsh/docker/java/cargo/uv…），`which -a` 等价物找多路径冲突；版本号采集（`--version` 仅对已知安全参数的工具执行）。
2. **PATH 审计**：Machine/User 两 scope 分列；每条 `Test-Path`（失效条目）；重复组（含尾反斜杠变体）；总长度（>2048 P1）；**顺序劫持**：同名可执行文件在两处的解析顺序（如旧 prefix 的 shim 抢在新全局 bin 前）。
3. **身份与代理**：`git config --global user.email`（个人邮箱/GitHub noreply 判定）；`http.proxy/https.proxy` 指向端口 vs `Get-NetTCPConnection` 实际监听（**端口错配 = 推送失败的功能性根因，定级见判定节：P1**）。
4. **包管理器配置**：npm（prefix/cache/registry/token）、pip、pnpm、uv、cargo——缓存位置在 C 盘还是数据盘（迁移建议素材）。
5. **凭据台账**（只列元数据，绝不读内容）：`~/.npmrc` authToken、各 agent auth 文件（`.claude/.credentials*`、`.codex/auth.json`、`.cc-switch/*.json` 等）、`~/.ssh` 私钥数、明文恢复码/密钥文件（Downloads 类目录扫描 `*recovery*|*secret*|*.pem|*.key`）。新增凭据文件 = P1。
6. Python 多版本：`py -0p` 注册表 vs 实际目录 vs PATH 可见性三角核对。
7. **CLI 登录体检**（现查现停，不自动登录或切换）：
   - 检查：`gh auth status` / `git config user.email` / `npm whoami` / `docker info` / `ssh -T -o BatchMode=yes -o ConnectTimeout=5 git@github.com`
   - 三态输出：`未登录` / `凭据过期` / `身份不符（期望 vs 实际）`（`ssh -T` 鉴权成功亦常返回退出码 1，以欢迎文本判定；离线标 `受限`）
   - 隐私与修复：报告只写 `"已登录（账号已脱敏）"`，不写 token 或完整账号名；仅给出修复命令（如 `gh auth login`），不自动执行

## 判定（v0.6 重写：五要素发现结构，拒绝武断定级）

每条发现按五要素记录：**观察到的事实 / 可能影响 / 证据充分程度 / 严重程度 / 适用规则**。严重程度必须与实际暴露和用户规则挂钩，禁止一律套高等级：

- **个人邮箱出现在 git 身份**：事实=某仓近期提交使用非 noreply 邮箱；影响=该邮箱可被采集（**仅当仓库公开**——私有仓影响大减）；证据=提交作者邮箱普查（充分）；严重度=公开仓 P1 / 私有仓 P2；适用规则=用户是否已声明该身份为公开身份（是则降为记录）。
- **git 代理端口无监听**：事实=配置端口无进程监听；影响=该配置下的 git 远程操作会失败；证据=配置值+端口扫描（充分）；严重度=**P1**（功能性故障，非安全事件；"所有推送都失败"需结合用户实际远端数量确认，不下绝对断言）。
- **新凭据文件**：事实=新增 auth/token 文件；影响=明文凭据暴露面扩大；证据=文件存在+模式匹配；严重度=P1（除非用户声明用途）。
- **未知项**（看不懂的配置/工具）：先记"待确认"，运行时搜索后再定级——未知≠危险。

## 坑
- `python3` 命中商店 stub（WindowsApps）≠ Python 已装；`py -0p` 看不到 stub。
- pip --user 脚本目录与全局 Scripts 是两套。
- `npm config get cache` 等结果才是真位置，别假设默认路径。
