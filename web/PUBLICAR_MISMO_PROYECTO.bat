@echo off
setlocal
cd /d "%~dp0"
title Publicar Web Supabase v2.4

echo.
echo ============================================================
echo   PUBLICAR MISMO PROYECTO VERCEL
echo   Carpeta: %CD%
echo ============================================================
echo.

if not exist ".vercel\project.json" (
  echo ERROR: Esta carpeta NO esta enlazada a Vercel.
  echo.
  echo Para conservar tu mismo link, NO publiques desde aqui todavia.
  echo Copia estos archivos dentro de:
  echo C:\Users\SAMUEL\Desktop\Monitor_Comportamiento_Saldos\web
  echo reemplazando los archivos existentes, PERO deja intacta la carpeta .vercel.
  echo.
  pause
  exit /b 1
)

findstr /C:"web_summary_deep" app.js >nul
if errorlevel 1 (
  echo ERROR: app.js no contiene web_summary_deep.
  pause
  exit /b 1
)

findstr /C:"TU_PROJECT_REF" config.json >nul
if not errorlevel 1 (
  echo ERROR: Primero ejecuta CONFIGURAR_WEB.bat.
  pause
  exit /b 1
)

findstr /C:"PEGA_AQUI" config.json >nul
if not errorlevel 1 (
  echo ERROR: Primero ejecuta CONFIGURAR_WEB.bat.
  pause
  exit /b 1
)

echo Publicando SUPABASE-V2.4 en el proyecto ya enlazado...
echo.
npx vercel@latest --prod --yes
echo.
echo ============================================================
echo Cuando termine, abre tu MISMO dominio.
echo La pagina correcta debe mostrar: "Actualizar vista"
echo ============================================================
pause
