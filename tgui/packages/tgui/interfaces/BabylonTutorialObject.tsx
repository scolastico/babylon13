// Settings of one Babylon tutorial object (modular_babylon/code/tutorial/wand.dm,
// /datum/babylon_tutorial_editor). The form is built from the object's schema
// (settings_schema() in DM); every change is validated on the server, which reports
// problems per field ("issues") and refused values ("notice").
import { useEffect, useState } from 'react';
import {
  Box,
  Button,
  Dropdown,
  Icon,
  Input,
  LabeledList,
  NoticeBox,
  NumberInput,
  Section,
  Stack,
  TextArea,
} from 'tgui-core/components';

import { useBackend } from '../backend';
import { Window } from '../layouts';

export type Option = { value: string; label: string };

export type Field = {
  key: string;
  label: string;
  type:
    | 'text'
    | 'longtext'
    | 'number'
    | 'bool'
    | 'choice'
    | 'typepath'
    | 'id'
    | 'idlist'
    | 'gateinputs'
    | 'zone'
    | 'tile'
    | 'effects'
    | 'target'
    | 'loadout'
    | 'event'
    | 'area_clip';
  default: unknown;
  help: string | null;
  options?: Option[];
  min?: number;
  max?: number;
  filter?: string[];
  when?: Record<string, string[]>;
  base?: string;
  required?: boolean;
  placeholder?: string;
  /** Gate inputs: each trigger is marked live, latched or gate. */
  input_modes?: boolean;
  /** Type search: "creative" searches like the Creative panel's Spawn tab. */
  search?: string;
};

/** One item of a stored loadout, as the window shows it. */
export type LoadoutEntry = {
  place: string;
  where: string;
  name: string;
  path: string;
  inside: number;
};

/** A stored area (a Paste area's snapshot), as the window sees it: never the copy itself. */
export type AreaClipView = {
  width: number;
  height: number;
  x: number | null;
  y: number | null;
  z: number | null;
  objects: number;
  /** Tiles stored, and how many of them are different (identical tiles are stored once). */
  tiles?: number;
  distinct?: number;
  /** Its stored size, and the most one snapshot may take. */
  bytes?: number;
  limit?: number;
  skipped_tutorial?: number;
  /** Why it can't be pasted (stored in another format ...), or null. */
  problem: string | null;
};

/** The builder's world-edit selection. */
export type AreaSelection = {
  x1: number;
  y1: number;
  x2: number;
  y2: number;
  z: number;
  width: number;
  height: number;
  tiles: number;
  problem: string | null;
};

/** A round event a Start event action can start. */
export type EventOption = Option & { category?: string; description?: string };

export type IdEntry = {
  id: string;
  kind?: string;
  kind_name: string;
  category: string;
  summary?: string;
  /** How a trigger counts as a gate input. */
  input_mode?: 'live' | 'latched' | 'gate';
};

export type Effect = {
  kind: string;
  chance: number;
  amount?: number;
  zone?: string;
  type?: string;
};

/** One input of a number gate: which trigger, and what its firing does to the number. */
export type GateInput = {
  id: string;
  op: string;
  amount: number;
  source: string;
};

/** A gate's state in the running test run. */
export type GateLive = {
  running: boolean;
  listening?: boolean;
  state?: boolean;
  value?: number | null;
  stopped?: string | null;
};

export type ObjectData = {
  missing?: boolean;
  kind: string;
  kind_name: string;
  kind_desc: string;
  category: string;
  icon: string;
  color: string;
  schema: Field[];
  effect_kinds: Option[];
  body_zones: Option[];
  wounds: Option[];
  diseases: Option[];
  reagents: Option[];
  new_actions?: Option[];
  /** Start event: the events the Creative panel's Events tab offers. */
  events?: EventOption[];
  /** Set inventory: where an added loadout item can go. */
  loadout_places?: Option[];
  id_help?: string;
  target_choices?: Option[];
  target_now?: string;
  id: string;
  values: Record<string, any>;
  issues: Record<string, string>;
  ids: IdEntry[];
  position: { x: number; y: number; z: number } | null;
  summary: string;
  search: {
    key: string;
    query: string;
    results: { path: string; name: string; hint?: string }[];
  } | null;
  notice: { text: string; ok: boolean; id: number; key?: string } | null;
  picking: boolean;
  /** The builder's world-edit selection (objects with a zone or a stored area). */
  area_selection?: AreaSelection | null;
  gate?: GateLive;
  npc?: {
    name: string;
    health: number;
    stat: string;
    outdated?: boolean;
  } | null;
};

/** Whether a field applies with the current values (its "when" condition). */
export const fieldActive = (field: Field, values: Record<string, any>) =>
  Object.entries(field.when || {}).every(([key, allowed]) =>
    allowed.includes(String(values[key])),
  );

