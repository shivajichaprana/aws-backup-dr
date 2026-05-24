# =============================================================================
# aws-backup-dr — Makefile
# =============================================================================
# Thin, well-documented wrappers around the Terraform and Python workflows so
# that local development mirrors CI (.github/workflows/backup-ci.yml).
#
# Usage:  make <target>     |  make help to list everything.
# =============================================================================

TF_DIR        := terraform
LAMBDA_DIR    := lambda
TESTS_DIR     := tests
PYTHON        ?= python3
TF            ?= terraform

# Pass extra args through, e.g.  make plan ARGS="-target=aws_backup_plan.standard"
ARGS ?=

.DEFAULT_GOAL := help

.PHONY: help init fmt fmt-check validate lint test test-deps plan apply destroy docs clean

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

init: ## terraform init (with backend if configured)
	cd $(TF_DIR) && $(TF) init $(ARGS)

fmt: ## Auto-format all Terraform files
	$(TF) fmt -recursive $(TF_DIR)

fmt-check: ## Check formatting (CI parity — fails on unformatted files)
	$(TF) fmt -check -recursive $(TF_DIR)

validate: ## terraform validate
	cd $(TF_DIR) && $(TF) validate

lint: ## Static analysis: tflint + checkov (skips gracefully if not installed)
	@command -v tflint >/dev/null 2>&1 && (cd $(TF_DIR) && tflint) || echo "tflint not installed — skipping"
	@command -v checkov >/dev/null 2>&1 && checkov -d $(TF_DIR) --quiet --compact || echo "checkov not installed — skipping"

test-deps: ## Install Python test dependencies
	$(PYTHON) -m pip install -r $(TESTS_DIR)/requirements.txt

test: ## Run the Lambda unit tests (moto-mocked)
	cd $(TESTS_DIR) && $(PYTHON) -m pytest -q

plan: ## terraform plan
	cd $(TF_DIR) && $(TF) plan $(ARGS)

apply: ## terraform apply
	cd $(TF_DIR) && $(TF) apply $(ARGS)

destroy: ## terraform destroy (refused while vault lock / prevent_destroy is active)
	cd $(TF_DIR) && $(TF) destroy $(ARGS)

docs: ## List the documentation set
	@echo "Documentation:"
	@echo "  README.md                      — overview, architecture, quick start"
	@echo "  docs/architecture.md           — component map and design decisions"
	@echo "  docs/dr-strategy.md            — threat model, RPO/RTO, rollout"
	@echo "  runbooks/restore-from-backup.md — manual data recovery"
	@echo "  runbooks/dr-failover.md        — regional DNS failover"

clean: ## Remove local Terraform + build artifacts
	rm -rf $(TF_DIR)/.terraform $(TF_DIR)/.build $(TF_DIR)/*.tfplan
	find . -type d -name __pycache__ -prune -exec rm -rf {} +
	find . -type d -name '.pytest_cache' -prune -exec rm -rf {} +
