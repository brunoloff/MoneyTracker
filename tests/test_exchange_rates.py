import sys, unittest
from pathlib import Path
from unittest.mock import patch
from decimal import Decimal
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'server'))
import exchange_rates as fx
import store
import test_paypal

class RatesTests(unittest.TestCase):
    def test_parse_cross_rate_weekend_and_missing(self):
        data=fx.parse(b'<root><Cube time="2026-09-04"><Cube currency="USD" rate="1.25"/><Cube currency="CHF" rate="0.8"/></Cube></root>')
        with patch.object(store,'read',return_value={'rates':data}): table=fx.Table()
        self.assertEqual(table.convert(-2500,'USD','EUR','2026-09-06'),(Decimal(-2000),'2026-09-04'))
        self.assertEqual(table.convert(-2500,'USD','CHF','2026-09-06')[0],Decimal(-1600))
        self.assertIsNone(table.convert(-2500,'USD','EUR','2026-08-01'))
        self.assertIsNone(table.convert(-2500,'USD','EUR','2026-09-15'))
        self.assertIsNone(table.convert(-2500,'XYZ','EUR','2026-09-06'))
    def test_bad_download_preserves_cache(self):
        with patch.object(fx.requests,'get') as get, patch.object(store,'write') as write:
            get.return_value.content=b'<root />'
            with self.assertRaises(ValueError): fx.download()
            write.assert_not_called()
    def test_invalid_rates(self):
        for rate in ['0','-1','NaN']:
            with self.assertRaises(ValueError): fx.parse(f'<root><Cube time="2026-09-04"><Cube currency="USD" rate="{rate}"/></Cube></root>')

class MatchingRatesTests(unittest.TestCase):
    setUp = test_paypal.PayPalTests.setUp
    def test_tolerance_boundary_and_no_rate(self):
        self.observation['currency']='USD'
        self.bank['amount']=-2200
        self.data['exchange-rates.json']={'rates':{'2026-09-08':{'EUR':'1','USD':'1.25'}}}
        self.assertEqual(paypal_review(self)['rule'],'fx')
        self.bank['amount']=-2201
        self.assertEqual(paypal_review(self)['candidates'],[])
        self.data['preferences.json']={'fxTolerancePercent':11}
        self.assertEqual(paypal_review(self)['rule'],'fx')
        self.data.pop('exchange-rates.json')
        self.assertEqual(paypal_review(self)['candidates'],[])

def paypal_review(test):
    import paypal
    return paypal.review()['rows'][0]
