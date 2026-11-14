// Lobby dialogs: every prompt, choice and confirmation of the lobby is an in-page modal
// instead of a BYOND system dialog. Requests go to lobby.dm as
// byond://?src=<ref>;action=<name>;payload=<urlencoded JSON>;request=<n>; lobby.dm checks
// every field again and the supervisor checks them once more. The checks here only make
// the form helpful. Answers come back through lobbyResult().
// Plain ES5 like loading.js, for BYOND's embedded browser.

var lobbyState = { ref: '', ckey: '', admin: 0, worlds: [], maps: [], limits: {}, player_limit: 1 };
var lobbyModal = null;
var lobbyRequestCounter = 0;
var lobbyToasts = [];
var lobbyToastCounter = 0;
var lobbyReturnFocus = null;

var LOBBY_VISIBILITY = [
  { id: 'private', label: 'Private', help: 'Only you, your members and server admins can join.' },
  { id: 'showcase', label: 'Showcase', help: 'Members build. Guests visit as visible ghosts who can look around and chat.' },
  { id: 'password', label: 'Password', help: 'Guests who know the password can join and play.' },
  { id: 'public', label: 'Public', help: 'Anyone can join and play.' }
];
var LOBBY_GROUPS = {
  babylon: { label: 'Babylon', help: 'Rebuild a station from scratch as a construction drone.' },
  creative_plane: { label: 'Creative Plane', help: 'An empty, flat plane to build anything on. Pick a size.' },
  station: { label: 'Stations', help: 'A regular station round on a classic map. The round starts when you press Start round.' }
};
var LOBBY_CREATIVE_HELP = 'Everyone in this world gets the Creative panel: spawn items, fly, godmode and more. Only inside this world.';
var LOBBY_PERSISTENT_HELP = 'Saves automatically. Turn off for throwaway rounds; an unsaved world does not count against your saved-world limit.';
var LOBBY_GRADIENTS = [
  ['#1f6f68', '#173a52'], ['#2d4f8a', '#1b2a44'], ['#5a3f8c', '#232a4a'],
  ['#7a5a22', '#2b2a33'], ['#1f5f7a', '#122536'], ['#6b3448', '#26223a']
];

// --- Small helpers ------------------------------------------------------------------------

function lobbyEsc(value) {
  return String(value === null || value === undefined ? '' : value)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function lobbyFind(list, key, value) {
  list = list || [];
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i][key] === value) return list[i];
  }
  return null;
}

function lobbyWorld(id) { return lobbyFind(lobbyState.worlds, 'id', id); }
function lobbyMap(id) { return lobbyFind(lobbyState.maps, 'id', id); }
function lobbyTrim(value) { return String(value === null || value === undefined ? '' : value).replace(/^\s+|\s+$/g, ''); }

function lobbyEl(id) { return document.getElementById(id); }

function lobbyUpdateState(state) {
  if (state && typeof state === 'object') lobbyState = state;
}

/// Navigates to a lobby.dm action. The payload is JSON in one urlencoded parameter.
function lobbySend(action, payload, request) {
  var url = 'byond://?src=' + lobbyState.ref + ';action=' + encodeURIComponent(action) +
    ';payload=' + encodeURIComponent(JSON.stringify(payload || {}));
  if (request) url += ';request=' + request;
  lobbyNavigate(url);
}

function lobbyNavigate(url) { window.location.href = url; }

/// Counts toward the per-owner limits: worlds this player owns (tutorial runs excluded).
function lobbyLimitInfo() {
  var limits = lobbyState.limits || {};
  var saved = 0;
  var total = 0;
  var worlds = lobbyState.worlds || [];
  for (var i = 0; i < worlds.length; i++) {
    var world = worlds[i];
    if (world.owner !== lobbyState.ckey || (world.kind && world.kind !== 'world')) continue;
    total++;
    if (world.persistent !== 0 && world.persistent !== false) saved++;
  }
  var maxSaved = limits.max_worlds_per_player || 0;
  var maxTotal = limits.max_total_worlds_per_player || 0;
  var exempt = !!lobbyState.admin;
  return {
    saved: saved, total: total, maxSaved: maxSaved, maxTotal: maxTotal, exempt: exempt,
    savedFull: !exempt && maxSaved > 0 && saved >= maxSaved,
    totalFull: !exempt && maxTotal > 0 && total >= maxTotal
  };
}

function lobbyLimitsHtml(info) {
  if (info.exempt) {
    return '<div class="limits"><span>Server administrator: the per-owner world limits do not apply to you.</span></div>';
  }
  return '<div class="limits" aria-label="Your world limits">' +
    '<span class="' + (info.savedFull ? 'full' : '') + '"><b>' + info.saved + ' of ' + info.maxSaved + '</b> saved worlds</span>' +
    '<span class="' + (info.totalFull ? 'full' : '') + '"><b>' + info.total + ' of ' + info.maxTotal + '</b> worlds in total</span></div>';
}

// --- Map catalog --------------------------------------------------------------------------

/// Groups of map cards in catalog order. Maps with a size (Creative Plane) share one card.
function lobbyMapGroups() {
  var groups = [];
  var byGroup = {};
  var sized = {};
  var maps = lobbyState.maps || [];
  for (var i = 0; i < maps.length; i++) {
    var map = maps[i];
    var group = byGroup[map.group];
    if (!group) {
      var known = LOBBY_GROUPS[map.group];
      group = byGroup[map.group] = { id: map.group, label: known ? known.label : map.group, help: known ? known.help : '', cards: [] };
      groups.push(group);
    }
    if (map.size) {
      var card = sized[map.group];
      if (!card) {
        card = sized[map.group] = { key: 'group:' + map.group, name: group.label, maps: [], multiz: false, group: map.group };
        group.cards.push(card);
      }
      card.maps.push(map);
      if (map.multiz) card.multiz = true;
    } else {
      group.cards.push({ key: map.id, name: map.name, maps: [map], multiz: !!map.multiz, group: map.group });
    }
  }
  return groups;
}

function lobbyMapCard(key) {
  var groups = lobbyMapGroups();
  for (var i = 0; i < groups.length; i++) {
    var card = lobbyFind(groups[i].cards, 'key', key);
    if (card) return card;
  }
  return null;
}

