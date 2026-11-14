// Babylon tutorial wand (modular_babylon/code/tutorial/wand.dm). Chooses what a click with the
// wand does (Place / Configure / NPC / Delete), lists every tutorial object with its problems
// and starts or stops a test run. Every action is checked again on the server.
import { type ReactNode, useEffect, useState } from 'react';
import {
  Box,
  Button,
  Icon,
  Input,
  NoticeBox,
  Section,
  Stack,
  Tabs,
} from 'tgui-core/components';
import { createSearch } from 'tgui-core/string';

import { useBackend } from '../backend';
import { Window } from '../layouts';

export type PaletteEntry = {
  kind: string;
  name: string;
  desc: string;
  example?: string;
  icon: string;
};

export type PaletteGroup = {
  id: string;
  name: string;
  desc: string;
  entries: PaletteEntry[];
};

export type Preset = { id: string; name: string; desc: string; icon: string };

export type TutorialObject = {
  ref: string;
  id: string;
  kind: string;
  kind_name: string;
  category: string;
  icon: string;
  summary: string;
  x: number | null;
  y: number | null;
  z: number | null;
  refs: string[];
  issues: string[];
  actions?: string[] | null;
  starts?: string | null;
  after?: string | null;
};

export type Warning = { text: string; ref: string | null };

export type WandData = {
  palette: PaletteGroup[];
  presets: Preset[];
  colors: Record<string, string>;
  creative: boolean;
  mode: string;
  selected_kind: string;
  selected_preset: string;
  objects: TutorialObject[];
  warnings: Warning[];
  picking: { id: string; corner: number } | null;
  has_start: boolean;
  test: {
    running: boolean;
    completed?: boolean;
    fired?: number;
    listening?: string[];
    steps?: string[];
    objective?: string | null;
  };
  notice: { text: string; ok: boolean; id: number } | null;
};

const MODES = [
  {
    id: 'place',
    name: 'Place',
    icon: 'plus',
    help: 'Click a tile with the wand to put the chosen object there. Its settings open right away.',
  },
  {
    id: 'configure',
    name: 'Configure',
    icon: 'sliders',
    help: 'Click a tutorial object (or an NPC) with the wand to open its settings.',
  },
  {
    id: 'npc',
    name: 'NPC',
    icon: 'user-plus',
    help: 'Click a tile to place an NPC from the chosen preset. It appears at once.',
  },
  {
    id: 'delete',
    name: 'Delete',
    icon: 'eraser',
    help: 'Click a tutorial object (or an NPC) with the wand to remove it.',
  },
];

export const BabylonTutorialWand = () => {
  const { data } = useBackend<WandData>();
  const [tab, setTab] = useState('build');
  // Every object's own problems are part of the warnings: count each once.
  const problems = data.warnings.length;
  return (
    <Window width={560} height={680} title="Tutorial wand">
      <Window.Content>
        <Stack fill vertical>
          {!data.creative && (
            <Stack.Item>
              <NoticeBox danger>
                The tutorial wand only works in creative worlds.
              </NoticeBox>
            </Stack.Item>
          )}
          <Stack.Item>
            <Tabs fluid>
              <Tabs.Tab
                icon="wand-magic-sparkles"
                selected={tab === 'build'}
                onClick={() => setTab('build')}
              >
                Build
              </Tabs.Tab>
              <Tabs.Tab
                icon="list"
                selected={tab === 'overview'}
                onClick={() => setTab('overview')}
              >
                Overview ({data.objects.length})
                {problems > 0 && (
                  <Box inline color="average" ml={1}>
                    <Icon name="triangle-exclamation" /> {problems}
                  </Box>
                )}
              </Tabs.Tab>
              <Tabs.Tab
                icon="play"
                selected={tab === 'test'}
                onClick={() => setTab('test')}
              >
                Test run{data.test.running ? ' (running)' : ''}
              </Tabs.Tab>
            </Tabs>
          </Stack.Item>
          {data.picking && (
            <Stack.Item>
              <PickingBanner />
            </Stack.Item>
          )}
          <Stack.Item grow basis={0} style={{ minHeight: 0 }}>
            <Box height="100%" style={{ overflowY: 'auto' }}>
              {tab === 'build' && <BuildTab />}
              {tab === 'overview' && <OverviewTab />}
              {tab === 'test' && <TestTab />}
            </Box>
          </Stack.Item>
          <Stack.Item>
            <Notice />
          </Stack.Item>
        </Stack>
      </Window.Content>
    </Window>
  );
};

