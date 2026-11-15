import { afterEach, describe, expect, it } from 'bun:test';
import { act, cleanup, render, screen } from '@testing-library/react';
import { gameDataAtom, store } from '../events/store';

import {
  BabylonTutorialObject,
  defaultEffect,
  defaultGateInput,
  effectNeeds,
  type Field,
  fieldActive,
  gateLiveText,
  idChoices,
  type ObjectData,
  operationTakesValue,
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
    { id: 'valve1', kind: 'button', kind_name: 'Button', category: 'trigger' },
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
