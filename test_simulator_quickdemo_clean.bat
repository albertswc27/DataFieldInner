@echo off
setlocal

REM Ejecucion limpia para QA del Quick Demo:
REM 1) Cierra simulator.exe
REM 2) Compila y firma
REM 3) Abre simulador
REM 4) Carga el datafield con monkeydo

cd /d "%~dp0"

if "%GarminIQ%"=="" (
    set "SDK_BIN=%APPDATA%\Garmin\ConnectIQ\Sdks\connectiq-sdk-win-8.2.3-2025-08-11-cac5b3b21\bin"
) else (
    set "SDK_BIN=%GarminIQ%"
)

set "DEVICE=fenix7pro"
set "DEV_KEY=%USERPROFILE%\.connectiq\keys\developer_key.der"
set "OUT_DIR=C:\ciq_temp"
set "OUT_PRG=%OUT_DIR%\InnerDataField1-quickdemo-clean.prg"
set "CIQ_ROOT=%APPDATA%\Garmin\ConnectIQ"
set "SIM_INI=%CIQ_ROOT%\simulator.ini"
set "APPS_DIR=%CIQ_ROOT%\Apps"

if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"

echo [0/4] Cerrando simulador anterior...
taskkill /IM simulator.exe /F >nul 2>&1
taskkill /IM java.exe /FI "WINDOWTITLE eq monkeydo*" >nul 2>&1

echo [0.1/4] Limpiando cache de simulador...
if exist "%SIM_INI%" del /q "%SIM_INI%" >nul 2>&1
if exist "%APPS_DIR%" del /q "%APPS_DIR%\*" >nul 2>&1
if exist "%OUT_PRG%" del /q "%OUT_PRG%" >nul 2>&1
ping 127.0.0.1 -n 2 >nul

echo [1/4] Compilando y firmando (%DEVICE%)...
call "%SDK_BIN%\monkeyc.bat" -f monkey.jungle -o "%OUT_PRG%" -d %DEVICE% -y "%DEV_KEY%"
if errorlevel 1 (
    echo [ERROR] Fallo la compilacion.
    exit /b 1
)

echo [2/4] Abriendo simulador...
start "" "%SDK_BIN%\simulator.exe"
ping 127.0.0.1 -n 5 >nul

echo [3/4] Cargando datafield...
start "monkeydo-quickdemo" /min cmd /c ""%SDK_BIN%\monkeydo.bat" "%OUT_PRG%" %DEVICE%"
ping 127.0.0.1 -n 3 >nul

echo [4/4] Listo.
echo       PRG: %OUT_PRG%
endlocal
