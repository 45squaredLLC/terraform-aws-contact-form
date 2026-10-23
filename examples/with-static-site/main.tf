# A static site (terraform-aws-static-site) with a working contact form.
#
# Before the first apply:
#   1. Verify your domain in SES (same account and region), and leave the SES
#      sandbox if the form should reach addresses you haven't verified.
#   2. Create a Cloudflare Turnstile widget for your domain. Put its secret key in
#      Parameter Store (it never touches Terraform state):
#        aws ssm put-parameter --type SecureString \
#          --name /contact-form/turnstile-secret --value '<secret key>'
#      and its site key in site/index.html (data-sitekey).
#
#   terraform init
#   terraform apply -var domain=yourdomain.com -var owner_email=you@yourdomain.com
#
# Then put the "endpoint" output into site/index.html (the form's action) and
# apply again so the site uploads with it.

variable "domain" {
  type = string
}

variable "owner_email" {
  type = string
}

provider "aws" {
  region = "us-east-1"
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

module "site" {
  source = "github.com/45squaredLLC/terraform-aws-static-site"

  domain   = var.domain
  site_dir = "${path.module}/site"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
}

module "contact_form" {
  source = "github.com/45squaredLLC/terraform-aws-contact-form"

  name                       = "${replace(var.domain, ".", "-")}-contact"
  to_addresses               = [var.owner_email]
  from_address               = "website@${var.domain}"
  allowed_origins            = ["https://${var.domain}", "https://www.${var.domain}"]
  turnstile_secret_parameter = "/contact-form/turnstile-secret"
}

output "url" {
  value = module.site.url
}

output "endpoint" {
  value = module.contact_form.endpoint
}
