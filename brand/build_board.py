#!/usr/bin/env python3
"""Build the haro brand board — inlines woff2 fonts as data URIs so the
artifact is fully self-contained (base64 never enters the conversation)."""
import base64, pathlib

FD = pathlib.Path(__file__).parent / "fonts"
def b64(name): return base64.b64encode((FD / name).read_bytes()).decode()

def face(family, file, weight):
    return (f"@font-face{{font-family:'{family}';font-style:normal;font-weight:{weight};"
            f"font-display:swap;src:url(data:font/woff2;base64,{b64(file)}) format('woff2');}}")

fonts = "".join([
    face("Open Runde", "OpenRunde-600.woff2", 600),
    face("IBM Plex Sans", "PlexSans-400.woff2", 400),
    face("IBM Plex Sans", "PlexSans-600.woff2", 600),
    face("IBM Plex Mono", "PlexMono-500.woff2", 500),
])

CSS = """
""" + fonts + """
:root{
  --paper:#F4F1E6; --card:#FBFAF4; --sunk:#EDE8D8;
  --ink:#17160F; --soft:#5B584C; --line:#E2DBC8;
  --gate:#12A150; --gate-deep:#0B7A3C; --coral:#FF5A36; --blue:#2A4BE0;
  --marker:#FFD84D; --red:#E5484D; --shadow:rgba(23,22,15,.14);
  --display:'Open Runde','Nunito',ui-rounded,system-ui,sans-serif;
  --sans:'IBM Plex Sans',ui-sans-serif,system-ui,sans-serif;
  --mono:'IBM Plex Mono',ui-monospace,monospace;
}
:root[data-theme="dark"]{
  --paper:#141310; --card:#201E17; --sunk:#0E0D0A;
  --ink:#F3F0E4; --soft:#A29C88; --line:#332F24;
  --gate:#41D183; --gate-deep:#41D183; --coral:#FF7A5C; --blue:#8AA0FF;
  --marker:#F5C63C; --red:#FF6B6B; --shadow:rgba(0,0,0,.5);
}
@media (prefers-color-scheme:dark){
  :root:not([data-theme="light"]){
    --paper:#141310; --card:#201E17; --sunk:#0E0D0A;
    --ink:#F3F0E4; --soft:#A29C88; --line:#332F24;
    --gate:#41D183; --gate-deep:#41D183; --coral:#FF7A5C; --blue:#8AA0FF;
    --marker:#F5C63C; --red:#FF6B6B; --shadow:rgba(0,0,0,.5);
  }
}
*{box-sizing:border-box;}
.wrap{background:var(--paper);color:var(--ink);font-family:var(--sans);
  font-size:16px;line-height:1.55;-webkit-font-smoothing:antialiased;
  padding:clamp(20px,5vw,64px);}
.board{max-width:1060px;margin:0 auto;display:flex;flex-direction:column;gap:28px;}
h1,h2,h3,.disp{font-family:var(--display);font-weight:600;letter-spacing:-.02em;
  line-height:1.05;margin:0;text-wrap:balance;}
.eyebrow{font-family:var(--mono);font-size:12px;font-weight:500;letter-spacing:.18em;
  text-transform:uppercase;color:var(--soft);}
p{margin:0;}
.dim{color:var(--soft);}

/* wordmark */
.top{display:flex;align-items:center;justify-content:space-between;gap:16px;flex-wrap:wrap;}
.mark{display:flex;align-items:center;gap:11px;font-family:var(--display);font-weight:600;
  font-size:26px;letter-spacing:-.03em;}
.dot{width:15px;height:15px;border-radius:50%;background:var(--gate);
  box-shadow:0 0 0 4px color-mix(in srgb,var(--gate) 22%,transparent);}
.pill{font-family:var(--mono);font-size:11px;letter-spacing:.14em;text-transform:uppercase;
  color:var(--soft);border:1px solid var(--line);border-radius:999px;padding:5px 11px;}

/* card */
.card{background:var(--card);border:1.5px solid var(--ink);border-radius:16px;
  padding:clamp(18px,3vw,30px);box-shadow:5px 5px 0 var(--shadow);}
.card.hero{box-shadow:7px 7px 0 var(--gate);}
.section-label{font-family:var(--mono);font-size:11px;letter-spacing:.16em;
  text-transform:uppercase;color:var(--soft);margin-bottom:14px;}

/* hero */
.hero h1{font-size:clamp(34px,6vw,60px);}
.hl{background:linear-gradient(transparent 58%,var(--marker) 58% 94%,transparent 94%);
  padding:0 .06em;border-radius:2px;}
.hero p.lede{font-size:clamp(16px,2.1vw,20px);color:var(--soft);margin-top:16px;max-width:52ch;}
.hero .cta{display:flex;gap:12px;margin-top:26px;flex-wrap:wrap;}

/* buttons */
.btn{font-family:var(--display);font-weight:600;font-size:15px;border-radius:11px;
  padding:11px 20px;border:1.5px solid var(--ink);cursor:pointer;
  box-shadow:3px 3px 0 var(--ink);transition:transform .08s,box-shadow .08s;text-decoration:none;
  display:inline-flex;align-items:center;gap:8px;color:var(--ink);background:var(--card);}
.btn:hover{transform:translate(1px,1px);box-shadow:2px 2px 0 var(--ink);}
.btn.primary{background:var(--gate);color:#04160c;}
.btn.coral{background:var(--coral);color:#210a03;}
.btn.mono{font-family:var(--mono);font-weight:500;}

/* palette */
.swatches{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:12px;}
.sw{border:1.5px solid var(--ink);border-radius:12px;overflow:hidden;background:var(--card);}
.sw .chip{height:74px;}
.sw .meta{padding:9px 11px;display:flex;flex-direction:column;gap:1px;}
.sw .nm{font-weight:600;font-size:13px;}
.sw .hex{font-family:var(--mono);font-size:11.5px;color:var(--soft);text-transform:uppercase;}

/* type specimens */
.type-row{display:flex;flex-direction:column;gap:6px;padding:16px 0;border-top:1px solid var(--line);}
.type-row:first-of-type{border-top:none;}
.type-tag{font-family:var(--mono);font-size:11px;color:var(--soft);letter-spacing:.08em;}
.spec-display{font-family:var(--display);font-weight:600;font-size:30px;letter-spacing:-.02em;}
.spec-sans{font-family:var(--sans);font-size:18px;}
.spec-mono{font-family:var(--mono);font-size:15px;}

/* grid of component demos */
.cols{display:grid;grid-template-columns:1fr 1fr;gap:20px;}
@media(max-width:720px){.cols{grid-template-columns:1fr;}}
.chips{display:flex;gap:8px;flex-wrap:wrap;}
.tag{font-family:var(--mono);font-size:12px;border:1.5px solid var(--ink);border-radius:999px;
  padding:4px 12px;background:var(--card);}
.tag.green{background:color-mix(in srgb,var(--gate) 20%,var(--card));border-color:var(--gate-deep);color:var(--gate-deep);}
.tag.red{background:color-mix(in srgb,var(--red) 16%,var(--card));border-color:var(--red);color:var(--red);}

/* gate sample */
.gate-badge{display:inline-flex;align-items:center;gap:8px;font-family:var(--mono);font-weight:500;
  font-size:14px;color:var(--gate-deep);}
.gate-badge .d{width:10px;height:10px;border-radius:50%;background:var(--gate);}
.grid{display:flex;gap:6px;flex-wrap:wrap;margin:14px 0;}
.cell{width:26px;height:26px;border-radius:6px;border:1.5px solid var(--ink);}
.cell.p{background:var(--gate);}
.cell.f{background:var(--red);}
.tests{font-family:var(--mono);font-size:13px;display:flex;flex-direction:column;gap:5px;}
.tests .ok::before{content:"\\2713 ";color:var(--gate-deep);}
.tests .no::before{content:"\\2717 ";color:var(--red);}

/* app-mode (always dark) mock */
.appmock{background:#141310;border:1.5px solid #0c0b08;border-radius:16px;padding:22px;
  box-shadow:5px 5px 0 rgba(0,0,0,.4);color:#F3F0E4;}
.appmock .gate-badge{color:#41D183;}
.appmock .gate-badge .d{background:#41D183;}
.appmock .cell{border-color:#0c0b08;}
.appmock .cell.p{background:#41D183;}
.appmock .cell.f{background:#FF6B6B;}
.appmock .muted{color:#A29C88;font-family:var(--mono);font-size:12px;}

.foot{display:flex;justify-content:space-between;gap:16px;flex-wrap:wrap;
  border-top:1px solid var(--line);padding-top:18px;font-family:var(--mono);font-size:12px;color:var(--soft);}
"""

