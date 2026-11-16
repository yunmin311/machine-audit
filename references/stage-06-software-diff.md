# Stage 06 · 软件与服务自启 diff

## 目的
软件面与服务面相对上一轮基线的变化，以及"登记与实体一致性"。核心纪律：**新增项必须逐个溯源**。

## 标准动作
1. **卸载表全量**：三键（HKLM 64/32 + HKCU）`DisplayName/DisplayVersion/InstallDate/InstallLocation/UninstallString` 导出，与上轮 diff：新增/消失各列一行。
2. **第三方自启服务**：`Win32_Service`，StartMode=Auto 且 PathName 不在 Windows 目录。与基线 diff；**PathName 指向不存在文件 = 死服务**（联动 15；解析规则见 conventions PATH 两步法）。
3. **自启面**：`Win32_StartupCommand` + HKCU/HKLM Run + 两个 Startup 文件夹——与基线 diff；指向项目 node_modules/target\debug 的自启单列（开发产物当生产自启用）。
4. **非微软计划任务**：TaskPath 非 `\Microsoft*` 全列 + Actions.Execute 存在性；新增任务逐个看动作与触发器。
5. **Appx**：`Get-AppxPackage` 计数与新增（store 应用常被忽略）。

## 判定
- 新增自启服务/任务/Run 项 → 必须溯源到安装事件（最近装的什么软件）；无法溯源 = P1。
- 死服务/死自启 → R 清单（15）。
- 计划任务名含中文或语义不明（如定时关机类）→ 单列高危提示。

## 坑
- MSI 卸载条目 UninstallString 永远是 msiexec.exe——存在性检查无意义。
- electron 应用一个进程名多个实例是常态，别当多开异常。
- 服务 PathName 引号规则：带引号取引号内首段；不带引号按 ` -`/` /` 切。
