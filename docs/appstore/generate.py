#!/usr/bin/env python3
"""Branded App Store screenshots (6.7" = 1290x2796) matching Cini's marquee
icon: glowing marquee-gold on house-lights-down black, marquee-bulb trim, the
REAL brand faces (Limelight wordmark + DM Serif Display headlines), and REAL
movie posters fetched from TMDB. Marketing frames = headline + phone mockup."""
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import os, json, urllib.request, urllib.parse

W, H = 1290, 2796
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
        fp = os.path.join(CACHE, path.lstrip("/"))
        if not os.path.exists(fp):
            urllib.request.urlretrieve(f"https://image.tmdb.org/t/p/w500{path}", fp)
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
    bulbs(d, 86)              # marquee trim across the very top
    y=160
    for ln in wrap(d, headline, sf(86), W-150):
        ctext(d, W/2, y, ln, sf(86), INK); y+=100
    y+=14
    for ln in wrap(d, sub, sa(40), W-200):
        ctext(d, W/2, y, ln, sa(40), GRAY); y+=54
    return y

SCREEN = None  # set by phone(); poster() pastes onto this
def phone(top, draw_screen):
    """Large clean phone — black bezel + soft shadow, no ornamental rim."""
    global SCREEN
    pw, ph = 1020, 2796-top-110
    x0=(W-pw)//2; y0=top
    sh=Image.new("RGBA",(W,H),(0,0,0,0))
    ImageDraw.Draw(sh).rounded_rectangle([x0-14,y0+14,x0+pw+14,y0+ph+34], radius=96, fill=(0,0,0,160))
    sh=sh.filter(ImageFilter.GaussianBlur(46))
    BASE.paste(Image.alpha_composite(BASE.convert("RGBA"),sh).convert("RGB"),(0,0))
    d=ImageDraw.Draw(BASE)
    d.rounded_rectangle([x0-14,y0-14,x0+pw+14,y0+ph+14], radius=90, fill="#0a0809")
    # marquee-gold frame echoing the app icon's border
    d.rounded_rectangle([x0-14,y0-14,x0+pw+14,y0+ph+14], radius=90, outline=MARQUEE, width=5)
    screen=Image.new("RGB",(pw,ph),BG); SCREEN=screen
    sd=ImageDraw.Draw(screen)
    draw_screen(sd, pw, ph)
    mask=Image.new("L",(pw,ph),0)
    ImageDraw.Draw(mask).rounded_rectangle([0,0,pw-1,ph-1], radius=76, fill=255)
    BASE.paste(screen,(x0,y0),mask)
    d.rounded_rectangle([x0,y0,x0+pw-1,y0+ph-1], radius=76, outline="#2a2526", width=2)

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
    d.text((40, 24), "9:41", font=sb(28), fill=INK)
    # signal + battery glyphs (simple)
    for i in range(4):
        h=10+i*8; d.rounded_rectangle([pw-150+i*18, 50-h, pw-138+i*18, 50], radius=2, fill=INK)
    d.rounded_rectangle([pw-78, 30, pw-40, 52], radius=5, outline=INK, width=2)
    d.rectangle([pw-74, 34, pw-50, 48], fill=INK)

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

# 1 — HERO (clean brand intro)
def s_hero(d, pw, ph):
    cx=pw//2
    f=disp(168); t="CINI"; w=d.textlength(t,font=f)
    d.text((cx-w/2, ph*0.30), t, font=f, fill=MARQUEE)
    ctext(d, cx, ph*0.30+200, "EVERY FILM · RANKED", sb(34), GRAY, track=12)
    ctext(d, cx, ph*0.52, "Rank everything you watch", sf(46), INK)
    ctext(d, cx, ph*0.52+70, "through quick head-to-head taps.", sf(46), INK)
    for k,(c,lbl) in enumerate([(LOVE,"Liked it"),(FINE,"It was fine"),(DIS,"Didn't")]):
        bx=cx-300+k*300
        d.ellipse([bx-60,ph*0.70,bx+60,ph*0.70+120], fill=c)
        ww=d.textlength(lbl,font=sa(28)); d.text((bx-ww/2, ph*0.70+150), lbl, font=sa(28), fill=GRAY)
SHOTS.append(("01-hero", "Every film, ranked.", "No star ratings — just your taste, in perfect order.", s_hero, "gold"))

