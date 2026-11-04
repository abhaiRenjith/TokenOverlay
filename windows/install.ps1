# Installs Claude Token Overlay for the current user (no admin rights needed):
#   - copies it to %LOCALAPPDATA%\Programs\ClaudeTokenOverlay
#   - adds "Claude Token Overlay" to the Start menu
#   - opens it whenever a Claude Code session starts (SessionStart hook in ~/.claude/settings.json)
#   - starts it now
# Usage: install.bat              install or update
#        install.bat -Uninstall   remove all of the above
param([switch]$Uninstall)
$ErrorActionPreference = 'Stop'

$dest   = Join-Path $env:LOCALAPPDATA 'Programs\ClaudeTokenOverlay'
$script = Join-Path $dest 'token_overlay.py'
$lnk    = Join-Path ([Environment]::GetFolderPath('Programs')) 'Claude Token Overlay.lnk'

function Stop-Overlay {
    Get-CimInstance Win32_Process -Filter "Name LIKE 'py%'" |
        Where-Object { $_.CommandLine -like '*token_overlay.py*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# A real Python 3 with tkinter. The Microsoft Store placeholder python.exe prints
# nothing and fails, so it is skipped.
function Find-Python {
    $probe = 'import sys, tkinter; print(sys.executable)'
    foreach ($cmd in @('py', 'python')) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { continue }
        $out = if ($cmd -eq 'py') { & py -3 -c $probe 2>$null } else { & python -c $probe 2>$null }
        if ($LASTEXITCODE -eq 0 -and $out) { return ($out | Select-Object -Last 1).Trim() }
    }
}

$py = Find-Python

if ($Uninstall) {
    Stop-Overlay
    if ($py -and (Test-Path $script)) { & $py $script --uninstall-hook }
    else { Write-Warning "Could not run Python; remove the token_overlay SessionStart hook from ~/.claude/settings.json by hand." }
    Remove-Item $lnk -ErrorAction SilentlyContinue
    Remove-Item (Join-Path ([Environment]::GetFolderPath('Startup')) 'ClaudeTokenOverlay.cmd') -ErrorAction SilentlyContinue
    Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'Claude Token Overlay removed. Your settings are kept in %APPDATA%\ClaudeTokenOverlay.'
    exit 0
}

if (-not $py) {
    Write-Host 'Python 3 with tkinter was not found.'
    Write-Host 'Install it from https://www.python.org/downloads/ (tick "Add python.exe to PATH"), then run install.bat again.'
    exit 1
}
$pyw = Join-Path (Split-Path $py) 'pythonw.exe'
if (-not (Test-Path $pyw)) { $pyw = $py }

Stop-Overlay
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'token_overlay.py') $script -Force

$sc = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
$sc.TargetPath = $pyw
$sc.Arguments = "`"$script`""
$sc.WorkingDirectory = $dest
$sc.Description = 'Claude token usage overlay'
$sc.Save()

& $py $script --install-hook
if ($LASTEXITCODE -ne 0) { throw 'Could not add the Claude Code hook (see the error above).' }

Start-Process $pyw -ArgumentList "`"$script`""

Write-Host ''
Write-Host "Installed to $dest"
Write-Host 'It opens with every new Claude Code session (CLI, desktop app, IDE) and is in the Start menu.'
Write-Host 'Right-click the overlay to turn "Launch with Claude" off. Uninstall: install.bat -Uninstall'
