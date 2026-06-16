#!/usr/bin/env python3
"""Branded App Store screenshots for Cini — iPhone (1284x2778) + iPad
(2048x2732). Beli-style marketing frames: an ALL-CAPS headline, one short
centered sentence, then a large device mockup that is the hero. Each device
renders a clean app mockup behind a polished gold-rimmed frame with a clearly
iOS status bar (9:41, Dynamic Island on iPhone, Wi-Fi + battery) — addressing
App Review's note about non-iOS status bars. Posters are real (TMDB)."""
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import os, json, urllib.request, urllib.parse

# Device + canvas are set per pass in render_all(); these are defaults.
W, H = 1284, 2778
DEVICE = "iphone"; ISLAND = True
BG="#131011"; BG2="#1b1614"; SURF="#1D1719"; SURF2="#281F20"; FILL="#2a2526"
INK="#F5EEDF"; GRAY="#A69C91"; MARQUEE="#E8B64C"; VELVET="#A8352A"; GOLD="#D9A93C"
GREEN="#2FBF71"; LOVE="#53B17C"; FINE="#F4C95C"; DIS="#EE9E9E"

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
RES = os.path.join(ROOT, "Cini", "Resources")
DISPLAY = os.path.join(RES, "Limelight-Regular.ttf")        # marquee wordmark
SERIF   = os.path.join(RES, "DMSerifDisplay-Regular.ttf")   # editorial headlines
SANS  = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
SANSB = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
def disp(p): return ImageFont.truetype(DISPLAY, p)
def sf(p): return ImageFont.truetype(SERIF, p)
def sa(p): return ImageFont.truetype(SANS, p)
def sb(p): return ImageFont.truetype(SANSB, p)

OUT = os.path.join(ROOT, "docs", "appstore")

# ---- Real posters from TMDB (the app's own image source) -------------------
def _tmdb_key():
    with open(os.path.join(RES, "Secrets.xcconfig")) as f:
        for line in f:
            if line.strip().startswith("TMDB_API_KEY"):
                return line.split("=", 1)[1].strip()
    return ""
KEY = _tmdb_key()
CACHE = "/tmp/cini_posters"; os.makedirs(CACHE, exist_ok=True)
_pc = {}
def poster_img(query, year=None):
    if query in _pc: return _pc[query]
    try:
        u = f"https://api.themoviedb.org/3/search/movie?api_key={KEY}&query={urllib.parse.quote(query)}"
        if year: u += f"&year={year}"
        data = json.load(urllib.request.urlopen(u, timeout=25))
        path = (data.get("results") or [{}])[0].get("poster_path")
        if not path: _pc[query] = None; return None
        fp = os.path.join(CACHE, "w780_" + path.lstrip("/"))
        if not os.path.exists(fp):
            urllib.request.urlretrieve(f"https://image.tmdb.org/t/p/w780{path}", fp)
        im = Image.open(fp).convert("RGB"); _pc[query] = im; return im
    except Exception as e:
        print("  poster miss:", query, e); _pc[query] = None; return None

def ctext(d, cx, y, t, f, fill, glow=None, track=0):
    if track:
        total = sum(d.textlength(ch, font=f) + track for ch in t) - track
        x = cx - total/2
        for ch in t:
            d.text((x, y), ch, font=f, fill=fill); x += d.textlength(ch, font=f) + track
        return f.size
    w = d.textlength(t, font=f)
    if glow:
        gl = Image.new("RGBA", (int(w)+120, f.size+120), (0,0,0,0))
        ImageDraw.Draw(gl).text((60,60), t, font=f, fill=glow)
        gl = gl.filter(ImageFilter.GaussianBlur(14))
        BASE.paste(gl, (int(cx-w/2-60), int(y-60)), gl)
    d.text((cx-w/2, y), t, font=f, fill=fill)
    return f.size

