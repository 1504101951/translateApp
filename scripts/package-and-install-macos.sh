#!/bin/bash
# 无参数；串行打包并安装，继承两个脚本的签名环境变量和安全检查。
set -euo pipefail

cd "$(dirname "$0")/.."

# 打包失败立即退出，避免把上次残留的 ZIP 当作本轮产物安装。
bash scripts/package-macos.sh
# 安装脚本负责验签、运行进程检查和失败回滚；此处不重复实现。
bash scripts/install-macos.sh
