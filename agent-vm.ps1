# agent-vm (Windows / WSL2 edition)
#
# Drop-in equivalent of https://github.com/sylvinus/agent-vm for Windows.
# The macOS/Linux version runs agents inside a Lima VM; this version runs them
# inside a single shared WSL2 distribution. The command surface is intentionally
# identical so the same documentation applies on both platforms:
#
#   agent-vm setup            Create and provision the WSL2 distro (run once)
#   agent-vm claude  [args]   Run Claude Code in the distro for the current dir
#   agent-vm opencode [args]  Run OpenCode in the distro for the current dir
#   agent-vm codex   [args]   Run Codex CLI in the distro for the current dir
#   agent-vm shell            Open a shell in the distro for the current dir
#   agent-vm run <cmd>        Run a command in the distro for the current dir
#   agent-vm stop             Terminate the distro
#   agent-vm rm               Unregister (delete) the distro
#   agent-vm status           Show the distro status
#   agent-vm list             List WSL distros
#   agent-vm help             Show help
#
# Install: dot-source this file from your PowerShell profile, e.g.
#   notepad $PROFILE
#   . "$HOME\work\agent-vm-windows\agent-vm.ps1"
#
# NOTE: This implementation has been written against the documented WSL CLI but
# has NOT yet been validated on a real Windows host. Treat v1 as "needs Windows
# validation". See README.md for the known-fragile bootstrap step.

$script:AgentVmDistro    = "agent-vm"
$script:AgentVmScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function script:Test-AgentVmWsl {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        Write-Error "WSL is not installed. Run 'wsl --install' (Windows 11) then reboot, and re-run 'agent-vm setup'."
        return $false
    }
    return $true
}

function script:Test-AgentVmDistroExists {
    # wsl -l -q emits UTF-16; normalise and trim.
    $names = (wsl.exe -l -q) -split "`r?`n" | ForEach-Object { ($_ -replace "`0", "").Trim() } | Where-Object { $_ }
    return $names -contains $script:AgentVmDistro
}

function script:Test-AgentVmReady {
    if (-not (script:Test-AgentVmDistroExists)) {
        Write-Error "Distro '$($script:AgentVmDistro)' not found. Run 'agent-vm setup' first."
        return $false
    }
    return $true
}

# Replay the per-user and per-project runtime scripts, mirroring what Lima does
# on every VM start. Both are expected to be idempotent.
function script:Invoke-AgentVmRuntime {
    param([string]$CwdWin)

    # Per-user runtime lives inside the distro home (~/.agent-vm/runtime.sh).
    # Out-Host keeps these logs on screen instead of polluting the boolean
    # return value of the calling Ensure-AgentVmRunning.
    & wsl.exe -d $script:AgentVmDistro -- bash -lc 'f="$HOME/.agent-vm/runtime.sh"; if [ -f "$f" ]; then echo "Running user runtime setup..."; zsh -l "$f"; fi' | Out-Host

    # Per-project runtime lives in the repo (.agent-vm.runtime.sh) and is piped
    # in over stdin, exactly like `limactl shell ... zsh -l < script`.
    $proj = Join-Path $CwdWin ".agent-vm.runtime.sh"
    if (Test-Path -LiteralPath $proj) {
        Write-Host "Running project runtime setup..."
        Get-Content -Raw -LiteralPath $proj | & wsl.exe -d $script:AgentVmDistro --cd $CwdWin -- zsh -l | Out-Host
    }
}

# Apply per-session restrictions that have a WSL equivalent.
function script:Set-AgentVmRestrictions {
    param([hashtable]$Opts, [string]$CwdWin)

    if ($Opts.offline) {
        Write-Host "Enabling offline mode..."
        $rules = @(
            'sudo iptables -F OUTPUT',
            'sudo iptables -A OUTPUT -o lo -j ACCEPT',
            'sudo iptables -A OUTPUT -d 10.0.0.0/8 -j ACCEPT',
            'sudo iptables -A OUTPUT -d 172.16.0.0/12 -j ACCEPT',
            'sudo iptables -A OUTPUT -d 192.168.0.0/16 -j ACCEPT',
            'sudo iptables -P OUTPUT DROP'
        ) -join '; '
        & wsl.exe -d $script:AgentVmDistro -- bash -lc $rules | Out-Host
    }
    if ($Opts.readonly) {
        Write-Host "Mounting project directory as read-only..."
        & wsl.exe -d $script:AgentVmDistro --cd $CwdWin -- bash -lc 'sudo mount -o remount,ro "$PWD" 2>/dev/null || true' | Out-Host
    }
    if ($Opts.gitro) {
        Write-Host "Mounting .git directory as read-only..."
        & wsl.exe -d $script:AgentVmDistro --cd $CwdWin -- bash -lc 'if [ -d "$PWD/.git" ]; then sudo mount --bind "$PWD/.git" "$PWD/.git"; sudo mount -o remount,ro,bind "$PWD/.git"; fi' | Out-Host
    }
    if ($Opts.disk -or $Opts.memory -or $Opts.cpus) {
        Write-Warning "On Windows, disk/memory/cpus are not per-distro: configure them globally in %USERPROFILE%\.wslconfig (see README), then run 'wsl --shutdown'. Ignoring these flags."
    }
}

