output "bucket_name" {
  value = aws_s3_bucket.langfuse.bucket
}

output "bucket_arn" {
  value = aws_s3_bucket.langfuse.arn
}