export const BabylonTutorialObject = () => {
  const { act, data } = useBackend<ObjectData>();
  if (data.missing) {
    return (
      <Window width={480} height={200} title="Tutorial object">
        <Window.Content>
          <NoticeBox>This tutorial object no longer exists.</NoticeBox>
        </Window.Content>
      </Window>
    );
  }
  const fields = data.schema.filter((field) => fieldActive(field, data.values));
  const isAction = data.category === 'action';
  return (
    <Window
      width={500}
      height={data.kind === 'npc_spawner' ? 720 : 600}
      title={`${data.kind_name}: ${data.id}`}
    >
      <Window.Content scrollable>
        <Section>
          <Stack align="center">
            <Stack.Item width="32px" textAlign="center">
              <Icon name={data.icon} size={2} color={data.color} />
            </Stack.Item>
            <Stack.Item grow>
              <Box bold fontSize="1.2em">
                {data.kind_name}
              </Box>
              <Box color="label">{data.kind_desc}</Box>
            </Stack.Item>
          </Stack>
          {data.position && (
            <Box mt={1} color="label" fontSize="0.9em">
              <Icon name="location-dot" mr={0.5} />
              At {data.position.x}, {data.position.y}, {data.position.z} —{' '}
              {data.summary}
            </Box>
          )}
        </Section>
        {data.notice && !data.notice.key && !data.notice.ok && (
          <NoticeBox danger>{data.notice.text}</NoticeBox>
        )}
        {data.notice?.ok && <NoticeBox success>{data.notice.text}</NoticeBox>}
        <Section title="Settings">
          <LabeledList>
            <LabeledList.Item
              label="Id"
              color={data.issues.id ? 'average' : undefined}
            >
              <IdInput
                value={data.id}
                onCommit={(value) => act('set', { key: 'id', value })}
              />
              <FieldHelp
                help={
                  data.id_help || 'Other parts refer to this object by its id.'
                }
                issue={data.issues.id}
                refused={fieldNotice(data, 'id')}
              />
            </LabeledList.Item>
            {fields.map((field) => (
              <LabeledList.Item
                key={field.key}
                label={field.label}
                verticalAlign="top"
              >
                <FieldInput field={field} />
                <FieldHelp
                  help={field.help}
                  issue={data.issues[field.key]}
                  refused={fieldNotice(data, field.key)}
                />
              </LabeledList.Item>
            ))}
          </LabeledList>
        </Section>
        {liveCopyWarning(data) && (
          <NoticeBox>{liveCopyWarning(data)}</NoticeBox>
        )}
        {otherIssues(data).map((text) => (
          <NoticeBox key={text}>{text}</NoticeBox>
        ))}
        {data.gate && <GateSection gate={data.gate} />}
        {data.kind === 'npc_spawner' && <NpcSection />}
        <Section>
          <Stack>
            {isAction && (
              <Stack.Item>
                <Button
                  icon="eye"
                  tooltip="Run this action now for you only, instead of for every player (an NPC it changes changes for everyone)."
                  onClick={() => act('preview')}
                >
                  Preview
                </Button>
              </Stack.Item>
            )}
            <Stack.Item>
              <Button icon="location-arrow" onClick={() => act('jump')}>
                Go there
              </Button>
            </Stack.Item>
            <Stack.Item grow />
            <Stack.Item>
              <Button.Confirm
                icon="trash"
                color="bad"
                onClick={() => act('delete')}
              >
                Delete
              </Button.Confirm>
            </Stack.Item>
          </Stack>
        </Section>
      </Window.Content>
    </Window>
  );
};

/** A Paste area copying a live area: players can change its source before it runs. */
export const liveCopyWarning = (data: ObjectData) => {
  if (data.kind !== 'paste_area' || data.values.mode !== 'live') {
    return null;
  }
  return data.values.protect
    ? 'Live copy: the source area is copied as it is when the action runs. While the tutorial runs (test runs and previews too), nobody can use tools or items on anything there, builders included (only the builder wands still work): stop the run before editing it. Bare hands (taking items off a table, moving things), explosions, fire and gas still change it. Prefer a stored snapshot unless you need the source to change.'
    : 'Live copy: players can change or damage the source area before the action runs, and the copy takes it as it is then. Turn on "Protect the source", or prefer a stored snapshot unless you need the source to change.';
};

/** Problems that belong to no field (an action's "Test run: ..." note); a gate shows its own. */
export const otherIssues = (data: ObjectData) =>
  Object.entries(data.issues || {})
    .filter(
      ([key]) =>
        key !== 'id' &&
        !(data.gate && key === 'live') &&
        !data.schema.some(
          (field) => field.key === key && fieldActive(field, data.values),
        ),
    )
    .map(([, text]) => text);

/** A refused value for this field, shown next to it. */
export const fieldNotice = (data: ObjectData, key: string) =>
  data.notice && !data.notice.ok && data.notice.key === key
    ? data.notice.text
    : undefined;

const FieldHelp = (props: {
  help: string | null;
  issue?: string;
  refused?: string;
}) => (
  <>
    {props.refused && (
      <Box color="bad" mt={0.5} fontSize="0.9em">
        <Icon name="circle-xmark" mr={0.5} />
        {props.refused}
      </Box>
    )}
    {props.issue && (
      <Box color="average" mt={0.5} fontSize="0.9em">
        <Icon name="triangle-exclamation" mr={0.5} />
        {props.issue}
      </Box>
    )}
    {props.help && (
      <Box color="label" mt={0.5} fontSize="0.9em">
        {props.help}
      </Box>
    )}
  </>
);

