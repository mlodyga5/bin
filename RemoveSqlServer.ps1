<#
.SYNOPSIS
Attempts to forcefully remove a specific SQL Server instance with automated backups
of registry keys and data directories, plus removal of related groups and firewall rules.

.DESCRIPTION
This script enhances the manual removal process for a broken SQL Server instance.
It REQUIRES the Instance Name. Use 'MSSQLSERVER' for the default instance.

WARNING: This script performs DESTRUCTIVE actions (process termination, service stop/disable,
file deletion, registry modification, group removal, firewall rule removal).
Run as Administrator. USE AT YOUR OWN RISK AFTER FULL BACKUP of unrelated system data.

BACKUPS: Creates a backup folder (default C:\SQL_Forced_Uninstall_Backup_...) containing:
  - Copies of detected Data/Log directory contents (.mdf, .ldf files etc.).
  - Exports (.reg files) of registry keys BEFORE they are removed.

AUTOMATION ADDED:
  - Attempts to kill related processes.
  - Attempts to remove instance-specific local Windows groups.
  - Attempts to remove instance-specific Windows Firewall rules.

STILL RECOMMENDED: Manual check of Apps & Features, reboot, final verification.

.PARAMETER InstanceName
The name of the SQL Server instance to remove. Use 'MSSQLSERVER' for the default instance.
(e.g., -InstanceName MSSQLSERVER, -InstanceName SQLEXPRESS)

.PARAMETER BackupRootPath
Optional. The root directory where the timestamped backup folder will be created.
Defaults to 'C:\'. The final backup path will be like <BackupRootPath>\SQL_Forced_Uninstall_Backup_<InstanceName>_<Timestamp>.

.EXAMPLE
.\Remove-SqlServerInstanceEnhanced.ps1 -InstanceName MSSQLSERVER

.EXAMPLE
.\Remove-SqlServerInstanceEnhanced.ps1 -InstanceName SQLEXPRESS -BackupRootPath "D:\Backups"

.NOTES
Author: Assistant (AI) based on user request
Version: 2.0
Requires: Administrator privileges, PowerShell 5.0+ (for Get-LocalGroup etc.)
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$InstanceName,

    [Parameter(Mandatory = $false)]
    [string]$BackupRootPath = "C:\"
)

# --- Script Setup ---
Write-Host "-----------------------------------------------------" -ForegroundColor Yellow
Write-Host " SQL Server Instance Force Removal Script (Enhanced) " -ForegroundColor Yellow
Write-Host "-----------------------------------------------------" -ForegroundColor Yellow
Write-Host "Target Instance: $InstanceName"

# Check for Administrator privileges
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "SCRIPT STOPPED: This script must be run with Administrator privileges." -ErrorAction Stop
}

# Validate BackupRootPath
if (-not (Test-Path -Path $BackupRootPath -PathType Container)) {
    Write-Error "SCRIPT STOPPED: BackupRootPath '$BackupRootPath' does not exist or is not a directory." -ErrorAction Stop
}

# Create Timestamped Backup Folder
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupFolderName = "SQL_Forced_Uninstall_Backup_${InstanceName}_${timestamp}"
$BackupPath = Join-Path -Path $BackupRootPath -ChildPath $backupFolderName
try {
    New-Item -Path $BackupPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
    Write-Host "Backup location created: '$BackupPath'" -ForegroundColor Cyan
} catch {
    Write-Error "SCRIPT STOPPED: Failed to create backup directory '$BackupPath'. Error: $($_.Exception.Message)" -ErrorAction Stop
}

# CRITICAL Confirmation Prompt
Write-Warning "----------------------------- !!! WARNING !!! ---------------------------------"
Write-Warning "This script will attempt to forcefully remove SQL Server instance '$InstanceName'."
Write-Warning "Actions: Process Kill, Service Stop/Disable, File Deletion, Registry Removal, Group Removal, Firewall Rule Removal."
Write-Warning "This is IRREVERSIBLE without backups and could damage your system if used incorrectly."
Write-Warning "Backups of registry and data files will be attempted to: '$BackupPath'"
Write-Warning "Ensure you have backed up ANY OTHER critical system data separately!"
Write-Warning "Review the script and understand its actions before proceeding."
Write-Warning "-------------------------------------------------------------------------------"
$confirmation = Read-Host "Type 'YES' in uppercase to confirm you understand the risks and wish to proceed:"

