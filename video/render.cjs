const { chromium } = require('playwright');

const URL = 'file:///Users/a1-6/AI Shared/repo/aiui-voiceprint/video/index.html';
const OUT = '/Users/a1-6/AI Shared/repo/aiui-voiceprint/video/render.webm';

(async () => {
  const browser = await chromium.launch({
    headless: true,
    executablePath: '/Users/a1-6/Library/Caches/ms-playwright/chromium_headless_shell-1234/chrome-headless-shell-mac-arm64/chrome-headless-shell',
    args: ['--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage', '--force-color-profile=srgb', '--hide-scrollbars']
  });
  const ctx = await browser.newContext({
    viewport: { width: 1920, height: 1080 },
    deviceScaleFactor: 1,
    recordVideo: { dir: '/Users/a1-6/AI Shared/repo/aiui-voiceprint/video', size: { width: 1920, height: 1080 } }
  });
  const page = await ctx.newPage();
  await page.goto(URL, { waitUntil: 'load' });
  // settle fonts/layout, then record the full 45s timeline
  await page.waitForTimeout(700);
  await page.waitForTimeout(45000);
  await ctx.close();
  await browser.close();
  console.log('render complete:', OUT);
})().catch(e => { console.error('RENDER ERROR', e); process.exit(1); });
