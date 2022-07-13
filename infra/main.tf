# Infrastructure definitions

provider "aws" {
  version = "~> 2.0"
  region  = var.aws_region
}

# Local vars
locals {
  default_lambda_timeout = 10

  default_lambda_log_retention = 1
}

resource "aws_s3_bucket" "lambda_bucket" {
  bucket        = "lambda-bucket-assets-1234567"
  acl           = "private"
}

module "lambda_ingestion" {
  source               = "./modules/lambda"
  code_src             = "../functions/ingestion/main.zip"
  bucket_id            = aws_s3_bucket.lambda_bucket.id
  timeout              = local.default_lambda_timeout
  function_name        = "Ingestion-function"
  runtime              = "nodejs12.x"
  handler              = "dist/index.handler"
  publish              = true
  alias_name           = "ingestion-dev"
  alias_description    = "Alias for ingestion function"
  iam_statements       = {
    sqs = {
      actions = [
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl",
        "sqs:SendMessage",
        "sqs:ReceiveMessage",
      ]
      effect = "Allow"
      resources = [
        aws_sqs_queue.ingest_queue.arn
      ]
    }
  }
  environment_vars = {
    QueueUrl        = aws_sqs_queue.ingest_queue.id
    DefaultRegion   = var.aws_region
  }
}

module "lambda_process_queue" {
  source               = "./modules/lambda"
  code_src             = "../functions/process-queue/main.zip"
  bucket_id            = aws_s3_bucket.lambda_bucket.id
  timeout              = local.default_lambda_timeout
  function_name        = "Process-Queue-function"
  runtime              = "nodejs12.x"
  handler              = "dist/index.handler"
  publish              = true
  alias_name           = "process-queue-dev"
  alias_description    = "Alias for ingestion function"
  iam_statements       = {
    sqs = {
      actions = [
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl",
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
      ]
      effect = "Allow"
      resources = [
        aws_sqs_queue.ingest_queue.arn
      ]
    }
    dlq_sqs = {
      actions = [
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl",
        "sqs:SendMessage",
        "sqs:ReceiveMessage",
      ]
      effect = "Allow"
      resources = [
        aws_sqs_queue.ingest_dlq.arn
      ]
    }
  }

  environment_vars = {
    DefaultRegion   = var.aws_region
  }
}

data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

### Github OIDC for Lambda
resource "aws_iam_openid_connect_provider" "github_actions" {
  client_id_list  = var.client_id_list
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
  url             = "https://token.actions.githubusercontent.com"
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "github_actions_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [
        format(
          "arn:aws:iam::%s:root",
          data.aws_caller_identity.current.account_id
        )
      ]
    }
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type = "Federated"
      identifiers = [
        format(
          "arn:aws:iam::%s:oidc-provider/token.actions.githubusercontent.com",
          data.aws_caller_identity.current.account_id
        )
      ]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.repo_name}:ref:refs/heads/master"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role_policy.json
}

data "aws_iam_policy_document" "github_actions" {
  statement {
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
      "s3:PutObject",
    ]
    effect = "Allow"
    resources = [
      aws_s3_bucket.lambda_bucket.arn,
      "${aws_s3_bucket.lambda_bucket.arn}/*"
    ]
  }

  statement {
    actions = [
      "lambda:updateFunctionConfiguration",
      "lambda:updateFunctionCode",
      "lambda:updateAlias",
      "lambda:publishVersion",
    ]
    effect = "Allow"
    resources = [
      module.lambda_ingestion.lambda[0].arn,
      module.lambda_process_queue.lambda[0].arn
    ]
  }
}

resource "aws_iam_role_policy" "github_actions" {
  name   = "github-actions"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions.json
}

resource "aws_apigatewayv2_api" "lambda" {
  name          = "webhook_api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_stage" "lambda" {
  api_id = aws_apigatewayv2_api.lambda.id

  name        = "serverless_lambda_stage"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gw.arn
    format = jsonencode({
      requestId               = "$context.requestId"
      sourceIp                = "$context.identity.sourceIp"
      requestTime             = "$context.requestTime"
      protocol                = "$context.protocol"
      httpMethod              = "$context.httpMethod"
      resourcePath            = "$context.resourcePath"
      routeKey                = "$context.routeKey"
      status                  = "$context.status"
      responseLength          = "$context.responseLength"
      integrationErrorMessage = "$context.integrationErrorMessage"
    })
  }
}

resource "aws_cloudwatch_log_group" "api_gw" {
  name = "/aws/api_gw/${aws_apigatewayv2_api.lambda.name}"
  # If this is not available add it to the top of the file
  # locals {
  #   default_lambda_log_retention = 1
  # }
  retention_in_days = local.default_lambda_log_retention
}

resource "aws_api_gateway_account" "this" {
  cloudwatch_role_arn = aws_iam_role.cloudwatch.arn
}

resource "aws_iam_role" "cloudwatch" {
  name = "api_gateway_cloudwatch_global"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = ""
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = {
        Service = "apigateway.amazonaws.com"
      }
    }]
  })
}

data "aws_iam_policy_document" "cloudwatch" {
  version = "2012-10-17"
  statement {
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
      "logs:GetLogEvents",
      "logs:FilterLogEvents"
    ]
    effect = "Allow"
    resources = [
      "*"
    ]
  }
}

resource "aws_iam_role_policy" "cloudwatch" {
  name   = "cloudwatch-default-log-policy-${var.aws_region}-${var.environment}"
  role   = aws_iam_role.cloudwatch.id
  policy = data.aws_iam_policy_document.cloudwatch.json
}

resource "aws_apigatewayv2_integration" "this" {
  api_id = aws_apigatewayv2_api.lambda.id
  integration_uri    = module.lambda_ingestion.alias[0].invoke_arn
  integration_type   = "AWS_PROXY"
  integration_method = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "this" {
  api_id = aws_apigatewayv2_api.lambda.id
  route_key = "POST /webhooks/receive"
  target    = "integrations/${aws_apigatewayv2_integration.this.id}"
}

resource "aws_sqs_queue" "ingest_queue" {
  name = "ingest-queue"
  # This may be tweaked depending on the processing time of the lambda
  visibility_timeout_seconds = local.default_lambda_timeout
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.ingest_dlq.arn,
    maxReceiveCount: 2
  })
  tags = {
    Environment = var.environment
  }
}

resource "aws_sqs_queue" "ingest_dlq" {
  name = "ingest-queue-dlq"
  receive_wait_time_seconds = 20
  tags = {
    Environment = var.environment
  }
}

resource "aws_lambda_event_source_mapping" "queue_lambda_event" {
  event_source_arn = aws_sqs_queue.ingest_queue.arn
  function_name    = module.lambda_process_queue.alias[0].arn
  batch_size       = 5
}

resource "aws_lambda_permission" "api_gw" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = module.lambda_ingestion.alias[0].arn
  principal     = "apigateway.amazonaws.com"
  source_arn = "${aws_apigatewayv2_api.lambda.execution_arn}/*/*"
}
