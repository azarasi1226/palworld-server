// Discord Bot 本体。3 つの顔を持つ:
//   1. Function URL: Discord からのインタラクション受信 (署名検証 → deferred 応答)
//   2. ワーカー: 自分自身への非同期 invoke で重い処理を実行し、応答を差し替える
//   3. EventBridge: スポット中断 / 起動失敗イベントの通知 (B 系統)
//
// 依存ゼロ: 署名検証は node:crypto、AWS は Lambda ランタイム同梱の SDK v3。
import crypto from "node:crypto";
import {
  AutoScalingClient,
  DescribeAutoScalingGroupsCommand,
  SetDesiredCapacityCommand,
} from "@aws-sdk/client-auto-scaling";
import {
  EC2Client,
  DescribeInstancesCommand,
  DescribeSpotPriceHistoryCommand,
} from "@aws-sdk/client-ec2";
import { S3Client, GetObjectCommand, PutObjectCommand } from "@aws-sdk/client-s3";
import {
  SSMClient,
  GetParameterCommand,
  SendCommandCommand,
  GetCommandInvocationCommand,
} from "@aws-sdk/client-ssm";
import { LambdaClient, InvokeCommand } from "@aws-sdk/client-lambda";

const {
  DISCORD_APP_ID,
  DISCORD_PUBLIC_KEY,
  DISCORD_ROLE_ID,
  ASG_NAME,
  BUCKET,
  WEBHOOK_PARAM,
  SERVER_FQDN,
  GAME_PORT,
  SELF_FUNCTION_NAME,
  STATUS_STALE_SECONDS,
} = process.env;

const asg = new AutoScalingClient({});
const ec2 = new EC2Client({});
const s3 = new S3Client({});
const ssm = new SSMClient({});
const lambda = new LambdaClient({});

// ---------------------------------------------------------------------------
// エントリポイント
// ---------------------------------------------------------------------------

export const handler = async (event) => {
  if (event.worker) return await runWorker(event);
  if (event.source === "aws.ec2" || event.source === "aws.autoscaling") {
    return await handleAwsEvent(event);
  }
  return await handleFunctionUrl(event);
};

// ---------------------------------------------------------------------------
// 1. Function URL: 署名検証と即時応答 (3 秒制限)
// ---------------------------------------------------------------------------

async function handleFunctionUrl(event) {
  const body = event.isBase64Encoded
    ? Buffer.from(event.body, "base64").toString("utf-8")
    : event.body;
  const sig = event.headers?.["x-signature-ed25519"];
  const ts = event.headers?.["x-signature-timestamp"];

  if (!sig || !ts || !verifySignature(body, sig, ts)) {
    return { statusCode: 401, body: "invalid request signature" };
  }

  const interaction = JSON.parse(body);

  if (interaction.type === 1) return json({ type: 1 }); // PING -> PONG

  if (interaction.type === 2) {
    const sub = interaction.data?.options?.[0]?.name ?? "status";

    // 権限: ロール指定がある場合、閲覧系以外はロール保持者のみ。
    const readonly = sub === "status" || sub === "players";
    if (DISCORD_ROLE_ID && !readonly) {
      const roles = interaction.member?.roles ?? [];
      if (!roles.includes(DISCORD_ROLE_ID)) {
        return json(reply("⛔ このコマンドを実行する権限がありません。"));
      }
    }

    // 重い処理はワーカー (自分自身への非同期 invoke) に委譲し、deferred を即返す。
    // 注意: invoke の完了を await してから return する (return 後は freeze されるため)。
    await lambda.send(
      new InvokeCommand({
        FunctionName: SELF_FUNCTION_NAME,
        InvocationType: "Event",
        Payload: JSON.stringify({ worker: true, action: sub, token: interaction.token }),
      }),
    );
    return json({ type: 5 }); // DEFERRED_CHANNEL_MESSAGE_WITH_SOURCE
  }

  return { statusCode: 400, body: "unsupported interaction type" };
}

function verifySignature(body, sig, ts) {
  try {
    // hex 公開鍵 → DER (SPKI)。Ed25519 の SPKI プレフィックスは固定 12 バイト。
    const spki = Buffer.concat([
      Buffer.from("302a300506032b6570032100", "hex"),
      Buffer.from(DISCORD_PUBLIC_KEY, "hex"),
    ]);
    const key = crypto.createPublicKey({ key: spki, format: "der", type: "spki" });
    return crypto.verify(null, Buffer.from(ts + body), key, Buffer.from(sig, "hex"));
  } catch {
    return false;
  }
}

