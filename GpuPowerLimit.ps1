# ==============================================================================================
#  GPU 功耗上限 / Dynamic Boost 控制（同方 EC · 通过 \\.\ACPIDriver）
# ----------------------------------------------------------------------------------------------
#  ℹ️ 说明：本脚本是一份「实现思路 / 参考实现」，目前只在 4060 测试机
#     （翼龙15Pro GM5HG0A / RTX 4060 Laptop）上验证过。
#     不同机型的 EC 地址与字节语义可能不同 —— 建议先用 -Action Status / Watch 只读确认，
#     再自行判断是否写入（脚本自带原值记录与 -Action Restore 回滚）。
#
#  实测结论（4060）：
#    enforced = 115W + DB 最大 TGP
#      0x746/0x7D5 = 0x00 -> 115W    0x05 -> 120W    0x0F -> 130W    0x19 -> 140W
#    0x743 = 0x07 表示 DB 使能（bit0+bit1+bit2）；0x745/0x7D4 = 0xFF 为 DB 目标
#
#  通道：\\.\ACPIDriver（H2RAM 窗口 0x700-0x7FF）
#    读 IOCTL 2621482120 / 写 IOCTL 2621482124
#
#  安全门：
#    1) 必须管理员               2) 只写 0x700-0x7FF
#    3) 写前记录原值             4) 写前"同值回写"自检
#    5) 写后回读校验 + nvidia-smi 交叉验证
#    6) 写入需显式 -Yes；-WhatIf 只看不写；-Action Restore 可回滚
#
#  用法（管理员 PowerShell）：
#    .\GpuPowerLimit.ps1 -Action Status                 # 只读：当前 EC 字节 + GPU 功耗
#    .\GpuPowerLimit.ps1 -Action Watch -Seconds 60      # 只读：连续 diff，看切模式时哪些字节变
#    .\GpuPowerLimit.ps1 -Action EnableDb -DbWatt 25 -WhatIf   # 预演：只打印将写的值
#    .\GpuPowerLimit.ps1 -Action EnableDb -DbWatt 25 -Yes      # 写入（140W）
#    .\GpuPowerLimit.ps1 -Action DisableDb -Yes                # 关闭 DB（回到默认）
#    .\GpuPowerLimit.ps1 -Action Restore -Yes                  # 回滚到本次进入时记录的原值
# ==============================================================================================
param(
    [ValidateSet('Status','Watch','EnableDb','DisableDb','Restore','SetByte','LockLow')]
    [string]$Action = 'Status',
    [int]$DbWatt = -1,   # -1 = 使用本机检测到的最大 DB 值
    [switch]$WhatIf,
    [switch]$Yes,
    [int]$Seconds = 20,
    [int]$WriteDelayMs = 1000,
    [int]$Addr = -1,
    [int]$Value = -1,
    [string]$LogPath = ''
)

$ErrorActionPreference = 'Continue'
$script:LogFile = if ($LogPath) { $LogPath } else { Join-Path $env:TEMP 'gpu-power-limit.txt' }
if ($Action -eq 'Status' -or $Action -eq 'Watch') { Remove-Item $script:LogFile -ErrorAction SilentlyContinue }
$script:TestedNote = '参考实现：仅在 4060（GM5HG0A / RTX 4060）验证过；其它机型请先只读确认地址与字节含义，再自行判断'

function Log([string]$msg, [string]$level = 'INFO') {
    $line = ('[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss.fff'), $level, $msg)
    $color = switch ($level) { 'WARN' { 'Yellow' } 'ERR' { 'Red' } 'OK' { 'Green' } default { 'Gray' } }
    Write-Host $line -ForegroundColor $color
    try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { }
}

