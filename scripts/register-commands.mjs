#!/usr/bin/env node
// /pal スラッシュコマンドをギルド (サーバー) に登録する。terraform apply 後に 1 回実行する。
// ギルドコマンドは即時反映される (グローバルコマンドは伝播に最大 1 時間かかるため使わない)。
//
// 使い方:
//   DISCORD_TOKEN=<Bot Token> DISCORD_APP_ID=<App ID> DISCORD_GUILD_ID=<Guild ID> \
//     node scripts/register-commands.mjs

const { DISCORD_TOKEN, DISCORD_APP_ID, DISCORD_GUILD_ID } = process.env;

if (!DISCORD_TOKEN || !DISCORD_APP_ID || !DISCORD_GUILD_ID) {
  console.error(
    "環境変数が不足しています: DISCORD_TOKEN, DISCORD_APP_ID, DISCORD_GUILD_ID",
  );
  process.exit(1);
}

const SUB = (name, description) => ({ type: 1, name, description });

const commands = [
  {
    name: "pal",
    description: "パルワールドサーバーの管理",
    options: [
      SUB("start", "サーバーを起動する"),
      SUB("stop", "セーブしてサーバーを停止する"),
      SUB("restart", "セーブしてサーバーを再起動する"),
      SUB("status", "サーバーの状態と接続人数を表示する"),
      SUB("players", "接続中のプレイヤー一覧を表示する"),
      SUB("backup", "今すぐバックアップを実行する"),
      SUB("cost", "今月かかっている AWS 料金を表示する"),
    ],
  },
];

const res = await fetch(
  `https://discord.com/api/v10/applications/${DISCORD_APP_ID}/guilds/${DISCORD_GUILD_ID}/commands`,
  {
    method: "PUT", // PUT はギルドの全コマンドを置き換える (冪等)
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bot ${DISCORD_TOKEN}`,
    },
    body: JSON.stringify(commands),
  },
);

if (!res.ok) {
  console.error(`登録失敗: ${res.status} ${res.statusText}`);
  console.error(await res.text());
  process.exit(1);
}

const body = await res.json();
console.log(`登録完了: ${body.map((c) => "/" + c.name).join(", ")}`);
console.log("Discord で /pal と入力して候補が出れば成功です。");
