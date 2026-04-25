<#
.SYNOPSIS
    Example wrapper that calls bootstrap.ps1 with your own values.

.DESCRIPTION
    Copy this file to bootstrap.local.ps1 (which is gitignored) and edit the
    parameter values for your machine. Then run it from an Administrator
    PowerShell prompt:

        PowerShell.exe -ExecutionPolicy Bypass -File .\bootstrap.local.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Edit these values for your setup -------------------------------------
$GitHubUser  = 'your-github-username'
$MachineName = 'petbox'
$SshUser     = 'devops'
$ProjectRoot = 'C:\sources\pet-project'
# --------------------------------------------------------------------------

& "$PSScriptRoot\bootstrap.ps1" `
    -GitHubUser  $GitHubUser `
    -MachineName $MachineName `
    -SshUser     $SshUser `
    -ProjectRoot $ProjectRoot
