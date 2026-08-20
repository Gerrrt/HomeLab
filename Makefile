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
	@# `up -d` recreates a container only when its *service definition* changes,
	@# so a freshly rendered snmp.yaml or an edited prometheus.yaml is invisible
	@# to it and the container keeps serving what it parsed at startup. Without
	@# this line `make up` reports success over a stale config — see
	@# scripts/reload-config.sh for the incident that produced it.
	./scripts/reload-config.sh $(STACK)
	@# The port is read back out of the rendered .env rather than expanded here.
	@# GRAFANA_PORT lives in $(STACK_DIR)/.env, which docker compose reads and make
	@# does not, so a bare $${GRAFANA_PORT:-3000} in a recipe yields 3000 whatever
	@# the operator actually set — a wrong URL that looks right. This line was
	@# previously inside a single-quoted printf format, so it did not expand at
	@# all and printed the literal text `$${GRAFANA_PORT:-3000}`: the same bug,
	@# just honest about it. Passed as a %s argument, not interpolated into the
	@# format, so a stray % in the value cannot be read as a format spec.
	@# tail -1 because compose takes the last of duplicate keys.
	@port="$$(grep -E '^GRAFANA_PORT=' $(STACK_DIR)/.env 2>/dev/null | tail -1 | cut -d= -f2-)"; \
	printf '\n\033[0;32mup\033[0m — Grafana: https://localhost:%s\n' "$${port:-3000}"
	@printf '   (self-signed by the lab CA — trust certificates/ca.pem, see docs/runbooks/generate-certificates.md)\n'

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
reload: ## Hot-reload Prometheus, Alertmanager and snmp-exporter (no restart)
	@# `make up` runs this too. It stays a separate target because a config-only
	@# change — an SNMP community rotation, an Alertmanager route edit — needs
	@# only `make render && make reload`, with no compose round trip.
	./scripts/reload-config.sh $(STACK)

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

.PHONY: check-compose-health
check-compose-health: ## Verify compose health dependencies can be satisfied
	python3 scripts/check_compose_health.py

.PHONY: check-loki-rules
check-loki-rules: ## Validate Loki (LogQL) alerting rules
	./scripts/check_loki_rules.sh

.PHONY: pin-digests
pin-digests: ## Re-resolve image digests in compose.yaml (--write applies)
	./scripts/pin-digests.sh --write

.PHONY: check-digests
check-digests: ## Verify pinned digests still match the registry
	./scripts/pin-digests.sh

.PHONY: scan
scan: ## Scan the working tree and history for secrets
	gitleaks detect --no-banner --redact -c .gitleaks.toml
	gitleaks detect --no-banner --redact -c .gitleaks.toml --log-opts="--all"

# ---------------------------------------------------------------------------
# Maintenance
# ---------------------------------------------------------------------------

.PHONY: snmp-mibs
snmp-mibs: ## Download the vendor MIBs snmp-generate needs (gitignored)
	./scripts/snmp-mibs.sh $(ARGS)

