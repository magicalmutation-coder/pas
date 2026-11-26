"""Pensive - the crew's memory as a constellation you can turn.

A memory here is not a list row. It is a point in space with lines to the things
that give it meaning: the bot whose run produced it, the project it belongs to,
its kind, its tags - and the retrieval index that decides whether it can ever be
found again. Turning the graph is how you see that a bot has learned one thing
twice, or that a whole project never made it into the index.

Reads, never writes:

  jobs/memories.db      memories (kind, project, text, tags, job)
  jobs/runs.db          runs, so a memory's job can name its bot
  crew.json             one avatar node per bot
  jobs/rag-index.json   folders and files, as the outer reef

Drag rotates, wheel zooms, click a node to read it, the legend hides a kind.
Stdlib only: runs on the shipped vendor\\python with no install step.
"""

import json
import math
import os
import sqlite3
from datetime import datetime, timezone

from paserve import run

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
JOBS = os.path.join(ROOT, "jobs")


def _connect(name):
    path = os.path.join(JOBS, name)
    if not os.path.exists(path):
        return None
    try:
        return sqlite3.connect("file:%s?mode=ro" % path.replace("\\", "/"), uri=True)
    except Exception:
        return None


def _rows(conn, sql, args=()):
    if not conn:
        return []
    try:
        cur = conn.execute(sql, args)
        cols = [d[0] for d in cur.description]
        return [dict(zip(cols, r)) for r in cur.fetchall()]
    except Exception:
        return []


def _crew():
    path = os.path.join(ROOT, "crew.json")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        if isinstance(data, dict):
            data = data.get("crew") or []
        return [m for m in data if isinstance(m, dict) and m.get("slug")]
    except Exception:
        return []


def _rag():
    """Files and chunk counts, from whatever shape the index has.

    The index is `{"chunks": [{path, start, end, text, tokens}, ...], ...}` - one
    entry per chunk, not one per file. Reading it as a dict of files (which is
    what this did first) found nothing and left the reef empty while the feed
    said "not built yet", which is a lie the page told confidently.
    """
    path = os.path.join(JOBS, "rag-index.json")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        return {"files": [], "chunks": 0, "built": ""}

    per = {}
    blobs = data.get("chunks") if isinstance(data, dict) else data
    if isinstance(blobs, dict):
        # An older/other shape: {path: {chunks: n}}.
        for f, info in blobs.items():
            n = 1
            if isinstance(info, dict):
                n = int(info.get("chunks") or len(info.get("chunkList") or []) or 1)
            per[str(f)] = per.get(str(f), 0) + n
    elif isinstance(blobs, list):
        for one in blobs:
            p = str(one.get("path") or "") if isinstance(one, dict) else str(one)
            if not p:
                continue
            per[p] = per.get(p, 0) + 1

    files = [{"path": p, "chunks": n} for p, n in per.items()]
    files.sort(key=lambda x: -x["chunks"])
    total = sum(f["chunks"] for f in files)
    built = ""
    if isinstance(data, dict):
        built = str(data.get("built") or data.get("at") or "")
    return {"files": files[:400], "chunks": total, "built": built}


