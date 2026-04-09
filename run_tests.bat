@echo off

:: Run tests and capture output
nvim --headless -u tests/minimal_init.lua ^
    -c "lua require('plenary.test_harness').test_directory('tests/spec/', {minimal_init='tests/minimal_init.lua'})" ^
    +qa > test_output.txt 2>&1

:: Print output without triggering batch errors
type test_output.txt

:: Extract failures and errors using findstr
set /a failures=0
set /a errors=0

for /f "tokens=3" %%i in ('findstr /c:"Failed :" test_output.txt') do set /a failures+=%%i
for /f "tokens=3" %%i in ('findstr /c:"Errors :" test_output.txt') do set /a errors+=%%i

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
