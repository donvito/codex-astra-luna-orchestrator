[CmdletBinding()]
param(
    [switch]$Check,

    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Keep the upstream coordinates fixed.  The updater must never fetch an
# arbitrary URL supplied by release metadata or by an archive entry.
$updaterOwner = 'donvito'
$updaterRepository = 'codex-astra-luna-orchestrator'
$updaterMetadataUri = "https://api.github.com/repos/$updaterOwner/$updaterRepository/releases/latest"
$updaterMetadataTimeoutSeconds = 5
$updaterArchiveTimeoutSeconds = 120
$updaterSkipEnvironmentVariable = 'CODEX_ORCHESTRATOR_SKIP_UPDATE_CHECK'
$updaterScriptDirectory = [IO.Path]::GetFullPath((Split-Path -Parent $PSCommandPath))

function Write-UpdaterWarning {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    [Console]::Error.WriteLine("Updater warning: $Message")
}

function Write-UpdaterError {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    [Console]::Error.WriteLine("Updater error: $Message")
}

function ConvertTo-SemanticVersion {
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    $text = $Value.Trim()
    $match = [regex]::Match(
        $text,
        '^(?:v)?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
    )
    if (-not $match.Success) {
        return $null
    }

    $major = $match.Groups[1].Value
    $minor = $match.Groups[2].Value
    $patch = $match.Groups[3].Value
    $normalized = "$major.$minor.$patch"

    return [pscustomobject]@{
        Major      = $major
        Minor      = $minor
        Patch      = $patch
        Normalized = $normalized
    }
}

function Compare-SemanticVersion {
    param(
        [Parameter(Mandatory)]
        [string]$Left,

        [Parameter(Mandatory)]
        [string]$Right
    )

    $leftVersion = ConvertTo-SemanticVersion -Value $Left
    $rightVersion = ConvertTo-SemanticVersion -Value $Right
    if (($null -eq $leftVersion) -or ($null -eq $rightVersion)) {
        throw "Cannot compare invalid semantic versions ('$Left' and '$Right')."
    }

    foreach ($component in @('Major', 'Minor', 'Patch')) {
        $leftComponent = $leftVersion.$component
        $rightComponent = $rightVersion.$component
        if ($leftComponent.Length -lt $rightComponent.Length) {
            return -1
        }
        if ($leftComponent.Length -gt $rightComponent.Length) {
            return 1
        }

        $componentComparison = [string]::CompareOrdinal($leftComponent, $rightComponent)
        if ($componentComparison -lt 0) {
            return -1
        }
        if ($componentComparison -gt 0) {
            return 1
        }
    }

    return 0
}

function Get-SourceVersion {
    param(
        [Parameter(Mandatory)]
        [string]$SourceDirectory
    )

    $versionPath = Join-Path $SourceDirectory 'VERSION'
    if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
        return $null
    }
    $versionItem = Get-Item -LiteralPath $versionPath -Force -ErrorAction Stop
    if (($versionItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        return $null
    }

    $versionText = [IO.File]::ReadAllText($versionPath).Trim()
    return ConvertTo-SemanticVersion -Value $versionText
}

function Test-UpdaterBoolean {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $false
    }
    if ($Value -is [bool]) {
        return [bool]$Value
    }
    if ($Value -is [string]) {
        return $Value.Trim().Equals('true', [StringComparison]::OrdinalIgnoreCase)
    }
    return [bool]$Value
}

function Get-ReleaseArchiveUrl {
    param(
        [Parameter(Mandatory)]
        [string]$Tag
    )

    $parsedTag = ConvertTo-SemanticVersion -Value $Tag
    if ($null -eq $parsedTag) {
        throw "Release tag is not a stable semantic version: $Tag"
    }

    $encodedTag = [Uri]::EscapeDataString($Tag)
    return "https://github.com/$updaterOwner/$updaterRepository/archive/refs/tags/$encodedTag.zip"
}

function Get-ReleasePageUrl {
    param(
        [Parameter(Mandatory)]
        [string]$Tag
    )

    $parsedTag = ConvertTo-SemanticVersion -Value $Tag
    if ($null -eq $parsedTag) {
        throw "Release tag is not a stable semantic version: $Tag"
    }

    $encodedTag = [Uri]::EscapeDataString($Tag)
    return "https://github.com/$updaterOwner/$updaterRepository/releases/tag/$encodedTag"
}

