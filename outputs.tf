output "ide_url" {
  description = "URL of the CloudFront-fronted IDE (equivalent of the IdeUrl CFN output)."
  value       = "https://${aws_cloudfront_distribution.ide.domain_name}"
}

output "ide_password" {
  description = "Password for the IDE (equivalent of the IdePassword CFN output)."
  value       = random_password.ide.result
  sensitive   = true
}