/** A text input that sends its value when it loses focus or Enter is pressed. */
const CommitInput = (props: {
  value: string;
  placeholder?: string;
  onCommit: (value: string) => void;
}) => {
  const [draft, setDraft] = useState(props.value);
  useEffect(() => setDraft(props.value), [props.value]);
  return (
    <Input
      fluid
      value={draft}
      placeholder={props.placeholder}
      onChange={(value: string) => setDraft(value)}
      onBlur={(value: string) => value !== props.value && props.onCommit(value)}
      onEnter={(value: string) => props.onCommit(value)}
    />
  );
};

const IdInput = (props: {
  value: string;
  onCommit: (value: string) => void;
}) => <CommitInput value={props.value} onCommit={props.onCommit} />;

const FieldInput = (props: { field: Field }) => {
  const { act, data } = useBackend<ObjectData>();
  const { field } = props;
  const value = data.values[field.key];
  const set = (next: unknown) => act('set', { key: field.key, value: next });
  switch (field.type) {
    case 'text':
      return (
        <CommitInput
          value={value ?? ''}
          placeholder={field.placeholder}
          onCommit={set}
        />
      );
    case 'longtext':
      return <LongText value={value ?? ''} field={field} onCommit={set} />;
    case 'number':
      return (
        <NumberInput
          value={Number(value ?? 0)}
          minValue={field.min ?? -1e6}
          maxValue={field.max ?? 1e6}
          step={1}
          width="90px"
          onChange={(next: number) => set(next)}
        />
      );
    case 'bool':
      return (
        <Button.Checkbox checked={!!value} onClick={() => set(!value)}>
          {value ? 'Yes' : 'No'}
        </Button.Checkbox>
      );
    case 'choice':
      return (
        <ChoiceInput
          options={field.options || []}
          value={String(value)}
          onSelect={set}
        />
      );
    case 'typepath':
      return <TypeInput field={field} />;
    case 'id':
      return (
        <IdPicker
          field={field}
          value={value ?? ''}
          ids={data.ids}
          onSelect={set}
        />
      );
    case 'idlist':
      return <IdListInput field={field} value={value || []} onChange={set} />;
    case 'gateinputs':
      return (
        <GateInputsInput field={field} value={value || []} onChange={set} />
      );
    case 'zone':
      return <ZoneInput field={field} value={value} />;
    case 'tile':
      return <TileInput field={field} value={value} />;
    case 'area_clip':
      return <AreaClipInput field={field} value={value} />;
    case 'effects':
      return <EffectsInput value={value || []} onChange={set} />;
    case 'target':
      return <TargetInput field={field} value={String(value ?? 'object')} />;
    case 'loadout':
      return <LoadoutInput field={field} value={value || []} />;
    case 'event':
      return <EventInput value={String(value ?? '')} onSelect={set} />;
  }
  return <Box color="bad">Unknown field type.</Box>;
};

const LongText = (props: {
  value: string;
  field: Field;
  onCommit: (value: string) => void;
}) => {
  const [draft, setDraft] = useState(props.value);
  useEffect(() => setDraft(props.value), [props.value]);
  return (
    <TextArea
      fluid
      height="70px"
      value={draft}
      placeholder={props.field.placeholder}
      onChange={(value: string) => setDraft(value)}
      onBlur={(value: string) => value !== props.value && props.onCommit(value)}
    />
  );
};

const ChoiceInput = (props: {
  options: Option[];
  value: string;
  onSelect: (value: string) => void;
}) => {
  const current = props.options.find((option) => option.value === props.value);
  return (
    <Dropdown
      width="100%"
      selected={current?.label ?? props.value}
      options={props.options.map((option) => ({
        displayText: option.label,
        value: option.value,
      }))}
      onSelected={(value: string) => props.onSelect(value)}
    />
  );
};

/** Ids of other objects the field may refer to (its filter), plus free text. */
export const idChoices = (field: Field, ids: IdEntry[]) =>
  ids.filter(
    (entry) => !field.filter?.length || field.filter.includes(entry.category),
  );

/** How another object is shown in pickers: id, kind and what it does. */
export const describeId = (entry: IdEntry) =>
  `${entry.id} — ${entry.kind_name}${entry.summary ? `: ${entry.summary}` : ''}`;

const INPUT_MODES: Record<string, string> = {
  live: 'live: true while it holds',
  latched: 'latched: true once it fired',
  gate: "gate: the gate's state",
};

/** A trigger as a gate input: described, with how it counts (live, latched, gate). */
export const describeInput = (entry: IdEntry) =>
  entry.input_mode
    ? `${describeId(entry)} [${INPUT_MODES[entry.input_mode]}]`
    : describeId(entry);

