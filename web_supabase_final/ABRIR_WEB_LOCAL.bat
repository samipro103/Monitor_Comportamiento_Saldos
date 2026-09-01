@echo off
setlocal
cd /d "%~dp0"
title Control de Saldos - Historico Profundo v2.3

echo.
echo ============================================================
echo   CONTROL DE SALDOS - HISTORICO PROFUNDO v2.3
echo   Carpeta: %CD%
echo   Puerto: 43213
echo ============================================================
echo.

start "" http://127.0.0.1:43213
python -m http.server 43213 --bind 127.0.0.1
pause
