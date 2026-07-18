[CmdletBinding()]
param(
    [switch]$Maintenance,
    [switch]$UpdateZapretLists
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$AppName = 'Senior Laptop Service'
$AppVersion = '0.23.0'
$InstallRoot = Join-Path $env:ProgramData 'SeniorLaptopService'
$ZapretRoot = Join-Path $PSScriptRoot 'Zapret'
$LogRoot = Join-Path $InstallRoot 'Logs'
$PortableSecretRoot = Join-Path $PSScriptRoot '.secrets'
$ReportTokenPath = Join-Path $PortableSecretRoot 'report-upload.token'
$PinnedZapretVersion = '1.9.9d'
$PinnedZapretSha256 = 'CCA30A0C7A9327841047147AF2C100024734855B9D18A4F9D84B81479AFB2EF3'
$PinnedZapretUrl = 'https://raw.githubusercontent.com/hatory42-oss/senior-laptop-service-updates/main/assets/zapret-discord-youtube-1.9.9d.zip'
$PinnedZapretApiUrl = 'https://api.github.com/repos/hatory42-oss/senior-laptop-service-updates/contents/assets/zapret-discord-youtube-1.9.9d.zip?ref=main'

function Ensure-Directory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

function Get-ReportStorageRoot {
    $portableRoot = Join-Path $PSScriptRoot 'Reports'
    try {
        Ensure-Directory $portableRoot
        return $portableRoot
    } catch {
        $temporaryRoot = Join-Path $env:TEMP 'SeniorLaptopService-Reports'
        Ensure-Directory $temporaryRoot
        return $temporaryRoot
    }
}

function Write-ServiceLog([string]$Message) {
    Ensure-Directory $LogRoot
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath (Join-Path $LogRoot ('maintenance-{0}.log' -f (Get-Date -Format 'yyyyMM'))) -Value $line -Encoding UTF8
    if ((Get-Variable -Name LogBox -Scope Script -ErrorAction SilentlyContinue) -and $script:LogBox) {
        $script:LogBox.AppendText($line + [Environment]::NewLine)
        $script:LogBox.SelectionStart = $script:LogBox.TextLength
        $script:LogBox.ScrollToCaret()
        [Windows.Forms.Application]::DoEvents()
    }
    if ((Get-Variable -Name OperationRunning -Scope Script -ErrorAction SilentlyContinue) -and $script:OperationRunning -and (Get-Variable -Name StatusLabel -Scope Script -ErrorAction SilentlyContinue) -and $script:StatusLabel) {
        $shortMessage = if ($Message.Length -gt 105) { $Message.Substring(0,105) + '…' } else { $Message }
        $script:LastOperationMessage = $shortMessage
        $elapsed = if ($script:OperationStopwatch) { [math]::Floor($script:OperationStopwatch.Elapsed.TotalSeconds) } else { 0 }
        $script:StatusLabel.Text = "Выполняется: $($script:CurrentAction) | $shortMessage | $elapsed сек."
        [Windows.Forms.Application]::DoEvents()
    }
}

function Test-Administrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Set-ManagedBrowserExtension([string]$PolicyPath, [string]$ExtensionId) {
    $knownBlockers = @('bgnkhhnnamicmpeenaelnjfhikgbkllg','gighmmpiobklfepjocnamgkkbiglidom','cfhdojbkjhnklbpkdaibdccddilifddb')
    New-Item -Path $PolicyPath -Force | Out-Null
    $policy = Get-ItemProperty -Path $PolicyPath -ErrorAction SilentlyContinue
    foreach ($property in @($policy.PSObject.Properties | Where-Object { $_.Name -match '^\d+$' })) {
        $configuredId = ([string]$property.Value -split ';')[0]
        if ($configuredId -in $knownBlockers) { Remove-ItemProperty -Path $PolicyPath -Name $property.Name -Force -ErrorAction SilentlyContinue }
    }
    $policy = Get-ItemProperty -Path $PolicyPath -ErrorAction SilentlyContinue
    $slot = 1
    while ($null -ne $policy.PSObject.Properties[[string]$slot]) { $slot++ }
    Set-ItemProperty -Path $PolicyPath -Name ([string]$slot) -Value ($ExtensionId + ';https://clients2.google.com/service/update2/crx') -Type String
}

function Get-SafeProperty([object]$Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    $property.Value
}

function Get-ThirdPartyAntivirusProducts {
    $knownPattern = 'Avast|AVG|Avira|Kaspersky|Norton|McAfee|ESET|NOD32|Bitdefender|Dr\.?Web|360 Total Security|Panda|Malwarebytes|Comodo|Trend Micro|Sophos|F-Secure|G DATA|ZoneAlarm|Webroot'
    $securityCenter = @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue | Where-Object { [string]$_.displayName -notmatch 'Microsoft Defender|Windows Defender' })
    $registeredNames = @($securityCenter | ForEach-Object { [string]$_.displayName } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $uninstallEntries = @(Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object {
        $name = [string](Get-SafeProperty $_ 'DisplayName')
        if ([string]::IsNullOrWhiteSpace($name) -or $name -match 'Microsoft Defender|Windows Defender') { return $false }
        if ($name -match $knownPattern) { return $true }
        foreach ($registeredName in $registeredNames) { if ($name -like "*$registeredName*" -or $registeredName -like "*$name*") { return $true } }
        return $false
    })
    [ordered]@{ security_center=$securityCenter; uninstall_entries=$uninstallEntries; names=@(($registeredNames + @($uninstallEntries | ForEach-Object { [string](Get-SafeProperty $_ 'DisplayName') })) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique) }
}

function Get-DetailedErrorText([System.Management.Automation.ErrorRecord]$ErrorRecord) {
    $parts = New-Object Collections.Generic.List[string]
    $parts.Add('Message: ' + $ErrorRecord.Exception.Message)
    $parts.Add('Exception: ' + $ErrorRecord.Exception.GetType().FullName)
    if ($ErrorRecord.Exception.InnerException) { $parts.Add('Inner exception: ' + $ErrorRecord.Exception.InnerException.Message) }
    if ($ErrorRecord.FullyQualifiedErrorId) { $parts.Add('Error ID: ' + $ErrorRecord.FullyQualifiedErrorId) }
    if ($ErrorRecord.CategoryInfo) { $parts.Add('Category: ' + $ErrorRecord.CategoryInfo.ToString()) }
    if ($ErrorRecord.InvocationInfo) {
        $parts.Add('Script: ' + $ErrorRecord.InvocationInfo.ScriptName)
        $parts.Add('Line: ' + $ErrorRecord.InvocationInfo.ScriptLineNumber)
        $parts.Add('Position: ' + $ErrorRecord.InvocationInfo.PositionMessage)
    }
    if ($ErrorRecord.ScriptStackTrace) { $parts.Add('Stack: ' + $ErrorRecord.ScriptStackTrace) }
    $parts -join [Environment]::NewLine
}

function New-AutomaticErrorReport([string]$ActionName, [System.Management.Automation.ErrorRecord]$ErrorRecord) {
    $reportRoot = Get-ReportStorageRoot
    $path = Join-Path $reportRoot ('SeniorLaptopService-ERROR-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $lines = @(
        'Senior Laptop Service automatic error report',
        "Application version: $AppVersion",
        "Created: $((Get-Date).ToString('o'))",
        "Action: $ActionName",
        "Computer: $env:COMPUTERNAME",
        "Windows: $($os.Caption) $($os.Version) build $($os.BuildNumber)",
        "PowerShell: $($PSVersionTable.PSVersion)",
        "Administrator: $(Test-Administrator)",
        '',
        (Get-DetailedErrorText $ErrorRecord),
        '',
        'Privacy: Wi-Fi passwords, browser history, cookies and personal files are not included.'
    )
    [IO.File]::WriteAllLines($path,$lines,[Text.UTF8Encoding]::new($true))
    Write-ServiceLog "Automatic error report created: $path"
    try { [Windows.Forms.Clipboard]::SetText($path) } catch { }
    $path
}

function Get-HttpErrorDetails([System.Management.Automation.ErrorRecord]$ErrorRecord) {
    $message = $ErrorRecord.Exception.Message
    try {
        $response = $ErrorRecord.Exception.Response
        if ($response) {
            $stream = $response.GetResponseStream()
            if ($stream) { $reader = New-Object IO.StreamReader($stream); try { $body=$reader.ReadToEnd() } finally { $reader.Dispose() }; if ($body) { $message += "`nGitHub response: $body" } }
        }
    } catch { }
    $message
}

function Remove-DirectoryContentsSafely([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return 0L }
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    if ($resolved.Length -lt 8 -or $resolved -match '^[A-Za-z]:\\?$') { throw "Unsafe cleanup target: $resolved" }
    $before = (Get-ChildItem -LiteralPath $resolved -Force -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    Get-ChildItem -LiteralPath $resolved -Force -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
    [int64]$before
}

function Get-CacheTargets {
    $targets = New-Object Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) { $targets.Add($env:TEMP) }
    if (-not [string]::IsNullOrWhiteSpace($env:windir)) { $targets.Add((Join-Path $env:windir 'Temp')) }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
        $targets.Add((Join-Path $env:ProgramData 'Microsoft\Windows\WER\Temp'))
        $targets.Add((Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue'))
    }
    $systemDrive = [Environment]::GetEnvironmentVariable('SystemDrive')
    if ([string]::IsNullOrWhiteSpace($systemDrive)) { $systemDrive = 'C:' }
    $usersRoot = Join-Path $systemDrive 'Users'
    $userRoots = @(Get-ChildItem -LiteralPath $usersRoot -Directory -Force -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -notin @('All Users','Default','Default User','Public','defaultuser0') -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
    })
    $chromiumRoots = @(
        'Yandex\YandexBrowser\User Data','Google\Chrome\User Data','Microsoft\Edge\User Data',
        'BraveSoftware\Brave-Browser\User Data','Vivaldi\User Data','Chromium\User Data'
    )
    $profileCacheNames = @('Cache','Code Cache','GPUCache','DawnCache','GrShaderCache')
    foreach ($userRoot in $userRoots) {
        $local = Join-Path $userRoot.FullName 'AppData\Local'
        $roaming = Join-Path $userRoot.FullName 'AppData\Roaming'
        $targets.Add((Join-Path $local 'Temp'))
        $targets.Add((Join-Path $local 'CrashDumps'))
        $targets.Add((Join-Path $local 'Microsoft\Windows\Explorer'))
        foreach ($relativeBrowserRoot in $chromiumRoots) {
            $browserRoot = Join-Path $local $relativeBrowserRoot
            foreach ($rootCache in @('ShaderCache','GrShaderCache','DawnCache')) { $targets.Add((Join-Path $browserRoot $rootCache)) }
            $browserProfiles = @(Get-ChildItem -LiteralPath $browserRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' -or $_.Name -in @('Guest Profile','System Profile') })
            foreach ($browserProfile in $browserProfiles) {
                foreach ($cacheName in $profileCacheNames) { $targets.Add((Join-Path $browserProfile.FullName $cacheName)) }
            }
        }
        $firefoxProfiles = @(Get-ChildItem -LiteralPath (Join-Path $local 'Mozilla\Firefox\Profiles') -Directory -ErrorAction SilentlyContinue)
        foreach ($firefoxProfile in $firefoxProfiles) { $targets.Add((Join-Path $firefoxProfile.FullName 'cache2')); $targets.Add((Join-Path $firefoxProfile.FullName 'startupCache')) }
        foreach ($operaProfile in @('Opera Software\Opera Stable','Opera Software\Opera GX Stable')) {
            $operaRoot = Join-Path $roaming $operaProfile
            foreach ($cacheName in $profileCacheNames) { $targets.Add((Join-Path $operaRoot $cacheName)) }
        }
    }
    @($targets | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Invoke-SafeCleanup {
    Write-ServiceLog 'Safe cleanup started.'
    $bytes = 0L
    foreach ($target in @(Get-CacheTargets | Select-Object -Unique)) {
        try { $bytes += Remove-DirectoryContentsSafely $target } catch { Write-ServiceLog "Skipped $target : $($_.Exception.Message)" }
    }
    try { if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) { Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue } } catch { }
    try { Clear-RecycleBin -Force -ErrorAction SilentlyContinue } catch { }
    Write-ServiceLog ('Safe cleanup finished; approximately {0:N1} MiB processed. History, cookies, passwords, bookmarks and personal files were not targeted.' -f ($bytes / 1MB))
    $bytes
}

function Update-ZapretDataLists {
    if (-not (Test-Path -LiteralPath $ZapretRoot)) { Write-ServiceLog 'Zapret is not installed; list update skipped.'; return }
    $listRoot = Join-Path $ZapretRoot 'lists'
    Ensure-Directory $listRoot
    $names = @('list-general.txt','list-exclude.txt','ipset-all.txt','ipset-exclude.txt')
    $client = New-Object Net.WebClient
    $client.Headers['User-Agent'] = 'SeniorLaptopService/0.9'
    foreach ($name in $names) {
        try {
            $url = "https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/lists/$name"
            $temp = Join-Path $env:TEMP ([guid]::NewGuid().ToString('N') + '.txt')
            $client.DownloadFile($url, $temp)
            if ((Get-Item $temp).Length -lt 10) { throw 'Downloaded list is unexpectedly small.' }
            Move-Item -LiteralPath $temp -Destination (Join-Path $listRoot $name) -Force
            Write-ServiceLog "Zapret list updated: $name"
        } catch { Write-ServiceLog "Zapret list update failed for $name : $($_.Exception.Message)" }
    }
    $client.Dispose()
}

function Stop-ZapretForUpdate {
    Write-ServiceLog 'Stopping existing Zapret components before file replacement...'
    foreach ($serviceName in @('zapret','WinDivert','WinDivert14')) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($null -ne $service -and $service.Status -ne 'Stopped') {
            try { & sc.exe stop $serviceName 2>$null | Out-Null } catch { }
            for ($wait=0; $wait -lt 20; $wait++) {
                $currentService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
                if ($null -eq $currentService -or $currentService.Status -eq 'Stopped') { break }
                Start-Sleep -Milliseconds 500
            }
        }
    }
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -in @('winws.exe','winws2.exe') -and [string]$_.ExecutablePath -like "$ZapretRoot*"
    } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    $lockedFile = Join-Path $ZapretRoot 'bin\cygwin1.dll'
    if (Test-Path -LiteralPath $lockedFile) {
        $released = $false
        for ($attempt=0; $attempt -lt 20; $attempt++) {
            try {
                $stream=[IO.File]::Open($lockedFile,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
                $stream.Dispose(); $released=$true; break
            } catch { Start-Sleep -Milliseconds 500 }
        }
        if (-not $released) { throw 'Файлы Zapret остаются заняты после остановки службы. Перезагрузите компьютер и повторите обновление.' }
    }
    Write-ServiceLog 'Existing Zapret components stopped; files are ready for replacement.'
}

function Remove-ZapretInstallation([bool]$RemoveFiles = $true) {
    Write-ServiceLog 'Removing previous Zapret installation completely...'
    Stop-ZapretForUpdate
    foreach ($serviceName in @('zapret','WinDivert','WinDivert14')) {
        try { & sc.exe delete $serviceName 2>$null | Out-Null } catch { }
    }
    Start-Sleep -Seconds 1
    if ($RemoveFiles -and (Test-Path -LiteralPath $ZapretRoot)) {
        $resolvedRoot = [IO.Path]::GetFullPath($ZapretRoot).TrimEnd('\')
        if ($resolvedRoot.Length -lt 8 -or (Split-Path $resolvedRoot -Leaf) -ne 'zapret') { throw "Отказ удаления небезопасного пути Zapret: $resolvedRoot" }
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force -ErrorAction Stop
    }
    if ($RemoveFiles) { Write-ServiceLog 'Previous Zapret service and files removed.' }
    else { Write-ServiceLog 'Previous Zapret service removed; matching portable files preserved.' }
}

function Get-ZapretRegisteredStrategy {
    try {
        $serviceKey = Get-ItemProperty -LiteralPath 'HKLM:\System\CurrentControlSet\Services\zapret' -ErrorAction Stop
        $strategyProperty = $serviceKey.PSObject.Properties['zapret-discord-youtube']
        if ($null -eq $strategyProperty) { return '' }
        return [string]$strategyProperty.Value
    } catch { return '' }
}

function Install-ZapretStrategy([string]$RootPath, [int]$StrategyIndex) {
    $serviceBat = Join-Path $RootPath 'service.bat'
    if (-not (Test-Path -LiteralPath $serviceBat)) { throw 'service.bat не найден после установки Zapret.' }
    $strategyFiles = @(Get-ChildItem -LiteralPath $RootPath -Filter '*.bat' -File | Where-Object { $_.Name -notlike 'service*' } | Sort-Object { [Regex]::Replace($_.Name,'(\d+)',{ $args[0].Value.PadLeft(8,'0') }) })
    if ($StrategyIndex -lt 1 -or $StrategyIndex -gt $strategyFiles.Count) { throw "Стратегия Zapret №$StrategyIndex отсутствует; найдено стратегий: $($strategyFiles.Count)." }
    $selectedStrategy = $strategyFiles[$StrategyIndex - 1].Name
    Write-ServiceLog "Zapret: automatic service installation, strategy #$StrategyIndex = $selectedStrategy"
    # The upstream installer pauses and returns to its interactive menu even after
    # a successful installation.  A private temporary copy exits at that exact
    # point, so redirected input cannot leave a hidden cmd.exe waiting forever.
    $automaticServiceBat = Join-Path $RootPath 'service-sls-automatic.bat'
    $serviceText = [IO.File]::ReadAllText($serviceBat,[Text.Encoding]::Default)
    $entryPattern = '(?m)^(setlocal EnableDelayedExpansion)\s*$'
    $entryReplacement = '${1}' + "`r`ngoto service_install"
    $automaticText = [Regex]::Replace($serviceText,$entryPattern,$entryReplacement,1)
    # Flowseal changed the prompt wording between 1.9.8 and 1.9.9; match the
    # strategy variable itself instead of depending on human-readable text.
    $choicePattern = '(?m)^set "choice="\s*\r?\nset /p "choice=[^"]*"\s*$'
    $choiceReplacement = 'set "choice=' + $StrategyIndex + '"'
    $automaticText = [Regex]::Replace($automaticText,$choicePattern,$choiceReplacement,1)
    $completionPattern = '(?ms)(reg add\s+"HKLM\\System\\CurrentControlSet\\Services\\zapret"\s+/v\s+zapret-discord-youtube.*?\r?\n)\s*\r?\n?pause\s*\r?\ngoto menu'
    $completionReplacement = '${1}' + "`r`nexit /b 0"
    $automaticText = [Regex]::Replace($automaticText,$completionPattern,$completionReplacement,1)
    if ($automaticText -eq $serviceText -or $automaticText -notmatch '(?m)^goto service_install\s*$' -or $automaticText -notmatch ('(?m)^set "choice=' + $StrategyIndex + '"\s*$') -or $automaticText -notmatch '(?m)^exit /b 0\s*$') { throw 'Не удалось подготовить автоматический режим service.bat: структура файла изменилась.' }
    [IO.File]::WriteAllText($automaticServiceBat,$automaticText,[Text.Encoding]::Default)
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'cmd.exe'
    $startInfo.Arguments = '/d /c ""' + $automaticServiceBat + '" admin"'
    $startInfo.WorkingDirectory = $RootPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Не удалось запустить service.bat.' }
        $installedInTime = $false
        $lastServiceState = 'Absent'
        $lastServicePid = 0
        $lastServicePath = ''
        $lastExitCode = $null
        $lastServiceExitCode = $null
        $manualStartAt = $null
        $installTimer = [Diagnostics.Stopwatch]::StartNew()
        while ($installTimer.Elapsed.TotalSeconds -lt 15) {
            [Windows.Forms.Application]::DoEvents()
            $currentService = Get-CimInstance Win32_Service -Filter "Name='zapret'" -ErrorAction SilentlyContinue
            if ($null -ne $currentService) {
                $lastServiceState = [string]$currentService.State
                $lastServicePid = [int64]$currentService.ProcessId
                $lastServicePath = [string]$currentService.PathName
                $lastExitCode = $currentService.ExitCode
                $lastServiceExitCode = $currentService.ServiceSpecificExitCode
                $expectedWinws = Join-Path $RootPath 'bin\winws.exe'
                if ($lastServiceState -eq 'Running' -and $lastServicePid -gt 0 -and $lastServicePath.IndexOf($expectedWinws,[StringComparison]::OrdinalIgnoreCase) -ge 0) { $installedInTime = $true; break }
            }
            if ($process.HasExited -and $process.ExitCode -ne 0) { throw "service.bat завершился с кодом $($process.ExitCode)." }
            if ($process.HasExited -and $process.ExitCode -eq 0 -and $null -ne $currentService -and $lastServiceState -eq 'Stopped') {
                if ($null -eq $manualStartAt) { try { & sc.exe start zapret 2>&1 | ForEach-Object { Write-ServiceLog "sc start: $_" } } catch { Write-ServiceLog "sc start exception: $($_.Exception.Message)" }; $manualStartAt = $installTimer.Elapsed.TotalSeconds }
                elseif (($installTimer.Elapsed.TotalSeconds - [double]$manualStartAt) -ge 5) { break }
            }
            Start-Sleep -Milliseconds 250
        }
        $installTimer.Stop()
        if (-not $process.HasExited) { try { $process.Kill() } catch { } }
        if (-not $installedInTime) {
            $installerState = if ($process.HasExited) { "завершён, код $($process.ExitCode)" } else { 'не завершён' }
            try { $registryImagePath = [string](Get-ItemProperty -LiteralPath 'HKLM:\System\CurrentControlSet\Services\zapret' -ErrorAction Stop).ImagePath } catch { $registryImagePath = '' }
            throw "Стратегия Zapret №$StrategyIndex не запустила службу. State=$lastServiceState; PID=$lastServicePid; PathName=$lastServicePath; ImagePath=$registryImagePath; Win32ExitCode=$lastExitCode; ServiceExitCode=$lastServiceExitCode; установщик: $installerState."
        }
        Write-ServiceLog "Zapret strategy #$StrategyIndex became active after $([math]::Round($installTimer.Elapsed.TotalSeconds,1)) seconds; installer menu closed."
    } finally {
        $process.Dispose()
        Remove-Item -LiteralPath $automaticServiceBat -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2
    $service = Get-CimInstance Win32_Service -Filter "Name='zapret'" -ErrorAction SilentlyContinue
    if ($null -eq $service -or $service.State -ne 'Running' -or [int64]$service.ProcessId -le 0) { throw 'Служба zapret не запущена после автоматической установки.' }
    $installedStrategy = Get-ZapretRegisteredStrategy
    Write-ServiceLog "Zapret service is running. Requested: $selectedStrategy; registered: $installedStrategy"
    [ordered]@{ index=$StrategyIndex; requested=$selectedStrategy; registered=$installedStrategy; service_status=[string]$service.State; service_pid=[int64]$service.ProcessId; service_path=[string]$service.PathName; total=$strategyFiles.Count }
}

function Test-WebEndpointResponsive([string]$Url, [int]$TimeoutSeconds = 30) {
    Add-Type -AssemblyName System.Net.Http
    $client = [Net.Http.HttpClient]::new()
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('Mozilla/5.0 SeniorLaptopService-YouTube-Test/1')
    $task = $client.GetAsync($Url,[Net.Http.HttpCompletionOption]::ResponseHeadersRead)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $response = $null
    try {
        while (-not $task.IsCompleted) {
            [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50
            if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { $client.CancelPendingRequests(); return $false }
        }
        if ($task.IsCanceled -or $task.IsFaulted) { return $false }
        $response = $task.Result
        return ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 400)
    } finally {
        $timer.Stop(); if ($null -ne $response) { $response.Dispose() }; $client.Dispose()
    }
}

function Test-YouTubeMediaStream([string]$VideoId = 'LNrBbGcLhXg', [int]$TimeoutSeconds = 25) {
    try {
        $headers = @{ 'User-Agent'='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126 Safari/537.36'; 'Accept-Language'='ru-RU,ru;q=0.9,en;q=0.7' }
        $watchUrl = "https://www.youtube.com/watch?v=$VideoId"
        $watch = Invoke-WebRequest -Uri $watchUrl -Headers $headers -UseBasicParsing -TimeoutSec $TimeoutSeconds
        $html = [string]$watch.Content
        $keyMatch = [Regex]::Match($html,'"INNERTUBE_API_KEY"\s*:\s*"([^"]+)"')
        $versionMatch = [Regex]::Match($html,'"INNERTUBE_CLIENT_VERSION"\s*:\s*"([^"]+)"')
        if (-not $keyMatch.Success -or -not $versionMatch.Success) { Write-ServiceLog 'YouTube stream test: player API parameters not found.'; return 'VerificationBlocked' }
        $body = @{ videoId=$VideoId; context=@{ client=@{ clientName='WEB'; clientVersion=$versionMatch.Groups[1].Value; hl='ru'; gl='RU' } }; contentCheckOk=$true; racyCheckOk=$true } | ConvertTo-Json -Depth 6 -Compress
        $player = Invoke-RestMethod -Method Post -Uri ("https://www.youtube.com/youtubei/v1/player?key=" + $keyMatch.Groups[1].Value) -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec $TimeoutSeconds
        $playability = [string]$player.playabilityStatus.status
        if ($playability -eq 'LOGIN_REQUIRED') { Write-ServiceLog "YouTube stream verification blocked by anti-bot/login requirement: $($player.playabilityStatus.reason)"; return 'VerificationBlocked' }
        if ($playability -ne 'OK') { Write-ServiceLog "YouTube stream test: playability=$playability; reason=$($player.playabilityStatus.reason)."; return 'Failed' }
        $formats = @($player.streamingData.adaptiveFormats) + @($player.streamingData.formats)
        $mediaUrl = $formats | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.url) } | Sort-Object { [int64]$_.bitrate } -Descending | Select-Object -First 1 -ExpandProperty url
        if ([string]::IsNullOrWhiteSpace($mediaUrl)) { Write-ServiceLog 'YouTube stream test: direct media URL not supplied.'; return 'VerificationBlocked' }
        $probe = Join-Path $env:TEMP ('sls-youtube-stream-' + [guid]::NewGuid().ToString('N') + '.bin')
        try {
            Invoke-WebRequest -Uri $mediaUrl -Headers (@{ 'User-Agent'=$headers['User-Agent']; 'Range'='bytes=0-262143' }) -UseBasicParsing -TimeoutSec $TimeoutSeconds -OutFile $probe
            $received = if (Test-Path -LiteralPath $probe) { (Get-Item -LiteralPath $probe).Length } else { 0 }
            Write-ServiceLog "YouTube media stream probe received $received bytes."
            if ($received -ge 65536) { return 'Working' }
            return 'Failed'
        } finally { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue }
    } catch {
        Write-ServiceLog "YouTube media stream probe failed: $($_.Exception.Message)"
        return 'Failed'
    }
}

function Invoke-ReliableZipDownload([string[]]$Urls, [string]$Destination, [string]$ExpectedSha256) {
    $lastError = 'unknown download error'
    for ($attempt=1; $attempt -le 3; $attempt++) {
        foreach ($downloadUrl in $Urls) {
            try {
                Write-ServiceLog "Zapret archive download attempt $attempt/3 via $(([Uri]$downloadUrl).Host)..."
                Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
                $downloadHeaders = @{ 'User-Agent'='SeniorLaptopService/0.22'; 'Accept' = if ($downloadUrl -like 'https://api.github.com/*/contents/*') { 'application/vnd.github.raw+json' } elseif ($downloadUrl -like 'https://api.github.com/*') { 'application/octet-stream' } else { 'application/zip,application/octet-stream' } }
                Invoke-WebRequest -Uri $downloadUrl -Headers $downloadHeaders -OutFile $Destination -UseBasicParsing -TimeoutSec 90
                if (-not (Test-Path -LiteralPath $Destination)) { throw 'Файл не был создан.' }
                $file = Get-Item -LiteralPath $Destination
                if ($file.Length -lt 100KB) { throw "Получен неполный архив размером $($file.Length) байт." }
                $stream = [IO.File]::OpenRead($Destination)
                try { $first=$stream.ReadByte(); $second=$stream.ReadByte() } finally { $stream.Dispose() }
                if ($first -ne 0x50 -or $second -ne 0x4B) { throw 'Загруженный файл не имеет сигнатуры ZIP.' }
                $actualSha256 = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
                if ($ExpectedSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or $actualSha256 -ne $ExpectedSha256) { throw "SHA-256 архива Zapret не совпала. Получено: $actualSha256" }
                Write-ServiceLog "Zapret archive downloaded and validated: $($file.Length) bytes."
                return
            } catch {
                $lastError = $_.Exception.Message
                Write-ServiceLog "Zapret download attempt failed: $lastError"
            }
        }
        if ($attempt -lt 3) { for ($wait=0; $wait -lt (2*$attempt*10); $wait++) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 } }
    }
    Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    throw "Не удалось скачать полный архив Zapret после повторных попыток. Последняя ошибка: $lastError"
}

