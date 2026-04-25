# Security

This document describes the security model of `tailscale-bootstrap-windows`,
what it is designed to protect against, what it is **not** designed to
protect against, and how to recover or revoke access.

## Threat model

The bootstrap is intended for a single-operator "pet" Windows machine on a
home or small-office network. The operator wants to:

- run a Windows server without keeping a screen and keyboard attached;
- reach it from their dev machine, anywhere, without exposing anything to the
  public Internet;
- use only credentials they already trust (their existing GitHub SSH keys);
- limit the damage if any single component is compromised.

The script trusts:

- **The Windows installation** the operator runs it on (it runs as
  Administrator).
- **GitHub** for the operator's listed SSH public keys
  (`https://api.github.com/users/<user>/keys`).
- **Tailscale** for the private overlay network and identity of the dev machine.
- **The TLS PKI** for the HTTPS connection to GitHub when fetching keys and
  for the Tailscale control plane.

## What the script protects against

- **Public exposure of SSH.** The Windows firewall is reconfigured so that
  port 22 is reachable only through the Tailscale interface (or, as a
  fallback, only at the local Tailscale IPv4). The default
  `OpenSSH-Server-In-TCP` rule is disabled.
- **Password guessing / credential stuffing.** Password authentication and
  keyboard-interactive authentication are disabled in `sshd_config`. Empty
  passwords are forbidden. `AuthenticationMethods publickey` makes
  public-key authentication the only path in.
- **Untrusted keys.** Only public keys returned by GitHub for the configured
  user are accepted. Each key is sanity-checked against known OpenSSH key-type
  prefixes.
- **Localized account-name bugs.** The local Administrators group, SYSTEM, and
  ACL principals are resolved by SID (`S-1-5-32-544`, `S-1-5-18`), so the
  script works correctly on non-English Windows installations.
- **Loose file permissions on authorized keys.**
  `C:\ProgramData\ssh\administrators_authorized_keys` is reset with
  inheritance disabled and FullControl granted only to SYSTEM and
  BUILTIN\Administrators.
- **Accidental secret storage.** The script does not require, accept, store,
  print, or commit a Tailscale auth key, a password, or any other secret.

## What the script does NOT protect against

- A **compromised GitHub account** belonging to the configured `GitHubUser`.
  Anyone who can add an SSH key to that account can SSH into the bootstrapped
  machine after the next run (or, if their key was already there, immediately).
  Protect the GitHub account with a strong password and a hardware MFA key.
- A **compromised Tailscale account or tailnet device**. Anyone whose device
  is in the same tailnet can reach SSH on port 22 (subject to Tailscale ACLs).
  Configure Tailscale ACLs to limit which devices can reach the headless
  machine on TCP 22.
- A **compromised dev machine**. If your dev machine is taken over, the attacker has
  your SSH private key and your Tailscale device. SSH key passphrases and
  full-disk encryption help here.
- A **compromised Windows machine**. Local malware running as Administrator
  can do anything the operator can.
- **Supply-chain attacks** on Tailscale, the OpenSSH Windows capability,
  GitHub, or `winget`. The script trusts all of those.
- **Physical attacks** on the headless machine.
- **Lateral movement on your LAN** that does not go through SSH (for example
  exploitation of other services on the same machine). The script only
  hardens SSH.

## What is intentionally not supported

- **Tailscale auth keys.** The script is interactive on first run on purpose:
  the operator finishes a browser login. This avoids storing a long-lived
  auth key on disk or in the repo.
- **SSH password login.** Disabled by design.
- **Public SSH (port 22 forwarded on the router).** Not supported and
  actively prevented by the firewall configuration.
- **Multiple users.** A single SSH user (default `devops`) is allowed via
  `AllowUsers`. Add more via SSH after bootstrap if you really need them.
- **Application stack installation.** Docker, Node.js, runners, etc. are
  out of scope for this repository.

## Why SSH password login is disabled

