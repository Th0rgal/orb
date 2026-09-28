import unittest
from playwright.async_api import async_playwright
from scripts.chatgpt_ui_driver import assistant_markdown

class MarkdownExtraction(unittest.IsolatedAsyncioTestCase):
    async def test_semantic_response(self):
        async with async_playwright() as pw:
            browser = await pw.chromium.launch()
            try:
                page = await browser.new_page()
                await page.set_content('''<article><h2>Result</h2><p><strong>Bold</strong> and <a href="https://example.org/source">Source</a></p><table><tr><th>Year</th><th>Value</th></tr><tr><td>2026</td><td>42</td></tr></table><span class="katex-display"><span class="katex"><math><annotation encoding="application/x-tex">x^2</annotation></math><span aria-hidden="true">duplicate formula</span></span></span><pre><code class="language-python">print(42)</code></pre><button>Copy</button></article>''')
                result = await assistant_markdown(page.locator('article'))
                self.assertIn('## Result', result)
                self.assertIn('**Bold**', result)
                self.assertIn('[Source](https://example.org/source)', result)
                self.assertIn('| Year | Value |\n| --- | --- |\n| 2026 | 42 |', result)
                self.assertIn('$$\nx^2\n$$', result)
                self.assertIn('```python\nprint(42)\n```', result)
                self.assertNotIn('duplicate', result)
                self.assertNotIn('Copy', result)
                # The live code card initially uses spans instead of pre/code.
                # Its semantic boundary still identifies a fenced code block.
                await page.set_content('''<article><div data-markdown-copy="code-block"><div data-markdown-copy="exclude"><div>Python</div><button>Copy</button></div><div><span>print</span><span>(43)</span></div></div></article>''')
                self.assertEqual(await assistant_markdown(page.locator('article')), '```python\nprint(43)\n```')
            finally:
                await browser.close()
