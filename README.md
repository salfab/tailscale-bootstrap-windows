# tailscale-bootstrap-windows

A safe, minimal, one-time bootstrap for a Windows headless machine. Plug in a
screen and keyboard once, run a single command from an Administrator
PowerShell, finish the Tailscale browser login, and you can manage the machine
remotely from your laptop over SSH through Tailscale forever after.

## What this repo does

- Installs Tailscale (via `winget`) and joins this machine to your tailnet.
- Installs the Windows OpenSSH Server.
- Creates a local administrator user dedicated to SSH.
- Imports your public SSH keys from your GitHub account.
- Configures `sshd` for **public-key authentication only** (no passwords).
- Restricts inbound SSH to the Tailscale network interface.
- Creates a project root folder with `cache/`, `data/`, `tmp/` subfolders.

That's it. The goal is remote access, nothing more.

## What this repo does NOT do

This repo is intentionally narrow. It does **not** install or configure:

- Docker
- Docker Desktop
- Node.js
- GitHub Actions runners
- Caddy
- Kubernetes
- Portainer
- Any application stack

Everything else (Docker, app deployments, GHCR pulls, CI/CD, reverse proxies,
etc.) is meant to be done **after** bootstrap, remotely, over SSH.

## Architecture

```
Laptop
  |
  | SSH
  |
Tailscale private network
  |
  |
Windows headless server
  |
  | OpenSSH Server
  |
PowerShell remote administration
```

## Prerequisites

