#!/usr/bin/env python3
"""Terraform external data source: return a Multipass VM's IPv4 address.

Input (stdin, JSON):  {"name": "<vm-name>"}
Output (stdout, JSON): {"ip": "<ipv4>"}
"""
import json
import subprocess
import sys

query = json.load(sys.stdin)
name = query["name"]

result = subprocess.run(
    ["multipass", "info", name, "--format", "json"],
    capture_output=True,
    text=True,
)
if result.returncode != 0:
    sys.stderr.write(f"multipass info {name} failed: {result.stderr}\n")
    sys.exit(1)

ipv4 = json.loads(result.stdout)["info"][name].get("ipv4", [])
if not ipv4:
    sys.stderr.write(f"VM {name} has no IPv4 address yet\n")
    sys.exit(1)

json.dump({"ip": ipv4[0]}, sys.stdout)
