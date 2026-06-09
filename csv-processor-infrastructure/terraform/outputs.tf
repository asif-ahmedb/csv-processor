output "vpc_id" {
  value = module.vpc.vpc_id
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "s3_bucket_name" {
  value = aws_s3_bucket.processed_csv.id
}

output "app_irsa_role_arn" {
  value       = module.app_irsa.iam_role_arn
  description = "Set as aws.irsaRoleArn in csv-processor-k8s-assets helm/csv-processor/values-eks.yaml"
}

output "aws_region" {
  value = var.aws_region
}
