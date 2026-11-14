// Area tools of the tutorial wand's Select mode (modular_babylon/code/tutorial/area_tools.dm):
// select a rectangle with two clicks, then copy, paste, fill, border, clear or undo. Every
// action is checked again on the server; disabled buttons say why.
import { useState } from 'react';
import {
  Box,
  Button,
  Icon,
  Input,
  NoticeBox,
  Section,
  Stack,
} from 'tgui-core/components';
import { createSearch } from 'tgui-core/string';

import { useBackend } from '../backend';

export type Material = { path: string; name: string; group: string };

export type AreaStats = {
  objects: number;
  tutorial: number;
  mobs: number;
  players: number;
  locked: number;
  protected?: number;
};

export type AreaResult = { text: string; ok: boolean; id: number };

export type AreaData = {
  step: 'corner1' | 'corner2' | 'selected' | 'paste_target' | 'paste_confirm';
  corner: { x: number; y: number } | null;
  selection: {
    x1: number;
    y1: number;
    x2: number;
    y2: number;
    z: number;
    width: number;
    height: number;
    tiles: number;
    problem: string | null;
    stats: AreaStats | null;
  } | null;
  clipboard: {
    width: number;
    height: number;
    objects: number;
    tutorial: number;
    x: number;
    y: number;
    not_copied?: string | null;
  } | null;
  paste: {
    target: { x1: number; y1: number; x2: number; y2: number } | null;
    problem: string | null;
    replaces?: { objects: number; tutorial: number; mobs: number } | null;
    suffix?: string | null;
    suffix_error?: string | null;
  } | null;
  paste_suffix?: string | null;
  undo: string | null;
  undo_approximate?: boolean;
  pasted?: number;
  result?: AreaResult | null;
  busy: boolean;
  cooldown: number;
  max_tiles: number;
  material: string | null;
  only_empty: boolean;
  skip_space: boolean;
  suffix_mode: 'auto' | 'custom' | 'keep';
  custom_suffix: string;
  clear_to: 'plating' | 'material';
};

type AreaWandData = {
  area?: AreaData;
  materials?: Material[];
};

/** "12×8 (96 tiles)" */
export const sizeText = (width: number, height: number) => {
  const tiles = width * height;
  return `${width}×${height} (${tiles.toLocaleString('en-US')} tile${tiles === 1 ? '' : 's'})`;
};

const plural = (count: number, word: string) =>
  `${count} ${word}${count === 1 ? '' : 's'}`;

/** What Paste and Clear undo cannot bring back exactly. */
export const APPROXIMATE_UNDO =
  'Undo puts it back approximately: floor markings and machine settings are lost.';

/** Said before an operation that would replace the pending undo step. */
export const replacesUndo = (area: AreaData) =>
  area.undo ? `This replaces your undo of: ${area.undo}.` : null;

/** "floor (dark)" for materials whose names repeat: the end of the path tells them apart. */
export const materialLabel = (material: Material, materials: Material[]) => {
  const same = materials.filter((m) => m.name === material.name);
  if (same.length < 2) {
    return material.name;
  }
  const tail = material.path.split('/').pop() || '';
  return `${material.name} (${tail.replace(/_/g, ' ')})`;
};

/** What the next click with the wand does. */
export const stepHint = (area: AreaData) => {
  switch (area.step) {
    case 'corner2':
      return `Corner 1 is at ${area.corner?.x}, ${area.corner?.y}. Click the opposite corner.`;
    case 'selected':
      return 'Choose what to do with the selection below. A new click with the wand starts a new selection.';
    case 'paste_target':
      return "Click the tile that becomes the copy's bottom-left (south-west) corner. The copy spreads up and to the right from there.";
    case 'paste_confirm':
      return 'Check the orange outline, then confirm. Click another tile to move it.';
    default:
      return 'Click the first corner of an area with the wand.';
  }
};

/** Why an operation can't run right now, or null. */
export const blockedReason = (
  area: AreaData,
  needs: { selection?: boolean; clipboard?: boolean; material?: boolean },
  materials: Material[],
) => {
  if (area.busy) {
    return "Another builder's area operation is still running.";
  }
  if (area.cooldown > 0) {
    return `Wait ${area.cooldown} more seconds: bigger areas need a longer pause between operations.`;
  }
  if (needs.selection) {
    if (!area.selection) {
      return 'Select an area first: click two opposite corners with the wand.';
    }
    if (area.selection.problem) {
      return area.selection.problem;
    }
  }
  if (needs.clipboard && !area.clipboard) {
    return 'Copy an area first.';
  }
  if (needs.material && !materials.find((m) => m.path === area.material)) {
    return 'Pick a floor, wall or structure below first.';
  }
  return null;
};

