param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,

    [Parameter(Mandatory = $true)]
    [string]$VitisWorkspace,

    [Parameter(Mandatory = $true)]
    [string]$AppName,

    [Parameter(Mandatory = $true)]
    [string]$PlatformName,

    [string]$VitisRoot = "A:\App\xilinx\Vitis\2020.2",
    [string]$VivadoProject = "",
    [string]$LaunchConfigName = "",
    [string]$ProcessorFilter = "",
    [switch]$OverwriteReadme
)

$ErrorActionPreference = "Stop"

function Convert-ToForwardSlash {
    param([string]$Path)
    return $Path.Replace("\", "/")
}

function Resolve-ProjectPath {
    param(
        [string]$Base,
        [string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return (Resolve-Path -LiteralPath $Path).Path
    }

    return (Resolve-Path -LiteralPath (Join-Path $Base $Path)).Path
}

function Assert-PathExists {
    param(
        [string]$Path,
        [string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Description not found: $Path"
    }
}

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Content
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Get-RelativeForwardPath {
    param(
        [string]$BasePath,
        [string]$TargetPath
    )

    $baseUri = [System.Uri]((Convert-ToForwardSlash $BasePath).TrimEnd("/") + "/")
    $targetUri = [System.Uri](Convert-ToForwardSlash $TargetPath)
    return [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString())
}

function Convert-ToComparableText {
    param([string]$Value)

    if ($null -eq $Value) {
        return ""
    }

    return (Convert-ToForwardSlash $Value).ToLowerInvariant()
}

function Find-LaunchValue {
    param(
        [System.Collections.IDictionary]$Attributes,
        [string[]]$KeyPatterns
    )

    foreach ($key in $Attributes.Keys) {
        foreach ($pattern in $KeyPatterns) {
            if ([string]$key -match $pattern) {
                $value = $Attributes[$key]
                if ($value -is [System.Array]) {
                    return (($value | Where-Object { $_ }) -join "; ")
                }

                return [string]$value
            }
        }
    }

    return ""
}

function Join-LaunchText {
    param(
        [System.Collections.IDictionary]$Attributes,
        [string[]]$ExtraValues
    )

    $values = New-Object System.Collections.Generic.List[string]
    foreach ($value in $ExtraValues) {
        if ($value) {
            $values.Add([string]$value)
        }
    }

    foreach ($key in $Attributes.Keys) {
        $values.Add([string]$key)
        $rawValue = $Attributes[$key]
        if ($rawValue -is [System.Array]) {
            foreach ($entry in $rawValue) {
                if ($entry) {
                    $values.Add([string]$entry)
                }
            }
        } elseif ($rawValue) {
            $values.Add([string]$rawValue)
        }
    }

    return ($values -join "`n")
}

function Get-ProcessorFilterFromText {
    param([string]$Text)

    $processorPatterns = @(
        @{ Regex = '(?i)ps7_cortexa9_(\d+)'; Target = 'A9' },
        @{ Regex = '(?i)psu_cortexa53_(\d+)'; Target = 'A53' },
        @{ Regex = '(?i)psu_cortexr5_(\d+)'; Target = 'R5' },
        @{ Regex = '(?i)microblaze_(\d+)'; Target = 'MicroBlaze' },
        @{ Regex = '(?i)cortex[-_ ]?a9\s*#\s*(\d+)'; Target = 'A9' },
        @{ Regex = '(?i)cortex[-_ ]?a53\s*#\s*(\d+)'; Target = 'A53' },
        @{ Regex = '(?i)cortex[-_ ]?r5\s*#\s*(\d+)'; Target = 'R5' },
        @{ Regex = '(?i)microblaze\s*#\s*(\d+)'; Target = 'MicroBlaze' }
    )

    foreach ($pattern in $processorPatterns) {
        if ($Text -match $pattern.Regex) {
            return "*$($pattern.Target)*#$($Matches[1])"
        }
    }

    if ($Text -match '(?i)ps7_cortexa9|cortex[-_ ]?a9') {
        return "*A9*#0"
    }

    if ($Text -match '(?i)psu_cortexa53|cortex[-_ ]?a53') {
        return "*A53*#0"
    }

    if ($Text -match '(?i)psu_cortexr5|cortex[-_ ]?r5') {
        return "*R5*#0"
    }

    if ($Text -match '(?i)microblaze') {
        return "*MicroBlaze*#0"
    }

    return ""
}

function Get-LaunchKind {
    param(
        [string]$Name,
        [string]$Type
    )

    if ($Name -match '(?i)\b(debug|gdb)\b') {
        return "debug"
    }

    if ($Name -match '(?i)\b(run|download)\b') {
        return "run"
    }

    if ($Type -match '(?i)debug|gdb') {
        return "run/debug"
    }

    if ($Type -match '(?i)run') {
        return "run"
    }

    return "unknown"
}

function Read-VitisLaunchConfig {
    param([System.IO.FileInfo]$File)

    try {
        [xml]$xml = Get-Content -Raw -Encoding UTF8 -LiteralPath $File.FullName
    } catch {
        return $null
    }

    if (-not $xml.launchConfiguration) {
        return $null
    }

    $attributes = [ordered]@{}
    foreach ($node in $xml.launchConfiguration.ChildNodes) {
        if ($node.NodeType -ne [System.Xml.XmlNodeType]::Element) {
            continue
        }

        if (-not $node.HasAttribute("key")) {
            continue
        }

        $key = $node.GetAttribute("key")
        if ($node.Name -eq "listAttribute") {
            $values = @()
            foreach ($entry in $node.ChildNodes) {
                if (($entry.NodeType -eq [System.Xml.XmlNodeType]::Element) -and $entry.HasAttribute("value")) {
                    $values += $entry.GetAttribute("value")
                }
            }
            $attributes[$key] = $values
        } elseif ($node.HasAttribute("value")) {
            $attributes[$key] = $node.GetAttribute("value")
        }
    }

    $type = $xml.launchConfiguration.type
    $text = Join-LaunchText -Attributes $attributes -ExtraValues @($File.BaseName, $File.FullName, $type)

    return [pscustomobject]@{
        Name = $File.BaseName
        Path = $File.FullName
        Type = $type
        Kind = Get-LaunchKind -Name $File.BaseName -Type $type
        ProcessorHint = Find-LaunchValue -Attributes $attributes -KeyPatterns @("processor", "cpu", "core", "target.*name")
        ProgramHint = Find-LaunchValue -Attributes $attributes -KeyPatterns @("program", "elf", "application")
        ProcessorFilter = Get-ProcessorFilterFromText -Text $text
        Text = $text
    }
}

function Test-LaunchMatchesProject {
    param(
        [pscustomobject]$Launch,
        [string]$AppName,
        [string]$PlatformName,
        [string]$AppRoot,
        [string]$PlatformRoot
    )

    $text = Convert-ToComparableText $Launch.Text
    $isVitisLaunch = ($text.Contains("xilinx") -or $text.Contains("vitis") -or
        $text.Contains(".elf") -or $text.Contains("cortex") -or $text.Contains("microblaze"))

    if (-not $isVitisLaunch) {
        return $false
    }

    $needles = @(
        (Convert-ToComparableText $AppName),
        (Convert-ToComparableText $PlatformName),
        (Convert-ToComparableText $AppRoot),
        (Convert-ToComparableText $PlatformRoot)
    ) | Where-Object { $_ }

    foreach ($needle in $needles) {
        if ($text.Contains($needle)) {
            return $true
        }
    }

    return $false
}

function Get-VitisLaunchConfigs {
    param(
        [string]$Workspace,
        [string]$VitisWs,
        [string]$AppName,
        [string]$PlatformName,
        [string]$AppRoot,
        [string]$PlatformRoot
    )

    $roots = @($VitisWs, $Workspace, $AppRoot, $PlatformRoot) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
        Select-Object -Unique

    $seen = @{}
    $configs = @()
    foreach ($root in $roots) {
        Get-ChildItem -LiteralPath $root -Force -Recurse -Filter "*.launch" -ErrorAction SilentlyContinue |
            ForEach-Object {
                if ($seen.ContainsKey($_.FullName)) {
                    return
                }

                $seen[$_.FullName] = $true
                $launch = Read-VitisLaunchConfig -File $_
                if ($launch -and (Test-LaunchMatchesProject -Launch $launch -AppName $AppName -PlatformName $PlatformName -AppRoot $AppRoot -PlatformRoot $PlatformRoot)) {
                    $configs += $launch
                }
            }
    }

    return @($configs | Sort-Object Path)
}

function Select-VitisLaunchConfig {
    param(
        [object[]]$LaunchConfigs,
        [string]$LaunchConfigName
    )

    if (-not $LaunchConfigs -or $LaunchConfigs.Count -eq 0) {
        return $null
    }

    if (-not [string]::IsNullOrWhiteSpace($LaunchConfigName)) {
        $matches = @($LaunchConfigs | Where-Object {
            ($_.Name -ieq $LaunchConfigName) -or
            ((Split-Path -Leaf $_.Path) -ieq $LaunchConfigName) -or
            ($_.Path -ieq $LaunchConfigName)
        })

        if ($matches.Count -eq 0) {
            $available = ($LaunchConfigs | ForEach-Object { $_.Name }) -join ", "
            throw "Launch config not found: $LaunchConfigName. Available local Vitis launch configs: $available"
        }

        return $matches[0]
    }

    return @($LaunchConfigs | Sort-Object `
        @{ Expression = { if ($_.ProcessorFilter) { 0 } else { 1 } } }, `
        @{ Expression = {
            switch ($_.Kind) {
                "debug" { 0; break }
                "run/debug" { 1; break }
                "run" { 2; break }
                default { 3; break }
            }
        } },
        Name)[0]
}

$workspace = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$vitisWs = Resolve-ProjectPath -Base $workspace -Path $VitisWorkspace
$appRoot = Join-Path $vitisWs $AppName
$appSrc = Join-Path $appRoot "src"
$appDebug = Join-Path $appRoot "Debug"
$platformRoot = Join-Path $vitisWs $PlatformName
$vscodeDir = Join-Path $workspace ".vscode"
$settingsBat = Join-Path $VitisRoot "settings64.bat"
$gcc = Join-Path $VitisRoot "gnu\aarch32\nt\gcc-arm-none-eabi\bin\arm-none-eabi-gcc.exe"

Assert-PathExists $settingsBat "Vitis settings64.bat"
Assert-PathExists $gcc "Xilinx ARM GCC"
Assert-PathExists $appSrc "Vitis application src directory"
Assert-PathExists (Join-Path $appDebug "makefile") "Vitis application Debug makefile"
Assert-PathExists $platformRoot "Vitis platform project"

$psInit = Join-Path $appRoot "_ide\psinit\ps7_init.tcl"
Assert-PathExists $psInit "PS init Tcl"

$xsaCandidates = @(
    (Join-Path $platformRoot "export\$PlatformName\hw\$PlatformName.xsa"),
    (Join-Path $platformRoot "hw\$PlatformName.xsa")
) + @(Get-ChildItem -LiteralPath $platformRoot -Recurse -Filter "*.xsa" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })

$xsa = $xsaCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $xsa) {
    throw "No XSA found under platform project: $platformRoot"
}

$bspInclude = Get-ChildItem -LiteralPath $platformRoot -Recurse -Directory -Filter "include" |
    Where-Object {
        (Test-Path -LiteralPath (Join-Path $_.FullName "xil_printf.h")) -and
        (Test-Path -LiteralPath (Join-Path $_.FullName "xparameters.h")) -and
        (Test-Path -LiteralPath (Join-Path $_.FullName "sleep.h"))
    } |
    Select-Object -First 1 -ExpandProperty FullName

if (-not $bspInclude) {
    throw "No BSP include directory with xil_printf.h, xparameters.h, and sleep.h found under: $platformRoot"
}

if ($VivadoProject -eq "") {
    $VivadoProject = Get-ChildItem -LiteralPath $workspace -Recurse -Filter "*.xpr" -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
} elseif (-not [System.IO.Path]::IsPathRooted($VivadoProject)) {
    $VivadoProject = Join-Path $workspace $VivadoProject
}

$launchConfigs = @(Get-VitisLaunchConfigs -Workspace $workspace -VitisWs $vitisWs -AppName $AppName -PlatformName $PlatformName -AppRoot $appRoot -PlatformRoot $platformRoot)
$selectedLaunchConfig = Select-VitisLaunchConfig -LaunchConfigs $launchConfigs -LaunchConfigName $LaunchConfigName
$processorFilterSource = "parameter"
if ([string]::IsNullOrWhiteSpace($ProcessorFilter)) {
    if ($selectedLaunchConfig -and $selectedLaunchConfig.ProcessorFilter) {
        $ProcessorFilter = $selectedLaunchConfig.ProcessorFilter
        $processorFilterSource = "launch config: $($selectedLaunchConfig.Name)"
    } else {
        $ProcessorFilter = "*A9*#0"
        $processorFilterSource = "default: Zynq-7000 Cortex-A9 #0"
    }
}

New-Item -ItemType Directory -Force -Path $vscodeDir | Out-Null

$workspaceFs = Convert-ToForwardSlash $workspace
$appSrcFs = Convert-ToForwardSlash $appSrc
$appDebugFs = Convert-ToForwardSlash $appDebug
$xsaFs = Convert-ToForwardSlash $xsa
$psInitFs = Convert-ToForwardSlash $psInit
$bspIncludeFs = Convert-ToForwardSlash $bspInclude
$gccFs = Convert-ToForwardSlash $gcc
$elfFs = "$appDebugFs/$AppName.elf"

$workspaceVar = '${workspaceFolder}'
$settingsCall = 'call "' + $settingsBat + '"'
$appDebugRelWin = (Get-RelativeForwardPath $workspace $appDebug).Replace("/", "\")
$downloadTclRelWin = ".vscode\download_$AppName.tcl"
$debugTclRelWin = ".vscode\debug_console_$AppName.tcl"

$downloadTclPath = Join-Path $vscodeDir "download_$AppName.tcl"
$debugTclPath = Join-Path $vscodeDir "debug_console_$AppName.tcl"
$launchSummaryPath = Join-Path $vscodeDir "vitis_launch_configs.json"

$launchSummary = [ordered]@{
    vitisWorkspace = $vitisWs
    appName = $AppName
    platformName = $PlatformName
    requestedLaunchConfigName = $LaunchConfigName
    selectedProcessorFilter = $ProcessorFilter
    processorFilterSource = $processorFilterSource
    selectedLaunchConfig = if ($selectedLaunchConfig) {
        [ordered]@{
            name = $selectedLaunchConfig.Name
            kind = $selectedLaunchConfig.Kind
            path = $selectedLaunchConfig.Path
            type = $selectedLaunchConfig.Type
            processorHint = $selectedLaunchConfig.ProcessorHint
            programHint = $selectedLaunchConfig.ProgramHint
            inferredProcessorFilter = $selectedLaunchConfig.ProcessorFilter
        }
    } else {
        $null
    }
    recognizedLaunchConfigs = @($launchConfigs | ForEach-Object {
        [ordered]@{
            name = $_.Name
            kind = $_.Kind
            path = $_.Path
            type = $_.Type
            processorHint = $_.ProcessorHint
            programHint = $_.ProgramHint
            inferredProcessorFilter = $_.ProcessorFilter
        }
    })
}
Write-Utf8NoBom -Path $launchSummaryPath -Content ($launchSummary | ConvertTo-Json -Depth 8)

$downloadTcl = @"
# Download and run $AppName on the target.
# This task resets the PS, initializes PS7, downloads the ELF, then continues.

connect -url tcp:127.0.0.1:3121

targets -set -nocase -filter {name =~"APU*"}
rst -system
after 3000

targets -set -nocase -filter {name =~"APU*"}
loadhw -hw $xsaFs -mem-ranges [list {0x40000000 0xbfffffff}] -regs
configparams force-mem-access 1

source $psInitFs
ps7_init
ps7_post_config

targets -set -nocase -filter {name =~ "$ProcessorFilter"}
dow $elfFs
configparams force-mem-access 0

puts "Download complete. Starting $AppName."
con
"@

$debugTcl = @"
# Initialize $AppName for interactive XSCT debugging.
# This resets PS, initializes PS7, downloads the ELF, then stays in XSCT.

connect -url tcp:127.0.0.1:3121

targets -set -nocase -filter {name =~"APU*"}
rst -system
after 3000

targets -set -nocase -filter {name =~"APU*"}
loadhw -hw $xsaFs -mem-ranges [list {0x40000000 0xbfffffff}] -regs
configparams force-mem-access 1

source $psInitFs
ps7_init
ps7_post_config

targets -set -nocase -filter {name =~ "$ProcessorFilter"}
dow $elfFs
configparams force-mem-access 0

puts "XSCT debug console is ready."
puts "Common commands: con, stop, targets, help bpadd, bplist, bpremove."
"@

Write-Utf8NoBom -Path $downloadTclPath -Content $downloadTcl
Write-Utf8NoBom -Path $debugTclPath -Content $debugTcl

$buildCmd = $settingsCall + ' && make -C "' + $workspaceVar + '\' + $appDebugRelWin + '" all'
$cleanCmd = $settingsCall + ' && make -C "' + $workspaceVar + '\' + $appDebugRelWin + '" clean'
$gdbCmd = $settingsCall + ' && set "HOME=%USERPROFILE%" && arm-none-eabi-gdb -batch -ex "file ' + $elfFs + '" -ex "info files"'
$downloadCmd = $settingsCall + ' && xsct "' + $workspaceVar + '\' + $downloadTclRelWin + '"'
$debugCmd = $settingsCall + ' && xsct -interactive "' + $workspaceVar + '\' + $debugTclRelWin + '"'

$tasks = [ordered]@{
    version = "2.0.0"
    tasks = @(
        [ordered]@{
            label = "Vitis: Build $AppName"
            type = "shell"
            command = "cmd.exe"
            args = @("/d", "/c", $buildCmd)
            group = [ordered]@{ kind = "build"; isDefault = $true }
            problemMatcher = '$gcc'
            options = [ordered]@{ cwd = '${workspaceFolder}' }
        },
        [ordered]@{
            label = "Vitis: Clean $AppName"
            type = "shell"
            command = "cmd.exe"
            args = @("/d", "/c", $cleanCmd)
            group = "build"
            problemMatcher = @()
            options = [ordered]@{ cwd = '${workspaceFolder}' }
        },
        [ordered]@{
            label = "Vitis: Verify GDB $AppName ELF"
            type = "shell"
            command = "cmd.exe"
            args = @("/d", "/c", $gdbCmd)
            problemMatcher = @()
            options = [ordered]@{ cwd = '${workspaceFolder}' }
        },
        [ordered]@{
            label = "Vitis: Download $AppName (XSCT)"
            type = "shell"
            command = "cmd.exe"
            args = @("/d", "/c", $downloadCmd)
            dependsOn = @("Vitis: Build $AppName")
            dependsOrder = "sequence"
            problemMatcher = @()
            presentation = [ordered]@{ panel = "dedicated"; reveal = "always" }
            options = [ordered]@{ cwd = '${workspaceFolder}' }
        },
        [ordered]@{
            label = "Vitis: Debug Console $AppName (XSCT)"
            type = "shell"
            command = "cmd.exe"
            args = @("/d", "/c", $debugCmd)
            dependsOn = @("Vitis: Build $AppName")
            dependsOrder = "sequence"
            problemMatcher = @()
            presentation = [ordered]@{ panel = "dedicated"; reveal = "always" }
            options = [ordered]@{ cwd = '${workspaceFolder}' }
        }
    )
}

if ($VivadoProject -and (Test-Path -LiteralPath $VivadoProject)) {
    $vivadoRel = (Get-RelativeForwardPath $workspace $VivadoProject).Replace("/", "\")
    $vivadoCmd = $settingsCall + ' && vivado "' + $workspaceVar + '\' + $vivadoRel + '"'
    $tasks.tasks += [ordered]@{
        label = "Vivado: Open $(Split-Path -Leaf $VivadoProject)"
        type = "shell"
        command = "cmd.exe"
        args = @("/d", "/c", $vivadoCmd)
        problemMatcher = @()
        options = [ordered]@{ cwd = '${workspaceFolder}' }
    }
}

Write-Utf8NoBom -Path (Join-Path $vscodeDir "tasks.json") -Content ($tasks | ConvertTo-Json -Depth 10)

$extensions = [ordered]@{
    recommendations = @(
        "llvm-vs-code-extensions.vscode-clangd",
        "ms-vscode.cpptools"
    )
}
Write-Utf8NoBom -Path (Join-Path $vscodeDir "extensions.json") -Content ($extensions | ConvertTo-Json -Depth 4)

$settings = [ordered]@{
    "editor.inlineSuggest.enabled" = $true
    "editor.quickSuggestions" = [ordered]@{
        other = "on"
        comments = "off"
        strings = "off"
    }
    "editor.suggestOnTriggerCharacters" = $true
    "clangd.arguments" = @(
        "--compile-commands-dir=${workspaceVar}",
        "--query-driver=$gccFs",
        "--background-index",
        "--clang-tidy"
    )
    "C_Cpp.intelliSenseEngine" = "disabled"
    "C_Cpp.autocomplete" = "disabled"
    "C_Cpp.errorSquiggles" = "disabled"
}
Write-Utf8NoBom -Path (Join-Path $vscodeDir "settings.json") -Content ($settings | ConvertTo-Json -Depth 4)

$commonArgs = @(
    $gccFs,
    "-Wall",
    "-O0",
    "-g3",
    "-c",
    "-fmessage-length=0",
    "-mcpu=cortex-a9",
    "-mfpu=vfpv3",
    "-mfloat-abi=hard",
    "-I$appSrcFs",
    "-I$bspIncludeFs"
)

$commands = @(Get-ChildItem -LiteralPath $appSrc -Filter "*.c" | Sort-Object Name | ForEach-Object {
    $sourceFs = Convert-ToForwardSlash $_.FullName
    $objectName = [System.IO.Path]::GetFileNameWithoutExtension($_.Name) + ".o"
    $objectFs = "$appDebugFs/src/$objectName"

    [ordered]@{
        directory = $appDebugFs
        file = $sourceFs
        arguments = @($commonArgs + @("-o", $objectFs, $sourceFs))
    }
})

if ($commands.Count -eq 0) {
    throw "No C source files found under: $appSrc"
}

Write-Utf8NoBom -Path (Join-Path $workspace "compile_commands.json") -Content ($commands | ConvertTo-Json -Depth 8)

$clangdConfig = @"
CompileFlags:
  CompilationDatabase: .
Diagnostics:
  UnusedIncludes: None
"@
Write-Utf8NoBom -Path (Join-Path $workspace ".clangd") -Content $clangdConfig

$readmePath = Join-Path $workspace "README.md"
if ((Test-Path -LiteralPath $readmePath) -and -not $OverwriteReadme) {
    $readmePath = Join-Path $workspace "README-vitis-vscode.md"
}

$templatePath = Join-Path (Split-Path -Parent $PSScriptRoot) "templates\README.vitis-vscode.zh.md"
if (Test-Path -LiteralPath $templatePath) {
    $readmeTemplate = Get-Content -Raw -Encoding UTF8 -LiteralPath $templatePath
} else {
    $readmeTemplate = @'
# Vitis Classic VS Code Usage

- Workspace root: `@@WORKSPACE@@`
- Vitis workspace: `@@VITIS_WS@@`
- Application: `@@APP@@`
- Platform: `@@PLATFORM@@`
- Vitis root: `@@VITIS_ROOT@@`
- ELF: `@@ELF@@`
- XSA: `@@XSA@@`
@@VIVADO_LINE@@

Run tasks with `Ctrl+Shift+P -> Tasks: Run Task`.
'@
}

$vivadoLine = if ($VivadoProject) { '- Vivado project: `' + $VivadoProject + '`' } else { "- Vivado project: not configured" }
$launchConfigLines = @(
    "- Selected XSCT processor filter: ``$ProcessorFilter`` ($processorFilterSource)"
)
if ($selectedLaunchConfig) {
    $launchConfigLines += "- Selected local Vitis launch config: ``$($selectedLaunchConfig.Name)`` [$($selectedLaunchConfig.Kind)]"
}

if ($launchConfigs.Count -eq 0) {
    $launchConfigLines += "- Recognized local Vitis Run/Debug configs: none found"
} else {
    $launchConfigLines += "- Recognized local Vitis Run/Debug configs:"
    foreach ($launchConfig in $launchConfigs) {
        $filter = if ($launchConfig.ProcessorFilter) { $launchConfig.ProcessorFilter } else { "not inferred" }
        $launchConfigLines += "  - ``$($launchConfig.Name)`` [$($launchConfig.Kind)], processor filter ``$filter``, file ``$($launchConfig.Path)``"
    }
}
$launchConfigSummary = $launchConfigLines -join "`r`n"

$readme = $readmeTemplate
$readme = $readme.Replace("@@WORKSPACE@@", $workspace)
$readme = $readme.Replace("@@VITIS_WS@@", $vitisWs)
$readme = $readme.Replace("@@APP@@", $AppName)
$readme = $readme.Replace("@@PLATFORM@@", $PlatformName)
$readme = $readme.Replace("@@VITIS_ROOT@@", $VitisRoot)
$readme = $readme.Replace("@@ELF@@", $elfFs)
$readme = $readme.Replace("@@XSA@@", $xsa)
$readme = $readme.Replace("@@VIVADO_LINE@@", $vivadoLine)
$readme = $readme.Replace("@@LAUNCH_CONFIGS@@", $launchConfigSummary)

Write-Utf8NoBom -Path $readmePath -Content $readme

Get-Content -Raw -LiteralPath (Join-Path $vscodeDir "tasks.json") | ConvertFrom-Json | Out-Null
Get-Content -Raw -LiteralPath (Join-Path $workspace "compile_commands.json") | ConvertFrom-Json | Out-Null

Write-Host "Generated VS Code Vitis Classic environment:"
Write-Host "  $vscodeDir"
Write-Host "  $(Join-Path $workspace 'compile_commands.json')"
Write-Host "  $(Join-Path $workspace '.clangd')"
Write-Host "  $launchSummaryPath"
Write-Host "  $readmePath"
Write-Host "Selected XSCT processor filter: $ProcessorFilter ($processorFilterSource)"
Write-Host "Do not run XSCT download/debug tasks unless target reset is acceptable."
