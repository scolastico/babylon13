import { afterEach, describe, expect, it } from 'bun:test';
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
  type TutorialObject,
  type WandData,
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
