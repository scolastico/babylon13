// Babylon Creative panel (opened by modular_babylon/code/creative/panel.dm).
// Every action is checked again on the server; this window only shows and asks.
// Tabs come from the server (panel.dm, /datum/babylon_creative_panel/proc/tabs); a module that
// adds a tab there registers its component in CREATIVE_TABS below.
import { type ComponentType, useEffect, useState } from 'react';
import {
  Box,
  Button,
  DmIcon,
  Dropdown,
  Icon,
  Input,
  LabeledList,
  NoticeBox,
  NumberInput,
  ProgressBar,
  Section,
  Stack,
  Tabs,
} from 'tgui-core/components';
import { createSearch } from 'tgui-core/string';

import { useBackend } from '../backend';
import { Window } from '../layouts';

type Tab = { id: string; name: string; icon: string };

type Entry = {
  path: string;
  name: string;
  icon: string;
  icon_state: string;
  stack: boolean;
  max: number;
  item: boolean;
};

type Category = { id: string; name: string; icon: string; entries: Entry[] };
type Level = { z: number; name: string };
type AreaEntry = { path: string; name: string; z: number };
type Player = { ckey: string; name: string; z: number };
type Marker = { id: string; x: number; y: number; z: number };
type EventEntry = {
  path: string;
  name: string;
  description: string;
  category: string;
};

export type CreativeData = {
  tabs: Tab[];
  categories: Category[];
  levels: Level[];
  areas: AreaEntry[];
  events: EventEntry[];
  wand_available: boolean;
  show_markers: boolean;
  map_size: { x: number; y: number };
  limits: {
    spawns: number;
    spawn_window: number;
    copies: number;
    events: number;
    event_window: number;
  };
  godmode: boolean;
  godmode_elsewhere: boolean;
  noclip: boolean;
  dead: boolean;
  health: number;
  body: string;
  position: { x: number; y: number; z: number; area: string } | null;
  players: Player[];
  markers: Marker[];
  search: { query: string; category: string; results: Entry[] };
  spawns_left: number;
  events_left: number;
  notice: { text: string; ok: boolean; id: number } | null;
  extensions: Record<string, unknown>;
};

/** Tab id -> component. Tabs the server lists without an entry here show a placeholder. */
export const CREATIVE_TABS: Record<string, ComponentType> = {
  self: SelfTab,
  spawn: SpawnTab,
  teleport: TeleportTab,
  events: EventsTab,
  tools: ToolsTab,
};

export const BabylonCreative = () => {
  const { data } = useBackend<CreativeData>();
  const tabs = data.tabs || [];
  const [tab, setTab] = useState(tabs[0]?.id || 'self');
  const Content = CREATIVE_TABS[tab];

  return (
    <Window width={600} height={680} title="Creative">
      <Window.Content>
        <Stack fill vertical>
          <Stack.Item>
            <Tabs fluid>
              {tabs.map((entry) => (
                <Tabs.Tab
                  key={entry.id}
                  icon={entry.icon}
                  selected={entry.id === tab}
                  onClick={() => setTab(entry.id)}
                >
                  {entry.name}
                </Tabs.Tab>
              ))}
            </Tabs>
          </Stack.Item>
          <Stack.Item grow basis={0} style={{ overflowY: 'auto' }}>
            {Content ? (
              <Content />
            ) : (
              <NoticeBox info>This tab is not available yet.</NoticeBox>
            )}
          </Stack.Item>
          <Stack.Item>
            <Notice />
          </Stack.Item>
        </Stack>
      </Window.Content>
    </Window>
  );
};

/** The last action's outcome; fades after a few seconds. */
const Notice = () => {
  const { data } = useBackend<CreativeData>();
  const { notice } = data;
  const [hiddenId, setHiddenId] = useState(-1);
  useEffect(() => {
    if (!notice) {
      return;
    }
    const timer = setTimeout(() => setHiddenId(notice.id), 6000);
    return () => clearTimeout(timer);
  }, [notice?.id]);
  if (!notice || notice.id === hiddenId) {
    return null;
  }
  const content = (
    <Stack align="center">
      <Stack.Item>
        <Icon name={notice.ok ? 'check' : 'triangle-exclamation'} />
      </Stack.Item>
      <Stack.Item grow>{notice.text}</Stack.Item>
      <Stack.Item>
        <Button
          icon="xmark"
          color="transparent"
          tooltip="Dismiss"
          onClick={() => setHiddenId(notice.id)}
        />
      </Stack.Item>
    </Stack>
  );
  return notice.ok ? (
    <NoticeBox success mb={0}>
      {content}
    </NoticeBox>
  ) : (
    <NoticeBox danger mb={0}>
      {content}
    </NoticeBox>
  );
};