if ($confirmation -ne 'YES') {
    Write-Host "Operation cancelled by user." -ForegroundColor Green
    Remove-Item -Path $BackupPath -Recurse -Force -ErrorAction SilentlyContinue # Clean up empty backup dir
    Exit
}

# --- Variables and Information Gathering ---
$ErrorActionPreference = 'SilentlyContinue' # Change to 'Continue' or 'Stop' for debugging
$VerbosePreference = 'Continue' # Enable verbose messages

$ComputerName = $env:COMPUTERNAME
$InstanceId = $null
$InstanceVersionNumber = $null # e.g., 150, 140
$SqlProgramFilesPath = $null # e.g., C:\Program Files\Microsoft SQL Server\MSSQL15.MSSQLSERVER
$SqlBinPath = $null # Path to Binn folder
$DefaultDataPath = $null
$DefaultLogPath = $null

# Derive service names
$sqlServiceName = if ($InstanceName -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { "MSSQL`$$InstanceName" }
$agentServiceName = if ($InstanceName -eq 'MSSQLSERVER') { 'SQLSERVERAGENT' } else { "SQLAgent`$$InstanceName" }
$ftDaemonServiceName = if ($InstanceName -eq 'MSSQLSERVER') { 'MSSQLFDLauncher' } else { "MSSQLFDLauncher`$$InstanceName" }
# Add other potential instance-specific services if needed (MSOLAP$, ReportServer$)

$instanceServicesToManage = @( $sqlServiceName, $agentServiceName, $ftDaemonServiceName )
$sharedServicesToManage = @('SQLBrowser', 'SQLWriter') # Stop these, but don't remove registry/files usually
$allServicesToStop = $instanceServicesToManage + $sharedServicesToManage

# Try to find instance details via WMI and Registry (Best effort)
Write-Verbose "Attempting to gather instance information..."
try {
    # Find service path to deduce Instance ID and paths
    $serviceObject = Get-CimInstance Win32_Service -Filter "Name='$sqlServiceName'" -ErrorAction SilentlyContinue
    if ($serviceObject -and $serviceObject.PathName) {
        $sqlServicePath = $serviceObject.PathName.Replace('"', '')
        Write-Verbose "Found service path: $sqlServicePath"
        # Regex to extract Instance ID (MSSQL<Ver>.<Name>) and Program Files path
        if ($sqlServicePath -match '^(.+?)\\(MSSQL(\d{1,2})\.(.+?))\\MSSQL\\Binn\\sqlservr\.exe') {
            $SqlProgramFilesPath = $Matches[1] + "\" + $Matches[2] # e.g., C:\Program Files\Microsoft SQL Server\MSSQL15.MSSQLSERVER
            $InstanceId = $Matches[2] # e.g., MSSQL15.MSSQLSERVER
            $InstanceVersionNumber = $Matches[3] + "0" # e.g., 15 -> 150
            $SqlBinPath = Join-Path -Path $SqlProgramFilesPath -ChildPath "MSSQL\Binn"
            Write-Host "Detected Instance ID: $InstanceId (Version $InstanceVersionNumber)" -ForegroundColor Cyan
            Write-Host "Detected Instance Path: $SqlProgramFilesPath" -ForegroundColor Cyan
        } else {
             Write-Warning "Could not parse standard Instance ID/Path from service path: $sqlServicePath"
        }
    } else {
         Write-Warning "SQL Server service '$sqlServiceName' not found or path is empty via WMI. Relying on registry/defaults."
    }

    # Try registry for paths (even if service is broken, registry might exist)
    $instanceRegKeyPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL"
    $instanceRegKeyValue = (Get-ItemProperty -Path $instanceRegKeyPath -Name $InstanceName -ErrorAction SilentlyContinue).$InstanceName
    if ($instanceRegKeyValue) {
         Write-Verbose "Found instance registry value: $instanceRegKeyValue"
         if (!$InstanceId) { $InstanceId = $instanceRegKeyValue } # Use this if WMI failed

         # Try getting Setup path and Data paths from instance key
         $instanceSetupPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceRegKeyValue\Setup"
         $sqlSetupProps = Get-ItemProperty -Path $instanceSetupPath -ErrorAction SilentlyContinue
         if ($sqlSetupProps) {
            if (!$SqlProgramFilesPath) { $SqlProgramFilesPath = $sqlSetupProps.SQLDataRoot } # Get path if not found earlier
            if ($SqlProgramFilesPath -and !$SqlBinPath) {$SqlBinPath = Join-Path -Path $SqlProgramFilesPath -ChildPath "MSSQL\Binn"} # Deduce Binn path

            # Get Default Data/Log paths for backup
            $mssqlRegPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceRegKeyValue\MSSQLServer"
            $mssqlProps = Get-ItemProperty -Path $mssqlRegPath -ErrorAction SilentlyContinue
            if($mssqlProps){
                $DefaultDataPath = $mssqlProps.DefaultData
                $DefaultLogPath = $mssqlProps.DefaultLog
                if ($DefaultDataPath) { Write-Host "Detected Default Data Path: $DefaultDataPath" -ForegroundColor Cyan } else { Write-Warning "Could not detect Default Data Path from registry."}
                if ($DefaultLogPath) { Write-Host "Detected Default Log Path: $DefaultLogPath" -ForegroundColor Cyan } else { Write-Warning "Could not detect Default Log Path from registry."}
            } else {
                 Write-Warning "Could not access registry key '$mssqlRegPath' for Data/Log paths."
            }
         } else {
              Write-Warning "Could not access registry key '$instanceSetupPath' for Setup paths."
         }
    } else {
         Write-Warning "Instance '$InstanceName' not found in '$instanceRegKeyPath'. Cannot determine registry paths reliably."
    }

    # Final check if we have core paths
    if (!$SqlProgramFilesPath) {
        Write-Warning "Could not determine the main SQL Server instance installation path. File deletion will be skipped."
    }
     if (!$InstanceId) {
         Write-Warning "Could not determine the Instance ID (e.g., MSSQL15.MSSQLSERVER). Registry cleanup for instance-specific keys will be skipped."
     }

} catch {
    Write-Warning "An error occurred during information gathering: $($_.Exception.Message)"
}


# --- Backup Phase ---
Write-Host "`n--- Backing Up Data and Registry ---" -ForegroundColor Yellow

# 1. Backup Data Directories
$dataBackupPerformed = $false
$dataBackupPath = Join-Path -Path $BackupPath -ChildPath "DataBackup"
if ($DefaultDataPath -and (Test-Path -Path $DefaultDataPath -PathType Container)) {
    Write-Host "Backing up Data directory '$DefaultDataPath' to '$dataBackupPath\Data'..."
    try {
        Copy-Item -Path $DefaultDataPath -Destination "$dataBackupPath\Data" -Recurse -Force -ErrorAction Stop
        Write-Host "Data directory backup complete." -ForegroundColor Green
        $dataBackupPerformed = $true
    } catch { Write-Warning "Failed to backup Data directory '$DefaultDataPath': $($_.Exception.Message)" }
} else { Write-Warning "Default Data Path not found or not specified. Skipping data directory backup." }

if ($DefaultLogPath -and (Test-Path -Path $DefaultLogPath -PathType Container) -and $DefaultLogPath -ne $DefaultDataPath) {
    Write-Host "Backing up Log directory '$DefaultLogPath' to '$dataBackupPath\Log'..."
    try {
        Copy-Item -Path $DefaultLogPath -Destination "$dataBackupPath\Log" -Recurse -Force -ErrorAction Stop
        Write-Host "Log directory backup complete." -ForegroundColor Green
        $dataBackupPerformed = $true
    } catch { Write-Warning "Failed to backup Log directory '$DefaultLogPath': $($_.Exception.Message)" }
} else { Write-Verbose "Default Log Path not found, same as Data Path, or not specified. Skipping separate log directory backup." }

if (-not $dataBackupPerformed) {
    Write-Warning "No data files were automatically backed up. Ensure manual backup if needed."
}

# 2. Backup Registry Keys
Write-Host "Backing up registry keys..."
$regBackupPath = Join-Path -Path $BackupPath -ChildPath "RegistryBackup"
New-Item -Path $regBackupPath -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

$regKeysToBackupAndRemove = @()
# Instance specific keys (HKLM Software)
if ($InstanceId) {
    $regKeysToBackupAndRemove += "HKLM\SOFTWARE\Microsoft\Microsoft SQL Server\$InstanceId"
    $regKeysToBackupAndRemove += "HKLM\SOFTWARE\Wow6432Node\Microsoft\Microsoft SQL Server\$InstanceId" # 64bit OS
}
# Instance specific keys (HKLM Instance Names) - Backup but maybe don't remove the root 'Instance Names\SQL'? Just the value.
# $regKeysToBackupAndRemove += "HKLM\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL" # Backup this level
# Service keys (HKLM System)
foreach ($serviceName in $instanceServicesToManage) {
    if ($serviceName) { $regKeysToBackupAndRemove += "HKLM\SYSTEM\CurrentControlSet\Services\$serviceName" }
}
# User settings keys (HKCU) - Backup but removal less critical / might target specific version if known
if($InstanceVersionNumber){
    $regKeysToBackupAndRemove += "HKCU\Software\Microsoft\Microsoft SQL Server\$InstanceVersionNumber"
}
$regKeysToBackupAndRemove += "HKCU\Software\Microsoft\MSSQLServer" # General tools settings

# Shared Keys - Backup only, script won't remove them by default
$regKeysToBackupOnly = @(
    "HKLM\SOFTWARE\Microsoft\Microsoft SQL Server", # Parent key
    "HKLM\SOFTWARE\Wow6432Node\Microsoft\Microsoft SQL Server", # Parent key (64bit)
    "HKLM\SYSTEM\CurrentControlSet\Services\SQLBrowser",
    "HKLM\SYSTEM\CurrentControlSet\Services\SQLWriter"
)

$allRegKeysToBackup = ($regKeysToBackupAndRemove + $regKeysToBackupOnly) | Sort-Object -Unique

foreach ($regKey in $allRegKeysToBackup) {
    $regKeyPathForFile = $regKey -replace ':', '' -replace '\\', '_'
    $backupFile = Join-Path -Path $regBackupPath -ChildPath "${regKeyPathForFile}.reg"
    if (Test-Path $regKey) {
        Write-Verbose "Backing up registry key '$regKey' to '$backupFile'..."
        try {
            # Use reg.exe export for simplicity and reliability
            Start-Process reg.exe -ArgumentList "export `"$regKey`" `"$backupFile`" /y" -Wait -NoNewWindow -ErrorAction Stop
            Write-Host "Backed up '$regKey'." -ForegroundColor Green
        } catch {
            Write-Warning "Failed to back up registry key '$regKey': $($_.Exception.Message)"
        }
    } else {
        Write-Verbose "Registry key '$regKey' not found, skipping backup."
    }
}


# --- Termination Phase ---
Write-Host "`n--- Terminating Processes and Services ---" -ForegroundColor Yellow

# 1. Kill Processes (if paths known)
if ($SqlBinPath -and (Test-Path $SqlBinPath)) {
    Write-Host "Attempting to terminate processes running from '$SqlBinPath'..."
    $sqlProcesses = @('sqlservr', 'sqlagent', 'sqlwriter', 'msmdsrv', 'ReportingServicesService') # Add others if needed
    foreach ($procName in $sqlProcesses) {
        Get-Process -Name $procName -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$SqlBinPath\*" } | ForEach-Object {
            Write-Warning "Terminating process: $($_.ProcessName) (PID: $($_.Id))"
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    }
} else {
    Write-Warning "SQL Binary path not determined. Skipping targeted process termination."
}

# 2. Stop and Disable Services
Write-Host "Stopping and disabling services..."
foreach ($serviceName in $allServicesToStop) {
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($service) {
        # Stop
        if ($service.Status -ne 'Stopped') {
            Write-Verbose "Stopping service: '$($serviceName)'..."
            Stop-Service -InputObject $service -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
            $service = Get-Service -Name $serviceName # Refresh
            if ($service.Status -ne 'Stopped') { Write-Warning "Failed to stop service '$serviceName'." }
            else { Write-Host "Service '$serviceName' stopped." -ForegroundColor Green }
        } else { Write-Verbose "Service '$serviceName' already stopped." }

        # Disable
        if ($service.StartType -ne 'Disabled') {
            Write-Verbose "Disabling service: '$($serviceName)'..."
            Set-Service -InputObject $service -StartupType Disabled -ErrorAction SilentlyContinue
            $service = Get-Service -Name $serviceName # Refresh
            if ($service.StartType -ne 'Disabled') { Write-Warning "Failed to disable service '$serviceName'." }
            else { Write-Host "Service '$serviceName' disabled." -ForegroundColor Green }
        } else { Write-Verbose "Service '$serviceName' already disabled." }
    } else {
        Write-Verbose "Service not found: '$($serviceName)'."
    }
}


# --- Removal Phase ---
Write-Host "`n--- Removing Firewall Rules, Registry, Groups, Folders ---" -ForegroundColor Yellow

# 1. Remove Firewall Rules (if Binn path known)
if ($SqlBinPath) {
    Write-Host "Attempting to remove firewall rules associated with '$SqlBinPath'..."
    try {
        $ruleCount = 0
        Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.Program -like "$SqlBinPath\*" } | ForEach-Object {
            Write-Warning "Removing Firewall Rule: '$($_.DisplayName)' ('$($_.Name)')"
            Remove-NetFirewallRule -Name $_.Name -ErrorAction SilentlyContinue
            $ruleCount++
        }
         Write-Host "Removed $ruleCount potential firewall rules." -ForegroundColor Green
    } catch {
         Write-Warning "Failed to query or remove firewall rules: $($_.Exception.Message)"
    }
} else {
    Write-Warning "SQL Binary path not determined. Skipping firewall rule removal."
}


