"""Run the synthetic BloodHound-style Neo4j differential regression suite."""
import os
from pathlib import Path
import subprocess

import angreal
from utils import ensure_extension_built, get_project_root

test = angreal.command_group(name="test", about="Run GraphQLite tests")


@test()
@angreal.command(name="bloodhound", about="Compare BloodHound-style queries with an empty Neo4j oracle")
@angreal.argument(name="neo4j_uri", long="neo4j-uri", default_value="",
                  help="Bolt URI of a disposable empty database (or set NEO4J_URI)")
@angreal.argument(name="extension", long="extension", default_value="",
                  help="Native extension to test; defaults to the local build")
@angreal.argument(name="output", long="output", default_value="build/bloodhound-parity.json",
                  help="JSON results and expected values")
def test_bloodhound(neo4j_uri: str = "", extension: str = "",
                   output: str = "build/bloodhound-parity.json") -> int:
    root = Path(get_project_root())
    if not extension:
        if not ensure_extension_built():
            return 1
        extension = str(next(path for path in (
            root / "build/graphqlite.dylib", root / "build/graphqlite.so",
            root / "build/graphqlite.dll") if path.exists()))
    python = os.environ.get("GQLITE_TEST_PYTHON", "python3")
    command = [python, str(root / "tests/bloodhound/compare.py"),
               "--extension", extension, "--output", output]
    if neo4j_uri:
        command += ["--neo4j-uri", neo4j_uri]
    return subprocess.run(command, cwd=root).returncode
