import { afterEach, describe, expect, it } from 'bun:test';
import { act, cleanup, render, screen } from '@testing-library/react';
import { gameDataAtom, store } from '../events/store';

import {
  BabylonTutorialObject,
  defaultEffect,
  defaultGateInput,
  effectNeeds,
  eventChoices,
  type Field,
  fieldActive,
  gateLiveText,
  idChoices,
  liveCopyWarning,
  type ObjectData,
  operationTakesValue,
  selectionText,
  storeBlocked,
} from './BabylonTutorialObject';

const schema: Field[] = [
  {
    key: 'text',
    label: 'Text',
    type: 'longtext',
    default: '',
    help: 'What to say.',
    required: true,
  },
  {
    key: 'style',
    label: 'Style',
    type: 'choice',
    default: 'chat',
    help: null,
    options: [
      { value: 'chat', label: 'Guide box in chat' },
      { value: 'speaker', label: 'Spoken by a speaker' },
    ],
  },
  {
    key: 'speaker',
    label: 'Speaker',
    type: 'id',
    default: '',
    help: 'Who speaks.',
    filter: ['npc', 'marker'],
    when: { style: ['speaker'] },
  },
  {
    key: 'delay',
    label: 'Delay (seconds)',
    type: 'number',
    default: 0,
    help: null,
    min: 0,
    max: 600,
  },
];

const base: ObjectData = {
  kind: 'message',
  kind_name: 'Message',
  kind_desc: 'Tells the player something.',
  category: 'action',
  icon: 'message',
  color: '#5ad1c6',
  schema,
  effect_kinds: [
    { value: 'brute', label: 'Brute damage' },
    { value: 'wound', label: 'Wound' },
  ],
  body_zones: [{ value: 'chest', label: 'Chest' }],
  wounds: [{ value: '/datum/wound/x', label: 'Hairline fracture' }],
  diseases: [{ value: '/datum/disease/cold', label: 'The Cold' }],
  reagents: [
    { value: '/datum/reagent/medicine/epinephrine', label: 'Epinephrine' },
  ],
  new_actions: [{ value: 'message', label: 'Message' }],
  id_help: 'Triggers list this id to run it.',
  id: 'hello',
  values: { text: 'Hi [player]!', style: 'chat', speaker: '', delay: 0 },
  issues: {},
  ids: [
    {
      id: 'guide1',
      kind_name: 'NPC spawner',
      category: 'npc',
      summary: 'Guide',
    },
    {
      id: 'enter',
      kind_name: 'Zone',
      category: 'trigger',
      summary: 'runs hello',
    },
  ],
  position: { x: 4, y: 5, z: 2 },
  summary: '"Hi [player]!"',
  search: null,
  notice: null,
  picking: false,
};

afterEach(cleanup);

const show = (override: Partial<ObjectData> = {}) => {
  store.set(gameDataAtom, { ...base, ...override });
  act(() => render(<BabylonTutorialObject />));
};

describe('BabylonTutorialObject', () => {
  it('builds the form from the schema and hides inactive fields', () => {
    show();
    expect(screen.getByText('Message')).toBeDefined();
    expect(screen.getByText('Text:')).toBeDefined();
    expect(screen.getByText('Style:')).toBeDefined();
    expect(screen.queryByText('Speaker:')).toBeNull();
    expect(screen.getByText('Preview')).toBeDefined();
  });

  it('shows the speaker field and its problem when the style needs it', () => {
    show({
      values: { ...base.values, style: 'speaker', speaker: 'ghost' },
      issues: { speaker: 'Nothing has the id "ghost".' },
    });
    expect(screen.getByText('Speaker:')).toBeDefined();
    expect(screen.getByText('Nothing has the id "ghost".')).toBeDefined();
  });

  it('shows a refused value next to its field', () => {
    show({
      notice: { text: 'Enter a number.', ok: false, id: 2, key: 'delay' },
    });
    expect(screen.getByText('Enter a number.')).toBeDefined();
    expect(screen.getByText('Triggers list this id to run it.')).toBeDefined();
  });

  it('marks a missing id and lists other objects with summaries', () => {
    show({
      values: { ...base.values, style: 'speaker', speaker: 'ghost' },
    });
    // Shown once, in the picker itself (the issue line explains it).
    expect(screen.getAllByPlaceholderText('ghost (missing)').length).toBe(1);
    expect(screen.queryByText('ghost (missing)')).toBeNull();
  });

  it("lists a trigger's actions by summary", () => {
    show({
      kind: 'zone',
      kind_name: 'Zone',
      category: 'trigger',
      schema: [
        {
          key: 'actions',
          label: 'Actions',
          type: 'idlist',
          default: [],
          help: null,
          filter: ['action'],
        },
      ],
      ids: [
        {
          id: 'hello',
          kind_name: 'Message',
          category: 'action',
          summary: '"Hi"',
        },
      ],
      values: { actions: ['hello'] },
    });
    expect(screen.getByText('hello — Message: "Hi"')).toBeDefined();
  });

  it('shows the NPC section for spawners', () => {
    show({
      kind: 'npc_spawner',
      kind_name: 'NPC spawner',
      category: 'npc',
      schema: [],
      npc: { name: 'Patient', health: 60, stat: 'awake', outdated: true },
    });
    expect(screen.getByText('Respawn now')).toBeDefined();
    expect(
      screen.getByText('Settings changed: press Respawn now to apply them.'),
    ).toBeDefined();
    expect(screen.getByText('Patient')).toBeDefined();
  });

  it('says when the object is gone', () => {
    show({ missing: true });
    expect(
      screen.getByText('This tutorial object no longer exists.'),
    ).toBeDefined();
  });
});

