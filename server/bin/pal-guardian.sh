#!/usr/bin/env bash
# ★中断検知の心臓部 (DESIGN.md 層 2)。
# 「終了させられそうだ」という兆候を 2 系統で見張り、掴んだ瞬間にセーブへ入る。
#
#   系統 1: スポット中断   2 分後に強制終了するという AWS の確定通知。IMDS に現れる
#           猶予 約 2 分   → 5 秒ごとに確認（1 秒でも早く気づきたい）
#
#   系統 2: ASG の終了指示 台数調整・回収の予兆による置き換え。ASG の API に聞くと分かる
#           猶予 300 秒    → 15 秒ごとに確認（余裕があるので API を叩きすぎない）
#
# 監視間隔が違うのは猶予の差がそのまま理由。ループ自体は短いほう (5 秒) に
# 合わせ、系統 2 は 3 周に 1 回だけ実行することで 15 秒間隔を作っている。
#
# どちらもプッシュ通知ではなく自分から見に行く方式 (ポーリング)。
# EventBridge 等のプッシュは EC2 内のシェルに直接届かず部品が増えるうえ、
# 配送失敗もありうる。自分で見に行けば取りこぼさない。
#
# なお中断の予兆 (リバランス推奨) は自前で監視しない。ASG の CapacityRebalance
# が先回りで置換を始め、旧インスタンスの終了は系統 2 を通るため保護される。
source /opt/palworld/lib/common.sh

IID=$(instance_id)

POLL_SEC=5           # ループ 1 周の長さ = 系統 1 の確認間隔
ASG_CHECK_EVERY=3    # 系統 2 は 3 周に 1 回 → 5 × 3 = 15 秒間隔
tick=0

log "guardian started (instance=$IID)"

while true; do
  # 停止完了後は Terminating:Wait のフック解放だけが残タスク。
  # exit せずループを続けるのは、その解放役が guardian 自身だから。
  if [ ! -f "$STATE_DIR/stopped" ]; then
    # --- 系統 1: スポット中断を確認 (毎周 = 5 秒ごと) -----------------------
    # 中断が決まると IMDS のこのパスに「いつ終了するか」が現れる。
    # 平常時は 404 なので imds_get が失敗し、この if には入らない。
    if imds_get "meta-data/spot/instance-action" >/dev/null; then
      log "SIGNAL: spot interruption notice"
      /opt/palworld/bin/pal-graceful-stop.sh spot || true
    fi
  fi

  # --- 系統 2: ASG の終了指示を確認 (3 周に 1 回 = 15 秒ごと) --------------
  # 「自分は今 ASG から見てどういう状態か」を聞く。Terminating:Wait なら
  # ライフサイクルフックで終了が保留されている = セーブの猶予がある状態。
  tick=$(( (tick + 1) % ASG_CHECK_EVERY ))
  if [ "$tick" = "0" ]; then
    STATE=$($AWS autoscaling describe-auto-scaling-instances --instance-ids "$IID" \
      --query "AutoScalingInstances[0].LifecycleState" --output text 2>/dev/null || true)

    if [ "$STATE" = "Terminating:Wait" ]; then
      if [ -f "$STATE_DIR/stopped" ]; then
        # 停止処理は完了済み。残タスクはフック解放のみ。
        # 失敗したら exit せず次のループで再試行する (exit すると誰も解放できず
        # ASG がタイムアウトの 300 秒を待ってしまう)。
        log "already stopped; completing lifecycle hook"
        ASG_NAME=$($AWS autoscaling describe-auto-scaling-instances --instance-ids "$IID" \
          --query "AutoScalingInstances[0].AutoScalingGroupName" --output text 2>/dev/null || true)
        if [ -n "$ASG_NAME" ] && $AWS autoscaling complete-lifecycle-action \
          --auto-scaling-group-name "$ASG_NAME" \
          --lifecycle-hook-name "$PAL_PROJECT-save-before-terminate" \
          --instance-id "$IID" \
          --lifecycle-action-result CONTINUE 2>/dev/null; then
          log "lifecycle hook completed; guardian exiting"
          exit 0
        fi
        log "WARN: complete-lifecycle-action failed; will retry"
      else
        # graceful-stop がフック解放まで行う。失敗していても stopped フラグが
        # 立つので、次のループで上の解放リトライに合流する。
        log "SIGNAL: ASG lifecycle Terminating:Wait"
        /opt/palworld/bin/pal-graceful-stop.sh lifecycle || true
      fi
    fi
  fi

  sleep "$POLL_SEC"
done
