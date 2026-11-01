@echo off
cd /d "%~dp0"
python tool/run_web.py --open %*
if errorlevel 1 pause
