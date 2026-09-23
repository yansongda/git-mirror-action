#!/usr/bin/env bash
# ============================================================
# GitCode 平台适配（兼容 Gitee API v5 风格）
# 插件文件只做声明；如需适配非 v5 风格的 API，可在此覆盖
# common.sh 中的 dst_api 函数（全平台调用自动切换）
# ============================================================

PLATFORM_HOST="gitcode.com"
PLATFORM_API="https://api.gitcode.com/api/v5"
