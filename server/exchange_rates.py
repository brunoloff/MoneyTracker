"""ECB historical daily reference rates. Local cache; no transaction data sent."""
from bisect import bisect_right
from datetime import date, datetime, timezone
from decimal import Decimal
import xml.etree.ElementTree as ET
import requests
import store

URL = 'https://www.ecb.europa.eu/stats/eurofxref/eurofxref-hist.xml'

def parse(content):
    rates = {}
    for element in ET.fromstring(content).iter():
        day = element.get('time')
        if not day: continue
        date.fromisoformat(day)
        currencies = {'EUR':'1'}
        for child in element:
            currency, value = child.get('currency'), child.get('rate')
            if currency and value:
                number = Decimal(value)
                if not number.is_finite() or number <= 0: raise ValueError('Invalid ECB rate')
                currencies[currency] = str(number)
        if len(currencies)>1: rates[day]=currencies
    if not rates: raise ValueError('ECB download contains no exchange rates')
    return rates

def download(progress=None):
    if progress: progress('Downloading ECB historical exchange rates…')
    response = requests.get(URL,timeout=60)
    response.raise_for_status()
    rates = parse(response.content)
    store.write('exchange-rates.json', {'source':'ECB', 'url':URL,'downloadedAt':datetime.now(timezone.utc).isoformat(),'rates':rates})

class Table:
    def __init__(self):
        self.data = store.read('exchange-rates.json', {})
        self.rates = self.data.get('rates', {})
        self.days = sorted(self.rates)
    def status(self):
        return {'source':'ECB','downloadedAt':self.data.get('downloadedAt'),'from':self.days[0] if self.days else None,'to':self.days[-1] if self.days else None}
    def convert(self, amount, source, target, day):
        index = bisect_right(self.days,day)-1
        if index<0: return None
        rate_day=self.days[index]
        if (date.fromisoformat(day)-date.fromisoformat(rate_day)).days>7: return None
        rates=self.rates[rate_day]
        if source not in rates or target not in rates: return None
        converted=Decimal(amount)*Decimal(rates[target])/Decimal(rates[source])
        return converted, rate_day
