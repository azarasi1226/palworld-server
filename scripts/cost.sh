#!/usr/bin/env bash
# 今かかっているコストを表示する。
#
#   AWS_PROFILE=prod_admin bash scripts/cost.sh
#
# 2 つの視点を並べて出す:
#   [A] 実績 (Cost Explorer) ... 正確だが反映が半日〜1日遅れる
#   [B] このセッション (EC2 API) ... 遅延ゼロ。今の起動でここまでいくら使ったか
#
# 注意: Cost Explorer API は 1 リクエスト $0.01 の有料 API。
# 1 回の実行につき 1 コールに抑えてある (DAILY 取得から合計・内訳・推移を計算)。
set -euo pipefail

REGION="${PAL_REGION:-ap-northeast-1}"
PROJECT="${PAL_PROJECT:-palworld}"

MONTH_START=$(date -u +%Y-%m-01)
TOMORROW=$(date -u -d "+1 day" +%Y-%m-%d)

# 為替 (ECB ベース・APIキー不要)。取れなければ概算値にフォールバックする。
FX=$(curl -s --max-time 3 "https://api.frankfurter.dev/v1/latest?from=USD&to=JPY" 2>/dev/null \
  | python -c "import json,sys; print(json.load(sys.stdin)['rates']['JPY'])" 2>/dev/null || true)
if [ -z "$FX" ]; then
  FX=163
  FX_NOTE=" (レート取得に失敗したため概算)"
else
  FX_NOTE=""
fi
export FX

echo "==================================================================="
echo " Palworld サーバー コストレポート  ($(date '+%Y-%m-%d %H:%M'))"
echo "==================================================================="
echo
echo "[A] 今月の実績  ($MONTH_START 〜)"
echo "-------------------------------------------------------------------"

# Cost Explorer は us-east-1 のグローバルエンドポイント。
if ! CE_JSON=$(aws ce get-cost-and-usage \
  --time-period "Start=$MONTH_START,End=$TOMORROW" \
  --granularity DAILY \
  --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --region us-east-1 --output json 2>&1); then
  echo "  取得できませんでした:"
  echo "$CE_JSON" | head -3 | sed 's/^/    /'
  echo "  (初回は請求コンソールで Cost Explorer の有効化が必要な場合があります)"
  CE_JSON=""
fi

if [ -n "$CE_JSON" ]; then
  echo "$CE_JSON" | python -c '
import json, sys, unicodedata
from collections import defaultdict

import os
FX = float(os.environ["FX"])

def pad(s, width):
    # 全角文字は 2 桁ぶんの幅を取るので、表示幅で揃える
    w = sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)
    return s + " " * max(0, width - w)

def yen(usd):
    return f"¥{round(usd * FX):,}"

data = json.load(sys.stdin)
by_service, by_day = defaultdict(float), []

for period in data["ResultsByTime"]:
    day_total = 0.0
    for g in period["Groups"]:
        amt = float(g["Metrics"]["UnblendedCost"]["Amount"])
        by_service[g["Keys"][0]] += amt
        day_total += amt
    by_day.append((period["TimePeriod"]["Start"], day_total))

total = sum(by_service.values())
print("  サービス別:")
for name, amt in sorted(by_service.items(), key=lambda x: -x[1]):
    if amt < 0.005:
        continue
    short = name.replace("Amazon Elastic Compute Cloud - Compute", "EC2 (インスタンス)")
    short = short.replace("EC2 - Other", "EC2 (EBS/IP など)").replace("Amazon Simple Storage Service", "S3")
    short = short.replace("Amazon Route 53", "Route 53").replace("AWS Cost Explorer", "Cost Explorer API")
    print(f"    {pad(short, 30)} {yen(amt):>9}")
print(f"    {'-' * 30} {'-' * 9}")
print(f"    {pad('合計', 30)} {yen(total):>9}   (${total:.2f})")

recent = [d for d in by_day if d[1] >= 0.005][-7:]
if recent:
    print()
    print("  直近の日別:")
    peak = max(d[1] for d in recent) or 1
    for day, amt in recent:
        print(f"    {day}  {yen(amt):>7}  {'#' * max(1, int(amt / peak * 24))}")
'
fi

echo
echo "[B] このセッション"
echo "-------------------------------------------------------------------"

IID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$PROJECT-server" --region "$REGION" \
  --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].InstanceId | [0]" \
  --output text 2>/dev/null || echo "None")

if [ -z "$IID" ] || [ "$IID" = "None" ]; then
  echo "  💤 サーバーは停止中 — EC2 の課金は発生していません"
  echo "     (停止中の負担は S3 の保管料と Route 53 のみ = 月 \$1 未満)"
else
  read -r ITYPE AZ LAUNCH <<< "$(aws ec2 describe-instances --instance-ids "$IID" --region "$REGION" \
    --query "Reservations[0].Instances[0].[InstanceType,Placement.AvailabilityZone,LaunchTime]" --output text)"

  SPOT=$(aws ec2 describe-spot-price-history --instance-types "$ITYPE" \
    --product-descriptions "Linux/UNIX" --availability-zone "$AZ" \
    --max-items 1 --region "$REGION" --query "SpotPriceHistory[0].SpotPrice" --output text 2>/dev/null || echo "0")

  echo "  🎮 稼働中: $ITYPE ($AZ)"
  UP_SEC=$(( $(date -u +%s) - $(date -u -d "$LAUNCH" +%s) ))
  SPOT="$SPOT" UP_SEC="$UP_SEC" python -c '
import os
spot = float(os.environ["SPOT"] or 0)
up_h = int(os.environ["UP_SEC"]) / 3600
FX = float(os.environ["FX"])

def yen(usd):
    return f"¥{round(usd * FX):,}"

ebs = 0.096 * 40 / 730   # gp3 40GB の時間割
ipv4 = 0.005             # パブリック IPv4
rate = spot + ebs + ipv4

def pad(s, width):
    import unicodedata
    w = sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)
    return s + " " * max(0, width - w)

print(f"    {pad('スポット価格', 30)} {yen(spot):>9}/時")
print(f"    {pad('EBS + IPv4', 30)} {yen(ebs + ipv4):>9}/時")
print(f"    {pad('稼働時間', 30)} {int(up_h)}時間{int(up_h % 1 * 60)}分")
print(f"    {'-' * 30} {'-' * 9}")
# 合計は時間単価ではなく「この起動で実際にいくら使ったか」。
# 単価は上の内訳で示しているので、ここで繰り返すとノイズになる。
print(f"    {pad('合計', 30)} {yen(rate * up_h):>9}")
'
fi

# 注記はまとめて末尾に置く (本文の途中に挟むと読みが途切れるため)
echo
echo "-------------------------------------------------------------------"
echo "※ [A] は反映が半日〜1 日遅れます（[B] は遅延なし）"
echo "※ この実行で Cost Explorer API を 1 回使用 (\$0.01)"
echo "※ 参考為替: \$1 = ¥${FX}${FX_NOTE}"
