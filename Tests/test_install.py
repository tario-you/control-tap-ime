import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("installer", Path(__file__).resolve().parents[1] / "scripts/install.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)
RULE = json.loads((installer.ROOT / "karabiner/control-tap-ime.json").read_text())["rules"][0]


class InstallTests(unittest.TestCase):
    def original(self):
        return json.dumps({"global": {"show_in_menu_bar": False}, "profiles": [
            {"selected": False, "name": "unused", "complex_modifications": {"rules": []}},
            {"selected": True, "name": "active", "devices": [{"ignore": False}],
             "complex_modifications": {"rules": [{"description": "unrelated", "manipulators": []}]}}]}, indent=4)

    def test_add_is_idempotent_and_preserves_unrelated_bytes(self):
        original = self.original()
        patched = installer.patch_rule(original, RULE)
        self.assertEqual(installer.patch_rule(patched, RULE), patched)
        self.assertIn('"description": "unrelated",\n', patched)
        parsed = json.loads(patched)
        self.assertEqual(parsed["profiles"][0], json.loads(original)["profiles"][0])
        self.assertEqual(parsed["profiles"][1]["devices"], [{"ignore": False}])
        self.assertEqual(len(parsed["profiles"][1]["complex_modifications"]["rules"]), 2)

    def test_remove_keeps_later_user_edits(self):
        patched = installer.patch_rule(self.original(), RULE)
        parsed = json.loads(patched)
        parsed["profiles"][1]["complex_modifications"]["rules"].append({"description": "new user work"})
        result = json.loads(installer.patch_rule(json.dumps(parsed), RULE, remove=True))
        self.assertEqual([r["description"] for r in result["profiles"][1]["complex_modifications"]["rules"]],
                         ["unrelated", "new user work"])

    def test_empty_and_single_rule_arrays(self):
        original = '{"profiles":[{"selected":true,"complex_modifications":{"rules":[]}}]}'
        patched = installer.patch_rule(original, RULE)
        self.assertEqual(json.loads(installer.patch_rule(patched, RULE, remove=True)), json.loads(original))

    def test_existing_control_mapping_is_not_overridden(self):
        original = json.loads(self.original())
        original["profiles"][1]["complex_modifications"]["rules"][0]["manipulators"] = [
            {"from": {"key_code": "left_control"}}]
        with self.assertRaises(ValueError):
            installer.patch_rule(json.dumps(original), RULE)

    def test_concurrent_edit_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.json"
            path.write_bytes(b"new user work")
            with self.assertRaises(RuntimeError):
                installer.atomic_write(path, b"replace", expected=b"stale snapshot")
            self.assertEqual(path.read_bytes(), b"new user work")

    def test_symlink_is_not_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "original"
            target.write_bytes(b"user data")
            link = Path(directory) / "link"
            link.symlink_to(target)
            with self.assertRaises(ValueError):
                installer.atomic_write(link, b"replace")
            self.assertEqual(target.read_bytes(), b"user data")


if __name__ == "__main__":
    unittest.main()
