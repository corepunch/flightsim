"""Build an offline, filterable reference sheet from native SpriteKit renders."""
import html
import json
import sys
from pathlib import Path


def build(output):
    entries = json.loads((output / 'manifest.json').read_text())
    devices = list(dict.fromkeys(e['device'] for e in entries))
    categories = list(dict.fromkeys(e['category'] for e in entries))
    locales = list(dict.fromkeys(e.get('locale', 'en') for e in entries))
    cards = []
    for e in entries:
        title = f"{e.get('locale', 'en')} / {e['device']} / {e['name']}"
        cards.append(f'''<figure data-locale="{e.get('locale', 'en')}" data-device="{e['device']}" data-category="{e['category']}" data-family="{e['family']}" data-name="{e['name']}">
<a href="{e['file']}" target="_blank"><img loading="lazy" src="{e['file']}" width="{e['width']}" height="{e['height']}" alt="{html.escape(title)}"></a>
<figcaption><strong>{html.escape(e['name'].replace('-', ' '))}</strong><span>{e.get('locale', 'en')} · {e['device']} · {e['width']} × {e['height']} pt</span></figcaption></figure>''')
    def options(values):
        return ''.join(f'<option>{html.escape(v)}</option>' for v in values)
    page = '''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Kestrel Frontier — UI reference</title><style>
:root{color-scheme:dark;font:16px/1.5 system-ui;background:#0c121b;color:#e1f5f0}body{margin:0}header{padding:32px 32px 16px;max-width:1100px}h1{font-size:28px;margin:0 0 8px}p{margin:8px 0;color:#b8cac8}nav{position:sticky;top:0;z-index:2;background:#111d27ee;backdrop-filter:blur(8px);padding:16px 32px;display:flex;gap:16px;align-items:end;flex-wrap:wrap;border-block:1px solid #324a4c}label{display:grid;gap:4px;font-size:13px}select,input,button{font:inherit;color:inherit;background:#172a36;border:1px solid #597878;border-radius:6px;padding:8px}input{min-width:180px}#count{margin-left:auto}main{padding:24px;display:grid;grid-template-columns:repeat(auto-fit,minmax(min(440px,100%),1fr));gap:24px;align-items:start}figure{margin:0;border:1px solid #324a4c;background:#101a24;border-radius:8px;overflow:hidden}img{display:block;width:100%;height:auto;background:#03090d}figcaption{padding:12px 16px;display:grid}figcaption span{color:#9cb4b2;font-size:13px}figure[hidden]{display:none}body.actual main{display:block;overflow:auto}body.actual figure{width:max-content;margin-bottom:24px}body.actual img{width:auto;max-width:none}body.actual figcaption{position:sticky;left:0;width:max-content}a{color:#b3eddc}aside{padding:0 32px 16px;color:#a5bfbb;font-size:14px}@media print{nav{position:static}main{grid-template-columns:1fr 1fr}figure{break-inside:avoid}header{padding:16px}body{background:white}}
</style><header><h1>Kestrel Frontier · UI reference</h1><p>Real engine controls, rendered without a game session. Open an image for full size, or choose Actual size to judge type and spacing at one scene point per pixel.</p><p>11 configurations cover small and notched iPhones, iPad landscape and window layouts, plus desktop, narrow and ultrawide windows. iPad portrait is an extra layout stress case; the shipped iOS app supports landscape.</p><p>These are shared SpriteKit fixtures rendered on macOS, including the same flight-control artwork used by UIKit. They do not simulate a device compositor, Retina scaling, or physical touch input.</p></header><nav>
<label>Language<select id="locale"><option>All</option>LOCALES</select></label>
<label>Family<select id="family"><option>All</option><option>iPhone</option><option>iPad</option><option>Desktop</option></select></label>
<label>Configuration<select id="device"><option>All</option>DEVICES</select></label>
<label>Category<select id="category"><option>All</option>CATEGORIES</select></label>
<label>Find control<input id="search" placeholder="bar, pause, settings…"></label><button id="size">Actual size</button><button onclick="print()">Print sheet</button><span id="count"></span></nav>
<aside>Normal, selected, hover and disabled button states; back/title/action bars; information rails; choice/action/slider settings at minimum, midpoint and maximum; every pause selection in local/online and chase/cockpit modes; menu states; mission grid and all three star ratings, conversation, map, success/failure/overflow reports; loading; LAN states; HUD, help and touch controls; cockpit target, ship, power and status displays in normal, warning and destroyed states. Hover applies the production hover transition. Pressed applies to touch controls, which implement it.</aside>
<main>CARDS</main><script>
const cards=[...document.querySelectorAll('figure')];
function update(){const locale=document.querySelector('#locale').value,family=document.querySelector('#family').value,device=document.querySelector('#device').value,category=document.querySelector('#category').value,q=document.querySelector('#search').value.toLowerCase();let count=0;for(const c of cards){c.hidden=!(locale==='All'||c.dataset.locale===locale)||!(family==='All'||c.dataset.family===family)||!(device==='All'||c.dataset.device===device)||!(category==='All'||c.dataset.category===category)||!c.dataset.name.includes(q);if(!c.hidden)count++}document.querySelector('#count').textContent=count+' / '+cards.length+' renders';location.hash=new URLSearchParams({locale,family,device,category,q})}
for(const id of ['locale','family','device','category','search'])document.getElementById(id).addEventListener('input',update);
document.querySelector('#size').onclick=()=>{document.body.classList.toggle('actual');document.querySelector('#size').textContent=document.body.classList.contains('actual')?'Fit sheet':'Actual size'};
const params=new URLSearchParams(location.hash.slice(1));for(const id of ['locale','family','device','category'])if(params.has(id))document.getElementById(id).value=params.get(id);document.querySelector('#search').value=params.get('q')||'';update();
</script></html>'''.replace('LOCALES', options(locales)).replace('DEVICES', options(devices)).replace('CATEGORIES', options(categories)).replace('CARDS', '\n'.join(cards))
    if len(locales) > 1 or 'locale' in entries[0]:
        page = page.replace('Kestrel Frontier · UI reference', 'Kestrel Frontier · Localized UI reference')
        start, end = page.index('<aside>'), page.index('</aside>') + len('</aside>')
        page = page[:start] + '<aside>Localized menus, pause actions, flight settings, information bars, flight HUD and help. The native renderer checks glyph fallback and text containment at every configuration. Choose a language and inspect at actual size. Campaign story dialogue is outside this interface translation pass.</aside>' + page[end:]
    (output / 'index.html').write_text(page)
    # Small overview sheets supplement full-resolution references without duplicating them.
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        return
    for family in ('iPhone', 'iPad', 'Desktop'):
        selected = [e for e in entries if e['family'] == family and e['category'] == 'controls']
        if not selected:
            continue
        cell_w, cell_h, cols = 600, 660, 3
        sheet = Image.new('RGB', (cols * cell_w, 56 + ((len(selected) + cols - 1) // cols) * cell_h), '#101823')
        draw = ImageDraw.Draw(sheet)
        draw.text((16, 16), f'{family} / shared controls — open index.html for full-size inspection', fill='#c5efdc')
        for i, e in enumerate(selected):
            x, y = i % cols * cell_w + 12, 56 + i // cols * cell_h
            draw.text((x, y), f"{e['device']} / {e['name']}", fill='#ffc76e')
            with Image.open(output / e['file']) as image:
                image.thumbnail((cell_w - 24, cell_h - 42))
                sheet.paste(image, (x, y + 24))
        sheet.save(output / f'{family.lower()}-controls.jpg', quality=90)


if __name__ == '__main__':
    build(Path(sys.argv[1]))