function lobbyCardForMap(mapId) {
  var groups = lobbyMapGroups();
  for (var i = 0; i < groups.length; i++) {
    for (var j = 0; j < groups[i].cards.length; j++) {
      if (lobbyFind(groups[i].cards[j].maps, 'id', mapId)) return groups[i].cards[j];
    }
  }
  return null;
}

function lobbyInitials(name) {
  var words = String(name || '?').replace(/([a-z])([A-Z])/g, '$1 $2').split(/[^A-Za-z0-9]+/);
  var letters = '';
  for (var i = 0; i < words.length && letters.length < 2; i++) {
    if (words[i]) letters += words[i].charAt(0).toUpperCase();
  }
  if (letters.length < 2 && words[0]) letters = words[0].substr(0, 2).charAt(0).toUpperCase() + words[0].substr(1, 1).toLowerCase();
  return letters || '?';
}

/// A preview image, or a generated gradient with the map's initials when there is none.
function lobbyPreviewHtml(card) {
  var map = card.maps[0];
  if (map && map.preview_url) {
    return '<span class="map-preview"><img src="' + lobbyEsc(map.preview_url) + '" alt=""><span class="map-check" aria-hidden="true">&#10003;</span></span>';
  }
  var hash = 0;
  for (var i = 0; i < card.key.length; i++) hash = (hash * 31 + card.key.charCodeAt(i)) % 100003;
  var colors = LOBBY_GRADIENTS[hash % LOBBY_GRADIENTS.length];
  var art = card.group === 'creative_plane' ? ' grid' : (card.group === 'babylon' ? ' rings' : '');
  var initials = card.group === 'babylon' ? 'B13' : lobbyInitials(card.name);
  return '<span class="map-preview" aria-hidden="true"><span class="map-art' + art + '" style="background:linear-gradient(135deg,' +
    colors[0] + ',' + colors[1] + ')"></span><span class="map-initials">' + lobbyEsc(initials) +
    '</span><span class="map-check">&#10003;</span></span>';
}

function lobbyMultizBadge(card) {
  return card.multiz ? '<span class="badge multiz">Multi-level</span>' : '';
}

// --- Toasts -------------------------------------------------------------------------------

function lobbyToast(text, kind) {
  var id = ++lobbyToastCounter;
  lobbyToasts.push({ id: id, text: String(text), kind: kind || 'info' });
  while (lobbyToasts.length > 3) lobbyToasts.shift();
  lobbyRenderToasts();
  setTimeout(function () { lobbyDismissToast(id); }, kind === 'error' ? 12000 : 7000);
}

function lobbyDismissToast(id) {
  for (var i = 0; i < lobbyToasts.length; i++) {
    if (lobbyToasts[i].id === id) {
      lobbyToasts.splice(i, 1);
      lobbyRenderToasts();
      return;
    }
  }
}

function lobbyRenderToasts() {
  var root = lobbyEl('toast-root');
  if (!root) return;
  var html = '';
  for (var i = 0; i < lobbyToasts.length; i++) {
    var toast = lobbyToasts[i];
    html += '<div class="toast ' + (toast.kind === 'error' ? 'error' : '') + '" role="' + (toast.kind === 'error' ? 'alert' : 'status') + '">' +
      '<span>' + lobbyEsc(toast.text) + '</span><button type="button" class="toast-close" aria-label="Dismiss" onclick="lobbyDismissToast(' +
      toast.id + ')">&times;</button></div>';
  }
  root.innerHTML = html;
}

// --- Modal lifecycle ----------------------------------------------------------------------

function lobbyOpenModal(modal) {
  if (typeof lobbyPending !== 'undefined' && (lobbyPending || lobbyLost)) return false;
  var active = document.activeElement;
  if (!lobbyModal) lobbyReturnFocus = active && active !== document.body ? active : null;
  modal.fields = modal.fields || {};
  modal.error = '';
  modal.busy = false;
  lobbyModal = modal;
  lobbyRenderModal();
  return false;
}

function lobbyClose() {
  if (!lobbyModal) return false;
  lobbyModal = null;
  lobbyRenderModal();
  var target = lobbyReturnFocus;
  lobbyReturnFocus = null;
  try {
    if (target && target.focus && document.body && document.body.contains && document.body.contains(target)) target.focus();
  } catch (e) { /* the button may be gone after a refresh */ }
  return false;
}

/// Hides every overlay at once (the connection is lost or a full-page loading screen took over).
function lobbyHideOverlays() {
  lobbyModal = null;
  lobbyRenderModal();
}

function lobbyBodyClass(open) {
  var body = document.body;
  if (!body) return;
  var name = (body.className || '').replace(/\s*\bmodal-open\b/g, '');
  body.className = open ? lobbyTrim(name + ' modal-open') : lobbyTrim(name);
}

var LOBBY_FOCUSABLE = 'button:not([disabled]), input:not([disabled]):not([type=hidden]), textarea:not([disabled]), a[href], [tabindex="0"]';

function lobbyFocusables(root) {
  if (!root || !root.querySelectorAll) return [];
  var found = root.querySelectorAll(LOBBY_FOCUSABLE);
  var list = [];
  for (var i = 0; i < found.length; i++) {
    // Radio groups: only the checked radio (or the first) is a tab stop.
    if (found[i].type === 'radio' && !found[i].checked) continue;
    list.push(found[i]);
  }
  return list;
}

/// Renders the open modal. Polling never calls this, so typing is never interrupted; it runs
/// only when the modal itself changes (step, toggle, busy, error). Values live in modal.fields.
function lobbyRenderModal() {
  var root = lobbyEl('modal-root');
  if (!root) return;
  var modal = lobbyModal;
  if (!modal) {
    root.innerHTML = '';
    lobbyBodyClass(false);
    return;
  }
  var active = document.activeElement;
  var sameView = modal.renderedView === lobbyModalView(modal);
  var focusId = sameView && active && active.id ? active.id : '';
  root.innerHTML = lobbyModalHtml(modal);
  modal.renderedView = lobbyModalView(modal);
  lobbyBodyClass(true);
  var target = focusId ? lobbyEl(focusId) : null;
  if (!target || target.disabled) {
    target = root.querySelector ? root.querySelector('[data-autofocus]') : null;
    if (!target || target.disabled) target = lobbyFocusables(root)[0];
  }
  if (target && target.focus) {
    try { target.focus(); } catch (e) { /* not focusable in this browser */ }
  }
}

function lobbyModalView(modal) { return modal.type + ':' + (modal.step || '') + ':' + (modal.loading ? 1 : 0); }

