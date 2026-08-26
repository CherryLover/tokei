import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class KeychainStoreTests(unittest.TestCase):
    def test_password_round_trip_update_and_delete(self):
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / "keychain-check"
            subprocess.run([
                "swiftc", "-parse-as-library", "-framework", "Security",
                str(ROOT / "Tokei/Sources/Tokei/KeychainStore.swift"),
                str(ROOT / "tests/swift/KeychainStoreCheck.swift"),
                "-o", str(binary),
            ], check=True, cwd=ROOT)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
            self.assertIn("keychain store checks passed", result.stdout)


if __name__ == "__main__":
    unittest.main()
