#!/usr/bin/env bash
# ── infra/bootstrap.sh ────────────────────────────────────────────────────────
# Creates S3 state bucket + DynamoDB lock table for a given environment.
# Usage: ENV=prod bash infra/bootstrap.sh

set -euo pipefail

ENV="${ENV:-dev}"
REGION="${AWS_REGION:-eu-west-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="cyberwatch-terraform-state-${ENV}-${ACCOUNT_ID}"
TABLE="cyberwatch-terraform-locks"

echo "═══════════════════════════════════════════"
echo " CyberWatch Terraform Bootstrap"
echo " Environment : $ENV"
echo " Region      : $REGION"
echo " Account     : $ACCOUNT_ID"
echo " State Bucket: $BUCKET"
echo "═══════════════════════════════════════════"
read -p "Continue? [y/N] " -n 1 -r; echo
[[ $REPLY =~ ^[Yy]$ ]] || exit 0

# S3 bucket
if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=$REGION"
  fi
fi

aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"},"BucketKeyEnabled":true}]}'
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
echo "✓ S3 bucket configured: $BUCKET"

# DynamoDB lock table
if ! aws dynamodb describe-table --table-name "$TABLE" --region "$REGION" 2>/dev/null; then
  aws dynamodb create-table \
    --table-name "$TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION"
  aws dynamodb wait table-exists --table-name "$TABLE" --region "$REGION"
  echo "✓ DynamoDB lock table created: $TABLE"
fi

# Write backend.tf
cat > "infra/terraform/environments/${ENV}/backend.tf" << EOF
terraform {
  backend "s3" {
    bucket         = "$BUCKET"
    key            = "${ENV}/terraform.tfstate"
    region         = "$REGION"
    encrypt        = true
    dynamodb_table = "$TABLE"
  }
}
EOF

echo "✓ Written infra/terraform/environments/${ENV}/backend.tf"
echo ""
echo "Next: cd infra/terraform/environments/$ENV && terraform init && terraform plan"