# 2. Remove Registry Keys (using the backup list)
Write-Host "Removing specific registry keys (already backed up)..."
$registryCleaned = $false
# Add the specific Instance Name value from the Instance Names key to the removal list
$instanceNameRegValuePath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL"
if (Get-ItemProperty -Path $instanceNameRegValuePath -Name $InstanceName -ErrorAction SilentlyContinue) {
    Write-Warning "Removing instance name entry '$InstanceName' from '$instanceNameRegValuePath'"
    try{
        Remove-ItemProperty -Path $instanceNameRegValuePath -Name $InstanceName -Force -ErrorAction Stop
        Write-Host "Removed instance name registry value." -ForegroundColor Green
    } catch {
        Write-Warning "Failed to remove instance name registry value '$InstanceName': $($_.Exception.Message)"
    }
}

foreach ($regKey in $regKeysToBackupAndRemove) {
    if (Test-Path $regKey) {
        Write-Warning "Removing Registry Key: '$regKey'"
        try {
            Remove-Item -Path $regKey -Recurse -Force -ErrorAction Stop
            Write-Host "Successfully removed '$regKey'." -ForegroundColor Green
            $registryCleaned = $true
        } catch {
            Write-Warning "Failed to remove registry key '$regKey': Error: $($_.Exception.Message). Manual removal required."
        }
    } else {
        # Write-Verbose "Registry key '$regKey' not found for removal (may already be gone)."
    }
}
if (-not $registryCleaned) {
     Write-Warning "No specific instance registry keys were found or automatically removed."
} else {
     Write-Warning "Registry cleaning attempted. Manual verification recommended (regedit)."
}

