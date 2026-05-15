# Deploying the BRA portal POC to S3 + CloudFront

This is a static site — HTML, CSS, SVG, and the local copy of `@govtech-bb/styles`. No build step, no server, no environment variables. The whole bucket is **under 1 MB**.

End-state: a public HTTPS URL like `https://d123abc456def.cloudfront.net/` that loads the prototype with zero external dependencies.

---

## Prerequisites

1. AWS CLI configured with credentials that can create S3 buckets and CloudFront distributions.
2. A unique bucket name. The examples below use `bra-portal-poc` — replace that with something globally unique (S3 bucket names are global).

```sh
BUCKET=bra-portal-poc-<your-initials>
REGION=us-east-1
SITE_DIR=.   # run these commands from the BRAportal folder
```

---

## 1. Create the S3 bucket

```sh
aws s3api create-bucket \
  --bucket "$BUCKET" \
  --region "$REGION"
```

`us-east-1` doesn't take a `LocationConstraint`. For any other region, add:

```sh
  --create-bucket-configuration LocationConstraint=$REGION
```

Block direct public access (CloudFront will reach the bucket via Origin Access Control, not the public S3 URL):

```sh
aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

---

## 2. Upload the site

From the `BRAportal/` folder:

```sh
aws s3 sync "$SITE_DIR" "s3://$BUCKET/" \
  --exclude ".DS_Store" \
  --exclude "*.md" \
  --exclude "tamis-pdfs/*" \
  --delete
```

Set sensible cache headers per file type so CloudFront caches CSS/fonts long but HTML stays fresh:

```sh
# HTML: short cache so updates propagate fast during POC
aws s3 cp "s3://$BUCKET/" "s3://$BUCKET/" \
  --recursive --exclude "*" --include "*.html" \
  --metadata-directive REPLACE \
  --cache-control "public, max-age=60" \
  --content-type "text/html; charset=utf-8"

# CSS, JS, SVG, fonts: cache for a week
aws s3 cp "s3://$BUCKET/" "s3://$BUCKET/" \
  --recursive --exclude "*" --include "*.css" --include "*.svg" --include "*.woff2" \
  --metadata-directive REPLACE \
  --cache-control "public, max-age=604800, immutable"
```

---

## 3. Create the CloudFront distribution

The easiest path is the console (Origin: your S3 bucket, Origin Access: "Origin access control settings (recommended)", Default root object: `index.html`, Viewer protocol policy: Redirect HTTP to HTTPS, Compress objects automatically: Yes). It takes ~5 minutes for the distribution to deploy.

CLI version — create the OAC first, then the distribution:

```sh
# 1. Origin Access Control so CloudFront can read the private bucket
OAC_ID=$(aws cloudfront create-origin-access-control \
  --origin-access-control-config \
    "Name=$BUCKET-oac,SigningProtocol=sigv4,SigningBehavior=always,OriginAccessControlOriginType=s3" \
  --query 'OriginAccessControl.Id' --output text)
echo "OAC: $OAC_ID"

# 2. Distribution config (save the JSON below as distribution.json, then run create-distribution)
```

Save this as `distribution.json` (replace `$BUCKET` and `$OAC_ID`):

```json
{
  "CallerReference": "bra-portal-poc-1",
  "Comment": "BRA portal POC",
  "Enabled": true,
  "DefaultRootObject": "index.html",
  "Origins": {
    "Quantity": 1,
    "Items": [
      {
        "Id": "s3-origin",
        "DomainName": "$BUCKET.s3.$REGION.amazonaws.com",
        "S3OriginConfig": { "OriginAccessIdentity": "" },
        "OriginAccessControlId": "$OAC_ID"
      }
    ]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "s3-origin",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": { "Quantity": 2, "Items": ["GET","HEAD"] },
    "Compress": true,
    "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6"
  },
  "ViewerCertificate": { "CloudFrontDefaultCertificate": true },
  "PriceClass": "PriceClass_100"
}
```

`658327ea-f89d-4fab-a63d-7e88639e58f6` is AWS's managed `CachingOptimized` policy. `PriceClass_100` keeps cost down by serving from US/EU/Canada edges only — fine for a POC.

```sh
aws cloudfront create-distribution --distribution-config file://distribution.json
```

The response includes `DomainName` (e.g. `d123abc456def.cloudfront.net`) — that's your public URL.

---

## 4. Allow CloudFront to read the bucket

Get the distribution ARN from the previous step's response (or with `aws cloudfront list-distributions`). Then attach this bucket policy:

```sh
DIST_ARN=arn:aws:cloudfront::<account-id>:distribution/<distribution-id>

cat > bucket-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowCloudFrontRead",
    "Effect": "Allow",
    "Principal": { "Service": "cloudfront.amazonaws.com" },
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::$BUCKET/*",
    "Condition": { "StringEquals": { "AWS:SourceArn": "$DIST_ARN" } }
  }]
}
EOF

aws s3api put-bucket-policy --bucket "$BUCKET" --policy file://bucket-policy.json
```

Wait ~5 minutes for the distribution to finish deploying (`Status: Deployed` in the console), then open the CloudFront domain in a browser.

---

## 5. Iterating: re-deploy after changes

Edit files locally, then:

```sh
aws s3 sync "$SITE_DIR" "s3://$BUCKET/" \
  --exclude ".DS_Store" --exclude "*.md" --exclude "tamis-pdfs/*" --delete

# Invalidate the HTML so the new version loads immediately
aws cloudfront create-invalidation \
  --distribution-id <distribution-id> \
  --paths "/*.html" "/"
```

CloudFront gives you 1,000 free invalidation paths per month — plenty for POC iteration.

---

## What's left to add for a real launch

- **Clean URLs** (e.g. `/sign-in` instead of `/sign-in.html`): add a tiny CloudFront Function on the `viewer-request` event that appends `.html` when the path has no extension.
- **Custom domain** (e.g. `alpha.bra.gov.bb`): request an ACM certificate in `us-east-1`, attach it to the distribution, and add a Route 53 alias record.
- **404 page**: add a `404.html`, then in CloudFront set a custom error response for HTTP 403/404 → `/404.html`.
- **Form persistence**: the prototype's forms currently lose state between pages because the bucket is fully static. The next step is small client-side `localStorage` writes from each page, replayed on Check Your Answers.

---

## Cost estimate

| Item | Cost |
|---|---|
| S3 storage (~1 MB) | < $0.01/month |
| S3 requests | < $0.10/month |
| CloudFront egress (POC traffic) | Free for the first 1 TB and 10 M requests in year 1; ~$0.085/GB after |
| Route 53 hosted zone (if used) | $0.50/month |

Realistic total for a POC seen by a few dozen people: **near zero**.
