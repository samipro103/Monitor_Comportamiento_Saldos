@echo off
setlocal
cd /d "%~dp0"
title Verificar config.json

echo.
echo CARPETA:
echo %CD%
echo.
echo CONTENIDO DE config.json:
echo ------------------------------------------------------------
type config.json
echo ------------------------------------------------------------
echo.
echo Luego ejecuta ABRIR_WEB_LOCAL.bat y abre:
echo http://127.0.0.1:43213/DIAGNOSTICO_CONFIG.html
echo.
pause
