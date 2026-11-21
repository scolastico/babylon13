// Babylon world-edit wand (modular_babylon/code/tutorial/world_edit.dm): the area tools, split off
// the tutorial wand (spec 12 #1). Click two corners with the wand to select an area, then copy,
// paste, fill, border, clear or undo here. Every action is checked again on the server.
import { NoticeBox, Section, Stack } from 'tgui-core/components';

import { useBackend } from '../backend';
import { Window } from '../layouts';
import { type AreaData, AreaTools, type Material } from './BabylonTutorialArea';

export type WorldEditData = {
  creative: boolean;
  notice: { text: string; ok: boolean; id: number } | null;
  area?: AreaData;
  materials?: Material[];
};

export const BabylonWorldEditWand = () => {
  const { data } = useBackend<WorldEditData>();
  return (
    <Window width={540} height={680} title="World-edit wand">
      <Window.Content scrollable>
        <Stack vertical>
          {!data.creative && (
            <Stack.Item>
              <NoticeBox danger>
                The world-edit wand only works in creative worlds.
              </NoticeBox>
            </Stack.Item>
          )}
          <Stack.Item>
            {data.area ? (
              <AreaTools />
            ) : (
              <Section>Hold the wand to use the area tools.</Section>
            )}
          </Stack.Item>
        </Stack>
      </Window.Content>
    </Window>
  );
};