def wrap(d, t, f, maxw):
    out=[]; cur=""
    for wd in t.split():
        s=(cur+" "+wd).strip()
        if d.textlength(s,font=f)<=maxw: cur=s
        else: out.append(cur); cur=wd
    if cur: out.append(cur)
    return out

# Per-screen branded backdrops — distinct warm cinema tones (top), settling
# into the house-lights-down charcoal. Cohesive with the marquee palette.
BACKDROPS = {
    "velvet": (0x6e, 0x27, 0x20),
    "gold":   (0x6c, 0x4e, 0x1d),
    "plum":   (0x45, 0x23, 0x4d),
    "bronze": (0x61, 0x43, 0x20),
    "ember":  (0x6e, 0x32, 0x1a),
}
def bg(accent="gold"):
    top = BACKDROPS.get(accent, BACKDROPS["gold"])
    base = tuple(int(c*0.30)+7 for c in top)   # darker, same hue — not black
    img = Image.new("RGB",(W,H))
    d = ImageDraw.Draw(img)
    for y in range(H):
        t = y/H
        r=int(top[0]+(base[0]-top[0])*t); g=int(top[1]+(base[1]-top[1])*t); b=int(top[2]+(base[2]-top[2])*t)
        d.line([(0,y),(W,y)], fill=(r,g,b))
    # soft warm glow up top, the brand signature
    glow = Image.new("RGBA",(W,H),(0,0,0,0))
    ImageDraw.Draw(glow).ellipse([W/2-W*0.55,-H*0.14,W/2+W*0.55,H*0.16], fill=(255,205,120,44))
    glow=glow.filter(ImageFilter.GaussianBlur(int(W*0.12)))
    img.paste(Image.alpha_composite(img.convert("RGBA"),glow).convert("RGB"),(0,0))
    return img

def caption(d, headline, sub):
    # Small gold wordmark (brand signature), a big ALL-CAPS headline, and a
    # clear one-sentence benefit. Scales with the canvas.
    k = W / 1290
    wm = disp(int(40 * k)); ww = d.textlength("cini", font=wm)
    d.text((W/2 - ww/2, int(58 * k)), "cini", font=wm, fill=MARQUEE)
    y = int(150 * k)
    hf = sf(int(126 * k))
    ctext(d, W/2, y, headline.upper(), hf, INK, track=int(10 * k))
    y += int(168 * k)
    sfont = sa(int(40 * k))
    for ln in wrap(d, sub, sfont, W - int(150 * k)):
        ctext(d, W/2, y, ln, sfont, GRAY); y += int(54 * k)
    return y

SCREEN = None  # set by phone(); poster() pastes onto this
def phone(top, draw_screen):
    """Big, centered device cropped at the bottom (Beli-style), gold marquee
    frame. Screen content is drawn on a 1180-wide logical canvas and resized to
    the device width, so the same code renders sharp on iPhone and iPad."""
    global SCREEN
    pw = 1180 if DEVICE == "iphone" else 1880    # on-canvas device width
    corner = 100 if DEVICE == "iphone" else 64
    x0 = (W - pw) // 2; y0 = top
    ph = H - y0 + 220                             # extend past the bottom → cropped
    sh = Image.new("RGBA",(W,H),(0,0,0,0))
    ImageDraw.Draw(sh).rounded_rectangle([x0-14,y0+16,x0+pw+14,y0+ph], radius=corner+4, fill=(0,0,0,160))
    sh = sh.filter(ImageFilter.GaussianBlur(48))
    BASE.paste(Image.alpha_composite(BASE.convert("RGBA"),sh).convert("RGB"),(0,0))
    d = ImageDraw.Draw(BASE)
    d.rounded_rectangle([x0-16,y0-16,x0+pw+16,y0+ph], radius=corner+16, fill="#0a0809")
    # thin marquee-gold rim — a brand accent, not a heavy frame (Beli-clean)
    d.rounded_rectangle([x0-16,y0-16,x0+pw+16,y0+ph], radius=corner+16, outline=MARQUEE, width=4)
    lw = 1180; lh = int(lw * ph / pw)
    screen = Image.new("RGB",(lw,lh),BG); SCREEN = screen
    draw_screen(ImageDraw.Draw(screen), lw, lh)
    if pw != lw: screen = screen.resize((pw, ph))
    mask = Image.new("L",(pw,ph),0)
    ImageDraw.Draw(mask).rounded_rectangle([0,0,pw-1,ph-1], radius=corner-16, fill=255)
    BASE.paste(screen,(x0,y0),mask)

