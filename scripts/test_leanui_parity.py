"""Small independent fixtures exercise metrics, pairing, repeats and reports."""
import contextlib
import io
from pathlib import Path
import tempfile
import unittest
import numpy as np
from PIL import Image
from scripts import leanui_parity as parity


class ParityTests(unittest.TestCase):
    def test_metrics_and_strict_tolerance(self):
        a = np.zeros((10, 10, 3), dtype=np.uint8)
        b = a.copy()
        b[0, 0] = [8, 0, 0]
        b[0, 1] = [9, 0, 0]
        result = parity.metrics(a, b)
        self.assertEqual(result['mismatch'], 2)
        self.assertEqual(result['above_tolerance'], 1)
        self.assertEqual(parity.ssim(a, a), 1)
        self.assertLess(result['ssim'], 1)
        self.assertAlmostEqual(parity.ssim(a, b), parity.ssim(b, a))
        with self.assertRaises(ValueError):
            parity.metrics(a, b[:2])

    def test_ssim_constant_images(self):
        a = np.full((9, 9, 3), 20, dtype=np.uint8)
        b = np.full_like(a, 40)
        self.assertAlmostEqual(parity.ssim(a, b), (2*20*40+6.5025)/(20**2+40**2+6.5025))

    def test_end_to_end(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            ref, native, repeat = [root/p for p in ('ref', 'native', 'repeat')]
            for directory in (ref, native, repeat):
                directory.mkdir()
                Image.new('RGB', (147, 93), (20, 20, 20)).save(directory/'01_control_empty_dark_1x.png')
            doc = root/'table.md'
            doc.write_text('before\n<!-- parity:begin -->old<!-- parity:end -->\nafter\n<!-- parity:crop 01_control_empty_dark_1x 0 0 10 10 -->')
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(parity.main(['--reference', str(ref), '--native', str(native), '--require', '1', '--table', str(doc), '--json', str(root/'result.json'), '--out', str(root/'diff'), '--crops-dir', str(root/'crops'), '--reference-repeat', str(repeat), '--native-repeat', str(repeat)]), 0)
            self.assertIn('1/1 images pixel-identical', doc.read_text())
            self.assertTrue(doc.read_text().startswith('before\n'))
            self.assertIn('\nafter\n', doc.read_text())
            self.assertEqual(len(list((root/'crops').glob('*.png'))), 2)
            Image.new('RGB', (147, 93), (21, 20, 20)).save(repeat/'01_control_empty_dark_1x.png')
            self.assertTrue(parity.compare(ref, native, reference_repeat=repeat)['errors'])
            (native/'01_control_empty_dark_1x.png').unlink()
            self.assertTrue(parity.compare(ref, native, require=1)['errors'])

    def test_unreadable_images_and_dimensions(self):
        with tempfile.TemporaryDirectory() as tmp:
            ref, native = Path(tmp)/'ref', Path(tmp)/'native'
            ref.mkdir()
            native.mkdir()
            name = '01_control_empty_dark_1x.png'
            Image.new('RGB', (10, 10)).save(ref/name)
            Image.new('RGB', (11, 10)).save(native/name)
            result = parity.compare(ref, native)
            self.assertFalse(result['pairs'])
            self.assertIn('dimension mismatch', result['errors'][0])
            (native/name).write_bytes(b'not an image')
            self.assertTrue(parity.compare(ref, native)['errors'])

    def test_documented_crops_budget(self):
        root = Path(__file__).resolve().parents[1]
        doc = (root/'docs/ui/leanui-parity.md').read_text()
        self.assertEqual(doc.count('<!-- parity:begin -->'), 1)
        self.assertEqual(doc.count('<!-- parity:end -->'), 1)
        declarations = parity.re.findall(r'<!-- parity:crop ([\w]+) (\d+) (\d+) (\d+) (\d+) -->', doc)
        self.assertEqual(len(declarations), 36)
        for stem, _, _, width, height in declarations:
            scale = int(parity.NAME.fullmatch(stem)[3])
            for renderer in ('ref', 'leanui'):
                path = root/'docs/ui/crops'/f'{stem}_{renderer}_crop.png'
                with self.subTest(path=path.name):
                    self.assertLessEqual(path.stat().st_size, 5*1024)
                    with Image.open(path) as im:
                        self.assertEqual(im.size, (int(width)*scale, int(height)*scale))

    def test_bad_markers_and_empty_input(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'doc.md'
            path.write_text('no markers')
            with self.assertRaises(ValueError):
                parity.rewrite(path, '')
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(parity.main(['--reference', tmp, '--native', tmp]), 1)


if __name__ == '__main__':
    unittest.main()
