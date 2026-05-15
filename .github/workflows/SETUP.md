# GitHub Actions → S3 + CloudFront setup

This pipeline deploys the BRA portal POC on every push to `main`. It uses **OIDC federation** so the repo doesn't hold any long-lived AWS keys.

One-time setup is about 10 minutes, all in the AWS console.

---

## 1. Add the GitHub OIDC provider in IAM (one-time, per AWS account)

If you don't already have one:

- IAM → Identity providers → **Add provider**
- Provider type: **OpenID Connect**
- Provider URL: `https://token.actions.githubusercontent.com`
- Audience: `sts.amazonaws.com`
- Click **Add provider**

(If a `token.actions.githubusercontent.com` provider already exists, skip this — you only need one per account.)

---

## 2. Create the deploy role

- IAM → Roles → **Create role**
- Trusted entity: **Web identity**
- Identity provider: `token.actions.githubusercontent.com`
- Audience: `sts.amazonaws.com`
- GitHub organisation: `gt`
- GitHub repository: `<your-repo-name>` (e.g. `bra-portal-poc`)
- GitHub branch: `main`
- Permissions: attach the inline policy below
- Role name: `bra-portal-deploy`

**Inline policy** (replace `<bucket>` and `<distribution-id>`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3Sync",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:GetObjectTagging",
        "s3:PutObjectTagging"
      ],
      "Resource": [
        "arn:aws:s3:::<bucket>",
        "arn:aws:s3:::<bucket>/*"
      ]
    },
    {
      "Sid": "CloudFrontInvalidate",
      "Effect": "Allow",
      "Action": [
        "cloudfront:CreateInvalidation",
        "cloudfront:GetInvalidation",
        "cloudfront:ListInvalidations"
      ],
      "Resource": "arn:aws:cloudfront::*:distribution/<distribution-id>"
    }
  ]
}
```

The **trust policy** AWS generates for you should already look like this — verify it before saving:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:gt/<your-repo-name>:ref:refs/heads/main"
      }
    }
  }]
}
```

Copy the role's **ARN** when it's created. It looks like `arn:aws:iam::123456789012:role/bra-portal-deploy`.

---

## 3. Configure the repo

In the GitHub repo: **Settings → Secrets and variables → Actions**.

**Repository variables** (Variables tab):

| Name | Value |
|---|---|
| `AWS_BUCKET` | your bucket name, e.g. `bra-portal-poc-cc` |
| `AWS_REGION` | e.g. `us-east-1` |
| `CLOUDFRONT_DISTRIBUTION_ID` | e.g. `E1ABCDEFGHIJK2` (find it in the CloudFront console) |

**Repository secrets** (Secrets tab):

| Name | Value |
|---|---|
| `AWS_DEPLOY_ROLE_ARN` | the role ARN from step 2 |

---

## 4. First deploy

Push to `main`, or click **Actions → Deploy to S3 + CloudFront → Run workflow**.

The job runs in ~30 seconds and prints the bucket + distribution ID in the summary.

---

## Troubleshooting

- **`Error: Could not assume role`** — the trust policy `sub` condition doesn't match. Double-check the repo name and branch.
- **`AccessDenied` on S3** — the inline policy bucket ARN doesn't match. Check the bucket name.
- **Site loads stale content** — CloudFront invalidations take ~30 seconds. Try a hard refresh.
- **Want to deploy from a non-main branch** — change the `sub` condition in the trust policy to `repo:gt/<repo>:*` (less strict) or add another `StringLike` for the branch.

---

## Fallback: long-lived access keys (not recommended)

If OIDC is too much hassle for the POC, create an IAM user with the same inline policy, generate access keys, and store them as repo secrets `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`. Then change the workflow's `Configure AWS credentials` step to:

```yaml
- name: Configure AWS credentials
  uses: aws-actions/configure-aws-credentials@v4
  with:
    aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
    aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
    aws-region: ${{ env.REGION }}
```

Works the same, but you're now rotating keys instead of nothing.
