# Claude Desktop 完全离线安装

**版本锁定：Claude Desktop `3.6556.2` + Claude Code `2.1.308`**

使用脚本离线安装 Claude 桌面版，并且把 **Cowork 工作区所需的虚拟机及运行时** 一并预置好。安装完成后首次打开 Cowork，不再需要从 `downloads.claude.ai` 官网下载 `rootfs.vhdx.zst`、`claude` 等大文件（没有好的代理和干净节点速度极慢）。



**特别说明**：Claude Code 并非完美 code agent，特别对于 API 用户，额度消耗是很高的（一个分析是它预置上下文特别长，导致输入消耗额度高）。中国模型厂商也在 agent 上发力，能力追赶也不慢，比如 Deepseek 的DSH，完全开源，生态丰富，Claude + 国模 API 的组合可能仅是尝鲜而已，特别是如果模型厂商都在后训练中对自家的 agent 进行特调。

> 适用系统：Windows 10 / Windows 11（64 位）
> 安装和运行时部署**不需要联网**；注意登录账号或者调用模型仍然需要网络。

---

## 为什么需要这个项目

Claude Desktop 的 MSIX 本身体积不大，但 Cowork 功能依赖一套 Linux 虚拟机运行时：

| 文件 | 压缩后 | 说明 |
|---|---:|---|
| `rootfs.vhdx.zst` | 1.31 GB | 工作区根文件系统，解压后约 7.3 GB |
| `claude`（VM 内 CLI） | 292 MB | Cowork 虚拟机里运行的 Claude Code |
| `claude.exe`（宿主 CLI） | 297 MB | Windows 上运行的 Claude Code |
| `vmlinuz.zst` / `initrd.zst` | 43 MB | 虚拟机内核与 initramfs |
| `Claude.msix` | 284 MB | 桌面版本体 |

这些文件默认由 Claude 在首次使用时从 `downloads.claude.ai` 下载。国内网络下速度常常只有几十 KB/s，还可能因为代理中断、HTTP 416、地区限制反复失败，极端情况要挂机数小时。

本项目把**官方原始文件**打包，安装时直接放到 Claude 期望的位置，让它跳过下载，自行解压。

---

## 包含什么

Releases 提供两个资产：

| 资产 | 大小 | 内容 |
|---|---:|---|
| `Claude.msix` | 284 MB | Claude Desktop 3.6556.2 官方安装包 |
| `claude-runtime-3.6556.2-2.1.308.zip` | 约 1.8 GB | Claude Code + Cowork 虚拟机运行时 |

runtime 包内结构如下（安装脚本会按这个结构复制到数据目录）：

```text
runtime/
├── claude-code/
│   └── 2.1.308/
│       └── c17a819afb40/
│           ├── claude.exe
│           ├── .payload
│           └── .verified
├── claude-code-vm/
│   ├── .sdk-version
│   └── 2.1.308/
│       ├── claude
│       ├── .payload
│       └── .verified
└── vm_bundles/
    └── claudevm.bundle/
        ├── rootfs.vhdx.zst
        ├── .rootfs.vhdx.zst.origin
        ├── vmlinuz.zst
        ├── .vmlinuz.zst.origin
        ├── initrd.zst
        ├── .initrd.zst.origin
        └── .cowork-adopted
```

另外附带 `manifest.json`，记录版本、大小和 SHA-256，安装时会逐个校验。

**不会打包**：`rootfs.vhdx`（运行期磁盘，约 7.8GB，可能含用户工作区数据）、`sessiondata.vhdx`（会话数据）、`smol-bin.vhdx`（应用会自己从 MSIX 资源复制）。

---

## 快速开始

1. 下载 Releases 里的两个资产。
2. 解压到同一个目录，保证结构如下：

   ```text
   claude-desktop-offline-install/
   ├── 离线安装Claude完整桌面版.bat
   ├── 卸载Claude桌面版.bat
   ├── scripts/
   ├── pkg/
   │   ├── Claude.msix
   │   ├── manifest.json
   │   └── runtime/
   └── log/
   ```