# 2 — COMPARE (the ranking modal)
def s_compare(d, pw, ph):
    status_bar(d, pw)
    cx=pw//2
    ctext(d, cx, 200, "Which did you", sf(64), INK)
    ctext(d, cx, 280, "like more?", sf(64), INK)
    pwid=380; px=80; py=520
    poster(d, px, py, pwid, pwid*3//2, query="Whiplash", year=2014)
    poster(d, pw-px-pwid, py, pwid, pwid*3//2, query="Interstellar", year=2014)
    cyc=py+pwid*3//4
    d.ellipse([cx-56, cyc-56, cx+56, cyc+56], fill=VELVET)
    vt="VS"; f=sb(42); w=d.textlength(vt,font=f); d.text((cx-w/2, cyc-28), vt, font=f, fill="#fff")
    for k,c in enumerate([LOVE,FINE,DIS]):
        bx=cx-150+k*150; by=py+pwid*3//2+90
        d.ellipse([bx-32,by,bx+32,by+64], fill=c)
    ctext(d, cx, py+pwid*3//2+200, "A few quick taps — no scores to overthink.", sa(28), GRAY)
SHOTS.append(("02-no-star-ratings", "No star ratings. Ever.", "Answer one question and Cini orders everything you've seen.", s_compare, "velvet"))

# 3 — YOUR LISTS (current app: segmented tabs + filter chips + ranked rows)
def s_list(d, pw, ph):
    status_bar(d, pw)
    d.text((44, 80), "Your Lists", font=sf(58), fill=INK)
    segs=["Watched","Want to Watch","Recs"]; sy=180; sx=44; sw=pw-88
    d.rounded_rectangle([sx,sy,sx+sw,sy+74], radius=37, fill=FILL)
    seg_w=sw/3
    for i,s in enumerate(segs):
        if i==0: d.rounded_rectangle([sx+5,sy+5,sx+seg_w-3,sy+69], radius=32, fill=SURF)
        f=sa(27); w=d.textlength(s,font=f); d.text((sx+seg_w*i+seg_w/2-w/2, sy+22), s, font=f, fill=INK if i==0 else GRAY)
    fy=sy+102; x=44
    x=chip(d,x,fy,"Movies",active=True); x=chip(d,x,fy,"TV")
    x=chip(d,x,fy,"Genre"); x=chip(d,x,fy,"Decade")
    titles=[("Past Lives",2023,9.4),("Oppenheimer",2023,8.6),("Poor Things",2023,7.6),
            ("Killers of the Flower Moon",2023,7.0),("Saltburn",2023,6.2)]
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
    tabbar(d, pw, ph, active=1)
SHOTS.append(("03-ranked-list", "A list that's truly yours", "Every title scored out of 10 — by you, not strangers.", s_list, "bronze"))

# 4 — FEED (cini header, search, pills, friend cards)
def s_feed(d, pw, ph):
    status_bar(d, pw)
    d.text((44, 72), "cini", font=disp(52), fill=MARQUEE)
    for k in range(3):
        bx=pw-220+k*70; d.ellipse([bx,86,bx+40,126], outline=GRAY, width=4)
    d.rounded_rectangle([44,170,pw-44,242], radius=20, fill=FILL)
    d.ellipse([66,190,98,222], outline=GRAY, width=4)
    d.text((118,188), "Search a movie, member, etc.", font=sa(28), fill=GRAY)
    x=chip(d,44,270,"Trending"); x=chip(d,x,270,"Friend Recs")
    cards=[("MAYA","ranked","Dune: Part Two",2024,8.7),("PRIYA","ranked","Anora",2024,9.1)]
    y=370
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
    tabbar(d, pw, ph, active=0)
SHOTS.append(("04-friends", "Better with friends", "See what friends scored before you spend a night on it.", s_feed, "plum"))

# 5 — WANT TO WATCH, sorted by Rec Score
def s_recs(d, pw, ph):
    status_bar(d, pw)
    d.text((44, 80), "Want to Watch", font=sf(54), fill=INK)
    d.text((44, 158), "sorted by what you'll love", font=sa(30), fill=GRAY)
    titles=[("Sinners",2025,9.2),("The Brutalist",2024,8.9),("Conclave",2024,8.3),
            ("A Real Pain",2024,7.8),("Nosferatu",2024,7.1),("Wicked",2024,6.4)]
    y=240
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
    tabbar(d, pw, ph, active=1)
SHOTS.append(("05-rec-scores", "Recs that match your taste", "Rec Scores predict how much YOU'll like what you haven't seen.", s_recs, "ember"))

os.makedirs(OUT, exist_ok=True)
for name, headline, sub, fn, accent in SHOTS:
    BASE = bg(accent)
    d = ImageDraw.Draw(BASE)
    ph_top = caption(d, headline, sub) + 30
    phone(int(ph_top), fn)
    BASE.save(os.path.join(OUT, f"{name}.png"))
    print("saved", name)
print("DONE")
