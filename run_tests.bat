@echo off
:: Run tests and capture output
:: Locate plenary.nvim in local pack directory
set PLENARY_PATH=%LOCALAPPDATA%\nvim-data\site\pack\packer\start\plenary.nvim

:: Verify plenary path existence (simple check)
if not exist "%PLENARY_PATH%" (
    echo Plenary not found at %PLENARY_PATH%
    echo Please ensure the path to plenary.nvim in run_tests.bat matches your Neovim installation.
    exit /b 1
)

:: Run tests and capture output
:: Add plenary to rtp dynamically via -c
nvim --headless -u tests/minimal_init.lua ^
    -c "lua vim.opt.rtp:append('%PLENARY_PATH: \\=\\%')" ^
    -c "lua require('plenary.test_harness').test_directory('tests/spec/', {minimal_init='tests/minimal_init.lua'})" ^
    +qa > test_output.txt 2>&1

type test_output.txt

:: Extract failures and errors using findstr
set /a failures=0
set /a errors=0

for /f "tokens=3" %%i in ('findstr "Failed :" test_output.txt') do set /a failures+=%%i
for /f "tokens=3" %%i in ('findstr "Errors :" test_output.txt') do set /a errors+=%%i

echo ----------------------------------------
if %failures% EQU 0 if %errors% EQU 0 (
    echo SUMMARY: All tests passed successfully.
    del test_output.txt
    exit /b 0
) else (
    echo SUMMARY: Tests failed (%failures% failures, %errors% errors).
    del test_output.txt
    exit /b 1
)
