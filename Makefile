.PHONY: help deps provision deploy backup restore

VAULT_PASS_FILE ?= .vault-pass
ANSIBLE_OPTS    ?=

ifdef VAULT_PASS_FILE
  _VAULT = --vault-password-file $(VAULT_PASS_FILE)
endif

help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "  deps       Install Ansible Galaxy collections"
	@echo "  provision  Full server provisioning (first run)"
	@echo "  deploy     Deploy latest code"
	@echo "  backup     Trigger a backup on the server"
	@echo "  restore    Restore last backup (add TIMESTAMP=YYYYMMDD_HHMMSS to target specific)"
	@echo ""
	@echo "Set VAULT_PASS_FILE=path/to/file to supply the vault password (default: .vault-pass)"

deps:
	ansible-galaxy collection install -r requirements.yml

provision:
	ansible-playbook $(_VAULT) $(ANSIBLE_OPTS) playbooks/provision.yml

deploy:
	ansible-playbook $(_VAULT) $(ANSIBLE_OPTS) playbooks/deploy.yml

backup:
	ansible-playbook $(_VAULT) $(ANSIBLE_OPTS) playbooks/backup.yml

restore:
	ansible-playbook $(_VAULT) $(ANSIBLE_OPTS) playbooks/restore.yml \
	  $(if $(TIMESTAMP),-e restore_timestamp=$(TIMESTAMP),)
