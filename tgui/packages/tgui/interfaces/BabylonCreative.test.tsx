import { describe, expect, it, mock } from 'bun:test';
import { act, fireEvent, render, screen } from '@testing-library/react';
import { gameDataAtom, store } from '../events/store';

import {
  BabylonCreative,
  type CreativeData,
  formatWait,
  type TutorialData,
} from './BabylonCreative';

const wrench = {
  path: '/obj/item/wrench',
  name: 'Wrench',
  icon: 'icons/obj/tools.dmi',
  icon_state: 'wrench',
  stack: false,
  max: 1,
  item: true,
};

const data: CreativeData = {
  tabs: [
    { id: 'self', name: 'Self', icon: 'user-shield' },
    { id: 'spawn', name: 'Spawn', icon: 'cube' },
    { id: 'teleport', name: 'Teleport', icon: 'location-arrow' },
    { id: 'events', name: 'Events', icon: 'bolt' },
    { id: 'tools', name: 'Kits', icon: 'toolbox' },
    { id: 'tutorial', name: 'Tutorial', icon: 'graduation-cap' },
    { id: 'future', name: 'Future', icon: 'question' },
  ],
  categories: [
    {
      id: 'creative',
      name: 'Creative machines',
      icon: 'wand-magic-sparkles',
      entries: [],
    },
    {
      id: 'tools',
      name: 'Tools',
      icon: 'screwdriver-wrench',
      entries: [wrench],
    },
    {
      id: 'materials',
      name: 'Construction materials',
      icon: 'cubes',
      entries: [
        {
          ...wrench,
          path: '/obj/item/stack/sheet/iron',
          name: 'Iron',
          stack: true,
          max: 50,
        },
      ],
    },
  ],
  levels: [{ z: 2, name: 'Babylon' }],
  areas: [
    { path: '/area/station/hallway', name: 'Hallway', z: 2 },
    { path: '/area/station/bridge', name: 'Bridge', z: 2 },
  ],
  events: [
    {
      path: '/datum/round_event_control/communications_blackout',
      name: 'Communications Blackout',
      description: 'Heavily EMPs all telecommunication machines.',
      category: 'Engineering',
    },
  ],
  wand_available: false,
  kit: [wrench],
  show_markers: true,
  map_size: { x: 255, y: 255 },
  limits: {
    spawns: 20,
    spawn_window: 10,
    copies: 10,
    events: 3,
    event_window: 30,
  },
  godmode: true,
  godmode_elsewhere: false,
  noclip: false,
  xray: false,
  fullbright: true,
  dead: false,
  health: 85,
  body: 'Maintenance drone',
  position: { x: 120, y: 98, z: 2, area: 'Hallway' },
  players: [{ ckey: 'friend', name: 'Drone (Friend)', z: 2 }],
  markers: [],
  search: { query: '', category: 'all', results: [], capped: false },
  spawns_left: 20,
  spawns_refill_in: 0,
  can_go_back: false,
  respawn_pending: false,
  events_left: 3,
  events_refill_in: 0,
  notice: { text: 'Godmode on: nothing can hurt you.', ok: true, id: 1 },
  extensions: {},
};

store.set(gameDataAtom, data);

const openTab = (name: string) => {
  act(() => render(<BabylonCreative />));
  act(() => {
    fireEvent.click(screen.getAllByText(name)[0]);
  });
};

