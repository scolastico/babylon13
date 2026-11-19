import { afterEach, describe, expect, it } from 'bun:test';
import { act, fireEvent, render, screen } from '@testing-library/react';
import { EscapeMenu, type ServerState } from './EscapeMenu';

const byondGlobal = globalThis as unknown as { Byond: typeof Byond };
const originalByond = Byond;
afterEach(() => {
  byondGlobal.Byond = originalByond;
});

function menu(canReturnToLobby: boolean) {
  const subscribers: Record<string, (payload?: unknown) => void> = {};
  const actions: unknown[] = [];
  byondGlobal.Byond = {
    ...originalByond,
    subscribeTo: (type: string, handler: (payload?: unknown) => void) => {
      subscribers[type] = handler;
    },
    sendMessage: (type: string, payload: unknown) => {
      if (type === 'action') actions.push(payload);
    },
  } as typeof Byond;
  render(<EscapeMenu />);
  const serverState: ServerState = {
    babylon: true,
    canReturnToLobby,
    stationName: 'Test world',
    resources: [],
    canLeaveBody: false,
    canAdminHelp: false,
    hasTicketNotification: false,
    roundId: '1',
    mapName: 'Test map',
    mapFeedbackLink: null,
    serverTime: '12:00:00',
    shiftTime: '00:00:00',
    timeDilation: '0',
    canSeeNotes: false,
    admins: [],
    players: [],
    ignoredOffline: [],
    suicideIcon: null,
  };
  act(() => subscribers.init(serverState));
  return actions;
}

describe('Escape menu departure', () => {
  it('names the Babylon lobby destination before confirming departure', () => {
    const actions = menu(true);
    fireEvent.click(screen.getByRole('button', { name: 'Return to lobby' }));
    expect(screen.getByText('Return to the Babylon lobby?')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Return to lobby' }));
    expect(actions).toEqual([{ action: 'quit' }]);
  });

  it('keeps client quit when no lobby destination is available', () => {
    const actions = menu(false);
    fireEvent.click(screen.getByRole('button', { name: 'Quit' }));
    expect(screen.getByText('Are you sure you wish to quit?')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Yes' }));
    expect(actions).toEqual([{ action: 'quit' }]);
  });
});
