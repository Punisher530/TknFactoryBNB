"""Static guards and deterministic integer-model tests.
Run: python -m unittest discover -s tests -v
Not Solidity EVM execution or BSC fork tests.
"""
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1] / "contracts/BNBBondingLaunchpadV14.sol"
E=10**18
BPS=10000
CURVE=800_000_000*E
LP=200_000_000*E
OFF=LP*CURVE//(CURVE-LP)
INIT=CURVE+OFF
V=250_000_000_000_000_000
K=INIT*V

def ceildiv(a,b):return (a+b-1)//b if a else 0

def initial_terminal_quote():
    net=ceildiv(K,OFF)-V
    gross=ceildiv(net*BPS,BPS-100)
    return net,gross

class TestIsolatedGraduation(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source=SOURCE.read_text()

    def test_final_buy_no_longer_migrates(self):
        self.assertIn('if (completed) emit GraduationReady(token, m.nativeReserve);', self.source)
        self.assertNotIn('if (completed) _graduateAtomic(token, m);',self.source)

    def test_graduation_permissionless_and_guarded(self):
        self.assertIn('function graduate(address token) external onlyBSC nonReentrant',self.source)
        self.assertIn('if (m.graduated || m.curveTokensRemaining != 0) revert NotReadyForGraduation();',self.source)
        self.assertIn('function _graduateAtomic(address token, Market storage m) internal',self.source)

    def test_sellers_still_have_curve_exit(self):
        sell=self.source.split('    function sell(address token,')[1].split('    function graduate(address token)')[0]
        self.assertIn('_activeMarket(token)',sell)
        self.assertNotIn('NotReadyForGraduation',sell)
        self.assertNotIn('readyAt',sell)

    def test_terminal_purchase_reserve_and_exit(self):
        net,gross=initial_terminal_quote()
        self.assertEqual(net,750_000_000_000_000_001)
        self.assertEqual(gross,757_575_757_575_757_577)
        final_vnative=V+net
        new_vnative=ceildiv(K,OFF+CURVE)
        gross_sell=final_vnative-new_vnative
        self.assertEqual(gross_sell,net)
        self.assertEqual(OFF+CURVE,INIT)

    def test_pair_validation_and_burn_still_present(self):
        self.assertIn('IPancakePairV14(pair).mint(BURN_ADDRESS)',self.source)
        self.assertIn('IWBNBV14(WBNB).deposit{value: nativeForLP}()',self.source)
        self.assertIn('_verifyMint(token, pair, existingWBNB, nativeForLP, mintedLP)',self.source)

if __name__ == '__main__':unittest.main()
