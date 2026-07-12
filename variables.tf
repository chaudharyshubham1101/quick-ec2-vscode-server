variable "instance_type" {
  description = "EC2 instance type used for the IDE (VS Code server) instance."
  type        = string
  default     = "c5.large"
}

variable "aws_region" {
  description = "AWS region to deploy the IDE stack into."
  type        = string
  default     = "us-east-1"
}

variable "code_server_version" {
  description = "Version of code-server to install on the IDE instance."
  type        = string
  default     = "4.93.1"
}
