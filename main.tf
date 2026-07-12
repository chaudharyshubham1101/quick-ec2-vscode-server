########################################
# Data sources
########################################

data "aws_availability_zones" "available" {
  state = "available"
}

# Equivalent of the SSM::Parameter::Value<AWS::EC2::Image::Id> parameter
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"
}

# CloudFront's managed prefix list, used to lock port 80 down to CloudFront only
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

########################################
# Networking (IDESECUIdeVPC + subnet + IGW + routing)
########################################

resource "aws_vpc" "ide" {
  cidr_block           = "192.168.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  instance_tenancy     = "default"

  tags = {
    Name = "IDE"
  }
}

resource "aws_subnet" "ide_public" {
  vpc_id                  = aws_vpc.ide.id
  cidr_block              = "192.168.0.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "IDE-PublicSubnet"
  }
}

resource "aws_internet_gateway" "ide" {
  tags = {
    Name = "IDE-IGW"
  }
}

resource "aws_internet_gateway_attachment" "ide" {
  vpc_id              = aws_vpc.ide.id
  internet_gateway_id = aws_internet_gateway.ide.id
}

resource "aws_route_table" "ide_public" {
  vpc_id = aws_vpc.ide.id

  tags = {
    Name = "IDE-PublicSubnet-RouteTable"
  }
}

resource "aws_route" "ide_public_default" {
  route_table_id         = aws_route_table.ide_public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.ide.id

  depends_on = [aws_internet_gateway_attachment.ide]
}

resource "aws_route_table_association" "ide_public" {
  subnet_id      = aws_subnet.ide_public.id
  route_table_id = aws_route_table.ide_public.id
}

########################################
# IAM: shared instance role/profile 
########################################

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "shared" {
  name               = "ide-shared-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy_attachment" "shared_admin" {
  role       = aws_iam_role.shared.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_role_policy_attachment" "shared_ssm_core" {
  role       = aws_iam_role.shared.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_partition" "current" {}

resource "aws_iam_instance_profile" "ide" {
  name = "ide-instance-profile"
  role = aws_iam_role.shared.name

  depends_on = [
    aws_internet_gateway_attachment.ide,
    aws_route.ide_public_default,
    aws_route_table.ide_public,
    aws_route_table_association.ide_public,
    aws_subnet.ide_public,
    aws_vpc.ide,
  ]
}


resource "aws_iam_role_policy" "shared_default" {
  name = "ide-shared-role-default-policy"
  role = aws_iam_role.shared.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = aws_cloudwatch_log_group.ide.arn
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:DescribeSecret", "secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.ide_password.arn
      }
    ]
  })
}

########################################
# Security groups 
########################################

