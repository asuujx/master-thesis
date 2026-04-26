data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "artifacts" {
  bucket        = "thesis-test-artifacts-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_iam_role" "codebuild" {
  name = "thesis-codebuild-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "codebuild" {
  role = aws_iam_role.codebuild.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${aws_s3_bucket.artifacts.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.artifacts.arn
      }
    ]
  })
}

resource "aws_codebuild_project" "playwright" {
  name         = "thesis-playwright-tests"
  service_role = aws_iam_role.codebuild.arn

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/standard:7.0"
    type         = "LINUX_CONTAINER"

    environment_variable {
      name  = "BASE_URL"
      value = "PLACEHOLDER"
    }

    environment_variable {
      name  = "ITERATION"
      value = "1"
    }

    environment_variable {
      name  = "CLOUD_PROVIDER"
      value = "aws"
    }

    environment_variable {
      name  = "ENVIRONMENT"
      value = "eks"
    }

    environment_variable {
      name  = "ARTIFACTS_BUCKET"
      value = aws_s3_bucket.artifacts.bucket
    }
  }

  source {
    type            = "GITHUB"
    location        = var.github_repo
    git_clone_depth = 1
    buildspec       = "pipelines/aws/buildspec.yml"
  }
}

resource "aws_codebuild_source_credential" "github" {
  auth_type   = "PERSONAL_ACCESS_TOKEN"
  server_type = "GITHUB"
  token       = var.github_token
}