function lobbyKeydown(event) {
  event = event || window.event;
  if (!lobbyModal || !event) return true;
  var key = event.keyCode || event.which;
  if (key === 27) {
    lobbyClose();
    lobbyPrevent(event);
    return false;
  }
  if (key === 9) {
    var items = lobbyFocusables(lobbyEl('modal-root'));
    if (!items.length) {
      lobbyPrevent(event);
      return false;
    }
    var first = items[0];
    var last = items[items.length - 1];
    var active = document.activeElement;
    var inside = false;
    for (var i = 0; i < items.length; i++) if (items[i] === active) inside = true;
    if (event.shiftKey && (active === first || !inside)) {
      last.focus();
      lobbyPrevent(event);
      return false;
    }
    if (!event.shiftKey && (active === last || !inside)) {
      first.focus();
      lobbyPrevent(event);
      return false;
    }
  }
  return true;
}

function lobbyPrevent(event) {
  if (event.preventDefault) event.preventDefault();
  event.returnValue = false;
}

/// A click on the dimmed backdrop (not inside the dialog) cancels.
function lobbyBackdrop(event) {
  event = event || window.event;
  var target = event && (event.target || event.srcElement);
  if (target && target.id === 'modal-backdrop') lobbyClose();
}

if (document.addEventListener) document.addEventListener('keydown', lobbyKeydown, false);
else if (document.attachEvent) document.attachEvent('onkeydown', lobbyKeydown);

// --- Requests and answers -----------------------------------------------------------------

/// Sends the modal's request; the modal stays open (busy) until lobby.dm answers.
function lobbyRequest(action, payload, busyLabel) {
  var modal = lobbyModal;
  if (!modal || modal.busy) return false;
  modal.busy = true;
  modal.error = '';
  modal.busyLabel = busyLabel || 'Working...';
  modal.request = ++lobbyRequestCounter;
  lobbyRenderModal();
  lobbySend(action, payload, modal.request);
  return false;
}

/// lobby.dm's answer to a request: an error stays in the open modal, success closes it.
function lobbyResult(encoded) {
  var data;
  try { data = JSON.parse(encoded); } catch (e) { return; }
  var modal = lobbyModal;
  var mine = !!(modal && data && modal.request === data.request);
  if (!mine) {
    if (data && data.error) lobbyToast(data.error, 'error');
    else if (data && data.notice) lobbyToast(data.notice);
    return;
  }
  modal.busy = false;
  if (data.error) {
    modal.error = String(data.error);
    modal.loading = false;
    lobbyRenderModal();
    return;
  }
  if (modal.type === 'checkpoints' && modal.loading) {
    modal.loading = false;
    modal.checkpoints = data.checkpoints || [];
    modal.latest = data.latest || null;
    lobbyRenderModal();
    return;
  }
  if (modal.type === 'discord' && modal.loading) {
    modal.loading = false;
    modal.command = String(data.command || '');
    modal.invite = !!data.invite;
    lobbyRenderModal();
    return;
  }
  lobbyClose();
  if (data.notice) lobbyToast(data.notice);
}

// --- Openers (called from buttons rendered by lobby.dm) -------------------------------------

function lobbyOpenCreate() {
  var info = lobbyLimitInfo();
  return lobbyOpenModal({
    type: 'create', step: 'map',
    fields: {
      card: '', map: '', name: '', description: '', visibility: 'private', password: '',
      max_players: String(lobbyState.player_limit || 1), creative: 0, persistent: info.savedFull ? 0 : 1
    }
  });
}

function lobbyOpenWorld(type, button) {
  var id = button && button.getAttribute ? button.getAttribute('data-id') : button;
  var world = lobbyWorld(id);
  if (!world) {
    lobbyToast('This world is no longer available.', 'error');
    return false;
  }
  if (type === 'edit') {
    return lobbyOpenModal({
      type: 'edit', world: world.id,
      fields: {
        name: world.name || '', description: world.description || '', visibility: world.visibility || 'private',
        password: '', max_players: String(world.max_players || 1),
        creative: world.creative ? 1 : 0, persistent: world.persistent === 0 ? 0 : 1
      }
    });
  }
  if (type === 'members') return lobbyOpenModal({ type: 'members', world: world.id, fields: { member: '', role: 'member' } });
  if (type === 'checkpoints') {
    lobbyOpenModal({ type: 'checkpoints', world: world.id, step: 'pick', loading: true, fields: { generation: '' } });
    return lobbyRequest('checkpoints', { world: world.id }, 'Loading checkpoints...');
  }
  if (type === 'stop' || type === 'delete' || type === 'reset') {
    return lobbyOpenModal({ type: 'confirm', action: type, world: world.id, fields: { confirm_name: '' } });
  }
  return false;
}

/// Join links: a guest of a password world is asked for the password first; every other
/// join follows the link with the loading screen, as before.
function lobbyJoin(link) {
  if (link.getAttribute('data-password') === '1') {
    var world = lobbyWorld(link.getAttribute('data-id'));
    if (!world) return false;
    lobbyOpenModal({ type: 'join', world: world.id, spectate: link.getAttribute('data-spectate') === '1', fields: { password: '' } });
    return false;
  }
  return beginAction(link);
}

function lobbyOpenDiscordLink() {
  lobbyOpenModal({ type: 'discord', loading: true });
  return lobbyRequest('discord_link', {}, 'Creating a link code...');
}

function lobbyOpenDiscordUnlink() {
  return lobbyOpenModal({ type: 'confirm', action: 'discord_unlink', fields: {} });
}

// --- Field and choice handlers ------------------------------------------------------------

function lobbyField(name, value, rerender) {
  var modal = lobbyModal;
  if (!modal) return;
  modal.fields[name] = value;
  if (name === 'creative') modal.creativeTouched = true;
  if (name === 'name') modal.nameTouched = true;
  if (rerender) lobbyRenderModal();
}

function lobbyChooseMap(card, mapId) {
  var modal = lobbyModal;
  if (!modal || modal.type !== 'create' || !card) return;
  modal.fields.card = card.key;
  modal.fields.map = mapId || card.maps[0].id;
  if (!modal.creativeTouched) modal.fields.creative = card.group === 'creative_plane' ? 1 : 0;
  if (!modal.nameTouched) modal.fields.name = 'My ' + card.name;
  modal.error = '';
  lobbyRenderModal();
}

