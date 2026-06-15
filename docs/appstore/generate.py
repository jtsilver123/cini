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

def bg():
    img = Image.new("RGB",(W,H),BG)
    d = ImageDraw.Draw(img)
    for y in range(H):
        t=y/H
        r=int(0x13+ (0x24-0x13)*(1-t)*0.5); g=int(0x10+(0x1c-0x10)*(1-t)*0.5); b=int(0x11+(0x14-0x11)*(1-t)*0.5)
        d.line([(0,y),(W,y)], fill=(r,g,b))
    glow = Image.new("RGBA",(W,H),(0,0,0,0))
    gd=ImageDraw.Draw(glow)
    gd.ellipse([W/2-560, -380, W/2+560, 480], fill=(232,182,76,46))
    glow=glow.filter(ImageFilter.GaussianBlur(120))
    img.paste(Image.alpha_composite(img.convert("RGBA"),glow).convert("RGB"),(0,0))
    return img

def bulbs(d, y, n=17):
    span=W-150; step=span/(n-1)
    for i in range(n):
        x=75+step*i
        d.ellipse([x-7,y-7,x+7,y+7], fill=MARQUEE)
        d.ellipse([x-3,y-3,x+3,y+3], fill="#fff7e0")

def caption(d, headline, sub, hl_color=MARQUEE):
    y=150
    bulbs(d, 92)
    for ln in wrap(d, headline, sf(80), W-150):
        ctext(d, W/2, y, ln, sf(80), hl_color, glow=(232,182,76,70)); y+=94
    y+=16
    for ln in wrap(d, sub, sa(40), W-220):
        ctext(d, W/2, y, ln, sa(40), GRAY); y+=54
    return y

SCREEN = None  # set by phone(); poster() pastes onto this
def phone(top, draw_screen):
    global SCREEN
    pw, ph = 980, 2796-top-70
    x0=(W-pw)//2; y0=top
    sh=Image.new("RGBA",(W,H),(0,0,0,0))
    ImageDraw.Draw(sh).rounded_rectangle([x0-16,y0+10,x0+pw+16,y0+ph+30], radius=92, fill=(0,0,0,150))
    sh=sh.filter(ImageFilter.GaussianBlur(40))
    BASE.paste(Image.alpha_composite(BASE.convert("RGBA"),sh).convert("RGB"),(0,0))
    d=ImageDraw.Draw(BASE)
    d.rounded_rectangle([x0-16,y0-16,x0+pw+16,y0+ph+16], radius=86, fill="#000000")
    d.rounded_rectangle([x0-16,y0-16,x0+pw+16,y0+ph+16], radius=86, outline=MARQUEE, width=3)
    screen=Image.new("RGB",(pw,ph),BG); SCREEN=screen
    sd=ImageDraw.Draw(screen)
    draw_screen(sd, pw, ph)
    mask=Image.new("L",(pw,ph),0)
    ImageDraw.Draw(mask).rounded_rectangle([0,0,pw-1,ph-1], radius=72, fill=255)
    BASE.paste(screen,(x0,y0),mask)
    d.rounded_rectangle([x0,y0,x0+pw-1,y0+ph-1], radius=72, outline="#2a2526", width=3)

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

def s_hero(d, pw, ph):
    cx=pw//2
    d.rounded_rectangle([60,150,pw-60,ph-150], radius=40, outline=MARQUEE, width=4)
    for i in range(12):
        x=120+i*((pw-240)/11); d.ellipse([x-6,176,x+6,188],fill=MARQUEE)
        d.ellipse([x-6,ph-188,x+6,ph-176],fill=MARQUEE)
    f=disp(150); t="CINI"; w=d.textlength(t,font=f)
    d.text((cx-w/2, ph/2-300), t, font=f, fill=MARQUEE)
    ctext(d, cx, ph/2-90, "EVERY FILM · RANKED", sb(32), GRAY, track=10)
    for k,(c,lbl) in enumerate([(LOVE,"Liked it"),(FINE,"It was fine"),(DIS,"Didn't")]):
        bx=cx-300+k*300
        d.ellipse([bx-58,ph/2+80,bx+58,ph/2+196], fill=c)
        ww=d.textlength(lbl,font=sa(28)); d.text((bx-ww/2, ph/2+220), lbl, font=sa(28), fill=GRAY)
SHOTS.append(("01-hero", "Every film, ranked.", "No star ratings — just your taste, in perfect order.", s_hero, INK))