# ---- EC 读写（\\.\ACPIDriver）----
$src = @'
using System;
using System.Runtime.InteropServices;
public static class AcpiEcRw
{
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(IntPtr h, uint code, IntPtr inBuf, int inSize, IntPtr outBuf, int outSize, out int ret, IntPtr ov);
    const string DevicePath = "\\\\.\\ACPIDriver";
    public static IntPtr Open() { return CreateFile(DevicePath, 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero); }
    public static bool IsValid(IntPtr h) { return h != IntPtr.Zero && h.ToInt64() != -1; }
    public static void Close(IntPtr h) { CloseHandle(h); }
    public static int Read(IntPtr h, int address)
    {
        IntPtr inBuf = Marshal.AllocHGlobal(4);
        IntPtr outBuf = Marshal.AllocHGlobal(16);
        try
        {
            Marshal.WriteInt32(inBuf, 0, address);
            int ret;
            if (!DeviceIoControl(h, 2621482120, inBuf, 4, outBuf, 16, out ret, IntPtr.Zero) || ret <= 0) return -1;
            return Marshal.ReadByte(outBuf);
        }
        finally { Marshal.FreeHGlobal(inBuf); Marshal.FreeHGlobal(outBuf); }
    }
    public static bool Write(IntPtr h, int address, byte value)
    {
        IntPtr inBuf = Marshal.AllocHGlobal(8);
        IntPtr outBuf = Marshal.AllocHGlobal(16);
        try
        {
            Marshal.WriteInt32(inBuf, 0, address);
            Marshal.WriteByte(inBuf, 4, value);
            int ret;
            return DeviceIoControl(h, 2621482124, inBuf, 5, outBuf, 16, out ret, IntPtr.Zero);
        }
        finally { Marshal.FreeHGlobal(inBuf); Marshal.FreeHGlobal(outBuf); }
    }
}
'@

$script:AddrCtrl   = 0x743   # DB 使能位
$script:AddrTarget = 0x745   # DB 目标
$script:AddrMax    = 0x746   # DB 最大 TGP
$script:AddrTarget2= 0x7D4   # 第二份 DB 目标
$script:AddrMax2   = 0x7D5   # 第二份 DB 最大 TGP
# 语义已确认、允许写入的地址（其余地址默认只读）
$script:ConfirmedAddrs = @($script:AddrCtrl, $script:AddrTarget, $script:AddrMax, $script:AddrTarget2, $script:AddrMax2)
$script:EcWindowLo = 0x700
$script:EcWindowHi = 0x7FF

function Get-GpuLine {
    $smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
    if (-not (Test-Path $smi)) { return 'n/a' }
    $l = & $smi --query-gpu=enforced.power.limit,power.limit,power.draw,temperature.gpu,clocks.current.graphics --format=csv,noheader 2>$null
    if ($l) { return ([string]$l).Trim() } else { return 'n/a' }
}

function Get-EnforcedWatts {
    $line = Get-GpuLine
    if ($line -eq 'n/a') { return -1 }
    if ($line -match '([0-9]+(?:\.[0-9]+)?)\s*W') { return [double]$Matches[1] }
    return -1
}
function Get-LimitWatts {
    $line = Get-GpuLine
    if ($line -eq 'n/a') { return -1 }
    $m = [regex]::Matches($line, '([0-9]+(?:\.[0-9]+)?)\s*W')
    if ($m.Count -ge 2) { return [double]$m[1].Groups[1].Value }
    return -1
}

function Show-NvPowerDetail {
    $smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
    if (-not (Test-Path $smi)) { return }
    $q = & $smi -q -d POWER 2>$null
    foreach ($pat in @('Current Power Limit','Default Power Limit','Min Power Limit','Max Power Limit')) {
        $line = ($q | Select-String -Pattern $pat | Select-Object -First 1)
        if ($line) { Log ('  驱动侧: ' + $line.Line.Trim()) }
    }
}

function Read-Bytes([IntPtr]$h, [int[]]$addrs) {
    $o = [ordered]@{}
    foreach ($a in $addrs) { $o[[string]$a] = [AcpiEcRw]::Read($h, [int]$a) }
    return $o
}

function Format-Bytes($map) {
    ($map.Keys | ForEach-Object {
        $a = [int]$_ ; $v = $map[$_]
        if ($v -lt 0) { ('0x{0:X3}=--' -f $a) } else { ('0x{0:X3}=0x{1:X2}' -f $a, $v) }
    }) -join ' · '
}

function Get-GpuPowerLimits {
    <# 从驱动读取本机显卡的功耗范围（默认/最小/最大），返回 W。失败时返回 -1。 #>
    $o = [pscustomobject]@{ Default = -1; Min = -1; Max = -1 }
    $smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
    if (-not (Test-Path $smi)) { return $o }
    $line = & $smi --query-gpu=power.default_limit,power.min_limit,power.max_limit --format=csv,noheader 2>$null
    if (-not $line) { return $o }
    $m = [regex]::Matches([string]$line, '([0-9]+(?:\.[0-9]+)?)\s*W')
    if ($m.Count -ge 3) {
        $o.Default = [double]$m[0].Groups[1].Value
        $o.Min     = [double]$m[1].Groups[1].Value
        $o.Max     = [double]$m[2].Groups[1].Value
    }
    return $o
}

