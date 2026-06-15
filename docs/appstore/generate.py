#!/usr/bin/env python3
"""Branded App Store screenshots (6.7" = 1290x2796) matching Cini's marquee
icon: glowing marquee-gold on house-lights-down black, marquee-bulb trim, the
REAL brand faces (Limelight wordmark + DM Serif Display headlines), and REAL
movie posters fetched from TMDB. Marketing frames = headline + phone mockup."""
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import os, json, urllib.request, urllib.parse

# Device + canvas are set per pass in render_all(); these are defaults.
W, H = 1290, 2796
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
    "velvet": (0x3a, 0x16, 0x12),
    "gold":   (0x39, 0x2b, 0x10),
    "plum":   (0x2c, 0x16, 0x30),
    "bronze": (0x33, 0x24, 0x12),
    "ember":  (0x3a, 0x1d, 0x10),
}
def bg(accent="gold"):
    top = BACKDROPS.get(accent, BACKDROPS["gold"])
    base = (0x13, 0x10, 0x11)
    img = Image.new("RGB",(W,H))
    d = ImageDraw.Draw(img)
    for y in range(H):
        t = min(y/(H*0.62), 1.0)        # fade the tint out by ~60% down
        r=int(top[0]+(base[0]-top[0])*t); g=int(top[1]+(base[1]-top[1])*t); b=int(top[2]+(base[2]-top[2])*t)
        d.line([(0,y),(W,y)], fill=(r,g,b))
    # soft marquee-gold glow up top, the brand signature
    glow = Image.new("RGBA",(W,H),(0,0,0,0))
    ImageDraw.Draw(glow).ellipse([W/2-620,-420,W/2+620,460], fill=(232,182,76,40))
    glow=glow.filter(ImageFilter.GaussianBlur(150))
    img.paste(Image.alpha_composite(img.convert("RGBA"),glow).convert("RGB"),(0,0))
    return img

def bulbs(d, y, n=17):
    span=W-150; step=span/(n-1)
    for i in range(n):
        x=75+step*i
        d.ellipse([x-7,y-7,x+7,y+7], fill=MARQUEE)
        d.ellipse([x-3,y-3,x+3,y+3], fill="#fff7e0")

def caption(d, headline, sub):
    # Clean one-word header (no marquee bulbs — they read as clutter); scales
    # with the canvas so iPad headers stay proportional.
    k = W / 1290
    y = int(150 * k)
    hf = sf(int(96 * k))
    for ln in wrap(d, headline, hf, W - int(150 * k)):
        ctext(d, W/2, y, ln, hf, INK); y += int(110 * k)
    y += int(12 * k)
    sfont = sa(int(40 * k))
    for ln in wrap(d, sub, sfont, W - int(200 * k)):
        ctext(d, W/2, y, ln, sfont, GRAY); y += int(54 * k)
    return y

SCREEN = None  # set by phone(); poster() pastes onto this
def phone(top, draw_screen):
    """Big, close device cropped at the bottom (Beli-style), gold marquee frame.
    The screen content is drawn on a 1180-wide logical canvas and resized to the
    device width, so the same draw code renders sharp on both iPhone and iPad."""
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
    # marquee-gold frame echoing the app icon's border
    d.rounded_rectangle([x0-16,y0-16,x0+pw+16,y0+ph], radius=corner+16, outline=MARQUEE, width=7)
    # Render the screen on a 1180-wide logical canvas, then scale to device width.
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

SHOTS=[]

def status_bar(d, pw):
    # Dynamic Island — iPhone only (iPad has no island).
    if ISLAND:
        iw=300; ih=78; ix=(pw-iw)//2; iy=30
        d.rounded_rectangle([ix,iy,ix+iw,iy+ih], radius=39, fill="#000000")
    # time (left)
    d.text((58, 40), "9:41", font=sb(38), fill=INK)
    # right cluster: signal bars, wifi fan, battery
    for i in range(4):
        h=16+i*10; d.rounded_rectangle([pw-260+i*18, 76-h, pw-249+i*18, 76], radius=2, fill=INK)
    wx=pw-176
    d.pieslice([wx, 40, wx+56, 96], 212, 328, fill=INK)
    bx=pw-96
    d.rounded_rectangle([bx, 44, bx+58, 78], radius=8, outline=INK, width=3)
    d.rounded_rectangle([bx+5, 49, bx+44, 73], radius=4, fill=INK)
    d.rounded_rectangle([bx+58, 54, bx+66, 68], radius=3, fill=INK)

