#!/usr/bin/env python3
"""Assert every container image this repository runs comes from compose.yaml.

`make backup` used to run a bare `alpine` — no tag, no digest — and it survived
every image check CI had, because all three are pattern matches and the defect
was the *absence* of a pattern:

  * the floating-tag check greps for a literal `:latest`, and a bare `alpine`
    has no tag to match;
  * the duplication check greps for `prom/` and `grafana/` prefixes, and
    `alpine` has neither;
  * the digest check reads `image:` lines out of compose.yaml, and a shell
    recipe is not compose.yaml.

That is #65. A grep cannot see a missing pin, so this parses instead.

The rule
--------
Every `docker run`, `docker pull` and `docker create` must carry, among its
arguments, at least one standalone token that resolves to scripts/image-for.sh:
either `$NAME`/`${NAME}` for a NAME assigned on a statement that mentions
image-for.sh in the same file, or an inline `$(... image-for.sh ...)`.

Scope is the Makefile, scripts/*.sh, the workflows, and fenced shell blocks in
the documents. A runbook is a shell recipe that a human executes, and
docs/runbooks/add-monitored-device.md pinned `grafana/alloy` by hand for exactly
as long as nothing checked it — the same argument check_docs.py makes for
extending CI into prose (#73).

Why traceability rather than "the image operand must be a variable"
-------------------------------------------------------------------
Two reasons, and the first is the important one.

`IMG=alpine` followed by `docker run "$IMG"` passes "must be a variable" and is
the identical defect. So is `IMG=alpine:3.22@sha256:...` — a digest written
anywhere but compose.yaml is one Dependabot cannot bump and `make pin-digests`
cannot re-resolve, which is the whole argument in the header of image-for.sh.
Tracing the name back to image-for.sh is what closes those; being a variable
closes nothing.

Second, identifying "the image operand" positionally requires a table of which
`docker run` flags consume a value (-v, --entrypoint, -w, --user, --network,
--security-opt, --mount, ...), maintained against Docker's CLI forever, where an
unknown value-taking flag silently becomes a false positive. It is already
broken here: the first positional in the snmp-generate recipe is `$${flags[@]}`,
a bash array. Requiring a traced token *somewhere* in the command needs no such
table.

The cost is that `docker run --label "from=$PROM_IMAGE" alpine tar` would pass.
That takes deliberate effort; the job of this check is to make the accident
impossible.

Known limits, stated rather than engineered away
------------------------------------------------
File scope is coarser than shell scope: a name traced in one workflow job
satisfies a use in another, which would fail loudly at run time with an empty
image argument. The trace does not verify image-for.sh was asked for a real
service; image-for.sh already exits 1 on that. restore-volumes.sh takes its
archiver from the backup manifest and only falls back to image-for.sh — that is
correct, because the manifest value was itself written from image-for.sh, and it
is the one place "same file" is doing real work. A heredoc body is parsed as
shell and would be flagged; a quoted string is a single token and would not.
podman and nerdctl are out of scope.

The socket rule
---------------
A `docker run` that binds /var/run/docker.sock must run the socket proxy: an
image traced to `image-for.sh docker-socket-proxy`, through a variable. `:ro`
on the socket does not stop POST /containers/create, so anything else holding
it is root on the host. check_compose_health.py asks the same question of the
compose files; this asks it of the shell, where deploy-agent.sh started
oracle's Alloy with the socket for months after #193 and #836 had taken it off
every compose-managed collector, because nothing that read shell looked.

There is deliberately no ignore mechanism. If a case needs one, the rule is
wrong — see the .gitleaksignore argument in the docstring of check_docs.py.

Usage: scripts/check_image_pins.py
"""
from __future__ import annotations

import pathlib
import re
import subprocess
import sys
from typing import Iterator, NamedTuple

# PyYAML is not guaranteed on a clean runner, and this script gates CI. Same
# install-rather-than-fail as check_docs.py and check_compose_health.py.
try:
    import yaml
except ModuleNotFoundError:
    print("installing PyYAML", file=sys.stderr)
    if subprocess.run(
        [sys.executable, "-m", "pip", "install", "--quiet",
         "--disable-pip-version-check", "pyyaml"],
        check=False,
    ).returncode:
        sys.exit("PyYAML is required and could not be installed")
    import yaml

