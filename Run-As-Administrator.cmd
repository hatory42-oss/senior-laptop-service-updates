@echo off
setlocal
cd /d "%~dp0"

if not exist "%~dp0Start-SeniorLaptopService.ps1" (
    echo ERROR: Start-SeniorLaptopService.ps1 was not found.
    echo Copy the complete Senior Laptop Service folder to the USB drive.
    pause
    exit /b 2
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "try { $argsLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File ""%~dp0Start-SeniorLaptopService.ps1"" -TargetScript ""%~dp0SeniorLaptopService.ps1""'; $process = Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList $argsLine -Wait -PassThru; exit $process.ExitCode } catch { Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Senior Laptop Service','OK','Error'); exit 1 }"

if errorlevel 1 (
    echo.
    echo Senior Laptop Service did not start. Read the message on screen.
    echo If an error report was created, send SeniorLaptopService-STARTUP-ERROR.txt for analysis.
    pause
)
