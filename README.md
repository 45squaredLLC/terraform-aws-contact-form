# terraform-aws-contact-form

A contact form backend for a static website, in one Terraform module. Your page posts the form; the module emails it to you.

- an **HTTP API** endpoint (`POST /contact`) with CORS for your site and low rate limits
- a small **Python Lambda** that checks the submission and sends it with **Amazon SES**, with Reply-To set to the visitor so you can just hit reply
- spam protection: a hidden **honeypot** field, plus optional **Cloudflare Turnstile** verification
- optional: a copy of every message in **DynamoDB**, deleted after a set number of days

It pairs with [terraform-aws-static-site](https://github.com/45squaredLLC/terraform-aws-static-site), but works with any site that can post a form: plain HTML, a vibe-coded app, or a site hosted somewhere else.

The Lambda is one short file ([`src/handler.py`](src/handler.py)) using only the Python standard library and boto3. There are no packages to install and nothing to patch.

## Quick start

```hcl
provider "aws" {
  region = "us-east-1"
}

module "contact_form" {
  source = "github.com/45squaredLLC/terraform-aws-contact-form"

  name            = "example-com-contact"
  to_addresses    = ["owner@example.com"]
  from_address    = "website@example.com" # example.com must be verified in SES
  allowed_origins = ["https://example.com", "https://www.example.com"]
}

output "form_endpoint" {
  value = module.contact_form.endpoint
}
```

Point your form at the `endpoint` output:

```html
<form id="contact" method="post" action="https://abc123.execute-api.us-east-1.amazonaws.com/contact">
  <input name="name">
  <input name="email" type="email" required>
  <textarea name="message" required></textarea>
  <!-- honeypot: hidden from people, bots fill it in -->
  <input name="website" tabindex="-1" autocomplete="off" style="position:absolute;left:-10000px" aria-hidden="true">
  <button>Send</button>
</form>
```

The endpoint accepts JSON (`fetch`) or a normal form post. It reads `name`, `email`, `phone`, `subject` and `message`. `email` and `message` are required.

- **JSON replies:** `{"ok": true, "message": "ok"}`, or HTTP 400 with a message you can show the visitor.
- **Plain HTML forms (no JavaScript):** set `redirect_url`. The visitor goes back to your page with `?sent=1` or `?error=...` added.

[`examples/with-static-site`](examples/with-static-site) is a complete page with Turnstile and a `fetch` submit, deployed alongside the static-site module.

## Before you apply

1. **SES.** Verify the sender's domain (or address) in SES, in the same account and region as the module.
   - A new AWS account starts in the SES sandbox, where mail only goes to verified addresses.
   - Request production access if the recipients aren't verified.
   - Accounts with a default SES configuration set work too: the Lambda's role may send through configuration sets as well as the sender identity.
2. **Turnstile (recommended).**
   1. Create a free widget at Cloudflare for your domain.
   2. Put the **secret key** in Parameter Store yourself, so it never lands in Terraform state:
      ```bash
      aws ssm put-parameter --type SecureString \
        --name /contact-form/turnstile-secret --value '<secret key>'
      ```
   3. Pass `turnstile_secret_parameter = "/contact-form/turnstile-secret"`.
   4. Add the widget to your form with the **site key**. The widget adds a `cf-turnstile-response` field; with Turnstile on, any submission without a valid token is refused.
3. **CI that applies a saved plan in a separate job.** The Lambda zip is built by `archive_file` during plan, at `.terraform/modules/<module name>/.build/<name>.zip`. A fresh apply job won't have it, so carry that file over with the plan, e.g. in the same artifact as `plan.out`. With `actions/upload-artifact`, set `include-hidden-files: true`. Without it the apply fails with "reading ZIP file … no such file or directory".

## Inputs

| Name | Description | Default |
|---|---|---|
| `name` | Name for the form's resources (letters, numbers, dashes). | required |
| `to_addresses` | Who receives the messages. | required |
| `from_address` | Sender address; its domain must be verified in SES. | required |
| `allowed_origins` | Sites allowed to post from a browser (CORS). | required |
| `turnstile_secret_parameter` | SSM SecureString name holding the Turnstile secret. | `null` (off) |
| `subject_prefix` | Start of the email subject. | `New message from your website` |
| `redirect_url` | Where plain HTML form posts go back to. | `null` (JSON replies) |
| `honeypot_field` | Hidden field name that marks a bot. | `website` |
| `store_submissions` | Keep a copy of each message in DynamoDB. | `false` |
| `retention_days` | Days to keep stored messages. | `365` |
| `rate_limit` | Requests per second the form accepts. | `1` |
| `burst_limit` | Short burst above the rate limit. | `5` |
| `log_retention_days` | CloudWatch log retention. | `30` |
| `tags` | Tags for every resource that takes them. | `{}` |

## Outputs

| Name | Description |
|---|---|
| `endpoint` | The URL your form posts to. |
| `api_id` | HTTP API ID. |
| `function_name` | Lambda function name (logs in `/aws/lambda/<name>`). |
| `table_name` | DynamoDB table, when `store_submissions` is on. |

## Cost

For a small business site, a few cents a month at most:

- **API Gateway (HTTP API):** $1.00 per million requests.
- **Lambda:** the always-free tier covers 1 million requests a month.
- **SES:** $0.10 per 1,000 emails.
- **DynamoDB** (optional): on-demand, fractions of a cent for a few messages.
- **CloudWatch Logs:** cents.
- **Turnstile:** free.

The low default rate limit (1 request a second, bursts of 5) caps what a flood of junk can cost. Raise it if a launch or campaign needs more.

## Tests

```bash
terraform init -backend=false
terraform test                               # plans against a mocked AWS provider; no account needed
python -m unittest discover -s tests -v      # the Lambda, with boto3 faked
```

## License

MIT. Made by [45Squared](https://45squared.com/?utm_source=github&utm_medium=readme&utm_campaign=terraform-aws-contact-form).