function lobbyPickMap(button) {
  var card = lobbyMapCard(button.getAttribute('data-card'));
  if (!card) return false;
  var modal = lobbyModal;
  var current = modal && lobbyFind(card.maps, 'id', modal.fields.map);
  var preferred = lobbyFind(card.maps, 'size', 'M');
  lobbyChooseMap(card, current ? current.id : (preferred ? preferred.id : card.maps[0].id));
  return false;
}

function lobbyPickSize(button) {
  var mapId = button.getAttribute('data-map');
  lobbyChooseMap(lobbyCardForMap(mapId), mapId);
  return false;
}

function lobbyWizardStep(step) {
  var modal = lobbyModal;
  if (!modal || modal.type !== 'create' || modal.busy) return false;
  if (step === 'details' && !lobbyMap(modal.fields.map)) {
    modal.error = 'Choose a map first.';
    lobbyRenderModal();
    return false;
  }
  modal.error = '';
  modal.step = step;
  lobbyRenderModal();
  return false;
}

/// The typed world name unlocks a danger button without re-rendering the modal.
function lobbyConfirmName(value) {
  var modal = lobbyModal;
  if (!modal) return;
  modal.fields.confirm_name = value;
  var button = lobbyEl('modal-confirm');
  var world = lobbyWorld(modal.world);
  if (button) button.disabled = !world || lobbyTrim(value) !== lobbyTrim(world.name);
}

function lobbyCopyCommand() {
  var input = lobbyEl('discord-command');
  var status = lobbyEl('copy-status');
  var copied = false;
  if (input) {
    try {
      input.focus();
      input.select();
      copied = document.execCommand('copy');
    } catch (e) { copied = false; }
  }
  if (status) status.textContent = copied ? 'Copied to your clipboard.' : 'Selected: press Ctrl+C to copy it.';
  return false;
}

function lobbyOpenDiscord() {
  lobbySend('discord_invite', {});
  return false;
}

// --- Form checks and submits --------------------------------------------------------------

/// The settings shared by create and edit, checked like lobby.dm checks them.
/// Returns an error text, or fills payload.
function lobbySettingsPayload(fields, payload, creating, world) {
  var name = lobbyTrim(fields.name);
  if (!name || name.length > 60) return 'Give the world a name of 1 to 60 characters.';
  var description = lobbyTrim(fields.description);
  if (description.length > 500) return 'Keep the description under 500 characters.';
  var visibility = fields.visibility;
  if (!lobbyFind(LOBBY_VISIBILITY, 'id', visibility)) return 'Choose who can join.';
  var maximum = Number(fields.max_players);
  var limit = lobbyState.player_limit || 1;
  if (!(maximum >= 1 && maximum <= limit && Math.floor(maximum) === maximum)) {
    return 'Choose between 1 and ' + limit + ' players.';
  }
  payload.name = name;
  payload.description = description;
  payload.visibility = visibility;
  payload.max_players = maximum;
  payload.creative = fields.creative ? 1 : 0;
  payload.persistent = fields.persistent ? 1 : 0;
  if (visibility === 'password') {
    var password = String(fields.password || '');
    if (password.length > 128) return 'Use a password of at most 128 characters.';
    if (password) payload.password = password;
    else if (creating || !world || world.visibility !== 'password') return 'Choose a password for your guests.';
  }
  return '';
}

function lobbyCreate(join) {
  var modal = lobbyModal;
  if (!modal || modal.type !== 'create' || modal.busy) return false;
  if (modal.step !== 'details') return lobbyWizardStep('details');
  var info = lobbyLimitInfo();
  var payload = { map: modal.fields.map };
  var error = '';
  if (!lobbyMap(modal.fields.map)) error = 'Choose a map first.';
  else if (info.totalFull) error = 'You have reached your limit of ' + info.maxTotal + ' worlds. Delete one to create another.';
  else if (modal.fields.persistent && info.savedFull) error = 'You have reached your limit of ' + info.maxSaved + ' saved worlds. Turn Persistent off, or delete a saved world.';
  else error = lobbySettingsPayload(modal.fields, payload, true, null);
  if (error) {
    modal.error = error;
    lobbyRenderModal();
    return false;
  }
  if (join) payload.join = 1;
  return lobbyRequest('create', payload, join ? 'Creating and starting...' : 'Creating...');
}

/// Enter in a form field (or its submit button) lands here.
function lobbySubmit() {
  var modal = lobbyModal;
  if (!modal || modal.busy) return false;
  if (modal.type === 'create') return modal.step === 'map' ? lobbyWizardStep('details') : lobbyCreate(1);
  if (modal.type === 'edit') {
    var world = lobbyWorld(modal.world);
    if (!world || world.state !== 'stopped') return false;
    var payload = { world: modal.world };
    var error = lobbySettingsPayload(modal.fields, payload, false, world);
    var info = lobbyLimitInfo();
    if (!error && payload.persistent && world.persistent === 0 && info.savedFull) {
      error = 'You have reached your limit of ' + info.maxSaved + ' saved worlds, so this world cannot be made persistent.';
    }
    if (error) {
      modal.error = error;
      lobbyRenderModal();
      return false;
    }
    return lobbyRequest('edit', payload, 'Saving...');
  }
  if (modal.type === 'join') {
    var joinPayload = { world: modal.world, password: String(modal.fields.password || '') };
    if (!joinPayload.password) {
      modal.error = 'Enter the world password.';
      lobbyRenderModal();
      return false;
    }
    if (modal.spectate) joinPayload.spectate = 1;
    return lobbyRequest('join', joinPayload, 'Joining...');
  }
  if (modal.type === 'members') {
    var member = lobbyTrim(modal.fields.member);
    if (!member || member.length > 64) {
      modal.error = 'Enter a BYOND account name.';
      lobbyRenderModal();
      return false;
    }
    var role = modal.fields.role === 'remove' ? 'remove' : 'member';
    return lobbyRequest('member', { world: modal.world, member: member, role: role }, role === 'remove' ? 'Removing...' : 'Adding...');
  }
  // Confirmations and the checkpoint picker never submit on Enter: they need an explicit click.
  return false;
}