describe('BabylonCreative', () => {
  it('opens on the Self tab with the powers and the last notice', () => {
    act(() => render(<BabylonCreative />));
    expect(screen.getByText('Godmode')).toBeDefined();
    expect(screen.getByText('Noclip')).toBeDefined();
    expect(screen.getByText('X-ray')).toBeDefined();
    expect(screen.getByText('Fullbright')).toBeDefined();
    expect(screen.getByText('Heal fully')).toBeDefined();
    expect(screen.getByText('Godmode on: nothing can hurt you.')).toBeDefined();
  });

  it('sends xray and fullbright from their own rows, each with its own state', () => {
    const sent: string[] = [];
    mock.module('../events/act', () => ({
      sendAct: (action: string) => {
        sent.push(action);
      },
    }));
    act(() => render(<BabylonCreative />));
    // Each toggle row: the name, then its own On/Off button (xray off, fullbright on here).
    const rowButton = (name: string) => {
      const row = screen.getByText(name).closest('div')?.parentElement
        ?.parentElement as HTMLElement;
      const buttons = row.querySelectorAll('.Button');
      return buttons[buttons.length - 1] as HTMLElement;
    };
    expect(rowButton('X-ray').textContent).toContain('Off');
    expect(rowButton('Fullbright').textContent).toContain('On');
    expect(rowButton('Noclip').textContent).toContain('Off');
    expect(rowButton('Godmode').textContent).toContain('On');
    act(() => {
      fireEvent.click(rowButton('X-ray'));
    });
    act(() => {
      fireEvent.click(rowButton('Fullbright'));
    });
    expect(sent).toEqual(['xray', 'fullbright']);
    // The header's quick toggles send the same actions.
    act(() => {
      fireEvent.click(document.querySelector('.fa-eye')!.closest('.Button')!);
      fireEvent.click(
        document.querySelector('.fa-lightbulb')!.closest('.Button')!,
      );
    });
    expect(sent.slice(2)).toEqual(['xray', 'fullbright']);
  });

  it('shows the curated spawn categories', () => {
    openTab('Spawn');
    // Empty categories stay out of "All"; stacks show their full-stack badge.
    expect(screen.getAllByText('Creative machines').length).toBe(1);
    expect(screen.getByText('x50')).toBeDefined();
    expect(screen.getByText('Full stack')).toBeDefined();
    expect(screen.getByText('20 spawns left')).toBeDefined();
  });

  it('lists players, areas and an empty marker section', () => {
    openTab('Teleport');
    expect(screen.getByText('Drone (Friend)')).toBeDefined();
    expect(screen.getByText('Bridge')).toBeDefined();
    expect(screen.getByText('No tutorial markers placed yet.')).toBeDefined();
  });

  it('lists events with a Run button', () => {
    openTab('Events');
    expect(screen.getByText('Communications Blackout')).toBeDefined();
    expect(screen.getByText('Run')).toBeDefined();
  });

  it('shows the wand as coming soon while it does not exist', () => {
    openTab('Kits');
    expect(screen.getByText('Get tool kit')).toBeDefined();
    expect(screen.getByText('Coming soon')).toBeDefined();
  });

  it('shows a placeholder for a server tab without a component', () => {
    openTab('Future');
    expect(screen.getByText('This tab is not available yet.')).toBeDefined();
  });
});

const idle: TutorialData = {
  mode: 'submit',
  blocked: null,
  blocked_text: null,
  wait_seconds: 0,
  checking: false,
  check_error: null,
  state: 'idle',
  message: null,
  title: null,
  cooldown_hours: 6,
  pause_seconds: 40,
  title_max: 60,
  description_max: 500,
};

const withTutorial = (tutorial: Partial<TutorialData>) =>
  store.set(gameDataAtom, {
    ...data,
    extensions: { tutorial: { ...idle, ...tutorial } },
  });

const submitButton = () =>
  screen.getByText(/^(Submit for review…|Submitting…)$/).closest('.Button');

const isDisabled = (element: Element | null) =>
  !!element?.className.includes('Button--disabled');

