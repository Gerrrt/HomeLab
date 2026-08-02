SHELL := /bin/bash
.DEFAULT_GOAL := help

STACK       ?= observability
STACK_DIR   := stacks/$(STACK)
COMPOSE     := docker compose -f $(STACK_DIR)/compose.yaml
SECRETS     := secrets/$(STACK).sops.yaml

.PHONY: help
help: ## Show this help
	@printf '\033[1mHomeLab\033[0m — make <target> [STACK=observability]\n\n'
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@printf '\n'

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

.PHONY: up
up: render ## Render config and start the stack
	$(COMPOSE) up -d --remove-orphans
	@printf '\n\033[0;32mup\033[0m — Grafana: http://localhost:$${GRAFANA_PORT:-3000}\n'

.PHONY: down
down: ## Stop the stack (volumes are preserved)
	$(COMPOSE) down --remove-orphans

.PHONY: restart
restart: down up ## Restart the stack

.PHONY: pull
pull: ## Pull the pinned images
	$(COMPOSE) pull

.PHONY: ps
ps: ## Show container status
	$(COMPOSE) ps

.PHONY: logs
logs: ## Tail logs (SERVICE=grafana to narrow)
	$(COMPOSE) logs -f --tail=100 $(SERVICE)

.PHONY: reload
reload: ## Hot-reload Prometheus and Alertmanager without a restart
	$(COMPOSE) exec prometheus   wget -q -O- --post-data='' http://localhost:9090/-/reload
	$(COMPOSE) exec alertmanager wget -q -O- --post-data='' http://localhost:9093/-/reload
	@printf '\033[0;32mreloaded\033[0m\n'

.PHONY: nuke
nuke: ## Stop the stack AND delete its volumes (destroys all metrics and logs)
	@printf '\033[0;33mThis deletes every metric and log stored by the stack.\033[0m\n'
	@read -p "Type 'nuke' to continue: " c; [ "$$c" = "nuke" ] || exit 1
	$(COMPOSE) down --volumes --remove-orphans

# ---------------------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------------------

.PHONY: secrets-init
secrets-init: ## Generate an age keypair and create the encrypted secrets file
	./scripts/bootstrap.sh $(STACK)

.PHONY: secrets-edit
secrets-edit: ## Edit the encrypted secrets in $$EDITOR
	sops $(SECRETS)

.PHONY: secrets-show
secrets-show: ## Print the decrypted secrets to stdout (careful)
	sops --decrypt $(SECRETS)

.PHONY: render
render: ## Decrypt secrets and render runtime config
	./scripts/render-config.sh $(STACK)

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

.PHONY: validate
validate: ## Run every check CI runs
	./scripts/validate.sh

.PHONY: lint
lint: ## Lint YAML, Markdown and shell
	yamllint .
	markdownlint-cli2
	shellcheck scripts/*.sh

.PHONY: check-dashboards
check-dashboards: ## Validate dashboard JSON and datasource references
	python3 scripts/check_dashboards.py

.PHONY: check-rules
check-rules: ## Validate Prometheus rules and config
	promtool check config $(STACK_DIR)/prometheus/prometheus.yaml
	promtool check rules $(STACK_DIR)/prometheus/rules/*.rules.yaml

.PHONY: scan
scan: ## Scan the working tree and history for secrets
	gitleaks detect --no-banner --redact -c .gitleaks.toml
	gitleaks detect --no-banner --redact -c .gitleaks.toml --log-opts="--all"

# ---------------------------------------------------------------------------
# Maintenance
# ---------------------------------------------------------------------------

.PHONY: snmp-generate
snmp-generate: ## Regenerate snmp.yaml from generator.yaml
	docker run --rm \
		-v "$(PWD)/$(STACK_DIR)/snmp-exporter:/opt/" \
		-e SNMP_COMMUNITY_PFSENSE='$${SNMP_COMMUNITY_PFSENSE}' \
		-e SNMP_COMMUNITY_APC='$${SNMP_COMMUNITY_APC}' \
		-e SNMP_COMMUNITY_MOKERLINK='$${SNMP_COMMUNITY_MOKERLINK}' \
		-e SNMP_COMMUNITY_ILO='$${SNMP_COMMUNITY_ILO}' \
		prom/snmp-generator:v0.28.0 generate \
		-m /opt/mibs -g /opt/generator.yaml -o /opt/snmp.yaml
	@printf '\033[0;33mCheck the diff before committing — placeholders must survive.\033[0m\n'

.PHONY: backup
backup: ## Back up the stack's volumes to ./backups/
	@mkdir -p backups
	@for v in prometheus-data loki-data grafana-data alertmanager-data; do \
		printf 'backing up %s\n' "$$v"; \
		docker run --rm -v $(STACK)_$$v:/data -v "$(PWD)/backups:/backup" \
			alpine tar czf "/backup/$$v.tar.gz" -C /data . ; \
	done
	@printf '\033[0;32mwrote backups/\033[0m\n'

.PHONY: purge-history-dry-run
purge-history-dry-run: ## Preview the git-history secret purge (safe)
	./scripts/purge-history.sh --dry-run