.PHONY: snmp-generate
snmp-generate: ## Regenerate snmp.yaml from generator.yaml (needs make snmp-mibs)
	@# The generator is released in lockstep with snmp-exporter but is not a
	@# compose service, so its version is derived from the exporter's pin rather
	@# than duplicated — see scripts/image-for.sh.
	@# --tag-only: the exporter's digest does not belong to the generator.
	@#
	@# Each -e sets a community variable to its own literal ${PLACEHOLDER} text,
	@# so the generator writes the placeholder back into snmp.yaml rather than
	@# baking in a real community.
	@#
	@# The flags are derived from the device inventory rather than listed here,
	@# because this list used to be a fifth copy of the device list and the only
	@# one that failed OPEN. A device missing its -e flag leaves the variable
	@# unset in the container, the generator expands it to empty, and snmp.yaml
	@# gets `community:` with nothing after it — which render-config.sh's guard
	@# cannot catch, because that guard looks for surviving placeholders and an
	@# empty expansion leaves none. The result is an exporter polling with no
	@# community at all. Hence: derive the list, then assert every placeholder
	@# actually survived.
	@#
	@# The metric count is compared before and after for the same reason. A
	@# regeneration that loses metrics is nearly always a missing or changed MIB
	@# rather than an intended edit, and the shrunken result is still a
	@# perfectly valid snmp.yaml. Walking the bare CPQ enterprise root rather
	@# than its subtrees silently cost ~1580 of them.
	@set -euo pipefail; \
	mibs="$(STACK_DIR)/snmp-exporter/mibs"; \
	if [[ ! -d "$$mibs" ]] || [[ -z "$$(ls -A "$$mibs" 2>/dev/null)" ]]; then \
		printf '\033[0;31merror:\033[0m no MIBs in %s\n' "$$mibs" >&2; \
		printf 'The generator resolves OIDs through net-snmp and the image ships almost no MIBs.\n' >&2; \
		printf 'Run: make snmp-mibs\n' >&2; \
		exit 1; \
	fi; \
	before="$$(grep -c '^    - name: ' "$(STACK_DIR)/snmp-exporter/snmp.yaml" 2>/dev/null || echo 0)"; \
	gen="$$(./scripts/image-for.sh --tag-only snmp-exporter | sed 's|snmp-exporter|snmp-generator|')"; \
	printf 'using %s\n' "$$gen"; \
	vars=(); flags=(); \
	while IFS=$$'\t' read -r _ip _auth _device var; do \
		[[ -n "$$var" ]] || continue; \
		vars+=("$$var"); \
		flags+=(-e "$$var=\$${$$var}"); \
	done < <(./scripts/snmp-targets.sh); \
	(($${#vars[@]} > 0)) || { printf '\033[0;31merror:\033[0m no SNMP devices in the inventory\n' >&2; exit 1; }; \
	printf 'placeholders: %s\n' "$${vars[*]}"; \
	docker run --rm \
		-v "$(PWD)/$(STACK_DIR)/snmp-exporter:/opt/" \
		"$${flags[@]}" \
		"$$gen" generate \
		-m /opt/mibs -g /opt/generator.yaml -o /opt/snmp.yaml; \
	after="$$(grep -c '^    - name: ' "$(STACK_DIR)/snmp-exporter/snmp.yaml" || echo 0)"; \
	printf 'metrics: %s -> %s\n' "$$before" "$$after"; \
	if (($$after < $$before)); then \
		printf '\033[0;31mwarning:\033[0m regeneration LOST %s metric(s)\n' "$$((before - after))" >&2; \
		printf 'Inspect the diff before committing. To discard:\n  git checkout -- %s/snmp-exporter/snmp.yaml\n' "$(STACK_DIR)" >&2; \
	fi; \
	missing=(); \
	for v in "$${vars[@]}"; do \
		grep -qF "\$${$$v}" "$(STACK_DIR)/snmp-exporter/snmp.yaml" || missing+=("$$v"); \
	done; \
	if (($${#missing[@]} > 0)); then \
		printf '\033[0;31merror:\033[0m placeholders missing from the generated snmp.yaml: %s\n' "$${missing[*]}" >&2; \
		printf 'the generator expanded them to empty, so snmp-exporter would poll with no community.\n' >&2; \
		printf 'snmp.yaml has NOT been restored — inspect it, then `git checkout -- %s/snmp-exporter/snmp.yaml`\n' "$(STACK_DIR)" >&2; \
		exit 1; \
	fi; \
	printf '\033[0;32mok\033[0m — %s placeholder(s) survived generation\n' "$${#vars[@]}"

.PHONY: snmp-verify
snmp-verify: ## Check each SNMP device answers to its community (ARGS=--old)
	@# Deliberately under Maintenance, not Validation: everything under
	@# Validation is offline and safe for CI, whereas this needs the age key and
	@# sends packets to production devices. Keeping it here stops anyone folding
	@# it into `make validate`.
	./scripts/snmp-verify.sh $(ARGS)

.PHONY: secrets-verify-backup
secrets-verify-backup: ## Check a backup age key decrypts the secrets (KEY=/path/to/keys.txt)
	@# Under Maintenance rather than Validation for the same reason as
	@# snmp-verify: everything under Validation is offline and safe for CI,
	@# and this needs a private key on disk. It must never end up inside
	@# `make validate`, where it would either always skip or ask CI for a key.
	@#
	@# KEY rather than ARGS because there is exactly one argument and it is
	@# required — an empty ARGS would reach the script as no argument at all
	@# and print usage, which reads like the target is broken.
	./scripts/verify-key-backup.sh "$(KEY)" $(STACK)

.PHONY: certs
certs: ## Create the internal CA / issue a leaf (ARGS="--host x.matrix.elysium --ip 10.0.0.1")
	@# certificates/ is gitignored. Nothing in the stack terminates TLS yet —
	@# see docs/roadmap.md — so this exists so that the CA is created
	@# deliberately rather than improvised the day something needs it.
	./scripts/gen-certs.sh $(ARGS)

.PHONY: gen-secret
gen-secret: ## Generate a random secret (ARGS=--snmp for one per SNMP device)
	./scripts/gen-secret.sh $(ARGS)

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
