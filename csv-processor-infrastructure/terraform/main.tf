data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name   = "${var.project_name}-${var.environment}"
  azs    = slice(data.aws_availability_zones.available.names, 0, 2)
  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 8, i)]
  public_subnets  = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 10)]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  tags = local.tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = local.name
  cluster_version = var.eks_cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = true

  eks_managed_node_groups = {
    ondemand = {
      min_size     = 1
      max_size     = 3
      desired_size = 1
      instance_types = var.eks_node_instance_types
      capacity_type  = "ON_DEMAND"
      labels = {
        lifecycle = "ondemand"
      }
      tags = {
        "k8s.io/cluster-autoscaler/enabled"             = "true"
        "k8s.io/cluster-autoscaler/${local.name}"       = "owned"
      }
    }
    spot = {
      min_size     = 0
      max_size     = 5
      desired_size = 0
      instance_types = var.eks_node_instance_types
      capacity_type  = "SPOT"
      labels = {
        lifecycle = "spot"
      }
      taints = [{
        key    = "lifecycle"
        value  = "spot"
        effect = "NO_SCHEDULE"
      }]
      tags = {
        "k8s.io/cluster-autoscaler/enabled"       = "true"
        "k8s.io/cluster-autoscaler/${local.name}" = "owned"
      }
    }
  }

  tags = local.tags
}

resource "aws_s3_bucket" "processed_csv" {
  bucket = "${local.name}-processed-${data.aws_caller_identity.current.account_id}"

  tags = merge(local.tags, { Name = "${local.name}-processed" })
}

resource "aws_s3_bucket_versioning" "processed_csv" {
  bucket = aws_s3_bucket.processed_csv.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "processed_csv" {
  bucket = aws_s3_bucket.processed_csv.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "processed_csv" {
  bucket                  = aws_s3_bucket.processed_csv.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "processed_csv" {
  bucket = aws_s3_bucket.processed_csv.id

  rule {
    id     = "processed-csv-lifecycle"
    status = "Enabled"

    filter {
      prefix = "processed/"
    }

    transition {
      days          = var.glacier_transition_days
      storage_class = "GLACIER"
    }

    transition {
      days          = var.glacier_deep_archive_days
      storage_class = "DEEP_ARCHIVE"
    }

    noncurrent_version_transition {
      noncurrent_days = 90
      storage_class   = "GLACIER"
    }

    noncurrent_version_expiration {
      noncurrent_days = 365
    }

    expiration {
      days = 365
    }
  }
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket_ownership_controls" "processed_csv" {
  bucket = aws_s3_bucket.processed_csv.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_iam_policy" "app_s3" {
  name        = "${local.name}-app-s3"
  description = "Allow CSV processor to read/write processed files in S3"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ObjectAccess"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload"
        ]
        Resource = "${aws_s3_bucket.processed_csv.arn}/*"
      },
      {
        Sid    = "BucketList"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = aws_s3_bucket.processed_csv.arn
      }
    ]
  })
}

module "app_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${local.name}-app"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["csv-processor:csv-processor"]
    }
  }

  role_policy_arns = {
    s3 = aws_iam_policy.app_s3.arn
  }

  tags = local.tags
}
