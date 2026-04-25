<#
.SYNOPSIS
    One-time bootstrap for a Windows headless machine: Tailscale + OpenSSH + key-only SSH.

.DESCRIPTION
    Run once on a fresh Windows machine while a screen and keyboard are still attached.
    The script:
      - installs Tailscale (via winget) and connects this machine to your tailnet,
      - installs the Windows OpenSSH Server,
      - creates a local admin user for SSH,
      - imports your public SSH keys from GitHub,
      - configures sshd for key-only authentication,
      - restricts inbound SSH to the Tailscale interface only,
      - creates the project root directories.

    After this script finishes you can unplug the screen and keyboard and manage
    the machine from your laptop over SSH through Tailscale.

.PARAMETER GitHubUser
    GitHub username whose public SSH keys (https://github.com/<user>.keys) will
    be allowed to log in over SSH. Required.

.PARAMETER MachineName
    Tailscale hostname for this machine. Defaults to "petbox".

.PARAMETER SshUser
    Local Windows username that will be created (if missing) and used for SSH
    login. Defaults to "devops".

.PARAMETER ProjectRoot
    Project root directory to create on the data drive. Defaults to "D:\pet-project".

.EXAMPLE
    PowerShell.exe -ExecutionPolicy Bypass -File .\bootstrap.ps1 -GitHubUser my-github-user

.NOTES
    Requires Windows PowerShell 5.1+ and an Administrator session.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$GitHubUser,

    [ValidateNotNullOrEmpty()]
    [string]$MachineName = 'petbox',

    [ValidateNotNullOrEmpty()]
    [string]$SshUser = 'devops',

    [ValidateNotNullOrEmpty()]
    [string]$ProjectRoot = 'D:\pet-project'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# CLI output layer
# ---------------------------------------------------------------------------
# Small set of helpers so the script feels polished in a plain terminal.
# We deliberately stick to ASCII so output renders correctly on old conhost
# as well as Windows Terminal, on both dark and light color schemes.

function Write-Title {
    param([Parameter(Mandatory)][string]$Text)
    $bar = ('=' * 60)
    Write-Host ''
    Write-Host $bar  -ForegroundColor Cyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host $bar  -ForegroundColor Cyan
    Write-Host ''
}

function Write-Section {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host ''
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ''
}

function Write-Step {
    param(
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][int]$Total,
        [Parameter(Mandatory)][string]$Text
    )
    Write-Host ''
    Write-Host ("[{0}/{1}] {2}" -f $Number, $Total, $Text) -ForegroundColor White
}

function Write-Info {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host ('      ' + $Text) -ForegroundColor Gray
}

function Write-Success {
    param([string]$Text = 'OK')
    Write-Host ('      ' + $Text) -ForegroundColor Green
}

function Write-WarningMessage {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host ('      WARN: ' + $Text) -ForegroundColor Yellow
}

function Write-ErrorMessage {
    param(
        [Parameter(Mandatory)][string]$Text,
        [string]$Suggestion
    )
    Write-Host ''
    Write-Host ('ERROR: ' + $Text) -ForegroundColor Red
    if ($Suggestion) {
        Write-Host ('SUGGESTION: ' + $Suggestion) -ForegroundColor Yellow
    }
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

function Test-IsAdministrator {
    # SECURITY: every later step assumes Administrator. We resolve the local
    # Administrators group by SID (S-1-5-32-544) so this works on non-English
    # Windows installations as well.
    $identity   = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal  = New-Object System.Security.Principal.WindowsPrincipal($identity)
    $adminsSid  = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544'
    return $principal.IsInRole($adminsSid)
}

function Get-TailscaleExe {
    # Returns the absolute path to tailscale.exe, or $null if not found.
    $cmd = Get-Command 'tailscale.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        "$env:ProgramFiles\Tailscale\tailscale.exe",
        "${env:ProgramFiles(x86)}\Tailscale\tailscale.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
}

function Install-Tailscale {
    Write-Info 'Looking for an existing Tailscale install...'
    $existing = Get-TailscaleExe
    if ($existing) {
        Write-Info "Found: $existing"
        return $existing
    }

    Write-Info 'Tailscale not found. Installing via winget...'
    $winget = Get-Command 'winget.exe' -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw "winget is not available on this machine. Install Tailscale manually from https://tailscale.com/download/windows and rerun this script."
    }

    # We capture output so the CLI stays clean; full output is shown only on failure.
    $wingetArgs = @(
        'install',
        '--id', 'Tailscale.Tailscale',
        '--exact',
        '--silent',
        '--accept-package-agreements',
        '--accept-source-agreements'
    )
    $output = & $winget.Source @wingetArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        $output | ForEach-Object { Write-Info $_ }
        throw "winget failed to install Tailscale (exit code $LASTEXITCODE)."
    }

    $exe = Get-TailscaleExe
    if (-not $exe) {
        throw "Tailscale appears to be installed but tailscale.exe was not found. Check your PATH or reboot and rerun this script."
    }
    return $exe
}