3. 双击 **`离线安装Claude完整桌面版.bat`**，在弹出的 UAC 提示中点「是」。
4. 安装脚本会自动：
   - 结束正在运行的 Claude 进程
   - 清理旧版 MSIX / 幽灵 `CoworkVMService`
   - 全用户预置安装 `Claude.msix`
   - 把 `pkg\runtime` 部署到数据目录并校验哈希
5. **重启电脑**（MSIX 的 Servicing 状态需要重启才能完成注册）。
6. 打开 Claude，进入 Cowork。首次启动会自动解压 `rootfs.vhdx`（约 7.3GB，通常 16–60 秒），**不再联网下载**。

---

## 数据目录与部署位置

Claude 的数据目录随部署模式不同：

| 模式 | 典型路径 |
|---|---|
| 3p（第三方/企业网关） | `%LOCALAPPDATA%\Claude-3p` |
| 标准 | `%APPDATA%\Claude` |
| 新版可能使用 | `%LOCALAPPDATA%\Claude-Data` |
| 旧版/兼容 | `%LOCALAPPDATA%\Claude` |

安装脚本默认 **自动检测**：

1. 如果 `%LOCALAPPDATA%\Claude\claude_desktop_config.json` 里 `deploymentMode` 是 `3p`，或 `%LOCALAPPDATA%\Claude-3p` 已存在 → 使用 `Claude-3p`
2. 否则如果 `%APPDATA%\Claude` 存在 → 使用标准目录
3. 否则依次检查 `Claude-Data`、`%LOCALAPPDATA%\Claude`
4. 都没有时按标准模式默认（`%APPDATA%\Claude`）

需要强制指定时：

```powershell
# 强制 3p 模式
.\scripts\install-claude-desktop.ps1 -DeploymentMode 3p

# 完全自定义目录（测试或非默认安装位置）
.\scripts\install-claude-desktop.ps1 -DataRoot D:\ClaudeData
```

> 干净机器上，Claude 的数据目录可能在首次启动时才创建。如果安装后首次打开 Cowork 仍要下载，说明实际目录与默认推断不同：先启动一次 Claude 让它创建目录，确认路径后，用 `-DataRoot <实际目录>` 重新运行 `-SkipMsix` 部署即可。

> 运行时是按**当前用户**部署的。多用户电脑请让每个用户分别运行一次 `-SkipMsix -DeploymentMode ...`（MSIX 已由管理员预置）。

---

## 安装脚本参数

| 参数 | 作用 |
|---|---|
| `-PackagePath <path>` | 指定 MSIX，默认 `pkg\Claude.msix` |
| `-DeploymentMode Auto\|3p\|Standard` | 数据目录模式，默认 `Auto` |
| `-DataRoot <path>` | 显式指定数据根目录，优先级最高 |
| `-SkipMsix` | 跳过 MSIX 安装，只部署运行时（不会卸载现有 Claude） |
| `-SkipRuntime` | 只安装 MSIX，不部署运行时 |
| `-DryRun` | 只检查并打印计划，不结束进程、不安装、不复制 |
| `-NoPause` | 结束后不等待回车，便于自动化 |

> 安装前会检查 **C 盘剩余空间**：低于 **12GB** 会提示空间可能不足并退出安装（`-DryRun` 只警告、不退出）。

示例：

```powershell
# 先试运行，确认路径和文件都正确
.\scripts\install-claude-desktop.ps1 -DryRun -NoPause

# 只补装运行时（Claude 已安装）
.\scripts\install-claude-desktop.ps1 -SkipMsix -DeploymentMode 3p
```

---

## 卸载

双击根目录的 **`卸载Claude桌面版.bat`**，输入 `yes` 确认。

默认行为：

