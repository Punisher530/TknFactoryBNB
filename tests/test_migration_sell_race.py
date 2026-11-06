"""Demonstrates a liveness regression in a split buy / graduate prototype.
These are exact-integer model calculations, NOT EVM transactions.
"""
import unittest

E = 10**18
CURVE = 800_000_000 * E
LP = 200_000_000 * E
OFFSET = LP * CURVE // (CURVE - LP)
INIT_VTOK = CURVE + OFFSET
VBNB = 250_000_000_000_000_000
K = INIT_VTOK * VBNB

def ceildiv(a, b): return (a + b - 1) // b if a else 0

class TinySellGriefing(unittest.TestCase):
    def test_one_wei_token_sale_reopens_exhausted_curve(self):
        end_vbnb = ceildiv(K, OFFSET)
        net_to_finish = end_vbnb - VBNB
        self.assertEqual(net_to_finish, 750_000_000_000_000_001)
        remaining, reserve, virtual_bnb = 0, net_to_finish, end_vbnb
        sold_tokens = 1
        bnb_after_sell = ceildiv(K, OFFSET + sold_tokens)
        gross = virtual_bnb - bnb_after_sell
        fee = gross * 100 // 10000
        native_credit = gross - fee
        self.assertEqual(native_credit, 1)
        remaining += sold_tokens
        reserve -= gross
        virtual_bnb = bnb_after_sell
        self.assertEqual(remaining, 1)
        self.assertNotEqual(remaining, 0)  # graduate() reverts
        net_required = end_vbnb - virtual_bnb
        gross_required = ceildiv(net_required * 10000, 9900)
        self.assertEqual(net_required, 1)
        self.assertEqual(gross_required, 2)
        remaining = 0
        self.assertEqual(remaining, 0)

if __name__ == '__main__': unittest.main()
