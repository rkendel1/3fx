import importlib.util
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'check-model-provider-boundary.py'
SPEC = importlib.util.spec_from_file_location('model_provider_boundary', SCRIPT)
BOUNDARY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BOUNDARY)


class ModelProviderBoundaryTests(unittest.TestCase):
    def audit(self, source, dependency=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            agent = root / 'src/core/agent'
            (agent / 'runtime').mkdir(parents=True)
            (agent / 'model_provider.zig').write_text(source)
            (agent / 'runtime/model_step.zig').write_text('const provider = @import("../model_provider.zig");')
            if dependency:
                (agent / 'nested.zig').write_text(dependency)
            previous = BOUNDARY.ROOT
            try:
                BOUNDARY.ROOT = root
                return BOUNDARY.audit(False)
            finally:
                BOUNDARY.ROOT = previous

    def test_neutral_std_only_contract_passes(self):
        self.assertEqual([], self.audit('const std = @import("std");\npub const Message = struct { content: []const u8 };'))

    def test_direct_legacy_import_fails(self):
        violations = self.audit('const legacy = @import("stream_provider.zig");')
        self.assertTrue(any('forbidden dependency' in item for item in violations))

    def test_transitive_credential_import_fails(self):
        violations = self.audit('const nested = @import("nested.zig");',
                                'const auth = @import("../auth/credentials.zig");')
        self.assertTrue(any('auth/credentials.zig' in item for item in violations))

    def test_control_plane_field_fails(self):
        violations = self.audit('pub const Request = struct { account_id: ?[]const u8 };')
        self.assertTrue(any('forbidden concept account_id' in item for item in violations))

    def test_test_only_compatibility_fixture_is_not_a_runtime_import(self):
        violations = self.audit('const std = @import("std");\ntest "fixture" { const legacy = @import("stream_provider.zig"); }')
        self.assertEqual([], violations)


if __name__ == '__main__':
    unittest.main()
