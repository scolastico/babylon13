// Focused real-browser layout checks, not the full game end-to-end suite.
// Requires playwright on NODE_PATH; optionally set CHROMIUM_EXECUTABLE and
// LOBBY_SCREENSHOT_DIR. Serves actual lobby assets on a disposable loopback port.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { chromium } = require('playwright');

const root = path.resolve(__dirname, '../..');
const dm = fs.readFileSync(path.join(root, 'modular_babylon/lobby/lobby.dm'), 'utf8');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
// Render the literal HTML emitted by DM, substituting fixture data only at its
// interpolation boundaries. Nested [] expressions can contain quotes themselves.
function fragment(marker, values = {}) {
  const line = dm.split('\n').find(line => line.includes(marker));
  assert.ok(line, 'DM fixture fragment exists: ' + marker);
  const source = line.slice(line.indexOf('"') + 1, line.lastIndexOf('"'));
  let output = '';
  for (let i = 0; i < source.length; i++) {
    if (source[i] !== '[') { output += source[i]; continue; }
    let end = i + 1, depth = 1;
    for (; end < source.length && depth; end++) {
      if (source[end] === '[') depth++;
      if (source[end] === ']') depth--;
    }
    const key = source.slice(i + 1, end - 1);
    assert.ok(Object.hasOwn(values, key), 'fixture value for ' + key);
    output += values[key];
    i = end - 1;
  }
  return output.replace(/\\"/g, '"').replace(/\\ref/g, 'fixture');
}
const longName = 'W'.repeat(60);
const longText = 'description'.repeat(40);
const maps = JSON.parse(read('_maps/babylon/catalog.json')).maps.map(map => ({
  ...map, preview_url: map.preview ? '/' + map.preview : null,
}));
const world = {
  id: '1'.repeat(32), name: longName, owner: 'tester', description: longText,
  map: 'babylon', state: 'stopped', role: 'owner', visibility: 'private',
  max_players: 12, players: 0, creative: 1, persistent: 1, kind: 'world',
  members: ['member'.repeat(10)],
};
const state = { ref: 'fixture', ckey: 'tester', worlds: [world], maps, player_limit: 12,
  limits: { max_worlds_per_player: 4, max_total_worlds_per_player: 20, max_players_per_world: 12 } };
const tabs = Array.from(dm.split('\n').find(line => line.includes('var/list/tabs =')).matchAll(/"([^"]+)" = "([^"]+)"/g));
const header = fragment('content = "<div class=\'brand\'>BABYLON 13') + tabs.map(([, tab, label]) =>
  fragment('content += "<a class=\'[selected', {
    'selected ? "active" : ""': tab === 'mine' ? 'active' : '',
    'selected ? "page" : "false"': tab === 'mine' ? 'page' : 'false',
    'tab == "tutorials" ? "Loading tutorials..." : "Loading worlds..."': 'Loading worlds...',
    src: '', 'lobby_payload(list("filter" = tab))': '', 'tabs[tab]': label, tab_count: '',
  })).join('') + fragment('content += "</nav><h2', { 'tabs[view_filter]': 'My worlds' });
const discord = fragment('return "<div class=\'discord linked\'>', {
  'html_encode(discord["name"])': longName, invite: '<a class="button">Open our Discord</a>',
});
const worldHtml = fragment('var/text = "<section class=\'card\'>', { world_name: longName,
  badges: "<span class='badge stopped'>Offline</span>" }) +
  fragment('text += "<div class=\'flags\'>', { 'html_encode(map_name)': 'Babylon', 'jointext(flags, "")': "<span class='badge creative'>Creative</span>" }) +
  fragment('text += "<p>[html_encode(card["description"])]', { 'html_encode(card["description"])': longText }) +
  "<div class='actions'><button class='button primary'>Start and join</button><button class='button'>Checkpoints</button>" +
  fragment('text += "<p class=\'card-error\'', { 'announce("card:[id]", card["error"], "alert")': '', 'html_encode(card["error"])': longText }) + '</div></section>';
const emptyHtml = fragment('content += "<div class=\'empty\'>', {
  'empty[view_filter]': 'You have no worlds yet.', create_button: '<p><button class="button primary">+ Create your first world</button></p>',
});
const loading = fragment("return \"<div class='loading-shell'><section class='loading' role='status' aria-live='polite' aria-busy", {
  'html_encode(world_name)': longName, 'html_encode(stage)': longText,
});
const restart = fragment("return \"<div class='loading-shell'><section class='loading' role='status' aria-live='polite'><div", {
  'html_encode(title)': 'Connection lost', 'html_encode(message)': longText,
});
// This HTTP geometry fixture has no native server. Mark its startup notification consumed
// before body.onload; the loading/native tests cover that callback and its emitted request.
const html = fragment('return "<!doctype html>', {
  src: '', poll_generation: 1,
  "file2text('modular_babylon/lobby/style.css')": read('modular_babylon/lobby/style.css'),
  "file2text('modular_babylon/lobby/loading.js')": read('modular_babylon/lobby/loading.js'),
  "file2text('modular_babylon/lobby/lobby.js')": read('modular_babylon/lobby/lobby.js'),
}) + '<main id="browser-content"></main><div id="action-loading">' + loading +
  '</div><div id="connection-lost" style="display:none">' + restart +
  '</div><div id="modal-root"></div><div id="toast-root" class="toasts" aria-live="polite"></div>' +
  '<script>window.fixture=' + JSON.stringify({ state, header, worldHtml, emptyHtml }) +
  ';lobbyWindowNotified=true;lobbyNavigate=function(url){window.lastNavigation=url;};setInterval(lobbyAlive,1000);</script></body></html>';

async function main() {
  const server = http.createServer((req, res) => {
    if (req.url === '/') { res.setHeader('Content-Type', 'text/html'); return res.end(html); }
    const file = path.resolve(root, '.' + req.url);
    if (!file.startsWith(root + path.sep) || !fs.existsSync(file)) { res.statusCode = 404; return res.end(); }
    res.setHeader('Content-Type', 'image/png');
    fs.createReadStream(file).pipe(res);
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  let browser;
  const failures = [];
  const check = async (name, fn) => {
    try { await fn(); console.log('PASS ' + name); }
    catch (error) { failures.push(name + ': ' + error.message); console.error('FAIL ' + failures.at(-1)); }
  };
  const screenshots = process.env.LOBBY_SCREENSHOT_DIR;
  if (screenshots) fs.mkdirSync(screenshots, { recursive: true });
  try {
    browser = await chromium.launch({ executablePath: process.env.CHROMIUM_EXECUTABLE || undefined, headless: true });
    const page = await browser.newPage();
    const pageErrors = [];
    page.on('pageerror', error => pageErrors.push(error.message));
    await page.goto('http://127.0.0.1:' + server.address().port);
    const snapshot = async name => {
      if (screenshots) await page.screenshot({ path: path.join(screenshots, name + '.png'), fullPage: true });
    };
    const render = async (empty = false) => page.evaluate(empty => {
      lobbyClose();
      renderLobby(JSON.stringify({ html: fixture.header + (empty ? fixture.emptyHtml : fixture.worldHtml),
        view: 'mine', revision: ++window.fixtureRevision || (window.fixtureRevision = 1), complete: true, state: fixture.state }));
    }, empty);
    const contained = async scope => {
      const overflow = await page.evaluate(scope => {
        const parent = document.querySelector(scope);
        const bounds = parent.getBoundingClientRect();
        return Array.from(parent.querySelectorAll('*')).filter(el => {
          const css = getComputedStyle(el);
          if (!el.getClientRects().length || css.position === 'absolute') return false;
          const r = el.getBoundingClientRect();
          // Decorative art is intentionally clipped by previews; single-line inputs
          // scroll their value internally. Their boxes must still fit the dialog.
          const clippedText = css.overflowX !== 'hidden' && el.tagName !== 'INPUT' && el.clientWidth > 0 && el.scrollWidth > el.clientWidth + 1;
          return r.width && (r.left < bounds.left - 1 || r.right > bounds.right + 1 || clippedText);
        }).map(el => el.tagName + '.' + el.className).slice(0, 12);
      }, scope);
      assert.deepEqual(overflow, [], 'no clipped or overflowing content in ' + scope);
    };
    const align = async () => {
      const geometry = await page.evaluate(() => Array.from(document.querySelectorAll('.map-row .map-card')).map(card => {
        const rect = selector => {
          const r = (selector ? card.querySelector(selector) : card).getBoundingClientRect();
          return { top: r.top, bottom: r.bottom, left: r.left, height: r.height };
        };
        return { card: rect(), preview: rect('.map-preview'), name: rect('.map-name'), desc: rect('.map-desc') };
      }));
      assert.equal(geometry.length, 2);
      for (const part of ['card', 'preview', 'name', 'desc']) {
        assert.ok(Math.abs(geometry[0][part].top - geometry[1][part].top) <= 1,
          part + ' tops aligned: ' + JSON.stringify(geometry));
      }
      assert.ok(Math.abs(geometry[0].card.height - geometry[1].card.height) <= 1, 'equal card heights');
    };
    const clickLowerSubmit = async () => {
      const point = await page.locator('#modal-submit').evaluate(el => {
        const r = el.getBoundingClientRect();
        const x = r.left + r.width / 2, y = Math.min(r.bottom - 3, innerHeight - 3);
        const hit = document.elementFromPoint(x, y);
        return { x, y, hit: hit && hit.closest('button') && hit.closest('button').id, request: lobbyRequestCounter };
      });
      assert.equal(point.hit, 'modal-submit', 'lower action edge is reachable without an invisible overlay');
      await page.mouse.click(point.x, point.y);
      assert.equal(await page.evaluate(() => lobbyRequestCounter), point.request + 1, 'the mouse click sends the real create request');
      assert.match(await page.evaluate(() => window.lastNavigation), /action=create;/);
      await page.evaluate(() => { lobbyModal.busy = false; lobbyRenderModal(); });
    };

    await page.setViewportSize({ width: 1920, height: 1080 });
    await render();
    await page.evaluate(() => lobbyOpenCreate());
    await snapshot('desktop-map-unselected');
    await check('desktop cards align before selection', align);
    for (const selection of ['babylon', 'creative_plane_s', 'creative_plane_m', 'creative_plane_l']) {
      await page.evaluate(selection => {
        if (selection === 'babylon') lobbyPickMap(document.querySelector('[data-card="babylon"]'));
        else lobbyPickSize(document.querySelector('[data-map="' + selection + '"]'));
      }, selection);
      await check(selection + ' cards align', align);
    }
    await page.focus('#size-creative_plane_l');
    await snapshot('desktop-map-selected');
    await check('selected card content color and space above sizes', async () => {
      const styles = await page.evaluate(() => {
        const card = document.querySelector('.map-card.selected');
        const body = card.querySelector('.map-body');
        const sizes = card.querySelector('.sizes');
        const desc = card.querySelector('.map-desc');
        const painted = el => {
          while (el && getComputedStyle(el).backgroundColor === 'rgba(0, 0, 0, 0)') el = el.parentElement;
          return getComputedStyle(el).backgroundColor;
        };
        return { body: painted(body), sizes: painted(sizes), gap: sizes.firstChild.getBoundingClientRect().top - desc.getBoundingClientRect().bottom };
      });
      assert.equal(styles.body, styles.sizes, 'background continues through size row');
      assert.ok(styles.gap >= 12, 'description has at least 12 px of breathing room');
    });
    await check('size focus is visible and contained', async () => {
      const focus = await page.locator('#size-creative_plane_l').evaluate(el => {
        const css = getComputedStyle(el);
        return { outline: css.outlineStyle, width: parseFloat(css.outlineWidth), offset: parseFloat(css.outlineOffset), shadow: css.boxShadow };
      });
      assert.ok((focus.outline !== 'none' && focus.width > 0 && focus.offset <= -focus.width) || focus.shadow.includes('inset'), JSON.stringify(focus));
    });
    for (const id of ['map-babylon', 'map-group-creative_plane']) {
      await page.focus('button#' + id);
      await check(id + ' focus stays inside the card selection', async () => {
        const focus = await page.locator('button#' + id).evaluate(el => {
          const css = getComputedStyle(el), ring = getComputedStyle(el, '::after');
          const card = getComputedStyle(el.closest('.map-card'));
          return { outline: css.outlineStyle, shadow: css.boxShadow, ringShadow: ring.boxShadow,
            ringBorder: parseFloat(ring.borderTopWidth), insets: [ring.top, ring.right, ring.bottom, ring.left].map(parseFloat),
            cardOutline: card.outlineStyle, cardShadow: card.boxShadow, selected: el.closest('.map-card').classList.contains('selected') };
        });
        assert.equal(focus.outline, 'none');
        assert.equal(focus.shadow, 'none');
        assert.equal(focus.ringShadow, 'none');
        assert.ok(focus.ringBorder > 0 && focus.insets.every(inset => inset > 0), JSON.stringify(focus));
        assert.equal(focus.cardOutline, 'none');
        assert.equal(focus.cardShadow === 'none', !focus.selected, 'only the selected card has an outer shadow');
      });
    }
    await page.focus('#size-creative_plane_l');
    await check('modal ids are unique for focus and accessible labels', async () => {
      const ids = await page.locator('.modal [id]').evaluateAll(elements => elements.map(el => el.id));
      assert.equal(new Set(ids).size, ids.length, 'duplicate modal ids');
    });
    await check('group help is associated with each builder card', async () => {
      const descriptions = await page.locator('.map-row > .map-grid').evaluateAll(elements => elements.map(el => {
        const help = document.getElementById(el.getAttribute('aria-describedby'));
        return help ? help.textContent : '';
      }));
      assert.equal(descriptions.length, 2);
      assert.ok(descriptions.every(Boolean), JSON.stringify(descriptions));
    });
    await check('keyboard sizes, focus trap and form values', async () => {
      await page.keyboard.press('ArrowRight');
      assert.equal(await page.locator('#size-creative_plane_s').getAttribute('aria-checked'), 'true');
      assert.equal(await page.evaluate(() => document.activeElement.id), 'size-creative_plane_s');
      await page.evaluate(() => lobbyWizardStep('details'));
      await page.fill('#f-name', 'My saved choice');
      await page.fill('#f-description', 'Description kept on return');
      await page.evaluate(() => lobbyWizardStep('map'));
      await page.evaluate(() => lobbyWizardStep('details'));
      assert.equal(await page.inputValue('#f-name'), 'My saved choice');
      assert.equal(await page.inputValue('#f-description'), 'Description kept on return');
      await page.locator('.modal-foot button').last().focus();
      await page.keyboard.press('Tab');
      assert.equal(await page.evaluate(() => document.activeElement.className), 'modal-close');
      await page.keyboard.press('Shift+Tab');
      assert.equal(await page.evaluate(() => document.activeElement.id), 'modal-submit');
    });
    // Different group/card descriptions must not move preview/title/description tops.
    await page.evaluate(() => {
      window.layoutOriginalHelp = LOBBY_GROUPS.babylon.help;
      window.layoutOriginalDescription = fixture.state.maps[0].description;
      LOBBY_GROUPS.babylon.help = 'A longer group introduction. '.repeat(12);
      fixture.state.maps[0].description = 'A long Babylon description. '.repeat(20);
      lobbyUpdateState(fixture.state);
      lobbyWizardStep('map');
    });
    await check('unequal group and card descriptions align', align);
    await page.evaluate(() => {
      window.layoutAllMaps = lobbyState.maps;
      lobbyState.maps = [fixture.state.maps[0]];
      lobbyRenderModal();
    });
    await check('a single available map fills its row', async () => {
      const widths = await page.evaluate(() => ({
        grid: document.querySelector('.map-row').getBoundingClientRect().width,
        card: document.querySelector('.map-card').getBoundingClientRect().width,
      }));
      assert.ok(widths.card >= widths.grid - 1, JSON.stringify(widths));
    });
    await page.evaluate(() => {
      fixture.state.maps = window.layoutAllMaps;
      LOBBY_GROUPS.babylon.help = window.layoutOriginalHelp;
      fixture.state.maps[0].description = window.layoutOriginalDescription;
    });

    for (const width of [320, 375, 600, 640, 641, 768, 1920]) {
      await page.setViewportSize({ width, height: width === 1920 ? 1080 : 740 });
      await render();
      await check(width + ' world list long names/descriptions/errors', () => contained('main'));
      await snapshot(width + '-world-list');
      await page.evaluate(discord => { document.querySelector('main').innerHTML += discord; }, discord);
      await check(width + ' Discord bar long name', () => contained('main'));
      await render(true);
      await check(width + ' empty world list', () => contained('main'));
      await page.evaluate(() => lobbyOpenCreate());
      await check(width + ' map picker', () => contained('.modal'));
      if (width <= 600) await check(width + ' station columns preserve the responsive grid', async () => {
        const columns = await page.locator('.map-group .map-grid').evaluate(el => getComputedStyle(el).gridTemplateColumns.split(' ').length);
        assert.equal(columns, width < 400 ? 1 : 2);
      });
      if (width > 640) await check(width + ' cards align', align);
      await snapshot(width + '-map');
      if (width === 600) {
        await page.locator('.map-group').evaluate(el => el.scrollIntoView());
        await snapshot('600-stations');
        await page.locator('#modal-backdrop').evaluate(el => { el.scrollTop = 0; });
      }
      await page.evaluate(() => lobbyPickMap(document.querySelector('[data-card="babylon"]')));
      await check(width + ' selected Babylon fits', () => contained('.modal'));
      for (const size of ['s', 'm', 'l']) {
        await page.evaluate(size => lobbyPickSize(document.querySelector('[data-map="creative_plane_' + size + '"]')), size);
        await check(width + ' Creative Plane ' + size + ' fits', () => contained('.modal'));
      }
      await page.evaluate(() => {
        lobbyPickSize(document.querySelector('[data-map="creative_plane_m"]'));
        lobbyWizardStep('details');
      });
      await check(width + ' details and chosen map', () => contained('.modal'));
      if (width <= 375) await check(width + ' empty initial toast root cannot block lower dialog action', clickLowerSubmit);
      if (width <= 375) await check(width + ' details footer leaves room for the form', async () => {
        const height = await page.locator('.modal-foot').evaluate(el => el.getBoundingClientRect().height);
        assert.ok(height < 160, 'four actions fit in two rows; footer height ' + height);
      });
      await snapshot(width + '-details');
      await page.evaluate(() => { lobbyModal.error = 'Failure'.repeat(80); lobbyRenderModal(); });
      await check(width + ' inline and footer errors', () => contained('.modal'));
      await check(width + ' long footer error leaves room for content', async () => {
        const height = await page.locator('.modal-foot').evaluate(el => el.getBoundingClientRect().height);
        assert.ok(height < page.viewportSize().height * 0.4, 'footer height ' + height);
      });
      await snapshot(width + '-errors');
      await page.evaluate(() => { lobbyModal.busy = true; lobbyModal.busyLabel = 'Creating and starting...'; lobbyRenderModal(); });
      await check(width + ' busy details', () => contained('.modal'));
      await page.evaluate(() => { lobbyModal.busy = false; lobbyClose(); lobbyOpenWorld('members', fixture.state.worlds[0].id); });
      await check(width + ' member names', () => contained('.modal'));
      await page.evaluate(() => lobbyOpenModal({ type: 'join', world: fixture.state.worlds[0].id, fields: { password: '' } }));
      await check(width + ' long Join title', () => contained('.modal'));
      await page.evaluate(() => lobbyOpenWorld('delete', fixture.state.worlds[0].id));
      await check(width + ' danger confirmation', () => contained('.modal'));
      await page.evaluate(() => lobbyOpenModal({ type: 'discord', fields: {}, command: '/link ' + 'x'.repeat(60) }));
      await check(width + ' Discord copy row', () => contained('.modal'));
      await page.evaluate(() => lobbyOpenModal({ type: 'checkpoints', world: fixture.state.worlds[0].id,
        fields: { generation: '' }, checkpoints: [
          { generation: 'save-20261114-130000-3', current: 1, objects: 4000 },
          { generation: 'save-20261114-120000-2', current: 0, objects: 3000 },
        ] }));
      await check(width + ' checkpoint rows', () => contained('.modal'));
      await page.evaluate(() => { lobbyModal.loading = true; lobbyRenderModal(); });
      await check(width + ' checkpoint loading', () => contained('.modal'));
      await page.evaluate(() => {
        lobbyClose();
        document.querySelector('main').innerHTML = lobbyTutorialSection('Tutorials', '', [
          { id: 't', title: fixture.state.worlds[0].name, description: fixture.state.worlds[0].description,
            author: 'tester', map: 'babylon', map_name: 'Babylon', status: 'pending', playing: 'running' },
        ], '', true);
      });
      await check(width + ' tutorial cards', () => contained('main'));
      await check(width + ' tutorial badges do not overlap', async () => {
        const badges = await page.locator('.tutorial-preview .badge').evaluateAll(elements => elements.map(el => {
          const r = el.getBoundingClientRect();
          return { left: r.left, right: r.right, top: r.top, bottom: r.bottom };
        }));
        for (let i = 0; i < badges.length; i++) for (let j = i + 1; j < badges.length; j++) {
          const a = badges[i], b = badges[j];
          assert.ok(a.right <= b.left || b.right <= a.left || a.bottom <= b.top || b.bottom <= a.top, JSON.stringify(badges));
        }
      });
      await snapshot(width + '-tutorials');
      await page.evaluate(() => lobbyToast('Failure'.repeat(80), 'error'));
      await check(width + ' error toast', () => contained('.toasts'));
      await check(width + ' toast shadows have space inside the scroll container', async () => {
        const padding = await page.locator('.toasts').evaluate(el => {
          const css = getComputedStyle(el);
          return [css.paddingLeft, css.paddingRight, css.paddingBottom].map(parseFloat);
        });
        assert.ok(padding.every(value => value >= 12), JSON.stringify(padding));
      });
      if (width === 600 || width === 320) await snapshot(width + '-toast');
      await page.evaluate(() => { lobbyToast('Failure'.repeat(80), 'error'); lobbyToast('Failure'.repeat(80), 'error'); });
      await check(width + ' toast stack fits the viewport', async () => {
        const box = await page.locator('.toasts').boundingBox();
        assert.ok(box.y >= 0 && box.height <= page.viewportSize().height / 2, JSON.stringify(box));
      });
      await check(width + ' long toast stack scrolls and dismisses', async () => {
        const scrollable = await page.locator('.toasts').evaluate(el => {
          el.scrollTop = el.scrollHeight;
          return el.scrollTop > 0;
        });
        assert.ok(scrollable, 'all long messages remain reachable');
        await page.locator('.toast-close').last().click();
        assert.equal(await page.locator('.toast').count(), 2);
        await page.locator('.toast-close').last().click();
        await page.locator('.toast-close').last().click();
        assert.equal(await page.locator('.toast').count(), 0);
      });
      if (width <= 375) {
        await page.evaluate(() => {
          lobbyOpenCreate();
          lobbyPickSize(document.querySelector('[data-map="creative_plane_m"]'));
          lobbyWizardStep('details');
        });
        await check(width + ' dismissed last toast cannot block lower dialog action', clickLowerSubmit);
      }
      await page.evaluate(() => showLobbyLoading(fixture.state.worlds[0].name, fixture.state.worlds[0].description));
      await check(width + ' loading long world name', () => contained('#action-loading'));
      await page.evaluate(() => { document.querySelector('#action-loading').style.display = 'none'; document.querySelector('#connection-lost').style.display = 'block'; });
      await check(width + ' reconnect screen', () => contained('#connection-lost'));
      await page.evaluate(() => { document.querySelector('#connection-lost').style.display = 'none'; });
    }
    assert.deepEqual(pageErrors, [], 'no browser script errors');
  } finally {
    if (browser) await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
  assert.equal(failures.length, 0, failures.join('\n'));
  console.log('Lobby real-browser layout and interaction checks passed.');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
