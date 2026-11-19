# ───────────────────────────────────────────────
# ecr.tf: private image registry for the app
# ───────────────────────────────────────────────

resource "aws_ecr_repository" "app" {
  for_each = toset(var.ecr_repos)

  name                 = each.value
  image_tag_mutability = "IMMUTABLE" # a tag like v1 can never be overwritten
  force_delete         = true        # terraform destroy works even with images inside

  image_scanning_configuration {
    scan_on_push = true # scan every pushed image for vulnerabilities
  }
}