/** The reason under a disabled button. */
const Reason = (props: { text: string | null }) =>
  props.text ? (
    <Box color="label" fontSize="0.9em" mt={0.5}>
      <Icon name="circle-info" mr={0.5} />
      {props.text}
    </Box>
  ) : null;

export const AreaTools = () => {
  const { act, data } = useBackend<AreaWandData>();
  const area = data.area;
  const materials = data.materials || [];
  if (!area) {
    return null;
  }
  const picked = materials.find((m) => m.path === area.material) || null;
  return (
    <>
      <StepBanner area={area} />
      <ResultBox result={area.result} />
      <SelectionSection area={area} />
      <CopyPasteSection area={area} materials={materials} />
      <Section title="Fill and border">
        <MaterialPicker materials={materials} selected={area.material} />
        <Button.Checkbox
          mt={1}
          checked={area.only_empty}
          tooltip="Skips walls and tiles with furniture, machines, items or mobs on them. Pipes and cables under the floor don't count. Without it, objects stay where they are, also under a new wall."
          onClick={() =>
            act('area_option', {
              option: 'only_empty',
              value: !area.only_empty,
            })
          }
        >
          Only empty tiles
        </Button.Checkbox>
        <FillButtons area={area} materials={materials} picked={picked} />
      </Section>
      <ClearSection area={area} materials={materials} picked={picked} />
      <Section title="Undo">
        <Button
          icon="rotate-left"
          disabled={!area.undo || area.busy}
          onClick={() => act('area_undo')}
        >
          {area.undo
            ? `Undo: ${area.undo}${area.undo_approximate ? ' (approximate)' : ''}`
            : 'Undo'}
        </Button>
        {area.undo_approximate && (
          <Box color="average" fontSize="0.9em" mt={0.5}>
            <Icon name="triangle-exclamation" mr={0.5} />
            Restores the whole rectangle as it was before, also undoing later
            changes there. Floor markings and machine settings are lost.
          </Box>
        )}
        <Reason
          text={
            !area.undo
              ? 'Nothing to undo yet. Undo takes back your last paste, fill, border or clear (one step).'
              : area.busy
                ? "Another builder's area operation is still running."
                : null
          }
        />
      </Section>
    </>
  );
};

/** The last area operation's outcome, kept in the panel until dismissed. */
export const ResultBox = (props: { result?: AreaResult | null }) => {
  const [hiddenId, setHiddenId] = useState(-1);
  const { result } = props;
  if (!result || result.id === hiddenId) {
    return null;
  }
  const content = (
    <Stack align="center">
      <Stack.Item>
        <Icon name={result.ok ? 'check' : 'triangle-exclamation'} />
      </Stack.Item>
      <Stack.Item grow>{result.text}</Stack.Item>
      <Stack.Item>
        <Button
          icon="xmark"
          color="transparent"
          tooltip="Dismiss"
          onClick={() => setHiddenId(result.id)}
        />
      </Stack.Item>
    </Stack>
  );
  return result.ok ? (
    <NoticeBox success>{content}</NoticeBox>
  ) : (
    <NoticeBox danger>{content}</NoticeBox>
  );
};

const StepBanner = (props: { area: AreaData }) => {
  const { act } = useBackend();
  const { area } = props;
  const pasting = area.step === 'paste_target' || area.step === 'paste_confirm';
  const content = (
    <Stack align="center">
      <Stack.Item>
        <Icon name={pasting ? 'paste' : 'vector-square'} size={1.4} mr={0.5} />
      </Stack.Item>
      <Stack.Item grow>
        <Box bold>
          {pasting
            ? 'Paste'
            : area.step === 'selected'
              ? 'Area selected'
              : `Select: corner ${area.step === 'corner2' ? 2 : 1} of 2`}
        </Box>
        <Box>{stepHint(area)}</Box>
      </Stack.Item>
      {(area.step === 'corner2' || area.step === 'selected') && (
        <Stack.Item>
          <Button icon="xmark" onClick={() => act('area_reselect')}>
            {area.step === 'corner2' ? 'Cancel' : 'Deselect'}
          </Button>
        </Stack.Item>
      )}
      <Stack.Item>
        <Button
          icon="plus"
          tooltip="Leave Select mode (right-clicking the wand while holding it also switches modes)."
          onClick={() => act('mode', { mode: 'place' })}
        >
          Back to Place
        </Button>
      </Stack.Item>
    </Stack>
  );
  // Paste mode stands out in the default (yellow) notice colour.
  return pasting ? (
    <NoticeBox>{content}</NoticeBox>
  ) : (
    <NoticeBox info>{content}</NoticeBox>
  );
};