def tabbar(d, pw, ph, active=0):
    bh=164; y=ph-bh
    d.rectangle([0,y,pw,ph], fill=(15,13,14))
    d.line([(0,y),(pw,y)], fill="#241f20", width=2)
    labels=["Feed","Your Lists","Search","Leaderboard","Profile"]
    step=pw/5
    for i,lbl in enumerate(labels):
        cx=step*i+step/2; iy=y+46; col=MARQUEE if i==active else GRAY
        if i==0:
            for k in range(3): d.rounded_rectangle([cx-22,iy-16+k*13,cx+22,iy-9+k*13],radius=3,fill=col)
        elif i==1:
            for k in range(3):
                d.ellipse([cx-24,iy-16+k*13,cx-15,iy-7+k*13],fill=col)
                d.rounded_rectangle([cx-8,iy-15+k*13,cx+24,iy-9+k*13],radius=2,fill=col)
        elif i==2:
            d.ellipse([cx-22,iy-20,cx+6,iy+8],outline=col,width=5); d.line([cx+3,iy+5,cx+20,iy+22],fill=col,width=6)
        elif i==3:
            d.rounded_rectangle([cx-18,iy-20,cx+18,iy+2],radius=9,fill=col)
            d.rectangle([cx-6,iy+2,cx+6,iy+14],fill=col); d.rectangle([cx-18,iy+14,cx+18,iy+22],fill=col)
        else:
            d.ellipse([cx-11,iy-22,cx+11,iy],fill=col); d.ellipse([cx-22,iy-2,cx+22,iy+26],fill=col)
        f=sa(20); w=d.textlength(lbl,font=f); d.text((cx-w/2,y+100),lbl,font=f,fill=col)

def chip(d, x, y, text, active=False):
    f=sa(26); w=d.textlength(text,font=f); cw=w+44; ch=58
    if active:
        d.rounded_rectangle([x,y,x+cw,y+ch],radius=29,fill=MARQUEE)
        d.text((x+22,y+14),text,font=f,fill=(19,16,17))
    else:
        d.rounded_rectangle([x,y,x+cw,y+ch],radius=29,outline="#3a3335",width=2)
        d.text((x+22,y+14),text,font=f,fill=GRAY)
    return x+cw+14

# 1 — HERO (brand intro)
def s_hero(d, pw, ph):
    status_bar(d, pw)
    cx=pw//2
    f=disp(176); t="CINI"; w=d.textlength(t,font=f)
    d.text((cx-w/2, 520), t, font=f, fill=MARQUEE)
    ctext(d, cx, 740, "EVERY FILM · RANKED", sb(36), GRAY, track=12)
    ctext(d, cx, 1000, "Rank everything you watch", sf(50), INK)
    ctext(d, cx, 1072, "through quick head-to-head taps.", sf(50), INK)
    for k,(c,lbl) in enumerate([(LOVE,"Liked it"),(FINE,"It was fine"),(DIS,"Didn't")]):
        bx=cx-320+k*320
        d.ellipse([bx-66,1360,bx+66,1492], fill=c)
        ww=d.textlength(lbl,font=sa(30)); d.text((bx-ww/2, 1520), lbl, font=sa(30), fill=GRAY)
# (brand-only hero dropped — every screenshot now shows the product.)

# 2 — COMPARE (the ranking modal)
def s_compare(d, pw, ph):
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
SHOTS.append(("01-rank", "Rank", "No star ratings — answer one question and Cini orders everything you've seen.", s_compare, "velvet"))

# 3 — YOUR LISTS (segmented tabs + filter chips + ranked rows)
def s_list(d, pw, ph):
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
SHOTS.append(("02-taste", "Taste", "Every title scored out of 10 — by you, not strangers.", s_list, "bronze"))

# 4 — FEED (cini header, search, pills, friend cards)
def s_feed(d, pw, ph):
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
SHOTS.append(("03-friends", "Friends", "See what friends scored before you spend a night on it.", s_feed, "plum"))

# 5 — WANT TO WATCH, sorted by Rec Score
def s_recs(d, pw, ph):
    status_bar(d, pw)
    d.text((44, 150), "Want to Watch", font=sf(56), fill=INK)
    d.text((44, 232), "sorted by what you'll love", font=sa(30), fill=GRAY)
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
SHOTS.append(("04-discover", "Discover", "Rec Scores predict how much you'll like what you haven't seen.", s_recs, "ember"))

def render_all(device):
    global W, H, DEVICE, ISLAND, BASE
    DEVICE = device
    if device == "iphone":
        W, H, ISLAND = 1284, 2778, True       # 6.7" iPhone (App Store size)
    else:
        W, H, ISLAND = 2048, 2732, False      # 12.9" iPad
    out = os.path.join(OUT, device)
    os.makedirs(out, exist_ok=True)
    for name, headline, sub, fn, accent in SHOTS:
        BASE = bg(accent)
        d = ImageDraw.Draw(BASE)
        ph_top = caption(d, headline, sub) + int(34 * W / 1290)
        phone(int(ph_top), fn)
        BASE.save(os.path.join(out, f"{name}.png"))
        print(device, "saved", name)

for dev in ("iphone", "ipad"):
    render_all(dev)
print("DONE")
