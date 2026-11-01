@echo off
cd /d "%~dp0"
rem Huan luyen long-range v2.1 tren may nay (thay cho Colab). Chay lai de tiep tuc tu buoc dang do.
python backend\scripts\run_v21_local.py %*
pause