def score_badge(d, cx, cy, val, r=44, color=None):
    color = color or (GREEN if val>=7 else FINE if val>=5 else DIS)
    d.ellipse([cx-r,cy-r,cx+r,cy+r], outline=color, width=5)
    f=sb(int(r*0.8)); t=f"{val:.1f}"; w=d.textlength(t,font=f)
    d.text((cx-w/2, cy-r*0.55), t, font=f, fill=color)

def poster(d, x, y, w, h, title="", tone=0, query=None, year=None):
    """Real TMDB poster (cover-fit + rounded), or a tasteful gradient fallback."""
    im = poster_img(query or title, year) if (query or title) else None
    if im is not None and SCREEN is not None:
        sr = im.width/im.height; dr = w/h
        if sr > dr: nh=h; nw=int(h*sr)
        else: nw=w; nh=int(w/sr)
        im2 = im.resize((max(nw,1), max(nh,1)))
        l=(nw-w)//2; t=(nh-h)//2
        im2 = im2.crop((l,t,l+w,t+h))
        mask=Image.new("L",(w,h),0); ImageDraw.Draw(mask).rounded_rectangle([0,0,w-1,h-1],radius=14,fill=255)
        SCREEN.paste(im2,(x,y),mask)
        d.rounded_rectangle([x,y,x+w,y+h], radius=14, outline="#3a3335", width=2)
        return
    cols=[(40,30,34),(34,40,46),(46,36,30),(30,42,38),(44,40,30),(38,32,44)]
    c=cols[tone%len(cols)]
    for i in range(h):
        f=i/h
        d.line([(x,y+i),(x+w,y+i)], fill=(int(c[0]*(1-f*0.4)+10),int(c[1]*(1-f*0.4)+8),int(c[2]*(1-f*0.4)+9)))
    d.rounded_rectangle([x,y,x+w,y+h], radius=14, outline="#3a3335", width=2)
    for j,ln in enumerate(wrap(d, title, sb(26), w-24)):
        d.text((x+14, y+h-90+j*30), ln, font=sb(26), fill="#efe6d4")

def status_bar(d, pw):
    """A clearly-iOS status bar: 9:41, Dynamic Island (iPhone only), cellular
    (iPhone only), Wi-Fi fan, and the iOS battery glyph."""
    if ISLAND:
        iw=300; ih=78; ix=(pw-iw)//2; iy=30
        d.rounded_rectangle([ix,iy,ix+iw,iy+ih], radius=39, fill="#000000")
    d.text((58, 40), "9:41", font=sb(38), fill=INK)
    if ISLAND:  # cellular signal — phones only
        for i in range(4):
            h=16+i*10; d.rounded_rectangle([pw-260+i*18, 76-h, pw-249+i*18, 76], radius=2, fill=INK)
    wx=pw-176
    d.pieslice([wx, 40, wx+56, 96], 212, 328, fill=INK)   # Wi-Fi fan
    bx=pw-96                                               # iOS battery
    d.rounded_rectangle([bx, 44, bx+58, 78], radius=8, outline=INK, width=3)
    d.rounded_rectangle([bx+5, 49, bx+44, 73], radius=4, fill=INK)
    d.rounded_rectangle([bx+58, 54, bx+66, 68], radius=3, fill=INK)