describe('tutorial object helpers', () => {
  it('evaluates when-conditions', () => {
    expect(fieldActive(schema[2], { style: 'speaker' })).toBe(true);
    expect(fieldActive(schema[2], { style: 'chat' })).toBe(false);
    expect(fieldActive(schema[0], {})).toBe(true);
  });

  it('offers only ids of the allowed categories', () => {
    expect(idChoices(schema[2], base.ids).map((entry) => entry.id)).toEqual([
      'guide1',
    ]);
  });

  it('gives new effects sensible defaults', () => {
    expect(defaultEffect('brute', base)).toEqual({
      kind: 'brute',
      chance: 100,
      amount: 20,
      zone: 'chest',
    });
    expect(defaultEffect('wound', base).type).toBe('/datum/wound/x');
    expect(effectNeeds('disease')).toEqual({
      amount: false,
      zone: false,
      wound: false,
      disease: true,
      reagent: false,
    });
  });
});

const gateInputs: Field = {
  key: 'inputs',
  label: 'Inputs',
  type: 'gateinputs',
  default: [],
  help: 'Each time an input fires, its operation changes the number.',
  filter: ['trigger'],
  input_modes: true,
  options: [
    { value: 'up', label: 'Count up (+1)' },
    { value: 'add', label: 'Add' },
    { value: 'reset', label: 'Reset to the start value' },
  ],
};

const numberGate: Partial<ObjectData> = {
  kind: 'number_gate',
  kind_name: 'Number gate',
  category: 'trigger',
  schema: [
    gateInputs,
    {
      key: 'actions_change',
      label: 'On change',
      type: 'idlist',
      default: [],
      help: 'Run whenever the number changes.',
      filter: ['action'],
    },
  ],
  ids: [
    {
      id: 'valve1',
      kind: 'button',
      kind_name: 'Button',
      category: 'trigger',
      input_mode: 'latched',
    },
    {
      id: 'bonus',
      kind: 'number_gate',
      kind_name: 'Number gate',
      category: 'trigger',
    },
    { id: 'hello', kind: 'message', kind_name: 'Message', category: 'action' },
  ],
  values: {
    inputs: [
      { id: 'valve1', op: 'up', amount: 1, source: '' },
      { id: 'bonus', op: 'add', amount: 1, source: 'bonus' },
      { id: 'gone', op: 'reset', amount: 1, source: '' },
    ],
    actions_change: ['hello'],
  },
  gate: { running: true, listening: true, state: true, value: 3 },
};