function Get-LatestRelease {
    [OutputType([pscustomobject])]
    param()

    $headers = @{
        Accept     = 'application/vnd.github+json'
        'User-Agent' = 'codex-astra-luna-orchestrator-updater'
    }

    # Invoke-RestMethod is intentionally used for the unauthenticated GitHub
    # REST request.  TimeoutSec is finite so an installer never hangs on a
    # blocked or disconnected network.
    $release = Invoke-RestMethod `
        -Uri $updaterMetadataUri `
        -Headers $headers `
        -TimeoutSec $updaterMetadataTimeoutSeconds

    if ($null -eq $release) {
        throw 'GitHub returned an empty release response.'
    }
    if (($release.PSObject.Properties.Name -contains 'draft') -and (Test-UpdaterBoolean -Value $release.draft)) {
        throw 'The latest GitHub release is a draft and cannot be installed.'
    }
    if (($release.PSObject.Properties.Name -contains 'prerelease') -and (Test-UpdaterBoolean -Value $release.prerelease)) {
        throw 'The latest GitHub release is a prerelease and cannot be installed.'
    }

    $tag = [string]$release.tag_name
    $version = ConvertTo-SemanticVersion -Value $tag
    if ($null -eq $version) {
        throw "GitHub returned an invalid stable release tag: $tag"
    }

    return [pscustomobject]@{
        Tag        = $tag
        Version    = $version.Normalized
        ReleaseUrl = Get-ReleasePageUrl -Tag $tag
        ArchiveUrl = Get-ReleaseArchiveUrl -Tag $tag
    }
}

function Get-UpdateStatus {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$SourceDirectory,

        [Parameter(Mandatory)]
        [pscustomobject]$Release
    )

    $sourceVersion = Get-SourceVersion -SourceDirectory $SourceDirectory
    $needsUpdate = $false
    $comparison = $null
    if ($null -ne $sourceVersion) {
        $comparison = Compare-SemanticVersion -Left $sourceVersion.Normalized -Right $Release.Version
        $needsUpdate = $comparison -lt 0
    }

    return [pscustomobject]@{
        SourceVersion      = if ($null -eq $sourceVersion) { $null } else { $sourceVersion.Normalized }
        SourceVersionKnown = $null -ne $sourceVersion
        Comparison         = $comparison
        LatestRelease      = $Release
        NeedsUpdate        = $needsUpdate
    }
}

function Invoke-UpdateCheck {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$SourceDirectory
    )

    $release = Get-LatestRelease
    return Get-UpdateStatus -SourceDirectory $SourceDirectory -Release $release
}

function Write-UpdateStatus {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Status
    )

    $sourceText = if ($Status.SourceVersionKnown) { $Status.SourceVersion } else { 'unknown' }
    [Console]::WriteLine("Current source version: $sourceText")
    [Console]::WriteLine("Latest stable release: $($Status.LatestRelease.Tag)")
    [Console]::WriteLine("Release: $($Status.LatestRelease.ReleaseUrl)")
}

function Read-UpdateConfirmation {
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,

        [Parameter(Mandatory)]
        [bool]$DefaultYes
    )

    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        [Console]::Write("$Prompt $suffix ")
        $answer = [Console]::In.ReadLine()
        if ($null -eq $answer) {
            throw 'Input ended before update confirmation was complete.'
        }

        switch ($answer.Trim().ToLowerInvariant()) {
            'y' { return $true }
            'yes' { return $true }
            'n' { return $false }
            'no' { return $false }
            '' { return $DefaultYes }
            default { [Console]::WriteLine('Please answer yes or no.') }
        }
    }
}

function Test-PathWithinDirectory {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Directory
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $resolvedDirectory = [IO.Path]::GetFullPath($Directory).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ([string]::Equals($resolvedPath, $resolvedDirectory, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $prefix = $resolvedDirectory + [IO.Path]::DirectorySeparatorChar
    return $resolvedPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function New-UpdaterStagingDirectory {
    [OutputType([pscustomobject])]
    param()

    $tempDirectory = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        $leaf = 'codex-astra-luna-update-' + [Guid]::NewGuid().ToString('N')
        $candidate = [IO.Path]::GetFullPath((Join-Path $tempDirectory $leaf))
        if (-not (Test-PathWithinDirectory -Path $candidate -Directory $tempDirectory)) {
            throw 'Updater staging path escaped the system temporary directory.'
        }

        try {
            New-Item -ItemType Directory -Path $candidate -ErrorAction Stop | Out-Null
            return [pscustomobject]@{
                Directory    = $candidate
                TempDirectory = $tempDirectory
            }
        }
        catch {
            if (-not (Test-Path -LiteralPath $candidate)) {
                throw
            }
        }
    }

    throw 'Unable to create a unique updater staging directory.'
}

function Remove-UpdaterStagingDirectory {
    param(
        [Parameter(Mandatory)]
        [string]$Directory,

        [Parameter(Mandatory)]
        [string]$TempDirectory
    )

    $resolvedDirectory = [IO.Path]::GetFullPath($Directory)
    $resolvedTempDirectory = [IO.Path]::GetFullPath($TempDirectory)
    if ([string]::Equals($resolvedDirectory.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), $resolvedTempDirectory.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to remove the system temporary directory.'
    }
    if (-not (Test-PathWithinDirectory -Path $resolvedDirectory -Directory $resolvedTempDirectory)) {
        throw 'Refusing to remove a staging path outside the system temporary directory.'
    }

    if (Test-Path -LiteralPath $resolvedDirectory) {
        $stagingItem = Get-Item -LiteralPath $resolvedDirectory -Force -ErrorAction Stop
        if (($stagingItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Refusing to remove a staging path that became a symbolic link or junction.'
        }
        Remove-Item -LiteralPath $resolvedDirectory -Recurse -Force -ErrorAction Stop
    }
}

function Test-ZipEntryName {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $normalized = $Name.Replace('\', '/')
    $isDirectory = $normalized.EndsWith('/')
    $trimmed = $normalized.TrimEnd('/')
    if ([string]::IsNullOrEmpty($trimmed)) {
        throw 'The release archive contains an empty path.'
    }
    if ($trimmed.StartsWith('/') -or [IO.Path]::IsPathRooted($trimmed)) {
        throw "The release archive contains an absolute path: $Name"
    }
    if ($normalized.Contains("`0")) {
        throw 'The release archive contains a path with a NUL character.'
    }

    $segments = $trimmed.Split('/')
    foreach ($segment in $segments) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -eq '.' -or $segment -eq '..') {
            throw "The release archive contains an unsafe path: $Name"
        }
        if ($segment.IndexOf(':') -ge 0) {
            throw "The release archive contains a path with a drive designator: $Name"
        }
        if ($segment.EndsWith('.') -or $segment.EndsWith(' ')) {
            throw "The release archive contains a path that Windows cannot represent safely: $Name"
        }
    }

    return [pscustomobject]@{
        Normalized = $normalized
        Path       = $trimmed
        Segments   = $segments
        IsDirectory = $isDirectory
    }
}

