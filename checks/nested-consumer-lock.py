#!/usr/bin/env python3
"""Exercise a real Network snapshot through a committed nested flake consumer.

Usage: checks/nested-consumer-lock.py [--source DIRECTORY] [--nix PATH]
Evidence is retained in .work/verification/nested-lock-unique/run.*.
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent
EVIDENCE = ROOT / ".work/verification/nested-lock-unique"
GIT_ID = ["-c", "user.name=Nested lock check", "-c", "user.email=check@example.invalid"]


def require(value, message):
    if not value:
        raise ValueError(message)


def command(args, log, cwd=None, env=None, data=None):
    started = time.monotonic()
    with log.open("w") as output:
        if data is None:
            result = subprocess.run(args, cwd=cwd, env=env, stdout=output, stderr=subprocess.STDOUT, check=False)
        else:
            with data.open("w") as values:
                result = subprocess.run(args, cwd=cwd, env=env, stdout=values, stderr=output, check=False)
        output.write(f"\nexit={result.returncode} elapsed_seconds={time.monotonic() - started:.3f}\n")
    print(f"{'PASS' if result.returncode == 0 else 'FAIL'} {log.name} ({time.monotonic() - started:.1f}s)", flush=True)
    require(result.returncode == 0, f"{args[0]} failed; see {log}")


def capture(args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def write_flake(path, source):
    path.write_text(source)


def commit(path, message, log):
    command(["git", "add", "-A"], log.with_name(log.stem + "-add.log"), cwd=path)
    command(["git", *GIT_ID, "commit", "-m", message], log, cwd=path)
    return capture(["git", "rev-parse", "HEAD"], cwd=path)


def git_url(path, rev):
    return f"git+file://{path}?rev={rev}"


def snapshot(source, target, log):
    # Preserve all nonignored candidate files, including staged and unstaged
    # edits, without accidentally including ignored verification artifacts.
    files = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=source
    ).split(b"\0")
    target.mkdir()
    copied = 0
    for raw in files:
        if not raw:
            continue
        relative = Path(os.fsdecode(raw))
        if relative.parts[0] in (".git", ".work"):
            continue
        origin = source / relative
        destination = target / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        if origin.is_symlink():
            destination.symlink_to(os.readlink(origin))
        elif origin.is_file():
            shutil.copy2(origin, destination)
        else:
            continue
        copied += 1
    require((target / "flake.nix").is_file() and (target / "flake.lock").is_file(), "source lacks flake files")
    command(["git", "init", "-q"], log.with_name("candidate-init.log"), cwd=target)
    revision = commit(target, "Network candidate", log)
    print(f"candidate files={copied} revision={revision}", flush=True)
    return revision


def resolved_input(lock, node, name, resolving=frozenset()):
    marker = (node, name)
    require(marker not in resolving, f"cyclic follows at {node}.{name}")
    link = lock["nodes"][node]["inputs"][name]
    if isinstance(link, str):
        return link
    require(isinstance(link, list), f"invalid lock input at {node}.{name}")
    current = lock["root"]
    for component in link:
        current = resolved_input(lock, current, component, resolving | {marker})
    return current


def corresponding_graph(left, left_root, right, right_root):
    pending = [(left_root, right_root)]
    forward, backward = {}, {}
    while pending:
        a, b = pending.pop()
        require(forward.get(a, b) == b and backward.get(b, a) == a, "dependency convergence differs")
        forward[a], backward[b] = b, a
        a_node, b_node = left["nodes"][a], right["nodes"][b]
        if a != left_root:
            require(a_node["locked"] == b_node["locked"], f"dependency source differs: {a}")
            require(a_node["original"] == b_node["original"], f"dependency origin differs: {a}")
        a_inputs, b_inputs = a_node.get("inputs", {}), b_node.get("inputs", {})
        require(a_inputs.keys() == b_inputs.keys(), f"dependency inputs differ: {a}")
        for name in a_inputs:
            pair = (resolved_input(left, a, name), resolved_input(right, b, name))
            if pair not in forward.items():
                pending.append(pair)
        require(a_node.get("flake", True) == b_node.get("flake", True), f"flake property differs: {a}")
    return len(forward) - 1


def direct(lock, node, name):
    return resolved_input(lock, node, name)


def validate(candidate, consumer, wrapper_revision, candidate_revision):
    root = consumer["root"]
    network = direct(consumer, root, "network")
    wrapper = direct(consumer, root, "wrapper")
    via_wrapper = direct(consumer, wrapper, "network")
    require(
        consumer["nodes"][network]["locked"] == consumer["nodes"][via_wrapper]["locked"]
        and consumer["nodes"][network]["original"] == consumer["nodes"][via_wrapper]["original"],
        "direct and wrapper Network sources differ",
    )
    require(consumer["nodes"][network]["locked"]["rev"] == candidate_revision, "consumer Network revision differs")
    require(consumer["nodes"][wrapper]["locked"]["rev"] == wrapper_revision, "consumer wrapper revision differs")
    count = corresponding_graph(candidate, candidate["root"], consumer, network)
    corresponding_graph(candidate, candidate["root"], consumer, via_wrapper)
    for selected in (network, via_wrapper):
        clan = direct(consumer, selected, "clan-core")
        require(direct(consumer, clan, "data-mesher") == selected, "Clan data-mesher does not resolve to Network")
    print(f"source graph={count} dependencies; direct/wrapper source identity=PASS")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT)
    parser.add_argument("--nix", default=os.environ.get("NIX_BIN", "nix"))
    args = parser.parse_args()
    source = args.source.resolve()
    require((source / ".git").exists(), "source must be a Git checkout")
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix="run.", dir=EVIDENCE))
    print(f"evidence={run}", flush=True)
    env = dict(os.environ, XDG_CACHE_HOME=str(run / "cache"))
    command([args.nix, "--version"], run / "nix-version.log", env=env)
    candidate = run / "network"
    revision = snapshot(source, candidate, run / "candidate-commit.log")
    nix = [args.nix, "--extra-experimental-features", "nix-command flakes"]

    # The wrapper is an independent committed flake, like a released Apps
    # dependency, and its Network URL points at an exact Git revision.
    wrapper = run / "wrapper"
    wrapper.mkdir()
    write_flake(wrapper / "flake.nix", '''{
  inputs.network.url = %s;
  outputs = { self, network }: {
    public = {
      contracts = network.lib.checkContracts;
      modules = builtins.attrNames network.clan.modules;
      dataMesher = builtins.isFunction network.nixosModules.data-mesher;
    };
  };
}
''' % json.dumps(git_url(candidate, revision)))
    command(["git", "init", "-q"], run / "wrapper-init.log", cwd=wrapper)
    commit(wrapper, "Wrapper source", run / "wrapper-source-commit.log")
    command(nix + ["flake", "lock", f"path:{wrapper}"], run / "wrapper-lock.log", env=env)
    wrapper_revision = commit(wrapper, "Wrapper lock", run / "wrapper-lock-commit.log")

    consumer = run / "consumer"
    consumer.mkdir()
    def consumer_source(network_revision, wrapper_rev):
        return '''{
  inputs.network.url = %s;
  inputs.wrapper.url = %s;
  outputs = { self, network, wrapper }: {
    public = {
      direct = {
        contracts = network.lib.checkContracts;
        modules = builtins.attrNames network.clan.modules;
        dataMesher = builtins.isFunction network.nixosModules.data-mesher;
      };
      inherited = wrapper.public;
    };
  };
}
''' % (json.dumps(git_url(candidate, network_revision)), json.dumps(git_url(wrapper, wrapper_rev)))
    write_flake(consumer / "flake.nix", consumer_source(revision, wrapper_revision))
    command(nix + ["flake", "lock", f"path:{consumer}"], run / "fresh-consumer-lock.log", env=env)
    command(nix + ["eval", "--json", "--no-update-lock-file", f"path:{consumer}#public"], run / "fresh-public-eval.log", env=env, data=run / "fresh-public-eval.json")
    first_public = json.loads((run / "fresh-public-eval.json").read_text())
    require(first_public["direct"] == first_public["inherited"], "direct and wrapper public outputs differ")
    require(first_public["direct"]["contracts"] and first_public["direct"]["modules"] and first_public["direct"]["dataMesher"], "public output is empty")
    candidate_lock = json.loads((candidate / "flake.lock").read_text())
    validate(candidate_lock, json.loads((consumer / "flake.lock").read_text()), wrapper_revision, revision)
    initial_lock = (consumer / "flake.lock").read_bytes()
    command(nix + ["flake", "lock", f"path:{consumer}"], run / "fresh-repeat-lock.log", env=env)
    require((consumer / "flake.lock").read_bytes() == initial_lock, "fresh lock changed on repeat")

    # Change both committed sources and update the existing valid consumer
    # lock with ordinary Nix input updates.
    (candidate / "nested-lock-revision.txt").write_text("second candidate revision\n")
    revision = commit(candidate, "Network candidate revision two", run / "candidate-update-commit.log")
    write_flake(wrapper / "flake.nix", (wrapper / "flake.nix").read_text().replace(
        git_url(candidate, capture(["git", "rev-parse", "HEAD^"], cwd=candidate)), git_url(candidate, revision)
    ))
    command(nix + ["flake", "update", "network", "--flake", f"path:{wrapper}"], run / "wrapper-update-lock.log", env=env)
    wrapper_revision = commit(wrapper, "Wrapper Network update", run / "wrapper-update-commit.log")
    write_flake(consumer / "flake.nix", consumer_source(revision, wrapper_revision))
    command(nix + ["flake", "update", "network", "wrapper", "--flake", f"path:{consumer}"], run / "consumer-update-lock.log", env=env)
    command(nix + ["eval", "--json", "--no-update-lock-file", f"path:{consumer}#public"], run / "updated-public-eval.log", env=env, data=run / "updated-public-eval.json")
    updated_public = json.loads((run / "updated-public-eval.json").read_text())
    require(updated_public == first_public, "public outputs changed after lock update")
    candidate_lock = json.loads((candidate / "flake.lock").read_text())
    validate(candidate_lock, json.loads((consumer / "flake.lock").read_text()), wrapper_revision, revision)
    updated_lock = (consumer / "flake.lock").read_bytes()
    command(nix + ["flake", "lock", f"path:{consumer}"], run / "updated-repeat-lock.log", env=env)
    require((consumer / "flake.lock").read_bytes() == updated_lock, "updated lock changed on repeat")
    print("fresh lock, public evaluation, source identity, update, and repeated locks passed", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError) as error:
        print(f"nested consumer lock check failed: {error}", file=sys.stderr)
        sys.exit(1)
