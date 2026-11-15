// Run with node tools/babylon/test_lobby_ui.cjs.
// The lobby dialogs (modular_babylon/lobby/lobby.js) against a minimal DOM shim, like
// test_lobby_loading.cjs: the page script renders HTML strings into #modal-root and sends
// requests by navigating to byond:// links, so both are recorded here.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

const elements = {};
const writes = {};
for (const id of ['browser-content', 'action-loading', 'loading-world', 'loading-stage', 'connection-lost', 'modal-root', 'toast-root']) {
  const element = { id, style: {}, textContent: '', querySelectorAll: () => [], querySelector: () => null };
  writes[id] = 0;
  Object.defineProperty(element, 'innerHTML', {
    get() { return this.html || ''; },
    set(value) { this.html = value; writes[id]++; },
  });
  elements[id] = element;
}
const navigations = [];
const keyHandlers = [];
const timers = [];
const body = { className: '', contains: () => false };
const context = {
  Date,
  JSON,
  Math,
  Number,
  String,
  encodeURIComponent,
  setInterval() {},
  setTimeout(fn) { timers.push(fn); },
  document: {
    body,
    activeElement: null,
    documentElement: { scrollTop: 0 },
    getElementById: id => elements[id] || null,
    addEventListener(type, fn) { if (type === 'keydown') keyHandlers.push(fn); },
  },
  window: {
    pageYOffset: 0,
    scrollTo(x, y) { this.pageYOffset = y; },
    location: { set href(url) { navigations.push(url); }, get href() { return navigations[navigations.length - 1] || ''; } },
  },
};
vm.createContext(context);
for (const file of ['loading.js', 'lobby.js']) {
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../../modular_babylon/lobby', file), 'utf8'), context, { filename: file });
}

const modalHtml = () => elements['modal-root'].innerHTML;
const toastHtml = () => elements['toast-root'].innerHTML;
const modal = () => context.lobbyModal;
const button = attributes => ({ getAttribute: name => (name in attributes ? attributes[name] : null) });
/** The last navigation as {action, payload, request}; fails if nothing was sent. */
function lastRequest() {
  assert.ok(navigations.length, 'a request was sent');
  const url = navigations[navigations.length - 1];
  assert.match(url, /^byond:\/\/\?src=\[0x3000001\];/);
  const params = {};
  for (const part of url.slice(url.indexOf('?') + 1).split(';')) {
    const at = part.indexOf('=');
    params[part.slice(0, at)] = decodeURIComponent(part.slice(at + 1));
  }
  return { action: params.action, payload: JSON.parse(params.payload), request: params.request ? Number(params.request) : 0 };
}
function expectNoRequest(during, message) {
  const before = navigations.length;
  during();
  assert.equal(navigations.length, before, message);
}

const maps = [
  { id: 'babylon', name: 'Babylon', description: 'The classic Babylon builder world.', group: 'babylon', size: null, build: 'babylon', preview: null, multiz: 0 },
  { id: 'creative_plane_s', name: 'Creative Plane S', description: 'A 50x50 floor.', group: 'creative_plane', size: 'S', build: 'station', preview: null, multiz: 0 },
  { id: 'creative_plane_m', name: 'Creative Plane M', description: 'A 100x100 floor.', group: 'creative_plane', size: 'M', build: 'station', preview: null, multiz: 0 },
  { id: 'creative_plane_l', name: 'Creative Plane L', description: 'A 200x200 floor.', group: 'creative_plane', size: 'L', build: 'station', preview: null, multiz: 0 },
  { id: 'metastation', name: 'MetaStation', description: 'A compact, dense station.', group: 'station', size: null, build: 'station', preview: null, multiz: 0 },
  { id: 'icebox', name: 'IceBoxStation', description: 'A frozen station on several levels.', group: 'station', size: null, build: 'station', preview: 'x.png', preview_url: 'babylon_map_icebox.png', multiz: 1 },
];
const world = (id, extra) => Object.assign({
  id, owner: 'tester', name: 'World ' + id, description: '', visibility: 'private', max_players: 8, map: 'babylon',
  creative: 0, persistent: 1, kind: 'world', role: 'owner', state: 'stopped', players: 0,
}, extra);
const hex = n => String(n).repeat(32).slice(0, 32);
function state(worlds, limits, extra) {
  return Object.assign({
    ref: '[0x3000001]', ckey: 'tester', admin: 0, worlds, maps, player_limit: 12,
    limits: Object.assign({ max_worlds_per_player: 4, max_total_worlds_per_player: 20, max_players_per_world: 12 }, limits || {}),
  }, extra || {});
}
let revision = 0;
function render(worlds, limits, extra, complete = true) {
  context.renderLobby(JSON.stringify({ html: '<p>list ' + revision + '</p>', view: 'mine', revision: revision++, complete, state: state(worlds, limits, extra) }));
}

const worlds = [
  world(hex(1), { name: 'Old <b>Base</b>' }),
  world(hex(2), { persistent: 0 }),
  world(hex(3), { state: 'running', creative: 1 }),
  world(hex(4), { owner: 'someone', role: 'guest', visibility: 'password', state: 'running', name: 'Locked' }),
];
const stationWorld = world(hex(6), { map: 'metastation', name: 'Meta' });
render(worlds);