function Expected-Tgp([int]$dbWatt) {
    # enforced = 显卡默认 TGP + DB 额外瓦数（默认值来自驱动，不写死）
    if ($script:GpuLimits.Default -gt 0) { return [int]($script:GpuLimits.Default + $dbWatt) }
    return -1
}

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Log '不是管理员：请右键「以管理员身份运行」，或通过工具箱入口启动' 'ERR'
        return $false
    }
    return $true
}

function Open-Ec {
    try { Add-Type -TypeDefinition $src -Language CSharp -ErrorAction Stop | Out-Null } catch { }
    $h = [AcpiEcRw]::Open()
    if (-not [AcpiEcRw]::IsValid($h)) {
        Log '打不开 \\.\ACPIDriver —— 本机没有该设备驱动。' 'ERR'
        Log '同方机型：控制台/管理组件会自带 UWACPIDriver（设备管理器里显示为 "ACPIDriver"，实例 ACPI\INOU0000）。' 'INFO'
        Log '  - 已装同方控制台但仍打不开：确认是否被卸载/禁用，或重装控制台。' 'INFO'
        Log '  - 想自己装：UWACPIDriver 包（.inf/.cat/.sys）在同方控制台的安装目录里，' 'INFO'
        Log '    管理员运行：pnputil /add-driver UWACPIDriver.inf /install' 'INFO'
        Log '  - 本脚本只做只读探测也走这条通道，所以没有驱动时连 Status 都读不到。' 'INFO'
        return [IntPtr]::Zero
    }
    return $h
}

function Write-Checked([IntPtr]$h, [int]$addr, [byte]$val) {
    if ($addr -lt $script:EcWindowLo -or $addr -gt $script:EcWindowHi) {
        Log ('拒绝写入窗口外地址 0x{0:X3}（仅允许 0x700-0x7FF）' -f $addr) 'ERR'
        return $false
    }
    $ok = [AcpiEcRw]::Write($h, [int]$addr, [byte]$val)
    Start-Sleep -Milliseconds 60
    $rb = [AcpiEcRw]::Read($h, [int]$addr)
    $same = ($rb -eq $val)
    $lvl = if ($same) { 'OK' } else { 'WARN' }
    Log ('  写 0x{0:X3}=0x{1:X2} -> 调用={2} 回读=0x{3:X2} {4}' -f $addr, $val, $ok, ([int]$rb), $(if ($same) { 'OK' } else { 'X 不一致' })) $lvl
    return $same
}

function Target-Map([int]$dbWatt, [bool]$enable) {
    $maxByte = switch ($dbWatt) { 0 { 0x00 } 5 { 0x05 } 15 { 0x0F } 25 { 0x19 } default { 0x19 } }
    if ($enable) {
        return @(
            @{ Addr = $script:AddrCtrl;    Value = [byte]0x07 },
            @{ Addr = $script:AddrTarget;  Value = [byte]0xFF },
            @{ Addr = $script:AddrMax;     Value = [byte]$maxByte },
            @{ Addr = $script:AddrTarget2; Value = [byte]0xFF },
            @{ Addr = $script:AddrMax2;    Value = [byte]$maxByte }
        )
    }
    return @(
        @{ Addr = $script:AddrCtrl;    Value = [byte]0x01 },
        @{ Addr = $script:AddrTarget;  Value = [byte]0x00 },
        @{ Addr = $script:AddrMax;     Value = [byte]0x00 },
        @{ Addr = $script:AddrTarget2; Value = [byte]0x00 },
        @{ Addr = $script:AddrMax2;    Value = [byte]0x00 }
    )
}

