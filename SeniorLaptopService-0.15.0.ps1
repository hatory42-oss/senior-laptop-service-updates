[CmdletBinding()]
param(
    [switch]$Maintenance,
    [switch]$UpdateZapretLists
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$AppName = 'Senior Laptop Service'
$AppVersion = '0.15.0'
$InstallRoot = Join-Path $env:ProgramData 'SeniorLaptopService'
$ZapretRoot = Join-Path $InstallRoot 'Zapret'
$LogRoot = Join-Path $InstallRoot 'Logs'
$PortableSecretRoot = Join-Path $PSScriptRoot '.secrets'
$ReportTokenPath = Join-Path $PortableSecretRoot 'report-upload.token'

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
}

function Test-Administrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-SafeProperty([object]$Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    $property.Value
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
    $local = $env:LOCALAPPDATA
    $roaming = $env:APPDATA
    @(
        $env:TEMP,
        (Join-Path $local 'Temp'),
        (Join-Path $local 'Yandex\YandexBrowser\User Data\Default\Cache'),
        (Join-Path $local 'Yandex\YandexBrowser\User Data\Default\Code Cache'),
        (Join-Path $local 'Yandex\YandexBrowser\User Data\Default\GPUCache'),
        (Join-Path $local 'Google\Chrome\User Data\Default\Cache'),
        (Join-Path $local 'Google\Chrome\User Data\Default\Code Cache'),
        (Join-Path $local 'Microsoft\Edge\User Data\Default\Cache'),
        (Join-Path $local 'Microsoft\Edge\User Data\Default\Code Cache')
    ) + @(Get-ChildItem (Join-Path $roaming 'Mozilla\Firefox\Profiles') -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'cache2' })
}

function Invoke-SafeCleanup {
    Write-ServiceLog 'Safe cleanup started.'
    $bytes = 0L
    foreach ($target in @(Get-CacheTargets | Select-Object -Unique)) {
        try { $bytes += Remove-DirectoryContentsSafely $target } catch { Write-ServiceLog "Skipped $target : $($_.Exception.Message)" }
    }
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
    $manifestBytes = Get-ResponsiveHttpsBytes $manifestRequestUrl 20
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
    $scriptBytes = Get-ResponsiveHttpsBytes $scriptRequestUrl 60
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
$form.Size = New-Object Drawing.Size(820,700)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object Drawing.Size(760,650)
$form.Font = New-Object Drawing.Font('Segoe UI',10)

$top = New-Object Windows.Forms.Label
$top.Dock = 'Top'; $top.Height = 45; $top.Padding = New-Object Windows.Forms.Padding(10,8,10,0)
$top.Text = if (Test-Administrator) { 'Права администратора: ДА' } else { 'Права администратора: НЕТ — системные действия будут ограничены' }
$top.ForeColor = if (Test-Administrator) { [Drawing.Color]::DarkGreen } else { [Drawing.Color]::DarkRed }
$form.Controls.Add($top)

$buttons = New-Object Windows.Forms.TableLayoutPanel
$buttons.Dock = 'Top'; $buttons.Height = 345; $buttons.ColumnCount = 3; $buttons.RowCount = 5; $buttons.Padding = New-Object Windows.Forms.Padding(8,4,8,4)
1..3 | ForEach-Object { [void]$buttons.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,33.33))) }
1..5 | ForEach-Object { [void]$buttons.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,20))) }
$form.Controls.Add($buttons)

$script:LogBox = New-Object Windows.Forms.TextBox
$script:LogBox.Dock = 'Fill'; $script:LogBox.Multiline = $true; $script:LogBox.ReadOnly = $true
$script:LogBox.ScrollBars = 'Vertical'; $script:LogBox.BackColor = [Drawing.Color]::White
$form.Controls.Add($script:LogBox)

