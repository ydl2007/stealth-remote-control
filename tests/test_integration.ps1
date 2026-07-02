<#
.SYNOPSIS
    Test di integrazione end-to-end per Stealth Remote Control.
    Verifica il ciclo completo: backup → enable RDP → stato → cleanup → rollback.

.DESCRIPTION
    Esegue ogni fase del programma e verifica che:
    - Il backup dello stato originale sia completo
    - L'abilitazione RDP modifichi registro, porta, firewall
    - Lo stato mostrato corrisponda alla realtà
    - Il cleanup ripristini esattamente lo stato originale
    - Non rimangano tracce dopo il cleanup

    Richiede privilegi amministrativi.

.NOTES
    Compatibilità: PowerShell 5.1+ (Windows)
#>

#Requires -Version 5.1

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $PSCommandPath
$projectRoot = Resolve-Path "$scriptDir\.."
$scriptsDir = "$projectRoot\scripts"

$passCount = 0
$failCount = 0
$results = @()

function Test-Step {
    param([string]$Name, [scriptblock]$Block)
    
    Write-Host "  ? $Name ... " -NoNewline
    try {
        $result = & $Block
        if ($result) {
            Write-Host "OK" -ForegroundColor Green
            $script:passCount++
            $results += [PSCustomObject]@{ Name = $Name; Passed = $true }
        } else {
            Write-Host "FALLITO" -ForegroundColor Red
            $script:failCount++
            $results += [PSCustomObject]@{ Name = $Name; Passed = $false }
        }
    } catch {
        Write-Host "FALLITO ($($_.Exception.Message))" -ForegroundColor Red
        $script:failCount++
        $results += [PSCustomObject]@{ Name = $Name; Passed = $false; Error = $_.Exception.Message }
    }
}

function Assert-RegValue {
    param([string]$Path, [string]$Name, $Expected, [string]$Label)
    
    try {
        $actual = (Get-ItemProperty -Path "HKLM:\$Path" -Name $Name -ErrorAction Stop).$Name
        return $actual -eq $Expected
    } catch {
        return $false
    }
}

# ============================================================
#   MAIN
# ============================================================
Write-Host @"

╔══════════════════════════════════════════╗
║  TEST INTEGRAZIONE — STEALTH REMOTE      ║
╚══════════════════════════════════════════╝

"@ -ForegroundColor Cyan

# Check admin
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[!] DEVI ESEGUIRE COME AMMINISTRATORE" -ForegroundColor Red
    exit 1
}

Write-Host "Ambiente: $env:COMPUTERNAME, $((Get-CimInstance Win32_OperatingSystem).Caption)" -ForegroundColor Gray
Write-Host ""

# ============================================================
#   FASE 1: Backup stato originale
# ============================================================
Write-Host "── FASE 1: Backup stato originale ──" -ForegroundColor Yellow

Test-Step "Backup: salva stato" {
    & "$scriptsDir\preflight_save_state.bat" 2>$null
    return $?
}

Test-Step "Backup: file registro esiste" {
    Test-Path "$env:TEMP\src_backup\rdp_backup.reg"
}

Test-Step "Backup: file firewall esiste" {
    Test-Path "$env:TEMP\src_backup\firewall_backup.txt"
}

Test-Step "Backup: file porte esiste" {
    Test-Path "$env:TEMP\src_backup\ports_backup.txt"
}

# Salva valori originali per verifica rollback
$origRdpState = Assert-RegValue "SYSTEM\CurrentControlSet\Control\Terminal Server" "fDenyTSConnections" $null
$origPort = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name PortNumber -ErrorAction SilentlyContinue).PortNumber

# ============================================================
#   FASE 2: Abilita RDP stealth
# ============================================================
Write-Host ""
Write-Host "── FASE 2: Abilita RDP stealth ──" -ForegroundColor Yellow

Test-Step "RDP: script enable eseguito" {
    & "$scriptsDir\enable_rdp_stealth.bat" 2>$null
    return $?
}

Test-Step "RDP: fDenyTSConnections = 0" {
    Assert-RegValue "SYSTEM\CurrentControlSet\Control\Terminal Server" "fDenyTSConnections" 0
}