function Get-NonEdgeDefaultBrowser {
    $browserExe = ''
    try {
        $choice = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice' -ErrorAction Stop
        $progIdProperty = $choice.PSObject.Properties['ProgId']
        if ($null -ne $progIdProperty) {
            $commandKey = Get-ItemProperty -LiteralPath ("Registry::HKEY_CLASSES_ROOT\" + [string]$progIdProperty.Value + '\shell\open\command') -ErrorAction Stop
            $commandProperty = $commandKey.PSObject.Properties['(default)']
            if ($null -ne $commandProperty) {
                $commandText = [string]$commandProperty.Value
                $match = [Regex]::Match($commandText,'^\s*"([^"]+\.exe)"|^\s*([^\s]+\.exe)')
                if ($match.Success) { $browserExe = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value } }
            }
        }
    } catch { }
    if (-not [string]::IsNullOrWhiteSpace($browserExe) -and (Test-Path -LiteralPath $browserExe) -and [IO.Path]::GetFileName($browserExe) -ne 'msedge.exe') { return $browserExe }
    $fallbacks = @(
        (Join-Path $env:LOCALAPPDATA 'Yandex\YandexBrowser\Application\browser.exe'),
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:ProgramFiles 'Mozilla Firefox\firefox.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Mozilla Firefox\firefox.exe')
    )
    @($fallbacks | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) }) | Select-Object -First 1
}

