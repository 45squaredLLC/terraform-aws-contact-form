# terraform test: plans the module against a mocked AWS provider, so it needs no
# AWS account or credentials.

mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/test-contact"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:123456789012:log-group:/aws/lambda/test-contact"
    }
  }

  mock_resource "aws_lambda_function" {
    defaults = {
      invoke_arn = "arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/arn:aws:lambda:us-east-1:123456789012:function:test-contact/invocations"
    }
  }

  mock_resource "aws_apigatewayv2_api" {
    defaults = {
      api_endpoint  = "https://abc123.execute-api.us-east-1.amazonaws.com"
      execution_arn = "arn:aws:execute-api:us-east-1:123456789012:abc123"
    }
  }

  mock_resource "aws_dynamodb_table" {
    defaults = {
      arn = "arn:aws:dynamodb:us-east-1:123456789012:table/test-contact"
    }
  }
}

variables {
  name            = "test-contact"
  to_addresses    = ["owner@example.com"]
  from_address    = "website@example.com"
  allowed_origins = ["https://example.com"]
}

run "defaults" {
  command = apply

  assert {
    condition     = aws_apigatewayv2_route.form.route_key == "POST /contact"
    error_message = "The form route should be POST /contact."
  }

  assert {
    condition     = output.endpoint == "https://abc123.execute-api.us-east-1.amazonaws.com/contact"
    error_message = "endpoint should be the API address plus /contact."
  }

  assert {
    condition     = aws_lambda_function.form.environment[0].variables.TURNSTILE_SECRET_PARAMETER == ""
    error_message = "Turnstile should be off when no parameter is given."
  }

  assert {
    condition     = length(aws_dynamodb_table.submissions) == 0 && output.table_name == null
    error_message = "No table unless store_submissions is on."
  }

  assert {
    condition     = strcontains(aws_iam_role_policy.form.policy, "identity/example.com") && !strcontains(aws_iam_role_policy.form.policy, "ssm:GetParameter")
    error_message = "The role may send as the sender's domain and has no SSM access without Turnstile."
  }

  assert {
    condition     = aws_apigatewayv2_stage.form.default_route_settings[0].throttling_rate_limit == 1
    error_message = "The default rate limit should be 1 request per second."
  }
}

run "turnstile_and_storage" {
  command = apply

  variables {
    turnstile_secret_parameter = "/contact-form/turnstile-secret"
    store_submissions          = true
    redirect_url               = "https://example.com/contact/"
    to_addresses               = ["a@example.com", "b@example.com"]
  }

  assert {
    condition     = aws_lambda_function.form.environment[0].variables.TURNSTILE_SECRET_PARAMETER == "/contact-form/turnstile-secret"
    error_message = "The Lambda should be told which parameter holds the Turnstile secret."
  }

  assert {
    condition     = strcontains(aws_iam_role_policy.form.policy, "parameter/contact-form/turnstile-secret")
    error_message = "The role should read exactly the Turnstile parameter."
  }

  assert {
    condition     = length(aws_dynamodb_table.submissions) == 1 && strcontains(aws_iam_role_policy.form.policy, "dynamodb:PutItem")
    error_message = "store_submissions should create the table and allow writes to it."
  }

  assert {
    condition     = aws_lambda_function.form.environment[0].variables.TO_ADDRESSES == "a@example.com,b@example.com"
    error_message = "Recipients should be passed comma-separated."
  }
}

run "rejects_bad_sender" {
  command = plan

  variables {
    from_address = "not-an-address"
  }

  expect_failures = [var.from_address]
}

run "rejects_no_recipients" {
  command = plan

  variables {
    to_addresses = []
  }

  expect_failures = [var.to_addresses]
}
