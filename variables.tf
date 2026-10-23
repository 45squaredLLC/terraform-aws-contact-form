variable "name" {
  description = "Name for the form's resources (Lambda, API, role, table), e.g. example-com-contact. Letters, numbers and dashes."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9-]{1,48}$", var.name))
    error_message = "name must be 1 to 48 letters, numbers or dashes."
  }
}

variable "to_addresses" {
  description = "Who receives the messages, e.g. [\"owner@example.com\"]. While SES is in its sandbox, each one must be a verified address."
  type        = list(string)

  validation {
    condition     = length(var.to_addresses) > 0 && alltrue([for a in var.to_addresses : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", a))])
    error_message = "to_addresses must hold at least one email address."
  }
}

variable "from_address" {
  description = "Sender address, e.g. website@example.com. Its domain (or the address itself) must be a verified SES identity in this account and region."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.from_address))
    error_message = "from_address must be an email address."
  }
}

variable "allowed_origins" {
  description = "Sites allowed to post to the form from a browser (CORS), e.g. [\"https://example.com\", \"https://www.example.com\"]."
  type        = list(string)
}

variable "turnstile_secret_parameter" {
  description = "Name of an SSM Parameter Store SecureString holding your Cloudflare Turnstile secret key, e.g. /contact-form/turnstile-secret. When set, every submission needs a valid Turnstile token. Create the parameter yourself so the secret never lands in Terraform state."
  type        = string
  default     = null
}

variable "subject_prefix" {
  description = "Start of the email subject; the sender's name is added after it."
  type        = string
  default     = "New message from your website"
}

variable "redirect_url" {
  description = "For plain HTML forms (no JavaScript): where to send the visitor after posting, e.g. https://example.com/contact/. ?sent=1 or ?error=<message> is added. Leave null when the page posts with fetch() and reads the JSON reply."
  type        = string
  default     = null
}

variable "honeypot_field" {
  description = "Name of a hidden field real visitors leave empty. A submission that fills it is dropped quietly."
  type        = string
  default     = "website"
}

variable "store_submissions" {
  description = "Also keep a copy of each message in a DynamoDB table (pay per request, deleted after retention_days)."
  type        = bool
  default     = false
}

variable "retention_days" {
  description = "How long stored messages are kept when store_submissions is on."
  type        = number
  default     = 365
}

variable "rate_limit" {
  description = "Steady-state requests per second the form accepts (API Gateway throttling). A contact form needs very little, and a low limit caps what a flood can cost."
  type        = number
  default     = 1
}

variable "burst_limit" {
  description = "Short burst of requests allowed above rate_limit."
  type        = number
  default     = 5
}

variable "log_retention_days" {
  description = "CloudWatch log retention for the Lambda."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags for every resource that takes them."
  type        = map(string)
  default     = {}
}
