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
};

export type WandData = {
  palette: PaletteGroup[];
  presets: Preset[];
  colors: Record<string, string>;
  creative: boolean;
  mode: string;
  selected_kind: string;
  selected_preset: string;
  objects: TutorialObject[];
  warnings: string[];
  picking: { id: string; corner: number } | null;
  has_start: boolean;
  test: {
    running: boolean;
    completed?: boolean;
    fired?: number;
    enabled?: number;
    steps?: string[];
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
  const problems =
    data.warnings.length +
    data.objects.filter((object) => object.issues.length).length;
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
      {data.mode === 'npc' ? <PresetPalette /> : <ObjectPalette />}
    </>
  );
};

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

const OverviewTab = () => {
  const { act, data } = useBackend<WandData>();
  const [query, setQuery] = useState('');
  const search = createSearch(
    query,
    (object: TutorialObject) =>
      `${object.id} ${object.kind_name} ${object.summary}`,
  );
  const objects = query ? data.objects.filter(search) : data.objects;
  return (
    <>
      <Section title="Checks">
        {data.warnings.length ? (
          <Stack vertical>
            {data.warnings.map((warning) => (
              <Stack.Item key={warning} color="average">
                <Icon name="triangle-exclamation" mr={1} />
                {warning}
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
        title="All tutorial objects"
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
        {Object.keys(CATEGORY_NAMES).map((category) => {
          const inCategory = objects.filter(
            (object) => object.category === category,
          );
          if (!inCategory.length) {
            return null;
          }
          return (
            <Box key={category} mb={1.5}>
              <Box bold color={data.colors[category]} mb={0.5}>
                {CATEGORY_NAMES[category]} ({inCategory.length})
              </Box>
              {inCategory.map((object) => (
                <ObjectRow key={object.ref} object={object} />
              ))}
            </Box>
          );
        })}
      </Section>
    </>
  );
};

const ObjectRow = (props: { object: TutorialObject }) => {
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
          </Box>
          {object.issues.map((issue) => (
            <Box key={issue} fontSize="0.9em" color="average">
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
  return (
    <Section title="Test your tutorial">
      <Box color="label" mb={1}>
        A test run plays the tutorial for you only: your triggers start
        listening and their actions run, just as for a player. Other builders
        can test at the same time without getting in your way. Stopping resets
        the run, not the world (spawned NPCs and given items stay).
      </Box>
      {test.running ? (
        <>
          <NoticeBox success>
            <Icon name="circle-play" mr={1} />
            {test.completed
              ? 'Test run complete: you reached a Complete action.'
              : `Test run active: ${test.enabled} trigger(s) listening, ${test.fired} action(s) run so far.`}
          </NoticeBox>
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
            onClick={() => act('test_start', { from: 'start' })}
          >
            Restart from start marker
          </Button>
        </>
      ) : (
        <Stack vertical>
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
              onClick={() => act('test_start', { from: 'start' })}
            >
              Start at the start marker
            </Button>
          </Stack.Item>
          <Stack.Item>
            <Button
              fluid
              icon="person"
              onClick={() => act('test_start', { from: 'here' })}
            >
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