# 3. Remove Local Groups
Write-Host "Attempting to remove local Windows groups for instance '$InstanceName'..."
# Construct expected group names
$sqlUserGroup = "SQLServerMSSQLUser`$$ComputerName`$$InstanceName"
$sqlAgentGroup = "SQLServerSQLAgentUser`$$ComputerName`$$InstanceName"
$sqlBrowserGroup = "SQLServerSQLBrowserUser`$$ComputerName" # Shared, remove with caution? Maybe not.
$sqlAnalysisGroup = "SQLServerMSASUser`$$ComputerName`$$InstanceName" # If AS installed
$sqlReportingGroup = "SQLServerReportServerUser`$$ComputerName`$$InstanceName" # If RS installed

$groupsToRemove = @( $sqlUserGroup, $sqlAgentGroup, $sqlAnalysisGroup, $sqlReportingGroup) # Exclude browser group for now
$groupsRemovedCount = 0
foreach ($groupName in $groupsToRemove) {
    try {
        $localGroup = Get-LocalGroup -Name $groupName -ErrorAction SilentlyContinue
        if ($localGroup) {
            Write-Warning "Removing local group: '$groupName'"
            Remove-LocalGroup -Name $groupName -ErrorAction Stop
            Write-Host "Successfully removed group '$groupName'." -ForegroundColor Green
            $groupsRemovedCount++
        } else {
            Write-Verbose "Local group '$groupName' not found."
        }
    } catch {
        Write-Warning "Failed to remove local group '$groupName': $($_.Exception.Message)"
    }
}
Write-Host "Removed $groupsRemovedCount potential local groups." -ForegroundColor Green
Write-Warning "Review local groups manually (lusrmgr.msc) for any others or dedicated user accounts."


