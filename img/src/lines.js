// 座標を指定して、水平と垂直の線だけで矢印を引く（wires.js の wire() を補う）。
// poly([[x1, y1], [x2, y2], ...], {hot, grey, dash, both, noarrow})
// 線の色と矢じりは wires.js と同じ。矢じりの先端は最後の点に来る。
// 斜めの線を引かないように、隣り合う 2 点は x か y のどちらかをそろえる（そろっていなければ例外にする）。
(function () {
  const NS = 'http://www.w3.org/2000/svg';
  function ensureGreyMarkers(svg) {
    if (svg.querySelector('#ag')) return;
    const defs = svg.querySelector('defs') || svg.appendChild(document.createElementNS(NS, 'defs'));
    defs.insertAdjacentHTML('beforeend',
      '<marker id="ag" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0 0L10 5L0 10z" fill="#8a877f"/></marker>' +
      '<marker id="ags" viewBox="0 0 10 10" refX="1" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M10 0L0 5L10 10z" fill="#8a877f"/></marker>');
  }
  window.poly = function (pts, o = {}) {
    for (let i = 1; i < pts.length; i++) {
      const [a, b] = [pts[i - 1], pts[i]];
      if (a[0] !== b[0] && a[1] !== b[1]) throw new Error('斜めの線: ' + JSON.stringify([a, b]));
    }
    const svg = document.getElementById('wires');
    ensureGreyMarkers(svg);
    const color = o.hot ? '#ff4d00' : o.grey ? '#8a877f' : '#0c0c0c';
    const m = o.hot ? 'ah' : o.grey ? 'ag' : 'ak';
    const p = document.createElementNS(NS, 'polyline');
    p.setAttribute('points', pts.map((q) => q.join(',')).join(' '));
    p.setAttribute('fill', 'none'); p.setAttribute('stroke', color); p.setAttribute('stroke-width', '2.5');
    if (o.dash) p.setAttribute('stroke-dasharray', '6 5');
    if (!o.noarrow) p.setAttribute('marker-end', `url(#${m})`);
    if (o.both) p.setAttribute('marker-start', `url(#${m}s)`);
    svg.appendChild(p);
  };
})();