- 结束 Claude 进程、卸载 MSIX、清理 `CoworkVMService`、MSIX 沙盒、快捷方式、注册表残留
- **保留** `%USERPROFILE%\.claude`（CLI 配置）
- **保留** `%LOCALAPPDATA%\Claude-3p` 与 `Claude-Data`（应用设置、会话、离线运行时）

如需彻底清理（会释放约 10GB，也会丢失会话）：

```powershell
.\scripts\uninstall-claude-desktop.ps1 -Force -RemoveAppData
```

其他选项：

```powershell
# 只扫描，显示将删除/保留的内容，不执行卸载
.\scripts\uninstall-claude-desktop.ps1 -DryRun

# 同时删除 CLI 配置 ~/.claude
.\scripts\uninstall-claude-desktop.ps1 -Force -RemoveCliConfig

# 清理用户环境变量里的 ANTHROPIC_*
.\scripts\uninstall-claude-desktop.ps1 -Force -CleanEnvVars

# 全部清理
.\scripts\uninstall-claude-desktop.ps1 -Force -RemoveAppData -RemoveCliConfig -CleanEnvVars
```

---

## 工作原理

Claude 判断“运行时是否已就绪”靠三样东西：

1. **文件本身**（`claude.exe`、`claude`、`rootfs.vhdx.zst` 等）
2. **校验标记**：`.verified`（解压后二进制的 SHA-256）、`.payload`（大小 + SHA-256）
3. **来源标记**：`.origin` / `.cowork-adopted`（VM bundle 版本，如 `072b6cbf…`）

安装脚本把这三类文件按原样放好，Claude 启动时就会发现缓存已存在，直接解压，不再发起下载。

首次启动后 Claude 会自己生成 `rootfs.vhdx`、`vmlinuz`、`initrd`、`smol-bin.vhdx`、`sessiondata.vhdx` 等运行期文件；这些**不要**在离线包里分发。

---

## 自己构建离线包

如果你已经有一台能正常使用 Cowork 的电脑，可以用它生成本项目的 `pkg`：

```powershell
# 在项目根目录运行
.\scripts\collect-runtime.ps1
```

脚本会：

- 自动探测数据目录（3p / 标准）
- 收集宿主 CLI、VM CLI、`rootfs.vhdx.zst`、`vmlinuz.zst`、`initrd.zst` 及全部标记
- 从 `%LOCALAPPDATA%\ClaudeInstaller\cache\Claude-win-x64.msix` 复制 MSIX
- 计算 SHA-256，生成 `pkg\manifest.json`
- 写入日志 `log\collect-runtime.log`

常用参数：

```powershell
# 指定源数据目录与输出目录
.\scripts\collect-runtime.ps1 -DataRoot C:\Users\me\AppData\Local\Claude-3p -OutputDir D:\pkg

# 只生成运行时，不收集 MSIX
.\scripts\collect-runtime.ps1 -SkipMsix

# 手动指定 MSIX
.\scripts\collect-runtime.ps1 -MsixPath D:\downloads\Claude.msix
```

收集完成后，把 `pkg` 目录放进安装包，或按 Releases 的方式打包上传。

### 打包发布资产

Windows 10/11 自带 `tar.exe`（bsdtar），可以直接生成 zip：

```powershell
# 运行时包（runtime + manifest），约 1.8GB
tar.exe -a -c -f claude-runtime-3.6556.2-2.1.308.zip -C pkg runtime manifest.json

# MSIX 单独上传
Copy-Item pkg\Claude.msix .\Claude.msix
```

GitHub Releases 单个文件上限约 2GB，runtime 包约 1.8GB，可以单独上传；MSIX 作为另一个资产。

> `pkg` 里的文件很大，不会提交到 Git 仓库；本项目的 `.gitignore` 已忽略 `pkg/*` 与 `log/*.log`。

---

## 磁盘空间

