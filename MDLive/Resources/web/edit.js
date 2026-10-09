/* MDLive in-place editing.
 *
 * The rendered document becomes contenteditable once the native side calls
 * enableEditing() (index.html). Saving never re-serialises the whole document:
 * every top-level block carries its source line range (data-src-start/end, from
 * markdown-it's token.map), the original Markdown is kept here, and on a real
 * change only the blocks whose DOM changed are turned back into Markdown and
 * spliced into the original text at their line ranges. Inside a changed block a
 * three-way line merge (original source / pristine block / edited block) keeps
 * the original bytes of every line the edit did not touch, so table padding,
 * list markers and footnote labels survive.
 *
 * Math (KaTeX), Mermaid diagrams and footnote references are atoms
 * (contenteditable=false) whose Markdown comes from their stored source.
 */
(function () {
  "use strict";
  var E = window.MDLiveEdit = { enabled: false };
  var S = null;            // per-render state
  var observer = null;
  var timer = null;
  var listening = false;

  // ---------- render-time stamping (markdown-it core rule) ----------
  E.installStamps = function (md) {
    md.core.ruler.push("mdlive_src", function (state) {
      var inFootnote = 0;
      state.tokens.forEach(function (t) {
        if (t.type === "footnote_open") inFootnote++;
        else if (t.type === "footnote_close") inFootnote--;
        if (t.block && t.map && t.nesting !== -1 && t.type !== "inline" &&
            ((t.level === 0 && !inFootnote) || (inFootnote && t.type === "paragraph_open"))) {
          t.attrSet("data-src-start", String(t.map[0]));
          t.attrSet("data-src-end", String(t.map[1]));
        }
        if (/^(bullet_list_open|ordered_list_open|fence|hr|heading_open)$/.test(t.type) && t.markup) t.attrSet("data-md", t.markup);
        if (t.type === "code_block") t.attrSet("data-md", "indent");
        if (t.type === "fence") t.attrSet("data-md-info", t.info || "");
        if (t.type === "inline" && t.children) t.children.forEach(function (c) {
          if (/^(strong_open|em_open|s_open|code_inline|link_open)$/.test(c.type) && c.markup) c.attrSet("data-md", c.markup);
        });
      });
    });
    var ref = md.renderer.rules.footnote_ref;
    if (ref) md.renderer.rules.footnote_ref = function (tokens, idx, options, env, slf) {
      var label = (tokens[idx].meta && tokens[idx].meta.label) || "";
      return ref(tokens, idx, options, env, slf).replace('<sup class="footnote-ref"',
        '<sup class="footnote-ref" contenteditable="false" data-md-label="' + md.utils.escapeHtml(label) + '"');
    };
  };

  // ---------- DOM -> Markdown ----------
  var BLOCK = /^(P|DIV|H[1-6]|UL|OL|LI|BLOCKQUOTE|TABLE|THEAD|TBODY|TR|PRE|HR|DL|DT|DD|SECTION)$/;
  function isBlock(n) { return n.nodeType === 1 && (BLOCK.test(n.tagName) || n.hasAttribute("data-mermaid-src")); }
  function attr(n, a) { return n.getAttribute ? n.getAttribute(a) : null; }

  // Escape only what would otherwise turn into markup. Text between $...$ is
  // left alone (math source, rendered or not), and a backslash is only doubled
  // where it would start an escape.
  function escText(t) {
    return t.replace(/\u00a0/g, " ").split(/(\$\$[\s\S]*?\$\$|\$[^$\n]+\$)/).map(function (part, i) {
      if (i % 2) return part;
      return part.replace(/\\(?=[!-\/:-@\[-`{-~])/g, "\\\\").replace(/([`*\[\]])/g, "\\$1")
        .replace(/(^|[^A-Za-z0-9])_|_(?=[^A-Za-z0-9]|$)/g, function (m) { return m.replace("_", "\\_"); });
    }).join("");
  }

  // Escape what would turn a paragraph line into another block type.
  function escLineStarts(s) {
    return s.split("\n").map(function (l) {
      return l.replace(/^(\s*)(#{1,6}(?=\s|$)|>|[-+](?=\s|$))/, "$1\\$2").replace(/^(\s*\d+)([.)])(?=\s|$)/, "$1\\$2");
    }).join("\n");
  }

  function texOf(k) {
    var a = k.querySelector('annotation[encoding="application/x-tex"]');
    return a ? a.textContent : k.textContent;
  }

  function inline(nodes) {
    var out = "";
    for (var i = 0; i < nodes.length; i++) out += inl(nodes[i], nodes, i);
    return out.indexOf("\u0001") < 0 ? out : out.replace(/[ \t]*\u0001[ \t]*/g, " ");
  }
  function kids(n) { return inline(n.childNodes); }
  function lastMeaningful(nodes, i) {
    for (var j = i + 1; j < nodes.length; j++) {
      var m = nodes[j];
      if (m.nodeType === 3 && !m.textContent.replace(/\s/g, "")) continue;
      return false;
    }
    return true;
  }
  function inl(n, siblings, i) {
    if (n.nodeType === 3) return escText(n.textContent);
    if (n.nodeType !== 1) return "";
    var tag = n.tagName, cl = n.classList, md = attr(n, "data-md");
    if (cl.contains("katex-display")) return "$$" + texOf(n) + "$$";
    if (cl.contains("katex")) return "$" + texOf(n) + "$";
    if (cl.contains("footnote-ref")) return "[^" + (attr(n, "data-md-label") || n.textContent.replace(/[\[\]]/g, "")) + "]";
    if (cl.contains("footnote-backref")) return "\u0001"; // dropped, with the space before it
    switch (tag) {
      case "BR": return lastMeaningful(siblings, i) ? "" : "\\\n";
      case "STRONG": case "B": var b = md || "**"; return wrap(b, kids(n));
      case "EM": case "I": var e = md || "*"; return wrap(e, kids(n));
      case "S": case "DEL": case "STRIKE": return wrap("~~", kids(n));
      case "CODE":
        var tx = n.textContent.replace(/ /g, " "), tk = md || "`";
        while (tx.indexOf(tk) >= 0) tk += "`";
        var pad = (/^`|`$/.test(tx) || (tx.charAt(0) === " " && tx.charAt(tx.length - 1) === " " && tx.trim())) ? " " : "";
        return tk + pad + tx + pad + tk;
      case "A":
        var href = attr(n, "href") || "", text = kids(n), title = attr(n, "title");
        if (md === "linkify" && n.textContent === text) return n.textContent;
        if (md === "autolink") return "<" + n.textContent + ">";
        return "[" + text + "](" + href + (title ? ' "' + title.replace(/"/g, '\\"') + '"' : "") + ")";
      case "IMG":
        var t2 = attr(n, "title");
        return "![" + (attr(n, "alt") || "").replace(/([\[\]])/g, "\\$1") + "](" + (attr(n, "data-src") || attr(n, "src") || "") +
          (t2 ? ' "' + t2.replace(/"/g, '\\"') + '"' : "") + ")";
      case "INPUT": case "BUTTON": case "SCRIPT": case "STYLE": return "";
      case "SPAN":
        var st = n.style, out = kids(n);
        if (st) {
          if (/line-through/.test(st.textDecoration || st.textDecorationLine || "")) out = wrap("~~", out);
          if (st.fontStyle === "italic") out = wrap("*", out);
          if (/^(bold|bolder|[6-9]00)$/.test(st.fontWeight || "")) out = wrap("**", out);
        }
        return out;
      default:
        if (isBlock(n)) return block(n);
        return kids(n);
    }
  }
  function wrap(m, s) {
    if (!s.trim()) return s;
    var lead = s.match(/^\s*/)[0], trail = s.match(/\s*$/)[0];
    return lead + m + s.trim() + m + trail;
  }
  function inlineBlock(n, leadEsc) {
    var s = kids(n).replace(/^\n+|\s+$/g, "");
    return leadEsc === false ? s : escLineStarts(s);
  }

  // A list of sibling nodes as blocks; runs of inline nodes become paragraphs.
  function blocks(nodes, sep) {
    var out = [], run = [];
    function flush() {
      if (!run.length) return;
      var s = escLineStarts(inline(run).replace(/^\s+|\s+$/g, ""));
      if (s) out.push(s);
      run = [];
    }
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i];
      if (n.nodeType === 1 && isBlock(n)) { flush(); var b = block(n); if (b) out.push(b); }
      else if (n.nodeType === 1 && /^(INPUT|BUTTON)$/.test(n.tagName)) continue;
      else run.push(n);
    }
    flush();
    return out.join(sep === undefined ? "\n\n" : sep);
  }

  function block(n) {
    var tag = n.tagName;
    if (n.hasAttribute("data-mermaid-src")) return fence("```", "mermaid", n.getAttribute("data-mermaid-src"));
    if (/^H[1-6]$/.test(tag)) {
      var lvl = +tag.charAt(1), md = attr(n, "data-md") || "", h = inlineBlock(n, false).replace(/\n/g, " ");
      if (md === "=" || md === "-") return h + "\n" + new Array(Math.max(3, h.length) + 1).join(md);
      return new Array(lvl + 1).join("#") + (h ? " " + h : "");
    }
    switch (tag) {
      case "P": case "DIV": case "SECTION": case "DT":
        // WebKit can leave a list (or another block) inside a paragraph.
        for (var i = 0; i < n.childNodes.length; i++) if (isBlock(n.childNodes[i])) return blocks(n.childNodes);
        return inlineBlock(n);
      case "UL": case "OL": return list(n);
      case "BLOCKQUOTE":
        return blocks(n.childNodes).split("\n").map(function (l) { return l ? "> " + l : ">"; }).join("\n");
      case "PRE": return pre(n);
      case "HR": return attr(n, "data-md") || "---";
      case "TABLE": return table(n);
      case "DL": return dl(n);
      default: return blocks(n.childNodes);
    }
  }

  function codeText(n) {
    var s = "";
    (function walk(x) {
      for (var c = x.firstChild; c; c = c.nextSibling) {
        if (c.nodeType === 3) s += c.textContent;
        else if (c.nodeType === 1) {
          if (c.tagName === "BR") { s += "\n"; continue; }
          var blk = /^(DIV|P)$/.test(c.tagName);
          if (blk && s && s.charAt(s.length - 1) !== "\n") s += "\n";
          walk(c);
          if (blk && s.charAt(s.length - 1) !== "\n") s += "\n";
        }
      }
    })(n);
    return s.replace(/ /g, " ");
  }
  function fence(mark, info, body) {
    body = body.replace(/\n$/, "");
    var m = mark || "```";
    var ch = m.charAt(0);
    var longest = 0, rx = ch === "~" ? /~{3,}/g : /`{3,}/g, x;
    while ((x = rx.exec(body))) longest = Math.max(longest, x[0].length);
    while (m.length <= longest) m += ch;
    return m + (info || "") + "\n" + body + (body ? "\n" : "") + m;
  }
  function pre(n) {
    var code = n.querySelector("code") || n;
    var md = attr(code, "data-md") || attr(n, "data-md");
    var body = codeText(code);
    if (md === "indent") return body.replace(/\n$/, "").split("\n").map(function (l) { return l ? "    " + l : ""; }).join("\n");
    var info = attr(code, "data-md-info");
    if (info === null) { var m = (code.className || "").match(/language-(\S+)/); info = m ? m[1] : ""; }
    return fence(md || "```", info, body);
  }

  function list(n) {
    var ordered = n.tagName === "OL", mk = attr(n, "data-md") || (ordered ? "." : "-");
    var start = parseInt(attr(n, "start") || "1", 10); if (isNaN(start)) start = 1;
    var items = Array.prototype.filter.call(n.children, function (c) { return c.tagName === "LI"; });
    var loose = items.some(function (li) { return Array.prototype.some.call(li.children, function (c) { return c.tagName === "P"; }); });
    var out = items.map(function (li, i) {
      var marker = ordered ? (start + i) + mk : mk;
      var task = "";
      var box = li.querySelector(":scope > input[type=checkbox]");
      if (box) task = box.checked || box.hasAttribute("checked") ? "[x] " : "[ ] ";
      var body = blocks(li.childNodes, loose ? "\n\n" : "\n").replace(/^\s+/, "");
      var pad = new Array(marker.length + 2).join(" ");
      var lines = (task + body).split("\n");
      return (marker + (lines[0] ? " " + lines[0] : "")) + lines.slice(1).map(function (l) { return "\n" + (l ? pad + l : ""); }).join("");
    });
    return out.join(loose ? "\n\n" : "\n");
  }

  function table(n) {
    var rows = Array.prototype.slice.call(n.querySelectorAll("tr"));
    if (!rows.length) return "";
    function cells(tr) {
      return Array.prototype.filter.call(tr.children, function (c) { return /^T[DH]$/.test(c.tagName); });
    }
    function line(tr) {
      return "| " + cells(tr).map(function (c) {
        return kids(c).replace(/^\s+|\s+$/g, "").replace(/\n/g, " ").replace(/\|/g, "\\|");
      }).join(" | ") + " |";
    }
    var head = rows[0];
    var aligns = cells(head).map(function (c) {
      var a = (c.style && c.style.textAlign) || attr(c, "align") || "";
      return a === "left" ? ":---" : a === "right" ? "---:" : a === "center" ? ":---:" : "---";
    });
    return [line(head), "| " + aligns.join(" | ") + " |"].concat(rows.slice(1).map(line)).join("\n");
  }

  function dl(n) {
    var out = [];
    Array.prototype.forEach.call(n.children, function (c) {
      if (c.tagName === "DT") out.push(inlineBlock(c));
      else if (c.tagName === "DD") {
        var body = blocks(c.childNodes).split("\n");
        out.push(": " + body[0] + body.slice(1).map(function (l) { return "\n" + (l ? "  " + l : ""); }).join(""));
      }
    });
    return out.join("\n");
  }

  // Serialise a run of top-level nodes that now stand where one source block was.
  function serializeNodes(nodes) {
    var parts = [], run = [];
    function flushRun() {
      if (!run.length) return;
      var s = escLineStarts(inline(run).replace(/^\s+|\s+$/g, ""));
      if (s) parts.push(s);
      run = [];
    }
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i];
      // WebKit can split a code block into two <pre> that share one range: join them back.
      if (n.nodeType === 1 && n.tagName === "PRE" && !n.hasAttribute("data-mermaid-src")) {
        var group = [n];
        while (i + 1 < nodes.length && nodes[i + 1].nodeType === 1 && nodes[i + 1].tagName === "PRE" &&
               stampOf(nodes[i + 1]) === stampOf(n)) group.push(nodes[++i]);
        flushRun();
        if (group.length > 1) {
          var code = group[0].querySelector("code") || group[0];
          var body = group.map(function (p) { return codeText(p.querySelector("code") || p).replace(/\n$/, ""); }).join("\n");
          var info = attr(code, "data-md-info"); if (info === null) info = "";
          parts.push(fence(attr(code, "data-md") || "```", info, body));
        } else parts.push(pre(n));
        continue;
      }
      if (n.nodeType === 1 && isBlock(n)) { flushRun(); var b = block(n); if (b) parts.push(b); }
      else if (n.nodeType === 1 || (n.nodeType === 3 && n.textContent.replace(/\s/g, ""))) run.push(n);
    }
    flushRun();
    return parts.join("\n\n");
  }
  E.serializeNodes = serializeNodes;

  // ---------- three-way line merge ----------
  function fuzzyKey(l) { return l.replace(/\s+/g, "").replace(/-{3,}/g, "---"); }
  function fuzzyEq(b, o) { return o === b || fuzzyKey(o) === fuzzyKey(b) || (b.length > 0 && o.length > b.length && o.slice(-b.length) === b); }
  function exactEq(a, b) { return a === b; }
  function lcs(a, b, eq) {
    var n = a.length, m = b.length, pairs = [];
    if (!n || !m || n * m > 4000000) return pairs;
    var dp = new Array(n + 1);
    for (var i = 0; i <= n; i++) dp[i] = new Int32Array(m + 1);
    for (i = n - 1; i >= 0; i--) for (var j = m - 1; j >= 0; j--)
      dp[i][j] = eq(a[i], b[j]) ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    i = 0; j = 0;
    while (i < n && j < m) {
      if (eq(a[i], b[j]) && dp[i][j] === dp[i + 1][j + 1] + 1) { pairs.push([i, j]); i++; j++; }
      else if (dp[i + 1][j] >= dp[i][j + 1]) i++; else j++;
    }
    return pairs;
  }
  function same(a, b) { if (a.length !== b.length) return false; for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false; return true; }
  function resolveLines(Oc, Bc, Nc) {
    if (Oc.length !== Bc.length) return Nc.slice();
    var p = 0;
    while (p < Bc.length && p < Nc.length && Bc[p] === Nc[p]) p++;
    var q = 0;
    while (q < Bc.length - p && q < Nc.length - p && Bc[Bc.length - 1 - q] === Nc[Nc.length - 1 - q]) q++;
    var out = Oc.slice(0, p), bm = Bc.slice(p, Bc.length - q), nm = Nc.slice(p, Nc.length - q), om = Oc.slice(p, Oc.length - q);
    if (bm.length === nm.length) {
      for (var k = 0; k < bm.length; k++) {
        var o = om[k], b = bm[k], nn = nm[k];
        if (b === nn) out.push(o);
        else if (o !== b && b && o.length > b.length && o.slice(-b.length) === b) out.push(o.slice(0, o.length - b.length) + nn);
        else out.push(nn);
      }
    } else out = out.concat(nm);
    return out.concat(Oc.slice(Oc.length - q));
  }
  function merge3(O, B, N) {
    if (same(N, B)) return O.slice();
    if (same(B, O)) return N.slice();
    var bo = lcs(B, O, fuzzyEq), bn = lcs(B, N, exactEq);
    var bToN = []; for (var i = 0; i < B.length; i++) bToN.push(-1);
    bn.forEach(function (p) { bToN[p[0]] = p[1]; });
    var nStart = [], cur = 0;
    for (var b = 0; b < B.length; b++) {
      if (bToN[b] >= 0) { nStart[b] = bToN[b]; cur = bToN[b] + 1; } else nStart[b] = cur;
    }
    nStart[B.length] = N.length;
    var out = N.slice(0, nStart[0]);
    function chunk(b0, b1, o0, o1) {
      var Bc = B.slice(b0, b1), Oc = O.slice(o0, o1), Nc = N.slice(nStart[b0], nStart[b1]);
      out = out.concat(same(Bc, Nc) ? Oc : resolveLines(Oc, Bc, Nc));
    }
    var pb = 0, po = 0;
    bo.forEach(function (p) {
      if (p[0] > pb || p[1] > po) chunk(pb, p[0], po, p[1]);
      chunk(p[0], p[0] + 1, p[1], p[1] + 1);
      pb = p[0] + 1; po = p[1] + 1;
    });
    chunk(pb, B.length, po, O.length);
    return out;
  }
  E.merge3 = merge3;

  // ---------- per-render state + change tracking ----------
  function stampOf(n) {
    return n && n.nodeType === 1 && n.hasAttribute("data-src-start") ? n.getAttribute("data-src-start") + "-" + n.getAttribute("data-src-end") : null;
  }
  function isFootnoteChrome(n) {
    return n.nodeType === 1 && (n.classList.contains("footnotes") || n.classList.contains("footnotes-sep"));
  }
  function footnoteParas(root) {
    return Array.prototype.slice.call(root.querySelectorAll("section.footnotes p[data-src-start]"));
  }

  function makeAtoms(c) {
    c.querySelectorAll(".katex-display, .katex, pre.mermaid, .mermaid-error, sup.footnote-ref, a.footnote-backref, input")
      .forEach(function (n) { if (!(n.classList.contains("katex") && n.parentNode.closest && n.parentNode.closest(".katex-display"))) n.setAttribute("contenteditable", "false"); });
  }

  // Read only again (an old version is on screen): no caret, no posts.
  E.disable = function (c) {
    E.enabled = false;
    if (timer) { clearTimeout(timer); timer = null; }
    if (observer) { observer.disconnect(); observer = null; }
    S = null;
    if (c) { c.removeAttribute("contenteditable"); c.blur(); }
  };

  E.setup = function (c, markdown) {
    if (observer) observer.disconnect();
    makeAtoms(c);
    // markdown-it puts a fence's attributes on <code>; the block is the <pre>.
    Array.prototype.forEach.call(c.children, function (n) {
      var code = n.tagName === "PRE" && !n.hasAttribute("data-src-start") && n.querySelector("code[data-src-start]");
      if (code) { n.setAttribute("data-src-start", code.getAttribute("data-src-start")); n.setAttribute("data-src-end", code.getAttribute("data-src-end")); }
    });
    var lines = markdown.split(/\r?\n/);
    var ranges = [], pristine = {};
    var clone = c.cloneNode(true);
    Array.prototype.forEach.call(clone.childNodes, function (n) {
      var k = stampOf(n);
      if (k && !pristine[k] && !isFootnoteChrome(n)) { pristine[k] = n; ranges.push(rangeOf(k, "top")); }
    });
    footnoteParas(clone).forEach(function (n) {
      var k = stampOf(n);
      if (!pristine[k]) { pristine[k] = n; ranges.push(rangeOf(k, "fn")); }
    });
    ranges.sort(function (a, b) { return a.s - b.s; });
    S = { c: c, O: lines, original: lines.join("\n"), last: lines.join("\n"), ranges: ranges, pristine: pristine,
          baseline: {}, cur: {}, dirty: [], changed: 0, posts: 0 };
    window.__mdliveEditInfo = { changedBlocks: 0, posts: 0, blocks: ranges.length };
    observer = new MutationObserver(function (recs) { note(recs); });
    observer.observe(c, { childList: true, characterData: true, subtree: true });
  };
  function rangeOf(k, kind) { var p = k.split("-"); return { key: k, s: +p[0], e: +p[1], kind: kind }; }

  function note(recs) {
    if (!S) return;
    recs.forEach(function (r) {
      S.dirty.push(r.target);
      if (r.type === "childList") {
        if (r.previousSibling) S.dirty.push(r.previousSibling);
        if (r.nextSibling) S.dirty.push(r.nextSibling);
        Array.prototype.forEach.call(r.addedNodes, function (a) { S.dirty.push(a); });
      }
    });
  }

  function baseline(k) {
    if (!(k in S.baseline)) S.baseline[k] = serializeNodes([S.pristine[k]]).split("\n");
    return S.baseline[k];
  }
  function touched(nodes) {
    for (var i = 0; i < S.dirty.length; i++) {
      var d = S.dirty[i];
      for (var j = 0; j < nodes.length; j++) if (nodes[j] === d || nodes[j].contains(d)) return true;
    }
    return false;
  }
  function recompute(k, nodes) {
    var r = null;
    for (var i = 0; i < S.ranges.length; i++) if (S.ranges[i].key === k) { r = S.ranges[i]; break; }
    var text = serializeNodes(nodes);
    var N = text === "" ? [] : text.split("\n");
    S.cur[k] = merge3(S.O.slice(r.s, r.e), baseline(k), N);
  }

  function process() {
    timer = null;
    if (!S) return;
    if (observer) note(observer.takeRecords());
    var c = S.c, segs = [], seg = null, seen = {};
    Array.prototype.forEach.call(c.childNodes, function (n) {
      if (isFootnoteChrome(n)) return;
      if (n.nodeType === 3 && !n.textContent.replace(/\s/g, "")) return;
      if (n.nodeType !== 1 && n.nodeType !== 3) return;
      var k = stampOf(n);
      if (k && S.pristine[k] && !seen[k]) { seen[k] = true; seg = { key: k, nodes: [n] }; segs.push(seg); }
      else if (seg) seg.nodes.push(n);
      else { seg = { key: null, nodes: [n] }; segs.push(seg); }
    });
    var lead = null;
    segs.forEach(function (sg) {
      if (sg.key === null) { var t = serializeNodes(sg.nodes); lead = t ? t.split("\n") : null; return; }
      if (sg.nodes.length > 1 || touched(sg.nodes) || S.cur[sg.key]) {
        if (sg.nodes.length > 1 || touched(sg.nodes)) recompute(sg.key, sg.nodes);
      }
    });
    footnoteParas(c).forEach(function (p) {
      var k = stampOf(p);
      if (!S.pristine[k]) return;
      seen[k] = true;
      if (touched([p])) recompute(k, [p]);
    });
    S.dirty = [];

    var out = lead ? lead.concat([""]) : [], pos = 0, O = S.O, changed = 0;
    S.ranges.forEach(function (r) {
      for (var i = pos; i < r.s; i++) out.push(O[i]);
      pos = Math.max(pos, r.s);
      var rep = seen[r.key] ? S.cur[r.key] : [];
      if (rep && !same(rep, O.slice(r.s, r.e))) changed++;
      if (rep && rep.length === 0) {
        pos = r.e;
        // A removed block takes the blank lines after it, so no gap is doubled.
        if (!out.length || out[out.length - 1] === "") while (pos < O.length && O[pos] === "") pos++;
        return;
      }
      if (rep) out = out.concat(rep); else for (i = r.s; i < r.e; i++) out.push(O[i]);
      pos = r.e;
    });
    for (var i = pos; i < O.length; i++) out.push(O[i]);
    var text = out.join("\n");
    S.changed = changed + (lead ? 1 : 0);
    window.__mdliveEditInfo = { changedBlocks: S.changed, posts: S.posts, blocks: S.ranges.length };
    if (text === S.last) return;
    S.last = text;
    S.posts++;
    window.__mdliveEditInfo.posts = S.posts;
    try { window.webkit.messageHandlers.edit.postMessage(text); } catch (e) {}
  }
  E.flush = function () { if (timer) { clearTimeout(timer); } process(); return window.__mdliveEditInfo; };

  function schedule() { if (timer) clearTimeout(timer); timer = setTimeout(process, 60); }

  function anchorElement() {
    var sel = window.getSelection();
    if (!sel || !sel.rangeCount) return null;
    var n = sel.getRangeAt(0).startContainer;
    return n.nodeType === 1 ? n : n.parentNode;
  }

  E.enable = function (c) {
    E.enabled = true;
    c.setAttribute("contenteditable", "true");
    c.setAttribute("spellcheck", "false");
    try { document.execCommand("defaultParagraphSeparator", false, "p"); } catch (e) {}
    if (!document.getElementById("mdlive-edit-css")) {
      var st = document.createElement("style");
      st.id = "mdlive-edit-css";
      st.textContent = "#content[contenteditable]{outline:none}";
      document.head.appendChild(st);
    }
    if (!listening) {
      listening = true;
      c.addEventListener("input", schedule);
      c.addEventListener("beforeinput", function (e) {
        var t = e.inputType;
        if (t !== "insertParagraph" && t !== "insertLineBreak") return;
        var a = anchorElement();
        if (!a || !a.closest) return;
        // Enter in a code block adds a line inside it (WebKit writes "\n" in pre text).
        if (a.closest("pre")) { if (t === "insertParagraph") { e.preventDefault(); document.execCommand("insertLineBreak"); } }
        else if (a.closest("td,th")) e.preventDefault(); // a table cell is one line
      });
      // Paste as plain text so pasted content takes the document's own look.
      c.addEventListener("paste", onPaste);
      c.addEventListener("drop", function (e) {
        var dt = e.dataTransfer;
        if (dt && dt.types && Array.prototype.indexOf.call(dt.types, "Files") >= 0) e.preventDefault();
      });
    }
    E.setup(c, window.__mdliveSource || "");
  };

  // Paste as plain text. When a source only offers HTML, its text is used.
  function onPaste(e) {
    var dt = e.clipboardData, t = dt ? dt.getData("text/plain") : "";
    if (!t && dt) {
      var h = dt.getData("text/html");
      if (h) t = new DOMParser().parseFromString(h, "text/html").body.textContent || "";
    }
    e.preventDefault();
    if (t) document.execCommand("insertText", false, t);
  }

  // ---------- Format menu commands ----------
  // One entry point for the Format menu, its shortcuts and the headless gate.
  // Every command goes through execCommand, so WebKit's undo stack and the
  // normal input -> splice -> autosave path run exactly as they do for typing.
  var INLINE = { bold: "bold", italic: "italic", strikethrough: "strikeThrough" };
  var BLOCKS = { heading1: "H1", heading2: "H2", heading3: "H3", body: "P" };

  function contentRoot() { return document.getElementById("content"); }
  function selRange() {
    var sel = window.getSelection();
    if (!sel || !sel.rangeCount) return null;
    var r = sel.getRangeAt(0), c = contentRoot();
    return c && c.contains(r.commonAncestorContainer) ? r : null;
  }
  function elOf(n) { return n && (n.nodeType === 1 ? n : n.parentNode); }
  function topBlock(n) {
    var c = contentRoot();
    while (n && n.parentNode && n.parentNode !== c) n = n.parentNode;
    return n && n.parentNode === c ? n : null;
  }
  function closestIn(n, sel) {
    var e = elOf(n), c = contentRoot();
    while (e && e !== c) { if (e.matches && e.matches(sel)) return e; e = e.parentNode; }
    return null;
  }
  function selectRange(r) { var s = window.getSelection(); s.removeAllRanges(); s.addRange(r); }

  // A collapsed caret strictly inside a word acts on that word, as in Docs.
  // At a word boundary (right after or before a word, in a space or next to
  // punctuation) nothing is selected and false comes back, so a bold or
  // italic command only sets the typing style for what is typed next.
  function expandToWord() {
    var r = selRange();
    if (!r || !r.collapsed || r.startContainer.nodeType !== 3) return false;
    var t = r.startContainer.textContent, a = r.startOffset, b = a, w = /[\wÀ-￿'-]/;
    if (a === 0 || a >= t.length || !w.test(t.charAt(a - 1)) || !w.test(t.charAt(a))) return false;
    while (a > 0 && w.test(t.charAt(a - 1))) a--;
    while (b < t.length && w.test(t.charAt(b))) b++;
    var nr = document.createRange();
    nr.setStart(r.startContainer, a); nr.setEnd(r.startContainer, b);
    selectRange(nr);
    return true;
  }

  function escHtml(t) { return t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }

  // Inline code has no execCommand of its own: insertHTML keeps it undoable.
  function toggleCode() {
    var r = selRange(); if (!r) return false;
    var code = closestIn(r.commonAncestorContainer, "code");
    if (code && closestIn(code, "pre")) return false;
    if (code) {
      var whole = document.createRange(); whole.selectNode(code); selectRange(whole);
      return document.execCommand("insertHTML", false, escHtml(code.textContent));
    }
    var text = r.toString();
    if (!text) return false;
    return document.execCommand("insertHTML", false, "<code>" + escHtml(text) + "</code>");
  }

  function toggleLink(url) {
    var r = selRange(); if (!r) return false;
    var a = closestIn(r.commonAncestorContainer, "a");
    if (!url) {
      if (!a) return false;
      var whole = document.createRange(); whole.selectNodeContents(a); selectRange(whole);
      return document.execCommand("unlink");
    }
    if (a) { a.setAttribute("href", url); schedule(); return true; }
    if (r.collapsed) {
      // Nothing selected and no word under the caret: the URL is its own text.
      document.execCommand("insertText", false, url);
      var r2 = selRange();
      if (!r2 || r2.startContainer.nodeType !== 3 || r2.startOffset < url.length) return true;
      var nr = document.createRange();
      nr.setStart(r2.startContainer, r2.startOffset - url.length); nr.setEnd(r2.startContainer, r2.startOffset);
      selectRange(nr);
    }
    return document.execCommand("createLink", false, url);
  }

  // After a block command WebKit puts a fresh element where the old block was.
  // It inherits the old block's source range so the splice replaces those lines.
  function restamp(start, end) {
    if (start === null) return;
    var c = contentRoot();
    if (c.querySelector(':scope > [data-src-start="' + start + '"][data-src-end="' + end + '"]')) return;
    var r = selRange(), top = r && topBlock(r.startContainer);
    if (top && top.nodeType === 1 && !top.hasAttribute("data-src-start")) {
      top.setAttribute("data-src-start", start); top.setAttribute("data-src-end", end);
    }
  }

  // WebKit joins a new list item onto a list right next to it. In Markdown that
  // rewrites the neighbour too, so the new item gets a list of its own and the
  // neighbour keeps its source lines (the blank line between them stays).
  function splitMergedList(nb) {
    var c = contentRoot(), r = selRange(), li = r && closestIn(r.startContainer, "li");
    var lst = li && li.parentNode;
    if (!lst || lst.parentNode !== c) return;
    var items = Array.prototype.filter.call(lst.children, function (x) { return x.tagName === "LI"; });
    if (items.length < 2) return;
    var idx = items.indexOf(li);
    if (idx !== 0 && idx !== items.length - 1) return;
    var at = textOffset(li, r.startContainer, r.startOffset);
    var fresh = document.createElement(lst.tagName);
    lst.removeAttribute("data-src-start"); lst.removeAttribute("data-src-end");
    for (var i = 0; i < nb.length; i++) {
      if (nb[i].tag === lst.tagName && nb[i].s !== null) {
        lst.setAttribute("data-src-start", nb[i].s); lst.setAttribute("data-src-end", nb[i].e); break;
      }
    }
    c.insertBefore(fresh, idx === 0 ? lst : lst.nextSibling);
    fresh.appendChild(li);
    caretAtOffset(li, at);
  }

  function blockCommand(cmd) {
    var r = selRange(); if (!r) return false;
    var top = topBlock(r.startContainer);
    var start = top && top.nodeType === 1 ? top.getAttribute("data-src-start") : null;
    var end = top && top.nodeType === 1 ? top.getAttribute("data-src-end") : null;
    var ok;
    if (cmd === "bulletList" || cmd === "numberList") {
      var wasList = top && /^(UL|OL)$/.test(top.tagName);
      var nb = top && top.nodeType === 1 ? [top.previousElementSibling, top.nextElementSibling].filter(Boolean)
        .map(function (e) { return { tag: e.tagName, s: attr(e, "data-src-start"), e: attr(e, "data-src-end") }; }) : [];
      ok = document.execCommand(cmd === "bulletList" ? "insertUnorderedList" : "insertOrderedList");
      if (ok && !wasList) splitMergedList(nb);
    } else {
      var want = BLOCKS[cmd], cur = closestIn(r.startContainer, "h1,h2,h3,h4,h5,h6,p,li,div");
      if (cur && cur.tagName === want && want !== "P") want = "P"; // the same heading again toggles it off
      ok = document.execCommand("formatBlock", false, "<" + want.toLowerCase() + ">");
    }
    restamp(start, end);
    return ok;
  }

  // Character offset of (node, off) inside `block`, and the way back. Used to
  // put a collapsed caret back where it was after a word command.
  function textOffset(block, node, off) {
    var r = document.createRange(); r.selectNodeContents(block); r.setEnd(node, off);
    return r.toString().length;
  }
  function caretAtOffset(block, n) {
    var w = document.createTreeWalker(block, NodeFilter.SHOW_TEXT, null), t, last = null;
    while ((t = w.nextNode())) {
      last = t;
      if (n <= t.textContent.length) break;
      n -= t.textContent.length;
    }
    if (!last) return;
    var r = document.createRange();
    r.setStart(last, Math.min(n, last.textContent.length)); r.collapse(true);
    selectRange(r);
  }

  E.format = function (cmd, arg) {
    var c = contentRoot();
    if (!E.enabled || !c) return false;
    var r0 = selRange();
    if (!r0) return false;
    try { document.execCommand("styleWithCSS", false, false); } catch (e) {}
    // A plain caret acts on the word under it, and stays a plain caret at the
    // same spot afterwards (as in Docs). Leaving the expanded word selected
    // showed as a highlight, and in a one-word line that is the whole line.
    var block = r0.collapsed ? topBlock(r0.startContainer) : null;
    var at = block && block.nodeType === 1 ? textOffset(block, r0.startContainer, r0.startOffset) : null;
    // At a word boundary Bold, Italic and Strikethrough run on the bare caret,
    // which toggles WebKit's typing style. Moving the selection afterwards would
    // clear that style, so the caret is left alone in that case.
    var ok = false, word = false;
    if (INLINE[cmd]) { word = expandToWord(); ok = document.execCommand(INLINE[cmd]); }
    else if (cmd === "code") { word = true; expandToWord(); ok = toggleCode(); }
    else if (cmd === "link") { word = true; expandToWord(); ok = toggleLink(arg || ""); }
    else if (BLOCKS[cmd] || cmd === "bulletList" || cmd === "numberList") ok = blockCommand(cmd);
    if (at !== null && !(INLINE[cmd] && !word)) {
      if (word && block.parentNode === c) caretAtOffset(block, at);
      else { var s = window.getSelection(); if (s.rangeCount && !s.isCollapsed) s.collapseToEnd(); }
    }
    schedule();
    return !!ok;
  };

  // Headless gate helpers.
  // Select the first occurrence of `text` anywhere in #content.
  E.selectText = function (text) {
    var c = contentRoot(); if (!c || !text) return { ok: false };
    var w = document.createTreeWalker(c, NodeFilter.SHOW_TEXT, null), nodes = [], all = "", n;
    while ((n = w.nextNode())) { nodes.push([n, all.length]); all += n.textContent; }
    var at = all.indexOf(text);
    if (at < 0) return { ok: false, error: "not found: " + text };
    function pos(i, isEnd) {
      for (var k = nodes.length - 1; k >= 0; k--) {
        var s = nodes[k][1];
        if (isEnd ? s < i : s <= i) return [nodes[k][0], i - s];
      }
      return [nodes[0][0], 0];
    }
    var a = pos(at, false), b = pos(at + text.length, true);
    c.focus();
    var r = document.createRange();
    r.setStart(a[0], a[1]); r.setEnd(b[0], b[1]);
    selectRange(r);
    return { ok: true, target: elOf(a[0]).tagName, selected: r.toString() };
  };
  // Put a collapsed caret in the middle of the first occurrence of `word`, or
  // right after it when `where` is "end".
  E.caretInWord = function (word, where) {
    var r = E.selectText(word);
    if (!r.ok) return r;
    var sel = window.getSelection(), rg = sel.getRangeAt(0);
    if (where === "end") {
      sel.collapseToEnd();
      return { ok: true, target: r.target, collapsed: window.getSelection().isCollapsed };
    }
    var n = rg.startContainer, at = rg.startOffset + Math.floor(word.length / 2);
    if (n.nodeType === 3 && at <= n.textContent.length) {
      var c = document.createRange(); c.setStart(n, at); c.collapse(true); selectRange(c);
    } else sel.collapseToStart();
    return { ok: true, target: r.target, collapsed: window.getSelection().isCollapsed };
  };
  // Type text at the caret through the normal editing path.
  E.typeText = function (text) {
    var c = contentRoot(); if (!c) return { ok: false };
    if (document.activeElement !== c) c.focus();
    return { ok: document.execCommand("insertText", false, text) };
  };
  // Run the real paste handler with HTML (plus its text) on the clipboard.
  E.testPaste = function (html) {
    var c = contentRoot();
    var dt = new DataTransfer();
    dt.setData("text/html", html);
    dt.setData("text/plain", new DOMParser().parseFromString(html, "text/html").body.textContent || "");
    var ev = new ClipboardEvent("paste", { clipboardData: dt, bubbles: true, cancelable: true });
    var r = selRange();
    (r ? elOf(r.startContainer) : c).dispatchEvent(ev);
    return { ok: true, prevented: ev.defaultPrevented };
  };

  // Headless edit gate (MDLIVE_EDIT_SELFTEST): put the caret at the end of the
  // first element matching `selector` and, if `text` is given, type it through
  // the normal editing path.
  E.selfTest = function (selector, text) {
    var c = document.getElementById("content");
    var el = c.querySelector(selector || "p");
    if (!el) return { ok: false, error: "no element for " + selector };
    c.focus();
    var r = document.createRange();
    r.selectNodeContents(el);
    r.collapse(false);
    var sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(r);
    if (text) document.execCommand("insertText", false, text);
    return { ok: true, target: el.tagName, editable: c.isContentEditable };
  };
})();