def graph():
    """Nodes and edges. Built here, laid out in the browser."""
    nodes = []
    edges = []
    seen = set()

    def add(node):
        if node["id"] in seen:
            return node["id"]
        seen.add(node["id"])
        nodes.append(node)
        return node["id"]

    def link(a, b, kind="member"):
        if a and b:
            edges.append({"s": a, "t": b, "k": kind})

    crew = _crew()
    bot_key = {}
    for m in crew:
        nid = add({"id": "bot:" + m["slug"], "t": "bot", "label": m.get("name") or m["slug"],
                   "sub": m.get("role") or "", "avatar": m.get("avatar") or "wizard",
                   "text": (m.get("blurb") or "")})
        bot_key[("slug", str(m["slug"]).lower())] = nid
        bot_key[("name", str(m.get("name") or "").lower())] = nid

    mem = _connect("memories.db")
    run_db = _connect("runs.db")
    memories = _rows(mem, "select id, at, project, kind, text, tags, job from memories order by id desc limit 500")
    if mem:
        mem.close()
    runs = _rows(run_db, "select id, objective, status from runs order by id desc limit 300")
    if run_db:
        run_db.close()

    # A run names its bot in the transcript, not in runs.db, so the crew link is
    # made from the memory's own job text when it carries one.
    job_text = {}
    for r in runs:
        job_text[str(r.get("id"))] = str(r.get("objective") or "")

    kinds = {}
    projects = {}
    tags = {}

    for m in memories:
        mid = add({"id": "mem:" + str(m.get("id")), "t": "mem",
                   "label": (m.get("text") or "")[:120],
                   "sub": str(m.get("kind") or "note"),
                   "kind": str(m.get("kind") or "note"),
                   "at": str(m.get("at") or ""),
                   "text": str(m.get("text") or ""),
                   "tags": str(m.get("tags") or ""),
                   "project": str(m.get("project") or "")})
        k = str(m.get("kind") or "note").strip() or "note"
        if k not in kinds:
            kinds[k] = add({"id": "kind:" + k, "t": "kind", "label": k, "sub": "kind", "text": ""})
        link(mid, kinds[k], "kind")

        p = str(m.get("project") or "").strip()
        if p:
            if p not in projects:
                projects[p] = add({"id": "proj:" + p, "t": "proj", "label": p, "sub": "project", "text": ""})
            link(mid, projects[p], "proj")

        raw_tags = str(m.get("tags") or "")
        for tag in [x.strip() for x in raw_tags.replace(";", ",").split(",") if x.strip()][:6]:
            if tag not in tags:
                tags[tag] = add({"id": "tag:" + tag, "t": "tag", "label": tag, "sub": "tag", "text": ""})
            link(mid, tags[tag], "tag")

        # The bot, from the memory text ("crew=weather") or the job's objective.
        lowered = (str(m.get("text") or "") + " " + job_text.get(str(m.get("job")), "")).lower()
        for (how, key), nid in list(bot_key.items()):
            if how == "slug" and len(key) > 2 and key in lowered:
                link(mid, nid, "bot")
                break

    # The reef: one folder node per top-level folder, one file node each.
    rag = _rag()
    folders = {}
    for f in rag["files"]:
        p = f["path"].replace("\\", "/")
        parts = [x for x in p.split("/") if x]
        folder = parts[0] if len(parts) > 1 else "(root)"
        if folder not in folders:
            folders[folder] = add({"id": "dir:" + folder, "t": "dir", "label": folder,
                                   "sub": "indexed folder", "text": ""})
        fid = add({"id": "file:" + p, "t": "file", "label": os.path.basename(p),
                   "sub": str(f["chunks"]) + " chunks", "text": p, "chunks": f["chunks"]})
        link(fid, folders[folder], "file")

    kinds_out = {}
    for n in nodes:
        if n["t"] == "mem":
            kinds_out[n.get("kind", "note")] = kinds_out.get(n.get("kind", "note"), 0) + 1

    return {
        "at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "nodes": nodes,
        "edges": edges,
        "counts": {
            "memories": len(memories),
            "crew": len(crew),
            "runs": len(runs),
            "indexedFiles": len(rag["files"]),
            "chunks": rag["chunks"],
        },
        "kinds": kinds_out,
        "ragBuilt": rag["built"],
    }