function script:Ensure-AgentVmRunning {
    param([hashtable]$Opts, [string]$CwdWin)

    if (-not (script:Test-AgentVmReady)) { return $false }

    if ($Opts.reset) {
        Write-Host "Resetting distro '$($script:AgentVmDistro)' (unregister + re-provision)..."
        & wsl.exe --unregister $script:AgentVmDistro | Out-Null
        if (-not (script:New-AgentVmDistro)) { return $false }
        if (-not (script:Invoke-AgentVmProvision)) { return $false }
    }

    script:Invoke-AgentVmRuntime -CwdWin $CwdWin
    script:Set-AgentVmRestrictions -Opts $Opts -CwdWin $CwdWin
    return $true
}

function script:New-AgentVmDistro {
    Write-Host "Creating WSL distro '$($script:AgentVmDistro)'..."
    # Debian matches upstream agent-vm's base (template:debian-13) and avoids the
    # Ubuntu/snap chromium issue (no snap in WSL). Requires a recent WSL (run
    # 'wsl --update'). --name keeps this distro isolated from any Debian you
    # already use. If --name is unsupported on your build, see the manual
    # `wsl --import` fallback in README.md.
    & wsl.exe --install -d Debian --name $script:AgentVmDistro --no-launch | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to create the distro. Try 'wsl --update', or use the wsl --import fallback (README.md)."
        return $false
    }
    return $true
}

function script:Invoke-AgentVmProvision {
    $setup = Join-Path $script:AgentVmScriptDir "setup-wsl2.sh"
    if (-not (Test-Path -LiteralPath $setup)) {
        Write-Error "setup-wsl2.sh not found next to agent-vm.ps1."
        return $false
    }
    Write-Host "Provisioning the distro (this takes a while the first time)..."
    # Run as root so the script can create the 'agent' user, enable systemd and
    # install packages without an interactive sudo password.
    Get-Content -Raw -LiteralPath $setup | & wsl.exe -d $script:AgentVmDistro -u root -- bash -l | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Provisioning failed."
        return $false
    }
    Write-Host "Restarting the distro to activate systemd (docker, postgres, redis)..."
    & wsl.exe --terminate $script:AgentVmDistro | Out-Null
    return $true
}

function script:Invoke-AgentVmAgent {
    param([string]$Binary, [string]$BinaryArgs, [hashtable]$Opts, [string[]]$Rest)

    $cwd = (Get-Location).Path
    if (-not (script:Ensure-AgentVmRunning -Opts $Opts -CwdWin $cwd)) { return }

    $extra = ($Rest -join ' ')
    # exec replaces the login shell with the agent while keeping the terminal TTY.
    $cmd = "exec $Binary $BinaryArgs $extra".Trim()
    & wsl.exe -d $script:AgentVmDistro --cd $cwd -- zsh -lc $cmd
    $code = $LASTEXITCODE

    if ($Opts.rm) {
        Write-Host "Terminating distro..."
        & wsl.exe --terminate $script:AgentVmDistro | Out-Null
    }
    return $code
}

function script:Show-AgentVmHelp {
@"
Usage: agent-vm [options] <command> [args]

Commands:
  setup              Create and provision the WSL2 distro (run once)
  claude [args]      Run Claude Code in the distro for the current directory
  opencode [args]    Run OpenCode in the distro for the current directory
  codex [args]       Run Codex CLI in the distro for the current directory
  shell              Open a shell in the distro for the current directory
  run <cmd> [args]   Run a command in the distro for the current directory
  stop               Terminate the distro (keeps it on disk)
  rm                 Unregister (delete) the distro
  list               List WSL distros
  status             Show the agent-vm distro status
  help               Show this help

Options (for claude, opencode, codex, shell, run):
  --reset            Unregister and re-provision the distro from scratch
  --offline          Block outbound internet (keeps host/distro communication)
  --readonly         Mount the project directory as read-only
  --git-read-only    Mount .git read-only (allows git diff/log but not commit)
  --rm               Terminate the distro after the command exits
  --disk/--memory/--cpus   Ignored on Windows (set globally in .wslconfig)

This Windows build runs everything in ONE shared WSL2 distro named
'$($script:AgentVmDistro)'. Customization, mirroring the macOS/Linux version:
  ~/.agent-vm/runtime.sh         (inside the distro)  per-user runtime
  <project>/.agent-vm.runtime.sh (in the repo)        per-project runtime

More info: README.md
"@ | Write-Host
}