- A Windows machine to bootstrap (the "headless server").
- A temporary screen and keyboard for the first run.
- A laptop you will use to SSH into the machine.
- A free [Tailscale](https://tailscale.com/) account.
- A [GitHub](https://github.com/) account with at least one SSH public key
  already uploaded to your account.
- Administrator rights on the Windows machine.

## 1. Generate an SSH key on your laptop

Skip this step if you already have a key you want to use.

In Windows PowerShell on your **laptop** (not the headless machine):

```powershell
ssh-keygen -t ed25519 -C "petbox"
```

Accept the default location (`%USERPROFILE%\.ssh\id_ed25519`) and choose a
passphrase if you want one.

## 2. Add the public key to GitHub

Print your public key:

```powershell
Get-Content "$env:USERPROFILE\.ssh\id_ed25519.pub"
```

Copy the output, then add it at <https://github.com/settings/keys> as a new
SSH key.

The `.pub` file is **safe** to share. The other file (`id_ed25519`, no
extension) is your **private key** and must never be shared, committed, or
uploaded anywhere.

## 3. Install and log into Tailscale on your laptop

- Download from <https://tailscale.com/download> and install.
- Sign in with the same account you will use on the headless machine.
- Verify your laptop appears in <https://login.tailscale.com/admin/machines>.

## 4. Run the one-time bootstrap on the headless Windows machine

Plug the screen and keyboard into the Windows machine. Open **PowerShell as
Administrator** and run the following. Replace `your-github-username` with
your own GitHub username.

> The command downloads the script to `%TEMP%`, opens it in Notepad so you
> can read it before running, and then executes it. **Do not** pipe remote
> scripts straight into `iex`.

```powershell
$GitHubUser = "your-github-username"
$RepoName   = "tailscale-bootstrap-windows"
$ScriptUrl  = "https://raw.githubusercontent.com/$GitHubUser/$RepoName/main/bootstrap.ps1"
$ScriptPath = "$env:TEMP\bootstrap.ps1"

Invoke-WebRequest -Uri $ScriptUrl -OutFile $ScriptPath

# Read the script before running it. Close Notepad to continue.
notepad $ScriptPath

PowerShell.exe -ExecutionPolicy Bypass -File $ScriptPath -GitHubUser $GitHubUser
```

You can also pass the optional parameters:

```powershell
PowerShell.exe -ExecutionPolicy Bypass -File $ScriptPath `
    -GitHubUser  $GitHubUser `
    -MachineName "petbox" `
    -SshUser     "devops" `
    -ProjectRoot "D:\pet-project"
```

When the script runs `tailscale up`, a browser window will open. Sign in with
the same Tailscale account as your laptop and approve this machine.

When the script finishes you will see a final result block with your
Tailscale IPv4 address and the two SSH commands to use.

## 5. Test SSH from your laptop

From the laptop, both of these should work:

```powershell
ssh devops@petbox
ssh devops@100.x.y.z
```

(`100.x.y.z` is the Tailscale IPv4 the script printed.)

`devops@petbox` works because Tailscale provides MagicDNS for tailnet
hostnames.

Once SSH works from the laptop, you can unplug the screen and keyboard from
the Windows machine.

## Troubleshooting

**`ssh: Could not resolve hostname petbox`**
MagicDNS is not enabled or your laptop is not connected to Tailscale. Enable
MagicDNS at <https://login.tailscale.com/admin/dns> and make sure the
Tailscale client is running on your laptop. As a fallback use the Tailscale
IPv4 directly.

**Tailscale login was not completed.**
Rerun `bootstrap.ps1`. It is safe to rerun. You can also run
`tailscale up --hostname=petbox --unattended` manually and complete the
browser login.

**No GitHub SSH keys found.**
Add at least one SSH public key at <https://github.com/settings/keys> and
rerun the script. Verify your keys are visible at
`https://github.com/<your-username>.keys` (a public endpoint).

**OpenSSH Server install fails.**
Run `Get-WindowsCapability -Online | ? Name -like 'OpenSSH.Server*'` to see
the available capability. On some Windows editions you may need to install
Windows updates first. Try again after rebooting.

**`Permission denied (publickey)`**
Check that your laptop's public key is in your GitHub account. The script
reads
`https://api.github.com/users/<your-username>/keys`,
so anything not on that list will not be accepted. Ensure you are connecting
as the SSH user the script created (default `devops`).

**Firewall rule issues.**
Inspect the rule:
`Get-NetFirewallRule -Name OpenSSH-Server-In-TCP-TailscaleOnly | Format-List *`.
The default rule `OpenSSH-Server-In-TCP` should be **disabled**.

**`winget` is missing.**
Install the latest "App Installer" from the Microsoft Store, or install
Tailscale manually from <https://tailscale.com/download/windows>, then rerun
the script.

**The Tailscale adapter cannot be detected.**
Reboot, ensure Tailscale is connected (it should appear as a network adapter
in `Get-NetAdapter`), and rerun the script. The script refuses to open SSH
publicly if it cannot identify the Tailscale adapter or IP.

**`tailscale ip -4` does not return an IP.**
Run `tailscale status` to check the connection state. If the machine is not
logged in, run `tailscale up --hostname=petbox --unattended` and complete the
browser login.

## Security notes

- No secrets are stored in this repo.
- **Never** commit Tailscale auth keys.
- **Never** commit private SSH keys (`id_ed25519`, `id_rsa`, `*.pem`, `*.key`).
- Do **not** forward port 22 on your router. SSH is intentionally reachable
  only over Tailscale.
- For long-term reuse, **pin** the raw GitHub URL to a specific commit SHA
  instead of `main`, so a compromised branch cannot silently change what you
  run as Administrator.
- Always **review the script** before executing it as Administrator. The
  `notepad $ScriptPath` step in the bootstrap command is there for that
  reason.
- Public GitHub SSH keys are public by design. Private keys must remain
  secret.
- SSH password login is intentionally disabled.
- SSH is intended to be reachable only through Tailscale.

See [SECURITY.md](SECURITY.md) for the full threat model and key-rotation
procedure.

## After bootstrap

Once SSH works from the laptop, this repository is done. Anything else
(Docker installation, Docker Compose, app deployments, pulling images from
GHCR, configuring caches, GitHub Actions self-hosted runners, reverse
proxies, CI/CD) should be configured **later, remotely, over SSH**.

Keeping this repo small is the point. Bootstrap stays boring; the rest is
managed elsewhere.
