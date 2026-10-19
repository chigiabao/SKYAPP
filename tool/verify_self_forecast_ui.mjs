// PLAYWRIGHT_MODULE_PATH points to an existing Playwright installation when it is not local.
import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';

const modulePath = process.env.PLAYWRIGHT_MODULE_PATH;
const { chromium } = await import(modulePath ? pathToFileURL(modulePath).href : 'playwright');
const base = process.env.WEATHER_WEB_URL ?? 'http://127.0.0.1:8097';
const output = new URL('../build/self-forecast-ui/', import.meta.url);
await mkdir(output, { recursive: true });
const browser = await chromium.launch({ headless: true });
const results = [];
try {
  for (const [name, width, height] of [
    ['phone', 390, 844], ['small-phone', 375, 667],
    ['landscape', 844, 390], ['desktop', 1440, 960],
  ]) {
    const context = await browser.newContext({ viewport: { width, height }, reducedMotion: 'reduce' });
    await context.addInitScript(() => {
      localStorage.setItem('flutter.onboarding_done_v1', 'true');
    });
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    const bundleResponse = page.waitForResponse(response => response.url().includes('/weather/bundle') && response.ok());
    await page.goto(base, { waitUntil: 'networkidle' });
    const bundle = await (await bundleResponse).json();
    assert.equal(bundle.forecast_provider, 'sky_weather_ai');
    assert.equal(bundle.forecast_error, null);
    assert.equal(bundle.daily.length, 7);
    assert(bundle.hourly.some(hour => hour.source === 'ai'));
    assert(bundle.daily.filter(day => day.source === 'ai').length > 0);
    assert(bundle.daily.filter(day => day.source === 'ai').every(day => day.rain_day_probability === null));
    await page.locator('flt-semantics-placeholder').evaluateAll(elements => elements.forEach(el => el.click()));
    await page.waitForTimeout(1800);
    await page.screenshot({ path: fileURLToPath(new URL(`${name}.png`, output)) });
    const canvas = page.locator('canvas').first();
    await canvas.waitFor({ state: 'attached' });
    const bounds = await canvas.boundingBox();
    assert(bounds && bounds.width > 0 && bounds.height > 0);
    await page.getByText('Điều kiện', { exact: true }).click();
    await page.waitForTimeout(350);
    await page.mouse.move(Math.round(width * 0.65), Math.round(height * 0.65));
    await page.mouse.wheel(0, height * 0.7);
    await page.waitForTimeout(400);
    await page.screenshot({ path: fileURLToPath(new URL(`${name}-conditions.png`, output)) });
    assert.deepEqual(errors, []);
    results.push({ name, width, height, checkedAt: new Date().toISOString(),
      backendUrl: (await bundleResponse).url(), provider: bundle.forecast_provider,
      hourly: bundle.hourly.length, daily: bundle.daily.length, errors });
    await context.close();
  }
} finally {
  await browser.close();
}
await writeFile(new URL('results.json', output), JSON.stringify(results, null, 2));
console.log(JSON.stringify(results, null, 2));
