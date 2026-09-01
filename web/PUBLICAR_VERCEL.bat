@echo off
setlocal
cd /d "%~dp0"
title Publicar Control de Saldos
where npx >nul 2>&1
if errorlevel 1 (
 echo Instala Node.js LTS primero.
 pause
 exit /b 1
)
npx vercel@latest --prod
pause
