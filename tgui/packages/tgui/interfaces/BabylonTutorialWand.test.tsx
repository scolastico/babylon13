import { afterEach, describe, expect, it, mock } from 'bun:test';
import {
  act,
  cleanup,
  fireEvent,
  render,
  screen,
} from '@testing-library/react';
import { gameDataAtom, store } from '../events/store';

import {
  allActions,
  BabylonTutorialWand,
  buildFlow,
  gateStateText,
  groupMembers,
  type TutorialObject,
  type WandData,
  WORLD_EDIT_HINT,
} from './BabylonTutorialWand';

const colors = {
  trigger: '#ffc857',
  action: '#5ad1c6',
  marker: '#8be07c',
  npc: '#c49bff',
};

const data: WandData = {
  palette: [
    {
      id: 'trigger',
      name: 'Triggers',
      desc: 'Wait for something a player does, then run actions.',
      entries: [
        {
          kind: 'zone',
          name: 'Zone',
          desc: 'Fires when the player walks into a rectangle of tiles.',
          icon: 'vector-square',
        },
      ],
    },
    {
      id: 'action',
      name: 'Actions',
      desc: 'What happens when a trigger fires.',
      entries: [
        {
          kind: 'message',
          name: 'Message',
          desc: 'Tells the player something.',
          icon: 'message',
        },
      ],
    },
    {
      id: 'marker',
      name: 'Markers',
      desc: 'Name a spot or an object.',
      entries: [
        { kind: 'marker', name: 'Marker', desc: 'Names a spot.', icon: 'x' },
      ],
    },
  ],
  presets: [
    {
      id: 'guide',
      name: 'Guide',
      desc: 'A friendly guide who can talk and point.',
      icon: 'person-chalkboard',
    },
  ],
  colors,
  creative: true,
  mode: 'place',
  selected_kind: 'message',
  selected_preset: 'guide',
  objects: [
    {
      ref: '[0x1]',
      id: 'enter_lab',
      kind: 'zone',
      kind_name: 'Zone',
      category: 'trigger',
      icon: 'vector-square',
      summary: '3x2 tiles, runs hello',
      x: 10,
      y: 12,
      z: 2,
      refs: ['hello'],
      issues: ['Nothing has the id "hello".'],
      actions: ['hello'],
      starts: 'start',
      after: null,
    },
  ],
  warnings: [
    {
      text: 'There is no marker with the id "start": players start at the arrivals instead.',
      ref: null,
    },
    { text: 'enter_lab: Nothing has the id "hello".', ref: '[0x1]' },
  ],
  picking: null,
  has_start: false,
  test: { running: false },
  notice: { text: 'Placed message message1.', ok: true, id: 3 },
};

afterEach(cleanup);

const show = (override: Partial<WandData> = {}) => {
  store.set(gameDataAtom, { ...data, ...override });
  act(() => render(<BabylonTutorialWand />));
};

const openTab = (name: string) => {
  act(() => {
    fireEvent.click(screen.getAllByText(name, { exact: false })[0]);
  });
};