describe('gate editors', () => {
  it('lists number gate inputs with their operations and values', () => {
    show(numberGate);
    expect(screen.getByText('On change:')).toBeDefined();
    expect(screen.getByText('Count up (+1)')).toBeDefined();
    expect(screen.getByText('Add')).toBeDefined();
    expect(screen.getByText("bonus's number")).toBeDefined();
    expect(screen.getByText('Reset to the start value')).toBeDefined();
    expect(screen.getAllByPlaceholderText('gone (missing)').length).toBe(1);
    expect(screen.getByText('hello — Message')).toBeDefined();
  });

  it('marks each input live, latched or gate', () => {
    show(numberGate);
    expect(
      screen.getAllByPlaceholderText(
        'valve1 — Button [latched: true once it fired]',
      ).length,
    ).toBe(1);
    cleanup();
    show({
      kind: 'logic_gate',
      kind_name: 'Logic gate',
      category: 'trigger',
      schema: [
        {
          key: 'inputs',
          label: 'Inputs',
          type: 'idlist',
          default: [],
          help: null,
          filter: ['trigger'],
          input_modes: true,
        },
      ],
      ids: [
        {
          id: 'lab',
          kind: 'zone',
          kind_name: 'Zone',
          category: 'trigger',
          input_mode: 'live',
        },
      ],
      values: { inputs: ['lab'] },
      gate: { running: false },
    });
    expect(
      screen.getByText('lab — Zone [live: true while it holds]'),
    ).toBeDefined();
  });

  it("shows the gate's state in the running test run", () => {
    show(numberGate);
    expect(screen.getByText('Number 3, condition true.')).toBeDefined();
    show({
      ...numberGate,
      gate: {
        running: true,
        listening: true,
        state: false,
        value: 2,
        stopped: 'loop stopped at bonus: bonus -> bonus',
      },
    });
    expect(
      screen.getByText('loop stopped at bonus: bonus -> bonus'),
    ).toBeDefined();
  });

  it('describes gate states and input defaults', () => {
    expect(gateLiveText({ running: false }, 'logic_gate')).toBe(
      'No test run is running.',
    );
    expect(
      gateLiveText(
        { running: true, listening: true, state: true },
        'logic_gate',
      ),
    ).toBe('Currently true.');
    expect(
      gateLiveText(
        { running: true, listening: false, state: false, value: 4 },
        'number_gate',
      ),
    ).toBe('Not listening (number 4).');
    expect(defaultGateInput('valve1')).toEqual({
      id: 'valve1',
      op: 'up',
      amount: 1,
      source: '',
    });
    expect(operationTakesValue('mul')).toBe(true);
    expect(operationTakesValue('reset')).toBe(false);
  });
});

