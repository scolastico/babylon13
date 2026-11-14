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
  type AreaData,
  blockedReason,
  type Material,
  sizeText,
  stepHint,
} from './BabylonTutorialArea';
import { BabylonTutorialWand, type WandData } from './BabylonTutorialWand';

const materials: Material[] = [
  { path: '/turf/open/floor/iron', name: 'floor', group: 'Floors' },
  { path: '/turf/closed/wall', name: 'wall', group: 'Walls' },
  { path: '/obj/structure/grille', name: 'grille', group: 'Structures' },
];

const area: AreaData = {
  step: 'corner1',
  corner: null,
  selection: null,
  clipboard: null,
  paste: null,
  undo: null,
  busy: false,
  cooldown: 0,
  max_tiles: 10000,
  material: null,
  only_empty: false,
  skip_space: true,
  suffix_mode: 'auto',
  custom_suffix: '_b',
  clear_to: 'plating',
};

const selection = {
  x1: 10,
  y1: 20,
  x2: 21,
  y2: 27,
  z: 2,
  width: 12,
  height: 8,
  tiles: 96,
  problem: null,
  stats: { objects: 30, tutorial: 4, mobs: 1, players: 0, locked: 0 },
};

const clipboard = {
  width: 12,
  height: 8,
  objects: 30,
  tutorial: 4,
  x: 10,
  y: 20,
};

const wand: WandData = {
  palette: [],
  presets: [],
  colors: {
    trigger: '#ffc857',
    action: '#5ad1c6',
    marker: '#8be07c',
    npc: '#c49bff',
  },
  creative: true,
  mode: 'select',
  selected_kind: 'message',
  selected_preset: 'guide',
  objects: [],
  warnings: [],
  picking: null,
  has_start: true,
  test: { running: false },
  notice: null,
  materials,
  area,
};

afterEach(cleanup);

const show = (override: Partial<AreaData> = {}) => {
  store.set(gameDataAtom, { ...wand, area: { ...area, ...override } });
  act(() => render(<BabylonTutorialWand />));
};

describe('BabylonTutorialArea', () => {
  it('formats sizes like 12×8 (96 tiles)', () => {
    expect(sizeText(12, 8)).toBe('12×8 (96 tiles)');
    expect(sizeText(100, 100)).toBe('100×100 (10,000 tiles)');
    expect(sizeText(1, 1)).toBe('1×1 (1 tile)');
  });

  it('says which corner to click', () => {
    show();
    expect(screen.getByText('Select: corner 1 of 2')).toBeDefined();
    expect(
      screen.getByText('Click the first corner of an area with the wand.'),
    ).toBeDefined();
    show({ step: 'corner2', corner: { x: 4, y: 7 } });
    expect(
      screen.getByText('Corner 1 is at 4, 7. Click the opposite corner.'),
    ).toBeDefined();
    expect(screen.getByText('Cancel')).toBeDefined();
  });

  it('disables operations with a reason while nothing is selected', () => {
    show();
    const copy = screen.getByText('Copy selection').closest('.Button');
    expect(copy?.className).toContain('Button--disabled');
    expect(
      screen.getAllByText(
        'Select an area first: click two opposite corners with the wand.',
      ).length,
    ).toBeGreaterThan(0);
    expect(screen.getByText('Copy an area first.')).toBeDefined();
    expect(
      screen.getByText(
        'Nothing to undo yet. Undo takes back your last paste, fill, border or clear (one step).',
      ),
    ).toBeDefined();
  });

  it('shows the selection size and what it contains', () => {
    show({ step: 'selected', selection });
    expect(screen.getByText('12×8 (96 tiles)')).toBeDefined();
    expect(screen.getByText('Area selected')).toBeDefined();
    expect(
      screen.getByText('Contains 30 objects, 4 tutorial objects, 1 mob', {
        exact: false,
      }),
    ).toBeDefined();
    const copy = screen.getByText('Copy selection').closest('.Button');
    expect(copy?.className).not.toContain('Button--disabled');
    // Fill needs a material.
    expect(
      screen.getByText('Pick a floor, wall or structure below first.'),
    ).toBeDefined();
  });

  it('names the picked material on Fill and Border', () => {
    show({ step: 'selected', selection, material: '/turf/closed/wall' });
    expect(screen.getByText('Fill with wall')).toBeDefined();
    expect(screen.getByText('Border of wall')).toBeDefined();
  });

  it('explains the paste corner and the id suffix', () => {
    show({
      step: 'paste_target',
      selection,
      clipboard,
      paste: { target: null, problem: null, suffix: '_2' },
    });
    expect(
      screen.getAllByText(/bottom-left \(south-west\) corner/).length,
    ).toBeGreaterThan(0);
    expect(screen.getByText('Auto (_2)')).toBeDefined();
    const confirm = screen.getByText('Confirm paste').closest('.Button');
    expect(confirm?.className).toContain('Button--disabled');
  });

  it('shows the paste footprint with confirm and refusals', () => {
    show({
      step: 'paste_confirm',
      clipboard,
      paste: {
        target: { x1: 30, y1: 20, x2: 41, y2: 27 },
        problem: null,
        suffix: '_2',
      },
    });
    expect(screen.getByText('30, 20')).toBeDefined();
    expect(screen.getByText('41, 27')).toBeDefined();
    const confirm = screen.getByText('Confirm paste').closest('.Button');
    expect(confirm?.className).not.toContain('Button--disabled');
    cleanup();
    show({
      step: 'paste_confirm',
      clipboard,
      paste: {
        target: { x1: 250, y1: 20, x2: 261, y2: 27 },
        problem: 'The copy (12×8 (96 tiles)) does not fit there.',
        suffix: '_2',
      },
    });
    expect(
      screen.getAllByText('The copy (12×8 (96 tiles)) does not fit there.')
        .length,
    ).toBeGreaterThan(0);
  });

  it('asks before clearing and says what goes', () => {
    show({ step: 'selected', selection });
    act(() => {
      fireEvent.click(screen.getByText('Clear selection'));
    });
    expect(
      screen.getByText('Remove 30 objects, 1 mob and 4 tutorial objects?'),
    ).toBeDefined();
  });

  it('filters the material list', () => {
    show({ step: 'selected', selection });
    expect(screen.getByText('grille')).toBeDefined();
    expect(screen.getByText('Structures')).toBeDefined();
  });

  it('waits out the cooldown', () => {
    expect(
      blockedReason(
        { ...area, selection, cooldown: 1.5 },
        { selection: true },
        materials,
      ),
    ).toBe('One area operation every 2 seconds: wait a moment.');
    expect(stepHint({ ...area, step: 'paste_confirm' })).toContain('confirm');
  });
});
