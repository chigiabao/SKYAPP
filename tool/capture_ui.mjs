// Sky Weather UI screenshot set (Playwright, Flutter web semantics).
//
// 1. Build:  flutter build web --release --no-tree-shake-icons --no-web-resources-cdn -o <webdir>
// 2. Serve on a DB copy (never the real backend/data):  python tool/serve_ui_snapshot.py --web <webdir> --port 8123
// 3. Capture: node tool/capture_ui.mjs [outDir] [onlyScenarioRegex]
//    env: SKY_URL (default http://127.0.0.1:8123), PLAYWRIGHT_MODULE_PATH (path to playwright/index.mjs)
//
// Scenes come from the app's own replay mode (real recorded data, no fake values):
//   day   = 2026-10-20 10:00 (clear sky), night = 2026-10-21 21:00 (thunderstorm preset).
// 200% text = browser root font-size 32px (Flutter web derives its text scale from it).
// Offline = API requests aborted in the browser (web bundle still served).
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const pw = process.env.PLAYWRIGHT_MODULE_PATH ?? 'D:/demo1/frontend/node_modules/playwright/index.mjs';
const { chromium } = await import(pathToFileURL(pw).href);
const BASE = process.env.SKY_URL ?? 'http://127.0.0.1:8123';
const OUT = path.resolve(process.argv[2] ?? 'build/ui-shots');
const ONLY = process.argv[3] ? new RegExp(process.argv[3]) : null;
fs.mkdirSync(OUT, { recursive: true });

const SCENES = { day: '2026-10-20T10:00:00+07:00', night: '2026-10-21T21:00:00+07:00' };
const SAVED = [{ id: 'tsn', label: 'home' }, { id: 'phuong-ben-thanh', label: 'work' }, { id: 'phuong-thu-duc', label: 'none' }];
const API = /^\/(weather|locations|health|live|auth|account|feedback|alerts|route|monitor|admin|ai|sync|api)\b/;

const log = []; // {file, ok, note}
const browser = await chromium.launch();

async function open({ scene = 'day', w = 390, h = 844, dpr = 3, text = 1, onboarding = false, offline = false, saved = true, reduced = false }) {
  const ctx = await browser.newContext({
    viewport: { width: w, height: h }, deviceScaleFactor: dpr, isMobile: w < 800, hasTouch: false,
    colorScheme: scene === 'day' ? 'light' : 'dark', reducedMotion: reduced ? 'reduce' : 'no-preference',
    locale: 'vi-VN', timezoneId: 'Asia/Ho_Chi_Minh',
  });
  await ctx.addInitScript(({ at, onboarding, saved }) => {
    if (sessionStorage.getItem('sky_init')) return;   // only seed the first load
    sessionStorage.setItem('sky_init', '1');
    localStorage.clear();
    if (!onboarding) localStorage.setItem('flutter.onboarding_done_v1', 'true');
    if (saved) localStorage.setItem('flutter.saved_places_v1', JSON.stringify(JSON.stringify(saved)));
    if (at) {
      localStorage.setItem('flutter.replayEnabled', 'true');
      localStorage.setItem('flutter.replayAt', JSON.stringify(at));
    }
  }, { at: offline ? null : SCENES[scene], onboarding, saved: saved ? SAVED : null });
  if (offline) await ctx.route(u => API.test(new URL(u).pathname), r => r.abort());
  const page = await ctx.newPage();
  page.__dpr = dpr;
  page.on('pageerror', e => console.log('  pageerror:', e.message));
  await page.goto(BASE, { waitUntil: 'networkidle' });
  await page.locator('flt-semantics-placeholder').waitFor({ state: 'attached', timeout: 30000 });
  await page.locator('flt-semantics-placeholder').evaluateAll(es => es.forEach(e => e.click()));
  if (text !== 1) await page.evaluate(px => { document.documentElement.style.fontSize = px; }, `${16 * text}px`);
  await page.waitForTimeout(4500);
  return { ctx, page };
}