// ---------------------------------------------------------------- Self

function SelfTab() {
  const { act, data } = useBackend<CreativeData>();
  const { godmode, godmode_elsewhere, noclip, dead, health, body, position } =
    data;
  return (
    <>
      <Section title="You">
        <LabeledList>
          <LabeledList.Item label="Body">{body}</LabeledList.Item>
          <LabeledList.Item label="Condition">
            {dead ? (
              <Box color="bad" bold>
                Dead
              </Box>
            ) : (
              <ProgressBar
                value={Math.max(health, 0)}
                minValue={0}
                maxValue={100}
                ranges={{
                  good: [70, Infinity],
                  average: [30, 70],
                  bad: [-Infinity, 30],
                }}
              >
                {health}%
              </ProgressBar>
            )}
          </LabeledList.Item>
          <LabeledList.Item label="Position">
            {position
              ? `${position.area} (${position.x}, ${position.y}, ${position.z})`
              : 'Unknown'}
          </LabeledList.Item>
        </LabeledList>
      </Section>
      <Section title="Powers">
        <Stack vertical>
          <PowerToggle
            icon="shield-halved"
            name="Godmode"
            enabled={godmode}
            description={
              godmode_elsewhere
                ? 'You are already invulnerable from another source.'
                : 'Nothing can hurt or kill you: no damage, no breathing, no pressure.'
            }
            onToggle={() => act('godmode')}
          />
          <PowerToggle
            icon="ghost"
            name="Noclip"
            enabled={noclip}
            description="Move through walls, machines and anything else. Turning it off moves you out of any wall to the nearest free spot."
            onToggle={() => act('noclip')}
          />
        </Stack>
      </Section>
      <Section title="Health">
        <Stack align="center">
          <Stack.Item grow color="label">
            {dead
              ? 'Bring your body back to life, fully healed.'
              : 'Heal every wound, ailment and missing part.'}
          </Stack.Item>
          <Stack.Item>
            <Button
              icon={dead ? 'heart-pulse' : 'kit-medical'}
              color={dead ? 'good' : undefined}
              onClick={() => act('heal')}
            >
              {dead ? 'Revive' : 'Heal fully'}
            </Button>
          </Stack.Item>
        </Stack>
      </Section>
    </>
  );
}

type PowerToggleProps = {
  icon: string;
  name: string;
  enabled: boolean;
  description: string;
  onToggle: () => void;
};

function PowerToggle(props: PowerToggleProps) {
  const { icon, name, enabled, description, onToggle } = props;
  return (
    <Stack.Item>
      <Stack align="center">
        <Stack.Item width="2.5em" textAlign="center">
          <Icon name={icon} size={1.6} color={enabled ? 'good' : 'label'} />
        </Stack.Item>
        <Stack.Item grow>
          <Box bold>{name}</Box>
          <Box color="label">{description}</Box>
        </Stack.Item>
        <Stack.Item>
          <Button
            width="5.5em"
            textAlign="center"
            icon={enabled ? 'toggle-on' : 'toggle-off'}
            color={enabled ? 'good' : 'default'}
            selected={enabled}
            onClick={onToggle}
          >
            {enabled ? 'On' : 'Off'}
          </Button>
        </Stack.Item>
      </Stack>
    </Stack.Item>
  );
}

// ---------------------------------------------------------------- Spawn