function agent-vm {
    if (-not (script:Test-AgentVmWsl)) { return }

    $opts = @{
        reset = $false; offline = $false; readonly = $false; gitro = $false; rm = $false
        disk = $null; memory = $null; cpus = $null
    }
    $rest = @()
    $cmd = $null
    $i = 0
    $a = @($args)

    # Parse global options before the subcommand (mirrors the bash version).
    # Note: PowerShell's break/continue inside `switch` target the switch, not
    # the loop, so we use explicit if/elseif here.
    $parsing = $true
    while ($parsing -and $i -lt $a.Count) {
        $tok = [string]$a[$i]
        if     ($tok -eq '--reset')    { $opts.reset = $true;    $i++ }
        elseif ($tok -eq '--offline')  { $opts.offline = $true;  $i++ }
        elseif ($tok -eq '--readonly') { $opts.readonly = $true; $i++ }
        elseif ($tok -eq '--git-read-only' -or $tok -eq '--git-ro') { $opts.gitro = $true; $i++ }
        elseif ($tok -eq '--rm')       { $opts.rm = $true;       $i++ }
        elseif ($tok -eq '--disk')     { $opts.disk = $a[$i+1];   $i += 2 }
        elseif ($tok -eq '--memory' -or $tok -eq '--ram') { $opts.memory = $a[$i+1]; $i += 2 }
        elseif ($tok -eq '--cpus')     { $opts.cpus = $a[$i+1];   $i += 2 }
        else { $cmd = $tok; $i++; $parsing = $false }
    }
    if ($i -lt $a.Count) { $rest = $a[$i..($a.Count-1)] }
    if (-not $cmd) { $cmd = "help" }

    switch ($cmd) {
        "setup" {
            if (-not (script:Test-AgentVmDistroExists)) {
                if (-not (script:New-AgentVmDistro)) { return }
            } else {
                Write-Host "Distro '$($script:AgentVmDistro)' already exists; re-provisioning."
            }
            if (-not (script:Invoke-AgentVmProvision)) { return }

            # Optional per-user setup, mirroring ~/.agent-vm/setup.sh on macOS.
            & wsl.exe -d $script:AgentVmDistro -u root -- bash -lc 'f="$HOME/.agent-vm/setup.sh"; [ -f "$f" ] && zsh -l "$f" || true'

            Write-Host ""
            Write-Host "Distro ready. Run 'agent-vm shell', 'agent-vm claude', or 'agent-vm codex' from any project directory."
        }
        "claude"   { script:Invoke-AgentVmAgent -Binary "claude" -BinaryArgs "--dangerously-skip-permissions" -Opts $opts -Rest $rest | Out-Null }
        "codex"    { script:Invoke-AgentVmAgent -Binary "codex"  -BinaryArgs "--dangerously-bypass-approvals-and-sandbox" -Opts $opts -Rest $rest | Out-Null }
        "opencode" { script:Invoke-AgentVmAgent -Binary "opencode" -BinaryArgs "" -Opts $opts -Rest $rest | Out-Null }
        "shell" {
            $cwd = (Get-Location).Path
            if (-not (script:Ensure-AgentVmRunning -Opts $opts -CwdWin $cwd)) { return }
            Write-Host "Distro: $($script:AgentVmDistro) | Dir: $cwd"
            Write-Host "Type 'exit' to leave (distro keeps running). Use 'agent-vm stop' to stop it."
            & wsl.exe -d $script:AgentVmDistro --cd $cwd -- zsh -l
            if ($opts.rm) { Write-Host "Terminating distro..."; & wsl.exe --terminate $script:AgentVmDistro | Out-Null }
        }
        "run" {
            if ($rest.Count -eq 0) { Write-Error "Usage: agent-vm run <command> [args]"; return }
            $cwd = (Get-Location).Path
            if (-not (script:Ensure-AgentVmRunning -Opts $opts -CwdWin $cwd)) { return }
            & wsl.exe -d $script:AgentVmDistro --cd $cwd -- zsh -lc ("exec " + ($rest -join ' '))
            if ($opts.rm) { Write-Host "Terminating distro..."; & wsl.exe --terminate $script:AgentVmDistro | Out-Null }
        }
        "stop" {
            if (-not (script:Test-AgentVmReady)) { return }
            Write-Host "Terminating distro '$($script:AgentVmDistro)'..."
            & wsl.exe --terminate $script:AgentVmDistro | Out-Null
            Write-Host "Distro stopped."
        }
        { $_ -in @("rm","destroy") } {
            if (-not (script:Test-AgentVmReady)) { return }
            Write-Host "Unregistering distro '$($script:AgentVmDistro)'..."
            & wsl.exe --unregister $script:AgentVmDistro | Out-Null
            Write-Host "Distro destroyed."
        }
        "list"   { & wsl.exe -l -v }
        "status" {
            Write-Host "agent-vm distro: $($script:AgentVmDistro)"
            if (script:Test-AgentVmDistroExists) { & wsl.exe -l -v | Select-String -SimpleMatch $script:AgentVmDistro }
            else { Write-Host "(not created — run 'agent-vm setup')" }
        }
        { $_ -in @("help","--help","-h") } { script:Show-AgentVmHelp }
        default {
            Write-Error "Unknown command: $cmd. Run 'agent-vm help' for usage."
        }
    }
}
