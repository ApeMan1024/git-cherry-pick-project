# Git Cherry-Pick 需求合并工具

一个在 **Windows** 上运行的 PowerShell 脚本工具，用于按「需求编号」批量检索 Git 提交记录，并通过 `git cherry-pick` 将指定需求的提交从「合并前项目」合并到「合并后项目」。

## 功能特性

- **多项目支持**：一个配置文件可同时管理多个项目，启动时交互选择要合并的项目
- **按项目独立检索**：每个项目可指定各自的需求编号文件（`gitCommitText.json`），互不干扰
- **精确需求匹配**：提交说明必须完整包含需求编号才命中（`REQ-1001` 不会误匹配 `REQ-10010`）
- **提交记录文件**：为每个需求单独生成 JSON 记录，包含提交文本、提交 ID、提交时间（ISO-8601）
- **中文无乱码**：提交记录中文文案与配置文件中文均正确处理
- **自动跳过已合并**：批量校验（一次 `rev-list` + 一次 `git cherry`）识别已存在或补丁等价的提交，自动跳过，重复运行安全
- **批量合并**：一次 `git cherry-pick` 传入多个提交（每批最多 100 个），大幅提升合并效率；冲突时停在当前提交，处理后自动继续剩余
- **合并前更新目标分支**：自动 `git pull` 将目标分支更新到最新状态；拉取失败时提示手动处理，确认后继续，不会终止程序
- **冲突可交互处理**：冲突时暂停，支持继续 / 跳过 / 中止 / 保留现场退出；外部已处理时自动识别并继续，不会死循环
- **合并提交（merge commit）处理**：自动识别合并提交，提供 `-m 1` 合并 / 跳过 / 中止 / 退出策略
- **简单确认流程**：全程选项式交互（A / B / C / S / E / M / Y / Q），无需手输长命令
- **绝不自动推送**：合并完成后由你自己检查并执行 `git push`

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

## 交互流程

1. **选择项目**：输入项目序号（或输入 `Q` 退出）；也可用 `-ProjectName` 参数直接指定
2. **扫描检索**：按需求编号检索源分支提交记录并生成记录文件
3. **选择需求**：输入 `A` 合并全部，或输入序号（多个用逗号分隔，如 `1,3`）；`Q` 退出
4. **确认合并**：输入 `A` 开始合并，`B` 取消
5. **更新目标分支**：自动 `git pull`；失败时提示手动处理，输入 `Y` 确认继续，`Q` 退出
6. **合并过程**：批量校验并自动跳过已合并提交；批量 `cherry-pick`（每批最多 100 条）：
   - 冲突 / 空提交时暂停：`C` 已解决并 `git add` 后继续 · `S` 跳过该提交 · `A` 中止并恢复 · `E` 保留现场退出
   - 遇到合并提交（merge commit）：`M` 以 `-m 1` 合并 · `S` 跳过 · `A` 中止 · `E` 退出
   - 若在另一个终端手动处理完成后，脚本会自动识别并继续后续合并，不会反复提示

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
- 合并前会检查目标项目工作区是否干净，存在未提交改动将中止
- 同一提交被多个需求命中的会去重，只合并一次
- 合并完成后**不会**执行 `git push`，请自行检查结果后再推送

## 常见问题

**Q：提示"不是 Git 工作区"？**
A：确认 `beforeAddress` / `backAddress` 指向的是包含 `.git` 目录的仓库根目录。

**Q：提示"目标分支没有配置上游分支"？**
A：`git pull` 需要目标分支配置了远程跟踪分支（`@{u}`）。未配置时会提示并跳过更新，不影响合并；也可用 `-SkipPull` 显式跳过。

**Q：配置文件里中文会不会乱码？**
A：脚本支持 UTF-8（含/不含 BOM）与系统默认编码（如 GBK）的配置文件；生成的文件统一为 UTF-8。
