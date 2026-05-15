#!/usr/bin/env bash
# Deploy the BRA portal POC to S3 + CloudFront in one shot.
#
# Prerequisites:
#   - AWS CLI v2 installed and configured (run `aws configure` first)
#   - jq installed (brew install jq)
#   - Credentials with permission to create S3 buckets, CloudFront distributions,
#     and put bucket policies in your AWS account
#
# Usage:
#   ./deploy.sh <bucket-name> [region]
#
# Example:
#   ./deploy.sh bra-portal-poc-cc us-east-1
#
# Re-runs are safe-ish: re-running with the same bucket will re-sync files
# and invalidate the CloudFront cache. It will not create a second distribution.

set -euo pipefail

BUCKET="${1:-}"
REGION="${2:-us-east-1}"
SITE_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ -z "$BUCKET" ]]; then
  echo "Usage: $0 <bucket-name> [region]" >&2
  exit 1
fi

for cmd in aws jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: '$cmd' is not installed." >&2
    exit 1
  fi
done

ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
echo "AWS account: $ACCOUNT_ID"
echo "Region:      $REGION"
echo "Bucket:      $BUCKET"
echo "Source:      $SITE_DIR"
echo

# ---------------------------------------------------------------------------
# 1. Create the bucket (idempotent: ignores AlreadyOwnedByYou)
# ---------------------------------------------------------------------------
echo "==> Ensuring S3 bucket exists"
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "Bucket already exists."
else
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
  echo "Created bucket $BUCKET."
fi

echo "==> Locking down public access"
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# ---------------------------------------------------------------------------
# 2. Sync the site with appropriate cache headers
# ---------------------------------------------------------------------------
echo "==> Syncing site"
aws s3 sync "$SITE_DIR" "s3://$BUCKET/" \
  --exclude ".*" \
  --exclude "*.md" \
  --exclude "*.sh" \
  --exclude "tamis-pdfs/*" \
  --exclude "node_modules/*" \
  --delete

echo "==> Setting cache headers"
# HTML: short cache so updates propagate fast
aws s3 cp "s3://$BUCKET/" "s3://$BUCKET/" \
  --recursive --exclude "*" --include "*.html" \
  --metadata-directive REPLACE \
  --cache-control "public, max-age=60" \
  --content-type "text/html; charset=utf-8" >/dev/null

# CSS, SVG, fonts: long cache.
# NB: --metadata-directive REPLACE wipes all metadata including content-type, so
# each extension needs its own cp call with an explicit --content-type. Without
# that, S3 falls back to binary/octet-stream and browsers reject the CSS (strict
# MIME checks) — the site renders as unstyled raw HTML.
aws s3 cp "s3://$BUCKET/" "s3://$BUCKET/" \
  --recursive --exclude "*" --include "*.css" \
  --metadata-directive REPLACE \
  --cache-control "public, max-age=604800, immutable" \
  --content-type "text/css; charset=utf-8" >/dev/null

aws s3 cp "s3://$BUCKET/" "s3://$BUCKET/" \
  --recursive --exclude "*" --include "*.svg" \
  --metadata-directive REPLACE \
  --cache-control "public, max-age=604800, immutable" \
  --content-type "image/svg+xml" >/dev/null

aws s3 cp "s3://$BUCKET/" "s3://$BUCKET/" \
  --recursive --exclude "*" --include "*.woff2" \
  --metadata-directive REPLACE \
  --cache-control "public, max-age=604800, immutable" \
  --content-type "font/woff2" >/dev/null

# ---------------------------------------------------------------------------
# 3. Find or create the CloudFront distribution
# ---------------------------------------------------------------------------
DIST_COMMENT="BRA portal POC ($BUCKET)"

DIST_ID=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='$DIST_COMMENT'] | [0].Id" \
  --output text 2>/dev/null || echo "None")

if [[ "$DIST_ID" == "None" || -z "$DIST_ID" ]]; then
  echo "==> Creating Origin Access Control"
  OAC_ID=$(aws cloudfront create-origin-access-control \
    --origin-access-control-config \
      "Name=${BUCKET}-oac,SigningProtocol=sigv4,SigningBehavior=always,OriginAccessControlOriginType=s3" \
    --query 'OriginAccessControl.Id' --output text)
  echo "OAC: $OAC_ID"

  echo "==> Creating CloudFront distribution"
  cat > /tmp/bra-distribution.json <<JSON
{
  "CallerReference": "bra-portal-poc-$(date +%s)",
  "Comment": "$DIST_COMMENT",
  "Enabled": true,
  "DefaultRootObject": "index.html",
  "Origins": {
    "Quantity": 1,
    "Items": [
      {
        "Id": "s3-origin",
        "DomainName": "${BUCKET}.s3.${REGION}.amazonaws.com",
        "S3OriginConfig": { "OriginAccessIdentity": "" },
        "OriginAccessControlId": "$OAC_ID",
        "CustomHeaders": { "Quantity": 0 },
        "ConnectionAttempts": 3,
        "ConnectionTimeout": 10
      }
    ]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "s3-origin",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {
      "Quantity": 2,
      "Items": ["GET","HEAD"],
      "CachedMethods": { "Quantity": 2, "Items": ["GET","HEAD"] }
    },
    "Compress": true,
    "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6"
  },
  "ViewerCertificate": { "CloudFrontDefaultCertificate": true },
  "PriceClass": "PriceClass_100",
  "HttpVersion": "http2",
  "IsIPV6Enabled": true
}
JSON

  RESPONSE=$(aws cloudfront create-distribution --distribution-config file:///tmp/bra-distribution.json)
  DIST_ID=$(echo "$RESPONSE" | jq -r '.Distribution.Id')
  DIST_DOMAIN=$(echo "$RESPONSE" | jq -r '.Distribution.DomainName')
  echo "Created distribution: $DIST_ID ($DIST_DOMAIN)"
else
  echo "==> Reusing existing distribution: $DIST_ID"
  DIST_DOMAIN=$(aws cloudfront get-distribution --id "$DIST_ID" \
    --query 'Distribution.DomainName' --output text)
fi

DIST_ARN="arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${DIST_ID}"

# ---------------------------------------------------------------------------
# 4. Bucket policy so CloudFront can read
# ---------------------------------------------------------------------------
echo "==> Applying bucket policy"
cat > /tmp/bra-bucket-policy.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowCloudFrontRead",
    "Effect": "Allow",
    "Principal": { "Service": "cloudfront.amazonaws.com" },
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::${BUCKET}/*",
    "Condition": { "StringEquals": { "AWS:SourceArn": "${DIST_ARN}" } }
  }]
}
JSON

aws s3api put-bucket-policy --bucket "$BUCKET" --policy file:///tmp/bra-bucket-policy.json

# ---------------------------------------------------------------------------
# 5. Invalidate so updates show up immediately
# ---------------------------------------------------------------------------
echo "==> Invalidating CloudFront cache"
aws cloudfront create-invalidation \
  --distribution-id "$DIST_ID" \
  --paths "/*" >/dev/null

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo
echo "================================================================"
echo " Deployed."
echo
echo "  Bucket:         s3://$BUCKET"
echo "  Distribution:   $DIST_ID"
echo "  URL:            https://$DIST_DOMAIN/"
echo
echo " First deploys take ~5 minutes for the distribution to finish"
echo " propagating. After that, open the URL above."
echo
echo " Re-deploy after editing files: ./deploy.sh $BUCKET $REGION"
echo "================================================================"
