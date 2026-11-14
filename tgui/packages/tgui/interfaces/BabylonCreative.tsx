// Babylon Creative panel (opened by modular_babylon/code/creative/panel.dm).
// Every action is checked again on the server; this window only shows and asks.
// Tabs come from the server (panel.dm, /datum/babylon_creative_panel/proc/tabs); a module that
// adds a tab there registers its component in CREATIVE_TABS below.
import { type ComponentType, type ReactNode, useEffect, useState } from 'react';
import {
  Box,
  Button,
  DmIcon,
  Dropdown,
  Icon,
  ImageButton,
  Input,
  LabeledList,
  NoticeBox,
  ProgressBar,
  RestrictedInput,
  Section,
  Stack,
  Tabs,
  TextArea,
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
  hint?: string;
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
  kit: Entry[];
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
  search: {
    query: string;
    category: string;
    results: Entry[];
    capped: boolean;
  };
  spawns_left: number;
  spawns_refill_in: number;
  events_left: number;
  events_refill_in: number;
  can_go_back: boolean;
  respawn_pending: boolean;
  notice: { text: string; ok: boolean; id: number } | null;
  extensions: { tutorial?: TutorialData } & Record<string, unknown>;
};

/** The Tutorial tab (modular_babylon/code/tutorial/submit.dm, tutorial_data()). */
export type TutorialData = {
  /** submit: an ordinary world; save_back: an admin's edit world of a pending tutorial. */
  mode: 'submit' | 'save_back';
  /** Why the button is disabled (a code and its text), else null. */
  blocked: string | null;
  blocked_text: string | null;
  /** Seconds left of the owner's cooldown (0: none or not known yet). */
  wait_seconds: number;
  checking: boolean;
  check_error: string | null;
  state: 'idle' | 'submitting' | 'saving_back' | 'done' | 'error';
  /** The last submission's or save back's outcome. */
  message: string | null;
  /** The edited tutorial's title (edit worlds). */
  title: string | null;
  title_max: number;
  description_max: number;
};

/** Tab id -> component. Tabs the server lists without an entry here show a placeholder. */
export const CREATIVE_TABS: Record<string, ComponentType> = {
  self: SelfTab,
  spawn: SpawnTab,
  teleport: TeleportTab,
  events: EventsTab,
  tools: KitsTab,
  tutorial: TutorialTab,
};

const plural = (count: number, word: string) =>
  `${count} ${word}${count === 1 ? '' : 's'}`;