BODY = """
<div class="wrap"><div class="board">

  <div class="top">
    <div class="mark"><span class="dot"></span>haro</div>
    <span class="pill">Brand System · v1</span>
  </div>

  <div class="card hero">
    <div class="eyebrow">The trademark</div>
    <h1 class="hero-h">Agents do the work.<br>The gate says when it's <span class="hl">green</span>.</h1>
    <p class="lede">A local-first, Linux-first orchestrator for AI coding agents — every change
    earns its merge by turning the tests green. Warm, tactile, and honest about state.</p>
    <div class="cta">
      <a class="btn primary">Run the gate</a>
      <a class="btn coral">Watch it work</a>
      <a class="btn mono">npx haro</a>
    </div>
  </div>

  <div class="card">
    <div class="section-label">Palette — paper &amp; ink, a green signature</div>
    <div class="swatches">
      SWATCHES
    </div>
  </div>

  <div class="cols">
    <div class="card">
      <div class="section-label">Type — rounded display, plex body &amp; mono</div>
      <div class="type-row"><span class="type-tag">Open Runde · display</span>
        <span class="spec-display">Ship it when it's green</span></div>
      <div class="type-row"><span class="type-tag">IBM Plex Sans · body</span>
        <span class="spec-sans">Readable, technical, humane — the voice of the product.</span></div>
      <div class="type-row"><span class="type-tag">IBM Plex Mono · code &amp; data</span>
        <span class="spec-mono">gate_green · 4✓ 0✗ · 422ms</span></div>
    </div>

    <div class="card">
      <div class="section-label">Elements</div>
      <div class="chips" style="margin-bottom:16px">
        <span class="tag green">● passing</span>
        <span class="tag red">✗ failing</span>
        <span class="tag">impacted</span>
        <span class="tag">worktree</span>
      </div>
      <div class="cta" style="margin:0">
        <a class="btn primary">Merge</a>
        <a class="btn">Run all</a>
      </div>
      <p style="margin-top:16px" class="dim">Key words wear a <span class="hl">highlighter</span> swipe;
      cards are bordered stickers with a soft offset — one hero card casts a green shadow.</p>
    </div>
  </div>

  <div class="cols">
    <div class="card hero">
      <div class="section-label">The gate — light (marketing)</div>
      <span class="gate-badge"><span class="d"></span>gate · green</span>
      <div class="grid"><span class="cell p"></span><span class="cell p"></span><span class="cell p"></span><span class="cell p"></span></div>
      <div class="tests"><span class="ok">add › adds two numbers</span><span class="ok">multiply › multiplies</span></div>
    </div>
    <div class="appmock">
      <div class="section-label" style="color:#A29C88">The gate — warm dark (app)</div>
      <span class="gate-badge"><span class="d"></span>gate · red</span>
      <div class="grid"><span class="cell p"></span><span class="cell p"></span><span class="cell f"></span><span class="cell f"></span></div>
      <div class="tests"><span class="ok" style="color:#41D183">add › adds two numbers</span><span class="no" style="color:#FF6B6B">multiply › not a function</span></div>
      <p class="muted" style="margin-top:12px">same palette, warm-dark ground — the developer's canvas</p>
    </div>
  </div>

  <div class="foot">
    <span>Open Runde + IBM Plex — open-source, bundleable</span>
    <span>one theme · app &amp; web</span>
  </div>

</div></div>
"""

