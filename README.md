# tailscale-bootstrap-windows

A safe, minimal, one-time bootstrap for a Windows headless machine. Plug in a
screen and keyboard once, run a single command from an Administrator
PowerShell, finish the Tailscale browser login, and from then on you can
manage the machine remotely from your laptop over SSH through Tailscale.

## What this repo does

- Installs Tailscale (via `winget`) and joins this machine to your tailnet.
- Installs the Windows OpenSSH Server.
- Creates a local administrator user dedicated to SSH (default name: `devops`).
- Imports your public SSH keys from your GitHub account.
- Configures `sshd` for **public-key authentication only** (no passwords).
- Restricts inbound SSH to the Tailscale network interface.
- Creates a project root folder with `cache/`, `data/`, `tmp/` subfolders.

That is the whole scope. The goal is remote access, nothing more.

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

Everything else (Docker, app deployments, GHCR pulls, CI/CD, reverse proxies)
is meant to be done **after** bootstrap, remotely, over SSH.

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
- A [GitHub](https://github.com/) account.
- Administrator rights on the Windows machine.

If you do not yet have an SSH key on your laptop, step 1 below shows how to
make one.

## What is an SSH key?

An SSH key is a pair of files: a **private key** that stays on your laptop
and a **public key** that you give to servers you want to log in to.

- The **public key** is safe to share. You will upload it to GitHub.
- The **private key** must stay on your laptop and never be shared, emailed,
  uploaded, or committed.

This script will fetch your **public** key from your GitHub profile and
install it on the Windows machine. SSH then lets you log in by proving you
hold the matching private key. There is no password to type or to leak.

### Where each layer lives

These three pieces are independent and do different jobs:

| Layer    | Role                                                          | Touches your SSH key? |
| -------- | ------------------------------------------------------------- | --------------------- |
| `ssh-keygen` on your laptop | Generates the key pair locally.                | Yes — creates it.     |
| GitHub   | Public-key distribution (`https://<user>.keys`).              | Public key only.      |
| Tailscale | Encrypted network tunnel between laptop and headless machine. | **No.** It never sees or stores SSH keys. |
| OpenSSH  | Authenticates SSH logins using the public/private key pair.   | Yes — the standard way. |

In other words, **the key pair is generated on your laptop with
`ssh-keygen` and never leaves it**. GitHub stores only the public half so
this script can download it. Tailscale is just the network — it does not
generate, store, or look at SSH keys.

(Tailscale does have a separate feature called "Tailscale SSH" that
replaces OpenSSH key auth with Tailscale identity. We deliberately do
**not** use it here — this repo sticks to standard OpenSSH + key auth.)

## 1. Generate an SSH key on your laptop

Skip this step if you already have a key you want to use.

In Windows PowerShell on your **laptop** (not the headless machine):

```powershell
ssh-keygen -t ed25519 -C "petbox"
```

Press Enter to accept the default location
(`%USERPROFILE%\.ssh\id_ed25519`). You can set a passphrase or leave it
empty.

This creates two files:

- `id_ed25519`     — your **private** key. Never share this.
- `id_ed25519.pub` — your **public** key. You will upload this to GitHub
  in the next step.

## 2. Add the public key to GitHub

Print your public key:

```powershell
Get-Content "$env:USERPROFILE\.ssh\id_ed25519.pub"
```

Copy the entire line that PowerShell prints, then go to
<https://github.com/settings/keys>, click **New SSH key**, paste it, and
save.

## 3. Install and log into Tailscale on your laptop

- Download from <https://tailscale.com/download> and install.
- Sign in with the account you will also use on the headless machine.
- Verify your laptop appears in <https://login.tailscale.com/admin/machines>.

The free tier is enough for personal use.

## (Optional) Fork this repository

You can run the script straight from the upstream repo by leaving
`$RepoOwner` set to the upstream GitHub user. But for long-term use it is
safer to fork: you then own the exact code that runs as Administrator on
your machine and nothing changes upstream without you noticing.

On GitHub, click **Fork** at the top right of the repo page (or use
[`gh repo fork`](https://cli.github.com/manual/gh_repo_fork) if you have
the GitHub CLI). Then on your laptop:

```powershell
git clone https://github.com/<your-github-username>/tailscale-bootstrap-windows.git
cd tailscale-bootstrap-windows
```

If you want to customise anything (defaults, comments, extra steps), edit
the files locally and push:

```powershell
git add .
git commit -m "my customisations"
git push origin main
```

In step 4 below, set `$RepoOwner` to your own GitHub username so the
bootstrap downloads your fork instead of the upstream.

## 4. Run the one-time bootstrap on the headless Windows machine

Plug the screen and keyboard into the Windows machine. Open **PowerShell as
Administrator**.

Edit the four values at the top of the block below, then copy and paste
the whole block. The script will be downloaded to `%TEMP%`, opened in
Notepad so you can read it first, and only run after you close Notepad.

```powershell
$GitHubUser  = "your-github-username"
$MachineName = "petbox"
$SshUser     = "devops"
$ProjectRoot = "C:\sources\pet-project"

$RepoOwner  = $GitHubUser   # change if you are running someone else's fork
$RepoName   = "tailscale-bootstrap-windows"
$ScriptUrl  = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/main/bootstrap.ps1"
$ScriptPath = "$env:TEMP\bootstrap.ps1"

Invoke-WebRequest -Uri $ScriptUrl -OutFile $ScriptPath
Start-Process -FilePath notepad.exe -ArgumentList $ScriptPath -Wait
PowerShell.exe -ExecutionPolicy Bypass -File $ScriptPath `
    -GitHubUser  $GitHubUser `
    -MachineName $MachineName `
    -SshUser     $SshUser `
    -ProjectRoot $ProjectRoot
```

The four values at the top are the only ones you usually need to change:

| Variable       | Example                  | What it is                                    |
| -------------- | ------------------------ | --------------------------------------------- |
| `$GitHubUser`  | `your-github-username`   | GitHub username whose public SSH keys to install. |
| `$MachineName` | `petbox`                 | Tailscale hostname for this machine.              |
| `$SshUser`     | `devops`                 | Local Windows username created for SSH.           |
| `$ProjectRoot` | `C:\sources\pet-project` | Project root directory (with `cache/`, `data/`, `tmp/`). |

All four are required. The script has no built-in defaults: if any is
missing it prints a usage screen and exits without making changes.

Notes:

- **Do not** pipe remote scripts straight into `iex`. Always download and
  inspect first.
- For long-term reuse, change `main` in `$ScriptUrl` to a specific commit
  SHA so a future change to the branch cannot silently change what you
  run as Administrator.

When the script reaches the Tailscale step, a browser window will open (or
a login URL will be printed). Sign in with the same Tailscale account as
your laptop and approve this machine. The script then continues.

When the script finishes you will see a final block with your Tailscale IP
and the two SSH commands you can use from your laptop.

## 5. Test SSH from your laptop

From the laptop, both of these should work (substitute the `SshUser`,
`MachineName`, and Tailscale IP you used / saw printed):

```powershell
ssh devops@petbox
ssh devops@100.x.y.z
```

`devops@petbox` works because Tailscale provides MagicDNS for tailnet
hostnames.

Once SSH works from the laptop, you can unplug the screen and keyboard
from the Windows machine.

## Troubleshooting

**`ssh: Could not resolve hostname petbox`**
Your laptop is not reaching MagicDNS. Make sure the Tailscale client is
running on your laptop and MagicDNS is enabled at
<https://login.tailscale.com/admin/dns>. As a fallback, use the Tailscale
IPv4 directly.

**Tailscale login was not completed.**
Rerun `bootstrap.ps1`. It is safe to rerun. You can also run
`tailscale up --hostname=petbox --unattended` manually and complete the
browser login.

**No GitHub SSH keys found.**
Add at least one SSH public key at <https://github.com/settings/keys> and
rerun the script. You can verify your keys are visible at
`https://github.com/<your-username>.keys` (a public endpoint).

**OpenSSH Server install fails.**
Run `Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*'`.
On some Windows editions you may need to install Windows updates first,
then reboot and rerun.

**`Permission denied (publickey)` when trying to SSH.**
Make sure the laptop's public key is in your GitHub account and that you
are connecting as the SSH user the script created (default `devops`).

**Firewall rule looks wrong.**
Inspect it with
`Get-NetFirewallRule -Name OpenSSH-Server-In-TCP-TailscaleOnly | Format-List *`.
The default rule `OpenSSH-Server-In-TCP` should be **Disabled**.

**`winget` is missing.**
Install the latest "App Installer" from the Microsoft Store, or install
Tailscale manually from <https://tailscale.com/download/windows>, then
rerun the script.

**The Tailscale adapter cannot be detected.**
Reboot, confirm Tailscale is connected (it should appear in
`Get-NetAdapter`), and rerun the script. The script refuses to open SSH
publicly if it cannot identify the Tailscale adapter or IP.

**`tailscale ip -4` does not return an IP.**
Run `tailscale status` to see the connection state. If the machine is not
logged in, run `tailscale up --hostname=petbox --unattended` and complete
the browser login.

## Security notes

- No secrets are stored in this repo.
- **Never** commit Tailscale auth keys.
- **Never** commit private SSH keys (`id_ed25519`, `id_rsa`, `*.pem`,
  `*.key`).
- Do **not** forward port 22 on your router. SSH is intentionally
  reachable only over Tailscale.
- Always **read the script** before running it as Administrator. The
  Notepad step in the bootstrap command is there for that reason.
- For long-term reuse, **pin** the raw GitHub URL to a specific commit
  SHA instead of `main`, so a later change to the branch cannot silently
  change what you run.
- Public GitHub SSH keys are public by design. Private keys must remain
  secret.
- SSH password login is intentionally disabled.
- SSH is intended to be reachable only through Tailscale.

See [SECURITY.md](SECURITY.md) for the full threat model, key-rotation
steps, and how to revoke access.

## After bootstrap

Once SSH works from the laptop, this repository is done. Anything else
(Docker, app deployments, GHCR pulls, GitHub Actions runners, reverse
proxies, CI/CD) belongs **later, remotely, over SSH** and is out of scope
here.

Bootstrap stays small and boring on purpose; the rest is managed
elsewhere.