const json = (obj) => ({
  statusCode: 200,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify(obj),
});
const reply = (content) => ({ type: 4, data: { content } });

// ---------------------------------------------------------------------------
// 2. ワーカー: 実処理 → @original を PATCH
// ---------------------------------------------------------------------------

async function runWorker({ action, token }) {
  let content;
  try {
    switch (action) {
      case "start":   content = await doStart(); break;
      case "stop":    content = await doStop(); break;
      case "restart": content = await doRestart(); break;
      case "status":  content = await doStatus(); break;
      case "players": content = await doPlayers(); break;
      case "backup":  content = await doBackup(); break;
      case "cost":    content = await doCost(); break;
      default:        content = `未知のコマンドです: ${action}`;
    }
  } catch (e) {
    console.error("worker error", e);
    content = `⚠️ エラーが発生しました: ${e.name}: ${e.message}`;
  }

  // PATCH の失敗でハンドラを異常終了させない。非同期 invoke はエラー時に
  // Lambda が自動リトライするため、throw すると restart 等の実処理が二重実行される。
  try {
    await fetch(
      `https://discord.com/api/v10/webhooks/${DISCORD_APP_ID}/${token}/messages/@original`,
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ content }),
      },
    );
  } catch (e) {
    console.error("failed to edit deferred response", e);
  }
}

async function getAsg() {
  const res = await asg.send(
    new DescribeAutoScalingGroupsCommand({ AutoScalingGroupNames: [ASG_NAME] }),
  );
  return res.AutoScalingGroups[0];
}

async function doStart() {
  const g = await getAsg();

  // 停止処理中の起動は世代逆転のもと (DESIGN.md 排他制御)。S3 ロックが最終防衛だが
  // ここで拒否して待たせるほうが体験がよい。
  if (g.Instances.some((i) => i.LifecycleState.startsWith("Terminating"))) {
    return "⏳ 停止処理中です (セーブ中)。30 秒ほど待ってからもう一度実行してください。";
  }
  if (g.DesiredCapacity >= 1) {
    return `ℹ️ すでに起動済み、または起動中です。\n接続先: **${SERVER_FQDN}:${GAME_PORT}**\n状態は \`/pal status\` で確認できます。`;
  }

  await asg.send(
    new SetDesiredCapacityCommand({
      AutoScalingGroupName: ASG_NAME,
      DesiredCapacity: 1,
      HonorCooldown: false,
    }),
  );
  return `🚀 起動を受け付けました。約 2〜3 分後 (初回は 6〜8 分後) に準備完了の通知が届きます。\n接続先: **${SERVER_FQDN}:${GAME_PORT}**`;
}

async function doStop() {
  const g = await getAsg();
  if (g.DesiredCapacity === 0 && g.Instances.length === 0) {
    return "ℹ️ サーバーはすでに停止しています。";
  }
  await asg.send(
    new SetDesiredCapacityCommand({
      AutoScalingGroupName: ASG_NAME,
      DesiredCapacity: 0,
      HonorCooldown: false,
    }),
  );
  return "🛑 停止を受け付けました。セーブ完了後に通知が届きます (1〜2 分)。";
}

async function doRestart() {
  // 停止済みなら単に起動する。doStop() の戻り文言で判定すると
  // 文言を変えた瞬間に壊れるため、状態そのものを見る。
  const before = await getAsg();
  if (before.DesiredCapacity === 0 && before.Instances.length === 0) {
    return await doStart();
  }
  await doStop();
  // 旧インスタンスの消滅を待ってから desired=1 に戻す。
  // 待ちきれなくても S3 ロックが正しさを守るので、起動要求だけ出して返す。
  // 注意: ここで待たずに desired=1 に戻すと、停止側が原因判定に使う desired が
  // 1 になり「ユーザー操作」ではなく「AWS 都合の置き換え」と誤報する。
  for (let i = 0; i < 20; i++) {
    await sleep(5000);
    const g = await getAsg();
    if (g.Instances.length === 0) break;
  }
  await asg.send(
    new SetDesiredCapacityCommand({
      AutoScalingGroupName: ASG_NAME,
      DesiredCapacity: 1,
      HonorCooldown: false,
    }),
  );
  return "🔄 再起動中です。セーブ → 停止 → 起動の順に進み、準備完了の通知が届きます。";
}

