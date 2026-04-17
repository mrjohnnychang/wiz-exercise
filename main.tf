resource "aws_s3_bucket" "vulnerable_bucket" {
  bucket = "wiz-demo-vulnerable-bucket"
  acl    = "public-read"
}