const PickingBanner = () => {
  const { act, data } = useBackend<WandData>();
  if (!data.picking) {
    return null;
  }
  return (
    <NoticeBox info mb={0}>
      <Stack align="center">
        <Stack.Item grow>
          <Icon name="vector-square" mr={1} />
          Zone of <b>{data.picking.id}</b>: click corner {data.picking.corner}{' '}
          of 2 with the wand.
        </Stack.Item>
        <Stack.Item>
          <Button icon="xmark" onClick={() => act('cancel_pick')}>
            Cancel
          </Button>
        </Stack.Item>
      </Stack>
    </NoticeBox>
  );
};

// ---------------------------------------------------------------- Build

const BuildTab = () => {
  const { act, data } = useBackend<WandData>();
  const mode = MODES.find((entry) => entry.id === data.mode) || MODES[0];
  return (
    <>
      <Section title="What a click does">
        <Stack>
          {MODES.map((entry) => (
            <Stack.Item key={entry.id} grow basis={0}>
              <Button
                fluid
                icon={entry.icon}
                selected={entry.id === data.mode}
                textAlign="center"
                onClick={() => act('mode', { mode: entry.id })}
              >
                {entry.name}
              </Button>
            </Stack.Item>
          ))}
        </Stack>
        <Box mt={1} color="label">
          <Icon name="circle-info" mr={1} />
          {mode.help}
        </Box>
      </Section>
      {!data.objects.length && <FirstSteps />}
      {data.mode === 'npc' ? <PresetPalette /> : <ObjectPalette />}
    </>
  );
};

/** Shown while nothing is placed yet: how a tutorial is built. */
const FirstSteps = () => (
  <NoticeBox info>
    <Box bold mb={0.5}>
      A tutorial is triggers (when…) that run actions (do…).
    </Box>
    <Box>Start here:</Box>
    <Box>
      ① <b>NPC → Guide</b> where players arrive.
    </Box>
    <Box>
      ② a <b>Marker</b> with the id <b>start</b> on the arrival tile.
    </Box>
    <Box>
      ③ a <b>Zone</b> trigger (or <b>Tutorial starts</b>) where something should
      happen, then add actions to it in its settings.
    </Box>
  </NoticeBox>
);

const ObjectPalette = () => {
  const { act, data } = useBackend<WandData>();
  const [query, setQuery] = useState('');
  const search = createSearch(
    query,
    (entry: PaletteEntry) => `${entry.name} ${entry.desc}`,
  );
  return (
    <Section
      title="Objects"
      buttons={
        <Input
          placeholder="Search..."
          value={query}
          onChange={(value: string) => setQuery(value)}
          width="160px"
        />
      }
    >
      {data.palette.map((group) => {
        const entries = query ? group.entries.filter(search) : group.entries;
        if (!entries.length) {
          return null;
        }
        return (
          <Box key={group.id} mb={1.5}>
            <Box bold color={data.colors[group.id]}>
              {group.name}
            </Box>
            <Box color="label" mb={0.5} fontSize="0.9em">
              {group.desc}
            </Box>
            <Stack vertical>
              {entries.map((entry) => (
                <Stack.Item key={entry.kind}>
                  <PaletteButton
                    icon={entry.icon}
                    color={data.colors[group.id]}
                    name={entry.name}
                    desc={entry.desc}
                    example={entry.example}
                    selected={
                      data.mode === 'place' && data.selected_kind === entry.kind
                    }
                    onClick={() => act('kind', { kind: entry.kind })}
                  />
                </Stack.Item>
              ))}
            </Stack>
          </Box>
        );
      })}
    </Section>
  );
};