describe('BabylonTutorialWand', () => {
  it('shows the modes and the grouped palette with descriptions', () => {
    show();
    for (const mode of ['Place', 'Configure', 'NPC', 'Delete']) {
      expect(screen.getAllByText(mode).length).toBeGreaterThan(0);
    }
    expect(screen.getByText('Triggers')).toBeDefined();
    expect(screen.getByText('Actions')).toBeDefined();
    expect(
      screen.getByText(
        'Fires when the player walks into a rectangle of tiles.',
      ),
    ).toBeDefined();
    expect(screen.getByText('Placed message message1.')).toBeDefined();
  });

  it('has no area tools: Select moved to the world-edit wand', () => {
    show();
    expect(screen.queryByText('Select')).toBeNull();
    expect(screen.queryByText('Copy selection')).toBeNull();
    expect(screen.getByText(WORLD_EDIT_HINT)).toBeDefined();
    // A wand from before the split, still in Select mode, shows the palette.
    cleanup();
    show({ mode: 'select' });
    expect(screen.getByText('Triggers')).toBeDefined();
    expect(screen.queryByText('Copy selection')).toBeNull();
  });

  it('says when a tile, not a zone, is being picked', () => {
    show({ picking: { id: 'reset1', corner: 1, tile: true } });
    expect(
      screen.getByText(': click it with the wand.', { exact: false }),
    ).toBeDefined();
    cleanup();
    show({ picking: { id: 'enter_lab', corner: 2 } });
    expect(
      screen.getByText('click corner 2 of 2 with the wand.', { exact: false }),
    ).toBeDefined();
  });

  it('shows the NPC presets in NPC mode', () => {
    show({ mode: 'npc' });
    expect(screen.getByText('NPC presets')).toBeDefined();
    expect(
      screen.getByText('A friendly guide who can talk and point.'),
    ).toBeDefined();
  });

  it('lists objects with their problems and the global checks', () => {
    show();
    openTab('Overview');
    expect(screen.getByText('enter_lab')).toBeDefined();
    expect(screen.getByText('Nothing has the id "hello".')).toBeDefined();
    expect(screen.getByText('listens from the beginning')).toBeDefined();
    expect(screen.getByText('1. hello (missing)')).toBeDefined();
    expect(
      screen.getByText(
        'There is no marker with the id "start": players start at the arrivals instead.',
      ),
    ).toBeDefined();
  });

  it('offers a test run where you stand without a start marker', () => {
    show();
    openTab('Test run');
    expect(screen.getByText('Start where I stand')).toBeDefined();
    expect(screen.getByText('Start at the start marker')).toBeDefined();
  });

  it('shows a running test run with its last steps', () => {
    show({
      has_start: true,
      test: {
        running: true,
        completed: false,
        fired: 2,
        players: 2,
        listening: ['enter_lab'],
        steps: ['enter_lab>hello'],
        objective: 'Scan the patient',
      },
    });
    openTab('Test run');
    expect(screen.getByText('Stop test run')).toBeDefined();
    expect(
      screen.getByText(
        'Test run active for 2 player(s): 2 action(s) run so far.',
      ),
    ).toBeDefined();
    expect(screen.getByText('Scan the patient')).toBeDefined();
    expect(
      screen.getAllByText('enter_lab', { exact: false }).length,
    ).toBeGreaterThan(0);
    expect(screen.getByText('enter_lab → hello')).toBeDefined();
  });

  it('tells the builder which zone corner to click', () => {
    show({ picking: { id: 'enter_lab', corner: 2 } });
    expect(screen.getByText('Cancel')).toBeDefined();
    expect(screen.getByText('enter_lab')).toBeDefined();
  });

  it('explains how to start while nothing is placed', () => {
    show({ objects: [] });
    expect(
      screen.getByText(
        'A tutorial is triggers (when…) that run actions (do…).',
      ),
    ).toBeDefined();
  });

  it('groups the flow and counts each problem once', () => {
    expect(
      buildFlow([
        { ...data.objects[0], actions: ['msg'] },
        {
          ...data.objects[0],
          ref: '[0x2]',
          id: 'msg',
          category: 'action',
          actions: null,
        },
        {
          ...data.objects[0],
          ref: '[0x3]',
          id: 'lonely',
          category: 'action',
          actions: null,
        },
      ]).unused.map((object) => object.id),
    ).toEqual(['lonely']);
    show();
    expect(screen.getByText('Overview (1)', { exact: false })).toBeDefined();
  });

  it('warns outside creative worlds', () => {
    show({ creative: false });
    expect(
      screen.getByText('The tutorial wand only works in creative worlds.'),
    ).toBeDefined();
  });

  it('shows gates with their three action lists in the flow', () => {
    show({ objects: [gate] });
    openTab('Overview');
    expect(screen.getByText('On true:')).toBeDefined();
    expect(screen.getByText('On change:')).toBeDefined();
    expect(screen.queryByText('On false:')).toBeNull();
    expect(screen.getByText('1. bell (missing)')).toBeDefined();
    expect(screen.getByText('1. tally (missing)')).toBeDefined();
  });

  it('shows the gates and stopped loops of a running test run', () => {
    show({
      test: {
        running: true,
        completed: false,
        fired: 0,
        players: 1,
        listening: ['both'],
        steps: [],
        gates: [
          {
            id: 'both',
            kind: 'logic_gate',
            state: true,
            value: null,
            listening: true,
            stopped: false,
          },
          {
            id: 'valves',
            kind: 'number_gate',
            state: false,
            value: 2,
            listening: true,
            stopped: true,
          },
        ],
        gate_log: [
          'loop stopped at valves: valves -> other -> valves (it was already updating in this wave).',
        ],
      },
    });
    openTab('Test run');
    expect(screen.getByText('Gates now')).toBeDefined();
    expect(screen.getByText('both: true', { exact: false })).toBeDefined();
    expect(
      screen.getByText('valves: 2 (false) — a loop was stopped here', {
        exact: false,
      }),
    ).toBeDefined();
    expect(
      screen.getByText('loop stopped at valves', { exact: false }),
    ).toBeDefined();
  });

  it('lists what actions could not do in the running test run', () => {
    show({
      test: {
        running: true,
        completed: false,
        fired: 1,
        players: 1,
        listening: [],
        steps: [],
        action_log: [
          'walk: Move NPC: Guide gave up after 60 seconds at 4, 5, 3 tiles from 7, 5 (no way through).',
        ],
      },
    });
    openTab('Test run');
    expect(screen.getByText('Actions that could not finish')).toBeDefined();
    expect(
      screen.getByText('Guide gave up after 60 seconds', { exact: false }),
    ).toBeDefined();
  });
});

