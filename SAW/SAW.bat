@echo off
:: ============================================================
:: Server Access Workbench (SAW) Launcher
:: Double-click this file to start the application.
:: ============================================================
title Server Access Workbench — CyberArk Operations Console
powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File "%~dp0SAW.ps1"
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo An error occurred. Exit code: %ERRORLEVEL%
    pause
)