function Invoke-YouTubeVisualTest([string]$Url, [int]$DurationSeconds = 45) {
    $browserExe = Get-NonEdgeDefaultBrowser
    if ([string]::IsNullOrWhiteSpace($browserExe)) { throw 'Для проверки нужен браузер по умолчанию, отличный от Microsoft Edge. Установите Яндекс Браузер, Chrome или Firefox.' }
    $testMarker = 'SeniorLaptopService-YouTube-' + [guid]::NewGuid().ToString('N')
    $testProfile = Join-Path $env:TEMP $testMarker
    Ensure-Directory $testProfile
    $browserProcessName = [IO.Path]::GetFileNameWithoutExtension($browserExe)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $connectionOk = $false
    try {
        $arguments = if ([IO.Path]::GetFileName($browserExe) -eq 'firefox.exe') { @('-new-instance','-profile',"`"$testProfile`"",'-new-window',$Url) } else { @("--user-data-dir=`"$testProfile`"",'--new-window','--no-first-run','--autoplay-policy=no-user-gesture-required',$Url) }
        Start-Process -FilePath $browserExe -ArgumentList $arguments | Out-Null
        Write-ServiceLog "YouTube test opened in $([IO.Path]::GetFileName($browserExe)) for $DurationSeconds seconds. Edge is excluded; system audio settings are unchanged."
        $connectionOk = Test-WebEndpointResponsive $Url ([math]::Min(30,$DurationSeconds))
        while ($timer.Elapsed.TotalSeconds -lt $DurationSeconds) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
    } finally {
        $timer.Stop()
        Get-CimInstance Win32_Process -Filter "Name='$browserProcessName.exe'" -ErrorAction SilentlyContinue | Where-Object { [string]$_.CommandLine -like "*$testMarker*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 500
        try {
            $resolvedTemp = (Resolve-Path -LiteralPath $env:TEMP).Path.TrimEnd('\')
            $resolvedProfile = (Resolve-Path -LiteralPath $testProfile -ErrorAction Stop).Path
            if ($resolvedProfile.StartsWith($resolvedTemp + '\',[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolvedProfile -Leaf) -like 'SeniorLaptopService-YouTube-*') { Remove-Item -LiteralPath $resolvedProfile -Recurse -Force -ErrorAction SilentlyContinue }
        } catch { }
    }
    if (-not $connectionOk) { throw "YouTube не подтвердил соединение за $DurationSeconds секунд. Тестовое окно закрыто." }
    Write-ServiceLog "YouTube connection test passed; test window closed automatically after $DurationSeconds seconds."
    return $true
}

function Invoke-MaintenanceMode {
    Invoke-SafeCleanup | Out-Null
    if ($UpdateZapretLists) { Update-ZapretDataLists }
}

function New-TechnicalReport {
    Write-ServiceLog 'Отчёт: сведения о Windows и компьютере...'
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    [Windows.Forms.Application]::DoEvents()
    Write-ServiceLog 'Отчёт: процессор и диски...'
    $cpu = @(Get-CimInstance Win32_Processor | ForEach-Object { [ordered]@{ name=$_.Name; cores=$_.NumberOfCores; logical_processors=$_.NumberOfLogicalProcessors } })
    $disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { [ordered]@{ drive=$_.DeviceID; size_bytes=[int64]$_.Size; free_bytes=[int64]$_.FreeSpace } })
    $board = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue | Select-Object -First 1
    $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue | Select-Object -First 1
    $enclosure = Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue | Select-Object -First 1
    $memoryModules = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue | ForEach-Object { [ordered]@{ capacity_bytes=[int64]$_.Capacity; manufacturer=[string]$_.Manufacturer; part_number=([string]$_.PartNumber).Trim(); speed_mhz=[int]$_.Speed; configured_speed_mhz=[int]$_.ConfiguredClockSpeed; device_locator=[string]$_.DeviceLocator; bank_label=[string]$_.BankLabel } })
    $physicalDisks = @(Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue | ForEach-Object { [ordered]@{ model=[string]$_.Model; size_bytes=[int64]$_.Size; interface=[string]$_.InterfaceType; media_type=[string]$_.MediaType; firmware=[string]$_.FirmwareRevision } })
    $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
    $batteryStatic = Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction SilentlyContinue | Select-Object -First 1
    $batteryFull = Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue | Select-Object -First 1
    $batteryCycles = Get-CimInstance -Namespace root\wmi -ClassName BatteryCycleCount -ErrorAction SilentlyContinue | Select-Object -First 1
    [Windows.Forms.Application]::DoEvents()
    Write-ServiceLog 'Отчёт: последние ошибки Windows (без медленной расшифровки текста)...'
    $events = @()
    foreach ($eventLogName in @('System','Application')) {
        $logEvents = @(Get-WinEvent -FilterHashtable @{ LogName=$eventLogName; Level=@(1,2,3) } -MaxEvents 25 -ErrorAction SilentlyContinue)
        $events += @($logEvents | ForEach-Object {
            [ordered]@{ time_utc=$_.TimeCreated.ToUniversalTime().ToString('o'); log=$_.LogName; provider=$_.ProviderName; event_id=$_.Id; level=$_.LevelDisplayName; record_id=$_.RecordId }
        })
        [Windows.Forms.Application]::DoEvents()
    }
    Write-ServiceLog 'Отчёт: список установленных программ...'
    $apps = @(Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace([string](Get-SafeProperty $_ 'DisplayName')) } | Sort-Object { [string](Get-SafeProperty $_ 'DisplayName') } -Unique | ForEach-Object { [ordered]@{ name=(Get-SafeProperty $_ 'DisplayName'); version=(Get-SafeProperty $_ 'DisplayVersion'); publisher=(Get-SafeProperty $_ 'Publisher') } })
    $serviceLog = @()
    $latestLog = Get-ChildItem $LogRoot -Filter '*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($null -ne $latestLog) {
        $serviceLog = @(Get-Content -LiteralPath $latestLog.FullName -Tail 150 -ErrorAction SilentlyContinue | ForEach-Object {
            $plainLine = [string]::Concat('',[string]$_)
            if ($plainLine.Length -gt 2000) { $plainLine = $plainLine.Substring(0,2000) + '…[обрезано]' }
            [string]::Concat('', $plainLine)
        })
    }
    Write-ServiceLog 'Отчёт: сбор данных завершён.'
    [ordered]@{
        schema='senior-laptop-service-report/1'
        created_at_utc=(Get-Date).ToUniversalTime().ToString('o')
        privacy=[ordered]@{ wifi_credentials_included=$false; browser_history_included=$false; cookies_included=$false; personal_files_included=$false; hardware_serials_included=$false }
        application=[ordered]@{ name=$AppName; version=$AppVersion; recent_log=$serviceLog }
        system=[ordered]@{ manufacturer=$cs.Manufacturer; model=$cs.Model; system_family=(Get-SafeProperty $cs 'SystemFamily'); system_sku=(Get-SafeProperty $cs 'SystemSKUNumber'); total_memory_bytes=[int64]$cs.TotalPhysicalMemory; os=$os.Caption; os_version=$os.Version; build=$os.BuildNumber; last_boot_utc=$os.LastBootUpTime.ToUniversalTime().ToString('o'); cpu=$cpu; disks=$disks; baseboard=[ordered]@{ manufacturer=(Get-SafeProperty $board 'Manufacturer'); product=(Get-SafeProperty $board 'Product'); version=(Get-SafeProperty $board 'Version') }; bios=[ordered]@{ manufacturer=(Get-SafeProperty $bios 'Manufacturer'); version=(Get-SafeProperty $bios 'SMBIOSBIOSVersion'); release_date=(Get-SafeProperty $bios 'ReleaseDate') }; enclosure=[ordered]@{ manufacturer=(Get-SafeProperty $enclosure 'Manufacturer'); model=(Get-SafeProperty $enclosure 'Model'); sku=(Get-SafeProperty $enclosure 'SKU'); chassis_types=@(Get-SafeProperty $enclosure 'ChassisTypes') }; installed_memory_modules=$memoryModules; physical_disks=$physicalDisks; battery=[ordered]@{ present=($null -ne $battery); name=(Get-SafeProperty $battery 'Name'); status=(Get-SafeProperty $battery 'Status'); estimated_charge_percent=(Get-SafeProperty $battery 'EstimatedChargeRemaining'); design_capacity_mwh=(Get-SafeProperty $batteryStatic 'DesignedCapacity'); full_charge_capacity_mwh=(Get-SafeProperty $batteryFull 'FullChargedCapacity'); cycle_count=(Get-SafeProperty $batteryCycles 'CycleCount') } }
        installed_programs=$apps
        recent_windows_errors=$events
    }
}

function Show-PasswordPrompt([string]$Title, [string]$Prompt) {
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text=$Title; $dialog.Size=New-Object Drawing.Size(470,170); $dialog.StartPosition='CenterParent'; $dialog.FormBorderStyle='FixedDialog'; $dialog.MaximizeBox=$false; $dialog.MinimizeBox=$false
    $label=New-Object Windows.Forms.Label; $label.Text=$Prompt; $label.SetBounds(15,15,425,42)
    $box=New-Object Windows.Forms.TextBox; $box.UseSystemPasswordChar=$true; $box.SetBounds(15,60,425,25)
    $ok=New-Object Windows.Forms.Button; $ok.Text='Отправить'; $ok.DialogResult='OK'; $ok.SetBounds(275,95,80,30)
    $cancel=New-Object Windows.Forms.Button; $cancel.Text='Отмена'; $cancel.DialogResult='Cancel'; $cancel.SetBounds(360,95,80,30)
    $dialog.Controls.AddRange(@($label,$box,$ok,$cancel)); $dialog.AcceptButton=$ok; $dialog.CancelButton=$cancel
    if ($dialog.ShowDialog($form) -eq 'OK') { $value=$box.Text; $dialog.Dispose(); return $value }
    $dialog.Dispose(); $null
}

function Get-PortableReportToken([switch]$AllowSetup) {
    if (Test-Path -LiteralPath $ReportTokenPath) {
        $stored = ([IO.File]::ReadAllText($ReportTokenPath,[Text.Encoding]::UTF8)).Trim()
        if (-not [string]::IsNullOrWhiteSpace($stored)) { return $stored }
    }
    $environmentToken = [Environment]::GetEnvironmentVariable('SLS_GITHUB_TOKEN','Process')
    if (-not [string]::IsNullOrWhiteSpace($environmentToken)) { return $environmentToken }
    if (-not $AllowSetup) { return $null }
    $token = Show-PasswordPrompt 'Настройка GitHub-отчётов' 'Введите fine-grained GitHub token: только репозиторий senior-laptop-service-reports, Contents: Read and write. Токен будет сохранён на этой флешке.'
    if ([string]::IsNullOrWhiteSpace($token)) { return $null }
    Ensure-Directory $PortableSecretRoot
    [IO.File]::WriteAllText($ReportTokenPath,$token.Trim(),[Text.UTF8Encoding]::new($false))
    try { (Get-Item -LiteralPath $PortableSecretRoot).Attributes = (Get-Item -LiteralPath $PortableSecretRoot).Attributes -bor [IO.FileAttributes]::Hidden; (Get-Item -LiteralPath $ReportTokenPath).Attributes = (Get-Item -LiteralPath $ReportTokenPath).Attributes -bor [IO.FileAttributes]::Hidden } catch { }
    Write-ServiceLog "Portable report credential configured: $ReportTokenPath"
    $token.Trim()
}

function Invoke-ResponsiveGitHubRequest([string]$Method, [string]$Uri, [string]$Token, [string]$JsonBody = $null, [int]$TimeoutSeconds = 45) {
    Add-Type -AssemblyName System.Net.Http
    $client = [Net.Http.HttpClient]::new()
    $client.DefaultRequestHeaders.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$Token)
    $client.DefaultRequestHeaders.Accept.ParseAdd('application/vnd.github+json')
    $client.DefaultRequestHeaders.Add('X-GitHub-Api-Version','2022-11-28')
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('SeniorLaptopService/0.13')
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method),$Uri)
    if (-not [string]::IsNullOrEmpty($JsonBody)) { $request.Content = [Net.Http.StringContent]::new($JsonBody,[Text.Encoding]::UTF8,'application/json') }
    $task = $client.SendAsync($request)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $response = $null
    try {
        while (-not $task.IsCompleted) {
            [Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 40
            if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                $client.CancelPendingRequests()
                throw "GitHub не ответил за $TimeoutSeconds секунд. Проверьте соединение и повторите отправку."
            }
        }
        if ($task.IsCanceled) { throw 'Отправка отчёта отменена.' }
        if ($task.IsFaulted) { throw ('Ошибка соединения с GitHub: ' + $task.Exception.GetBaseException().Message) }
        $response = $task.Result
        $readTask = $response.Content.ReadAsStringAsync()
        while (-not $readTask.IsCompleted) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 20 }
        $responseText = $readTask.Result
        if (-not $response.IsSuccessStatusCode) {
            throw ('GitHub HTTP {0} ({1}): {2}' -f [int]$response.StatusCode,$response.ReasonPhrase,$responseText)
        }
        if ([string]::IsNullOrWhiteSpace($responseText)) { return $null }
        return ($responseText | ConvertFrom-Json)
    } finally {
        $timer.Stop()
        if ($null -ne $response) { $response.Dispose() }
        $request.Dispose()
        $client.Dispose()
    }
}