function Connect-Tailscale {
    param(
        [Parameter(Mandatory)][string]$TailscaleExe,
        [Parameter(Mandatory)][string]$Hostname
    )

    Write-Info "Running: tailscale up --hostname=$Hostname --unattended"
    Write-Info 'If this is the first run, a browser window will open for Tailscale login.'
    Write-Info 'Complete the login in your browser, then return to this terminal.'

    # No auth key on purpose: this triggers the normal interactive login flow.
    # We do not redirect output: the user may need to see the login URL printed by tailscale.
    & $TailscaleExe up --hostname=$Hostname --unattended
    if ($LASTEXITCODE -ne 0) {
        throw "tailscale up failed (exit code $LASTEXITCODE). Try running it manually and rerun this script."
    }
}

function Wait-ForTailscaleIp {
    param(
        [Parameter(Mandatory)][string]$TailscaleExe,
        [int]$TimeoutSeconds = 300
    )

    Write-Info 'Waiting for a Tailscale IPv4 address (up to 5 minutes)...'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $raw = (& $TailscaleExe ip -4 2>$null) | Out-String
        $ip  = ($raw -split "`r?`n" | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1)
        if ($ip) {
            return $ip.Trim()
        }
        Start-Sleep -Seconds 3
    }
    throw "Timed out waiting for a Tailscale IPv4 address. Make sure the Tailscale login was completed and the machine is connected to the tailnet."
}

function Disable-DefaultOpenSshFirewallRule {
    # SECURITY (fail-closed): the OpenSSH.Server capability creates a built-in
    # firewall rule named 'OpenSSH-Server-In-TCP' that is enabled by default
    # and allows port 22 from every profile. We must keep it disabled at all
    # times. Step 8 of the bootstrap creates a Tailscale-restricted rule;
    # until then (and on every rerun) the only allow-rule is ours.
    $rule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
    if ($rule -and $rule.Enabled -ne 'False') {
        Disable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP'
        Write-Info "Disabled default firewall rule 'OpenSSH-Server-In-TCP'."
    }
}

function Install-OpenSshServer {
    # SECURITY: disable the built-in OpenSSH firewall rule BEFORE the capability
    # install (in case it already exists from a prior install) and AGAIN after,
    # because Add-WindowsCapability recreates and enables the rule. We must do
    # this BEFORE starting sshd so the service never has an unrestricted
    # listener accessible on the LAN, even briefly.
    Disable-DefaultOpenSshFirewallRule

    $cap = Get-WindowsCapability -Online -ErrorAction Stop |
        Where-Object { $_.Name -like 'OpenSSH.Server*' } |
        Select-Object -First 1
    if (-not $cap) {
        throw "OpenSSH.Server capability not found on this Windows edition. Install the latest Windows updates and rerun this script."
    }

    if ($cap.State -ne 'Installed') {
        Write-Info "Installing capability: $($cap.Name)"
        Add-WindowsCapability -Online -Name $cap.Name | Out-Null
        # The capability install just recreated the default rule; disable it again.
        Disable-DefaultOpenSshFirewallRule
    } else {
        Write-Info "OpenSSH Server already installed."
    }

    if (-not (Get-Service -Name 'sshd' -ErrorAction SilentlyContinue)) {
        throw "OpenSSH Server is installed but the 'sshd' service is not registered yet. A reboot may be required; reboot and rerun this script."
    }

    Write-Info 'Configuring sshd service (Automatic, started)...'
    Set-Service -Name 'sshd' -StartupType Automatic
    if ((Get-Service -Name 'sshd').Status -ne 'Running') {
        Start-Service -Name 'sshd'
    }
}

