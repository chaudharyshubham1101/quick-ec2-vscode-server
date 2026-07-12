# Quick IDE (VSCode Server) on a EC2 Instance

Terraform module that sets up a temporary, browser-based VS Code IDE
(`code-server`) on EC2, fronted by CloudFront for HTTPS and access control.

This is a Terraform port of a CDK-generated CloudFormation stack
([`Setup-IDE.json`](./Setup-IDE-CF-Template.json)) — see [Differences from the
original CloudFormation template](#differences-from-the-original-cloudformation-template)
for what changed along the way.

## Deploy it via the CF template ([`Setup-IDE.json`](./Setup-IDE-CF-Template.json)) or follow along to deply via terraform.


## What it creates

- A dedicated VPC with a public subnet, internet gateway, and routing
- An EC2 instance (Amazon Linux 2023) running `code-server` behind Caddy
- A CloudFront distribution in front of the instance, providing HTTPS with
  zero domain/cert setup, and locking down direct access to the instance
  (port 80 only accepts traffic from CloudFront's IP range)
- A Secrets Manager secret holding a randomly generated IDE password
- An SSM Command document that bootstraps the instance (installs
  `code-server`, Docker, the AWS CLI, Caddy, and runs custom bootstrap code)
- A CloudWatch log group for bootstrap output
- The IAM role/instance profile the EC2 instance runs as

```
                       ┌───────────────────┐
   HTTPS               │   CloudFront      │         HTTP (port 80 only,
 ───────────────────▶  │   distribution    │  ────▶  from CloudFront's
                       └───────────────────┘         managed prefix list)
                                                              │
                                                              ▼
                                                    ┌───────────────────┐
                                                    │   EC2 instance     │
                                                    │  Caddy → code-server│
                                                    └───────────────────┘
```

## Prerequisites

- Terraform >= 1.5.0
- AWS provider credentials with permissions to create the resources above
  (VPC, EC2, IAM, Secrets Manager, CloudWatch Logs, SSM, CloudFront)
- The AWS CLI installed **locally**, on whichever machine runs
  `terraform apply` — the bootstrap trigger (see below) shells out to it
- `jq` is not required locally, but is installed *on the instance* by the
  bootstrap script itself

## Usage

```hcl
module "ide" {
  source = "github.com/chaudharyshubham1101/quick-ec2-vscode-server"

  aws_region    = "us-east-1"
  instance_type = "c5.large"
}
```

Or, standalone from this repo:

```bash
terraform init
terraform plan
terraform apply
```

After `apply` finishes, get the URL and password:

```bash
terraform output ide_url
terraform output -raw ide_password
```

Open the URL in a browser and log in with that password.

### Cleaning up

```bash
terraform destroy
```

The CloudWatch log group and Secrets Manager secret are destroyed
immediately (no retention window) — see the [Differences](#differences-from-the-original-cloudformation-template)
section if you'd rather they weren't.

## Inputs

| Name | Description | Type | Default |
|---|---|---|---|
| `instance_type` | EC2 instance type for the IDE instance | `string` | `"c5.large"` |
| `aws_region` | AWS region to deploy into | `string` | `"us-east-1"` |
| `code_server_version` | Version of `code-server` to install | `string` | `"4.93.1"` |

## Outputs

| Name | Description |
|---|---|
| `ide_url` | HTTPS URL of the IDE (the CloudFront distribution domain) |
| `ide_password` | Generated login password for `code-server` (sensitive) |

## File structure

```
.
├── versions.tf                          # provider requirements
├── variables.tf                         # instance_type, aws_region, code_server_version
├── main.tf                              # all AWS resources
├── outputs.tf                           # ide_url, ide_password
└── scripts/
    ├── setup-vscode-server.sh.tftpl      # installs/configures code-server, Caddy, Docker, AWS CLI
    └── custom-code.sh                    # custom bootstrap code, kept separate and
                                           # injected into the setup script above
```

To add your own post-bootstrap customization, edit `scripts/custom-code.sh` — such as copying files from S3.
you don't need to touch the main setup script.

## Differences from the original CloudFormation template

The original CDK/CloudFormation stack used two Lambda-backed Custom
Resources. Both were replaced with more idiomatic Terraform, since Terraform
doesn't need a Lambda where a native resource or a shell command will do:

- **Password export.** The original invoked a Lambda purely to read the
  generated Secrets Manager password back out for a stack Output. This module
  generates the password with `random_password` directly, so it's already
  available to the `ide_password` output with no Lambda involved.
- **Bootstrap trigger.** The original waited for the instance to boot, waited
  for it to register with SSM, then called `ssm:SendCommand` — gated by a
  CloudFormation `WaitCondition` with a 30-minute timeout. This module
  reproduces that with a `null_resource` + `local-exec` provisioner that polls
  the AWS CLI directly. It runs with whatever credentials/role you run
  `terraform apply` with, so make sure that principal has
  `ec2:DescribeInstances`, `ssm:DescribeInstanceInformation`,
  `ssm:SendCommand`, and `ssm:GetCommandInvocation` permissions.

A couple of smaller, deliberate deviations:

- The CloudWatch log group and Secrets Manager secret are deleted immediately
  on destroy (`recovery_window_in_days = 0` / no retention protection),
  whereas the original template retained the log group and the secret had a
  30-day recovery window by default. Adjust if you'd like to match that.
- The CloudFront distribution's `AllViewer` origin request policy and
  `CachingDisabled` cache policy are carried over unchanged — CloudFront here
  provides HTTPS termination and access control, **not** caching (code-server
  is a live, stateful app; caching it would break it).

## Notes

- This is intended for short-lived/workshop-style environments (temporary,
  single EC2 instance, `AdministratorAccess` on the instance role). Harden
  the IAM policy and add persistence/backup if you plan to run this
  long-term.
- The instance opens no public ports directly — everything goes through
  CloudFront (port 80, restricted to CloudFront's IP range) or SSM Session
  Manager for admin/debug access.
