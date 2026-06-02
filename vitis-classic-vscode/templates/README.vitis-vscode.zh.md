# Vitis Classic VS Code 使用说明

本工作区已经配置为 Vitis Classic 嵌入式软件开发环境。

## 工程信息

- 工作区根目录: `@@WORKSPACE@@`
- Vitis workspace: `@@VITIS_WS@@`
- 应用工程: `@@APP@@`
- 平台工程: `@@PLATFORM@@`
- Vitis 根目录: `@@VITIS_ROOT@@`
- ELF: `@@ELF@@`
- XSA: `@@XSA@@`
@@VIVADO_LINE@@

## VS Code Tasks

使用 `Ctrl+Shift+P -> Tasks: Run Task` 执行任务。

- `Vitis: Build @@APP@@`: 先调用 `settings64.bat`，再进入应用工程 `Debug` 目录执行 `make all`。
- `Vitis: Clean @@APP@@`: 先调用 `settings64.bat`，再执行 `make clean`。
- `Vitis: Verify GDB @@APP@@ ELF`: 使用 Xilinx `arm-none-eabi-gdb` 读取 ELF，验证 GDB 和 ELF 可用。
- `Vitis: Download @@APP@@ (XSCT)`: 先构建，再通过 XSCT 复位 PS、执行 `ps7_init`、下载 ELF，然后 `con` 运行。
- `Vitis: Debug Console @@APP@@ (XSCT)`: 先构建，再通过 XSCT 初始化并下载 ELF，最后停留在 XSCT 交互控制台。
- `Vivado: Open ...`: 如果找到 `.xpr`，打开 Vivado 工程，方便处理 PL 内容和 bitstream。

## 推荐使用顺序

1. 执行 `Vitis: Build @@APP@@`。
2. 可选执行 `Vitis: Verify GDB @@APP@@ ELF`。
3. 如果程序依赖 PL 逻辑，先在 Vivado Hardware Manager 中下载 bitstream。
4. 执行 `Vitis: Download @@APP@@ (XSCT)` 下载并运行 PS ELF。
5. 需要命令行调试时，执行 `Vitis: Debug Console @@APP@@ (XSCT)`。

## XSCT 注意事项

下载和调试任务会执行 `rst -system`，会复位目标板 PS。它们只下载 PS 侧 ELF，不会下载 PL bitstream。

常用 XSCT 命令:

```text
con
stop
targets
help bpadd
bplist
bpremove
```

## clangd 头文件索引

如果 VS Code 找不到 `xil_printf.h`、`sleep.h`、`xparameters.h` 等 Vitis/BSP 头文件，重新运行 skill 的安装脚本生成配置，然后执行:

```text
Ctrl+Shift+P -> clangd: Restart language server
```

脚本生成的关键文件是 `compile_commands.json`、`.clangd` 和 `.vscode/settings.json`。

## 常见问题

- 找不到 `xsct`、`make` 或 `arm-none-eabi-gdb`: 检查 `VitisRoot` 是否正确，并确认每个任务都会先调用 `settings64.bat`。
- 找不到 Vitis 头文件: 重新运行安装脚本，让脚本根据 BSP 自动生成 `compile_commands.json`。
- 下载失败: 检查 JTAG、板卡电源、线缆驱动，以及 Vivado Hardware Manager 是否能识别目标板。
- 软件和硬件不一致: 从 Vivado 重新导出 XSA，并重建 Vitis platform/BSP。
