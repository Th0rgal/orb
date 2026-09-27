import unittest
from unittest.mock import AsyncMock, MagicMock, patch
from scripts import chatgpt_ui_driver as driver

class ResumeTests(unittest.IsolatedAsyncioTestCase):
    def page(self, count, message, baseline=0):
        page = MagicMock()
        page.url = 'https://chatgpt.com/c/abc123def456'
        page.goto = AsyncMock()
        page.wait_for_timeout = AsyncMock()
        users = page.locator.return_value
        users.count = AsyncMock(side_effect=count if isinstance(count, list) else None, return_value=count if isinstance(count, int) else 1)
        users.last.inner_text = AsyncMock(return_value=message)
        users.last.evaluate = AsyncMock(return_value=baseline)
        return page

    async def resume(self, page, message):
        with patch.object(driver, 'wait_out_cloudflare', AsyncMock()), patch.object(driver, 'complete_saved_account_picker', AsyncMock()), patch.object(driver, 'raise_if_rate_limited', AsyncMock()), patch.object(driver, 'verify_authentication', AsyncMock()):
            return await driver.establish_resumed_chat(page, '/c/abc123def456', message)

    async def test_waits_for_history_instead_of_reporting_missing(self):
        page = self.page([0, 0, 1], 'marker')
        self.assertEqual(await self.resume(page, 'marker'), 0)
        self.assertEqual(page.wait_for_timeout.await_count, 2)

    async def test_followup_uses_latest_prompt_and_preceding_response_baseline(self):
        page = self.page(3, 'followup', 2)
        self.assertEqual(await self.resume(page, 'followup'), 2)
        page.locator.return_value.last.inner_text.assert_awaited()

    async def test_mismatched_prompt_never_reattaches(self):
        page = self.page(2, 'unrelated')
        with self.assertRaises(driver.ResumeMismatch):
            await self.resume(page, 'expected')
        page.locator.return_value.last.evaluate.assert_not_awaited()

class DownloadControls(unittest.TestCase):
    def test_current_download_button_is_supported_without_clicking_analysis(self):
        self.assertEqual(driver.download_control_key('button', None, 'Download file', '', ''), 'direct-download')
        self.assertIsNone(driver.download_control_key('button', None, 'View analysis', '', ''))
        self.assertIsNone(driver.download_control_key('button', None, 'Download', '', ''))
