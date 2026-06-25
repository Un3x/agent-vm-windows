# agent-vm-windows

A Windows port of [agent-vm](https://github.com/sylvinus/agent-vm). The original
runs AI coding agents (Claude Code, OpenCode, Codex) inside a sandboxed
[Lima](https://lima-vm.io/) VM on macOS/Linux. Lima does **not** run on Windows,
so this port swaps the VM layer: it runs the agents inside a **WSL2**
distribution instead.

The command surface is kept **identical** to upstream on purpose, so the same
documentation applies on every platform — only the install step differs:

```
agent-vm setup        # create + provision the WSL2 distro (run once)
agent-vm claude       # run Claude Code in the distro for the current directory
agent-vm codex        # run Codex CLI
agent-vm opencode     # run OpenCode
agent-vm shell        # open a shell in the distro
agent-vm stop|rm|status|list
agent-vm --offline claude     # block outbound internet
```

> ⚠️ **Status: v1, not yet validated on a real Windows host.** It is written
> against the documented WSL CLI but I do not have a Windows machine to run it.
> Expect to adjust the distro bootstrap (see *Known fragile bits*). Contributions
> and test reports welcome.

## How it differs from upstream

| Upstream (macOS/Linux) | This port (Windows) |
| --- | --- |
| Lima VM (`limactl`) | WSL2 distro (`wsl.exe`) |
| One VM **per directory** | One **shared** distro (`agent-vm`) for everything |
| Bash function in `.zshrc` | PowerShell function dot-sourced in `$PROFILE` |
| Debian 13 base | Debian (same family as upstream) |
| `--disk/--memory/--cpus` per VM | Global, via `%USERPROFILE%\.wslconfig` (these flags are ignored) |

Everything else maps directly: `--offline` (iptables in the distro), the per-user
`~/.agent-vm/runtime.sh` and per-project `<repo>/.agent-vm.runtime.sh` runtime
scripts (replayed on every invocation, exactly like Lima), and automatic
`localhost` port forwarding (WSL2 forwards ports to Windows, so a dev server on
`:5000` is reachable from the Windows browser).

## Requirements

- Windows 11 with virtualization enabled (most consumer machines).
- Admin rights to install WSL2.
- A recent WSL: run `wsl --update`. The `--name` flag used by `agent-vm setup`
  needs WSL ≥ 2.4.x.

## Install

1. Install WSL2 (once), then reboot:

   ```powershell
   wsl --install --no-distribution
   wsl --update
   ```

2. Clone this repo somewhere, e.g. `~\tools\agent-vm-windows`:

   ```powershell
   git clone https://github.com/skelz0r/agent-vm-windows $HOME\tools\agent-vm-windows
   ```

3. Dot-source the script from your PowerShell profile:

   ```powershell
   notepad $PROFILE
   # add this line:
   . "$HOME\tools\agent-vm-windows\agent-vm.ps1"
   ```

   Open a new terminal, then:

   ```powershell
   agent-vm setup
   ```

   This creates the `agent-vm` distro, provisions it (Docker, Node 24, mise,
   Claude, Codex, gh, Chromium…), and restarts it to activate systemd.

## Usage

From any project directory (PowerShell / Windows Terminal):

```powershell
cd C:\Users\you\work\apistration
agent-vm claude        # or: agent-vm codex / agent-vm shell
```

## Where to keep your project

Two options:

- **On the Windows filesystem (simplest):** `agent-vm` passes your current
  directory through to the distro via `wsl --cd`, which sees it under `/mnt/c/…`.
  Works out of the box and lets GitHub Desktop on Windows manage the repo
  normally. Downside: `/mnt/c` I/O is slow and file-watching is unreliable — fine
  for editing content, less so for running a heavy dev server.
- **Inside the WSL filesystem (faster):** clone the repo inside the distro
  (`agent-vm shell`, then `git clone …` under `~`). Docker and file-watching are
  much faster. GitHub Desktop on Windows can still open it via the
  `\\wsl.localhost\agent-vm\home\agent\…` path.

## Customization (same as upstream)

- `~/.agent-vm/runtime.sh` — per-user runtime, **inside the distro**. See
  [`runtime.example.sh`](runtime.example.sh).
- `<project>/.agent-vm.runtime.sh` — per-project runtime, committed in the repo.

Both are replayed on every `agent-vm` invocation and must be idempotent.

## Resource limits

WSL2 sizes memory/CPU globally, not per distro. Create
`%USERPROFILE%\.wslconfig`:

```ini
[wsl2]
memory=8GB
processors=4
```

Then `wsl --shutdown`. (The `--disk/--memory/--cpus` flags are accepted for
command-line compatibility but ignored, with a warning.)

## Known fragile bits (need Windows validation)

- **Distro creation.** `agent-vm setup` uses
  `wsl --install -d Debian --name agent-vm --no-launch`. On older WSL builds
  `--name` may not exist. Fallback: download a Debian WSL rootfs tarball and
  import it manually:

  ```powershell
  wsl --import agent-vm "$HOME\wsl\agent-vm" path\to\debian-rootfs.tar
  ```

  then run the provisioning script:

  ```powershell
  Get-Content -Raw setup-wsl2.sh | wsl -d agent-vm -u root -- bash -l
  wsl --terminate agent-vm
  ```

- **systemd.** Docker/redis/postgres rely on systemd, enabled via `/etc/wsl.conf`
  during setup; it only activates after the post-setup `wsl --terminate`. If
  services are down, run `wsl --shutdown` once.

- **Default user.** Setup creates an `agent` user with passwordless sudo and sets
  it as the distro default. If you used the `--import` fallback, confirm
  `/etc/wsl.conf` has `[user] default=agent` after the first run.

## Credits

Port of [sylvinus/agent-vm](https://github.com/sylvinus/agent-vm) (MIT). The
provisioning script and runtime contract follow upstream closely.