async function fetchStatusJson() {
  try {
    const res = await s3.send(new GetObjectCommand({ Bucket: BUCKET, Key: "status.json" }));
    return JSON.parse(await res.Body.transformToString());
  } catch {
    return null;
  }
}

async function doStatus() {
  const g = await getAsg();
  const st = await fetchStatusJson();

  const running = g.Instances.filter((i) => i.LifecycleState === "InService").length;
  const lines = [];

  if (g.DesiredCapacity === 0 && g.Instances.length === 0) {
    lines.push("💤 **停止中** — `/pal start` で起動できます。");
  } else if (running === 0) {
    lines.push("🚀 **起動処理中** — 準備完了の通知をお待ちください。");
  } else {
    lines.push(`🎮 **稼働中** — 接続先: **${SERVER_FQDN}:${GAME_PORT}**`);
  }

  if (st) {
    const age = Math.floor(Date.now() / 1000) - (st.updated_epoch ?? 0);
    if (age > Number(STATUS_STALE_SECONDS)) {
      // 突然死したインスタンスの残骸を信用しない (DESIGN.md 鮮度チェック)。
      lines.push(`⚠️ 詳細情報は ${Math.floor(age / 60)} 分前のもので古い可能性があります。`);
    } else if (st.state === "running") {
      lines.push(`接続人数: ${st.player_count} 人`);
      if (st.players?.length) lines.push(`プレイヤー: ${st.players.join(", ")}`);
      lines.push(`インスタンス: ${st.instance_type}`);
      if (st.boot_epoch) {
        const up = Math.floor((Date.now() / 1000 - st.boot_epoch) / 60);
        lines.push(`稼働時間: ${Math.floor(up / 60)} 時間 ${up % 60} 分`);
      }
      if (st.last_backup_epoch) {
        const b = Math.floor((Date.now() / 1000 - st.last_backup_epoch) / 60);
        lines.push(`最終バックアップ: ${b} 分前`);
      }

      // リソース使用状況。メモリとディスクは CloudWatch では取得できないため
      // インスタンス側が status.json に載せている (エージェント不要 = 追加コスト無し)。
      const res = [];
      if (st.mem_total_mb) {
        const pct = Math.round((st.mem_used_mb / st.mem_total_mb) * 100);
        const gb = (mb) => (mb / 1024).toFixed(1);
        let mem = `メモリ: ${gb(st.mem_used_mb)} / ${gb(st.mem_total_mb)} GB (${pct}%)`;
        if (pct >= 90) mem = `⚠️ ${mem} — 逼迫しています`;
        res.push(mem);
        // Linux は空きがあってもアイドルページを退避するため数百 MB は正常。
        // 1GB を超えたら物理メモリ不足を疑うレベル。
        if (st.swap_used_mb > 1024) {
          res.push(`⚠️ スワップ ${gb(st.swap_used_mb)} GB 使用 — メモリ不足の兆候です`);
        }
      }
      if (st.cpu_cores) {
        res.push(`CPU: ${st.cpu_percent}% (${st.cpu_cores} コア / load ${st.load1})`);
      }
      if (st.disk_total_gb) {
        const pct = Math.round((st.disk_used_gb / st.disk_total_gb) * 100);
        let disk = `ディスク: ${st.disk_used_gb} / ${st.disk_total_gb} GB (${pct}%)`;
        if (pct >= 85) disk = `⚠️ ${disk} — 空き容量が不足しています`;
        res.push(disk);
      }
      if (res.length) lines.push("", ...res);
    }
  }
  return lines.join("\n");
}

async function doPlayers() {
  const st = await fetchStatusJson();
  if (!st || st.state !== "running") return "💤 サーバーは稼働していません。";
  const age = Math.floor(Date.now() / 1000) - (st.updated_epoch ?? 0);
  if (age > Number(STATUS_STALE_SECONDS)) return "⚠️ 情報が古いため取得できません。";
  if (!st.players?.length) return "現在接続しているプレイヤーはいません。";
  return `接続中 (${st.player_count} 人): ${st.players.join(", ")}`;
}

