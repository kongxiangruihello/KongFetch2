#!/bin/bash
# 双击运行：编译 KongFetch 并安装到“应用程序”文件夹。
# 输出同时保存在 build/build.log。
cd "$(dirname "$0")"
bash scripts/build-app.sh --install
status=$?
echo
if [[ $status -eq 0 ]]; then
  echo "完成。KongFetch 已安装并启动，可以关闭这个窗口。"
else
  echo "构建失败（退出码 $status）。详细信息在 build/build.log。"
fi
