import unittest
from unittest.mock import Mock

from ben_isolation_matrix import PROD_URL, Api, IsolationError
from ben_visibility_receipt import outcomes


class VisibilityReceiptTests(unittest.TestCase):
    def test_two_tenant_projection(self):
        key = 'missions/REST'
        plan = {'identity': 'ben', 'target': 'production', 'walk': 'synthetic', 'cells': {
            key: {'operation': 'member-list', 'mode': 'list', 'aliases': ['own', 'shared']}}}
        observed = {'operation': 'member-list', 'outcome': 'visible', 'complete': True}
        receipt = dict(plan, cells={key: observed})
        for items, status in [(['shared', 'own'], 'PASS'), ([], 'BLOCKED'),
                              (['own', 'own'], 'BLOCKED'), (['other-private'], 'STOP')]:
            observed['aliases'] = items
            result = outcomes(plan, receipt)
            self.assertEqual(len(result), 18)
            self.assertTrue(result[key].startswith(status))
            self.assertTrue(result['missions/MCP'].startswith('BLOCKED'))
            self.assertNotIn('other-private', str(result))
        receipt['identity'] = 'operator'
        self.assertTrue(outcomes(plan, receipt)[key].startswith('BLOCKED'))

    def test_permission_denial_distinct_from_unsupported(self):
        key = 'secrets/MCP'
        plan = {'identity': 'ben', 'target': 'production', 'walk': 'synthetic', 'cells': {
            key: {'operation': 'names-only', 'mode': 'denied'}}}
        for observation, status in [('unsupported', 'BLOCKED'), ('permission_denied', 'PASS'),
                                    ('visible', 'STOP')]:
            receipt = dict(plan, cells={key: {'operation': 'names-only', 'outcome': observation}})
            self.assertTrue(outcomes(plan, receipt)[key].startswith(status))

    def test_legacy_production_modes_never_dispatch(self):
        for mode in ('prod-full', 'prod-readonly'):
            api = Api(PROD_URL, mode)
            api.opener = Mock()
            with self.assertRaises(IsolationError):
                api.call('GET', '/api/health')
            api.opener.open.assert_not_called()