const IdPicker = (props: {
  field: Field;
  value: string;
  ids: IdEntry[];
  onSelect: (value: string) => void;
}) => {
  const { act } = useBackend<ObjectData>();
  const choices = idChoices(props.field, props.ids);
  const current = props.ids.find((entry) => entry.id === props.value);
  return (
    <Box>
      <Stack align="center">
        <Stack.Item grow>
          <Dropdown
            width="100%"
            searchInput
            selected={props.value}
            color={current || !props.value ? undefined : 'average'}
            displayText={
              current
                ? describeId(current)
                : props.value
                  ? `${props.value} (missing)`
                  : '(none) - choose...'
            }
            options={[
              { displayText: '(none)', value: '' },
              ...choices.map((entry) => ({
                displayText: describeId(entry),
                value: entry.id,
              })),
            ]}
            onSelected={(value: string) => props.onSelect(value)}
          />
        </Stack.Item>
        {current && (
          <Stack.Item>
            <Button
              icon="up-right-from-square"
              tooltip="Open its settings"
              onClick={() => act('open', { id: props.value })}
            />
          </Stack.Item>
        )}
      </Stack>
    </Box>
  );
};

const IdListInput = (props: {
  field: Field;
  value: string[];
  onChange: (value: string[]) => void;
}) => {
  const { act, data } = useBackend<ObjectData>();
  const { value } = props;
  const byId: Record<string, IdEntry> = {};
  for (const entry of data.ids) {
    byId[entry.id] = entry;
  }
  const choices = idChoices(props.field, data.ids).filter(
    (entry) => !value.includes(entry.id),
  );
  const offersNew = !!props.field.filter?.includes('action');
  const describe = props.field.input_modes ? describeInput : describeId;
  const move = (index: number, delta: number) => {
    const next = [...value];
    const [entry] = next.splice(index, 1);
    next.splice(index + delta, 0, entry);
    props.onChange(next);
  };
  return (
    <Box>
      {!value.length && <Box color="label">None yet.</Box>}
      {value.map((id, index) => (
        <Stack key={`${index}-${id}`} align="center" mb={0.25}>
          <Stack.Item color="label" width="18px">
            {index + 1}.
          </Stack.Item>
          <Stack.Item grow>
            {byId[id] ? (
              <Button
                fluid
                color="transparent"
                tooltip="Open its settings"
                style={{ whiteSpace: 'normal' }}
                onClick={() => act('open', { id })}
              >
                {describe(byId[id])}
              </Button>
            ) : (
              <Box color="average">{id} (missing)</Box>
            )}
          </Stack.Item>
          <Stack.Item>
            <Button
              icon="arrow-up"
              disabled={index === 0}
              tooltip="Earlier"
              onClick={() => move(index, -1)}
            />
            <Button
              icon="arrow-down"
              disabled={index === value.length - 1}
              tooltip="Later"
              onClick={() => move(index, 1)}
            />
            <Button
              icon="xmark"
              tooltip="Remove"
              onClick={() =>
                props.onChange(value.filter((_, i) => i !== index))
              }
            />
          </Stack.Item>
        </Stack>
      ))}
      <Dropdown
        width="100%"
        searchInput
        selected={null}
        placeholder={offersNew ? 'Add an action...' : 'Add...'}
        disabled={!choices.length && !offersNew}
        options={[
          ...(offersNew
            ? (data.new_actions || []).map((option) => ({
                displayText: `＋ New ${option.label}`,
                value: `new:${option.value}`,
              }))
            : []),
          ...choices.map((entry) => ({
            displayText: describe(entry),
            value: entry.id,
          })),
        ]}
        onSelected={(id: string) =>
          id.startsWith('new:')
            ? act('new_linked', { key: props.field.key, kind: id.slice(4) })
            : props.onChange([...value, id])
        }
      />
    </Box>
  );
};

const TargetInput = (props: { field: Field; value: string }) => {
  const { act, data } = useBackend<ObjectData>();
  const choices = data.target_choices || [];
  return (
    <Box>
      <ChoiceInput
        options={choices}
        value={props.value}
        onSelect={(value) => act('set', { key: props.field.key, value })}
      />
      {data.target_now && (
        <Box mt={0.5}>
          Currently: <b>{data.target_now}</b>
        </Box>
      )}
    </Box>
  );
};

const TypeInput = (props: { field: Field }) => {
  const { act, data } = useBackend<ObjectData>();
  const { field } = props;
  const current = data.values[field.key] || { path: '', name: '' };
  const [query, setQuery] = useState('');
  const results = data.search?.key === field.key ? data.search.results : [];
  return (
    <Box>
      {field.options?.length ? (
        <ChoiceInput
          options={field.options}
          value={current.path}
          onSelect={(value) => act('set', { key: field.key, value })}
        />
      ) : null}
      <Box my={0.5}>
        {current.path ? (
          <>
            <b>{current.name}</b>{' '}
            <Box inline color="label" fontSize="0.85em">
              {current.path}
            </Box>
          </>
        ) : (
          <Box inline color="label">
            Nothing chosen.
          </Box>
        )}
      </Box>
      <Input
        fluid
        expensive={300}
        value={query}
        placeholder={field.placeholder || 'Search...'}
        onChange={(value: string) => {
          setQuery(value);
          act('search', { key: field.key, query: value });
        }}
      />
      {results.map((result) => (
        <Button
          key={result.path}
          fluid
          color="transparent"
          onClick={() => {
            act('set', { key: field.key, value: result.path });
            setQuery('');
          }}
        >
          <SearchResultText result={result} />
        </Button>
      ))}
      {query.length >= 2 && !results.length && (
        <Box color="label">Nothing matches.</Box>
      )}
    </Box>
  );
};