function SpawnTab() {
  const { act, data } = useBackend<CreativeData>();
  const { categories = [], search, spawns_left, limits } = data;
  const [query, setQuery] = useState(search?.query || '');
  const [category, setCategory] = useState(search?.category || 'all');
  const [inHand, setInHand] = useState(true);
  const [amount, setAmount] = useState(1);
  const searching = query.trim().length >= 2;

  const runSearch = (nextQuery: string, nextCategory: string) => {
    if (nextQuery.trim().length >= 2) {
      act('search', { query: nextQuery, category: nextCategory });
    }
  };

  const shown = categories.filter(
    (entry) => category === 'all' || entry.id === category,
  );
  const answered =
    search && search.query === query.trim() && search.category === category;
  const spawn = (entry: Entry) =>
    act('spawn', {
      path: entry.path,
      amount: entry.stack
        ? Math.min(amount, entry.max)
        : Math.min(amount, limits.copies),
      in_hand: entry.item && inHand ? 1 : 0,
    });

  return (
    <>
      <Section>
        <Stack vertical>
          <Stack.Item>
            <Input
              fluid
              autoFocus
              expensive={300}
              value={query}
              placeholder="Search everything that can be spawned (name or type path)"
              onChange={(value) => {
                setQuery(value);
                runSearch(value, category);
              }}
            />
          </Stack.Item>
          <Stack.Item>
            <Box style={{ display: 'flex', flexWrap: 'wrap', gap: '0.25em' }}>
              <Button
                icon="layer-group"
                selected={category === 'all'}
                onClick={() => {
                  setCategory('all');
                  runSearch(query, 'all');
                }}
              >
                All
              </Button>
              {categories.map((entry) => (
                <Button
                  key={entry.id}
                  icon={entry.icon}
                  selected={category === entry.id}
                  onClick={() => {
                    setCategory(entry.id);
                    runSearch(query, entry.id);
                  }}
                >
                  {entry.name}
                </Button>
              ))}
            </Box>
          </Stack.Item>
          <Stack.Item>
            <Stack align="center">
              <Stack.Item color="label">Put it</Stack.Item>
              <Stack.Item>
                <Button
                  icon="hand"
                  selected={inHand}
                  tooltip="Items go into your hands; everything else lands at your feet."
                  onClick={() => setInHand(true)}
                >
                  In hand
                </Button>
                <Button
                  icon="shoe-prints"
                  selected={!inHand}
                  onClick={() => setInHand(false)}
                >
                  At my feet
                </Button>
              </Stack.Item>
              <Stack.Item ml={1} color="label">
                Amount
              </Stack.Item>
              <Stack.Item>
                <NumberInput
                  width="4em"
                  minValue={1}
                  maxValue={50}
                  step={1}
                  value={amount}
                  onChange={(value) => setAmount(Math.round(value))}
                />
              </Stack.Item>
              <Stack.Item grow textAlign="right" color="label">
                <Icon name="gauge" mr={0.5} />
                {spawns_left}/{limits.spawns} per {limits.spawn_window}s
              </Stack.Item>
            </Stack>
            <Box color="label" mt={0.5} fontSize="0.9em">
              Stacks spawn as one stack of the amount (up to a full stack);
              anything else spawns that many copies, at most {limits.copies}.
            </Box>
          </Stack.Item>
        </Stack>
      </Section>
      {searching ? (
        <Section
          title={
            answered
              ? `Results for "${query.trim()}"`
              : `Searching for "${query.trim()}"...`
          }
        >
          {answered && !search.results.length && (
            <NoticeBox>
              Nothing matches. Try another word or the type path, or pick "All".
            </NoticeBox>
          )}
          {answered && <EntryList entries={search.results} onSpawn={spawn} />}
        </Section>
      ) : (
        shown.map((entry) => (
          <Section
            key={entry.id}
            title={
              <>
                <Icon name={entry.icon} mr={1} />
                {entry.name}
              </>
            }
          >
            {entry.entries.length ? (
              <EntryList entries={entry.entries} onSpawn={spawn} />
            ) : (
              <Box color="label">Nothing here yet.</Box>
            )}
          </Section>
        ))
      )}
    </>
  );
}

type EntryListProps = { entries: Entry[]; onSpawn: (entry: Entry) => void };

function EntryList(props: EntryListProps) {
  const { entries, onSpawn } = props;
  return (
    <Box
      style={{
        display: 'grid',
        gridTemplateColumns: 'repeat(auto-fill, minmax(16em, 1fr))',
        gap: '0.25em',
      }}
    >
      {entries.map((entry) => (
        <Button
          key={entry.path}
          fluid
          color="transparent"
          tooltip={entry.path}
          tooltipPosition="bottom"
          onClick={() => onSpawn(entry)}
        >
          <Stack align="center">
            <Stack.Item>
              <DmIcon
                icon={entry.icon}
                icon_state={entry.icon_state}
                width="32px"
                height="32px"
                fallback={<Icon name="cube" size={1.5} color="label" />}
              />
            </Stack.Item>
            <Stack.Item
              grow
              style={{
                overflow: 'hidden',
                textOverflow: 'ellipsis',
                whiteSpace: 'nowrap',
              }}
            >
              {entry.name}
              {entry.stack && (
                <Box inline color="label" ml={0.5}>
                  (stack of {entry.max})
                </Box>
              )}
            </Stack.Item>
          </Stack>
        </Button>
      ))}
    </Box>
  );
}

