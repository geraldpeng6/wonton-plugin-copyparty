# shellcheck shell=bash disable=SC2034
# scripts/smoke.sh 的一项一项探测，跟着插件走。没写的项会 FAIL 并给出写法，不会默认放行。
#
# Copyparty：sso=proxy（网关注入 X-Wonton-User，配置见 docker-compose.yml 的内联 copyparty.conf）；
# 清单没有 mcp。SSO/MCP 给冒烟读取，本文件里不使用。
# 钩子只依赖套件契约：SMOKE_STATE/SMOKE_OWNER 变量和 web_get/dweb 助手。
SSO=proxy
MCP=0

# curl UA 拿到的是 copyparty 的纯文本列表（# acct:/# perms: 开头），浏览器 UA 是 UI 页（id="ht_brw"）。
web_assert() { grep -Eq '^(# perms: |.*id="ht_brw")'; }

identity_check() { # 应用自己的目录列表：认出的用户名和权限都在响应头两行里
  local page
  page="$(dweb /)" || { echo "页面失败：$page"; return 1; }
  grep -qF "# acct: $SMOKE_OWNER" <<<"$page" ||
    { echo "应用认出的不是用户 $SMOKE_OWNER：$(head -c 200 <<<"$page")"; return 1; }
  grep -q "'admin'" <<<"$page" ||
    { echo "用户没有 admin 权限：$(head -c 200 <<<"$page")"; return 1; }
}

# 数据：经网关以用户会话上传一个小文件（和浏览器上传同一条路），data_check 读回比对。
# 文件名固定、带 replace: t 覆盖写（实测不带会生成带时间戳后缀的副本）；标记记进
# $SMOKE_STATE（e2e 里是一个文件）。升级+重装流程 data_check 会跑两次，读的都是
# 同一个文件，所以这里不删探针文件。
data_write() {
  local tmp fn token
  [[ -f "$SMOKE_STATE" ]] || { echo "SMOKE_STATE 不是文件（$SMOKE_STATE），存不了标记"; return 1; }
  fn="copier-probe.txt"
  token="probe-$(tr -dc a-z0-9 </dev/urandom | head -c 12)-$(date +%s)"
  tmp="$(mktemp)"
  printf 'copyparty data probe %s\n' "$token" >"$tmp"
  if ! web_get "/$fn" -H 'replace: t' -T "$tmp" >/dev/null; then
    rm -f "$tmp"
    echo "PUT /$fn 失败"
    return 1
  fi
  rm -f "$tmp"
  printf '%s\n' "copyparty-data-probe $fn $token" >>"$SMOKE_STATE"
}

data_check() {
  local line fn token got
  line="$(grep '^copyparty-data-probe ' "$SMOKE_STATE" 2>/dev/null | tail -1)"
  [[ -n "$line" ]] || { echo "标记没写进 $SMOKE_STATE"; return 1; }
  fn="$(awk '{print $2}' <<<"$line")"
  token="$(awk '{print $3}' <<<"$line")"
  if ! got="$(web_get "/$fn")"; then
    echo "读不回 /$fn：升级/重装把文件弄丢了？"
    return 1
  fi
  [[ "$got" == "copyparty data probe $token"* ]] ||
    { echo "文件内容对不上（期望 token $token）：$(head -c 120 <<<"$got")"; return 1; }
}
