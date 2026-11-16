# Stage 09 · 事件日志四查

## 目的
用日志回答"这台机器正在发生什么异常"。四查：系统错误、应用崩溃、安全相关 provider、噪音基线 diff。

## 标准动作
1. **System 7 天 Level 1/2**：`Get-WinEvent -FilterHashtable @{LogName="System";Level=1,2;StartTime=(Get-Date).AddDays(-7)}` 按 ProviderName 分组计数——与 overlay `noise` 噪音基线 diff。
2. **高频新源下钻**：非基线来源且 >50 条/周 → 按 `Id` 再分组，取样例 Message 前 200 字，定性到具体服务/程序。
3. **应用崩溃 30 天**：ProviderName="Application Error" 按 `出错应用程序名称` 分组；对崩溃 ≥3 次的程序，取 ".NET Runtime" 同期事件拿完整堆栈（FailFast/异常类型/故障模块）。
4. **PowerShellCore/Operational**：崩溃（FailFast）与 53506 IPC 噪音区分；脚本块 4104 是审计日志非错误。
5. **噪音登记（v0.6 修正）**：本轮定性为噪音的新模式（如某客户端高频 TLS 错误）先进"待确认"——需要连续两轮模式一致 + 来源定性 + 复查时间，才可写入 overlay `noise:` 段成为豁免。**新观察不自动成为白名单**。

## 判定
- 非基线来源 >50 条/周且无法定性 → P1（日志洪水会淹没真故障）。
- 新应用崩溃程序 → P2（一次异常不算病，复发才算——同模式第二次出现才升级，见成熟的运维原则）。
- FailFast 类崩溃给完整堆栈定位到模块与上游 bug 编号。

## 坑
- `Get-WinEvent` 空结果会抛异常——try/catch 包裹，"无记录"也是有效结论。
- 安全类 provider（Schannel）高频错误多数是客户端 TLS 行为噪音，定性到进程后降级。
- 日志默认轮转覆盖——查 30 天前可能查不到，不是"没有历史"。
