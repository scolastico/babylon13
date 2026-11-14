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
    | 'zone'
    | 'effects';
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
};

export type IdEntry = { id: string; kind_name: string; category: string };

export type Effect = {
  kind: string;
  chance: number;
  amount?: number;
  zone?: string;
  type?: string;
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
  id: string;
  values: Record<string, any>;
  issues: Record<string, string>;
  ids: IdEntry[];
  position: { x: number; y: number; z: number } | null;
  summary: string;
  search: {
    key: string;
    query: string;
    results: { path: string; name: string }[];
  } | null;
  notice: { text: string; ok: boolean; id: number; key?: string } | null;
  picking: boolean;
  npc?: { name: string; health: number; stat: string } | null;
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
        {data.notice && !data.notice.ok && (
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
                help="Other parts refer to this object by its id. A marker named start is where players begin."
                issue={data.issues.id}
              />
            </LabeledList.Item>
            {fields.map((field) => (
              <LabeledList.Item
                key={field.key}
                label={field.label}
                verticalAlign="top"
              >
                <FieldInput field={field} />
                <FieldHelp help={field.help} issue={data.issues[field.key]} />
              </LabeledList.Item>
            ))}
          </LabeledList>
        </Section>
        {data.kind === 'npc_spawner' && <NpcSection />}
        <Section>
          <Stack>
            {isAction && (
              <Stack.Item>
                <Button
                  icon="eye"
                  tooltip="Run this action for yourself now (nobody else sees it)."
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

const FieldHelp = (props: { help: string | null; issue?: string }) => (
  <>
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
    case 'zone':
      return <ZoneInput field={field} value={value} />;
    case 'effects':
      return <EffectsInput value={value || []} onChange={set} />;
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

const IdPicker = (props: {
  field: Field;
  value: string;
  ids: IdEntry[];
  onSelect: (value: string) => void;
}) => {
  const choices = idChoices(props.field, props.ids);
  return (
    <Stack>
      <Stack.Item grow>
        <Dropdown
          width="100%"
          selected={props.value || '(none)'}
          options={[
            { displayText: '(none)', value: '' },
            ...choices.map((entry) => ({
              displayText: `${entry.id} (${entry.kind_name})`,
              value: entry.id,
            })),
          ]}
          onSelected={(value: string) => props.onSelect(value)}
        />
      </Stack.Item>
      <Stack.Item width="110px">
        <CommitInput
          value={props.value}
          placeholder="or type an id"
          onCommit={props.onSelect}
        />
      </Stack.Item>
    </Stack>
  );
};

const IdListInput = (props: {
  field: Field;
  value: string[];
  onChange: (value: string[]) => void;
}) => {
  const { data } = useBackend<ObjectData>();
  const { value } = props;
  const known = new Set(data.ids.map((entry) => entry.id));
  const choices = idChoices(props.field, data.ids).filter(
    (entry) => !value.includes(entry.id),
  );
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
        <Stack key={id} align="center" mb={0.25}>
          <Stack.Item color="label" width="18px">
            {index + 1}.
          </Stack.Item>
          <Stack.Item grow color={known.has(id) ? undefined : 'average'}>
            {id}
            {!known.has(id) && ' (missing)'}
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
                props.onChange(value.filter((entry) => entry !== id))
              }
            />
          </Stack.Item>
        </Stack>
      ))}
      <Dropdown
        width="100%"
        selected="Add..."
        disabled={!choices.length}
        options={choices.map((entry) => ({
          displayText: `${entry.id} (${entry.kind_name})`,
          value: entry.id,
        }))}
        onSelected={(id: string) => props.onChange([...value, id])}
      />
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
          {result.name}{' '}
          <Box inline color="label" fontSize="0.85em">
            {result.path}
          </Box>
        </Button>
      ))}
      {query.length >= 2 && !results.length && (
        <Box color="label">Nothing matches.</Box>
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
  const { act, data } = useBackend<ObjectData>();
  const { value } = props;
  const [reagentQuery, setReagentQuery] = useState('');
  const update = (index: number, change: Partial<Effect>) =>
    props.onChange(
      value.map((effect, i) =>
        i === index ? { ...effect, ...change } : effect,
      ),
    );
  const label = (options: Option[], current?: string) =>
    options.find((option) => option.value === current)?.label ?? 'Choose...';
  const reagentResults =
    data.search?.key === 'effect_reagent' ? data.search.results : [];
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
                  <Box color="label" fontSize="0.85em">
                    {effect.type || 'No reagent chosen'}
                  </Box>
                  <Input
                    fluid
                    value={reagentQuery}
                    placeholder="Search reagents..."
                    onChange={(query: string) => {
                      setReagentQuery(query);
                      act('search', { key: 'effect_reagent', query });
                    }}
                  />
                  {reagentResults.slice(0, 8).map((result) => (
                    <Button
                      key={result.path}
                      fluid
                      color="transparent"
                      onClick={() => {
                        update(index, { type: result.path });
                        setReagentQuery('');
                      }}
                    >
                      {result.name}
                    </Button>
                  ))}
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
    effect.type = '/datum/reagent/water';
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
          <Box color="label" fontSize="0.9em">
            Changes apply the next time the NPC is created: press Respawn now.
          </Box>
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