function Send-ReportToGitHub([string]$ReportPath, [string]$Token, [string]$Category = 'reports') {
    $repo = 'hatory42-oss/senior-laptop-service-reports'
    $safeComputer = ($env:COMPUTERNAME -replace '[^A-Za-z0-9._-]','_')
    $extension = [IO.Path]::GetExtension($ReportPath).ToLowerInvariant()
    if ($extension -notin @('.json','.txt')) { $extension = '.dat' }
    $safeCategory = if ($Category -eq 'errors') { 'errors' } else { 'reports' }
    $remotePath = '{0}/{1}/{2}/{3}-{4}{5}' -f $safeCategory,(Get-Date -Format 'yyyy'),(Get-Date -Format 'MM'),$safeComputer,(Get-Date -Format 'yyyyMMdd-HHmmssfff'),$extension
    $bytes = [IO.File]::ReadAllBytes($ReportPath)
    $body = @{ message="Add diagnostic report from $safeComputer"; content=[Convert]::ToBase64String($bytes); branch='main' } | ConvertTo-Json
    try {
        Write-ServiceLog 'Проверка доступа к приватному репозиторию GitHub...'
        $access = Invoke-ResponsiveGitHubRequest 'GET' "https://api.github.com/repos/$repo" $Token $null 30
    } catch {
        throw ('GitHub access check failed. Use a fine-grained token for repository senior-laptop-service-reports with Contents: Read and write.' + [Environment]::NewLine + (Get-HttpErrorDetails $_))
    }
    if (-not $access.private) { throw 'Safety check failed: reports repository is not private.' }
    $uri = "https://api.github.com/repos/$repo/contents/$remotePath"
    try {
        Write-ServiceLog 'Передача отчёта в GitHub...'
        $result = Invoke-ResponsiveGitHubRequest 'PUT' $uri $Token $body 60
    } catch {
        throw ('GitHub upload failed. Confirm that Contents permission is Read and write and the token has access to senior-laptop-service-reports.' + [Environment]::NewLine + (Get-HttpErrorDetails $_))
    }
    [ordered]@{ path=$remotePath; url=$result.content.html_url; commit=$result.commit.sha }
}

function Get-ResponsiveHttpsBytes([string]$Url, [int]$TimeoutSeconds = 30) {
    if (-not $Url.StartsWith('https://')) { throw 'Разрешены только HTTPS-запросы.' }
    Add-Type -AssemblyName System.Net.Http
    $handler = [Net.Http.HttpClientHandler]::new()
    $client = [Net.Http.HttpClient]::new($handler)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('SeniorLaptopService-Updater/1')
    $client.DefaultRequestHeaders.Accept.ParseAdd('application/vnd.github.raw+json')
    $client.DefaultRequestHeaders.CacheControl = [Net.Http.Headers.CacheControlHeaderValue]::new()
    $client.DefaultRequestHeaders.CacheControl.NoCache = $true
    $task = $client.GetByteArrayAsync($Url)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        while (-not $task.IsCompleted) {
            [Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 40
            if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                $client.CancelPendingRequests()
                throw "Сервер обновлений не ответил за $TimeoutSeconds секунд. Проверьте интернет и повторите попытку."
            }
        }
        if ($task.IsCanceled) { throw 'Проверка обновлений была отменена.' }
        if ($task.IsFaulted) { throw ('Ошибка соединения с сервером обновлений: ' + $task.Exception.GetBaseException().Message) }
        return $task.Result
    } finally {
        $timer.Stop()
        $client.Dispose()
        $handler.Dispose()
    }
}

function Get-GitHubApiFallbackUrl([string]$Url) {
    $uri = [Uri]$Url
    if ($uri.Host -ne 'raw.githubusercontent.com') { return $null }
    if ($uri.AbsolutePath -notmatch '^/([^/]+)/([^/]+)/([^/]+)/(.*)$') { return $null }
    $owner=$matches[1]; $repo=$matches[2]; $branch=$matches[3]; $path=$matches[4]
    "https://api.github.com/repos/$owner/$repo/contents/${path}?ref=$branch"
}

function Get-UpdateBytesWithFallback([string]$Url, [int]$PrimaryTimeoutSeconds, [int]$FallbackTimeoutSeconds) {
    try { return Get-ResponsiveHttpsBytes $Url $PrimaryTimeoutSeconds }
    catch {
        $primaryError = $_.Exception.Message
        $fallbackUrl = Get-GitHubApiFallbackUrl $Url
        if ([string]::IsNullOrWhiteSpace($fallbackUrl)) { throw }
        Write-ServiceLog "RAW GitHub unavailable ($primaryError). Retrying through GitHub API..."
        return Get-ResponsiveHttpsBytes $fallbackUrl $FallbackTimeoutSeconds
    }
}

