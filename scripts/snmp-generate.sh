#!/usr/bin/env bash
#
# Regenerate snmp.yaml from generator.yaml. Needs `make snmp-mibs` first.
#
# Moved out of the Makefile recipe (#849), where it was the second-longest
# recipe and the only one of its size that shellcheck never read. Two faults it
# carried there are fixed here: it mounted $(PWD), which is the CALLER's
# directory, so `make -C <repo> snmp-generate` mounted the wrong path; and the
# container ran as root, so a regenerated snmp.yaml could come out root-owned.
#
# The generator is released in lockstep with snmp-exporter but is not a compose
# service, so its version is derived from the exporter's pin rather than
# duplicated — see scripts/image-for.sh. --tag-only: the exporter's digest does
# not belong to the generator.
#
# Each -e sets a credential variable — a community, or a v3 device's two
# passphrases — to its own literal ${PLACEHOLDER} text, so the generator writes
# the placeholder back into snmp.yaml rather than baking in a real value.
#
# The flags are derived from the device inventory rather than listed here,
# because this list used to be a fifth copy of the device list and the only one
# that failed OPEN. A device missing its -e flag leaves the variable unset in
# the container, the generator expands it to empty, and snmp.yaml gets
# `community:` with nothing after it — which render-config.sh's guard cannot
# catch, because that guard looks for surviving placeholders and an empty
# expansion leaves none. The result is an exporter polling with no community at
# all. Hence: derive the list, then assert every placeholder actually survived.
#
# The metric count is compared before and after for the same reason. A
# regeneration that loses metrics is nearly always a missing or changed MIB
# rather than an intended edit, and the shrunken result is still a perfectly
# valid snmp.yaml. Walking the bare CPQ enterprise root rather than its
# subtrees silently cost ~1580 of them.
#
# Usage: STACK=observability scripts/snmp-generate.sh      (or: make snmp-generate)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
STACK="${STACK:-observability}"
SNMP_DIR="stacks/${STACK}/snmp-exporter"
SNMP_YAML="${SNMP_DIR}/snmp.yaml"

die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# `grep -c` already prints 0 when it matches nothing, and exits 1 doing it, so
# `|| echo 0` printed a second 0 and broke the comparison below. A missing file
# is the one case that prints nothing.
count_metrics() {
  [[ -f "${SNMP_YAML}" ]] || { echo 0; return; }
  grep -c '^    - name: ' "${SNMP_YAML}" || true
}

mibs="${SNMP_DIR}/mibs"
if [[ ! -d "${mibs}" ]] || [[ -z "$(ls -A "${mibs}" 2>/dev/null)" ]]; then
  printf '\033[0;31merror:\033[0m no MIBs in %s\n' "${mibs}" >&2
  printf 'The generator resolves OIDs through net-snmp and the image ships almost no MIBs.\n' >&2
  printf 'Run: make snmp-mibs\n' >&2
  exit 1
fi

before="$(count_metrics)"
gen="$(./scripts/image-for.sh --tag-only snmp-exporter | sed 's|snmp-exporter|snmp-generator|')"
printf 'using %s\n' "${gen}"

vars=(); flags=()
while IFS=$'\t' read -r _ip _auth _device _version keys; do
  [[ -n "${keys}" ]] || continue
  IFS=, read -ra key_list <<< "${keys}"
  for var in "${key_list[@]}"; do
    vars+=("${var}")
    flags+=(-e "${var}=\${${var}}")
  done
done < <(./scripts/snmp-targets.sh)
((${#vars[@]} > 0)) || die "no SNMP devices in the inventory"
printf 'placeholders: %s\n' "${vars[*]}"

# --user for the reason scripts/lint.sh gives its containers: a file written
# into a bind mount takes the container's uid, and root's would outlive the run.
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "${REPO_ROOT}/${SNMP_DIR}:/opt/" \
  "${flags[@]}" \
  "${gen}" generate \
  -m /opt/mibs -g /opt/generator.yaml -o /opt/snmp.yaml

after="$(count_metrics)"
printf 'metrics: %s -> %s\n' "${before}" "${after}"
if ((after < before)); then
  printf '\033[0;31mwarning:\033[0m regeneration LOST %s metric(s)\n' "$((before - after))" >&2
  printf 'Inspect the diff before committing. To discard:\n  git checkout -- %s\n' "${SNMP_YAML}" >&2
fi

missing=()
for v in "${vars[@]}"; do
  grep -qF "\${${v}}" "${SNMP_YAML}" || missing+=("${v}")
done
if ((${#missing[@]} > 0)); then
  printf '\033[0;31merror:\033[0m placeholders missing from the generated snmp.yaml: %s\n' "${missing[*]}" >&2
  printf 'the generator expanded them to empty, so snmp-exporter would poll with no community.\n' >&2
  # shellcheck disable=SC2016  # the backticks are literal text in the message
  printf 'snmp.yaml has NOT been restored — inspect it, then `git checkout -- %s`\n' "${SNMP_YAML}" >&2
  exit 1
fi
printf '\033[0;32mok\033[0m — %s placeholder(s) survived generation\n' "${#vars[@]}"