async function doBackup() {
  const iid = await findRunningInstance();
  if (!iid) return "💤 サーバーが稼働していないためバックアップできません。";

  const cmd = await ssm.send(
    new SendCommandCommand({
      DocumentName: "AWS-RunShellScript",
      InstanceIds: [iid],
      Parameters: { commands: ["/opt/palworld/bin/pal-backup.sh"], executionTimeout: ["120"] },
    }),
  );

  const commandId = cmd.Command.CommandId;
  for (let i = 0; i < 18; i++) {
    await sleep(5000);
    try {
      const inv = await ssm.send(
        new GetCommandInvocationCommand({ CommandId: commandId, InstanceId: iid }),
      );
      if (inv.Status === "Success") return "✅ バックアップが完了しました。";
      if (["Failed", "Cancelled", "TimedOut"].includes(inv.Status)) {
        return `🚨 バックアップに失敗しました (${inv.Status})。整合性チェックに落ちた場合は通知チャンネルに詳細があります。`;
      }
    } catch {
      // InvocationDoesNotExist: 反映待ち
    }
  }
  return "⚠️ バックアップの完了を確認できませんでした (タイムアウト)。";
}

async function findRunningInstance() {
  const g = await getAsg();
  const inst = g.Instances.find((i) => i.LifecycleState === "InService");
  return inst?.InstanceId ?? null;
}

// ---------------------------------------------------------------------------
// コストレポート
//   [A] 今月の実績 (Cost Explorer) ... 正確だが反映が半日〜1日遅れる
//   [B] 今この瞬間 (EC2 API)       ... 遅延なし。時間単価と当セッション分
// ---------------------------------------------------------------------------

const COST_CACHE_KEY = "cost-cache.json";
const COST_CACHE_TTL = 3600; // 秒

// --- 為替 -------------------------------------------------------------------
// 外部 API (ECB ベース・キー不要) から取得するが、落ちても壊れないよう
// フォールバック定数を持つ。キャッシュは warm コンテナ内のメモリのみ =
// S3 も IAM も増やさない。ECB のレートは 1 日 1 回更新なので TTL は 24h。
const FX_URL = "https://api.frankfurter.dev/v1/latest?from=USD&to=JPY";
const FX_FALLBACK = 163; // 取得失敗時の概算値 (2026-07 時点の目安)
const FX_TTL = 86400;
let fxCache = { rate: null, epoch: 0 };

async function getUsdJpy() {
  const now = Math.floor(Date.now() / 1000);
  if (fxCache.rate && now - fxCache.epoch < FX_TTL) {
    return { rate: fxCache.rate, exact: true };
  }
  try {
    const res = await fetch(FX_URL, { signal: AbortSignal.timeout(3000) });
    const rate = (await res.json())?.rates?.JPY;
    if (typeof rate === "number" && rate > 0) {
      fxCache = { rate, epoch: now };
      return { rate, exact: true };
    }
  } catch (e) {
    console.error("fx fetch failed", e);
  }
  return { rate: FX_FALLBACK, exact: false }; // 概算表示にフォールバック
}

const yen = (usd, rate) => "¥" + Math.round(usd * rate).toLocaleString("ja-JP");