sw = [
  ("Paper","#F4F1E6","warm canvas"),
  ("Ink","#17160F","text"),
  ("Gate green","#12A150","signature"),
  ("Coral","#FF5A36","energy"),
  ("Ink blue","#2A4BE0","links"),
  ("Marker","#FFD84D","highlight"),
  ("Gate red","#E5484D","fail"),
  ("Line","#E2DBC8","borders"),
]
sw_html = "".join(
  f'<div class="sw"><div class="chip" style="background:{hex}"></div>'
  f'<div class="meta"><span class="nm">{nm}</span><span class="hex">{hex}</span>'
  f'<span class="hex" style="text-transform:none">{note}</span></div></div>'
  for nm,hex,note in sw
)
BODY = BODY.replace("SWATCHES", sw_html)

# Encoding-safe: replace non-ASCII glyphs with HTML entities so the published
# artifact renders correctly regardless of the served charset.
for g, ent in [("—","&mdash;"),("·","&middot;"),("✓","&#10003;"),("✗","&#10007;"),
               ("›","&rsaquo;"),("●","&#9679;"),("✕","&#10005;")]:
    BODY = BODY.replace(g, ent)

html = f"<style>{CSS}</style>\n{BODY}"
out = pathlib.Path(__file__).parent / "haro-brand-board.html"
out.write_text(html)
print(f"wrote {out} ({len(html)//1024}KB)")
