[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\edl'),
    [switch]$NoInstallPrerequisites,
    [switch]$Uninstall
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Run-Checked {
    param([string]$Exe, [string[]]$Argv)
    & $Exe @Argv
    if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE): $Exe $($Argv -join ' ')" }
}

function Find-Git {
    $found = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $candidates = @()
    if ($found) { $candidates += $found.Source }
    $candidates += @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe'),
        (Join-Path $env:ProgramFiles 'Git\cmd\git.exe')
    )
    foreach ($exe in ($candidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { continue }
        & $exe --version *> $null
        if ($LASTEXITCODE -eq 0) { return $exe }
    }
    return $null
}

function Find-Python {
    $candidates = @()
    foreach ($name in @('python', 'python3', 'py')) {
        $found = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            $prefix = @()
            if ($name -eq 'py') { $prefix = @('-3') }
            $candidates += [pscustomobject]@{ Exe = $found.Source; Prefix = $prefix }
        }
    }
    $root = Join-Path $env:LOCALAPPDATA 'Programs\Python'
    if (Test-Path -LiteralPath $root) {
        foreach ($exe in (Get-ChildItem -LiteralPath $root -Filter python.exe -Recurse -File -ErrorAction SilentlyContinue)) {
            $candidates += [pscustomobject]@{ Exe = $exe.FullName; Prefix = @() }
        }
    }
    foreach ($candidate in $candidates) {
        try {
            $probe = @($candidate.Prefix) + @('-c', 'import sys; print("{}.{}".format(*sys.version_info[:2])); sys.exit(sys.version_info < (3, 10))')
            $version = & $candidate.Exe @probe 2>$null
            if ($LASTEXITCODE -eq 0) {
                return [pscustomobject]@{ Exe = $candidate.Exe; Prefix = @($candidate.Prefix); Version = $version }
            }
        } catch {
            # Skip broken installations and Windows App Execution Aliases.
        }
    }
    return $null
}

function Install-Prerequisite {
    param([string]$PackageId)
    if ($NoInstallPrerequisites) {
        throw "$PackageId is missing. Install it manually or omit -NoInstallPrerequisites."
    }
    $winget = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $winget) { throw "$PackageId is missing and winget is unavailable." }
    Run-Checked $winget.Source @(
        'install', '--id', $PackageId, '--exact', '--scope', 'user',
        '--accept-package-agreements', '--accept-source-agreements'
    )
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath) { $env:Path = "$userPath;$env:Path" }
}

function Update-UserPath {
    param([string]$Directory, [bool]$Remove)
    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    $normalized = [IO.Path]::GetFullPath($Directory).TrimEnd('\', '/')
    $entries = @($current -split ';' | Where-Object {
        $_ -and [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\', '/') -ine $normalized
    })
    if (-not $Remove) { $entries += $Directory }
    [Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'User')
    if ($Remove) {
        $env:Path = (@($env:Path -split ';' | Where-Object {
            $_ -and [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\', '/') -ine $normalized
        }) -join ';')
    } else {
        $env:Path = "$Directory;$env:Path"
    }
}

if (-not $env:LOCALAPPDATA) { throw 'This installer requires Windows and LOCALAPPDATA.' }
$InstallDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InstallDir)
$SourceDir = Join-Path $InstallDir 'src'
$VenvDir = Join-Path $InstallDir '.venv'
$VenvPython = Join-Path $VenvDir 'Scripts\python.exe'
$VenvScripts = Join-Path $VenvDir 'Scripts'
$MarkerFile = Join-Path $InstallDir '.edl-user-install'

if ($Uninstall) {
    if (-not (Test-Path -LiteralPath $MarkerFile -PathType Leaf)) {
        throw "Refusing to remove an unmanaged directory: $InstallDir"
    }
    Update-UserPath $VenvScripts $true
    Remove-Item -LiteralPath $InstallDir -Recurse -Force
    Write-Host "Removed EDL from $InstallDir. Git, Python and USB drivers were not changed."
    return
}
if ((Test-Path -LiteralPath $InstallDir -PathType Container) -and
    -not (Test-Path -LiteralPath $MarkerFile -PathType Leaf)) {
    if (@(Get-ChildItem -LiteralPath $InstallDir -Force).Count -gt 0) {
        throw "Refusing to install into a non-empty unmanaged directory: $InstallDir"
    }
}
$git = Find-Git
if (-not $git) {
    Install-Prerequisite 'Git.Git'
    $git = Find-Git
    if (-not $git) { throw 'Git is still unavailable after installation.' }
}
$python = Find-Python
if (-not $python) {
    # The project and requests>=2.34.2 do not support Python 3.9.
    Install-Prerequisite 'Python.Python.3.13'
    $python = Find-Python
    if (-not $python) { throw 'Python 3.10+ is still unavailable after installation.' }
}
Write-Host "Using Git: $git"
Write-Host "Using Python $($python.Version): $($python.Exe)"

if (Test-Path -LiteralPath $SourceDir) {
    if (-not (Test-Path -LiteralPath (Join-Path $SourceDir '.git'))) {
        throw "Refusing to overwrite an existing non-Git directory: $SourceDir"
    }
    Run-Checked $git @('-C', $SourceDir, 'pull', '--ff-only')
    Run-Checked $git @('-C', $SourceDir, 'submodule', 'update', '--init', '--recursive')
} else {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Set-Content -LiteralPath $MarkerFile -Value 'EDL per-user installation' -Encoding Ascii
    Run-Checked $git @('clone', '--recurse-submodules', 'https://github.com/bkerler/edl.git', $SourceDir)
}
if (-not (Test-Path -LiteralPath $VenvPython -PathType Leaf)) {
    Run-Checked $python.Exe (@($python.Prefix) + @('-m', 'venv', $VenvDir))
}
Run-Checked $VenvPython @('-m', 'pip', 'install', '--upgrade', $SourceDir)
Set-Content -LiteralPath $MarkerFile -Value 'EDL per-user installation' -Encoding Ascii
Update-UserPath $VenvScripts $false
Write-Host "EDL installed at $InstallDir"
Write-Host 'Restart the terminal to use the edl command.'
$legacyDir = Join-Path $env:ProgramFiles 'edl'
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
if ((Test-Path -LiteralPath (Join-Path $legacyDir 'edl.bat')) -and
    (@($machinePath -split ';' | Where-Object {
        $_ -and [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\', '/') -ieq $legacyDir
    }).Count -gt 0)) {
    Write-Warning "An old machine PATH entry ($legacyDir) may shadow this user's edl command."
}
Write-Host "EDL executable: $(Join-Path $VenvScripts 'edl.exe')"
Write-Host 'Install USB/9008 drivers separately if required.'
