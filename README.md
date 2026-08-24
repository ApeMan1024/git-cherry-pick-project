# Git Cherry-Pick 需求合并工具

一个在 **Windows** 上运行的 Git 提交合并工具，提供 **PowerShell 命令行脚本**与**可视化桌面 GUI** 两种操作方式。按「需求编号」批量检索 Git 提交记录，并通过 `git cherry-pick` 将指定需求的提交从「合并前项目」合并到「合并后项目」。

## 功能特性

- **多项目支持**：一个配置文件可同时管理多个项目，启动时交互选择要合并的项目
- **按项目独立检索**：每个项目可指定各自的需求编号文件（`gitCommitText.json`），互不干扰
- **精确需求匹配**：提交说明必须完整包含需求编号才命中（`REQ-1001` 不会误匹配 `REQ-10010`）
- **提交记录文件**：为每个需求单独生成 JSON 记录，包含提交文本、提交 ID、提交时间（ISO-8601）
- **中文无乱码**：提交记录中文文案与配置文件中文均正确处理
- **自动跳过已合并**：批量校验（一次 `rev-list` + 一次 `git cherry`）识别已存在或补丁等价的提交，自动跳过，重复运行安全
- **外部已合清单**：按需求编号记录已合并提交（不污染提交消息），即使冲突解决时改动内容与源提交不同，也能靠清单识别并跳过；启动时按需求多选/全选加载清单
- **残留状态检测**：启动时检测目标仓库未完成的 cherry-pick 状态，支持中止恢复 / 手动处理后继续 / 退出
- **批量合并**：一次 `git cherry-pick` 传入多个提交（每批最多 100 个），大幅提升合并效率；冲突时停在当前提交，处理后自动继续剩余
- **合并前更新目标分支**：自动 `git pull` 将目标分支更新到最新状态；拉取失败时提示手动处理，确认后继续，不会终止程序
- **冲突可交互处理**：冲突时暂停，支持继续 / 跳过 / 中止 / 保留现场退出；外部已处理时自动识别并继续，不会死循环
- **合并提交（merge commit）处理**：自动识别合并提交，提供 `-m 1` 合并 / 跳过 / 中止 / 退出策略
- **简单确认流程**：全程选项式交互（A / B / C / S / E / M / Y / Q），无需手输长命令
- **可视化桌面 GUI**：配套 WinForms 桌面程序（`git-cherry-pick-gui.ps1`），无需记忆命令行即可完成项目选择、需求勾选、合并与冲突处理；并支持在界面内新增 / 修改 / 删除项目配置（自动创建记录目录与需求编号文件）
- **合并完成后可选择推送**：合并成功后可选择直接执行 `git push`（自动识别上游分支；未配置上游时支持以第一个远端做首次推送并设置上游；失败可重试）；也可选择不推送，自行检查后再推

## 环境要求

| 依赖 | 说明 |
| --- | --- |
| 操作系统 | Windows（Windows 10 / 11 或 Windows Server） |
| Git | Git for Windows，需已加入 PATH（`git --version` 可运行） |
| PowerShell | Windows 自带的 PowerShell 5.1 及以上即可，无需额外安装 |

## 文件说明

| 文件 | 说明 |
| --- | --- |
| `git-cherry-pick.ps1` | 主脚本（核心逻辑） |
| `运行合并脚本.cmd` | 双击启动入口（自动以允许执行策略运行脚本，结束后停留窗口） |
| `git-cherry-pick-gui.ps1` | 可视化桌面程序（WinForms GUI，复用核心脚本的数据文件与合并策略，并支持界面内管理项目配置） |
| `运行可视化界面.cmd` | 双击启动 GUI 的入口（已隐藏控制台窗口） |
| `运行可视化界面.vbs` | 无黑窗口启动器（双击仅显示 GUI 窗口，不弹出命令行窗口） |
| `warehouse.json` | 项目配置（需自行创建，参考 `warehouse.example.json`） |
| `gitCommitText.json` | 需求编号配置（需自行创建，参考 `gitCommitText.example.json`） |
| `warehouse.example.json` | 项目配置示例 |
| `gitCommitText.example.json` | 需求编号配置示例 |
| `gitCommitRecord/` | 生成的提交记录文件目录（按项目分目录存放） |

## 快速开始

### 1. 创建项目配置文件 `warehouse.json`

