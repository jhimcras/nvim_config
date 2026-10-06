@echo off

setlocal
cd /d "%~dp0"
set "NVIM_TEST_TARGET=%~1"
if not defined NVIM_TEST_TARGET set "NVIM_TEST_TARGET=tests/spec"

:: Use the same runner and real process exit status as the Unix entry point.
nvim --headless -u tests/minimal_init.lua -i NONE -l tests/run_unit.lua
exit /b %errorlevel%