const PresetPalette = () => {
  const { act, data } = useBackend<WandData>();
  return (
    <Section title="NPC presets">
      <Box color="label" mb={1}>
        NPCs stand still and never wander. After placing one you can change its
        name, outfit and what is wrong with it.
      </Box>
      <Stack vertical>
        {data.presets.map((preset) => (
          <Stack.Item key={preset.id}>
            <PaletteButton
              icon={preset.icon}
              color={data.colors.npc}
              name={preset.name}
              desc={preset.desc}
              selected={data.selected_preset === preset.id}
              onClick={() => act('preset', { preset: preset.id })}
            />
          </Stack.Item>
        ))}
      </Stack>
    </Section>
  );
};

const PaletteButton = (props: {
  icon: string;
  color: string;
  name: string;
  desc: string;
  example?: string;
  selected: boolean;
  onClick: () => void;
}) => (
  <Button fluid selected={props.selected} onClick={props.onClick}>
    <Stack align="center" py={0.25}>
      <Stack.Item width="24px" textAlign="center">
        <Icon name={props.icon} color={props.color} size={1.2} />
      </Stack.Item>
      <Stack.Item grow style={{ whiteSpace: 'normal' }}>
        <Box bold>{props.name}</Box>
        <Box fontSize="0.9em" opacity={0.8}>
          {props.desc}
        </Box>
        {props.example && (
          <Box fontSize="0.85em" opacity={0.6} italic>
            {props.example}
          </Box>
        )}
      </Stack.Item>
    </Stack>
  </Button>
);

// ---------------------------------------------------------------- Overview

const CATEGORY_NAMES: Record<string, string> = {
  trigger: 'Triggers',
  action: 'Actions',
  marker: 'Markers',
  npc: 'NPCs',
};

/** Groups the objects as the tutorial flows: each trigger with its actions and the triggers that
 * listen after it; markers and NPCs; actions no trigger uses at the bottom. */
export const buildFlow = (objects: TutorialObject[]) => {
  const triggers = objects.filter((object) => object.category === 'trigger');
  const used = new Set<string>();
  for (const trigger of triggers) {
    for (const id of trigger.actions || []) {
      used.add(id);
    }
  }
  const usedBy: Record<string, string[]> = {};
  for (const trigger of triggers) {
    for (const id of trigger.actions || []) {
      usedBy[id] = [...(usedBy[id] || []), trigger.id];
    }
  }
  return {
    triggers,
    usedBy,
    places: objects.filter(
      (object) => object.category === 'marker' || object.category === 'npc',
    ),
    usedActions: objects.filter(
      (object) => object.category === 'action' && used.has(object.id),
    ),
    unused: objects.filter(
      (object) => object.category === 'action' && !used.has(object.id),
    ),
  };
};

