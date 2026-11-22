"""Measure the packaged sidebar over two backgrounds on the disposable Sway output."""
import json
from statistics import median
import subprocess
import time


def measure(env):
    def patch():
        image = subprocess.check_output(['grim', '-g', '16,520 140x24', '-t', 'ppm', '-'], env=env)
        return subprocess.check_output(['magick', '-', '-depth', '8', 'rgb:-'], input=image)

    def set_color(color):
        replies = json.loads(subprocess.check_output(['swaymsg', 'output', '*', 'bg', color, 'solid_color'], env=env))
        assert all(reply['success'] for reply in replies), replies

    set_color('#000000')
    time.sleep(.5)
    black = patch()
    set_color('#ffffff')
    deadline = time.monotonic() + 5
    try:
        while True:
            white = patch()
            change = median(abs(a - b) for a, b in zip(black, white, strict=True))
            if change > 0 or time.monotonic() >= deadline:
                return change
            time.sleep(.2)
    finally:
        set_color('#000000')
