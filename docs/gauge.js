// Shared by the draft pages: draws the pace dial and plays the three example paces.
//
// Markup inside the root element:
//   <svg class="dial" viewBox="...">        the dial is drawn into it
//   <button data-s="coast|cruise|fast">     picks an example pace
//   <x data-g="menu|pace|live">             filled with the example's text (live follows the needle)
//   <x data-when="coast fast">              shown only for those examples
// The root gets data-state="<example>" and the class is-over while the needle is above 100%.
(function () {
  const NS = 'http://www.w3.org/2000/svg';
  const rad = d => d * Math.PI / 180;

  // 38% of the 5-hour limit left, 1h 48m to reset at 18:22, so SET is 21 %/h.
  const EXAMPLES = {
    coast: { v: 64, pace: '13 %/h', menu: '64% pace' },
    cruise: { v: 97, pace: '20 %/h', menu: '97% pace' },
    fast: { v: 138, pace: '29 %/h', menu: '138% pace · 17:52' }
  };

  window.TempomatDial = function (root, opts) {
    const o = Object.assign({
      cx: 150, cy: 150, r: 110, sweep: 270, max: 200,
      track: true, valueArc: true,
      minor: 10, major: 50, tickOuter: 15, tickMinor: 6, tickMajor: 12,
      labels: true, labelInset: 40,
      rim: true, rimGap: 15,
      setMark: 'triangle',
      needleInset: 22, needleWidth: 4, needleTail: 16, hub: 9, dot: 3.5,
      numberY: null, caption: null, captionY: null, onDraw: null,
      start: 'cruise', every: 4200, duration: 1300
    }, opts || {});

    const svg = root.querySelector('svg.dial');
    const half = o.sweep / 2;
    const ang = v => -half + o.sweep * Math.max(0, Math.min(o.max, v)) / o.max;
    const pt = (a, r) => [o.cx + r * Math.sin(rad(a)), o.cy - r * Math.cos(rad(a))];
    const arc = (a1, a2, r) => {
      const [x1, y1] = pt(a1, r), [x2, y2] = pt(a2, r);
      return `M${x1.toFixed(2)} ${y1.toFixed(2)} A${r} ${r} 0 ${a2 - a1 > 180 ? 1 : 0} 1 ${x2.toFixed(2)} ${y2.toFixed(2)}`;
    };
    const el = (name, attrs, parent) => {
      const e = document.createElementNS(NS, name);
      for (const k in attrs) e.setAttribute(k, attrs[k]);
      (parent || svg).appendChild(e);
      return e;
    };

    if (o.track) el('path', { d: arc(-half, half, o.r), class: 'd-track' });
    const value = o.valueArc ? el('path', { d: arc(-half, -half + .1, o.r), class: 'd-value' }) : null;
    if (o.rim) el('path', { d: arc(ang(100), half, o.r + o.rimGap), class: 'd-rim' });
    for (let v = 0; v <= o.max; v += o.minor) {
      const major = v % o.major === 0, a = ang(v);
      const [x1, y1] = pt(a, o.r - o.tickOuter);
      const [x2, y2] = pt(a, o.r - o.tickOuter - (major ? o.tickMajor : o.tickMinor));
      el('line', { x1, y1, x2, y2, class: major ? 'd-tick d-major' : 'd-tick' });
      if (major && o.labels) {
        const [tx, ty] = pt(a, o.r - o.labelInset);
        el('text', { x: tx, y: ty, class: 'd-label', 'text-anchor': 'middle', 'dominant-baseline': 'central' }).textContent = v;
      }
    }
    const set = el('g', { class: 'd-set', transform: `rotate(${ang(100)} ${o.cx} ${o.cy})` });
    if (o.setMark === 'triangle') {
      el('path', { d: `M${o.cx - 8} ${o.cy - o.r - 22} L${o.cx + 8} ${o.cy - o.r - 22} L${o.cx} ${o.cy - o.r + 3} Z` }, set);
    } else if (o.setMark === 'line') {
      el('line', { x1: o.cx, y1: o.cy - o.r - o.rimGap - 8, x2: o.cx, y2: o.cy - o.r + 10 }, set);
    }

    const needle = el('g', { class: 'd-needle' });
    const w = o.needleWidth;
    el('path', { d: `M${o.cx - w} ${o.cy} L${o.cx} ${o.cy - o.r + o.needleInset} L${o.cx + w} ${o.cy} L${o.cx} ${o.cy + o.needleTail} Z` }, needle);
    if (o.hub) el('circle', { cx: o.cx, cy: o.cy, r: o.hub, class: 'd-hub' });
    if (o.dot) el('circle', { cx: o.cx, cy: o.cy, r: o.dot, class: 'd-dot' });
    const num = o.numberY == null ? null : el('text', { x: o.cx, y: o.cy + o.numberY, class: 'd-num', 'text-anchor': 'middle' });
    if (o.caption) el('text', { x: o.cx, y: o.cy + o.captionY, class: 'd-cap', 'text-anchor': 'middle' }).textContent = o.caption;

    const lives = root.querySelectorAll('[data-g="live"]');
    const draw = v => {
      const a = ang(v);
      needle.setAttribute('transform', `rotate(${a.toFixed(2)} ${o.cx} ${o.cy})`);
      if (value) value.setAttribute('d', arc(-half, Math.max(a, -half + .1), o.r));
      root.classList.toggle('is-over', v > 100);
      const text = Math.round(Math.max(0, v)) + '%';
      if (num) num.textContent = text;
      lives.forEach(n => { n.textContent = text; });
      if (o.onDraw) o.onDraw(v);
    };

    const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    const easeOutBack = t => 1 + 2.2 * Math.pow(t - 1, 3) + 1.2 * Math.pow(t - 1, 2);
    let cur = 0, raf = 0;
    const animate = target => {
      cancelAnimationFrame(raf);
      if (reduce) { cur = target; draw(cur); return; }
      const from = cur, t0 = performance.now();
      const step = now => {
        const t = Math.min(1, (now - t0) / o.duration);
        cur = from + (target - from) * easeOutBack(t);
        draw(cur);
        if (t < 1) raf = requestAnimationFrame(step);
      };
      raf = requestAnimationFrame(step);
    };

    const buttons = root.querySelectorAll('[data-s]');
    const label = key => {
      const ex = EXAMPLES[key];
      root.dataset.state = key;
      buttons.forEach(b => b.setAttribute('aria-pressed', String(b.dataset.s === key)));
      root.querySelectorAll('[data-g]').forEach(n => { if (n.dataset.g in ex) n.textContent = ex[n.dataset.g]; });
      root.querySelectorAll('[data-when]').forEach(n => { n.hidden = !n.dataset.when.split(' ').includes(key); });
    };
    const show = key => { label(key); animate(EXAMPLES[key].v); };

    const order = Object.keys(EXAMPLES);
    let idx = order.indexOf(o.start), timer = 0, started = false;
    buttons.forEach(b => b.addEventListener('click', () => {
      clearInterval(timer);
      idx = order.indexOf(b.dataset.s);
      started = true;
      show(b.dataset.s);
    }));

    label(order[idx]);
    draw(0);
    const start = () => {
      if (started) return;
      started = true;
      show(order[idx]);
      if (!reduce) timer = setInterval(() => { idx = (idx + 1) % order.length; show(order[idx]); }, o.every);
    };
    if ('IntersectionObserver' in window) {
      const io = new IntersectionObserver(es => {
        if (es.some(e => e.isIntersecting)) { io.disconnect(); setTimeout(start, 250); }
      }, { threshold: .3 });
      io.observe(svg);
    } else {
      start();
    }

    return { svg, pt, ang, el, o };
  };
})();