function Test-ZipEntryAttributes {
    param(
        [Parameter(Mandatory)]
        [object]$Entry,

        [Parameter(Mandatory)]
        [bool]$IsDirectory
    )

    # GitHub's source archives carry Unix mode bits.  Permit regular files
    # and directories, and reject links/devices/sockets before extraction.
    # ExternalAttributes is a signed Int32 on Windows PowerShell.  Keep the
    # signed value for the shift, then mask the mode bits; casting a negative
    # Unix-mode value directly to UInt32 is rejected by PowerShell 5.1.
    $attributes = [int64]$Entry.ExternalAttributes
    $mode = ($attributes -shr 16) -band 0xFFFF
    $fileType = $mode -band 0xF000
    if (($fileType -eq 0) -or (($fileType -eq 0x4000) -and $IsDirectory) -or (($fileType -eq 0x8000) -and (-not $IsDirectory))) {
        return
    }

    throw "The release archive contains a link or unsupported filesystem entry: $($Entry.FullName)"
}

function Find-UpdaterReparsePoint {
    param(
        [Parameter(Mandatory)]
        [string]$Directory
    )

    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($Directory)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        foreach ($child in (Get-ChildItem -LiteralPath $current -Force)) {
            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                return $child.FullName
            }
            if ($child.PSIsContainer) {
                $pending.Push($child.FullName)
            }
        }
    }

    return $null
}

