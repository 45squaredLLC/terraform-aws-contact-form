output "endpoint" {
  description = "The URL your form posts to."
  value       = "${aws_apigatewayv2_api.form.api_endpoint}/contact"
}

output "api_id" {
  description = "HTTP API ID."
  value       = aws_apigatewayv2_api.form.id
}

output "function_name" {
  description = "Lambda function name (its logs are in /aws/lambda/<name>)."
  value       = aws_lambda_function.form.function_name
}

output "table_name" {
  description = "DynamoDB table with stored messages, or null when store_submissions is off."
  value       = var.store_submissions ? aws_dynamodb_table.submissions[0].name : null
}