export const BabylonCreative = () => {
  const { data } = useBackend<CreativeData>();
  const tabs = data.tabs || [];
  const [tab, setTab] = useState(tabs[0]?.id || 'self');
  const Content = CREATIVE_TABS[tab];

  return (
    <Window width={620} height={700} title="Creative">
      <Window.Content>
        <Stack fill vertical>
          <Stack.Item>
            <Stack align="center">
              <Stack.Item grow>
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
              <Stack.Item>
                <QuickToggles />
              </Stack.Item>
            </Stack>
          </Stack.Item>
          <Stack.Item grow basis={0} style={{ minHeight: 0 }}>
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

/** Godmode and noclip, reachable from every tab. */
const QuickToggles = () => {
  const { act, data } = useBackend<CreativeData>();
  const { godmode, godmode_elsewhere, noclip } = data;
  return (
    <>
      <Button
        icon="shield-halved"
        selected={godmode || godmode_elsewhere}
        disabled={godmode_elsewhere}
        tooltip={
          godmode_elsewhere
            ? 'Godmode: granted by something else'
            : `Godmode: ${godmode ? 'on' : 'off'} (click to toggle)`
        }
        onClick={() => act('godmode')}
      />
      <Button
        icon="ghost"
        selected={noclip}
        tooltip={`Noclip: ${noclip ? 'on' : 'off'} (click to toggle)`}
        onClick={() => act('noclip')}
      />
    </>
  );
};

/** Scrolls its content inside the tab area. */
const Scroll = (props: { children: ReactNode }) => (
  <Box height="100%" style={{ overflowY: 'auto' }}>
    {props.children}
  </Box>
);

/**
 * The last action's outcome. Successes fade after a few seconds; refusals stay until
 * dismissed or replaced by the next action's outcome.
 */
const Notice = () => {
  const { data } = useBackend<CreativeData>();
  const { notice } = data;
  const [hiddenId, setHiddenId] = useState(-1);
  useEffect(() => {
    if (!notice?.ok) {
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
  const {
    godmode,
    godmode_elsewhere,
    noclip,
    dead,
    health,
    body,
    position,
    respawn_pending,
  } = data;
  return (
    <Scroll>
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
                {health <= 0 ? 'Critical' : `${health}%`}
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
            enabled={godmode || godmode_elsewhere}
            locked={godmode_elsewhere}
            description="Nothing can hurt or kill you: no damage, no breathing, no pressure."
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
            {respawn_pending
              ? 'A new body is on its way; heal that one once it arrives.'
              : dead
                ? 'Bring your body back to life, fully healed.'
                : 'Heal every wound, ailment and missing part.'}
          </Stack.Item>
          <Stack.Item>
            <Button
              icon={dead ? 'heart-pulse' : 'kit-medical'}
              color={dead ? 'good' : undefined}
              disabled={respawn_pending}
              onClick={() => act('heal')}
            >
              {dead ? 'Revive' : 'Heal fully'}
            </Button>
          </Stack.Item>
        </Stack>
      </Section>
      <Section title="Quick start">
        <Stack vertical>
          <QuickTip
            icon="cube"
            text="Spawn: search or browse, click to get it."
          />
          <QuickTip
            icon="location-arrow"
            text="Teleport: coordinates, areas, other players, and Back."
          />
          <QuickTip
            icon="bolt"
            text="Events: start station events here, for everyone."
          />
          <QuickTip
            icon="toolbox"
            text="Kits: a full tool kit with one click."
          />
        </Stack>
      </Section>
    </Scroll>
  );
}

const QuickTip = (props: { icon: string; text: string }) => (
  <Stack.Item color="label">
    <Icon name={props.icon} mr={1} width="1.2em" />
    {props.text}
  </Stack.Item>
);

type PowerToggleProps = {
  icon: string;
  name: string;
  enabled: boolean;
  locked?: boolean;
  description: string;
  onToggle: () => void;
};

function PowerToggle(props: PowerToggleProps) {
  const { icon, name, enabled, locked, description, onToggle } = props;
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
            disabled={locked}
            tooltip={locked ? 'Granted by something else' : undefined}
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

/** null: the default (a full stack for stacks, one of anything else). */
type Amount = number | null;

/** How many of an entry a click spawns. */
const amountFor = (entry: Entry, amount: Amount, copies: number) => {
  if (entry.stack) {
    return amount === null ? entry.max : Math.min(amount, entry.max);
  }
  return amount === null ? 1 : Math.min(amount, copies);
};

function SpawnTab() {
  const { act, data } = useBackend<CreativeData>();
  const { categories = [], search, spawns_left, limits } = data;
  const [query, setQuery] = useState(search?.query || '');
  const [category, setCategory] = useState(search?.category || 'all');
  const [inHand, setInHand] = useState(true);
  const [amount, setAmount] = useState<Amount>(null);
  const trimmed = query.trim();
  const searching = trimmed.length >= 2;

  const runSearch = (nextQuery: string, nextCategory: string) => {
    if (nextQuery.trim().length >= 2) {
      act('search', { query: nextQuery, category: nextCategory });
    }
  };

  const shown = categories.filter((entry) =>
    category === 'all' ? entry.entries.length > 0 : entry.id === category,
  );
  const answered =
    search && search.query === trimmed && search.category === category;
  const spawn = (entry: Entry) =>
    act('spawn', {
      path: entry.path,
      amount: amountFor(entry, amount, limits.copies),
      in_hand: entry.item && inHand ? 1 : 0,
    });
  const list = (entries: Entry[]) => (
    <EntryGrid
      entries={entries}
      amount={amount}
      inHand={inHand}
      disabled={!spawns_left}
      onSpawn={spawn}
    />
  );

  return (
    <Stack fill vertical>
      <Stack.Item>
        <Section>
          <Stack vertical>
            <Stack.Item>
              <Input
                fluid
                autoFocus
                expensive={300}
                value={query}
                placeholder="Search everything that can be spawned (name, nickname or type path)"
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
              <Stack align="center" wrap>
                <Stack.Item color="label">Spawn into</Stack.Item>
                <Stack.Item>
                  <Button
                    icon="hand"
                    selected={inHand}
                    tooltip="Items go into your hands (at your feet when your hands are full). Machines, structures and mobs always land at your feet."
                    onClick={() => setInHand(true)}
                  >
                    Your hands
                  </Button>
                  <Button
                    icon="shoe-prints"
                    selected={!inHand}
                    onClick={() => setInHand(false)}
                  >
                    Your feet
                  </Button>
                </Stack.Item>
                <Stack.Item ml={1} color="label">
                  Amount
                </Stack.Item>
                <Stack.Item>
                  <AmountPicker
                    amount={amount}
                    copies={limits.copies}
                    onChange={setAmount}
                  />
                </Stack.Item>
              </Stack>
            </Stack.Item>
            <Stack.Item>
              <SpawnBudget />
            </Stack.Item>
          </Stack>
        </Section>
      </Stack.Item>
      <Stack.Item grow basis={0} style={{ minHeight: 0 }}>
        <Scroll>
          {query.trim().length === 1 && (
            <NoticeBox info>Type at least 2 letters to search.</NoticeBox>
          )}
          {searching ? (
            <Section
              title={
                answered
                  ? `Results for "${trimmed}"`
                  : `Searching for "${trimmed}"...`
              }
            >
              {answered && !search.results.length && (
                <Box color="label">
                  Nothing matches. Try another word or the type path, or search
                  in "All".
                </Box>
              )}
              {answered && list(search.results)}
              {answered && search.capped && (
                <Box color="label" mt={0.5}>
                  Showing the first {search.results.length}: type more to narrow
                  the list.
                </Box>
              )}
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
                  list(entry.entries)
                ) : (
                  <Box color="label">
                    Nothing here yet. Search in "All" to find more.
                  </Box>
                )}
              </Section>
            ))
          )}
        </Scroll>
      </Stack.Item>
    </Stack>
  );
}

type AmountPickerProps = {
  amount: Amount;
  copies: number;
  onChange: (amount: Amount) => void;
};

function AmountPicker(props: AmountPickerProps) {
  const { amount, copies, onChange } = props;
  const presets = [1, 5, 10];
  const [custom, setCustom] = useState(false);
  const pick = (value: Amount) => {
    setCustom(false);
    onChange(value);
  };
  return (
    <Stack align="center">
      <Stack.Item>
        {presets.map((value) => (
          <Button
            key={value}
            selected={!custom && amount === value}
            tooltip={
              value === 1
                ? 'One of anything; stacks of 1.'
                : `${value} copies (at most ${copies}); stacks of ${value}.`
            }
            onClick={() => pick(value)}
          >
            {value}
          </Button>
        ))}
        <Button
          selected={!custom && amount === null}
          tooltip="Stacks come as a full stack; anything else as one."
          onClick={() => pick(null)}
        >
          Full stack
        </Button>
        <Button
          selected={custom}
          tooltip="Another amount (1-50)"
          onClick={() => {
            setCustom(true);
            onChange(amount ?? 1);
          }}
        >
          Other
        </Button>
      </Stack.Item>
      {custom && (
        <Stack.Item>
          <RestrictedInput
            autoFocus
            autoSelect
            width="3.5em"
            minValue={1}
            maxValue={50}
            value={amount ?? 1}
            onChange={(value) => onChange(Math.max(1, Math.round(value)))}
          />
        </Stack.Item>
      )}
    </Stack>
  );
}

/** The spawn rate limit, visible before it bites. */
function SpawnBudget() {
  const { data } = useBackend<CreativeData>();
  const { spawns_left, spawns_refill_in, limits } = data;
  const refill =
    spawns_left < limits.spawns && spawns_refill_in > 0
      ? ` · refills in ${spawns_refill_in}s`
      : '';
  return (
    <ProgressBar
      value={spawns_left}
      minValue={0}
      maxValue={limits.spawns}
      ranges={{
        good: [limits.spawns / 2, Infinity],
        average: [1, limits.spawns / 2],
        bad: [-Infinity, 1],
      }}
    >
      {spawns_left
        ? `${plural(spawns_left, 'spawn')} left${refill}`
        : `No spawns left${refill}`}
    </ProgressBar>
  );
}

type EntryGridProps = {
  entries: Entry[];
  amount: Amount;
  inHand: boolean;
  disabled: boolean;
  onSpawn: (entry: Entry) => void;
};

function EntryGrid(props: EntryGridProps) {
  const { data } = useBackend<CreativeData>();
  const { entries, amount, inHand, disabled, onSpawn } = props;
  const copies = data.limits.copies;
  return (
    <Box
      style={{
        display: 'grid',
        gridTemplateColumns: 'repeat(auto-fill, minmax(17em, 1fr))',
        gap: '0.25em',
      }}
    >
      {entries.map((entry) => {
        const count = amountFor(entry, amount, copies);
        const where = entry.item && inHand ? 'into your hand' : 'at your feet';
        return (
          <ImageButton
            key={entry.path}
            fluid
            dmIcon={entry.icon}
            dmIconState={entry.icon_state}
            fallbackIcon="cube"
            imageSize={32}
            disabled={disabled}
            tooltip={
              <>
                <Box bold>
                  Click: {entry.stack ? `a stack of ${count}` : count} {where}
                </Box>
                <Box color="label">{entry.path}</Box>
              </>
            }
            tooltipPosition="bottom"
            buttonsAlt={
              count > 1 ? (
                <Box color="label" fontSize="0.85em" pr={0.5}>
                  x{count}
                </Box>
              ) : undefined
            }
            onClick={() => onSpawn(entry)}
          >
            <Box
              style={{
                overflow: 'hidden',
                textOverflow: 'ellipsis',
                whiteSpace: 'nowrap',
              }}
            >
              {entry.name}
            </Box>
            {!!entry.hint && (
              <Box color="label" fontSize="0.85em">
                {entry.hint}
              </Box>
            )}
          </ImageButton>
        );
      })}
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
    can_go_back,
  } = data;
  const [x, setX] = useState(position?.x || 1);
  const [y, setY] = useState(position?.y || 1);
  const [z, setZ] = useState(position?.z || levels[0]?.z || 1);
  const [areaQuery, setAreaQuery] = useState('');
  const levelNames = levels.map((level) => level.name);
  const levelsCollide = new Set(levelNames).size !== levelNames.length;
  const levelName = (level: number) => {
    const name =
      levels.find((entry) => entry.z === level)?.name || `Level ${level}`;
    return levelsCollide ? `${name} (${level})` : name;
  };
  const matches = areas.filter(
    createSearch(areaQuery, (entry: AreaEntry) => entry.name),
  );
  const areaNameCount: Record<string, number> = {};
  for (const entry of areas) {
    areaNameCount[entry.name] = (areaNameCount[entry.name] || 0) + 1;
  }

  return (
    <Scroll>
      <Section
        title="Coordinates"
        buttons={
          <>
            <Button
              icon="rotate-left"
              disabled={!can_go_back}
              tooltip="Back to where you were before your last teleport"
              onClick={() => act('teleport_back')}
            >
              Back
            </Button>
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
          </>
        }
      >
        <Stack align="center">
          <Stack.Item color="label">X</Stack.Item>
          <Stack.Item>
            <RestrictedInput
              width="4em"
              minValue={1}
              maxValue={map_size.x}
              value={x}
              onChange={(value) => setX(Math.round(value))}
            />
          </Stack.Item>
          <Stack.Item color="label">Y</Stack.Item>
          <Stack.Item>
            <RestrictedInput
              width="4em"
              minValue={1}
              maxValue={map_size.y}
              value={y}
              onChange={(value) => setY(Math.round(value))}
            />
          </Stack.Item>
          <Stack.Item color="label">Level</Stack.Item>
          <Stack.Item grow>
            <Dropdown
              width="100%"
              selected={`${z}`}
              displayText={levelName(z)}
              options={levels.map((level) => ({
                value: `${level.z}`,
                displayText: levelName(level.z),
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
        <Box color="label" mt={0.5}>
          Landing spot:{' '}
          {noclip
            ? 'exactly there (noclip on)'
            : 'the nearest free tile (noclip off)'}
          .
        </Box>
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
                    {levels.length > 1 && (
                      <Box inline color="label" ml={1}>
                        {levelName(player.z)}
                      </Box>
                    )}
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
          placeholder={`Search ${plural(areas.length, 'area')}`}
          onChange={setAreaQuery}
        />
        <Stack vertical mt={0.5}>
          {matches.slice(0, 60).map((entry) => (
            <Stack.Item key={`${entry.path}-${entry.z}`}>
              <Stack align="center">
                <Stack.Item grow>
                  {entry.name}
                  {(levels.length > 1 || areaNameCount[entry.name] > 1) && (
                    <Box inline color="label" ml={1}>
                      {areaNameCount[entry.name] > 1
                        ? `${levelName(entry.z)}, ${entry.path.split('/').pop()}`
                        : levelName(entry.z)}
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
              {plural(matches.length - 60, 'more area')}: type to narrow the
              list.
            </Stack.Item>
          )}
          {!matches.length && (
            <Stack.Item color="label">No area matches.</Stack.Item>
          )}
        </Stack>
      </Section>
    </Scroll>
  );
}

// ---------------------------------------------------------------- Events

function EventsTab() {
  const { act, data } = useBackend<CreativeData>();
  const { events = [], events_left, events_refill_in, limits } = data;
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
  const budget = `Up to ${limits.events} every ${limits.event_window} seconds: ${events_left} left.`;

  if (!events.length) {
    return (
      <Section fill>
        <Box color="label">No events are available in this world.</Box>
      </Section>
    );
  }

  return (
    <Scroll>
      {events_left ? (
        <NoticeBox>
          Events hit the whole world, other players in it included. {budget}
        </NoticeBox>
      ) : (
        <NoticeBox danger>
          No events left right now: the next one in {events_refill_in}s.
        </NoticeBox>
      )}
      <Section>
        <Input
          fluid
          value={query}
          placeholder={`Search ${plural(events.length, 'event')}`}
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
                        width="6em"
                        textAlign="center"
                        disabled={!events_left}
                        tooltip={
                          events_left
                            ? undefined
                            : `Next event in ${events_refill_in}s`
                        }
                        confirmContent="Run for everyone?"
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
    </Scroll>
  );
}

// ---------------------------------------------------------------- Kits

function KitsTab() {
  const { act, data } = useBackend<CreativeData>();
  const { wand_available, kit = [] } = data;
  return (
    <Scroll>
      <Section
        title="Tool kit"
        buttons={
          <Button icon="toolbox" onClick={() => act('give_tools')}>
            Get tool kit
          </Button>
        }
      >
        <Box color="label" mb={0.5}>
          The belt and gloves are put on when those slots are free; the rest
          goes into your hands.
        </Box>
        <Box
          style={{
            display: 'grid',
            gridTemplateColumns: 'repeat(auto-fill, minmax(12em, 1fr))',
            gap: '0.25em',
          }}
        >
          {kit.map((entry) => (
            <Stack key={entry.path} align="center">
              <Stack.Item>
                <DmIcon
                  icon={entry.icon}
                  icon_state={entry.icon_state}
                  width="32px"
                  height="32px"
                  fallback={<Icon name="cube" size={1.5} color="label" />}
                />
              </Stack.Item>
              <Stack.Item grow>{entry.name}</Stack.Item>
            </Stack>
          ))}
        </Box>
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
              tooltip={
                wand_available
                  ? 'Puts the tutorial wand into your hand: click things with it to mark tutorial steps.'
                  : 'Coming soon: the wand that places tutorial markers, triggers and actions.'
              }
              onClick={() => act('give_wand')}
            >
              {wand_available ? 'Get tutorial wand' : 'Coming soon'}
            </Button>
          </Stack.Item>
        </Stack>
      </Section>
    </Scroll>
  );
}

/** Submit this world as a tutorial, or save an edit world back to its pending tutorial. */
function TutorialTab() {
  const { act, data } = useBackend<CreativeData>();
  const tutorial = data.extensions?.tutorial;
  const [title, setTitle] = useState('');
  const [description, setDescription] = useState('');
  const [confirming, setConfirming] = useState(false);
  // The cooldown comes from the supervisor: ask for it when the tab opens.
  useEffect(() => {
    act('tutorial_refresh');
  }, []);
  if (!tutorial) {
    return <NoticeBox info>This tab is not available yet.</NoticeBox>;
  }
  const running =
    tutorial.state === 'submitting' || tutorial.state === 'saving_back';
  const outcome = running ? (
    <NoticeBox info>
      <Icon name="spinner" spin mr={1} />
      {tutorial.state === 'submitting'
        ? 'Submitting… the world pauses while it is saved.'
        : 'Saving back… the world pauses while it is saved.'}
    </NoticeBox>
  ) : tutorial.state === 'done' || tutorial.state === 'error' ? (
    <OutcomeBox ok={tutorial.state === 'done'}>
      <Stack align="center">
        <Stack.Item grow>{tutorial.message}</Stack.Item>
        <Stack.Item>
          <Button
            icon="xmark"
            tooltip="Dismiss"
            onClick={() => act('tutorial_dismiss')}
          />
        </Stack.Item>
      </Stack>
    </OutcomeBox>
  ) : null;
  const blocked = tutorial.blocked_text && !running && (
    <Box color="average" mt={1}>
      <Icon name="circle-info" mr={1} />
      {tutorial.blocked_text}
    </Box>
  );

  if (tutorial.mode === 'save_back') {
    return (
      <Scroll>
        <Section title={`Editing: ${tutorial.title || 'a pending tutorial'}`}>
          <Box color="label" mb={1}>
            Saving back replaces the pending tutorial's saved state with this
            world as it is now. The world pauses while it is saved. Players
            start where the start marker is.
          </Box>
          {confirming && !running ? (
            <NoticeBox>
              <Box mb={1}>
                Replace the pending tutorial with the current state of this
                world? This cannot be undone.
              </Box>
              <Button
                icon="floppy-disk"
                color="good"
                onClick={() => {
                  setConfirming(false);
                  act('tutorial_save_back');
                }}
              >
                Yes, save back
              </Button>
              <Button icon="xmark" onClick={() => setConfirming(false)}>
                Cancel
              </Button>
            </NoticeBox>
          ) : (
            <Button
              icon="floppy-disk"
              disabled={running || !!tutorial.blocked}
              onClick={() => setConfirming(true)}
            >
              Save back to the pending tutorial
            </Button>
          )}
          {blocked}
        </Section>
        {outcome}
      </Scroll>
    );
  }

  const tooLong =
    title.length > tutorial.title_max ||
    description.length > tutorial.description_max;
  const canSend =
    !running && !tutorial.blocked && title.trim().length > 0 && !tooLong;
  // Only the owner of a Creative station world has a cooldown to show.
  const noCooldown =
    tutorial.blocked === 'not_capable' || tutorial.blocked === 'not_owner';
  return (
    <Scroll>
      <Section title="Submit as a tutorial">
        <NoticeBox>
          Submitting sends this world to the moderators for review and saves its
          current state as the tutorial (the world pauses while it is saved).
          Players start at the start marker.
        </NoticeBox>
        <LabeledList>
          <LabeledList.Item label="Title">
            <Input
              fluid
              value={title}
              maxLength={tutorial.title_max}
              placeholder={`1–${tutorial.title_max} characters`}
              disabled={running}
              onChange={(value: string) => setTitle(value)}
            />
          </LabeledList.Item>
          <LabeledList.Item label="Description">
            <TextArea
              fluid
              height="90px"
              value={description}
              maxLength={tutorial.description_max}
              placeholder="What the tutorial teaches (optional)"
              disabled={running}
              onChange={(value: string) => setDescription(value)}
            />
            <Box color="label" textAlign="right">
              {description.length}/{tutorial.description_max}
            </Box>
          </LabeledList.Item>
          {!noCooldown && (
            <LabeledList.Item label="Cooldown">
              {tutorial.checking
                ? 'Checking…'
                : tutorial.check_error
                  ? `Unknown (${tutorial.check_error})`
                  : tutorial.wait_seconds
                    ? `${formatWait(tutorial.wait_seconds)} left`
                    : 'None: you can submit now'}
            </LabeledList.Item>
          )}
        </LabeledList>
        <Box mt={1}>
          <Button
            icon="paper-plane"
            color="good"
            disabled={!canSend}
            onClick={() => act('tutorial_submit', { title, description })}
          >
            {running ? 'Submitting…' : 'Submit for review'}
          </Button>
        </Box>
        {blocked}
      </Section>
      {outcome}
    </Scroll>
  );
}

const OutcomeBox = (props: { ok: boolean; children: ReactNode }) =>
  props.ok ? (
    <NoticeBox success>{props.children}</NoticeBox>
  ) : (
    <NoticeBox danger>{props.children}</NoticeBox>
  );

/** "4 min", "1 h 5 min", "30 s" (as the server words it). */
export const formatWait = (seconds: number) => {
  if (seconds < 60) {
    return `${Math.round(seconds)} s`;
  }
  const minutes = Math.ceil(seconds / 60);
  if (minutes < 60) {
    return `${minutes} min`;
  }
  const rest = minutes % 60;
  return `${Math.floor(minutes / 60)} h${rest ? ` ${rest} min` : ''}`;
};
