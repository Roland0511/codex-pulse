import base64
import datetime
import importlib.util
from pathlib import Path
import sys
import unittest
import xml.etree.ElementTree as ET
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import update_feed
import build_app


class UpdateFeedTests(unittest.TestCase):
    def test_feed_keeps_machine_build_separate_from_display_version(self):
        signature = base64.b64encode(b'x' * 64).decode()
        xml = update_feed.make_xml('0.2.0', '6', 'CodexPulse-0.2.0-universal-notarized.zip', 123, signature,
                                   '<script>never executable</script> & details',
                                   datetime.datetime(2026, 10, 13, tzinfo=datetime.timezone.utc))
        root = ET.fromstring(xml)
        item = root.find('./channel/item')
        self.assertEqual(item.findtext('{'+update_feed.SPARKLE+'}version'), '6')
        self.assertEqual(item.findtext('{'+update_feed.SPARKLE+'}shortVersionString'), '0.2.0')
        enclosure = item.find('enclosure')
        self.assertEqual(enclosure.get('url'), 'https://github.com/Roland0511/codex-pulse/releases/download/v0.2.0/CodexPulse-0.2.0-universal-notarized.zip')
        self.assertEqual(enclosure.get('{'+update_feed.SPARKLE+'}edSignature'), signature)
        self.assertEqual(item.find('description').get('{'+update_feed.SPARKLE+'}format'), 'plain-text')
        self.assertNotIn(b'<script>', xml)

    def test_invalid_signature_metadata_and_path_are_rejected(self):
        signature = base64.b64encode(b'x' * 64).decode()
        for version, build, name, size, sig in [('../bad','6','x.zip',1,signature), ('0.2.0','0','x.zip',1,signature),
                                                ('0.2.0','6','../x.zip',1,signature), ('0.2.0','6','x.zip',0,signature),
                                                ('0.2.0','6','x.zip',1,base64.b64encode(b'x').decode())]:
            with self.assertRaises(ValueError):
                update_feed.make_xml(version, build, name, size, sig, 'text')

    def test_signing_key_must_match_shipped_public_key(self):
        with patch.object(update_feed, 'tool', return_value=Path('/synthetic/generate_keys')):
            with patch.object(update_feed.subprocess, 'check_output', return_value='wrong key'):
                with self.assertRaises(ValueError):
                    update_feed.verify_key()

    def test_production_feed_and_public_key_are_valid(self):
        config = build_app.update_configuration()
        self.assertTrue(config['feedURL'].startswith('https://github.com/Roland0511/codex-pulse/'))
        self.assertEqual(len(base64.b64decode(config['publicEDKey'])), 32)
