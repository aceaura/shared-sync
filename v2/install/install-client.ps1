<#
.SYNOPSIS
  shared-sync v2 —— Windows 客户端一键安装器(角色3 的 Windows 版)。

.DESCRIPTION
  把 v2 自适应连接客户端三件套装好并起好(nebula + frpc visitor + connd):
    * connd 暴露固定本地端点 127.0.0.1:8418,引擎 server_url 永远指它,切层(T0/T1/T2)透明。
  二进制自动下载:connd(本仓库 Release)、nebula、frpc(官方 Release,含 Wintun 驱动)。
  以【计划任务】常驻(开机自启 + 崩溃重启),并立即启动。

  必须【以管理员身份】运行 PowerShell(nebula 要创建 Wintun 虚拟网卡)。

.PARAMETER Bundle
  enroll-client.sh 产出的接入包目录(含 node.yml / connd.yaml / frpc-visitor.toml / 证书 …)。
  把它从操作机拷到本机后,指向该目录。

.PARAMETER SharedDir
  可选:要同步的本地文件夹。给了就把 GUI/CLI 的配置也指向本地端点(否则手动在客户端里填)。

.PARAMETER Action
  install(默认)| status | uninstall

.EXAMPLE
  # 管理员 PowerShell 中:
  .\install-client.ps1 -Bundle .\winpc -SharedDir C:\SharedWork
  .\install-client.ps1 -Action status
  .\install-client.ps1 -Action uninstall
#>
[CmdletBinding()]
param(
  [string]$Bundle,
  [string]$SharedDir = "",
  [string]$InstallDir = "$env:ProgramData\shared-sync",
  [string]$ConndTag   = "v2.0.0",
  [string]$NebulaVer  = "1.10.3",
  [string]$FrpVer     = "0.69.1",
  [string]$GhRepo     = "aceaura/shared-sync",
  [ValidateSet("install","status","uninstall")]
  [string]$Action     = "install"
)

$ErrorActionPreference = "Stop"
$LocalEndpoint = "http://127.0.0.1:8418/shared.git"
$StatusUrl     = "http://127.0.0.1:4243/status"
$FrpcTask      = "shared-sync-frpc"
$ConndTask     = "shared-sync-connd"

function Info($m){ Write-Host ">> $m" -ForegroundColor Cyan }
function Ok($m){ Write-Host "OK $m" -ForegroundColor Green }
function Warn($m){ Write-Host "WARN $m" -ForegroundColor Yellow }
function Die($m){ Write-Host "ERROR $m" -ForegroundColor Red; exit 1 }

function Assert-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Die "请以【管理员身份】运行 PowerShell(nebula 需创建 Wintun 网卡)。"
  }
}

# ---- status / uninstall ----------------------------------------------------
if ($Action -eq "status") {
  foreach ($t in @($FrpcTask,$ConndTask)) {
    $info = schtasks /query /tn $t /fo LIST 2>$null | Select-String "状态:|Status:"
    Write-Host "--- $t ---"; if ($info){ $info } else { Write-Host "(未安装)" }
  }
  Write-Host "--- 连接状态 ($StatusUrl) ---"
  try { (Invoke-RestMethod -Uri $StatusUrl -TimeoutSec 5) | ConvertTo-Json -Compress } catch { Write-Host "(connd 未就绪)" }
  exit 0
}
if ($Action -eq "uninstall") {
  Assert-Admin
  foreach ($t in @($ConndTask,$FrpcTask)) {
    schtasks /end /tn $t 2>$null | Out-Null
    schtasks /delete /tn $t /f 2>$null | Out-Null
  }
  Get-Process connd,frpc,nebula -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Ok "已移除 connd/frpc 计划任务并停止进程(配置/证书保留在 $InstallDir)。"
  exit 0
}

# ---- install ---------------------------------------------------------------
Assert-Admin
if (-not $Bundle) { Die "用法: .\install-client.ps1 -Bundle <接入包目录> [-SharedDir <文件夹>]" }
$Bundle = (Resolve-Path $Bundle).Path
foreach ($f in @("node.yml","frpc-visitor.toml","connd.yaml","ca.crt","ctl_key","sshd_hostkey")) {
  if (-not (Test-Path (Join-Path $Bundle $f))) { Die "接入包缺少 $f(不是合法 enroll 产物?)" }
}
$clientCrt = Get-ChildItem (Join-Path $Bundle "client-*.crt") | Select-Object -First 1
if (-not $clientCrt) { Die "接入包缺少 client-*.crt" }
$certName = $clientCrt.BaseName            # client-winpc
$short    = $certName -replace '^client-',''  # winpc

# OpenSSH 客户端(connd 查 nebula hostmap 需要 ssh.exe)
if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) {
  Warn "未找到 ssh.exe;请装 Windows OpenSSH 客户端(设置→应用→可选功能→OpenSSH 客户端)。connd 判 T0/T1 需要它。"
}

