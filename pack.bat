::Just run this script on Windows
set SCRIPT_DIR=%~dp0

rmdir /s /q "%SCRIPT_DIR%package\src\main\ets" 2>nul
rmdir /s /q "%SCRIPT_DIR%dist" 2>nul
xcopy "%SCRIPT_DIR%native_ability\src\main\ets\*" "%SCRIPT_DIR%package\src\main\ets\" /E /I /Y >nul

tar -czf ability.har package
