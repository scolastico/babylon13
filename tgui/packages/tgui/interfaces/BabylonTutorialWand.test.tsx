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
  BabylonTutorialWand,
  buildFlow,
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
      desc: 'Wait for something the player does, then run actions.',
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
        listening: ['enter_lab'],
        steps: ['enter_lab>hello'],
        objective: 'Scan the patient',
      },
    });
    openTab('Test run');
    expect(screen.getByText('Stop test run')).toBeDefined();
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
});
