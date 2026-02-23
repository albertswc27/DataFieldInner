@echo off
setlocal

REM Script para compilar y ejecutar el Data Field en el simulador.
REM Firma el PRG con la clave de Connect IQ y usa una ruta ASCII para evitar problemas.

cd /d "%~dp0"

if "%GarminIQ%"=="" (
    set "SDK_BIN=%APPDATA%\Garmin\ConnectIQ\Sdks\connectiq-sdk-win-8.2.3-2025-08-11-cac5b3b21\bin"
) else (
    set "SDK_BIN=%GarminIQ%"
)

set "DEVICE=fenix7pro"
set "DEV_KEY=%USERPROFILE%\.connectiq\keys\developer_key.der"
set "OUT_DIR=C:\ciq_temp"
set "OUT_PRG=%OUT_DIR%\InnerDataField1.prg"

if not exist "%SDK_BIN%\monkeyc.bat" (
    echo [ERROR] No se encontro monkeyc.bat en "%SDK_BIN%".
    goto :end
)

if not exist "%SDK_BIN%\monkeydo.bat" (
    echo [ERROR] No se encontro monkeydo.bat en "%SDK_BIN%".
    goto :end
)

if not exist "%DEV_KEY%" (
    echo [ERROR] No se encontro la clave de desarrollador: "%DEV_KEY%".
    echo         Genera o instala la clave desde la extension Monkey C de VS Code.
    goto :end
)

if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"

echo [1/2] Compilando y firmando para %DEVICE%...
call "%SDK_BIN%\monkeyc.bat" -f monkey.jungle -o "%OUT_PRG%" -d %DEVICE% -y "%DEV_KEY%"
if errorlevel 1 (
    echo [ERROR] Fallo la compilacion.
    goto :end
)

echo [2/2] Ejecutando en el simulador...
tasklist /FI "IMAGENAME eq simulator.exe" | find /I "simulator.exe" >nul
if errorlevel 1 (
    start "" "%SDK_BIN%\simulator.exe"
    timeout /t 2 >nul
)

call "%SDK_BIN%\monkeydo.bat" "%OUT_PRG%" %DEVICE%

:end
pause