function Save-Originals($sets) {
    $path = Join-Path $env:TEMP 'gpu-power-limit-orig.json'
    $sets | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Load-Originals {
    $path = Join-Path $env:TEMP 'gpu-power-limit-orig.json'
    if (-not (Test-Path $path)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

# ======================================== 主流程 ========================================
if (-not (Assert-Admin)) { exit 5 }
$h = Open-Ec
if ($h -eq [IntPtr]::Zero) { exit 6 }
$script:GpuLimits = Get-GpuPowerLimits
if ($script:GpuLimits.Default -gt 0) {
    Log ("显卡: " + (Get-GpuLine))
    Log ("功耗范围: 默认 {0}W / 最小 {1}W / 最大 {2}W  (DB 可调 0..{3}W)" -f $script:GpuLimits.Default, $script:GpuLimits.Min, $script:GpuLimits.Max, [int]($script:GpuLimits.Max - $script:GpuLimits.Default))
} else {
    Log '警告：读不到显卡的功耗范围（nvidia-smi 不可用），期望值无法计算' 'WARN'
}

try {
    Log ("=== GPU 功耗控制 · Action={0} · DbWatt={1}W ===" -f $Action, $DbWatt)
    Log ("注意：{0}" -f $script:TestedNote) 'WARN'
    Log ("GPU: " + (Get-GpuLine))

    $script:ExtraAddrs = @(0x7C4, 0x7C6, 0x751, 0x7CC)
    $readAddrs = @($script:AddrCtrl, $script:AddrTarget, $script:AddrMax, $script:AddrTarget2, $script:AddrMax2) + $script:ExtraAddrs
    $before = Read-Bytes $h $readAddrs
    Log ("当前 EC: " + (Format-Bytes $before))

    switch ($Action) {
        'Status' {
            $enforced = Get-EnforcedWatts
            Log ("enforced 功耗上限: " + $(if ($enforced -ge 0) { "$enforced W" } else { 'n/a' }))
            Show-NvPowerDetail
            if ($script:GpuLimits.Default -gt 0) {
                $dbMax = [int]($script:GpuLimits.Max - $script:GpuLimits.Default)
                Log ("本机: 默认 {0}W + DB(0..{1}W) => 上限 {2}W" -f $script:GpuLimits.Default, $dbMax, $script:GpuLimits.Max)
            } else {
                Log '读不到显卡功耗范围（nvidia-smi 不可用）' 'WARN'
            }
            Log '注意：DB 是动态的 —— 空闲时 enforced 通常仍显示基础 TGP（115W）；请跑 GPU 负载（FurMark/游戏）再看这个值。' 'WARN'
            break
        }
        'Watch' {
            Log ("开始监视 {0} 秒（只读，每 1 秒 diff 0x700-0x7FF）…" -f $Seconds)
            $prev = @{}
            for ($a = $script:EcWindowLo; $a -le $script:EcWindowHi; $a++) { $prev[$a] = [AcpiEcRw]::Read($h, $a) }
            $deadline = (Get-Date).AddSeconds($Seconds)
            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Seconds 1
                $changes = @()
                for ($a = $script:EcWindowLo; $a -le $script:EcWindowHi; $a++) {
                    $v = [AcpiEcRw]::Read($h, $a)
                    if ($v -ne $prev[$a]) { $changes += ('0x{0:X3}:0x{1:X2}->0x{2:X2}' -f $a, $prev[$a], $v); $prev[$a] = $v }
                }
                if ($changes.Count -gt 0) { Log ("  变更: " + ($changes -join ' ')) }
                Log ("  GPU: " + (Get-GpuLine))
            }
            break
        }
        'EnableDb' {
            $dbMax = [int]([math]::Max(0, $script:GpuLimits.Max - $script:GpuLimits.Default))
            if ($script:GpuLimits.Default -le 0) { Log '读不到显卡功耗范围，已中止（避免写入错误值）' 'ERR'; break }
            if ($DbWatt -lt 0) { $DbWatt = $dbMax }
            if ($DbWatt -gt $dbMax) { Log ('DB 请求 {0}W 超出本机范围 0..{1}W，已中止' -f $DbWatt, $dbMax) 'ERR'; break }
            $targets = Target-Map $DbWatt $true
            Log ("将写入（DB={0}W -> 期望 {1}W）:" -f $DbWatt, (Expected-Tgp $DbWatt))
            foreach ($t in $targets) { Log ('   0x{0:X3} = 0x{1:X2}' -f $t.Addr, $t.Value) }

            if ($WhatIf) { Log '[WhatIf] 只读预演，未写入任何字节' 'WARN'; break }

            if (-not $Yes) {
                Write-Host ''
                Write-Host ('即将写入 EC（{0}）。确认请在下方输入 YES：' -f $script:TestedNote) -ForegroundColor Yellow
                $ans = Read-Host 'Confirm'
                if ($ans -ne 'YES') { Log '用户取消' 'WARN'; break }
            }

            # 安全门：先做"同值回写"自检（写当前值再回读，确认通道正常）
            $probe = [int]$before[[string]$script:AddrMax]
            if ($probe -ge 0) {
                Log '写通道自检（同值回写 0x746）…'
                $selfOk = Write-Checked $h $script:AddrMax ([byte]$probe)
                if (-not $selfOk) { Log '写通道自检失败，已中止（未改动任何有效值）' 'ERR'; break }
            }

            Save-Originals $targets | Out-Null
            $origPath = Join-Path $env:TEMP 'gpu-power-limit-orig-before.json'
            ($before.GetEnumerator() | ForEach-Object { @{ Addr = [int]$_.Key; Value = $_.Value } }) | ConvertTo-Json | Set-Content -LiteralPath $origPath -Encoding UTF8

            # 模仿控制中心的写法：只写需要变的字节；数值两份分开写（0x746 -> 等待 -> 0x7D5）
            $allOk = $true
            $firstMaxWritten = $false
            foreach ($t in $targets) {
                $cur = [AcpiEcRw]::Read($h, [int]$t.Addr)
                if ($cur -eq $t.Value) { Log ('  0x{0:X3} 已是 0x{1:X2}，跳过' -f $t.Addr, $t.Value); continue }
                if ($t.Addr -eq $script:AddrMax2 -and $firstMaxWritten -and $WriteDelayMs -gt 0) {
                    Log ('  等待 {0} ms 再写第二份 0x7D5（控制中心也是分开写）…' -f $WriteDelayMs)
                    Start-Sleep -Milliseconds $WriteDelayMs
                }
                if (-not (Write-Checked $h $t.Addr ([byte]$t.Value))) { $allOk = $false }
                if ($t.Addr -eq $script:AddrMax) { $firstMaxWritten = $true }
            }
            Start-Sleep -Milliseconds 600
            $after = Read-Bytes $h $readAddrs
            Log ("写入后 EC: " + (Format-Bytes $after))

            $enforced = Get-EnforcedWatts
            $expect = Expected-Tgp $DbWatt
# 写入后监视 15 秒：驱动侧数值可能延迟更新（或需 GPU 负载/模式切换）
            Log ("enforced: " + $(if ($enforced -ge 0) { "$enforced W" } else { 'n/a' }) + "（期望约 $expect W）") $(if ([math]::Abs($enforced -$expect) -le 5 -or $enforced -lt 0) { 'OK' } else { 'WARN' })
            Show-NvPowerDetail
            Log '监视 15 秒，看驱动侧数值是否随后变化（现在可开 FurMark / 游戏）…'
            $lastE = $enforced; $lastL = (Get-LimitWatts)
            for ($i = 0; $i -lt 15; $i++) {
                Start-Sleep -Seconds 1
                $e2 = Get-EnforcedWatts; $l2 = Get-LimitWatts
                if ($e2 -ne $lastE -or $l2 -ne $lastL) { Log ("   enforced={0}W  limit={1}W" -f $e2, $l2); $lastE = $e2; $lastL = $l2 }
            }
            if ($enforced -ge 0 -and [math]::Abs($enforced - $expect) -gt 5) {
                Log 'EC 已写入，但驱动侧 enforced 未跟随：该值可能由驱动/vBIOS 侧控制，或需切换一次性能模式 / 重启后才生效。' 'WARN'
                Log '建议验证顺序：a) 观察到 15 秒内是否变化；b) 切一次控制台性能模式；c) 重启后再看。' 'WARN'
            }
            Log '提示：DB 是动态的 —— 只有 GPU 有负载时才会维持高档；负载停止后固件会回写数值。' 'WARN'
            Log '回滚：-Action Restore -Yes（或切换一次性能模式 / 重启）' 'WARN'
            break
        }
        'DisableDb' {
            $targets = Target-Map 0 $false
            Log '将关闭 DB（0x743=01 / 0x745=00 / 0x746=00 / 0x7D4=00 / 0x7D5=00）'
            if ($WhatIf) { Log '[WhatIf] 只读预演，未写入' 'WARN'; break }
            if (-not $Yes) {
                $ans = Read-Host '输入 YES 确认关闭 DB'
                if ($ans -ne 'YES') { Log '用户取消' 'WARN'; break }
            }
            foreach ($t in $targets) { Write-Checked $h $t.Addr ([byte]$t.Value) | Out-Null }
            Start-Sleep -Milliseconds 500
            Log ("关闭后 EC: " + (Format-Bytes (Read-Bytes $h $readAddrs)))
            Log ("enforced: " + (Get-GpuLine))
            break
        }
        'SetByte' {
            if ($Addr -lt $script:EcWindowLo -or $Addr -gt $script:EcWindowHi) { Log '需要合法的 -Addr（0x700-0x7FF）' 'ERR'; break }
            if ($Value -lt 0 -or $Value -gt 255) { Log '需要 -Value 0-255' 'ERR'; break }
            if (-not ($script:ConfirmedAddrs -contains $Addr)) {
                Log ('地址 0x{0:X3} 语义未确认，默认拒绝写入；' -f $Addr) 'ERR'
                break
            }
            Log ('单字节实验：0x{0:X3} = 0x{1:X2}' -f $Addr, $Value) 'WARN'
            if ($WhatIf) { Log '[WhatIf] 未写入' 'WARN'; break }
            if (-not $Yes) { $ans = Read-Host '输入 YES 确认写入'; if ($ans -ne 'YES') { Log '用户取消' 'WARN'; break } }
            $origPath = Join-Path $env:TEMP 'gpu-power-limit-orig-before.json'
            ($before.GetEnumerator() | ForEach-Object { @{ Addr = [int]$_.Key; Value = $_.Value } }) | ConvertTo-Json | Set-Content -LiteralPath $origPath -Encoding UTF8
            Write-Checked $h $Addr ([byte]$Value) | Out-Null
            Start-Sleep -Milliseconds 600
            Log ("写入后 EC: " + (Format-Bytes (Read-Bytes $h $readAddrs)))
            Log ("GPU: " + (Get-GpuLine))
            break
        }
        'LockLow' {
            # 参考"离电"实测值：模拟电池模式的低功耗配置（插电时强制压低）
            $dcSet = @(
                @{ Addr = $script:AddrCtrl;    Value = [byte]0x01 },
                @{ Addr = $script:AddrTarget;  Value = [byte]0x00 },
                @{ Addr = $script:AddrMax;     Value = [byte]0x00 },
                @{ Addr = $script:AddrTarget2; Value = [byte]0x00 },
                @{ Addr = $script:AddrMax2;    Value = [byte]0x00 },
                @{ Addr = 0x7C4; Value = [byte]0x20 },
                @{ Addr = 0x751; Value = [byte]0xA0 },
                @{ Addr = 0x7CC; Value = [byte]0x00 }
            )
            Log '锁定低功耗（模拟离电配置；插电时也能压低）:' 'WARN'
            foreach ($t in $dcSet) { Log ('   0x{0:X3} = 0x{1:X2}' -f $t.Addr, $t.Value) }
            Log '以上是"离电时的参考值"。这些地址（0x7C4/0x751/0x7CC）语义未确认。' 'WARN'
            Log '按当前策略：只展示、不写入（避免伪造电池状态影响充电/功耗策略）。' 'WARN'
            break
        }
        'Restore' {
            $origPath = Join-Path $env:TEMP 'gpu-power-limit-orig-before.json'
            if (-not (Test-Path $origPath)) { Log '没有找到原值记录（%TEMP%\gpu-power-limit-orig-before.json）—— 无法 Restore' 'ERR'; break }
            $saved = Get-Content -LiteralPath $origPath -Raw -Encoding UTF8 | ConvertFrom-Json
            Log '回滚到进入时记录的原值：'
            foreach ($s in $saved) {
                if ($s.Value -lt 0) { continue }
                if (-not ($script:ConfirmedAddrs -contains [int]$s.Addr)) {
                    Log ('  跳过未确认地址 0x{0:X3}（只读，不回写）' -f [int]$s.Addr) 'INFO'
                    continue
                }
                Write-Checked $h ([int]$s.Addr) ([byte]$s.Value) | Out-Null
            }
            Start-Sleep -Milliseconds 500
            Log ("回滚后 EC: " + (Format-Bytes (Read-Bytes $h $readAddrs)))
            Log ("GPU: " + (Get-GpuLine))
            break
        }
    }
    Log ('日志：' + $script:LogFile)
}
finally {
    [AcpiEcRw]::Close($h)
}
exit 0
