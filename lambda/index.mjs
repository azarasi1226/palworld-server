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
import { EC2Client, DescribeInstancesCommand } from "@aws-sdk/client-ec2";
import { S3Client, GetObjectCommand } from "@aws-sdk/client-s3";
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
      default:        content = `未知のコマンドです: ${action}`;
    }
  } catch (e) {
    console.error("worker error", e);
    content = `⚠️ エラーが発生しました: ${e.name}: ${e.message}`;
  }

  await fetch(
    `https://discord.com/api/v10/webhooks/${DISCORD_APP_ID}/${token}/messages/@original`,
    {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ content }),
    },
  );
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
  const stopMsg = await doStop();
  if (stopMsg.startsWith("ℹ️")) {
    // 停止済みならそのまま起動へ。
    return await doStart();
  }
  // 旧インスタンスの消滅を待ってから desired=1 に戻す (最大 ~100 秒)。
  // 待ちきれなくても S3 ロックが正しさを守るので、起動要求だけ出して返す。
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
