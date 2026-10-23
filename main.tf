locals {
  # Partition, region and account come from the log group's ARN
  # (arn:<partition>:logs:<region>:<account>:...), the same on AWS provider v5 and v6.
  arn_parts   = split(":", aws_cloudwatch_log_group.form.arn)
  prefix      = "arn:${local.arn_parts[1]}"
  region      = local.arn_parts[3]
  account     = local.arn_parts[4]
  from_domain = split("@", var.from_address)[1]
  turnstile   = var.turnstile_secret_parameter != null && var.turnstile_secret_parameter != ""
}

# ---- Lambda ------------------------------------------------------------------

data "archive_file" "handler" {
  type        = "zip"
  source_file = "${path.module}/src/handler.py"
  output_path = "${path.module}/.build/${var.name}.zip"
}

resource "aws_iam_role" "form" {
  name = var.name
  tags = var.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "form" {
  name = var.name
  role = aws_iam_role.form.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Effect   = "Allow"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
          Resource = "${aws_cloudwatch_log_group.form.arn}:*"
        },
        {
          # Send only as the configured sender's domain or address. When the
          # account has a default configuration set, SES also authorizes every
          # send against that set, so configuration sets are allowed too
          # (without them the send fails with AccessDenied).
          Effect = "Allow"
          Action = ["ses:SendEmail"]
          Resource = [
            "${local.prefix}:ses:${local.region}:${local.account}:identity/${local.from_domain}",
            "${local.prefix}:ses:${local.region}:${local.account}:identity/${var.from_address}",
            "${local.prefix}:ses:${local.region}:${local.account}:configuration-set/*",
          ]
        },
      ],
      local.turnstile ? [{
        # A SecureString under the aws/ssm key: that key's policy covers decryption.
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "${local.prefix}:ssm:${local.region}:${local.account}:parameter/${trimprefix(var.turnstile_secret_parameter, "/")}"
      }] : [],
      var.store_submissions ? [{
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = aws_dynamodb_table.submissions[0].arn
      }] : [],
    )
  })
}

resource "aws_cloudwatch_log_group" "form" {
  name              = "/aws/lambda/${var.name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_lambda_function" "form" {
  function_name    = var.name
  description      = "Contact form: checks a submission and emails it to the site owner"
  role             = aws_iam_role.form.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = data.archive_file.handler.output_path
  source_code_hash = data.archive_file.handler.output_base64sha256
  memory_size      = 128
  timeout          = 10
  tags             = var.tags

  environment {
    variables = {
      TO_ADDRESSES               = join(",", var.to_addresses)
      FROM_ADDRESS               = var.from_address
      SUBJECT_PREFIX             = var.subject_prefix
      TURNSTILE_SECRET_PARAMETER = local.turnstile ? var.turnstile_secret_parameter : ""
      TABLE_NAME                 = var.store_submissions ? aws_dynamodb_table.submissions[0].name : ""
      RETENTION_DAYS             = tostring(var.retention_days)
      REDIRECT_URL               = var.redirect_url == null ? "" : var.redirect_url
      HONEYPOT_FIELD             = var.honeypot_field
    }
  }

  depends_on = [aws_cloudwatch_log_group.form, aws_iam_role_policy.form]
}

# ---- HTTP API ----------------------------------------------------------------

resource "aws_apigatewayv2_api" "form" {
  name          = var.name
  protocol_type = "HTTP"
  tags          = var.tags

  cors_configuration {
    allow_origins = var.allowed_origins
    allow_methods = ["POST"]
    allow_headers = ["content-type"]
    max_age       = 86400
  }
}

resource "aws_apigatewayv2_integration" "form" {
  api_id                 = aws_apigatewayv2_api.form.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.form.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "form" {
  api_id    = aws_apigatewayv2_api.form.id
  route_key = "POST /contact"
  target    = "integrations/${aws_apigatewayv2_integration.form.id}"
}

resource "aws_apigatewayv2_stage" "form" {
  api_id      = aws_apigatewayv2_api.form.id
  name        = "$default"
  auto_deploy = true
  tags        = var.tags

  default_route_settings {
    throttling_rate_limit  = var.rate_limit
    throttling_burst_limit = var.burst_limit
  }
}

resource "aws_lambda_permission" "api" {
  statement_id  = "AllowHttpApi"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.form.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.form.execution_arn}/*/*/contact"
}

# ---- Optional copy of each message ---------------------------------------------

resource "aws_dynamodb_table" "submissions" {
  count        = var.store_submissions ? 1 : 0
  name         = var.name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"
  tags         = var.tags

  attribute {
    name = "id"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }
}
