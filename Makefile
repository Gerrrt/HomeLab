SHELL := /bin/bash
.DEFAULT_GOAL := help

STACK       ?= observability
# How far back check-loki-coverage looks, and the reason it is 24h rather than
# the 7d it started as (#335). The window is not a sensitivity dial in the
# direction it looks: BOTH sides of the check's comparison use it, so a host
# that goes quiet drops out of the denominator as well as the numerator and the
# check goes vacuous rather than wrong. What the window actually sets is
# DETECTION LAG. `reach` counts lines over the window, so a selector that went
# blind an hour ago still shows the host as reached until the last pre-breakage
# line falls out of range — a 7d window hides a new gap for up to a week.
#
# 24h is as short as the estate allows. Measured 2026-09-06, lines per host:
#
#   window   Saruman   morpheus   oracle   prometheus
#   1h            15      5,048      204          326
#   24h          186     89,340    5,379       45,998
#
# Saruman is the constraint at ~15 lines an hour and is comfortably present at
# 24h. The cost of the shorter window, stated rather than glossed: a host whose
# *subject* lines are rare — Saruman produced 2 SSH accepts in seven days — has
# none inside 24h, so a real gap there is reported as a latent WARN instead of a
# live FAIL. Verified both ways against the pre-#261 rules, where 24h still
# exits 1 on morpheus.
#
# Overridable per run (WINDOW=7d make check-loki-coverage) and inherited by
# homelab-loki-coverage.service, which sets no window of its own — one number,
# in one place.
WINDOW      ?= 24h
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
	@# BEFORE the reload, because the reload is not what is broken. A single-file
	@# bind mount is pinned to the inode and git replaces it, so a config-only
	@# commit leaves the container on the pre-merge bytes and POST /-/reload
	@# returns 200 having faithfully re-read them. That is #355, found when #166
	@# deployed clean and its three targets never appeared. --fix recreates only
	@# the services that actually diverged, then asserts the recreate worked.
	python3 scripts/check_mounted_config.py --fix $(STACK)
	./scripts/reload-config.sh $(STACK)
	@# The deploy asserts on its own result. Everything above reports success
	@# from having ISSUED the commands — compose accepted the file, the reloads
	@# returned 200 — and none of it asks whether what came up is actually
	@# serving. snmp-exporter sat permanently unhealthy on a healthcheck pointed
	@# at a 404 for as long as it did precisely because nothing ever asked
	@# (#205). This is the only place the question can be asked, since CI has no
	@# stack to ask it of.
	@#
	@# It waits, so a slow start is not a failure: the per-service deadline is
	@# derived from that service's own start_period, retries, interval and
	@# timeout, and is the point Docker itself would have given up.
	python3 scripts/check_container_health.py $(STACK)
	@# And that Alertmanager can still read the URLs it notifies through. The
	@# container's view, not this host's: in #214 the files were present here and
	@# absent inside the container, and every receiver reads from the same
	@# directory, so all four went dark together for ten and a half hours. The
	@# alert that fired about it could not be delivered, because it was the
	@# delivery path that was broken — so this has to be a check rather than an
	@# alert.
	python3 scripts/check_alert_channels.py --files --live $(STACK)
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

.PHONY: converge
converge: ## Fetch main, verify it, fast-forward and deploy (ARGS=--dry-run)
	@# What the hourly timer runs, and what a human runs to deploy on purpose
	@# without waiting for it. It ends in `make up` rather than replacing it, so
	@# there is exactly one deployment path and both callers exercise it.
	@#
	@# It refuses to run anywhere but /home/robo/code/Gerrrt/HomeLab, for the
	@# reason `make up` cares about and `make deploy-agent` does not: render
	@# writes into the .rendered/ of the tree it is run from, and no container
	@# mounts a worktree's copy. ARGS=--dry-run says what it would do.
	./scripts/converge.sh $(ARGS)

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
	@# Not a bare `sops $(SECRETS)`. sops decrypts to a temp file and opens
	@# $$EDITOR on it, and a vim or neovim with `undofile` set then writes that
	@# buffer — the decrypted secrets — into a permanent undodir. sops shreds
	@# its own temp file on exit; nothing shreds the undo file. Found in the
	@# wild on the monitoring host: three of them holding the live SNMP
	@# community strings for pfSense, the APC NMC and iLO, mode 664, on an
	@# unencrypted disk. scripts/secrets-edit.sh silences the editor first.
	./scripts/secrets-edit.sh $(STACK)