describe('BabylonCreative Tutorial tab', () => {
  it('idle: warns, shows the limits and enables Submit once titled', () => {
    withTutorial({});
    openTab('Tutorial');
    expect(
      screen.getByText(/sends this world to the moderators/),
    ).toBeDefined();
    expect(screen.getByText('None: you can submit now')).toBeDefined();
    expect(screen.getByPlaceholderText('1–60 characters')).toBeDefined();
    expect(screen.getByText('0/500')).toBeDefined();
    // No title yet: nothing to send.
    expect(isDisabled(submitButton())).toBe(true);
    expect(screen.getByText('Enter a title to submit.')).toBeDefined();
    // The warning names what the player can't undo.
    expect(screen.getByText(/can't change it afterwards/)).toBeDefined();
    expect(screen.getByText(/cooldown \(6 h\)/)).toBeDefined();
    act(() => {
      fireEvent.change(screen.getByPlaceholderText('1–60 characters'), {
        target: { value: 'First aid' },
      });
    });
    expect(isDisabled(submitButton())).toBe(false);
    expect(screen.queryByText('Enter a title to submit.')).toBeNull();
  });

  it('leaves the cooldown out when the server has none', () => {
    withTutorial({ cooldown_hours: 0 });
    openTab('Tutorial');
    expect(screen.queryByText(/after the cooldown/)).toBeNull();
    expect(screen.getByText(/can't change it afterwards/)).toBeDefined();
  });

  it('keeps an open confirm but disables it while nothing can be sent', () => {
    withTutorial({});
    let view: ReturnType<typeof render> | undefined;
    act(() => {
      view = render(<BabylonCreative />);
    });
    act(() => {
      fireEvent.click(screen.getAllByText('Tutorial')[0]);
    });
    act(() => {
      fireEvent.change(screen.getByPlaceholderText('1–60 characters'), {
        target: { value: 'First aid' },
      });
    });
    act(() => {
      fireEvent.click(screen.getByText('Submit for review…'));
    });
    // A cooldown arrives while the confirm is open: it stays, but can't be confirmed.
    withTutorial({ blocked: 'cooldown', blocked_text: 'Cooldown: 4 min.' });
    act(() => {
      view?.rerender(<BabylonCreative />);
    });
    expect(screen.getByText('Cooldown: 4 min.')).toBeDefined();
    const yes = screen.getByText('Yes, submit').closest('.Button');
    expect(isDisabled(yes)).toBe(true);
  });

  it('confirms a submission before sending it', () => {
    withTutorial({});
    openTab('Tutorial');
    act(() => {
      fireEvent.change(screen.getByPlaceholderText('1–60 characters'), {
        target: { value: 'First aid' },
      });
    });
    act(() => {
      fireEvent.click(screen.getByText('Submit for review…'));
    });
    expect(screen.getByText(/Submit "First aid" for review\?/)).toBeDefined();
    expect(screen.getByText(/waits 6 h/)).toBeDefined();
    expect(screen.getByText('Yes, submit')).toBeDefined();
    act(() => {
      fireEvent.click(screen.getByText('Cancel'));
    });
    expect(screen.queryByText('Yes, submit')).toBeNull();
    expect(screen.getByText('Submit for review…')).toBeDefined();
  });

  it('cooldown: shows the time left and why Submit is disabled', () => {
    withTutorial({
      blocked: 'cooldown',
      blocked_text: 'Cooldown: you can submit another tutorial in 4 min.',
      wait_seconds: 240,
    });
    openTab('Tutorial');
    expect(screen.getByText('4 min left')).toBeDefined();
    expect(
      screen.getByText('Cooldown: you can submit another tutorial in 4 min.'),
    ).toBeDefined();
    expect(isDisabled(submitButton())).toBe(true);
  });

  it('missing start marker: explains and disables Submit', () => {
    withTutorial({
      blocked: 'no_start',
      blocked_text:
        'Needs a start marker: place a marker with the id "start" (tutorial wand) where players begin.',
    });
    openTab('Tutorial');
    expect(screen.getByText(/Needs a start marker/)).toBeDefined();
    expect(isDisabled(submitButton())).toBe(true);
  });

  it('submitting: shows the pending state and blocks a second click', () => {
    withTutorial({ state: 'submitting' });
    openTab('Tutorial');
    expect(screen.getByText(/^Submitting… the world pauses/)).toBeDefined();
    expect(screen.getByText('Submitting…')).toBeDefined();
    expect(isDisabled(submitButton())).toBe(true);
  });

  it('done: shows the success message', () => {
    withTutorial({
      state: 'done',
      message:
        'Submitted "First aid". The moderators review it before it is published.',
    });
    openTab('Tutorial');
    expect(screen.getByText(/The moderators review it/)).toBeDefined();
  });

  it('error: shows the server error', () => {
    withTutorial({
      state: 'error',
      message: 'Not submitted: the server could not be reached.',
    });
    openTab('Tutorial');
    expect(
      screen.getByText('Not submitted: the server could not be reached.'),
    ).toBeDefined();
  });

  it('not a creative station world: explains why nothing can be sent', () => {
    withTutorial({
      blocked: 'not_capable',
      blocked_text:
        'Tutorials can only be submitted from a Creative world on a station map (a Creative Plane or a station). Babylon worlds can build, but not submit.',
    });
    openTab('Tutorial');
    expect(screen.getByText(/Babylon worlds can build/)).toBeDefined();
    expect(isDisabled(submitButton())).toBe(true);
    expect(screen.queryByText('None: you can submit now')).toBeNull();
    // Nothing can be sent from here: the form is read-only.
    expect(
      screen.getByPlaceholderText('1–60 characters').hasAttribute('disabled'),
    ).toBe(true);
  });

  it('save back: admins confirm before the pending tutorial is replaced', () => {
    withTutorial({ mode: 'save_back', title: 'First aid' });
    openTab('Tutorial');
    expect(screen.getByText('Editing: First aid')).toBeDefined();
    expect(screen.queryByText('Submit for review…')).toBeNull();
    act(() => {
      fireEvent.click(screen.getByText('Save back to the pending tutorial'));
    });
    expect(screen.getByText(/Replace the pending tutorial/)).toBeDefined();
    expect(screen.getByText('Yes, save back')).toBeDefined();
    act(() => {
      fireEvent.click(screen.getByText('Cancel'));
    });
    expect(screen.queryByText('Yes, save back')).toBeNull();
  });

  it('save back: the button says it is running', () => {
    withTutorial({ mode: 'save_back', state: 'saving_back' });
    openTab('Tutorial');
    expect(screen.getByText('Saving back…')).toBeDefined();
  });

  it('save back: players who are not admins see why it is disabled', () => {
    withTutorial({
      mode: 'save_back',
      blocked: 'not_admin',
      blocked_text:
        'Only server administrators can save back to a pending tutorial.',
    });
    openTab('Tutorial');
    expect(screen.getByText(/Only server administrators/)).toBeDefined();
    const button = screen
      .getByText('Save back to the pending tutorial')
      .closest('.Button');
    expect(isDisabled(button)).toBe(true);
  });

  it('words the cooldown like the server', () => {
    expect(formatWait(30)).toBe('30 s');
    expect(formatWait(240)).toBe('4 min');
    expect(formatWait(3900)).toBe('1 h 5 min');
  });
});
