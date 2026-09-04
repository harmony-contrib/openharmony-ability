::Just run this script on Windows
set SCRIPT_DIR=%~dp0

:: Wipe stale package metadata + ArkTS source. The whole package/ tree is
:: build output (gitignored since issue #87 minor-8) — everything under it
:: is regenerated below from native_ability/.
del /q "%SCRIPT_DIR%package\oh-package.json5" 2>nul
del /q "%SCRIPT_DIR%package\index.ets" 2>nul
del /q "%SCRIPT_DIR%package\build-profile.json5" 2>nul
del /q "%SCRIPT_DIR%package\BuildProfile.ets" 2>nul
del /q "%SCRIPT_DIR%package\hvigorfile.ts" 2>nul
del /q "%SCRIPT_DIR%package\obfuscation-rules.txt" 2>nul
del /q "%SCRIPT_DIR%package\consumer-rules.txt" 2>nul
rmdir /s /q "%SCRIPT_DIR%package\src\main\ets" 2>nul
rmdir /s /q "%SCRIPT_DIR%dist" 2>nul

:: Copy the source-package metadata (ohpm needs `oh-package.json5` at
:: the HAR root — see ohpm error 00617204). These mirror the layout of
:: `native_ability/` which is the canonical source package
:: (@ohos-rs/ability).
copy /Y "%SCRIPT_DIR%native_ability\oh-package.json5" "%SCRIPT_DIR%package\oh-package.json5" >nul
copy /Y "%SCRIPT_DIR%native_ability\index.ets" "%SCRIPT_DIR%package\index.ets" >nul
copy /Y "%SCRIPT_DIR%native_ability\build-profile.json5" "%SCRIPT_DIR%package\build-profile.json5" >nul
copy /Y "%SCRIPT_DIR%native_ability\BuildProfile.ets" "%SCRIPT_DIR%package\BuildProfile.ets" >nul
copy /Y "%SCRIPT_DIR%native_ability\hvigorfile.ts" "%SCRIPT_DIR%package\hvigorfile.ts" >nul
copy /Y "%SCRIPT_DIR%native_ability\obfuscation-rules.txt" "%SCRIPT_DIR%package\obfuscation-rules.txt" >nul
copy /Y "%SCRIPT_DIR%native_ability\consumer-rules.txt" "%SCRIPT_DIR%package\consumer-rules.txt" >nul

:: ETS source tree.
xcopy "%SCRIPT_DIR%native_ability\src\main\ets\*" "%SCRIPT_DIR%package\src\main\ets\" /E /I /Y >nul

:: Resources (color.json etc.). The package/ tree is fully generated now
:: (issue #87 minor-8) — a fresh clone has no tracked resources to reuse,
:: so mirror them from native_ability like every other package input.
xcopy "%SCRIPT_DIR%native_ability\src\main\resources\*" "%SCRIPT_DIR%package\src\main\resources\" /E /I /Y >nul

:: Aggregate the 13 bridge plugins into the package so the HAR is a
:: self-contained `@ohos-rs/ability` (base + all plugins). Consumers depend on a
:: single `@ohos-rs/ability` HAR and import plugin classes from it directly.
:: See pack-plugins.ps1 for the barrel + import-rewrite mechanism.
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%pack-plugins.ps1" "%SCRIPT_DIR%"
if errorlevel 1 (
  echo [pack] plugin aggregation failed 1>&2
  exit /b 1
)

tar -czf ability.har package
