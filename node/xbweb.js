// 小宝影院（ibaotv.com）数据层：分类列表 / 搜索 / 详情 / 取播放地址
// 用法：node xbweb.js list <tid> <page>
//       node xbweb.js search <关键词> <page>
//       node xbweb.js detail <vod_id>
//       node xbweb.js playurl <vod_id> <sid> <nid>
// 输出 JSON 到 stdout（失败输出 {"__error":"..."}）。纯 GET，无签名/无加密。
const SITE = process.env.IBAOTV_SITE || 'https://ibaotv.com';
const UA = 'Mozilla/5.0 (Linux; Android 10; Volla Phone Build/QP1A.191005.007) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.6099.144 Mobile Safari/537.36';

async function fetchText(url, timeout) {
  timeout = timeout || 25000;
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeout);
  try {
    const res = await fetch(url, {
      headers: {
        'User-Agent': UA,
        'Accept': 'text/html,application/xhtml+xml,application/json,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        'Referer': SITE + '/',
      },
      signal: ctrl.signal,
    });
    if (!res.ok) {
      const e = new Error('HTTP ' + res.status);
      e.status = res.status;
      throw e;
    }
    return await res.text();
  } finally { clearTimeout(t); }
}

function absUrl(u) {
  u = String(u || '').trim();
  if (!u) return '';
  if (/^https?:\/\//i.test(u)) return u;
  return SITE + (u.charAt(0) === '/' ? u : '/' + u);
}

function unesc(s) {
  return String(s || '')
    .replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#39;/g, "'")
    .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&nbsp;/g, ' ');
}

function stripTags(s) {
  return unesc(String(s || '').replace(/<[^>]+>/g, ' ')).replace(/\s+/g, ' ').trim();
}

function firstGroup(text, re) {
  const m = text.match(re);
  return m ? m[1] : '';
}