/// The danger/confirm button of a confirmation. Only a click (or Space/Enter on the
/// focused button itself) gets here.
function lobbyConfirm() {
  var modal = lobbyModal;
  if (!modal || modal.busy) return false;
  if (modal.type === 'checkpoints') {
    if (modal.step !== 'confirm' || !modal.fields.generation) return false;
    return lobbyRequest('rollback', {
      world: modal.world, generation: modal.fields.generation, expected_latest: modal.latest, confirm: 1
    }, 'Restoring...');
  }
  if (modal.type !== 'confirm') return false;
  if (modal.action === 'discord_unlink') return lobbyRequest('discord_unlink', { confirm: 1 }, 'Unlinking...');
  var world = lobbyWorld(modal.world);
  if (!world) return false;
  if (modal.action === 'stop') return lobbyRequest('stop', { world: world.id, confirm: 1 }, 'Stopping...');
  if (lobbyTrim(modal.fields.confirm_name) !== lobbyTrim(world.name)) return false;
  var payload = { world: world.id, confirm: 1, confirm_name: lobbyTrim(modal.fields.confirm_name) };
  if (modal.action === 'delete') return lobbyRequest('delete', payload, 'Deleting...');
  if (modal.action === 'reset') return lobbyRequest('reset', payload, 'Resetting...');
  return false;
}

function lobbyCheckpointStep(step) {
  var modal = lobbyModal;
  if (!modal || modal.type !== 'checkpoints' || modal.busy) return false;
  if (step === 'confirm' && !modal.fields.generation) return false;
  modal.step = step;
  modal.error = '';
  lobbyRenderModal();
  return false;
}

// --- Rendering ----------------------------------------------------------------------------

function lobbyButtons(modal, buttons) {
  var html = '';
  for (var i = 0; i < buttons.length; i++) {
    var b = buttons[i];
    if (b.spacer) {
      html += '<span class="spacer"></span>';
      continue;
    }
    var disabled = b.disabled || (modal.busy && !b.cancel);
    var label = modal.busy && b.busy ? '<span class="spinner inline" aria-hidden="true"></span>' + lobbyEsc(modal.busyLabel) : lobbyEsc(b.label);
    html += '<button type="' + (b.submit ? 'submit' : 'button') + '" class="button ' + (b.kind || '') + '"' +
      (b.id ? ' id="' + b.id + '"' : '') + (b.onclick ? ' onclick="' + b.onclick + '"' : '') +
      (b.autofocus ? ' data-autofocus="1"' : '') + (disabled ? ' disabled' : '') + '>' + label + '</button>';
  }
  return html;
}

function lobbyDialog(modal, options) {
  var head = '<header class="modal-head"><div>' + (options.step ? '<div class="step">' + lobbyEsc(options.step) + '</div>' : '') +
    '<h2 id="modal-title">' + lobbyEsc(options.title) + '</h2>' +
    (options.subtitle ? '<p id="modal-subtitle">' + lobbyEsc(options.subtitle) + '</p>' : '') +
    '</div><button type="button" class="modal-close" aria-label="Close" onclick="return lobbyClose()">&times;</button></header>';
  var error = modal.error ? '<div class="modal-error" role="alert">' + lobbyEsc(modal.error) + '</div>' : '';
  var inner = error + '<div class="modal-body">' + options.body + '</div><footer class="modal-foot">' + options.footer + '</footer>';
  if (options.form) inner = '<form onsubmit="return lobbySubmit()" novalidate autocomplete="off">' + inner + '</form>';
  return '<div class="modal-backdrop" id="modal-backdrop" onmousedown="lobbyBackdrop(event)">' +
    '<div class="modal' + (options.wide ? ' wide' : '') + (options.danger ? ' danger' : '') + '" role="' +
    (options.danger ? 'alertdialog' : 'dialog') + '" aria-modal="true" aria-labelledby="modal-title"' +
    (options.subtitle ? ' aria-describedby="modal-subtitle"' : '') + '>' + head + inner + '</div></div>';
}

function lobbyModalHtml(modal) {
  if (modal.type === 'create') return modal.step === 'map' ? lobbyCreateMapHtml(modal) : lobbyCreateDetailsHtml(modal);
  if (modal.type === 'edit') return lobbyEditHtml(modal);
  if (modal.type === 'join') return lobbyJoinHtml(modal);
  if (modal.type === 'members') return lobbyMembersHtml(modal);
  if (modal.type === 'checkpoints') return lobbyCheckpointsHtml(modal);
  if (modal.type === 'discord') return lobbyDiscordHtml(modal);
  if (modal.type === 'confirm') return lobbyConfirmHtml(modal);
  return '';
}

function lobbyCreateMapHtml(modal) {
  var groups = lobbyMapGroups();
  var info = lobbyLimitInfo();
  var body = lobbyLimitsHtml(info);
  if (info.totalFull) {
    body += '<div class="callout">You have reached your limit of ' + info.maxTotal + ' worlds. Delete a world you no longer need to create a new one.</div>';
  }
  var first = true;
  for (var g = 0; g < groups.length; g++) {
    var group = groups[g];
    body += '<section class="map-group" aria-label="' + lobbyEsc(group.label) + '"><h3>' + lobbyEsc(group.label) + '</h3>' +
      (group.help ? '<p>' + lobbyEsc(group.help) + '</p>' : '') + '<div class="map-grid">';
    for (var c = 0; c < group.cards.length; c++) {
      var card = group.cards[c];
      var selected = modal.fields.card === card.key;
      var shown = selected ? lobbyFind(card.maps, 'id', modal.fields.map) || card.maps[0] : card.maps[0];
      var description = card.maps.length > 1 && !selected ? (LOBBY_GROUPS[card.group] ? LOBBY_GROUPS[card.group].help : shown.description) : shown.description;
      var autofocus = selected || (!modal.fields.card && first);
      first = false;
      body += '<div class="map-card' + (selected ? ' selected' : '') + '">' +
        '<button type="button" class="map-pick" id="map-' + lobbyEsc(card.key.replace(/[^a-z0-9_]/g, '-')) + '" data-card="' + lobbyEsc(card.key) +
        '" aria-pressed="' + (selected ? 'true' : 'false') + '"' + (autofocus ? ' data-autofocus="1"' : '') +
        ' onclick="return lobbyPickMap(this)" ondblclick="lobbyPickMap(this); return lobbyWizardStep(\'details\')">' +
        lobbyPreviewHtml(card) + '<span class="map-body"><span class="map-name">' + lobbyEsc(card.name) + lobbyMultizBadge(card) + '</span>' +
        '<span class="map-desc">' + lobbyEsc(description) + '</span></span></button>';
      if (card.maps.length > 1) {
        body += '<div class="sizes" role="radiogroup" aria-label="' + lobbyEsc(card.name) + ' size">';
        for (var s = 0; s < card.maps.length; s++) {
          var sized = card.maps[s];
          var on = selected && sized.id === modal.fields.map;
          body += '<button type="button" class="size' + (on ? ' selected' : '') + '" id="size-' + lobbyEsc(sized.id) + '" role="radio" aria-checked="' +
            (on ? 'true' : 'false') + '" data-map="' + lobbyEsc(sized.id) + '" title="' + lobbyEsc(sized.description) +
            '" onclick="return lobbyPickSize(this)">' + lobbyEsc(sized.size) + '</button>';
        }
        body += '</div>';
      }
      body += '</div>';
    }
    body += '</div></section>';
  }
  if (!groups.length) body += '<div class="empty">No maps are available right now.</div>';
  return lobbyDialog(modal, {
    title: 'Choose a map', step: 'New world · step 1 of 2', wide: true, form: true,
    subtitle: 'The map is fixed once the world exists. Everything else can be changed later.',
    body: body,
    footer: lobbyButtons(modal, [
      { label: 'Cancel', onclick: 'return lobbyClose()', cancel: true },
      { label: 'Next: details', kind: 'primary', submit: true, disabled: !modal.fields.map || info.totalFull }
    ])
  });
}

