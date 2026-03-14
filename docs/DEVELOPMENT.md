# 开发与仓库约定

本文档对应“执行 3”，目标不是改动核心部署逻辑，而是在不破坏现有使用方式的前提下，把仓库整理成更容易维护的脚本工程。

## 当前结构

```text
flyto-network/
├── docs/                # 架构图、分析文档、拓扑图
├── modules/             # 核心部署模块
├── scripts/             # 仓库级检查与开发辅助脚本
├── tools/               # 面向运维者的辅助工具
├── flyto.sh             # 主入口
├── Makefile             # 统一开发命令入口
├── LICENSE
├── README.md
└── secrets.enc
```

## 为什么这样整理

- `modules/` 继续承载生产逻辑，避免影响现有入口和 README。
- `docs/` 集中放分析、架构和审计结果，避免 README 过重。
- `scripts/` 放仓库维护脚本，和面向使用者的 `tools/` 区分开。
- `Makefile` 提供统一命令入口，降低接手门槛。

## 本次新增的工程化内容

- `Makefile`
  - `make check` 运行基础语法与目录校验
- `scripts/check.sh`
  - 校验 Bash 语法
  - 校验关键目录存在
  - 防止误生成 `{modules,tools,docs}` 这类异常目录
- `.editorconfig`
  - 统一换行、缩进和文件尾换行
- `.gitignore`
  - 忽略常见本地编辑器和 macOS 垃圾文件

## 建议的后续整理方向

- 新增 `lib/` 目录，把颜色输出、OS 检测、网络探测等公共逻辑抽离。
- 为 `modules/hk-setup.sh` 和 `modules/warp.sh` 提供 `--non-interactive` 参数。
- 引入 `shellcheck` 和 `shfmt`，让 `make check` 更完整。
- 未来如果功能继续增长，可把 `docs/` 拆分为 `architecture/`、`operations/`、`audits/`。
