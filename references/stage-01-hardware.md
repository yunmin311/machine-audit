# Stage 01 · 硬件与系统

## 目的
建立硬件画像、核对固件/驱动新旧、发现"第三方虚拟设备"与异常配置。只读。

## 标准动作
1. 基线：`Win32_ComputerSystem`（厂商/型号/内存）、`Win32_BIOS`（版本/日期）、`Win32_Processor`、`Win32_PhysicalMemory`（**Speed vs ConfiguredClockSpeed 对比**——标称跑不满是常见可修复项）、`Win32_PageFileUsage`、`powercfg /getactivescheme`。
2. 存储：`Get-Disk`（**FirmwareVersion**——对照厂商最新，如 980 PRO 的 5B2QGXA7 修复过变砖 bug）、`Get-PhysicalDisk`（HealthStatus；HDD 标记会触发阶段 2 降级）、分区布局。
3. 图形：`Win32_VideoController`（**DriverDate 与最新版核对**——OEM 锁定导致数年不更新是高发项）；注意 `AdapterRAM` 是 32 位会溢出（8GB 卡显示 4GB），以型号为准；第三方虚拟显示驱动（Mirage/GameViewer 类远程串流残留）逐个登记。
4. 网卡/音频：`Win32_PnPSignedDriver` 按 DeviceName 过滤，DriverDate 超过 2 年的列"过时候选"。
5. 距上次重启天数（>14 提示）；`Win32_StartupCommand` 不在此阶段。

## 判定
- HealthStatus 非 Healthy → P0。固件/BIOS 有已知修复且本机落后 → P1（需联网核对最新版，结论带来源与日期）。
- 驱动过时 >3 年 → P2 候选（更新建议注明 OEM 锁定可能性）。
- 内存 ConfiguredClockSpeed < Speed → P2（BIOS 可调项）。
- 出现无主虚拟设备驱动 → 联动阶段 15 溯源。

## 坑
- `Win32_VideoController.AdapterRAM` 溢出不可信；`WmiMonitorID` 在部分机型返回空。
- 电池设计容量查询需管理员且厂商各异——拿不到就标受限，勿猜百分比。
- 品牌机预装工具链差异大：服务名不进白名单，统一按"非 Windows 目录"规则报告。
