#!/usr/bin/env python3
"""Check the HTML head for offline reading and native math."""
from pathlib import Path
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
XSL = '{http://www.w3.org/1999/XSL/Transform}'
XHTML = '{http://www.w3.org/1999/xhtml}'
MATHML = '{http://www.w3.org/1998/Math/MathML}'
STYLESHEET = ROOT / 'xml/docbook2html_config_xhtml.xsl'


class HtmlHeadTest(unittest.TestCase):
    def test_offline_script_and_native_math(self):
        root = ET.parse(STYLESHEET).getroot()
        head = root.find(f"{XSL}template[@name='user.head.content']")
        self.assertIsNotNone(head)
        scripts = head.findall(f'.//{XHTML}script')
        offline = [node for node in scripts if node.get('src') == 'assets/scripts/offline.js']
        self.assertEqual(len(offline), 1)
        self.assertEqual(offline[0].get('defer'), 'defer')
        self.assertNotIn('mathjax', ET.tostring(head, encoding='unicode').lower())

    def test_fraction_thickness_preserves_explicit_values(self):
        source = '<math xmlns="http://www.w3.org/1998/Math/MathML">' \
                 '<mfrac><mn>2</mn><mn>7</mn></mfrac>' \
                 '<mfrac linethickness="0"><mn>3</mn><mn>5</mn></mfrac></math>'
        with tempfile.TemporaryDirectory() as directory:
            wrapper = Path(directory) / 'wrapper.xsl'
            wrapper.write_text(f'''<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:include href="{STYLESHEET.as_uri()}"/>
  <xsl:template match="*">
    <xsl:copy><xsl:copy-of select="@*"/><xsl:apply-templates/></xsl:copy>
  </xsl:template>
</xsl:stylesheet>''')
            result = subprocess.run(['xsltproc', str(wrapper), '-'], input=source,
                                    text=True, capture_output=True, check=True)
        fractions = ET.fromstring(result.stdout).findall(f'{MATHML}mfrac')
        self.assertEqual([node.get('linethickness') for node in fractions], ['0.07em', '0'])
        self.assertEqual([''.join(node.itertext()) for node in fractions], ['27', '35'])


if __name__ == '__main__':
    unittest.main()
