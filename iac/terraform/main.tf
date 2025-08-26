provider "aws" { region = var.region }

locals { tags = { Project=var.project_name, Env="poc", Owner="aerolimo" } }

resource "aws_s3_bucket" "raw"     { bucket = "${var.project_name}-raw"     tags = local.tags }
resource "aws_s3_bucket" "curated" { bucket = "${var.project_name}-curated" tags = local.tags }

data "aws_iam_policy_document" "lambda_assume" {
  statement { actions=["sts:AssumeRole"]; principals { type="Service" identifiers=["lambda.amazonaws.com"] } }
}
resource "aws_iam_role" "lambda_ingest_role" {
  name = "${var.project_name}-lambda-ingest-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags = local.tags
}
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role = aws_iam_role.lambda_ingest_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
resource "aws_iam_policy" "lambda_destinations" {
  name = "${var.project_name}-lambda-destinations"
  policy = jsonencode({
    Version="2012-10-17",
    Statement=[
      {Effect="Allow", Action=["s3:PutObject"], Resource=["${aws_s3_bucket.raw.arn}/*","${aws_s3_bucket.curated.arn}/*"]},
      {Effect="Allow", Action=["es:ESHttpPost","es:ESHttpPut"], Resource="*"}
    ]
  })
}
resource "aws_iam_role_policy_attachment" "lambda_destinations_attach" {
  role = aws_iam_role.lambda_ingest_role.name
  policy_arn = aws_iam_policy.lambda_destinations.arn
}

data "archive_file" "ingest_zip" {
  type="zip"
  source_dir  = "${path.module}/../../lambda/ingest"
  output_path = "${path.module}/../../lambda/ingest.zip"
}
resource "aws_lambda_function" "ingest" {
  function_name = "${var.project_name}-ingest"
  handler = "handler.lambda_handler"
  runtime = "python3.11"
  role    = aws_iam_role.lambda_ingest_role.arn
  filename = data.archive_file.ingest_zip.output_path
  timeout = 15
  environment { variables = {
    RAW_BUCKET = aws_s3_bucket.raw.bucket
    CURATED_BUCKET = aws_s3_bucket.curated.bucket
    INDEX_NAME = "${var.project_name}-logs"
  }}
  tags = local.tags
}

resource "aws_apigatewayv2_api" "http_api" { name="${var.project_name}-http"; protocol_type="HTTP"; tags=local.tags }
resource "aws_apigatewayv2_integration" "ingest_integration" {
  api_id = aws_apigatewayv2_api.http_api.id
  integration_type="AWS_PROXY"
  integration_uri = aws_lambda_function.ingest.arn
  integration_method="POST"
  payload_format_version="2.0"
}
resource "aws_apigatewayv2_route" "logs_route" {
  api_id=aws_apigatewayv2_api.http_api.id
  route_key="POST /ingest"
  target="integrations/${aws_apigatewayv2_integration.ingest_integration.id}"
}
resource "aws_lambda_permission" "apigw_invoke" {
  statement_id="AllowAPIGWInvoke"
  action="lambda:InvokeFunction"
  function_name=aws_lambda_function.ingest.function_name
  principal="apigateway.amazonaws.com"
  source_arn="${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

resource "aws_opensearch_domain" "domain" {
  domain_name = var.project_name
  engine_version = var.opensearch_ver
  cluster_config { instance_type="t3.small.search"; instance_count=1 }
  ebs_options    { ebs_enabled=true; volume_size=10; volume_type="gp3" }
  encrypt_at_rest { enabled=true }
  node_to_node_encryption { enabled=true }
  domain_endpoint_options { enforce_https=true }
  tags = local.tags
}

resource "aws_athena_database" "db" {
  name   = replace("${var.project_name}_db","-","_")
  bucket = aws_s3_bucket.curated.bucket
}

data "aws_ami" "al2023" { most_recent=true; owners=["137112412989"]; filter { name="name" values=["al2023-ami-*-x86_64"] } }
resource "aws_instance" "trainer" {
  ami = data.aws_ami.al2023.id
  instance_type = "t3.micro"
  tags = merge(local.tags, {Name="${var.project_name}-trainer"})
}