/** A type search result: its name, the Creative panel's hint for same-named types, its path. */
const SearchResultText = (props: {
  result: { path: string; name: string; hint?: string };
}) => (
  <>
    {props.result.name}
    {props.result.hint ? ` (${props.result.hint})` : ''}{' '}
    <Box inline color="label" fontSize="0.85em">
      {props.result.path}
    </Box>
  </>
);

/** A stored loadout: its items by place, "Store my current loadout", remove and add by type. */
const LoadoutInput = (props: { field: Field; value: LoadoutEntry[] }) => {
  const { act, data } = useBackend<ObjectData>();
  const { field } = props;
  const places = data.loadout_places || [];
  const [place, setPlace] = useState(places[0]?.value || '');
  const [query, setQuery] = useState('');
  const results = data.search?.key === field.key ? data.search.results : [];
  return (
    <Box>
      <Button
        icon="person-rays"
        tooltip="Copies what you wear and hold right now, with names, settings and what is inside bags."
        onClick={() => act('store_loadout', { key: field.key })}
      >
        Store my current loadout
      </Button>
      <Box mt={0.5}>
        {props.value.length ? (
          props.value.map((entry, index) => (
            <Stack key={`${index}-${entry.place}-${entry.path}`} align="center">
              <Stack.Item width="110px" color="label">
                {entry.where}
              </Stack.Item>
              <Stack.Item grow>
                <b>{entry.name}</b>
                {entry.inside ? ` (+${entry.inside} inside)` : ''}{' '}
                <Box inline color="label" fontSize="0.85em">
                  {entry.path}
                </Box>
              </Stack.Item>
              <Stack.Item>
                <Button
                  icon="xmark"
                  color="transparent"
                  tooltip="Remove from the loadout"
                  onClick={() =>
                    act('loadout_remove', { key: field.key, index })
                  }
                />
              </Stack.Item>
            </Stack>
          ))
        ) : (
          <Box color="label">Empty: nothing stored yet.</Box>
        )}
      </Box>
      <Box mt={1} bold>
        Add an item
      </Box>
      <ChoiceInput options={places} value={place} onSelect={setPlace} />
      <Input
        fluid
        expensive={300}
        value={query}
        placeholder={field.placeholder || 'Search items, e.g. gauze'}
        onChange={(value: string) => {
          setQuery(value);
          act('search', { key: field.key, query: value });
        }}
      />
      {results.map((result) => (
        <Button
          key={result.path}
          fluid
          color="transparent"
          onClick={() => {
            act('loadout_add', { key: field.key, place, path: result.path });
            setQuery('');
          }}
        >
          <SearchResultText result={result} />
        </Button>
      ))}
      {query.length >= 2 && !results.length && (
        <Box color="label">Nothing matches.</Box>
      )}
    </Box>
  );
};

/** The events of the Creative panel's Events tab, as "Category: name", and what one does. */
export const eventChoices = (events: EventOption[]) =>
  events.map((event) => ({
    value: event.value,
    label: event.category ? `${event.category}: ${event.label}` : event.label,
  }));

const EventInput = (props: {
  value: string;
  onSelect: (value: string) => void;
}) => {
  const { data } = useBackend<ObjectData>();
  const events = data.events || [];
  const chosen = events.find((event) => event.value === props.value);
  return (
    <Box>
      <ChoiceInput
        options={eventChoices(events)}
        value={props.value}
        onSelect={props.onSelect}
      />
      {chosen?.description && (
        <Box mt={0.5} color="label" fontSize="0.9em">
          {chosen.description}
        </Box>
      )}
    </Box>
  );
};

const ZoneInput = (props: { field: Field; value: number[] | null }) => {
  const { act, data } = useBackend<ObjectData>();
  const zone = props.value;
  return (
    <Box>
      <Box mb={0.5}>
        {zone ? (
          <>
            ({zone[0]}, {zone[1]}) to ({zone[2]}, {zone[3]}) on level {zone[4]}{' '}
            <Box inline color="label">
              — {zone[2] - zone[0] + 1}×{zone[3] - zone[1] + 1} tiles
            </Box>
          </>
        ) : (
          <Box inline color="label">
            Not set: only this object's own tile.
          </Box>
        )}
      </Box>
      {data.picking ? (
        <NoticeBox info mb={0}>
          Click the corners with the wand…
        </NoticeBox>
      ) : (
        <>
          <Button
            icon="vector-square"
            onClick={() => act('pick_zone', { key: props.field.key })}
          >
            Pick corners
          </Button>
          {data.area_selection && (
            <Button
              icon="object-group"
              tooltip={`Your world-edit selection: ${selectionText(data.area_selection)}.`}
              onClick={() => act('use_selection', { key: props.field.key })}
            >
              Use my world-edit selection
            </Button>
          )}
          {zone && (
            <Button
              icon="xmark"
              onClick={() => act('clear_zone', { key: props.field.key })}
            >
              Clear
            </Button>
          )}
        </>
      )}
    </Box>
  );
};

