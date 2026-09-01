@echo off
setlocal
cd /d "%~dp0"
title Comprobar Web Supabase v2.4

echo.
echo ============================================================
echo   COMPROBACION WEB SUPABASE v2.4
echo   Carpeta: %CD%
echo ============================================================
echo.

if not exist index.html (
  echo ERROR: No existe index.html en esta carpeta.
  pause
  exit /b 1
)

if not exist app.js (
  echo ERROR: No existe app.js.
  pause
  exit /b 1
)

if not exist config.json (
  echo ERROR: No existe config.json.
  pause
  exit /b 1
)

findstr /C:"web_summary_deep" app.js >nul
if errorlevel 1 (
  echo ERROR: Este app.js NO es la version Supabase.
  pause
  exit /b 1
)

findstr /C:"TU_PROJECT_REF" config.json >nul
if not errorlevel 1 (
  echo ERROR: config.json aun tiene TU_PROJECT_REF.
  echo Ejecuta CONFIGURAR_WEB.bat primero.
  pause
  exit /b 1
)

findstr /C:"PEGA_AQUI" config.json >nul
if not errorlevel 1 (
  echo ERROR: config.json aun tiene PEGA_AQUI.
  echo Ejecuta CONFIGURAR_WEB.bat primero.
  pause
  exit /b 1
)

echo OK: index.html presente
echo OK: app.js usa web_summary_deep
echo OK: config.json esta configurado
echo.
echo BOTON ESPERADO EN LA WEB: Actualizar vista
echo VERSION ESPERADA: SUPABASE-V2.4
echo.
if exist ".vercel\project.json" (
  echo OK: Esta carpeta ya esta enlazada con un proyecto Vercel.
) else (
  echo AVISO: No existe .vercel\project.json
  echo Si quieres conservar el MISMO proyecto/link, primero copia estos archivos
  echo dentro de la carpeta web que ya estaba enlazada a monitor-saldos.
)
echo.
pause