function lobbyToggleHtml(id, name, title, help, checked, disabledReason) {
  return '<label class="toggle' + (disabledReason ? ' disabled' : '') + '" for="' + id + '">' +
    '<input type="checkbox" id="' + id + '"' + (checked ? ' checked' : '') + (disabledReason ? ' disabled' : '') +
    ' onclick="lobbyField(\'' + name + '\', this.checked ? 1 : 0, true)">' +
    '<span class="switch" aria-hidden="true"></span><span class="toggle-text"><b>' + lobbyEsc(title) + '</b><small>' + lobbyEsc(help) + '</small>' +
    (disabledReason ? '<small class="why">' + lobbyEsc(disabledReason) + '</small>' : '') + '</span></label>';
}

/// Name, description, who can join, password, capacity and the two flags.
function lobbySettingsHtml(modal, options) {
  var f = modal.fields;
  var locked = options.locked ? ' disabled' : '';
  var html = '<div class="field"><label for="f-name">World name</label><input type="text" id="f-name" maxlength="60" data-autofocus="1" value="' +
    lobbyEsc(f.name) + '" oninput="lobbyField(\'name\', this.value)"' + locked + '></div>' +
    '<div class="field"><label for="f-description">Description <small>(optional)</small></label><textarea id="f-description" maxlength="500" rows="3" oninput="lobbyField(\'description\', this.value)"' +
    locked + '>' + lobbyEsc(f.description) + '</textarea></div>' +
    '<fieldset class="choice-group"><legend>Who can join?</legend><div class="choices">';
  for (var i = 0; i < LOBBY_VISIBILITY.length; i++) {
    var v = LOBBY_VISIBILITY[i];
    var on = f.visibility === v.id;
    html += '<label class="choice' + (on ? ' selected' : '') + (options.locked ? ' disabled' : '') + '" for="vis-' + v.id + '">' +
      '<input type="radio" name="visibility" id="vis-' + v.id + '" value="' + v.id + '"' + (on ? ' checked' : '') + locked +
      ' onclick="lobbyField(\'visibility\', this.value, true)"><b>' + lobbyEsc(v.label) + '</b><small>' + lobbyEsc(v.help) + '</small></label>';
  }
  html += '</div></fieldset>';
  if (f.visibility === 'password') {
    var keep = !options.creating && options.world && options.world.visibility === 'password';
    html += '<div class="field"><label for="f-password">World password</label><input type="password" id="f-password" maxlength="128" value="' +
      lobbyEsc(f.password) + '" oninput="lobbyField(\'password\', this.value)"' + locked +
      (keep ? ' placeholder="Leave empty to keep the current password"' : '') + '>' +
      '<small class="hint">Guests enter this to join. Members and admins never need it.</small></div>';
  }
  html += '<div class="field"><label for="f-max">Maximum players</label><input type="number" id="f-max" min="1" max="' + (lobbyState.player_limit || 1) +
    '" step="1" value="' + lobbyEsc(f.max_players) + '" oninput="lobbyField(\'max_players\', this.value)"' + locked + '>' +
    '<small class="hint">Up to ' + (lobbyState.player_limit || 1) + ' on this server.</small></div>';
  html += '<div class="toggles" role="group" aria-label="World type"><span class="field-label">World type</span>' +
    lobbyToggleHtml('f-creative', 'creative', 'Creative', LOBBY_CREATIVE_HELP, f.creative, options.locked ? options.lockReason : '') +
    lobbyToggleHtml('f-persistent', 'persistent', 'Persistent', LOBBY_PERSISTENT_HELP, f.persistent,
      options.locked ? options.lockReason : options.persistentReason) + '</div>';
  return html;
}

function lobbyCreateDetailsHtml(modal) {
  var info = lobbyLimitInfo();
  var map = lobbyMap(modal.fields.map);
  var card = map ? lobbyCardForMap(map.id) : null;
  var body = '';
  if (card) {
    body += '<div class="chosen-map">' + lobbyPreviewHtml({ key: card.key, name: card.name, group: card.group, maps: [map] }) +
      '<div class="grow"><b>' + lobbyEsc(map.name) + '</b>' + lobbyMultizBadge(card) + '<br><small>' + lobbyEsc(map.description) + '</small></div>' +
      '<button type="button" class="button small" onclick="return lobbyWizardStep(\'map\')">Change map</button></div>';
  }
  body += lobbyLimitsHtml(info);
  if (info.totalFull) body += '<div class="callout">You have reached your limit of ' + info.maxTotal + ' worlds. Delete a world you no longer need to create a new one.</div>';
  var persistentReason = info.savedFull ? 'You already have ' + info.saved + ' of ' + info.maxSaved + ' saved worlds, so this one can only be an unsaved world.' : '';
  body += lobbySettingsHtml(modal, { creating: true, persistentReason: persistentReason });
  return lobbyDialog(modal, {
    title: 'World details', step: 'New world · step 2 of 2', form: true,
    body: body,
    footer: lobbyButtons(modal, [
      { label: 'Back', kind: 'back', onclick: 'return lobbyWizardStep(\'map\')' },
      { spacer: true },
      { label: 'Cancel', onclick: 'return lobbyClose()', cancel: true },
      { label: 'Create only', onclick: 'return lobbyCreate(0)', disabled: info.totalFull },
      { label: 'Create & join', kind: 'primary', submit: true, busy: true, id: 'modal-submit', disabled: info.totalFull }
    ])
  });
}

