import contextlib
import io
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from solara_cli import cli, endpoint, identity, skills

INSTALL_SCRIPT = Path(__file__).resolve().parents[1] / "install.sh"


class Product(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="solara-identity-")).resolve()
        self.addCleanup(shutil.rmtree, self.home, True)

    def test_help_names_the_product_and_command(self):
        for command in (["exec"], ["scripts"], ["scripts", "test"], ["scripts", "install"], ["skills", "install"]):
            out = io.StringIO()
            with contextlib.redirect_stdout(out), self.assertRaises(SystemExit):
                cli.build_parser().parse_args([*command, "--help"])
            self.assertIn(f"usage: {identity.COMMAND} {' '.join(command)}", out.getvalue())
            self.assertIn(identity.PRODUCT, out.getvalue())
        self.assertIn(f"Run Python against the running {identity.PRODUCT}", cli.EXEC_DESCRIPTION)
        self.assertIn(f"{identity.COMMAND} exec 'await tab.title()'", cli.EXEC_DESCRIPTION)
        self.assertIn("SolaraControl.json", cli.EXEC_EPILOG)
        self.assertIn("$SOLARA_DATA_DIR", cli.EXEC_EPILOG)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            cli.main(["--version"])
        self.assertTrue(out.getvalue().startswith(f"{identity.COMMAND} "))

    def test_the_installed_data_dir_uses_the_bundle_id(self):
        with mock.patch.dict(os.environ, {"HOME": str(self.home)}):
            os.environ.pop("SOLARA_DATA_DIR", None)
            expected = Path.home() / "Library" / "Application Support" / identity.BUNDLE_ID
            self.assertEqual(endpoint.installed_data_dir(), expected)
            self.assertEqual(endpoint.data_root(), expected)
            os.environ["SOLARA_DATA_DIR"] = str(self.home / "scratch")
            self.assertEqual(endpoint.data_root(), self.home / "scratch")

    def test_the_skill_installs_its_source_verbatim(self):
        with mock.patch.object(Path, "home", lambda: self.home), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(skills.install(["claude-code"], False), 0)
            self.assertEqual(skills.install(["claude-code"], False), 0)
        folder = self.home / ".claude" / "skills" / identity.COMMAND
        self.assertTrue(skills.is_ours(folder))
        for source in skills.skill_source().rglob("*.md"):
            installed = folder / source.relative_to(skills.skill_source())
            self.assertEqual(installed.read_bytes(), source.read_bytes())


@unittest.skipUnless(sys.platform == "darwin" and os.uname().machine == "arm64", "install.sh runs on Apple silicon only")
class Installer(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="solara-install-")).resolve()
        self.addCleanup(shutil.rmtree, self.root, True)
        self.home = self.root / "home"
        self.home.mkdir()

    def tarball(self, says: str, version: str = "1.2.3") -> str:
        top = self.root / "src" / f"solara-cli-{version}"
        (top / "bin").mkdir(parents=True, exist_ok=True)
        launcher = top / "bin" / "solara"
        launcher.write_text(f"#!/bin/sh\necho '{says} {version}'\n")
        launcher.chmod(0o755)
        path = self.root / f"solara-cli-{version}-macos-arm64.tar.gz"
        with tarfile.open(path, "w:gz") as archive:
            archive.add(top, arcname=top.name)
        digest = subprocess.run(["shasum", "-a", "256", str(path)], capture_output=True, text=True, check=True).stdout
        Path(f"{path}.sha256").write_text(digest)
        return path.as_uri()

    def install(self, url: str, *flags: str) -> subprocess.CompletedProcess:
        env = {key: value for key, value in os.environ.items() if not key.startswith("SOLARA_CLI_")}
        env.update(HOME=str(self.home), SOLARA_CLI_URL=url, SHELL="/bin/zsh")
        return subprocess.run(["/bin/sh", str(INSTALL_SCRIPT), *flags], env=env, capture_output=True, text=True, timeout=120)

    def test_solara_installs_its_command_and_home(self):
        result = self.install(self.tarball("solara"), "--product", "Solara", "--repo", "andrewbenson/solara")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        link = self.home / ".local" / "bin" / "solara"
        cli_home = self.home / "Library" / "Application Support" / "Solara" / "CLI"
        self.assertIn(f"installed {link}", result.stdout)
        self.assertEqual(os.readlink(link), str(cli_home / "current" / "bin" / "solara"))
        self.assertEqual(os.readlink(cli_home / "current"), "1.2.3")
        result = self.install(self.tarball("solara"), "--product", "Solara", "--uninstall")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(link.is_symlink())
        self.assertFalse((cli_home / "current").is_symlink())
        self.assertFalse((cli_home / "1.2.3").exists())

    def test_a_tarball_baked_for_another_app_is_refused(self):
        result = self.install(self.tarball("other"), "--product", "Solara")
        self.assertEqual(result.returncode, 1)
        self.assertIn("error the tarball is for another app: it says other 1.2.3, not solara 1.2.3", result.stdout)
        self.assertFalse((self.home / ".local" / "bin" / "solara").exists())

    def test_bad_names_are_refused(self):
        for flags in (["--product", "../x"], ["--product", "My App"], ["--repo", "no-slash"], ["--repo", "a/b c"]):
            result = self.install(self.tarball("solara"), *flags)
            self.assertEqual(result.returncode, 1, flags)
            self.assertTrue(result.stdout.startswith("error bad --"), result.stdout)


if __name__ == "__main__":
    unittest.main()
