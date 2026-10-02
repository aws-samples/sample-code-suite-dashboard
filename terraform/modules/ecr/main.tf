resource "aws_ecr_repository" "this" {
  name         = var.name
  force_delete = var.force_delete

  image_scanning_configuration {
    scan_on_push = var.scan_on_push
  }

  # checkov:skip=CKV_AWS_136: AWS-managed AES256 encryption is on by default.
  # CMK encryption is unnecessary for public demo container images.
  # checkov:skip=CKV_AWS_51: Tag mutability is intentional for demo workflows
  # where samples push to fixed tags like `latest` during iteration. Promote
  # to IMMUTABLE before any production use.
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last ${var.keep_last_n_images} images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = var.keep_last_n_images
      }
      action = { type = "expire" }
    }]
  })
}
