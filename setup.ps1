[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
$banner = @'
+---------------------------------------+
|    _    ____ _____ ____      _        |
|   / \  / ___|_   _|  _ \    / \       |
|  / _ \ \___ \ | | | |_) |  / _ \      |
| / ___ \ ___) || | |  _ <  / ___ \     |
|/_/   \_\____/ |_| |_| \_\/_/   \_\    |
|                                       |
|       O R C H E S T R A T O R         |
|   Plan and orchestrate with Astra.    |
|          Execute with Luna.           |
+---------------------------------------+
'@

[Console]::WriteLine($banner)
[Console]::WriteLine('Interactive project setup for Windows')

function Read-Confirmation {
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
            throw 'Input ended before setup was complete.'
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

function Read-Plan {
    [Console]::WriteLine('Codex plan:')
    [Console]::WriteLine('  1) Pro  - GPT-6 Astra orchestrates, GPT-5.6 Luna executes, GPT-6 Astra reviews')
    [Console]::WriteLine('  2) Plus - GPT-5.6 Luna (max reasoning) orchestrates, GPT-5.6 Luna executes, GPT-6 Astra reviews')

    while ($true) {
        [Console]::Write('Select plan [1/2] (default 1): ')
        $answer = [Console]::In.ReadLine()
        if ($null -eq $answer) {
            throw 'Input ended before setup was complete.'
        }

        switch ($answer.Trim().ToLowerInvariant()) {
            '1' { return 'pro' }
            'pro' { return 'pro' }
            '' { return 'pro' }
            '2' { return 'plus' }
            'plus' { return 'plus' }
            default { [Console]::WriteLine('Please answer 1 (Pro) or 2 (Plus).') }
        }
    }
}

function Copy-DirectoryContents {
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Destination
    )

    foreach ($sourceChild in (Get-ChildItem -LiteralPath $Source -Force)) {
        $destinationChildPath = Join-Path $Destination $sourceChild.Name
        $destinationChild = Get-Item -LiteralPath $destinationChildPath -Force -ErrorAction SilentlyContinue

        if ($sourceChild.PSIsContainer) {
            if ($null -eq $destinationChild) {
                New-Item -ItemType Directory -Path $destinationChildPath | Out-Null
            }
            elseif (-not $destinationChild.PSIsContainer) {
                throw "Cannot merge directory over file: $destinationChildPath"
            }

            Copy-DirectoryContents -Source $sourceChild.FullName -Destination $destinationChildPath
        }
        else {
            if (($null -ne $destinationChild) -and $destinationChild.PSIsContainer) {
                throw "Cannot overwrite directory with file: $destinationChildPath"
            }

            Copy-Item -LiteralPath $sourceChild.FullName -Destination $destinationChildPath -Force
        }
    }
}

function Find-ReparsePoint {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    foreach ($child in (Get-ChildItem -LiteralPath $Path -Force)) {
        if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $child.FullName
        }
        if ($child.PSIsContainer) {
            $nestedLink = Find-ReparsePoint -Path $child.FullName
            if ($null -ne $nestedLink) {
                return $nestedLink
            }
        }
    }

    return $null
}

function Test-DirectoryMergeCompatible {
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Destination
    )

    foreach ($sourceChild in (Get-ChildItem -LiteralPath $Source -Force)) {
        $destinationChildPath = Join-Path $Destination $sourceChild.Name
        $destinationChild = Get-Item -LiteralPath $destinationChildPath -Force -ErrorAction SilentlyContinue
        if ($null -eq $destinationChild) {
            continue
        }
        if ($sourceChild.PSIsContainer -ne $destinationChild.PSIsContainer) {
            return $false
        }
        if ($sourceChild.PSIsContainer -and (-not (Test-DirectoryMergeCompatible -Source $sourceChild.FullName -Destination $destinationChildPath))) {
            return $false
        }
    }

    return $true
}

function Get-OverwritePaths {
    param(
        [Parameter(Mandatory)]
        [System.IO.FileSystemInfo]$Source,

        [Parameter(Mandatory)]
        [string]$Destination,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not $Source.PSIsContainer) {
        if ($null -ne (Get-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue)) {
            return $Name
        }
        return
    }

    foreach ($sourceFile in (Get-ChildItem -LiteralPath $Source.FullName -File -Recurse -Force)) {
        $relativePath = $sourceFile.FullName.Substring($Source.FullName.Length + 1)
        $destinationFile = Join-Path $Destination $relativePath
        if ($null -ne (Get-Item -LiteralPath $destinationFile -Force -ErrorAction SilentlyContinue)) {
            $path = $Name + [IO.Path]::DirectorySeparatorChar + $relativePath
            Write-Output $path
        }
    }
}

