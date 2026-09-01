@echo off
setlocal
cd /d "%~dp0"
python configurar_web.py
if errorlevel 1 pause
