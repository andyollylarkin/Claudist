/* Claudist code graph viewer: one saved view (data/<id>.json), drawn with sigma.js. */
(() => {
  "use strict";
  const params = new URLSearchParams(location.search);
  const viewId = params.get("view") || "";
  const full = params.get("mode") === "full";
  document.body.classList.add(full ? "full" : "inline");
  if (full) document.body.classList.add("legend");

  const $ = (id) => document.getElementById(id);
  const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const post = (type, payload = {}) => {
    try { window.webkit.messageHandlers.graph.postMessage(Object.assign({ type, view: viewId }, payload)); } catch (e) { console.log(type, payload); }
  };
  window.onerror = (msg, src, line) => { post("error", { text: `${msg} (${(src || "").split("/").pop()}:${line})` }); };

  const PALETTE = ["#4E79A7", "#F28E2B", "#59A14F", "#E15759", "#76B7B2", "#EDC948", "#B07AA1", "#FF9DA7",
    "#9C755F", "#86BCB6", "#D37295", "#8CD17D", "#A0CBE8", "#FFBE7D", "#BAB0AC", "#499894"];
  const ROLE_LABEL = { seed: "Center", path: "Path", changed: "Changed", affected: "Depends on changes" };
  let drawn = false;

  let data, graph, renderer;
  const color = {};          // community -> color
  const communityName = {};  // community -> name
  const state = {
    hovered: null, selected: null, neighbors: new Set(),
    hiddenCommunities: new Set(), hiddenRelations: new Set(),
    showInferred: true, showExternal: true, neighborhoodOnly: false,
    pathFrom: null, path: null, hidden: new Set(),
  };

  // WebGL colors are opaque here: blend toward the background instead of using alpha.
  function rgb(hex) {
    const h = hex.replace("#", "");
    const n = parseInt(h.length === 3 ? h.split("").map((c) => c + c).join("") : h, 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  function fade(hex, amount) {
    const a = rgb(hex), b = rgb(css("--bg"));
    const m = a.map((v, i) => Math.round(v * amount + b[i] * (1 - amount)));
    return "#" + m.map((v) => v.toString(16).padStart(2, "0")).join("");
  }

  // MARK: Data

  async function load() {
    const res = await fetch("data/" + encodeURIComponent(viewId) + ".json");
    if (!res.ok) throw new Error("This graph view is no longer available (" + res.status + ")");
    data = await res.json();
    drawn = data.mode === "drawn";
    if (drawn) ROLE_LABEL.seed = "Highlighted";
  }

  function build() {
    graph = new graphology.MultiDirectedGraph();
    const counts = {};
    for (const n of data.nodes) {
      const c = n.community ?? -1;
      counts[c] = (counts[c] || 0) + 1;
      if (n.communityName && communityName[c] == null) communityName[c] = n.communityName;
    }
    const ranked = Object.keys(counts).filter((c) => c !== "-1").sort((a, b) => counts[b] - counts[a]);
    ranked.forEach((c, i) => { color[c] = i < PALETTE.length ? PALETTE[i] : generated(i); });
    color["-1"] = css("--external");
    state.communityCounts = counts;
    state.ranked = ranked;
    state.hasRoles = data.nodes.some((n) => n.role);

    const pos = data.positions || {};
    const slot = {};
    ranked.forEach((c, i) => { slot[c] = i; });
    data.nodes.forEach((n, i) => {
      let x, y;
      if (pos[n.id]) [x, y] = pos[n.id];
      else {
        // Each subsystem starts in its own place so the layout settles quickly.
        const k = slot[n.community ?? -1] ?? ranked.length;
        const r = 12 * Math.sqrt(k + 1), a = k * 2.399;
        x = r * Math.cos(a) + (Math.random() - 0.5) * 6;
        y = r * Math.sin(a) + (Math.random() - 0.5) * 6;
      }
      graph.addNode(String(i), {
        x, y, label: n.label, size: nodeSize(n), color: nodeColor(n),
        community: String(n.community ?? -1), role: n.role || null, kind: n.kind,
        forceLabel: n.role === "seed" || n.role === "path" || n.role === "changed",
      });
    });
    data.edges.forEach((e, i) => {
      const arrow = drawn ? e.directed !== false : !!e.onPath;
      graph.addEdgeWithKey("e" + i, String(e.s), String(e.t), {
        relation: e.relation, confidence: e.confidence, onPath: !!e.onPath, directed: arrow,
        label: drawn && e.relation !== "related" ? e.relation : "",
        size: e.onPath ? 2.5 : drawn ? 1 : 0.7, color: e.onPath ? css("--edge-hi") : css("--edge"), type: arrow ? "arrow" : "line",
      });
    });
    if (data.mode === "path") {
      const nodes = new Set(graph.filterNodes((_, a) => a.role === "path"));
      const edges = new Set(graph.filterEdges((_, a) => a.onPath));
      if (nodes.size) state.path = { nodes, edges, given: true };
    }
  }

  /// Colors past the palette: golden-angle hues, so neighbors in the ranking still differ.
  function generated(i) {
    const dark = matchMedia("(prefers-color-scheme: dark)").matches;
    const h = (i * 137.508) % 360, s = 0.42, l = dark ? 0.6 : 0.55;
    const k = (n) => (n + h / 30) % 12, a = s * Math.min(l, 1 - l);
    const f = (n) => Math.round(255 * (l - a * Math.max(-1, Math.min(k(n) - 3, Math.min(9 - k(n), 1)))));
    return "#" + [f(0), f(8), f(4)].map((v) => v.toString(16).padStart(2, "0")).join("");
  }

  function nodeSize(n) {
    const scale = data.nodes.length > 1500 ? 0.6 : data.nodes.length > 500 ? 0.8 : 1;
    // Drawn graphs are usually small: give every node a size you can hit.
    const base = Math.min(drawn ? 18 : 15, (drawn ? 6 : 2.6) + 1.7 * Math.log2(1 + (n.degree || 0))) * scale;
    return n.role === "seed" || n.role === "path" || n.role === "changed" ? base + 3 : base;
  }

  function nodeColor(n) {
    if (n.role === "seed" || n.role === "path") return css("--accent");
    if (n.role === "changed") return css("--changed");
    if (n.role === "affected") return css("--affected");
    if (!drawn && n.kind === "external") return css("--external");
    const c = color[String(n.community ?? -1)] || css("--external");
    return state.hasRoles ? fade(c, 0.5) : c;
  }

  // MARK: Rendering

  function computeHidden() {
    const hidden = new Set();
    const sel = state.selected;
    graph.forEachNode((node, a) => {
      if (state.hiddenCommunities.has(a.community)) hidden.add(node);
      else if (!drawn && !state.showExternal && a.kind === "external") hidden.add(node);
      else if (state.neighborhoodOnly && sel != null && node !== sel && !graph.areNeighbors(node, sel)) hidden.add(node);
    });
    state.hidden = hidden;
  }

  function nodeReducer(node, a) {
    if (state.hidden.has(node)) return Object.assign({}, a, { hidden: true });
    const res = Object.assign({}, a);
    const focus = state.hovered ?? state.selected;
    if (focus != null) {
      if (node === focus || state.neighbors.has(node)) {
        res.zIndex = 2;
        if (node === focus) res.highlighted = true;
        if (node === focus || state.neighbors.size <= 30) res.forceLabel = true;
      } else {
        res.color = css("--dim");
        res.label = "";
        res.forceLabel = false;
        res.zIndex = 0;
      }
    } else if (state.path) {
      if (state.path.nodes.has(node)) { res.zIndex = 2; res.forceLabel = true; res.highlighted = !state.path.given; }
      else { res.color = css("--dim"); res.forceLabel = false; }
    }
    return res;
  }

  function edgeReducer(edge, a) {
    if (state.hiddenRelations.has(a.relation) || (!state.showInferred && a.confidence === "INFERRED")) return Object.assign({}, a, { hidden: true });
    const [s, t] = graph.extremities(edge);
    if (state.hidden.has(s) || state.hidden.has(t)) return Object.assign({}, a, { hidden: true });
    const res = Object.assign({}, a);
    const focus = state.hovered ?? state.selected;
    if (focus != null) {
      if (s === focus || t === focus) { res.color = css("--edge-hi"); res.size = 1.6; res.zIndex = 1; res.type = drawn ? a.type : "arrow"; res.forceLabel = true; }
      else res.hidden = true;
    } else if (state.path) {
      if (state.path.edges.has(edge)) { res.color = css("--edge-hi"); res.size = 3; res.zIndex = 2; res.type = "arrow"; }
      else res.color = css("--dim");
    }
    return res;
  }

  function drawHover(ctx, d, settings) {
    const size = settings.labelSize, font = settings.labelFont, weight = settings.labelWeight;
    ctx.font = `${weight} ${size}px ${font}`;
    const label = d.label || "";
    const w = ctx.measureText(label).width + 12, h = size + 10;
    const x = d.x + d.size + 3, y = d.y - h / 2;
    ctx.fillStyle = css("--panel");
    ctx.shadowColor = "rgba(0,0,0,.18)"; ctx.shadowBlur = 8;
    ctx.beginPath();
    if (ctx.roundRect) ctx.roundRect(x, y, w, h, 6); else ctx.rect(x, y, w, h);
    ctx.fill();
    ctx.shadowBlur = 0;
    ctx.fillStyle = css("--text");
    ctx.fillText(label, x + 6, d.y + size / 3);
    ctx.beginPath();
    ctx.arc(d.x, d.y, d.size + 2, 0, Math.PI * 2);
    ctx.strokeStyle = css("--accent"); ctx.lineWidth = 2; ctx.stroke();
  }

  function createRenderer() {
    renderer = new Sigma(graph, $("graph"), {
      // Drawn graphs name their links; show the names while there are few enough to read.
      renderEdgeLabels: drawn && graph.size <= 200,
      edgeLabelSize: 10,
      edgeLabelColor: { color: css("--muted") },
      labelFont: '-apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif',
      labelSize: 12, labelWeight: "500",
      labelColor: { color: css("--text") },
      // Small views label everything; big ones label what is large enough on screen.
      labelRenderedSizeThreshold: graph.order <= 80 ? 0 : full ? 7 : 9,
      labelDensity: full ? 0.9 : 0.6,
      defaultEdgeColor: css("--edge"),
      zIndex: true, minCameraRatio: 0.02, maxCameraRatio: 12,
      // Room for the toolbar and the status line.
      stagePadding: 48,
      allowInvalidContainer: true,
      hoverRenderer: drawHover,
      nodeReducer, edgeReducer,
    });
    renderer.on("enterNode", ({ node }) => { setHover(node); });
    renderer.on("leaveNode", () => { setHover(null); });
    renderer.on("clickNode", ({ node }) => {
      if (state.pathFrom != null && state.pathFrom !== node) return showPath(state.pathFrom, node);
      select(node);
    });
    renderer.on("doubleClickNode", (e) => { e.preventSigmaDefault && e.preventSigmaDefault(); openNode(e.node); });
    renderer.on("clickStage", () => {
      if (state.pathFrom != null) { state.pathFrom = null; banner(); }
      else if (state.path && !state.path.given) state.path = null;
      select(null);
    });
  }

  function refresh() { if (renderer) renderer.refresh(); }

  function setHover(node) {
    state.hovered = node;
    const focus = node ?? state.selected;
    state.neighbors = focus != null ? new Set(graph.neighbors(focus)) : new Set();
    $("graph").style.cursor = node != null ? "pointer" : "";
    refresh();
  }

  // MARK: Layout

  function layout(force) {
    if (data.positions && !force) return done(false);
    $("loading").textContent = "Laying out " + graph.order + " nodes…";
    $("loading").classList.remove("hide");
    const lib = graphologyLibrary;
    const settings = lib.layoutForceAtlas2.inferSettings(graph);
    settings.barnesHutOptimize = graph.order > 250;
    settings.adjustSizes = false;
    // LinLog pulls subsystems into visible clusters instead of one ball.
    settings.linLogMode = graph.order > 60;
    if (settings.linLogMode) { settings.scalingRatio = Math.max(settings.scalingRatio || 1, 2); settings.gravity = 0.5; }
    let worker = null;
    try {
      worker = new lib.FA2Layout(graph, { settings });
      worker.start();
    } catch (e) {
      worker = null;
      lib.layoutForceAtlas2.assign(graph, { iterations: graph.order > 1500 ? 60 : 150, settings });
    }
    const finish = () => {
      if (worker) { worker.stop(); worker.kill(); }
      try { lib.layoutNoverlap.assign(graph, { maxIterations: graph.order > 1500 ? 15 : 40, settings: { ratio: 1.3, margin: 1 } }); } catch (e) { /* optional */ }
      done(true);
    };
    if (worker) setTimeout(finish, Math.min(7000, 1500 + graph.order * 2)); else finish();
  }

  function done(save) {
    $("loading").classList.add("hide");
    refresh();
    if (renderer) renderer.getCamera().animatedReset({ duration: 300 });
    if (save) {
      const positions = {};
      graph.forEachNode((node, a) => { positions[data.nodes[+node].id] = [Math.round(a.x * 100) / 100, Math.round(a.y * 100) / 100]; });
      post("positions", { positions });
    }
  }

  // MARK: Selection and details

  function select(node, move) {
    state.selected = node;
    state.neighbors = node != null ? new Set(graph.neighbors(node)) : new Set();
    if (!node) state.neighborhoodOnly = false;
    computeHidden();
    refresh();
    details();
    if (node != null && move) focusCamera(node);
  }

  function focusCamera(node) {
    const d = renderer.getNodeDisplayData(node);
    if (!d) return;
    const cam = renderer.getCamera();
    cam.animate({ x: d.x, y: d.y, ratio: Math.min(cam.getState().ratio, 0.3) }, { duration: 450 });
  }

  function nodeInfo(node) { return data.nodes[+node]; }

  function where(n) {
    if (n.file) return n.file + (n.line ? ":" + n.line : "");
    if (n.link) return n.link + (n.line && n.link.startsWith("/") ? ":" + n.line : "");
    return null;
  }
  const isPath = (link) => !!link && (link.startsWith("/") || link.startsWith("~"));

  function details() {
    const box = $("details");
    const node = state.selected;
    if (node == null) { box.classList.remove("show"); return; }
    const n = nodeInfo(node);
    const groups = {};
    graph.forEachOutEdge(node, (e, a, s, t) => { (groups[a.relation + " →"] ||= []).push(t); });
    graph.forEachInEdge(node, (e, a, s) => { (groups["← " + a.relation] ||= []).push(s); });
    const comm = communityName[n.community ?? -1] || (n.community != null ? "Community " + n.community : "");
    const target = where(n);
    const kindText = drawn ? esc(comm) : esc(n.kind) + (comm ? " · " + esc(comm) : "");
    let html = `<button class="close" id="d-close" title="Close">✕</button>
      <h3>${esc(n.label)}</h3>
      <div class="meta">${kindText} · ${n.degree} links${drawn ? "" : " in the whole graph"}${n.role ? " · <b>" + esc(ROLE_LABEL[n.role] || n.role) + "</b>" : ""}</div>`;
    if (n.description) html += `<div class="desc">${esc(n.description)}</div>`;
    if (target) html += `<a class="file" id="d-open">${esc(target)}</a>`;
    const canReveal = n.file || isPath(n.link);
    html += `<div class="actions">
      ${target ? '<button class="primary" id="d-openbtn">Open</button>' : ""}${canReveal ? '<button id="d-reveal">Reveal</button>' : ""}
      <button id="d-ask" title="Put this node into your message">Ask in chat</button>
      <button id="d-path" class="${state.pathFrom === node ? "on" : ""}" title="Then click another node">Path from here</button>
      <button id="d-hood" class="${state.neighborhoodOnly ? "on" : ""}">Only neighbors</button>
      <button id="d-copy">Copy</button>
    </div>`;
    const keys = Object.keys(groups).sort((a, b) => groups[b].length - groups[a].length);
    if (!keys.length) html += `<h4>No links in this view</h4>`;
    for (const k of keys) {
      const list = [...new Set(groups[k])].sort((a, b) => nodeInfo(b).degree - nodeInfo(a).degree);
      html += `<h4>${esc(k)} (${list.length})</h4>`;
      for (const m of list.slice(0, 40)) {
        const x = nodeInfo(m);
        html += `<div class="conn" data-node="${m}"><span class="dot" style="background:${graph.getNodeAttribute(m, "color")}"></span><span class="name">${esc(x.label)}</span><span class="tag">${esc(x.kind)}</span></div>`;
      }
      if (list.length > 40) html += `<div class="meta">… ${list.length - 40} more</div>`;
    }
    box.innerHTML = html;
    box.classList.add("show");
    $("d-close").onclick = () => select(null);
    if (target) $("d-open").onclick = $("d-openbtn").onclick = () => openNode(node);
    if (canReveal) $("d-reveal").onclick = () => post("reveal", n.file ? { file: n.file } : { link: n.link });
    $("d-ask").onclick = () => post("ask", { text: "`" + n.label + "`" + (n.file ? " (" + where(n) + ")" : "") + " " });
    $("d-path").onclick = () => { state.pathFrom = state.pathFrom === node ? null : node; banner(); details(); };
    $("d-hood").onclick = () => { state.neighborhoodOnly = !state.neighborhoodOnly; computeHidden(); refresh(); details(); };
    $("d-copy").onclick = () => post("copy", { text: n.label + (target ? " — " + target : "") + (n.description ? "\n" + n.description : "") });
    box.querySelectorAll(".conn").forEach((el) => { el.onclick = () => select(el.dataset.node, true); });
  }

  function openNode(node) {
    const n = nodeInfo(node);
    if (n.file) post("open", { file: n.file, line: n.line || 0 });
    else if (n.link) post("link", { link: n.link, line: n.line || 0 });
  }

  // MARK: Paths

  function shortestPath(a, b) {
    const prev = new Map([[a, a]]);
    const queue = [a];
    for (let i = 0; i < queue.length; i++) {
      const n = queue[i];
      for (const m of graph.neighbors(n)) {
        if (prev.has(m) || state.hidden.has(m)) continue;
        prev.set(m, n);
        if (m === b) {
          const path = [b];
          let cur = b;
          while (cur !== a) { cur = prev.get(cur); path.push(cur); }
          return path.reverse();
        }
        queue.push(m);
      }
    }
    return null;
  }

  function showPath(a, b) {
    state.pathFrom = null;
    const path = shortestPath(a, b);
    if (!path) { banner(`No path between “${esc(nodeInfo(a).label)}” and “${esc(nodeInfo(b).label)}” in this view.`); return; }
    const edges = new Set();
    for (let i = 0; i + 1 < path.length; i++) {
      const e = graph.edges(path[i], path[i + 1])[0] || graph.edges(path[i + 1], path[i])[0];
      if (e) edges.add(e);
    }
    state.path = { nodes: new Set(path), edges, given: false };
    select(null);
    banner(`${path.length - 1} hops: ` + path.map((p) => esc(nodeInfo(p).label)).join(" → "), true);
  }

  function banner(html, clearable) {
    const el = $("banner");
    if (!html && state.pathFrom != null) html = `Click another node to trace the path from “${esc(nodeInfo(state.pathFrom).label)}”`;
    if (!html) { el.classList.remove("show"); return; }
    el.innerHTML = html + (clearable || state.pathFrom != null ? ' <button id="banner-x">Clear</button>' : "");
    el.classList.add("show");
    const x = $("banner-x");
    if (x) x.onclick = () => { state.pathFrom = null; if (state.path && !state.path.given) state.path = null; banner(); refresh(); };
  }

  // MARK: Search

  let results = [], active = 0;
  function search(text) {
    const q = text.trim().toLowerCase();
    const box = $("results");
    if (!q) { box.classList.remove("show"); results = []; return; }
    const scored = [];
    graph.forEachNode((node) => {
      const n = nodeInfo(node);
      const l = n.label.toLowerCase().replace(/^\./, "");
      let s = 0;
      if (l === q) s = 4; else if (l.startsWith(q)) s = 3; else if (l.includes(q)) s = 2;
      else if ((n.file || n.link || "").toLowerCase().includes(q)) s = 1;
      else if ((n.description || "").toLowerCase().includes(q)) s = 0.5;
      if (s) scored.push([node, s + Math.min(n.degree, 60) / 100]);
    });
    scored.sort((a, b) => b[1] - a[1]);
    results = scored.slice(0, 10).map((x) => x[0]);
    active = 0;
    box.innerHTML = results.length
      ? results.map((node, i) => { const n = nodeInfo(node); return `<div class="result${i === 0 ? " active" : ""}" data-node="${node}"><span>${esc(n.label)}</span><span class="file">${esc(where(n) || n.kind)}</span></div>`; }).join("")
      : `<div class="result"><span class="file">Nothing found</span></div>`;
    box.classList.add("show");
    box.querySelectorAll(".result[data-node]").forEach((el) => { el.onmousedown = (e) => { e.preventDefault(); pick(el.dataset.node); }; });
  }

  function pick(node) {
    $("results").classList.remove("show");
    $("search").blur();
    if (state.hidden.has(node)) { state.hiddenCommunities.delete(graph.getNodeAttribute(node, "community")); state.showExternal = true; legend(); }
    select(node, true);
  }

  // MARK: Legend and filters

  function legend() {
    const box = $("legend");
    let html = "";
    if (state.hasRoles) {
      html += "<h4>Highlighted</h4>";
      const roles = {};
      data.nodes.forEach((n) => { if (n.role) roles[n.role] = (roles[n.role] || 0) + 1; });
      const roleColor = { seed: css("--accent"), path: css("--accent"), changed: css("--changed"), affected: css("--affected") };
      for (const r of Object.keys(roles)) html += `<div class="row"><span class="dot" style="background:${roleColor[r]}"></span><span class="name">${esc(ROLE_LABEL[r] || r)}</span><span class="count">${roles[r]}</span></div>`;
    }
    html += `<h4>${drawn ? "Groups" : "Subsystems"} (${state.ranked.length})</h4><div class="links"><button id="c-all">All</button><button id="c-none">None</button></div>`;
    for (const c of state.ranked) {
      html += `<div class="row ${state.hiddenCommunities.has(c) ? "off" : ""}" data-c="${c}" title="Click to hide · ⌥-click to show only this"><span class="dot" style="background:${color[c]}"></span><span class="name">${esc(communityName[c] || "Community " + c)}</span><span class="count">${state.communityCounts[c]}</span></div>`;
    }
    const rel = {};
    let inferred = 0;
    graph.forEachEdge((e, a) => { rel[a.relation] = (rel[a.relation] || 0) + 1; if (a.confidence === "INFERRED") inferred++; });
    html += "<h4>Links</h4>";
    for (const r of Object.keys(rel).sort((a, b) => rel[b] - rel[a])) {
      html += `<div class="row ${state.hiddenRelations.has(r) ? "off" : ""}" data-r="${esc(r)}"><span class="name">${esc(r)}</span><span class="count">${rel[r]}</span></div>`;
    }
    if (inferred) html += `<div class="row ${state.showInferred ? "" : "off"}" id="f-inferred" title="Links graphify resolved rather than read directly"><span class="name">Inferred links</span><span class="count">${inferred}</span></div>`;
    const ext = drawn ? 0 : data.nodes.filter((n) => n.kind === "external").length;
    if (ext) html += `<div class="row ${state.showExternal ? "" : "off"}" id="f-external" title="Library and system types used by the code"><span class="name">Library types</span><span class="count">${ext}</span></div>`;
    box.innerHTML = html;
    box.querySelectorAll(".row[data-c]").forEach((el) => {
      el.onclick = (e) => {
        const c = el.dataset.c;
        if (e.altKey) { state.hiddenCommunities = new Set(state.ranked.filter((x) => x !== c)); }
        else if (state.hiddenCommunities.has(c)) state.hiddenCommunities.delete(c); else state.hiddenCommunities.add(c);
        apply();
      };
    });
    box.querySelectorAll(".row[data-r]").forEach((el) => {
      el.onclick = () => { const r = el.dataset.r; if (state.hiddenRelations.has(r)) state.hiddenRelations.delete(r); else state.hiddenRelations.add(r); apply(); };
    });
    $("c-all").onclick = () => { state.hiddenCommunities.clear(); apply(); };
    $("c-none").onclick = () => { state.hiddenCommunities = new Set(state.ranked); apply(); };
    if ($("f-inferred")) $("f-inferred").onclick = () => { state.showInferred = !state.showInferred; apply(); };
    if (!drawn && $("f-external")) $("f-external").onclick = () => { state.showExternal = !state.showExternal; apply(); };
  }

  function apply() { computeHidden(); refresh(); legend(); stats(); }

  function stats() {
    let nodes = 0, edges = 0;
    graph.forEachNode((n) => { if (!state.hidden.has(n)) nodes++; });
    graph.forEachEdge((e, a, s, t) => {
      if (!state.hidden.has(s) && !state.hidden.has(t) && !state.hiddenRelations.has(a.relation) && (state.showInferred || a.confidence !== "INFERRED")) edges++;
    });
    if (drawn) { $("stats").textContent = `${nodes} nodes · ${edges} links`; return; }
    const folder = data.root.split("/").pop();
    const extra = data.truncated ? ` · ${data.truncated} more not shown` : "";
    $("stats").textContent = `${nodes} nodes · ${edges} links${extra} · ${folder} · of ${data.graph.nodes} in the graph`;
  }

  // MARK: Wiring

  function wire() {
    $("b-legend").onclick = () => { document.body.classList.toggle("legend"); $("b-legend").classList.toggle("on", document.body.classList.contains("legend")); };
    $("b-legend").classList.toggle("on", document.body.classList.contains("legend"));
    const zoom = (f) => { const cam = renderer.getCamera(); cam.animate({ ratio: cam.getState().ratio * f }, { duration: 200 }); };
    $("b-in").onclick = () => zoom(1 / 1.5);
    $("b-out").onclick = () => zoom(1.5);
    $("b-fit").onclick = () => renderer.getCamera().animatedReset({ duration: 300 });
    $("b-layout").onclick = () => layout(true);
    if (drawn) $("b-whole").style.display = "none";
    else $("b-whole").onclick = () => post("overview", { root: data.root });
    if (full) $("b-expand").style.display = "none";
    else $("b-expand").onclick = () => post("expand");
    if (data.mode === "overview") $("b-whole").title = "Rebuild the whole graph now";
    const opens = drawn ? "its link" : "its file";
    $("hint").textContent = full ? `Double-click a node to open ${opens}` : `⌘-scroll to zoom · double-click opens ${opens}`;
    const input = $("search");
    input.oninput = () => search(input.value);
    input.onkeydown = (e) => {
      const items = $("results").querySelectorAll(".result[data-node]");
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault();
        if (!items.length) return;
        active = (active + (e.key === "ArrowDown" ? 1 : items.length - 1)) % items.length;
        items.forEach((el, i) => el.classList.toggle("active", i === active));
      } else if (e.key === "Enter" && results.length) pick(results[active]);
      else if (e.key === "Escape") { input.value = ""; search(""); input.blur(); }
    };
    input.onblur = () => setTimeout(() => $("results").classList.remove("show"), 120);
    document.addEventListener("keydown", (e) => {
      if (e.target === input) return;
      if (e.key === "/" || (e.key === "f" && (e.metaKey || e.ctrlKey))) { e.preventDefault(); input.focus(); input.select(); }
      else if (e.key === "Escape") { state.pathFrom = null; banner(); select(null); }
    });
    matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
      renderer.setSetting("labelColor", { color: css("--text") });
      graph.forEachNode((node) => graph.setNodeAttribute(node, "color", nodeColor(nodeInfo(node))));
      graph.forEachEdge((e, a) => graph.setEdgeAttribute(e, "color", a.onPath ? css("--edge-hi") : css("--edge")));
      legend();
    });
  }

  // Called by the app.
  window.claudistGraph = {
    focus(name) {
      const q = String(name).toLowerCase();
      const node = graph.findNode((n, a) => a.label.toLowerCase() === q) || graph.findNode((n, a) => a.label.toLowerCase().includes(q));
      if (node != null) pick(node);
    },
  };

  (async () => {
    try {
      await load();
      build();
      computeHidden();
      createRenderer();
      wire();
      legend();
      stats();
      if (state.path && state.path.given) banner(`${state.path.nodes.size - 1} hops: ` + data.query, false);
      layout(false);
      post("ready");
    } catch (e) {
      $("loading").classList.add("hide");
      $("error").style.display = "flex";
      $("error").textContent = e.message || String(e);
      post("error", { text: String(e && e.stack || e) });
    }
  })();
})();
