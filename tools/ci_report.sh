#!/bin/sh
# 构建失败时把编译日志贴成 commit comment。
#
# 为什么要有这个：Actions 的日志下载接口即使对公开仓库也要鉴权，
# 在没有 token 的机器上根本看不到失败原因。commit comment 是公开可读的，
# 相当于给 CI 开了一条「只读回传通道」。
#
# 用法（workflow 里）：
#   env: GH_TOKEN: ${{ github.token }}
#   run: sh tools/ci_report.sh

set -e

[ -f build.log ] || { echo "no build.log, skip"; exit 0; }

# 只取尾部：编译错误一般在最后，整份日志贴上去会被 API 拒
tail -c 3000 build.log > /tmp/sl_err.txt

{
    printf '```\n'
    cat /tmp/sl_err.txt
    printf '\n```\n'
} > /tmp/sl_body.txt

gh api "repos/${GITHUB_REPOSITORY}/commits/${GITHUB_SHA}/comments" \
    -F body=@/tmp/sl_body.txt > /dev/null && echo "build log posted to commit comment"