复制 `warehouse.example.json` 为 `warehouse.json`，并填写真实路径：

```json
{
  "project-a": {
    "beforeAddress": "D:\\workspace\\source-project-a",
    "backAddress": "D:\\workspace\\target-project-a",
    "commitRecordAddress": "gitCommitRecord/project-a/",
    "commitTextSearchAddress": "commitTextSearch/project-a/gitCommitText.json"
  },
  "project-b": {
    "beforeAddress": "D:\\workspace\\source-project-b",
    "backAddress": "D:\\workspace\\target-project-b",
    "commitRecordAddress": "gitCommitRecord/project-b/",
    "commitTextSearchAddress": "commitTextSearch/project-b/gitCommitText.json"
  }
}
```

### 2. 创建需求编号文件 `gitCommitText.json`

复制 `gitCommitText.example.json` 为 `gitCommitText.json`（或按项目放置到各自目录）：

```json
[
  {
    "commitText": "REQ-1001"
  },
  {
    "commitText": "REQ-1002"
  }
]
```

### 3. 运行

双击 `运行合并脚本.cmd`，或在 PowerShell 中执行：

```powershell
.\git-cherry-pick.ps1
```

### 4. 可视化桌面 GUI（可选）

如果你更习惯图形界面，可使用配套的可视化桌面程序，无需在命令行输入任何指令。

**启动方式**（任选其一，双击即可）：

- `运行可视化界面.vbs`：推荐，仅显示 GUI 窗口，不弹出命令行黑窗口
- `运行可视化界面.cmd`：启动 GUI，且不保留命令行窗口

**GUI 功能：**

- **项目选择与管理**：下拉 / 列表选择要合并的项目；支持在界面内**新增 / 修改 / 删除**项目（含合并前 / 后地址、提交记录目录、需求编号文件路径），保存时自动创建记录目录与需求编号文件，无需手工编辑 `warehouse.json`
- **需求勾选**：列出各需求命中到的提交数量，勾选要合并的需求即可
- **合并与冲突处理**：内置与核心脚本一致的合并引擎——批量校验并自动跳过已合并提交；遇到冲突 / 空提交 / 合并提交时弹出操作面板，提供继续 / 跳过 / 中止 / 保留现场等选项
- **已合清单**：自动读取并更新 `<项目名>_applied.json`，加载后对应提交不再重复合并
- **推送**：合并完成后询问是否 `git push`，支持首次推送设置上游与失败重试
- **实时日志**：界面内实时显示操作日志，便于核对合并过程

> GUI 与核心脚本共用同一套数据文件（`warehouse.json` / `gitCommitText.json` / `gitCommitRecord/` / `commitTextSearch/`），二者可混用，记录互不冲突。GUI 通过 `运行可视化界面.vbs/.cmd` 启动，无需额外命令行参数。

## 配置详解

### warehouse.json

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `beforeAddress` | 是 | 合并前项目（源）本地地址，提交从该项目检索 |
| `backAddress` | 是 | 合并后项目（目标）本地地址，提交合并到该项目 |
| `commitRecordAddress` | 否 | 提交记录文件生成目录，默认 `gitCommitRecord/<项目名>/` |
| `commitTextSearchAddress` | 否 | 本项目需求编号文件路径，默认使用根目录 `gitCommitText.json`；也兼容 `commitTextAddress` 写法 |

> 路径可以是绝对路径，也可以是相对脚本目录的相对路径（如 `.test-fixture/source`）。

### gitCommitText.json

顶层为数组，每一项必须包含 `commitText` 字段，值为需求编号字符串。重复的需求编号会被自动去重。

## 生成的文件

每个需求生成一个记录文件，命名格式：`<项目名称>_<需求编号>.json`（如 `project-a_REQ-1001.json`）。

```json
{
  "demandNo": "REQ-1001",
  "commitRecordList": [
    {
      "commitText": "feat: REQ-1001 增加订单列表功能",
      "commitId": "50a9795a5551fa0856301201f1b8767b81843e9b",
      "commitTime": "2026-08-10T11:14:31+08:00"
    }
  ]
}
```

## 外部已合清单

合并过程中，成功合入的提交会按需求编号记录到清单文件：`gitCommitRecord/<项目名>/<项目名>_applied.json`（记录提交文本与提交 ID，**不修改任何提交消息**）。再次运行时：

