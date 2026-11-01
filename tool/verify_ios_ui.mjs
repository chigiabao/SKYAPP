// Uses a real historical backend response, never fabricated production readings.
import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';

const modulePath = process.env.PLAYWRIGHT_MODULE_PATH;
const { chromium } = await import(modulePath ? pathToFileURL(modulePath).href : 'playwright');
const base = process.env.WEATHER_WEB_URL ?? 'http://127.0.0.1:8110';
const backend = process.env.WEATHER_API_URL ?? 'http://127.0.0.1:8022';
const output = new URL(process.env.WEATHER_UI_OUTPUT ?? '../build/ios-ui/', import.meta.url);
await mkdir(output, { recursive: true });
const browser = await chromium.launch({ headless: true });
const results = [];

async function open(width, height, offline = false) {
  const context = await browser.newContext({
    viewport: { width, height }, reducedMotion: 'reduce',
  });
  await context.addInitScript(({ backend, offline }) => {
    localStorage.setItem('flutter.onboarding_done_v1', 'true');
    localStorage.setItem('flutter.api_base_url_override', JSON.stringify(backend));
    localStorage.setItem('flutter.themeMode', JSON.stringify('dark'));
    if (!offline) {
      localStorage.setItem('flutter.replayEnabled', 'true');
      localStorage.setItem('flutter.replayAt', JSON.stringify('2026-10-19T18:00:00+07:00'));
    }
  }, { backend, offline });
  if (offline) await context.route(`${backend}/**`, route => route.abort());
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(base, { waitUntil: 'networkidle' });
  await page.locator('canvas').first().waitFor({ state: 'visible' });
  await page.locator('flt-semantics-placeholder').waitFor({ state: 'attached' });
  await page.locator('flt-semantics-placeholder').evaluateAll(elements => elements.forEach(el => el.click()));
  await page.getByText(offline ? 'Máy chủ dữ liệu' : 'Dự báo', { exact: true }).waitFor();
  await page.waitForTimeout(600);
  return { context, page, errors };
}

try {
  for (const [name, width, height] of [
    ['phone', 390, 844], ['small-phone', 320, 667],
    ['landscape', 844, 390], ['desktop', 1440, 960],
  ]) {
    const { context, page, errors } = await open(width, height);
    await page.screenshot({ path: fileURLToPath(new URL(`${name}.png`, output)) });
    const bounds = await page.locator('canvas').first().boundingBox();
    assert(bounds && bounds.width > 0 && bounds.height > 0);
    await page.getByText('Điều kiện', { exact: true }).click();
    await page.waitForTimeout(300);
    if (height < 700) {
      await page.mouse.move(width / 2, height * 0.6);
      await page.mouse.wheel(0, 500);
      await page.waitForTimeout(300);
    }
    await page.screenshot({ path: fileURLToPath(new URL(`${name}-conditions.png`, output)) });
    await page.getByRole('button', { name: 'Cài đặt', exact: true }).click();
    await page.waitForTimeout(700);
    await page.getByText(/Thông báo/i).waitFor();
    await page.screenshot({ path: fileURLToPath(new URL(`${name}-settings.png`, output)) });
    await page.getByText(/Hiển thị/).click();
    await page.waitForTimeout(500);
    await page.screenshot({ path: fileURLToPath(new URL(`${name}-display.png`, output)) });
    await page.getByRole('button', { name: /^Chế độ giao diện:/ }).first().waitFor();
    await page.getByRole('button', { name: 'Quay lại', exact: true }).click();
    await page.getByText(/Tài khoản/).click();
    await page.getByText('Quên mật khẩu?', { exact: true }).click();
    await page.getByText('Khôi phục mật khẩu', { exact: true }).waitFor();
    await page.screenshot({ path: fileURLToPath(new URL(`${name}-recovery.png`, output)) });
    assert.deepEqual(errors, []);
    results.push({ name, width, height, errors, mode: 'historical_reference' });
    await context.close();
  }
  const { context, page, errors } = await open(390, 844, true);
  await page.screenshot({ path: fileURLToPath(new URL('phone-offline.png', output)) });
  await page.getByText('Máy chủ dữ liệu', { exact: true }).click();
  await page.waitForTimeout(700);
  await page.getByText(/Thông báo/i).waitFor();
  assert.deepEqual(errors, []);
  results.push({ name: 'phone-offline', errors, settingsReachable: true });
  await context.close();
} finally {
  await browser.close();
}
await writeFile(new URL('results.json', output), JSON.stringify(results, null, 2));
console.log(JSON.stringify(results, null, 2));
