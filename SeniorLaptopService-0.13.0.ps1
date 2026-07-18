[CmdletBinding()]
param(
    [switch]$Maintenance,
    [switch]$UpdateZapretLists
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$AppName = 'Senior Laptop Service'
$AppVersion = '0.13.0'
$InstallRoot = Join-Path $env:ProgramData 'SeniorLaptopService'
$ZapretRoot = Join-Path $InstallRoot 'Zapret'
$LogRoot = Join-Path $InstallRoot 'Logs'
$PortableSecretRoot = Join-Path $PSScriptRoot '.secrets'
$ReportTokenPath = Join-Path $PortableSecretRoot 'report-upload.token'

function Ensure-Directory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
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
    $desktop = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($desktop) -or -not (Test-Path $desktop)) { $desktop = $env:TEMP }
    $path = Join-Path $desktop ('SeniorLaptopService-ERROR-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
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
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $cpu = @(Get-CimInstance Win32_Processor | ForEach-Object { [ordered]@{ name=$_.Name; cores=$_.NumberOfCores; logical_processors=$_.NumberOfLogicalProcessors } })
    $disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { [ordered]@{ drive=$_.DeviceID; size_bytes=[int64]$_.Size; free_bytes=[int64]$_.FreeSpace } })
    $events = @(Get-WinEvent -FilterHashtable @{ LogName=@('System','Application'); Level=@(1,2,3); StartTime=(Get-Date).AddDays(-7) } -MaxEvents 80 -ErrorAction SilentlyContinue | ForEach-Object {
        [ordered]@{ time_utc=$_.TimeCreated.ToUniversalTime().ToString('o'); log=$_.LogName; provider=$_.ProviderName; event_id=$_.Id; level=$_.LevelDisplayName; message=([string]$_.Message).Substring(0,[math]::Min(1200,([string]$_.Message).Length)) }
    })
    $apps = @(Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.DisplayName) } | Sort-Object -Property DisplayName -Unique | ForEach-Object { [ordered]@{ name=$_.DisplayName; version=$_.DisplayVersion; publisher=$_.Publisher } })
    $serviceLog = @(Get-ChildItem $LogRoot -Filter '*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | ForEach-Object { @(Get-Content $_.FullName -Tail 200 -ErrorAction SilentlyContinue) })
    [ordered]@{
        schema='senior-laptop-service-report/1'
        created_at_utc=(Get-Date).ToUniversalTime().ToString('o')
        privacy=[ordered]@{ wifi_credentials_included=$false; browser_history_included=$false; cookies_included=$false; personal_files_included=$false; hardware_serials_included=$false }
        application=[ordered]@{ name=$AppName; version=$AppVersion; recent_log=$serviceLog }
        system=[ordered]@{ manufacturer=$cs.Manufacturer; model=$cs.Model; total_memory_bytes=[int64]$cs.TotalPhysicalMemory; os=$os.Caption; os_version=$os.Version; build=$os.BuildNumber; last_boot_utc=$os.LastBootUpTime.ToUniversalTime().ToString('o'); cpu=$cpu; disks=$disks }
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

function Send-ReportToGitHub([string]$ReportPath, [string]$Token, [string]$Category = 'reports') {
    $repo = 'hatory42-oss/senior-laptop-service-reports'
    $safeComputer = ($env:COMPUTERNAME -replace '[^A-Za-z0-9._-]','_')
    $extension = [IO.Path]::GetExtension($ReportPath).ToLowerInvariant()
    if ($extension -notin @('.json','.txt')) { $extension = '.dat' }
    $safeCategory = if ($Category -eq 'errors') { 'errors' } else { 'reports' }
    $remotePath = '{0}/{1}/{2}/{3}-{4}{5}' -f $safeCategory,(Get-Date -Format 'yyyy'),(Get-Date -Format 'MM'),$safeComputer,(Get-Date -Format 'yyyyMMdd-HHmmssfff'),$extension
    $bytes = [IO.File]::ReadAllBytes($ReportPath)
    $body = @{ message="Add diagnostic report from $safeComputer"; content=[Convert]::ToBase64String($bytes); branch='main' } | ConvertTo-Json
    $headers = @{ Authorization="Bearer $Token"; Accept='application/vnd.github+json'; 'X-GitHub-Api-Version'='2022-11-28'; 'User-Agent'='SeniorLaptopService/0.13' }
    try {
        $access = Invoke-RestMethod -Method Get -Uri "https://api.github.com/repos/$repo" -Headers $headers
    } catch {
        throw ('GitHub access check failed. Use a fine-grained token for repository senior-laptop-service-reports with Contents: Read and write.' + [Environment]::NewLine + (Get-HttpErrorDetails $_))
    }
    if (-not $access.private) { throw 'Safety check failed: reports repository is not private.' }
    $uri = "https://api.github.com/repos/$repo/contents/$remotePath"
    try {
        $result = Invoke-RestMethod -Method Put -Uri $uri -Headers $headers -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json'
    } catch {
        throw ('GitHub upload failed. Confirm that Contents permission is Read and write and the token has access to senior-laptop-service-reports.' + [Environment]::NewLine + (Get-HttpErrorDetails $_))
    }
    [ordered]@{ path=$remotePath; url=$result.content.html_url; commit=$result.commit.sha }
}

function Invoke-SelfUpdate {
    $configPath = Join-Path $PSScriptRoot 'Updater.json'
    if (-not (Test-Path $configPath)) { throw 'Updater.json не найден. Укажите URL манифеста обновлений.' }
    $config = Get-Content -Raw $configPath | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($config.manifest_url) -or $config.manifest_url -like '*CHANGE-ME*') { throw 'В Updater.json ещё не указан реальный manifest_url.' }
    if (-not $config.manifest_url.StartsWith('https://')) { throw 'Обновления разрешены только через HTTPS.' }
    Write-ServiceLog "Checking update manifest: $($config.manifest_url)"
    $manifest = Invoke-RestMethod $config.manifest_url -Headers @{'User-Agent'='SeniorLaptopService-Updater/1'}
    if ([version]$manifest.version -le [version]$AppVersion) { Write-ServiceLog "No update required; current $AppVersion, remote $($manifest.version)."; return }
    if (-not $manifest.script_url.StartsWith('https://') -or $manifest.sha256 -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Некорректный или небезопасный манифест обновления.' }
    $download = Join-Path $env:TEMP ('SeniorLaptopService-' + [guid]::NewGuid().ToString('N') + '.ps1')
    Invoke-WebRequest $manifest.script_url -OutFile $download -UseBasicParsing -Headers @{'User-Agent'='SeniorLaptopService-Updater/1'}
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
    [Windows.Forms.MessageBox]::Show('Обновление установлено. Перезапустите панель.','Обновление') | Out-Null
}

if ($Maintenance) { Invoke-MaintenanceMode; exit 0 }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object Windows.Forms.Form
$form.Text = "$AppName $AppVersion"
$form.Size = New-Object Drawing.Size(820,620)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object Drawing.Size(760,560)
$form.Font = New-Object Drawing.Font('Segoe UI',10)

$top = New-Object Windows.Forms.Label
$top.Dock = 'Top'; $top.Height = 45; $top.Padding = New-Object Windows.Forms.Padding(10,8,10,0)
$top.Text = if (Test-Administrator) { 'Права администратора: ДА' } else { 'Права администратора: НЕТ — системные действия будут ограничены' }
$top.ForeColor = if (Test-Administrator) { [Drawing.Color]::DarkGreen } else { [Drawing.Color]::DarkRed }
$form.Controls.Add($top)

$buttons = New-Object Windows.Forms.TableLayoutPanel
$buttons.Dock = 'Top'; $buttons.Height = 275; $buttons.ColumnCount = 3; $buttons.RowCount = 4; $buttons.Padding = New-Object Windows.Forms.Padding(8,4,8,4)
1..3 | ForEach-Object { [void]$buttons.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,33.33))) }
1..4 | ForEach-Object { [void]$buttons.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,25))) }
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
}