.PHONY: secrets-add-recipient
secrets-add-recipient: ## Add a second age recipient and re-key (PUBKEY=age1...)
	@# Under Secrets and not Maintenance because it is part of setting the
	@# secrets up, but it is the one target here that rewrites a committed file
	@# — .sops.yaml and secrets/$(STACK).sops.yaml both change and must be
	@# committed together. ADR-0024 says why more than one recipient exists.
	@#
	@# PUBKEY rather than ARGS, for the reason secrets-verify-backup takes KEY:
	@# exactly one argument, required, and an empty ARGS would reach the script
	@# as no argument at all and print usage, which reads like a broken target.
	@#
	@# The PUBLIC half only. The private half of the key being added must never
	@# be generated on, copied to, or pasted into this host — that is the whole
	@# property the second recipient exists to have.
	@[[ -n "$(PUBKEY)" ]] || { \
		printf '\033[0;31merror:\033[0m PUBKEY is required\n' >&2; \
		printf 'Generate the keypair where it will LIVE, then bring back its public half:\n' >&2; \
		printf '  make secrets-add-recipient PUBKEY=age1...\n' >&2; \
		printf 'See docs/runbooks/back-up-the-age-key.md\n' >&2; \
		exit 2; \
	}
	./scripts/add-recipient.sh "$(PUBKEY)" $(STACK)

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
lint: ## Lint YAML, Markdown, shell, workflows and EditorConfig
	./scripts/lint.sh

.PHONY: check-docs
check-docs: ## Verify the documents agree with the configs
	python3 scripts/check_docs.py

.PHONY: check-dashboards
check-dashboards: ## Validate dashboard JSON and datasource references
	python3 scripts/check_dashboards.py

