---
name: vitis-classic-vscode
description: Set up VS Code development for AMD/Xilinx Vitis Classic embedded software projects, especially Vitis 2020.2 standalone/Zynq projects. Use when the user wants to install or repair VS Code tasks, clangd include resolution, XSCT download/debug workflows, GDB ELF verification, Vivado open tasks, or README documentation for an existing Vitis workspace, .xsa/.xpr project, BSP, or embedded C application.
---

# Vitis Classic VS Code

Use this skill to install a reusable VS Code programming environment for a
Vitis Classic embedded software project.

## Required First Step

Ask which project to configure before editing files unless the user already
gave all needed paths. Ask for:

- VS Code workspace root, for example `D:\Project\fpga`
- Vitis Classic workspace, for example `helloworld\vitis`
- application project name, for example `hello_world`
- platform project name, for example `system_wrapper`
- Vitis install root/version, defaulting to `A:\App\xilinx\Vitis\2020.2`

If the workspace has exactly one clear `.xpr`, `.xsa`, `platform.spr`, and
application `Debug\makefile`, state the inferred project and proceed. If there
are multiple candidates, ask the user to choose.

## Workflow

1. Inspect the repo with `rg --files` and targeted file reads.
2. Confirm the Vitis Classic layout:
   - `<vitis-workspace>\<app>\src`
   - `<vitis-workspace>\<app>\Debug\makefile`
   - `<vitis-workspace>\<app>\_ide\psinit\ps7_init.tcl`
   - `<vitis-workspace>\<platform>\export\<platform>\hw\*.xsa`
   - BSP include directory containing `xil_printf.h`, `sleep.h`, and
     `xparameters.h`
3. Generate VS Code files with `scripts/Install-VitisClassicVsCode.ps1`.
4. Validate generated JSON and build with the generated task command.
5. Refresh clangd with the generated script/config.
6. Generate or update README documentation explaining every task and the safe
   order of use.

Do not manually hand-edit include paths when clangd cannot find Vitis headers.
Generate `compile_commands.json`, `.clangd`, and `.vscode/settings.json` from
the project data instead.

## Script

Prefer the bundled script:

```powershell
powershell.exe -ExecutionPolicy Bypass `
  -File <skill-dir>\scripts\Install-VitisClassicVsCode.ps1 `
  -WorkspaceRoot <workspace-root> `
  -VitisWorkspace <relative-or-absolute-vitis-workspace> `
  -AppName <application-project-name> `
  -PlatformName <platform-project-name> `
  -VitisRoot A:\App\xilinx\Vitis\2020.2
```

The script creates or updates:

- `.vscode\tasks.json`
- `.vscode\extensions.json`
- `.vscode\settings.json`
- `.vscode\download_<app>.tcl`
- `.vscode\debug_console_<app>.tcl`
- `compile_commands.json`
- `.clangd`
- `README.md` or `README-vitis-vscode.md`

It avoids PL bitstream download. Vivado bitstream programming remains a Vivado
Hardware Manager task unless the user explicitly asks to automate it.

## Tasks To Generate

Generate these tasks:

- `Vitis: Build <app>`: call `settings64.bat`, then run `make -C <app>\Debug all`
- `Vitis: Clean <app>`: call `settings64.bat`, then run `make -C <app>\Debug clean`
- `Vitis: Verify GDB <app> ELF`: use Xilinx `arm-none-eabi-gdb` to read the ELF
- `Vitis: Download <app> (XSCT)`: build, initialize PS, `dow`, then `con`
- `Vitis: Debug Console <app> (XSCT)`: build, initialize PS, `dow`, then stay
  interactive for `con`, `stop`, `targets`, `bpadd`, `bplist`, `bpremove`
- `Vivado: Open <project>.xpr`: open the Vivado project when `.xpr` exists

Use XSCT, not XSDB, for Vitis Classic download/debug tasks unless the user
explicitly requests XSDB.

## README Requirements

Always generate README documentation for the configured project. It must include:

- project paths and toolchain version
- what each VS Code task does
- exact task execution order
- warning that XSCT download/debug tasks run `rst -system`
- distinction between PS ELF download and PL bitstream download
- clangd refresh command
- common troubleshooting for missing headers, wrong toolchain, and JTAG failure

If `README.md` already exists and contains unrelated project documentation,
write `README-vitis-vscode.md` instead unless the user asks to merge.

## Validation

After generation, run:

```powershell
Get-Content -Raw .vscode\tasks.json | ConvertFrom-Json | Out-Null
Get-Content -Raw compile_commands.json | ConvertFrom-Json | Out-Null
```

Then run the build command, but do not run XSCT download/debug automatically
unless the user explicitly approves, because those tasks reset the target board.

If build fails due to embedded C code, fix the code according to the embedded C
coding skill and rerun the build. For Zynq GPIO pins, prefer pin-level APIs such
as `XGpioPs_SetDirectionPin` and `XGpioPs_SetOutputEnablePin`.
