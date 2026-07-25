# ---------------------------------------------------------------------------
# セーブデータの「正」となるバケット。
# EC2 は使い捨てで、ワールドの唯一の永続化先はここ。
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name

  # セーブが入っているバケットを terraform destroy で消せてしまうと事故になる。
  # 本当に消したい場合は明示的にこのブロックを外すこと。
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# バージョニングが世代管理そのもの。
# saves/latest.tar.zst を毎回上書きしても、過去の中身はバージョンとして残る。
# 復元時のフォールバック (層 5) はこのバージョン履歴を辿る。
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket     = aws_s3_bucket.state.id
  depends_on = [aws_s3_bucket_versioning.state]

  # 過去バージョン (= 5 分ごとの上書きで積み上がる履歴) の保持期間。
  # 30 日にすると非現行バージョンだけで 160GB 級に膨らむため 48h に絞る。
  # 長期の世代管理は saves/archive/ (1 時間ごと・backup_retention_days 日) が担う。
  rule {
    id     = "expire-noncurrent-saves"
    status = "Enabled"

    filter {
      prefix = "saves/"
    }

    noncurrent_version_expiration {
      noncurrent_days           = 2
      newer_noncurrent_versions = 10 # 期間を過ぎても直近 10 世代は必ず残す
    }
  }

  # 明示的に作る世代アーカイブ。
  rule {
    id     = "expire-archives"
    status = "Enabled"

    filter {
      prefix = "saves/archive/"
    }

    expiration {
      days = var.backup_retention_days
    }
  }

  rule {
    id     = "expire-logs"
    status = "Enabled"

    filter {
      prefix = "logs/"
    }

    expiration {
      days = 14
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }

  # ゲーム本体キャッシュは常に 1 世代だけあればよい。
  rule {
    id     = "expire-gamecache-versions"
    status = "Enabled"

    filter {
      prefix = "gamecache/"
    }

    noncurrent_version_expiration {
      noncurrent_days = 3
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 3
    }
  }
}

# ---------------------------------------------------------------------------
# サーバー側スクリプトの配布
#   AMI に焼かず S3 に置く。スクリプトを直したら terraform apply して
#   サーバーを起動し直すだけで反映される。
# ---------------------------------------------------------------------------

locals {
  server_files = fileset("${path.module}/../server", "**/*")

  content_types = {
    sh      = "text/x-shellscript"
    py      = "text/x-python"
    service = "text/plain"
    timer   = "text/plain"
  }
}

resource "aws_s3_object" "server_script" {
  for_each = local.server_files

  bucket = aws_s3_bucket.state.id
  key    = "bootstrap/${each.value}"
  source = "${path.module}/../server/${each.value}"

  # 中身が変わったときだけ再アップロードされ、user_data 側の sync も差分だけになる。
  etag         = filemd5("${path.module}/../server/${each.value}")
  content_type = lookup(local.content_types, element(split(".", each.value), length(split(".", each.value)) - 1), "application/octet-stream")
}