const OverviewTab = () => {
  const { act, data } = useBackend<WandData>();
  const [query, setQuery] = useState('');
  const search = createSearch(
    query,
    (object: TutorialObject) =>
      `${object.id} ${object.kind_name} ${object.summary}`,
  );
  const objects = query ? data.objects.filter(search) : data.objects;
  const flow = buildFlow(objects);
  const byId: Record<string, TutorialObject> = {};
  for (const object of data.objects) {
    byId[object.id] = byId[object.id] || object;
  }
  const open = (id: string) =>
    byId[id] && act('configure', { ref: byId[id].ref });
  return (
    <>
      <Section title="Checks">
        {data.warnings.length ? (
          <Stack vertical>
            {data.warnings.map((warning, index) => (
              <Stack.Item key={`${index}-${warning.text}`}>
                <Button
                  fluid
                  color="transparent"
                  disabled={!warning.ref}
                  style={{ whiteSpace: 'normal' }}
                  onClick={() =>
                    warning.ref && act('configure', { ref: warning.ref })
                  }
                >
                  <Box color="average">
                    <Icon name="triangle-exclamation" mr={1} />
                    {warning.text}
                  </Box>
                </Button>
              </Stack.Item>
            ))}
          </Stack>
        ) : (
          <Box color="good">
            <Icon name="check" mr={1} />
            No problems found.
          </Box>
        )}
      </Section>
      <Section
        title="Flow"
        buttons={
          <Input
            placeholder="Search..."
            value={query}
            onChange={(value: string) => setQuery(value)}
            width="160px"
          />
        }
      >
        {!data.objects.length && (
          <Box color="label">
            Nothing placed yet. Start with a marker named <b>start</b>, a
            trigger and a message.
          </Box>
        )}
        {flow.triggers.map((trigger, index) => (
          <Box key={`${trigger.ref}-${index}`} mb={1}>
            <ObjectRow object={trigger} />
            <Box ml={3}>
              <Box color="label" fontSize="0.9em">
                {trigger.starts === 'after'
                  ? `listens after ${trigger.after || '?'} fired`
                  : trigger.starts === 'manual'
                    ? 'listens when an Enable action switches it on'
                    : 'listens from the beginning'}
              </Box>
              {(trigger.actions || []).map((id, index) => (
                <Button
                  key={`${trigger.ref}-${index}-${id}`}
                  icon={byId[id]?.icon || 'question'}
                  color={byId[id] ? undefined : 'average'}
                  onClick={() => open(id)}
                >
                  {index + 1}. {id}
                  {byId[id] ? ` — ${byId[id].kind_name}` : ' (missing)'}
                </Button>
              ))}
              {!(trigger.actions || []).length && (
                <Box color="average" fontSize="0.9em">
                  No actions yet.
                </Box>
              )}
            </Box>
          </Box>
        ))}
        {!!flow.places.length && (
          <Box mt={1.5}>
            <Box bold mb={0.5}>
              Markers and NPCs
            </Box>
            {flow.places.map((object, index) => (
              <ObjectRow key={`${object.ref}-${index}`} object={object} />
            ))}
          </Box>
        )}
        {!!flow.usedActions.length && (
          <Box mt={1.5}>
            <Box bold mb={0.5}>
              Actions
            </Box>
            {flow.usedActions.map((object, index) => (
              <ObjectRow
                key={`${object.ref}-${index}`}
                object={object}
                note={`used by ${(flow.usedBy[object.id] || []).join(', ')}`}
              />
            ))}
          </Box>
        )}
        {!!flow.unused.length && (
          <Box mt={1.5}>
            <Box bold mb={0.5} color="average">
              Not used by any trigger
            </Box>
            {flow.unused.map((object, index) => (
              <ObjectRow key={`${object.ref}-${index}`} object={object} />
            ))}
          </Box>
        )}
      </Section>
    </>
  );
};

const ObjectRow = (props: { object: TutorialObject; note?: string }) => {
  const { act, data } = useBackend<WandData>();
  const { object } = props;
  return (
    <Box
      mb={0.5}
      p={0.5}
      style={{
        borderLeft: `3px solid ${data.colors[object.category]}`,
        background: 'rgba(255, 255, 255, 0.03)',
      }}
    >
      <Stack align="center">
        <Stack.Item width="20px" textAlign="center">
          <Icon name={object.icon} color={data.colors[object.category]} />
        </Stack.Item>
        <Stack.Item grow>
          <Box>
            <b>{object.id}</b>{' '}
            <Box inline color="label">
              {object.kind_name}
              {object.x !== null && ` at ${object.x}, ${object.y}, ${object.z}`}
            </Box>
          </Box>
          <Box fontSize="0.9em" opacity={0.8}>
            {object.summary}
            {props.note && ` — ${props.note}`}
          </Box>
          {object.issues.map((issue, index) => (
            <Box key={`${index}-${issue}`} fontSize="0.9em" color="average">
              <Icon name="triangle-exclamation" mr={0.5} />
              {issue}
            </Box>
          ))}
        </Stack.Item>
        <Stack.Item>
          <Button
            icon="sliders"
            tooltip="Settings"
            onClick={() => act('configure', { ref: object.ref })}
          />
          <Button
            icon="location-arrow"
            tooltip="Go there"
            onClick={() => act('jump', { ref: object.ref })}
          />
          <Button.Confirm
            icon="trash"
            color="bad"
            tooltip="Delete"
            onClick={() => act('delete', { ref: object.ref })}
          />
        </Stack.Item>
      </Stack>
    </Box>
  );
};