PAGE = r"""<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Pensive</title>
<style>
html,body{height:100%;margin:0}
body{background:radial-gradient(90% 80% at 50% 8%,#1a1140 0%,#0a0a1e 45%,#04040c 100%);
  color:#dfe6ff;font:14px/1.5 ui-sans-serif,system-ui,"Segoe UI",Roboto,sans-serif;overflow:hidden;
  -webkit-user-select:none;user-select:none}
#wrap{display:grid;grid-template-columns:1fr 312px;height:100%}
@media(max-width:900px){#wrap{grid-template-columns:1fr}#side{display:none}}
#stage{position:relative;overflow:hidden}
canvas{display:block;width:100%;height:100%;cursor:grab}
canvas.dragging{cursor:grabbing}
#hud{position:absolute;left:20px;top:14px;pointer-events:none}
#hud h1{margin:0;font-size:17px;letter-spacing:.2em;text-transform:uppercase;color:#cfd6ff;
  text-shadow:0 0 24px #7a6bff88;font-weight:600}
#hud .sub{color:#8a8cc0;font-size:12px;margin-top:2px}
#tools{position:absolute;right:16px;top:14px;display:flex;gap:6px}
#tools button{background:#161636cc;border:1px solid #2e2e60;color:#b9c0ee;border-radius:8px;
  padding:5px 9px;font-size:12px;cursor:pointer}
#tools button:hover{border-color:#4a4a90;color:#e6e9ff}
#search{position:absolute;left:20px;bottom:18px;background:#11112acc;border:1px solid #2e2e60;
  border-radius:9px;padding:6px 10px;color:#dfe6ff;font-size:12.5px;width:230px;outline:none}
#search::placeholder{color:#6a6c96}
#info{position:absolute;right:16px;bottom:16px;width:300px;max-height:46%;overflow:auto;
  background:#12122bdd;border:1px solid #2e2e60;border-radius:12px;padding:12px 14px;display:none;
  box-shadow:0 16px 44px #000a;font-size:12.5px}
#info b{color:#eef0ff}
#info .tag{display:inline-block;padding:1px 7px;border-radius:99px;background:#23234a;
  color:#a9b0e6;font-size:11px;margin:2px 4px 2px 0}
#info .body{margin-top:8px;color:#c3c9ee;white-space:pre-wrap;word-break:break-word}
#info .close{float:right;cursor:pointer;color:#7a7db0;font-size:16px;line-height:1}
#side{background:linear-gradient(180deg,#12122c,#080814);border-left:1px solid #24244a;
  padding:15px 15px 24px;overflow:auto}
#side h2{font-size:11px;letter-spacing:.16em;text-transform:uppercase;color:#7c80b8;
  margin:17px 0 8px;font-weight:600}
#side h2:first-child{margin-top:2px}
.kv{display:flex;justify-content:space-between;gap:8px;padding:3px 0;font-size:12.5px}
.kv b{font-weight:500;color:#e9ecff}
.kv span{color:#7c80b8}
.lg{display:flex;align-items:center;gap:8px;padding:3px 0;cursor:pointer;font-size:12.5px}
.lg i{width:10px;height:10px;border-radius:99px;flex:0 0 auto}
.lg.off{opacity:.35}
.lg em{margin-left:auto;color:#7c80b8;font-style:normal}
#err{position:absolute;left:20px;top:56px;color:#ffb4b4;font-size:12px}
</style></head>
<body>
<div id="wrap">
  <div id="stage">
    <canvas id="c"></canvas>
    <div id="hud"><h1>Pensive</h1><div class="sub" id="sub">drawing the memories...</div></div>
    <div id="tools">
      <button id="btnSpin">spin</button>
      <button id="btnFit">fit</button>
      <button id="btnLive">live</button>
    </div>
    <input id="search" placeholder="find a memory...">
    <div id="info"></div>
    <div id="err"></div>
  </div>
  <aside id="side">
    <h2>The basin</h2><div id="counts"></div>
    <h2>Kinds &middot; click to hide</h2><div id="legend"></div>
    <h2>What the lines mean</h2>
    <div class="kv"><span>memory &rarr; bot</span><b>whose run</b></div>
    <div class="kv"><span>memory &rarr; project</span><b>what for</b></div>
    <div class="kv"><span>memory &rarr; kind</span><b>what sort</b></div>
    <div class="kv"><span>memory &rarr; tag</span><b>how it is found</b></div>
    <div class="kv"><span>file &rarr; folder</span><b>the reef</b></div>
    <h2>Reef &middot; retrieval index</h2><div id="rag"></div>
  </aside>
</div>
<script>
const BASE = location.pathname.replace(/\/+$/, "");
const c = document.getElementById("c"), ctx = c.getContext("2d");
let W = 0, H = 0, dpr = 1, DATA = null;
let rotX = -0.28, rotY = 0.5, zoom = 1, spin = true, live = true;
let nodes = [], edges = [], images = {}, hidden = {}, hover = null, picked = null;
let drag = null, searchText = "", t = 0;
// Screen offsets the operator gave a node by dragging it. Kept by node id so the
// 30-second live reload (which rebuilds the nodes) does not throw the arrangement away.
let offsets = {};

const COLOURS = {bot:"#8fb4ff", mem:"#6fe0c8", kind:"#ffd479", proj:"#d59cff", tag:"#ff9fb2",
  dir:"#7fe3ff", file:"#9aa6d8"};
const RADIUS = {bot: 24, kind: 16, proj: 13, tag: 9, dir: 15, file: 7, mem: 5};

function resize(){
  dpr = Math.min(2, window.devicePixelRatio || 1);
  W = c.clientWidth; H = c.clientHeight;
  c.width = Math.floor(W * dpr); c.height = Math.floor(H * dpr);
  ctx.setTransform(dpr,0,0,dpr,0,0);
}
function avatarUrl(id){
  const a = String(id || "wizard");
  return a === "wizard" ? "/assets/wizard-avatar.svg" : "/assets/" + encodeURIComponent(a) + ".svg";
}
function loadImage(id){
  if (images[id] !== undefined) return images[id];
  images[id] = null;
  const img = new Image();
  img.onload = () => { images[id] = img; };
  img.onerror = () => { images[id] = false; };
  img.src = avatarUrl(id);
  return null;
}

async function load(){
  try{
    const r = await fetch(BASE + "/api/graph", {cache:"no-store"});
    if (!r.ok) throw new Error("HTTP " + r.status);
    DATA = await r.json();
  }catch(e){
    document.getElementById("err").textContent = "could not read the memories: " + e.message;
    return;
  }
  layout();
  for (const n of nodes) if (n.t === "bot") loadImage(n.avatar);
  paintPanel();
}
function layout(){
  nodes = (DATA.nodes || []).map(n => {
    const o = offsets[n.id] || [0, 0];
    return {...n, x:0, y:0, z:0, vx:0, vy:0, vz:0, ox:o[0], oy:o[1]};
  });
  edges = (DATA.edges || []).map(e => ({...e}));
  const byId = {}; nodes.forEach(n => byId[n.id] = n);

  // Hubs on a sphere, leaves around their own hub. Deterministic so the shape
  // is recognisable between visits: a graph that rearranges itself every reload
  // teaches nothing.
  const hubs = nodes.filter(n => n.t !== "mem" && n.t !== "file");
  hubs.forEach((n, i) => {
    const phi = Math.acos(1 - 2 * (i + 0.5) / Math.max(1, hubs.length));
    const theta = Math.PI * (1 + Math.sqrt(5)) * i;
    const R = 320;
    n.x = R * Math.cos(theta) * Math.sin(phi);
    n.y = R * Math.cos(phi) * 0.8;
    n.z = R * Math.sin(theta) * Math.sin(phi);
  });
  // A sphere is not evenly spaced once it is projected: 36 hubs still stack two on
  // one screen spot. Relax them apart in 3D (cheap at this size) before the leaves
  // are hung on them, so "clumped together" is not just the near/far flattening.
  for (let pass = 0; pass < 60; pass++) {
    for (let i = 0; i < hubs.length; i++) {
      for (let j = i + 1; j < hubs.length; j++) {
        const a = hubs[i], b = hubs[j];
        let dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z;
        const d2 = dx * dx + dy * dy + dz * dz;
        const min = 112;
        if (d2 > 0.0001 && d2 < min * min) {
          const d = Math.sqrt(d2), push = (min - d) / d * 0.5;
          dx *= push; dy *= push; dz *= push;
          a.x -= dx; a.y -= dy; a.z -= dz;
          b.x += dx; b.y += dy; b.z += dz;
        }
      }
    }
  }
  // Screen-space pass for the opening view. Two hubs can be metres apart in 3D and
  // still land on the same pixel once projected - that is what "clumped together"
  // looks like even after the 3D relaxation. Push them apart in the plane they are
  // seen in; rotating still reveals the depth.
  for (let pass = 0; pass < 40; pass++) {
    let movedAny = false;
    for (let i = 0; i < hubs.length; i++) {
      for (let j = i + 1; j < hubs.length; j++) {
        const a = hubs[i], b = hubs[j];
        const pa = project(a), pb = project(b);
        let dx = pb.x - pa.x, dy = pb.y - pa.y;
        const d = Math.hypot(dx, dy), min = 96;
        if (d > 0.001 && d < min) {
          const kAvg = Math.max(0.25, (pa.k + pb.k) / 2);
          const push = (min - d) / d * 0.45 / kAvg;
          dx *= push; dy *= push;
          a.x -= dx; a.y -= dy; b.x += dx; b.y += dy;
          movedAny = true;
        }
      }
    }
    if (!movedAny) break;
  }
  const leaves = nodes.filter(n => n.t === "mem" || n.t === "file");
  leaves.forEach((n, i) => {
    const mine = edges.filter(e => e.s === n.id || e.t === n.id)
      .map(e => byId[e.s === n.id ? e.t : e.s]).filter(h => h && h.t !== "mem" && h.t !== "file");
    const anchor = mine[0] || hubs[i % Math.max(1, hubs.length)];
    const spread = n.t === "file" ? 58 : 95;
    // Deterministic per id, not Math.random: a reload must not rearrange the reef.
    let h = 0; for (let k = 0; k < n.id.length; k++) h = (h * 31 + n.id.charCodeAt(k)) >>> 0;
    const a = (h % 1024) / 1024 * Math.PI * 2, b = ((h >>> 10) % 1024) / 1024 * Math.PI;
    n.x = (anchor ? anchor.x : 0) + Math.cos(a) * Math.sin(b) * spread;
    n.y = (anchor ? anchor.y : 0) + Math.cos(b) * spread * 0.8;
    n.z = (anchor ? anchor.z : 0) + Math.sin(a) * Math.sin(b) * spread;
  });
  // Fit the cloud to the canvas, so no hub projects off the edge (a narrow pane was
  // clipping one after the spacing change). 0.42 leaves room for the bot heads.
  let rmax = 1;
  for (const n of nodes) rmax = Math.max(rmax, Math.hypot(n.x, n.y, n.z));
  const span = Math.max(240, Math.min(W || 800, H || 800));
  const fit = (span * 0.42) / rmax;
  for (const n of nodes) { n.x *= fit; n.y *= fit; n.z *= fit; }
}
function paintPanel(){
  const k = DATA.counts;
  document.getElementById("counts").innerHTML =
    kv("memories", k.memories) + kv("crew", k.crew) + kv("runs", k.runs) +
    kv("indexed files", k.indexedFiles) + kv("chunks", k.chunks);
  document.getElementById("rag").innerHTML =
    (DATA.ragBuilt ? kv("built", String(DATA.ragBuilt).replace("T"," ").slice(0,16)) : "") +
    (k.indexedFiles ? "" : '<div class="kv"><span>not built yet - run rag_index</span></div>');
  const total = Math.max(1, Object.values(DATA.kinds || {}).reduce((a,b) => a+b, 0));
  document.getElementById("legend").innerHTML = Object.entries(DATA.kinds || {})
    .sort((a,b) => b[1]-a[1]).map(([name, n]) =>
      '<div class="lg' + (hidden[name] ? ' off' : '') + '" data-kind="' + esc(name) + '">' +
      '<i style="background:' + colourFor('kind', name) + '"></i>' + esc(name) +
      '<em>' + n + '</em></div>').join("") || '<div class="kv"><span>no memories yet</span></div>';
  const sub = DATA.counts.memories + " memories  ·  " + DATA.counts.crew + " bots  ·  " +
    DATA.counts.indexedFiles + " indexed files";
  document.getElementById("sub").textContent = sub;
}
function colourFor(type, name){
  if (type !== "kind") return COLOURS[type] || "#9aa6d8";
  let h = 0; const s = String(name || "");
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) % 360;
  return "hsl(" + h + ",72%,66%)";
}
function kv(k,v){ return '<div class="kv"><span>'+esc(k)+'</span><b>'+esc(String(v))+'</b></div>'; }
function esc(s){ return String(s).replace(/[&<>"]/g, m => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[m])); }

function project(p){
  const cy = Math.cos(rotY), sy = Math.sin(rotY);
  const cx = Math.cos(rotX), sx = Math.sin(rotX);
  let x = p.x * cy - p.z * sy;
  let z = p.x * sy + p.z * cy;
  let y = p.y * cx - z * sx;
  z = p.y * sx + z * cx;
  const d = 700;
  const k = d / Math.max(120, d + z) * zoom;
  return {x: W / 2 + x * k + (p.ox || 0), y: H / 2 + y * k + (p.oy || 0), z: z, k: k};
}

function visible(n){
  if (n.t === "mem" && hidden[n.kind]) return false;
  if (n.t === "kind" && hidden[n.label]) return false;
  return true;
}

function paint(){
  ctx.clearRect(0, 0, W, H);
  if (spin) rotY += 0.0022;
  const pos = {};
  for (const n of nodes) pos[n.id] = project(n);

  // edges, dim and depth-sorted so the near ones draw on top
  const drawable = edges.filter(e => {
    const a = nodes.find(x => x.id === e.s), b = nodes.find(x => x.id === e.t);
    return a && b && visible(a) && visible(b);
  });
  drawable.sort((p, q) => (pos[p.s].z + pos[p.t].z) - (pos[q.s].z + pos[q.t].z));
  for (const e of drawable){
    const a = pos[e.s], b = pos[e.t];
    const depth = (a.z + b.z) / 2;
    const alpha = Math.max(0.04, Math.min(0.5, 0.42 - depth / 900));
    ctx.strokeStyle = "rgba(140,150,235," + alpha + ")";
    ctx.lineWidth = e.k === "bot" ? 1.3 : (e.k === "kind" ? 0.9 : 0.6);
    ctx.beginPath(); ctx.moveTo(a.x, a.y); ctx.lineTo(b.x, b.y); ctx.stroke();
  }

  const order = nodes.filter(visible).sort((p, q) => pos[p.id].z - pos[q.id].z);
  for (const n of order){
    const p = pos[n.id];
    const depth = Math.max(0.25, Math.min(1.35, 1.25 - p.z / 900));
    const r = (RADIUS[n.t] || 6) * p.k * 1.6;
    let botSize = 0;
    const isHover = hover === n, isPicked = picked === n;
    const dimmed = searchText && !(n.label || "").toLowerCase().includes(searchText) &&
      !(n.text || "").toLowerCase().includes(searchText);

    ctx.globalAlpha = dimmed ? 0.16 : depth;

    if (n.t === "bot"){
      const img = images[n.avatar] || loadImage(n.avatar);
      // A bot head is a landmark, not a portrait: at the old size (r*2.2, drawn at
      // 1.56x) it swallowed the graph around it. Smaller head, same hit area.
      const size = Math.max(16, r * 1.7);
      botSize = size;
      ctx.globalAlpha = 0.22 * depth;
      const g = ctx.createRadialGradient(p.x, p.y, 2, p.x, p.y, size);
      g.addColorStop(0, COLOURS.bot); g.addColorStop(1, "rgba(120,140,255,0)");
      ctx.fillStyle = g; ctx.beginPath(); ctx.arc(p.x, p.y, size, 0, Math.PI * 2); ctx.fill();
      ctx.globalAlpha = dimmed ? 0.16 : depth;
      if (img) ctx.drawImage(img, p.x - size * 0.65, p.y - size * 0.65, size * 1.3, size * 1.3);
      else { ctx.strokeStyle = COLOURS.bot; ctx.lineWidth = 2; ctx.beginPath(); ctx.arc(p.x, p.y, size * 0.55, 0, Math.PI * 2); ctx.stroke(); }
    } else if (n.t === "file" || n.t === "mem"){
      const col = n.t === "mem" ? colourFor("kind", n.kind) : COLOURS.file;
      ctx.fillStyle = col;
      ctx.beginPath(); ctx.arc(p.x, p.y, Math.max(1.6, r), 0, Math.PI * 2); ctx.fill();
      if (n.t === "mem" && r > 2.2){
        ctx.globalAlpha = (dimmed ? 0.1 : depth) * 0.35;
        ctx.beginPath(); ctx.arc(p.x, p.y, r * 2.6, 0, Math.PI * 2); ctx.fill();
        ctx.globalAlpha = dimmed ? 0.16 : depth;
      }
    } else {
      const col = n.t === "kind" ? colourFor("kind", n.label) : (COLOURS[n.t] || "#9aa6d8");
      ctx.beginPath(); ctx.arc(p.x, p.y, Math.max(2.5, r), 0, Math.PI * 2);
      ctx.fillStyle = col; ctx.globalAlpha = (dimmed ? 0.16 : depth) * 0.85; ctx.fill();
      ctx.globalAlpha = dimmed ? 0.16 : Math.min(1, depth + 0.15);
      ctx.strokeStyle = col; ctx.lineWidth = 1.2;
      ctx.beginPath(); ctx.arc(p.x, p.y, Math.max(2.5, r) + 2.5, 0, Math.PI * 2); ctx.stroke();
      ctx.globalAlpha = dimmed ? 0.16 : depth;
    }

    if (isHover || isPicked){
      ctx.strokeStyle = "#eef0ff"; ctx.lineWidth = 1.6;
      ctx.beginPath(); ctx.arc(p.x, p.y, Math.max(6, n.t === "bot" ? botSize * 0.95 : r * 1.9), 0, Math.PI * 2); ctx.stroke();
    }

    const big = n.t === "bot" || n.t === "kind" || n.t === "proj" || n.t === "dir";
    if (big && !dimmed && depth > 0.5){
      ctx.font = (n.t === "bot" ? "600 12px" : "11px") + " ui-sans-serif,system-ui";
      ctx.textAlign = "center";
      ctx.fillStyle = "rgba(226,232,255," + Math.min(0.95, depth) + ")";
      ctx.fillText(n.label, p.x, p.y + (n.t === "bot" ? Math.max(26, botSize * 0.95) : Math.max(4, r) + 14));
    }
  }
  ctx.globalAlpha = 1;
  t++;
  requestAnimationFrame(paint);
}

function pickNode(x, y){
  let best = null, bestD = 1e9;
  for (const n of nodes){
    if (!visible(n)) continue;
    const p = project(n);
    const r = Math.max(10, (RADIUS[n.t] || 6) * p.k * 1.9);
    const d = (x - p.x) ** 2 + (y - p.y) ** 2;
    if (d < r * r && d < bestD) { bestD = d; best = n; }
  }
  return best;
}

c.addEventListener("pointerdown", ev => {
  const r = c.getBoundingClientRect();
  // Over a node, dragging moves that node (a screen-space offset, kept for the
  // session); over empty space it rotates the constellation, as before.
  const hit = pickNode(ev.clientX - r.left, ev.clientY - r.top);
  drag = {x: ev.clientX, y: ev.clientY, moved: 0, node: hit || null};
  if (hit) spin = false;
  c.classList.add("dragging");
  c.setPointerCapture(ev.pointerId);
});
c.addEventListener("pointermove", ev => {
  const r = c.getBoundingClientRect();
  const x = ev.clientX - r.left, y = ev.clientY - r.top;
  if (drag){
    const dx = ev.clientX - drag.x, dy = ev.clientY - drag.y;
    drag.moved += Math.abs(dx) + Math.abs(dy);
    drag.x = ev.clientX; drag.y = ev.clientY;
    if (drag.node){
      drag.node.ox = (drag.node.ox || 0) + dx;
      drag.node.oy = (drag.node.oy || 0) + dy;
      offsets[drag.node.id] = [drag.node.ox, drag.node.oy];
      spin = false;
      return;
    }
    rotY += dx * 0.006; rotX += dy * 0.006;
    rotX = Math.max(-1.45, Math.min(1.45, rotX));
    spin = false;
    return;
  }
  hover = pickNode(x, y);
  c.style.cursor = hover ? "pointer" : "grab";
});
c.addEventListener("pointerup", ev => {
  const wasDrag = drag && drag.moved > 6;
  c.classList.remove("dragging");
  drag = null;
  if (wasDrag) return;
  const r = c.getBoundingClientRect();
  const n = pickNode(ev.clientX - r.left, ev.clientY - r.top);
  picked = n ? (picked === n ? null : n) : null;
  showInfo(picked);
});
c.addEventListener("dblclick", ev => {
  // Let go of a node (or of every node, on empty space) without reloading.
  const r = c.getBoundingClientRect();
  const n = pickNode(ev.clientX - r.left, ev.clientY - r.top);
  if (n) { n.ox = 0; n.oy = 0; delete offsets[n.id]; }
  else { for (const m of nodes) { m.ox = 0; m.oy = 0; } offsets = {}; }
});
c.addEventListener("wheel", ev => {
  ev.preventDefault();
  zoom = Math.max(0.35, Math.min(4.2, zoom * (ev.deltaY > 0 ? 0.92 : 1.08)));
}, {passive: false});

function showInfo(n){
  const box = document.getElementById("info");
  if (!n){ box.style.display = "none"; return; }
  box.style.display = "block";
  let h = '<span class="close" id="infoClose">&times;</span>';
  h += '<b>' + esc(n.label || n.id) + '</b>';
  h += '<div style="color:#8a8ec4;font-size:11.5px;margin-top:2px">' + esc(n.t) +
       (n.sub ? ' · ' + esc(n.sub) : '') + (n.at ? ' · ' + esc(String(n.at).replace("T", " ").slice(0, 16)) : '') + '</div>';
  if (n.tags) h += '<div style="margin-top:7px">' + String(n.tags).split(",").filter(Boolean)
    .map(x => '<span class="tag">' + esc(x.trim()) + '</span>').join("") + '</div>';
  if (n.t === "mem" && n.project) h += '<div style="margin-top:6px;color:#9aa0d0">project: ' + esc(n.project) + '</div>';
  if (n.text) h += '<div class="body">' + esc(n.text) + '</div>';
  box.innerHTML = h;
  const close = document.getElementById("infoClose");
  if (close) close.onclick = () => { picked = null; box.style.display = "none"; };
}

document.getElementById("btnSpin").onclick = () => { spin = !spin; };
document.getElementById("btnFit").onclick = () => { zoom = 1; rotX = -0.28; rotY = 0.5; };
document.getElementById("btnLive").onclick = () => {
  live = !live;
  document.getElementById("btnLive").style.color = live ? "" : "#6a6c96";
};
document.getElementById("search").addEventListener("input", ev => {
  searchText = ev.target.value.trim().toLowerCase();
});
document.getElementById("legend").addEventListener("click", ev => {
  const row = ev.target.closest("[data-kind]");
  if (!row) return;
  const k = row.dataset.kind;
  hidden[k] = !hidden[k];
  paintPanel();
});
window.addEventListener("resize", resize);
resize(); load(); paint();
setInterval(() => { if (live) load(); }, 30000);
</script>
</body></html>
"""


