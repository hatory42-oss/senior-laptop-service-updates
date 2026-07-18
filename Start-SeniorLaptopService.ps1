[CmdletBinding()]
param([string]$TargetScript)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
if ([string]::IsNullOrEmpty($TargetScript)) { $TargetScript = Join-Path $scriptRoot 'SeniorLaptopService.ps1' }
$errorName = 'SeniorLaptopService-STARTUP-ERROR.txt'
$errorPath = Join-Path $scriptRoot $errorName
try {
    if (Test-Path -LiteralPath $errorPath) { Remove-Item -LiteralPath $errorPath -Force -ErrorAction SilentlyContinue }
} catch {
    $errorPath = Join-Path $env:TEMP $errorName
}

function Show-StartupMessage([string]$Text, [string]$Title, [string]$Icon) {
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show($Text, $Title, 'OK', $Icon)
}

function Write-StartupError([string]$Message, [object]$Failure) {
    $details = @(
        'Senior Laptop Service startup report',
        ('Created: ' + (Get-Date).ToString('s')),
        ('Computer: ' + $env:COMPUTERNAME),
        ('Windows: ' + [Environment]::OSVersion.VersionString),
        ('PowerShell: ' + $PSVersionTable.PSVersion.ToString()),
        ('CLR: ' + $PSVersionTable.CLRVersion.ToString()),
        ('Target: ' + $TargetScript),
        '',
        ('Message: ' + $Message)
    )
    if ($null -ne $Failure) {
        $details += ('Exception: ' + $Failure.Exception.GetType().FullName)
        $details += ('Error: ' + $Failure.Exception.Message)
        $details += ('Position: ' + [string]$Failure.InvocationInfo.PositionMessage)
        $details += ('Stack: ' + [string]$Failure.ScriptStackTrace)
    }
    try { $details | Out-File -LiteralPath $errorPath -Encoding UTF8 -Force } catch { }
}

try {
    $osVersion = [Environment]::OSVersion.Version
    $isWindows7 = ($osVersion.Major -eq 6 -and $osVersion.Minor -eq 1)
    if ($isWindows7) {
        $os = Get-WmiObject Win32_OperatingSystem -ErrorAction Stop
        if ([int]$os.ServicePackMajorVersion -lt 1) {
            $message = "Обнаружена Windows 7 без Service Pack 1.`r`n`r`nПрограмма не сможет безопасно запуститься. Сначала установите Windows 7 SP1, затем .NET Framework 4.5.2 или новее и Windows Management Framework 5.1."
            Write-StartupError $message $null
            Show-StartupMessage ($message + "`r`n`r`nОтчёт: " + $errorPath) 'Требуется Windows 7 SP1' 'Error'
            exit 41
        }
    }

    $powerShellVersion = $PSVersionTable.PSVersion
    if ($powerShellVersion.Major -lt 5 -or ($powerShellVersion.Major -eq 5 -and $powerShellVersion.Minor -lt 1)) {
        $netRelease = 0
        try {
            $netInfo = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction Stop
            $releaseProperty = $netInfo.PSObject.Properties['Release']
            if ($null -ne $releaseProperty) { $netRelease = [int]$releaseProperty.Value }
        } catch { }

        if ($isWindows7 -and $netRelease -lt 379893) {
            $message = "На Windows 7 отсутствует обязательный .NET Framework 4.5.2 или новее.`r`n`r`nСначала установите .NET Framework 4.8 с сайта Microsoft, перезагрузите компьютер, затем снова запустите программу."
            Write-StartupError $message $null
            Add-Type -AssemblyName System.Windows.Forms
            $answer = [System.Windows.Forms.MessageBox]::Show(($message + "`r`n`r`nОткрыть официальную страницу Microsoft?`r`n`r`nОтчёт: " + $errorPath), '.NET Framework требуется', 'YesNo', 'Warning')
            if ($answer -eq 'Yes') { Start-Process 'https://dotnet.microsoft.com/en-us/download/dotnet-framework/net48' }
            exit 42
        }

        $architectureFile = if ([IntPtr]::Size -eq 8) { 'Win7AndW2K8R2-KB3191566-x64.zip' } else { 'Win7-KB3191566-x86.zip' }
        $message = "Установлен Windows PowerShell $($powerShellVersion.ToString()), а программе требуется PowerShell 5.1.`r`n`r`nДля Windows 7 SP1 установите Windows Management Framework 5.1 (KB3191566), файл $architectureFile, затем обязательно перезагрузите компьютер."
        Write-StartupError $message $null
        Add-Type -AssemblyName System.Windows.Forms
        $answer = [System.Windows.Forms.MessageBox]::Show(($message + "`r`n`r`nОткрыть официальную страницу загрузки Microsoft?`r`n`r`nОтчёт: " + $errorPath), 'PowerShell 5.1 требуется', 'YesNo', 'Warning')
        if ($answer -eq 'Yes') { Start-Process 'https://www.microsoft.com/download/details.aspx?id=54616' }
        exit 43
    }

    if (-not (Test-Path -LiteralPath $TargetScript -PathType Leaf)) {
        throw "Основной файл не найден: $TargetScript"
    }

    & $TargetScript
}
catch {
    $message = 'Основная программа не запустилась. Отчёт об ошибке сохранён рядом с программой.'
    Write-StartupError $message $_
    Show-StartupMessage ($message + "`r`n`r`n" + $_.Exception.Message + "`r`n`r`nОтчёт: " + $errorPath) 'Ошибка запуска Senior Laptop Service' 'Error'
    exit 50
}