REPO = pathlib.Path(__file__).resolve().parent.parent

RESOLVER = "image-for.sh"
# Stands in for a $( ... image-for.sh ... ) that has been lifted out of a line.
# A bare word, so the tokenizer yields it as its own argument.
RESOLVED = "\x00IMAGE_FOR\x00"
SUBST = "\x00SUBST\x00"

SHELL_GLOB = "scripts/*.sh"
WORKFLOW_GLOBS = (".github/workflows/*.yml", ".github/workflows/*.yaml")
MARKDOWN_GLOBS = ("*.md", "docs/*.md", "docs/**/*.md")
SHELL_FENCES = {"bash", "sh", "shell", "console"}

# Only run/pull/create: they are the verbs that fetch and execute an image.
# `docker compose` reads compose.yaml and needs no check of its own, and
# `docker image inspect` neither pulls nor runs.
SUBCOMMANDS = {"run", "pull", "create"}
# `docker container run`, `docker image pull` — the long forms of the same verbs.
MANAGEMENT = {"container", "image"}
# The handful of *global* flags that take a value. Unlike `docker run`'s flags
# this set is small and stable, and getting it wrong only skips an invocation.
GLOBAL_VALUE_FLAGS = {"--context", "--config", "--host", "-H", "--log-level",
                      "-l", "--tlscacert", "--tlscert", "--tlskey"}

VAR = re.compile(r"^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$")
ASSIGN = re.compile(
    r"""(?:^|[\s;&|("'])
        (?:export\s+|local\s+|declare\s+(?:-\w+\s+)*)?
        ([A-Za-z_][A-Za-z0-9_]*)=""",
    re.VERBOSE,
)
# A Make expansion, but never the `$$(` that escapes a shell substitution.
MAKE_REF = re.compile(r"(?<!\$)\$\(([A-Za-z_][A-Za-z0-9_]*)\)")
MAKE_ASSIGN = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*[:?+]?=\s*(.*)$")
FENCE = re.compile(r"^\s*(`{3,}|~{3,})\s*([A-Za-z0-9_+-]*)")


class Line(NamedTuple):
    """One logical (continuation-joined) line of shell."""

    lineno: int
    text: str
    context: str


# ---------------------------------------------------------------------------
# Readers — each source kind becomes a list of logical lines
# ---------------------------------------------------------------------------
def join_continuations(numbered: list[tuple[int, str]], context: str = "") -> list[Line]:
    """Join backslash-continued lines, keeping the first one's number."""
    out: list[Line] = []
    buf, start = "", 0
    for lineno, text in numbered:
        if not buf:
            start = lineno
        if text.endswith("\\"):
            buf += text[:-1] + " "
            continue
        out.append(Line(start, buf + text, context))
        buf = ""
    if buf:
        out.append(Line(start, buf, context))
    return out


def shell_lines(text: str) -> list[Line]:
    return join_continuations(list(enumerate(text.splitlines(), 1)))


def makefile_lines(text: str) -> list[Line]:
    """Recipe lines only, with Make expansions resolved before shell parsing.

    A variable definition is not a command, so only tab-indented recipe lines
    are in scope. Order matters twice over: Make's `$(NAME)` is expanded before
    `$$` is collapsed to `$`, or a `$$(cmd ...)` substitution is mangled into a
    Make reference and lost.
    """
    variables: dict[str, str] = {}
    for raw in text.splitlines():
        match = MAKE_ASSIGN.match(raw)
        if match:
            variables.setdefault(match.group(1), match.group(2).strip())
    for _ in range(5):  # resolve references between variables, bounded
        for name, value in list(variables.items()):
            variables[name] = MAKE_REF.sub(
                lambda m: variables.get(m.group(1), m.group(0)), value
            )

    numbered = []
    for lineno, raw in enumerate(text.splitlines(), 1):
        if not raw.startswith("\t"):
            continue
        line = raw[1:].lstrip().lstrip("@-+")
        # Expanded rather than blanked, so a future `$(DOCKER) run` is not a
        # blind spot. An unknown reference becomes an opaque word.
        line = MAKE_REF.sub(lambda m: variables.get(m.group(1), "MAKEVAR"), line)
        numbered.append((lineno, line.replace("$$", "$")))
    return join_continuations(numbered)