| 阶段 | 占用 |
|---|---:|
| 解压后的安装包（pkg） | 约 2.2 GB |
| MSIX 安装后 | 约 0.6–1 GB |
| 运行时（zst + 二进制） | 约 1.9 GB |
| 首次启动解压出的 `rootfs.vhdx` | 约 7.3 GB，运行后会增长 |
| `sessiondata.vhdx` 等 | 约 0.5 GB 起 |

建议 C 盘至少预留 **12 GB**。安装脚本会在安装前检查 C 盘剩余空间，**低于 12GB 会提示空间可能不足并退出安装**（`-DryRun` 只警告）；部署运行时的目标盘低于 12GB 时也会给出警告。

---

## 常见问题

### 首次打开 Cowork 仍然报 `Host Claude Code binary not available`

说明预置文件没有被识别。依次检查：

1. 数据目录是否选对：看 `log\install-claude-desktop.log` 里的“数据目录”一行。
2. `pkg\manifest.json` 里的版本是否与已安装 MSIX 一致。
3. 重新运行 `.\scripts\install-claude-desktop.ps1 -SkipMsix -NoPause`，它会逐个校验文件并补齐。
4. 如果仍失败，运行 `collect-runtime.ps1` 从当前机器重新生成包（可能是版本已升级）。

### 报 `Request error: net::ERR_NETWORK_ACCESS_DENIED`

这是 Windows/代理层拒绝了连接，不是文件损坏。常见原因：

- 系统代理关闭，但直连 `downloads.claude.ai` 被阻断；
- 代理客户端只监听了 `127.0.0.1`，Claude 的 MSIX 进程访问不到；
- 防火墙/杀软拦截了 `claude.exe`。

本项目通过预置文件**避免下载**，但登录、更新检查仍需要网络。建议开启系统代理，并选择美国/日本/新加坡等支持地区的节点。

### 下载到 100% 后又报错，或卡在 416

Claude 的下载器会用 `Range: bytes=<当前大小>-` 续传。如果文件已经完整，服务器返回 **416**，它可能把 416 当成失败。这不是离线安装流程的问题；本项目不做网络下载，所以不受影响。

### 报 `Claude isn't available in your region`

当前出口 IP 在 Anthropic 不支持的地区（例如香港）。换美国/日本/新加坡节点。

### 点了 “reinstall the workspace” 后进度清零

该按钮会删除本地工作区文件并重新下载。**不要**在运行时未就绪时点它；用本项目的 `-SkipMsix` 补装即可。

### 安装后打不开 Claude

MSIX 可能处于 `Servicing` 状态，**重启电脑**后再打开。安装日志：`log\install-claude-desktop.log`。

### 企业策略禁止 MSIX 侧载

需要 IT 放行 `Add-AppxProvisionedPackage` / MSIX 侧载，或改用官方的企业部署方式。

---

## 版本升级

Claude 升级后会要求新的 Claude Code 版本（例如从 `2.1.308` 升到更高版本），旧的预置文件会被忽略并重新下载。升级流程：

1. 在一台能正常联网的机器上安装新版并成功启动一次 Cowork，让它下载完新运行时；
2. 运行 `.\scripts\collect-runtime.ps1` 重新生成 `pkg`；
3. 更新 README 和 Release 资产里的版本号；
4. 用新版 `pkg` 重新打包发布。

`manifest.json` 会自动记录新版本，安装脚本无需改代码。

---

## 安全与来源

- 所有二进制、MSIX、VM 镜像均来自 Anthropic 官方，**未做任何修改**。
- `manifest.json` 记录每个文件的 SHA-256；安装时会校验，校验失败会中止。
- 本项目不包含任何账号凭据、API Key 或用户会话数据。

Claude Desktop 软件本身由 Anthropic 提供，使用须遵守其服务条款。

---

## 许可

本仓库脚本以 [CC BY-NC 4.0](LICENSE)（署名-非商业性使用）协议发布，**禁止商用**。
