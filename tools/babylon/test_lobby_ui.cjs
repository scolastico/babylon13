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
render(worlds);

// --- Create wizard: map picker -------------------------------------------------------------
assert.equal(context.lobbyOpenCreate(), false, 'opening a dialog does not follow a link');
assert.equal(navigations.length, 0, 'opening the wizard sends nothing');
assert.match(modalHtml(), /role="dialog" aria-modal="true"/);
assert.match(modalHtml(), /Choose a map/);
assert.match(body.className, /modal-open/);
assert.equal((modalHtml().match(/data-card="group:creative_plane"/g) || []).length, 1, 'Creative Plane is a single card');
for (const size of ['S', 'M', 'L']) assert.match(modalHtml(), new RegExp('data-map="creative_plane_' + size.toLowerCase() + '"[^>]*>' + size + '<'));
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
assert.match(modalHtml(), /class="size selected"[^>]*aria-checked="true" data-map="creative_plane_l"/);
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

// Supervisor errors are shown inline; the dialog stays open with the values.
context.lobbyResult(JSON.stringify({ request: 1, error: 'Your total world limit has been reached' }));
assert.equal(modal().type, 'create');
assert.equal(modal().busy, false);
assert.match(modalHtml(), /class="modal-error" role="alert">Your total world limit has been reached/);
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

context.lobbyOpenWorld('members', button({ 'data-id': hex(1) }));
context.lobbyField('member', 'Some Friend');
context.lobbyField('role', 'remove', true);
context.lobbySubmit();
sent = lastRequest();
assert.deepEqual(sent.payload, { world: hex(1), member: 'Some Friend', role: 'remove' });
context.lobbyClose();

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

// Losing the connection removes every dialog.
context.lobbyOpenCreate();
context.lobbyHideOverlays();
assert.equal(modalHtml(), '');
console.log('Lobby dialog, wizard payload, confirmation, escape, limit and poll-preservation checks passed.');