const SelectionSection = (props: { area: AreaData }) => {
  const { area } = props;
  const selection = area.selection;
  return (
    <Section title="Selection">
      {selection ? (
        <>
          <Box>
            <Box inline bold fontSize="1.2em">
              {sizeText(selection.width, selection.height)}
            </Box>
            <Box inline color="label" ml={1}>
              from {selection.x1}, {selection.y1} to {selection.x2},{' '}
              {selection.y2}
            </Box>
          </Box>
          {selection.stats && (
            <Box color="label" mt={0.5}>
              Contains {plural(selection.stats.objects, 'object')},{' '}
              {plural(selection.stats.tutorial, 'tutorial object')},{' '}
              {plural(selection.stats.mobs, 'mob')}
              {selection.stats.players > 0 &&
                `, ${plural(selection.stats.players, 'player')} (never removed)`}
              {selection.stats.locked > 0 &&
                `, ${plural(selection.stats.locked, 'protected tile')} (walls or floors the game won't let you change, outlined in red; left alone)`}
              {!!selection.stats.protected &&
                `, ${plural(selection.stats.protected, 'protected object')} (never copied or removed)`}
              .
            </Box>
          )}
          {selection.problem && (
            <Box color="bad" mt={0.5}>
              <Icon name="triangle-exclamation" mr={0.5} />
              {selection.problem}
            </Box>
          )}
        </>
      ) : (
        <Box color="label">
          Nothing selected. Areas can be up to{' '}
          {area.max_tiles.toLocaleString('en-US')} tiles on one deck.
        </Box>
      )}
    </Section>
  );
};

const CopyPasteSection = (props: { area: AreaData; materials: Material[] }) => {
  const { act } = useBackend();
  const { area, materials } = props;
  const clip = area.clipboard;
  const copyBlocked = blockedReason(area, { selection: true }, materials);
  const pasteBlocked = blockedReason(area, { clipboard: true }, materials);
  const pasting = area.step === 'paste_target' || area.step === 'paste_confirm';
  const target = area.paste?.target;
  const confirmBlocked = !target
    ? 'Click where the copy goes first.'
    : area.paste?.problem ||
      area.paste?.suffix_error ||
      blockedReason(area, {}, materials);
  const replaces = area.paste?.replaces;
  return (
    <Section title="Copy and paste">
      <Box mb={1}>
        <Icon name="clipboard" mr={1} color="label" />
        {clip ? (
          <>
            Clipboard: <b>{sizeText(clip.width, clip.height)}</b> copied at{' '}
            {clip.x}, {clip.y} — {plural(clip.objects, 'object')}
            {clip.tutorial > 0 &&
              `, ${plural(clip.tutorial, 'tutorial object')}`}
            {clip.not_copied && (
              <Box color="label" fontSize="0.9em" mt={0.5}>
                {clip.not_copied}
              </Box>
            )}
          </>
        ) : (
          <Box inline color="label">
            The clipboard is empty.
          </Box>
        )}
      </Box>
      {!pasting ? (
        <Stack>
          <Stack.Item grow basis={0}>
            <Button
              fluid
              icon="copy"
              disabled={!!copyBlocked}
              onClick={() => act('area_copy')}
            >
              Copy selection
            </Button>
            <Reason text={copyBlocked} />
          </Stack.Item>
          <Stack.Item grow basis={0}>
            <Button
              fluid
              icon="paste"
              disabled={!!pasteBlocked}
              onClick={() => act('area_paste')}
            >
              Paste…
            </Button>
            <Reason text={pasteBlocked} />
          </Stack.Item>
        </Stack>
      ) : (
        <Box>
          {target ? (
            <Box mb={1}>
              Paste {clip && sizeText(clip.width, clip.height)} from{' '}
              <b>
                {target.x1}, {target.y1}
              </b>{' '}
              (bottom-left) to{' '}
              <b>
                {target.x2}, {target.y2}
              </b>{' '}
              (top-right).
              <Box color="average" mt={0.5}>
                It replaces everything there
                {replaces
                  ? `: ${plural(replaces.objects, 'object')}, ${plural(replaces.tutorial, 'tutorial object')} and ${plural(replaces.mobs, 'mob')}`
                  : ''}
                . Players are moved aside. {APPROXIMATE_UNDO}
              </Box>
            </Box>
          ) : (
            <Box mb={1} color="label">
              Waiting for a click with the wand: the clicked tile becomes the
              bottom-left (south-west) corner.
            </Box>
          )}
          {area.paste?.problem && (
            <Box color="bad" mb={1}>
              <Icon name="triangle-exclamation" mr={0.5} />
              {area.paste.problem}
            </Box>
          )}
          <Stack>
            <Stack.Item grow basis={0}>
              <Button
                fluid
                icon="check"
                color="good"
                disabled={!!confirmBlocked}
                onClick={() => act('area_paste_confirm')}
              >
                Confirm paste
              </Button>
              <Reason
                text={target ? confirmBlocked || replacesUndo(area) : null}
              />
            </Stack.Item>
            <Stack.Item grow basis={0}>
              <Button
                fluid
                icon="xmark"
                onClick={() => act('area_paste_cancel')}
              >
                {area.pasted ? 'Stop pasting' : 'Cancel'}
              </Button>
            </Stack.Item>
          </Stack>
        </Box>
      )}
      {!!clip?.tutorial && <SuffixOptions area={area} />}
      <Button.Checkbox
        mt={1}
        checked={area.skip_space}
        tooltip="On: tiles that were space in the copy leave the target as it is, so pasting a room next to another doesn't punch holes into it."
        onClick={() =>
          act('area_option', { option: 'skip_space', value: !area.skip_space })
        }
      >
        Don't overwrite tiles that are empty space in the copy
      </Button.Checkbox>
    </Section>
  );
};