// ---------------------------------------------------------------- Test run

const TestTab = () => {
  const { act, data } = useBackend<WandData>();
  const { test } = data;
  const [resetNpcs, setResetNpcs] = useState(true);
  const start = (from: string) =>
    act('test_start', { from, reset_npcs: resetNpcs });
  return (
    <Section title="Test your tutorial">
      <Box color="label" mb={1}>
        A test run plays the tutorial for you only: your triggers start
        listening and their actions run, just as for a player. Other builders
        can test at the same time without getting in your way. Stopping resets
        the run, not the world (spawned NPCs and given items stay).
      </Box>
      <Button.Checkbox
        checked={resetNpcs}
        onClick={() => setResetNpcs(!resetNpcs)}
        tooltip="NPCs set to spawn at the start are created again, with their effects."
      >
        Reset NPCs when starting
      </Button.Checkbox>
      {test.running ? (
        <>
          <NoticeBox success mt={1}>
            <Icon name="circle-play" mr={1} />
            {test.completed
              ? 'Test run complete: you reached a Complete action.'
              : `Test run active: ${test.fired} action(s) run so far.`}
          </NoticeBox>
          {!test.completed && (
            <Box mb={1}>
              <Box bold mb={0.5}>
                Listening now
              </Box>
              {test.listening?.length ? (
                test.listening.map((id) => (
                  <Box inline key={id} mr={1}>
                    <Icon name="ear-listen" color={data.colors.trigger} /> {id}
                  </Box>
                ))
              ) : (
                <Box color="average">
                  No trigger is listening: nothing more can happen.
                </Box>
              )}
            </Box>
          )}
          {test.objective && (
            <Box mb={1}>
              <b>Objective on screen:</b> {test.objective}
            </Box>
          )}
          {!!test.steps?.length && (
            <Box mb={1}>
              <Box bold mb={0.5}>
                Last steps
              </Box>
              {test.steps.map((step, index) => (
                <Box key={`${index}-${step}`} fontFamily="monospace">
                  {step.replace('>', ' → ')}
                </Box>
              ))}
            </Box>
          )}
          <Button icon="stop" color="bad" onClick={() => act('test_stop')}>
            Stop test run
          </Button>
          <Button
            icon="rotate-left"
            disabled={!data.has_start}
            onClick={() => start('start')}
          >
            Restart from start marker
          </Button>
        </>
      ) : (
        <Stack vertical mt={1}>
          <Stack.Item>
            <Button
              fluid
              icon="flag"
              disabled={!data.has_start}
              tooltip={
                data.has_start
                  ? undefined
                  : 'Place a marker with the id "start" first.'
              }
              onClick={() => start('start')}
            >
              Start at the start marker
            </Button>
          </Stack.Item>
          <Stack.Item>
            <Button fluid icon="person" onClick={() => start('here')}>
              Start where I stand
            </Button>
          </Stack.Item>
        </Stack>
      )}
    </Section>
  );
};

// ---------------------------------------------------------------- Notice

/** The last action's outcome; successes fade after a few seconds. */
export const Notice = (props: {
  notice?: { text: string; ok: boolean; id: number } | null;
}) => {
  const { data } = useBackend<WandData>();
  const notice = props.notice === undefined ? data.notice : props.notice;
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
  const content: ReactNode = (
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
