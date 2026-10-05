import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location(
    "assert_index", pathlib.Path(__file__).parent.parent / "scripts" / "assert-index-platforms.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

BOTH = ["linux/amd64", "linux/arm64"]


def image(arch):
    return {"digest": "sha256:" + arch, "platform": {"os": "linux", "architecture": arch}}


def attestation(of):
    return {
        "digest": "sha256:att" + of,
        "platform": {"os": "unknown", "architecture": "unknown"},
        "annotations": {"vnd.docker.reference.type": "attestation-manifest", "vnd.docker.reference.digest": of},
    }


class AssertIndex(unittest.TestCase):
    def test_full_index_with_attestations_passes(self):
        index = {"manifests": [image("amd64"), attestation("a"), image("arm64"), attestation("b")]}
        self.assertEqual(mod.problems(index, BOTH), [])

    def test_attestation_only_index_fails(self):
        index = {"manifests": [attestation("a"), attestation("b")]}
        self.assertEqual(len(mod.problems(index, BOTH)), 2)

    def test_missing_arch_fails(self):
        self.assertEqual(len(mod.problems({"manifests": [image("amd64"), attestation("a")]}, BOTH)), 1)

    def test_duplicate_arch_fails(self):
        index = {"manifests": [image("amd64"), image("amd64"), image("arm64")]}
        self.assertEqual(len(mod.problems(index, BOTH)), 1)

    def test_annotation_not_platform_marks_an_attestation(self):
        odd = attestation("a")
        odd["platform"] = {"os": "linux", "architecture": "amd64"}
        index = {"manifests": [odd, image("arm64")]}
        self.assertEqual(len(mod.problems(index, BOTH)), 1)

    def test_unexpected_platform_fails(self):
        index = {"manifests": [image("amd64"), image("arm64"), image("s390x")]}
        self.assertEqual(len(mod.problems(index, BOTH)), 1)

    def test_plain_manifest_is_not_an_index(self):
        self.assertEqual(len(mod.problems({"config": {}}, BOTH)), 1)


if __name__ == "__main__":
    unittest.main()