/** "12×8 at 10, 20" */
export const selectionText = (selection: AreaSelection) =>
  `${selection.width}×${selection.height} at ${selection.x1}, ${selection.y1}`;

/** One picked tile (a Paste area's target corner): pick it with the wand, or clear it. */
const TileInput = (props: { field: Field; value: number[] | null }) => {
  const { act, data } = useBackend<ObjectData>();
  const tile = props.value;
  return (
    <Box>
      <Box mb={0.5}>
        {tile ? (
          <>
            ({tile[0]}, {tile[1]}) on level {tile[2]}
          </>
        ) : (
          <Box inline color="label">
            Not set.
          </Box>
        )}
      </Box>
      {data.picking ? (
        <NoticeBox info mb={0}>
          Click the tile with the wand…
        </NoticeBox>
      ) : (
        <>
          <Button
            icon="crosshairs"
            onClick={() => act('pick_zone', { key: props.field.key })}
          >
            Pick tile
          </Button>
          {tile && (
            <Button
              icon="xmark"
              onClick={() => act('clear_zone', { key: props.field.key })}
            >
              Clear
            </Button>
          )}
        </>
      )}
    </Box>
  );
};

/** "412 tiles, 38 KB of the 512 KB limit" */
export const storedSizeText = (stored: AreaClipView) => {
  const kb = (bytes: number) => `${Math.max(1, Math.round(bytes / 1024))} KB`;
  const parts: string[] = [];
  if (stored.tiles !== undefined) {
    parts.push(`${stored.tiles} tile${stored.tiles === 1 ? '' : 's'}`);
  }
  if (stored.bytes !== undefined && stored.limit !== undefined) {
    parts.push(`${kb(stored.bytes)} of the ${kb(stored.limit)} limit`);
  }
  return parts.join(', ');
};

/** Why "Store selection" can't run, or null. */
export const storeBlocked = (selection?: AreaSelection | null) => {
  if (!selection) {
    return 'Select an area with the world-edit wand first (click two opposite corners with it).';
  }
  return selection.problem || null;
};

/** A stored area (Paste area's snapshot): what is stored, and storing the world-edit selection. */
const AreaClipInput = (props: { field: Field; value: AreaClipView | null }) => {
  const { act, data } = useBackend<ObjectData>();
  const stored = props.value;
  const selection = data.area_selection;
  const blocked = storeBlocked(selection);
  return (
    <Box>
      <Box mb={0.5}>
        {stored ? (
          <>
            {stored.width}×{stored.height} tiles from ({stored.x}, {stored.y})
            on level {stored.z}
            <Box inline color="label">
              {' '}
              — {stored.objects} object{stored.objects === 1 ? '' : 's'}
            </Box>
            {storedSizeText(stored) && (
              <Box color="label" fontSize="0.9em">
                Stored: {storedSizeText(stored)}.
              </Box>
            )}
          </>
        ) : (
          <Box inline color="label">
            Nothing stored yet.
          </Box>
        )}
      </Box>
      {stored?.problem && (
        <NoticeBox danger mb={0.5}>
          {stored.problem}
        </NoticeBox>
      )}
      <Button
        icon="floppy-disk"
        disabled={!!blocked}
        tooltip={
          blocked ||
          (stored
            ? 'Replaces the stored area with your world-edit selection as it is now.'
            : 'Copies your world-edit selection as it is now into this action.')
        }
        onClick={() => act('store_area', { key: props.field.key })}
      >
        Store selection in this action
      </Button>
      <Box mt={0.5} color="label" fontSize="0.9em">
        {selection
          ? `Your selection: ${selectionText(selection)} (${selection.tiles} tiles).`
          : blocked}
      </Box>
    </Box>
  );
};

/** Operations that use a value: a constant or another number gate's number. */
export const operationTakesValue = (op: string) =>
  ['set', 'add', 'sub', 'mul'].includes(op);

/** A new number gate input: count up when the trigger fires. */
export const defaultGateInput = (id: string): GateInput => ({
  id,
  op: 'up',
  amount: 1,
  source: '',
});

