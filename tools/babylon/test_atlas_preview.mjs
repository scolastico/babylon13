/** Run inside the pinned atlas container: node --test /source/tools/babylon/test_atlas_preview.mjs */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import { cropAtlas } from './atlas_preview.mjs';
const sharp = createRequire('/opt/atlas/package.json')('sharp');

test('crop uses map coordinates, full resolution chunks and only visible channels', async () => {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'atlas-preview-'));
  try {
    mkdirSync(path.join(dir, 'map/1'), {recursive: true});
    writeFileSync(path.join(dir, 'manifest.json'), JSON.stringify({schema: 3, tilePixels: 1, chunkTiles: 2}));
    // Four 2x2 pixel chunks, each pixel representing one tile; map height is four tiles.
    // Strip order matches atlas schema 3: base, foreground, power. Power must not be visible.
    const pyramid = [];
    for (let cy = 0; cy < 2; cy++) for (let cx = 0; cx < 2; cx++) {
      const base = Buffer.alloc(16);
      for (let y = 0; y < 2; y++) for (let x = 0; x < 2; x++) {
        base.set([cx * 2 + x + 1, 4 - (cy * 2 + y), 0, 255], (y * 2 + x) * 4);
      }
      const foreground = Buffer.alloc(16);
      if (cx === 1 && cy === 1) foreground.set([99, 88, 77, 255]);
      const power = Buffer.alloc(16, 255);
      await sharp(Buffer.concat([base, foreground, power]), {raw: {width: 2, height: 6, channels: 4}})
        .webp({lossless: true}).toFile(path.join(dir, 'map/1', `c-${cx}-${cy}.webp`));
      pyramid.push([cx, cy, 1 | 2 | 8]);
    }
    writeFileSync(path.join(dir, 'map/map.json'), JSON.stringify({schema: 3, width: 4, height: 4}));
    writeFileSync(path.join(dir, 'map/1.json'), JSON.stringify({schema: 3, pyramid: [pyramid]}));
    const first = await cropAtlas(path.join(dir, 'map'), 1, [2, 1, 3, 3], [2, 3]);
    assert.deepEqual(first, await cropAtlas(path.join(dir, 'map'), 1, [2, 1, 3, 3], [2, 3]));
    const raw = await sharp(first).raw().toBuffer();
    assert.deepEqual([...raw], [2,3,0,255, 3,3,0,255, 2,2,0,255, 99,88,77,255, 2,1,0,255, 3,1,0,255]);
    const larger = await sharp(await cropAtlas(path.join(dir, 'map'), 1, [2,1,3,3], [4,6])).metadata();
    assert.equal(larger.width, 4);
    assert.equal(larger.height, 6);
    for (const box of [[0,1,3,3], [2,1,5,3], [3,1,2,3]]) {
      await assert.rejects(cropAtlas(path.join(dir, 'map'), 1, box, [2,3]), /crop/i);
    }
  } finally {
    rmSync(dir, {recursive: true, force: true});
  }
});
