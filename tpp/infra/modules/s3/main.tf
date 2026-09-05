# Langfuse event / large object storage
resource "aws_s3_bucket" "langfuse" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_public_access_block" "langfuse" {
  bucket = aws_s3_bucket.langfuse.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "langfuse" {
  bucket = aws_s3_bucket.langfuse.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "langfuse" {
  bucket = aws_s3_bucket.langfuse.id

  rule {
    id     = "expire-old-events"
    status = "Enabled"

    filter {}

    expiration {
      days = var.expiration_days
    }
  }
}