/** A number gate's inputs: per input the trigger, its operation and the value it uses. */
const GateInputsInput = (props: {
  field: Field;
  value: GateInput[];
  onChange: (value: GateInput[]) => void;
}) => {
  const { act, data } = useBackend<ObjectData>();
  const { value } = props;
  const operations = props.field.options || [];
  const triggers = idChoices(props.field, data.ids);
  const numberGates = data.ids.filter((entry) => entry.kind === 'number_gate');
  const byId: Record<string, IdEntry> = {};
  for (const entry of data.ids) {
    byId[entry.id] = entry;
  }
  const update = (index: number, change: Partial<GateInput>) =>
    props.onChange(
      value.map((input, i) => (i === index ? { ...input, ...change } : input)),
    );
  const label = (op: string) =>
    operations.find((option) => option.value === op)?.label ?? op;
  return (
    <Box>
      {!value.length && <Box color="label">No inputs yet.</Box>}
      {value.map((input, index) => (
        <Box
          key={index}
          mb={0.75}
          p={0.5}
          style={{ background: 'rgba(255, 255, 255, 0.04)' }}
        >
          <Stack align="center">
            <Stack.Item color="label">When</Stack.Item>
            <Stack.Item grow>
              <Dropdown
                width="100%"
                searchInput
                selected={input.id}
                color={byId[input.id] || !input.id ? undefined : 'average'}
                displayText={
                  byId[input.id]
                    ? describeInput(byId[input.id])
                    : input.id
                      ? `${input.id} (missing)`
                      : 'Choose a trigger...'
                }
                options={triggers.map((entry) => ({
                  displayText: describeInput(entry),
                  value: entry.id,
                }))}
                onSelected={(id: string) => update(index, { id })}
              />
            </Stack.Item>
            <Stack.Item color="label">fires</Stack.Item>
            <Stack.Item>
              {byId[input.id] && (
                <Button
                  icon="up-right-from-square"
                  tooltip="Open its settings"
                  onClick={() => act('open', { id: input.id })}
                />
              )}
              <Button
                icon="trash"
                color="transparent"
                tooltip="Remove"
                onClick={() =>
                  props.onChange(value.filter((_, i) => i !== index))
                }
              />
            </Stack.Item>
          </Stack>
          <Stack mt={0.5} align="center" wrap>
            <Stack.Item>
              <Dropdown
                width="190px"
                selected={label(input.op)}
                options={operations.map((option) => ({
                  displayText: option.label,
                  value: option.value,
                }))}
                onSelected={(op: string) => update(index, { op })}
              />
            </Stack.Item>
            {operationTakesValue(input.op) && (
              <>
                <Stack.Item>
                  <Dropdown
                    width="150px"
                    selected={input.source || ''}
                    displayText={
                      input.source ? `${input.source}'s number` : 'a number'
                    }
                    options={[
                      { displayText: 'a number', value: '' },
                      ...numberGates.map((entry) => ({
                        displayText: `${entry.id}'s number`,
                        value: entry.id,
                      })),
                    ]}
                    onSelected={(source: string) => update(index, { source })}
                  />
                </Stack.Item>
                {!input.source && (
                  <Stack.Item>
                    <NumberInput
                      value={input.amount ?? 1}
                      minValue={-100000}
                      maxValue={100000}
                      step={1}
                      width="80px"
                      onChange={(amount: number) => update(index, { amount })}
                    />
                  </Stack.Item>
                )}
              </>
            )}
          </Stack>
        </Box>
      ))}
      <Dropdown
        width="100%"
        searchInput
        selected={null}
        placeholder="Add an input..."
        disabled={!triggers.length}
        options={triggers.map((entry) => ({
          displayText: describeInput(entry),
          value: entry.id,
        }))}
        onSelected={(id: string) =>
          props.onChange([...value, defaultGateInput(id)])
        }
      />
    </Box>
  );
};

/** What a gate is in the running test run. */
export const gateLiveText = (gate: GateLive, kind: string) => {
  if (!gate.running) {
    return 'No test run is running.';
  }
  if (!gate.listening) {
    return `Not listening${kind === 'number_gate' ? ` (number ${gate.value})` : ''}.`;
  }
  const state = gate.state ? 'true' : 'false';
  return kind === 'number_gate'
    ? `Number ${gate.value}, condition ${state}.`
    : `Currently ${state}.`;
};

const GateSection = (props: { gate: GateLive }) => {
  const { data } = useBackend<ObjectData>();
  const { gate } = props;
  return (
    <Section title="Test run">
      <Box color={gate.running ? (gate.state ? 'good' : undefined) : 'label'}>
        <Icon name={gate.state ? 'toggle-on' : 'toggle-off'} mr={1} />
        {gateLiveText(gate, data.kind)}
      </Box>
      {gate.stopped && (
        <Box color="bad" mt={0.5}>
          <Icon name="circle-exclamation" mr={0.5} />
          {gate.stopped}
        </Box>
      )}
    </Section>
  );
};

/** Which extra inputs an effect kind has. */
export const effectNeeds = (kind: string) => ({
  amount: [
    'brute',
    'burn',
    'tox',
    'oxy',
    'unconscious',
    'bleed',
    'reagent',
  ].includes(kind),
  zone: ['brute', 'burn', 'wound', 'bleed'].includes(kind),
  wound: kind === 'wound',
  disease: kind === 'disease',
  reagent: kind === 'reagent',
});

const AMOUNT_LABELS: Record<string, string> = {
  unconscious: 'seconds',
  bleed: 'blood lost',
  reagent: 'units',
};