Info "===== Windows 客户端安装:$short ====="
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$tmp = Join-Path $env:TEMP "ss-install-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
  # 1) connd(本仓库 Release)
  Info "下载 connd($ConndTag)"
  $conndUrl = if ($ConndTag) { "https://github.com/$GhRepo/releases/download/$ConndTag/connd-windows-amd64.exe" }
              else { "https://github.com/$GhRepo/releases/latest/download/connd-windows-amd64.exe" }
  Invoke-WebRequest -Uri $conndUrl -OutFile (Join-Path $InstallDir "connd.exe") -UseBasicParsing

  # 2) nebula(官方 Release,含 wintun.dll)
  Info "下载 nebula v$NebulaVer(含 Wintun)"
  Invoke-WebRequest -Uri "https://github.com/slackhq/nebula/releases/download/v$NebulaVer/nebula-windows-amd64.zip" -OutFile "$tmp\nebula.zip" -UseBasicParsing
  Expand-Archive -Path "$tmp\nebula.zip" -DestinationPath "$tmp\nebula" -Force
  Copy-Item "$tmp\nebula\nebula.exe" (Join-Path $InstallDir "nebula.exe") -Force
  Copy-Item "$tmp\nebula\dist\windows\wintun\bin\amd64\wintun.dll" (Join-Path $InstallDir "wintun.dll") -Force

  # 3) frpc(官方 Release)
  Info "下载 frpc v$FrpVer"
  Invoke-WebRequest -Uri "https://github.com/fatedier/frp/releases/download/v$FrpVer/frp_${FrpVer}_windows_amd64.zip" -OutFile "$tmp\frp.zip" -UseBasicParsing
  Expand-Archive -Path "$tmp\frp.zip" -DestinationPath "$tmp\frp" -Force
  Copy-Item "$tmp\frp\frp_${FrpVer}_windows_amd64\frpc.exe" (Join-Path $InstallDir "frpc.exe") -Force
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

# 4) 拷接入包 + 把 Linux 路径改写为本机安装路径(nebula/connd 用正斜杠,Go 在 Windows 也认)
$cfgPath = ($InstallDir -replace '\\','/')   # 例 C:/ProgramData/shared-sync
Copy-Item (Join-Path $Bundle "ca.crt")            (Join-Path $InstallDir "ca.crt") -Force
Copy-Item $clientCrt.FullName                     (Join-Path $InstallDir "$certName.crt") -Force
Copy-Item (Join-Path $Bundle "$certName.key")     (Join-Path $InstallDir "$certName.key") -Force
Copy-Item (Join-Path $Bundle "ctl_key")           (Join-Path $InstallDir "ctl_key") -Force
Copy-Item (Join-Path $Bundle "sshd_hostkey")      (Join-Path $InstallDir "sshd_hostkey") -Force
Copy-Item (Join-Path $Bundle "frpc-visitor.toml") (Join-Path $InstallDir "frpc-visitor.toml") -Force

# node.yml:把 /etc/nebula/ → 安装目录
(Get-Content (Join-Path $Bundle "node.yml") -Raw).Replace('/etc/nebula/', "$cfgPath/") |
  Set-Content (Join-Path $InstallDir "node.yml") -NoNewline -Encoding UTF8

# connd.yaml:/etc/nebula/ → 安装目录;nebula.binPath → nebula.exe 绝对路径
$connd = (Get-Content (Join-Path $Bundle "connd.yaml") -Raw).Replace('/etc/nebula/', "$cfgPath/")
$connd = $connd -replace '(?m)^(\s*binPath:).*', "`$1 $cfgPath/nebula.exe"
$connd | Set-Content (Join-Path $InstallDir "connd.yaml") -NoNewline -Encoding UTF8

# 5) 私钥权限:OpenSSH 拒绝"权限过松"的私钥;只留 SYSTEM + Administrators。
foreach ($k in @("ctl_key","$certName.key","sshd_hostkey")) {
  $kp = Join-Path $InstallDir $k
  icacls $kp /inheritance:r 2>$null | Out-Null
  icacls $kp /grant:r "SYSTEM:(R)" "Administrators:(R)" 2>$null | Out-Null
}

# 6) 计划任务:frpc + connd(开机自启 + 崩溃重启;以 SYSTEM 跑 = 管理员权限,nebula 能建网卡)
function Register-Svc($name, $exe, $arglist) {
  schtasks /delete /tn $name /f 2>$null | Out-Null
  $act = New-ScheduledTaskAction -Execute $exe -Argument $arglist -WorkingDirectory $InstallDir
  $trg = New-ScheduledTaskTrigger -AtStartup
  $pr  = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
  $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
           -RestartCount 9999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
  Register-ScheduledTask -TaskName $name -Action $act -Trigger $trg -Principal $pr -Settings $set -Force | Out-Null
}
Info "注册计划任务 frpc / connd(开机自启 + 崩溃重启)"
Register-Svc $FrpcTask  (Join-Path $InstallDir "frpc.exe")  ("-c `"" + (Join-Path $InstallDir "frpc-visitor.toml") + "`"")
Register-Svc $ConndTask (Join-Path $InstallDir "connd.exe") ("run -config `"" + (Join-Path $InstallDir "connd.yaml") + "`"")

Info "启动服务"
schtasks /run /tn $FrpcTask  | Out-Null
Start-Sleep -Seconds 2
schtasks /run /tn $ConndTask | Out-Null
Start-Sleep -Seconds 4

# 7)(可选)引擎接入
if ($SharedDir) {
  $cli = Get-Command sync_cli.exe -ErrorAction SilentlyContinue
  if ($cli) {
    Info "初始化 v1 引擎:$SharedDir → $LocalEndpoint"
    & $cli.Source init --dir $SharedDir --server $LocalEndpoint --client-id $short
  } else {
    Warn "未找到 sync_cli.exe;请在 shared-sync 客户端(GUI 或 CLI)里把 server_url 填 $LocalEndpoint"
  }
}

Ok "Windows 客户端装好:frpc + connd 常驻(connd 托管 nebula),固定本地端点 127.0.0.1:8418。"
Write-Host "引擎接入: server_url = $LocalEndpoint"
Write-Host "查看连接: .\install-client.ps1 -Action status   (或 $InstallDir\connd.exe status)"
Write-Host "--- 当前连接 ---"
try { (Invoke-RestMethod -Uri $StatusUrl -TimeoutSec 6) | ConvertTo-Json } catch { Write-Host "(connd 启动中,稍后再 -Action status 查)" }
