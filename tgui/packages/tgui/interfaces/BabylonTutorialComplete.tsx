// "Tutorial complete!" (modular_babylon/code/tutorial/actions.dm, the Complete action).
import { Box, Button, Icon, Section, Stack } from 'tgui-core/components';

import { useBackend } from '../backend';
import { Window } from '../layouts';

export type CompleteData = {
  text: string;
  test_run: boolean;
  /** A Preview's Complete: only Close (Run again would restart the world's run for everyone). */
  preview?: boolean;
  title: string | null;
};

export const BabylonTutorialComplete = () => {
  const { act, data } = useBackend<CompleteData>();
  return (
    <Window width={420} height={300} title="Tutorial complete!">
      <Window.Content>
        <Section fill>
          <Stack fill vertical align="center" justify="space-around">
            <Stack.Item>
              <Icon name="flag-checkered" size={3} color="good" />
            </Stack.Item>
            <Stack.Item>
              <Box fontSize="1.6em" bold textAlign="center">
                Tutorial complete!
              </Box>
            </Stack.Item>
            {data.title && (
              <Stack.Item>
                <Box color="label" textAlign="center">
                  {data.title}
                </Box>
              </Stack.Item>
            )}
            <Stack.Item>
              <Box textAlign="center" style={{ whiteSpace: 'pre-wrap' }}>
                {data.text}
              </Box>
            </Stack.Item>
            <Stack.Item>
              {data.test_run ? (
                <>
                  <Box color="label" textAlign="center" mb={1}>
                    {data.preview
                      ? 'This was a preview, for you only: players get a "Back to lobby" button here.'
                      : 'This was a test run: players get a "Back to lobby" button here.'}
                  </Box>
                  {!data.preview && (
                    <Button icon="rotate-left" onClick={() => act('again')}>
                      Run again
                    </Button>
                  )}
                  <Button icon="check" onClick={() => act('close')}>
                    Close
                  </Button>
                </>
              ) : (
                <Stack>
                  <Stack.Item>
                    <Button
                      icon="door-open"
                      color="good"
                      onClick={() => act('lobby')}
                    >
                      Back to lobby
                    </Button>
                  </Stack.Item>
                  <Stack.Item>
                    <Button icon="eye" onClick={() => act('close')}>
                      Stay and look around
                    </Button>
                  </Stack.Item>
                </Stack>
              )}
            </Stack.Item>
          </Stack>
        </Section>
      </Window.Content>
    </Window>
  );
};