// ---------------------------------------------------------------- Teleport

function TeleportTab() {
  const { act, data } = useBackend<CreativeData>();
  const {
    levels = [],
    areas = [],
    players = [],
    markers = [],
    show_markers,
    position,
    map_size,
    noclip,
  } = data;
  const [x, setX] = useState(position?.x || 1);
  const [y, setY] = useState(position?.y || 1);
  const [z, setZ] = useState(position?.z || levels[0]?.z || 1);
  const [areaQuery, setAreaQuery] = useState('');
  const levelName = (level: number) =>
    levels.find((entry) => entry.z === level)?.name || `Level ${level}`;
  const matches = areas.filter(
    createSearch(areaQuery, (entry: AreaEntry) => entry.name),
  );

  return (
    <>
      {!noclip && (
        <NoticeBox info>
          Without noclip you land on the nearest free spot, never inside a wall.
        </NoticeBox>
      )}
      <Section
        title="Coordinates"
        buttons={
          <Button
            icon="crosshairs"
            disabled={!position}
            onClick={() => {
              if (position) {
                setX(position.x);
                setY(position.y);
                setZ(position.z);
              }
            }}
          >
            Use my position
          </Button>
        }
      >
        <Stack align="center">
          <Stack.Item color="label">X</Stack.Item>
          <Stack.Item>
            <NumberInput
              width="4.5em"
              minValue={1}
              maxValue={map_size.x}
              step={1}
              value={x}
              onChange={(value) => setX(Math.round(value))}
            />
          </Stack.Item>
          <Stack.Item color="label">Y</Stack.Item>
          <Stack.Item>
            <NumberInput
              width="4.5em"
              minValue={1}
              maxValue={map_size.y}
              step={1}
              value={y}
              onChange={(value) => setY(Math.round(value))}
            />
          </Stack.Item>
          <Stack.Item color="label">Level</Stack.Item>
          <Stack.Item grow>
            <Dropdown
              width="100%"
              selected={`${z}`}
              displayText={`${levelName(z)} (${z})`}
              options={levels.map((level) => ({
                value: `${level.z}`,
                displayText: `${level.name} (${level.z})`,
              }))}
              onSelected={(value) => setZ(Number(value))}
            />
          </Stack.Item>
          <Stack.Item>
            <Button
              icon="location-arrow"
              onClick={() => act('teleport_coords', { x, y, z })}
            >
              Teleport
            </Button>
          </Stack.Item>
        </Stack>
      </Section>
      <Section title="Players in this world">
        {players.length ? (
          <Stack vertical>
            {players.map((player) => (
              <Stack.Item key={player.ckey}>
                <Stack align="center">
                  <Stack.Item grow>
                    <Icon name="user" mr={1} color="label" />
                    {player.name}
                    <Box inline color="label" ml={1}>
                      {levelName(player.z)}
                    </Box>
                  </Stack.Item>
                  <Stack.Item>
                    <Button
                      icon="location-arrow"
                      onClick={() =>
                        act('teleport_player', { ckey: player.ckey })
                      }
                    >
                      Go to
                    </Button>
                  </Stack.Item>
                </Stack>
              </Stack.Item>
            ))}
          </Stack>
        ) : (
          <Box color="label">Nobody else is in this world right now.</Box>
        )}
      </Section>
      {!!show_markers && (
        <Section title="Tutorial markers">
          {markers.length ? (
            <Stack vertical>
              {markers.map((marker) => (
                <Stack.Item key={marker.id}>
                  <Stack align="center">
                    <Stack.Item grow>
                      <Icon name="flag" mr={1} color="label" />
                      {marker.id}
                      <Box inline color="label" ml={1}>
                        ({marker.x}, {marker.y}, {marker.z})
                      </Box>
                    </Stack.Item>
                    <Stack.Item>
                      <Button
                        icon="location-arrow"
                        onClick={() =>
                          act('teleport_marker', { id: marker.id })
                        }
                      >
                        Go to
                      </Button>
                    </Stack.Item>
                  </Stack>
                </Stack.Item>
              ))}
            </Stack>
          ) : (
            <Box color="label">No tutorial markers placed yet.</Box>
          )}
        </Section>
      )}
      <Section title="Areas">
        <Input
          fluid
          value={areaQuery}
          placeholder={`Search ${areas.length} areas`}
          onChange={setAreaQuery}
        />
        <Stack vertical mt={0.5}>
          {matches.slice(0, 60).map((entry) => (
            <Stack.Item key={`${entry.path}-${entry.z}`}>
              <Stack align="center">
                <Stack.Item grow>
                  {entry.name}
                  {levels.length > 1 && (
                    <Box inline color="label" ml={1}>
                      {levelName(entry.z)}
                    </Box>
                  )}
                </Stack.Item>
                <Stack.Item>
                  <Button
                    icon="location-arrow"
                    onClick={() =>
                      act('teleport_area', { path: entry.path, z: entry.z })
                    }
                  >
                    Go to
                  </Button>
                </Stack.Item>
              </Stack>
            </Stack.Item>
          ))}
          {matches.length > 60 && (
            <Stack.Item color="label">
              {matches.length - 60} more; type to narrow the list.
            </Stack.Item>
          )}
          {!matches.length && (
            <Stack.Item color="label">No area matches.</Stack.Item>
          )}
        </Stack>
      </Section>
    </>
  );
}