function Show-OverwriteWarning {
    param(
        [Parameter(Mandatory)]
        [System.IO.FileSystemInfo]$Source,

        [Parameter(Mandatory)]
        [string]$Destination,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $paths = @(Get-OverwritePaths -Source $Source -Destination $Destination -Name $Name)
    if ($paths.Count -eq 0) {
        return
    }

    [Console]::WriteLine('WARNING: the following existing files will be overwritten:')
    foreach ($path in $paths) {
        [Console]::WriteLine("  - $path")
    }
}

function Install-Component {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$TargetDirectory,

        [string]$SourcePath
    )

    if ([string]::IsNullOrEmpty($SourcePath)) {
        $SourcePath = Join-Path $scriptDir $Name
    }
    $sourcePath = $SourcePath
    $destinationPath = Join-Path $TargetDirectory $Name
    $sourceItem = Get-Item -LiteralPath $sourcePath -Force -ErrorAction SilentlyContinue
    if ($null -eq $sourceItem) {
        throw "Setup source is missing: $sourcePath"
    }

    $destinationItem = Get-Item -LiteralPath $destinationPath -Force -ErrorAction SilentlyContinue
    if ($null -ne $destinationItem) {
        if (($destinationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            [Console]::Error.WriteLine("Skipped ${Name}: the existing target is a symbolic link or junction.")
            return $false
        }

        if ($sourceItem.PSIsContainer -and $destinationItem.PSIsContainer) {
            $linkedPath = Find-ReparsePoint -Path $destinationPath
            if ($null -ne $linkedPath) {
                [Console]::Error.WriteLine("Skipped ${Name}: the existing target contains a symbolic link or junction ($linkedPath).")
                return $false
            }
            if (-not (Test-DirectoryMergeCompatible -Source $sourcePath -Destination $destinationPath)) {
                [Console]::Error.WriteLine("Skipped ${Name}: source and target types are incompatible.")
                return $false
            }
        }
        elseif (($sourceItem.PSIsContainer -and (-not $destinationItem.PSIsContainer)) -or ((-not $sourceItem.PSIsContainer) -and $destinationItem.PSIsContainer)) {
            [Console]::Error.WriteLine("Skipped ${Name}: source and target types are incompatible.")
            return $false
        }

        if ($Name -eq 'AGENTS.md') {
            $instructions = [IO.File]::ReadAllText($sourcePath)
            $existing = [IO.File]::ReadAllText($destinationPath)
            $normalizedInstructions = $instructions.Replace("`r`n", "`n").TrimEnd("`n")
            if ($existing.Replace("`r`n", "`n").Contains($normalizedInstructions)) {
                [Console]::WriteLine("Skipped ${Name}: instructions already present.")
                return $false
            }
            $reader = [IO.StreamReader]::new($destinationPath, [Text.Encoding]::UTF8, $true)
            try {
                $null = $reader.ReadToEnd()
                $encoding = $reader.CurrentEncoding
            }
            finally {
                $reader.Dispose()
            }
            [IO.File]::AppendAllText($destinationPath, "`n`n" + $instructions, $encoding)
            [Console]::WriteLine("Appended instructions to ${Name}. Existing contents preserved.")
            return $true
        }

        Show-OverwriteWarning -Source $sourceItem -Destination $destinationPath -Name $Name

        if (-not (Read-Confirmation -Prompt "Update ${Name}? New files will be added; only paths listed above will be replaced." -DefaultYes $false)) {
            [Console]::WriteLine("Skipped $Name (existing target left unchanged).")
            return $false
        }

        if ($sourceItem.PSIsContainer -and $destinationItem.PSIsContainer) {
            Copy-DirectoryContents -Source $sourcePath -Destination $destinationPath
        }
        elseif ((-not $sourceItem.PSIsContainer) -and (-not $destinationItem.PSIsContainer)) {
            Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
        }
        else {
            [Console]::Error.WriteLine("Skipped ${Name}: source and target types are incompatible.")
            return $false
        }

        [Console]::WriteLine("Updated $Name.")
        return $true
    }

    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Recurse -Force
    [Console]::WriteLine("Installed $Name.")
    return $true
}

try {
    [Console]::Write('Target repository path: ')
    $targetPath = [Console]::In.ReadLine()
    if ($null -eq $targetPath) {
        throw 'Input ended before a target repository was provided.'
    }
    if ([string]::IsNullOrWhiteSpace($targetPath)) {
        throw 'Target repository path cannot be empty.'
    }

    $targetItem = Get-Item -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue
    if (($null -eq $targetItem) -or (-not $targetItem.PSIsContainer)) {
        throw "Target must be an existing directory: $targetPath"
    }

    $targetDirectory = $targetItem.FullName
    if ([string]::Equals($targetDirectory, $scriptDir, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Target repository must be different from the setup source directory.'
    }

    $plan = Read-Plan
    $profileDirectory = Join-Path $scriptDir "profiles/$plan"

    $installed = 0
    foreach ($component in '.codex', '.agents', 'AGENTS.md') {
        if (Read-Confirmation -Prompt "Install $component?" -DefaultYes $true) {
            $result = if ($component -eq '.codex') {
                Install-Component -Name $component -TargetDirectory $targetDirectory -SourcePath (Join-Path $profileDirectory "codex")
            }
            elseif ($component -eq '.agents') {
                Install-Component -Name $component -TargetDirectory $targetDirectory -SourcePath (Join-Path $profileDirectory "agents")
            }
            else {
                Install-Component -Name $component -TargetDirectory $targetDirectory
            }
            if ($result) {
                $installed++
            }
        }
        else {
            [Console]::WriteLine("Skipped $component.")
        }
    }

    [Console]::WriteLine()
    [Console]::WriteLine("Setup complete. $installed component(s) installed in $targetDirectory (plan: $plan).")
    [Console]::WriteLine('See guides/ for optional Codex model and Fast-mode configurations.')
}
catch {
    [Console]::Error.WriteLine("Setup cancelled: $($_.Exception.Message)")
    exit 1
}
