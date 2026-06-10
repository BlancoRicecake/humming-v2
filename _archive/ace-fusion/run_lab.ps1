# ace-fusion lab launcher — starts backend(:8000), orchestrator(:8200), web(:5273)
# Each service opens in its own PowerShell window. Ctrl+C in a window stops it.
$ErrorActionPreference = "Stop"
$lab = $PSScriptRoot
$root = Resolve-Path (Join-Path $lab "..\..")          # Humming V2 root
$backend = Join-Path $root "backend"
$server = Join-Path $lab "server"
$web = Join-Path $lab "web"

Write-Host "ace-fusion lab @ $lab" -ForegroundColor Cyan

# --- 1) orchestrator venv + deps (idempotent) ---
$serverPy = Join-Path $server ".venv\Scripts\python.exe"
if (-not (Test-Path $serverPy)) {
  Write-Host "[server] creating venv + installing deps..." -ForegroundColor Yellow
  python -m venv (Join-Path $server ".venv")
  & $serverPy -m pip install --quiet --upgrade pip
  & $serverPy -m pip install --quiet -r (Join-Path $server "requirements.txt")
}

# --- 2) backend (:8000) ---
$backendPy = Join-Path $backend ".venv\Scripts\python.exe"
if (-not (Test-Path $backendPy)) { $backendPy = "python" }  # fall back to PATH python
Write-Host "[backend] starting on :8000 (CREPE needs torch/torchcrepe installed)" -ForegroundColor Green
Start-Process powershell -ArgumentList @(
  "-NoExit", "-Command",
  "Set-Location '$backend'; & '$backendPy' -m uvicorn app.main:app --port 8000 --reload"
)

# --- 3) orchestrator (:8200) ---
Write-Host "[server] starting on :8200" -ForegroundColor Green
Start-Process powershell -ArgumentList @(
  "-NoExit", "-Command",
  "Set-Location '$server'; & '$serverPy' -m uvicorn main:app --port 8200 --reload"
)

# --- 4) web (:5273) ---
if (-not (Test-Path (Join-Path $web "node_modules"))) {
  Write-Host "[web] npm install..." -ForegroundColor Yellow
  Push-Location $web; npm install; Pop-Location
}
Write-Host "[web] starting on :5273" -ForegroundColor Green
Start-Process powershell -ArgumentList @(
  "-NoExit", "-Command",
  "Set-Location '$web'; npm run dev"
)

Write-Host "`n→ open http://localhost:5273 (give the servers ~5s to boot)" -ForegroundColor Cyan