function lobbyEditHtml(modal) {
  var world = lobbyWorld(modal.world) || { name: modal.fields.name, state: 'stopped' };
  var running = world.state !== 'stopped';
  var map = lobbyMap(world.map);
  var info = lobbyLimitInfo();
  var persistentReason = '';
  if (world.persistent === 0 && info.savedFull) persistentReason = 'You already have ' + info.saved + ' of ' + info.maxSaved + ' saved worlds.';
  var body = '';
  if (running) {
    body += '<div class="callout">This world is ' + lobbyEsc(world.state === 'running' ? 'online' : world.state) +
      '. Stop it to change its settings: every setting, Creative and Persistent included, can only change while the world is offline.</div>';
  }
  body += '<p class="muted">Map: <b>' + lobbyEsc(map ? map.name : (world.map || 'Babylon')) + '</b> (fixed when the world was created)</p>';
  body += lobbySettingsHtml(modal, {
    creating: false, world: world, locked: running, lockReason: 'Stop the world to change this.', persistentReason: persistentReason
  });
  var buttons = running ? [{ label: 'Close', onclick: 'return lobbyClose()', cancel: true }] : [
    { label: 'Cancel', onclick: 'return lobbyClose()', cancel: true },
    { label: 'Save settings', kind: 'primary', submit: true, busy: true, id: 'modal-submit' }
  ];
  return lobbyDialog(modal, { title: 'World settings', subtitle: world.name, form: true, body: body, footer: lobbyButtons(modal, buttons) });
}

function lobbyJoinHtml(modal) {
  var world = lobbyWorld(modal.world) || { name: 'this world' };
  var body = '<p>' + lobbyEsc(world.name) + ' is protected by a password. Ask its owner if you do not know it.</p>' +
    '<div class="field"><label for="join-password">World password</label><input type="password" id="join-password" maxlength="128" data-autofocus="1" value="' +
    lobbyEsc(modal.fields.password) + '" oninput="lobbyField(\'password\', this.value)"></div>';
  return lobbyDialog(modal, {
    title: 'Join ' + world.name, form: true, body: body,
    footer: lobbyButtons(modal, [
      { label: 'Cancel', onclick: 'return lobbyClose()', cancel: true },
      { label: modal.spectate ? 'Spectate' : 'Join world', kind: 'primary', submit: true, busy: true, id: 'modal-submit' }
    ])
  });
}

function lobbyMembersHtml(modal) {
  var world = lobbyWorld(modal.world) || { name: 'this world' };
  var role = modal.fields.role === 'remove' ? 'remove' : 'member';
  var body = '<p class="muted">Members can start this world while you are away, join it even when it is private, and build in it.</p>' +
    '<div class="field"><label for="f-member">BYOND account</label><input type="text" id="f-member" maxlength="64" data-autofocus="1" value="' +
    lobbyEsc(modal.fields.member) + '" oninput="lobbyField(\'member\', this.value)"></div>' +
    '<fieldset class="choice-group"><legend>Change</legend><div class="choices">' +
    '<label class="choice' + (role === 'member' ? ' selected' : '') + '" for="role-member"><input type="radio" name="role" id="role-member" value="member"' +
    (role === 'member' ? ' checked' : '') + ' onclick="lobbyField(\'role\', this.value, true)"><b>Add as member</b><small>Grant access to this world.</small></label>' +
    '<label class="choice' + (role === 'remove' ? ' selected' : '') + '" for="role-remove"><input type="radio" name="role" id="role-remove" value="remove"' +
    (role === 'remove' ? ' checked' : '') + ' onclick="lobbyField(\'role\', this.value, true)"><b>Remove access</b><small>The account becomes a guest again.</small></label>' +
    '</div></fieldset>';
  return lobbyDialog(modal, {
    title: 'Members', subtitle: world.name, form: true, body: body,
    footer: lobbyButtons(modal, [
      { label: 'Cancel', onclick: 'return lobbyClose()', cancel: true },
      { label: role === 'remove' ? 'Remove access' : 'Add member', kind: role === 'remove' ? 'danger' : 'primary', submit: true, busy: true, id: 'modal-submit' }
    ])
  });
}

/// "save-20261114-130522-3" as "2026-11-14 13:05:22".
function lobbyCheckpointLabel(generation) {
  var match = /^save-(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})-(\d+)$/.exec(String(generation));
  if (!match) return String(generation);
  return match[1] + '-' + match[2] + '-' + match[3] + ' ' + match[4] + ':' + match[5] + ':' + match[6];
}