// --- Create wizard: map picker -------------------------------------------------------------
assert.equal(context.lobbyOpenCreate(), false, 'opening a dialog does not follow a link');
assert.equal(navigations.length, 0, 'opening the wizard sends nothing');
assert.match(modalHtml(), /role="dialog" aria-modal="true"/);
assert.match(modalHtml(), /Choose a map/);
assert.match(body.className, /modal-open/);
assert.equal((modalHtml().match(/data-card="group:creative_plane"/g) || []).length, 1, 'Creative Plane is a single card');
for (const [size, area] of [['S', '50×50'], ['M', '100×100'], ['L', '200×200']]) {
  assert.match(modalHtml(), new RegExp('data-map="creative_plane_' + size.toLowerCase() + '"[^>]*>' + size + ' · ' + area + '<'), 'size buttons name the floor');
}
assert.match(modalHtml(), /Creative Plane<\/span><span class="map-desc">Pick a size below\.</, 'an unselected Creative Plane card asks for a size');
assert.doesNotMatch(modalHtml(), /data-autofocus="1"[^>]*onclick="return lobbyPickMap/, 'no card is focused before one is chosen');
assert.match(modalHtml(), /<div class="map-row"><section class="map-group" aria-label="Babylon">.*<\/section><section class="map-group" aria-label="Creative Plane">.*<\/section><\/div><section class="map-group" aria-label="Stations">/,
  'single-card groups share a row');
for (const label of ['Babylon', 'Creative Plane', 'Stations']) assert.match(modalHtml(), new RegExp('<h3>' + label + '</h3>'), label + ' group');
assert.match(modalHtml(), /IceBoxStation<span class="badge multiz">Multi-level<\/span>/, 'multi-z maps carry a badge');
assert.doesNotMatch(modalHtml(), /MetaStation<span class="badge multiz">/);
assert.match(modalHtml(), /<img src="babylon_map_icebox.png"/, 'a preview image is used when there is one');
assert.match(modalHtml(), /class="map-initials">MS</, 'maps without a preview get a generated placeholder');
assert.match(modalHtml(), /<b>2 of 4<\/b> saved worlds/, 'saved-world counter (non-persistent worlds excluded)');
assert.match(modalHtml(), /<b>3 of 20<\/b> worlds in total/, 'total counter');
assert.match(modalHtml(), /Next: details<\/button>/);
assert.match(modalHtml(), /type="submit" class="button primary" disabled>Next: details/, 'next needs a map');
context.lobbySubmit();
assert.equal(modal().step, 'map', 'enter without a map stays on the map step');

context.lobbyPickMap(button({ 'data-card': 'group:creative_plane' }));
assert.equal(modal().fields.map, 'creative_plane_m', 'the Creative Plane card starts at size M');
assert.equal(modal().fields.creative, 1, 'Creative Plane suggests creative mode');
assert.equal(modal().fields.name, 'My Creative Plane');
context.lobbyPickSize(button({ 'data-map': 'creative_plane_l' }));
assert.equal(modal().fields.map, 'creative_plane_l');
assert.match(modalHtml(), /class="size selected"[^>]*aria-checked="true" tabindex="0" data-map="creative_plane_l"/);
assert.match(modalHtml(), /aria-checked="false" tabindex="-1" data-map="creative_plane_s"/, 'one tab stop per size group');
// Arrow keys move between sizes (roving tabindex).
let arrowPrevented = false;
context.lobbySizeKey({ keyCode: 37, preventDefault() { arrowPrevented = true; } }, button({ 'data-map': 'creative_plane_l' }));
assert.equal(modal().fields.map, 'creative_plane_m');
assert.equal(arrowPrevented, true);
context.lobbySizeKey({ keyCode: 39, preventDefault() {} }, button({ 'data-map': 'creative_plane_m' }));
assert.equal(modal().fields.map, 'creative_plane_l');
context.lobbySizeKey({ keyCode: 39, preventDefault() {} }, button({ 'data-map': 'creative_plane_l' }));
assert.equal(modal().fields.map, 'creative_plane_s', 'arrows wrap around');
context.lobbyPickSize(button({ 'data-map': 'creative_plane_l' }));
assert.equal(navigations.length, 0);

// --- Create wizard: details -------------------------------------------------------------------
context.lobbySubmit(); // Enter on the map step goes on to the details
assert.equal(modal().step, 'details');
assert.match(modalHtml(), /New world · step 2 of 2/);
assert.match(modalHtml(), /Creative Plane L/);
assert.match(modalHtml(), /Everyone in this world gets the Creative panel: spawn items, fly, godmode/);
assert.match(modalHtml(), /Saves automatically\. Turn off for throwaway rounds/);
assert.match(modalHtml(), /id="f-creative" checked/);
assert.doesNotMatch(modalHtml(), /id="f-password"/, 'no password field unless the world uses one');
for (const id of ['private', 'showcase', 'password', 'public']) assert.match(modalHtml(), new RegExp('id="vis-' + id + '"'));
context.lobbyField('visibility', 'password', true);
assert.match(modalHtml(), /<input type="password" id="f-password"/, 'the password field is a password input');
context.lobbyField('name', '  Sandbox  ');
context.lobbyField('description', 'Testing things');
context.lobbyField('max_players', '6');
context.lobbyField('persistent', 0, true);

// Errors from the page's own checks keep the dialog open.
context.lobbySubmit();
assert.equal(navigations.length, 0, 'a password world needs a password');
assert.match(modalHtml(), /role="alert">Choose a password for your guests\./);
context.lobbyField('password', 'hunter2');

// A poll while the player is typing must not touch the open dialog.
context.lobbyField('name', 'Sandbox typed');
const modalWrites = writes['modal-root'];
render(worlds.concat([world(hex(5))]));
assert.equal(writes['modal-root'], modalWrites, 'a poll does not re-render the open dialog');
assert.equal(modal().fields.name, 'Sandbox typed', 'the typed value survives a poll');
context.lobbyField('creative', 1, true); // any later re-render shows the typed value again
assert.match(modalHtml(), /id="f-name" maxlength="60" data-autofocus="1" value="Sandbox typed"/);
assert.match(modalHtml(), /<b>3 of 4<\/b> saved worlds/, 'counters use the newest poll');

context.lobbySubmit(); // Enter: Create & join
let sent = lastRequest();
assert.equal(sent.action, 'create');
assert.equal(sent.request, 1);
assert.deepEqual(sent.payload, {
  map: 'creative_plane_l', name: 'Sandbox typed', description: 'Testing things', visibility: 'password',
  max_players: 6, creative: 1, persistent: 0, password: 'hunter2', join: 1,
});
assert.equal(modal().busy, true);
assert.match(modalHtml(), /Creating and starting\.\.\./);
expectNoRequest(() => context.lobbySubmit(), 'a busy dialog does not send twice');
assert.match(modalHtml(), /id="f-name"[^>]* disabled>/, 'fields are disabled while the request runs');
// While a request runs, Esc and the backdrop do not close the dialog, so its answer is not lost.
keyHandlers.forEach(fn => fn({ keyCode: 27, preventDefault() {} }));
context.lobbyBackdrop({ target: { id: 'modal-backdrop' } });
assert.equal(modal().type, 'create', 'a busy dialog ignores Esc and the backdrop');

// Supervisor errors are shown inline; the dialog stays open with the values.
context.lobbyResult(JSON.stringify({ request: 1, error: 'Your total world limit has been reached' }));
assert.equal(modal().type, 'create');
assert.equal(modal().busy, false);
assert.match(modalHtml(), /class="modal-error">Your total world limit has been reached/);
assert.match(modalHtml(), /<footer class="modal-foot"><span class="foot-error" role="alert">Your total world limit has been reached<\/span>/,
  'the error is repeated next to the buttons');
assert.equal(modal().scrollToError, false, 'the error was scrolled into view once');
assert.match(modalHtml(), /value="Sandbox typed"/);
context.lobbyCreate(0);
sent = lastRequest();
assert.equal(sent.payload.join, undefined, 'Create only does not join');
assert.equal(sent.request, 2);
context.lobbyResult(JSON.stringify({ request: 2, ok: 1, notice: 'Sandbox typed was created.' }));
assert.equal(modal(), null, 'success closes the dialog');
assert.equal(modalHtml(), '');
assert.doesNotMatch(body.className, /modal-open/);
assert.match(toastHtml(), /Sandbox typed was created\./);

// --- Esc and backdrop -------------------------------------------------------------------------
let prevented = false;
context.lobbyOpenCreate();
keyHandlers.forEach(fn => fn({ keyCode: 27, preventDefault() { prevented = true; } }));
assert.equal(modal(), null, 'Esc closes the dialog');
assert.equal(prevented, true);
assert.equal(modalHtml(), '');
context.lobbyOpenCreate();
context.lobbyBackdrop({ target: { id: 'some-card' } });
assert.notEqual(modal(), null, 'a click inside the dialog does not close it');
context.lobbyBackdrop({ target: { id: 'modal-backdrop' } });
assert.equal(modal(), null, 'a click on the backdrop closes it');

// --- Limits -------------------------------------------------------------------------------
const full = [];
for (let i = 1; i <= 4; i++) full.push(world(hex(i)));
render(full);
context.lobbyOpenCreate();
assert.equal(modal().fields.persistent, 0, 'at the saved-world limit new worlds start unsaved');
context.lobbyPickMap(button({ 'data-card': 'metastation' }));
assert.equal(modal().fields.creative, 0);
context.lobbyWizardStep('details');
assert.match(modalHtml(), /id="f-persistent" disabled/, 'persistence cannot be turned on at the limit');
assert.match(modalHtml(), /You already have 4 of 4 saved worlds/);
context.lobbyClose();
render(full, { max_total_worlds_per_player: 4 });
context.lobbyOpenCreate();
assert.match(modalHtml(), /You have reached your limit of 4 worlds/);
context.lobbyPickMap(button({ 'data-card': 'babylon' }));
assert.match(modalHtml(), /type="submit" class="button primary" disabled>Next: details/, 'the total limit blocks the wizard');
context.lobbyClose();
render(full, { max_total_worlds_per_player: 4 }, { admin: 1 });
context.lobbyOpenCreate();
assert.match(modalHtml(), /limits do not apply to you/, 'administrators are exempt');
assert.equal(modal().fields.persistent, 1);
context.lobbyClose();
render(worlds);

// --- Danger confirmations need an explicit click ---------------------------------------------
context.lobbyOpenWorld('delete', button({ 'data-id': hex(1) }));
assert.match(modalHtml(), /role="alertdialog"/);
assert.match(modalHtml(), /Old &lt;b&gt;Base&lt;\/b&gt;/, 'world names are escaped');
assert.doesNotMatch(modalHtml(), /Old <b>Base/);
assert.match(modalHtml(), /cannot be undone/);
assert.match(modalHtml(), /id="modal-confirm"[^>]* disabled>Delete permanently/);
expectNoRequest(() => context.lobbySubmit(), 'Enter never confirms a deletion');
expectNoRequest(() => context.lobbyConfirm(), 'the button stays locked until the name is typed');
context.lobbyConfirmName('Old <b>Base</b>');
context.lobbyConfirm();
sent = lastRequest();
assert.equal(sent.action, 'delete');
assert.deepEqual(sent.payload, { world: hex(1), confirm: 1, confirm_name: 'Old <b>Base</b>' });
context.lobbyResult(JSON.stringify({ request: sent.request, error: 'Stop the world before deleting it' }));
assert.match(modalHtml(), /Stop the world before deleting it/, 'delete errors stay in the dialog');
context.lobbyClose();

context.lobbyOpenWorld('reset', button({ 'data-id': hex(2) }));
assert.match(modalHtml(), /All of its saves and checkpoints are permanently deleted/);
expectNoRequest(() => context.lobbySubmit(), 'Enter never confirms a reset');
context.lobbyConfirmName('World ' + hex(2));
context.lobbyConfirm();
sent = lastRequest();
assert.equal(sent.action, 'reset');
assert.deepEqual(sent.payload, { world: hex(2), confirm: 1, confirm_name: 'World ' + hex(2) });
context.lobbyResult(JSON.stringify({ request: sent.request, ok: 1, notice: 'reset done' }));
assert.equal(modal(), null);

context.lobbyOpenWorld('stop', button({ 'data-id': hex(3) }));
assert.match(modalHtml(), /saves a final checkpoint/);
expectNoRequest(() => context.lobbySubmit(), 'Enter never confirms a stop');
context.lobbyConfirm();
sent = lastRequest();
assert.equal(sent.action, 'stop');
assert.deepEqual(sent.payload, { world: hex(3), confirm: 1 });
context.lobbyResult(JSON.stringify({ request: sent.request, ok: 1 }));
assert.equal(modal(), null);

// --- Rollback: pick, then confirm ---------------------------------------------------------
context.lobbyOpenWorld('checkpoints', button({ 'data-id': hex(1) }));
sent = lastRequest();
assert.equal(sent.action, 'checkpoints');
assert.match(modalHtml(), /Loading saved checkpoints/);
context.lobbyResult(JSON.stringify({ request: sent.request, ok: 1, latest: 'save-20261114-130000-3', checkpoints: [
  { generation: 'save-20261114-130000-3', current: 1, objects: 40 },
  { generation: 'save-20261114-120000-2', current: 0, objects: 30 },
  { generation: 'save-20261113-090502-1', current: 0, objects: 20 },
] }));
assert.match(modalHtml(), /2026-11-13 09:05:02/);
assert.match(modalHtml(), /value="save-20261114-130000-3" disabled/, 'the current checkpoint cannot be restored');
context.lobbyField('generation', 'save-20261113-090502-1', true);
expectNoRequest(() => context.lobbySubmit(), 'Enter does not restore');
context.lobbyCheckpointStep('confirm');
assert.match(modalHtml(), /<b>2 newer checkpoints<\/b>/);
assert.match(modalHtml(), /permanently deleted/);
expectNoRequest(() => context.lobbySubmit(), 'Enter does not confirm a rollback');
context.lobbyConfirm();
sent = lastRequest();
assert.equal(sent.action, 'rollback');
assert.deepEqual(sent.payload, { world: hex(1), generation: 'save-20261113-090502-1', expected_latest: 'save-20261114-130000-3', confirm: 1 });
context.lobbyClose();

// --- Settings, members, join password, Discord ----------------------------------------------
context.lobbyOpenWorld('edit', button({ 'data-id': hex(3) }));
assert.match(modalHtml(), /Stop it to change its settings/, 'a running world explains why settings are locked');
assert.match(modalHtml(), /id="f-creative" checked disabled/);
expectNoRequest(() => context.lobbySubmit(), 'a running world cannot be edited');
context.lobbyClose();
context.lobbyOpenWorld('edit', button({ 'data-id': hex(2) }));
assert.match(modalHtml(), /id="f-persistent" onclick/, 'a stopped world can toggle persistence');
context.lobbyField('persistent', 1, true);
context.lobbySubmit();
sent = lastRequest();
assert.equal(sent.action, 'edit');
assert.deepEqual(sent.payload, { world: hex(2), name: 'World ' + hex(2), description: '', visibility: 'private', max_players: 8, creative: 0, persistent: 1 });
context.lobbyClose();

// Members: the current list with a remove button each, and an add field; the dialog stays open.
render(worlds.map(w => w.id === hex(1) ? Object.assign({}, w, { members: ['alice', 'bob'] }) : w).concat([stationWorld]));
context.lobbyOpenWorld('members', button({ 'data-id': hex(1) }));
assert.match(modalHtml(), /<li><span>alice<\/span><button type="button" class="button small danger" data-member="alice"/);
assert.match(modalHtml(), /Members can start this world while you are away/, 'Babylon wording');
context.lobbyField('member', 'Some Friend');
context.lobbySubmit();
sent = lastRequest();
assert.deepEqual(sent.payload, { world: hex(1), member: 'Some Friend', role: 'member' });
context.lobbyResult(JSON.stringify({ request: sent.request, ok: 1, notice: 'Some Friend is now a member.' }));
assert.equal(modal().type, 'members', 'Members stays open after a change');
assert.equal(modal().fields.member, '', 'the add field is cleared');
const membersWrites = writes['modal-root'];
render(worlds.map(w => w.id === hex(1) ? Object.assign({}, w, { members: ['alice', 'bob', 'somefriend'] }) : w).concat([stationWorld]));
assert.ok(writes['modal-root'] > membersWrites, 'the member list refreshes after a change');
assert.match(modalHtml(), /data-member="somefriend"/);
context.lobbyRemoveMember(button({ 'data-member': 'bob' }));
sent = lastRequest();
assert.deepEqual(sent.payload, { world: hex(1), member: 'bob', role: 'remove' });
assert.match(modalHtml(), /Removing\.\.\./);
context.lobbyResult(JSON.stringify({ request: sent.request, error: 'Invalid membership change' }));
assert.match(modalHtml(), /foot-error" role="alert">Invalid membership change/);
context.lobbyClose();
context.lobbyOpenWorld('members', button({ 'data-id': hex(6) }));
assert.match(modalHtml(), /Only you \(or an admin\) can press Start round, so the round waits for you\./, 'station wording');
assert.match(modalHtml(), /No members yet\./);
context.lobbyClose();
render(worlds);

assert.equal(context.lobbyJoin(button({ 'data-id': hex(4), 'data-password': '1' })), false, 'a password join opens a dialog instead of the link');
assert.match(modalHtml(), /<input type="password" id="join-password"/, 'the join password is a password input');
context.lobbyField('password', 'secret');
context.lobbySubmit();
sent = lastRequest();
assert.equal(sent.action, 'join');
assert.deepEqual(sent.payload, { world: hex(4), password: 'secret' });
context.lobbyResult(JSON.stringify({ request: sent.request, error: 'This world is private or the password is incorrect' }));
assert.match(modalHtml(), /password is incorrect/, 'a wrong password is shown in the dialog');
context.lobbyClose();

context.lobbyOpenDiscordLink();
sent = lastRequest();
assert.equal(sent.action, 'discord_link');
context.lobbyResult(JSON.stringify({ request: sent.request, ok: 1, command: '/link code:ABC123', invite: 1 }));
assert.match(modalHtml(), /id="discord-command" readonly value="\/link code:ABC123"/);
assert.match(modalHtml(), /Open our Discord/);
context.lobbyClose();
context.lobbyOpenDiscordUnlink();
expectNoRequest(() => context.lobbySubmit(), 'Enter does not unlink');
context.lobbyConfirm();
assert.equal(lastRequest().action, 'discord_unlink');
context.lobbyClose();

// Answers for a dialog that was closed become toasts.
context.lobbyResult(JSON.stringify({ request: 999, error: 'Late failure' }));
assert.match(toastHtml(), /Late failure/);

// --- Discord ----------------------------------------------------------------------------------
render(worlds, null, { discord: { link: 1, linked: 0, require_create: 1 } });
context.lobbyOpenCreate();
assert.match(modalHtml(), /needs a linked Discord account before you can create a world/, 'the wizard says early that Discord is required');
context.lobbyClose();
context.lobbyOpenDiscordLink();
sent = lastRequest();
context.lobbyResult(JSON.stringify({ request: sent.request, ok: 1, command: '/link code:ABC123', invite: 0 }));
render(worlds, null, { discord: { link: 1, linked: 1, name: 'joschua', require_create: 1 } });
assert.equal(modal(), null, 'the link dialog closes once the account is linked');
assert.match(toastHtml(), /Discord linked as joschua\./);
render(worlds);

// --- Settings of a running world offer the stop ------------------------------------------------
context.lobbyOpenWorld('edit', button({ 'data-id': hex(3) }));
assert.match(modalHtml(), /onclick="return lobbyStopFromSettings\(\)">Save and stop\.\.\.</);
context.lobbyStopFromSettings();
assert.equal(modal().type, 'confirm');
assert.equal(modal().action, 'stop');
context.lobbyClose();

// --- The page shell survives hostile world names -----------------------------------------------
// lobby.dm embeds the first state in an inline <script>renderLobby(...)</script>. Its JSON goes
// through lobby_script_json; this ports that proc's escape table from lobby.dm and checks that a
// world named like markup can neither end the script nor open an HTML comment in it.
{
  const dm = fs.readFileSync(path.join(__dirname, '../../modular_babylon/lobby/lobby.dm'), 'utf8');
  assert.match(dm, /<script>renderLobby\(\[lobby_script_json\(json_encode\(data\)\)\]\);<\/script>/, 'the shell embeds its state via lobby_script_json');
  const table = {};
  for (const m of dm.matchAll(/"(.)" = "\\\\u([0-9a-f]{4})"/g)) table[m[1]] = '\\u' + m[2];
  for (const m of dm.matchAll(/escapes\[ascii2text\((\d+)\)\] = "\\\\u([0-9a-f]{4})"/g)) table[String.fromCharCode(Number(m[1]))] = '\\u' + m[2];
  assert.deepEqual(Object.keys(table).sort(), ['&', '<', '>', '\u2028', '\u2029'].sort(), 'escape table found in lobby.dm');
  const scriptJson = value => {
    let text = JSON.stringify(value);
    for (const [character, escape] of Object.entries(table)) text = text.split(character).join(escape);
    return text;
  };
  // Captured from BYOND 516 (lobby_script_json run in DreamDaemon) for the same data.
  assert.equal(scriptJson({ name: '</script><!--<script>a&b>\u2028x', n: 1 }),
    '{"name":"\\u003c/script\\u003e\\u003c!--\\u003cscript\\u003ea\\u0026b\\u003e\\u2028x","n":1}');
  const hostile = world(hex(7), { name: '</script><!--<script>alert(1)//', description: '</SCRIPT >\u2028\u2029 & more' });
  const data = { html: '<p>shell</p>', view: 'mine', revision: 1000, complete: 1, state: state([hostile]) };
  const shell = '<script>renderLobby(' + scriptJson(JSON.stringify(data)) + ');</script>';
  const body = shell.slice('<script>'.length, shell.length - '</script>'.length);
  assert.equal(body.search(/<\/script/i), -1, 'nothing ends the script early');
  assert.equal(body.indexOf('<'), -1, 'no markup at all inside the script (no <!-- either)');
  vm.runInContext(body, context);
  assert.equal(elements['browser-content'].innerHTML, '<p>shell</p>', 'the shell still renders');
  assert.equal(context.lobbyState.worlds[0].name, hostile.name, 'the name arrives unchanged');
  assert.equal(context.lobbyState.worlds[0].description, hostile.description);
  context.lobbyOpenWorld('delete', button({ 'data-id': hex(7) }));
  assert.match(modalHtml(), /&lt;\/script&gt;&lt;!--&lt;script&gt;alert\(1\)\/\//, 'and is shown escaped');
  context.lobbyClose();
}

// --- Tutorials tab -------------------------------------------------------------------------------
{
  revision = 2000; // after the shell test's revision 1000
  const placeholder = "<div id='lobby-tutorials'></div>";
  const dm = fs.readFileSync(path.join(__dirname, '../../modular_babylon/lobby/lobby.dm'), 'utf8');
  assert.ok(dm.includes('content += "' + placeholder + '"'), 'lobby.dm leaves the placeholder lobby.js fills');
  const tutorial = (id, extra) => Object.assign({
    id, title: 'Tutorial ' + id, description: 'Learn something.', author: 'builder', map: 'icebox', map_name: 'IceBoxStation',
    status: 'published', created: 1794650000, playing: null, editing: null,
  }, extra);
  const published = [
    tutorial('p1'),
    tutorial('p2', { title: '<img src=x onerror=alert(1)>', description: '"quoted" & <b>bold</b>', author: 'evil"author', map: 'creative_plane_m', map_name: 'Creative Plane M', playing: 'running' }),
  ];
  const pending = [tutorial('q2', { status: 'pending', created: 1794660000, based_on: { id: 'p1', title: 'Tutorial p1', author: 'builder' } }), tutorial('q1', { status: 'pending', created: 1794650000, editing: 'running' })];
  const renderTutorials = (list, extra) => context.renderLobby(JSON.stringify({
    html: '<h2>Tutorials</h2>' + placeholder, view: 'tutorials', revision: revision++, complete: true,
    state: state(worlds, null, Object.assign({ tutorials: list }, extra || {})),
  }));
  const page = () => elements['browser-content'].innerHTML;

  // Cards render from the state, every value escaped; a preview image when the map has one.
  renderTutorials(published.concat(pending));
  assert.doesNotMatch(page(), /lobby-tutorials'><\/div>/, 'the placeholder is filled');
  assert.doesNotMatch(page(), /Published tutorials|section-count/, 'players get the list without a second heading');
  assert.equal((page().match(/class="tutorial-card/g) || []).length, 2, 'players see the published cards only');
  assert.doesNotMatch(page(), /Pending tutorials|Tutorial q1|Tutorial q2|Accept/, 'no pending section for players');
  assert.match(page(), /<h3>Tutorial p1<\/h3><div class="tutorial-meta">by <b>builder<\/b>/);
  assert.match(page(), /<span class="badge map">IceBoxStation<\/span>/, 'the map badge');
  assert.match(page(), /<img src="babylon_map_icebox.png"/, 'the map preview image');
  assert.match(page(), /class="map-initials">CP</, 'maps without a preview get the generated placeholder');
  assert.doesNotMatch(page(), /<img src=x|<b>bold<\/b>|evil"author/, 'player text never becomes markup');
  assert.match(page(), /&lt;img src=x onerror=alert\(1\)&gt;/);
  assert.match(page(), /&quot;quoted&quot; &amp; &lt;b&gt;bold&lt;\/b&gt;/);
  assert.match(page(), /data-tutorial="p2" onclick="return lobbyPlayTutorial\(this\)"[^>]*>Rejoin</, 'a running copy is rejoined');
  assert.match(page(), /data-tutorial="p1" onclick="return lobbyPlayTutorial\(this\)"[^>]*>Play</);
  assert.match(page(), /data-tutorial="p1" onclick="return lobbyOpenTutorial\('copy', this\)"[^>]*>Copy to my worlds\.\.\.</);
  assert.doesNotMatch(page(), /lobbyOpenTutorial\('delete'/, 'players cannot delete tutorials');

  // Play: the full-page loading screen and a plain request, like Join.
  let before = navigations.length;
  context.lobbyPlayTutorial(button({ 'data-tutorial': 'p1' }));
  let sent = lastRequest();
  assert.equal(navigations.length, before + 1);
  assert.deepEqual([sent.action, sent.payload, sent.request], ['tutorial_play', { tutorial: 'p1' }, 0]);
  assert.equal(elements['action-loading'].style.display, 'block');
  assert.equal(elements['loading-world'].textContent, 'Tutorial p1');
  expectNoRequest(() => context.lobbyPlayTutorial(button({ 'data-tutorial': 'p2' })), 'no second request while one loads');
  renderTutorials(published);
  expectNoRequest(() => context.lobbyPlayTutorial(button({ 'data-tutorial': 'gone' })), 'an unknown tutorial sends nothing');
  assert.match(toastHtml(), /no longer available/);

  // Copy: a confirmation that explains the saved, creative world and the limits.
  expectNoRequest(() => context.lobbyOpenTutorial('copy', button({ 'data-tutorial': 'p1' })), 'opening the dialog sends nothing');
  assert.match(modalHtml(), /Copy to my worlds\?/);
  assert.match(modalHtml(), /This creates a new world of your own from the tutorial: <b>Creative<\/b>, <b>saved<\/b> and private, on IceBoxStation\. It is a fresh copy, so nothing you build changes the original\./);
  assert.match(modalHtml(), /counts against your world limits/);
  assert.match(modalHtml(), /<b>2 of 4<\/b> saved worlds/);
  expectNoRequest(() => context.lobbySubmit(), 'Enter never confirms');
  context.lobbyTutorialConfirm();
  sent = lastRequest();
  assert.deepEqual([sent.action, sent.payload], ['tutorial_copy', { tutorial: 'p1', confirm: 1 }]);
  assert.ok(sent.request > 0, 'a dialog request');
  context.lobbyResult(JSON.stringify({ request: sent.request, error: 'Your world limit has been reached' }));
  assert.match(modalHtml(), /modal-error">Your world limit has been reached/, 'errors stay in the dialog');
  context.lobbyTutorialConfirm();
  sent = lastRequest();
  context.lobbyResult(JSON.stringify({ request: sent.request, ok: 1, notice: 'Tutorial p1 was copied to My worlds.' }));
  assert.equal(modal(), null);
  assert.match(toastHtml(), /Tutorial p1 was copied to My worlds\./);

  // At the saved-world limit the copy is refused before anything is sent.
  const full = [1, 2, 3, 4].map(n => world(hex(n)));
  context.renderLobby(JSON.stringify({ html: placeholder, view: 'tutorials', revision: revision++, complete: true, state: state(full, null, { tutorials: published }) }));
  context.lobbyOpenTutorial('copy', button({ 'data-tutorial': 'p1' }));
  assert.match(modalHtml(), /class="callout" id="copy-limit">You already have 4 of 4 saved worlds/);
  assert.match(modalHtml(), /id="modal-confirm"[^>]* title="You already have 4 of 4 saved worlds[^"]*" aria-describedby="copy-limit" disabled>Copy to my worlds</);
  assert.match(modalHtml(), /<div class="callout" id="copy-limit">/);
  expectNoRequest(() => context.lobbyTutorialConfirm(), 'a copy over the limit is not sent');
  context.lobbyClose();

  // Admins: the pending section (oldest first, before the published ones), review buttons and Delete.
  renderTutorials(published.concat(pending), { admin: 1 });
  assert.match(page(), /<h2>Pending tutorials<\/h2><span class="section-count">2<\/span><span class="badge">Administrators only<\/span>/);
  assert.match(page(), /<h2>Published tutorials<\/h2><span class="section-count">2<\/span><\/div><div class="tutorial-grid">/, 'admins keep the headings, no second help text');
  assert.match(page(), /Submitted 2026-/);
  assert.match(page(), /Based on <b>Tutorial p1<\/b> by <b>builder<\/b>/, 'a pending copy credits its original');
  assert.match(page(), /<span class="badges"><span class="badge review"[^>]*>Being edited<\/span><\/span>/, 'status badges share one wrapper');
  assert.ok(page().indexOf('Pending tutorials') < page().indexOf('Published tutorials'), 'the review queue comes first');
  assert.ok(page().indexOf('Tutorial q1') < page().indexOf('Tutorial q2'), 'oldest submission first');
  assert.match(page(), /Being edited/, 'an open edit world is shown');
  for (const action of ['edit', 'accept', 'reject']) {
    assert.match(page(), new RegExp('data-tutorial="q2" onclick="return lobbyOpenTutorial\\(\'' + action + '\', this\\)"'), action);
  }
  assert.match(page(), /data-tutorial="p1" onclick="return lobbyOpenTutorial\('delete', this\)"/);
  assert.doesNotMatch(page(), /data-tutorial="q2" onclick="return lobbyOpenTutorial\('copy'/, 'pending tutorials cannot be copied');
  renderTutorials(published, { admin: 1 });
  assert.match(page(), /<h2>Pending tutorials<\/h2><span class="badge">/, 'no count pill on an empty section');
  assert.match(page(), /No tutorials are waiting for review\./);
  assert.ok(page().indexOf('Published tutorials') < page().indexOf('Pending tutorials'), 'an empty queue goes last');
  renderTutorials(published.concat(pending), { admin: 1 });

  const review = [
    ['edit', 'q2', 'Edit this tutorial?', 'Start editing', 'tutorial_edit', { tutorial: 'q2' }, false],
    ['edit', 'q1', 'Join the edit session?', 'Join edit session', 'tutorial_edit', { tutorial: 'q1' }, false],
    ['accept', 'q2', 'Publish this tutorial?', 'Accept and publish', 'tutorial_accept', { tutorial: 'q2', confirm: 1 }, false],
    ['reject', 'q2', 'Reject this tutorial?', 'Reject and delete', 'tutorial_reject', { tutorial: 'q2', confirm: 1 }, true],
    ['delete', 'p1', 'Delete this tutorial?', 'Delete permanently', 'tutorial_delete', { tutorial: 'p1', confirm: 1 }, true],
  ];
  for (const [action, id, title, label, request, payload, danger] of review) {
    context.lobbyOpenTutorial(action, button({ 'data-tutorial': id }));
    assert.match(modalHtml(), new RegExp('<h2 id="modal-title">' + title.replace('?', '\\?') + '</h2>'), title);
    assert.match(modalHtml(), new RegExp('>' + label + '</button>'), label);
    assert.equal(/role="alertdialog"/.test(modalHtml()), danger, title + ' danger style');
    assert.match(modalHtml(), /data-autofocus="1"[^>]*>Cancel</, 'focus starts on Cancel');
    expectNoRequest(() => context.lobbySubmit(), 'Enter never confirms ' + action);
    context.lobbyTutorialConfirm();
    sent = lastRequest();
    assert.deepEqual([sent.action, sent.payload], [request, payload], action);
    context.lobbyResult(JSON.stringify({ request: sent.request, ok: 1 }));
    assert.equal(modal(), null, action + ' closes on success');
  }
  context.lobbyOpenTutorial('edit', button({ 'data-tutorial': 'q2' }));
  assert.match(modalHtml(), /Save back to pending tutorial/, 'the edit dialog says how changes are kept');
  context.lobbyClose();
  context.lobbyOpenTutorial('accept', button({ 'data-tutorial': 'q1' }));
  assert.match(modalHtml(), /An admin is editing this tutorial right now; unsaved changes in that edit world will be lost\./);
  context.lobbyClose();
  context.lobbyOpenTutorial('accept', button({ 'data-tutorial': 'q2' }));
  assert.doesNotMatch(modalHtml(), /An admin is editing/);
  context.lobbyClose();

  // A refusal while the tutorial is reserved (a save back or a snapshot read) stays in the dialog,
  // which can be confirmed again once the reservation is gone.
  const busy = [
    ['accept', 'q2', 'An admin is saving this tutorial back right now. Try again in a moment.'],
    ['reject', 'q2', 'This tutorial is being started or copied right now. Try again in a moment.'],
    ['delete', 'p1', 'This tutorial is being started or copied right now. Try again in a moment.'],
    ['edit', 'q1', 'The last edit session of this tutorial is still ending. Try again in a moment.'],
  ];
  for (const [action, id, refusal] of busy) {
    context.lobbyOpenTutorial(action, button({ 'data-tutorial': id }));
    context.lobbyTutorialConfirm();
    sent = lastRequest();
    assert.match(modalHtml(), /id="modal-confirm"[^>]* disabled><span class="spinner inline"/, action + ' shows it is busy');
    context.lobbyResult(JSON.stringify({ request: sent.request, error: refusal }));
    assert.ok(modal(), action + ' stays open on a refusal');
    assert.equal(modal().busy, false, action + ' can be confirmed again');
    assert.ok(modalHtml().includes('modal-error">' + refusal), action + ' shows the refusal');
    assert.match(modalHtml(), new RegExp('Tutorial ' + id), action + ' keeps its summary');
    before = navigations.length;
    context.lobbyTutorialConfirm();
    assert.equal(navigations.length, before + 1, action + ' is sent again');
    context.lobbyResult(JSON.stringify({ request: lastRequest().request, ok: 1 }));
    assert.equal(modal(), null);
  }

  // A tutorial dropped by a refresh while its dialog is open (another admin reviewed it):
  // nothing is sent and the dialog still says which tutorial it was.
  context.lobbyOpenTutorial('reject', button({ 'data-tutorial': 'q2' }));
  renderTutorials(published.concat([pending[1]]), { admin: 1 });
  expectNoRequest(() => context.lobbyTutorialConfirm(), 'a vanished tutorial is not sent');
  assert.match(modalHtml(), /modal-error">This tutorial is no longer available\./);
  assert.match(modalHtml(), /<b>Tutorial q2<\/b><br><small>by builder · IceBoxStation<\/small>/, 'the summary is kept');
  context.lobbyClose();
  renderTutorials(published.concat(pending), { admin: 1 });

  // The player's own run that is ending or broke is shown on its card (Play is refused until then).
  renderTutorials([tutorial('p1', { playing: 'stopping' }), tutorial('p3', { playing: 'error' })]);
  assert.match(page(), /<span class="badge stopping"[^>]*>Ending<\/span>/);
  assert.match(page(), /<span class="badge error" title="Your run of it ran into a problem\. Stop it under My worlds, then press Play again\.">Problem<\/span>/);
  assert.doesNotMatch(page(), /Rejoin|You are playing/, 'neither is offered as a rejoin');
  renderTutorials(published.concat(pending), { admin: 1 });

  // Empty states and a failed list.
  renderTutorials([]);
  assert.match(page(), /No tutorials have been published yet\. Want to be the first\? Build something in a Creative world on a station map, then submit it from the Creative panel\./);
  renderTutorials([], { tutorials_error: 'The tutorials could not be loaded. Please try again in a moment.' });
  assert.match(page(), /class="notice" role="alert">The tutorials could not be loaded\. Please try again in a moment\./);
  assert.match(page(), /class="empty">Press the Tutorials tab again to retry\./);
  // A failed Play shows its notice at the top: the page comes back scrolled up.
  context.renderLobby(JSON.stringify({ html: placeholder, view: 'tutorials', revision: revision++, complete: true, state: state(worlds, null, { tutorials: published }) }));
  context.lobbyScroll.tutorials = 800;
  context.lobbyPlayTutorial(button({ 'data-tutorial': 'p1' }));
  assert.equal(context.lobbyScroll.tutorials, 0);
  renderTutorials([]);
  // Tutorial runs are stopped with their own confirmation.
  context.renderLobby(JSON.stringify({ html: '<p>runs</p>', view: 'mine', revision: revision++, complete: true,
    state: state([world(hex(8), { kind: 'tutorial', persistent: 0, state: 'running', name: 'Power run' }),
      world(hex(9), { kind: 'tutorial_edit', persistent: 0, state: 'error', name: 'Editing: X' })]) }));
  context.lobbyOpenWorld('stop', button({ 'data-id': hex(8) }));
  assert.match(modalHtml(), /Stop this tutorial\?/);
  assert.match(modalHtml(), /Press Play in Tutorials to start it fresh/);
  context.lobbyConfirm();
  assert.deepEqual([lastRequest().action, lastRequest().payload], ['stop', { world: hex(8), confirm: 1 }]);
  context.lobbyClose();
  context.lobbyOpenWorld('stop', button({ 'data-id': hex(9) }));
  assert.match(modalHtml(), /Changes not saved back to the pending tutorial are lost/);
  context.lobbyClose();
  const lobbyDm = fs.readFileSync(path.join(__dirname, '../../modular_babylon/lobby/lobby.dm'), 'utf8');
  assert.match(lobbyDm, />Stop tutorial\.\.\.</, 'tutorial runs get a Stop button in the world list');
  // The notices that send a player back name the button that does it (lobby_retry_notice, DM):
  // Join on a world card, Rejoin or Play on a tutorial card, Edit on a pending tutorial.
  const retry = lobbyDm.match(/^\/proc\/lobby_retry_notice\([\s\S]*?(?=^\S)/m);
  assert.ok(retry, 'lobby.dm words the retry notices in one place');
  assert.match(retry[0], /"join" = "press Join"/);
  assert.match(retry[0], /"play" = "open Tutorials and press Rejoin \(or Play, if it has ended\)"/);
  assert.match(retry[0], /"edit" = "open Tutorials and press Edit on the pending tutorial"/);
  assert.match(retry[0], /The world took too long to let you in\. \[sentence\] to try again\./, 'the admission timeout is worded per button');
  assert.match(lobbyDm, /join_world\(world_id, world_name, list\("world" = world_id\), 0, stage, action == "tutorial_edit" \? "edit" : "play"\)/,
    'Edit and Play pass their own retry wording');
  assert.match(lobbyDm, /last_retry = retry\n\t+src << link\(result\["address"\]\)/, 'the lobby remembers how the player was sent');
  assert.match(lobbyDm, /mob:set_notice\(lobby_retry_notice\(world_notice, mob:last_retry\), TRUE\)/, 'a bounced player gets the matching wording');
  assert.doesNotMatch(lobbyDm, /Press Join to try again|press Play again/, 'no fixed Join or Play wording is left');
  // Problems in the page notice are alerts, like the page's other errors; confirmations stay status.
  assert.match(lobbyDm, /<p class='notice' role='\[notice_alert \? "alert" : "status"\]'>/);
  assert.match(lobbyDm, /set_notice\(data\["error"\] \|\| data\["notice"\], !!data\["error"\]\)/, 'a refused Play is an alert');
  assert.equal((lobbyDm.match(/(?<!var\/)\bnotice = /g) || []).length, 1, 'the notice is only set through set_notice (which also sets its role)');
  assert.doesNotMatch(lobbyDm, /<p class='notice'>/, 'every notice has a role');
  // Other tabs have no placeholder and are left alone.
  render(worlds);
  assert.equal(page(), '<p>list ' + (revision - 1) + '</p>');
}

// Losing the connection removes every dialog.
context.lobbyOpenCreate();
context.lobbyHideOverlays();
assert.equal(modalHtml(), '');
console.log('Lobby dialog, wizard payload, confirmation, escape, limit, poll-preservation and tutorial checks passed.');
