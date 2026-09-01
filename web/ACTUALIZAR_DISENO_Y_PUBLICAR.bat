@echo off
setlocal
title Actualizar diseño Monitor de Saldos v2.6

set "WEB=C:\Users\SAMUEL\Desktop\Monitor_Comportamiento_Saldos\web"

echo.
echo ============================================================
echo   MONITOR DE SALDOS - DISEÑO v2.6
echo   FUENTE GRANDE + RESPONSIVE
echo ============================================================
echo.

if not exist "%~dp0styles.css" (
  echo ERROR: No encuentro styles.css al lado de este BAT.
  echo Extrae primero TODO el ZIP a una carpeta.
  pause
  exit /b 1
)

if not exist "%WEB%\index.html" (
  echo ERROR: No encuentro la carpeta web correcta.
  pause
  exit /b 1
)

if not exist "%WEB%\.vercel\project.json" (
  echo ERROR: La carpeta web no esta enlazada al proyecto Vercel.
  echo No se publicara nada.
  pause
  exit /b 1
)

echo Copiando SOLO styles.css...
copy /Y "%~dp0styles.css" "%WEB%\styles.css" >nul

if errorlevel 1 (
  echo ERROR copiando styles.css.
  pause
  exit /b 1
)

echo.
echo OK: Diseño actualizado.
echo NO se modifico app.js, config.json, index.html ni Supabase.
echo.
echo Publicando en el MISMO proyecto Vercel...
echo.

cd /d "%WEB%"
npx vercel@latest --prod --yes

echo.
echo ============================================================
echo LISTO.
echo Abre el mismo dominio y usa Ctrl+F5.
echo En telefono basta con cerrar y volver a abrir la pagina.
echo ============================================================
pause