const gate: TutorialObject = {
  ...data.objects[0],
  ref: '[0x9]',
  id: 'both',
  kind: 'logic_gate',
  kind_name: 'Logic gate',
  summary: 'AND from a, b',
  gate: true,
  issues: [],
  actions: ['bell'],
  actions_false: [],
  actions_change: ['tally'],
};

describe('tutorial wand helpers', () => {
  it("counts a gate's On false and On change actions as used", () => {
    const flow = buildFlow([
      { ...gate, actions: [], actions_false: ['off'], actions_change: ['on'] },
      { ...gate, ref: '[0xa]', id: 'off', kind: 'message', category: 'action' },
      { ...gate, ref: '[0xb]', id: 'on', kind: 'message', category: 'action' },
    ]);
    expect(flow.unused).toEqual([]);
    expect(flow.usedBy.off).toEqual(['both']);
    expect(allActions({ ...gate, actions_change: ['bell'] })).toEqual(['bell']);
  });

  it("counts an action's follow-ups (Move NPC's On arrival) as used", () => {
    const flow = buildFlow([
      { ...gate, actions: ['walk'], actions_false: [], actions_change: [] },
      {
        ...gate,
        ref: '[0xc]',
        id: 'walk',
        kind: 'move_npc',
        category: 'action',
        follow_ups: ['greet'],
      },
      {
        ...gate,
        ref: '[0xd]',
        id: 'greet',
        kind: 'message',
        category: 'action',
      },
    ]);
    expect(flow.unused).toEqual([]);
    expect(flow.usedBy.greet).toEqual(['walk']);
  });

  it('describes gate states', () => {
    const base = {
      id: 'g',
      kind: 'number_gate',
      state: true,
      value: 3,
      listening: true,
      stopped: false,
    };
    expect(gateStateText(base)).toBe('3 (true)');
    expect(gateStateText({ ...base, value: null, state: false })).toBe('false');
    expect(gateStateText({ ...base, listening: false })).toBe(
      '3 (true), not listening',
    );
  });
});

