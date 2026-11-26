"""Aquarium - the crew, swimming.

Each bot is drawn as its own avatar (the same SVG the dashboard and the crew bar
use) and says what it has actually been doing: a learned lesson, its own blurb,
or a line from its last team message. They wander, and when two drift close they
stop and talk to each other.

Reads, never writes:

  crew.json             one swimmer per bot, with its avatar and lessons
  jobs/memories.db      the bubbles
  jobs/runs.db          recent runs and team messages
  jobs/rag-index.json   the reef

Stdlib only: it runs on the shipped vendor\\python with no install step.
"""

import json
import os
import re
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


def _clean(text, limit=150):
    s = re.sub(r"\s+", " ", str(text or "")).strip()
    s = s.replace("**", "").replace("`", "")
    if len(s) > limit:
        s = s[: limit - 1].rstrip() + "\u2026"
    return s


def _crew(msgs):
    """Crew rows, each with a few things it might say."""
    by_name = {}
    for m in msgs:
        n = str(m.get("name") or "").strip().lower()
        if not n:
            continue
        by_name.setdefault(n, []).append(_clean(m.get("text"), 130))

    path = os.path.join(ROOT, "crew.json")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        return []
    if isinstance(data, dict):
        data = data.get("crew") or []

    out = []
    for m in data:
        if not isinstance(m, dict) or not m.get("slug"):
            continue
        if m.get("enabled") is False:
            continue
        name = m.get("name") or m["slug"]
        lessons = [_clean(x, 130) for x in str(m.get("learned") or "").splitlines() if x.strip()]
        said = by_name.get(str(name).strip().lower(), [])[:3]
        # Newest first: what it just did is more interesting than a lesson from
        # a week ago, and the last thing it said is the most human of all.
        lines = said + lessons + [_clean(m.get("blurb"), 150)]
        lines = [x for x in lines if x]
        # A quiet bot should still have something to be seen doing: a bot with
        # one line repeats it all evening, which reads as a bug rather than a
        # character. These are deliberately about the work, not filler chatter.
        if len(lines) < 3:
            role = str(m.get("role") or "").lower()
            ambient = ["reading the run log", "checking what changed", "waiting for a job"]
            if "mail" in role or "message" in role:
                ambient = ["nothing unread that matters", "skimming the inbox", "leaving that one for later"]
            elif "cod" in role:
                ambient = ["red before green", "one small diff at a time", "reading it before changing it"]
            elif "secur" in role or "recon" in role:
                ambient = ["nothing new on the wire", "watching the ports", "same hosts as last time"]
            lines = lines + ambient[:3 - len(lines)]
        out.append({
            "slug": m["slug"],
            "name": name,
            "role": m.get("role") or "",
            "avatar": m.get("avatar") or "",
            "blurb": _clean(m.get("blurb"), 140),
            "learned": len(lessons),
            "lines": lines[:6],
        })
    return out


def _rag():
    """The reef: how much is indexed, and under which folders.

    The index stores one entry per chunk (`{"chunks": [{path, ...}]}`), so the
    file count is the number of distinct paths - not the number of entries. This
    read the old `files` dict first and reported zero for a built index, which is
    the wrong way round: the page said "not built yet" while the index existed.
    """
    path = os.path.join(JOBS, "rag-index.json")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        return {"chunks": 0, "files": 0, "folders": [], "built": ""}

    per = {}
    blobs = data.get("chunks") if isinstance(data, dict) else data
    if isinstance(blobs, dict):
        for f, info in blobs.items():
            n = 1
            if isinstance(info, dict):
                n = int(info.get("chunks") or len(info.get("chunkList") or []) or 1)
            per[str(f)] = per.get(str(f), 0) + n
    elif isinstance(blobs, list):
        for one in blobs:
            p = str(one.get("path") or "") if isinstance(one, dict) else str(one)
            if p:
                per[p] = per.get(p, 0) + 1

    folders = []
    for p in per:
        rel = p
        if rel.lower().startswith(ROOT.lower()):
            rel = rel[len(ROOT):].lstrip("\\/")
        parts = [x for x in rel.replace("\\", "/").split("/") if x]
        d = parts[0] if len(parts) > 1 else "(root)"
        if d not in folders:
            folders.append(d)
    return {
        "chunks": sum(per.values()),
        "files": len(per),
        "folders": folders[:14],
        "built": str(data.get("built") or data.get("at") or "") if isinstance(data, dict) else "",
    }