def chip(d, x, y, text, active=False):
    f=sa(26); w=d.textlength(text,font=f); cw=w+44; ch=58
    if active:
        d.rounded_rectangle([x,y,x+cw,y+ch],radius=29,fill=MARQUEE)
        d.text((x+22,y+14),text,font=f,fill=(19,16,17))
    else:
        d.rounded_rectangle([x,y,x+cw,y+ch],radius=29,outline="#3a3335",width=2)
        d.text((x+22,y+14),text,font=f,fill=GRAY)
    return x+cw+14

# ============================ SCREENS ======================================

# 1 — DISCOVER (search + Tonight's Pick hero + trending row)
def s_discover(d, pw, ph):
    status_bar(d, pw)
    d.text((44, 150), "cini", font=disp(54), fill=MARQUEE)
    d.rounded_rectangle([44,248,pw-44,320], radius=20, fill=FILL)
    d.ellipse([66,268,98,300], outline=GRAY, width=4)
    d.text((118,266), "Search movies, shows, friends", font=sa(28), fill=GRAY)
    d.text((44, 366), "TONIGHT'S PICK", font=sb(28), fill=MARQUEE)
    by=420; bw=pw-88; bh=540
    poster(d, 44, by, bw, bh, query="Dune: Part Two", year=2024)
    d.text((44, by+bh+22), "Dune: Part Two", font=sf(48), fill=INK)
    d.rounded_rectangle([44, by+bh+100, 198, by+bh+148], radius=24, fill=SURF2)
    d.text((60, by+bh+108), "ON NETFLIX", font=sb(20), fill=GRAY)
    d.text((222, by+bh+104), "We think you'll love it", font=sa(28), fill=GRAY)
    ty=by+bh+200
    d.text((44, ty), "Trending now", font=sf(40), fill=INK)
    titles=[("Anora",2024),("The Brutalist",2024),("Conclave",2024),("Sinners",2025)]
    pwid=240; gap=24; x=44; py=ty+70
    for t,yr in titles:
        poster(d, x, py, pwid, pwid*3//2, query=t, year=yr); x += pwid+gap

# 2 — RANK (ranked list: top movies + your own scores)
def s_rank(d, pw, ph):
    status_bar(d, pw)
    d.text((44, 150), "Your Lists", font=sf(60), fill=INK)
    segs=["Watched","Want to Watch","Recs"]; sy=250; sx=44; sw=pw-88
    d.rounded_rectangle([sx,sy,sx+sw,sy+74], radius=37, fill=FILL)
    seg_w=sw/3
    for i,s in enumerate(segs):
        if i==0: d.rounded_rectangle([sx+5,sy+5,sx+seg_w-3,sy+69], radius=32, fill=SURF)
        f=sa(27); w=d.textlength(s,font=f); d.text((sx+seg_w*i+seg_w/2-w/2, sy+22), s, font=f, fill=INK if i==0 else GRAY)
    fy=sy+100; x=44
    x=chip(d,x,fy,"Movies",active=True); x=chip(d,x,fy,"TV")
    x=chip(d,x,fy,"Genre"); x=chip(d,x,fy,"Decade")
    titles=[("Past Lives",2023,9.4),("Anatomy of a Fall",2023,8.9),("Oppenheimer",2023,8.6),
            ("The Holdovers",2023,8.2),("Poor Things",2023,7.6),("American Fiction",2023,7.4),
            ("Killers of the Flower Moon",2023,7.0),("Barbie",2023,6.8),("Saltburn",2023,6.2),
            ("Wonka",2023,5.4)]
    y=fy+92
    for i,(t,yr,sc) in enumerate(titles):
        d.rounded_rectangle([44,y,pw-44,y+150], radius=20, fill=SURF)
        d.text((74,y+52), f"{i+1}", font=sb(38), fill=GRAY)
        poster(d, 146, y+18, 86, 114, query=t, year=yr)
        for j,ln in enumerate(wrap(d, t, sf(34), pw-270-170)):
            d.text((262, y+26+j*40), ln, font=sf(34), fill=INK)
        d.text((262, y+108), str(yr), font=sa(24), fill=GRAY)
        score_badge(d, pw-118, y+75, sc)
        y+=166

# 3 — SHARE (social feed: friends ranking / saving)
def s_share(d, pw, ph):
    status_bar(d, pw)
    d.text((44, 150), "cini", font=disp(54), fill=MARQUEE)
    for k in range(3):
        bx=pw-220+k*70; d.ellipse([bx,164,bx+40,204], outline=GRAY, width=4)
    d.rounded_rectangle([44,250,pw-44,322], radius=20, fill=FILL)
    d.ellipse([66,270,98,302], outline=GRAY, width=4)
    d.text((118,268), "Search a movie, member, etc.", font=sa(28), fill=GRAY)
    x=chip(d,44,352,"Trending"); x=chip(d,x,352,"Friend Recs")
    cards=[("MAYA","ranked","Dune: Part Two",2024,8.7),("PRIYA","ranked","Anora",2024,9.1),
           ("SAM","ranked","Oppenheimer",2023,8.4),("LEO","wants to watch","The Substance",2024,None)]
    y=450
    for name,act,title,yr,sc in cards:
        d.rounded_rectangle([44,y,pw-44,y+360], radius=22, fill=SURF)
        d.ellipse([74,y+30,150,y+106], fill=SURF2)
        d.text((86,y+46), name[0], font=disp(42), fill=MARQUEE)
        d.text((170,y+40), f"@{name.lower()}", font=sb(30), fill=INK)
        d.text((170,y+86), act, font=sa(26), fill=GRAY)
        poster(d, 74, y+140, 150, 200, query=title, year=yr)
        for j,ln in enumerate(wrap(d, title, sf(40), pw-460)):
            d.text((254, y+170+j*48), ln, font=sf(40), fill=INK)
        if sc is not None: score_badge(d, pw-150, y+220, sc, r=50)
        y+=386

# 4 — SAVE (Want to Watch, sorted by Rec Score)
def s_save(d, pw, ph):
    status_bar(d, pw)
    d.text((44, 150), "Want to Watch", font=sf(56), fill=INK)
    d.text((44, 232), "for movie night, date night & later", font=sa(30), fill=GRAY)
    titles=[("Sinners",2025,9.2),("The Brutalist",2024,8.9),("Anora",2024,8.5),("Conclave",2024,8.3),
            ("Dune: Part Two",2024,8.0),("Challengers",2024,7.9),("A Real Pain",2024,7.8),
            ("The Substance",2024,7.5),("Nosferatu",2024,7.1),("Wicked",2024,6.4)]
    y=320
    for t,yr,sc in titles:
        d.rounded_rectangle([44,y,pw-44,y+150], radius=20, fill=SURF)
        poster(d, 64, y+18, 86, 114, query=t, year=yr)
        for j,ln in enumerate(wrap(d, t, sf(34), pw-220-300)):
            d.text((176, y+26+j*40), ln, font=sf(34), fill=INK)
        d.text((176, y+108), str(yr), font=sa(24), fill=GRAY)
        d.rounded_rectangle([pw-310, y+50, pw-150, y+104], radius=27, fill=SURF2)
        d.text((pw-292, y+62), "REC", font=sb(22), fill=GRAY)
        score_badge(d, pw-118, y+77, sc, r=42)
        y+=164

# 5 — LOG (the head-to-head logging flow)
def s_log(d, pw, ph):
    status_bar(d, pw)
    cx=pw//2
    ctext(d, cx, 220, "Which did you", sf(66), INK)
    ctext(d, cx, 304, "like more?", sf(66), INK)
    pwid=460; px=70; py=520
    poster(d, px, py, pwid, pwid*3//2, query="Whiplash", year=2014)
    poster(d, pw-px-pwid, py, pwid, pwid*3//2, query="Interstellar", year=2014)
    cyc=py+pwid*3//4
    d.ellipse([cx-62, cyc-62, cx+62, cyc+62], fill=VELVET)
    vt="VS"; f=sb(46); w=d.textlength(vt,font=f); d.text((cx-w/2, cyc-30), vt, font=f, fill="#fff")
    for k,c in enumerate([LOVE,FINE,DIS]):
        bx=cx-170+k*170; by=py+pwid*3//2+110
        d.ellipse([bx-38,by,bx+38,by+76], fill=c)
    ctext(d, cx, py+pwid*3//2+240, "A few quick taps — no scores to overthink.", sa(30), GRAY)

# 6 — RECS (Ask Cini: a personalized recommendation)
def s_recs(d, pw, ph):
    status_bar(d, pw)
    d.text((44, 150), "Ask Cini", font=sf(58), fill=INK)
    d.text((44, 234), "your personal movie concierge", font=sa(30), fill=GRAY)
    q="What should I watch tonight?"
    qf=sa(30); qw=d.textlength(q,font=qf); bw=qw+56; bx=pw-44-bw; by=326
    d.rounded_rectangle([bx,by,bx+bw,by+74], radius=30, fill=MARQUEE)
    d.text((bx+28,by+18), q, font=qf, fill=(19,16,17))
    cy=by+126
    d.rounded_rectangle([44,cy,pw-44,cy+520], radius=24, fill=SURF)
    d.text((76,cy+34), "Based on your taste, watch:", font=sa(28), fill=GRAY)
    poster(d, 76, cy+96, 230, 330, query="Past Lives", year=2023)
    d.text((338, cy+104), "Past Lives", font=sf(46), fill=INK)
    d.text((338, cy+168), "2023 · Drama", font=sa(26), fill=GRAY)
    score_badge(d, pw-128, cy+150, 9.4, r=54)
    for j,ln in enumerate(wrap(d, "Because you loved Whiplash and Aftersun — quiet, aching, beautifully restrained.", sa(28), pw-338-70)):
        d.text((338, cy+236+j*40), ln, font=sa(28), fill=INK)
    x=76; fy=cy+452
    x=chip(d,x,fy,"Something lighter"); x=chip(d,x,fy,"Shorter")

SHOTS = [
    ("01-discover", "Discover", "Find what to watch tonight from your taste, friends, and what's trending", s_discover, "gold"),
    ("02-rank",     "Rank",     "Rate movies and build a taste profile that gets smarter", s_rank, "velvet"),
    ("03-share",    "Share",    "See what friends are watching, saving, and recommending", s_share, "plum"),
    ("04-save",     "Save",     "Build a watchlist for movie night, date night, and later", s_save, "bronze"),
    ("05-log",      "Log",      "Keep track of what you watched and what you loved", s_log, "ember"),
    ("06-recs",     "Recs",     "Get better picks the more you rank, save, and watch", s_recs, "gold"),
]

def render_all(device):
    global W, H, DEVICE, ISLAND, BASE
    DEVICE = device
    if device == "iphone":
        W, H, ISLAND = 1284, 2778, True       # 6.5"/6.7" iPhone (App Store size)
    else:
        W, H, ISLAND = 2048, 2732, False      # 12.9" iPad
    out = os.path.join(OUT, device)
    os.makedirs(out, exist_ok=True)
    for name, headline, sub, fn, accent in SHOTS:
        BASE = bg(accent)
        d = ImageDraw.Draw(BASE)
        ph_top = caption(d, headline, sub) + int(40 * W / 1290)
        phone(int(ph_top), fn)
        BASE.save(os.path.join(out, f"{name}.png"))
        print(device, "saved", name)

for dev in ("iphone", "ipad"):
    render_all(dev)
print("DONE")