$audit = {
    Write-ServiceLog 'Audit started.'
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    Write-ServiceLog "PC: $($cs.Manufacturer) $($cs.Model); RAM: $([math]::Round($cs.TotalPhysicalMemory/1GB,1)) GiB"
    Write-ServiceLog "OS: $($os.Caption), build $($os.BuildNumber); CPU: $($cpu.Name)"
    Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { Write-ServiceLog "Disk $($_.DeviceID): $([math]::Round($_.FreeSpace/1GB,1)) GiB free of $([math]::Round($_.Size/1GB,1)) GiB" }
    $avast = Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { [string]$_.DisplayName -match 'Avast' }
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
    $items = @(Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { [string]$_.DisplayName -match 'Avast' })
    if (-not $items) { [Windows.Forms.MessageBox]::Show('Avast не найден.','Проверка') | Out-Null; return }
    $names = ($items.DisplayName | Sort-Object -Unique) -join "`n"
    if ([Windows.Forms.MessageBox]::Show("Найдено:`n$names`n`nЗапустить штатное удаление Avast?",'Удаление Avast','YesNo','Warning') -ne 'Yes') { return }
    foreach ($item in $items) {
        $cmd = if ($item.QuietUninstallString) { $item.QuietUninstallString } else { $item.UninstallString }
        if ($cmd) { Write-ServiceLog "Starting vendor uninstaller: $($item.DisplayName)"; Start-Process cmd.exe -ArgumentList '/c', $cmd -Verb RunAs -Wait }
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

$reportAction = {
    Write-ServiceLog 'Creating privacy-filtered technical report...'
    $report = New-TechnicalReport
    $json = $report | ConvertTo-Json -Depth 10
    $desktop = [Environment]::GetFolderPath('Desktop')
    $reportPath = Join-Path $desktop ('SeniorLaptopService-report-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    [IO.File]::WriteAllText($reportPath,$json,[Text.UTF8Encoding]::new($true))
    $token = Get-PortableReportToken -AllowSetup
    if ([string]::IsNullOrWhiteSpace($token)) { Write-ServiceLog "Report saved locally; GitHub upload cancelled: $reportPath"; return }
    Write-ServiceLog 'Uploading report to private GitHub repository...'
    $uploaded = Send-ReportToGitHub $reportPath $token
    $token=$null
    Write-ServiceLog "Report uploaded to private GitHub path: $($uploaded.path); commit: $($uploaded.commit)"
    [Windows.Forms.MessageBox]::Show("Отчёт загружен в приватный GitHub-репозиторий.`n`nПуть: $($uploaded.path)`n`nЛокальная копия: $reportPath",'Отправлено') | Out-Null
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

Write-ServiceLog "$AppName $AppVersion started."
[void]$form.ShowDialog()