const EffectsInput = (props: {
  value: Effect[];
  onChange: (value: Effect[]) => void;
}) => {
  const { data } = useBackend<ObjectData>();
  const { value } = props;
  const update = (index: number, change: Partial<Effect>) =>
    props.onChange(
      value.map((effect, i) =>
        i === index ? { ...effect, ...change } : effect,
      ),
    );
  const label = (options: Option[], current?: string) =>
    options.find((option) => option.value === current)?.label ?? 'Choose...';
  return (
    <Box>
      {!value.length && <Box color="label">Healthy: no effects.</Box>}
      {value.map((effect, index) => {
        const needs = effectNeeds(effect.kind);
        return (
          <Box
            key={index}
            mb={0.75}
            p={0.5}
            style={{ background: 'rgba(255, 255, 255, 0.04)' }}
          >
            <Stack align="center" wrap>
              <Stack.Item grow bold>
                {label(data.effect_kinds, effect.kind)}
              </Stack.Item>
              <Stack.Item color="label">Chance</Stack.Item>
              <Stack.Item>
                <NumberInput
                  value={effect.chance}
                  minValue={0}
                  maxValue={100}
                  step={5}
                  unit="%"
                  width="60px"
                  onChange={(chance: number) => update(index, { chance })}
                />
              </Stack.Item>
              <Stack.Item>
                <Button
                  icon="trash"
                  color="transparent"
                  tooltip="Remove"
                  onClick={() =>
                    props.onChange(value.filter((_, i) => i !== index))
                  }
                />
              </Stack.Item>
            </Stack>
            <Stack mt={0.5} align="center" wrap>
              {needs.amount && (
                <Stack.Item>
                  <NumberInput
                    value={effect.amount ?? 0}
                    minValue={0}
                    maxValue={3600}
                    step={1}
                    unit={AMOUNT_LABELS[effect.kind] || 'damage'}
                    width="110px"
                    onChange={(amount: number) => update(index, { amount })}
                  />
                </Stack.Item>
              )}
              {needs.zone && (
                <Stack.Item>
                  <Dropdown
                    width="110px"
                    selected={label(data.body_zones, effect.zone)}
                    options={data.body_zones.map((option) => ({
                      displayText: option.label,
                      value: option.value,
                    }))}
                    onSelected={(zone: string) => update(index, { zone })}
                  />
                </Stack.Item>
              )}
              {needs.wound && (
                <Stack.Item grow>
                  <Dropdown
                    width="100%"
                    selected={label(data.wounds, effect.type)}
                    options={data.wounds.map((option) => ({
                      displayText: option.label,
                      value: option.value,
                    }))}
                    onSelected={(type: string) => update(index, { type })}
                  />
                </Stack.Item>
              )}
              {needs.disease && (
                <Stack.Item grow>
                  <Dropdown
                    width="100%"
                    selected={label(data.diseases, effect.type)}
                    options={data.diseases.map((option) => ({
                      displayText: option.label,
                      value: option.value,
                    }))}
                    onSelected={(type: string) => update(index, { type })}
                  />
                </Stack.Item>
              )}
              {needs.reagent && (
                <Stack.Item grow>
                  <Dropdown
                    width="100%"
                    searchInput
                    selected={effect.type}
                    displayText={label(data.reagents, effect.type)}
                    options={data.reagents.map((option) => ({
                      displayText: option.label,
                      value: option.value,
                    }))}
                    onSelected={(type: string) => update(index, { type })}
                  />
                </Stack.Item>
              )}
            </Stack>
          </Box>
        );
      })}
      <Dropdown
        width="100%"
        selected="Add an effect..."
        options={data.effect_kinds.map((option) => ({
          displayText: option.label,
          value: option.value,
        }))}
        onSelected={(kind: string) =>
          props.onChange([...value, defaultEffect(kind, data)])
        }
      />
    </Box>
  );
};

/** A new effect with sensible defaults. */
export const defaultEffect = (kind: string, data: ObjectData): Effect => {
  const effect: Effect = { kind, chance: 100 };
  const needs = effectNeeds(kind);
  if (needs.amount) {
    effect.amount =
      kind === 'unconscious'
        ? 300
        : kind === 'bleed'
          ? 50
          : kind === 'reagent'
            ? 10
            : 20;
  }
  if (needs.zone) {
    effect.zone = 'chest';
  }
  if (needs.wound) {
    effect.type = data.wounds[0]?.value;
  }
  if (needs.disease) {
    effect.type = data.diseases[0]?.value;
  }
  if (needs.reagent) {
    effect.type = data.reagents?.[0]?.value;
  }
  return effect;
};

const NpcSection = () => {
  const { act, data } = useBackend<ObjectData>();
  const { npc } = data;
  return (
    <Section
      title="NPC"
      buttons={
        <Button icon="rotate" onClick={() => act('spawn_npc')}>
          {npc ? 'Respawn now' : 'Spawn now'}
        </Button>
      }
    >
      {npc ? (
        <Box>
          <b>{npc.name}</b> is {npc.stat}, health {Math.round(npc.health)}.
          {npc.outdated ? (
            <Box color="average" mt={0.5}>
              <Icon name="rotate" mr={0.5} />
              Settings changed: press Respawn now to apply them.
            </Box>
          ) : (
            <Box color="label" fontSize="0.9em">
              Changes apply the next time the NPC is created.
            </Box>
          )}
        </Box>
      ) : (
        <Box color="label">
          Not spawned. It appears at the start (if set) or by a Spawn NPC
          action.
        </Box>
      )}
    </Section>
  );
};