resource "aws_security_group" "ide" {
  name        = "ide-security-group"
  description = "IDE security group"
  vpc_id      = aws_vpc.ide.id

  egress {
    description = "Allow all outbound traffic by default"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group_rule" "http_from_cloudfront" {
  type              = "ingress"
  description       = "HTTP from CloudFront only"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  security_group_id = aws_security_group.ide.id
  prefix_list_ids   = [data.aws_ec2_managed_prefix_list.cloudfront.id]
}

########################################
# EC2 instance
########################################

resource "aws_instance" "ide" {
  ami                          = data.aws_ssm_parameter.al2023_ami.value
  instance_type                = var.instance_type
  availability_zone            = data.aws_availability_zones.available.names[0]
  subnet_id                    = aws_subnet.ide_public.id
  vpc_security_group_ids       = [aws_security_group.ide.id]
  iam_instance_profile         = aws_iam_instance_profile.ide.name
  associate_public_ip_address  = true

  root_block_device {
    delete_on_termination = true
    encrypted              = true
    volume_size            = 30
    volume_type            = "gp3"
  }

  user_data = "#!/bin/bash"

  tags = {
    Name = "Temporary-IDE"
  }

  depends_on = [
    aws_internet_gateway_attachment.ide,
    aws_route.ide_public_default,
    aws_route_table.ide_public,
    aws_route_table_association.ide_public,
    aws_subnet.ide_public,
    aws_vpc.ide,
    aws_iam_role_policy.shared_default,
  ]
}

########################################
# CW Log group for logging ssm send-command
########################################

resource "aws_cloudwatch_log_group" "ide" {
  name              = "/ide/bootstrap"
  retention_in_days = 7
}

########################################
# IDE password
########################################

resource "random_password" "ide" {
  length = 32

  # Mirrors GenerateSecretString: ExcludePunctuation = true (so no special
  # characters at all, which also covers ExcludeCharacters "\"@/\\") and
  # IncludeSpace = false.
  special = false
  upper   = true
  lower   = true
  numeric = true
}

resource "aws_secretsmanager_secret" "ide_password" {
  name = "ide-password"

  # Mirrors DeletionPolicy: Delete on the original secret (skip the default
  # 30-day recovery window).
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "ide_password" {
  secret_id     = aws_secretsmanager_secret.ide_password.id
  secret_string = jsonencode({ password = random_password.ide.result })
}

########################################
# CloudFront distribution
########################################

resource "aws_cloudfront_distribution" "ide" {
  enabled         = true
  http_version    = "http2"
  is_ipv6_enabled = true

  origin {
    domain_name = aws_instance.ide.public_dns
    origin_id   = "IdeDistributionOrigin"

    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = "http-only"
      origin_ssl_protocols     = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id        = "IdeDistributionOrigin"
    viewer_protocol_policy   = "allow-all"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "PATCH", "POST", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    compress                 = true

    # AWS managed policies: CachingDisabled / AllViewer
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

########################################
# SSM Document (For setting up the VSCode server and running custom script)
########################################

locals {
  bootstrap_script = templatefile("${path.module}/scripts/setup-vscode-server.sh.tftpl", {
    instance_iam_role_name   = aws_iam_role.shared.name
    instance_iam_role_arn    = aws_iam_role.shared.arn
    password_name            = aws_secretsmanager_secret.ide_password.name
    domain                   = aws_cloudfront_distribution.ide.domain_name
    code_server_version      = var.code_server_version
    environment_contents_zip = ""
    extensions               = ""
    splash_url               = ""
    readme_url               = ""
    terminal_on_startup      = "false"
    install_gitea            = ""
    custom_bootstrap_script  = file("${path.module}/scripts/custom-code.sh")
  })
}

resource "aws_ssm_document" "ide_bootstrap" {
  name            = "ide-bootstrap-document"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Bootstrap IDE"
    parameters = {
      BootstrapScript = {
        type        = "String"
        description = "(Optional) Custom bootstrap script to run."
        default     = ""
      }
    }
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "IdeBootstrapFunction"
        inputs = {
          runCommand = [local.bootstrap_script]
        }
      }
    ]
  })
}

########################################
# local-exec for executing the ssm-document on the Instance
########################################

resource "null_resource" "ide_bootstrap_trigger" {
  triggers = {
    instance_id  = aws_instance.ide.id
    document_arn = aws_ssm_document.ide_bootstrap.arn
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      INSTANCE_ID="${aws_instance.ide.id}"
      DOCUMENT="${aws_ssm_document.ide_bootstrap.name}"
      LOG_GROUP="${aws_cloudwatch_log_group.ide.name}"
      PROFILE=default

      echo "Waiting for instance $INSTANCE_ID to be running..."
      aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --profile "$PROFILE"

      echo "Waiting for instance to register with SSM..."
      for i in $(seq 1 60); do
        STATUS=$(aws ssm describe-instance-information \
          --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
          --query 'InstanceInformationList[0].PingStatus' --profile "$PROFILE" --output text 2>/dev/null || echo "None")
        if [ "$STATUS" = "Online" ]; then
          echo "Instance is online in SSM"
          break
        fi
        sleep 10
      done

      echo "Sending bootstrap command..."
      COMMAND_ID=$(aws ssm send-command \
        --instance-ids "$INSTANCE_ID" \
        --document-name "$DOCUMENT" \
        --profile "$PROFILE" \
        --cloud-watch-output-config "CloudWatchLogGroupName=$LOG_GROUP,CloudWatchOutputEnabled=true" \
        --query 'Command.CommandId' --output text)

      echo "Waiting for bootstrap command $COMMAND_ID to finish (timeout 1800s)..."
      elapsed=0
      while [ $elapsed -lt 1800 ]; do
        STATUS=$(aws ssm get-command-invocation \
          --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
          --profile "$PROFILE" \
          --query 'Status' --output text 2>/dev/null || echo "Pending")
        case "$STATUS" in
          Success) echo "Bootstrap succeeded"; exit 0 ;;
          Failed|Cancelled|TimedOut) echo "Bootstrap failed with status: $STATUS"; exit 1 ;;
        esac
        sleep 15
        elapsed=$((elapsed + 15))
      done

      echo "Timed out waiting for bootstrap command to complete"
      exit 1
    EOT
  }

  depends_on = [
    aws_iam_instance_profile.ide,
    aws_instance.ide,
    aws_ssm_document.ide_bootstrap,
  ]
}
