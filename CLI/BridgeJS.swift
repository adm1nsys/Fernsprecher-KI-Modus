//
//  BridgeJS.swift
//  fernsprecher-ki-modus-an
//
//  JavaScript injected into the FaceTime web client (facetime.apple.com) at document start.
//  It replaces the microphone with a WebAudio stream we feed with synthesized speech,
//  replaces the camera with a drawn tile (agent name, status, captions, or whatever `show` puts there),
//  taps every remote WebRTC audio track, keeps remote video for `look`, and drives the join flow without a human.
//

import Foundation

enum BridgeJS {
    static func source(name: String, language: String, avatar: String, brand: String = "", monitor: Bool, video: Bool, verbose: Bool) -> String {
        let config = #"window.__ftkConfig = { name: \#(jsString(name)), lang: \#(jsString(language)), avatar: \#(jsString(avatar)), brand: \#(jsString(brand)), monitor: \#(monitor), noVideo: \#(!video), verbose: \#(verbose), mutedPressed: 'true' };"#
        return config + "\n" + body
    }

    static func jsString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        let arr = String(data: data, encoding: .utf8)!
        return String(arr.dropFirst().dropLast())
    }

    private static let body = #"""
(() => {
  if (window.__ftk) return;
  const cfg = window.__ftkConfig || {};
  const post = (m) => { try { window.webkit.messageHandlers.ftk.postMessage(m); } catch (e) {} };
  const fmt = (a) => a.map(x => { try { return typeof x === 'string' ? x : JSON.stringify(x); } catch (e) { return String(x); } }).join(' ');
  const log = (...a) => post({ type: 'log', text: fmt(a) });
  for (const k of (cfg.verbose ? ['log', 'info', 'warn', 'error', 'debug'] : ['error'])) {
    const orig = console[k];
    console[k] = (...a) => { post({ type: 'console', level: k, text: fmt(a).replace(/%c/g, '').slice(0, 2000) }); orig.apply(console, a); };
  }
  window.addEventListener('error', e => post({ type: 'console', level: 'uncaught', text: String(e.message) + ' ' + e.filename + ':' + e.lineno }));
  window.addEventListener('unhandledrejection', e => post({ type: 'console', level: 'rejection', text: String(e.reason && (e.reason.stack || e.reason.message) || e.reason).slice(0, 1500) }));
  if (cfg.verbose) {
    const peek = (d) => typeof d === 'string' ? d.slice(0, 300) : ('<' + (d.byteLength || d.size || 0) + ' bytes>');
    const WS = window.WebSocket;
    window.WebSocket = function (url, p) {
      const ws = p === undefined ? new WS(url) : new WS(url, p);
      log('ws open', url);
      ws.addEventListener('message', e => log('ws <-', peek(e.data)));
      ws.addEventListener('close', e => log('ws close', e.code, e.reason));
      const send = ws.send.bind(ws);
      ws.send = (d) => { log('ws ->', peek(d)); return send(d); };
      return ws;
    };
    window.WebSocket.prototype = WS.prototype;
    Object.assign(window.WebSocket, { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 });
    const f = window.fetch;
    window.fetch = (...a) => f(...a).then(r => { log('fetch', r.status, String(a[0] && a[0].url || a[0]).slice(0, 200)); return r; }, e => { log('fetch failed', String(a[0]).slice(0, 200), String(e)); throw e; });
    const W = window.Worker;
    const brief = (d) => { try { return JSON.stringify(d, (k, v) => (v && v.byteLength !== undefined) ? '<' + v.byteLength + 'b>' : v).slice(0, 400); } catch (e) { return String(d); } };
    window.__ftkWorkers = [];
    window.Worker = function (u, o) {
      log('worker', String(u));
      const w = new W(u, o);
      window.__ftkWorkers.push(w);
      w.addEventListener('error', e => log('worker error', e.message));
      w.addEventListener('message', e => log('worker ->', brief(e.data)));
      const pm = w.postMessage.bind(w);
      w.postMessage = (d, t) => { log('worker <-', brief(d)); return pm(d, t); };
      return w;
    };
    window.Worker.prototype = W.prototype;
  }

  // The view lives off-screen; the client must still believe it is a focused, visible tab or it never connects media.
  try {
    Object.defineProperty(Document.prototype, 'visibilityState', { get: () => 'visible', configurable: true });
    Object.defineProperty(Document.prototype, 'hidden', { get: () => false, configurable: true });
    Document.prototype.hasFocus = () => true;
  } catch (e) {}

  // English UI regardless of system language, so the autopilot can match labels.
  try {
    Object.defineProperty(Navigator.prototype, 'language', { get: () => 'en-US', configurable: true });
    Object.defineProperty(Navigator.prototype, 'languages', { get: () => ['en-US', 'en'], configurable: true });
  } catch (e) {}

  const b64 = (buf) => {
    const u = new Uint8Array(buf); let s = '';
    for (let i = 0; i < u.length; i += 0x8000) s += String.fromCharCode.apply(null, u.subarray(i, i + 0x8000));
    return btoa(s);
  };
  const unb64 = (s) => { const bin = atob(s); const u = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i); return u.buffer; };

  // ---- audio graph -------------------------------------------------------
  let ctx = null;
  const state = { tracks: 0, sent: 0, peak: 0, playing: null, mics: [], cams: [], pcs: [], videos: [] };
  const audio = () => {
    if (ctx) return ctx;
    ctx = new AudioContext({ sampleRate: 48000 });
    // Outgoing: everything connected to outGain becomes our "microphone".
    ctx.__out = ctx.createMediaStreamDestination();
    ctx.__outGain = ctx.createGain();
    ctx.__outGain.connect(ctx.__out);
    ctx.__meter = ctx.createAnalyser();
    ctx.__meter.fftSize = 512;
    ctx.__outGain.connect(ctx.__meter);
    const osc = ctx.createOscillator(), z = ctx.createGain();
    z.gain.value = 0; osc.connect(z).connect(ctx.__out); osc.start();
    // Incoming: remote tracks are mixed and resampled to 16 kHz mono Int16.
    ctx.__mix = ctx.createGain();
    const sink = ctx.createGain(); sink.gain.value = 0;
    sink.connect(ctx.destination);
    // 48 kHz -> 16 kHz: average each 3-sample window (a box low-pass), carrying the remainder across chunks.
    let carry = new Float32Array(0);
    const handle = (chunk) => {
      if (state.tracks <= 0) return;
      const x = new Float32Array(carry.length + chunk.length);
      x.set(carry); x.set(chunk, carry.length);
      const step = Math.round(ctx.sampleRate / 16000) || 1;
      const n = Math.floor(x.length / step);
      const out = new Int16Array(n);
      let peak = 0;
      for (let k = 0; k < n; k++) {
        let v = 0;
        for (let j = 0; j < step; j++) v += x[k * step + j];
        v = Math.max(-1, Math.min(1, v / step));
        if (Math.abs(v) > peak) peak = Math.abs(v);
        out[k] = v * 32767;
      }
      carry = x.slice(n * step);
      state.peak = Math.max(state.peak * 0.9, peak);
      state.sent += n;
      post({ type: 'audio', pcm: b64(out.buffer) });
    };
    // Capture on the audio thread (AudioWorklet), so a busy page thread can't drop audio; ScriptProcessor is the fallback.
    const worklet = `class C extends AudioWorkletProcessor {
      constructor() { super(); this.b = new Float32Array(3072); this.n = 0; }
      process(inputs) {
        const c = inputs[0] && inputs[0][0];
        if (c) { this.b.set(c, this.n); this.n += c.length; if (this.n >= this.b.length) { this.port.postMessage(this.b.slice(0)); this.n = 0; } }
        return true;
      }
    }
    registerProcessor('ftk-capture', C);`;
    const fallback = (why) => {
      post({ type: 'log', text: 'audio capture: ScriptProcessor (' + why + ')' });
      const proc = ctx.createScriptProcessor(4096, 1, 1);
      ctx.__mix.connect(proc);
      proc.connect(sink);
      proc.onaudioprocess = (e) => handle(e.inputBuffer.getChannelData(0));
    };
    if (ctx.audioWorklet) {
      ctx.audioWorklet.addModule(URL.createObjectURL(new Blob([worklet], { type: 'application/javascript' }))).then(() => {
        const node = new AudioWorkletNode(ctx, 'ftk-capture', { numberOfInputs: 1, numberOfOutputs: 1, channelCount: 1, channelCountMode: 'explicit' });
        node.port.onmessage = (e) => handle(e.data);
        ctx.__mix.connect(node);
        node.connect(sink);
        post({ type: 'log', text: 'audio capture: AudioWorklet' });
      }, (e) => fallback(String(e)));
    } else {
      fallback('no AudioWorklet');
    }
    setInterval(() => { if (ctx.state !== 'running') ctx.resume().catch(() => {}); }, 1000);
    ctx.resume().catch(() => {});
    post({ type: 'log', text: 'audio context ' + ctx.sampleRate + ' Hz, ' + ctx.state });
    return ctx;
  };

  // ---- camera replacement: the agent's tile --------------------------------
  const tile = (() => {
    // Square: phones crop 16:9 tiles to the middle, which cut the captions off.
    const W = 960, H = 960;
    const cv = document.createElement('canvas');
    cv.width = W; cv.height = H;
    const g = cv.getContext('2d');
    const allLabels = {
      en: { connecting: 'Connecting…', listening: 'Listening', hearing: 'Hearing you…', thinking: 'Thinking…', speaking: 'Speaking', waking: 'Calling ' + cfg.name + '…', away: 'Away' },
      de: { connecting: 'Verbindet sich…', listening: 'Hört zu', hearing: 'Hört zu…', thinking: 'Denkt nach…', speaking: 'Spricht', waking: 'Weckt ' + cfg.name + '…', away: 'Pause' },
      fr: { connecting: 'Connexion…', listening: 'À l’écoute', hearing: 'Je vous entends…', thinking: 'Réflexion…', speaking: 'Parle', waking: 'On appelle ' + cfg.name + '…', away: 'En pause' },
      da: { connecting: 'Forbinder…', listening: 'Lytter', hearing: 'Lytter…', thinking: 'Tænker…', speaking: 'Taler', waking: 'Vækker ' + cfg.name + '…', away: 'Pause' },
      ja: { connecting: '接続中…', listening: '聞いています', hearing: '聞き取り中…', thinking: '考え中…', speaking: '話しています', waking: cfg.name + 'を呼んでいます…', away: '休憩中' },
    };
    const lang2 = String(cfg.lang || 'en').slice(0, 2).toLowerCase();
    const labels = allLabels[lang2] || allLabels.en;
    // Brand themes: --brand claude|gpt, or guessed from the agent's name. Custom: --brand '#bg1,#bg2,#orb'.
    const brands = {
      claude: { bg: ['#2b2a27', '#1a1917'], orb: '#d97757' },
      gpt: { bg: ['#2a2b2e', '#202123'], orb: '#10a37f' },
      none: { bg: ['#0b0b14', '#17172a'], orb: null },
    };
    const brand = (() => {
      const b = String(cfg.brand || '').toLowerCase();
      if (b.includes('#')) { const c = b.split(',').map(x => x.trim()); return { bg: [c[0], c[1] || c[0]], orb: c[2] || null }; }
      if (brands[b]) return brands[b];
      if (/claude/i.test(cfg.name)) return brands.claude;
      if (/gpt|openai|codex/i.test(cfg.name)) return brands.gpt;
      return brands.none;
    })();
    const colors = { connecting: '#8e8e93', listening: '#64d2ff', hearing: '#30d158', thinking: '#ffd60a', speaking: '#bf5af2', waking: '#ff9f0a', away: '#636366' };
    if (brand.orb) { colors.listening = brand.orb; colors.speaking = brand.orb; }
    const st = { state: 'connecting', caption: '', note: '', image: null, changed: performance.now() };
    let level = 0;
    const buf = new Uint8Array(512);

    const wrap = (text, maxW, maxLines) => {
      const words = String(text).split(/\s+/).filter(Boolean), lines = [];
      let line = '';
      for (const w of words) {
        const t = line ? line + ' ' + w : w;
        if (g.measureText(t).width > maxW && line) { lines.push(line); line = w; } else line = t;
      }
      if (line) lines.push(line);
      if (lines.length > maxLines) { const tail = lines.slice(-maxLines); tail[0] = '… ' + tail[0]; return tail; }
      return lines;
    };

    // Orb: breathes when listening, pulses with the voice when speaking, orbits when thinking.
    const drawOrb = (cx, cy, t, statusColor) => {
      // The orb wears the brand colour; the status shows in its motion and in the label under the name.
      const color = brand.orb || statusColor;
      let r = 105 + Math.sin(t * 1.6) * 4;
      if (st.state === 'speaking') r = 105 + level * 90;
      if (st.state === 'hearing') r = 105 + Math.abs(Math.sin(t * 6)) * 14;
      if (st.state === 'away') r = 95;
      if (st.state === 'waking') r = 105 + Math.abs(Math.sin(t * 3)) * 25;
      const orb = g.createRadialGradient(cx - 30, cy - 30, 10, cx, cy, r);
      orb.addColorStop(0, '#ffffff'); orb.addColorStop(0.35, color); orb.addColorStop(1, 'rgba(20,20,40,0)');
      g.fillStyle = orb; g.beginPath(); g.arc(cx, cy, r + 40, 0, Math.PI * 2); g.fill();
      if (st.state === 'thinking') {
        for (let i = 0; i < 3; i++) {
          const a = t * 2.4 + i * (Math.PI * 2 / 3);
          g.fillStyle = color; g.beginPath(); g.arc(cx + Math.cos(a) * 165, cy + Math.sin(a) * 165, 12, 0, Math.PI * 2); g.fill();
        }
      }
    };

    // The character: a little robot head whose face screen shows eyes and a mouth. Eyes blink and look around,
    // the mouth opens with the loudness of our own voice, the antenna glows in the status colour.
    let nextBlink = 2, blinkUntil = 0;
    const drawBot = (cx, cy, t, color) => {
      const s = st.state;
      const bob = s === 'speaking' ? Math.sin(t * 9) * 3 * Math.min(1, level * 4) : Math.sin(t * 1.4) * 4;
      const y = cy + bob;
      const glow = (c, blur) => { g.shadowColor = c; g.shadowBlur = blur; };
      const noGlow = () => { g.shadowBlur = 0; };

      // antenna
      g.strokeStyle = '#3a3a52'; g.lineWidth = 8; g.lineCap = 'round';
      g.beginPath(); g.moveTo(cx, y - 120); g.lineTo(cx, y - 168); g.stroke();
      const pulse = s === 'waking' ? 0.5 + 0.5 * Math.abs(Math.sin(t * 6)) : s === 'away' ? 0.25 : 0.75 + 0.25 * Math.sin(t * 3);
      glow(color, 30 * pulse); g.fillStyle = color; g.globalAlpha = 0.4 + 0.6 * pulse;
      g.beginPath(); g.arc(cx, y - 178, 15, 0, Math.PI * 2); g.fill();
      g.globalAlpha = 1; noGlow();

      // headphones while hearing someone
      if (s === 'hearing') {
        g.strokeStyle = color; g.lineWidth = 10;
        g.beginPath(); g.arc(cx, y - 10, 175, Math.PI * 1.08, Math.PI * 1.92); g.stroke();
        g.fillStyle = color;
        g.beginPath(); g.roundRect(cx - 192, y - 40, 34, 80, 14); g.fill();
        g.beginPath(); g.roundRect(cx + 158, y - 40, 34, 80, 14); g.fill();
      }

      // head
      const head = g.createLinearGradient(0, y - 120, 0, y + 130);
      head.addColorStop(0, '#34344a'); head.addColorStop(1, '#1d1d2c');
      g.fillStyle = head; glow('rgba(0,0,0,0.6)', 30);
      g.beginPath(); g.roundRect(cx - 155, y - 120, 310, 245, 70); g.fill(); noGlow();
      g.strokeStyle = color; g.globalAlpha = 0.55; g.lineWidth = 4;
      g.beginPath(); g.roundRect(cx - 155, y - 120, 310, 245, 70); g.stroke(); g.globalAlpha = 1;
      // face screen
      g.fillStyle = '#07070d';
      g.beginPath(); g.roundRect(cx - 125, y - 92, 250, 190, 52); g.fill();

      // eyes
      if (t > nextBlink) { blinkUntil = t + 0.13; nextBlink = t + 2.5 + Math.random() * 3; }
      const blinking = t < blinkUntil;
      let lookX = 0, lookY = 0, eyeH = 54;
      if (s === 'thinking') { lookX = 14 * Math.sin(t * 1.3); lookY = -14; }
      if (s === 'hearing') { eyeH = 62; }
      if (s === 'waking') { eyeH = 34 + 28 * Math.abs(Math.sin(t * 4)); }
      g.fillStyle = color; glow(color, 22);
      for (const dx of [-55, 55]) {
        const ex = cx + dx + lookX, ey = y - 18 + lookY;
        if (s === 'away') {
          g.beginPath(); g.roundRect(ex - 24, ey - 3, 48, 7, 4); g.fill();
        } else if (blinking) {
          g.beginPath(); g.roundRect(ex - 22, ey - 3, 44, 7, 4); g.fill();
        } else {
          g.beginPath(); g.roundRect(ex - 21, ey - eyeH / 2, 42, eyeH, 21); g.fill();
          g.fillStyle = 'rgba(255,255,255,0.85)'; noGlow();
          g.beginPath(); g.arc(ex - 7, ey - eyeH / 2 + 15, 6, 0, Math.PI * 2); g.fill();
          g.fillStyle = color; glow(color, 22);
        }
      }
      noGlow();

      // cheeks
      g.fillStyle = color; g.globalAlpha = 0.18;
      for (const dx of [-88, 88]) { g.beginPath(); g.ellipse(cx + dx, y + 30, 18, 11, 0, 0, Math.PI * 2); g.fill(); }
      g.globalAlpha = 1;

      // mouth
      g.fillStyle = color; g.strokeStyle = color; g.lineWidth = 7; g.lineCap = 'round';
      const my = y + 50;
      if (s === 'speaking') {
        const open = 8 + Math.min(46, level * 160);
        glow(color, 16);
        g.beginPath(); g.roundRect(cx - 34, my - open / 2, 68, open, Math.min(open / 2, 18)); g.fill(); noGlow();
      } else if (s === 'thinking') {
        g.beginPath(); g.moveTo(cx - 18, my + 2); g.lineTo(cx + 22, my - 4); g.stroke();
        for (let i = 0; i < 3; i++) {
          g.globalAlpha = 0.35 + 0.65 * Math.max(0, Math.sin(t * 4 - i * 0.8));
          g.beginPath(); g.arc(cx + 150 + i * 30, y - 130 - i * 22, 9 + i * 3, 0, Math.PI * 2); g.fill();
        }
        g.globalAlpha = 1;
      } else if (s === 'away') {
        g.beginPath(); g.moveTo(cx - 20, my); g.lineTo(cx + 20, my); g.stroke();
        g.font = '700 40px -apple-system, Helvetica, sans-serif'; g.textAlign = 'left';
        g.globalAlpha = 0.5 + 0.5 * Math.sin(t * 2);
        g.fillText('z', cx + 150, y - 110); g.font = '700 28px -apple-system, Helvetica, sans-serif'; g.fillText('z', cx + 185, y - 145);
        g.globalAlpha = 1;
      } else if (s === 'waking') {
        g.beginPath(); g.ellipse(cx, my, 14, 16, 0, 0, Math.PI * 2); g.stroke();
      } else {
        g.beginPath(); g.arc(cx, my - 22, 34, Math.PI * 0.2, Math.PI * 0.8); g.stroke();
      }
    };

    // A human: a stylised person whose gaze, brows, head and lips move like a speaker's do. Looks at you
    // (with small saccades) while listening, raises brows and nods while hearing you, looks up and away while
    // thinking, moves the lips with the loudness of our voice while speaking, dozes when away.
    const P = { gx: 0, gy: 0, tgx: 0, tgy: 0, nextSaccade: 0, tilt: 0, brow: 0, mouth: 0, nextBlink: 1.5, blinkAt: -1 };
    const ease = (a, b, k) => a + (b - a) * k;
    const skin = '#f0c4a1', skinShade = '#d9a27f', hair = '#2f2420', shirt = '#2c3b57', iris = '#4f7396';
    const drawHuman = (cx, cy, t, color) => {
      const s = st.state;
      if (t > P.nextSaccade) {
        if (s === 'thinking') { P.tgx = -0.75 + Math.random() * 0.25; P.tgy = -0.85; }
        else if (s === 'away') { P.tgx = 0; P.tgy = 0.7; }
        else if (s === 'hearing' || s === 'speaking') { P.tgx = (Math.random() - 0.5) * 0.2; P.tgy = (Math.random() - 0.5) * 0.15; }
        else { P.tgx = (Math.random() - 0.5) * 0.6; P.tgy = (Math.random() - 0.5) * 0.3; }
        P.nextSaccade = t + (s === 'thinking' ? 1.4 : 0.7 + Math.random() * 2.3);
      }
      P.gx = ease(P.gx, P.tgx, 0.4); P.gy = ease(P.gy, P.tgy, 0.4);
      const tiltTo = s === 'hearing' ? 0.07 : s === 'thinking' ? -0.06 : s === 'away' ? 0.1 : 0;
      P.tilt = ease(P.tilt, tiltTo + Math.sin(t * 0.7) * 0.015, 0.08);
      P.brow = ease(P.brow, s === 'hearing' ? 1 : s === 'thinking' ? -0.7 : s === 'waking' ? 1.3 : 0, 0.15);
      P.mouth = ease(P.mouth, s === 'speaking' ? Math.min(1, level * 4.5) : 0, 0.5);
      if (t > P.nextBlink) { P.blinkAt = t; P.nextBlink = t + 2 + Math.random() * 4; }
      const since = t - P.blinkAt;
      let lid = since >= 0 && since < 0.16 ? Math.abs(since - 0.08) / 0.08 : 1;
      if (s === 'away') lid = 0.06;
      if (s === 'waking') lid = Math.min(lid, 0.35 + 0.65 * Math.abs(Math.sin(t * 3)));
      const nod = s === 'hearing' ? Math.sin(t * 2.2) * 6 : s === 'speaking' ? Math.sin(t * 5) * 3 * P.mouth : 0;
      const y0 = cy + Math.sin(t * 1.3) * 2 + nod;

      // status halo
      const halo = g.createRadialGradient(cx, cy, 60, cx, cy, 230);
      halo.addColorStop(0, color); halo.addColorStop(1, 'rgba(0,0,0,0)');
      g.globalAlpha = s === 'away' ? 0.12 : 0.28 + (s === 'speaking' ? level * 0.6 : 0);
      g.fillStyle = halo; g.beginPath(); g.arc(cx, cy, 230, 0, Math.PI * 2); g.fill();
      g.globalAlpha = 1;

      // shoulders and neck
      g.fillStyle = shirt;
      g.beginPath();
      g.moveTo(cx - 200, 470); g.bezierCurveTo(cx - 195, 395, cx - 120, 372, cx - 45, 365);
      g.lineTo(cx + 45, 365); g.bezierCurveTo(cx + 120, 372, cx + 195, 395, cx + 200, 470); g.closePath(); g.fill();
      g.fillStyle = skinShade; g.beginPath(); g.roundRect(cx - 32, cy + 80, 64, 80, 20); g.fill();
      g.fillStyle = shirt; g.beginPath(); g.ellipse(cx, 368, 52, 16, 0, 0, Math.PI); g.fill();

      g.save();
      g.translate(cx, y0); g.rotate(P.tilt);
      // ears
      g.fillStyle = skinShade;
      for (const dx of [-98, 98]) { g.beginPath(); g.ellipse(dx, 8, 17, 27, 0, 0, Math.PI * 2); g.fill(); }
      // face
      const face = g.createRadialGradient(-25, -30, 20, 0, 0, 135);
      face.addColorStop(0, '#f7d3b4'); face.addColorStop(1, skin);
      g.fillStyle = face; g.beginPath(); g.ellipse(0, 0, 98, 120, 0, 0, Math.PI * 2); g.fill();
      // hair
      g.fillStyle = hair;
      g.beginPath();
      g.moveTo(-102, 10); g.bezierCurveTo(-112, -95, -60, -140, 5, -138);
      g.bezierCurveTo(75, -136, 115, -95, 103, 8);
      g.bezierCurveTo(95, -40, 70, -68, 30, -72);
      g.bezierCurveTo(5, -58, -30, -64, -55, -72);
      g.bezierCurveTo(-80, -60, -95, -30, -102, 10);
      g.fill();

      // eyes
      for (const dx of [-36, 36]) {
        const ey = -8;
        g.save();
        g.beginPath(); g.ellipse(dx, ey, 20, 13, 0, 0, Math.PI * 2); g.clip();
        g.fillStyle = '#ffffff'; g.fillRect(dx - 22, ey - 15, 44, 30);
        const ix = dx + P.gx * 8, iy = ey + P.gy * 5;
        g.fillStyle = iris; g.beginPath(); g.arc(ix, iy, 9.5, 0, Math.PI * 2); g.fill();
        g.fillStyle = '#111'; g.beginPath(); g.arc(ix, iy, 4.5, 0, Math.PI * 2); g.fill();
        g.fillStyle = 'rgba(255,255,255,0.9)'; g.beginPath(); g.arc(ix - 3, iy - 3.5, 2.6, 0, Math.PI * 2); g.fill();
        // upper lid closes from the top
        const lidY = ey - 14 + 28 * (1 - lid);
        g.fillStyle = skinShade; g.fillRect(dx - 22, ey - 16, 44, lidY - (ey - 16));
        g.restore();
        g.strokeStyle = '#3a2a24'; g.lineWidth = 2.5;
        g.beginPath(); g.moveTo(dx - 20, Math.min(ey, ey - 14 + 28 * (1 - lid)) ); g.quadraticCurveTo(dx, ey - 14 + 28 * (1 - lid) - (lid > 0.3 ? 6 : 0), dx + 20, Math.min(ey, ey - 14 + 28 * (1 - lid))); g.stroke();
      }
      // brows: up when hearing, inner ends down when thinking
      g.strokeStyle = hair; g.lineWidth = 6; g.lineCap = 'round';
      for (const dx of [-36, 36]) {
        const by = -38 - Math.max(0, P.brow) * 8, inner = dx < 0 ? 1 : -1;
        const furrow = Math.max(0, -P.brow) * 9;     // thinking: inner ends drawn down
        g.beginPath();
        g.moveTo(dx - 19 * inner, by + 3);
        g.quadraticCurveTo(dx - 2 * inner, by - 6, dx + 19 * inner, by + 2 + furrow);
        g.stroke();
      }
      // nose
      g.strokeStyle = skinShade; g.lineWidth = 3.5;
      g.beginPath(); g.moveTo(4, 2); g.quadraticCurveTo(12, 26, 0, 30); g.stroke();
      // cheeks
      g.fillStyle = 'rgba(232,120,110,0.22)';
      for (const dx of [-55, 55]) { g.beginPath(); g.ellipse(dx, 30, 17, 10, 0, 0, Math.PI * 2); g.fill(); }
      // mouth
      const my = 58;
      if (P.mouth > 0.06) {
        const h = 5 + P.mouth * 24, w = 30 - P.mouth * 6;
        g.fillStyle = '#5b2025'; g.beginPath(); g.ellipse(0, my + h / 3, w, h / 2 + 2, 0, 0, Math.PI * 2); g.fill();
        g.fillStyle = '#ffffff'; g.beginPath(); g.ellipse(0, my + 1, w - 6, Math.min(5, h / 4), 0, 0, Math.PI); g.fill();
        g.fillStyle = '#d9656d'; g.beginPath(); g.ellipse(0, my + h / 2 + 4, w - 10, Math.max(2, h / 6), 0, 0, Math.PI * 2); g.fill();
      } else {
        g.strokeStyle = '#b5555c'; g.lineWidth = 5; g.lineCap = 'round';
        g.beginPath();
        if (s === 'thinking') { g.moveTo(-16, my + 4); g.quadraticCurveTo(4, my + 2, 20, my - 2); }
        else if (s === 'away') { g.moveTo(-12, my + 3); g.lineTo(12, my + 3); }
        else { g.moveTo(-24, my); g.quadraticCurveTo(0, my + (s === 'hearing' ? 10 : 13), 24, my); }
        g.stroke();
      }
      g.restore();

      if (s === 'away') {
        g.fillStyle = color; g.font = '700 40px -apple-system, Helvetica, sans-serif'; g.textAlign = 'left';
        g.globalAlpha = 0.5 + 0.5 * Math.sin(t * 2);
        g.fillText('z', cx + 120, cy - 110); g.font = '700 28px -apple-system, Helvetica, sans-serif'; g.fillText('z', cx + 155, cy - 145);
        g.globalAlpha = 1;
      }
      if (s === 'thinking') {
        g.fillStyle = color;
        for (let i = 0; i < 3; i++) {
          g.globalAlpha = 0.35 + 0.65 * Math.max(0, Math.sin(t * 4 - i * 0.8));
          g.beginPath(); g.arc(cx - 130 - i * 28, cy - 125 - i * 22, 8 + i * 3, 0, Math.PI * 2); g.fill();
        }
        g.globalAlpha = 1;
      }
    };

    // The default look, built from small modules (Tile/*.js, also editable in site/tile.html): one per state
    // that sets a few values, then `scene`, which draws. Tile/sync.py copies them in here.
    const ready = { en: 'Ready to talk', de: 'Bereit zum Gespräch', fr: 'Prêt à discuter', da: 'Klar til en snak', ja: 'いつでも話せます' };
    const rgbOf = hex => { const m = /^#?([0-9a-f]{6})$/i.exec(String(hex || '').trim()); const v = m ? parseInt(m[1], 16) : 0x8b7cf6; return [v >> 16, (v >> 8) & 255, v & 255]; };
    const rgba = (c, a) => 'rgba(' + c.map(Math.round).join(',') + ',' + a + ')';
    const mixc = (c, d, k) => c.map((x, i) => x + (d[i] - x) * k);
    const hue = (c, deg) => {
      // rotate the hue in RGB space (Rodrigues around the grey axis)
      const a = deg * Math.PI / 180, cos = Math.cos(a), sin = Math.sin(a), k = (1 - cos) / 3, q = Math.sqrt(1 / 3) * sin;
      const m = [cos + k, k - q, k + q, k + q, cos + k, k - q, k - q, k + q, cos + k];
      return [0, 1, 2].map(i => Math.max(0, Math.min(255, c[0] * m[i * 3] + c[1] * m[i * 3 + 1] + c[2] * m[i * 3 + 2])));
    };
    const blob = (x, y, r, c, a) => {
      const gr = g.createRadialGradient(x, y, 0, x, y, r);
      gr.addColorStop(0, rgba(c, a)); gr.addColorStop(1, rgba(c, 0));
      g.fillStyle = gr; g.fillRect(x - r, y - r, r * 2, r * 2);
    };
    // <tile-modules>
    const tileModules = {
      scene: (o) => {
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
      },
      connecting: (o) => {
      // Joining the call: orb in the middle, grey dot.
      o.dotColor = o.grey;
      o.pulse = Math.sin(o.t * 3) * 0.02;
      },
      listening: (o) => {
      // Waiting for someone to speak: same, slow breathing.
      o.dotColor = o.grey;
      o.pulse = Math.sin(o.t * 1.6) * 0.03;
      },
      hearing: (o) => {
      // Someone is talking: the dot takes the agent's colour.
      o.dotColor = o.brandColor;
      o.pulse = Math.abs(Math.sin(o.t * 6)) * 0.06;
      },
      thinking: (o) => {
      // Working on an answer: yellow dot, particles around the orb.
      o.dotColor = o.yellow;
      o.particles = true;
      o.pulse = Math.sin(o.t * 1.6) * 0.03;
      },
      speaking: (o) => {
      // Talking: small orb top left, subtitles below, the dot flickers with the voice (o.level 0…1).
      o.corner = true;
      o.dotColor = o.brandColor;
      o.dotAlpha = 0.35 + Math.min(1, o.level * 4) * 0.65;
      o.pulse = Math.min(1, o.level * 3) * 0.25;
      },
      waking: (o) => {
      // Speech woke the agent up: like connecting, with eager pulses.
      o.dotColor = o.grey;
      o.pulse = Math.abs(Math.sin(o.t * 3)) * 0.1;
      },
      away: (o) => {
      // Nobody is listening: grey dot, the whole tile dimmed.
      o.dotColor = o.grey;
      o.darken = 0.6;
      },
    };
    // </tile-modules>
    const tileMem = {};
    const runTile = (t, statusColor) => {
      const s = st.state;
      const o = {
        g, W, H, t, level, state: s, mem: tileMem, rgba, mixc, blob, wrap,
        name: cfg.name, label: String(labels[s] || s).toLocaleUpperCase(),
        caption: st.caption || '', note: st.note || '', image: st.image,
        brand: rgbOf(brand.orb || statusColor), background: rgbOf(brand.bg[1] || brand.bg[0]),
        brandColor: brand.orb || statusColor, grey: '#8e8e93', yellow: '#ffd60a',
        // what the state modules may change
        dotColor: '#8e8e93', dotAlpha: 1, pulse: 0, particles: false, corner: false, darken: 0,
      };
      (tileModules[s] || tileModules.listening)(o);
      tileModules.scene(o);
    };

    const draw = () => {
      const t = performance.now() / 1000;
      if (ctx && ctx.__meter) {
        ctx.__meter.getByteTimeDomainData(buf);
        let m = 0; for (const v of buf) m = Math.max(m, Math.abs(v - 128) / 128);
        level = level * 0.7 + m * 0.3;
      }
      const color = colors[st.state] || '#64d2ff';
      const bg = g.createLinearGradient(0, 0, W, H);
      bg.addColorStop(0, brand.bg[0]); bg.addColorStop(1, brand.bg[1]);
      g.fillStyle = bg; g.fillRect(0, 0, W, H);

      if (st.image && (cfg.avatar === 'human' || cfg.avatar === 'bot')) {
        // `show --image`: the picture takes the tile, with a small status line below.
        const im = st.image, s = Math.min((W - 60) / im.width, (H - 150) / im.height);
        const w = im.width * s, h = im.height * s;
        g.drawImage(im, (W - w) / 2, 30 + (H - 150 - h) / 2, w, h);
        g.font = '600 34px -apple-system, Helvetica, sans-serif';
        g.fillStyle = color; g.textAlign = 'center';
        g.fillText(cfg.name + ' · ' + (labels[st.state] || st.state), W / 2, H - 55);
        return;
      }

      if (cfg.avatar !== 'human' && cfg.avatar !== 'bot') { runTile(t, color); return; }

      const cx = W / 2, cy = 270;
      if (cfg.avatar === 'human') drawHuman(cx, cy, t, color); else if (cfg.avatar === 'bot') drawBot(cx, cy, t, color); else drawOrb(cx, cy, t, color);

      g.textAlign = 'center';
      g.fillStyle = '#ffffff';
      g.font = '700 72px -apple-system, Helvetica, sans-serif';
      g.fillText(cfg.name, cx, 520);
      g.fillStyle = color;
      g.font = '600 38px -apple-system, Helvetica, sans-serif';
      g.fillText(labels[st.state] || st.state, cx, 580);

      const text = st.note || st.caption;
      if (text) {
        g.font = '400 32px -apple-system, Helvetica, sans-serif';
        const lines = wrap(text, W - 200, 5);
        g.fillStyle = 'rgba(255,255,255,0.08)';
        g.fillRect(70, 630, W - 140, 28 + lines.length * 42);
        g.fillStyle = st.note ? '#ffffff' : 'rgba(255,255,255,0.85)';
        lines.forEach((l, i) => g.fillText(l, cx, 668 + i * 42));
      }
    };
    setInterval(() => { try { draw(); } catch (e) {} }, 66);
    draw();
    const stream = cv.captureStream(15);
    return {
      track: () => stream.getVideoTracks()[0].clone(),
      set(p) { Object.assign(st, p); st.changed = performance.now(); },
      get() { return { state: st.state, caption: st.caption, note: st.note, image: !!st.image }; },
    };
  })();

  // ---- microphone / camera replacement -----------------------------------
  const md = new EventTarget();
  md.getUserMedia = async (c) => {
    const wantsAudio = !!(c && c.audio), wantsVideo = !!(c && c.video);
    const s = new MediaStream();
    if (wantsAudio) {
      const mic = audio().__out.stream.getAudioTracks()[0].clone();
      state.mics.push(mic);
      s.addTrack(mic);
    }
    if (wantsVideo) {
      const cam = tile.track();
      state.cams.push(cam);
      s.addTrack(cam);
    }
    log('getUserMedia', { audio: wantsAudio, video: wantsVideo });
    return s;
  };
  md.enumerateDevices = async () => [
    { deviceId: 'default', groupId: 'ftk', kind: 'audioinput', label: 'Claude', toJSON() { return this; } },
    { deviceId: 'default', groupId: 'ftk', kind: 'audiooutput', label: 'Claude', toJSON() { return this; } },
    { deviceId: 'ftk-tile', groupId: 'ftk', kind: 'videoinput', label: 'Claude', toJSON() { return this; } },
  ];
  md.getSupportedConstraints = () => ({ deviceId: true, groupId: true, echoCancellation: true, noiseSuppression: true, autoGainControl: true, sampleRate: true, channelCount: true, width: true, height: true, frameRate: true, facingMode: true, aspectRatio: true });
  md.ondevicechange = null;
  Object.defineProperty(Navigator.prototype, 'mediaDevices', { get: () => md, configurable: true });
  if (navigator.permissions && navigator.permissions.query) {
    const q = navigator.permissions.query.bind(navigator.permissions);
    navigator.permissions.query = async (d) => (d && (d.name === 'microphone' || d.name === 'camera'))
      ? { name: d.name, state: 'granted', onchange: null, addEventListener() {}, removeEventListener() {} }
      : q(d);
  }

  // ---- remote audio tap --------------------------------------------------
  const seen = new WeakSet();
  const attach = (track) => {
    if (!track || seen.has(track)) return;
    if (track.kind === 'video') {
      seen.add(track);
      state.videos.push(track);
      track.addEventListener('ended', () => { state.videos = state.videos.filter(v => v !== track); });
      return;
    }
    if (track.kind !== 'audio') return;
    seen.add(track);
    const c = audio();
    const src = c.createMediaStreamSource(new MediaStream([track]));
    src.connect(c.__mix);
    state.tracks++;
    post({ type: 'track', id: track.id, count: state.tracks });
    track.addEventListener('ended', () => {
      try { src.disconnect(); } catch (e) {}
      state.tracks--;
      post({ type: 'track-ended', id: track.id, count: state.tracks });
    });
  };
  const OPC = window.RTCPeerConnection;
  if (OPC) {
    if (cfg.verbose) {
      for (const m of ['createOffer', 'createAnswer', 'setLocalDescription', 'setRemoteDescription', 'addIceCandidate', 'addTrack', 'addTransceiver', 'getStats']) {
        const orig = OPC.prototype[m];
        if (!orig) continue;
        OPC.prototype[m] = function (...a) {
          if (m !== 'getStats') log('pc.' + m, m.startsWith('set') && a[0] ? (a[0].type + ' ' + (a[0].sdp || '').length + 'b') : '');
          try {
            const r = orig.apply(this, a);
            if (r && r.catch) r.catch(e => log('pc.' + m + ' failed', String(e)));
            return r;
          } catch (e) { log('pc.' + m + ' threw', String(e)); throw e; }
        };
      }
    }
    const PC = function (...a) {
      const pc = new OPC(...a);
      state.pcs.push(pc);
      pc.addEventListener('track', e => attach(e.track));
      if (cfg.verbose) {
        log('pc created', JSON.stringify(a[0] || {}).slice(0, 300));
        for (const ev of ['connectionstatechange', 'iceconnectionstatechange', 'signalingstatechange', 'icegatheringstatechange'])
          pc.addEventListener(ev, () => log('pc ' + ev, pc.connectionState, pc.iceConnectionState, pc.signalingState, pc.iceGatheringState));
        pc.addEventListener('track', e => log('pc track', e.track.kind, e.track.id));
      }
      return pc;
    };
    PC.prototype = OPC.prototype;
    Object.setPrototypeOf(PC, OPC);
    window.RTCPeerConnection = PC;
  }

  // The page plays remote audio through media elements; keep them silent unless monitoring.
  if (!cfg.monitor) {
    const d = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'muted');
    const wanted = new WeakMap();
    Object.defineProperty(HTMLMediaElement.prototype, 'muted', {
      configurable: true,
      get() { return wanted.has(this) ? wanted.get(this) : d.get.call(this); },
      set(v) { wanted.set(this, !!v); d.set.call(this, true); },
    });
    const play = HTMLMediaElement.prototype.play;
    HTMLMediaElement.prototype.play = function () { d.set.call(this, true); return play.apply(this, arguments); };
  }

  // ---- autopilot ----------------------------------------------------------
  const visible = (el) => !!el && el.getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden';
  const buttons = () => [...document.querySelectorAll('button, ui-button, ui-toggle-button, [role=button]')].filter(visible);
  const label = (el) => ((el.getAttribute('aria-label') || '') + ' ' + (el.innerText || '')).replace(/\s+/g, ' ').trim();
  const find = (re) => buttons().find(b => re.test(label(b)));
  const setValue = (input, v) => {
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(input, v);
    input.dispatchEvent(new Event('input', { bubbles: true }));
    input.dispatchEvent(new Event('change', { bubbles: true }));
  };
  const clickOnce = (el, key) => { if (!el || el['__ftk_' + key]) return false; el['__ftk_' + key] = 1; el.click(); return true; };

  let phase = 'loading', lastSnapshot = '';
  const setPhase = (p) => {
    if (p === phase) return;
    phase = p;
    if (p === 'in-call' && tile.get().state === 'connecting') tile.set({ state: 'listening' });
    post({ type: 'phase', phase: p, text: snapshot() });
  };
  const snapshot = () => (document.body ? document.body.innerText : '').replace(/\s+/g, ' ').trim().slice(0, 400);

  const tick = () => {
    const text = snapshot();
    if (/not supported|nicht unterstützt/i.test(text) && !document.querySelector('#name-entry')) return setPhase('unsupported');
    if (/request declined|can.t be joined|abgelehnt/i.test(text)) return setPhase('declined');
    if (/call ended|you left|anruf beendet|has ended/i.test(text) && !find(/^leave|end call/i)) return setPhase('ended');

    const name = document.querySelector('#name-entry');
    if (visible(name)) {
      if (name.value !== cfg.name) setValue(name, cfg.name);
      const cont = document.querySelector('.continue-button');
      if (cont && name.value) clickOnce(cont, 'continue');
      return setPhase('name');
    }

    // Make sure the microphone is on and the camera stays off (aria-pressed="true" means muted / camera on).
    const now = Date.now();
    const mute = document.getElementById('callcontrols-mute-button');
    if (mute && visible(mute) && mute.getAttribute('aria-pressed') === cfg.mutedPressed && now - (mute.__ftkAt || 0) > 3000) {
      mute.__ftkAt = now; mute.click(); log('unmuting microphone');
    }

    // Turn the "camera" (our tile) on once in the call: retry until a live video sender carries one of our tracks.
    if (phase === 'in-call' && !cfg.noVideo) {
      const sending = state.pcs.some(pc => { try { return pc.getSenders().some(s => s.track && s.track.kind === 'video' && s.track.readyState === 'live'); } catch (e) { return false; } });
      const cam = document.getElementById('callcontrols-video-button');
      state.camSending = sending;
      if (!sending && cam && visible(cam) && now - (cam.__ftkAt || 0) > 4000 && (cam.__ftkTries || 0) < 4) {
        cam.__ftkAt = now; cam.__ftkTries = (cam.__ftkTries || 0) + 1; cam.click(); log('turning the tile camera on (pressed=' + cam.getAttribute('aria-pressed') + ')');
      }
    }

    const join = find(/^(join|beitreten)$/i);
    if (join) { clickOnce(join, 'join'); return setPhase('joining'); }

    if (/waiting to be let in|waiting for|warten/i.test(text) && state.tracks === 0) return setPhase('waiting');
    if (find(/^(leave|end call|verlassen|auflegen)/i) || state.tracks > 0) return setPhase('in-call');
  };
  setInterval(() => { try { tick(); } catch (e) { post({ type: 'log', text: 'tick error ' + e }); } }, 700);

  window.__ftk = {
    play(data, id, sampleRate) {
      const c = audio();
      const pcm = new Int16Array(unb64(data));
      const buf = c.createBuffer(1, Math.max(1, pcm.length), sampleRate);
      const ch = buf.getChannelData(0);
      for (let i = 0; i < pcm.length; i++) ch[i] = pcm[i] / 32768;
      const s = c.createBufferSource();
      s.buffer = buf;
      s.connect(c.__outGain);
      s.onended = () => { if (state.playing === s) state.playing = null; post({ type: 'played', id }); };
      state.playing = s;
      s.start();
      return buf.duration;
    },
    stop() { if (state.playing) { try { state.playing.stop(); } catch (e) {} } },
    tile(p) { tile.set(p); return tile.get(); },
    chime() {
      // Soft two-note "got it" cue into the call.
      const c = audio(), t0 = c.currentTime + 0.01;
      [[660, 0], [990, 0.09]].forEach(([f, dt]) => {
        const o = c.createOscillator(), g = c.createGain();
        o.type = 'sine'; o.frequency.value = f;
        g.gain.setValueAtTime(0, t0 + dt);
        g.gain.linearRampToValueAtTime(0.06, t0 + dt + 0.015);
        g.gain.exponentialRampToValueAtTime(0.0001, t0 + dt + 0.16);
        o.connect(g).connect(c.__outGain);
        o.start(t0 + dt); o.stop(t0 + dt + 0.2);
      });
    },
    async showImage(dataURL) {
      if (!dataURL) { tile.set({ image: null }); return 'cleared'; }
      const im = new Image();
      await new Promise((ok, bad) => { im.onload = ok; im.onerror = () => bad(new Error('cannot decode image')); im.src = dataURL; });
      tile.set({ image: im });
      return im.width + 'x' + im.height;
    },
    // People in the call, read from the web client's participant tiles ("Displaying Anna’s video, toggle
    // prominence"), with the video tracks shown in each tile.
    people() {
      const frames = [...new Set(document.querySelectorAll('.participant-frame, [aria-label^="Displaying"]'))];
      return frames.map(f => {
        const l = f.getAttribute('aria-label') || '';
        const m = /^Displaying (.+?)[’']s? (\w+)/i.exec(l);
        const tracks = [...f.querySelectorAll('video')].flatMap(v => v.srcObject ? v.srcObject.getVideoTracks() : [])
          .filter(t => t.readyState === 'live');
        return { name: m ? m[1] : l, shows: m ? m[2] : '', video: tracks.some(t => !t.muted), tracks: tracks.map(t => t.id) };
      }).filter(p => p.name && !/^(you|your)$/i.test(p.name));
    },
    participants() { return JSON.stringify(this.people()); },
    async look(maxWidth, who) {
      // One JPEG frame per remote video track that is actually delivering frames (cameras, screen shares);
      // with `who`, only that person's.
      const within = (p, ms) => Promise.race([p, new Promise(r => setTimeout(() => r('timeout'), ms))]);
      const grab = async (track) => {
        const v = document.createElement('video');
        v.muted = true; v.playsInline = true; v.autoplay = true; v.srcObject = new MediaStream([track]);
        try {
          await within(v.play().catch(() => {}), 2500);
          await within(new Promise(r => { if (v.videoWidth) r(); else v.addEventListener('loadeddata', r, { once: true }); }), 2500);
          if (!v.videoWidth) return { id: track.id, error: 'no frames' };
          const s = Math.min(1, (maxWidth || 1600) / v.videoWidth);
          const cv = document.createElement('canvas');
          cv.width = Math.round(v.videoWidth * s); cv.height = Math.round(v.videoHeight * s);
          cv.getContext('2d').drawImage(v, 0, 0, cv.width, cv.height);
          const settings = track.getSettings ? track.getSettings() : {};
          return { id: track.id, width: v.videoWidth, height: v.videoHeight, surface: settings.displaySurface || '', jpeg: cv.toDataURL('image/jpeg', 0.85).split(',')[1] };
        } catch (e) {
          return { id: track.id, error: String(e) };
        } finally {
          v.pause(); v.srcObject = null;
        }
      };
      const people = this.people();
      const owner = id => (people.find(p => p.tracks.includes(id)) || {}).name || '';
      const want = String(who || '').toLowerCase();
      const live = state.videos.filter(t => t.readyState === 'live' && !t.muted)
        .filter(t => !want || owner(t.id).toLowerCase().includes(want));
      const out = await Promise.all(live.map(async t => Object.assign(await grab(t), { who: owner(t.id) })));
      return JSON.stringify(out);
    },
    hangup() {
      const b = find(/^(leave|end call|end|verlassen|auflegen|beenden)/i);
      if (b) { b.click(); return label(b); }
      return null;
    },
    status() {
      const m = document.getElementById('callcontrols-mute-button');
      return { phase, tracks: state.tracks, videos: state.videos.length, camSending: !!state.camSending, tile: tile.get(), mutePressed: m && m.getAttribute('aria-pressed'), micsEnabled: state.mics.map(t => t.enabled + '/' + t.readyState), peak: state.peak, sent: state.sent, ctx: ctx ? ctx.state : 'none', text: snapshot() };
    },
    dump() {
      return snapshot() + '\n---\n' + buttons().map(b => b.tagName.toLowerCase() + ' .' + (b.className || '') + ' [' + label(b) + ']').join('\n');
    },
  };
  post({ type: 'log', text: 'bridge installed' });
})();
"""#
}