const rx = s => (s instanceof RegExp ? s : new RegExp(s));
function helpers(page, prefix) {
  const touch = false;
  // Raw pointer input must reach the Flutter canvas, not the semantics DOM overlay.
  const passThrough = on => page.evaluate(on => {
    let st = document.getElementById('sky-pt');
    if (!st) { st = document.createElement('style'); st.id = 'sky-pt'; document.head.appendChild(st); }
    st.textContent = on ? 'flt-semantics-host, flt-semantics-host * { pointer-events: none !important; }' : '';
  }, on);
  const H = {
    wait: ms => page.waitForTimeout(ms),
    async tap(name, { ms = 1400, role = 'button' } = {}) {
      const loc = role ? page.getByRole(role, { name: rx(name) }) : page.getByText(rx(name));
      try {
        await loc.first().click({ timeout: 4000 });
      } catch {   // off-screen (e.g. at 200% text): scroll it into view, then retry
        await H.scrollTo(name, { role });
        await loc.first().click({ timeout: 6000 });
      }
      await page.waitForTimeout(ms);
    },
    async fill(text) {
      const box = page.locator('textarea, input[type="text"], input:not([type])').first();
      await box.click({ timeout: 6000 }); await page.keyboard.type(text, { delay: 10 });
      await page.waitForTimeout(800);
    },
    async tapXY(x, y, ms = 1400) {
      await passThrough(true); await page.mouse.click(x, y); await passThrough(false);
      await page.waitForTimeout(ms);
    },
    async wheel(dy, x, y) {
      const vp = page.viewportSize();
      await passThrough(true);
      await page.mouse.move(x ?? vp.width / 2, y ?? vp.height * 0.55);
      // At DPR 3 Flutter web moves only ~1/6 of the wheel delta (slow frames), so scale up, in notches.
      const scale = (page.__dpr ?? 1) >= 2 ? 6 : 1.2;
      for (let left = dy * scale; Math.abs(left) > 1;) {
        const d = Math.sign(left) * Math.min(500, Math.abs(left));
        await page.mouse.wheel(0, d); left -= d;
        await page.waitForTimeout(200);
      }
      await passThrough(false);
      await page.waitForTimeout(900);
    },
    // Scroll down until an element (button name or text) is inside the viewport.
    async scrollTo(name, { role = 'button', step = 350, max = 20, x } = {}) {
      const vp = page.viewportSize();
      for (let i = 0; i < max; i++) {
        const loc = (role ? page.getByRole(role, { name: rx(name) }) : page.getByText(rx(name))).first();
        if (await loc.count()) {
          const b = await loc.boundingBox();
          if (b && b.y >= 0 && b.y + Math.min(b.height, 50) <= vp.height - 90) return loc;
        }
        await H.wheel(step, x);
      }
      throw new Error(`scrollTo: ${name} not found`);
    },
    async shot(file, note) {
      await page.mouse.move(page.viewportSize().width - 1, 1);   // no hover tooltips in shots
      await page.waitForTimeout(400);
      const f = path.join(OUT, `${file}.png`);
      await page.screenshot({ path: f });
      log.push({ file: `${file}.png`, ok: true, note });
      console.log('  saved', file);
    },
    async labels() {
      return page.evaluate(() => [...document.querySelectorAll('flt-semantics')]
        .filter(e => !e.querySelector('flt-semantics'))
        .map(e => `${e.getAttribute('role') || ''}|${(e.getAttribute('aria-label') || e.textContent.trim()).slice(0, 70)}`));
    },
    back: (ms = 1200) => H.tap('^Quay lại$', { ms }),
  };
  return H;
}

const scenarios = [];
const S = (name, opts, fn) => scenarios.push({ name, opts, fn });
const TAB = { map: '^Bản đồ$', trip: '^Tôi sắp ra ngoài', places: '^Danh sách địa điểm', home: '^Hôm nay$' };

