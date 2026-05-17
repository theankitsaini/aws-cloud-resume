# =================================================================
# 1. PROVIDER & S3 BUCKET CONFIGURATION (From Step 1.2)
# =================================================================

provider "aws" {
  region = "eu-west-1" # Highly valued region for Dutch compliance (GDPR/Data Residency)
}

/*resource "aws_s3_bucket" "resume_bucket" {
  bucket        = "yourname-dutch-cloud-resume-2026" # Must be completely unique globally
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "resume_bucket_privacy" {
  bucket = aws_s3_bucket.resume_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# =================================================================
# 2. CLOUDFRONT OAC & DELIVERY CONFIGURATION (From Step 1.3)
# =================================================================

# This creates the secure lock/key configuration identifier
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "s3-resume-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# This creates the actual global CDN distribution network
resource "aws_cloudfront_distribution" "cdn" {
  origin {
    domain_name              = aws_s3_bucket.resume_bucket.bucket_regional_domain_name
    origin_id                = "S3Origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  enabled             = true
  default_root_object = "index.html"

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "S3Origin"
    viewer_protocol_policy = "redirect-to-https" # Enforces security, a must-have for Dutch banks

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true 
  }
}

# This attaches a policy to S3 saying: "Only accept traffic coming from our CloudFront CDN"
resource "aws_s3_bucket_policy" "allow_cloudfront" {
  bucket = aws_s3_bucket.resume_bucket.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudFrontServicePrincipalReadOnly"
        Effect    = "Allow"
        Principal = { Service = "://amazonaws.com" }
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.resume_bucket.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.cdn.arn
          }
        }
      }
    ]
  })
}
*/
resource "aws_dynamodb_table" "visitor_counter" {
  name         = "visitor-count-table"
  billing_mode = "PROVISIONED" # Explicitly choose provisioned to stay in Free Tier
  read_capacity  = 1
  write_capacity = 1
  hash_key       = "id"

  attribute {
    name = "id"
    type = "S"
  }
}

# Packages the python file into a zip automatically
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/counter.py"
  output_path = "${path.module}/lambda/counter.zip"
}

# IAM Role for Lambda
resource "aws_iam_role" "lambda_role" {
  name = "resume_lambda_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { 
        Service = "lambda.amazonaws.com" 
      }
    }]
  })
}


# IAM Policy allowing Lambda to talk to DynamoDB and write logs
resource "aws_iam_policy" "lambda_policy" {
  name = "resume_lambda_policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:UpdateItem", "dynamodb:GetItem"]
        Resource = aws_dynamodb_table.visitor_counter.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

resource "aws_lambda_function" "counter_func" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "visitor-counter-backend"
  role             = aws_iam_role.lambda_role.arn
  handler          = "counter.lambda_handler"
  runtime          = "python3.11"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
}

# HTTP API Gateway (Cheaper & faster than REST API, perfect for Free Tier)
resource "aws_apigatewayv2_api" "http_api" {
  name          = "visitor-counter-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id           = aws_apigatewayv2_api.http_api.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.counter_func.invoke_arn
}

resource "aws_apigatewayv2_route" "api_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "GET /counter"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_apigatewayv2_stage" "api_stage" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "api_gw_permission" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.counter_func.function_name
  principal     = "apigateway.amazonaws.com" # <--- FIXED HERE
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}


output "api_url" {
  value = "${aws_apigatewayv2_api.http_api.api_endpoint}/counter"
}