const SuffixOptions = (props: { area: AreaData }) => {
  const { act } = useBackend();
  const { area } = props;
  const suffix = area.paste ? area.paste.suffix : area.paste_suffix;
  const error = area.paste?.suffix_error;
  const choices: { id: AreaData['suffix_mode']; label: string; tip: string }[] =
    [
      {
        id: 'auto',
        label: `Auto${area.suffix_mode === 'auto' && suffix ? ` (${suffix})` : ''}`,
        tip: 'The first free suffix: _2, then _3 …',
      },
      {
        id: 'custom',
        label: 'Custom',
        tip: 'Your own suffix, such as _b.',
      },
      {
        id: 'keep',
        label: 'Keep ids',
        tip: 'Only when the ids are free, e.g. after deleting the original to move a room.',
      },
    ];
  return (
    <Box mt={1}>
      <Box bold>Names of pasted tutorial objects</Box>
      <Box color="label" fontSize="0.9em" mb={0.5}>
        Each pasted tutorial object gets a suffix (zone1 → zone1_2). Links among
        the pasted objects follow; links to objects outside the copy stay.
      </Box>
      {choices.map((choice) => (
        <Button
          key={choice.id}
          selected={area.suffix_mode === choice.id}
          tooltip={choice.tip}
          onClick={() =>
            act('area_option', { option: 'suffix_mode', value: choice.id })
          }
        >
          {choice.label}
        </Button>
      ))}
      {area.suffix_mode === 'custom' && (
        <Input
          ml={1}
          width="140px"
          placeholder="e.g. _b, then Enter"
          value={area.custom_suffix}
          onBlur={(value: string) =>
            act('area_option', { option: 'custom_suffix', value })
          }
          onEnter={(value: string) =>
            act('area_option', { option: 'custom_suffix', value })
          }
        />
      )}
      {error && (
        <Box color="bad" mt={0.5}>
          <Icon name="triangle-exclamation" mr={0.5} />
          {error}
        </Box>
      )}
    </Box>
  );
};