function lobbyCheckpointsHtml(modal) {
  var world = lobbyWorld(modal.world) || { name: 'this world' };
  var points = modal.checkpoints || [];
  if (modal.step === 'confirm') {
    var index = 0;
    for (var i = 0; i < points.length; i++) if (points[i].generation === modal.fields.generation) index = i;
    var newer = index;
    var confirmBody = '<div class="consequence"><p>Restore <b>' + lobbyEsc(world.name) + '</b> to the checkpoint from <b>' +
      lobbyEsc(lobbyCheckpointLabel(modal.fields.generation)) + '</b>?</p><p>This rewinds the entire world for everyone. <b>' + newer +
      ' newer checkpoint' + (newer === 1 ? '' : 's') + '</b>, the current state included, will be <b>permanently deleted</b>. This cannot be undone.</p></div>';
    return lobbyDialog(modal, {
      title: 'Restore this checkpoint?', danger: true, body: confirmBody,
      footer: lobbyButtons(modal, [
        { label: 'Back', kind: 'back', onclick: 'return lobbyCheckpointStep(\'pick\')' },
        { spacer: true },
        { label: 'Cancel', onclick: 'return lobbyClose()', cancel: true, autofocus: true },
        { label: 'Restore and delete newer', kind: 'danger solid', onclick: 'return lobbyConfirm()', busy: true, id: 'modal-confirm' }
      ])
    });
  }
  var body = '';
  if (modal.loading) {
    body = '<p><span class="spinner inline" aria-hidden="true"></span>Loading saved checkpoints...</p>';
  } else if (!modal.checkpoints) {
    body = '<p class="muted">The checkpoints could not be loaded. Close this window and try again.</p>';
  } else if (!points.length) {
    body = '<p>This world has no saved checkpoints yet. It saves automatically while it runs.</p>';
  } else {
    body = '<p class="muted">Newest first. Restoring a checkpoint rewinds the world to that moment.</p><ul class="checkpoints" role="radiogroup" aria-label="Saved checkpoints">';
    for (var p = 0; p < points.length; p++) {
      var point = points[p];
      var current = !!point.current;
      var on = modal.fields.generation === point.generation;
      var id = 'cp-' + p;
      body += '<li><label class="checkpoint' + (on ? ' selected' : '') + (current ? ' current' : '') + '" for="' + id + '">' +
        '<input type="radio" name="checkpoint" id="' + id + '" value="' + lobbyEsc(point.generation) + '"' + (on ? ' checked' : '') +
        (current ? ' disabled' : '') + ' onclick="lobbyField(\'generation\', this.value, true)">' +
        '<span class="when">' + lobbyEsc(lobbyCheckpointLabel(point.generation)) + '</span>' +
        (point.objects !== undefined ? '<small>' + lobbyEsc(point.objects) + ' objects</small>' : '') +
        (current ? '<span class="badge running">Current</span>' : '') + '</label></li>';
    }
    body += '</ul>';
  }
  return lobbyDialog(modal, {
    title: 'Saved checkpoints', subtitle: world.name, body: body,
    footer: lobbyButtons(modal, [
      { label: 'Close', onclick: 'return lobbyClose()', cancel: true },
      { label: 'Restore...', kind: 'danger', onclick: 'return lobbyCheckpointStep(\'confirm\')', disabled: modal.loading || !modal.fields.generation }
    ])
  });
}

function lobbyDiscordHtml(modal) {
  var body;
  if (modal.loading) {
    body = '<p><span class="spinner inline" aria-hidden="true"></span>Creating your link code...</p>';
  } else if (!modal.command) {
    body = '<p class="muted">No link code could be created. Close this window and try again in a moment.</p>';
  } else {
    body = '<p>Type this command in our Discord within <b>10 minutes</b>:</p>' +
      '<div class="copy-row"><input type="text" id="discord-command" readonly value="' + lobbyEsc(modal.command) + '" onfocus="this.select()" data-autofocus="1">' +
      '<button type="button" class="button" onclick="return lobbyCopyCommand()">Copy</button></div>' +
      '<div class="copy-status" id="copy-status" role="status"></div>' +
      '<p class="muted">This page notices the link by itself a few seconds after you sent the command.</p>';
  }
  var buttons = [];
  if (!modal.loading && modal.command && modal.invite) buttons.push({ label: 'Open our Discord', onclick: 'return lobbyOpenDiscord()' });
  buttons.push({ label: 'Done', kind: 'primary', onclick: 'return lobbyClose()', cancel: true });
  return lobbyDialog(modal, { title: 'Link your Discord account', body: body, footer: lobbyButtons(modal, buttons) });
}

function lobbyConfirmHtml(modal) {
  if (modal.action === 'discord_unlink') {
    return lobbyDialog(modal, {
      title: 'Unlink Discord?',
      body: '<p>Unlink your Discord account from <b>' + lobbyEsc(lobbyState.ckey) + '</b>? If this server requires a linked account, you need to link again before creating or joining worlds.</p>',
      footer: lobbyButtons(modal, [
        { label: 'Cancel', onclick: 'return lobbyClose()', cancel: true, autofocus: true },
        { label: 'Unlink', kind: 'danger solid', onclick: 'return lobbyConfirm()', busy: true, id: 'modal-confirm' }
      ])
    });
  }
  var world = lobbyWorld(modal.world) || { name: '', persistent: 1 };
  var name = '<b>' + lobbyEsc(world.name) + '</b>';
  if (modal.action === 'stop') {
    var saved = world.persistent !== 0;
    return lobbyDialog(modal, {
      title: saved ? 'Save and stop this world?' : 'Stop this world?', danger: !saved,
      body: '<div class="' + (saved ? 'callout info' : 'consequence') + '"><p>' + (saved
        ? 'The world saves a final checkpoint, then stops. Everyone still in ' + name + ' is returned to the lobby.'
        : name + ' is not saved: <b>everything built since it started is lost</b> when it stops. Everyone still in it is returned to the lobby.') + '</p></div>',
      footer: lobbyButtons(modal, [
        { label: 'Cancel', onclick: 'return lobbyClose()', cancel: true, autofocus: true },
        { label: saved ? 'Save and stop' : 'Stop without saving', kind: saved ? 'primary' : 'danger solid', onclick: 'return lobbyConfirm()', busy: true, id: 'modal-confirm' }
      ])
    });
  }
  var reset = modal.action === 'reset';
  var consequence = reset
    ? '<p>Reset ' + name + '? <b>All of its saves and checkpoints are permanently deleted</b>; its next start begins on a fresh map.</p><p>The world itself, its settings and members stay. This cannot be undone.</p>'
    : '<p>Permanently delete ' + name + '? <b>The world and all of its saved checkpoints are deleted for everyone.</b></p><p>This cannot be undone.</p>';
  var matches = lobbyTrim(modal.fields.confirm_name) === lobbyTrim(world.name);
  var body = '<div class="consequence">' + consequence + '</div>' +
    '<div class="field"><label for="confirm-name">Type <b>' + lobbyEsc(world.name) + '</b> to confirm</label>' +
    '<input type="text" id="confirm-name" data-autofocus="1" value="' + lobbyEsc(modal.fields.confirm_name) + '" oninput="lobbyConfirmName(this.value)"></div>';
  return lobbyDialog(modal, {
    title: reset ? 'Reset world?' : 'Delete world?', danger: true, body: body,
    footer: lobbyButtons(modal, [
      { label: 'Cancel', onclick: 'return lobbyClose()', cancel: true },
      { label: reset ? 'Reset world' : 'Delete permanently', kind: 'danger solid', onclick: 'return lobbyConfirm()', busy: true, id: 'modal-confirm', disabled: !matches }
    ])
  });
}