def _walk_runs(node, name: str = "") -> Iterator[tuple[object, str]]:
    """Yield every `run:` scalar node in a workflow, with its step name."""
    if isinstance(node, yaml.MappingNode):
        label = name
        for key, value in node.value:
            if getattr(key, "value", None) == "name" and isinstance(value, yaml.ScalarNode):
                label = value.value
        for key, value in node.value:
            if getattr(key, "value", None) == "run" and isinstance(value, yaml.ScalarNode):
                yield value, label
            else:
                yield from _walk_runs(value, label)
    elif isinstance(node, yaml.SequenceNode):
        for item in node.value:
            yield from _walk_runs(item, name)


def workflow_lines(path: pathlib.Path) -> list[Line]:
    """Let PyYAML own block-scalar parsing — indentation and style are its job."""
    out: list[Line] = []
    root = yaml.compose(path.read_text(encoding="utf-8"))
    if root is None:
        return out
    for node, name in _walk_runs(root):
        # start_mark is the `run:` line itself. A block scalar's content starts
        # on the line after it; an inline scalar starts on it.
        base = node.start_mark.line + (2 if node.style in ("|", ">") else 1)
        numbered = [(base + i, t) for i, t in enumerate(node.value.splitlines())]
        out.extend(join_continuations(numbered, context=name))
    return out


def markdown_lines(text: str) -> list[Line]:
    """Fenced shell blocks only. Prose that merely names a command is not one."""
    out: list[Line] = []
    fence, numbered = "", []
    for lineno, raw in enumerate(text.splitlines(), 1):
        match = FENCE.match(raw)
        if fence:
            if match and match.group(1).startswith(fence):
                out.extend(join_continuations(numbered))
                fence, numbered = "", []
            else:
                numbered.append((lineno, raw))
        elif match and match.group(2).lower() in SHELL_FENCES:
            fence = match.group(1)
    out.extend(join_continuations(numbered))
    return out


# ---------------------------------------------------------------------------
# Shell parsing
# ---------------------------------------------------------------------------
def statements(text: str) -> list[str]:
    """Split on `;`, `&&` and `||` at paren depth zero, outside quotes.

    Statement granularity is load-bearing for the trace. The snmp-generate
    recipe is a single forty-line continued logical line; tracing it whole would
    mark every variable it assigns as coming from image-for.sh, which would let
    an unpinned image in through the same recipe.
    """
    out, cur, quote, depth, i = [], "", "", 0, 0
    while i < len(text):
        ch = text[i]
        if quote:
            cur += ch
            if ch == quote:
                quote = ""
            i += 1
            continue
        if ch in "\"'":
            quote, cur = ch, cur + ch
        elif ch == "(":
            depth, cur = depth + 1, cur + ch
        elif ch == ")":
            depth, cur = max(0, depth - 1), cur + ch
        elif depth == 0 and ch == ";":
            out.append(cur)
            cur = ""
        elif depth == 0 and text[i:i + 2] in ("&&", "||"):
            out.append(cur)
            cur, i = "", i + 2
            continue
        else:
            cur += ch
        i += 1
    out.append(cur)
    return [s for s in out if s.strip()]


def extract_substs(text: str) -> tuple[list[str], str]:
    """Lift every `$( )` body out as its own line to be parsed in its own right.

    A body that mentions image-for.sh collapses to RESOLVED, so the inline form
    `docker run ... "$(./scripts/image-for.sh archiver)" ...` — which
    docs/runbooks/restore-the-stack.md already uses — satisfies the rule
    directly rather than needing a variable to hold it.
    """
    inner: list[str] = []
    out, i = "", 0
    while i < len(text):
        if text.startswith("$(", i):
            depth, j = 1, i + 2
            while j < len(text) and depth:
                if text[j] == "(":
                    depth += 1
                elif text[j] == ")":
                    depth -= 1
                j += 1
            body = text[i + 2:j - 1] if depth == 0 else text[i + 2:]
            nested, flat = extract_substs(body)
            inner.extend(nested)
            inner.append(flat)
            out += RESOLVED if RESOLVER in body else SUBST
            i = j
            continue
        out += text[i]
        i += 1
    return inner, out