def application(environ, start_response):
    path = environ.get("PATH_INFO", "/") or "/"
    if path.rstrip("/") == "/api/health":
        body = json.dumps({"ok": True, "app": "pensive"}).encode()
        start_response("200 OK", [("Content-Type", "application/json"),
                                  ("Content-Length", str(len(body)))])
        return [body]
    if path.rstrip("/") == "/api/graph":
        try:
            body = json.dumps(graph(), default=str).encode()
            code = "200 OK"
        except Exception as exc:
            body = json.dumps({"ok": False, "error": str(exc)}).encode()
            code = "500 Internal Server Error"
        start_response(code, [("Content-Type", "application/json"),
                              ("Content-Length", str(len(body)))])
        return [body]
    if path in ("/", "/index.html"):
        body = PAGE.encode("utf-8")
        start_response("200 OK", [("Content-Type", "text/html; charset=utf-8"),
                                  ("Content-Length", str(len(body)))])
        return [body]
    # The crew avatars live in the dashboard's assets folder, not in this app. The page
    # asks for /assets/<id>.svg; without this route every bot fell back to a plain
    # circle (which is what "the avatars are too big" was actually looking at, and why
    # making the circle smaller made them vanish). Only a bare .svg name is served.
    if path.startswith("/assets/"):
        name = os.path.basename(path)
        full = os.path.join(ROOT, "assets", name)
        if name.lower().endswith(".svg") and os.path.isfile(full):
            with open(full, "rb") as fh:
                body = fh.read()
            start_response("200 OK", [("Content-Type", "image/svg+xml"),
                                      ("Content-Length", str(len(body))),
                                      ("Cache-Control", "max-age=3600")])
            return [body]
    body = b"not found"
    start_response("404 Not Found", [("Content-Type", "text/plain"),
                                     ("Content-Length", str(len(body)))])
    return [body]


if __name__ == "__main__":
    run(application)
