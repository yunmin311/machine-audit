# Stage 05 · 虚拟化

## 目的
盘点所有虚拟机平台：登记与实体的一致性、虚拟磁盘的位置与体量、平台间冲突。

## 标准动作
1. **WSL**：`wsl.exe -l -v`（UTF-16 清洗）+ 注册表 `HKCU:\...\Lxss` 枚举——两者数量必须一致，不一致=隐藏发行版；每个发行版的 vhdx 路径与体量；`wsl --status`（默认版本/NAT-mirrored）。
2. **VirtualBox**：注册表 InstallDir + `<配置目录>\VirtualBox.xml` 的 MachineEntry 计数（0 台=纯壳安装）；驱动服务状态；目录在不在（服务在、目录不在=死服务，联动 15）。
3. **Hyper-V**：`Get-VM` 可用则列 VM；不可用（家庭版）则查 `C:\ProgramData\Microsoft\Windows\Hyper-V` 与 Public Documents 目录、`Get-CimInstance Win32_ComputerSystem` 的 HypervisorPresent。
4. **模拟器**：卸载表按 BlueStacks/LDPlayer/MuMu/Nox/雷电/夜神/逍遥/Genymotion 关键词扫描（安卓模拟器=虚拟机，且自带驱动）。
5. **虚拟磁盘全盘搜**：`*.vhd,*.vhdx,*.vdi,*.qcow2,*.vmx,*.vbox`——排除已知 WSL/Docker 路径后，孤儿磁盘文件=候选（可能是被删 VM 的遗产）。
6. **平台冲突矩阵**：VBS/Hypervisor 在跑时，VirtualBox 旧版/模拟器/反作弊的兼容性提示。

## 判定
- 注册表登记 vs 实体不一致（死服务/幽灵安装）→ 联动 15。
- 孤儿 vhdx >1GB → P2（占用+隐私：里面可能有旧系统数据）。
- 虚拟网卡数量突变 → 对照基线声明。

## 坑
- `wsl -l` 输出 UTF-16 + 中文版本名（Ubuntu-24.04 之外的发行版名可能是本地化文本）。
- VirtualBox MachineEntry 数与 `.VirtualBox` 目录里 VirtualBox.xml-prev 可能不同步——以主 xml 为准。
- Docker Desktop 的 WSL 发行版（docker-desktop）是机制一部分，不算"多余虚拟机"。