def segments(text: str) -> list[list[str]]:
    """Tokenize into pipeline/list segments, quote-aware.

    `{` and `}` are deliberately not separators. Treating them as such splits
    `${#vars[@]}` into `$` and a bare `#`, a naive comment rule then swallows
    the rest of the line, and the snmp-generate invocation disappears from the
    check entirely — a green run that examined nothing.
    """
    segs: list[list[str]] = []
    toks: list[str] = []
    cur, quote, started, i = "", "", False, 0

    def flush_token() -> None:
        nonlocal cur, started
        if cur or started:
            toks.append(cur)
        cur, started = "", False

    def flush_segment() -> None:
        nonlocal toks
        flush_token()
        if toks:
            segs.append(toks)
        toks = []

    while i < len(text):
        ch = text[i]
        if quote:
            if ch == quote:
                quote = ""
            elif ch == "\\" and quote == '"' and i + 1 < len(text):
                cur += text[i + 1]
                i += 2
                continue
            else:
                cur += ch
            i += 1
            continue
        if ch in "\"'":
            quote, started = ch, True
        elif ch == "\\" and i + 1 < len(text):
            cur, started = cur + text[i + 1], True
            i += 2
            continue
        elif ch == "#" and not cur and not started:
            break  # a comment, only ever at a word boundary
        elif ch.isspace():
            flush_token()
        elif ch in "|;&":
            flush_segment()
            while i < len(text) and text[i] in "|;&":
                i += 1
            continue
        elif ch in "()":
            flush_segment()
        else:
            cur, started = cur + ch, True
        i += 1
    flush_segment()
    return segs


def invocation(tokens: list[str]) -> list[str] | None:
    """Return the arguments of a `docker run|pull|create`, or None.

    The subcommand must follow `docker` adjacently, past global flags and an
    optional container/image management word. That is what keeps
    `docker compose run` out — compose reads compose.yaml, so it needs no check.
    """
    for i, tok in enumerate(tokens):
        if tok.rsplit("/", 1)[-1] != "docker":
            continue
        j = i + 1
        while j < len(tokens):
            tok = tokens[j]
            if tok.startswith("-"):
                j += 2 if tok in GLOBAL_VALUE_FLAGS else 1
            elif tok in MANAGEMENT:
                j += 1
            else:
                break
        if j < len(tokens) and tokens[j] in SUBCOMMANDS:
            return tokens[j + 1:]
        return None
    return None


# ---------------------------------------------------------------------------
def traced_names(lines: list[Line]) -> set[str]:
    """Names assigned on a statement that mentions image-for.sh."""
    traced: set[str] = set()
    for line in lines:
        for statement in statements(line.text):
            if RESOLVER in statement:
                traced.update(m.group(1) for m in ASSIGN.finditer(statement))
    # One fixpoint pass, so renaming through an intermediate stays traced.
    for _ in range(3):
        for line in lines:
            for statement in statements(line.text):
                match = ASSIGN.search(statement)
                if not match or match.group(1) in traced:
                    continue
                rest = statement[match.end():].strip().strip("\"'")
                ref = VAR.match(rest)
                if ref and ref.group(1) in traced:
                    traced.add(match.group(1))
    return traced


DOCKER_SOCKETS = ("/var/run/docker.sock", "/run/docker.sock")
SOCKET_DIRS = ("/run", "/var/run")
PROXY_SERVICE = "docker-socket-proxy"


