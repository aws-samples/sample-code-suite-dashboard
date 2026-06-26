# -----------------------------------------------------------------------------
# Seed each CodeCommit repo with the matching folder under sample-apps/.
# Without an initial commit on `main`, the pipeline has no source to consume
# and won't run, so this is what makes the sample stack truly demo-ready.
# -----------------------------------------------------------------------------

resource "null_resource" "seed" {
  for_each = var.samples

  # Re-seed whenever any file in the sample app changes.
  triggers = {
    repo_name = aws_codecommit_repository.this[each.key].repository_name
    source_hash = sha256(join("", [
      for f in fileset("${path.module}/sample-apps/${each.value.source_dir}", "**") :
      filesha256("${path.module}/sample-apps/${each.value.source_dir}/${f}")
    ]))
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      WORKDIR="$(mktemp -d)"
      trap 'rm -rf "$WORKDIR"' EXIT

      cp -R "${path.module}/sample-apps/${each.value.source_dir}/." "$WORKDIR/"

      cd "$WORKDIR"
      git init -q -b main
      git -c user.email=terraform@sample-pipelines.local \
          -c user.name=terraform \
          add .
      git -c user.email=terraform@sample-pipelines.local \
          -c user.name=terraform \
          commit -q -m "Seed ${each.key} sample app"

      # Push using the git-codecommit HTTPS helper. Requires the operator to
      # have configured `aws codecommit` credential helper or AWS_PROFILE.
      git push -q --force \
        "codecommit::${var.aws_region}://${aws_codecommit_repository.this[each.key].repository_name}" \
        main
    EOT
  }

  depends_on = [aws_codecommit_repository.this]
}