function Add-ActionButton([string]$Text, [scriptblock]$Action, [int]$Column, [int]$Row, [Drawing.Color]$Color = [Drawing.Color]::WhiteSmoke) {
    $button = New-Object Windows.Forms.Button
    $button.Text = $Text; $button.Dock = 'Fill'; $button.Margin = New-Object Windows.Forms.Padding(5); $button.BackColor = $Color
    $button.Add_Click({
        try { $form.UseWaitCursor = $true; & $Action }
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
        finally { $form.UseWaitCursor = $false }
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
    $avast = Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { [string](Get-SafeProperty $_ 'DisplayName') -match 'Avast' }
    Write-ServiceLog ('Avast products found: ' + @($avast).Count)
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

$removeAvast = {
    $items = @(Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { [string](Get-SafeProperty $_ 'DisplayName') -match 'Avast' })
    if (-not $items) { [Windows.Forms.MessageBox]::Show('Avast не найден.','Проверка') | Out-Null; return }
    $names = @($items | ForEach-Object { Get-SafeProperty $_ 'DisplayName' } | Sort-Object -Unique) -join "`n"
    if ([Windows.Forms.MessageBox]::Show("Найдено:`n$names`n`nЗапустить штатное удаление Avast?",'Удаление Avast','YesNo','Warning') -ne 'Yes') { return }
    foreach ($item in $items) {
        $quietCommand = Get-SafeProperty $item 'QuietUninstallString'
        $normalCommand = Get-SafeProperty $item 'UninstallString'
        $cmd = if ($quietCommand) { $quietCommand } else { $normalCommand }
        if ($cmd) { Write-ServiceLog "Starting vendor uninstaller: $(Get-SafeProperty $item 'DisplayName')"; Start-Process cmd.exe -ArgumentList '/c', $cmd -Verb RunAs -Wait }
    }
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
    Write-ServiceLog 'Checking official GitHub release for Zapret...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{ 'User-Agent'='SeniorLaptopService/0.9'; 'Accept'='application/vnd.github+json' }
    $release = Invoke-RestMethod 'https://api.github.com/repos/Flowseal/zapret-discord-youtube/releases/latest' -Headers $headers
    $asset = $release.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
    if (-not $asset) { throw 'Official release has no ZIP asset.' }
    $zip = Join-Path $env:TEMP ('zapret-' + [guid]::NewGuid().ToString('N') + '.zip')
    $stage = Join-Path $env:TEMP ('zapret-' + [guid]::NewGuid().ToString('N'))
    Invoke-WebRequest $asset.browser_download_url -Headers $headers -OutFile $zip -UseBasicParsing
    Ensure-Directory $stage; Expand-Archive -LiteralPath $zip -DestinationPath $stage -Force
    $source = Get-ChildItem $stage -Filter service.bat -Recurse | Select-Object -First 1 -ExpandProperty DirectoryName
    if (-not $source) { throw 'service.bat not found in official archive.' }
    $userFiles = @{}
    if (Test-Path $ZapretRoot) { Get-ChildItem $ZapretRoot -Filter '*-user.txt' -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $userFiles[$_.Name] = Get-Content -Raw $_.FullName } }
    Ensure-Directory $ZapretRoot
    Copy-Item (Join-Path $source '*') $ZapretRoot -Recurse -Force
    foreach ($name in $userFiles.Keys) { Set-Content -LiteralPath (Join-Path (Join-Path $ZapretRoot 'lists') $name) -Value $userFiles[$name] -Encoding UTF8 }
    Set-Content -LiteralPath (Join-Path $ZapretRoot '.installed-version') -Value $release.tag_name -Encoding ASCII
    Remove-Item $zip -Force -ErrorAction SilentlyContinue; Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    Write-ServiceLog "Zapret $($release.tag_name) installed from official GitHub release. Launching service menu."
    Start-Process (Join-Path $ZapretRoot 'service.bat') -Verb RunAs
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

Add-ActionButton 'Аудит системы' $audit 0 0
Add-ActionButton 'Безопасная очистка' $clean 1 0 ([Drawing.Color]::Honeydew)
Add-ActionButton 'Исправить 100 окон Яндекса' $fixYandex 2 0 ([Drawing.Color]::LightYellow)
Add-ActionButton 'Удалить Avast' $removeAvast 0 1 ([Drawing.Color]::MistyRose)
Add-ActionButton 'Оптимизация производительности' $optimize 1 1
Add-ActionButton 'Установить еженедельную очистку' $schedule 2 1
Add-ActionButton 'Zapret: установить / обновить' $zapretUpdate 0 2 ([Drawing.Color]::LightCyan)
Add-ActionButton 'Zapret: открыть управление' $zapretOpen 1 2
Add-ActionButton 'Отправить отчёт в GitHub' $reportAction 2 2 ([Drawing.Color]::Lavender)
Add-ActionButton 'DISM + SFC' $repair 0 3
Add-ActionButton 'Восстановление Windows' $restore 1 3 ([Drawing.Color]::MistyRose)
Add-ActionButton 'Проверить обновления панели' { Invoke-SelfUpdate } 2 3 ([Drawing.Color]::LightCyan)
$guideButton = Add-ActionButton 'Создать памятку и предварительные рекомендации' $recommendationsAction 0 4 ([Drawing.Color]::Honeydew)
$buttons.SetColumnSpan($guideButton,2)
Add-ActionButton 'Проверить заключение GitHub' $checkDiagnosisAction 2 4 ([Drawing.Color]::Lavender)

Write-ServiceLog "$AppName $AppVersion started."
[void]$form.ShowDialog()