def socket_reach(args: list[str]) -> str | None:
    """How a docker run's mounts reach the socket, or None.

    The same three shapes check_compose_health.py refuses (#836 review): the
    socket under either spelling, its directory, or the host's / without a
    --tmpfs over <target>/run. A read-only mount does not stop connect().
    """
    tmpfs = set()
    for i, a in enumerate(args):
        if a == "--tmpfs" and i + 1 < len(args):
            tmpfs.add(args[i + 1].split(":")[0].rstrip("/"))
        elif a.startswith("--tmpfs="):
            tmpfs.add(a.split("=", 1)[1].split(":")[0].rstrip("/"))
    for i, a in enumerate(args):
        spec = None
        if a in ("-v", "--volume") and i + 1 < len(args):
            spec = args[i + 1].split(":")
        elif a.startswith("--volume="):
            spec = a.split("=", 1)[1].split(":")
        elif a.startswith("type=bind") or "source=" in a and "target=" in a:
            kv = dict(p.split("=", 1) for p in a.split(",") if "=" in p)
            spec = [kv.get("source", kv.get("src", "")), kv.get("target", kv.get("dst", ""))]
        if not spec:
            continue
        source = spec[0].rstrip("/") or "/"
        target = (spec[1] if len(spec) > 1 else spec[0]).rstrip("/")
        if source in DOCKER_SOCKETS or source in SOCKET_DIRS:
            return f"binds {source}, which is or holds the Docker socket"
        if source == "/" and f"{target}/run" not in tmpfs:
            return (f"binds the host's / at {target} without --tmpfs {target}/run, "
                    f"so the Docker socket is at {target}/run/docker.sock")
    return None


def proxy_names(lines: list[Line]) -> set[str]:
    """Names assigned from `image-for.sh docker-socket-proxy`."""
    names: set[str] = set()
    for line in lines:
        for statement in statements(line.text):
            if RESOLVER in statement and PROXY_SERVICE in statement:
                names.update(m.group(1) for m in ASSIGN.finditer(statement))
    return names


def check_file(rel: str, lines: list[Line]) -> tuple[list[str], int]:
    traced = traced_names(lines)
    proxies = proxy_names(lines)
    problems, seen = [], 0
    for line in lines:
        pending = [line.text]
        while pending:
            inner, flat = extract_substs(pending.pop())
            pending.extend(inner)
            for tokens in segments(flat):
                args = invocation(tokens)
                if args is None:
                    continue
                seen += 1
                reach = socket_reach(args)
                if reach and not any(
                    VAR.match(a) and VAR.match(a).group(1) in proxies for a in args
                ):
                    where = f"{rel}:{line.lineno}"
                    problems.append(
                        f"{where}: this docker command {reach}, and is not the "
                        f"socket proxy. `:ro` does not stop connect() or POST "
                        f"/containers/create, so this is root on the host. Use "
                        f"the image from `image-for.sh {PROXY_SERVICE}` for the "
                        f"socket, and mask /run in a rootfs mount (#193, #836)"
                    )
                if any(
                    a == RESOLVED or (VAR.match(a) and VAR.match(a).group(1) in traced)
                    for a in args
                ):
                    continue
                where = f"{rel}:{line.lineno}"
                if line.context:
                    where += f" ({line.context})"
                problems.append(
                    f"{where}: this docker command runs an image that does not "
                    f"come from compose.yaml — resolve it with "
                    f"scripts/image-for.sh, adding a profile-gated stub service "
                    f"to stacks/observability/compose.yaml if the image is not "
                    f"a running one (see the `archiver` service, and #65)"
                )
    return problems, seen


def sources() -> list[tuple[str, list[Line]]]:
    out: list[tuple[str, list[Line]]] = []
    makefile = REPO / "Makefile"
    out.append(("Makefile", makefile_lines(makefile.read_text(encoding="utf-8"))))
    for path in sorted(REPO.glob(SHELL_GLOB)):
        out.append((str(path.relative_to(REPO)),
                    shell_lines(path.read_text(encoding="utf-8"))))
    for glob in WORKFLOW_GLOBS:
        for path in sorted(REPO.glob(glob)):
            out.append((str(path.relative_to(REPO)), workflow_lines(path)))
    seen: set[pathlib.Path] = set()
    for glob in MARKDOWN_GLOBS:
        for path in sorted(REPO.glob(glob)):
            if path in seen:
                continue
            seen.add(path)
            out.append((str(path.relative_to(REPO)),
                        markdown_lines(path.read_text(encoding="utf-8"))))
    return out