function Expand-AndValidateReleaseArchive {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$ArchivePath,

        [Parameter(Mandatory)]
        [string]$ExtractionDirectory
    )

    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        throw "Downloaded release archive is missing: $ArchivePath"
    }

    $resolvedExtractionDirectory = [IO.Path]::GetFullPath($ExtractionDirectory)
    if (Test-Path -LiteralPath $resolvedExtractionDirectory) {
        $existingExtractionItem = Get-Item -LiteralPath $resolvedExtractionDirectory -Force
        if (-not $existingExtractionItem.PSIsContainer) {
            throw 'Updater extraction path is not a directory.'
        }
        if (@(Get-ChildItem -LiteralPath $resolvedExtractionDirectory -Force).Count -ne 0) {
            throw 'Updater extraction directory must be empty.'
        }
    }
    else {
        New-Item -ItemType Directory -Path $resolvedExtractionDirectory -ErrorAction Stop | Out-Null
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $zip = $null
    $pathTypes = @{}
    $rootNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $requiredFiles = @{}
    try {
        $zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
        if ($zip.Entries.Count -eq 0) {
            throw 'The release archive is empty.'
        }

        foreach ($entry in $zip.Entries) {
            $safeEntry = Test-ZipEntryName -Name ([string]$entry.FullName)
            Test-ZipEntryAttributes -Entry $entry -IsDirectory $safeEntry.IsDirectory

            $segments = $safeEntry.Segments
            if (($segments.Count -eq 1) -and (-not $safeEntry.IsDirectory)) {
                throw "The release archive contains a top-level file instead of one source root: $($entry.FullName)"
            }
            if (-not $rootNames.Add($segments[0])) {
                # HashSet.Add returns false for the same root, which is valid.
            }

            $pathKey = $safeEntry.Path.ToLowerInvariant()
            if ($pathTypes.ContainsKey($pathKey)) {
                throw "The release archive contains duplicate paths: $($entry.FullName)"
            }
            $entryType = if ($safeEntry.IsDirectory) { 'directory' } else { 'file' }
            for ($ancestorIndex = 1; $ancestorIndex -lt $segments.Count; $ancestorIndex++) {
                $ancestorPath = ($segments[0..($ancestorIndex - 1)] -join '/').ToLowerInvariant()
                if ($pathTypes.ContainsKey($ancestorPath) -and ($pathTypes[$ancestorPath] -eq 'file')) {
                    throw "The release archive contains a file/directory path conflict: $($entry.FullName)"
                }
            }
            if (-not $safeEntry.IsDirectory) {
                $descendantPrefix = $pathKey + '/'
                foreach ($knownPath in $pathTypes.Keys) {
                    if ($knownPath.StartsWith($descendantPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                        throw "The release archive contains a file/directory path conflict: $($entry.FullName)"
                    }
                }
            }
            $pathTypes[$pathKey] = $entryType

            $relativeWindowsPath = $safeEntry.Path.Replace('/', [IO.Path]::DirectorySeparatorChar)
            $candidate = [IO.Path]::GetFullPath((Join-Path $resolvedExtractionDirectory $relativeWindowsPath))
            if (-not (Test-PathWithinDirectory -Path $candidate -Directory $resolvedExtractionDirectory)) {
                throw "The release archive path escaped the staging directory: $($entry.FullName)"
            }

            if ($segments.Count -ge 2) {
                $relativeToRoot = $segments[1..($segments.Count - 1)] -join '/'
                if ($relativeToRoot -eq 'setup.ps1' -or $relativeToRoot -eq 'AGENTS.md') {
                    if ($safeEntry.IsDirectory) {
                        throw "The release archive contains a directory where a required file is expected: $($entry.FullName)"
                    }
                    $requiredFiles[$relativeToRoot] = $true
                }
            }
        }

        if ($rootNames.Count -ne 1) {
            throw 'The release archive must contain exactly one source root directory.'
        }
        $rootName = @($rootNames)[0]
        if (-not $requiredFiles.ContainsKey('setup.ps1') -or -not $requiredFiles.ContainsKey('AGENTS.md')) {
            throw 'The release archive root must contain setup.ps1 and AGENTS.md.'
        }
        $profilesPathKey = ($rootName + '/profiles').ToLowerInvariant()
        $hasProfiles = $false
        foreach ($knownPath in $pathTypes.Keys) {
            if ([string]::Equals($knownPath, $profilesPathKey, [StringComparison]::OrdinalIgnoreCase) -or $knownPath.StartsWith($profilesPathKey + '/', [StringComparison]::OrdinalIgnoreCase)) {
                if ($pathTypes[$knownPath] -eq 'directory' -or $knownPath.StartsWith($profilesPathKey + '/', [StringComparison]::OrdinalIgnoreCase)) {
                    $hasProfiles = $true
                    break
                }
            }
        }
        if (-not $hasProfiles) {
            throw 'The release archive root must contain a profiles directory.'
        }
    }
    finally {
        if ($null -ne $zip) {
            $zip.Dispose()
        }
    }

    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $resolvedExtractionDirectory -Force -ErrorAction Stop

    $extractedChildren = @(Get-ChildItem -LiteralPath $resolvedExtractionDirectory -Force)
    if ($extractedChildren.Count -ne 1 -or (-not $extractedChildren[0].PSIsContainer)) {
        throw 'The release archive must extract to exactly one source root directory.'
    }
    $rootDirectory = $extractedChildren[0]
    $reparsePoint = Find-UpdaterReparsePoint -Directory $rootDirectory.FullName
    if ($null -ne $reparsePoint) {
        throw "The release archive extracted a symbolic link or junction: $reparsePoint"
    }

    foreach ($requiredPath in @('setup.ps1', 'AGENTS.md')) {
        $requiredItem = Get-Item -LiteralPath (Join-Path $rootDirectory.FullName $requiredPath) -Force -ErrorAction SilentlyContinue
        if (($null -eq $requiredItem) -or $requiredItem.PSIsContainer) {
            throw "The extracted release root is missing a regular file: $requiredPath"
        }
    }
    $profilesItem = Get-Item -LiteralPath (Join-Path $rootDirectory.FullName 'profiles') -Force -ErrorAction SilentlyContinue
    if (($null -eq $profilesItem) -or (-not $profilesItem.PSIsContainer)) {
        throw 'The extracted release root is missing the profiles directory.'
    }

    return $rootDirectory.FullName
}

function Invoke-SetupProcess {
    param(
        [Parameter(Mandatory)]
        [string]$SetupPath
    )

    if (-not (Test-Path -LiteralPath $SetupPath -PathType Leaf)) {
        throw "Release setup script is missing: $SetupPath"
    }

    $originalLocation = (Get-Location).Path
    $hadPreviousValue = $null -ne [Environment]::GetEnvironmentVariable($updaterSkipEnvironmentVariable, 'Process')
    $previousValue = [Environment]::GetEnvironmentVariable($updaterSkipEnvironmentVariable, 'Process')
    try {
        [Environment]::SetEnvironmentVariable($updaterSkipEnvironmentVariable, '1', 'Process')
        # The call operator keeps the current PowerShell host, working
        # directory, stdin, and console prompts.  The downloaded setup gets
        # no updater-specific parameters.
        & $SetupPath
        if (-not $?) {
            throw 'The release setup script reported a failure.'
        }
    }
    finally {
        try {
            Set-Location -LiteralPath $originalLocation
        }
        finally {
            if ($hadPreviousValue) {
                [Environment]::SetEnvironmentVariable($updaterSkipEnvironmentVariable, $previousValue, 'Process')
            }
            else {
                [Environment]::SetEnvironmentVariable($updaterSkipEnvironmentVariable, $null, 'Process')
            }
        }
    }
}

function Invoke-ReleaseInstaller {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Release,

        [switch]$SkipConfirmation
    )

    if ($null -eq $Release.Tag -or $null -eq (ConvertTo-SemanticVersion -Value ([string]$Release.Tag))) {
        throw 'Cannot install a release without a valid stable semantic version tag.'
    }

    if (-not $SkipConfirmation) {
        [Console]::WriteLine("Latest stable release: $($Release.Tag)")
        [Console]::WriteLine("Release: $(Get-ReleasePageUrl -Tag ([string]$Release.Tag))")
        if (-not (Read-UpdateConfirmation -Prompt "Download and run $($Release.Tag) installer?" -DefaultYes $false)) {
            [Console]::WriteLine('Update declined.')
            return $false
        }
    }

    $staging = $null
    try {
        $staging = New-UpdaterStagingDirectory
        $archivePath = Join-Path $staging.Directory 'release.zip'
        $extractionDirectory = Join-Path $staging.Directory 'extract'
        $archiveUrl = Get-ReleaseArchiveUrl -Tag ([string]$Release.Tag)

        [Console]::WriteLine("Downloading $($Release.Tag) from $archiveUrl")
        Invoke-WebRequest `
            -Uri $archiveUrl `
            -OutFile $archivePath `
            -UseBasicParsing `
            -TimeoutSec $updaterArchiveTimeoutSeconds

        $releaseRoot = Expand-AndValidateReleaseArchive `
            -ArchivePath $archivePath `
            -ExtractionDirectory $extractionDirectory
        $setupPath = Join-Path $releaseRoot 'setup.ps1'
        [Console]::WriteLine("Running release installer: $setupPath")
        Invoke-SetupProcess -SetupPath $setupPath
        [Console]::WriteLine("Release $($Release.Tag) setup completed.")
        return $true
    }
    finally {
        if ($null -ne $staging) {
            try {
                Remove-UpdaterStagingDirectory `
                    -Directory $staging.Directory `
                    -TempDirectory $staging.TempDirectory
            }
            catch {
                Write-UpdaterWarning "Could not clean staging directory $($staging.Directory): $($_.Exception.Message)"
            }
        }
    }
}

