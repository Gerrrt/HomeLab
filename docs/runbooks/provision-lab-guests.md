# Runbook: Provision lab guests with OpenTofu, from `phoenix`

**Target:** guests cloned from `packer/`'s templates on `Saruman`, through the
Proxmox API, with state that is encrypted before it is first written. The first
apply is the proof guest, 998. It shows that the state carries no secret, and
then it is destroyed.

**Time:** an hour the first time. After that, an apply takes as long as a full
clone does.

**You will need:**

- a shell on `phoenix` as the user that owns `~/.config/proxmox/phoenix.env`;
- a root shell on `Saruman`, for §2 only;
- a shell on `prometheus`, for §3's escrow check only;
- template 901 built and smoke-tested
  ([`build-the-lab-templates.md`](build-the-lab-templates.md) §6).

**Before this:** [#440](https://github.com/Gerrrt/HomeLab/issues/440)'s
templates, and `phoenix`'s token working
([`build-the-jumpbox.md`](build-the-jumpbox.md) §4).

**After this:** the estate has a way to express a guest, and
[#448](https://github.com/Gerrrt/HomeLab/issues/448) and
[#421](https://github.com/Gerrrt/HomeLab/issues/421) have somewhere to declare
theirs.

This carries out what
[ADR-0076](../adr/0076-provision-lab-guests-with-opentofu-and-encrypt-its-state-from-the-first-apply.md)
decided for [#445](https://github.com/Gerrrt/HomeLab/issues/445). The HCL is in
[`tofu/`](../../tofu/README.md).

---

## 0. What is decided, and why

| | Decision | Why this and not the obvious alternative |
| --- | --- | --- |
| Tool | OpenTofu, not Terraform | It encrypts state. A Terraform state holds every value the provider touched, in cleartext |
| State key | `pbkdf2` passphrase in `phoenix.env`, escrowed in `secrets/tofu.sops.yaml` | OpenTofu has no age key provider, and `phoenix` holds no age key (ADR-0043). The escrow is encrypted to the estate's two recipients, so `phoenix` can write it but cannot read it |
| Plaintext | Refused: `enforced = true` on state and plan | Without it, a missing method writes plaintext and says nothing |
| State location | `tofu/state/lab.tfstate`, gitignored and asserted untracked | `git add -f` walks past `.gitignore`, and `check-tracked-artefacts.sh` does not |
| Clones | Full, written into the module | `packer build -force` rebuilds a template in place (ADR-0074) |
| Pools | Derived from the guests | A pool is created with its first guest and destroyed with its last |
| The six domain guests | Not managed here | Hand-built, two of them DCs. #448 or an evaluation rebuild brings them in |

## 1. OpenTofu, on `phoenix`

Install the version `stacks/observability/compose.yaml` pins for `tofu`. CI
proves the encryption with that image, and the binary that writes the real
state should be the one that was proved. Take the `linux_amd64` zip from
OpenTofu's GitHub release and check it against the `SHA256SUMS` published
beside it:

```bash
V=1.13.1   # the tag compose.yaml pins for tofu
cd /tmp
curl -fsSLO "https://github.com/opentofu/opentofu/releases/download/v${V}/tofu_${V}_linux_amd64.zip"
curl -fsSLO "https://github.com/opentofu/opentofu/releases/download/v${V}/tofu_${V}_SHA256SUMS"
grep " tofu_${V}_linux_amd64.zip$" "tofu_${V}_SHA256SUMS" | sha256sum -c -
unzip -o "tofu_${V}_linux_amd64.zip" tofu && sudo install -m 755 tofu /usr/local/bin/tofu
tofu version
```

§3 encrypts with `sops`, which `phoenix` did not otherwise have. It needs only
the public keys, so installing it here gives this host nothing it can decrypt.
Install it the same way, checked against the release's checksums file:

```bash
S=3.13.3   # the getsops/sops release
curl -fsSLO "https://github.com/getsops/sops/releases/download/v${S}/sops-v${S}.linux.amd64"
curl -fsSLO "https://github.com/getsops/sops/releases/download/v${S}/sops-v${S}.checksums.txt"
grep " sops-v${S}.linux.amd64$" "sops-v${S}.checksums.txt" | sha256sum -c -
sudo install -m 755 "sops-v${S}.linux.amd64" /usr/local/bin/sops
```

Then add three lines to `phoenix.env`. The provider reads the first two
directly. The third is the state key. The token line is built from the file's
own `PROXMOX_TOKEN_ID` and `PROXMOX_TOKEN_SECRET`, so no secret is typed or
printed. This prints only variable names, the passphrase's length and the
API's status code:

```bash
E=~/.config/proxmox/phoenix.env
if grep -qE '^(PROXMOX_VE_|TF_VAR_state_passphrase)' "$E"; then
  echo "already present"
elif cp -p "$E" "$E.bak-445"; then
  ( set -a; . "$E"; set +a; umask 077
    printf 'PROXMOX_VE_ENDPOINT=https://10.0.30.110:8006/\nPROXMOX_VE_API_TOKEN=%s=%s\nTF_VAR_state_passphrase=%s\n' \
      "$PROXMOX_TOKEN_ID" "$PROXMOX_TOKEN_SECRET" "$(openssl rand -base64 32)" >> "$E" )
  chmod 600 "$E"; grep -o '^[A-Za-z_]*=' "$E"
  ( set -a; . "$E"; set +a; echo "passphrase length ${#TF_VAR_state_passphrase}"
    printf 'header = "Authorization: PVEAPIToken=%s"\n' "${PROXMOX_VE_API_TOKEN}" \
      | curl -K - -fsS -o /dev/null -w 'API %{http_code}\n' "${PROXMOX_VE_ENDPOINT}api2/json/version" )
else
  echo "backup failed: nothing written"
fi
```

`passphrase length 44` and `API 200`. Then `rm` the `.bak-445` copy, which
holds the token. A full root makes the copy fail. The first run hit exactly
that, and the build's §2 now grows the volume (`build-the-jumpbox.md`). A
failed backup now stops the edit rather than being skipped past. **Do §3 before any `tofu apply`.** A state written before
its key is escrowed is a state that one disk failure can lose.

## 2. What the token is missing, on `Saruman`

Creating a pool, putting a guest in it, and deleting it all need
`Pool.Allocate` on that pool's path. Grant it per pool, not on `/pool` and
never at `/`:

```bash
pveum role modify PhoenixBuilder --append 1 --privs "Pool.Allocate,Pool.Audit"
pveum acl modify /pool/proof --users phoenix@pve --roles PhoenixBuilder
pveum acl list | grep phoenix
```

The ACL can name a pool that does not exist yet, which is the point: OpenTofu
creates it. **Deleting a pool deletes its ACL too.** Proxmox's pool delete calls
`delete_pool_acl`, which drops everything granted on `/pool/<name>`. So a grant
outlives its pool only if the pool is never destroyed. A pool that is
destroyed with its last guest, as `proof` is in §4, needs the `acl modify`
line above run again, as root on `Saruman`, before the next apply that
recreates it. Without that line, the pool create fails with
`Permission check failed (/pool/proof, Pool.Allocate)`.

Each later pool gets its own `acl modify` line here and a row below:

| Path | Role | For |
| --- | --- | --- |
| `/pool/proof` | `PhoenixBuilder` | §4's proof guest. It exists only while the proof runs, and §4's teardown deletes this grant with it. Re-run it before any later `-var proof=true` |

If an apply fails with `Permission check failed (/…, Some.Privilege)`, add that
privilege to the role and record it here. This is ADR-0043's rule again.

## 3. Escrow the passphrase, before the first apply

On `phoenix`, encrypt the passphrase to the catch-all rule's recipients. `sops`
needs only the public keys, which are in `.sops.yaml`, so this works on a host
that cannot decrypt the result:

```bash
cd ~/code/Gerrrt/HomeLab && git pull
set -a; . ~/.config/proxmox/phoenix.env; set +a
umask 077
printf 'TOFU_STATE_PASSPHRASE: %s\n' "${TF_VAR_state_passphrase}" \
  | sops --encrypt --filename-override secrets/tofu.sops.yaml \
         --input-type yaml --output-type yaml /dev/stdin > secrets/tofu.sops.yaml
grep -c 'age1' secrets/tofu.sops.yaml          # 2: the estate key and the second recipient
sops --decrypt secrets/tofu.sops.yaml          # fails here, and that is the design
printf '%s' "${TF_VAR_state_passphrase}" | sha256sum
```

Commit `secrets/tofu.sops.yaml` through a pull request. `check-sops-encrypted.sh`
asserts that it is ciphertext. Then, on `prometheus`, once it has pulled:

```bash
sops --decrypt secrets/tofu.sops.yaml | sed -n 's/^TOFU_STATE_PASSPHRASE: //p' | tr -d '\n' | sha256sum
```

The two hashes match. That proves the estate key can recover the state key.
Proving the second recipient through
[`back-up-the-age-key.md`](back-up-the-age-key.md) covers this file as well,
because the recipients are the same.

## 4. The first apply: the proof guest, and both halves of the proof

```bash
cd ~/code/Gerrrt/HomeLab
set -a; . ~/.config/proxmox/phoenix.env; set +a
umask 077
mkdir -p tofu/state && chmod 700 tofu/state
tofu -chdir=tofu init
tofu -chdir=tofu plan -var proof=true -out=proof.tfplan
tofu -chdir=tofu apply proof.tfplan && rm tofu/proof.tfplan
api() { printf 'header = "Authorization: PVEAPIToken=%s"\n' "${PROXMOX_VE_API_TOKEN}" | curl -K - -fsS "${PROXMOX_URL}$1"; }
api /nodes/Saruman/qemu/998/config | jq '.data | {name, tags, scsi0, net0}'
api /pools/proof | jq -r '.data.members[].vmid'
```

`umask 077` is not optional. tofu creates the state file under the shell's
umask, and the first apply, under Ubuntu's 002, wrote it 664: readable by every
account on `phoenix`. It is ciphertext, but ADR-0076 counts file permissions as
part of the control. Any later shell that runs tofu here needs the same
`umask`. The directory's 700 covers a file created without it.

The plan adds three things: the `proof` pool, a password, and guest 998.
`scsi0` is on `large_data`, `tags` reads `disposable;tofu`, and the pool's only
member is 998.

**Half one: the state holds no secret.** The proof guest's cloud-init password
was sent to Proxmox by the provider, so an unencrypted state would hold it.
Pipe it in. Never pass it as an argument:

```bash
tofu -chdir=tofu output -raw proof_password \
  | scripts/check-tofu-state-encryption.sh tofu/state/lab.tfstate
grep -cF -f <(printf '%s\n' "${TF_VAR_state_passphrase}") tofu/state/lab.tfstate   # 0
```

Two PASS lines: the file is the encrypted wrapper, and the password does not
occur in it. The `grep` shows the key is not in it either.

**Half two: git refuses it, and validation catches it when forced.**

```bash
git add tofu/state/lab.tfstate; echo "exit $?"   # "ignored by one of your .gitignore files", exit 1
git add -f tofu/state/lab.tfstate
scripts/check-tracked-artefacts.sh; echo "exit $?"  # names tofu/state/lab.tfstate, exit 1
git reset -q tofu/state/lab.tfstate
git status --short tofu/                           # nothing
```

`make validate` goes red on the same tracked file, because it calls the same
script. Running that script is enough here, since `phoenix` has no Docker for
the rest of `make validate`.

**Then destroy it.** Turning `proof` off removes guest 998, and with it the
`proof` pool:

```bash
tofu -chdir=tofu apply -var proof=false
api /pools | jq -r '.data[].poolid'
```

`proof` is not in the list, and `qm list` on `Saruman` has no 998. The
`/pool/proof` grant is gone too, because Proxmox deletes a pool's ACL with the
pool. `pveum acl list | grep phoenix` on `Saruman` no longer shows it. That is
expected, and it means a later proof starts at §2 again. If it is
left behind, `DisposableGuestOutlived` fires a fortnight later, because the
guest is tagged `disposable`.

Record the date, and the PASS lines from half one, in §6.

## 5. Adding a guest

Add an entry to `locals` in `tofu/guests.tf`. Give the new pool a grant in §2
first, then run plan and apply as in §4. The module refuses:

- a VMID inside the template range;
- a template that is not one of `packer/`'s.

A Windows guest takes no `initialization` block, because its first-boot answers
come from the template's sysprep answer file (ADR-0074 §3).

A plan that says `must be replaced` for a guest that exists is a stop, not a
step. Read why before applying. A changed template VMID or clone setting
replaces the guest, and replacing it re-clones it from scratch.

## 6. As run

| Date | What | Result |
| --- | --- | --- |
| 2026-10-03 | §1 tofu 1.13.1 and sops 3.13.3, both checksum-verified | Installed in `/usr/local/bin`. `phoenix.env` gained its three lines: `passphrase length 44`, `API 200` |
| 2026-10-03 | §2 grant, as root on `Saruman` | `Pool.Allocate` and `Pool.Audit` on `PhoenixBuilder`, and the ACL on `/pool/proof`. Proxmox accepted an ACL on a pool that did not exist yet |
| 2026-10-03 | §3 escrow written on `phoenix` | 2 recipients, the catch-all's two. `sops --decrypt` fails on `phoenix`, as designed. Committed as `secrets/tofu.sops.yaml` |
| 2026-10-03 | §3 hashes compared on `prometheus` | Equal. The estate key recovers the state key |
| 2026-10-03 | §4 apply, `-var proof=true` | Plan: 3 to add. 998 `tofu-proof` came up as a full clone of 901: `tags` `disposable;tofu`, `scsi0` on `large_data` (32G, discard, iothread, ssd), `balloon 0`, host CPU. The `proof` pool's only member was 998 |
| 2026-10-03 | §4 half one, `check-tofu-state-encryption.sh` on the real state | Two PASS: the encrypted wrapper with no gitleaks match, and the proof password absent. The passphrase grep returned `0`. The state file was mode 664, found from `Saruman` and fixed (`umask 077` above) |
| 2026-10-03 | §4 half two, `git add` refused, and `-f` caught | `git add` refused: "ignored by one of your .gitignore files", exit 1. With `-f`, `check-tracked-artefacts.sh` named `tofu/state/lab.tfstate`, exit 1. Reset, and nothing was left staged |
| 2026-10-03 | §4 proof guest and `proof` pool destroyed | `-var proof=false`: 3 destroyed. From `Saruman`: no 998, no pools, no `vm-998` disk on `large_data`, and no `/pool/proof` ACL. Proxmox deleted the grant with the pool, as §2 says |
| 2026-10-06 | `PhoenixHostKeys` grant, as root on `Saruman` ([#846](https://github.com/Gerrrt/HomeLab/issues/846), [`build-the-lab-domain.md`](build-the-lab-domain.md#run-it-from-phoenix)) | Role created with `VM.GuestAgent.FileRead` alone and granted to `phoenix@pve` on `/pool/lab-domain` (no such pool yet; accepted, as `/pool/proof` was) and on `/vms/150`–`/vms/155`. `PhoenixBuilder` unchanged. With `phoenix`'s token, `agent/file-read` returned `bahamut`'s host key from 150, and was refused on 160 (`odin`): `Permission check failed (/vms/160, VM.GuestAgent.FileRead\|VM.GuestAgent.Unrestricted)`. The six VMID grants go with their guests on a destroy; the pool grant is the one that outlives a rebuild |

## Recovery: `phoenix` is gone

The state is only recoverable if its file is. Take it from `phoenix`'s backup.
The passphrase comes from escrow, on `prometheus`:

```bash
sops --decrypt secrets/tofu.sops.yaml   # TOFU_STATE_PASSPHRASE
```

Carry it to the rebuilt `phoenix` by hand, as `TF_VAR_state_passphrase` in
`phoenix.env`, and run `tofu -chdir=tofu plan`. No changes means the state and
the key are back.

If the state file is lost and only the guests remain, write `import` blocks for
them. That makes a state again, and nothing here is destroyed for want of one.