- 若清单存在且本次选中的需求有记录，会询问是否加载（`A` 全部加载，或输入序号按需求多选，`Q` 不加载）
- 加载后，这些提交即使冲突解决时内容与源提交不同，也会被识别为"已合并"并跳过，避免重复合并或再次冲突

```json
[
  {
    "demandNo": "REQ-1001",
    "appliedCommitIds": [
      { "commitText": "feat: REQ-1001 增加订单列表功能", "commitId": "50a9795a5551fa0856301201f1b8767b81843e9b" }
    ]
  }
]
```

> 注意：清单文件记录了"本次工具合入过哪些提交"。若你手动 `git reset` 撤回了已合提交，请删除清单中对应条目，否则会被误判为已合并。

## 交互流程

1. **选择项目**：输入项目序号（或输入 `Q` 退出）；也可用 `-ProjectName` 参数直接指定
2. **扫描检索**：按需求编号检索源分支提交记录并生成记录文件
3. **选择需求**：输入 `A` 合并全部，或输入序号（多个用逗号分隔，如 `1,3`）；`Q` 退出
4. **加载已合清单**（可选）：若本次选中的需求存在已合清单，询问是否加载（`A` 全部 / 序号多选 / `Q` 不加载）
5. **确认合并**：输入 `A` 开始合并，`B` 取消
6. **残留状态检测**：若目标仓库存在未完成的 cherry-pick，提示处理（`A` 中止并继续 / `C` 我已手动处理完成 / `E` 退出）
7. **更新目标分支**：自动 `git pull`；失败时提示手动处理，输入 `Y` 确认继续，`Q` 退出
8. **合并过程**：批量校验并自动跳过已合并提交；批量 `cherry-pick`（每批最多 100 条）：
   - 冲突 / 空提交时暂停：`C` 已解决并 `git add` 后继续 · `S` 跳过该提交 · `A` 中止并恢复 · `E` 保留现场退出
   - 遇到合并提交（merge commit）：`M` 以 `-m 1` 合并 · `S` 跳过 · `A` 中止 · `E` 退出
   - 若在另一个终端手动处理完成后，脚本会自动识别并继续后续合并，不会反复提示
9. **推送（可选）**：合并全部完成后，询问是否执行 `git push`。选择推送时自动识别上游分支；未配置上游则以第一个远端做首次推送并设置上游；推送失败可重试。也可选择不推送，自行检查后再推

## 常用参数

```powershell
# 仅扫描生成提交记录文件，不执行合并
.\git-cherry-pick.ps1 -ScanOnly

# 直接指定项目，跳过项目选择
.\git-cherry-pick.ps1 -ProjectName project-a

# 合并时跳过目标分支的 pull 更新
.\git-cherry-pick.ps1 -SkipPull

# 指定配置文件路径（默认读取脚本目录下的 warehouse.json / gitCommitText.json）
.\git-cherry-pick.ps1 -WarehouseFile .\test\warehouse-test.json -DemandFile .\test\demand-test.json
```

## 合并规则

- 合并方向：从「合并前项目」当前分支 →「合并后项目」当前分支
- 合并顺序：按源分支提交时间从旧到新
- 合并前会检查目标项目工作区是否干净，存在未提交改动将中止；同时检测残留的未完成 cherry-pick
- 同一提交被多个需求命中的会去重，只合并一次
- 已合并判断：目标分支历史（rev-list）→ 补丁等价（git cherry）→ 外部已合清单，命中任一即跳过
- 合并完成后会询问是否执行 `git push`：默认不推送，你可一键推送（自动识别上游分支，未配置上游时支持首次推送并设置上游，失败可重试），也可选择自行检查后再推

## 常见问题

**Q：提示"不是 Git 工作区"？**
A：确认 `beforeAddress` / `backAddress` 指向的是包含 `.git` 目录的仓库根目录。

**Q：提示"目标分支没有配置上游分支"？**
A：`git pull` 需要目标分支配置了远程跟踪分支（`@{u}`）。未配置时会提示并跳过更新，不影响合并；也可用 `-SkipPull` 显式跳过。

**Q：配置文件里中文会不会乱码？**
A：脚本支持 UTF-8（含/不含 BOM）与系统默认编码（如 GBK）的配置文件；生成的文件统一为 UTF-8。
