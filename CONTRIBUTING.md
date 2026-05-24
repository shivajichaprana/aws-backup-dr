# Contributing to aws-backup-dr

Thanks for your interest in improving this project. This guide explains how to set up
your environment, the quality bar for changes, and how to get a change merged.

## Ground rules

- **Safety over features.** This repository manages backups and disaster recovery.
  Changes that could weaken immutability, retention, or recoverability require explicit
  justification and review.
- **Never commit secrets or real account data.** No real AWS account IDs, ARNs, access
  keys, bucket names, or `terraform.tfvars`. Use the documented placeholders
  (`123456789012`, `<your-tfstate-bucket-name>`, `app.example.com`). `terraform.tfvars`
  and build artifacts are gitignored — keep it that way.
- **Infrastructure changes ship with their docs.** If you change behaviour, update the
  relevant file in `docs/` or `runbooks/` in the same PR.

## Prerequisites

- Terraform ≥ 1.5 (CI pins 1.9.8)
- AWS provider ≥ 5.0
- Python 3.12 (for the Lambdas and test suite)
- `tflint` and `checkov` for local static analysis (optional but recommended)

## Local setup

```bash
# Clone and enter the repo
git clone https://github.com/shivajichaprana/aws-backup-dr.git
cd aws-backup-dr

# Configure your inputs (never commit this file)
cp terraform/terraform.tfvars.example terraform/terraform.tfvars

# Initialize and validate
make init
make validate

# Install Python test dependencies
make test-deps
```

## Before you open a PR

Run the full local quality gate — this mirrors the CI in
`.github/workflows/backup-ci.yml`:

```bash
make fmt        # terraform fmt -recursive (auto-format)
make validate   # terraform validate
make lint       # tflint + checkov
make test       # pytest on the Lambda handlers (moto-mocked)
```

All four must pass. CI runs `terraform fmt -check`, so format before pushing.

## Commit conventions

Commits follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <imperative summary>
```

Common types: `feat`, `fix`, `docs`, `test`, `ci`, `refactor`, `chore`. Examples:

```
feat(backup): add FSx to the critical backup plan
fix(restore-tester): handle empty recovery-point list without erroring
docs(dr-strategy): clarify vault-lock rollout steps
```

Keep commits focused and the working tree clean (no `terraform.tfvars`, no `.build/`
artifacts).

## Pull requests

1. Branch from `main`.
2. Make your change with accompanying tests and docs.
3. Ensure the local quality gate passes.
4. Open the PR with a clear description of *what* changed and *why*, plus the output of
   `terraform plan` if the change affects infrastructure.
5. A maintainer will review. Address feedback by pushing additional commits.

## Reporting issues

- **Bugs / features:** open an issue or start a Discussion in the repository.
- **Security vulnerabilities:** do **not** open a public issue. Report privately via a
  [GitHub Security Advisory](https://github.com/shivajichaprana/aws-backup-dr/security/advisories/new).

## Code of conduct

Be respectful and constructive. Assume good intent, give specific feedback, and keep
discussions focused on the work.

## License

By contributing, you agree that your contributions are licensed under the MIT License,
the same license that covers this project (see [LICENSE](LICENSE)).
