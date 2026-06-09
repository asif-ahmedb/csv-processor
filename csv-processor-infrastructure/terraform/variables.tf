variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "csv-processor"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "vpc_cidr" {
  type    = string
  default = "10.1.0.0/16"
}

variable "eks_cluster_version" {
  type    = string
  default = "1.29"
}

variable "eks_node_instance_types" {
  type    = list(string)
  default = ["t3.small", "t3.medium"]
}

variable "glacier_transition_days" {
  type        = number
  description = "Days after upload before transition to Glacier"
  default     = 30

  validation {
    condition     = var.glacier_transition_days > 0
    error_message = "glacier_transition_days must be greater than 0."
  }
}

variable "glacier_deep_archive_days" {
  type        = number
  description = "Days after upload before transition to Glacier Deep Archive (must exceed glacier_transition_days)"
  default     = 180

  validation {
    condition     = var.glacier_deep_archive_days > 30
    error_message = "glacier_deep_archive_days must be greater than 30 (the minimum Glacier storage duration)."
  }
}