# 4. Delete Installation Folders (if path known)
Write-Host "Attempting to remove installation folder..."
if ($SqlProgramFilesPath -and (Test-Path -Path $SqlProgramFilesPath -PathType Container)) {
    Write-Warning "!!! Removing Installation Folder: '$SqlProgramFilesPath' !!!"
    Write-Warning "Data/Log files should have been backed up to '$BackupPath'."
    Write-Warning "This folder and ALL its remaining contents will be deleted."
    try {
        Remove-Item -Path $SqlProgramFilesPath -Recurse -Force -ErrorAction Stop
        Write-Host "Successfully removed '$SqlProgramFilesPath'." -ForegroundColor Green
    } catch {
        Write-Error "Failed to remove folder '$SqlProgramFilesPath'. Error: $($_.Exception.Message)."
        Write-Error "Manual deletion required. Files might be locked (Reboot might help)."
    }
} else {
    Write-Warning "SQL Installation path not found or specified ('$SqlProgramFilesPath'). Skipping folder deletion."
    Write-Warning "Manual check required in '$($Env:ProgramFiles)\Microsoft SQL Server' and '$($Env:ProgramFiles(x86))\Microsoft SQL Server'."
}


# --- Final Steps and Recommendations ---
Write-Host "`n--- Final Manual Steps REQUIRED ---" -ForegroundColor Cyan
Write-Host "1. *** REBOOT THE COMPUTER *** This is crucial to release file locks and finalize changes."
Write-Host "2. Open 'Apps & Features' (or 'Programs and Features'). MANUALLY UNINSTALL any remaining components:"
Write-Host "   - Microsoft SQL Server Setup (might still be listed)"
Write-Host "   - Microsoft SQL Server Native Client / ODBC / JDBC Drivers"
Write-Host "   - Microsoft SQL Server Management Studio (SSMS)"
Write-Host "   - Azure Data Studio"
Write-Host "   - Microsoft SQL Server Data Tools (SSDT)"
Write-Host "   - Microsoft VSS Writer for SQL Server"
Write-Host "   - SQL Server Browser (if no other instances remain)"
Write-Host "   - Any other 'Microsoft SQL Server' entries."
Write-Host "   >>> Use the 'Microsoft Program Install and Uninstall Troubleshooter' if standard uninstall fails <<<"
Write-Host "3. Manually verify removal of files/folders if the script reported errors or skipped them."
Write-Host "4. Manually verify removal of registry keys (using regedit) and local groups/users (lusrmgr.msc)."
Write-Host "5. Check the backup folder '$BackupPath' to ensure critical data/registry backups are present."

Write-Host "`nEnhanced removal script finished." -ForegroundColor Green
Write-Host "Review all output above for warnings/errors and perform the REQUIRED manual steps." -ForegroundColor Green

# Reset ErrorActionPreference if changed
$ErrorActionPreference = 'Continue'
$VerbosePreference = 'SilentlyContinue'