// ---------------------------------------------------------------- Events

function EventsTab() {
  const { act, data } = useBackend<CreativeData>();
  const { events = [], events_left, limits } = data;
  const [query, setQuery] = useState('');
  const matches = events.filter(
    createSearch(
      query,
      (entry: EventEntry) => `${entry.name} ${entry.description}`,
    ),
  );
  const groups: Record<string, EventEntry[]> = {};
  for (const entry of matches) {
    if (!groups[entry.category]) {
      groups[entry.category] = [];
    }
    groups[entry.category].push(entry);
  }

  return (
    <>
      <NoticeBox>
        Events hit the whole world, other players in it included. Up to{' '}
        {limits.events} every {limits.event_window} seconds: {events_left} left.
      </NoticeBox>
      <Section>
        <Input
          fluid
          value={query}
          placeholder={`Search ${events.length} events`}
          onChange={setQuery}
        />
      </Section>
      {Object.keys(groups)
        .sort()
        .map((category) => (
          <Section key={category} title={category}>
            <Stack vertical>
              {groups[category].map((entry) => (
                <Stack.Item key={entry.path}>
                  <Stack align="center">
                    <Stack.Item grow>
                      <Box bold>{entry.name}</Box>
                      {!!entry.description && (
                        <Box color="label">{entry.description}</Box>
                      )}
                    </Stack.Item>
                    <Stack.Item>
                      <Button.Confirm
                        icon="play"
                        width="5.5em"
                        textAlign="center"
                        disabled={!events_left}
                        confirmContent="Sure?"
                        confirmIcon="bolt"
                        onClick={() => act('run_event', { path: entry.path })}
                      >
                        Run
                      </Button.Confirm>
                    </Stack.Item>
                  </Stack>
                </Stack.Item>
              ))}
            </Stack>
          </Section>
        ))}
      {!matches.length && (
        <Section>
          <Box color="label">No event matches.</Box>
        </Section>
      )}
    </>
  );
}

// ---------------------------------------------------------------- Tools

function ToolsTab() {
  const { act, data } = useBackend<CreativeData>();
  const { wand_available } = data;
  return (
    <>
      <Section title="Basic tool kit">
        <Stack align="center">
          <Stack.Item grow>
            <Box color="label">
              A toolbelt with a power screwdriver, power crowbar, experimental
              welder, multitool, cable coil, analyzer and T-ray scanner, plus
              insulated gloves, an RCD loaded with matter and an RPD. The belt
              and gloves are put on when the slots are free.
            </Box>
          </Stack.Item>
          <Stack.Item>
            <Button icon="toolbox" onClick={() => act('give_tools')}>
              Get tool kit
            </Button>
          </Stack.Item>
        </Stack>
      </Section>
      <Section title="Tutorial wand">
        <Stack align="center">
          <Stack.Item grow>
            <Box color="label">
              Build tutorials: place markers, triggers and actions with the
              wand.
            </Box>
          </Stack.Item>
          <Stack.Item>
            <Button
              icon="wand-magic-sparkles"
              disabled={!wand_available}
              tooltip={wand_available ? undefined : 'Coming soon'}
              onClick={() => act('give_wand')}
            >
              {wand_available ? 'Get tutorial wand' : 'Coming soon'}
            </Button>
          </Stack.Item>
        </Stack>
      </Section>
    </>
  );
}
