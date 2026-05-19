# =====================================================================
#  BLACK-BACKUP for Windows - Installer
#  Run in PowerShell as Administrator:
#    powershell -ExecutionPolicy Bypass -File install.ps1
# =====================================================================

if (-not ([Security.Principal.WindowsPrincipal]
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "  [X] Please run PowerShell as Administrator." -ForegroundColor Red
    exit 1
}

$INSTALL_DIR = "C:\Program Files\BlackBackup"
$TOOL_PS1    = "$INSTALL_DIR\black-backup.ps1"
$TOOL_CMD    = "$INSTALL_DIR\black-backup.cmd"

# ── Embedded main script ──────────────────────────────────────────────
$SCRIPT = @'
# =====================================================================
#  black-backup v1.0 for Windows
#  Full / Light / Incremental backup with chain restore via WinRE
# =====================================================================

$BACKUP_DIR = "C:\BlackBackup"
$LOG_FILE   = "C:\BlackBackup\black-backup.log"
$HTTP_PORT  = 8765
$FW_RULE    = "BlackBackup-HTTP"

# ── Output helpers ────────────────────────────────────────────────────
function Write-OK   { param($m) Write-Host "  [OK] $m" -ForegroundColor Green;   Add-Log "OK"   $m }
function Write-Warn { param($m) Write-Host "   [!] $m" -ForegroundColor Yellow;  Add-Log "WARN" $m }
function Write-Err  { param($m) Write-Host "   [X] $m" -ForegroundColor Red;     Add-Log "ERR"  $m }
function Write-Step { param($m) Write-Host "   [>] $m" -ForegroundColor Cyan;    Add-Log "STEP" $m }
function Write-Info { param($m) Write-Host "   [i] $m" -ForegroundColor Magenta; Add-Log "INFO" $m }
function Write-Div  { Write-Host "  ──────────────────────────────────────────" -ForegroundColor Cyan }
function Add-Log {
    param($lvl,$msg)
    try { "[$lvl] $(Get-Date -f 'HH:mm:ss') $msg" | Add-Content $LOG_FILE -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
}

function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  +==========================================+" -ForegroundColor Cyan
    Write-Host "  |      BLACK-BACKUP  v1.0  (Windows)      |" -ForegroundColor Cyan
    Write-Host "  |    Server Snapshot & Restore Tool        |" -ForegroundColor Cyan
    Write-Host "  +==========================================+" -ForegroundColor Cyan
    Write-Host ""
}

# ── Network / firewall ────────────────────────────────────────────────
function Get-PublicIP {
    try { (Invoke-WebRequest "https://api.ipify.org" -UseBasicParsing -TimeoutSec 5).Content.Trim() }
    catch { (Get-NetIPAddress -AddressFamily IPv4 |
             Where-Object { $_.PrefixOrigin -ne "WellKnown" -and $_.InterfaceAlias -notlike "Loopback*" } |
             Select-Object -First 1).IPAddress }
}

function Open-FWPort {
    try { New-NetFirewallRule -DisplayName $FW_RULE -Direction Inbound -Protocol TCP -LocalPort $HTTP_PORT -Action Allow -EA Stop | Out-Null }
    catch { netsh advfirewall firewall add rule name="$FW_RULE" dir=in action=allow protocol=TCP localport=$HTTP_PORT 2>$null | Out-Null }
    Write-OK "Firewall: port $HTTP_PORT opened."
}
function Close-FWPort {
    Remove-NetFirewallRule -DisplayName $FW_RULE -EA SilentlyContinue
    netsh advfirewall firewall delete rule name="$FW_RULE" 2>$null | Out-Null
    Write-OK "Firewall: port $HTTP_PORT closed."
}

# ── HTTP server (streaming, no full-file-in-RAM) ──────────────────────
function Start-HTTPServer {
    param([string]$FilePath)
    $fileName = [Uri]::EscapeDataString((Split-Path $FilePath -Leaf))
    $fileSize = (Get-Item $FilePath).Length
    $ip = Get-PublicIP
    Open-FWPort
    Write-Host ""
    Write-Host "  +==========================================+" -ForegroundColor Green
    Write-Host "  |         DOWNLOAD LINK  (active)         |" -ForegroundColor Green
    Write-Host "  |  http://${ip}:${HTTP_PORT}/$fileName" -ForegroundColor Cyan
    Write-Host "  +==========================================+" -ForegroundColor Green
    Write-Host ""
    Write-Info "File : $FilePath"
    Write-Warn "Press Ctrl+C to stop the server."
    Write-Host ""

    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://+:${HTTP_PORT}/")
    $listener.Start()
    try {
        while ($listener.IsListening) {
            $ctx = $listener.GetContext()
            $req = $ctx.Request; $res = $ctx.Response
            if ($req.Url.LocalPath -eq "/$fileName") {
                $res.ContentType = "application/octet-stream"
                $res.ContentLength64 = $fileSize
                $res.Headers.Add("Content-Disposition", "attachment; filename=`"$(Split-Path $FilePath -Leaf)`"")
                $fs  = [System.IO.File]::OpenRead($FilePath)
                $buf = New-Object byte[] 65536
                try { while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) { $res.OutputStream.Write($buf, 0, $n) } }
                finally { $fs.Close() }
            } else { $res.StatusCode = 404 }
            try { $res.Close() } catch {}
        }
    } catch { <# Ctrl+C lands here #> }
    finally { try { $listener.Stop() } catch {}; Close-FWPort; Write-OK "HTTP server stopped." }
}

# ── Meta helpers ──────────────────────────────────────────────────────
function Save-Meta {
    param([string]$Name, [string]$File, [string]$Type="full",
          [string]$Base="", [int]$Seq=0)
    $ifaces = (Get-NetAdapter | Where-Object Status -eq Up | Select-Object -Expand Name) -join ","
    $sz = if (Test-Path $File) { "{0:N0} MB" -f ((Get-Item $File).Length/1MB) } else { "?" }
    @"
name=$Name
date=$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')
size=$sz
hostname=$env:COMPUTERNAME
file=$File
interfaces=$ifaces
os=$((Get-CimInstance Win32_OperatingSystem).Caption)
arch=$env:PROCESSOR_ARCHITECTURE
type=$Type
base=$Base
sequence=$Seq
"@ | Set-Content "$BACKUP_DIR\$Name.meta" -Encoding UTF8
}

function Get-MetaVal {
    param([string]$MetaPath, [string]$Key)
    if (-not (Test-Path $MetaPath)) { return "" }
    $line = Get-Content $MetaPath | Where-Object { $_ -match "^${Key}=" } | Select-Object -First 1
    if ($line) { return $line.Substring($Key.Length + 1) } else { return "" }
}

function Get-AllMetas {
    Get-ChildItem "$BACKUP_DIR\*.meta" -EA SilentlyContinue | Sort-Object LastWriteTime
}

function Get-IncMetas {
    param([string]$BaseName)
    Get-ChildItem "$BACKUP_DIR\*.meta" -EA SilentlyContinue |
        Where-Object { (Get-MetaVal $_.FullName "type") -eq "incremental" -and
                       (Get-MetaVal $_.FullName "base") -eq $BaseName } |
        Sort-Object { [int](Get-MetaVal $_.FullName "sequence") }
}

# ── VSS snapshot ──────────────────────────────────────────────────────
function New-VSS {
    $wmi = [WMICLASS]"root\cimv2:Win32_ShadowCopy"
    $r   = $wmi.Create("C:\", "ClientAccessible")
    if ($r.ReturnValue -ne 0) { throw "VSS failed (code $($r.ReturnValue)). Ensure VSS service is running." }
    $s = Get-WmiObject Win32_ShadowCopy | Where-Object { $_.ID -eq $r.ShadowID }
    return $s
}
function Remove-VSS { param($s); try { $s.Delete() } catch {} }

# ── Backup name prompt ────────────────────────────────────────────────
function Read-BackupName {
    param([string]$Prefix = "backup")
    $def = "${Prefix}-$(Get-Date -f 'yyyyMMdd_HHmmss')"
    Write-Host ""
    $n = Read-Host "  Backup name [$def]"
    if ([string]::IsNullOrWhiteSpace($n)) { $n = $def }
    return ($n -replace '[^\w\-_\.]', '-')
}

# ─────────────────────────────────────────────────────────────────────
# FULL BACKUP
# ─────────────────────────────────────────────────────────────────────
function Invoke-FullBackup {
    New-Item -ItemType Directory -Force -Path $BACKUP_DIR | Out-Null
    $name = Read-BackupName "backup"
    $file = "$BACKUP_DIR\$name.wim"

    if (Test-Path $file) {
        Write-Warn "Backup already exists."
        if ((Read-Host "  Overwrite? (y/n)") -ne 'y') { Write-Warn "Cancelled."; return }
        Remove-Item $file -Force
    }

    Write-Host ""
    Write-Step "Creating VSS snapshot..."
    $shadow = New-VSS
    $src = $shadow.DeviceObject + "\"
    Write-OK "VSS snapshot: $src"
    Write-Step "Capturing full system image — this may take 10-30 min..."

    $p = Start-Process dism.exe -ArgumentList `
        "/Capture-Image /ImageFile:`"$file`" /CaptureDir:`"$src`" /Name:`"$name`" /Compress:max" `
        -Wait -PassThru -NoNewWindow
    Remove-VSS $shadow

    if ($p.ExitCode -ne 0) { Write-Err "DISM failed (exit $($p.ExitCode))."; return }

    Save-Meta -Name $name -File $file -Type "full"
    $sz = "{0:N1} GB" -f ((Get-Item $file).Length/1GB)
    Write-Host ""; Write-Div
    Write-OK "Full backup completed!"
    Write-Info "Name : $name"
    Write-Info "File : $file"
    Write-Info "Size : $sz"
    Write-Div; Write-Host ""
    if ((Read-Host "  Generate download link? (y/n)") -eq 'y') { Start-HTTPServer $file }
}

# ─────────────────────────────────────────────────────────────────────
# LIGHT BACKUP
# ─────────────────────────────────────────────────────────────────────
function Invoke-LightBackup {
    New-Item -ItemType Directory -Force -Path $BACKUP_DIR | Out-Null
    $name = Read-BackupName "light"
    $file = "$BACKUP_DIR\$name.wim"

    if (Test-Path $file) {
        Write-Warn "Backup already exists."
        if ((Read-Host "  Overwrite? (y/n)") -ne 'y') { Write-Warn "Cancelled."; return }
        Remove-Item $file -Force
    }

    # Exclusion config for DISM
    $cfg = "$env:TEMP\bb-exclude.ini"
    @"
[ExclusionList]
\pagefile.sys
\hiberfil.sys
\swapfile.sys
\Windows\Temp\*
\Windows\Logs\*
\Windows\SoftwareDistribution\Download\*
\ProgramData\Microsoft\Windows Defender\Scans\*
\Users\*\AppData\Local\Temp\*
\Users\*\AppData\Local\Microsoft\Windows\INetCache\*
\Users\*\AppData\Local\Google\Chrome\User Data\Default\Cache\*
\inetpub\logs\*
"@ | Set-Content $cfg -Encoding UTF8

    Write-Host ""
    Write-Step "Creating VSS snapshot..."
    $shadow = New-VSS
    $src = $shadow.DeviceObject + "\"
    Write-OK "VSS snapshot ready."
    Write-Step "Capturing light image (skips temp, logs, caches, WD scans)..."

    $p = Start-Process dism.exe -ArgumentList `
        "/Capture-Image /ImageFile:`"$file`" /CaptureDir:`"$src`" /Name:`"$name`" /Compress:max /ConfigFile:`"$cfg`"" `
        -Wait -PassThru -NoNewWindow
    Remove-VSS $shadow
    Remove-Item $cfg -EA SilentlyContinue

    if ($p.ExitCode -ne 0) { Write-Err "DISM failed (exit $($p.ExitCode))."; return }

    Save-Meta -Name $name -File $file -Type "light"
    $sz = "{0:N1} GB" -f ((Get-Item $file).Length/1GB)
    Write-Host ""; Write-Div
    Write-OK "Light backup completed!"
    Write-Info "Name : $name"
    Write-Info "File : $file"
    Write-Info "Size : $sz"
    Write-Div
    Write-Host ""
    Write-Host "  Excluded: temp, logs, WD scans, browser cache, pagefile" -ForegroundColor Yellow
    Write-Host ""
    if ((Read-Host "  Generate download link? (y/n)") -eq 'y') { Start-HTTPServer $file }
}

# ─────────────────────────────────────────────────────────────────────
# INCREMENTAL BACKUP
# ─────────────────────────────────────────────────────────────────────
function Invoke-IncrementalBackup {
    New-Item -ItemType Directory -Force -Path $BACKUP_DIR | Out-Null

    # Find most recent base backup
    $baseMeta = $null; $newest = [datetime]::MinValue
    foreach ($m in Get-AllMetas) {
        $t = Get-MetaVal $m.FullName "type"
        if ($t -eq "full" -or $t -eq "light") {
            if ($m.LastWriteTime -gt $newest) { $newest = $m.LastWriteTime; $baseMeta = $m }
        }
    }

    if (-not $baseMeta) {
        Write-Host ""; Write-Warn "No base backup found! Take a full or light backup first."
        if ((Read-Host "  Take a full backup now? (y/n)") -eq 'y') { Invoke-FullBackup }
        return
    }

    $baseName = Get-MetaVal $baseMeta.FullName "name"

    # Find most recent entry in this chain to get reference date
    $lastMeta = $baseMeta; $lastSeq = 0; $newest = $baseMeta.LastWriteTime
    foreach ($inc in Get-IncMetas $baseName) {
        if ($inc.LastWriteTime -gt $newest) { $newest = $inc.LastWriteTime; $lastMeta = $inc }
        $s = [int](Get-MetaVal $inc.FullName "sequence")
        if ($s -gt $lastSeq) { $lastSeq = $s }
    }
    $lastDate = [datetime]::Parse((Get-MetaVal $lastMeta.FullName "date"))
    $newSeq   = $lastSeq + 1

    Write-Host ""
    Write-Info "Base backup    : $baseName"
    Write-Info "Last checkpoint: $($lastDate.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Info "New sequence   : #$newSeq"
    Write-Host ""
    Write-Step "Only files modified after $($lastDate.ToString('yyyy-MM-dd HH:mm:ss')) will be included."

    $name = Read-BackupName "inc${newSeq}"
    $file = "$BACKUP_DIR\$name.zip"

    if (Test-Path $file) {
        Write-Warn "Backup already exists."
        if ((Read-Host "  Overwrite? (y/n)") -ne 'y') { Write-Warn "Cancelled."; return }
        Remove-Item $file -Force
    }

    Write-Host ""
    Write-Step "Creating VSS snapshot..."
    $shadow = New-VSS
    $shadowRoot = $shadow.DeviceObject + "\"
    Write-OK "VSS snapshot ready."

    # Dirs to skip
    $skipPatterns = @(
        "Windows\Temp", "Windows\Logs", "Windows\SoftwareDistribution\Download",
        "ProgramData\Microsoft\Windows Defender\Scans",
        "BlackBackup", "pagefile.sys", "hiberfil.sys", "swapfile.sys"
    )

    Write-Step "Scanning for changed files (this may take a few minutes)..."
    $staging = "$env:TEMP\bb-inc-$$"
    New-Item -ItemType Directory -Force -Path $staging | Out-Null

    $count = 0
    Get-ChildItem -Path $shadowRoot -Recurse -Force -EA SilentlyContinue |
        Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -gt $lastDate } |
        ForEach-Object {
            $rel = $_.FullName.Substring($shadowRoot.Length)
            foreach ($pat in $skipPatterns) { if ($rel -like "$pat*") { return } }
            $dst = Join-Path $staging $rel
            $dstDir = Split-Path $dst -Parent
            if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
            try { Copy-Item $_.FullName $dst -Force -EA Stop; $count++ } catch {}
        }

    Remove-VSS $shadow
    Write-OK "$count changed file(s) found."

    if ($count -eq 0) {
        Write-Warn "No changes since last backup. Incremental not needed."
        Remove-Item $staging -Recurse -Force -EA SilentlyContinue
        return
    }

    Write-Step "Compressing changed files..."
    Compress-Archive -Path "$staging\*" -DestinationPath $file -CompressionLevel Optimal -Force
    Remove-Item $staging -Recurse -Force -EA SilentlyContinue

    Save-Meta -Name $name -File $file -Type "incremental" -Base $baseName -Seq $newSeq
    $sz = "{0:N0} MB" -f ((Get-Item $file).Length/1MB)
    Write-Host ""; Write-Div
    Write-OK "Incremental backup completed!"
    Write-Info "Name     : $name"
    Write-Info "File     : $file"
    Write-Info "Size     : $sz"
    Write-Info "Base     : $baseName"
    Write-Info "Sequence : #$newSeq"
    Write-Info "Since    : $($lastDate.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Div; Write-Host ""
    if ((Read-Host "  Generate download link? (y/n)") -eq 'y') { Start-HTTPServer $file }
}

# ─────────────────────────────────────────────────────────────────────
# BACKUP MENU
# ─────────────────────────────────────────────────────────────────────
function Show-BackupMenu {
    Show-Banner
    Write-Host "  === BACKUP MODE ===" -ForegroundColor White
    Write-Div; Write-Host ""
    Write-Host "  1)  Full Backup" -ForegroundColor Cyan
    Write-Host "       Complete system image - safest, largest" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  2)  Light Backup" -ForegroundColor Cyan
    Write-Host "       Skips temp, logs, caches - smaller size" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  3)  Incremental Backup" -ForegroundColor Cyan
    Write-Host "       Only changed files since last backup - minimum storage" -ForegroundColor Gray
    Write-Host "       Requires an existing full or light base backup" -ForegroundColor Gray
    Write-Host ""; Write-Div
    switch (Read-Host "  Backup type (1/2/3)") {
        "1" { Invoke-FullBackup }
        "2" { Invoke-LightBackup }
        "3" { Invoke-IncrementalBackup }
        default { Write-Err "Invalid choice."; Start-Sleep 1 }
    }
}

# ─────────────────────────────────────────────────────────────────────
# CHAIN HELPERS
# ─────────────────────────────────────────────────────────────────────
function Get-BaseMeta {
    param([string]$MetaPath)
    $t = Get-MetaVal $MetaPath "type"
    if ($t -ne "incremental") { return $MetaPath }
    $bName = Get-MetaVal $MetaPath "base"
    $bMeta = "$BACKUP_DIR\$bName.meta"
    if (-not (Test-Path $bMeta)) { throw "Base backup '$bName' not found." }
    return $bMeta
}

# Prompts user to pick a chain checkpoint.
# Returns an array of meta file paths (ordered base→inc1→…→incN).
function Select-Checkpoint {
    param([string]$BaseMetaPath)
    $bName = Get-MetaVal $BaseMetaPath "name"
    $all   = @($BaseMetaPath) + @((Get-IncMetas $bName).FullName)
    if ($all.Count -eq 1) { return $all }

    Write-Host ""
    Write-Host "  Backup chain for: $bName" -ForegroundColor White
    Write-Div
    Write-Host ("  {0,-4} {1,-8} {2,-30} {3,-22} {4}" -f "#","Type","Name","Date","Size") -ForegroundColor Cyan
    Write-Host ""
    $i = 1
    foreach ($m in $all) {
        $n   = Get-MetaVal $m "name"
        $d   = Get-MetaVal $m "date"
        $s   = Get-MetaVal $m "size"
        $t   = Get-MetaVal $m "type"; if (-not $t) { $t = "full" }
        $seq = Get-MetaVal $m "sequence"
        $tl  = if ($t -eq "incremental") { "inc#$seq" } else { "base" }
        Write-Host ("  {0,-4} {1,-8} {2,-30} {3,-22} {4}" -f "$i)", $tl, $n, $d, $s)
        $i++
    }
    Write-Host ""
    Write-Info "All layers from #1 up to your choice will be merged."
    Write-Host ""
    $sel = Read-Host "  Checkpoint number [$($all.Count)]"
    if ([string]::IsNullOrWhiteSpace($sel)) { $sel = $all.Count }
    $sel = [int]$sel
    if ($sel -lt 1 -or $sel -gt $all.Count) { throw "Invalid selection." }
    return $all[0..($sel-1)]
}

# Merge an ordered list of meta files into a single WIM for download.
# Returns the path to the merged WIM.
function Merge-Chain {
    param([string[]]$Chain)
    $mergeDir  = "$env:TEMP\bb-merge-$$"
    $mergedWim = "$env:TEMP\bb-merged-$$.wim"
    New-Item -ItemType Directory -Force -Path $mergeDir | Out-Null
    Write-Step "Merging $($Chain.Count) layer(s) into one archive..."

    $first = $true
    foreach ($m in $Chain) {
        $f  = Get-MetaVal $m "file"
        $t  = Get-MetaVal $m "type"; if (-not $t) { $t = "full" }
        $sq = Get-MetaVal $m "sequence"
        $tl = if ($t -eq "incremental") { "inc#$sq" } else { $t }
        if (-not (Test-Path $f)) { throw "Archive not found: $f" }
        Write-Step "Applying [$tl]: $(Split-Path $f -Leaf)..."
        if ($f -like "*.wim") {
            $p = Start-Process dism.exe -ArgumentList `
                "/Apply-Image /ImageFile:`"$f`" /Index:1 /ApplyDir:`"$mergeDir`"" `
                -Wait -PassThru -NoNewWindow
            if ($p.ExitCode -ne 0) { throw "DISM apply failed on $f" }
        } elseif ($f -like "*.zip") {
            Expand-Archive -Path $f -DestinationPath $mergeDir -Force
        }
        $first = $false
    }

    Write-Step "Repacking merged archive..."
    $p = Start-Process dism.exe -ArgumentList `
        "/Capture-Image /ImageFile:`"$mergedWim`" /CaptureDir:`"$mergeDir`" /Name:`"merged-restore`" /Compress:max" `
        -Wait -PassThru -NoNewWindow
    Remove-Item $mergeDir -Recurse -Force -EA SilentlyContinue
    if ($p.ExitCode -ne 0 -or -not (Test-Path $mergedWim)) { throw "Merge pack failed." }

    $sz = "{0:N1} GB" -f ((Get-Item $mergedWim).Length/1GB)
    Write-OK "Merged archive ready ($sz): $mergedWim"
    return $mergedWim
}

# ─────────────────────────────────────────────────────────────────────
# WINRE RESTORE INJECTION
# Injects a restore script into WinRE startnet.cmd, saves a restore plan,
# and arms reagentc to boot WinRE on next restart.
# ─────────────────────────────────────────────────────────────────────
function Set-WinRERestore {
    param([string[]]$Chain)

    # Build restore plan: one line per layer (TYPE|filepath)
    $planLines = foreach ($m in $Chain) {
        $f = Get-MetaVal $m "file"
        $t = Get-MetaVal $m "type"; if (-not $t) { $t = "full" }
        if ($f -like "*.wim") { "WIM|$f" } else { "ZIP|$f" }
    }
    $planFile = "$BACKUP_DIR\restore-pending.txt"
    $planLines | Set-Content $planFile -Encoding UTF8

    # PowerShell runner that WinRE will execute
    # Note: C:\ in WinRE refers to the installed OS partition (not WinPE X:\)
    $runner = @'
$plan = "C:\BlackBackup\restore-pending.txt"
if (-not (Test-Path $plan)) { & wpeutil reboot; exit }

Write-Host ""
Write-Host "  +===================================+" -ForegroundColor Cyan
Write-Host "  |   BLACK-BACKUP RESTORE IN PROGRESS|" -ForegroundColor Cyan
Write-Host "  +===================================+" -ForegroundColor Cyan
Write-Host ""

$mountDir = "X:\WimMount"
$first    = $true

foreach ($line in (Get-Content $plan)) {
    $parts = $line -split "\|", 2
    $type  = $parts[0]; $path = $parts[1].Trim()
    if (-not (Test-Path $path)) { Write-Host "  [!] Missing: $path" -ForegroundColor Yellow; continue }

    Write-Host "  [>] Applying [$type]: $(Split-Path $path -Leaf)" -ForegroundColor Cyan

    if ($type -eq "WIM") {
        if ($first) {
            # Base image: apply to C:\ (replaces entire OS partition contents)
            & dism /Apply-Image /ImageFile:"$path" /Index:1 /ApplyDir:C:\
            $first = $false
        } else {
            # Incremental WIM: mount read-only and copy changed files over base
            New-Item -ItemType Directory -Force -Path $mountDir | Out-Null
            & dism /Mount-Image /ImageFile:"$path" /Index:1 /MountDir:$mountDir /ReadOnly
            & robocopy $mountDir C:\ /E /H /SYS /COPYALL /NFL /NDL /NJH /R:1 /W:1
            & dism /Unmount-Image /MountDir:$mountDir /Discard
        }
    } elseif ($type -eq "ZIP") {
        Expand-Archive -Path $path -DestinationPath C:\ -Force
    }
}

Write-Host ""
Write-Host "  [>] Fixing bootloader..." -ForegroundColor Cyan
& bcdboot C:\Windows /s C: /f ALL

Remove-Item $plan -Force -EA SilentlyContinue

Write-Host ""
Write-Host "  [OK] Restore complete! Rebooting in 5 seconds..." -ForegroundColor Green
Start-Sleep 5
& wpeutil reboot
'@
    $runnerPath = "$BACKUP_DIR\restore-runner.ps1"
    Set-Content $runnerPath $runner -Encoding UTF8

    # WinRE startnet.cmd that calls the PS runner
    $startnet = "@echo off`r`nif not exist `"C:\BlackBackup\restore-pending.txt`" goto :done`r`npowershell.exe -ExecutionPolicy Bypass -NonInteractive -File `"C:\BlackBackup\restore-runner.ps1`"`r`n:done`r`nwpeutil reboot`r`n"

    # Locate and mount WinRE.wim
    $winREWim = "$env:SystemRoot\System32\Recovery\WinRE.wim"
    if (-not (Test-Path $winREWim)) {
        Write-Err "WinRE.wim not found at $winREWim"
        Write-Warn "Manual WinPE restore required."
        return $false
    }

    Write-Step "Mounting WinRE image..."
    $mnt = "$env:SystemDrive\WinREMount_BB"
    New-Item -ItemType Directory -Force -Path $mnt | Out-Null
    # Remove read-only attribute so DISM can mount for edit
    Set-ItemProperty $winREWim -Name IsReadOnly -Value $false -EA SilentlyContinue

    $p = Start-Process dism.exe -ArgumentList `
        "/Mount-Image /ImageFile:`"$winREWim`" /Index:1 /MountDir:`"$mnt`"" `
        -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) {
        Write-Err "Failed to mount WinRE (exit $($p.ExitCode))."
        Remove-Item $mnt -Force -EA SilentlyContinue; return $false
    }

    # Backup original startnet and inject ours
    $sn = "$mnt\Windows\System32\startnet.cmd"
    if (Test-Path $sn) { Copy-Item $sn "$sn.bak" -Force }
    Set-Content $sn $startnet -Encoding ASCII
    Write-OK "Restore script injected into WinRE."

    # Unmount and commit
    Write-Step "Committing WinRE image..."
    $p = Start-Process dism.exe -ArgumentList `
        "/Unmount-Image /MountDir:`"$mnt`" /Commit" `
        -Wait -PassThru -NoNewWindow
    Remove-Item $mnt -Recurse -Force -EA SilentlyContinue

    if ($p.ExitCode -ne 0) {
        Write-Err "Failed to commit WinRE (exit $($p.ExitCode))."; return $false
    }
    Write-OK "WinRE updated."

    # Arm WinRE to run on next boot
    & reagentc /boottore 2>&1 | Out-Null
    Write-OK "WinRE will run on next restart and apply the restore."
    return $true
}

# ─────────────────────────────────────────────────────────────────────
# RESTORE
# ─────────────────────────────────────────────────────────────────────
function Invoke-Restore {
    Show-Banner
    Write-Host "  === RESTORE MODE ===" -ForegroundColor White
    Write-Div; Write-Host ""
    Write-Warn "Target should be a fresh Windows installation."
    Write-Host ""
    Write-Host "  Restore source:"
    Write-Host "  1) Pick from saved backups on this server" -ForegroundColor Cyan
    Write-Host "  2) Enter local file path" -ForegroundColor Cyan
    Write-Host "  3) Download from URL" -ForegroundColor Cyan
    Write-Host ""
    $src = Read-Host "  Choice (1/2/3)"

    $chain    = @()
    $useChain = $false
    $singleFile = ""

    switch ($src) {
        "1" {
            $metas = @(Get-AllMetas)
            if ($metas.Count -eq 0) { Write-Err "No backups found."; return }
            $i = 1
            foreach ($m in $metas) {
                $n = Get-MetaVal $m.FullName "name"; $d = Get-MetaVal $m.FullName "date"
                $s = Get-MetaVal $m.FullName "size"; $t = Get-MetaVal $m.FullName "type"
                $sq = Get-MetaVal $m.FullName "sequence"; if (-not $t) { $t = "full" }
                $tl = if ($t -eq "incremental") { "inc#$sq" } else { $t }
                Write-Host ("  {0,-4} [{1,-6}] {2,-30} {3,-22} {4}" -f "$i)", $tl, $n, $d, $s)
                $i++
            }
            Write-Host ""
            $num = [int](Read-Host "  Select number")
            if ($num -lt 1 -or $num -gt $metas.Count) { Write-Err "Invalid."; return }
            $selMeta = $metas[$num-1].FullName
            $selType = Get-MetaVal $selMeta "type"; if (-not $selType) { $selType = "full" }

            try { $baseMeta = Get-BaseMeta $selMeta } catch { Write-Err $_; return }
            $bName = Get-MetaVal $baseMeta "name"
            $incCnt = @(Get-IncMetas $bName).Count

            if ($incCnt -gt 0 -or $selType -eq "incremental") {
                try { $chain = Select-Checkpoint $baseMeta; $useChain = $true }
                catch { Write-Err $_; return }
            } else {
                $chain = @($selMeta); $useChain = $true
            }
        }
        "2" {
            $singleFile = Read-Host "  File path"
            if (-not (Test-Path $singleFile)) { Write-Err "File not found."; return }
            $useChain = $false
        }
        "3" {
            $url = Read-Host "  Download URL"
            $singleFile = "$env:TEMP\bb-dl-restore.wim"
            Write-Step "Downloading..."
            try { Invoke-WebRequest -Uri $url -OutFile $singleFile -UseBasicParsing; Write-OK "Download complete." }
            catch { Write-Err "Download failed: $_"; return }
            $useChain = $false
        }
        default { Write-Err "Invalid choice."; return }
    }

    Write-Host ""

    if ($useChain) {
        Write-Host ""
        Write-Info "Restore plan: $($chain.Count) layer(s)"
        foreach ($m in $chain) {
            $n = Get-MetaVal $m "name"; $t = Get-MetaVal $m "type"
            $sq = Get-MetaVal $m "sequence"; if (-not $t) { $t = "full" }
            $tl = if ($t -eq "incremental") { "inc#$sq" } else { $t }
            Write-Info "  -> [$tl] $n"
        }
        Write-Host ""
        Write-Warn "This will OVERWRITE the system on next reboot!"
        if ((Read-Host "  Type YES to confirm") -ne "YES") { Write-Warn "Cancelled."; return }

        $ok = Set-WinRERestore -Chain $chain
        if ($ok) {
            Write-Host ""
            Write-OK "Restore is armed. It will run automatically on next reboot."
            if ((Read-Host "  Reboot now? (y/n)") -eq 'y') { Restart-Computer -Force }
        }
    } else {
        # Single-file: wrap in a temp meta and use WinRE
        $tmpMeta = "$env:TEMP\bb-single.meta"
        @"
name=manual
date=$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')
size=?
hostname=$env:COMPUTERNAME
file=$singleFile
type=full
base=
sequence=0
"@ | Set-Content $tmpMeta -Encoding UTF8

        Write-Warn "This will OVERWRITE the system on next reboot!"
        if ((Read-Host "  Type YES to confirm") -ne "YES") { Write-Warn "Cancelled."; return }

        $ok = Set-WinRERestore -Chain @($tmpMeta)
        Remove-Item $tmpMeta -Force -EA SilentlyContinue
        if ($ok) {
            Write-Host ""
            Write-OK "Restore is armed."
            if ((Read-Host "  Reboot now? (y/n)") -eq 'y') { Restart-Computer -Force }
        }
    }
}

# ─────────────────────────────────────────────────────────────────────
# LIST BACKUPS & DOWNLOAD
# ─────────────────────────────────────────────────────────────────────
function Show-BackupList {
    while ($true) {
        Show-Banner
        Write-Host "  === BACKUP LIST ===" -ForegroundColor White
        Write-Div; Write-Host ""

        $metas = @(Get-AllMetas)
        if ($metas.Count -eq 0) {
            Write-Warn "No backups found in $BACKUP_DIR"
            Write-Host ""; Read-Host "  Press Enter to go back"; return
        }

        $i = 1
        foreach ($m in $metas) {
            $n  = Get-MetaVal $m.FullName "name"
            $d  = Get-MetaVal $m.FullName "date"
            $s  = Get-MetaVal $m.FullName "size"
            $f  = Get-MetaVal $m.FullName "file"
            $t  = Get-MetaVal $m.FullName "type"; if (-not $t) { $t = "full" }
            $sq = Get-MetaVal $m.FullName "sequence"
            $b  = Get-MetaVal $m.FullName "base"
            $tl = switch ($t) { "full" {"[FULL ]"} "light" {"[LITE ]"} "incremental" {"[INC#$sq]"} default {"[?????]"} }
            Write-Host "  $i)  $tl $n" -ForegroundColor Cyan
            Write-Host ("       {0,-22}  {1}" -f $d, $s) -ForegroundColor Yellow
            Write-Host "       Path: $f" -ForegroundColor Magenta
            if ($t -eq "incremental") { Write-Host "       Base: $b" -ForegroundColor Cyan }
            Write-Host ""; $i++
        }

        Write-Div; Write-Host ""
        Write-Host "  Enter a number to download.  0 / Enter = back." -ForegroundColor Cyan
        Write-Host ""
        $num = Read-Host "  Choice"
        if ([string]::IsNullOrWhiteSpace($num) -or $num -eq "0") { return }
        $num = [int]$num
        if ($num -lt 1 -or $num -gt $metas.Count) { Write-Err "Invalid."; Start-Sleep 1; continue }

        $selMeta = $metas[$num-1].FullName
        $selType = Get-MetaVal $selMeta "type"; if (-not $selType) { $selType = "full" }
        $selFile = Get-MetaVal $selMeta "file"

        try { $baseMeta = Get-BaseMeta $selMeta } catch { Write-Err $_; Start-Sleep 2; continue }
        $bName  = Get-MetaVal $baseMeta "name"
        $incCnt = @(Get-IncMetas $bName).Count

        if ($incCnt -gt 0 -or $selType -eq "incremental") {
            try { $chain = Select-Checkpoint $baseMeta } catch { Write-Err $_; Start-Sleep 1; continue }
            try {
                $merged = Merge-Chain $chain
                Write-Info "Merged archive: $merged"
                Start-HTTPServer $merged
                Remove-Item $merged -Force -EA SilentlyContinue
            } catch { Write-Err $_; Start-Sleep 2 }
        } else {
            if (-not (Test-Path $selFile)) { Write-Err "File not found: $selFile"; Start-Sleep 2; continue }
            Start-HTTPServer $selFile
        }
    }
}

# ─────────────────────────────────────────────────────────────────────
# DELETE BACKUP
# ─────────────────────────────────────────────────────────────────────
function Remove-BackupEntry {
    Show-Banner
    Write-Host "  === DELETE BACKUP ===" -ForegroundColor White
    Write-Div; Write-Host ""

    $metas = @(Get-AllMetas)
    if ($metas.Count -eq 0) { Write-Warn "No backups found."; return }

    $i = 1
    foreach ($m in $metas) {
        $n = Get-MetaVal $m.FullName "name"; $d = Get-MetaVal $m.FullName "date"
        $s = Get-MetaVal $m.FullName "size"; $t = Get-MetaVal $m.FullName "type"
        $sq = Get-MetaVal $m.FullName "sequence"; if (-not $t) { $t = "full" }
        $tl = if ($t -eq "incremental") { "[inc#$sq]" } else { "[$t]" }
        Write-Host ("  {0,-4} {1,-10} {2,-30} {3,-22} {4}" -f "$i)", $tl, $n, $d, $s)
        $i++
    }

    Write-Host ""
    $num = [int](Read-Host "  Backup number to delete (0 to cancel)")
    if ($num -eq 0) { Write-Warn "Cancelled."; return }
    if ($num -lt 1 -or $num -gt $metas.Count) { Write-Err "Invalid."; return }

    $sel    = $metas[$num-1]
    $dFile  = Get-MetaVal $sel.FullName "file"
    $dName  = Get-MetaVal $sel.FullName "name"
    $dType  = Get-MetaVal $sel.FullName "type"; if (-not $dType) { $dType = "full" }

    if ($dType -eq "full" -or $dType -eq "light") {
        $incCnt = @(Get-IncMetas $dName).Count
        if ($incCnt -gt 0) {
            Write-Host ""
            Write-Warn "WARNING: This base has $incCnt incremental(s) depending on it!"
            Write-Warn "They cannot be restored without this base."
            Write-Host ""
            if ((Read-Host "  Delete base AND all incrementals? (yes/no)") -eq "yes") {
                foreach ($inc in Get-IncMetas $dName) {
                    $iFile = Get-MetaVal $inc.FullName "file"
                    $iName = Get-MetaVal $inc.FullName "name"
                    if (Test-Path $iFile) { Remove-Item $iFile -Force }
                    Remove-Item $inc.FullName -Force
                    Write-OK "Deleted incremental: $iName"
                }
            } else { Write-Warn "Cancelled."; return }
        }
    }

    Write-Host ""; Write-Warn "About to delete: $dName"
    if ((Read-Host "  Confirm? (yes/no)") -eq "yes") {
        if (Test-Path $dFile) { Remove-Item $dFile -Force }
        Remove-Item $sel.FullName -Force
        Write-OK "Deleted: $dName"
    } else { Write-Warn "Cancelled." }
}

# ─────────────────────────────────────────────────────────────────────
# UNINSTALL
# ─────────────────────────────────────────────────────────────────────
function Invoke-Uninstall {
    Show-Banner
    Write-Host "  === UNINSTALL ===" -ForegroundColor White
    Write-Div; Write-Host ""
    Write-Warn "This will remove:"
    Write-Host "    - C:\Program Files\BlackBackup\"
    Write-Host "    - All backups in $BACKUP_DIR"
    Write-Host ""
    if ((Read-Host "  Type YES to confirm") -ne "YES") { Write-Warn "Cancelled."; return }
    $cur = [Environment]::GetEnvironmentVariable("Path","Machine")
    $new = ($cur -split ";" | Where-Object { $_ -notlike "*BlackBackup*" }) -join ";"
    [Environment]::SetEnvironmentVariable("Path", $new, "Machine")
    Remove-Item "C:\Program Files\BlackBackup" -Recurse -Force -EA SilentlyContinue
    Remove-Item $BACKUP_DIR -Recurse -Force -EA SilentlyContinue
    Write-OK "black-backup removed."
    Write-Host ""; exit 0
}

# ─────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────
if (-not ([Security.Principal.WindowsPrincipal]
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "  [X] Please run as Administrator." -ForegroundColor Red; exit 1
}
New-Item -ItemType Directory -Force -Path $BACKUP_DIR | Out-Null
if (-not (Test-Path $LOG_FILE)) { New-Item -ItemType File -Force -Path $LOG_FILE | Out-Null }

while ($true) {
    Show-Banner
    Write-Host "  Main Menu" -ForegroundColor White
    Write-Host ""
    Write-Host "  1)  Take a Backup"         -ForegroundColor Cyan
    Write-Host "  2)  Restore from Backup"   -ForegroundColor Cyan
    Write-Host "  3)  View Backups & Download" -ForegroundColor Cyan
    Write-Host "  4)  Delete a Backup"       -ForegroundColor Cyan
    Write-Host "  5)  Uninstall black-backup" -ForegroundColor Cyan
    Write-Host "  0)  Exit"                  -ForegroundColor Cyan
    Write-Host ""; Write-Div
    switch (Read-Host "  Choice") {
        "1" { Show-BackupMenu }
        "2" { Invoke-Restore }
        "3" { Show-BackupList }
        "4" { Remove-BackupEntry; Read-Host "  Press Enter to continue" }
        "5" { Invoke-Uninstall }
        "0" { Write-Host ""; Write-OK "Goodbye."; Write-Host ""; exit 0 }
        default { Write-Warn "Invalid. Enter 0-5."; Start-Sleep 1 }
    }
}
'@
# ── End of embedded script ────────────────────────────────────────────

New-Item -ItemType Directory -Force -Path $INSTALL_DIR | Out-Null
[System.IO.File]::WriteAllText($TOOL_PS1, $SCRIPT, [System.Text.Encoding]::UTF8)

# CMD wrapper so user can type "black-backup" from any prompt
$cmd = "@powershell.exe -ExecutionPolicy Bypass -NoProfile -File `"$TOOL_PS1`" %*"
[System.IO.File]::WriteAllText($TOOL_CMD, $cmd, [System.Text.Encoding]::ASCII)

# Add install dir to system PATH
$curPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
if ($curPath -notlike "*BlackBackup*") {
    [Environment]::SetEnvironmentVariable("Path", "$curPath;$INSTALL_DIR", "Machine")
    $env:PATH += ";$INSTALL_DIR"
}

Write-Host ""
Write-Host "  [OK] black-backup installed!" -ForegroundColor Green
Write-Host "  Run from any Administrator prompt:" -ForegroundColor Cyan
Write-Host "       black-backup" -ForegroundColor White
Write-Host ""
Write-Host "  Or run directly:" -ForegroundColor Gray
Write-Host "       powershell -ExecutionPolicy Bypass -File `"$TOOL_PS1`"" -ForegroundColor Gray
Write-Host ""