function Invoke-SelfUpdate {
    $configPath = Join-Path $PSScriptRoot 'Updater.json'
    if (-not (Test-Path $configPath)) { throw 'Updater.json не найден. Укажите URL манифеста обновлений.' }
    $config = Get-Content -Raw $configPath | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($config.manifest_url) -or $config.manifest_url -like '*CHANGE-ME*') { throw 'В Updater.json ещё не указан реальный manifest_url.' }
    if (-not $config.manifest_url.StartsWith('https://')) { throw 'Обновления разрешены только через HTTPS.' }
    Write-ServiceLog "Checking update manifest: $($config.manifest_url)"
    $nonce = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $manifestSeparator = if ($config.manifest_url.Contains('?')) { '&' } else { '?' }
    $manifestRequestUrl = $config.manifest_url + $manifestSeparator + 'nocache=' + $nonce
    Write-ServiceLog 'Получение сведений об актуальной версии...'
    $manifestBytes = Get-UpdateBytesWithFallback $manifestRequestUrl 20 45
    $manifestText = [Text.Encoding]::UTF8.GetString($manifestBytes)
    $manifest = $manifestText | ConvertFrom-Json
    if ([version]$manifest.version -le [version]$AppVersion) {
        Write-ServiceLog "No update required; current $AppVersion, remote $($manifest.version)."
        [Windows.Forms.MessageBox]::Show("Установлена актуальная версия $AppVersion.`nОбновления не требуются.",'Проверка обновлений','OK','Information') | Out-Null
        return $false
    }
    if (-not $manifest.script_url.StartsWith('https://') -or $manifest.sha256 -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Некорректный или небезопасный манифест обновления.' }
    $download = Join-Path $env:TEMP ('SeniorLaptopService-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $scriptSeparator = if ($manifest.script_url.Contains('?')) { '&' } else { '?' }
    $scriptRequestUrl = $manifest.script_url + $scriptSeparator + 'nocache=' + $nonce
    Write-ServiceLog "Скачивание обновления $($manifest.version)..."
    $scriptBytes = Get-UpdateBytesWithFallback $scriptRequestUrl 60 90
    [IO.File]::WriteAllBytes($download, $scriptBytes)
    $actual = (Get-FileHash $download -Algorithm SHA256).Hash
    if ($actual -ne $manifest.sha256) { Remove-Item $download -Force; throw "SHA-256 не совпал. Получено $actual" }
    $tokens=$null; $parseErrors=$null; [void][Management.Automation.Language.Parser]::ParseFile($download,[ref]$tokens,[ref]$parseErrors)
    if ($parseErrors.Count) { Remove-Item $download -Force; throw 'Загруженный сценарий не прошёл проверку синтаксиса.' }
    $backup = $PSCommandPath + '.before-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item $PSCommandPath $backup -Force
    Copy-Item $download $PSCommandPath -Force
    $installed = Join-Path $InstallRoot 'SeniorLaptopService.ps1'
    if (Test-Path $installed) { Copy-Item $download $installed -Force }
    Remove-Item $download -Force
    Write-ServiceLog "Updated from $AppVersion to $($manifest.version). Backup: $backup"
    [Windows.Forms.MessageBox]::Show("Обновление $($manifest.version) установлено.`nПанель сейчас перезапустится автоматически.",'Обновление','OK','Information') | Out-Null
    $restartArguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
    Start-Process powershell.exe -ArgumentList $restartArguments
    $form.Close()
    return $true
}

if ($Maintenance) { Invoke-MaintenanceMode; exit 0 }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object Windows.Forms.Form
$form.Text = "$AppName $AppVersion"
$form.Size = New-Object Drawing.Size(820,650)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object Drawing.Size(760,600)
$form.Font = New-Object Drawing.Font('Segoe UI',10)

$top = New-Object Windows.Forms.Label
$top.Dock = 'Top'; $top.Height = 45; $top.Padding = New-Object Windows.Forms.Padding(10,8,10,0)
$top.Text = if (Test-Administrator) { 'Права администратора: ДА' } else { 'Права администратора: НЕТ — системные действия будут ограничены' }
$top.ForeColor = if (Test-Administrator) { [Drawing.Color]::DarkGreen } else { [Drawing.Color]::DarkRed }
$form.Controls.Add($top)

$buttons = New-Object Windows.Forms.TableLayoutPanel
$buttons.Dock = 'Top'; $buttons.Height = 250; $buttons.ColumnCount = 2; $buttons.RowCount = 3; $buttons.Padding = New-Object Windows.Forms.Padding(8,4,8,4)
1..2 | ForEach-Object { [void]$buttons.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,50))) }
1..3 | ForEach-Object { [void]$buttons.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,33.33))) }
$form.Controls.Add($buttons)

$progressPanel = New-Object Windows.Forms.Panel
$progressPanel.Dock='Top'; $progressPanel.Height=58; $progressPanel.Padding=New-Object Windows.Forms.Padding(12,4,12,5); $progressPanel.BackColor=[Drawing.Color]::AliceBlue
$script:StatusLabel = New-Object Windows.Forms.Label
$script:StatusLabel.Dock='Top'; $script:StatusLabel.Height=25; $script:StatusLabel.Text='Готово к работе.'; $script:StatusLabel.AutoEllipsis=$true
$script:OperationProgress = New-Object Windows.Forms.ProgressBar
$script:OperationProgress.Dock='Bottom'; $script:OperationProgress.Height=20; $script:OperationProgress.Style=[Windows.Forms.ProgressBarStyle]::Blocks; $script:OperationProgress.Value=0
$progressPanel.Controls.Add($script:StatusLabel); $progressPanel.Controls.Add($script:OperationProgress)
$form.Controls.Add($progressPanel)

$script:OperationTimer = New-Object Windows.Forms.Timer
$script:OperationTimer.Interval=500
$script:OperationTimer.Add_Tick({
    if ($script:OperationRunning -and $script:OperationStopwatch) {
        $elapsed=[math]::Floor($script:OperationStopwatch.Elapsed.TotalSeconds)
        $detail=if([string]::IsNullOrWhiteSpace($script:LastOperationMessage)){'обработка...'}else{$script:LastOperationMessage}
        $script:StatusLabel.Text="Выполняется: $($script:CurrentAction) | $detail | $elapsed сек."
    }
})
$script:OperationRunning=$false
$script:CurrentAction=''
$script:LastOperationMessage=''
$script:OperationStopwatch=$null

$script:LogBox = New-Object Windows.Forms.TextBox
$script:LogBox.Dock = 'Fill'; $script:LogBox.Multiline = $true; $script:LogBox.ReadOnly = $true
$script:LogBox.ScrollBars = 'Vertical'; $script:LogBox.BackColor = [Drawing.Color]::White
$form.Controls.Add($script:LogBox)

function Start-OperationProgress([string]$ActionName) {
    $script:OperationRunning=$true; $script:CurrentAction=$ActionName; $script:LastOperationMessage='запуск...'
    $script:OperationStopwatch=[Diagnostics.Stopwatch]::StartNew()
    $script:StatusLabel.Text="Выполняется: $ActionName | запуск... | 0 сек."
    $script:OperationProgress.Style=[Windows.Forms.ProgressBarStyle]::Marquee; $script:OperationProgress.MarqueeAnimationSpeed=25
    $buttons.Enabled=$false; $script:OperationTimer.Start(); [Windows.Forms.Application]::DoEvents()
}

function Stop-OperationProgress([string]$ResultText='Готово.') {
    $elapsed=if($script:OperationStopwatch){[math]::Round($script:OperationStopwatch.Elapsed.TotalSeconds,1)}else{0}
    if($script:OperationStopwatch){$script:OperationStopwatch.Stop()}
    $script:OperationTimer.Stop(); $script:OperationRunning=$false
    $script:OperationProgress.MarqueeAnimationSpeed=0; $script:OperationProgress.Style=[Windows.Forms.ProgressBarStyle]::Blocks; $script:OperationProgress.Value=100
    $script:StatusLabel.Text="$ResultText Время: $elapsed сек."
    $buttons.Enabled=$true; [Windows.Forms.Application]::DoEvents()
}

function Add-ActionButton([string]$Text, [scriptblock]$Action, [int]$Column, [int]$Row, [Drawing.Color]$Color = [Drawing.Color]::WhiteSmoke) {
    $button = New-Object Windows.Forms.Button
    $button.Text = $Text; $button.Dock = 'Fill'; $button.Margin = New-Object Windows.Forms.Padding(5); $button.BackColor = $Color
    $button.Add_Click({
        try { $form.UseWaitCursor = $true; Start-OperationProgress $Text; & $Action }
        catch {
            Write-ServiceLog ("ERROR in [$Text]: " + (Get-DetailedErrorText $_))
            $errorReportPath = New-AutomaticErrorReport $Text $_
            $delivery = 'GitHub: не настроен; отчёт оставлен локально.'
            try {
                $automaticToken = Get-PortableReportToken
                if (-not [string]::IsNullOrWhiteSpace($automaticToken)) {
                    $automaticUpload = Send-ReportToGitHub $errorReportPath $automaticToken 'errors'
                    $delivery = "GitHub: отправлен автоматически ($($automaticUpload.path))."
                    Write-ServiceLog $delivery
                }
            } catch { $delivery = 'GitHub: автоматическая отправка не удалась: ' + $_.Exception.Message; Write-ServiceLog $delivery }
            [Windows.Forms.MessageBox]::Show("Операция завершилась ошибкой.`n`n$($_.Exception.Message)`n`nАвтоматический отчёт создан:`n$errorReportPath`n`n$delivery`n`nПуть скопирован в буфер обмена.",'Ошибка','OK','Error') | Out-Null
            Start-Process notepad.exe $errorReportPath
        }
        finally { $form.UseWaitCursor = $false; Stop-OperationProgress }
    }.GetNewClosure())
    $buttons.Controls.Add($button,$Column,$Row)
    return $button
}

$audit = {
    Write-ServiceLog 'Audit started.'
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    Write-ServiceLog "PC: $($cs.Manufacturer) $($cs.Model); RAM: $([math]::Round($cs.TotalPhysicalMemory/1GB,1)) GiB"
    Write-ServiceLog "OS: $($os.Caption), build $($os.BuildNumber); CPU: $($cpu.Name)"
    Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { Write-ServiceLog "Disk $($_.DeviceID): $([math]::Round($_.FreeSpace/1GB,1)) GiB free of $([math]::Round($_.Size/1GB,1)) GiB" }
    $antivirus = Get-ThirdPartyAntivirusProducts
    Write-ServiceLog ('Third-party antivirus products found: ' + @($antivirus.names).Count + '; ' + (@($antivirus.names) -join ', '))
}

$clean = { Invoke-SafeCleanup | Out-Null; [Windows.Forms.MessageBox]::Show('Очистка завершена. Личные файлы, история, пароли и закладки не удалялись.','Готово') | Out-Null }

$fixYandex = {
    $answer = [Windows.Forms.MessageBox]::Show('Будут закрыты все окна Яндекс.Браузера и сброшено восстановление открытых вкладок. История, закладки, пароли и файлы сохранятся. Продолжить?','Исправление Яндекс.Браузера','YesNo','Warning')
    if ($answer -ne 'Yes') { return }
    Get-Process browser -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $root = Join-Path $env:LOCALAPPDATA 'Yandex\YandexBrowser\User Data'
    $backup = Join-Path $InstallRoot ('Backups\YandexSessions-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $found = 0
    Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' } | ForEach-Object {
        $sessions = Join-Path $_.FullName 'Sessions'
        if (Test-Path $sessions) { Ensure-Directory $backup; Copy-Item $sessions (Join-Path $backup $_.Name) -Recurse -Force; Remove-DirectoryContentsSafely $sessions | Out-Null; $found++ }
    }
    Write-ServiceLog "Yandex session reset complete; profiles processed: $found; backup: $backup"
}

