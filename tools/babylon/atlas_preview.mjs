/** Crop full-resolution SPLURT atlas schema 3 strips using inclusive DMM tile coordinates.
 * Requires the pinned atlas image's sharp and channel definitions. Hidden utilities and
 * mapper markers are omitted; base and foreground give the normal sprite view.
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
const sharp = createRequire('/opt/atlas/package.json')('sharp');
const { slotIndex } = await import('/opt/atlas/scripts/lib/map-format.mjs');

export async function cropAtlas(directory, z, box, size) {
  const manifest = JSON.parse(readFileSync(path.join(directory, '../manifest.json')));
  const meta = JSON.parse(readFileSync(path.join(directory, 'map.json')));
  const level = JSON.parse(readFileSync(path.join(directory, `${z}.json`)));
  if (manifest.schema !== 3 || meta.schema !== 3 || level.schema !== 3) throw new Error('Unsupported atlas schema');
  const [left, bottom, right, top] = box;
  if (!box.every(Number.isInteger) || left < 1 || bottom < 1 || right > meta.width ||
      top > meta.height || right < left || top < bottom) throw new Error('Invalid atlas crop');
  const S = manifest.tilePixels, P = S * manifest.chunkTiles;
  const x0 = (left - 1) * S, y0 = (meta.height - top) * S;
  const width = (right - left + 1) * S, height = (top - bottom + 1) * S;
  const composites = [];
  // All base chunks first, then foreground, matching atlas layer order.
  for (const channel of ['base', 'foreground']) {
    for (const [cx, cy, mask] of level.pyramid[0]) {
      const slot = slotIndex(mask, channel);
      const x = Math.max(x0, cx * P), y = Math.max(y0, cy * P);
      const x1 = Math.min(x0 + width, (cx + 1) * P), y1 = Math.min(y0 + height, (cy + 1) * P);
      if (slot < 0 || x1 <= x || y1 <= y) continue;
      const input = await sharp(path.join(directory, `${z}`, `c-${cx}-${cy}.webp`))
        .extract({left: x - cx * P, top: slot * P + y - cy * P, width: x1 - x, height: y1 - y})
        .png().toBuffer();
      composites.push({input, left: x - x0, top: y - y0});
    }
  }
  const raw = await sharp({create: {width, height, channels: 4, background: '#00000000'}})
    .composite(composites).raw().toBuffer();
  return sharp(raw, {raw: {width, height, channels: 4}})
    .resize(size[0], size[1], {kernel: 'lanczos3', fit: 'fill'})
    .png({compressionLevel: 9, adaptiveFiltering: false}).toBuffer();
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [directory, output, box] = process.argv.slice(2);
  writeFileSync(output, await cropAtlas(directory, 1, box.split(',').map(Number), [256, 128]));
}