function normPages(html) {
  const pages = [...html.matchAll(/search\/page\/(\d+)\/wd\//g)].map((m) => parseInt(m[1], 10));
  return pages.length ? Math.max(...pages) : 1;
}

function cardFromJson(v) {
  return {
    sid: String(v.vod_id),
    title: unesc(v.vod_name || ''),
    cover: absUrl(v.vod_pic || ''),
    year: v.vod_year || '',
    cls: String(v.vod_class || '').replace(/,/g, ' / '),
    area: v.vod_area || '',
    remarks: v.vod_remarks || '',
  };
}

async function list(tid, page) {
  page = parseInt(page || '1', 10) || 1;
  const txt = await fetchText(`${SITE}/index.php/ajax/data?mid=1&tid=${encodeURIComponent(tid)}&page=${page}`);
  let d;
  try { d = JSON.parse(txt); } catch (_) { throw new Error('列表返回非 JSON'); }
  const pagecount = parseInt(d.pagecount, 10) || 1;
  return {
    page,
    pagecount,
    cards: page > pagecount ? [] : (d.list || []).map(cardFromJson),
  };
}

function parseSearch(html) {
  const i = html.indexOf('id="searchList"');
  let block = '';
  if (i >= 0) {
    const j = html.indexOf('</ul>', i);
    block = html.slice(i, j > i ? j : html.length);
  }
  const cards = [];
  const seen = new Set();
  for (const m of block.matchAll(/<li class="clearfix">([\s\S]*?)<\/li>/g)) {
    const li = m[1];
    const href = firstGroup(li, /href="(\/index\.php\/vod\/detail\/id\/\d+\.html)"/);
    const idm = href.match(/\/id\/(\d+)\.html/);
    if (!idm) continue;
    const sid = idm[1];
    if (seen.has(sid)) continue;
    seen.add(sid);
    const anchor = li.match(/<a class="myui-vodlist__thumb[^"]*"([^>]*)>/);
    const attrs = anchor ? anchor[1] : '';
    const title = stripTags(firstGroup(attrs, /title="([^"]*)"/)) || sid;
    const cover = absUrl(firstGroup(attrs, /data-original="([^"]*)"/));
    const head = li.slice(0, li.indexOf('</a>') + 4);
    cards.push({
      sid,
      title,
      cover,
      year: firstGroup(li, /年份：<\/span>([^<]*)</) || firstGroup(li, /<span class="tag"[^>]*>([^<]*)<\/span>/),
      cls: firstGroup(li, /分类：<\/span>([^<]*)</).replace(/,/g, ' / '),
      area: firstGroup(li, /地区：<\/span>([^<]*)</),
      remarks: firstGroup(head, /<span class="pic-text text-right">([^<]*)<\/span>/),
    });
  }
  return cards;
}

async function search(keyword, page) {
  page = parseInt(page || '1', 10) || 1;
  const wd = encodeURIComponent(String(keyword || ''));
  const url = page <= 1
    ? `${SITE}/index.php/vod/search.html?wd=${wd}`
    : `${SITE}/index.php/vod/search/page/${page}/wd/${wd}.html`;
  let html;
  try {
    html = await fetchText(url);
  } catch (e) {
    if (e && e.status === 404) return { page, pagecount: page, cards: [] };
    throw e;
  }
  return { page, pagecount: normPages(html), cards: parseSearch(html) };
}

function detailField(seg, name) {
  const re = new RegExp(name + '：\\s*</span>([\\s\\S]*?)(?=<span class="text-muted|</p>|<br|</li>|$)');
  return stripTags(firstGroup(seg, re));
}

function parseEpisodes(html) {
  const groups = [];
  for (const pm of html.matchAll(/<div id="playlist(\d+)"[\s\S]*?<ul class="myui-content__list[\s\S]*?<\/ul>/g)) {
    const sid = pm[1];
    const eps = [];
    for (const am of pm[0].matchAll(/<a[^>]+href="[^"]*\/vod\/play\/id\/\d+\/sid\/\d+\/nid\/(\d+)\.html"[^>]*>([\s\S]*?)<\/a>/g)) {
      eps.push({ nid: am[1], label: stripTags(am[2]) });
    }
    if (eps.length) groups.push({ sid, episodes: eps });
  }
  if (!groups.length) {
    const eps = [];
    for (const am of html.matchAll(/href="[^"]*\/vod\/play\/id\/\d+\/sid\/(\d+)\/nid\/(\d+)\.html"[^>]*>([\s\S]*?)<\/a>/g)) {
      const label = stripTags(am[3]);
      if (!label || /立即播放/.test(label)) continue;
      eps.push({ nid: am[2], label });
    }
    if (eps.length) groups.push({ sid: '1', episodes: eps });
  }
  groups.sort((a, b) => b.episodes.length - a.episodes.length);
  const best = groups[0] || { sid: '1', episodes: [] };
  const seen = new Set();
  const episodes = [];
  for (const e of best.episodes) {
    if (seen.has(e.nid)) continue;
    seen.add(e.nid);
    episodes.push({
      nid: e.nid,
      sid: best.sid,
      index: episodes.length + 1,
      label: e.label || ('第' + (episodes.length + 1) + '集'),
    });
  }
  return { sid: best.sid, sources: groups.length, episodes };
}

async function detail(id) {
  const html = await fetchText(`${SITE}/index.php/vod/detail/id/${encodeURIComponent(id)}.html`);
  const di = html.indexOf('myui-content__detail');
  const seg = di >= 0 ? html.slice(di, di + 6000) : '';
  let title = stripTags(firstGroup(html, /<h1[^>]*>([\s\S]*?)<\/h1>/));
  if (!title) title = stripTags(firstGroup(html, /<meta[^>]+property="og:title"[^>]+content="([^"]*)"/));
  if (!title) throw new Error('未找到影片标题');
  const cover = absUrl(
    firstGroup(html, /<meta[^>]+property="og:image"[^>]+content="([^"]*)"/)
    || firstGroup(seg, /data-original="([^"]*)"/)
  );
  let intro = stripTags(firstGroup(html, /<span class="sketch content">([\s\S]*?)<\/span>/));
  if (!intro) intro = detailField(seg, '简介');
  const meta = {
    cls: detailField(seg, '分类'),
    area: detailField(seg, '地区'),
    year: detailField(seg, '年份'),
    updated: detailField(seg, '更新'),
    actor: detailField(seg, '主演'),
    director: detailField(seg, '导演'),
  };
  const { sid, sources, episodes } = parseEpisodes(html);
  return {
    sid: String(id),
    title,
    cover,
    intro,
    cls: meta.cls,
    area: meta.area,
    year: meta.year,
    updated: meta.updated,
    actor: meta.actor,
    director: meta.director,
    total: episodes.length,
    sources,
    playSid: sid,
    episodes,
  };
}

async function playUrl(id, sid, nid) {
  sid = sid || '1';
  const html = await fetchText(`${SITE}/index.php/vod/play/id/${encodeURIComponent(id)}/sid/${encodeURIComponent(sid)}/nid/${encodeURIComponent(nid)}.html`);
  const m = html.match(/player_aaaa\s*=\s*(\{[\s\S]*?\})\s*;?\s*<\/script>/);
  if (!m) throw new Error('播放页无播放地址');
  let j;
  try { j = JSON.parse(m[1]); } catch (_) { throw new Error('播放信息解析失败'); }
  if (j.encrypt && Number(j.encrypt) !== 0) throw new Error('播放源已加密，暂不支持');
  const url = String(j.url || '').replace(/\\\//g, '/');
  if (!url) throw new Error('播放地址为空');
  if (!/\.m3u8(\?|$)|\.mp4(\?|$)/i.test(url)) throw new Error('暂不支持该播放格式');
  return { url, from: j.from || '', sid: j.sid, nid: j.nid, encrypt: Number(j.encrypt) || 0 };
}

async function main() {
  const [cmd, arg, arg2, arg3] = process.argv.slice(2);
  try {
    if (cmd === 'list') console.log(JSON.stringify(await list(arg, arg2)));
    else if (cmd === 'search') console.log(JSON.stringify(await search(arg, arg2)));
    else if (cmd === 'detail') console.log(JSON.stringify(await detail(arg)));
    else if (cmd === 'playurl') console.log(JSON.stringify(await playUrl(arg, arg2, arg3)));
    else throw new Error('未知命令');
  } catch (e) {
    console.log(JSON.stringify({ __error: String((e && e.message) || e) }));
    process.exit(1);
  }
}

if (require.main === module) main();

module.exports = { fetchText, list, search, detail, playUrl, SITE, UA };
