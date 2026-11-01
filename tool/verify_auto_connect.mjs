// Verify real release requests without seeding a server URL on fresh installs.
import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const modulePath = process.env.PLAYWRIGHT_MODULE_PATH;
const { chromium } = createRequire(import.meta.url)(modulePath ?? 'playwright');
const base = process.env.WEATHER_WEB_URL ?? 'http://127.0.0.1:8000';
const alternate = process.env.WEATHER_ALTERNATE_WEB_URL ?? 'http://127.0.0.1:8001';
const output = new URL('../build/auto-connect-ui/', import.meta.url);
await mkdir(output, { recursive: true });
const browser = await chromium.launch({ headless: true, channel: process.env.PLAYWRIGHT_CHANNEL });
const results = [];
try {
  for (const [name, url, viewport, legacy] of [
    ['fresh-phone', base, { width: 390, height: 844 }, false],
    ['fresh-desktop', base, { width: 1440, height: 960 }, false],
    ['legacy-small-phone', base, { width: 320, height: 667 }, true],
    ['alternate-port', alternate, { width: 390, height: 844 }, false],
  ]) {
    const context = await browser.newContext({ viewport, reducedMotion: 'reduce' });
    await context.addInitScript(({ legacy }) => {
      localStorage.setItem('flutter.onboarding_done_v1', 'true');
      if (legacy) {
        localStorage.setItem('flutter.api_base_url_override', JSON.stringify('http://127.0.0.1:8036'));
      }
    }, { legacy });
    const page = await context.newPage();
    const errors = [];
    const apiUrls = [];
    const failedAssets = [];
    page.on('pageerror', error => errors.push(error.message));
    page.on('response', response => {
      if (response.url().includes('/weather/') || response.url().includes('/locations/')) {
        apiUrls.push(response.url());
      } else if (response.status() >= 400 && new URL(response.url()).origin === url) {
        failedAssets.push({ url: response.url(), status: response.status() });
      }
    });
    const bundle = page.waitForResponse(response =>
      response.url().startsWith(url + '/weather/bundle?') && response.status() === 200,
    { timeout: 60000 });
    await page.goto(url, { waitUntil: 'networkidle' });
    const response = await bundle;
    const payload = await response.json();
    assert(payload.current, 'Real backend must return current weather, even if stale');
    await page.locator('canvas').first().waitFor({ state: 'visible' });
    await page.locator('flt-semantics-placeholder').waitFor({ state: 'attached' });
    await page.locator('flt-semantics-placeholder').evaluateAll(elements => elements.forEach(el => el.click()));
    await page.getByText('Dự báo', { exact: true }).waitFor();
    await page.screenshot({ path: fileURLToPath(new URL(name + '.png', output)) });
    assert(apiUrls.length > 0);
    assert(apiUrls.every(value => new URL(value).origin === url), JSON.stringify(apiUrls));
    const saved = await page.evaluate(() => localStorage.getItem('flutter.api_base_url_override'));
    assert(saved === null || saved === 'null', 'Fresh/legacy web must use default origin');
    assert.deepEqual(errors, []);
    assert.deepEqual(failedAssets, []);
    results.push({ name, url, viewport, apiUrls, errors, failedAssets, source: 'real-live-response-may-be-stale' });
    await context.close();
  }
  await writeFile(new URL('results.json', output), JSON.stringify(results, null, 2));
  console.log(JSON.stringify(results, null, 2));
} finally {
  await browser.close();
}
