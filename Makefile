SHELL        := /bin/bash
TF_DIR       := terraform
ANSIBLE_DIR  := ansible
KEYS_DIR     := keys
VENV         := .venv
VENV_ABS     := $(abspath $(VENV))
PY           := $(VENV_ABS)/bin/python
PIP          := $(VENV_ABS)/bin/pip
AP           := $(VENV_ABS)/bin/ansible-playbook
AG           := $(VENV_ABS)/bin/ansible-galaxy
AL           := $(VENV_ABS)/bin/ansible-lint
AV           := $(VENV_ABS)/bin/ansible-vault
VAULT_PASS   := ~/.vault_pass
AWS_PROFILE  ?= SA_Standard_Access-491489166083

.DEFAULT_GOAL := help
.PHONY: help setup install-terraform keys init plan apply provision provision-check deploy destroy \
        lint lint-tf lint-ansible vault-init vault-create vault-edit clean _tf_outputs _ssh_cfg _my_ip

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

_my_ip:
	$(eval MY_IP := $(shell curl -sf --max-time 5 https://ifconfig.me || curl -sf --max-time 5 https://api.ipify.org || curl -sf --max-time 5 https://checkip.amazonaws.com | tr -d '[:space:]'))
	@[ -n "$(MY_IP)" ] || (echo "ERROR: Could not detect public IP"; exit 1)
	@echo "  Using admin_cidr: $(MY_IP)/32"

init: ## Terraform init
	cd $(TF_DIR) && terraform init

plan: _my_ip ## Terraform plan (requires terraform.tfvars)
	cd $(TF_DIR) && terraform plan -var-file="terraform.tfvars" -var "admin_cidr=$(MY_IP)/32"

apply: _my_ip ## Terraform apply (auto-detects current public IP for admin_cidr)
	cd $(TF_DIR) && terraform apply -var-file="terraform.tfvars" -var "admin_cidr=$(MY_IP)/32" -auto-approve

destroy: _my_ip ## Tear down all infrastructure (DESTRUCTIVE)
	cd $(TF_DIR) && terraform destroy -var-file="terraform.tfvars" -var "admin_cidr=$(MY_IP)/32" -auto-approve

# ── Ansible ────────────────────────────────────────────────────────────────────

_tf_outputs:
	$(eval BASTION_IP    := $(shell cd $(TF_DIR) && terraform output -raw bastion_public_ip 2>/dev/null))
	$(eval APPS_ALB_DNS  := $(shell cd $(TF_DIR) && terraform output -raw apps_alb_dns 2>/dev/null))
	$(eval KONG_ADMIN_URL := $(shell cd $(TF_DIR) && terraform output -raw kong_admin_url 2>/dev/null))
	$(eval NGINX_ALB_DNS := $(shell cd $(TF_DIR) && terraform output -raw nginx_alb_dns 2>/dev/null))
	@if [ -z "$(BASTION_IP)" ]; then \
		echo "ERROR: Could not read Terraform outputs. Run 'make apply' first."; exit 1; fi

_ssh_cfg: _tf_outputs
	@rm -f /tmp/ansible-ssh-* 2>/dev/null; true
	@printf 'Host *\n\tStrictHostKeyChecking no\n\tUserKnownHostsFile /dev/null\n\tIdentityFile $(CURDIR)/$(KEYS_DIR)/lab_key\n\nHost 10.0.*.*\n\tProxyJump ec2-user@$(BASTION_IP)\n' > /tmp/lab-ssh.cfg

provision: _ssh_cfg ## Run Ansible playbooks against live infrastructure
	cd $(ANSIBLE_DIR) && \
		AWS_PROFILE=$(AWS_PROFILE) $(AP) site.yml \
		--vault-password-file $(VAULT_PASS) \
		--private-key ../$(KEYS_DIR)/lab_key \
		--ssh-common-args="-F /tmp/lab-ssh.cfg" \
		--extra-vars "apps_alb_dns=$(APPS_ALB_DNS) kong_admin_url=$(KONG_ADMIN_URL) nginx_alb_dns=$(NGINX_ALB_DNS)"

provision-check: _ssh_cfg ## Dry-run Ansible (--check mode)
	cd $(ANSIBLE_DIR) && \
		AWS_PROFILE=$(AWS_PROFILE) $(AP) site.yml \
		--vault-password-file $(VAULT_PASS) \
		--private-key ../$(KEYS_DIR)/lab_key \
		--ssh-common-args="-F /tmp/lab-ssh.cfg" \
		--extra-vars "apps_alb_dns=$(APPS_ALB_DNS) kong_admin_url=$(KONG_ADMIN_URL) nginx_alb_dns=$(NGINX_ALB_DNS)" \
		--check --diff

vault-init: ## Create ~/.vault_pass with a random password (run once, keep it safe)
	@if [ -f $(VAULT_PASS) ]; then \
		echo "$(VAULT_PASS) already exists — skipping."; \
	else \
		python3 -c "import secrets, string; print(secrets.token_urlsafe(32))" > $(VAULT_PASS); \
		chmod 600 $(VAULT_PASS); \
		echo "Created $(VAULT_PASS) — back this up somewhere safe (password manager)."; \
		echo "Password: $$(cat $(VAULT_PASS))"; \
	fi

vault-create: vault-init ## Create ansible/vault.yml from example and encrypt it
	@if [ -f $(ANSIBLE_DIR)/vault.yml ]; then \
		if head -1 $(ANSIBLE_DIR)/vault.yml | grep -q '^\$$ANSIBLE_VAULT'; then \
			echo "ansible/vault.yml already exists and is encrypted. Use make vault-edit."; \
		else \
			echo "ansible/vault.yml exists but is NOT encrypted. Encrypting now..."; \
			$(AV) encrypt $(ANSIBLE_DIR)/vault.yml --vault-password-file $(VAULT_PASS) && \
			echo "ansible/vault.yml is now encrypted."; \
		fi \
	else \
		cp $(ANSIBLE_DIR)/vault.yml.example $(ANSIBLE_DIR)/vault.yml && \
		$(AV) encrypt $(ANSIBLE_DIR)/vault.yml --vault-password-file $(VAULT_PASS) && \
		echo "ansible/vault.yml created and encrypted."; \
	fi

vault-edit: ## Edit encrypted ansible/vault.yml
	@[ -f $(VAULT_PASS) ] || (echo "Run 'make vault-init' first."; exit 1)
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