# ---------------------------------------------------------------------------
# The three pattern checks, folded in from ci.yml (#175)
# ---------------------------------------------------------------------------
# These were inline shell in the workflow and unrunnable locally. They belong
# here because this file already owns the argument: the docstring above explains
# why a grep cannot see a *missing* pin, and these three are the greps it is
# explaining. Keeping them beside the parser is what makes that paragraph
# checkable rather than a note about code somewhere else.
#
# Scope is `git ls-files`, not a recursive walk of the working tree. The shell
# versions walked `.`, which is fine in CI's clean checkout and wrong here: this
# repository keeps git worktrees under .claude/worktrees/, so a local run would
# have descended into full copies of itself and reported another branch's
# findings as this one's. Tracked files are also the right question — an
# untracked scratch file pinning :latest harms nobody.

VERSION_PIN = re.compile(
    r"(^|[^a-zA-Z0-9._/-])"
    r"[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._-]*:v?[0-9]+\.[0-9]+"
)
FLOATING = re.compile(r"(^|\s)[a-z0-9._/-]+:latest(\s|$)")
COMMENT = re.compile(r"^\s*#")

PIN_SCAN = ("scripts/", ".github/", "Makefile")
FLOAT_SUFFIXES = (".yaml", ".yml", ".sh")


def tracked_files() -> list[str]:
    out = subprocess.run(
        ["git", "ls-files"], cwd=REPO, capture_output=True, text=True, check=True
    )
    return out.stdout.splitlines()


def pattern_problems() -> list[str]:
    problems: list[str] = []
    files = tracked_files()

    for rel in files:
        path = REPO / rel
        if not path.is_file():
            continue
        in_pin_scan = rel.startswith(PIN_SCAN) or rel == "Makefile"
        is_float_scan = rel.endswith(FLOAT_SUFFIXES) or rel.endswith("Makefile")
        if not (in_pin_scan or is_float_scan):
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for n, line in enumerate(text.splitlines(), 1):
            if COMMENT.search(line):
                continue
            # compose.yaml is where a version is SUPPOSED to live.
            if in_pin_scan and VERSION_PIN.search(line):
                problems.append(
                    f"{rel}:{n} pins an image version outside compose.yaml — "
                    f"resolve it with scripts/image-for.sh"
                )
            if is_float_scan and FLOATING.search(line):
                problems.append(
                    f"{rel}:{n} uses a floating :latest tag — pin an explicit "
                    f"version"
                )
    return problems


def digest_problems() -> list[str]:
    """Every service image in every stack carries a digest.

    A tag is a mutable pointer and a digest is the content hash, so an image
    with only a tag can change what gets deployed without anything in this
    repository changing. Read off the parsed compose file rather than an awk
    over `image:` lines, so a quoted or flow-style value is not a hole.
    """
    problems = []
    composes = sorted(REPO.glob("stacks/*/compose.yaml"))
    if not composes:
        return ["no stacks/*/compose.yaml found — this check has stopped checking"]
    for cf in composes:
        doc = yaml.safe_load(cf.read_text(encoding="utf-8")) or {}
        for name, svc in (doc.get("services") or {}).items():
            image = (svc or {}).get("image")
            if image and "@sha256:" not in image:
                rel = cf.relative_to(REPO)
                problems.append(
                    f"{rel}: {name} image {image} is not pinned by digest — "
                    f"run make pin-digests"
                )
    return problems


# A per-architecture tag, the suffix some registries publish beside the
# multi-arch index: `1.13.1-386`, `0.156.0-amd64`. Optionally after another
# suffix, as in `1.13.1-minimal-386`.
ARCH_TAG = re.compile(r"-(?:386|amd64|arm64|arm|armv[0-9]+|ppc64le|s390x|riscv64)$")


def arch_tag_problems() -> list[str]:
    """No service image is pinned to a single-architecture tag.

    Dependabot parses a numeric suffix as a version segment, so it reads
    `1.13.1-386` as 1.13.1.386, newer than `1.13.1`, and proposes the 32-bit
    x86 image as an upgrade over the multi-arch index (dependabot-core#15718).
    It is a bare manifest, so it pulls without error on amd64 and runs a
    32-bit binary, and nothing else here would notice. It reached main once:
    #811 moved tofu, the binary that proves state encryption, to it.
    `-amd64` and the rest are refused too. They are not Dependabot's mistake,
    but a hand-written one would pin this estate to one CPU just as quietly.
    """
    problems = []
    for cf in sorted(REPO.glob("stacks/*/compose.yaml")):
        doc = yaml.safe_load(cf.read_text(encoding="utf-8")) or {}
        for name, svc in (doc.get("services") or {}).items():
            image = str((svc or {}).get("image") or "")
            ref = image.partition("@")[0]
            tag = ref.rpartition(":")[2] if ":" in ref.rpartition("/")[2] else ""
            if tag and ARCH_TAG.search(tag):
                problems.append(
                    f"{cf.relative_to(REPO)}: {name} image {ref} is a "
                    f"single-architecture tag — pin the multi-arch tag and its "
                    f"index digest (a Dependabot -386 bump is "
                    f"dependabot-core#15718; close it, do not merge it)"
                )
    return problems