Passwords are guessable and reusable. Public-key authentication is
non-interactive, harder to brute-force, and tied to a key file the operator
controls. Combining `PasswordAuthentication no`,
`KbdInteractiveAuthentication no`, and `PermitEmptyPasswords no` removes
password-based code paths in `sshd` entirely.

## Why Tailscale instead of public SSH

- No port forwarding on the home router, so no Internet-facing attack
  surface for SSH at all.
- Tailscale provides identity, MagicDNS, and ACLs.
- The headless machine is reachable from anywhere the operator's dev machine is,
  without dynamic DNS or VPN appliances.

## Why remote scripts must be reviewed before execution

`bootstrap.ps1` runs as Administrator. It is downloaded over HTTPS from a
GitHub raw URL. If the branch is later modified or the GitHub account is
compromised, future runs would execute different code. Therefore:

1. The README tells you to download to `%TEMP%`, open the file in Notepad,
   and only then run it. Do **not** use `iex` on a remote URL.
2. For long-term reuse, pin the raw URL to a specific commit SHA instead of
   `main`, e.g.

   ```
   https://raw.githubusercontent.com/<user>/tailscale-bootstrap-windows/<commit-sha>/bootstrap.ps1
   ```

## How to rotate SSH keys

1. On the dev machine, generate a new key:

   ```powershell
   ssh-keygen -t ed25519 -C "petbox-rotated"
   ```

2. Add the new public key to GitHub at
   <https://github.com/settings/keys>.
3. SSH into the headless machine (still using the old key) and remove the
   old key from GitHub at <https://github.com/settings/keys>.
4. On the headless machine, refresh `administrators_authorized_keys` either
   by rerunning `bootstrap.ps1` (it's idempotent) or by editing
   `C:\ProgramData\ssh\administrators_authorized_keys` directly to remove
   the old key.
5. Verify SSH still works with the new key, then delete the old private key
   file on the dev machine.

## How to remove access entirely

Do **all** of these to fully revoke access:

1. **Tailscale**: remove the dev machine and the headless machine from your
   tailnet at <https://login.tailscale.com/admin/machines>.
2. **GitHub**: remove SSH keys you no longer trust at
   <https://github.com/settings/keys>.
3. **Headless machine**: open
   `C:\ProgramData\ssh\administrators_authorized_keys` and remove the lines
   for keys that should no longer have access. Restart `sshd`:

   ```powershell
   Restart-Service sshd
   ```

4. Optionally, disable the local SSH user:

   ```powershell
   Disable-LocalUser -Name devops
   ```

## How to audit the firewall rule

```powershell
Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP-TailscaleOnly' | Format-List *
Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP-TailscaleOnly' |
    Get-NetFirewallInterfaceFilter
Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP-TailscaleOnly' |
    Get-NetFirewallAddressFilter
Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP'  # should be Disabled
```

The expected state is:

- `OpenSSH-Server-In-TCP-TailscaleOnly` is **Enabled** and scoped either to
  the Tailscale `InterfaceAlias` or to the Tailscale local IPv4.
- `OpenSSH-Server-In-TCP` (the default open rule) is **Disabled**.

## How to check that SSH is not exposed publicly

From outside your home network (e.g. a phone on cellular data), try to
connect to your home's public IP on port 22. The connection must time out.

You can also check listening sockets locally:

```powershell
Get-NetTCPConnection -LocalPort 22 -State Listen
```

`sshd` will be listening on `0.0.0.0:22`. That is fine: the **firewall**, not
`sshd`, is what prevents traffic from non-Tailscale interfaces from reaching
the listener.

## Warning: arbitrary remote scripts

Running a script from the Internet as Administrator is dangerous. Even when
the script is from a project you trust:

- Read it before you run it.
- Pin to a specific commit SHA for repeatable runs.
- Prefer cloning the repo, reviewing the diff, and running the local file.
- Never run a remote script via `iex (irm <url>)` as Administrator.