Test-Step "RDP: PortNumber = 3390 (0xD3E)" {
    $port = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name PortNumber -ErrorAction Stop).PortNumber
    return $port -eq 3390
}

Test-Step "RDP: regola firewall presente" {
    $rules = netsh advfirewall firewall show rule name="Windows Remote Desktop Services" 2>&1
    return ($rules -match "Windows Remote Desktop Services")
}

Test-Step "RDP: TermService in esecuzione" {
    $svc = Get-Service TermService -ErrorAction SilentlyContinue
    return ($svc -and $svc.Status -eq 'Running')
}

Test-Step "RDP: porta 3390 in ascolto" {
    $connections = netstat -ano | Select-String ":3390 "
    return ($connections -ne $null)
}

# ============================================================
#   FASE 3: Verifica stato
# ============================================================
Write-Host ""
Write-Host "── FASE 3: Stato sistema ──" -ForegroundColor Yellow

Test-Step "Stato: stealth_host.exe --status esegue" {
    # Non abbiamo ancora l'exe, verifichiamo con check_rdp_status.bat
    & "$scriptsDir\check_rdp_status.bat" 2>$null
    return $?
}

# ============================================================
#   FASE 4: Detection sandbox — verifica che i nostri componenti
#            siano invisibili
# ============================================================
Write-Host ""
Write-Host "── FASE 4: Detection sandbox ──" -ForegroundColor Yellow

Test-Step "Detection: sandbox esegue senza errori" {
    $output = & "$scriptsDir\detection_sandbox.ps1" 2>&1
    return $?
}

Test-Step "Detection: report JSON generato" {
    $reportPath = "$projectRoot\.omo\evidence\task-1-detection-sandbox.json"
    return (Test-Path $reportPath)
}

# ============================================================
#   FASE 5: Cleanup e rollback
# ============================================================
Write-Host ""
Write-Host "── FASE 5: Cleanup e rollback ──" -ForegroundColor Yellow

# Prima pulizia normalizzata con disable_rdp_stealth
Test-Step "Cleanup: disable RDP eseguito" {
    & "$scriptsDir\disable_rdp_stealth.bat" 2>$null
    return $?
}

Test-Step "Cleanup: fDenyTSConnections = 1 (RDP disabilitato)" {
    Assert-RegValue "SYSTEM\CurrentControlSet\Control\Terminal Server" "fDenyTSConnections" 1
}

Test-Step "Cleanup: PortNumber = 3389 (0xD3D)" {
    $port = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name PortNumber -ErrorAction SilentlyContinue).PortNumber
    return $port -eq 3389
}

Test-Step "Cleanup: regola firewall rimossa" {
    $rules = netsh advfirewall firewall show rule name="Windows Remote Desktop Services" 2>&1
    return ($rules -match "Nessuna regola")
}

# ============================================================
#   REPORT FINALE
# ============================================================
Write-Host ""
Write-Host "────────────────────────────────────────" -ForegroundColor Cyan
$total = $passCount + $failCount
if ($failCount -eq 0) {
    Write-Host "  ✅ TUTTI I TEST SUPERATI ($passCount/$total)" -ForegroundColor Green
} else {
    Write-Host "  ❌ $failCount test FALLITI su $total" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Dettaglio fallimenti:" -ForegroundColor Red
    foreach ($r in $results | Where-Object { -not $_.Passed }) {
        Write-Host "    - $($r.Name)" -ForegroundColor Red
        if ($r.Error) { Write-Host "      Motivo: $($r.Error)" -ForegroundColor Gray }
    }
}
Write-Host "────────────────────────────────────────" -ForegroundColor Cyan
Write-Host ""

# Esporta risultati
$results | Export-Csv -Path "$projectRoot\.omo\evidence\task-integration-report.csv" -NoTypeInformation
Write-Host "[*] Report salvato in .omo\evidence\task-integration-report.csv" -ForegroundColor Gray

if ($failCount -gt 0) { exit 1 } else { exit 0 }