.PHONY: check-rules
check-rules: ## Validate and unit-test Prometheus rules and config
	promtool check config $(STACK_DIR)/prometheus/prometheus.yaml
	promtool check rules $(STACK_DIR)/prometheus/rules/*.rules.yaml
	promtool test rules $(STACK_DIR)/prometheus/tests/*.test.yaml

.PHONY: check-compose-health
check-compose-health: ## Verify health deps are satisfiable, probe the images (needs docker)
	@# --probe unconditionally, like check-rules above needs promtool. It execs
	@# each healthcheck's binary inside that service's pinned image, which is
	@# the only way to know an image has not moved to a distroless base under a
	@# Dependabot bump (#79). Without a docker daemon this fails and says to
	@# drop the flag, rather than handing back a green run it did not earn.
	@# `make validate` is the graceful path — it skips the probe and says so.
	python3 scripts/check_compose_health.py --probe

.PHONY: check-container-health
check-container-health: ## Ask the RUNNING stack whether its healthchecks pass (deploy-time)
	@# The other half of check-compose-health above, and deliberately not part
	@# of `make validate`: that one asks whether a healthcheck CAN run, from the
	@# config and the image, and gates pull requests. This one asks whether the
	@# endpoint it probes actually answers, which only a running daemon knows.
	@# `make up` runs it; this target is for asking again later without a
	@# redeploy. Add --no-wait for a snapshot of a stack that is already up.
	python3 scripts/check_container_health.py $(STACK)

.PHONY: check-loki-rules
check-loki-rules: ## Validate Loki (LogQL) alerting rules and dashboard panel queries
	./scripts/check_loki_rules.sh

.PHONY: patch-state
patch-state: ## Collect this host's package patch state into the textfile dir
	@# Needs no root: apt-check runs unprivileged, /var/run/reboot-required is a
	@# world-readable flag, and the textfile directory is owned by the user the
	@# timers run as. --print writes to stdout instead, for looking without
	@# touching the collector.
	./scripts/collect-patch-state.sh

.PHONY: install-agent-patch-state
install-agent-patch-state: ## Put the patch-state collector on an agent host (needs sudo THERE)
	@# AGENT=user@host, one or more. #152 covered the monitoring host and only it;
	@# this covers a host that runs Alloy but has no checkout of this repository,
	@# which on 2026-09-06 meant `oracle` had a kernel update unbooted for two days
	@# that nothing in the estate could see (#360).
	@#
	@# Deliberately NOT part of deploy-agent.sh, which goes out of its way to need
	@# no privilege on the target. This step does — /usr/local/bin, /etc/systemd
	@# and the root-owned textfile directory — so it is run by hand, once per host,
	@# and prompts for a sudo password there. AGENT='...' ARGS=--check verifies an
	@# existing install and changes nothing.
	@test -n "$(AGENT)" || { echo "set AGENT=user@host (e.g. AGENT=atropos@10.0.99.30)"; exit 1; }
	./scripts/install-agent-patch-state.sh $(ARGS) $(AGENT)

.PHONY: check-mounted-config
check-mounted-config: ## Verify each container runs the config the repo has (deploy-time)
	@# Read-only without --fix, so it is safe to ask at any time. `make up` runs
	@# it with --fix. Compares BYTES rather than inodes: an inode check would
	@# report a file rewritten with identical content as stale, which git and
	@# render-config.sh both do routinely.
	python3 scripts/check_mounted_config.py $(STACK)

.PHONY: check-alert-channels
check-alert-channels: ## Verify Alertmanager can read every receiver URL (deploy-time)
	@# The static half runs in `make validate` and in CI, where it needs neither
	@# a secret nor a host. This adds --files and --live, which need both: the
	@# rendered files on this host, and what the running container can actually
	@# open. #214 is the difference between those two.
	python3 scripts/check_alert_channels.py --files --live $(STACK)

.PHONY: check-loki-coverage
check-loki-coverage: ## Ask the LIVE Loki whether any rule is blind to a host (deploy-time)
	@# Not in `make validate`, and not in CI, for the reason check_loki_rules.sh
	@# gives in its own header: that script boots the pinned image against a
	@# throwaway config with no data and asks whether the rules PARSE. This asks
	@# whether they can SEE, which only a Loki holding real logs can answer, and
	@# CI has no log store at all (#327). WINDOW=24h to narrow it.
	python3 scripts/check_loki_coverage.py $(STACK) --window $(WINDOW)

.PHONY: check-dashboard-roundtrip
check-dashboard-roundtrip: ## Boot the pinned Grafana and verify the dashboards round-trip
	@# Under Validation and not Maintenance, unlike `dashboards-export` below,
	@# because it needs neither a secret nor the live stack: it boots a
	@# throwaway Grafana from the pinned image, provisions the committed JSON
	@# into it and reads it back. Same shape and the same reasoning as
	@# `check-loki-rules` — the only thing that genuinely understands the format
	@# is the thing that will serve it.
	@#
	@# It also asserts that Grafana still ACCEPTS a save to a provisioned
	@# dashboard. That is not incidental: while allowUiUpdates is false the
	@# export is a silent no-op, so this is the check standing between #100 and
	@# a command that succeeds without doing anything.
	./scripts/check_dashboard_roundtrip.sh

.PHONY: check-image-pins
check-image-pins: ## Verify every docker image comes from compose.yaml
	python3 scripts/check_image_pins.py

.PHONY: check-timers
check-timers: ## Verify the schedule and its staleness thresholds agree
	@# Under Validation rather than Maintenance, unlike `install-timers` below:
	@# --check reads files, shells out to `systemd-analyze calendar`, and touches
	@# neither the host nor a secret. It is what stops the cadence in a .timer
	@# and the threshold in scripts/install-timers.sh drifting apart — the same
	@# two-copies-of-one-fact problem the amtool route assertions exist for (#68).
	./scripts/install-timers.sh --check

.PHONY: pin-digests
pin-digests: ## Re-resolve image digests in every stack's compose.yaml (--write applies)
	@# Every stack, not just the estate's. pin-digests.sh takes one compose file
	@# and rewrites it in place, which is the right shape for the work it does —
	@# so the loop lives here rather than inside it, driven by the same
	@# scripts/stacks.sh that validate.sh and ci.yml read. Left single-stack,
	@# `stacks/lab`'s digests would be re-resolved by nothing and verified by
	@# nothing, which is the #263 defect in the one place it costs a supply-chain
	@# guarantee rather than a test.
	@set -e; for sd in $$(./scripts/stacks.sh --paths); do \
		printf '\033[0;34m--\033[0m %s\n' "$$sd"; \
		COMPOSE_FILE="$$sd/compose.yaml" ./scripts/pin-digests.sh --write; \
	done

.PHONY: check-digests
check-digests: ## Verify pinned digests still match the registry
	@set -e; for sd in $$(./scripts/stacks.sh --paths); do \
		printf '\033[0;34m--\033[0m %s\n' "$$sd"; \
		COMPOSE_FILE="$$sd/compose.yaml" ./scripts/pin-digests.sh; \
	done

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

.PHONY: check-versions
check-versions: ## Check the documented OS versions against what the hosts report
	@# Under Maintenance rather than Validation, for the same reason snmp-verify
	@# is: it reads the running system. Everything under Validation is offline and
	@# safe for CI, and this one needs Prometheus — so `make validate` must not
	@# grow it, or CI starts failing on a host it cannot reach.
	@#
	@# This is the half check_docs.py structurally cannot do. That script asserts
	@# hardware.md and network.md agree with each other, which passed for a whole
	@# pfSense release while both said FreeBSD 15 and the box ran 16 (#292).
	./scripts/check_versions.py $(ARGS)

.PHONY: snmp-verify
snmp-verify: ## Check each SNMP device answers to its community (ARGS=--old)
	@# Deliberately under Maintenance, not Validation: everything under
	@# Validation is offline and safe for CI, whereas this needs the age key and
	@# sends packets to production devices. Keeping it here stops anyone folding
	@# it into `make validate`.
	./scripts/snmp-verify.sh $(ARGS)

.PHONY: snmp-walk
snmp-walk: ## Walk one OID subtree on one SNMP device, exporter-shaped (ARGS="--device neo <oid>")
	@# Maintenance for the same reason as snmp-verify: needs the age key and
	@# sends packets to a production device. It exists so a new column is read
	@# off the switch before it goes into generator.yaml — see the mokerlink
	@# module's comment for why that order matters on this hardware.
	./scripts/snmp-walk.sh $(ARGS)

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
	@#
	@# Guarded here rather than left to the script so that a bare
	@# `make secrets-verify-backup` does not reach run-scheduled.sh and get
	@# recorded as a FAILED verification. A forgotten argument is a typo, not
	@# evidence about the key backup, and it must not fire an alert.
	@[[ -n "$(KEY)" ]] || { \
		printf '\033[0;31merror:\033[0m KEY is required\n' >&2; \
		printf 'Mount the offline copy, then:  make secrets-verify-backup KEY=/path/to/keys.txt\n' >&2; \
		printf 'See docs/runbooks/back-up-the-age-key.md\n' >&2; \
		exit 2; \
	}
	@# Wrapped, even though a human runs it, and that is the whole point of #77.
	@# This is the one job that cannot be put on a timer — verify-key-backup.sh
	@# refuses the live key by device:inode precisely so that what gets tested is
	@# a copy on removable media, and no timer can mount that. So the schedule is
	@# enforced from the other end: a successful run records its timestamp, and
	@# SecretsKeyBackupUnproven fires when that proof passes ninety days old.
	@# Nagging is not as good as running it, but it beats remembering.
	./scripts/run-scheduled.sh --job verify-key-backup --lock keys \
		-- ./scripts/verify-key-backup.sh "$(KEY)" $(STACK)

.PHONY: certs
certs: ## Create the internal CA / issue a leaf (ARGS="--host x.matrix.elysium --ip 10.0.0.1")
	@# certificates/ is gitignored, so a clean clone has neither the CA nor the
	@# leaf and this is a required deployment step, not a someday one: Grafana
	@# serves https from the leaf and Prometheus verifies it with the CA. It read
	@# as optional for as long as this comment claimed nothing terminated TLS,
	@# which is how #69 happened — `make up` bind-mounted the absent files and
	@# Docker silently created directories in their place. render-config.sh now
	@# refuses to render until they exist.
	./scripts/gen-certs.sh $(ARGS)

.PHONY: gen-secret
gen-secret: ## Generate a random secret (ARGS=--snmp for one per SNMP device)
	./scripts/gen-secret.sh $(ARGS)

.PHONY: screenshots
screenshots: ## Render the dashboards to docs/images/ (stack must be up)
	@# Under Maintenance, not Validation, for the same reason as snmp-verify and
	@# secrets-verify-backup: it needs the decrypted Grafana password and a
	@# running stack, so it must never be reachable from `make validate`, where
	@# it would either always skip or ask CI for a secret.
	@#
	@# It starts the `capture` profile's renderer, shoots five PNGs and stops it
	@# again. Review every image before committing — docs/images/README.md says
	@# what to look for.
	./scripts/capture-screenshots.sh $(STACK)

.PHONY: dashboards-export
dashboards-export: ## Pull the dashboards out of the running Grafana into git (ARGS=--check)
	@# Under Maintenance, not Validation, for the same reason as `screenshots`:
	@# it needs the decrypted Grafana password and a running stack, so it must
	@# never be reachable from `make validate`, where it would either always skip
	@# or ask CI for a secret. `make check-dashboard-roundtrip` is the half that
	@# belongs there.
	@#
	@# The loop this replaces was Dashboard settings → JSON Model, select all,
	@# copy, paste over the file — manual, and therefore skipped under pressure
	@# (#100). It is now: edit in the UI, run this, read `git diff`.
	@#
	@# ARGS=--check writes nothing and exits non-zero when the running Grafana
	@# holds an edit that git does not. That is the half that makes
	@# allowUiUpdates: true safe rather than merely convenient, and it is what
	@# the `dashboards-drift` timer runs — see systemd/homelab-dashboards-drift.
	./scripts/export-dashboards.sh $(ARGS) $(STACK)

.PHONY: backup-firewall
backup-firewall: ## Pull morpheus's pfSense config, encrypt it to ./backups/, copy it to oracle
	@# The single largest unmitigated failure in the estate is morpheus dying
	@# with no config export. Output is gitignored and never committed — see
	@# the header of scripts/backup-firewall.sh for why.
	@#
	@# The copy to oracle is part of this target, not a second one: a run whose
	@# copy fails exits non-zero even though the local file was written, so the
	@# nightly timer's metric says "stopped leaving this host" rather than
	@# "fine" (#92). ARGS=--local-only skips it, for a bench.
	@#
	@# Retention is part of the same run: FW_KEEP exports survive on each side
	@# and the rest are removed, so a nightly job cannot grow without bound.
	@# ARGS=--list is its dry run and ARGS=--prune applies it on its own. Note
	@# FW_KEEP and not KEEP — every unit shares /etc/default/homelab-timers and
	@# backup-volumes.sh already owns KEEP there.
	./scripts/backup-firewall.sh $(ARGS)

.PHONY: backup
backup: ## Quiesce the stack, archive its volumes to ./backups/ and verify
	@# Thin on purpose. This target used to BE the implementation, and every
	@# defect in #64 followed from that: one fixed output filename that tar
	@# truncated at open, so the only way to lose a backup was to take one; a
	@# hardcoded volume list that had silently skipped alloy-data since Alloy
	@# was added; an unpinned `alpine`; a hot copy of an open TSDB; and no
	@# verification beyond tar's exit status.
	@#
	@# The volume list and the services to stop are now derived from
	@# compose.yaml, so a sixth volume cannot be forgotten. STACK goes in the
	@# environment rather than positionally: the script's arguments are flags.
	STACK=$(STACK) ./scripts/backup-volumes.sh $(ARGS)

.PHONY: restore
restore: ## Restore the stack's volumes from a backup set (ARGS="--from <stamp>")
	@# Deliberately a separate script from `backup`. One script that both writes
	@# archives and overwrites live volumes is one mistyped flag from an outage,
	@# and scripts/backup-firewall.sh — the model for both — never writes to the
	@# thing it backs up and never deletes outside its own retention window
	@# (#92). The volume inventory is not duplicated: restore-volumes.sh
	@# reads `backup-volumes.sh --inventory`, the way every SNMP tool reads
	@# scripts/snmp-targets.sh.
	STACK=$(STACK) ./scripts/restore-volumes.sh $(ARGS)

.PHONY: install-timers
install-timers: ## Install and enable the systemd timers on this host (needs sudo)
	@# Under Maintenance for the same reason as snmp-verify and
	@# secrets-verify-backup: it changes the host. It must never be reachable
	@# from `make validate` — `make check-timers` is the half that is.
	@#
	@# The units carry absolute paths, so the script refuses to install from
	@# anywhere but the deployment checkout. Installing from a worktree would
	@# point every timer at a directory that gets deleted, and the symptom would
	@# be jobs that silently never run — the exact condition this exists to make
	@# visible.
	sudo ./scripts/install-timers.sh --install

.PHONY: deploy-agent
deploy-agent: ## Deploy or redeploy the Alloy agent on a host (ARGS="[--runtime native] user@host")
	@# Under Maintenance because it changes a host — a remote one — and must
	@# never be reachable from `make validate`. The image and the config come
	@# from this checkout, so run it from the checkout whose state you want the
	@# host to have; the script ships files over ssh and needs no render, so a
	@# worktree is fine here, unlike `make up`.
	./scripts/deploy-agent.sh $(ARGS)

.PHONY: purge-history-dry-run
purge-history-dry-run: ## Preview the git-history secret purge (safe)
	./scripts/purge-history.sh --dry-run
