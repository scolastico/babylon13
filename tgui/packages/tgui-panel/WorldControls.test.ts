import { describe, expect, it } from 'bun:test';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { runInNewContext } from 'node:vm';

function panel() {
  document.body.innerHTML = '<div id="menu"></div><div id="statcontent"></div>';
  const subscribers: Record<string, (payload?: unknown) => void> = {};
  runInNewContext(readFileSync(resolve(import.meta.dir, '../../../html/statbrowser.js'), 'utf8'), {
    document,
    window,
    setTimeout,
    Byond: {
      subscribeTo: (type: string, callback: (payload?: unknown) => void) => {
        subscribers[type] = callback;
      },
      sendMessage: () => {},
      winset: () => {},
      command: () => {},
    },
  });
  return subscribers;
}

function orderedTabs() {
  return Array.from(document.querySelectorAll<HTMLElement>('#menu > .button'))
    .sort((a, b) => Number(a.style.order) - Number(b.style.order))
    .map((tab) => tab.textContent);
}

describe('World Controls stat tab', () => {
  for (const admin of [false, true]) {
    it(`is second for ${admin ? 'admins' : 'players'} after initial verbs and refresh`, () => {
      const messages = panel();
      messages.init_verbs({
        panel_tabs: admin ? ['World Controls', 'OOC', 'Admin', 'IC'] : ['World Controls', 'OOC', 'IC'],
        verblist: [['World Controls', 'Return to Babylon lobby']],
      });
      if (admin) messages.add_admin_tabs('fixture-token');
      expect(orderedTabs().slice(0, 2)).toEqual(['Status', 'World Controls']);
      messages.remove_admin_tabs();
      expect(orderedTabs().slice(0, 2)).toEqual(['Status', 'World Controls']);
    });
  }
});
