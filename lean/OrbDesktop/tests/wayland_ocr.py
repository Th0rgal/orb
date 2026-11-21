"""Locate rendered labels in private compositor screenshots."""
import csv
import subprocess


def read_words(image, geometry, full_frame=False):
    origin, size = geometry.split()
    crop = ['-crop', size + '+' + origin.replace(',', '+'), '+repage'] if full_frame else []
    png = subprocess.check_output(['magick', '-', *crop, '-colorspace', 'gray', '-auto-level',
                                   '-resize', '300%', 'png:-'], input=image)
    result = subprocess.check_output(['tesseract', 'stdin', 'stdout', '--psm', '11', 'tsv'],
                                     input=png, stderr=subprocess.DEVNULL, text=False)
    ox, oy = map(int, geometry.split(' ')[0].split(','))
    return [(r['text'].strip('.,:|…').lower(), ox+(int(r['left'])+int(r['width'])//2)//3,
             oy+(int(r['top'])+int(r['height'])//2)//3) for r in
            csv.DictReader(result.decode().splitlines(), delimiter='\t') if r['text'].strip()]
