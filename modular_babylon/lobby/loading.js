// One browser document keeps status updates from resetting the viewport.
var lobbyView = '';
var lobbyScroll = {};
var lobbyPending = false;
var lobbyRevision = -1;
// The lobby sends lobbyAlive every 5 seconds. When it stops, the server is gone (usually a
// restart): links would do nothing, so the page shows the reconnect screen instead.
var lobbyLastAlive = new Date().getTime();
var lobbyLost = false;
// A link deliberately leaves this server. Its stale browser must not report an outage.
var lobbyHandoff = false;

function lobbyAlive() {
  lobbyLastAlive = new Date().getTime();
}

setInterval(function () {
  if (lobbyLost || lobbyHandoff || new Date().getTime() - lobbyLastAlive < 15000) return;
  lobbyLost = true;
  document.getElementById('browser-content').style.display = 'none';
  document.getElementById('action-loading').style.display = 'none';
  document.getElementById('connection-lost').style.display = 'block';
  if (typeof lobbyHideOverlays === 'function') lobbyHideOverlays();
  window.scrollTo(0, 0);
}, 2000);

function rememberLobbyScroll() {
  if (lobbyView && !lobbyPending) {
    lobbyScroll[lobbyView] = window.pageYOffset || document.documentElement.scrollTop || 0;
  }
}

function showLobbyLoading(name, stage) {
  rememberLobbyScroll();
  lobbyPending = true;
  // A full-page loading screen replaces any open dialog (lobby.js).
  if (typeof lobbyHideOverlays === 'function') lobbyHideOverlays();
  document.getElementById('loading-world').textContent = name || 'Your world';
  document.getElementById('loading-stage').textContent = stage || 'Working...';
  document.getElementById('browser-content').style.display = 'none';
  document.getElementById('action-loading').style.display = 'block';
  document.getElementById('handoff-return').style.display = 'none';
  window.scrollTo(0, 0);
}

function showLobbyHandoff(name, lobbyAddress) {
  showLobbyLoading(name, 'Connection offered. If the world does not open, return to the lobby to try again.');
  lobbyHandoff = true;
  var back = document.getElementById('handoff-return');
  if (lobbyAddress) {
    back.href = lobbyAddress;
    back.style.display = 'inline-block';
  }
}

function beginAction(link) {
  if (lobbyPending || lobbyLost) return false;
  showLobbyLoading(link.getAttribute('data-world') || 'Babylon 13',
    link.getAttribute('data-stage') || 'Preparing your request...');
  return true;
}

function renderLobby(encoded) {
  var data = JSON.parse(encoded);
  if (lobbyLost || lobbyHandoff) return;
  if (data.revision < lobbyRevision || (lobbyPending && !data.complete)) return;
  rememberLobbyScroll();
  lobbyRevision = data.revision;
  lobbyView = data.view;
  // World and map data for the dialogs (lobby.js). An open dialog is not re-rendered, so
  // what the player is typing survives every poll.
  if (data.state && typeof lobbyUpdateState === 'function') lobbyUpdateState(data.state);
  var main = document.getElementById('browser-content');
  // Sections lobby.js draws from the state (the tutorial cards) fill their placeholders here.
  var html = typeof lobbyExpandSections === 'function' ? lobbyExpandSections(data.html) : data.html;
  if (main.innerHTML !== html) main.innerHTML = html;
  document.getElementById('action-loading').style.display = 'none';
  main.style.display = 'block';
  lobbyPending = false;
  var position = lobbyScroll[lobbyView] || 0;
  window.scrollTo(0, position);
  setTimeout(function () {
    if (!lobbyPending && lobbyView === data.view && lobbyRevision === data.revision) window.scrollTo(0, position);
  }, 0);
}
