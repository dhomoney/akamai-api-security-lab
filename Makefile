SHELL        := /bin/bash
TF_DIR       := terraform
ANSIBLE_DIR  := ansible
KEYS_DIR     := keys
VENV         := .venv
PY           := $(VENV)/bin/python
PIP          := $(VENV)/bin/pip
AP           := $(VENV)/bin/ansible-playbook
AG           := $(VENV)/bin/ansible-galaxy
AL           := $(VENV)/bin/ansible-lint
AV           := $(VENV)/bin/ansible-vault
VAULT_PASS   := ~/.vault_pass

.DEFAULT_GOAL := help
.PHONY: help setup install-terraform keys init plan apply provision deploy destroy \
        lint lint-tf lint-ansible vault-edit vault-create clean

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-22s\033[0m %s\n", $$1, $$2}'

# ── Setup ──────────────────────────────────────────────────────────────────────

setup: ## Create venv and install Ansible + Galaxy requirements
	python3 -m venv $(VENV)
	$(PIP) install --upgrade pip ansible ansible-lint boto3 botocore
	$(AG) install -r $(ANSIBLE_DIR)/requirements.yml --force
	@echo ""
	@echo "Setup complete. If you haven't yet, run: make install-terraform && make keys"

install-terraform: ## Download and install Terraform (latest) to /usr/local/bin
	@LATEST=$$(curl -s https://api.releases.hashicorp.com/v1/releases/terraform/latest | python3 -c "import sys,json; print(json.load(sys.stdin)['version'])"); \
	echo "Installing Terraform $$LATEST..."; \
	curl -sLo /tmp/tf.zip "https://releases.hashicorp.com/terraform/$${LATEST}/terraform_$${LATEST}_linux_amd64.zip"; \
	unzip -o /tmp/tf.zip -d /tmp/tf_bin; \
	sudo mv /tmp/tf_bin/terraform /usr/local/bin/terraform; \
	rm -rf /tmp/tf.zip /tmp/tf_bin; \
	terraform version

keys: ## Generate ED25519 SSH keypair for lab instances
	@mkdir -p $(KEYS_DIR)
	@if [ -f $(KEYS_DIR)/lab_key ]; then \
		echo "Keys already exist at $(KEYS_DIR)/lab_key. Delete them to regenerate."; \
	else \
		ssh-keygen -t ed25519 -f $(KEYS_DIR)/lab_key -N "" -C "akamai-api-security-lab"; \
		chmod 600 $(KEYS_DIR)/lab_key; \
		echo "Keys generated. lab_key is in .gitignore — keep it safe."; \
	fi

# ── Terraform ──────────────────────────────────────────────────────────────────

init: ## Terraform init
	cd $(TF_DIR) && terraform init

plan: ## Terraform plan (requires terraform.tfvars)
	cd $(TF_DIR) && terraform plan -var-file="terraform.tfvars"

apply: ## Terraform apply
	cd $(TF_DIR) && terraform apply -var-file="terraform.tfvars" -auto-approve

destroy: ## Tear down all infrastructure (DESTRUCTIVE)
	cd $(TF_DIR) && terraform destroy -var-file="terraform.tfvars" -auto-approve

# ── Ansible ────────────────────────────────────────────────────────────────────

provision: ## Run Ansible playbooks against live infrastructure
	cd $(ANSIBLE_DIR) && \
		AWS_PROFILE=$(AWS_PROFILE) $(AP) site.yml \
		--vault-password-file $(VAULT_PASS) \
		--private-key ../$(KEYS_DIR)/lab_key

provision-check: ## Dry-run Ansible (--check mode)
	cd $(ANSIBLE_DIR) && \
		AWS_PROFILE=$(AWS_PROFILE) $(AP) site.yml \
		--vault-password-file $(VAULT_PASS) \
		--private-key ../$(KEYS_DIR)/lab_key \
		--check --diff

vault-create: ## Create ansible/vault.yml from example and encrypt it
	@if [ -f $(ANSIBLE_DIR)/vault.yml ]; then \
		echo "ansible/vault.yml already exists. Use make vault-edit to modify it."; \
	else \
		cp $(ANSIBLE_DIR)/vault.yml.example $(ANSIBLE_DIR)/vault.yml; \
		$(AV) encrypt $(ANSIBLE_DIR)/vault.yml --vault-password-file $(VAULT_PASS); \
		echo "ansible/vault.yml created and encrypted."; \
	fi

vault-edit: ## Edit encrypted ansible/vault.yml
	$(AV) edit $(ANSIBLE_DIR)/vault.yml --vault-password-file $(VAULT_PASS)

# ── Full lifecycle ─────────────────────────────────────────────────────────────

deploy: init apply provision ## Full deployment: init → apply → provision

# ── Linting ────────────────────────────────────────────────────────────────────

lint: lint-tf lint-ansible ## Run all linters

lint-tf: ## Check Terraform formatting and validate
	cd $(TF_DIR) && terraform fmt -check -recursive
	cd $(TF_DIR) && terraform validate
	@which tflint > /dev/null 2>&1 && tflint --chdir=$(TF_DIR) --recursive || \
		echo "tflint not installed — skipping (optional)"

lint-ansible: ## Run ansible-lint
	$(AL) $(ANSIBLE_DIR)/site.yml

# ── Cleanup ────────────────────────────────────────────────────────────────────

clean: ## Remove venv and Terraform cache (does NOT destroy infrastructure)
	rm -rf $(VENV) $(TF_DIR)/.terraform
	@echo "Cleaned. Infrastructure (if any) is still running — use 'make destroy' first."