/** Searchable list of the turfs and structures Fill, Border and Clear can use. */
export const MaterialPicker = (props: {
  materials: Material[];
  selected: string | null;
}) => {
  const { act } = useBackend();
  const [query, setQuery] = useState('');
  const search = createSearch(
    query,
    (material: Material) =>
      `${material.name} ${material.group} ${material.path}`,
  );
  const shown = (
    query ? props.materials.filter(search) : props.materials
  ).slice(0, 150);
  const picked = props.materials.find((m) => m.path === props.selected);
  let lastGroup = '';
  return (
    <Box>
      <Stack align="center" mb={0.5}>
        <Stack.Item grow>
          {picked ? (
            <>
              Using <b>{picked.name}</b>{' '}
              <Box inline color="label">
                ({picked.group})
              </Box>
            </>
          ) : (
            <Box color="label">Pick a floor, wall or structure:</Box>
          )}
        </Stack.Item>
        <Stack.Item>
          <Input
            placeholder="Search, e.g. wall"
            value={query}
            onChange={(value: string) => setQuery(value)}
            width="150px"
          />
        </Stack.Item>
      </Stack>
      <Box
        style={{
          maxHeight: '140px',
          overflowY: 'auto',
          border: '1px solid rgba(255, 255, 255, 0.1)',
        }}
        p={0.5}
      >
        {!shown.length && <Box color="label">Nothing matches.</Box>}
        {shown.map((material) => {
          const header = material.group !== lastGroup;
          lastGroup = material.group;
          return (
            <Box key={material.path}>
              {header && (
                <Box bold color="label" mt={0.5}>
                  {material.group}
                </Box>
              )}
              <Button
                fluid
                color="transparent"
                tooltip={material.path}
                selected={material.path === props.selected}
                onClick={() =>
                  act('area_option', {
                    option: 'material',
                    value: material.path,
                  })
                }
              >
                {materialLabel(material, props.materials)}
              </Button>
            </Box>
          );
        })}
      </Box>
    </Box>
  );
};

const FillButtons = (props: {
  area: AreaData;
  materials: Material[];
  picked: Material | null;
}) => {
  const { act } = useBackend();
  const { area, materials, picked } = props;
  const blocked = blockedReason(
    area,
    { selection: true, material: true },
    materials,
  );
  return (
    <>
      <Stack mt={1}>
        <Stack.Item grow basis={0}>
          <Button
            fluid
            icon="fill-drip"
            disabled={!!blocked}
            onClick={() => act('area_fill')}
          >
            Fill{picked ? ` with ${picked.name}` : ''}
          </Button>
        </Stack.Item>
        <Stack.Item grow basis={0}>
          <Button
            fluid
            icon="border-all"
            disabled={!!blocked}
            onClick={() => act('area_border')}
          >
            Border{picked ? ` of ${picked.name}` : ''}
          </Button>
        </Stack.Item>
      </Stack>
      <Reason text={blocked || replacesUndo(area)} />
    </>
  );
};

const ClearSection = (props: {
  area: AreaData;
  materials: Material[];
  picked: Material | null;
}) => {
  const { act } = useBackend();
  const { area, materials, picked } = props;
  const pickedTurf = picked && picked.group !== 'Structures' ? picked : null;
  const blocked =
    blockedReason(area, { selection: true }, materials) ||
    (area.clear_to === 'material' && !pickedTurf
      ? 'Pick a floor or wall above to clear to, or clear to plating.'
      : null);
  const stats = area.selection?.stats;
  const floor =
    area.clear_to === 'material' && pickedTurf ? pickedTurf.name : 'plating';
  const removes = stats
    ? `${plural(stats.objects, 'object')}, ${plural(stats.mobs, 'mob')} and ${plural(stats.tutorial, 'tutorial object')}`
    : 'everything';
  return (
    <Section title="Clear">
      <Box color="label" mb={0.5}>
        Removes objects, mobs and tutorial objects; every tile becomes {floor}.
        Players are moved aside, never removed.
      </Box>
      <Box mb={1}>
        Tiles become:{' '}
        <Button
          selected={area.clear_to === 'plating'}
          onClick={() =>
            act('area_option', { option: 'clear_to', value: 'plating' })
          }
        >
          Plating
        </Button>
        <Button
          selected={area.clear_to === 'material'}
          disabled={!pickedTurf}
          tooltip={
            pickedTurf ? undefined : 'Pick a floor or wall in the list above.'
          }
          onClick={() =>
            act('area_option', { option: 'clear_to', value: 'material' })
          }
        >
          {pickedTurf ? pickedTurf.name : 'Picked floor'}
        </Button>
      </Box>
      <Button.Confirm
        icon="trash"
        color="bad"
        disabled={!!blocked}
        confirmContent={`Remove ${removes}? Undo is approximate.`}
        confirmIcon="triangle-exclamation"
        onClick={() => act('area_clear')}
      >
        Clear selection
      </Button.Confirm>
      <Box color="label" fontSize="0.9em" mt={0.5}>
        {APPROXIMATE_UNDO}
      </Box>
      <Reason text={blocked || replacesUndo(area)} />
    </Section>
  );
};
