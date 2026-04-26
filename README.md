# tailscale-bootstrap-windows

A safe, minimal, one-time bootstrap for a Windows headless machine. Plug in a
screen and keyboard once, run a single command from an Administrator
PowerShell, finish the Tailscale browser login, and from then on you can
manage the machine remotely from your dev machine over SSH through Tailscale.

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
Dev machine
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
- A dev machine you will use to SSH into the machine.
- A free [Tailscale](https://tailscale.com/) account.
- A [GitHub](https://github.com/) account.
- Administrator rights on the Windows machine.

If you do not yet have an SSH key on your dev machine, step 1 below shows how to
make one.

## What is an SSH key?

An SSH key is a pair of files: a **private key** that stays on your dev machine
and a **public key** that you give to servers you want to log in to.

- The **public key** is safe to share. You will upload it to GitHub.
- The **private key** must stay on your dev machine and never be shared, emailed,
  uploaded, or committed.

This script will fetch your **public** key from your GitHub profile and
install it on the Windows machine. SSH then lets you log in by proving you
hold the matching private key. There is no password to type or to leak.

### Where each layer lives

These three pieces are independent and do different jobs:

| Layer    | Role                                                          | Touches your SSH key? |
| -------- | ------------------------------------------------------------- | --------------------- |
| `ssh-keygen` on your dev machine | Generates the key pair locally.                | Yes — creates it.     |
| GitHub   | Public-key distribution (`https://<user>.keys`).              | Public key only.      |
| Tailscale | Encrypted network tunnel between dev machine and headless machine. | **No.** It never sees or stores SSH keys. |
| OpenSSH  | Authenticates SSH logins using the public/private key pair.   | Yes — the standard way. |

In other words, **the key pair is generated on your dev machine with
`ssh-keygen` and never leaves it**. GitHub stores only the public half so
this script can download it. Tailscale is just the network — it does not
generate, store, or look at SSH keys.

(Tailscale does have a separate feature called "Tailscale SSH" that
replaces OpenSSH key auth with Tailscale identity. We deliberately do
**not** use it here — this repo sticks to standard OpenSSH + key auth.)

## 1. Generate an SSH key on your dev machine

Skip this step if you already have a key you want to use.

In Windows PowerShell on your **dev machine** (not the headless machine):

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

## 3. Install and log into Tailscale on your dev machine

- Download from <https://tailscale.com/download> and install.
- Sign in with the account you will also use on the headless machine.
- Verify your dev machine appears in <https://login.tailscale.com/admin/machines>.

The free tier is enough for personal use.

## 4. Run the one-time bootstrap on the headless Windows machine

Plug the screen and keyboard into the Windows machine. Open **PowerShell as
Administrator**.

Edit every value at the top of the block below, then copy and paste the
whole block. The script will be downloaded to `%TEMP%`, opened in Notepad
so you can read it first, and only run after you close Notepad.

```powershell
$GitHubUser  = "your-github-username"
$MachineName = "petbox"
$SshUser     = "devops"
$ProjectRoot = "C:\sources\pet-project"
$RepoOwner   = "salfab"
$RepoName    = "tailscale-bootstrap-windows"

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

Every variable at the top of the block is required and has no fallback —
edit each value to match your setup before running:

| Variable       | Example                  | What it is                                                    |
| -------------- | ------------------------ | ------------------------------------------------------------- |
| `$GitHubUser`  | `your-github-username`   | GitHub username whose public SSH keys to install.             |
| `$MachineName` | `petbox`                 | Tailscale hostname for this machine.                          |
| `$SshUser`     | `devops`                 | Local Windows username created for SSH.                       |
| `$ProjectRoot` | `C:\sources\pet-project` | Project root directory (with `cache/`, `data/`, `tmp/`).      |
| `$RepoOwner`   | `salfab`                 | GitHub user/organisation that hosts `bootstrap.ps1`.          |
| `$RepoName`    | `tailscale-bootstrap-windows` | GitHub repository name where `bootstrap.ps1` lives.      |

The four `-GitHubUser`, `-MachineName`, `-SshUser`, `-ProjectRoot` flags are
required by `bootstrap.ps1` itself; if any is missing the script prints a
usage screen and exits without making changes.

Notes:

- **Do not** pipe remote scripts straight into `iex`. Always download and
  inspect first.
- For long-term reuse, change `main` in `$ScriptUrl` to a specific commit
  SHA so a future change to the branch cannot silently change what you
  run as Administrator.

When the script reaches the Tailscale step, a browser window will open (or
a login URL will be printed). Sign in with the same Tailscale account as
your dev machine and approve this machine. The script then continues.

When the script finishes you will see a final block with your Tailscale IP
and the two SSH commands you can use from your dev machine.

## 5. Test SSH from your dev machine

From the dev machine, both of these should work (substitute the `SshUser`,
`MachineName`, and Tailscale IP you used / saw printed):

```powershell
ssh devops@petbox
ssh devops@100.x.y.z
```

`devops@petbox` works because Tailscale provides MagicDNS for tailnet
hostnames.

Once SSH works from the dev machine, you can unplug the screen and keyboard
from the Windows machine.

## Troubleshooting

**`ssh: Could not resolve hostname petbox`**
Your dev machine is not reaching MagicDNS. Make sure the Tailscale client is
running on your dev machine and MagicDNS is enabled at
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
Make sure the dev machine's public key is in your GitHub account and that you
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

## Best practices for running the bootstrap

**Before running:**

- Open `https://github.com/<your-username>.keys` in a browser and confirm
  every key listed is one you still trust. Anything on that page will get
  SSH access on the headless machine. Remove anything stale at
  <https://github.com/settings/keys> first.
- Make sure your GitHub account is protected with 2FA (ideally a hardware
  security key). The bootstrap inherits whatever security GitHub provides
  for your account.
- Make sure your dev machine is already in the same tailnet, so you can
  verify SSH from it the moment the headless machine joins. If the dev
  machine isn't ready, you'll have to walk back to the screen and
  keyboard later.
- Read `bootstrap.ps1` after `Invoke-WebRequest` downloads it to
  `%TEMP%`. The Notepad step in the step-4 block is there for that
  reason — don't skip it.
- For repeatable, auditable runs, switch `$ScriptUrl` from `main` to a
  pinned reference (commit SHA or release tag — see *Cutting a release*
  below).

**After running:**

- Run `tailscale status` on your dev machine and confirm the headless
  machine is listed before unplugging anything. The script's final
  walkthrough prints the exact commands.
- The script is idempotent. Rerun it any time you change your GitHub
  SSH keys: new keys are merged into `administrators_authorized_keys`,
  duplicates are de-duplicated, and old keys you've already removed
  from GitHub will eventually fall out the next time you rerun (or you
  can edit the file by hand).
- For full key rotation and revocation procedures, see [SECURITY.md](SECURITY.md).

## Cutting a release (for maintainers)

`main` can change. Anyone running the bootstrap from
`https://raw.githubusercontent.com/.../main/bootstrap.ps1` runs whatever
is on the branch at that moment. For a stable, auditable distribution,
publish a GitHub release and have users pin to it.

1. Tag the commit you want to ship and push the tag:

   ```bash
   git tag -a v1.0.0 -m "First stable bootstrap"
   git push origin v1.0.0
   ```

2. Create a release attached to that tag and upload `bootstrap.ps1` as
   an asset. Via the GitHub UI: click *Draft a new release* on the
   Releases page. Or via the GitHub CLI:

   ```bash
   gh release create v1.0.0 ./bootstrap.ps1 `
       --title "v1.0.0" `
       --notes "First stable release of the Tailscale + OpenSSH bootstrap."
   ```

3. Update the step-4 block in this README so `$ScriptUrl` points to the
   release asset instead of `main`:

   ```powershell
   $ScriptUrl = "https://github.com/$RepoOwner/$RepoName/releases/download/v1.0.0/bootstrap.ps1"
   ```

   The release-asset URL is immutable once published — GitHub will not
   let the asset bytes change after the fact. Users who pin to `v1.0.0`
   always get the exact same script.

Maintainer hygiene:

- Sign tags with GPG (`git tag -s ...`) so consumers can verify
  provenance with `git tag -v`.
- Cut a **new** release for every change, even one-line edits. Never
  edit a published `bootstrap.ps1` in place — that defeats the
  immutability guarantee.
- Keep release notes specific: what changed, why, and call out any
  security-sensitive edit so users know whether to upgrade.

## After bootstrap

Once SSH works from the dev machine, this repository is done. Anything else
(Docker, app deployments, GHCR pulls, GitHub Actions runners, reverse
proxies, CI/CD) belongs **later, remotely, over SSH** and is out of scope
here.

Bootstrap stays small and boring on purpose; the rest is managed
elsewhere.
