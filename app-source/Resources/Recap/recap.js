(() => {
  'use strict';
  let data = null;
  const expanded = { songs: false, artists: false, albums: false };
  const limits = { songs: 5, artists: 5, albums: 3 };
  const $ = id => document.getElementById(id);
  const number = value => Number(value || 0).toLocaleString();
  const send = (action, rest = {}) => window.webkit?.messageHandlers?.recap?.postMessage({ action, ...rest });
  function text(id, value) {
    const node = $(id);
    if (node.textContent !== String(value)) node.textContent = String(value);
  }
  function element(tag, className, content) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (content !== undefined) node.textContent = String(content);
    return node;
  }
  function total(row) { return data.metric === 'time' ? row.duration : number(row.entries); }
  function amount(row) { return data.metric === 'time' ? row.seconds : row.entries; }
  function rowNode(row, maximum) {
    const node = element('div', 'rank-row');
    const identity = element('div', 'row-identity');
    identity.append(element('div', 'row-title', row.title));
    if (row.subtitle) identity.append(element('div', 'row-subtitle', row.subtitle));
    const track = element('div', 'bar-track');
    const bar = element('div', 'rank-bar');
    bar.style.width = `${maximum > 0 ? amount(row) / maximum * 100 : 0}%`;
    bar.dataset.value = String(amount(row));
    track.append(bar); identity.append(track);
    track.setAttribute('aria-hidden', 'true');
    const value = element('div', 'row-total');
    value.append(element('strong', '', total(row)));
    const movement = element('span', `movement ${row.direction}`, row.movement === '—' ? '–' : row.movement);
    movement.title = row.movementHelp; movement.setAttribute('aria-label', row.movementHelp);
    value.append(movement);
    node.append(element('span', 'row-rank', String(row.rank).padStart(2, '0')), identity, value);
    node.title = `${row.title}: ${number(row.entries)} entries · ${row.duration} observed. ${row.movementHelp}`;
    return node;
  }
  function renderList(category) {
    const container = $(category === 'songs' ? 'song-list' : category === 'artists' ? 'artist-list' : 'album-list');
    const rows = data[category];
    const visible = expanded[category] ? rows : rows.slice(0, limits[category]);
    const maximum = rows.length ? amount(rows[0]) : 0;
    const signature = JSON.stringify([data.metric, maximum, visible]);
    if (container.dataset.signature !== signature) {
      container.replaceChildren(...visible.map(row => rowNode(row, maximum)));
      container.dataset.signature = signature;
    }
    const button = $(`more-${category}`);
    button.hidden = rows.length <= limits[category];
    button.textContent = expanded[category] ? 'Less ↑' : `All ${number(rows.length)} ↓`;
    button.setAttribute('aria-expanded', String(expanded[category]));
    button.setAttribute('aria-label', expanded[category] ? `Show fewer ${category}` : `Show all ${rows.length} ${category}`);
    document.querySelector(`.export[data-category="${category}"]`).disabled = rows.length === 0;
  }
  function svgElement(tag, attrs = {}, content) {
    const node = document.createElementNS('http://www.w3.org/2000/svg', tag);
    for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, String(value));
    if (content !== undefined) node.textContent = String(content);
    return node;
  }
  function renderDays() {
    const chart = $('day-chart');
    const width = Math.max(320, chart.clientWidth), height = Math.max(160, chart.clientHeight);
    const signature = JSON.stringify([data.month, data.days, width, height]);
    if (chart.dataset.signature === signature) return;
    const observed = data.days.filter(day => !day.future);
    const peak = Math.max(0, ...observed.map(day => day.seconds / 60));
    const left = peak >= 10000 ? 78 : peak >= 1000 ? 65 : 42, right = 12, top = 14, bottom = 28;
    const plotWidth = width - left - right, plotHeight = height - top - bottom;
    // Three explicit, shared tick intervals. The same baseline and scale apply
    // to every day; upcoming dates never become fabricated zero observations.
    const step = Math.max(1, Math.ceil(peak / 3));
    const ceiling = step * 3;
    const x = day => left + (day - 1) / Math.max(1, data.days.length - 1) * plotWidth;
    const y = seconds => top + plotHeight * (1 - seconds / 60 / ceiling);
    const svg = svgElement('svg', { viewBox: `0 0 ${width} ${height}`, preserveAspectRatio: 'none', 'aria-label': `${data.monthName}: daily observed minutes` });
    svg.append(svgElement('title', {}, `${data.monthName} daily listening`));
    const firstFuture = data.days.find(day => day.future);
    if (firstFuture) {
      const boundary = (x(firstFuture.day - 1) + x(firstFuture.day)) / 2;
      svg.append(svgElement('rect', { x: boundary, y: top, width: width - right - boundary, height: plotHeight, class: 'future-area' }));
    }
    for (let tick = 0; tick <= 3; tick++) {
      const minutes = tick * step;
      const position = top + plotHeight * (1 - tick / 3);
      svg.append(svgElement('line', { x1: left, x2: width - right, y1: position, y2: position, class: 'grid-line' }));
      svg.append(svgElement('text', { x: left - 10, y: position + 4, 'text-anchor': 'end', class: 'axis-label' }, number(minutes)));
    }
    const ticks = [...new Set([1, 8, 15, 22, data.days.length])];
    for (const day of ticks) {
      svg.append(svgElement('text', { x: x(day), y: height - 6, 'text-anchor': day === 1 ? 'start' : day === data.days.length ? 'end' : 'middle', class: 'axis-label' }, day));
    }
    if (observed.length) {
      const points = observed.map(day => `${x(day.day)},${y(day.seconds)}`).join(' ');
      svg.append(svgElement('polygon', { points: `${x(observed[0].day)},${y(0)} ${points} ${x(observed[observed.length - 1].day)},${y(0)}`, class: 'listening-area' }));
      svg.append(svgElement('polyline', { points, class: 'listening-line', 'vector-effect': 'non-scaling-stroke' }));
      for (const day of observed) {
        const label = `${data.monthName} ${day.day} · ${number(Math.round(day.seconds / 60 * 10) / 10)} min`;
        const point = svgElement('g', { class: 'data-point', tabindex: 0, role: 'img', 'aria-label': label });
        point.append(svgElement('title', {}, label));
        point.append(svgElement('circle', { cx: x(day.day), cy: y(day.seconds), r: 11, class: 'point-hit' }));
        point.append(svgElement('circle', { cx: x(day.day), cy: y(day.seconds), r: 3, class: 'point-dot', 'vector-effect': 'non-scaling-stroke' }));
        point.addEventListener('pointerenter', () => text('chart-readout', label));
        point.addEventListener('pointerleave', () => { if (!point.matches(':focus')) text('chart-readout', ''); });
        point.addEventListener('focus', () => text('chart-readout', label));
        point.addEventListener('blur', () => text('chart-readout', ''));
        svg.append(point);
      }
    }
    // Restore the inspected day across updates, as well as keyboard focus.
    const focused = chart.contains(document.activeElement) ? document.activeElement.getAttribute('aria-label')?.split(' · ')[0] : null;
    chart.replaceChildren(svg); chart.dataset.signature = signature;
    chart.setAttribute('aria-label', `${data.monthName}: ${data.activeDays} listening days. ${observed.map(day => `Day ${day.day}: ${Math.round(day.seconds / 60 * 10) / 10} minutes`).join('; ')}`);
    if (focused) {
      const point = [...svg.querySelectorAll('.data-point')].find(node => node.getAttribute('aria-label').startsWith(focused + ' · '));
      point?.focus({ preventScroll: true });
    } else text('chart-readout', '');
  }
  function update(payload) {
    const changedMonth = data?.month && data.month !== payload.month;
    if (changedMonth) Object.keys(expanded).forEach(key => { expanded[key] = false; });
    data = payload;
    text('month-name', `${data.monthName} ${data.year}`);
    text('status', data.current ? data.recording ? 'Live' : 'Paused' : 'Archive');
    $('status-dot').classList.toggle('paused', !data.current || !data.recording);
    text('minutes', number(data.minutes)); text('entries', number(data.entries));
    text('song-count', number(data.songCount)); text('artist-count', number(data.artistCount)); text('active-days', number(data.activeDays));
    text('song-count-label', data.songCount === 1 ? 'Song' : 'Songs');
    text('artist-count-label', data.artistCount === 1 ? 'Artist' : 'Artists');
    text('active-days-label', data.activeDays === 1 ? 'Day' : 'Days');
    const choices = JSON.stringify(data.months);
    if ($('month').dataset.choices !== choices) {
      $('month').replaceChildren(...data.months.map(month => { const option = element('option', '', month.label); option.value = month.key; return option; }));
      $('month').dataset.choices = choices;
    }
    $('month').value = data.month; $('next').disabled = data.current; $('metric').value = data.metric;
    for (const category of Object.keys(expanded)) { renderList(category); $(category).hidden = data.entries === 0; }
    $('activity').hidden = data.entries === 0; $('ranking-toolbar').hidden = data.entries === 0;
    $('empty-message').hidden = data.entries !== 0;
    text('empty-detail', data.current ? 'Start recording in AM Track.' : 'Choose another month.');
    renderDays();
    text('updated', `${data.updated} · Local${data.current && data.recording ? ' · 5s updates' : ''}`);
    text('provenance', `${number(data.undated)} undated entries excluded. ${data.timeZone}. Data stays inside AM Track.`);
    if (changedMonth) { window.scrollTo(0, 0); text('announcement', `${data.monthName} ${data.year}`); }
  }
  $('previous').addEventListener('click', () => send('previous'));
  $('next').addEventListener('click', () => send('next'));
  $('month').addEventListener('change', event => send('month', { value: event.target.value }));
  $('metric').addEventListener('change', event => send('metric', { value: event.target.value }));
  $('refresh').addEventListener('click', () => send('refresh'));
  for (const category of Object.keys(expanded)) {
    $(`more-${category}`).addEventListener('click', () => { expanded[category] = !expanded[category]; renderList(category); });
  }
  document.querySelectorAll('.export').forEach(button => button.addEventListener('click', () => send('export', { category: button.dataset.category })));
  new ResizeObserver(() => { if (data) renderDays(); }).observe($('day-chart'));
  window.Recap = { update };
  send('ready');
})();
