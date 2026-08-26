import gzip
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class GzipCodecTests(unittest.TestCase):
    def test_swift_and_python_gzip_are_bidirectionally_compatible(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            binary = tmp / "gzip-check"
            plain = tmp / "plain.json"
            python_gzip = tmp / "python.json.gz"
            swift_gzip = tmp / "swift.json.gz"
            payload = ('{"设备":"办公室 Mac","projects":[' + ','.join('"secret"' for _ in range(5000)) + ']}').encode()
            plain.write_bytes(payload)
            python_gzip.write_bytes(gzip.compress(payload, mtime=0))
            subprocess.run([
                "swiftc", "-parse-as-library",
                str(ROOT / "Tokei/Sources/Tokei/GzipCodec.swift"),
                str(ROOT / "tests/swift/GzipCodecCheck.swift"),
                "-o", str(binary),
            ], check=True, cwd=ROOT)
            result = subprocess.run([str(binary), str(plain), str(python_gzip), str(swift_gzip)],
                                    check=True, capture_output=True, text=True)
            self.assertIn("gzip codec checks passed", result.stdout)
            self.assertEqual(gzip.decompress(swift_gzip.read_bytes()), payload)


if __name__ == "__main__":
    unittest.main()