function Invoke-SetupUpdateCheck {
    param(
        [Parameter(Mandatory)]
        [string]$SourceDirectory,

        [switch]$Offline
    )

    if ($Offline) {
        return 'Skipped'
    }
    if ([string]::Equals(
            [Environment]::GetEnvironmentVariable($updaterSkipEnvironmentVariable, 'Process'),
            '1',
            [StringComparison]::Ordinal
        )) {
        return 'Skipped'
    }

    try {
        $status = Invoke-UpdateCheck -SourceDirectory $SourceDirectory
    }
    catch {
        Write-UpdaterWarning "$($_.Exception.Message) Continuing with local setup."
        return 'Unavailable'
    }

    if (-not $status.SourceVersionKnown) {
        Write-UpdaterWarning 'Local VERSION is missing or invalid; continuing with local setup.'
        return 'Unknown'
    }
    if (-not $status.NeedsUpdate) {
        return 'Current'
    }

    Write-UpdateStatus -Status $status
    if (-not (Read-UpdateConfirmation -Prompt "Download and run $($status.LatestRelease.Tag) installer?" -DefaultYes $false)) {
        [Console]::WriteLine('Update declined; continuing with local setup.')
        return 'Declined'
    }

    # The confirmation happened above, so automatic setup update must not ask
    # the same question a second time.  A failure after acceptance is fatal;
    # continuing with the old installer could apply a confusing partial update.
    $installed = Invoke-ReleaseInstaller -Release $status.LatestRelease -SkipConfirmation
    if ($installed) {
        return 'Installed'
    }
    return 'Declined'
}

