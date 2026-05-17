.PHONY: help deps setup deploy backup restore

VAULT_PASS_FILE ?= .vault-pass

ifdef VAULT_PASS_FILE
  _VAULT := --vault-password-file $(VAULT_PASS_FILE)
endif

ifdef VERBOSE
  _V := -v
endif

ifdef TAGS
  _TAGS := --tags $(TAGS)
endif

# ── SITE=ORG/REPO:BRANCH parsing ──────────────────────────────────────────────
# Example: SITE=AtheerSolutions/castlegroup:dev
ifdef SITE
  _GH_PATH   := $(firstword $(subst :, ,$(SITE)))
  _BRANCH    := $(lastword $(subst :, ,$(SITE)))
  _ORG       := $(firstword $(subst /, ,$(_GH_PATH)))
  _REPO      := $(lastword $(subst /, ,$(_GH_PATH)))
  _EXTRA     := -e github_org=$(_ORG) -e github_repo=$(_REPO) -e repo_branch=$(_BRANCH)
  ifneq ($(wildcard sites/$(_REPO)/vars.yml),)
    _EXTRA   += -e @sites/$(_REPO)/vars.yml
  endif
  ifneq ($(wildcard sites/$(_REPO)/vault.yml),)
    _EXTRA   += -e @sites/$(_REPO)/vault.yml
  endif
endif

ifdef DOMAIN
  _EXTRA     += -e domain=$(DOMAIN)
endif

ifdef EMAIL
  _EXTRA     += -e certbot_email=$(EMAIL)
endif

_AP := ansible-playbook $(_VAULT) $(_V) $(_TAGS)

# ── Targets ───────────────────────────────────────────────────────────────────
help:
	@echo ""
	@echo "  Usage:"
	@echo ""
	@echo "    make setup                         Install server software (first run)"
	@echo "    make setup SITE=ORG/REPO:BRANCH    Set up an application site"
	@echo "    make deploy SITE=ORG/REPO:BRANCH   Deploy latest code"
	@echo "    make backup SITE=ORG/REPO:BRANCH   Trigger a manual backup"
	@echo "    make restore SITE=ORG/REPO:BRANCH  Restore last backup"
	@echo "    make deps                          Install Ansible Galaxy collections"
	@echo ""
	@echo "  Options:"
	@echo "    DOMAIN=example.com           Domain for the site (vhost + TLS)"
	@echo "    EMAIL=you@example.com        Email for Let's Encrypt notifications"
	@echo "    VERBOSE=1                    Show full task output (-v)"
	@echo "    TIMESTAMP=YYYYMMDD_HHMMSS   Restore a specific snapshot"
	@echo "    VAULT_PASS_FILE=path         Vault password file (default: .vault-pass)"
	@echo ""
	@echo "  Workflow:"
	@echo "    1. make setup"
	@echo "    2. Create sites/<repo>/vault.yml  (db_pass) and encrypt it"
	@echo "    3. make setup SITE=AtheerSolutions/castlegroup:dev DOMAIN=example.com EMAIL=you@example.com"
	@echo "    4. make deploy SITE=AtheerSolutions/castlegroup:dev"
	@echo ""

deps:
	ansible-galaxy collection install -r requirements.yml

setup:
ifdef SITE
	$(_AP) $(_EXTRA) playbooks/site-setup.yml
else
	$(_AP) playbooks/server-setup.yml
endif

deploy:
	@[ -n "$(SITE)" ] || { echo "Error: SITE is required.  Usage: make deploy SITE=ORG/REPO:BRANCH"; exit 1; }
	$(_AP) $(_EXTRA) playbooks/deploy.yml

backup:
	@[ -n "$(SITE)" ] || { echo "Error: SITE is required.  Usage: make backup SITE=ORG/REPO:BRANCH"; exit 1; }
	$(_AP) $(_EXTRA) playbooks/backup.yml

restore:
	@[ -n "$(SITE)" ] || { echo "Error: SITE is required.  Usage: make restore SITE=ORG/REPO:BRANCH"; exit 1; }
	$(_AP) $(_EXTRA) playbooks/restore.yml \
	  $(if $(TIMESTAMP),-e restore_timestamp=$(TIMESTAMP),)
