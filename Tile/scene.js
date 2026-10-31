// Draws the whole tile every frame. The state modules only set a few values first:
//   o.dotColor   colour of the dot top right            o.pulse      orb size change (0.1 = 10 % bigger)
//   o.dotAlpha   its brightness 0…1                     o.particles  dots circling the orb
//   o.corner     true = small orb top left, subtitles   o.darken     0…1, dims the whole tile
// Positions are on a 960 × 960 canvas, (0, 0) is the top left corner.
// Sizes (the playground's sliders edit these lines)
const ORB = 240;        // orb radius in the middle
const ORB_Y = 490;      // orb centre, pixels from the top
const NAME_GAP = 170;   // from the orb's lower edge to the name
const SMALL = 70;       // orb radius while speaking (top left)

const { g, W, H, t, mem, rgba, mixc, blob, wrap } = o;
const white = [255, 255, 255], black = [0, 0, 0];
const ease = (now, target, speed) => now + (target - now) * Math.min(1, (t - (mem.last || t)) * speed);
const lerp = (a, b, k) => a + (b - a) * k;

// 0 = orb in the middle, 1 = small orb in the corner (speaking); eased, so the layout morphs
mem.p = ease(mem.p ?? (o.corner ? 1 : 0), o.corner ? 1 : 0, 5);
mem.dark = ease(mem.dark ?? o.darken, o.darken, 4);
mem.part = ease(mem.part ?? 0, o.particles ? 1 : 0, 4);
mem.last = t;
const p = mem.p * mem.p * (3 - 2 * mem.p);   // smoothstep

// background: one colour, soft light from the top left corner
g.fillStyle = rgba(o.background, 1); g.fillRect(0, 0, W, H);
const light = g.createRadialGradient(0, 0, 0, 0, 0, W * 1.15);
light.addColorStop(0, rgba(o.brand, 0.32)); light.addColorStop(1, rgba(o.brand, 0));
g.fillStyle = light; g.fillRect(0, 0, W, H);

// `show --image` / `show --screen`: the picture fills the tile under a slim status bar
if (o.image) {
  const im = o.image, box = { x: 40, y: 130, w: W - 80, h: H - 170 };
  const k = Math.min(box.w / im.width, box.h / im.height), w = im.width * k, h = im.height * k;
  const x = box.x + (box.w - w) / 2, y = box.y + (box.h - h) / 2;
  g.save(); g.beginPath(); g.roundRect(x, y, w, h, 24); g.clip(); g.drawImage(im, x, y, w, h); g.restore();
  g.strokeStyle = 'rgba(255,255,255,0.12)'; g.lineWidth = 2; g.beginPath(); g.roundRect(x, y, w, h, 24); g.stroke();
  g.font = '600 28px -apple-system, Helvetica, sans-serif'; g.textAlign = 'left'; g.fillStyle = 'rgba(255,255,255,0.55)';
  if ('letterSpacing' in g) g.letterSpacing = '3px';
  g.fillText(o.name.toLocaleUpperCase() + ' · ' + o.label, 64, 86);
  if ('letterSpacing' in g) g.letterSpacing = '0px';
  g.fillStyle = o.dotColor; g.shadowColor = o.dotColor; g.shadowBlur = 26; g.globalAlpha = o.dotAlpha;
  g.beginPath(); g.arc(W - 72, 77, 12, 0, Math.PI * 2); g.fill();
  g.shadowBlur = 0; g.globalAlpha = 1;
  return;
}

// orb
const cx = lerp(480, 40 + SMALL * 1.6, p), cy = lerp(ORB_Y, 40 + SMALL * 1.6, p);
const R = lerp(ORB, SMALL, p), r = R * (1 + o.pulse);
blob(cx, cy, r * 2, o.brand, 0.3);
g.fillStyle = rgba(o.brand, 0.16); g.beginPath(); g.arc(cx, cy, r * 1.18, 0, Math.PI * 2); g.fill();   // halo disc
const sphere = g.createRadialGradient(cx - r * 0.32, cy - r * 0.38, r * 0.04, cx, cy, r);
sphere.addColorStop(0, rgba(white, 1)); sphere.addColorStop(0.2, rgba(mixc(o.brand, white, 0.55), 1));
sphere.addColorStop(0.65, rgba(o.brand, 1)); sphere.addColorStop(1, rgba(mixc(o.brand, black, 0.45), 1));
g.fillStyle = sphere; g.beginPath(); g.arc(cx, cy, r, 0, Math.PI * 2); g.fill();
g.strokeStyle = rgba(white, 0.4); g.lineWidth = lerp(2.5, 1.5, p);   // inner ring
g.beginPath(); g.arc(cx, cy, r * 0.79, 0, Math.PI * 2); g.stroke();
if (mem.part > 0.01) {
  g.fillStyle = rgba(white, 0.9 * mem.part);
  for (let i = 0; i < 3; i++) {
    const a = t * 2.4 + i * (Math.PI * 2 / 3), d = r * 1.32;
    g.beginPath(); g.arc(cx + Math.cos(a) * d, cy + Math.sin(a) * d, lerp(10, 5, p), 0, Math.PI * 2); g.fill();
  }
}

// name under the orb
g.textAlign = 'center'; g.textBaseline = 'alphabetic'; g.fillStyle = '#ffffff';
g.font = '700 ' + Math.round(lerp(68, 34, p)) + 'px -apple-system, Helvetica, sans-serif';
g.fillText(o.name, cx, cy + R * 1.18 + lerp(NAME_GAP - 0.18 * ORB, 56, p));

// status text (always grey): top left, moving next to the dot while speaking
const grey = 'rgba(255,255,255,0.55)';
g.font = '600 28px -apple-system, Helvetica, sans-serif';
if ('letterSpacing' in g) g.letterSpacing = '3px';
g.fillStyle = grey;
g.globalAlpha = 1 - p; g.textAlign = 'left'; g.fillText(o.label, 64, 86);
g.globalAlpha = p; g.textAlign = 'right'; g.fillText(o.label, W - 104, 86);
if ('letterSpacing' in g) g.letterSpacing = '0px';
g.globalAlpha = 1;

// the dot, top right, with its own light
g.fillStyle = o.dotColor; g.shadowColor = o.dotColor; g.shadowBlur = 26; g.globalAlpha = o.dotAlpha;
g.beginPath(); g.arc(W - 72, 77, 12, 0, Math.PI * 2); g.fill();
g.shadowBlur = 0; g.globalAlpha = 1;

// subtitles fill the rest of the tile while speaking; a note from `show` sits under the name otherwise
const words = o.caption || o.note;
if (words && p > 0.01) {
  g.globalAlpha = p; g.textAlign = 'left'; g.fillStyle = 'rgba(255,255,255,0.9)';
  g.font = '500 46px -apple-system, Helvetica, sans-serif';
  const top = 40 + SMALL * 3.2 + 110;
  wrap(words, W - 144, Math.floor((H - top) / 58)).forEach((l, i) => g.fillText(l, 72, top + i * 58));
  g.globalAlpha = 1;
}
if (o.note && p < 0.99) {
  g.globalAlpha = 1 - p; g.textAlign = 'center'; g.fillStyle = grey;
  g.font = '400 32px -apple-system, Helvetica, sans-serif';
  wrap(o.note, W - 200, 2).forEach((l, i) => g.fillText(l, 480, Math.min(H - 70, ORB_Y + ORB + NAME_GAP + 56) + i * 42));
  g.globalAlpha = 1;
}

// away: the whole tile goes dark
if (mem.dark > 0.01) { g.fillStyle = rgba(black, mem.dark); g.fillRect(0, 0, W, H); }