def state():
    mem = _connect("memories.db")
    run_db = _connect("runs.db")
    memories = _rows(mem, "select id, at, project, kind, text, tags, job from memories order by id desc limit 400")
    if mem:
        mem.close()
    runs = _rows(run_db, "select id, objective, status, created from runs order by id desc limit 12")
    msgs = _rows(run_db, "select at, name, text, channel from team_messages order by id desc limit 200")
    if run_db:
        run_db.close()

    kinds = {}
    for m in memories:
        k = (m.get("kind") or "note").strip() or "note"
        kinds[k] = kinds.get(k, 0) + 1

    crew = _crew(msgs)
    return {
        "at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "crew": crew,
        "memories": memories,
        "kinds": kinds,
        "runs": runs,
        "counts": {"memories": len(memories), "runs": len(runs), "messages": len(msgs)},
        "rag": _rag(),
    }


PAGE = r"""<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Aquarium</title>
<style>
html,body{height:100%;margin:0}
body{background:radial-gradient(120% 90% at 50% 0%,#0b3a52 0%,#061a27 45%,#030c13 100%);
  color:#cfe9f5;font:14px/1.5 ui-sans-serif,system-ui,"Segoe UI",Roboto,sans-serif;overflow:hidden}
#wrap{display:grid;grid-template-columns:1fr 306px;height:100%}
@media(max-width:860px){#wrap{grid-template-columns:1fr}#side{display:none}}
#tank{position:relative;overflow:hidden}
canvas{display:block;width:100%;height:100%;cursor:pointer}
#hud{position:absolute;left:20px;top:15px;pointer-events:none}
#hud h1{margin:0;font-size:18px;font-weight:600;letter-spacing:.16em;text-transform:uppercase;color:#bfe6f7;text-shadow:0 0 20px #2aa7d055}
#hud .sub{color:#7fa8bd;font-size:12px;margin-top:3px}
#card{position:absolute;pointer-events:none;background:#0b2434ee;border:1px solid #1d4c66;border-radius:10px;
  padding:9px 12px;max-width:300px;font-size:12.5px;display:none;box-shadow:0 10px 30px #0008}
#card b{color:#eaf7ff}
#card .r{color:#7fa8bd}
#side{background:linear-gradient(180deg,#08202d,#050f17);border-left:1px solid #10344a;padding:15px 15px 24px;overflow:auto}
#side h2{font-size:11px;letter-spacing:.16em;text-transform:uppercase;color:#6f97ad;margin:17px 0 8px;font-weight:600}
#side h2:first-child{margin-top:2px}
.kv{display:flex;justify-content:space-between;gap:8px;padding:3px 0;font-size:12.5px}
.kv b{font-weight:500;color:#e6f6ff}
.kv span{color:#7fa8bd}
.bar{height:4px;border-radius:3px;background:#0e2b3c;overflow:hidden;margin:4px 0 9px}
.bar i{display:block;height:100%;background:linear-gradient(90deg,#2aa7d0,#6fe0c8)}
.pill{display:inline-block;padding:1px 7px;border-radius:99px;background:#0d3247;color:#9fd6ee;font-size:11px;margin:2px 4px 2px 0}
.bot{display:flex;align-items:center;gap:9px;padding:4px 0}
.bot img{width:26px;height:26px}
.bot small{color:#7fa8bd}
#err{position:absolute;bottom:12px;left:20px;color:#ffb4b4;font-size:12px}
</style></head>
<body>
<div id="wrap">
  <div id="tank">
    <canvas id="c"></canvas>
    <div id="hud"><h1>Aquarium</h1><div class="sub" id="sub">reading the tank...</div></div>
    <div id="card"></div>
    <div id="err"></div>
  </div>
  <aside id="side">
    <h2>Tank</h2><div id="counts"></div>
    <h2>Reef &middot; retrieval index</h2><div id="rag"></div>
    <h2>Memories by kind</h2><div id="kinds"></div>
    <h2>Crew</h2><div id="crew"></div>
    <h2>Recent runs</h2><div id="runs"></div>
  </aside>
</div>
<script>
const BASE = location.pathname.replace(/\/+$/, "");
const c = document.getElementById("c"), ctx = c.getContext("2d");
const card = document.getElementById("card");
let W = 0, H = 0, dpr = 1, t = 0, DATA = null;
let swimmers = [], bubbles = [], weeds = [], images = {}, hover = null, chosen = null;
let chats = [], nextChatCheck = 0;

function resize(){
  dpr = Math.min(2, window.devicePixelRatio || 1);
  W = c.clientWidth; H = c.clientHeight;
  c.width = Math.floor(W * dpr); c.height = Math.floor(H * dpr);
  ctx.setTransform(dpr,0,0,dpr,0,0);
  // A resize must not reset the tank: the crew keeps its places and only the
  // edges are clamped, or every window drag teleports everyone.
  for (const s of swimmers){
    s.x = Math.max(40, Math.min(W - 40, s.x));
    s.y = Math.max(60, Math.min(H - 60, s.y));
    s.tx = Math.max(40, Math.min(W - 40, s.tx));
    s.ty = Math.max(60, Math.min(H - 60, s.ty));
  }
  if (!weeds.length) weeds = Array.from({length: 16}, () => ({x: Math.random() * W, h: 46 + Math.random() * 130,
    sway: Math.random() * Math.PI * 2, w: 2 + Math.random() * 3}));
}
function seed(){
  const crew = (DATA && DATA.crew) || [];
  swimmers = crew.map((m, i) => {
    const x = 70 + Math.random() * Math.max(40, W - 140);
    const y = 100 + Math.random() * Math.max(40, H - 210);
    return {
      ...m, x, y, tx: x, ty: y,
      vx: 0, vy: 0,
      // Slow: these are people at a desk, not fish. Speed is in pixels per
      // frame, and a wander at 0.1 crosses the tank in about a minute.
      speed: 0.055 + Math.random() * 0.045,
      size: 50 + (i % 3) * 7,
      phase: Math.random() * Math.PI * 2,
      wait: Math.random() * 8,
      bubble: null,
      bubbleAt: 0,
      nextSay: 3 + Math.random() * 12,
      chatUntil: 0,
      partner: null
    };
  });
  if (!swimmers.length) swimmers = [{name: "the foreman", role: "no crew.json yet", avatar: "wizard",
    lines: ["no crew.json yet - the roster seeds itself on first read"],
    x: W / 2, y: H / 2, tx: W / 2, ty: H / 2, vx: 0, vy: 0, speed: .06, size: 60,
    phase: 0, wait: 0, bubble: null, bubbleAt: 0, nextSay: 4, chatUntil: 0, partner: null}];
  weeds = Array.from({length: 16}, () => ({x: Math.random() * W, h: 46 + Math.random() * 130,
    sway: Math.random() * Math.PI * 2, w: 2 + Math.random() * 3}));
}
function avatarUrl(id){
  // The wizard's file is wizard-avatar.svg; every other avatar is <id>.svg.
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
    const r = await fetch(BASE + "/api/state", {cache: "no-store"});
    if (!r.ok) throw new Error("HTTP " + r.status);
    DATA = await r.json();
  }catch(e){
    document.getElementById("err").textContent = "could not read the tank: " + e.message;
    return;
  }
  const had = swimmers.length;
  for (const m of DATA.crew) loadImage(m.avatar);
  // The first paint happens before the first fetch answers, so "already
  // seeded" cannot mean "has swimmers" - the placeholder had one. Reseed
  // whenever the tank is holding the placeholder or the roster changed size.
  const placeholder = swimmers.length === 1 && !swimmers[0].slug;
  if (!had || placeholder || swimmers.length !== DATA.crew.length) seed();
  else {
    // Keep them where they are when the data refreshes; only the words change.
    for (const s of swimmers){
      const fresh = DATA.crew.find(m => m.slug === s.slug);
      if (fresh){ s.lines = fresh.lines; s.role = fresh.role; s.learned = fresh.learned; }
    }
  }
  document.getElementById("sub").textContent =
    DATA.counts.memories + " memories  ·  " + DATA.counts.messages +
    " team messages  ·  " + DATA.rag.chunks + " indexed chunks";

  document.getElementById("counts").innerHTML =
    kv("swimmers", DATA.crew.length) + kv("memories", DATA.counts.memories) +
    kv("runs", DATA.counts.runs) + kv("team messages", DATA.counts.messages);
  document.getElementById("rag").innerHTML =
    kv("chunks", DATA.rag.chunks) + kv("files", DATA.rag.files) +
    (DATA.rag.built ? kv("built", String(DATA.rag.built).replace("T", " ").slice(0, 16)) : "") +
    (DATA.rag.folders.length
      ? DATA.rag.folders.map(f => '<span class="pill">' + esc(f) + '</span>').join("")
      : '<div class="kv"><span>not built yet - run rag_index</span></div>');
  const maxK = Math.max(1, ...Object.values(DATA.kinds));
  document.getElementById("kinds").innerHTML =
    Object.entries(DATA.kinds).sort((a, b) => b[1] - a[1]).slice(0, 8).map(([k, n]) =>
      '<div class="kv"><b>' + esc(k) + '</b><span>' + n + '</span></div>' +
      '<div class="bar"><i style="width:' + Math.round(n / maxK * 100) + '%"></i></div>'
    ).join("") || '<div class="kv"><span>empty</span></div>';
  document.getElementById("crew").innerHTML = DATA.crew.map(m =>
    '<div class="bot"><img src="' + avatarUrl(m.avatar) + '" alt="">' +
    '<div><b>' + esc(m.name) + '</b><br><small>' + esc(m.role || m.slug) +
    (m.learned ? " · " + m.learned + " lessons" : "") + '</small></div></div>'
  ).join("") || '<div class="kv"><span>no crew.json yet</span></div>';
  document.getElementById("runs").innerHTML = (DATA.runs || []).map(r =>
    '<div class="kv"><b title="' + esc(r.objective || "") + '">' +
    esc((r.objective || "(untitled)").slice(0, 26)) + '</b><span>' + esc(r.status || "") + '</span></div>'
  ).join("") || '<div class="kv"><span>no runs yet</span></div>';
}
function kv(k, v){ return '<div class="kv"><span>' + esc(k) + '</span><b>' + esc(String(v)) + '</b></div>'; }
function esc(s){ return String(s).replace(/[&<>"]/g, m => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[m])); }

c.addEventListener("mousemove", ev => {
  const r = c.getBoundingClientRect();
  const x = ev.clientX - r.left, y = ev.clientY - r.top;
  hover = null;
  for (const s of swimmers){
    const dx = x - s.x, dy = y - s.y;
    if (dx * dx + dy * dy < (s.size * 0.62) ** 2) { hover = s; break; }
  }
  c.style.cursor = hover ? "pointer" : "default";
  if (hover){
    card.style.display = "block";
    card.innerHTML = '<b>' + esc(hover.name) + '</b><div class="r">' + esc(hover.role) + '</div>' +
      '<div style="margin-top:4px;color:#9fc4d6">' + esc(hover.blurb || "") + '</div>';
    card.style.left = Math.min(x + 16, W - 320) + "px";
    card.style.top = Math.max(10, y - 20) + "px";
  } else card.style.display = "none";
});
c.addEventListener("click", () => { chosen = hover ? (chosen === hover ? null : hover) : null; });

// ---- words ----------------------------------------------------------------
function say(s, text){
  if (!text) return;
  s.bubble = String(text);
  s.bubbleAt = t;
}
function pickLine(s){
  const lines = (s.lines || []).filter(Boolean);
  if (!lines.length) return "";
  return lines[Math.floor(Math.random() * lines.length)];
}

// ---- wandering ------------------------------------------------------------
function newTarget(s){
  const pad = 70;
  s.tx = pad + Math.random() * Math.max(60, W - pad * 2);
  s.ty = pad + 40 + Math.random() * Math.max(60, H - pad * 2 - 40);
}
function steer(s, dt){
  if (s.chatUntil > t){
    // Standing still, facing the other one: a conversation, not a swim-past.
    if (s.partner){
      const dx = s.partner.x - s.x, dy = s.partner.y - s.y;
      const d = Math.hypot(dx, dy) || 1;
      const want = 68;
      s.x += (dx / d) * (d - want) * 0.006;
      s.y += (dy / d) * (d - want) * 0.006;
      s.facing = dx >= 0 ? 1 : -1;
    }
    return;
  }
  const dx = s.tx - s.x, dy = s.ty - s.y;
  const d = Math.hypot(dx, dy);
  if (d < 6){
    if (s.wait > 0){ s.wait -= dt; return; }
    // A pause at each end of a wander: this is what stops the tank looking
    // like a screensaver of things sliding past each other.
    newTarget(s);
    s.wait = 2 + Math.random() * 9;
    return;
  }
  const accel = 0.0022;
  s.vx += (dx / d) * accel * dt * 3;
  s.vy += (dy / d) * accel * dt * 3;
  const max = s.speed;
  const sp = Math.hypot(s.vx, s.vy);
  if (sp > max){ s.vx = s.vx / sp * max; s.vy = s.vy / sp * max; }
  s.x += s.vx;
  s.y += s.vy;
  if (Math.abs(s.vx) > 0.005) s.facing = s.vx >= 0 ? 1 : -1;
}

// ---- conversations --------------------------------------------------------
function updateChats(){
  if (t < nextChatCheck) return;
  nextChatCheck = t + 45;
  if (chats.length >= 2) return;
  for (let i = 0; i < swimmers.length; i++){
    const a = swimmers[i];
    if (a.chatUntil > t) continue;
    for (let j = i + 1; j < swimmers.length; j++){
      const b = swimmers[j];
      if (b.chatUntil > t) continue;
      const d = Math.hypot(a.x - b.x, a.y - b.y);
      if (d > 150) continue;
      // Close enough to notice each other. They stop, say their own words, and
      // separate on their own - nothing is invented, both lines are real.
      a.partner = b; b.partner = a;
      a.chatUntil = b.chatUntil = t + 240 + Math.random() * 180;
      say(a, pickLine(a)); say(b, pickLine(b));
      chats.push({a, b, until: a.chatUntil});
      break;
    }
    if (chats.length >= 2) break;
  }
}

function drawBubble(s, bob){
  if (!s.bubble) return;
  const age = t - s.bubbleAt;
  if (age > 330){ s.bubble = null; return; }
  const fade = Math.min(1, Math.min(age / 20, (330 - age) / 30));
  ctx.save();
  ctx.globalAlpha = Math.max(0, fade) * 0.96;
  ctx.font = "12px ui-sans-serif,system-ui";
  const maxW = 196;
  const words = String(s.bubble).split(" ");
  const lines = [];
  let cur = "";
  for (const w of words){
    const test = cur ? cur + " " + w : w;
    if (ctx.measureText(test).width > maxW && cur){ lines.push(cur); cur = w; }
    else cur = test;
    if (lines.length >= 3) break;
  }
  if (cur && lines.length < 3) lines.push(cur);
  const wMax = Math.max(...lines.map(l => ctx.measureText(l).width), 30);
  const padX = 10, padY = 8, lh = 15;
  const bw = Math.min(maxW + padX * 2, wMax + padX * 2);
  const bh = lines.length * lh + padY * 2;
  let bx = s.x - bw / 2;
  let by = s.y + bob - s.size * 0.72 - bh - 12;
  bx = Math.max(8, Math.min(W - bw - 8, bx));
  by = Math.max(8, by);
  const r = 9;
  ctx.beginPath();
  ctx.moveTo(bx + r, by);
  ctx.arcTo(bx + bw, by, bx + bw, by + bh, r);
  ctx.arcTo(bx + bw, by + bh, bx, by + bh, r);
  ctx.arcTo(bx, by + bh, bx, by, r);
  ctx.arcTo(bx, by, bx + bw, by, r);
  ctx.closePath();
  ctx.fillStyle = "rgba(9,32,45,0.94)";
  ctx.fill();
  ctx.strokeStyle = "rgba(120,220,255,0.45)";
  ctx.lineWidth = 1;
  ctx.stroke();
  // tail
  ctx.beginPath();
  const tx = Math.max(bx + 14, Math.min(bx + bw - 14, s.x));
  ctx.moveTo(tx - 6, by + bh - 1);
  ctx.lineTo(tx + 6, by + bh - 1);
  ctx.lineTo(tx, by + bh + 9);
  ctx.closePath();
  ctx.fillStyle = "rgba(9,32,45,0.94)";
  ctx.fill();
  ctx.fillStyle = "#d9f2ff";
  ctx.textAlign = "left";
  lines.forEach((l, i) => ctx.fillText(l, bx + padX, by + padY + 11 + i * lh));
  ctx.restore();
}

function paint(){
  const dt = 1;
  ctx.clearRect(0, 0, W, H);
  // light shafts
  for (let i = 0; i < 5; i++){
    const x = (W / 6) * (i + 1) + Math.sin(t / 420 + i) * 26;
    const g = ctx.createLinearGradient(x, 0, x + 90, H);
    g.addColorStop(0, "rgba(120,220,255,0.05)"); g.addColorStop(1, "rgba(120,220,255,0)");
    ctx.fillStyle = g; ctx.beginPath();
    ctx.moveTo(x - 26, 0); ctx.lineTo(x + 52, 0); ctx.lineTo(x + 130, H); ctx.lineTo(x + 30, H);
    ctx.closePath(); ctx.fill();
  }
  const sand = ctx.createLinearGradient(0, H - 95, 0, H);
  sand.addColorStop(0, "rgba(20,58,72,0)"); sand.addColorStop(1, "rgba(26,74,86,0.85)");
  ctx.fillStyle = sand; ctx.fillRect(0, H - 95, W, 95);
  for (const w of weeds){
    ctx.strokeStyle = "rgba(80,190,160,0.32)"; ctx.lineWidth = w.w; ctx.beginPath();
    ctx.moveTo(w.x, H);
    ctx.quadraticCurveTo(w.x + Math.sin(t / 150 + w.sway) * 18, H - w.h * 0.6,
      w.x + Math.sin(t / 120 + w.sway) * 30, H - w.h);
    ctx.stroke();
  }
  for (const b of bubbles){
    b.y += b.vy; b.wob += 0.02;
    const x = b.x + Math.sin(b.wob) * 11;
    ctx.beginPath(); ctx.arc(x, b.y, b.r, 0, Math.PI * 2);
    ctx.strokeStyle = "rgba(170,235,255,0.4)"; ctx.lineWidth = 1; ctx.stroke();
    ctx.fillStyle = "rgba(120,210,255,0.08)"; ctx.fill();
  }
  bubbles = bubbles.filter(b => b.y > -24);

  updateChats();
  chats = chats.filter(ch => ch.until > t);
  for (const ch of chats){
    // a dotted thread between two who are talking
    ctx.save();
    ctx.setLineDash([2, 6]);
    ctx.strokeStyle = "rgba(160,235,255,0.28)";
    ctx.beginPath(); ctx.moveTo(ch.a.x, ch.a.y); ctx.lineTo(ch.b.x, ch.b.y); ctx.stroke();
    ctx.restore();
  }

  for (const s of swimmers){
    s.phase += 0.022;
    steer(s, dt);
    if (s.chatUntil <= t && s.partner){ s.partner = null; s.chatUntil = 0; s.wait = 2 + Math.random() * 6; }
    if (s.nextSay > 0){
      s.nextSay -= dt / 60;
      if (s.nextSay <= 0 && s.chatUntil <= t){
        say(s, pickLine(s));
        s.nextSay = 14 + Math.random() * 26;
      }
    }
    const bob = Math.sin(s.phase * 1.4) * 3;
    const img = images[s.avatar] || loadImage(s.avatar);
    const dim = (chosen && chosen !== s) ? 0.35 : 1;

    ctx.save();
    ctx.globalAlpha = 0.18 * dim;
    const halo = ctx.createRadialGradient(s.x, s.y + bob, 2, s.x, s.y + bob, s.size * 0.8);
    halo.addColorStop(0, "#9fe8ff"); halo.addColorStop(1, "rgba(120,210,255,0)");
    ctx.fillStyle = halo;
    ctx.beginPath(); ctx.arc(s.x, s.y + bob, s.size * 0.8, 0, Math.PI * 2); ctx.fill();
    ctx.restore();

    if (img){
      ctx.save();
      ctx.globalAlpha = dim;
      ctx.translate(s.x, s.y + bob);
      ctx.rotate(Math.sin(s.phase) * 0.035);
      ctx.drawImage(img, -s.size / 2, -s.size / 2, s.size, s.size);
      ctx.restore();
    } else {
      ctx.save(); ctx.globalAlpha = dim;
      ctx.beginPath(); ctx.arc(s.x, s.y + bob, s.size * 0.4, 0, Math.PI * 2);
      ctx.fillStyle = "#123c52"; ctx.fill();
      ctx.restore();
    }
    if (chosen === s){
      ctx.beginPath(); ctx.arc(s.x, s.y + bob, s.size * 0.62, 0, Math.PI * 2);
      ctx.strokeStyle = "rgba(120,240,220,0.85)"; ctx.lineWidth = 2; ctx.stroke();
    }
    ctx.font = "11.5px ui-sans-serif,system-ui"; ctx.textAlign = "center";
    ctx.fillStyle = "rgba(214,240,250," + (dim === 1 ? 0.78 : 0.3) + ")";
    ctx.fillText(s.name, s.x, s.y + bob + s.size * 0.62 + 13);
    drawBubble(s, bob);
  }

  t++;
  requestAnimationFrame(paint);
}

window.addEventListener("resize", resize);
resize(); load(); paint();
setInterval(() => {
  if (!DATA) return;
  const m = DATA.memories[Math.floor(Math.random() * Math.max(1, DATA.memories.length))];
  if (m) bubbles.push({x: 30 + Math.random() * (W - 60), y: H + 10,
    r: 1.6 + Math.random() * 3.2, vy: -(0.16 + Math.random() * 0.34),
    wob: Math.random() * Math.PI * 2});
}, 1500);
setInterval(load, 30000);
</script>
</body></html>
"""


def application(environ, start_response):
    path = environ.get("PATH_INFO", "/") or "/"
    if path.rstrip("/") == "/api/health":
        body = json.dumps({"ok": True, "app": "tank"}).encode()
        start_response("200 OK", [("Content-Type", "application/json"),
                                  ("Content-Length", str(len(body)))])
        return [body]
    if path.rstrip("/") == "/api/state":
        try:
            body = json.dumps(state(), default=str).encode()
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
    body = b"not found"
    start_response("404 Not Found", [("Content-Type", "text/plain"),
                                     ("Content-Length", str(len(body)))])
    return [body]


if __name__ == "__main__":
    run(application)