function New-RandomPassword {
    param([int]$Length = 32)
    # Cryptographically strong random password. We never display or persist it:
    # access is granted via SSH public keys, not via the password.
    $bytes = New-Object byte[] $Length
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#%^&*()-_=+'
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $bytes) {
        [void]$sb.Append($alphabet[$b % $alphabet.Length])
    }
    return ConvertTo-SecureString -String $sb.ToString() -AsPlainText -Force
}

function Ensure-LocalAdminUser {
    param([Parameter(Mandatory)][string]$Username)

    $existing = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Info "Local user '$Username' already exists; not resetting password."
    } else {
        Write-Info "Creating local user '$Username'..."
        $password = New-RandomPassword -Length 32
        New-LocalUser -Name $Username `
                      -Password $password `
                      -FullName $Username `
                      -Description 'Bootstrap-managed SSH admin user' `
                      -PasswordNeverExpires:$true `
                      -UserMayNotChangePassword:$false | Out-Null
    }

    # Resolve the local Administrators group by SID so this works on
    # non-English Windows installations (e.g. "Administrateurs" in French).
    $adminsSid   = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544'
    $adminsGroup = Get-LocalGroup -SID $adminsSid

    # Idempotent membership add. Get-LocalGroupMember can fail on machines with
    # stale/orphaned SIDs in the group, so we just try to add and treat the
    # typed "MemberExists" error as success. We match on FullyQualifiedErrorId
    # rather than the message text so this works on non-English Windows.
    try {
        Add-LocalGroupMember -Group $adminsGroup -Member $Username -ErrorAction Stop
        Write-Info "Added '$Username' to local Administrators."
    } catch {
        if ($_.FullyQualifiedErrorId -like 'MemberExists*') {
            Write-Info "'$Username' is already a local administrator."
        } else {
            throw
        }
    }
}

function Get-GitHubPublicKeys {
    param([Parameter(Mandatory)][string]$User)

    $url = "https://api.github.com/users/$User/keys"
    Write-Info "Fetching public keys from $url"

    # GitHub requires a User-Agent header. TLS 1.2 is enforced for compatibility
    # with older PowerShell defaults on Windows Server.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    try {
        $response = Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = 'tailscale-bootstrap-windows' } -UseBasicParsing
    } catch {
        throw "Failed to fetch SSH keys for GitHub user '$User': $($_.Exception.Message)"
    }

    if (-not $response) {
        throw "No SSH keys returned for GitHub user '$User'. Add at least one SSH key at https://github.com/settings/keys and rerun."
    }

    $validPrefixes = @(
        'ssh-ed25519 ',
        'ecdsa-sha2-nistp256 ',
        'ecdsa-sha2-nistp384 ',
        'ecdsa-sha2-nistp521 ',
        'ssh-rsa '
    )

    $keys = @()
    foreach ($entry in $response) {
        $k = ($entry.key).Trim()
        if (-not $k) { continue }
        $accepted = $false
        foreach ($p in $validPrefixes) {
            if ($k.StartsWith($p)) { $accepted = $true; break }
        }
        if ($accepted) {
            $keys += $k
        } else {
            Write-WarningMessage "Skipping a key that does not match a known SSH public-key prefix."
        }
    }

    if ($keys.Count -eq 0) {
        throw "GitHub user '$User' has keys, but none matched a known SSH public-key prefix."
    }

    return $keys
}

function Set-AdministratorsAuthorizedKeys {
    param([Parameter(Mandatory)][string[]]$Keys)

    # Defensive: refuse to write an empty authorized_keys file. An empty file
    # would lock everyone out of SSH on the next sshd restart. The caller
    # already validates that GitHub returned at least one key, but we re-check
    # here to keep this function safe to call directly.
    if (-not $Keys -or $Keys.Count -eq 0) {
        throw "Refusing to write an empty administrators_authorized_keys file."
    }

    $sshDir  = 'C:\ProgramData\ssh'
    $keyFile = Join-Path $sshDir 'administrators_authorized_keys'

    if (-not (Test-Path -LiteralPath $sshDir)) {
        # OpenSSH installer normally creates this directory; create it if needed.
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    }

    # Read existing keys so we can de-duplicate without losing manual entries.
    $existing = @()
    if (Test-Path -LiteralPath $keyFile) {
        $existing = Get-Content -LiteralPath $keyFile -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') }
    }

    $merged = New-Object System.Collections.Generic.List[string]
    $seen   = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($line in $existing) {
        if ($seen.Add($line)) { [void]$merged.Add($line) }
    }
    $added = 0
    foreach ($k in $Keys) {
        if ($seen.Add($k)) {
            [void]$merged.Add($k)
            $added++
        }
    }

    # Write file with a trailing newline using ASCII (avoids accidental BOM).
    $content = ($merged -join "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($keyFile, $content, [System.Text.Encoding]::ASCII)
    Write-Info ("Installed {0} key(s); {1} new, {2} already present." -f $merged.Count, $added, ($merged.Count - $added))

    # SECURITY: administrators_authorized_keys must be writable only by SYSTEM
    # and BUILTIN\Administrators. Anything looser lets sshd refuse the file
    # (sshd's StrictModes check) and is a privilege-escalation risk.
    # We use SIDs to avoid localized account-name issues.
    $systemSid = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18'
    $adminsSid = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544'

    $acl = Get-Acl -LiteralPath $keyFile
    # Disable inheritance and discard any inherited rules.
    $acl.SetAccessRuleProtection($true, $false)
    # Strip every existing access rule so the final DACL contains only what we add below.
    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRule($rule)
    }

    $rights = [System.Security.AccessControl.FileSystemRights]::FullControl
    $allow  = [System.Security.AccessControl.AccessControlType]::Allow
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($systemSid, $rights, $allow)))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($adminsSid, $rights, $allow)))
    $acl.SetOwner($adminsSid)

    Set-Acl -LiteralPath $keyFile -AclObject $acl
}

function Set-SshdConfig {
    param([Parameter(Mandatory)][string]$AllowedUser)

    $configPath = 'C:\ProgramData\ssh\sshd_config'
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "sshd_config not found at $configPath. Is OpenSSH Server installed correctly?"
    }

    # Desired directives. Order matters only when we need to append new ones.
    $desired = [ordered]@{
        'PubkeyAuthentication'        = 'yes'
        'PasswordAuthentication'      = 'no'
        'KbdInteractiveAuthentication'= 'no'
        'PermitEmptyPasswords'        = 'no'
        'AuthenticationMethods'       = 'publickey'
        'AllowUsers'                  = $AllowedUser
    }

    $lines = Get-Content -LiteralPath $configPath
    $output = New-Object System.Collections.Generic.List[string]
    $applied = @{}
    foreach ($k in $desired.Keys) { $applied[$k] = $false }

    foreach ($line in $lines) {
        $trim = $line.TrimStart()
        $matched = $false
        foreach ($k in $desired.Keys) {
            # Match active (non-comment) directives. We comment out duplicates so
            # subsequent runs stay idempotent without clobbering user comments.
            if ($trim -match ('^(?i)' + [regex]::Escape($k) + '\s+\S')) {
                if (-not $applied[$k]) {
                    [void]$output.Add(("{0} {1}" -f $k, $desired[$k]))
                    $applied[$k] = $true
                } else {
                    [void]$output.Add('# ' + $line + '   # commented by bootstrap (duplicate)')
                }
                $matched = $true
                break
            }
        }
        if (-not $matched) {
            [void]$output.Add($line)
        }
    }

    # Append any directive we never saw.
    $appended = @()
    foreach ($k in $desired.Keys) {
        if (-not $applied[$k]) {
            $appended += ("{0} {1}" -f $k, $desired[$k])
        }
    }
    if ($appended.Count -gt 0) {
        [void]$output.Add('')
        [void]$output.Add('# Added by tailscale-bootstrap-windows')
        foreach ($a in $appended) { [void]$output.Add($a) }
    }

    $newContent = ($output -join "`r`n") + "`r`n"
    $existing   = ''
    if (Test-Path -LiteralPath $configPath) {
        $existing = [System.IO.File]::ReadAllText($configPath)
    }
    if ($existing -ne $newContent) {
        [System.IO.File]::WriteAllText($configPath, $newContent, [System.Text.UTF8Encoding]::new($false))
        Write-Info 'sshd_config updated; restarting sshd...'
        Restart-Service -Name 'sshd'
    } else {
        Write-Info 'sshd_config already in desired state.'
    }
}

function Set-DefaultSshShellToPowerShell {
    $regPath = 'HKLM:\SOFTWARE\OpenSSH'
    $shell   = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'

    if (-not (Test-Path -LiteralPath $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    New-ItemProperty -Path $regPath -Name 'DefaultShell' -Value $shell -PropertyType String -Force | Out-Null
    Write-Info "DefaultShell set to $shell"
}

function Set-SshFirewallTailscaleOnly {
    param([Parameter(Mandatory)][string]$TailscaleIPv4)

    $newRule = 'OpenSSH-Server-In-TCP-TailscaleOnly'

    # Belt-and-braces: the default rule was already disabled by
    # Install-OpenSshServer, but make sure it's still disabled here so reruns
    # cannot leave it enabled.
    Disable-DefaultOpenSshFirewallRule

    # Remove our previous rule so we can recreate it cleanly (idempotent).
    $existingNew = Get-NetFirewallRule -Name $newRule -ErrorAction SilentlyContinue
    if ($existingNew) {
        Remove-NetFirewallRule -Name $newRule
    }

    # Prefer scoping by InterfaceAlias (the Tailscale virtual adapter); this
    # is more robust than scoping by IP if the tailnet IP ever changes.
    $tsAdapter = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match 'Tailscale' -or
            $_.InterfaceDescription -match 'Tailscale'
        } | Select-Object -First 1

    $common = @{
        Name        = $newRule
        DisplayName = 'OpenSSH Server via Tailscale only'
        Direction   = 'Inbound'
        Protocol    = 'TCP'
        LocalPort   = 22
        Action      = 'Allow'
        Enabled     = 'True'
        Profile     = 'Any'
    }

    if ($tsAdapter) {
        New-NetFirewallRule @common -InterfaceAlias $tsAdapter.Name | Out-Null
        Write-Info "SSH allowed only on Tailscale adapter '$($tsAdapter.Name)'."
    } elseif ($TailscaleIPv4) {
        # Fallback: bind by local address to the Tailscale IPv4. This still
        # avoids exposing SSH on LAN/Internet interfaces.
        New-NetFirewallRule @common -LocalAddress $TailscaleIPv4 | Out-Null
        Write-Info "SSH allowed only on local address $TailscaleIPv4."
    } else {
        # SECURITY: never fall back to allowing SSH on every interface.
        throw "Could not detect a Tailscale adapter or IPv4. Refusing to open SSH publicly."
    }
}

function New-ProjectDirectories {
    param([Parameter(Mandatory)][string]$Root)

    $dirs = @(
        $Root,
        (Join-Path $Root 'cache'),
        (Join-Path $Root 'data'),
        (Join-Path $Root 'tmp')
    )
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            Write-Info "Created $d"
        } else {
            Write-Info "Already exists: $d"
        }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    Write-Title 'Windows Headless Bootstrap'

    Write-Host 'Selected configuration:' -ForegroundColor White
    Write-Host ''
    Write-Host ("  GitHub user:  {0}" -f $GitHubUser)
    Write-Host ("  Machine name: {0}" -f $MachineName)
    Write-Host ("  SSH user:     {0}" -f $SshUser)
    Write-Host ("  Project root: {0}" -f $ProjectRoot)

    Write-Section 'Planned operations:'
    $plan = @(
        'Check administrator privileges',
        'Install or locate Tailscale',
        'Connect machine to Tailscale',
        'Install and start OpenSSH Server',
        'Create local admin SSH user',
        'Fetch public SSH keys from GitHub',
        'Configure SSH key-only authentication',
        'Restrict SSH firewall access to Tailscale',
        'Create project directories'
    )
    for ($i = 0; $i -lt $plan.Count; $i++) {
        Write-Host ("  [{0}/{1}] {2}" -f ($i + 1), $plan.Count, $plan[$i])
    }

    $total = $plan.Count

    Write-Step 1 $total 'Checking administrator privileges...'
    if (-not (Test-IsAdministrator)) {
        throw "This script must be run as Administrator. Right-click PowerShell and choose 'Run as Administrator'."
    }
    Write-Success

    Write-Step 2 $total 'Installing or locating Tailscale...'
    $tailscaleExe = Install-Tailscale
    Write-Success

    Write-Step 3 $total 'Connecting machine to Tailscale...'
    Connect-Tailscale -TailscaleExe $tailscaleExe -Hostname $MachineName
    $tailscaleIp = Wait-ForTailscaleIp -TailscaleExe $tailscaleExe -TimeoutSeconds 300
    Write-Info "Tailscale IPv4: $tailscaleIp"
    Write-Success

    Write-Step 4 $total 'Installing and starting OpenSSH Server...'
    Install-OpenSshServer
    Write-Success

    Write-Step 5 $total 'Creating local admin SSH user...'
    Ensure-LocalAdminUser -Username $SshUser
    Write-Success

    Write-Step 6 $total 'Fetching public SSH keys from GitHub...'
    $githubKeys = Get-GitHubPublicKeys -User $GitHubUser
    Write-Info ("Got {0} key(s) from GitHub user '{1}'." -f $githubKeys.Count, $GitHubUser)
    Write-Success

    Write-Step 7 $total 'Configuring SSH key-only authentication...'
    Set-AdministratorsAuthorizedKeys -Keys $githubKeys
    Set-SshdConfig -AllowedUser $SshUser
    Set-DefaultSshShellToPowerShell
    Write-Success

    Write-Step 8 $total 'Restricting SSH firewall access to Tailscale...'
    Set-SshFirewallTailscaleOnly -TailscaleIPv4 $tailscaleIp
    Write-Success

    Write-Step 9 $total 'Creating project directories...'
    New-ProjectDirectories -Root $ProjectRoot
    Write-Success

    Write-Title 'Final result'
    Write-Host '  Tailscale IP:' -ForegroundColor White
    Write-Host ("    {0}" -f $tailscaleIp) -ForegroundColor Green
    Write-Host ''
    Write-Host '  Connect from your laptop:' -ForegroundColor White
    Write-Host ("    ssh {0}@{1}" -f $SshUser, $MachineName) -ForegroundColor Green
    Write-Host ("    ssh {0}@{1}" -f $SshUser, $tailscaleIp)  -ForegroundColor Green
    Write-Host ''
    Write-Host '  Reminders:' -ForegroundColor White
    Write-Host '    - SSH password login is disabled (key-only).'
    Write-Host '    - SSH is restricted to the Tailscale interface.'
    Write-Host '    - Once you have verified SSH from your laptop, you can'
    Write-Host '      unplug the screen and keyboard from this machine.'
    Write-Host ''
}
catch {
    Write-ErrorMessage -Text $_.Exception.Message -Suggestion 'Read the message above, fix the cause, then rerun this script. It is safe to rerun.'
    exit 1
}
