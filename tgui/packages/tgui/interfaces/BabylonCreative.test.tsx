import { describe, expect, it } from 'bun:test';
import { act, fireEvent, render, screen } from '@testing-library/react';
import { gameDataAtom, store } from '../events/store';

import { BabylonCreative, type CreativeData } from './BabylonCreative';

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
    expect(screen.getByText('Heal fully')).toBeDefined();
    expect(screen.getByText('Godmode on: nothing can hurt you.')).toBeDefined();
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
    openTab('Tutorial');
    expect(screen.getByText('This tab is not available yet.')).toBeDefined();
  });
});