async function doCost() {
  const out = ["📊 **コストレポート**", ""];
  const fx = await getUsdJpy();

  // --- [A] 実績 -------------------------------------------------------------
  // Cost Explorer は 1 リクエスト $0.01 の有料 API。誰が何回叩いても
  // 1 時間に 1 回しか実際には課金されないよう S3 にキャッシュする。
  let ce = null;
  let ageMin = 0;
  try {
    const r = await s3.send(new GetObjectCommand({ Bucket: BUCKET, Key: COST_CACHE_KEY }));
    const cached = JSON.parse(await r.Body.transformToString());
    const age = Math.floor(Date.now() / 1000) - cached.fetched_epoch;
    if (age < COST_CACHE_TTL) {
      ce = cached;
      ageMin = Math.floor(age / 60);
    }
  } catch {
    // キャッシュ無し
  }

  if (!ce) {
    ce = await fetchCostExplorer();
    if (ce) {
      await s3.send(
        new PutObjectCommand({
          Bucket: BUCKET,
          Key: COST_CACHE_KEY,
          Body: JSON.stringify(ce),
          ContentType: "application/json",
        }),
      );
    }
  }

  if (ce) {
    const total = Object.values(ce.by_service).reduce((a, b) => a + b, 0);
    const freshness = ageMin > 0 ? `${ageMin} 分前の取得` : "たった今取得";
    out.push(`**今月の実績** (${ce.month_start} 〜 / ${freshness})`);
    out.push("```");
    for (const [name, amt] of Object.entries(ce.by_service).sort((a, b) => b[1] - a[1])) {
      if (amt < 0.005) continue;
      out.push(`  ${shortServiceName(name)}: ${yen(amt, fx.rate)}`);
    }
    out.push("  ─────────────────");
    out.push(`  合計: ${yen(total, fx.rate)}  ($${total.toFixed(2)})`);
    out.push("```");
  } else {
    out.push("**今月の実績**: 取得できませんでした");
    out.push("（Cost Explorer が未有効か、Lambda にモジュールが同梱されていません。README のトラブルシュート参照）");
  }

  // --- [B] このセッション ---------------------------------------------------
  // 上の「今月の実績」と対になる。Cost Explorer の遅延を受けないので、
  // 今まさに遊んでいるぶんがいくらかを即時に出せる。
  out.push("");
  const g = await getAsg();
  const inst = g.Instances.find((i) => i.LifecycleState === "InService");

  if (!inst) {
    // 停止中は「セッション」が存在しないので見出しを出し分ける
    out.push("**現在の状態**");
    out.push("💤 停止中 — EC2 の課金は発生していません");
    out.push("（停止中の負担は S3 と Route 53 のみ = 月 $1 未満）");
  } else {
    out.push("**このセッション**");
    const d = await ec2.send(new DescribeInstancesCommand({ InstanceIds: [inst.InstanceId] }));
    const i = d.Reservations[0].Instances[0];

    let spot = 0;
    try {
      const sp = await ec2.send(
        new DescribeSpotPriceHistoryCommand({
          InstanceTypes: [i.InstanceType],
          ProductDescriptions: ["Linux/UNIX"],
          AvailabilityZone: i.Placement.AvailabilityZone,
          MaxResults: 1,
        }),
      );
      spot = parseFloat(sp.SpotPriceHistory?.[0]?.SpotPrice ?? "0");
    } catch {
      // 価格が引けなくても稼働情報は出す
    }

    const ebsIp = (0.096 * 40) / 730 + 0.005; // gp3 40GB の時間割 + パブリック IPv4
    const hourly = spot + ebsIp;
    const upH = (Date.now() - new Date(i.LaunchTime).getTime()) / 3600000;

    out.push(`🎮 稼働中: ${i.InstanceType} (${i.Placement.AvailabilityZone})`);
    out.push("```");
    out.push(`  スポット価格   ${yen(spot, fx.rate)}/時`);
    out.push(`  EBS + IPv4     ${yen(ebsIp, fx.rate)}/時`);
    out.push(`  稼働時間       ${Math.floor(upH)}時間${Math.floor((upH % 1) * 60)}分`);
    out.push("  ─────────────────");
    // 合計は時間単価ではなく「この起動で実際にいくら使ったか」。
    // 単価は上の内訳で示しているので、ここで繰り返すとノイズになる。
    out.push(`  合計           ${yen(hourly * upH, fx.rate)}`);
    out.push("```");
  }

  // --- 注記はまとめて末尾に置く（本文の途中に挟むと読みが途切れるため）---
  // 実装の都合（Cost Explorer 由来など）は書かない。利用者に伝わらないうえ、
  // 知っても行動が変わらないため。「反映が遅れる」ことだけ伝われば十分。
  out.push("");
  if (ce) out.push("_※ 今月の実績は反映が半日〜1 日遅れます_");
  out.push(
    fx.exact
      ? `_※ 参考為替: $1 = ¥${fx.rate.toFixed(1)}_`
      : `_※ 参考為替: $1 = ¥${fx.rate}（レート取得に失敗したため概算）_`,
  );

  return out.join("\n");
}

