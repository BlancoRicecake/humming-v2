# Launch the ACE-Step REST server for the ace-fusion lab.
# Bakes in the fixes discovered during bring-up:
#   - PYTHONUTF8=1 / PYTHONIOENCODING=utf-8  -> ACE-Step crashes on Korean (cp949)
#     Windows locale when it writes an em-dash; UTF-8 mode fixes it.
#   - Port 8011 (default :8001 was occupied by another local backend here).
#   - ACESTEP_INIT_LLM=false -> DiT-only (4GB Tier1 safety; avoids LLM-VRAM OOM #198).
# The orchestrator must point at this port:  ACE_BASE_URL=http://127.0.0.1:8011
$ErrorActionPreference = "Stop"
$ace = "C:\Users\jlion\Documents\Humtrack\ACE-Step-1.5"
$uv  = "$env:USERPROFILE\.local\bin\uv.exe"

$env:ACESTEP_API_HOST = "127.0.0.1"
$env:ACESTEP_API_PORT = "8011"
$env:ACESTEP_INIT_LLM = "false"
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"
Remove-Item Env:VIRTUAL_ENV -ErrorAction SilentlyContinue

Set-Location $ace
Write-Host "Starting ACE-Step API on http://127.0.0.1:8011 (UTF-8, DiT-only)..." -ForegroundColor Green
& $uv run acestep-api