for (const scene of ['day', 'night']) {
  const n = scene;
  S(`home_${n}`, { scene }, async H => {
    await H.shot(`home_${n}_01_top`, `Home, ${n} scene (replay), top`);
    await H.wheel(700); await H.shot(`home_${n}_02_scrolled`, 'Home scrolled: hourly/7-day');
    await H.wheel(900); await H.shot(`home_${n}_03_scrolled_more`, 'Home scrolled further: planning/AI cards');
    await H.wheel(2000); await H.shot(`home_${n}_04_end`, 'Home end of page');
  });
  S(`home_conditions_${n}`, { scene }, async H => {
    await H.scrollTo('^Điều kiện$'); await H.tap('^Điều kiện$');
    await H.shot(`home_${n}_05_conditions`, 'Home "Điều kiện" segment');
  });
  S(`tabs_${n}`, { scene }, async H => {
    await H.tap(TAB.map, { ms: 4000 }); await H.shot(`tab_map_${n}`, 'Bản đồ tab root, tab bar visible');
    await H.tapXY(75, 335, 2500); await H.shot(`tab_map_${n}_cell_sheet`, 'Map cell sheet after tapping a grid cell (should cover tab bar)');
    await H.tap(TAB.trip, { ms: 2500 }).catch(async () => { await H.tapXY(195, 800); await H.tap(TAB.trip, { ms: 2500 }); });
    await H.shot(`tab_trip_${n}`, 'Ra ngoài tab root');
    await H.tap(TAB.places, { ms: 2500 }); await H.shot(`tab_places_${n}`, 'Địa điểm tab root (3 saved places)');
  });
}

S('map_extras_day', {}, async H => {
  await H.tap(TAB.map, { ms: 4000 });
  await H.tap('^Chú giải$'); await H.shot('tab_map_day_legend', 'Map legend open');
  await H.tap('^Chú giải$').catch(() => {});
  await H.tap('^Xem dạng danh sách$', { ms: 2000 }); await H.shot('tab_map_day_list', 'Map list view');
});

S('pushed_in_tab', {}, async H => {
  await H.tap(TAB.places, { ms: 2000 });
  await H.tap('^Tùy chọn cho Phường Bến Thành', { ms: 1500 });
  await H.shot('places_action_sheet', 'Action sheet for a place (red destructive action expected)');
  await H.tap('^Xóa', { ms: 700 });
  await H.shot('toast_place_deleted', 'Toast after deleting a place (undo action)');
  await H.tap(TAB.trip, { ms: 2000 });
  await H.tap('^Chọn điểm đến$', { ms: 2000 });
  await H.shot('tab_trip_pushed_destination', 'Pushed page inside Ra ngoài tab (destination picker)');
});

for (const scene of ['day', 'night']) {
  S(`forecast_${scene}`, { scene }, async H => {
    await H.scrollTo(scene === 'day' ? '^Hôm nay 20' : '^Hôm nay 21');
    await H.tap(scene === 'day' ? '^Hôm nay 20' : '^Hôm nay 21', { ms: 2500 });
    await H.shot(`forecast_${scene}_01_day_detail`, 'Forecast / day detail (pushed, tab bar visible)');
    await H.wheel(700); await H.shot(`forecast_${scene}_02_hourly`, 'Day detail scrolled: hourly table');
    await H.wheel(900); await H.shot(`forecast_${scene}_03_more`, 'Day detail scrolled further');
  });
}
S('forecast_share', {}, async H => {
  await H.scrollTo('^Hôm nay 20'); await H.tap('^Hôm nay 20', { ms: 2500 });
  await H.tap('^Chia sẻ$', { ms: 1500 }); await H.shot('forecast_share_sheet', 'Share action sheet from day detail');
});

for (const scene of ['day', 'night']) {
  S(`alerts_${scene}`, { scene }, async H => {
    await H.tap('^Cảnh báo$', { ms: 2500 }); await H.shot(`alerts_${scene}`, 'Alerts screen in replay ("Đã xảy ra" labels)');
    await H.wheel(600); await H.shot(`alerts_${scene}_scrolled`, 'Alerts scrolled');
  });
}
S('alert_settings', {}, async H => {
  await H.tap('^Cảnh báo$', { ms: 2500 }); await H.tap('^Cài đặt cảnh báo$', { ms: 2000 });
  await H.shot('alert_settings_01', 'Alert settings (iOS sliders)');
  await H.wheel(600); await H.shot('alert_settings_02_scrolled', 'Alert settings scrolled');
  await H.wheel(800); await H.shot('alert_settings_03_scrolled', 'Alert settings end');
});

