// Talking: small orb top left, subtitles below, the dot flickers with the voice (o.level 0…1).
o.corner = true;
o.dotColor = o.brandColor;
o.dotAlpha = 0.35 + Math.min(1, o.level * 4) * 0.65;
o.pulse = Math.min(1, o.level * 3) * 0.25;