describe('world action editors', () => {
  const inventory: Partial<ObjectData> = {
    kind: 'inventory',
    kind_name: 'Set inventory',
    category: 'action',
    schema: [
      {
        key: 'loadout',
        label: 'Loadout',
        type: 'loadout',
        default: [],
        help: null,
        base: '/obj/item',
        search: 'creative',
      },
    ],
    values: {
      loadout: [
        {
          place: 'slot:1',
          where: 'Uniform',
          name: 'medical scrubs',
          path: '/obj/item/clothing/under/rank/medical/scrubs',
          inside: 0,
        },
        {
          place: 'slot:8',
          where: 'Back',
          name: 'Field kit',
          path: '/obj/item/storage/backpack/medic',
          inside: 3,
        },
      ],
    },
    loadout_places: [
      { value: 'slot:1', label: 'Uniform' },
      { value: 'hand:1', label: 'Left hand' },
    ],
    search: {
      key: 'loadout',
      query: 'kit',
      results: [
        {
          path: '/obj/item/storage/medkit/regular',
          name: 'First-aid kit',
          hint: 'standard',
        },
      ],
    },
  };

  it('shows a stored loadout with its places, and the search like the Creative panel', () => {
    show(inventory);
    expect(screen.getByText('Store my current loadout')).toBeDefined();
    // In the list, and as the place an added item goes to.
    expect(screen.getAllByText('Uniform').length).toBe(2);
    expect(screen.getByText('medical scrubs')).toBeDefined();
    expect(screen.getByText('Field kit')).toBeDefined();
    expect(screen.getByText('(+3 inside)', { exact: false })).toBeDefined();
    expect(screen.getByText('Add an item')).toBeDefined();
    // The Creative panel's hint for same-named types is shown with each result.
    expect(
      screen.getByText('First-aid kit (standard)', { exact: false }),
    ).toBeDefined();
  });

  it('says when no loadout is stored yet', () => {
    show({ ...inventory, values: { loadout: [] }, search: null });
    expect(screen.getByText('Empty: nothing stored yet.')).toBeDefined();
  });

  it("offers the Creative panel's events by category, with a description", () => {
    const events = [
      {
        value: '/datum/round_event_control/meteor_wave',
        label: 'Meteor Wave: Normal',
        category: 'Space Threat',
        description: 'A regular meteor wave.',
      },
    ];
    show({
      kind: 'start_event',
      kind_name: 'Start event',
      category: 'action',
      schema: [
        {
          key: 'event',
          label: 'Event',
          type: 'event',
          default: '',
          help: null,
        },
      ],
      values: { event: '/datum/round_event_control/meteor_wave' },
      events,
    });
    expect(screen.getByText('A regular meteor wave.')).toBeDefined();
    expect(eventChoices(events)).toEqual([
      {
        value: '/datum/round_event_control/meteor_wave',
        label: 'Space Threat: Meteor Wave: Normal',
      },
    ]);
  });

  it('shows test run notes that belong to no field', () => {
    show({
      issues: {
        live: 'Test run: Move NPC: Guide gave up after 60 seconds.',
      },
    });
    expect(
      screen.getByText('Test run: Move NPC: Guide gave up after 60 seconds.'),
    ).toBeDefined();
  });

  describe('Paste area', () => {
    const pasteSchema: Field[] = [
      {
        key: 'mode',
        label: 'Copy from',
        type: 'choice',
        default: 'snapshot',
        help: null,
        options: [
          { value: 'snapshot', label: 'A stored snapshot (recommended)' },
          { value: 'live', label: 'A live area, copied when it runs' },
        ],
      },
      {
        key: 'snapshot',
        label: 'Stored area',
        type: 'area_clip',
        default: null,
        help: 'Select the room with the world-edit wand, then store it here.',
        when: { mode: ['snapshot'] },
      },
      {
        key: 'source',
        label: 'Source area',
        type: 'zone',
        default: null,
        help: null,
        when: { mode: ['live'] },
      },
      {
        key: 'protect',
        label: 'Protect the source',
        type: 'bool',
        default: 1,
        help: null,
        when: { mode: ['live'] },
      },
      {
        key: 'target',
        label: 'Paste at',
        type: 'tile',
        default: null,
        help: null,
      },
    ];
    const selection = {
      x1: 10,
      y1: 20,
      x2: 13,
      y2: 22,
      z: 2,
      width: 4,
      height: 3,
      tiles: 12,
      problem: null,
    };
    const paste: Partial<ObjectData> = {
      kind: 'paste_area',
      kind_name: 'Paste area',
      schema: pasteSchema,
      values: { mode: 'snapshot', snapshot: null, protect: 1, target: null },
      area_selection: selection,
    };

    it('stores the world-edit selection and shows what is stored', () => {
      show(paste);
      expect(screen.getByText('Nothing stored yet.')).toBeDefined();
      const store_button = screen
        .getByText('Store selection in this action')
        .closest('.Button');
      expect(store_button?.className).not.toContain('Button--disabled');
      expect(
        screen.getByText('Your selection: 4×3 at 10, 20 (12 tiles).'),
      ).toBeDefined();
      cleanup();
      show({
        ...paste,
        values: {
          ...paste.values,
          snapshot: {
            width: 4,
            height: 3,
            x: 10,
            y: 20,
            z: 2,
            objects: 7,
            tiles: 12,
            distinct: 3,
            bytes: 38 * 1024,
            limit: 512 * 1024,
            problem: null,
          },
          target: [30, 40, 2],
        },
      });
      expect(
        screen.getByText('tiles from (10, 20) on level 2', { exact: false }),
      ).toBeDefined();
      expect(screen.getByText('— 7 objects', { exact: false })).toBeDefined();
      expect(
        screen.getByText('(30, 40) on level 2', { exact: false }),
      ).toBeDefined();
      expect(screen.getByText('Pick tile')).toBeDefined();
      expect(
        screen.getByText('Stored: 12 tiles, 38 KB of the 512 KB limit.'),
      ).toBeDefined();
    });

    it('needs a selection to store, and shows an old format as an error', () => {
      expect(storeBlocked(null)).toContain('world-edit wand');
      expect(storeBlocked({ ...selection, problem: 'Too big.' })).toBe(
        'Too big.',
      );
      expect(storeBlocked(selection)).toBeNull();
      expect(selectionText(selection)).toBe('4×3 at 10, 20');
      show({
        ...paste,
        area_selection: null,
        values: {
          ...paste.values,
          snapshot: {
            width: 4,
            height: 3,
            x: 10,
            y: 20,
            z: 2,
            objects: 7,
            problem: 'This area was stored in an older format.',
          },
        },
      });
      expect(
        screen.getByText('This area was stored in an older format.'),
      ).toBeDefined();
      const store_button = screen
        .getByText('Store selection in this action')
        .closest('.Button');
      expect(store_button?.className).toContain('Button--disabled');
    });

    it('warns that a live source can change, and offers the selection as source', () => {
      const live = {
        ...paste,
        values: { mode: 'live', source: null, protect: 0, target: null },
      };
      show(live);
      expect(screen.getByText('Use my world-edit selection')).toBeDefined();
      expect(
        screen.getByText(/players can change or damage the source area/),
      ).toBeDefined();
      expect(
        liveCopyWarning({
          ...base,
          ...live,
          values: { mode: 'live', protect: 1 },
        } as ObjectData),
      ).toContain('nobody can use tools or items');
      expect(liveCopyWarning({ ...base, ...paste } as ObjectData)).toBeNull();
    });
  });
});