$removeAntivirus = {
    if (-not (Test-Administrator)) { throw 'Запустите программу от имени администратора.' }
    $detected = Get-ThirdPartyAntivirusProducts
    if (@($detected.names).Count -eq 0) {
        $defender = Get-MpComputerStatus -ErrorAction SilentlyContinue
        $statusText = if ($defender -and $defender.AntivirusEnabled) { 'Microsoft Defender уже включён.' } else { 'Сторонний антивирус не найден. Проверьте состояние Microsoft Defender.' }
        [Windows.Forms.MessageBox]::Show($statusText,'Проверка антивируса','OK','Information') | Out-Null
        return
    }
    $nameList = @($detected.names) -join "`n• "
    $answer = [Windows.Forms.MessageBox]::Show("Найдены сторонние защитные продукты:`n`n• $nameList`n`nБудут запущены их штатные программы удаления. Microsoft Defender удаляться не будет. После удаления может потребоваться перезагрузка.`n`nПродолжить?",'Замена антивируса','YesNo','Warning')
    if ($answer -ne 'Yes') { return }
    $restoreCreated = $false
    try {
        Enable-ComputerRestore -Drive ($env:SystemDrive + '\') -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description ('Before antivirus removal ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')) -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        $restoreCreated = $true; Write-ServiceLog 'System restore point created before antivirus removal.'
    } catch { Write-ServiceLog "Restore point could not be created: $($_.Exception.Message)" }
    if (-not $restoreCreated -and [Windows.Forms.MessageBox]::Show('Точку восстановления создать не удалось. Продолжить удаление без неё?','Нет точки восстановления','YesNo','Warning') -ne 'Yes') { return }
    $started = 0
    foreach ($item in @($detected.uninstall_entries)) {
        $productName = [string](Get-SafeProperty $item 'DisplayName')
        $command = [string](Get-SafeProperty $item 'QuietUninstallString')
        if ([string]::IsNullOrWhiteSpace($command)) { $command = [string](Get-SafeProperty $item 'UninstallString') }
        if ([string]::IsNullOrWhiteSpace($command)) { Write-ServiceLog "No registered uninstaller for $productName"; continue }
        if ($command -match '(?i)msiexec(\.exe)?\s+/(I|package)\s*({[^}]+})') { $command = "msiexec.exe /X $($matches[3]) /passive /norestart" }
        Write-ServiceLog "Starting registered antivirus uninstaller: $productName"
        Start-Process cmd.exe -ArgumentList '/d','/c',$command -Verb RunAs -Wait
        $started++
    }
    if ($started -eq 0) { throw 'Антивирус зарегистрирован в Центре безопасности, но штатная команда удаления не найдена. Требуется фирменная утилита очистки производителя.' }
    Write-ServiceLog 'Requesting Microsoft Defender activation, signature update and background quick scan.'
    try { Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction SilentlyContinue } catch { }
    $defenderCommand = 'Update-MpSignature -ErrorAction SilentlyContinue; Start-MpScan -ScanType QuickScan -ErrorAction SilentlyContinue'
    Start-Process powershell.exe -ArgumentList '-NoLogo','-NoProfile','-WindowStyle','Hidden','-Command',$defenderCommand -WindowStyle Hidden
    Start-Sleep -Seconds 3
    $remaining = Get-ThirdPartyAntivirusProducts
    $defender = Get-MpComputerStatus -ErrorAction SilentlyContinue
    $defenderText = if ($defender -and $defender.AntivirusEnabled) { 'Microsoft Defender включён.' } else { 'Defender пока не подтвердил включение; перезагрузите компьютер и проверьте снова.' }
    $remainingText = if (@($remaining.names).Count) { "Остались записи: $(@($remaining.names) -join ', '). Может потребоваться перезагрузка или фирменная утилита удаления." } else { 'Сторонние антивирусы больше не зарегистрированы.' }
    [Windows.Forms.MessageBox]::Show("Удаление запущено/завершено.`n`n$defenderText`n$remainingText`n`nОбновление баз и быстрая проверка Defender выполняются в фоне.",'Замена антивируса','OK','Information') | Out-Null
}

$optimize = {
    if (-not (Test-Administrator)) { throw 'Запустите программу от имени администратора.' }
    powercfg.exe /setactive SCHEME_MIN | Out-Null
    New-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Force | Out-Null
    Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' EnableTransparency 0 -Type DWord
    New-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' -Force | Out-Null
    Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' StartupDelayInMSec 0 -Type DWord
    New-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Force | Out-Null
    @('ContentDeliveryAllowed','OemPreInstalledAppsEnabled','PreInstalledAppsEnabled','PreInstalledAppsEverEnabled','SilentInstalledAppsEnabled','SubscribedContent-338388Enabled','SubscribedContent-338389Enabled','SubscribedContent-353694Enabled','SubscribedContent-353696Enabled') | ForEach-Object {
        Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' $_ 0 -Type DWord
    }
    $safeUnusedServices = @('DiagTrack','dmwappushservice','MapsBroker','Fax','RetailDemo','PhoneSvc','XblAuthManager','XblGameSave','XboxNetApiSvc','WMPNetworkSvc')
    foreach ($serviceName in $safeUnusedServices) {
        $service = Get-Service $serviceName -ErrorAction SilentlyContinue
        if ($service) {
            Stop-Service $serviceName -Force -ErrorAction SilentlyContinue
            Set-Service $serviceName -StartupType Disabled -ErrorAction SilentlyContinue
            Write-ServiceLog "Disabled unused service: $serviceName"
        }
    }
    Write-ServiceLog 'Communication-only profile applied: high performance, no consumer suggestions, unused Xbox/maps/fax/telemetry services disabled.'
    Write-ServiceLog 'Kept enabled: Defender, Windows Update, audio, camera, microphone, Bluetooth, printing, networking and browser-related services.'
}

$schedule = {
    if (-not (Test-Administrator)) { throw 'Запустите программу от имени администратора.' }
    Ensure-Directory $InstallRoot
    $installedScript = Join-Path $InstallRoot 'SeniorLaptopService.ps1'
    Copy-Item -LiteralPath $PSCommandPath -Destination $installedScript -Force
    $taskCommand = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$installedScript`" -Maintenance -UpdateZapretLists"
    schtasks.exe /Create /TN 'SeniorLaptopService Weekly Maintenance' /SC WEEKLY /D SUN /ST 12:00 /RL HIGHEST /RU SYSTEM /TR $taskCommand /F | Out-Null
    Write-ServiceLog "Weekly task installed. Script: $installedScript"
}

$restore = {
    if ([Windows.Forms.MessageBox]::Show('Открыть восстановление Windows? Сброс системы может удалить программы и данные. Сам сброс начнётся только после дополнительных подтверждений Windows.','Восстановление Windows','YesNo','Warning') -eq 'Yes') { Start-Process 'ms-settings:recovery' }
}

$zapretUpdate = {
    if (-not (Test-Administrator)) { throw 'Запустите программу от имени администратора.' }
    Write-ServiceLog "Checking portable Zapret folder: $ZapretRoot"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $versionFile = Join-Path $ZapretRoot '.installed-version'
    $portableVersion = if (Test-Path -LiteralPath $versionFile) { [string](Get-Content -LiteralPath $versionFile -Raw -ErrorAction SilentlyContinue).Trim() } else { '' }
    $portableReady = ($portableVersion -eq $PinnedZapretVersion -and (Test-Path -LiteralPath (Join-Path $ZapretRoot 'service.bat')) -and (Test-Path -LiteralPath (Join-Path $ZapretRoot 'bin\winws.exe')))
    if ($portableReady) {
        Write-ServiceLog "Portable Zapret $portableVersion is current; archive download and file replacement skipped."
        Remove-ZapretInstallation $false
    } else {
        Write-ServiceLog "Portable Zapret version '$portableVersion' differs from required '$PinnedZapretVersion'; downloading verified replacement..."
        $zip = Join-Path $env:TEMP ('zapret-' + [guid]::NewGuid().ToString('N') + '.zip')
        $stage = Join-Path $env:TEMP ('zapret-' + [guid]::NewGuid().ToString('N'))
        Invoke-ReliableZipDownload @($PinnedZapretUrl,$PinnedZapretApiUrl) $zip $PinnedZapretSha256
        Ensure-Directory $stage; Expand-Archive -LiteralPath $zip -DestinationPath $stage -Force
        $source = Get-ChildItem $stage -Filter service.bat -Recurse | Select-Object -First 1 -ExpandProperty DirectoryName
        if (-not $source -or -not (Test-Path -LiteralPath (Join-Path $source 'bin\winws.exe'))) { throw 'Проверенный архив не содержит service.bat или bin\winws.exe.' }
        Remove-ZapretInstallation $true
        Ensure-Directory $ZapretRoot
        Copy-Item (Join-Path $source '*') $ZapretRoot -Recurse -Force
        Set-Content -LiteralPath $versionFile -Value $PinnedZapretVersion -Encoding ASCII
        Remove-Item $zip -Force -ErrorAction SilentlyContinue; Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
        Write-ServiceLog "Portable Zapret updated to $PinnedZapretVersion from hatory42-oss repository."
    }
    Write-ServiceLog 'Previous service is removed. Installing strategy #9 first.'
    $strategyCount = @(Get-ChildItem -LiteralPath $ZapretRoot -Filter '*.bat' -File | Where-Object { $_.Name -notlike 'service*' }).Count
    if ($strategyCount -lt 1) { throw 'В установленном релизе Zapret не найдены стратегии.' }
    $strategyOrder = New-Object Collections.Generic.List[int]
    if ($strategyCount -ge 9) { $strategyOrder.Add(9) }
    for ($strategyNumber=1; $strategyNumber -le $strategyCount; $strategyNumber++) { if ($strategyNumber -ne 9) { $strategyOrder.Add($strategyNumber) } }
    $strategyResult = $null
    $strategyFailures = New-Object Collections.Generic.List[string]
    $strategyTestTimer = [Diagnostics.Stopwatch]::StartNew()
    $strategyAttempts = 0
    foreach ($strategyNumber in $strategyOrder) {
        if ($strategyTestTimer.Elapsed.TotalSeconds -ge 60) { Write-ServiceLog 'Zapret strategy rotation reached the total 60-second limit.'; break }
        $strategyAttempts++
        Write-ServiceLog "Applying Zapret strategy #$strategyNumber and checking actual YouTube media stream..."
        try { $candidate = Install-ZapretStrategy $ZapretRoot $strategyNumber }
        catch { $strategyFailures.Add("#${strategyNumber}: $($_.Exception.Message)"); Write-ServiceLog "Strategy #$strategyNumber installation failed; continuing: $($_.Exception.Message)"; continue }
        Start-Sleep -Seconds 3
        $remainingSeconds = [math]::Floor(60 - $strategyTestTimer.Elapsed.TotalSeconds)
        if ($remainingSeconds -lt 3) { Write-ServiceLog 'No time remains for media verification within the 60-second limit.'; break }
        $streamStatus = Test-YouTubeMediaStream 'LNrBbGcLhXg' ([math]::Min(25,$remainingSeconds))
        if ($streamStatus -eq 'Working') { $strategyResult = $candidate; Write-ServiceLog "Zapret strategy #$strategyNumber passed the media stream test."; break }
        if ($streamStatus -eq 'VerificationBlocked') { throw "YouTube потребовал вход или антибот-проверку, поэтому автоматически оценить поток невозможно. Стратегия №$strategyNumber установлена; бессмысленный перебор других стратегий остановлен." }
        Write-ServiceLog "Zapret strategy #$strategyNumber did not pass. Trying the next strategy automatically."
    }
    $strategyTestTimer.Stop()
    if ($null -eq $strategyResult) { throw "За 60 секунд не найдена рабочая стратегия Zapret. Проверено попыток: $strategyAttempts. Ошибки установки: $($strategyFailures -join ' | ')" }
    $youtubeAtThreeMinutes = 'https://www.youtube.com/watch?v=LNrBbGcLhXg&autoplay=1&t=180s'
    $youtubeAtFourTwentySeven = 'https://www.youtube.com/watch?v=LNrBbGcLhXg&autoplay=1&t=267s'
    Write-ServiceLog 'Starting first visual YouTube verification at 03:00.'
    [void](Invoke-YouTubeVisualTest $youtubeAtThreeMinutes 20)
    Write-ServiceLog 'Starting second visual YouTube verification at 04:27.'
    [void](Invoke-YouTubeVisualTest $youtubeAtFourTwentySeven 20)
    [Windows.Forms.MessageBox]::Show("Zapret установлен и запущен.`n`nРабочая стратегия №$($strategyResult.index): $($strategyResult.registered)`nСлужба: $($strategyResult.service_status)`n`nВидео проверено с отметок 03:00 и 04:27. Каждое тестовое окно закрыто автоматически. Системные звуки не изменялись.",'Проверка Zapret','OK','Information') | Out-Null
}

$zapretOpen = {
    $service = Join-Path $ZapretRoot 'service.bat'
    if (-not (Test-Path $service)) { throw 'Zapret не установлен. Сначала нажмите «Zapret: установить/обновить».' }
    Start-Process $service -Verb RunAs
}

$repair = {
    if (-not (Test-Administrator)) { throw 'Запустите программу от имени администратора.' }
    Write-ServiceLog 'Starting DISM component repair, then SFC. This can take a long time.'
    Start-Process cmd.exe -ArgumentList '/k','DISM /Online /Cleanup-Image /RestoreHealth && sfc /scannow' -Verb RunAs
}

$apps = { Start-Process 'ms-settings:appsfeatures' }

$installAdBlockAction = {
    if (-not (Test-Administrator)) { throw 'Запустите программу от имени администратора.' }
    $choice = [Windows.Forms.MessageBox]::Show("Выберите один блокировщик рекламы:`n`nДА — AdGuard AdBlocker`nНЕТ — Adblock Plus`nОТМЕНА — ничего не менять`n`nОдновременно два блокировщика не устанавливаются.",'Блокировщик рекламы','YesNoCancel','Question')
    if ($choice -eq 'Cancel') { return }
    $extensionId = if ($choice -eq 'Yes') { 'bgnkhhnnamicmpeenaelnjfhikgbkllg' } else { 'cfhdojbkjhnklbpkdaibdccddilifddb' }
    $extensionName = if ($choice -eq 'Yes') { 'AdGuard AdBlocker' } else { 'Adblock Plus' }
    $applied = New-Object Collections.Generic.List[string]
    $chromeInstalled = (Test-Path "$env:ProgramFiles\Google\Chrome\Application\chrome.exe") -or (Test-Path "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe")
    if ($chromeInstalled) { Set-ManagedBrowserExtension 'HKLM:\Software\Policies\Google\Chrome\ExtensionInstallForcelist' $extensionId; $applied.Add('Google Chrome') }
    $edgeInstalled = Test-Path "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    if ($edgeInstalled) { Set-ManagedBrowserExtension 'HKLM:\Software\Policies\Microsoft\Edge\ExtensionInstallForcelist' $extensionId; $applied.Add('Microsoft Edge') }
    $yandexInstalled = @(Get-ChildItem 'C:\Users\*\AppData\Local\Yandex\YandexBrowser\Application\browser.exe' -Force -ErrorAction SilentlyContinue).Count -gt 0
    if ($yandexInstalled) { Set-ManagedBrowserExtension 'HKLM:\Software\Policies\YandexBrowser\ExtensionInstallForcelist' $extensionId; $applied.Add('Яндекс Браузер') }
    if ($applied.Count -eq 0) { throw 'Поддерживаемые браузеры не обнаружены. Установите Chrome, Edge или Яндекс Браузер и повторите.' }
    Write-ServiceLog "$extensionName configured as a managed extension for: $($applied -join ', ')"
    [Windows.Forms.MessageBox]::Show("$extensionName назначен для автоматической установки.`n`nБраузеры: $($applied -join ', ')`n`nПолностью закройте и снова откройте браузер. Установка произойдёт через интернет автоматически.",'Готово','OK','Information') | Out-Null
}

$engineerGuideAction = {
    $guidePath = Join-Path $PSScriptRoot 'ИНСТРУКЦИЯ СЕРВИСНОГО ИНЖЕНЕРА.html'
    $guideHtml = @'
<!doctype html><html lang="ru"><head><meta charset="utf-8"><title>Инструкция сервисного инженера</title><style>
body{font-family:Segoe UI,Arial,sans-serif;max-width:1050px;margin:28px auto;padding:0 24px;color:#182230;font-size:19px;line-height:1.5}h1{font-size:38px}h2{font-size:28px;margin-top:32px}.step{border-left:8px solid #3979bd;background:#eef5ff;padding:16px 22px;margin:18px 0}.safe{border-left-color:#37944d;background:#eaf8ee}.warn{border-left-color:#d39420;background:#fff7df}.danger{border-left-color:#c7443d;background:#fff0ef}code{font-size:17px}li{margin:9px 0}.num{font-size:28px;font-weight:700}</style></head><body>
<h1>Порядок работы с Senior Laptop Service</h1>
<div class="step safe"><h2>Шесть кнопок главного окна</h2><ol><li><b>Полное обслуживание</b> — рекомендуемый пошаговый цикл.</li><li><b>Диагностика и отчёт</b> — аудит и отправка в GitHub без изменений системы.</li><li><b>Очистка и ускорение</b> — очистка, оптимизация и еженедельная задача.</li><li><b>Безопасность и блокировщик</b> — проверка/замена стороннего антивируса и выбор блокировщика рекламы.</li><li><b>Zapret и проверка YouTube</b> — установка стратегии №9 и контроль соединения.</li><li><b>Дополнительные инструменты</b> — редкие и потенциально опасные операции.</li></ol></div>
<div class="step warn"><h2>Перед началом</h2><ol><li>Подключите ноутбук к зарядке.</li><li>Убедитесь, что интернет работает.</li><li>Закройте браузеры, Zoom и мессенджеры для полной очистки их кэшей.</li><li>Запустите <b>Run-As-Administrator.cmd</b> от имени администратора.</li><li>Не запускайте восстановление Windows без резервной копии.</li></ol></div>
<div class="step"><span class="num">1. Проверить обновления панели</span><p>Всегда нажимайте первой. Если найдена новая версия, программа обновится и перезапустится. После перезапуска продолжайте со второго шага.</p></div>
<div class="step"><span class="num">2. Аудит системы</span><p>Показывает модель, Windows, процессор, память, диски и наличие Avast. Используйте для первичной быстрой проверки.</p></div>
<div class="step"><span class="num">3. Отправить отчёт в GitHub</span><p>Создаёт подробный приватный отчёт. После успешной отправки локальный JSON удаляется. Затем напишите в Codex: <b>«Проверь последний отчёт»</b>.</p></div>
<div class="step"><span class="num">4. Проверить заключение GitHub</span><p>Нажимайте после того, как Codex сообщил о готовности анализа. Заключение сохраняется на рабочем столе пользователя и открывается в браузере.</p></div>
<div class="step safe"><span class="num">5. Безопасная очистка</span><p>Очищает временные файлы, корзину и кэши всех профилей Chrome, Edge, Яндекс, Firefox, Brave, Vivaldi, Chromium и Opera. Не удаляет пароли, cookies, историю, закладки, вкладки и личные файлы. Для полного результата браузеры должны быть закрыты.</p></div>
<div class="step"><span class="num">6. Исправить 100 окон Яндекса</span><p>Нажимайте только если Яндекс при запуске открывает множество окон. Профиль предварительно копируется в резервную папку, затем повреждённая сессия сбрасывается.</p></div>
<div class="step"><span class="num">7. Заменить сторонний антивирус</span><p>Показывает найденные сторонние антивирусы, создаёт точку восстановления, запускает их зарегистрированные программы удаления и включает бесплатный Microsoft Defender. Подтвердите список перед продолжением. После удаления перезагрузите компьютер, если программа это рекомендует.</p></div>
<div class="step"><span class="num">8. Оптимизация производительности</span><p>Применяет профиль высокой производительности, отключает рекламные предложения и ненужные для сценария общения службы. Сеть, звук, камера, микрофон, Bluetooth, печать, Defender и Windows Update сохраняются.</p></div>
<div class="step"><span class="num">9. Установить блокировщик рекламы</span><p>Выберите только один вариант: AdGuard AdBlocker или Adblock Plus. Закройте и снова откройте браузер, затем убедитесь, что расширение появилось. Другие расширения не удаляются.</p></div>
<div class="step"><span class="num">10. Zapret: установить / обновить</span><p>Скачивает официальный релиз, автоматически выбирает стратегию №9, устанавливает и проверяет службу. Затем в отдельном окне Edge на 45 секунд открывается тестовое видео с котиками. Системные звуки программа не меняет. При успешном соединении тестовое окно закроется само. Если YouTube не ответит, окно также закроется, а программа создаст и автоматически отправит отчёт ошибки.</p></div>
<div class="step"><span class="num">11. Установить еженедельную очистку</span><p>Делайте после завершения настройки. Каждое воскресенье в 12:00 очистка запускается от SYSTEM и обновляет списки Zapret. Повторное нажатие безопасно: задача заменяется новой версией.</p></div>
<div class="step warn"><span class="num">11. DISM + SFC</span><p>Используйте при повреждении Windows, системных ошибках или после неудачных обновлений. Операция длительная; не выключайте ноутбук.</p></div>
<div class="step safe"><span class="num">12. Создать памятку</span><p>В конце создаёт на рабочем столе простую памятку для пожилого пользователя. Технические предварительные рекомендации остаются на USB.</p></div>
<div class="step danger"><span class="num">13. Восстановление Windows</span><p><b>Только крайняя мера.</b> Сначала сохраните фотографии, документы, данные браузера и мессенджеров. Кнопка лишь открывает настройки восстановления; внимательно выбирайте сохранение личных файлов.</p></div>
<h2>Рекомендуемая последовательность для обычного обслуживания</h2><p><b>Обновление → Аудит → Отчёт GitHub → Анализ → Очистка → исправление Яндекса/замена стороннего антивируса при необходимости → перезагрузка → Оптимизация → блокировщик рекламы → Zapret → Еженедельная задача → Памятка.</b></p>
<h2>Что не делать автоматически</h2><ul><li>Не удалять неизвестные программы без проверки владельца.</li><li>Не сбрасывать Windows ради обычной медленной работы.</li><li>Не обновлять BIOS без зарядки, точной модели и причины.</li><li>Не считать число слотов из BIOS физически достоверным.</li><li>Не разбирать устройство до проверки гарантии и сервисного руководства.</li></ul>
</body></html>
'@
    [IO.File]::WriteAllText($guidePath,$guideHtml,[Text.UTF8Encoding]::new($true))
    Write-ServiceLog "Инструкция сервисного инженера создана: $guidePath"
    Start-Process $guidePath
}

$recommendationsAction = {
    Write-ServiceLog 'Создание рекомендаций и памятки для пользователя...'
    $cs = Get-CimInstance Win32_ComputerSystem
    $board = Get-CimInstance Win32_BaseBoard | Select-Object -First 1
    $modules = @(Get-CimInstance Win32_PhysicalMemory)
    $diskDrives = @(Get-CimInstance Win32_DiskDrive)
    $systemDisk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    $ramGb = [math]::Round([double]$cs.TotalPhysicalMemory / 1GB,1)
    $freeGb = [math]::Round([double]$systemDisk.FreeSpace / 1GB,1)
    $freePercent = if ($systemDisk.Size) { [math]::Round(100 * [double]$systemDisk.FreeSpace / [double]$systemDisk.Size,1) } else { 0 }
    $technical = New-Object Collections.Generic.List[string]
    $technical.Add('ПРАКТИЧЕСКИЕ РЕКОМЕНДАЦИИ ПО МОДЕРНИЗАЦИИ')
    $technical.Add('Создано: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $technical.Add("Устройство: $($cs.Manufacturer) $($cs.Model)")
    $technical.Add("Плата: $($board.Manufacturer) $($board.Product), версия: $($board.Version)")
    $technical.Add("ОЗУ: $ramGb ГБ; фактически установлено модулей: $($modules.Count)")
    $technical.Add("Диск C: свободно $freeGb ГБ ($freePercent%)")
    $technical.Add('')
    if ($ramGb -lt 8) { $technical.Add('ПРИОРИТЕТ: увеличить ОЗУ минимум до 8 ГБ, предпочтительно до 16 ГБ.') }
    elseif ($ramGb -lt 16) { $technical.Add('РЕКОМЕНДАЦИЯ: для браузера, Zoom и мессенджеров увеличить ОЗУ до 16 ГБ.') }
    else { $technical.Add('ОЗУ: объём достаточен для браузера, Zoom и мессенджеров.') }
    if ($freePercent -lt 15) { $technical.Add('ПРИОРИТЕТ: на системном диске мало места. Освободить минимум 30–40 ГБ или заменить SSD на более ёмкий.') }
    elseif ($freePercent -lt 25) { $technical.Add('Диск C: желательно освободить дополнительное место.') }
    else { $technical.Add('Диск C: запас свободного места достаточен.') }
    $technical.Add('')
    $technical.Add('Обнаруженные физические накопители:')
    foreach ($disk in $diskDrives) { $technical.Add(('- {0}; {1} ГБ; интерфейс: {2}; тип: {3}' -f $disk.Model,[math]::Round([double]$disk.Size/1GB,1),$disk.InterfaceType,$disk.MediaType)) }
    $technical.Add('')
    $technical.Add('ВАЖНО О СЛОТАХ ОЗУ И SSD: Windows/BIOS не подтверждают физическое количество разъёмов. Число выше — только реально установленные модули. Перед покупкой вскрыть сервисную крышку либо проверить сервис-мануал именно для модели, ревизии платы и варианта корпуса. Не считать SMBIOS NumberOfMemoryDevices доказательством физических слотов.')
    $reportRoot = Get-ReportStorageRoot
    $technicalPath = Join-Path $reportRoot ('Modernization-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    [IO.File]::WriteAllLines($technicalPath,$technical,[Text.UTF8Encoding]::new($true))

    $desktop = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($desktop) -or -not (Test-Path -LiteralPath $desktop)) { throw 'Рабочий стол пользователя не найден.' }
    $guidePath = Join-Path $desktop 'ПАМЯТКА — как безопасно пользоваться интернетом.html'
    $html = @'
<!doctype html><html lang="ru"><head><meta charset="utf-8"><title>Памятка по компьютеру</title><style>
body{font-family:Segoe UI,Arial,sans-serif;font-size:24px;line-height:1.5;max-width:900px;margin:30px auto;padding:0 24px;color:#172033;background:#fff}h1{font-size:40px}h2{font-size:30px;margin-top:32px}.card{padding:20px 24px;margin:18px 0;border-radius:14px}.ok{background:#e9f8ec;border:3px solid #3a9b50}.stop{background:#fff0ef;border:3px solid #d3473f}.tip{background:#eef5ff;border:3px solid #4785cf}li{margin:14px 0}.big{font-weight:700}footer{font-size:18px;color:#555;margin-top:40px}@media print{body{font-size:20px}.card{break-inside:avoid}}</style></head><body>
<h1>Памятка: как спокойно пользоваться компьютером</h1>
<div class="card ok"><h2>Открытие сайтов</h2><ol><li>Нажмите значок браузера <span class="big">один раз</span>.</li><li>Подождите несколько секунд.</li><li>Пишите запрос только в верхней строке.</li><li>Ненужную вкладку закрывайте крестиком на самой вкладке.</li></ol></div>
<div class="card stop"><h2>Не нажимайте</h2><ul><li>«Ваш компьютер заражён».</li><li>«Срочно обновите браузер» на незнакомом сайте.</li><li>«Вы выиграли приз».</li><li>Просьбы сообщить пароль, код из СМС или данные карты.</li><li>Не устанавливайте «ускорители» и «чистильщики» с сайтов.</li></ul><p class="big">Просто закройте такую страницу крестиком.</p></div>
<div class="card tip"><h2>Если открылось много окон</h2><ol><li>Не нажимайте внутри этих окон.</li><li>Закройте браузер крестиком справа вверху.</li><li>Если окна не закрываются — позвоните человеку, который обслуживает компьютер.</li></ol></div>
<div class="card ok"><h2>Zoom и мессенджеры</h2><ul><li>Открывайте программу одним нажатием и подождите.</li><li>Обновления устанавливайте только внутри самой программы.</li><li>Незнакомцам не разрешайте управление вашим экраном.</li></ul></div>
<div class="card tip"><h2>Чтобы компьютер не засорялся</h2><ul><li>Не скачивайте программы «для ускорения».</li><li>Не соглашайтесь на лишние панели и антивирусы.</li><li>Фотографии и документы удаляйте только если уверены.</li><li>Автоматическая безопасная очистка уже выполняется без удаления паролей и личных файлов.</li></ul></div>
<footer>Эту памятку можно открыть двойным нажатием и распечатать.</footer></body></html>
'@
    [IO.File]::WriteAllText($guidePath,$html,[Text.UTF8Encoding]::new($true))
    Write-ServiceLog "Технические рекомендации: $technicalPath"
    Write-ServiceLog "Памятка пользователя сохранена на рабочем столе: $guidePath"
    Start-Process $guidePath
    [Windows.Forms.MessageBox]::Show("Памятка сохранена на рабочем столе пользователя.`n`nТехнические рекомендации сохранены на USB:`n$technicalPath",'Готово') | Out-Null
}

$checkDiagnosisAction = {
    $token = Get-PortableReportToken -AllowSetup
    if ([string]::IsNullOrWhiteSpace($token)) { return }
    $safeComputer = ($env:COMPUTERNAME -replace '[^A-Za-z0-9._-]','_')
    $diagnosisPath = "diagnoses/$safeComputer/latest.html"
    $uri = "https://api.github.com/repos/hatory42-oss/senior-laptop-service-reports/contents/$diagnosisPath"
    Write-ServiceLog "Проверка готового заключения GitHub: $diagnosisPath"
    try {
        $remote = Invoke-ResponsiveGitHubRequest 'GET' $uri $token $null 30
    } catch {
        if ($_.Exception.Message -match 'HTTP 404') {
            [Windows.Forms.MessageBox]::Show("Заключение для этого компьютера ещё не подготовлено.`n`nСначала отправьте отчёт, затем напишите в Codex: «Проверь последний отчёт». После подготовки снова нажмите эту кнопку.",'Заключение ещё не готово','OK','Information') | Out-Null
            return
        }
        throw
    } finally { $token = $null }
    if ([string]::IsNullOrWhiteSpace([string]$remote.content)) { throw 'GitHub вернул пустое заключение.' }
    $htmlBytes = [Convert]::FromBase64String(([string]$remote.content -replace '\s',''))
    if ($htmlBytes.Length -gt 2MB) { throw 'Заключение имеет недопустимо большой размер.' }
    $desktop = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($desktop) -or -not (Test-Path -LiteralPath $desktop)) { throw 'Рабочий стол пользователя не найден.' }
    $localDiagnosis = Join-Path $desktop 'ЗАКЛЮЧЕНИЕ ПО НОУТБУКУ.html'
    [IO.File]::WriteAllBytes($localDiagnosis,$htmlBytes)
    Write-ServiceLog "Заключение получено и сохранено: $localDiagnosis"
    Start-Process $localDiagnosis
}

$reportAction = {
    Write-ServiceLog 'Creating privacy-filtered technical report...'
    $report = New-TechnicalReport
    Write-ServiceLog 'Отчёт: преобразование данных в JSON...'
    $json = ConvertTo-Json -InputObject $report -Depth 6 -Compress
    $jsonSizeBytes = [Text.Encoding]::UTF8.GetByteCount($json)
    $jsonSizeKb = [math]::Round($jsonSizeBytes / 1KB, 1)
    Write-ServiceLog "Отчёт: JSON подготовлен ($jsonSizeKb КБ)."
    if ($jsonSizeBytes -gt 2MB) {
        throw "Отчёт имеет аномальный размер $jsonSizeKb КБ и не будет отправлен. Допустимый предел: 2048 КБ."
    }
    $reportRoot = Get-ReportStorageRoot
    $reportPath = Join-Path $reportRoot ('SeniorLaptopService-report-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    [IO.File]::WriteAllText($reportPath,$json,[Text.UTF8Encoding]::new($true))
    Write-ServiceLog "Отчёт: локальная копия сохранена: $reportPath"
    Write-ServiceLog 'Отчёт: чтение ключа доступа GitHub...'
    $token = Get-PortableReportToken -AllowSetup
    if ([string]::IsNullOrWhiteSpace($token)) { Write-ServiceLog "Report saved locally; GitHub upload cancelled: $reportPath"; return }
    Write-ServiceLog 'Uploading report to private GitHub repository...'
    $uploaded = Send-ReportToGitHub $reportPath $token
    $token=$null
    Write-ServiceLog "Report uploaded to private GitHub path: $($uploaded.path); commit: $($uploaded.commit)"
    $localStatus = 'Локальная временная копия удалена.'
    try {
        Remove-Item -LiteralPath $reportPath -Force -ErrorAction Stop
        Write-ServiceLog "Temporary local report deleted after confirmed GitHub upload: $reportPath"
    } catch {
        $localStatus = "Не удалось удалить локальную копию: $reportPath"
        Write-ServiceLog ("WARNING: GitHub upload succeeded, but temporary local report could not be deleted: " + $_.Exception.Message)
    }
    [Windows.Forms.MessageBox]::Show("Отчёт загружен в приватный GitHub-репозиторий.`n`nПуть: $($uploaded.path)`n`n$localStatus",'Отправлено') | Out-Null
}

$diagnosticsWorkflow = {
    Write-ServiceLog 'WORKFLOW: diagnostics and GitHub report started.'
    & $audit
    & $reportAction
    Write-ServiceLog 'WORKFLOW: diagnostics and GitHub report completed.'
}

$cleanupWorkflow = {
    if ([Windows.Forms.MessageBox]::Show('Будут выполнены безопасная очистка всех профилей, оптимизация производительности и установка/обновление еженедельной задачи. Личные данные не удаляются. Продолжить?','Очистка и ускорение','YesNo','Question') -ne 'Yes') { return }
    Write-ServiceLog 'WORKFLOW: cleanup and performance started.'
    & $clean
    & $optimize
    & $schedule
    Write-ServiceLog 'WORKFLOW: cleanup and performance completed.'
    [Windows.Forms.MessageBox]::Show('Очистка, оптимизация и плановая задача выполнены.','Готово','OK','Information') | Out-Null
}

$securityWorkflow = {
    Write-ServiceLog 'WORKFLOW: security and ad blocker started.'
    & $removeAntivirus
    & $installAdBlockAction
    Write-ServiceLog 'WORKFLOW: security and ad blocker completed.'
}

$zapretWorkflow = {
    Write-ServiceLog 'WORKFLOW: Zapret installation and YouTube test started.'
    & $zapretUpdate
    Write-ServiceLog 'WORKFLOW: Zapret installation and YouTube test completed.'
}

$fullServiceWorkflow = {
    $summary = "Полное обслуживание выполнит:`n`n1. Проверку обновлений программы`n2. Аудит и отправку отчёта`n3. Очистку и оптимизацию`n4. Предложение заменить сторонний антивирус`n5. Выбор блокировщика рекламы`n6. Предложение установить Zapret`n7. Установку еженедельной очистки`n8. Создание памятки пользователю`n`nОпасные действия сохраняют отдельные подтверждения. Продолжить?"
    if ([Windows.Forms.MessageBox]::Show($summary,'Полное обслуживание','YesNo','Question') -ne 'Yes') { return }
    Write-ServiceLog 'WORKFLOW: full service started.'
    if (Invoke-SelfUpdate) { return }
    & $audit
    & $reportAction
    & $clean
    & $optimize
    $detectedAntivirus = Get-ThirdPartyAntivirusProducts
    if (@($detectedAntivirus.names).Count -gt 0) { & $removeAntivirus }
    & $installAdBlockAction
    if ([Windows.Forms.MessageBox]::Show('Установить/обновить Zapret и провести 45-секундную проверку YouTube?','Zapret','YesNo','Question') -eq 'Yes') { & $zapretUpdate }
    & $schedule
    & $recommendationsAction
    Write-ServiceLog 'WORKFLOW: full service completed.'
    [Windows.Forms.MessageBox]::Show('Основной цикл обслуживания завершён. После анализа отчёта используйте «Проверить заключение GitHub» в дополнительных инструментах.','Обслуживание завершено','OK','Information') | Out-Null
}

$additionalToolsAction = {
    Stop-OperationProgress 'Открыты дополнительные инструменты.'
    $toolsForm = New-Object Windows.Forms.Form
    $toolsForm.Text = 'Дополнительные инструменты'
    $toolsForm.Size = New-Object Drawing.Size(720,470)
    $toolsForm.StartPosition = 'CenterParent'; $toolsForm.FormBorderStyle = 'FixedDialog'; $toolsForm.MaximizeBox=$false; $toolsForm.MinimizeBox=$false
    $toolsForm.Font = New-Object Drawing.Font('Segoe UI',10)
    $panel = New-Object Windows.Forms.TableLayoutPanel
    $panel.Dock='Fill'; $panel.Padding=New-Object Windows.Forms.Padding(10); $panel.ColumnCount=2; $panel.RowCount=4
    1..2 | ForEach-Object { [void]$panel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,50))) }
    1..4 | ForEach-Object { [void]$panel.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,25))) }
    $toolsForm.Controls.Add($panel)
    $toolDefinitions = @(
        @('Проверить обновления',{ $toolsForm.Close(); Invoke-SelfUpdate }),
        @('Проверить заключение GitHub',$checkDiagnosisAction),
        @('Исправить 100 окон Яндекса',$fixYandex),
        @('Открыть управление Zapret',$zapretOpen),
        @('DISM + SFC',$repair),
        @('Восстановление Windows',$restore),
        @('Создать памятку пользователю',$recommendationsAction),
        @('Инструкция сервисного инженера',$engineerGuideAction)
    )
    for ($index=0; $index -lt $toolDefinitions.Count; $index++) {
        $toolText=[string]$toolDefinitions[$index][0]; $toolAction=[scriptblock]$toolDefinitions[$index][1]
        $toolButton=New-Object Windows.Forms.Button; $toolButton.Text=$toolText; $toolButton.Dock='Fill'; $toolButton.Margin=New-Object Windows.Forms.Padding(6)
        $toolButton.Add_Click({
            try { $toolsForm.UseWaitCursor=$true; Start-OperationProgress $toolText; & $toolAction }
            catch {
                Write-ServiceLog ("ERROR in additional tool [$toolText]: " + (Get-DetailedErrorText $_))
                $toolErrorPath = New-AutomaticErrorReport $toolText $_
                try { $toolToken=Get-PortableReportToken; if(-not [string]::IsNullOrWhiteSpace($toolToken)){[void](Send-ReportToGitHub $toolErrorPath $toolToken 'errors')}; $toolToken=$null } catch { }
                [Windows.Forms.MessageBox]::Show("Операция завершилась ошибкой.`n`n$($_.Exception.Message)`n`nОтчёт: $toolErrorPath",'Ошибка','OK','Error') | Out-Null
            }
            finally { $toolsForm.UseWaitCursor=$false; Stop-OperationProgress }
        }.GetNewClosure())
        $panel.Controls.Add($toolButton,($index % 2),[math]::Floor($index / 2))
    }
    [void]$toolsForm.ShowDialog($form)
    $toolsForm.Dispose()
}

Add-ActionButton '1. Полное обслуживание' $fullServiceWorkflow 0 0 ([Drawing.Color]::LightBlue)
Add-ActionButton '2. Диагностика и отчёт' $diagnosticsWorkflow 1 0 ([Drawing.Color]::Lavender)
Add-ActionButton '3. Очистка и ускорение' $cleanupWorkflow 0 1 ([Drawing.Color]::Honeydew)
Add-ActionButton '4. Безопасность и блокировщик' $securityWorkflow 1 1 ([Drawing.Color]::MistyRose)
Add-ActionButton '5. Zapret и проверка YouTube' $zapretWorkflow 0 2 ([Drawing.Color]::LightCyan)
Add-ActionButton '6. Дополнительные инструменты' $additionalToolsAction 1 2 ([Drawing.Color]::LightYellow)

Write-ServiceLog "$AppName $AppVersion started."
[void]$form.ShowDialog()