async function toCompare(H) {
  await H.tap(TAB.places, { ms: 2000 }); await H.tap('^So sánh$');
  await H.tap('^Tân Sơn Nhất, ', { ms: 600 }); await H.tap('^Phường Bến Thành', { ms: 600 }); await H.tap('^Phường Thủ Đức', { ms: 600 });
  await H.shot(`compare_00_select${H.suffix}`, 'Places in compare-select mode (3/3 chosen)');
  await H.tap('^So sánh', { ms: 3500 });
}
for (const [suffix, text] of [['', 1], ['_text200', 2]]) {
  S(`compare${suffix}`, { text }, async H => {
    H.suffix = suffix;
    await toCompare(H);
    await H.shot(`compare_01${suffix}`, `Compare, ${text * 100}% text (${text === 1 ? 'columns' : 'stacked'} expected)`);
    await H.wheel(700); await H.shot(`compare_02${suffix}_scrolled`, 'Compare scrolled');
  });
}

async function settings(H) { await H.tap('^Cài đặt$', { ms: 2000 }); }
S('settings', {}, async H => {
  await settings(H); await H.shot('settings_01_root', 'Settings root (pushed, tab bar visible)');
  for (const [btn, file] of [['^Hiển thị', 'settings_02_display'], ['^Thông báo', 'settings_03_notify'],
    ['^Nơi và hoạt động', 'settings_04_places'], ['^Trợ năng', 'settings_05_accessibility'],
    ['^Nâng cao', 'settings_06_server_advanced'], ['^Trợ giúp', 'settings_07_help_info']]) {
    try {
      await H.tap(btn, { ms: 1800 }); await H.shot(file, `Settings > ${btn.slice(1)}`);
      await H.wheel(800); await H.shot(`${file}_scrolled`, `Settings > ${btn.slice(1)} scrolled`);
      await H.back(1500);
    } catch (e) { log.push({ file: `${file}.png`, ok: false, note: e.message }); }
  }
});
S('settings_toast', {}, async H => {
  await settings(H); await H.tap('^Nâng cao', { ms: 1800 });
  await H.tap('^Kiểm tra kết nối$', { ms: 700 }); await H.shot('toast_check_connection', 'Toast after "Kiểm tra kết nối"');
});
S('settings_text200', { text: 2 }, async H => {
  await settings(H); await H.shot('settings_01_root_text200', 'Settings root at 200% text');
  await H.wheel(800); await H.shot('settings_01_root_text200_scrolled', 'Settings root 200% scrolled');
});
S('account', {}, async H => {
  await settings(H); await H.tap('^Tài khoản', { ms: 2000 });
  await H.shot('account_01', 'Account / sync (signed out)');
  await H.wheel(800); await H.shot('account_02_scrolled', 'Account scrolled');
});
for (const [suffix, text] of [['', 1], ['_text200', 2]]) {
  S(`feedback${suffix}`, { text }, async H => {
    await settings(H); await H.tap('^Trợ giúp', { ms: 1800 }); await H.tap('^Phản hồi và báo lỗi', { ms: 2000 });
    await H.shot(`feedback_01${suffix}`, `Phản hồi (segmented controls, IosTextField) ${text * 100}% text`);
    await H.wheel(600); await H.shot(`feedback_02${suffix}_scrolled`, 'Phản hồi scrolled');
    if (!suffix) {
      const L = await H.labels(); console.log('  feedback labels:', L.filter(l => l.startsWith('button') || l.startsWith('radio')).join(' / '));
    }
  });
}
S('feedback_bochon', {}, async H => {
  await settings(H); await H.tap('^Trợ giúp', { ms: 1800 }); await H.tap('^Phản hồi và báo lỗi', { ms: 2000 });
  await H.tap('^Dự báo sai$', { ms: 1000 });
  await H.shot('feedback_03_du_bao_sai', 'Phản hồi, "Dự báo sai" chosen: optional segmented questions (none selected)');
  await H.tap('^Có$', { ms: 800 }); await H.tap('^Nóng|^Oi|^Bình thường', { ms: 800 }).catch(() => {});
  await H.shot('feedback_04_bo_chon', 'Optional answers selected: "Bỏ chọn" buttons visible');
  await H.fill('Mưa to ở Tân Bình lúc 15h nhưng app báo khô.').catch(e => console.log('  fill:', e.message.split('\n')[0]));
  await H.wheel(400); await H.shot('feedback_05_text_field', 'IosTextField with typed text');
});
S('ai_verify', {}, async H => {
  await H.tap('^AI hồi cứu|^Dự báo AI|Kiểm chứng AI', { ms: 4000 });
  await H.shot('ai_verify_01', 'Kiểm chứng AI (replay)');
  await H.wheel(800); await H.shot('ai_verify_02_scrolled', 'Kiểm chứng AI scrolled');
});
S('activities', {}, async H => {
  await settings(H); await H.tap('^Nơi và hoạt động', { ms: 1800 }); await H.tap('^Hoạt động yêu thích', { ms: 2500 });
  await H.shot('activities_01', 'Activities');
  await H.wheel(800); await H.shot('activities_02_scrolled', 'Activities scrolled');
});
S('onboarding', { onboarding: true, saved: false }, async H => {
  for (let i = 1; i <= 6; i++) {
    await H.shot(`onboarding_0${i}`, `Onboarding step ${i}`);
    try { await H.tap('^Tiếp tục$', { ms: 1500 }); } catch { break; }
  }
});
S('home_text200', { text: 2 }, async H => {
  await H.shot('home_text200_01_top', 'Home at 200% text');
  await H.wheel(700); await H.shot('home_text200_02_scrolled', 'Home 200% scrolled');
});
S('offline', { offline: true }, async H => {
  await H.wait(4000); await H.shot('offline_01_home', 'Home with API unreachable (requests aborted)');
  await H.wheel(600); await H.shot('offline_02_home_scrolled', 'Offline home scrolled');
});
S('small_375', { w: 375, h: 667 }, async H => {
  await H.shot('s375_home_day', 'Home 375x667');
  await H.tap(TAB.places, { ms: 2000 }); await H.shot('s375_places_day', 'Places 375x667');
  await H.tap(TAB.home, { ms: 1500 }); await settings(H); await H.shot('s375_settings', 'Settings 375x667');
});
S('small_375_night', { w: 375, h: 667, scene: 'night' }, async H => {
  await H.shot('s375_home_night', 'Home 375x667 night');
  await H.tap(TAB.map, { ms: 4000 }); await H.shot('s375_map_night', 'Map 375x667 night');
});
S('desktop', { w: 1440, h: 960, dpr: 1 }, async H => {
  await H.shot('d1440_home_day', 'Home 1440x960 (two-column)');
  await H.tap(TAB.map, { ms: 4000 }); await H.shot('d1440_map_day', 'Map 1440x960');
  await H.tap(TAB.home, { ms: 1500 }); await settings(H); await H.shot('d1440_settings', 'Settings 1440x960');
});
S('desktop_night', { w: 1440, h: 960, dpr: 1, scene: 'night' }, async H => {
  await H.shot('d1440_home_night', 'Home 1440x960 night');
});

for (const sc of scenarios) {
  if (ONLY && !ONLY.test(sc.name)) continue;
  console.log(`[${sc.name}]`);
  let ctx;
  try {
    const o = await open(sc.opts);
    ctx = o.ctx;
    await sc.fn(helpers(o.page, sc.name));
  } catch (e) {
    console.log('  FAILED:', e.message.split('\n')[0]);
    log.push({ file: `(${sc.name})`, ok: false, note: e.message.split('\n')[0] });
  } finally { await ctx?.close(); }
}
await browser.close();
fs.writeFileSync(path.join(OUT, 'capture_log.json'), JSON.stringify(log, null, 2));
console.log(`done: ${log.filter(l => l.ok).length} shots, ${log.filter(l => !l.ok).length} failures`);