// Reposition (spec 12 #15) and visibility (#17): the actions the Overview sends.
describe('BabylonTutorialWand view and reposition', () => {
  const sent: { action: string; params: any }[] = [];
  mock.module('../events/act', () => ({
    sendAct: (action: string, params: any = {}) => {
      sent.push({ action, params });
    },
  }));
  const marker: TutorialObject = {
    ref: '[0x2]',
    id: 'start',
    kind: 'marker',
    kind_name: 'Marker',
    category: 'marker',
    icon: 'location-dot',
    summary: 'this tile',
    x: 5,
    y: 5,
    z: 2,
    refs: [],
    issues: [],
    group: 'marker',
    hidden: true,
  };
  const viewData: Partial<WandData> = {
    objects: [{ ...data.objects[0], group: 'trigger' }, marker],
    view_groups: [
      { id: 'marker', name: 'Markers' },
      { id: 'trigger', name: 'Triggers' },
      { id: 'gate', name: 'Gates' },
      { id: 'action', name: 'Actions' },
      { id: 'npc', name: 'NPC spawners' },
    ],
    hidden_count: 1,
  };
  // An Overview row: the id in bold next to the row's Settings button.
  const rowOf = (id: string) =>
    screen
      .getAllByText(id)
      .filter((node) => node.tagName === 'B')
      .map((node) => node.parentElement?.parentElement?.parentElement)
      .find((row) => row?.querySelector('.Button .fa-sliders')) as HTMLElement;
  const iconButton = (row: HTMLElement, icon: string) =>
    row.querySelector(`.Button .fa-${icon}`)?.closest('.Button') as HTMLElement;
  const last = () => sent[sent.length - 1];

  it('labels hidden objects and toggles one object', () => {
    show(viewData);
    openTab('Overview');
    const row = rowOf('start');
    expect(row.textContent).toContain('hidden');
    expect(rowOf('enter_lab').textContent).not.toContain('hidden');
    act(() => {
      fireEvent.click(iconButton(row, 'eye-slash'));
    });
    expect(last()).toEqual({
      action: 'visibility',
      params: { ref: '[0x2]', hidden: false },
    });
    act(() => {
      fireEvent.click(iconButton(rowOf('enter_lab'), 'eye'));
    });
    expect(last()).toEqual({
      action: 'visibility',
      params: { ref: '[0x1]', hidden: true },
    });
  });

  it('has group buttons that hide or show a whole group', () => {
    show(viewData);
    openTab('Overview');
    // Only groups with members get a button; counts show what is hidden.
    const markers = screen.getByText('Markers (1 of 1 hidden)', {
      exact: false,
    });
    const triggers = screen.getByText('Triggers (1)', { exact: false });
    expect(screen.queryByText('Gates', { exact: false })).toBeNull();
    act(() => {
      fireEvent.click(markers);
    });
    expect(last()).toEqual({
      action: 'group_visibility',
      params: { group: 'marker', hidden: false },
    });
    act(() => {
      fireEvent.click(triggers);
    });
    expect(last()).toEqual({
      action: 'group_visibility',
      params: { group: 'trigger', hidden: true },
    });
    act(() => {
      fireEvent.click(screen.getByText('Show all (1 hidden)'));
    });
    expect(last().action).toBe('show_all');
    expect(groupMembers(viewData.objects || [], 'marker')).toEqual([marker]);
  });

  it('arms a reposition and shows the armed state clearly', () => {
    show(viewData);
    openTab('Overview');
    act(() => {
      fireEvent.click(iconButton(rowOf('enter_lab'), 'up-down-left-right'));
    });
    expect(last()).toEqual({
      action: 'reposition',
      params: { ref: '[0x1]' },
    });
    cleanup();
    show({
      ...viewData,
      moving: { id: 'start', ref: '[0x2]', hidden: true },
    });
    openTab('Overview');
    // Banner over every tab, the row marked, the hidden object said to show until moved.
    expect(
      screen.getByText(': click its new tile with the wand.', {
        exact: false,
      }),
    ).toBeDefined();
    expect(
      screen.getByText('Hidden in your view: shown until it is moved.', {
        exact: false,
      }),
    ).toBeDefined();
    expect(rowOf('start').textContent).toContain('click its new tile');
    const armed = iconButton(rowOf('start'), 'up-down-left-right');
    expect(armed.className).toContain('selected');
    // Pressing it again cancels (the server toggles); so do Cancel and Escape.
    act(() => {
      fireEvent.click(armed);
    });
    expect(last()).toEqual({
      action: 'reposition',
      params: { ref: '[0x2]' },
    });
    act(() => {
      fireEvent.click(screen.getByText('Cancel'));
    });
    expect(last().action).toBe('cancel_move');
    sent.length = 0;
    act(() => {
      fireEvent.keyDown(window, { key: 'Escape' });
    });
    expect(last()?.action).toBe('cancel_move');
  });

  it('says on the test run tab that hidden objects still work', () => {
    show(viewData);
    openTab('Test run');
    expect(
      screen.getByText('1 object(s) are hidden in your wand view', {
        exact: false,
      }),
    ).toBeDefined();
    act(() => {
      fireEvent.click(screen.getByText('Show all'));
    });
    expect(last().action).toBe('show_all');
  });
});