function Show-UpdaterHelp {
    [Console]::WriteLine('Usage: update.ps1 [-Check] [-Help]')
    [Console]::WriteLine('')
    [Console]::WriteLine('Checks the latest stable GitHub release and optionally runs its setup.ps1.')
    [Console]::WriteLine('  -Check  Check release metadata only; never downloads or installs.')
    [Console]::WriteLine('  -Help   Show this help text.')
}

function Invoke-Updater {
    param(
        [Parameter(Mandatory)]
        [string]$SourceDirectory,

        [switch]$Check,

        [switch]$Help
    )

    if ($Help) {
        Show-UpdaterHelp
        return 0
    }

    try {
        $status = Invoke-UpdateCheck -SourceDirectory $SourceDirectory
    }
    catch {
        Write-UpdaterError $_.Exception.Message
        return 1
    }

    Write-UpdateStatus -Status $status
    if (-not $status.SourceVersionKnown) {
        [Console]::WriteLine('The source version is unknown; update status requires review.')
    }
    elseif ($status.NeedsUpdate) {
        [Console]::WriteLine('A newer stable release is available.')
    }
    elseif ($status.SourceVersionKnown -and $status.Comparison -eq 0) {
        [Console]::WriteLine('The source version matches the latest stable release.')
    }
    elseif ($status.SourceVersionKnown -and $status.Comparison -gt 0) {
        [Console]::WriteLine('The source version is newer than the latest stable release.')
    }
    else {
        [Console]::WriteLine('The source version status is unavailable.')
    }

    if ($Check) {
        return 0
    }

    try {
        $installed = Invoke-ReleaseInstaller -Release $status.LatestRelease
        if ($installed) {
            return 0
        }
        return 0
    }
    catch {
        Write-UpdaterError $_.Exception.Message
        return 1
    }
}

# Dot-sourcing is the setup.ps1 integration mechanism.  Keep the entrypoint
# behind this guard so importing the library never performs network or disk
# installation work.
if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = Invoke-Updater -SourceDirectory $updaterScriptDirectory -Check:$Check -Help:$Help
    exit ([int]$exitCode)
}