def main() -> int:
    problems, sites, files = [], 0, 0
    problems.extend(pattern_problems())
    problems.extend(digest_problems())
    problems.extend(arch_tag_problems())
    for rel, lines in sources():
        found, seen = check_file(rel, lines)
        problems.extend(found)
        sites += seen
        files += 1 if seen else 0

    for problem in problems:
        print(f"  {problem}", file=sys.stderr)
    if problems:
        print(
            f"\n{len(problems)} image pin problem(s): a docker command running an "
            f"image from outside compose.yaml or holding the Docker socket, or "
            f"a compose image without a digest or on a single-architecture tag",
            file=sys.stderr,
        )
        return 1

    # The count is the point. A parser that quietly stops matching would
    # otherwise pass this check while examining nothing at all.
    print(
        f"image pins OK — {sites} docker run/pull/create invocation(s) across "
        f"{files} file(s), every image resolved from compose.yaml via "
        f"scripts/image-for.sh"
    )
    return 0


def self_test() -> int:
    """The socket rule against fixture shell; the image rule is CI's own run."""
    def problems(*text: str) -> int:
        lines = [Line(i + 1, t, "") for i, t in enumerate(text)]
        return sum("socket proxy" in p for p in check_file("fixture", lines)[0])

    img = 'IMAGE="$(./scripts/image-for.sh alloy)"'
    proxy = 'PROXY_IMAGE="$(./scripts/image-for.sh docker-socket-proxy)"'
    cases = [
        ("a collector holding the socket fails, even :ro", 1,
         (img, 'docker run -d -v /var/run/docker.sock:/var/run/docker.sock:ro "$IMAGE"')),
        ("the --mount form fails the same way", 1,
         (img, 'docker run -d --mount type=bind,source=/var/run/docker.sock,target=/s "$IMAGE"')),
        ("the proxy, traced by service, may hold it", 0,
         (proxy, 'docker run -d -v /var/run/docker.sock:/var/run/docker.sock:ro "$PROXY_IMAGE"')),
        ("any other traced image may not, whatever its variable is called", 1,
         ('PROXY_IMAGE="$(./scripts/image-for.sh alloy)"',
          'docker run -d -v /var/run/docker.sock:/var/run/docker.sock:ro "$PROXY_IMAGE"')),
        ("a run without the socket is not this rule's business", 0,
         (img, 'docker run -d -v /var/log:/var/log:ro "$IMAGE"')),
        ("/run/docker.sock is the same socket", 1,
         (img, 'docker run -d -v /run/docker.sock:/var/run/docker.sock "$IMAGE"')),
        ("the host's / without /run masked reaches the socket", 1,
         (img, 'docker run -d -v /:/rootfs:ro "$IMAGE"')),
        ("the host's / with --tmpfs <target>/run is fine", 0,
         (img, 'docker run -d -v /:/rootfs:ro --tmpfs /rootfs/run:size=64k "$IMAGE"')),
        ("a mask at the wrong path does not count", 1,
         (img, 'docker run -d -v /:/rootfs:ro --tmpfs /run "$IMAGE"')),
    ]
    failed = 0
    for name, want, text in cases:
        got = problems(*text)
        ok = got == want
        failed += not ok
        print(f"  {'PASS' if ok else 'FAIL'} {name}" + ("" if ok else f" (got {got}, expected {want})"))
    return 1 if failed else 0


if __name__ == "__main__":
    if "--self-test" in sys.argv[1:]:
        sys.exit(self_test())
    sys.exit(main())
