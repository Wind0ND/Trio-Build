"""Validate the personal build's public TestFlight copy before publishing."""
import json
from pathlib import Path
import re

path = Path(__file__).resolve().parents[1] / 'fastlane/beta_metadata.json'
metadata = json.loads(path.read_text(encoding='utf-8'))
if not isinstance(metadata, dict) or not {'en-US', 'zh-Hans'} <= metadata.keys():
    raise SystemExit('TestFlight copy must include en-US and zh-Hans')

private_terms = re.compile(
    r'血糖|医疗|醫療|糖尿病|胰岛素|胰島素|血糖儀|血糖仪|'
    r'\b(?:glucose|diabetes|diabetic|insulin|cgm|medical|healthcare|health|blood\s+sugar|aid)\b',
    re.IGNORECASE
)
for locale, entry in metadata.items():
    if not isinstance(entry, dict) or set(entry) != {'description', 'whats_new'}:
        raise SystemExit(f'Invalid TestFlight fields: {locale}')
    for field, value in entry.items():
        if not isinstance(value, str) or not value.strip() or len(value) > 4000:
            raise SystemExit(f'Invalid TestFlight text: {locale}/{field}')
        if '\ufffd' in value or private_terms.search(value):
            raise SystemExit(f'TestFlight copy needs privacy/encoding review: {locale}/{field}')
print('Public TestFlight copy passed structure, encoding and privacy checks.')