async function fetchCostExplorer() {
  // Cost Explorer クライアントがランタイムに同梱されているか保証がないため
  // 動的 import する。読めなくても他のコマンドは壊さない。
  let mod;
  try {
    mod = await import("@aws-sdk/client-cost-explorer");
  } catch (e) {
    console.error("cost-explorer module unavailable", e);
    return null;
  }

  try {
    const client = new mod.CostExplorerClient({ region: "us-east-1" }); // CE はグローバル
    const now = new Date();
    const start = `${now.getUTCFullYear()}-${String(now.getUTCMonth() + 1).padStart(2, "0")}-01`;
    const end = new Date(Date.now() + 86400000).toISOString().slice(0, 10);

    // 日別の推移は Discord では出さないので MONTHLY で足りる
    // (API コールも 1 回に抑えられる)。日別グラフが要るときは scripts/cost.sh を使う。
    const res = await client.send(
      new mod.GetCostAndUsageCommand({
        TimePeriod: { Start: start, End: end },
        Granularity: "MONTHLY",
        Metrics: ["UnblendedCost"],
        GroupBy: [{ Type: "DIMENSION", Key: "SERVICE" }],
      }),
    );

    const byService = {};
    for (const p of res.ResultsByTime ?? []) {
      for (const grp of p.Groups ?? []) {
        byService[grp.Keys[0]] =
          (byService[grp.Keys[0]] ?? 0) + parseFloat(grp.Metrics.UnblendedCost.Amount);
      }
    }
    return {
      fetched_epoch: Math.floor(Date.now() / 1000),
      month_start: start,
      by_service: byService,
    };
  } catch (e) {
    console.error("cost explorer query failed", e);
    return null;
  }
}

function shortServiceName(name) {
  return name
    .replace("Amazon Elastic Compute Cloud - Compute", "EC2 (インスタンス)")
    .replace("EC2 - Other", "EC2 (EBS/IP など)")
    .replace("Amazon Simple Storage Service", "S3")
    .replace("Amazon Route 53", "Route 53")
    .replace("AWS Cost Explorer", "Cost Explorer API")
    .replace("AWS Key Management Service", "KMS")
    .replace("AWS Systems Manager", "SSM");
}

// ---------------------------------------------------------------------------
// 3. EventBridge: 通知 B 系統 (インスタンスの生死に依存しない)
// ---------------------------------------------------------------------------

let lastLaunchFailureNotify = 0; // warm コンテナ内のベストエフォート抑制

async function handleAwsEvent(event) {
  if (event["detail-type"] === "EC2 Spot Instance Interruption Warning") {
    // アカウント内の他のスポットにも反応するため、自分の ASG のインスタンスか確認する。
    const iid = event.detail?.["instance-id"];
    if (!(await isOurInstance(iid))) return;
    await sendWebhook(
      "⚠️ スポット中断の通知を受信しました (AWS 側検知)",
      `インスタンス ${iid} が約 2 分後に回収されます。\nサーバー側の緊急セーブが並行して動いています。セーブ完了通知が続かない場合、直前の定期バックアップ (最大 5 分前) まで巻き戻る可能性があります。`,
      0xffcc4d,
    );
    return;
  }

  if (event["detail-type"] === "EC2 Instance Launch Unsuccessful") {
    const now = Date.now();
    if (now - lastLaunchFailureNotify < 10 * 60 * 1000) return; // 連投抑制
    lastLaunchFailureNotify = now;
    await sendWebhook(
      "❌ サーバーの起動に失敗しています",
      `スポットキャパシティ不足の可能性があります。自動でリトライが続きます。\n復旧しない場合は時間をおいて \`/pal stop\` → \`/pal start\` を試すか、README のオンデマンド切替手順を参照してください。\n詳細: ${event.detail?.StatusMessage ?? "不明"}`,
      0xed4245,
    );
  }
}

async function isOurInstance(instanceId) {
  if (!instanceId) return false;
  try {
    const res = await ec2.send(new DescribeInstancesCommand({ InstanceIds: [instanceId] }));
    const tags = res.Reservations?.[0]?.Instances?.[0]?.Tags ?? [];
    return tags.some(
      (t) => t.Key === "aws:autoscaling:groupName" && t.Value === ASG_NAME,
    );
  } catch {
    return false;
  }
}

let cachedWebhook = null;

async function sendWebhook(title, description, color) {
  if (!cachedWebhook) {
    const p = await ssm.send(
      new GetParameterCommand({ Name: WEBHOOK_PARAM, WithDecryption: true }),
    );
    cachedWebhook = p.Parameter.Value;
  }
  await fetch(cachedWebhook, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ embeds: [{ title, description, color }] }),
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
