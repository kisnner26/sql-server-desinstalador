@echo off
setlocal
rem =============================================================================
rem  Lanzador de doble clic para el asistente grafico del desinstalador de
rem  SQL Server. Reabre el .ps1 con privilegios elevados automaticamente.
rem  Desarrollado por: Kisnner Obando
rem =============================================================================
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0Uninstall-SqlServer.ps1\"'"