def s_compare(d, pw, ph):
    ctext(d, pw//2, 150, "Which did you", sf(60), INK)
    ctext(d, pw//2, 224, "like more?", sf(60), INK)
    pwid=360; px=70; py=440
    poster(d, px, py, pwid, pwid*3//2, query="Whiplash", year=2014)
    poster(d, pw-px-pwid, py, pwid, pwid*3//2, query="Interstellar", year=2014)
    d.ellipse([pw//2-52, py+pwid*3//4-52, pw//2+52, py+pwid*3//4+52], fill=VELVET)
    vt="VS"; f=sb(40); w=d.textlength(vt,font=f); d.text((pw//2-w/2, py+pwid*3//4-26), vt, font=f, fill="#fff")
    ctext(d, pw//2, py+pwid*3//2+70, "A few quick taps — no scores to overthink.", sa(28), GRAY)
SHOTS.append(("02-no-star-ratings", "No star ratings. Ever.", "Answer one question and Cini orders everything you've seen.", s_compare, MARQUEE))

def s_list(d, pw, ph):
    ctext(d, pw//2, 150, "Your ranked list", sf(56), INK)
    titles=[("Past Lives",2023,9.4),("The Zone of Interest",2023,8.8),("Oppenheimer",2023,8.1),
            ("Poor Things",2023,7.6),("Killers of the Flower Moon",2023,7.0),
            ("Saltburn",2023,6.2),("Wonka",2023,5.4)]
    y=300
    for i,(t,yr,sc) in enumerate(titles):
        d.rounded_rectangle([60,y,pw-60,y+150], radius=20, fill=SURF)
        d.text((92,y+54), f"{i+1}", font=sb(40), fill=GRAY)
        poster(d, 165, y+18, 86, 114, query=t, year=yr)
        for j,ln in enumerate(wrap(d, t, sf(36), pw-165-300)):
            d.text((280, y+30+j*42), ln, font=sf(36), fill=INK)
        score_badge(d, pw-130, y+75, sc)
        y+=172
SHOTS.append(("03-ranked-list", "A list that's truly yours", "Every title scored out of 10 — by you, not strangers.", s_list, MARQUEE))

def s_feed(d, pw, ph):
    ctext(d, pw//2, 150, "Better with friends", sf(56), INK)
    cards=[("MAYA","ranked","Dune: Part Two",2024,8.7),("LEO","wants to watch","The Substance",2024,None),
           ("PRIYA","ranked","Anora",2024,9.1)]
    y=300
    for name,act,title,yr,sc in cards:
        d.rounded_rectangle([60,y,pw-60,y+330], radius=22, fill=SURF)
        poster(d, 92, y+34, 130, 174, query=title, year=yr)
        d.text((250,y+44), f"@{name.lower()}", font=sb(30), fill=INK)
        d.text((250,y+90), f"{act}", font=sa(26), fill=GRAY)
        for j,ln in enumerate(wrap(d, title, sf(40), pw-460)):
            d.text((250, y+140+j*46), ln, font=sf(40), fill=INK)
        if sc is not None: score_badge(d, pw-150, y+96, sc, r=48)
        for k,ic in enumerate(["like","reply","share"]):
            d.text((250+k*150, y+256), ic, font=sa(26), fill=GRAY)
        y+=355
SHOTS.append(("04-friends", "Know before you commit", "See what friends scored before you spend the night on it.", s_feed, MARQUEE))

def s_recs(d, pw, ph):
    ctext(d, pw//2, 150, "Want to Watch", sf(56), INK)
    ctext(d, pw//2, 230, "sorted by what you'll love", sa(32), GRAY)
    titles=[("Sinners",2025,9.2),("The Brutalist",2024,8.9),("Conclave",2024,8.3),
            ("A Real Pain",2024,7.8),("Nosferatu",2024,7.1),("Wicked",2024,6.4)]
    y=340
    for t,yr,sc in titles:
        d.rounded_rectangle([60,y,pw-60,y+150], radius=20, fill=SURF)
        poster(d, 80, y+18, 86, 114, query=t, year=yr)
        for j,ln in enumerate(wrap(d, t, sf(36), pw-200-320)):
            d.text((196, y+30+j*42), ln, font=sf(36), fill=INK)
        d.rounded_rectangle([pw-300, y+48, pw-92, y+108], radius=30, fill=SURF2)
        d.text((pw-282, y+60), "Rec", font=sa(26), fill=GRAY)
        score_badge(d, pw-150, y+78, sc, r=40)
        y+=172
SHOTS.append(("05-rec-scores", "Recs that match your taste", "Rec Scores predict how much YOU'll like what you haven't seen.", s_recs, MARQUEE))

os.makedirs(OUT, exist_ok=True)
for name, headline, sub, fn, hl in SHOTS:
    BASE = bg()
    d = ImageDraw.Draw(BASE)
    ph_top = caption(d, headline, sub, hl) + 40
    phone(int(ph_top), fn)
    BASE.save(os.path.join(OUT, f"{name}.png"))
    print("saved", name)
print("DONE")
