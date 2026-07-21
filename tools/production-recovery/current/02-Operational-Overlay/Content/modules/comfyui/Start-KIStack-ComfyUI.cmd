@echo off
rem KI-STACK-COMFYUI-MANAGED
setlocal EnableExtensions DisableDelayedExpansion
set "COMFY_ROOT=C:\KI-Stack\ComfyUI"
set "COMFY_PYTHON=C:\KI-Stack\python\venvs\comfyui\Scripts\python.exe"
set "MODEL_CONFIG=C:\KI-Stack\modules\comfyui\extra_model_paths.yaml"
set "COMFY_INPUT=C:\KI-Stack\data\comfyui\input"
set "COMFY_OUTPUT=C:\KI-Stack\data\comfyui\output"
set "COMFY_USER=C:\KI-Stack\data\comfyui\user"
set "COMFY_DB_DIR=C:\KI-Stack\ComfyUI\user"
set "PYTHONNOUSERSITE=1"
set "PIP_DISABLE_PIP_VERSION_CHECK=1"

if not exist "%COMFY_PYTHON%" (
  echo FEHLER: ComfyUI-Python fehlt: %COMFY_PYTHON%
  exit /b 1
)
if not exist "%COMFY_ROOT%\main.py" (
  echo FEHLER: ComfyUI main.py fehlt: %COMFY_ROOT%\main.py
  exit /b 1
)
for %%D in ("%COMFY_INPUT%" "%COMFY_OUTPUT%" "%COMFY_USER%" "%COMFY_DB_DIR%") do (
  if not exist "%%~D" mkdir "%%~D" 2>nul
  if not exist "%%~D" (
    echo FEHLER: ComfyUI-Datenverzeichnis konnte nicht angelegt werden: %%~D
    exit /b 1
  )
)

pushd "%COMFY_ROOT%"
"%COMFY_PYTHON%" "%COMFY_ROOT%\main.py" --listen "127.0.0.1" --port 8188 --extra-model-paths-config "%MODEL_CONFIG%" --input-directory "%COMFY_INPUT%" --output-directory "%COMFY_OUTPUT%" --user-directory "%COMFY_USER%" --enable-manager
set "EXITCODE=%ERRORLEVEL%"
popd
exit /b %EXITCODE%
