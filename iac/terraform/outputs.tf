output "api_endpoint"   { value = aws_apigatewayv2_api.http_api.api_endpoint }
output "opensearch_url" { value = aws_opensearch_domain.domain.endpoint }
output "s3_raw"         { value = aws_s3_bucket.raw.bucket }
output "s3_curated"     { value = aws_s3_bucket.curated.bucket }
output "athena_db"      { value = aws_athena_database.db.name }
