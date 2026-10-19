# 核显省电工具箱（iGPU saving toolbox）

纯 PowerShell 实现的**独显省电工具箱**，面向**同方（TongFang）模具**笔记本：

- 无需安装、**不携带任何 exe**、无第三方依赖（只用 Windows 自带组件）
- 读取显卡/固件信息并生成报告（只读，不改设置）
- **禁用 / 启用独显**（Windows PnP 设备层）
- **热切换**：在支持固件的机型上让独显真正下线（无需重启）

> 本工具为独立社区项目，非任何厂商官方工具，与硬件厂商无隶属或授权关系。

## 功能分级

| 机型 | 能力 | 实现 |
|---|---|---|
| RTX 30 / 40 系 | 禁用 / 启用显示设备（省电、降温） | Windows PnP（`Get-PnpDevice` / `Disable-PnpDevice` / `pnputil`） |
| RTX 50 系 | 固件支持时**真正让独显下线** | 文档化 ACPI-WMI 接口（`ACPI\PNP0C14`）读取支持位与状态、写入设备选择字 |

> 内屏由独显驱动时脚本会**拒绝执行**（否则会黑屏）；有程序占用独显时会先报告，需显式 `-Force` 才会强制释放。

## 快速使用

1. 保持整个目录完整（不要只拷单个文件）
2. 双击 **`双击运行-核显省电工具箱.cmd`**（会请求管理员权限，必须允许）
3. 在中文菜单里选数字按回车

也可以直接调用脚本（便于被其他项目引用）：

```powershell
# 只读体检
.\Invoke-DgpuSilence.ps1 -Action Status

# 禁用独显（省电）
.\Invoke-DgpuSilence.ps1 -Action Disable -Elevated

# 恢复独显
.\Invoke-DgpuSilence.ps1 -Action Enable -Elevated

# 固件热切换（仅支持机型）
.\Invoke-GpuHotSwitch.ps1 -Action Silence -Yes
.\Invoke-GpuHotSwitch.ps1 -Action Restore -Yes
```

## 脚本与参数契约

| 脚本 | 作用 | 主要参数 |
|---|---|---|
| `GpuPowerSavingToolbox.ps1` | 中文菜单入口 | — |
| `Invoke-DgpuSilence.ps1` | PnP 禁用/启用独显 | `-Action Status\|Disable\|Enable`、`-Force`、`-NoElevate`、`-Elevated`、`-DryRun`、`-RemoveDevice` |
| `Invoke-GpuHotSwitch.ps1` | 固件热切换（读取支持位、写入选择字、校验与回滚） | `-Action Status\|Silence\|Restore`、`-Yes`、`-Force`、`-DryRun`、`-StateEngine <helpers.ps1>` |
| `Get-NvramState.ps1` | 只读固件状态探测与快照/对比 | `-Mode Probe\|Snapshot\|Compare` |
| `Clear-DgpuOccupants.ps1` | 列出/释放占用独显的程序 | `-List`、`-Kill`、`-Tier heavy\|light` |

退出码（`Invoke-DgpuSilence.ps1`）：`0` 成功 · `2` 门控拒绝 · `3` 被占用 · `4` 禁用失败 · `5` 启用失败。

## 安全设计

- 显示拓扑门控：内屏由独显驱动时拒绝执行，避免黑屏
- 独占检测：先报告占用程序，强制释放需显式开关
- 结果校验与自动回滚：热切换后校验状态，失败自动切回
- 全程日志与退出码，便于脚本化调用

## 许可

[MIT](LICENSE)

---

> 备注：本仓库为脚本原版，可直接被其他项目引用或调用；不依赖任何加载器、插件框架或运行时。
